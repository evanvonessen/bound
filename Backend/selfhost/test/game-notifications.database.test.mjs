import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomBytes, randomUUID, createHmac } from 'node:crypto';
import { adaptContract } from '../migrate.mjs';

const databaseURL = process.env.BOUND_NOTIFICATION_TEST_DATABASE_URL;
test('notification preferences, run authorization, APNs filtering and idempotency in isolated PostgreSQL', { skip: !databaseURL }, async () => {
  const { default: pg } = await import('pg');
  const name = 'bound_notification_test_' + randomBytes(6).toString('hex');
  const admin = new pg.Client({ connectionString: databaseURL });
  const url = new URL(databaseURL); url.pathname = '/' + name;
  const client = new pg.Client({ connectionString: url.toString() });
  const { fixture, owner: a, peer: b, roomID: room, secret } = await import('../../nakama/test/fixture.mjs');
  const f = fixture(); f.nk.uuidv4 = randomUUID;
  const ticket = Buffer.from(JSON.stringify({version:1,protocol:'bound-saves-v1',ownerID:a,partnerID:b,roomID:room,issuedAt:1000,expiresAt:1090})).toString('base64url');
  const settings = Buffer.alloc(32); settings[0]=5; settings[12]=187; settings.fill(255,13,20);
  const createdRun = JSON.parse(f.independent.rpc(f.ctx,f.logger,f.nk,JSON.stringify({action:'create',
    saveTicket:ticket+'.'+createHmac('sha256',secret).update(ticket).digest('hex'),request_id:randomUUID(),partnerID:b,
    gameID:'multi_red',romSHA256:'a'.repeat(64),settings:settings.toString('base64'),profile:{name:'RED',gender:0}})));
  const run=createdRun.save_id, outsider=randomUUID();
  const storedRun=f.stored.get('bound_independent_v2:'+run).value;
  const ia = randomUUID(), ib = randomUUID(), tokenA = 'aa'.repeat(32), tokenB = 'bb'.repeat(32);
  let created = false;
  try {
    await admin.connect();
    // Roles are cluster-wide; this test creates missing no-login API roles only.
    for (const role of ['anon', 'authenticated', 'service_role']) {
      if (!(await admin.query('SELECT 1 FROM pg_roles WHERE rolname=$1', [role])).rowCount) await admin.query('CREATE ROLE ' + role + ' NOLOGIN');
    }
    await admin.query('CREATE DATABASE ' + name); created = true;
    await client.connect();
    await client.query(`CREATE TABLE public.users(id uuid PRIMARY KEY,is_anonymous boolean DEFAULT false,email_confirmed_at timestamptz DEFAULT now(),deleted_at timestamptz,raw_user_meta_data jsonb DEFAULT '{}');
      CREATE SCHEMA auth; CREATE VIEW auth.users AS SELECT * FROM public.users;
      CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql AS 'SELECT current_setting(''request.jwt.claims'',true)::jsonb';
      CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS 'SELECT (auth.jwt()->>''sub'')::uuid';
      CREATE SCHEMA cup117_private;
      CREATE FUNCTION cup117_private.assert_active(actor uuid) RETURNS void LANGUAGE plpgsql AS $$BEGIN
        IF NOT EXISTS(SELECT 1 FROM public.users WHERE id=actor AND deleted_at IS NULL) THEN RAISE EXCEPTION 'inactive'; END IF;
      END$$;
      CREATE SCHEMA cup050_private;
      CREATE TABLE cup050_private.rooms(id uuid PRIMARY KEY,owner_a uuid,owner_b uuid,active boolean DEFAULT true,name_a text,name_b text);
      CREATE SCHEMA bound_moderation_private;
      CREATE FUNCTION bound_moderation_private.denied_pair(uuid,uuid) RETURNS boolean LANGUAGE sql AS 'SELECT false';
      CREATE TABLE public.storage(collection text,user_id uuid,key text,value jsonb);`);
    await client.query(adaptContract(await readFile(new URL('../../social/supabase/migrations/20261015210839_bound_friend_social_v1.sql', import.meta.url), 'utf8')));
    await client.query(adaptContract(await readFile(new URL('../../social/supabase/migrations/20261015212112_bound_device_registration_revision_fence.sql', import.meta.url), 'utf8')));
    // The real v2 function delegates device actions to this unchanged v1 path;
    // username-only functions are unrelated to the notification contract.
    await client.query("CREATE FUNCTION public.bound_social_v2(action text,payload jsonb) RETURNS jsonb LANGUAGE sql SECURITY INVOKER AS 'SELECT public.bound_social_v1(action,payload)'");
    await client.query(await readFile(new URL('../game-notifications.sql', import.meta.url), 'utf8'));
    for (const id of [a,b,outsider]) await client.query('INSERT INTO public.users(id) VALUES($1)', [id]);
    await client.query('INSERT INTO cup050_private.rooms(id,owner_a,owner_b) VALUES($1,$2,$3)', [room,a,b]);
    for (const [owner,installation,token] of [[a,ia,tokenA],[b,ib,tokenB]]) {
      await client.query("INSERT INTO bound_social_private.profiles(owner,username) VALUES($1,'River')", [owner]);
      await client.query("INSERT INTO bound_social_private.devices(installation_id,owner,token,environment) VALUES($1,$2,$3,'sandbox')", [installation,owner,token]);
    }
    await client.query("INSERT INTO public.storage VALUES('bound_independent_v2','00000000-0000-0000-0000-000000000000',$1,$2)",
      [run,JSON.stringify(storedRun)]);
    const claims = async (owner,role='authenticated') => client.query("SELECT set_config('request.jwt.claims',$1,false)", [JSON.stringify({sub:owner,role})]);
    const preferences = async (owner,installation,send=true,receive=true,revision='1') => {
      await claims(owner);
      return (await client.query('SELECT public.bound_notification_preferences($1) AS result',
        [{installationID:installation,sendJoin:String(send),receiveInvites:String(receive),revision}])).rows[0].result;
    };
    const clear = () => client.query('DELETE FROM bound_social_private.jiggle_jobs');
    const dispatch = async (kind='shared-join',owner=a,installation=ia,request=randomUUID(),targetRun=run) => {
      await claims(owner,'service_role');
      return (await client.query('SELECT public.bound_game_notification_dispatch($1,$2,$3,$4,$5,$6) AS result',
        [owner,room,request,kind,kind==='bound-jiggle'?null:targetRun,kind==='bound-jiggle'?null:installation])).rows[0].result;
    };
    assert.deepEqual(await preferences(a,ib),{ok:false},'cannot change friend installation');
    assert.deepEqual(await preferences(a,ia),{ok:true});
    assert.deepEqual(await preferences(b,ib,true,false),{ok:true});
    await preferences(b,ib,true,true,'1');
    assert.equal((await client.query('SELECT receive_invites FROM bound_social_private.notification_preferences WHERE owner=$1',[b])).rows[0].receive_invites,false,'stale preference revision ignored');
    const request = randomUUID();
    const join = await dispatch('shared-join',a,ia,request);
    assert.equal(join.ok,true); assert.equal(join.devices[0].token,tokenB,'join independent of receive invite preference');
    assert.equal((await dispatch('shared-join',a,ia,request)).duplicate,true);
    assert.equal((await dispatch('shared-start',a,ia,request)).error,'request_conflict');
    await clear();
    assert.equal((await dispatch('shared-start')).status,'suppressed');
    await clear(); assert.equal((await dispatch('bound-jiggle')).status,'suppressed','manual invitation respects child preference');
    await preferences(b,ib,true,true,'2'); await clear();
    assert.equal((await dispatch('shared-start')).devices[0].token,tokenB);
    await clear(); assert.equal((await dispatch('shared-invite')).devices[0].token,tokenB);
    await clear();
    await client.query('DELETE FROM bound_social_private.notification_preferences WHERE owner=$1',[b]);
    assert.equal((await dispatch('bound-jiggle')).devices[0].token,tokenB,'legacy registration without child prefs still receives invitations');
    await claims(b);
    const modernDevice={installationID:ib,revision:'3',token:tokenB,environment:'sandbox',sendJoin:'true',receiveInvites:'false'};
    assert.equal((await client.query('SELECT public.bound_notification_device($1) AS result',[modernDevice])).rows[0].result.ok,true);
    await clear(); assert.equal((await dispatch('shared-start')).status,'suppressed','atomic modern device upload enforces receive preference');
    await claims(b);
    assert.equal((await client.query('SELECT public.bound_notification_device($1) AS result',
      [{...modernDevice,revision:'2',receiveInvites:'true'}])).rows[0].result.ignored,true);
    await clear(); assert.equal((await dispatch('bound-jiggle')).status,'suppressed','late registration cannot overwrite current child choice');
    await clear(); assert.equal((await dispatch('shared-join',outsider)).error,'friend_unavailable');
    assert.equal((await dispatch('shared-start',b,ib)).error,'friend_unavailable','only creator can announce server start');
    assert.equal((await dispatch('shared-join',a,ia,randomUUID(),randomUUID())).error,'friend_unavailable');
    await preferences(a,ia,false,true,'2');
    assert.equal((await dispatch()).status,'suppressed','outgoing child toggle enforced on server');
    await preferences(a,ia,true,true,'3');
    await client.query('DELETE FROM bound_social_private.devices WHERE owner=$1',[a]);
    assert.equal((await dispatch()).status,'suppressed','master off unregister wins over child prefs');
    await claims(a);
    assert.equal((await client.query('SELECT public.bound_game_notification_dispatch($1,$2,$3,$4,$5,$6) AS result',
      [a,room,randomUUID(),'shared-join',run,ia])).rows[0].result.error,'invalid_request','dispatch is service only');
  } finally {
    await client.end().catch(()=>{});
    if (created) await admin.query('DROP DATABASE ' + name + ' WITH (FORCE)');
    await admin.end();
  }
});
