-- APNs device registration race fence. Revisions are monotonic per native installation.
-- Clients pass a decimal-string revision for every device/unregister action.
BEGIN;
CREATE TABLE bound_social_private.registration_fences (
  installation_id uuid PRIMARY KEY,
  owner uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  revision bigint NOT NULL CHECK (revision > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE bound_social_private.registration_fences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE bound_social_private.registration_fences FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.bound_social_v1(action text, payload jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='3s' AS $$
DECLARE actor uuid:=auth.uid(); stamp timestamptz:=clock_timestamp(); profile_name text;
        result jsonb; next_payload jsonb; peer uuid; pairing cup050_private.rooms%rowtype;
        installation uuid; token_value text; env text; change_count integer;
        registration_revision bigint; fence_owner uuid; fence_revision bigint; fence_count integer;
        denied constant jsonb:='{"ok":false}'::jsonb;
BEGIN
  PERFORM cup117_private.assert_active(actor);
  IF actor IS NULL OR NOT EXISTS(
    SELECT 1 FROM auth.users u WHERE u.id=actor AND u.is_anonymous=false
      AND u.email_confirmed_at IS NOT NULL AND u.deleted_at IS NULL
  ) THEN RETURN denied; END IF;
  IF action IS NULL OR action NOT IN ('profile','username','list','create','accept','room','remove','block','unblock','report','device','unregister')
     OR payload IS NULL OR jsonb_typeof(payload)<>'object'
     OR octet_length(payload::text)>(CASE WHEN action='device' THEN 2048 ELSE 512 END) THEN RETURN denied; END IF;

  -- Match the legacy friend-service/deletion-fence lock order for stateful operations.
  PERFORM pg_advisory_xact_lock(505002026);
  profile_name:=bound_social_private.ensure_profile(actor);

  IF action='profile' THEN
    IF payload<>'{}'::jsonb THEN RETURN denied; END IF;
    RETURN jsonb_build_object('ok',true,'username',profile_name);
  ELSIF action='username' THEN
    IF payload-'username'<>'{}'::jsonb OR jsonb_typeof(payload->'username') IS DISTINCT FROM 'string'
       OR NOT bound_moderation_private.clean_name(payload->>'username') THEN
      RETURN jsonb_build_object('ok',false,'error','name_not_allowed');
    END IF;
    SELECT count(*) INTO change_count FROM bound_social_private.username_changes
      WHERE owner=actor AND changed_at>stamp-interval '1 hour';
    IF change_count>=10 THEN RETURN jsonb_build_object('ok',false,'error','rate_limited'); END IF;
    profile_name:=btrim(payload->>'username');
    INSERT INTO bound_social_private.profiles(owner,username,updated_at) VALUES(actor,profile_name,stamp)
      ON CONFLICT(owner) DO UPDATE SET username=EXCLUDED.username,updated_at=EXCLUDED.updated_at;
    DELETE FROM bound_social_private.username_changes WHERE owner=actor AND changed_at<stamp-interval '30 days';
    INSERT INTO bound_social_private.username_changes(owner,changed_at) VALUES(actor,stamp);
    UPDATE cup050_private.rooms SET name_a=profile_name WHERE owner_a=actor;
    UPDATE cup050_private.rooms SET name_b=profile_name WHERE owner_b=actor;
    UPDATE cup050_private.invites SET display_name=profile_name WHERE creator=actor AND NOT consumed;
    RETURN jsonb_build_object('ok',true,'username',profile_name);
  ELSIF action='device' THEN
    IF payload-'installationID'-'token'-'environment'-'revision'<>'{}'::jsonb
       OR jsonb_typeof(payload->'installationID') IS DISTINCT FROM 'string'
       OR jsonb_typeof(payload->'token') IS DISTINCT FROM 'string'
       OR jsonb_typeof(payload->'environment') IS DISTINCT FROM 'string'
       OR jsonb_typeof(payload->'revision') IS DISTINCT FROM 'string'
       OR coalesce(payload->>'installationID','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR (char_length(coalesce(payload->>'token','')) NOT BETWEEN 32 AND 512 OR mod(char_length(coalesce(payload->>'token','')),2)<>0 OR coalesce(payload->>'token','') !~* '^[0-9a-f]+$')
       OR coalesce(payload->>'environment','') NOT IN ('sandbox','production')
       OR coalesce(payload->>'revision','') !~ '^[1-9][0-9]{0,18}$'
       OR (char_length(payload->>'revision')=19 AND payload->>'revision'>'9223372036854775807') THEN RETURN denied; END IF;
    installation:=(payload->>'installationID')::uuid;
    registration_revision:=(payload->>'revision')::bigint;
    token_value:=lower(payload->>'token'); env:=payload->>'environment';
    SELECT f.owner,f.revision INTO fence_owner,fence_revision FROM bound_social_private.registration_fences f
      WHERE f.installation_id=installation FOR UPDATE;
    IF FOUND THEN
      IF registration_revision<=fence_revision THEN RETURN jsonb_build_object('ok',true,'ignored',true); END IF;
      IF fence_owner<>actor THEN
        SELECT count(*) INTO fence_count FROM bound_social_private.registration_fences f WHERE f.owner=actor;
        IF fence_count>=20 THEN RETURN jsonb_build_object('ok',false,'error','installation_limit'); END IF;
      END IF;
    ELSE
      SELECT count(*) INTO fence_count FROM bound_social_private.registration_fences f WHERE f.owner=actor;
      IF fence_count>=20 THEN RETURN jsonb_build_object('ok',false,'error','installation_limit'); END IF;
    END IF;
    DELETE FROM bound_social_private.devices WHERE expires_at<=stamp;
    -- A token proves a new account owner; an installation ID alone cannot take another account's slot.
    IF EXISTS(SELECT 1 FROM bound_social_private.devices d WHERE d.installation_id=installation AND d.owner<>actor AND d.token<>token_value)
      THEN RETURN denied; END IF;
    IF NOT EXISTS(SELECT 1 FROM bound_social_private.devices d WHERE (d.token=token_value AND d.owner=actor) OR (d.installation_id=installation AND d.owner=actor))
       AND (SELECT count(*) FROM bound_social_private.devices d WHERE d.owner=actor AND d.expires_at>stamp)>=5
      THEN RETURN jsonb_build_object('ok',false,'error','device_limit'); END IF;
    -- The transaction-wide social lock serializes fences and the token/installation upsert.
    -- Rebind an already registered APNs token first (account switch), otherwise
    -- replace this account's installation token after APNs rotation.
    DELETE FROM bound_social_private.devices d WHERE d.installation_id=installation AND d.owner=actor AND d.token<>token_value;
    UPDATE bound_social_private.devices d SET installation_id=installation,owner=actor,environment=env,
      updated_at=stamp,expires_at=stamp+interval '60 days' WHERE d.token=token_value;
    IF NOT FOUND THEN
      UPDATE bound_social_private.devices d SET token=token_value,environment=env,updated_at=stamp,
        expires_at=stamp+interval '60 days' WHERE d.installation_id=installation AND d.owner=actor;
      IF NOT FOUND THEN
        INSERT INTO bound_social_private.devices(installation_id,owner,token,environment,updated_at,expires_at)
          VALUES(installation,actor,token_value,env,stamp,stamp+interval '60 days');
      END IF;
    END IF;
    INSERT INTO bound_social_private.registration_fences(installation_id,owner,revision,updated_at)
      VALUES(installation,actor,registration_revision,stamp)
      ON CONFLICT(installation_id) DO UPDATE SET owner=EXCLUDED.owner,revision=EXCLUDED.revision,updated_at=EXCLUDED.updated_at;
    RETURN jsonb_build_object('ok',true);
  ELSIF action='unregister' THEN
    IF payload-'installationID'-'revision'<>'{}'::jsonb
       OR jsonb_typeof(payload->'installationID') IS DISTINCT FROM 'string'
       OR jsonb_typeof(payload->'revision') IS DISTINCT FROM 'string'
       OR coalesce(payload->>'installationID','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR coalesce(payload->>'revision','') !~ '^[1-9][0-9]{0,18}$'
       OR (char_length(payload->>'revision')=19 AND payload->>'revision'>'9223372036854775807') THEN RETURN denied; END IF;
    installation:=(payload->>'installationID')::uuid;
    registration_revision:=(payload->>'revision')::bigint;
    SELECT f.owner,f.revision INTO fence_owner,fence_revision FROM bound_social_private.registration_fences f
      WHERE f.installation_id=installation FOR UPDATE;
    IF FOUND THEN
      -- A sign-out from a previous account must never revoke the new account's device.
      IF fence_owner<>actor OR registration_revision<=fence_revision THEN RETURN jsonb_build_object('ok',true,'ignored',true); END IF;
    ELSE
      -- Before migration, a device row may exist without a fence. Do not let a
      -- different account create a tombstone for that installation.
      IF EXISTS(SELECT 1 FROM bound_social_private.devices d WHERE d.installation_id=installation AND d.owner<>actor)
        THEN RETURN jsonb_build_object('ok',true,'ignored',true); END IF;
      SELECT count(*) INTO fence_count FROM bound_social_private.registration_fences f WHERE f.owner=actor;
      IF fence_count>=20 THEN RETURN jsonb_build_object('ok',false,'error','installation_limit'); END IF;
    END IF;
    -- Persist an unregister tombstone even when its newer registration is still in flight.
    INSERT INTO bound_social_private.registration_fences(installation_id,owner,revision,updated_at)
      VALUES(installation,actor,registration_revision,stamp)
      ON CONFLICT(installation_id) DO UPDATE SET owner=EXCLUDED.owner,revision=EXCLUDED.revision,updated_at=EXCLUDED.updated_at;
    DELETE FROM bound_social_private.devices WHERE installation_id=installation AND owner=actor;
    RETURN jsonb_build_object('ok',true);
  ELSIF action='list' THEN
    IF payload<>'{}'::jsonb THEN RETURN denied; END IF;
    result:=public.cup050_friends('list','{}'::jsonb);
    IF coalesce((result->>'ok')::boolean,false) IS NOT TRUE OR jsonb_typeof(result->'rooms')<>'array' THEN RETURN result; END IF;
    SELECT coalesce(jsonb_agg(
      CASE WHEN room_value->>'roomID' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        room_value || jsonb_build_object('displayName',bound_social_private.ensure_profile(
          CASE WHEN r.owner_a=actor THEN r.owner_b ELSE r.owner_a END))
      ELSE room_value END ORDER BY ordinal), '[]'::jsonb)
      INTO next_payload
      FROM jsonb_array_elements(result->'rooms') WITH ORDINALITY rows(room_value,ordinal)
      LEFT JOIN cup050_private.rooms r ON r.id=(room_value->>'roomID')::uuid AND actor IN(r.owner_a,r.owner_b);
    RETURN jsonb_set(result,'{rooms}',coalesce(next_payload,'[]'::jsonb),false) || jsonb_build_object('username',profile_name);
  ELSIF action='create' THEN
    IF payload<>'{}'::jsonb THEN RETURN denied; END IF;
    result:=public.cup050_friends('create',jsonb_build_object('displayName',profile_name));
    IF result->>'ok'='true' THEN result:=result||jsonb_build_object('username',profile_name); END IF;
    RETURN result;
  ELSIF action='accept' THEN
    IF payload-'code'<>'{}'::jsonb OR jsonb_typeof(payload->'code') IS DISTINCT FROM 'string' THEN RETURN denied; END IF;
    result:=public.cup050_friends('accept',jsonb_build_object('code',payload->>'code','displayName',profile_name));
    IF result->>'ok'='true' AND result->'room'->>'roomID' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      SELECT * INTO pairing FROM cup050_private.rooms WHERE id=(result->'room'->>'roomID')::uuid;
      peer:=CASE WHEN pairing.owner_a=actor THEN pairing.owner_b ELSE pairing.owner_a END;
      result:=jsonb_set(result,'{room,displayName}',to_jsonb(bound_social_private.ensure_profile(peer)),false);
    END IF;
    IF result->>'ok'='true' THEN result:=result||jsonb_build_object('username',profile_name); END IF;
    RETURN result;
  ELSE
    -- Keep legacy remove/room/block/report validation and response semantics in its unchanged RPC.
    RETURN public.cup050_friends(action,payload);
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.bound_social_v1(text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bound_social_v1(text,jsonb) TO authenticated;

COMMIT;
