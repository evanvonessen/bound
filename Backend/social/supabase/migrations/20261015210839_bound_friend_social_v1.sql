-- Additive Bound social profile, device registration, and Jiggle queue.
-- Existing cup050_friends and moderation definitions are intentionally unchanged.
BEGIN;
CREATE SCHEMA IF NOT EXISTS bound_social_private;
REVOKE ALL ON SCHEMA bound_social_private FROM PUBLIC, anon, authenticated;

CREATE TABLE bound_social_private.profiles (
  owner uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username text NOT NULL CHECK (char_length(username) BETWEEN 1 AND 40),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE bound_social_private.username_changes (
  owner uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  changed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON bound_social_private.username_changes(owner, changed_at DESC);

CREATE TABLE bound_social_private.devices (
  installation_id uuid PRIMARY KEY,
  owner uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token text NOT NULL UNIQUE CHECK (char_length(token) BETWEEN 32 AND 512 AND mod(char_length(token),2)=0 AND token ~* '^[0-9a-f]+$'),
  environment text NOT NULL CHECK (environment IN ('sandbox','production')),
  updated_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '60 days')
);
CREATE INDEX ON bound_social_private.devices(owner, expires_at);

CREATE TABLE bound_social_private.jiggle_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  recipient uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  room uuid NOT NULL REFERENCES cup050_private.rooms(id) ON DELETE CASCADE,
  request_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','sent','failed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  UNIQUE(sender, request_id),
  CHECK(sender <> recipient)
);
CREATE INDEX ON bound_social_private.jiggle_jobs(sender, created_at DESC);
CREATE INDEX ON bound_social_private.jiggle_jobs(recipient, created_at DESC);
CREATE INDEX ON bound_social_private.jiggle_jobs(sender, recipient, created_at DESC);
CREATE INDEX ON bound_social_private.jiggle_jobs(created_at);
ALTER TABLE bound_social_private.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE bound_social_private.username_changes ENABLE ROW LEVEL SECURITY;
ALTER TABLE bound_social_private.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE bound_social_private.jiggle_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA bound_social_private FROM PUBLIC, anon, authenticated;

