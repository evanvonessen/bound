import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { open, readFile, mkdir, unlink, lstat } from 'node:fs/promises';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { archiveDirectory, validateArchiveEntry } from './archive.mjs';

// Explicit historical Bound data, not an escape hatch for unknown tables.
export const legacyRowOwners = Object.freeze({
  'cup041_private.actors': 'owner', 'cup041_private.entities': 'owner',
  'cup041_private.games': 'owner', 'cup041_private.receipts': 'owner',
  'cup041_private.revisions': 'owner',
  'cup041_v3_private.actors': 'owner', 'cup041_v3_private.branches': 'owner',
  'cup041_v3_private.counters': 'owner', 'cup041_v3_private.games': 'owner',
  'cup041_v3_private.imports': 'owner', 'cup041_v3_private.markers': 'owner',
  'cup041_v3_private.observations': 'owner', 'cup041_v3_private.payloads': 'owner',
  'cup041_v3_private.receipts': 'owner', 'cup041_v3_private.values': 'owner',
  'public.bound_autosave_revisions': 'owner', 'public.bound_note_revisions': 'owner',
  'public.bound_roms': 'owner', 'public.cup040_catalogue': 'owner_id',
});
export const deletedRowOwners = Object.freeze({ 'cup117_private.deletions': 'owner', 'cup117_private.capabilities': 'owner' });
export const archiveTables = ['bound_archive_private.catalog', 'bound_archive_private.records', 'bound_archive_private.objects',
  'bound_archive_private.deleted_records'];
export const deletionDestinationTables = ['cup117_private.deletions', 'cup117_private.deletion_jobs'];
const quote = name => '"' + name.replaceAll('"', '""') + '"';
const relation = name => name.split('.').map(quote).join('.');
export class ArchiveImportError extends Error {
  constructor(code) { super(code); this.code = code; }
}
const fail = code => { throw new ArchiveImportError(code); };

export async function legacyRowPlan(source, table, fields, count, sourceUsers = 'auth.users') {
  const deleted = Object.hasOwn(deletedRowOwners, table);
  const owner = legacyRowOwners[table] ?? deletedRowOwners[table];
  if (!owner || !fields.some(field => field.name === owner && field.type === 'uuid' && field.nullable === 'NO')
      || fields.some(field => field.type_schema !== 'pg_catalog')) fail('unsupported_legacy_row_schema');
  const result = await source.query(`SELECT a.attname AS name FROM pg_index i
    CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(attnum,position)
    JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.attnum
    WHERE i.indrelid=$1::regclass AND i.indisprimary AND k.position<=i.indnkeyatts ORDER BY k.position`, [table]);
  const primaryKey = result.rows.map(row => row.name);
  if (!primaryKey.length || primaryKey.some(name => !fields.some(field => field.name === name))) fail('legacy_primary_key_required');
  if (deleted) {
    const deletions = table === 'cup117_private.deletions';
    const required = deletions ? ['complete', 'bool'] : ['operation', 'text'];
    if (!fields.some(field => field.name === required[0] && field.type === required[1] && field.nullable === 'NO')
        || JSON.stringify(primaryKey) !== JSON.stringify([deletions ? 'owner' : 'operation'])) fail('unsupported_legacy_deletion_schema');
    const invalid = await source.query(`SELECT count(*)::text AS count FROM ${relation(table)} t
      WHERE EXISTS(SELECT 1 FROM ${relation(sourceUsers)} u WHERE u.id=t.owner)
      OR ${deletions ? 't.complete IS DISTINCT FROM true' : `t.operation !~ '^[a-f0-9]{64}$'
        OR NOT EXISTS(SELECT 1 FROM cup117_private.deletions d WHERE d.owner=t.owner AND d.complete=true)`}`);
    if (invalid.rows[0]?.count !== '0') fail(deletions ? 'legacy_deletion_pending_or_active' : 'legacy_deletion_capability_mismatch');
  } else {
    const orphans = await source.query(`SELECT count(*)::text AS count FROM ${relation(table)} t
      WHERE NOT EXISTS(SELECT 1 FROM ${relation(sourceUsers)} u WHERE u.id=t.${quote(owner)})`);
    if (orphans.rows[0]?.count !== '0') fail('legacy_owner_not_found');
  }
  return { table, fields, count, owner, primaryKey, deleted };
}

export async function insertLegacyRow(destination, plan, row) {
  const target = plan.deleted ? 'bound_archive_private.deleted_records' : 'bound_archive_private.records';
  await destination.query(`INSERT INTO ${target}(source_table,source_key,owner,source_row)
    VALUES($1,$2,$3,$4::jsonb)`, [plan.table, row.source_key, row.owner, row.source_row]);
  if (plan.deleted && plan.table === 'cup117_private.deletions') {
    await destination.query('INSERT INTO cup117_private.deletions(owner,complete) VALUES($1,true)', [row.owner]);
  }
}

