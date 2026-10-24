import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createBackups, backupDirectory } from '../backups.mjs';
import { setBackupApproval, normalizeApprovalEmail } from '../backup-access.mjs';

const owner = '11111111-1111-4111-8111-111111111111';
const peer = '22222222-2222-4222-8222-222222222222';
const session = '33333333-3333-4333-8333-333333333333';
const digest = value => createHash('sha256').update(value).digest('hex');
const zip = value => Buffer.concat([Buffer.from('504b0304', 'hex'), Buffer.from(value)]);
const tick = () => new Promise(resolve => setImmediate(resolve));
function request(path, { method = 'GET', body, headers = {} } = {}) {
  return new Request(`https://bound.example/backups/v1/${path}`, { method, headers,
    ...(body === undefined ? {} : { body, duplex: 'half' }) });
}
function put(game, body, version = '*', headers = {}) {
  return request('saves/' + game, { method: 'PUT', body, headers: {
    'content-type': 'application/zip', 'if-match': version,
    'x-content-sha256': Buffer.isBuffer(body) ? digest(body) : 'a'.repeat(64),
    'x-backup-name': encodeURIComponent('Pokémon FireRed'), ...headers,
  } });
}

async function fixture(t, options = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'bound-backups-test-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const config = { FILE_DIRECTORY: dir, ...options };
  const state = { owner, active: true, revoked: false, confirmed: true, rows: new Map(), prefs: new Map(),
    grants: new Map([[owner, { email: 'owner@example.invalid', owner, approved: true, revision: randomUUID() }]]),
    users: new Map([[owner, { id: owner, email: 'owner@example.invalid', email_confirmed_at: new Date() }],
      [peer, { id: peer, email: 'peer@example.invalid', email_confirmed_at: new Date() }]]), locks: new Map(), time: Date.now() };
  const rows = (id, game) => [...state.rows.values()].filter(row => (!id || row.owner === id) && (!game || row.game_id === game));
  const ordered = (id, game) => rows(id, game).filter(row => row.state === 'ready').sort((a, b) => b.modified_at - a.modified_at || b.version.localeCompare(a.version));
  function client() {
    let unlock = null;
    return { async query(input, args = []) {
      const sql = input.replace(/\s+/g, ' ').trim();
      if (sql.startsWith('SELECT pg_advisory_lock(')) {
        const previous = state.locks.get(args[0]) ?? Promise.resolve();
        let finish; const next = new Promise(resolve => { finish = resolve; });
        state.locks.set(args[0], next);
        await previous; unlock = finish;
        return { rows: [] };
      }
      if (sql.startsWith('SELECT pg_advisory_unlock(')) { unlock?.(); unlock = null; return { rows: [] }; }
      if (sql.startsWith('SELECT pg_try_advisory_lock(')) return { rows: [{ locked: true }] };
      if (sql.startsWith('SELECT owner FROM bound_backups_private.approvals')) return { rows: state.grants.has(args[0]) ? [{ owner: args[0] }] : [] };
      if (['BEGIN', 'COMMIT', 'ROLLBACK'].includes(sql) || sql.startsWith('SELECT pg_advisory_xact_lock')) return { rows: [] };
      if (sql.startsWith('SELECT u.id FROM auth.users')) return { rows: state.active && !state.revoked && state.confirmed && state.users.has(args[0]) ? [{ id: args[0] }] : [] };
      if (sql.startsWith('UPDATE bound_backups_private.approvals a')) {
        const user = state.users.get(args[0]);
        const grant = [...state.grants.values()].find(grant => grant.email === user?.email && grant.owner === null && grant.approved);
        if (grant && state.confirmed && user.email_confirmed_at) { state.grants.delete(null); grant.owner = args[0]; state.grants.set(args[0], grant); }
        return { rows: [] };
      }
      if (sql.startsWith('INSERT INTO bound_backups_private.preferences')) {
        if (!state.prefs.has(args[0])) state.prefs.set(args[0], { provider: 'dropbox', revision: randomUUID() });
        return { rows: [] };
      }
      if (sql.startsWith('SELECT p.provider')) {
        const pref = state.prefs.get(args[0]), grant = state.grants.get(args[0]);
        return { rows: pref ? [{ ...pref, approved: grant?.approved, approval_revision: grant?.revision }] : [] };
      }
      if (sql.startsWith('UPDATE bound_backups_private.preferences SET provider=$2')) {
        state.prefs.set(args[0], { provider: args[1], revision: randomUUID() }); return { rows: [] };
      }
      if (sql.startsWith("UPDATE bound_backups_private.preferences SET provider='none'")) {
        if (state.prefs.get(args[0])?.provider === 'server') state.prefs.set(args[0], { provider: 'none', revision: randomUUID() });
        return { rows: [] };
      }
      if (sql.startsWith('SELECT coalesce(sum(size)')) return { rows: [{ total: rows().reduce((sum, row) => sum + row.size, 0), owned: rows(args[0]).reduce((sum, row) => sum + row.size, 0) }] };
      if (sql.startsWith('INSERT INTO bound_backups_private.objects')) {
        const [version, id, game_id, name, size, sha256] = args;
        state.rows.set(version, { version, owner: id, game_id, name, size, sha256, state: 'uploading', modified_at: new Date(++state.time) });
        state.onReserve?.(); return { rows: [] };
      }
      if (sql.startsWith('UPDATE bound_backups_private.objects SET state')) {
        const row = state.rows.get(args[0]);
        if (!row || row.state !== 'uploading') return { rows: [] };
        Object.assign(row, { state: 'ready', size: args[1], modified_at: new Date(++state.time) }); return { rows: [row] };
      }
      if (sql.startsWith('SELECT DISTINCT ON(game_id)')) return { rows: [...new Set(ordered(args[0]).map(row => row.game_id))].map(game => ordered(args[0], game)[0]) };
      if (sql.startsWith('SELECT * FROM bound_backups_private.objects')) {
        if (sql.includes("state='uploading'")) return { rows: rows(args[0]).filter(row => row.state === 'uploading' && row.modified_at.getTime() < Date.now() - 600000) };
        if (sql.includes('LIMIT 1')) return { rows: ordered(args[0], args[1]).slice(0, 1) };
        if (sql.includes('OFFSET $3')) return { rows: ordered(args[0], args[1]).slice(args[2]) };
        return { rows: rows(args[0], args[1]) };
      }
      if (sql.startsWith('DELETE FROM bound_backups_private.objects')) { state.rows.delete(args[0]); return { rows: [] }; }
      if (sql.startsWith('DELETE FROM bound_backups_private.approvals')) {
        state.grants.delete(args[0]);
        const user = state.users.get(args[0]);
        if (sql.includes('SELECT lower(email)') && user?.email_confirmed_at) {
          for (const [key, grant] of state.grants) if (grant.owner === null && grant.email === user.email) state.grants.delete(key);
        }
        return { rows: [] };
      }
      if (sql.startsWith('DELETE FROM bound_backups_private.preferences')) { state.prefs.delete(args[0]); return { rows: [] }; }
      if (sql.startsWith('SELECT DISTINCT o.owner')) return { rows: [...new Set(rows().filter(row => !state.users.has(row.owner)).map(row => row.owner))].map(owner => ({ owner })) };
      if (sql.startsWith('SELECT DISTINCT owner')) return { rows: [] };
      if (sql.startsWith('SELECT id,email_confirmed_at FROM auth.users')) return { rows: [...state.users.values()].filter(user => user.email === args[0]) };
      if (sql.startsWith('UPDATE bound_backups_private.approvals SET owner=NULL')) {
        const grant = state.grants.get(args[0]);
        if (grant && grant.email !== args[1]) { state.grants.delete(args[0]); Object.assign(grant, { owner: null, approved: false, revision: randomUUID() }); state.grants.set(null, grant); }
        return { rows: [] };
      }
      if (sql.startsWith('INSERT INTO bound_backups_private.approvals(email')) {
        const previous = [...state.grants.values()].find(grant => grant.email === args[0]);
        const grant = { email: args[0], owner: args[1] ?? previous?.owner ?? null, approved: args[2], revision: randomUUID() };
        state.grants.set(grant.owner, grant); return { rows: [grant] };
      }
      assert.fail('Unexpected SQL: ' + sql);
    }, release() { assert.equal(unlock, null, 'release must release owner lock'); } };
  }
  const pool = { connect: async () => client(), query: async (...args) => { const c = client(); return c.query(...args); } };
  const authenticate = async () => {
    if (state.revoked) throw Error('revoked');
    return { ownerID: state.owner, sessionID: session };
  };
  const backups = createBackups({ pool, authenticate, rpc: async () => state.active, config });
  const status = async () => (await backups.handle(request('status'))).json();
  const provider = async (value, revision) => backups.handle(request('provider', { method: 'PUT', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ provider: value, expectedRevision: revision ?? (await status()).revision }) }));
  return { backups, state, config, pool, authenticate, status, provider, dir: backupDirectory(config) };
}

