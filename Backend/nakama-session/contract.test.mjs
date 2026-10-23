import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import test from 'node:test';

const pg = await import(process.env.PG_MODULE ?? 'pg');
const Client = pg.Client ?? pg.default?.Client;
const socket = process.env.BOUND_NAKAMA_TEST_SOCKET;
if (!socket?.startsWith('/private/tmp/')) throw Error('Use a disposable PostgreSQL Unix socket under /private/tmp');
const owner = '11111111-1111-4111-8111-111111111111';
const peer = '22222222-2222-4222-8222-222222222222';
const stranger = '33333333-3333-4333-8333-333333333333';
const roomID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const session = randomUUID(), peerSession = randomUUID(), strangerSession = randomUUID();

test('Nakama room authorization preserves existing APIs and enforces live identities, sessions and moderation', async t => {
  const config = { host: socket, port: Number(process.env.BOUND_NAKAMA_TEST_PORT ?? 54923), database: 'postgres' };
  const admin = new Client(config); await admin.connect();
  const database = 'bound_nakama_' + randomUUID().replaceAll('-', '');
  await admin.query('CREATE DATABASE ' + database);
  const db = new Client({ ...config, database }); await db.connect();
  const concurrent = new Client({ ...config, database }); await concurrent.connect();
  const exec = sql => db.query(sql);
  const as = async (sub = owner, sid = session, extras = {}) => {
    await exec('RESET ROLE');
    await db.query("SELECT set_config('request.jwt.claims',$1,false)", [JSON.stringify({ sub, role: 'authenticated', session_id: sid, ...extras })]);
    await exec('SET ROLE authenticated');
  };
  const root = async () => { await exec('RESET ROLE'); };
  const call = async (payload = { roomID }) => (await db.query('SELECT public.bound_nakama_room_v1($1::jsonb) result', [JSON.stringify(payload)])).rows[0].result;
  const denied = { ok: false, error: 'forbidden' };
  const functions = ['public.cup050_friends(text,jsonb)', 'public.bound_run_lease_v1(text,jsonb)',
    'public.bound_require_mfa()', 'cup117_private.assert_active(uuid)', 'bound_moderation_private.denied_pair(uuid,uuid)'];
  const hashes = async () => (await db.query('SELECT md5(pg_get_functiondef(value::regprocedure)) hash FROM unnest($1::text[]) value', [functions])).rows;
  try {
    await exec(await readFile(new URL('./local-fixture.sql', import.meta.url), 'utf8'));
    // Reuse the checked-in deletion fixture's actual lock + active-account guard.
    const deletionFixture = await readFile(new URL('../moderation/local-fixture.sql', import.meta.url), 'utf8');
    const guard = deletionFixture.match(/CREATE FUNCTION cup117_private\.assert_active\(actor uuid\)[\s\S]*?END \$\$;/)?.[0];
    assert.ok(guard); await exec(guard);
    // Load the exact existing MFA functions, without its cluster-wide PostgREST
    // role setting or unrelated RLS-policy deployment.
    const mfa = await readFile(new URL('../account-security/contract.sql', import.meta.url), 'utf8');
    const mfaFunctions = mfa.split('-- Storage does not execute')[0];
    assert.ok(mfaFunctions.includes('CREATE FUNCTION public.bound_require_mfa()'));
    await exec(mfaFunctions + '\nCOMMIT;');
    const migrations = new URL('../multiplayer/supabase/migrations/', import.meta.url);
    for (const file of (await readdir(migrations)).filter(file => file.endsWith('.sql')).sort()) await exec(await readFile(new URL(file, migrations), 'utf8'));
    await db.query('INSERT INTO auth.users(id) VALUES($1),($2),($3)', [owner, peer, stranger]);
    await db.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2),($3,$4),($5,$6)', [session, owner, peerSession, peer, strangerSession, stranger]);
    await db.query("INSERT INTO cup050_private.rooms(id,owner_a,owner_b,name_a,name_b) VALUES($1,$2,$3,'A','B')", [roomID, owner, peer]);
    const before = await hashes();
    await exec(await readFile(new URL('./contract.sql', import.meta.url), 'utf8'));
    assert.deepEqual(await hashes(), before, 'existing friend, lease, MFA, deletion and moderation functions remain identical');

    await t.test('public invoker and private definer grant only authenticated execution with empty search paths', async () => {
      const definitions = (await db.query(`SELECT proname,prosecdef,proconfig FROM pg_proc
        WHERE oid IN('public.bound_nakama_room_v1(jsonb)'::regprocedure,'bound_multiplayer_private.nakama_room_v1(jsonb)'::regprocedure)
        ORDER BY proname`)).rows;
      assert.equal(definitions.find(row => row.proname === 'bound_nakama_room_v1').prosecdef, false);
      assert.equal(definitions.find(row => row.proname === 'nakama_room_v1').prosecdef, true);
      for (const value of definitions) assert.ok(value.proconfig.includes('search_path=""'));
      for (const role of ['anon', 'service_role']) {
        await exec('SET ROLE ' + role);
        await assert.rejects(call(), /permission denied/);
        await assert.rejects(db.query("SELECT bound_multiplayer_private.nakama_room_v1('{}')"), /permission denied/);
        await root();
      }
      await as();
      for (const table of ['auth.users', 'auth.sessions', 'cup050_private.rooms', 'bound_moderation_private.blocks', 'bound_multiplayer_private.run_leases']) {
        await assert.rejects(db.query('SELECT * FROM ' + table), /permission denied/);
      }
      await root();
    });
    await t.test('both eligible members receive only their own owner identity and sorted authorized membership', async () => {
      await as();
      assert.deepEqual(await call(), { roomID, ownerID: owner, peerID: peer, members: [owner, peer] });
      await as(peer, peerSession);
      assert.deepEqual(await call(), { roomID, ownerID: peer, peerID: owner, members: [owner, peer] });
      await root();
    });
    await t.test('unrelated owner and inactive or nonexistent rooms are denied', async () => {
      await as(stranger, strangerSession); assert.deepEqual(await call(), denied);
      await as(); assert.deepEqual(await call({ roomID: randomUUID() }), denied);
      await root(); await db.query('UPDATE cup050_private.rooms SET active=false WHERE id=$1', [roomID]);
      await as(); assert.deepEqual(await call(), denied);
      await root(); await db.query('UPDATE cup050_private.rooms SET active=true WHERE id=$1', [roomID]);
    });
    await t.test('malformed payloads cannot choose owners, peers or extra fields', async () => {
      await as();
      for (const payload of [{}, null, [], { roomID: 'invalid' }, { roomID, ownerID: stranger }, { roomID, members: [owner, stranger] }, { roomID, large: 'x'.repeat(200) }]) {
        assert.deepEqual(await call(payload), denied);
      }
      await root();
    });
    await t.test('missing, foreign, revoked and expired Auth sessions are denied', async () => {
      await as(owner, undefined, { session_id: null }); assert.deepEqual(await call(), denied);
      await as(owner, 'invalid'); assert.deepEqual(await call(), denied);
      await as(owner, peerSession); assert.deepEqual(await call(), denied);
      await as(owner, session, { role: 'anon' }); assert.deepEqual(await call(), denied);
      await root(); await db.query('DELETE FROM auth.sessions WHERE id=$1', [session]);
      await as(); assert.deepEqual(await call(), denied);
      await root(); await db.query("INSERT INTO auth.sessions(id,user_id,not_after) VALUES($1,$2,now()-interval '1 second')", [session, owner]);
      await as(); assert.deepEqual(await call(), denied);
      await root(); await db.query('UPDATE auth.sessions SET not_after=NULL WHERE id=$1', [session]);
    });
    await t.test('MFA enrollment requires AAL2 while preserving existing unenrolled accounts', async () => {
      await db.query("INSERT INTO auth.mfa_factors(user_id,status) VALUES($1,'verified')", [owner]);
      await as(owner, session, { aal: 'aal1' }); await assert.rejects(call(), /second_factor_required/);
      await as(owner, session, { aal: 'aal2' }); assert.equal((await call()).ownerID, owner);
      await as(peer, peerSession); assert.equal((await call()).ownerID, peer);
      await root(); await db.query('DELETE FROM auth.mfa_factors WHERE user_id=$1', [owner]);
    });
    await t.test('unconfirmed, anonymous and soft-deleted accounts on either side are denied', async () => {
      for (const target of [owner, peer]) {
        for (const update of ['email_confirmed_at=NULL', 'is_anonymous=true', 'deleted_at=now()']) {
          await db.query('UPDATE auth.users SET ' + update + ' WHERE id=$1', [target]);
          await as();
          if (update.startsWith('deleted_at')) await assert.rejects(call(), /account unavailable/);
          else assert.deepEqual(await call(), denied);
          await root();
          await db.query('UPDATE auth.users SET email_confirmed_at=now(),is_anonymous=false,deleted_at=NULL WHERE id=$1', [target]);
        }
      }
    });
    await t.test('pending deletion markers for either member prevent admission', async () => {
      for (const target of [owner, peer]) {
        await db.query('INSERT INTO cup117_private.deletions(owner) VALUES($1)', [target]);
        await as(); await assert.rejects(call(), /account unavailable/);
        await root(); await db.query('DELETE FROM cup117_private.deletions WHERE owner=$1', [target]);
      }
    });
    await t.test('blocks in either direction and suspensions of either member prevent admission', async () => {
      for (const [a, b] of [[owner, peer], [peer, owner]]) {
        await db.query('INSERT INTO bound_moderation_private.blocks(owner,target) VALUES($1,$2)', [a, b]);
        await as(); assert.deepEqual(await call(), denied);
        await root(); await db.query('DELETE FROM bound_moderation_private.blocks');
      }
      for (const target of [owner, peer]) {
        await db.query('INSERT INTO bound_moderation_private.suspensions(owner) VALUES($1)', [target]);
        await as(); assert.deepEqual(await call(), denied);
        await root(); await db.query('DELETE FROM bound_moderation_private.suspensions');
      }
    });
    await t.test('a queued room request observes a block or session revocation committed ahead of it', async () => {
      for (const action of ['block', 'revoke']) {
        await concurrent.query('BEGIN');
        try {
          await concurrent.query('SELECT pg_advisory_xact_lock(505002026)');
          if (action === 'block') await concurrent.query('INSERT INTO bound_moderation_private.blocks(owner,target) VALUES($1,$2)', [peer, owner]);
          else await concurrent.query('DELETE FROM auth.sessions WHERE id=$1', [session]);
          await as(); const pending = call();
          await new Promise(resolve => setTimeout(resolve, 30));
          await concurrent.query('COMMIT');
          assert.deepEqual(await pending, denied);
        } finally { await concurrent.query('ROLLBACK'); }
        await root();
        await db.query('DELETE FROM bound_moderation_private.blocks');
        if (action === 'revoke') await db.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)', [session, owner]);
      }
    });
    await as(); assert.equal((await call()).ownerID, owner, 'restored eligible membership works after all denials');
    await root(); assert.deepEqual(await hashes(), before);
  } finally {
    await concurrent.end(); await db.end();
    await admin.query('DROP DATABASE ' + database); await admin.end();
  }
});
