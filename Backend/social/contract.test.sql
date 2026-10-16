-- Contract tests run only against Backend/social/local-fixture.sql in disposable PostgreSQL.
\set ON_ERROR_STOP on
CREATE TEMP TABLE legacy_baseline AS SELECT md5(pg_get_functiondef('public.cup050_friends(text,jsonb)'::regprocedure)) AS legacy_hash;
\ir supabase/migrations/20261015210839_bound_friend_social_v1.sql
\ir supabase/migrations/20261015212112_bound_device_registration_revision_fence.sql
\ir supabase/migrations/20261015212554_bound_device_registration_owner_index.sql
DO $$
DECLARE a constant uuid:='11111111-1111-4111-8111-111111111111';
        b constant uuid:='22222222-2222-4222-8222-222222222222';
        c constant uuid:='33333333-3333-4333-8333-333333333333';
        room_id uuid; response jsonb; i integer; token_a text:=repeat('a',64); token_b text:=repeat('b',64);
        install_a constant uuid:='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
        install_b constant uuid:='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
        job_id uuid; dispatch jsonb; request_id constant uuid:='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
BEGIN
  IF md5(pg_get_functiondef('public.cup050_friends(text,jsonb)'::regprocedure))<>(SELECT legacy_hash FROM legacy_baseline) THEN RAISE EXCEPTION 'legacy RPC definition changed'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  response:=public.bound_social_v1('profile','{}');
  IF response->>'username' NOT LIKE 'Player_%' THEN RAISE EXCEPTION 'fallback username not persisted: %',response; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',c,'role','authenticated')::text,true);
  response:=public.bound_social_v1('profile','{}');
  IF response->>'username'<>'Third Seed' THEN RAISE EXCEPTION 'metadata seed was not used: %',response; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub','77777777-7777-4777-8777-777777777777','role','authenticated')::text,true);
  response:=public.bound_social_v1('profile','{}');
  IF response->>'username'<>'Room Seed' THEN RAISE EXCEPTION 'existing own room label was not used: %',response; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  response:=public.bound_social_v1('username','{"username":"Alice Persisted"}');
  IF response->>'username'<>'Alice Persisted' THEN RAISE EXCEPTION 'username update failed: %',response; END IF;
  response:=public.bound_social_v1('create','{}');
  IF response->>'ok'<>'true' OR response->>'username'<>'Alice Persisted' THEN RAISE EXCEPTION 'legacy create wrapper omitted account username: %',response; END IF;
  IF (SELECT display_name FROM cup050_private.invites WHERE creator=a AND NOT consumed) IS DISTINCT FROM 'Alice Persisted' THEN RAISE EXCEPTION 'invite does not use profile'; END IF;
  response:=public.bound_social_v1('username','{"username":"Alice Invite Updated"}');
  IF (SELECT display_name FROM cup050_private.invites WHERE creator=a AND NOT consumed) IS DISTINCT FROM 'Alice Invite Updated' THEN RAISE EXCEPTION 'username change did not update outstanding invite'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  response:=public.bound_social_v1('accept','{"code":"FIXTURECODE123456"}');
  IF response->>'ok'<>'true' OR response->>'username'<>'Player_22222222' THEN RAISE EXCEPTION 'legacy accept wrapper omitted account username: %',response; END IF;
  room_id:=(response->'room'->>'roomID')::uuid;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  response:=public.bound_social_v1('list','{}');
  IF response->'rooms'->0->>'displayName'<>'Player_22222222' OR response->>'username'<>'Alice Invite Updated' THEN RAISE EXCEPTION 'list omitted peer/profile username: %',response; END IF;
  response:=public.bound_social_v1('username','{"username":"Alice Updated"}');
  IF response->>'username'<>'Alice Updated' OR (SELECT name_a FROM cup050_private.rooms WHERE id=room_id)<>'Alice Updated' THEN RAISE EXCEPTION 'rename did not update legacy room labels'; END IF;
  response:=public.cup050_friends('room',jsonb_build_object('roomID',room_id));
  IF response->>'ok'<>'true' THEN RAISE EXCEPTION 'legacy sharing passthrough failed'; END IF;
  response:=public.bound_social_v1('block',jsonb_build_object('roomID',room_id));
  IF response->>'action'<>'block' THEN RAISE EXCEPTION 'moderation passthrough failed'; END IF;
  DELETE FROM bound_moderation_private.blocks WHERE owner=a AND target=b;
  -- APNs token storage is private; registration never returns raw tokens.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  response:=public.bound_social_v1('device',jsonb_build_object('installationID',install_b,'token',token_b,'environment','sandbox','revision','1'));
  IF response<>'{"ok":true}'::jsonb OR response::text LIKE '%'||token_b||'%' THEN RAISE EXCEPTION 'device registration leaked token or failed: %',response; END IF;
  -- Same token may move to the new signed-in owner; old owner no longer receives it.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',c,'role','authenticated')::text,true);
  response:=public.bound_social_v1('device',jsonb_build_object('installationID',install_b,'token',token_b,'environment','production','revision','2'));
  IF response->>'ok'<>'true' OR (SELECT owner FROM bound_social_private.devices WHERE token=token_b)<>c THEN RAISE EXCEPTION 'device account rebind failed'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  response:=public.bound_social_v1('unregister',jsonb_build_object('installationID',install_b,'revision','3'));
  IF response->>'ignored'<>'true' OR (SELECT owner FROM bound_social_private.devices WHERE token=token_b)<>c THEN RAISE EXCEPTION 'old account unregister revoked the current owner'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',c,'role','authenticated')::text,true);
  response:=public.bound_social_v1('device',jsonb_build_object('installationID',install_b,'token',token_b,'environment','production','revision','1'));
  IF response->>'ignored'<>'true' OR (SELECT owner FROM bound_social_private.devices WHERE token=token_b)<>c THEN RAISE EXCEPTION 'stale registration revision was not ignored'; END IF;
  response:=public.bound_social_v1('unregister',jsonb_build_object('installationID',install_b,'revision','3'));
  IF response->>'ok'<>'true' OR EXISTS(SELECT 1 FROM bound_social_private.devices WHERE token=token_b) THEN RAISE EXCEPTION 'device unregister failed'; END IF;
  -- A newer unregister tombstone wins even if an older registration arrives later.
  response:=public.bound_social_v1('unregister',jsonb_build_object('installationID','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','revision','2'));
  IF response->>'ok'<>'true' OR NOT EXISTS(SELECT 1 FROM bound_social_private.registration_fences WHERE installation_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' AND owner=c AND revision=2) THEN RAISE EXCEPTION 'unregister did not persist a revision tombstone'; END IF;
  response:=public.bound_social_v1('device',jsonb_build_object('installationID','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','token',repeat('e',64),'environment','sandbox','revision','1'));
  IF response->>'ignored'<>'true' OR EXISTS(SELECT 1 FROM bound_social_private.devices WHERE installation_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee') THEN RAISE EXCEPTION 'older registration replaced a newer unregister'; END IF;
  response:=public.bound_social_v1('device',jsonb_build_object('installationID','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','token',repeat('e',64),'environment','sandbox','revision','3'));
  IF response->>'ok'<>'true' OR (SELECT revision FROM bound_social_private.registration_fences WHERE installation_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee')<>3 THEN RAISE EXCEPTION 'newer registration did not supersede tombstone'; END IF;
  response:=public.bound_social_v1('unregister',jsonb_build_object('installationID','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','revision','2'));
  IF response->>'ignored'<>'true' OR NOT EXISTS(SELECT 1 FROM bound_social_private.devices WHERE installation_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee') THEN RAISE EXCEPTION 'older unregister removed a newer registration'; END IF;
  response:=public.bound_social_v1('unregister',jsonb_build_object('installationID','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','revision','4'));
  IF response->>'ok'<>'true' OR EXISTS(SELECT 1 FROM bound_social_private.devices WHERE installation_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee') THEN RAISE EXCEPTION 'newer unregister failed'; END IF;
  -- Fill five registrations, then verify the sixth is rejected.
  PERFORM public.bound_social_v1('device',jsonb_build_object('installationID','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','token',repeat('1',64),'environment','sandbox','revision','1'));
  PERFORM public.bound_social_v1('device',jsonb_build_object('installationID','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2','token',repeat('2',64),'environment','sandbox','revision','1'));
  PERFORM public.bound_social_v1('device',jsonb_build_object('installationID','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3','token',repeat('3',64),'environment','sandbox','revision','1'));
  PERFORM public.bound_social_v1('device',jsonb_build_object('installationID','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4','token',repeat('4',64),'environment','sandbox','revision','1'));
  PERFORM public.bound_social_v1('device',jsonb_build_object('installationID','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5','token',repeat('5',64),'environment','sandbox','revision','1'));
  response:=public.bound_social_v1('device',jsonb_build_object('installationID','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa6','token',repeat('6',64),'environment','sandbox','revision','1'));
  IF response->>'error'<>'device_limit' THEN RAISE EXCEPTION 'device cap not enforced: %',response; END IF;
  response:=public.bound_social_v1('device',jsonb_build_object('installationID',install_a,'token',repeat('a',64),'environment',NULL,'revision','1'));
  IF response->>'ok'<>'false' THEN RAISE EXCEPTION 'null device environment was not denied cleanly: %',response; END IF;
  response:=public.bound_social_v1('device',jsonb_build_object('installationID',install_a,'token',repeat('a',64),'environment','sandbox','revision','9223372036854775808'));
  IF response->>'ok'<>'false' THEN RAISE EXCEPTION 'out-of-range revision was not denied cleanly: %',response; END IF;
  response:=public.bound_social_v1('unregister',jsonb_build_object('installationID',install_a,'revision','1'));
  IF response->>'ok'<>'true' OR NOT EXISTS(SELECT 1 FROM bound_social_private.registration_fences WHERE installation_id=install_a AND owner=c AND revision=1) THEN RAISE EXCEPTION 'unregister did not create an installation tombstone'; END IF;
  FOR i IN 1..18 LOOP
    PERFORM public.bound_social_v1('unregister',jsonb_build_object('installationID',('dddddddd-dddd-4ddd-8ddd-'||lpad(to_hex(i),12,'0'))::uuid,'revision','1'));
  END LOOP;
  IF (SELECT count(*) FROM bound_social_private.registration_fences WHERE owner=c)<>20 THEN RAISE EXCEPTION 'expected exactly 20 retained registration fences'; END IF;
  response:=public.bound_social_v1('unregister',jsonb_build_object('installationID','ffffffff-ffff-4fff-8fff-ffffffffffff','revision','1'));
  IF response->>'error'<>'installation_limit' OR EXISTS(SELECT 1 FROM bound_social_private.registration_fences WHERE installation_id='ffffffff-ffff-4fff-8fff-ffffffffffff') THEN RAISE EXCEPTION 'registration fence cap was not enforced: %',response; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  PERFORM public.bound_social_v1('device',jsonb_build_object('installationID',install_b,'token',token_b,'environment','sandbox','revision','4'));
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',c,'role','authenticated')::text,true);
  response:=public.bound_social_v1('device',jsonb_build_object('installationID',install_b,'token',token_b,'environment','sandbox','revision','5'));
  IF response->>'error'<>'device_limit' OR (SELECT owner FROM bound_social_private.devices WHERE token=token_b)<>b THEN RAISE EXCEPTION 'account switch bypassed device cap: %',response; END IF;
  -- User eligibility is checked against current auth.users, not only JWT claims.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub','44444444-4444-4444-8444-444444444444','role','authenticated')::text,true);
  IF public.bound_social_v1('profile','{}')->>'ok'<>'false' THEN RAISE EXCEPTION 'anonymous user was accepted'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub','66666666-6666-4666-8666-666666666666','role','authenticated')::text,true);
  IF public.bound_social_v1('profile','{}')->>'ok'<>'false' THEN RAISE EXCEPTION 'unconfirmed user was accepted'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub','55555555-5555-4555-8555-555555555555','role','authenticated')::text,true);
  BEGIN
    response:=public.bound_social_v1('profile','{}');
    RAISE EXCEPTION 'deleted user was accepted';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- Jiggle authorization is service-role only; no peer token data in ordinary client responses.
  IF NOT has_function_privilege('authenticated','public.bound_social_v1(text,jsonb)','EXECUTE') OR has_function_privilege('anon','public.bound_social_v1(text,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'client wrapper grants are incorrect'; END IF;
  IF has_schema_privilege('authenticated','bound_social_private','USAGE') OR has_table_privilege('authenticated','bound_social_private.profiles','SELECT') THEN RAISE EXCEPTION 'client can enter/read private social schema'; END IF;
  IF has_function_privilege('authenticated','public.bound_jiggle_dispatch(uuid,uuid,uuid)','EXECUTE') THEN RAISE EXCEPTION 'authenticated can execute service dispatch'; END IF;
  IF has_function_privilege('anon','public.bound_jiggle_finish(uuid,boolean,text[])','EXECUTE') THEN RAISE EXCEPTION 'anon can execute service finish'; END IF;
  IF has_table_privilege('authenticated','bound_social_private.devices','SELECT') OR has_table_privilege('authenticated','bound_social_private.registration_fences','SELECT') THEN RAISE EXCEPTION 'client can read private device registration data'; END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='bound_social_private.devices'::regclass) OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='bound_social_private.registration_fences'::regclass) THEN RAISE EXCEPTION 'private device RLS is disabled'; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='bound_social_private' AND indexname='registration_fences_owner_idx') THEN RAISE EXCEPTION 'registration fence owner index is missing'; END IF;
  -- Dispatch validates the live room and returns the recipient's token only to service role.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  PERFORM public.bound_social_v1('unregister',jsonb_build_object('installationID',install_b,'revision','5'));
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','service_role')::text,true);
  dispatch:=public.bound_jiggle_dispatch(a,room_id,request_id);
  IF dispatch->>'error'<>'friend_unavailable' THEN RAISE EXCEPTION 'missing-device dispatch should fail closed: %',dispatch; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  PERFORM public.bound_social_v1('device',jsonb_build_object('installationID',install_b,'token',token_b,'environment','sandbox','revision','6'));
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','service_role')::text,true);
  INSERT INTO bound_moderation_private.blocks(owner,target,label) VALUES(a,b,'fixture block');
  dispatch:=public.bound_jiggle_dispatch(a,room_id,request_id);
  IF dispatch->>'ok'<>'false' THEN RAISE EXCEPTION 'blocked pair was allowed to dispatch: %',dispatch; END IF;
  DELETE FROM bound_moderation_private.blocks WHERE owner=a AND target=b;
  dispatch:=public.bound_jiggle_dispatch(a,room_id,request_id);
  IF dispatch->>'ok'<>'true' OR dispatch->'devices'->0->>'token'<>token_b THEN RAISE EXCEPTION 'service dispatch did not return recipient device: %',dispatch; END IF;
  job_id:=(dispatch->>'jobID')::uuid;
  response:=public.bound_jiggle_finish(job_id,true,ARRAY[token_b]);
  IF response->>'status'<>'sent' OR EXISTS(SELECT 1 FROM bound_social_private.devices WHERE token=token_b) THEN RAISE EXCEPTION 'finish did not transition/purge target token'; END IF;
  dispatch:=public.bound_jiggle_dispatch(a,room_id,request_id);
  IF dispatch->>'duplicate'<>'true' OR dispatch->>'status'<>'sent' THEN RAISE EXCEPTION 'request idempotency failed: %',dispatch; END IF;
  dispatch:=public.bound_jiggle_dispatch(a,room_id,'dddddddd-dddd-4ddd-8ddd-dddddddddddd');
  IF dispatch->>'error'<>'rate_limited' THEN RAISE EXCEPTION 'pair cooldown was not enforced: %',dispatch; END IF;
  -- Account deletion cascades private social data.
  INSERT INTO bound_social_private.devices(installation_id,owner,token,environment) VALUES(install_a,a,token_a,'sandbox');
  DELETE FROM auth.users WHERE id=a;
  IF EXISTS(SELECT 1 FROM bound_social_private.profiles WHERE owner=a) OR EXISTS(SELECT 1 FROM bound_social_private.devices WHERE owner=a) THEN RAISE EXCEPTION 'account deletion did not cascade social data'; END IF;
END $$;
SELECT 'Bound social SQL contract passed' AS result;
