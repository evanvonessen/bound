-- Operator-only smoke check of the deployed RPCs. All fixture data is rolled back.
-- Generates isolated identities and never reads or modifies customer rows.
BEGIN;
DO $$
DECLARE a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); code text;
        pairing uuid; answer jsonb; installation uuid:=gen_random_uuid();
BEGIN
  INSERT INTO auth.users(id,email,email_confirmed_at,is_anonymous,raw_user_meta_data)
    VALUES(a,'bound-social-'||a||'@example.invalid',now(),false,'{"cupcake_username_v1":"Fixture River"}'),
          (b,'bound-social-'||b||'@example.invalid',now(),false,'{"cupcake_username_v1":"Fixture Navi"}');
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  answer:=public.bound_social_v1('profile','{}');
  IF answer->>'username'<>'Fixture River' THEN RAISE EXCEPTION 'profile seed failed'; END IF;
  answer:=public.bound_social_v1('unregister',jsonb_build_object('installationID',installation,'revision','2'));
  IF answer->>'ok'<>'true' THEN RAISE EXCEPTION 'revocation fence failed'; END IF;
  answer:=public.bound_social_v1('device',jsonb_build_object('installationID',installation,'revision','1','token',repeat('ab',32),'environment','sandbox'));
  IF answer->>'ignored'<>'true' OR EXISTS(SELECT 1 FROM bound_social_private.devices WHERE installation_id=installation)
    THEN RAISE EXCEPTION 'stale registration resurrected device'; END IF;
  answer:=public.bound_social_v1('device',jsonb_build_object('installationID',installation,'revision','3','token',repeat('ab',32),'environment','sandbox'));
  IF answer->>'ok'<>'true' OR NOT EXISTS(SELECT 1 FROM bound_social_private.devices WHERE installation_id=installation AND owner=a)
    THEN RAISE EXCEPTION 'new registration failed'; END IF;
  answer:=public.bound_social_v1('unregister',jsonb_build_object('installationID',installation,'revision','4'));
  IF answer->>'ok'<>'true' OR EXISTS(SELECT 1 FROM bound_social_private.devices WHERE installation_id=installation)
    THEN RAISE EXCEPTION 'device revocation failed'; END IF;
  answer:=public.bound_social_v1('create','{}');
  IF answer->>'ok'<>'true' OR answer->>'username'<>'Fixture River' THEN RAISE EXCEPTION 'invite failed'; END IF;
  code:=answer->>'code';
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  answer:=public.bound_social_v1('accept',jsonb_build_object('code',code));
  IF answer->>'ok'<>'true' OR answer->'room'->>'displayName'<>'Fixture River' OR answer->>'username'<>'Fixture Navi'
    THEN RAISE EXCEPTION 'accept failed'; END IF;
  pairing:=(answer->'room'->>'roomID')::uuid;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  answer:=public.bound_social_v1('username','{"username":"Fixture Ember"}');
  IF answer->>'ok'<>'true' THEN RAISE EXCEPTION 'rename failed'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  answer:=public.bound_social_v1('list','{}');
  IF answer->'rooms'->0->>'displayName'<>'Fixture Ember' THEN RAISE EXCEPTION 'profile list failed'; END IF;
  answer:=public.cup050_friends('list','{}');
  IF answer->'rooms'->0->>'displayName'<>'Fixture Ember' THEN RAISE EXCEPTION 'legacy list compatibility failed'; END IF;
  answer:=public.cup050_friends('room',jsonb_build_object('roomID',pairing));
  IF answer->>'ok'<>'true' THEN RAISE EXCEPTION 'legacy room authorization failed'; END IF;
  answer:=public.cup050_friends('remove',jsonb_build_object('roomID',pairing));
  IF answer->>'ok'<>'true' THEN RAISE EXCEPTION 'remove failed'; END IF;
  answer:=public.cup050_friends('room',jsonb_build_object('roomID',pairing));
  IF answer->>'ok'<>'false' THEN RAISE EXCEPTION 'removed room remains authorized'; END IF;
  IF NOT has_function_privilege('authenticated','public.bound_social_v1(text,jsonb)','EXECUTE')
    OR has_function_privilege('anon','public.bound_social_v1(text,jsonb)','EXECUTE')
    OR has_function_privilege('authenticated','public.bound_jiggle_dispatch(uuid,uuid,uuid)','EXECUTE')
    OR has_schema_privilege('authenticated','bound_social_private','USAGE')
    THEN RAISE EXCEPTION 'social privileges failed'; END IF;
END $$;
ROLLBACK;