test('status preserves Dropbox default; only verified approved owners can select server with current revision', async t => {
  const { backups, state, status, provider } = await fixture(t);
  const first = await status();
  assert.equal(first.provider, 'dropbox'); assert.equal(first.approved, true);
  assert.equal((await provider('server', first.revision)).status, 200);
  assert.equal((await provider('none', first.revision)).status, 409);
  state.owner = peer;
  assert.equal((await status()).approved, false);
  assert.equal((await provider('server')).status, 403);
  assert.equal((await backups.handle(request('saves'))).status, 403);
  state.revoked = true;
  assert.equal((await backups.handle(request('status'))).status, 401);
  state.revoked = false; state.active = false;
  assert.equal((await backups.handle(request('status'))).status, 401);
});

test('pending email approval binds only a verified account and cannot be claimed by another email', async t => {
  const { state, status } = await fixture(t);
  state.grants.delete(owner);
  state.grants.set(null, { owner: null, email: 'owner@example.invalid', approved: true, revision: randomUUID() });
  state.owner = peer; assert.equal((await status()).approved, false);
  state.owner = owner; state.confirmed = false;
  assert.equal((await status()).error, 'forbidden');
  state.confirmed = true; assert.equal((await status()).approved, true);
  assert.equal(state.grants.get(owner).owner, owner);
});