// Every cell uses its PostgreSQL text representation. This retains bigint,
// bytea, arrays, timestamp precision and SQL NULL versus a JSON null value.
export function legacyRowSelection(plan) {
  const pairs = plan.fields.flatMap(field => ["'" + field.name.replaceAll("'", "''") + "'", quote(field.name) + '::text']);
  return `${quote(plan.owner)}::text AS owner,
    jsonb_build_array(${plan.primaryKey.map(name => quote(name) + '::text').join(',')})::text AS source_key,
    jsonb_build_object(${pairs.join(',')})::text AS source_row`;
}

async function inspectBytes(path, expected, output) {
  const input = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const details = await input.stat();
    if (!details.isFile() || details.size !== expected.size) fail('archive_size_mismatch');
    const hash = createHash('sha256'), buffer = Buffer.alloc(64 * 1024);
    let size = 0;
    for (;;) {
      const { bytesRead } = await input.read(buffer, 0, buffer.length, null);
      if (!bytesRead) break;
      size += bytesRead;
      if (size > expected.size) fail('archive_size_mismatch');
      const chunk = buffer.subarray(0, bytesRead); hash.update(chunk);
      if (output) await output.writeFile(chunk);
    }
    if (size !== expected.size || hash.digest('hex') !== expected.sha256) fail('archive_digest_mismatch');
    if (output) await output.sync();
  } finally { await input.close(); }
}

export async function prepareArchiveImport({ source, manifestPath, objectCount, env = {}, sourceUsers = 'auth.users' }) {
  if (!manifestPath || !isAbsolute(manifestPath)) fail('storage_files_require_verified_manifest');
  let manifest;
  try { manifest = JSON.parse(await readFile(manifestPath, 'utf8')); }
  catch { fail('invalid_archive_manifest'); }
  if (manifest?.version !== 1 || !Array.isArray(manifest.objects) || manifest.objects.length !== objectCount
      || manifest.objects.length > 10000 || typeof manifest.projectRef !== 'string') fail('archive_inventory_mismatch');
  const sourceIDs = new Set(), destinationIDs = new Set(), paths = new Set();
  const staging = join(dirname(resolve(manifestPath)), 'objects');
  const stagingDetails = await lstat(staging);
  if (!stagingDetails.isDirectory() || stagingDetails.isSymbolicLink()) fail('invalid_archive_staging_directory');
  for (const entry of manifest.objects) {
    try { validateArchiveEntry(entry); } catch { fail('invalid_archive_entry'); }
    const path = entry.bucket + '/' + entry.name;
    if (entry.projectRef !== manifest.projectRef || sourceIDs.has(entry.sourceId) || destinationIDs.has(entry.id) || paths.has(path)) fail('archive_inventory_mismatch');
    sourceIDs.add(entry.sourceId); destinationIDs.add(entry.id); paths.add(path);
    // Compare complete original metadata in PostgreSQL, without reserializing
    // it through JS or exposing it in reports. Exact count+unique IDs covers all
    // source objects, including any unknown bucket which fails validation above.
    const result = await source.query(`SELECT count(*)::text AS count FROM storage.objects o
      JOIN ${relation(sourceUsers)} u ON u.id=$3::uuid
      WHERE o.id=$1::uuid AND to_jsonb(o)=$2::jsonb`, [entry.sourceId, entry.sourceRowText, entry.owner]);
    if (result.rows[0]?.count !== '1') fail('archive_source_snapshot_mismatch');
    await inspectBytes(join(staging, entry.id), entry);
  }
  const directory = archiveDirectory(env), created = [];
  async function apply(destination) {
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const directoryDetails = await lstat(directory);
    if (!directoryDetails.isDirectory() || directoryDetails.isSymbolicLink()) fail('invalid_archive_destination_directory');
    for (const entry of manifest.objects) {
      const file = join(directory, entry.id);
      // Reserve with O_EXCL; rollback may remove only paths this import created.
      const output = await open(file, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      created.push(file);
      try { await inspectBytes(join(staging, entry.id), entry, output); }
      finally { await output.close(); }
      await inspectBytes(file, entry);
      await destination.query(`INSERT INTO bound_archive_private.objects
        (id,owner,project_ref,bucket,name,source_id,source_version,source_updated_at,source_row,size,sha256,state)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10,$11,'ready')`,
      [entry.id, entry.owner, entry.projectRef, entry.bucket, entry.name, entry.sourceId,
        entry.sourceVersion ?? null, entry.sourceUpdatedAt ?? null, entry.sourceRowText, entry.size, entry.sha256]);
    }
    const directoryHandle = await open(directory, constants.O_RDONLY);
    try { await directoryHandle.sync(); } finally { await directoryHandle.close(); }
    const copied = await destination.query('SELECT count(*)::text AS count FROM bound_archive_private.objects');
    if (copied.rows[0]?.count !== String(objectCount)) fail('archive_import_count_mismatch');
  }
  async function discard() {
    for (const path of created) await unlink(path).catch(error => { if (error.code !== 'ENOENT') throw error; });
  }
  return { apply, discard, count: objectCount, bytes: manifest.objects.reduce((sum, entry) => sum + entry.size, 0) };
}
