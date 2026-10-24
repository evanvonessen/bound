import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, createHash } from 'node:crypto';
import { readFile, mkdtemp, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBackups, backupDirectory } from '../backups.mjs';
import { setBackupApproval } from '../backup-access.mjs';

// Opt-in only. All user/schema/filesystem changes are confined to a newly named
// disposable database and temporary directory; no live account is read/changed.
const databaseURL = process.env.BOUND_BACKUP_TEST_DATABASE_URL;
test('isolated PostgreSQL backup schema, approval, CAS, retention, revocation, and owner deletion', { skip: !databaseURL }, async () => {
  const { default: pg } = await import('pg');
  const name = 'bound_backup_test_' + randomBytes(6).toString('hex');
  const admin = new pg.Client({ connectionString: databaseURL });
  const url = new URL(databaseURL); url.pathname = '/' + name;
  const pool = new pg.Pool({ connectionString: url.toString(), max: 8 });
  const directory = await mkdtemp(join(tmpdir(), 'bound-backup-db-test-'));
  const owner = '11111111-1111-4111-8111-111111111111', peer = '22222222-2222-4222-8222-222222222222';
  const session = '33333333-3333-4333-8333-333333333333';
  let currentOwner = owner, revoked = false, created = false;
  const content = Buffer.concat([Buffer.from('504b0304', 'hex'), Buffer.from('save bytes')]);
  const sha = createHash('sha256').update(content).digest('hex');
  const request = (path, method = 'GET', body, headers = {}) => new Request('https://bound.example/backups/v1/' + path,
    { method, headers, ...(body === undefined ? {} : { body, duplex: 'half' }) });
  try {
    await admin.connect(); await admin.query('CREATE DATABASE ' + name); created = true;
    await pool.query(`CREATE TABLE public.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz,deleted_at timestamptz);
      CREATE SCHEMA auth;
      CREATE VIEW auth.users AS SELECT * FROM public.users;
      CREATE TABLE auth.sessions(id uuid,user_id uuid REFERENCES public.users(id) ON DELETE CASCADE,not_after timestamptz);
      CREATE SCHEMA cup117_private;
      CREATE TABLE cup117_private.deletions(owner uuid PRIMARY KEY);
      INSERT INTO public.users VALUES('${owner}','owner@example.invalid',now(),NULL),('${peer}','peer@example.invalid',now(),NULL);
      INSERT INTO auth.sessions VALUES('${session}','${owner}',now()+interval '1 hour'),('${session}','${peer}',now()+interval '1 hour');`);
    await pool.query(await readFile(new URL('../backups.sql', import.meta.url), 'utf8'));
    const config = { FILE_DIRECTORY: directory };
    const backups = createBackups({ pool, config,
      authenticate: async () => { if (revoked) throw Error('revoked'); return { ownerID: currentOwner, sessionID: session }; },
      rpc: async () => true });
    const status = async () => (await backups.handle(request('status'))).json();
    const provider = async value => backups.handle(request('provider', 'PUT', JSON.stringify({ provider: value, expectedRevision: (await status()).revision }), { 'content-type': 'application/json' }));
    const upload = (version = '*', bytes = content) => backups.handle(request('saves/game', 'PUT', bytes, {
      'content-type': 'application/zip', 'x-content-sha256': createHash('sha256').update(bytes).digest('hex'),
      'if-match': version, 'x-backup-name': 'Game',
    }));
    assert.equal((await status()).approved, false);
    assert.equal((await status()).provider, 'dropbox');
    assert.equal((await provider('server')).status, 403);
    await setBackupApproval(pool, { action: 'approve', email: 'owner@example.invalid' });
    assert.equal((await provider('server')).status, 200);
    const first = await upload(); assert.equal(first.status, 200); let version = (await first.json()).version;
    assert.equal((await upload()).status, 409);
    for (let i = 0; i < 3; i++) { const next = await upload(version); assert.equal(next.status, 200); version = (await next.json()).version; }
    assert.equal((await pool.query('SELECT count(*)::int AS n FROM bound_backups_private.objects')).rows[0].n, 3);
    assert.equal((await readdir(join(backupDirectory(config), owner))).length, 3);
    const list = await (await backups.handle(request('saves'))).json();
    assert.equal(list.saves.length, 1); assert.equal(list.saves[0].version, version);
    const download = await backups.handle(request('saves/game'));
    assert.equal(download.status, 200); assert.equal(download.headers.get('x-content-sha256'), sha);
    assert.deepEqual(Buffer.from(await download.arrayBuffer()), content);
    currentOwner = peer;
    await setBackupApproval(pool, { action: 'approve', email: 'peer@example.invalid' });
    await provider('server');
    assert.equal((await backups.handle(request('saves/game'))).status, 404);
    assert.deepEqual((await (await backups.handle(request('saves'))).json()).saves, []);
    currentOwner = owner;
    const denied = await setBackupApproval(pool, { action: 'revoke', email: 'owner@example.invalid' });
    assert.equal(denied.approved, false);
    assert.equal((await status()).provider, 'none');
    assert.equal((await backups.handle(request('saves/game'))).status, 403);
    assert.equal((await backups.handle(request('saves/game', 'DELETE'))).status, 200);
    assert.equal((await pool.query('SELECT count(*)::int AS n FROM bound_backups_private.objects')).rows[0].n, 0);
    await setBackupApproval(pool, { action: 'approve', email: 'owner@example.invalid' });
    await provider('server'); assert.equal((await upload()).status, 200);
    // Never-opening-settings case: approval exists for the verified mailbox
    // but has not yet bound to the account. Preserve unrelated future grants.
    await pool.query('DELETE FROM bound_backups_private.approvals WHERE owner=$1', [owner]);
    await pool.query("INSERT INTO bound_backups_private.approvals(email) VALUES('owner@example.invalid')");
    await setBackupApproval(pool, { action: 'approve', email: 'future@example.invalid', pending: true });
    await backups.prepareDeletion(owner);
    assert.equal((await pool.query("SELECT 1 FROM bound_backups_private.approvals WHERE email='owner@example.invalid'")).rowCount, 0);
    await pool.query('DELETE FROM public.users WHERE id=$1', [owner]);
    // Durable receipts intentionally outlive the user until filesystem purge.
    assert.equal((await pool.query('SELECT count(*)::int AS n FROM bound_backups_private.objects')).rows[0].n, 1);
    revoked = true; await backups.purgeOwner(owner);
    assert.equal((await pool.query('SELECT count(*)::int AS n FROM bound_backups_private.objects')).rows[0].n, 0);
    await assert.rejects(readdir(join(backupDirectory(config), owner)), { code: 'ENOENT' });
    assert.equal((await pool.query("SELECT owner FROM bound_backups_private.approvals WHERE email='future@example.invalid'")).rows[0].owner, null);
    const recreated = '44444444-4444-4444-8444-444444444444';
    await pool.query("INSERT INTO public.users VALUES($1,'owner@example.invalid',now(),NULL)", [recreated]);
    await pool.query("INSERT INTO auth.sessions VALUES($1,$2,now()+interval '1 hour')", [session, recreated]);
    revoked = false; currentOwner = recreated;
    assert.equal((await status()).approved, false);
    currentOwner = peer;
    assert.equal((await upload()).status, 200);
    await pool.query('DELETE FROM public.users WHERE id=$1', [peer]);
    await backups.cleanup();
    assert.equal((await pool.query('SELECT count(*)::int AS n FROM bound_backups_private.objects')).rows[0].n, 0);
    await assert.rejects(readdir(join(backupDirectory(config), peer)), { code: 'ENOENT' });
  } finally {
    await pool.end();
    if (created) await admin.query('DROP DATABASE ' + name);
    await admin.end(); await rm(directory, { recursive: true, force: true });
  }
});