test('owned save roundtrip preserves exact bytes and isolates list/download by owner', async t => {
  const { backups, state, provider } = await fixture(t);
  await provider('server');
  const bytes = zip('private save bytes');
  const saved = await backups.handle(put('game_1', bytes));
  assert.equal(saved.status, 200);
  const receipt = await saved.json();
  assert.equal(receipt.sha256, digest(bytes)); assert.equal(receipt.name, 'Pokémon FireRed');
  assert.equal(receipt.gameID, 'game_1'); assert.equal(receipt.size, bytes.length);
  const list = await (await backups.handle(request('saves'))).json();
  assert.deepEqual(list.saves, [receipt]);
  const response = await backups.handle(request('saves/game_1'));
  assert.equal(response.headers.get('x-backup-version'), receipt.version);
  assert.equal(response.headers.get('x-content-sha256'), receipt.sha256);
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), bytes);
  state.owner = peer;
  state.grants.set(peer, { owner: peer, email: 'peer@example.invalid', approved: true, revision: randomUUID() });
  await provider('server');
  assert.deepEqual((await (await backups.handle(request('saves'))).json()).saves, []);
  assert.equal((await backups.handle(request('saves/game_1'))).status, 404);
  assert.equal(state.rows.size, 1);
});

test('stale concurrent upload cannot overwrite a save and retention keeps three versions', async t => {
  const { backups, state, provider, dir } = await fixture(t);
  await provider('server');
  const [a, b] = await Promise.all([backups.handle(put('game', zip('one'))), backups.handle(put('game', zip('two')))]);
  assert.deepEqual([a.status, b.status].sort(), [200, 409]);
  let version = (await (a.status === 200 ? a : b).json()).version;
  for (const text of ['three', 'four', 'five']) {
    const response = await backups.handle(put('game', zip(text), version));
    assert.equal(response.status, 200); version = (await response.json()).version;
  }
  assert.equal(state.rows.size, 3);
  assert.equal((await readdir(join(dir, owner))).length, 3);
  assert.equal((await backups.handle(put('game', zip('stale'), '*'))).status, 409);
});

