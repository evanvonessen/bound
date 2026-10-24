import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { insertLegacyRow, legacyRowPlan, prepareArchiveImport } from '../import-archive.mjs';

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'bound-import-archive-'));
  const bytes = Buffer.from('historical-save');
  const entry = { id: '11111111-1111-4111-8111-111111111111', owner: '22222222-2222-4222-8222-222222222222',
    projectRef: 'fixture', bucket: 'cup040-saves', sourceId: '33333333-3333-4333-8333-333333333333',
    sourceVersion: 'version-one', sourceUpdatedAt: '2026-01-01T00:00:00.123456Z', size: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex') };
  entry.name = entry.owner + '/nested/save.bin';
  entry.sourceRowText = JSON.stringify({ id: entry.sourceId, bucket_id: entry.bucket, name: entry.name,
    owner_id: entry.owner, version: entry.sourceVersion, updated_at: entry.sourceUpdatedAt, metadata: { size: bytes.length } });
  const manifestPath = join(root, 'manifest.json'), sourceCalls = [], inserts = [];
  const manifest = { version: 1, projectRef: 'fixture', objects: [entry] };
  await mkdir(join(root, 'objects'));
  await writeFile(join(root, 'objects', entry.id), bytes);
  await writeFile(manifestPath, JSON.stringify(manifest));
  const source = { async query(sql, parameters) {
    assert.ok(sql.startsWith('SELECT count(*)'));
    assert.ok(sql.includes('"bound_migration_export"."users"'));
    assert.equal(parameters[1], entry.sourceRowText); sourceCalls.push(parameters);
    return { rows: [{ count: '1' }] };
  } };
  const destination = { async query(sql, parameters) {
    if (sql.startsWith('INSERT')) inserts.push(parameters);
    return { rows: [{ count: String(inserts.length) }] };
  } };
  const options = { source, manifestPath, objectCount: 1, sourceUsers: 'bound_migration_export.users',
    env: { FILE_DIRECTORY: join(root, 'destination') } };
  return { root, bytes, entry, manifest, sourceCalls, inserts, destination, options,
    output: join(root, 'destination', 'archive', entry.id), cleanup: () => rm(root, { recursive: true, force: true }) };
}

test('verified archive copies exact bytes and original metadata before marking the destination ready', async () => {
  const f = await fixture();
  try {
    const plan = await prepareArchiveImport(f.options);
    assert.equal(plan.count, 1); assert.equal(plan.bytes, f.bytes.length); assert.equal(f.inserts.length, 0);
    assert.equal(f.sourceCalls.length, 1);
    await plan.apply(f.destination);
    assert.deepEqual(await readFile(f.output), f.bytes);
    assert.equal(f.inserts.length, 1); assert.equal(f.inserts[0][8], f.entry.sourceRowText);
    assert.equal(f.inserts[0][1], f.entry.owner); assert.equal(f.inserts[0][10], f.entry.sha256);
    await plan.discard(); await assert.rejects(access(f.output));
  } finally { await f.cleanup(); }
});

test('changed staged bytes fail before publishing a manifest and rollback removes only new files', async () => {
  const f = await fixture();
  try {
    const plan = await prepareArchiveImport(f.options);
    await writeFile(join(f.root, 'objects', f.entry.id), Buffer.alloc(f.bytes.length, 1));
    await assert.rejects(plan.apply(f.destination), { code: 'archive_digest_mismatch' });
    assert.equal(f.inserts.length, 0);
    await plan.discard(); await assert.rejects(access(f.output));
  } finally { await f.cleanup(); }
});

test('missing inventory, changed source metadata and owner mismatches remain blockers', async () => {
  const f = await fixture();
  try {
    await assert.rejects(prepareArchiveImport({ ...f.options, objectCount: 2 }), { code: 'archive_inventory_mismatch' });
    await assert.rejects(prepareArchiveImport({ ...f.options, source: { async query() { return { rows: [{ count: '0' }] }; } } }),
      { code: 'archive_source_snapshot_mismatch' });
    f.manifest.objects[0].owner = '44444444-4444-4444-8444-444444444444';
    await writeFile(f.options.manifestPath, JSON.stringify(f.manifest));
    await assert.rejects(prepareArchiveImport(f.options), { code: 'invalid_archive_entry' });
  } finally { await f.cleanup(); }
});

test('completed deletion receipts retain full private history and fences without activating old capabilities', async () => {
  const owner = '55555555-5555-4555-8555-555555555555', operation = 'a'.repeat(64);
  const fields = (table) => (table.endsWith('.deletions')
    ? [['owner', 'uuid'], ['complete', 'bool'], ['requested_at', 'timestamptz']]
    : [['operation', 'text'], ['owner', 'uuid']]).map(([name, type]) => ({ name, type, nullable: 'NO', type_schema: 'pg_catalog' }));
  const source = (table, invalid = false) => ({ async query(sql) {
    if (sql.includes('FROM pg_index')) return { rows: [{ name: table.endsWith('.deletions') ? 'owner' : 'operation' }] };
    assert.ok(sql.includes('WHERE EXISTS(SELECT 1 FROM "auth"."users"'));
    assert.ok(table.endsWith('.deletions') ? sql.includes('complete IS DISTINCT FROM true')
      : sql.includes("operation !~ '^[a-f0-9]{64}$'") && sql.includes('d.complete=true'));
    return { rows: [{ count: invalid ? '1' : '0' }] };
  } });
  const writes = [], destination = { async query(sql, values) { writes.push({ sql, values }); } };
  for (const table of ['cup117_private.deletions', 'cup117_private.capabilities']) {
    const plan = await legacyRowPlan(source(table), table, fields(table), 1);
    const row = { owner, source_key: JSON.stringify([table.endsWith('.deletions') ? owner : operation]),
      source_row: JSON.stringify(table.endsWith('.deletions')
        ? { owner, complete: 'true', requested_at: '2026-01-01 00:00:00.123456+00' } : { operation, owner }) };
    await insertLegacyRow(destination, plan, row);
    assert.equal(writes.find(write => write.values[0] === table).values[3], row.source_row);
    await assert.rejects(legacyRowPlan(source(table, true), table, fields(table), 1),
      { code: table.endsWith('.deletions') ? 'legacy_deletion_pending_or_active' : 'legacy_deletion_capability_mismatch' });
  }
  assert.equal(writes.filter(write => write.sql.startsWith('INSERT INTO bound_archive_private.deleted_records')).length, 2);
  assert.deepEqual(writes.find(write => write.sql.startsWith('INSERT INTO cup117_private.deletions')).values, [owner]);
  assert.equal(writes.some(write => /deletion_jobs|INSERT INTO cup117_private.capabilities/.test(write.sql)), false);
});
