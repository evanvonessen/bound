import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile, readFile, mkdir, utimes } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createArchive, archiveDirectory, validateArchiveEntry } from '../archive.mjs';
import { createFileService } from '../files.mjs';

const owner = '11111111-1111-4111-8111-111111111111';
const peer = '22222222-2222-4222-8222-222222222222';
const id = '33333333-3333-4333-8333-333333333333';
const digest = value => createHash('sha256').update(value).digest('hex');
const request = (path = `/${id}`) => new Request(`https://bound.example/files/v1/archive${path}`);

async function setup(t, content = Buffer.from('private historic save')) {
  const directory = await mkdtemp(join(tmpdir(), 'bound-archive-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const config = { FILE_DIRECTORY: directory }, archived = archiveDirectory(config);
  await mkdir(archived);
  const row = { id, owner, bucket: 'cup040-saves', name: `${owner}/game/save.sav`, size: content.length,
    sha256: digest(content), imported_at: new Date(), state: 'ready' };
  const rows = new Map([[id, row]]);
  await writeFile(join(archived, id), content);
  const state = { owner, active: true, revoked: false };
  const pool = { async query(sql, args) {
    if (sql.startsWith('SELECT id,bucket')) return { rows: [...rows.values()].filter(row => row.owner === args[0] && row.state === 'ready' && (!args[1] || row.id > args[1])) };
    if (sql.startsWith('SELECT id,size')) return { rows: [...rows.values()].filter(row => row.id === args[0] && row.owner === args[1] && row.state === 'ready') };
    if (sql.startsWith('SELECT id FROM bound_archive')) return { rows: [...rows.values()].filter(row => row.owner === args[0]) };
    if (sql.startsWith('DELETE FROM bound_archive')) { for (const [key, row] of rows) if (row.owner === args[0]) rows.delete(key); return { rows: [] }; }
    if (sql.includes('FROM bound_files_private.transfers')) return { rows: [] };
    assert.fail('unexpected query: ' + sql);
  }};
  const auth = async () => { if (state.revoked) throw Error('revoked'); return { ownerID: state.owner }; };
  const rpc = async () => state.active;
  const archive = createArchive({ pool, authenticate: auth, rpc, config });
  return { archive, pool, config, archived, content, rows, state, row, auth, rpc };
}

test('archive entries retain the original JSON text and reject conflicting owner metadata', () => {
  const sourceRowText = `{"id":"${id}","bucket_id":"cup040-saves","name":"${owner}/save","owner_id":"${owner}","metadata":{"size":1,"historicalBigint":9007199254740993}}`;
  const entry = { id, owner, projectRef: 'project', bucket: 'cup040-saves', name: `${owner}/save`, sourceId: id,
    sourceRowText, size: 1, sha256: digest('x') };
  assert.equal(validateArchiveEntry(entry).sourceRowText, sourceRowText);
  assert.throws(() => validateArchiveEntry({ ...entry, owner: peer }), /invalid_archive_entry/);
  assert.throws(() => validateArchiveEntry({ ...entry, sourceRowText: sourceRowText.replace(`"owner_id":"${owner}"`, `"owner_id":"${peer}"`) }), /archive_source_mismatch/);
});

test('archives require an active Nakama owner and reject corrupt bytes', async t => {
  const fixture = await setup(t), { archive, state, content, archived } = fixture;
  state.revoked = true;
  assert.equal((await archive.handle(request())).status, 401);
  state.revoked = false; state.active = false;
  assert.equal((await archive.handle(request())).status, 403);
  state.active = true; state.owner = peer;
  assert.equal((await archive.handle(request())).status, 404);
  assert.deepEqual((await (await archive.handle(request(''))).json()).objects, []);
  state.owner = owner;
  const response = await archive.handle(request());
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), content);
  await writeFile(join(archived, id), Buffer.alloc(content.length));
  assert.equal((await archive.handle(request())).status, 404);
});

test('temporary-file cleanup never expires archived bytes; purge drains downloads and removes receipts', async t => {
  const fixture = await setup(t, Buffer.alloc(2 * 1024 * 1024, 3));
  const { archive, pool, config, archived, content, rows, auth, rpc } = fixture;
  await utimes(join(archived, id), new Date(0), new Date(0));
  const temporary = createFileService({ pool, authenticate: auth, rpc, config });
  await temporary.cleanup();
  assert.deepEqual(await readFile(join(archived, id)), content);
  const response = await archive.handle(request());
  assert.equal(response.status, 200);
  await archive.purgeOwner(owner);
  assert.equal(rows.size, 0);
  await assert.rejects(readFile(join(archived, id)), { code: 'ENOENT' });
  await assert.rejects(response.arrayBuffer());
});

test('failed archive cleanup retains receipts for a retry', async t => {
  const { archive, archived, rows } = await setup(t);
  await rm(join(archived, id));
  await mkdir(join(archived, id)); // An unlink failure must not discard its receipt.
  await assert.rejects(archive.purgeOwner(owner));
  assert.equal(rows.size, 1);
  await rm(join(archived, id), { recursive: true });
  await archive.purgeOwner(owner);
  assert.equal(rows.size, 0);
});
