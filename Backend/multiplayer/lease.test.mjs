import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
const { Client } = await import(process.env.PG_MODULE ?? 'pg');
const socket = process.env.BOUND_LEASE_TEST_SOCKET;
if (!socket?.startsWith('/private/tmp/')) throw Error('Use a disposable local PostgreSQL Unix socket under /private/tmp');
const owner = randomUUID(), other = randomUUID(), session = randomUUID(), otherSession = randomUUID();
const deviceA = randomUUID(), deviceB = randomUUID(), run = randomUUID();

test('exclusive per-player run leases fence concurrent devices, expiry, account changes and revoked sessions', async () => {
  const config = {host:socket,port:Number(process.env.BOUND_LEASE_TEST_PORT ?? 54884),database:'postgres'};
  const admin = new Client(config); await admin.connect();
  const database = 'bound_lease_' + randomUUID().replaceAll('-','');
  await admin.query('CREATE DATABASE ' + database);
  const db = new Client({...config,database}); await db.connect();
  db.exec = sql => db.query(sql);
  try {
    await db.exec(`DO $$ DECLARE r text; BEGIN FOREACH r IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
      IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('CREATE ROLE %I',r); END IF; END LOOP; END $$;
      CREATE SCHEMA auth; CREATE SCHEMA cup117_private;
      CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
      CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT (auth.jwt()->>'sub')::uuid $$;
      CREATE TABLE auth.users(id uuid PRIMARY KEY,deleted_at timestamptz,is_anonymous boolean DEFAULT false,email_confirmed_at timestamptz DEFAULT now());
      CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,not_after timestamptz);
      CREATE TABLE cup117_private.deletions(owner uuid PRIMARY KEY);
      CREATE FUNCTION cup117_private.assert_active(actor uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN
        IF actor IS NULL OR EXISTS(SELECT 1 FROM cup117_private.deletions WHERE owner=actor) THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='42501'; END IF;
      END $$;
      INSERT INTO auth.users(id) VALUES ('${owner}'),('${other}');
      INSERT INTO auth.sessions(id,user_id) VALUES ('${session}','${owner}'),('${otherSession}','${other}');`);
    const migrations = new URL('./supabase/migrations/',import.meta.url);
    for (const file of (await readdir(migrations)).filter(x=>x.endsWith('.sql')).sort()) {
      await db.exec(await readFile(new URL(file,migrations),'utf8'));
    }
    const as = async (user=owner, sid=session) => {
      await db.exec('RESET ROLE');
      await db.query("SELECT set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:user,role:'authenticated',session_id:sid})]);
      await db.exec('SET ROLE authenticated');
    };
    const call = async (action, payload) => (await db.query('SELECT public.bound_run_lease_v1($1,$2::jsonb) AS result',[action,JSON.stringify(payload)])).rows[0].result;
    const acquire = (deviceID=deviceA, requestID=randomUUID(), transfer=false, runID=run) => ({runID,deviceID,requestID,transfer});
    const proof = value => ({runID:value.runID,deviceID:value.deviceID,token:value.token,fence:value.fence});
    await db.exec('SET ROLE anon');
    await assert.rejects(call('acquire',acquire()), /permission denied/);
    await db.exec('RESET ROLE');
    await as();
    await assert.rejects(db.query('SELECT * FROM bound_multiplayer_private.run_leases'), /permission denied/);
    assert.equal((await call('acquire',{...acquire(),owner:other})).error,'invalid_request');
    assert.equal((await call('acquire',{...acquire(),transfer:'true'})).error,'invalid_request');
    assert.equal((await call('acquire',{...acquire(),runID:'bad'})).error,'invalid_request');
    const firstRequest = acquire();
    const clients = await Promise.all(Array.from({length:16}, async () => {
      const client = new Client({...config,database}); await client.connect();
      await client.query("SELECT set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:owner,role:'authenticated',session_id:session})]);
      await client.query('SET ROLE authenticated'); return client;
    }));
    let contenders;
    try {
      // Hold the first winner's uncommitted row while every competing connection
      // tries to acquire. None can observe a gap and create a second authority.
      await db.query('BEGIN');
      const winner = await call('acquire',firstRequest);
      const pending = clients.map(client => client.query('SELECT public.bound_run_lease_v1($1,$2::jsonb) AS result',
        ['acquire',JSON.stringify(acquire(deviceB))]));
      await new Promise(resolve => setTimeout(resolve,30));
      await db.query('COMMIT');
      contenders = [winner,...(await Promise.all(pending)).map(result=>result.rows[0].result)];
    } finally { await db.query('ROLLBACK'); await Promise.all(clients.map(client=>client.end())); }
    assert.equal(contenders.filter(x=>x.ok).length,1);
    assert.ok(contenders.slice(1).every(x=>x.error==='lease_held'));
    const first = contenders[0]; assert.equal(first.ownerID,owner); assert.equal(first.fence,'1');
    assert.ok(first.expiresAt-first.serverTime<=60);
    const retry = await call('acquire',firstRequest);
    assert.equal(retry.token,first.token); assert.equal(retry.expiresAt,first.expiresAt);
    assert.equal((await call('renew',{...proof(first),deviceID:deviceB})).error,'fenced');
    assert.equal((await call('renew',{...proof(first),token:randomUUID()})).error,'fenced');
    assert.equal((await call('renew',proof(first))).ok,true);
    assert.equal(first.anchorVersion,'0'); assert.equal(first.checkpointID,null); assert.equal(first.historyDigest,null);
    const history = (grant,digest,version=grant.anchorVersion) => ({...proof(grant),history:digest,expectedVersion:version});
    const checkpoint = (grant,id,parent,digest,version=grant.anchorVersion) => ({...history(grant,digest,version),checkpointID:id,predecessor:parent});
    const a = 'a'.repeat(64), b = 'b'.repeat(64), c = 'c'.repeat(64), d = 'd'.repeat(64), checkpointA = randomUUID(), checkpointB = randomUUID();
    assert.equal((await call('checkpoint',checkpoint(first,checkpointA,null,a))).error,'anchor_conflict','checkpoint cannot precede its shared-history anchor');
    const anchoredA = await call('history',history(first,a));
    assert.equal(anchoredA.anchorVersion,'1'); assert.equal(anchoredA.historyDigest,a);
    assert.equal((await call('history',history(first,a))).anchorVersion,'1','uncertain history retry is idempotent');
    const committedA = await call('checkpoint',checkpoint(anchoredA,checkpointA,null,a));
    assert.equal(committedA.anchorVersion,'2'); assert.equal(committedA.checkpointID,checkpointA); assert.equal(committedA.checkpointHistory,a);
    assert.equal((await call('checkpoint',checkpoint(anchoredA,checkpointA,null,a))).anchorVersion,'2','checkpoint retry is idempotent');
    assert.equal((await call('checkpoint',checkpoint(committedA,checkpointA,null,b))).error,'anchor_conflict','same checkpoint ID cannot change history');
    const anchoredB = await call('history',history(committedA,b));
    assert.equal(anchoredB.anchorVersion,'3'); assert.equal(anchoredB.historyDigest,b); assert.equal(anchoredB.checkpointHistory,a);
    assert.equal((await call('history',history(committedA,a))).error,'anchor_conflict','stale history cannot overwrite a newer death/progression anchor');
    const racing = await Promise.all(Array.from({length:2}, async () => {
      const client = new Client({...config,database}); await client.connect();
      await client.query("SELECT set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:owner,role:'authenticated',session_id:session})]);
      await client.query('SET ROLE authenticated'); return client;
    }));
    let results;
    try {
      results = await Promise.all(racing.map((client,i)=>client.query('SELECT public.bound_run_lease_v1($1,$2::jsonb) AS result',
        ['history',JSON.stringify(history(anchoredB,i===0?c:d))])));
    } finally { await Promise.all(racing.map(client=>client.end())); }
    const anchorRace = results.map(x=>x.rows[0].result);
    assert.equal(anchorRace.filter(x=>x.ok).length,1); assert.equal(anchorRace.filter(x=>x.error==='anchor_conflict').length,1);
    const newest = await call('renew',proof(first));
    assert.equal(newest.anchorVersion,'4'); assert.ok([c,d].includes(newest.historyDigest));
    const committedB = await call('checkpoint',checkpoint(newest,checkpointB,checkpointA,newest.historyDigest));
    assert.equal(committedB.anchorVersion,'5'); assert.equal(committedB.checkpointID,checkpointB);
    assert.equal((await call('checkpoint',checkpoint(anchoredA,checkpointA,null,a))).error,'anchor_conflict','older checkpoint cannot replace current head');
    assert.equal((await call('checkpoint',checkpoint(committedB,randomUUID(),checkpointA,newest.historyDigest))).error,'anchor_conflict','wrong parent cannot branch the authoritative head');
    assert.equal((await call('checkpoint',checkpoint(committedB,checkpointB,checkpointB,newest.historyDigest))).error,'invalid_request','checkpoint cannot be its own ancestor');
    assert.equal((await call('history',{...history(committedB,b),expectedVersion:'-1'})).error,'invalid_request');
    await as(other,otherSession);
    assert.equal((await call('renew',proof(first))).error,'fenced','other account cannot renew original authority');
    assert.equal((await call('acquire',acquire(deviceB))).ok,true,'partner has an independent lease for the same run');
    await as();
    assert.equal((await call('release',proof(first))).ok,true);
    assert.equal((await call('release',proof(first))).ok,true,'release retry is idempotent');
    assert.equal((await call('renew',proof(first))).error,'lease_expired');
    assert.equal((await call('acquire',acquire(deviceB))).error,'transfer_required');
    const second = await call('acquire',acquire(deviceB,randomUUID(),true));
    assert.equal(second.fence,'2'); assert.notEqual(second.token,first.token);
    assert.equal(second.checkpointID,checkpointB); assert.equal(second.anchorVersion,'5');
    assert.equal(second.checkpointHistory,newest.historyDigest); assert.equal(second.historyDigest,newest.historyDigest);
    assert.equal((await call('history',history(first,a))).error,'fenced','old device cannot change shared history after transfer');
    assert.equal((await call('checkpoint',checkpoint(first,randomUUID(),checkpointB,a))).error,'fenced','old device cannot checkpoint after transfer');
    assert.equal((await call('renew',proof(first))).error,'fenced');
    assert.equal((await call('release',proof(first))).error,'fenced','old writer cannot release new device');
    assert.equal((await call('acquire',acquire(deviceA,randomUUID(),true))).error,'lease_held','transfer confirmation cannot steal a live lease');
    await db.exec('RESET ROLE');
    await db.query("UPDATE bound_multiplayer_private.run_leases SET expires_at=clock_timestamp()-interval '1 second' WHERE owner=$1 AND run_id=$2",[owner,run]);
    await as();
    assert.equal((await call('renew',proof(second))).error,'lease_expired');
    const third = await call('acquire',acquire(deviceA,randomUUID(),true));
    assert.equal(third.fence,'3'); assert.equal((await call('renew',proof(second))).error,'fenced');
    assert.equal((await call('end',proof(second))).error,'fenced','old device cannot end transferred authority');
    const endedRun = randomUUID(), ended = await call('acquire',acquire(deviceA,randomUUID(),false,endedRun));
    assert.equal((await call('end',{...proof(ended),owner:other})).error,'invalid_request');
    await as(other,otherSession);
    assert.equal((await call('end',proof(ended))).error,'fenced','another account cannot end the owner run');
    await as();
    assert.equal((await call('release',proof(ended))).ok,true);
    assert.equal((await call('end',proof(ended))).ok,true,'the same proof may end after expiry/release');
    assert.equal((await call('end',proof(ended))).ok,true,'lost end replies are idempotent');
    assert.equal((await call('release',proof(ended))).ok,true,'ending does not make safe release fail');
    for (const deviceID of [deviceA,deviceB]) {
      assert.equal((await call('acquire',acquire(deviceID,randomUUID(),true,endedRun))).error,'run_ended','a tombstoned UUID cannot restart even with transfer confirmation');
    }
    assert.equal((await call('renew',proof(ended))).error,'run_ended');
    assert.equal((await call('history',history(ended,a))).error,'run_ended');
    assert.equal((await call('checkpoint',checkpoint(ended,randomUUID(),null,a))).error,'run_ended');
    assert.equal((await call('acquire',acquire(deviceA,randomUUID(),false,randomUUID()))).ok,true,'ending one UUID does not prevent a new run');
    await db.exec('RESET ROLE');
    await db.query('DELETE FROM auth.sessions WHERE id=$1',[session]); await as();
    assert.equal((await call('renew',proof(third))).error,'unauthorized');
    await db.exec('RESET ROLE');
    await db.query('INSERT INTO auth.sessions(id,user_id,not_after) VALUES ($1,$2,now()-interval \'1 minute\')',[session,owner]); await as();
    assert.equal((await call('acquire',acquire())).error,'unauthorized');
    await db.exec('RESET ROLE'); await db.query('UPDATE auth.sessions SET not_after=NULL WHERE id=$1',[session]);
    await db.query('INSERT INTO cup117_private.deletions(owner) VALUES ($1)',[owner]); await as();
    assert.equal((await call('renew',proof(third))).error,'unauthorized');
    await db.exec('RESET ROLE'); await db.query('DELETE FROM auth.users WHERE id=$1',[owner]);
    assert.equal((await db.query('SELECT * FROM bound_multiplayer_private.run_leases WHERE owner=$1',[owner])).rows.length,0);
    assert.equal((await db.query("SELECT relrowsecurity FROM pg_class WHERE oid='bound_multiplayer_private.run_leases'::regclass")).rows[0].relrowsecurity,true);
  } finally {
    await db.end();
    await admin.query('DROP DATABASE ' + database);
    await admin.end();
  }
});