CREATE FUNCTION bound_social_private.ensure_profile(actor uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE selected text;
BEGIN
  IF actor IS NULL THEN RETURN NULL; END IF;
  SELECT username INTO selected FROM bound_social_private.profiles WHERE owner=actor;
  IF FOUND THEN RETURN selected; END IF;
  SELECT CASE WHEN bound_moderation_private.clean_name(u.raw_user_meta_data->>'cupcake_username_v1')
    THEN btrim(u.raw_user_meta_data->>'cupcake_username_v1') END
    INTO selected FROM auth.users u WHERE u.id=actor AND u.deleted_at IS NULL;
  IF selected IS NULL THEN
    SELECT CASE WHEN bound_moderation_private.clean_name(candidate) THEN btrim(candidate) END
      INTO selected
      FROM (
        SELECT CASE WHEN owner_a=actor THEN name_a ELSE name_b END AS candidate
        FROM cup050_private.rooms
        WHERE actor IN(owner_a,owner_b)
        ORDER BY id
      ) names
      WHERE bound_moderation_private.clean_name(candidate)
      LIMIT 1;
  END IF;
  IF selected IS NULL THEN selected:='Player_'||left(replace(actor::text,'-',''),8); END IF;
  INSERT INTO bound_social_private.profiles(owner,username) VALUES(actor,selected)
    ON CONFLICT(owner) DO NOTHING;
  SELECT username INTO selected FROM bound_social_private.profiles WHERE owner=actor;
  RETURN selected;
END $$;
REVOKE ALL ON FUNCTION bound_social_private.ensure_profile(uuid) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.bound_social_v1(action text, payload jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='3s' AS $$
DECLARE actor uuid:=auth.uid(); stamp timestamptz:=clock_timestamp(); profile_name text;
        result jsonb; next_payload jsonb; peer uuid; pairing cup050_private.rooms%rowtype;
        installation uuid; token_value text; env text; change_count integer;
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
    IF payload-'installationID'-'token'-'environment'<>'{}'::jsonb
       OR jsonb_typeof(payload->'installationID') IS DISTINCT FROM 'string'
       OR jsonb_typeof(payload->'token') IS DISTINCT FROM 'string'
       OR jsonb_typeof(payload->'environment') IS DISTINCT FROM 'string'
       OR coalesce(payload->>'installationID','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR (char_length(coalesce(payload->>'token','')) NOT BETWEEN 32 AND 512 OR mod(char_length(coalesce(payload->>'token','')),2)<>0 OR coalesce(payload->>'token','') !~* '^[0-9a-f]+$')
       OR coalesce(payload->>'environment','') NOT IN ('sandbox','production') THEN RETURN denied; END IF;
    installation:=(payload->>'installationID')::uuid;
    token_value:=lower(payload->>'token'); env:=payload->>'environment';
    DELETE FROM bound_social_private.devices WHERE expires_at<=stamp;
    -- A token proves a new account owner; an installation ID alone cannot take another account's slot.
    IF EXISTS(SELECT 1 FROM bound_social_private.devices d WHERE d.installation_id=installation AND d.owner<>actor AND d.token<>token_value)
      THEN RETURN denied; END IF;
    IF NOT EXISTS(SELECT 1 FROM bound_social_private.devices d WHERE (d.token=token_value AND d.owner=actor) OR (d.installation_id=installation AND d.owner=actor))
       AND (SELECT count(*) FROM bound_social_private.devices d WHERE d.owner=actor AND d.expires_at>stamp)>=5
      THEN RETURN jsonb_build_object('ok',false,'error','device_limit'); END IF;
    -- The transaction-wide social lock serializes the token/installation upsert.
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
    RETURN jsonb_build_object('ok',true);
  ELSIF action='unregister' THEN
    IF payload-'installationID'<>'{}'::jsonb OR coalesce(payload->>'installationID','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RETURN denied; END IF;
    DELETE FROM bound_social_private.devices WHERE installation_id=(payload->>'installationID')::uuid AND owner=actor;
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

CREATE FUNCTION public.bound_jiggle_dispatch(sender uuid, room uuid, request uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='3s' AS $$
DECLARE pairing cup050_private.rooms%rowtype; recipient_id uuid; username_value text; prior bound_social_private.jiggle_jobs%rowtype;
        job_id uuid; devices jsonb; stamp timestamptz:=clock_timestamp();
BEGIN
  IF coalesce(auth.jwt()->>'role','')<>'service_role' THEN RETURN jsonb_build_object('ok',false); END IF;
  PERFORM cup117_private.assert_active(sender);
  PERFORM pg_advisory_xact_lock(505002026);
  -- APNs calls are bounded to seconds; a queued row older than an hour is abandoned.
  UPDATE bound_social_private.jiggle_jobs SET status='failed',finished_at=stamp
    WHERE status='queued' AND created_at<stamp-interval '1 hour';
  -- Retain completed idempotency records for 30 days, then bound private queue growth.
  DELETE FROM bound_social_private.jiggle_jobs WHERE created_at<stamp-interval '30 days';
  SELECT * INTO prior FROM bound_social_private.jiggle_jobs j WHERE j.sender=bound_jiggle_dispatch.sender AND j.request_id=bound_jiggle_dispatch.request;
  IF FOUND THEN
    IF prior.room<>bound_jiggle_dispatch.room THEN RETURN jsonb_build_object('ok',false,'error','request_conflict'); END IF;
    RETURN jsonb_build_object('ok',true,'duplicate',true,'status',prior.status);
  END IF;
  SELECT * INTO pairing FROM cup050_private.rooms r WHERE r.id=bound_jiggle_dispatch.room AND r.active
    AND bound_jiggle_dispatch.sender IN(r.owner_a,r.owner_b);
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false); END IF;
  recipient_id:=CASE WHEN pairing.owner_a=sender THEN pairing.owner_b ELSE pairing.owner_a END;
  PERFORM cup117_private.assert_active(recipient_id);
  IF NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=sender AND NOT u.is_anonymous AND u.email_confirmed_at IS NOT NULL AND u.deleted_at IS NULL)
     OR NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=recipient_id AND NOT u.is_anonymous AND u.email_confirmed_at IS NOT NULL AND u.deleted_at IS NULL)
     OR bound_moderation_private.denied_pair(sender,recipient_id) THEN RETURN jsonb_build_object('ok',false); END IF;
  IF EXISTS(SELECT 1 FROM bound_social_private.jiggle_jobs j WHERE j.sender IN(bound_jiggle_dispatch.sender,recipient_id)
      AND j.recipient IN(bound_jiggle_dispatch.sender,recipient_id) AND j.created_at>stamp-interval '1 minute')
     OR (SELECT count(*) FROM bound_social_private.jiggle_jobs j WHERE j.sender=bound_jiggle_dispatch.sender AND j.created_at>stamp-interval '1 hour')>=20
    THEN RETURN jsonb_build_object('ok',false,'error','rate_limited'); END IF;
  username_value:=bound_social_private.ensure_profile(sender);
  PERFORM bound_social_private.ensure_profile(recipient_id);
  SELECT coalesce(jsonb_agg(jsonb_build_object('token',d.token,'environment',d.environment) ORDER BY d.updated_at DESC),'[]'::jsonb)
    INTO devices FROM bound_social_private.devices d WHERE d.owner=recipient_id AND d.expires_at>stamp;
  IF jsonb_array_length(devices)=0 THEN RETURN jsonb_build_object('ok',false,'error','friend_unavailable'); END IF;
  INSERT INTO bound_social_private.jiggle_jobs(sender,recipient,room,request_id,status,created_at)
    VALUES(sender,recipient_id,pairing.id,request,'queued',stamp) RETURNING id INTO job_id;
  RETURN jsonb_build_object('ok',true,'jobID',job_id,'username',username_value,'recipientID',recipient_id,'devices',devices);
END $$;

CREATE FUNCTION public.bound_jiggle_finish(job uuid, delivered boolean, invalid_tokens text[] DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='3s' AS $$
DECLARE item bound_social_private.jiggle_jobs%rowtype;
BEGIN
  IF coalesce(auth.jwt()->>'role','')<>'service_role' THEN RETURN jsonb_build_object('ok',false); END IF;
  PERFORM pg_advisory_xact_lock(505002026);
  SELECT * INTO item FROM bound_social_private.jiggle_jobs WHERE id=bound_jiggle_finish.job FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',false); END IF;
  IF item.status='queued' THEN
    UPDATE bound_social_private.jiggle_jobs SET status=CASE WHEN delivered THEN 'sent' ELSE 'failed' END,
      finished_at=clock_timestamp() WHERE id=item.id RETURNING * INTO item;
  END IF;
  IF coalesce(array_length(invalid_tokens,1),0)>0 THEN
    DELETE FROM bound_social_private.devices d WHERE d.owner=item.recipient AND d.token=ANY(invalid_tokens);
  END IF;
  RETURN jsonb_build_object('ok',true,'status',item.status);
END $$;
REVOKE ALL ON FUNCTION public.bound_jiggle_dispatch(uuid,uuid,uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bound_jiggle_finish(uuid,boolean,text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bound_jiggle_dispatch(uuid,uuid,uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.bound_jiggle_finish(uuid,boolean,text[]) TO service_role;
COMMIT;
