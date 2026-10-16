-- Local integration pass against the read-only snapshot of the currently installed legacy RPC.
-- Run from the repository root on an empty disposable database. Never apply live.
\set ON_ERROR_STOP on
\ir local-fixture.sql
-- The snapshot's moderation wrapper needs these response-shaping helpers. The tested
-- create/accept/list/room/remove paths use the actual live function bodies below.
CREATE FUNCTION bound_moderation_private.label(value text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT CASE WHEN bound_moderation_private.clean_name(value) THEN value ELSE 'Friend' END
$$;
CREATE FUNCTION bound_moderation_private.block_list(actor uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('blockID',b.target,'displayName',bound_moderation_private.label(b.label)) ORDER BY b.target),'[]'::jsonb)
 FROM bound_moderation_private.blocks b WHERE b.owner=actor
$$;
CREATE FUNCTION bound_moderation_private.action(action text,payload jsonb) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT '{"ok":false}'::jsonb $$;
\ir live-legacy-functions.fixture.sql
UPDATE auth.users SET raw_user_meta_data='{"cupcake_username_v1":"Meta Alice"}' WHERE id='11111111-1111-4111-8111-111111111111';
CREATE TEMP TABLE legacy_baseline AS
 SELECT md5(pg_get_functiondef('public.cup050_friends(text,jsonb)'::regprocedure)) AS public_hash,
        md5(pg_get_functiondef('cup050_private.bound_friend_service_v1(text,jsonb)'::regprocedure)) AS service_hash;
\ir supabase/migrations/20261015210839_bound_friend_social_v1.sql
\ir supabase/migrations/20261015212112_bound_device_registration_revision_fence.sql
\ir supabase/migrations/20261015212554_bound_device_registration_owner_index.sql
SELECT set_config('request.jwt.claims','{"role":"authenticated","sub":"11111111-1111-4111-8111-111111111111"}',false);
SET ROLE authenticated;
DO $$ DECLARE answer jsonb; BEGIN
  answer:=public.bound_social_v1('profile','{}');
  IF answer->>'username'<>'Meta Alice' THEN RAISE EXCEPTION 'authenticated client cannot call social wrapper: %',answer; END IF;
END $$;
RESET ROLE;
DO $$
DECLARE a constant uuid:='11111111-1111-4111-8111-111111111111';
        b constant uuid:='22222222-2222-4222-8222-222222222222';
        room_id uuid; code text; answer jsonb; actual_count integer; i integer;
BEGIN
  IF md5(pg_get_functiondef('public.cup050_friends(text,jsonb)'::regprocedure))<>(SELECT public_hash FROM legacy_baseline)
     OR md5(pg_get_functiondef('cup050_private.bound_friend_service_v1(text,jsonb)'::regprocedure))<>(SELECT service_hash FROM legacy_baseline) THEN
    RAISE EXCEPTION 'legacy live RPC definitions changed';
  END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  answer:=public.bound_social_v1('profile','{}');
  IF answer->>'username'<>'Meta Alice' THEN RAISE EXCEPTION 'versioned legacy metadata seed mismatch: %',answer; END IF;
  answer:=public.bound_social_v1('create','{}');
  IF answer->>'ok'<>'true' OR answer->>'username'<>'Meta Alice' OR coalesce(answer->>'code','') !~ '^[0-9A-F]{16}$' THEN
    RAISE EXCEPTION 'actual invite creation / own username response mismatch: %',answer;
  END IF;
  code:=answer->>'code';
  IF NOT EXISTS(SELECT 1 FROM cup050_private.invites WHERE creator=a AND NOT consumed
      AND digest=extensions.digest(code,'sha256') AND display_name='Meta Alice') THEN RAISE EXCEPTION 'actual RPC invite storage mismatch'; END IF;
  answer:=public.bound_social_v1('username','{"username":"Renamed Alice"}');
  IF answer->>'username'<>'Renamed Alice' OR NOT EXISTS(SELECT 1 FROM cup050_private.invites WHERE creator=a AND NOT consumed AND display_name='Renamed Alice') THEN
    RAISE EXCEPTION 'profile rename did not update actual outstanding invite';
  END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',b,'role','authenticated')::text,true);
  answer:=public.bound_social_v1('accept',jsonb_build_object('code',code));
  IF answer->>'ok'<>'true' OR answer->>'username'<>'Player_22222222'
     OR answer->'room'->>'displayName'<>'Renamed Alice' THEN RAISE EXCEPTION 'actual accept/name response mismatch: %',answer; END IF;
  room_id:=(answer->'room'->>'roomID')::uuid;
  IF NOT EXISTS(SELECT 1 FROM cup050_private.rooms WHERE id=room_id AND owner_a=a AND owner_b=b
      AND name_a='Renamed Alice' AND name_b='Player_22222222' AND active) THEN RAISE EXCEPTION 'actual room columns/name mapping mismatch'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  answer:=public.bound_social_v1('list','{}');
  IF answer->>'username'<>'Renamed Alice' OR answer->'rooms'->0->>'displayName'<>'Player_22222222'
     OR jsonb_typeof(answer->'blocks')<>'array' THEN RAISE EXCEPTION 'actual list wrapper compatibility failed: %',answer; END IF;
  -- Existing own room names outrank display strings once no metadata/profile is present.
  DELETE FROM bound_social_private.profiles WHERE owner='77777777-7777-4777-8777-777777777777';
  PERFORM set_config('request.jwt.claims','{"sub":"77777777-7777-4777-8777-777777777777","role":"authenticated"}',true);
  answer:=public.bound_social_v1('profile','{}');
  IF answer->>'username'<>'Room Seed' THEN RAISE EXCEPTION 'room label fallback mismatch: %',answer; END IF;
  -- The real service counts creates and commits quota state on every invocation.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated')::text,true);
  FOR i IN 2..5 LOOP
    answer:=public.bound_social_v1('create','{}');
    IF answer->>'ok'<>'true' OR answer->>'username'<>'Renamed Alice' THEN RAISE EXCEPTION 'actual create quota rejected attempt %: %',i,answer; END IF;
  END LOOP;
  answer:=public.bound_social_v1('create','{}');
  IF answer->>'ok'<>'false' THEN RAISE EXCEPTION 'actual five-create hourly quota was bypassed: %',answer; END IF;
  SELECT creates INTO actual_count FROM cup050_private.limits WHERE owner=a;
  IF actual_count<>5 THEN RAISE EXCEPTION 'legacy create quota counter mismatch: %',actual_count; END IF;
  -- Remove uses the unchanged legacy path and keeps the row for the old list semantics.
  answer:=public.bound_social_v1('remove',jsonb_build_object('roomID',room_id::text));
  IF answer->>'ok'<>'true' OR NOT EXISTS(SELECT 1 FROM cup050_private.rooms WHERE id=room_id AND NOT active) THEN
    RAISE EXCEPTION 'actual remove passthrough failed: %',answer;
  END IF;
  answer:=public.bound_social_v1('list','{}');
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(answer->'rooms') r WHERE r->>'roomID'=room_id::text) THEN RAISE EXCEPTION 'removed room remained in list'; END IF;
END $$;
SELECT 'Bound social live-legacy integration contract passed' AS result;