test('invalid hashes, formats, traversal, and size declarations leave no backup receipts', async t => {
  const { backups, state, provider, dir } = await fixture(t, { BACKUP_MAX_BYTES: 20 });
  await provider('server');
  assert.equal((await backups.handle(put('game', zip('hash'), '*', { 'x-content-sha256': '0'.repeat(64) }))).status, 400);
  assert.equal((await backups.handle(put('game', Buffer.from('not a zip')))).status, 400);
  assert.equal((await backups.handle(put('game', zip('large'), '*', { 'content-length': '21' }))).status, 413);
  assert.equal((await backups.handle(put('game', zip('x'), '*', { 'content-length': '7' }))).status, 400);
  assert.equal((await backups.handle(put('%2Fetc', zip('x')))).status, 404);
  assert.equal(state.rows.size, 0);
  assert.deepEqual(await readdir(join(dir, owner)), []);
});

test('owner and total quota include reserved uploads before accepting additional bytes', async t => {
  const { backups, state, provider } = await fixture(t, { BACKUP_MAX_BYTES: 64, BACKUP_OWNER_BYTES: 15, BACKUP_TOTAL_BYTES: 20 });
  await provider('server');
  const bytes = zip('123456'); // ten bytes
  assert.equal((await backups.handle(put('one', bytes, '*', { 'content-length': '10' }))).status, 200);
  assert.equal((await backups.handle(put('two', bytes, '*', { 'content-length': '10' }))).status, 413);
  state.owner = peer;
  state.grants.set(peer, { owner: peer, email: 'peer@example.invalid', approved: true, revision: randomUUID() });
  await provider('server');
  assert.equal((await backups.handle(put('one', bytes, '*', { 'content-length': '10' }))).status, 200);
  assert.equal((await backups.handle(put('two', zip('x'), '*', { 'content-length': '5' }))).status, 413);
});

test('session revoked while receiving an upload cannot publish and removes partial bytes', async t => {
  const { backups, state, provider, dir } = await fixture(t);
  await provider('server');
  let controller, reserved;
  const waiting = new Promise(resolve => { reserved = resolve; }); state.onReserve = reserved;
  const bytes = zip('private');
  const body = new ReadableStream({ start(value) { controller = value; controller.enqueue(bytes.subarray(0, 4)); } });
  const response = backups.handle(put('game', body, '*', { 'x-content-sha256': digest(bytes) }));
  await waiting;
  state.revoked = true; controller.enqueue(bytes.subarray(4)); controller.close();
  assert.equal((await response).status, 401);
  assert.equal(state.rows.size, 0);
  assert.deepEqual(await readdir(join(dir, owner)), []);
});

test('provider transition waits for active downloads; disabled provider rejects token issuance', async t => {
  const { backups, provider, authenticate } = await fixture(t);
  await provider('server');
  const bytes = zip(Buffer.alloc(1024 * 1024, 7));
  assert.equal((await backups.handle(put('game', bytes))).status, 200);
  const response = await backups.handle(request('saves/game'));
  let finished = false;
  const change = provider('dropbox').then(result => { finished = true; return result; });
  await tick(); assert.equal(finished, false);
  await response.arrayBuffer();
  assert.equal((await change).status, 200);
  let issued = false;
  assert.equal((await backups.withDropbox(await authenticate(), 'token', async () => { issued = true; return new Response('ok'); })).status, 200);
  assert.equal(issued, true);
  await provider('none'); issued = false;
  assert.equal((await backups.withDropbox(await authenticate(), 'token', async () => { issued = true; })).status, 403);
  assert.equal(issued, false);
});

