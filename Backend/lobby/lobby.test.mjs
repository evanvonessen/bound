import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile,readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
const {Client}=await import(process.env.PG_MODULE??'pg');
const socket=process.env.BOUND_LOBBY_TEST_SOCKET;
if(!socket?.startsWith('/private/tmp/')) throw Error('Use a disposable local PostgreSQL Unix socket under /private/tmp');

test('four-player lobby authorization, invitation/ready lifecycle, independent runs, fencing and concurrent capacity',async()=>{
 const config={host:socket,port:Number(process.env.BOUND_LOBBY_TEST_PORT??54885),database:'postgres'};
 const admin=new Client(config);await admin.connect();
 const database='bound_lobby_'+randomUUID().replaceAll('-','');await admin.query('CREATE DATABASE '+database);
 const db=new Client({...config,database});await db.connect();
 const users=Array.from({length:6},()=>({id:randomUUID(),sid:randomUUID()}));const rooms=new Map();
 try {
  await db.query(`DO $$ DECLARE r text; BEGIN FOREACH r IN ARRAY ARRAY['anon','authenticated'] LOOP
    IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('CREATE ROLE %I',r);END IF; END LOOP;END $$;
   CREATE SCHEMA auth;CREATE SCHEMA cup117_private;CREATE SCHEMA cup050_private;CREATE SCHEMA bound_social_private;CREATE SCHEMA bound_moderation_private;
   CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
   CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT (auth.jwt()->>'sub')::uuid $$;
   CREATE TABLE auth.users(id uuid PRIMARY KEY,deleted_at timestamptz,is_anonymous boolean DEFAULT false,email_confirmed_at timestamptz DEFAULT now());
   CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,not_after timestamptz);
   CREATE TABLE cup117_private.deletions(owner uuid PRIMARY KEY);
   CREATE FUNCTION cup117_private.assert_active(actor uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN
    IF actor IS NULL OR EXISTS(SELECT 1 FROM cup117_private.deletions WHERE owner=actor) THEN RAISE EXCEPTION 'unavailable' USING ERRCODE='42501';END IF; END $$;
   CREATE TABLE cup050_private.rooms(id uuid PRIMARY KEY,owner_a uuid,owner_b uuid,active boolean DEFAULT true);
   CREATE TABLE bound_social_private.profiles(owner uuid PRIMARY KEY,username text);
   CREATE TABLE bound_moderation_private.blocks(owner uuid,target uuid);
   CREATE FUNCTION bound_moderation_private.denied_pair(a uuid,b uuid) RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
    SELECT EXISTS(SELECT 1 FROM bound_moderation_private.blocks WHERE (owner=a AND target=b) OR (owner=b AND target=a)) $$;`);
  for(let i=0;i<users.length;i++){
   await db.query('INSERT INTO auth.users(id) VALUES($1)',[users[i].id]);
   await db.query('INSERT INTO auth.sessions VALUES($1,$2,NULL)',[users[i].sid,users[i].id]);
   await db.query('INSERT INTO bound_social_private.profiles VALUES($1,$2)',[users[i].id,'Player '+i]);
   for(let j=0;j<i;j++){const id=randomUUID();rooms.set(`${j}:${i}`,id);await db.query('INSERT INTO cup050_private.rooms(id,owner_a,owner_b) VALUES($1,$2,$3)',[id,users[j].id,users[i].id]);}
  }
  const migrations=new URL('./supabase/migrations/',import.meta.url);
  for(const file of (await readdir(migrations)).filter(x=>x.endsWith('.sql')).sort())await db.query(await readFile(new URL(file,migrations),'utf8'));
  const as=async(i=0,session=users[i].sid,client=db)=>{
   await client.query('RESET ROLE');await client.query("SELECT set_config('request.jwt.claims',$1,false)",[JSON.stringify({sub:users[i].id,session_id:session,role:'authenticated'})]);await client.query('SET ROLE authenticated');
  };
  const call=async(action,payload,client=db)=>(await client.query('SELECT public.bound_lobby_v1($1,$2::jsonb) result',[action,JSON.stringify(payload)])).rows[0].result;
  const room=(a,b)=>rooms.get([a,b].sort((a,b)=>a-b).join(':'));
  const meta=(mode='solo',partnerRoomID=null,runID=null)=>({mode,partnerRoomID,runID});
  const create=(roomIDs=[],metadata=meta())=>({requestID:randomUUID(),...metadata,roomIDs});
  const proof=g=>({lobbyID:g.lobby.lobbyID,memberToken:g.memberToken});
  await db.query('SET ROLE anon');await assert.rejects(call('list',{}),/permission denied/);
  await as();await assert.rejects(db.query('SELECT * FROM bound_lobby_private.members'),/permission denied/);
  await assert.rejects(db.query('SELECT bound_lobby_private.snapshot($1)',[randomUUID()]),/permission denied/);
  assert.equal((await call('create',{...create(),ownerID:users[1].id})).error,'invalid_request');
  assert.equal((await call('create',create([randomUUID()]))).error,'invalid_friend');
  for(const extra of [{roomIDs:{}},{roomIDs:['not-a-room']},{roomIDs:[1]},{roomIDs:Array(4).fill(room(0,1))},{mode:'invalid'},{runID:123},{partnerRoomID:true}]) {
   assert.ok(!(await call('create',{...create(),...extra})).ok,'malformed lobby payload must fail');
  }
  assert.equal((await call('create',create([],meta('soulLink',randomUUID())))).error,'invalid_partner');
  const req=create([room(0,1),room(0,2),room(0,3)],meta('soulLink',room(0,1)));
  const a=await call('create',req);assert.equal(a.ok,true);assert.equal(a.lobby.members.length,4);assert.equal(a.lobby.members[0].runID,null);
  assert.deepEqual(a.lobby.members.map(m=>m.uid),[1,2,3,4]);assert.equal(a.lobby.members[0].partnerOwnerID,users[1].id);
  const retry=await call('create',req);assert.equal(retry.lobby.lobbyID,a.lobby.lobbyID);assert.equal(retry.memberToken,a.memberToken);
  const lid=a.lobby.lobbyID;
  await as(5);assert.equal((await call('get',{lobbyID:lid})).error,'forbidden');assert.deepEqual((await call('list',{})).lobbies,[]);
  await as(1);assert.equal((await call('list',{})).lobbies.length,1);
  assert.equal((await call('room',{lobbyID:lid,memberToken:randomUUID()})).error,'fenced');
  const b=await call('accept',{lobbyID:lid,...meta('soulLink',room(0,1))});assert.equal(b.ok,true);
  const sessionB=b.lobby.members.find(m=>m.ownerID===users[1].id).sessionID;
  assert.equal((await call('accept',{lobbyID:lid,...meta('soulLink',room(0,1))})).memberToken,b.memberToken,'uncertain accept retry retains membership');
  assert.equal((await call('start',proof(b))).error,'not_creator');
  assert.equal((await call('ready',{...proof(b),ready:true})).ok,true);
  await as();assert.equal((await call('start',proof(a))).error,'not_ready');
  assert.equal((await call('ready',{...proof(a),ready:true})).ok,true);
  assert.equal((await call('start',proof(a))).lobby.state,'started','pending invitees do not block ready accepted members');
  const pairedRun=randomUUID();assert.equal((await call('configure',{...proof(a),...meta('soulLink',room(0,1),pairedRun)})).ok,true);
  assert.equal((await call('configure',{...proof(a),...meta('solo',null,randomUUID())})).error,'run_mismatch');
  await as(1);assert.equal((await call('configure',{...proof(b),...meta('soulLink',room(0,1),pairedRun)})).ok,true);
  await as(2);const c=await call('accept',{lobbyID:lid,...meta('solo',null,randomUUID())});assert.equal(c.ok,true);
  await as(3);assert.equal((await call('decline',{lobbyID:lid})).ok,true);assert.equal((await call('accept',{lobbyID:lid,...meta()})).error,'invitation_declined');
  await as();assert.equal((await call('invite',{...proof(a),roomID:room(0,3)})).error,'invitation_declined');
  const roster=await call('room',proof(a));assert.equal(roster.ok,true);assert.equal(roster.room.members.length,3);assert.equal(roster.room.members[0].uid,1);
  assert.ok(roster.room.members.every(m=>m.sessionID && m.generation));assert.ok(!JSON.stringify(roster).includes(a.memberToken));
  await call('leave',proof(a));await as(1);const afterCreator=await call('get',{lobbyID:lid});assert.equal(afterCreator.lobby.state,'started');assert.equal(afterCreator.lobby.creatorID,users[1].id);
  assert.equal((await call('heartbeat',proof(b))).ok,true,'creator departure does not stop other players');
  assert.equal((await call('leave',proof(b))).ok,true);assert.equal((await call('heartbeat',proof(b))).error,'membership_expired');
  assert.equal((await call('rejoin',{lobbyID:lid,...meta()})).error,'run_mismatch','rejoin cannot change run ownership');
  const returned=await call('rejoin',{lobbyID:lid,...meta('soulLink',room(0,1),pairedRun)});assert.equal(returned.ok,true);assert.notEqual(returned.memberToken,b.memberToken);
  const newB=returned.lobby.members.find(m=>m.ownerID===users[1].id);assert.equal(newB.uid,2);assert.notEqual(newB.sessionID,sessionB);assert.equal(newB.runID,pairedRun);
  assert.equal((await call('leave',proof(b))).error,'fenced','old leave cannot terminate a rejoined membership');
  await db.query('RESET ROLE');await db.query("UPDATE bound_lobby_private.members SET expires_at=now()-interval '1 second' WHERE lobby=$1 AND owner=$2",[lid,users[1].id]);await as(1);
  assert.equal((await call('room',proof(returned))).error,'membership_expired');
  const expired=await call('rejoin',{lobbyID:lid,...meta('soulLink',room(0,1),pairedRun)});assert.notEqual(expired.memberToken,returned.memberToken);assert.equal((await call('heartbeat',proof(returned))).error,'fenced');
  // Real independent DB connections compete for the last slot; the lobby row
  // lock must prevent overbooking while invites from different owners race.
  await as();const race=await call('create',create([room(0,1),room(0,2)]));
  const clients=await Promise.all([0,1].map(async()=>{const x=new Client({...config,database});await x.connect();await as(0,users[0].sid,x);return x;}));
  try{
   await db.query('BEGIN');await db.query('RESET ROLE');await db.query('SELECT id FROM bound_lobby_private.lobbies WHERE id=$1 FOR UPDATE',[race.lobby.lobbyID]);
   const pending=clients.map((x,i)=>call('invite',{...proof(race),roomID:room(0,i+3)},x));
   await new Promise(r=>setTimeout(r,30));await db.query('COMMIT');const outcomes=await Promise.all(pending);
   assert.equal(outcomes.filter(x=>x.ok).length,1);assert.equal(outcomes.filter(x=>x.error==='lobby_full').length,1);
  }finally{await db.query('ROLLBACK');await Promise.all(clients.map(x=>x.end()));}
  await as();assert.equal((await call('get',{lobbyID:race.lobby.lobbyID})).lobby.members.length,4);
  await db.query('RESET ROLE');await db.query('INSERT INTO bound_moderation_private.blocks VALUES($1,$2)',[users[1].id,users[2].id]);await as(1);
  assert.equal((await call('room',proof(expired))).error,'forbidden','block gates existing membership and token renewal');
  await as();const before=(await call('list',{})).lobbies.length;assert.equal((await call('create',create([room(0,1),room(0,2)]))).error,'invalid_friend');
  assert.equal((await call('list',{})).lobbies.length,before,'rejected group invite creates no partial lobby');
  await db.query('RESET ROLE');await db.query('DELETE FROM bound_moderation_private.blocks');await db.query('UPDATE cup050_private.rooms SET active=false WHERE id=$1',[room(0,1)]);await as(1);
  assert.equal((await call('get',{lobbyID:lid})).error,'forbidden','removed friendship revokes old membership');
  await as(2);await db.query('RESET ROLE');await db.query('DELETE FROM auth.sessions WHERE id=$1',[users[2].sid]);await as(2);
  assert.equal((await call('heartbeat',proof(c))).error,'unauthorized','revoked Auth session cannot renew membership');
  await as(5);await db.query('RESET ROLE');await db.query('INSERT INTO cup117_private.deletions VALUES($1)',[users[5].id]);await as(5);
  assert.equal((await call('list',{})).error,'unauthorized');
  await db.query('RESET ROLE');await db.query('INSERT INTO cup117_private.deletions VALUES($1)',[users[0].id]);await as(1);
  assert.equal((await call('get',{lobbyID:race.lobby.lobbyID})).error,'forbidden','pending account deletion fences a friendship before final Auth deletion');
  await db.query('RESET ROLE');const audit=await db.query("SELECT count(*)::integer n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='bound_lobby_private' AND (p.proconfig IS NULL OR NOT ('search_path=\"\"'=ANY(p.proconfig)))");assert.equal(audit.rows[0].n,0,'private privileged functions pin search path');
 }finally{await db.end();await admin.query('DROP DATABASE '+database);await admin.end();}
});
