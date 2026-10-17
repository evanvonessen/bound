-- Operator-only smoke check of captured/live RPC contracts. All generated rows roll back.
-- Every identity, username, token, and installation is unique per invocation.
\set ON_ERROR_STOP on
BEGIN;
CREATE TEMP TABLE smoke_legacy_baseline AS
  SELECT md5(pg_get_functiondef('public.cup050_friends(text,jsonb)'::regprocedure)) AS function_hash;
DO $$
DECLARE
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); c uuid:=gen_random_uuid(); direct_peer uuid:=gen_random_uuid();
  opt_out uuid:=gen_random_uuid(); installation uuid:=gen_random_uuid();
  suffix text:=left(replace(gen_random_uuid()::text,'-',''),10);
  token text:=encode(extensions.gen_random_bytes(32),'hex');
  a_name text:='Smoke River '||suffix; b_name text:='Smoke Navi '||suffix;
  c_name text:='Smoke Friend '||suffix;
  direct_name text:='Smoke Direct '||suffix;
  code text; pairing uuid; added_room uuid; answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims','{}',true);
  PERFORM set_config('request.jwt.claim.sub','',true);
  INSERT INTO auth.users(id,email,email_confirmed_at,is_anonymous,raw_user_meta_data)
    VALUES(a,'bound-social-'||a||'@example.invalid',now(),false,
      jsonb_build_object('cupcake_username_v1',a_name,'bound_username_v1',a_name));
  INSERT INTO auth.users(id,email,email_confirmed_at,is_anonymous,raw_user_meta_data)
    VALUES(b,'bound-social-'||b||'@example.invalid',now(),false,
      jsonb_build_object('cupcake_username_v1',b_name,'bound_username_v1',b_name));
  INSERT INTO auth.users(id,email,email_confirmed_at,is_anonymous,raw_user_meta_data)
    VALUES(c,'bound-social-'||c||'@example.invalid',now(),false,
      jsonb_build_object('cupcake_username_v1',c_name,'bound_username_v1',c_name));
  INSERT INTO auth.users(id,email,email_confirmed_at,is_anonymous,raw_user_meta_data)
    VALUES(direct_peer,'bound-social-'||direct_peer||'@example.invalid',now(),false,
      jsonb_build_object('cupcake_username_v1',direct_name,'bound_username_v1',direct_name));
  INSERT INTO auth.users(id,email,email_confirmed_at,is_anonymous,raw_user_meta_data)
    VALUES(opt_out,'bound-social-'||opt_out||'@example.invalid',now(),false,'{}'::jsonb);
  IF EXISTS(SELECT 1 FROM bound_social_private.profiles WHERE owner=opt_out)
    THEN RAISE EXCEPTION 'opt-out signup unexpectedly created a profile'; END IF;

  -- All social calls explicitly set both claim formats to avoid a stale actor.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',a::text,true);
  answer:=public.bound_social_v1('profile','{}');
  IF answer->>'username'<>a_name THEN RAISE EXCEPTION 'profile seed failed: %',answer; END IF;
  answer:=public.bound_username_available(lower(a_name));
  IF answer->>'ok'<>'true' OR answer->>'available'<>'false'
      OR (answer-'ok'-'available')<>'{}'::jsonb
    THEN RAISE EXCEPTION 'casefold availability failed: %',answer; END IF;

  -- Username-based add creates a room and a repeat tap returns that same room.
  answer:=public.bound_social_v2('add',jsonb_build_object('username',upper(c_name)));
  IF answer->>'ok'<>'true' OR answer->>'username'<>a_name
      OR answer->'room'->>'displayName'<>c_name
    THEN RAISE EXCEPTION 'username add failed: %',answer; END IF;
  added_room:=(answer->'room'->>'roomID')::uuid;
  answer:=public.bound_social_v2('add',jsonb_build_object('username',lower(c_name)));
  IF answer->>'ok'<>'true' OR (answer->'room'->>'roomID')::uuid<>added_room
      OR (SELECT count(*) FROM cup050_private.rooms WHERE active
          AND ((owner_a=a AND owner_b=c) OR (owner_a=c AND owner_b=a)))<>1
    THEN RAISE EXCEPTION 'username add was not idempotent: %',answer; END IF;

  -- Preserve post-Build-13 revision-fence/device registration and revocation behavior.
  answer:=public.bound_social_v1('unregister',jsonb_build_object('installationID',installation,'revision','2'));
  IF answer->>'ok'<>'true' THEN RAISE EXCEPTION 'revocation fence failed: %',answer; END IF;
  answer:=public.bound_social_v1('device',jsonb_build_object('installationID',installation,'revision','1','token',token,'environment','sandbox'));
  IF answer->>'ignored'<>'true' OR EXISTS(SELECT 1 FROM bound_social_private.devices WHERE installation_id=installation)
    THEN RAISE EXCEPTION 'stale registration resurrected device'; END IF;
  answer:=public.bound_social_v1('device',jsonb_build_object('installationID',installation,'revision','3','token',token,'environment','sandbox'));
  IF answer->>'ok'<>'true' OR NOT EXISTS(SELECT 1 FROM bound_social_private.devices WHERE installation_id=installation AND owner=a)
    THEN RAISE EXCEPTION 'new registration failed'; END IF;
  answer:=public.bound_social_v1('unregister',jsonb_build_object('installationID',installation,'revision','4'));
  IF answer->>'ok'<>'true' OR EXISTS(SELECT 1 FROM bound_social_private.devices WHERE installation_id=installation)
    THEN RAISE EXCEPTION 'device revocation failed'; END IF;

  -- The original Build 13 invite lifecycle remains usable alongside name add.
  answer:=public.bound_social_v1('create','{}');
  IF answer->>'ok'<>'true' OR answer->>'username'<>a_name THEN RAISE EXCEPTION 'invite creation failed: %',answer; END IF;
  code:=answer->>'code';
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',b::text,true);
  answer:=public.bound_social_v1('accept',jsonb_build_object('code',code));
  IF answer->>'ok'<>'true' OR answer->'room'->>'displayName'<>a_name OR answer->>'username'<>b_name
    THEN RAISE EXCEPTION 'Build 13 accept failed: %',answer; END IF;
  pairing:=(answer->'room'->>'roomID')::uuid;
  -- Exercise the direct Build 13 endpoint pair independently of the v1 wrapper.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',a::text,true);
  answer:=public.cup050_friends('create',jsonb_build_object('displayName',a_name||' Direct'));
  IF answer->>'ok'<>'true' OR coalesce(answer->>'code','') !~ '^[0-9A-F]{16}$'
    THEN RAISE EXCEPTION 'direct Build 13 invite creation failed: %',answer; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',direct_peer,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',direct_peer::text,true);
  answer:=public.cup050_friends('accept',jsonb_build_object('code',answer->>'code','displayName',direct_name));
  IF answer->>'ok'<>'true' OR answer->'room'->>'displayName'<>a_name||' Direct'
    THEN RAISE EXCEPTION 'direct Build 13 invite acceptance failed: %',answer; END IF;
  pairing:=(answer->'room'->>'roomID')::uuid;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',a::text,true);
  answer:=public.bound_social_v1('create','{}');
  IF answer->>'ok'<>'true' THEN RAISE EXCEPTION 'second v1 invite creation failed: %',answer; END IF;
  answer:=public.bound_social_v1('username',jsonb_build_object('username','Smoke Ember '||suffix));
  IF answer->>'ok'<>'true' OR answer->>'username'<>'Smoke Ember '||suffix
    THEN RAISE EXCEPTION 'v1 username rename failed: %',answer; END IF;
  IF (SELECT display_name FROM cup050_private.invites WHERE creator=a AND NOT consumed) IS DISTINCT FROM ('Smoke Ember '||suffix)
    THEN RAISE EXCEPTION 'v1 rename did not update outstanding invite'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',b::text,true);
  answer:=public.bound_social_v1('list','{}');
  IF answer->'rooms'->0->>'displayName'<>'Smoke Ember '||suffix
    THEN RAISE EXCEPTION 'v1 list did not receive renamed peer label: %',answer; END IF;
  answer:=public.cup050_friends('list','{}');
  IF answer->'rooms'->0->>'displayName'<>'Smoke Ember '||suffix
    THEN RAISE EXCEPTION 'legacy list compatibility failed: %',answer; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',direct_peer,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',direct_peer::text,true);
  answer:=public.cup050_friends('list','{}');
  IF answer->'rooms'->0->>'displayName'<>'Smoke Ember '||suffix
    THEN RAISE EXCEPTION 'direct Build 13 list failed: %',answer; END IF;
  answer:=public.cup050_friends('room',jsonb_build_object('roomID',pairing));
  IF answer->>'ok'<>'true' THEN RAISE EXCEPTION 'legacy room authorization failed: %',answer; END IF;
  answer:=public.cup050_friends('remove',jsonb_build_object('roomID',pairing));
  IF answer->>'ok'<>'true' THEN RAISE EXCEPTION 'legacy removal failed: %',answer; END IF;
  answer:=public.cup050_friends('room',jsonb_build_object('roomID',pairing));
  IF answer->>'ok'<>'false' THEN RAISE EXCEPTION 'removed room remains authorized'; END IF;

  IF md5(pg_get_functiondef('public.cup050_friends(text,jsonb)'::regprocedure))
       IS DISTINCT FROM (SELECT function_hash FROM smoke_legacy_baseline)
    THEN RAISE EXCEPTION 'legacy friend function definition changed'; END IF;
  IF NOT has_function_privilege('authenticated','public.bound_social_v1(text,jsonb)','EXECUTE')
      OR NOT has_function_privilege('authenticated','public.bound_social_v2(text,jsonb)','EXECUTE')
      OR has_function_privilege('anon','public.bound_social_v2(text,jsonb)','EXECUTE')
      OR has_function_privilege('authenticated','public.bound_jiggle_dispatch(uuid,uuid,uuid)','EXECUTE')
      OR has_schema_privilege('authenticated','bound_social_private','USAGE')
    THEN RAISE EXCEPTION 'social privileges failed'; END IF;
END $$;
ROLLBACK;