test('owner purge aborts downloads and erases receipts; unapproved owners can delete their own old saves', async t => {
  const { backups, state, provider, dir } = await fixture(t);
  await provider('server');
  await backups.handle(put('game', zip(Buffer.alloc(1024 * 1024, 3))));
  state.grants.get(owner).approved = false;
  assert.equal((await backups.handle(request('saves/game', { method: 'DELETE' }))).status, 200);
  assert.equal(state.rows.size, 0);
  state.grants.get(owner).approved = true;
  await backups.handle(put('game', zip(Buffer.alloc(1024 * 1024, 3))));
  const response = await backups.handle(request('saves/game'));
  await backups.purgeOwner(owner);
  await assert.rejects(response.arrayBuffer());
  assert.equal(state.rows.size, 0);
  await assert.rejects(readdir(join(dir, owner)), { code: 'ENOENT' });
});

test('operator approvals require exact email, can pend future verified accounts, and revoke drains uploads', async t => {
  const { backups, state, provider, pool } = await fixture(t);
  assert.throws(() => normalizeApprovalEmail('Chico'), /email/);
  await assert.rejects(setBackupApproval(pool, { action: 'approve', email: 'missing@example.invalid' }), /No verified account/);
  const pending = await setBackupApproval(pool, { action: 'approve', email: 'Missing@Example.Invalid', pending: true });
  assert.equal(pending.pending, true); assert.equal(pending.email, 'missing@example.invalid');
  await provider('server');
  let controller, reserved;
  const waiting = new Promise(resolve => { reserved = resolve; }); state.onReserve = reserved;
  const bytes = zip('private');
  const body = new ReadableStream({ start(value) { controller = value; controller.enqueue(bytes.subarray(0, 4)); } });
  const uploading = backups.handle(put('game', body, '*', { 'x-content-sha256': digest(bytes) }));
  await waiting;
  const revoke = setBackupApproval(pool, { action: 'revoke', email: 'owner@example.invalid' });
  await tick(); controller.enqueue(bytes.subarray(4)); controller.close();
  assert.equal((await uploading).status, 403);
  assert.equal((await revoke).approved, false);
  assert.equal(state.prefs.get(owner).provider, 'none');
  assert.equal(state.rows.size, 0);
});

test('deleting a verified account removes its unclaimed pending grant and preserves future-user grants', async t => {
  const { backups, state, status } = await fixture(t);
  state.grants.delete(owner);
  state.grants.set('pending-owner', { owner: null, email: 'owner@example.invalid', approved: true, revision: randomUUID() });
  state.grants.set('pending-future', { owner: null, email: 'future@example.invalid', approved: true, revision: randomUUID() });
  // No status call before deletion: the first grant has never bound to a UUID.
  await backups.prepareDeletion(owner);
  assert.equal([...state.grants.values()].some(grant => grant.email === 'owner@example.invalid'), false);
  assert.equal([...state.grants.values()].some(grant => grant.email === 'future@example.invalid'), true);
  state.users.delete(owner);
  await backups.purgeOwner(owner);
  // Re-creating a verified account with that mailbox must not regain approval.
  state.users.set(owner, { id: owner, email: 'owner@example.invalid', email_confirmed_at: new Date() });
  assert.equal((await status()).approved, false);
});

test('cleanup erases native-deleted owners while preserving another owner\'s durable backups', async t => {
  const { backups, state, provider, dir } = await fixture(t);
  await provider('server');
  await backups.handle(put('game', zip('owner')));
  state.owner = peer;
  state.grants.set(peer, { owner: peer, email: 'peer@example.invalid', approved: true, revision: randomUUID() });
  await provider('server');
  await backups.handle(put('game', zip('peer')));
  state.users.delete(owner); // Native console deletion bypasses the HTTP route.
  await backups.cleanup();
  assert.equal([...state.rows.values()].some(row => row.owner === owner), false);
  assert.equal([...state.rows.values()].some(row => row.owner === peer), true);
  await assert.rejects(readdir(join(dir, owner)), { code: 'ENOENT' });
  assert.equal((await readdir(join(dir, peer))).length, 1);
});
