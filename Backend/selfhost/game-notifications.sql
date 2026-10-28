-- Additive self-hosted notification settings. Device registration remains the
-- master opt-in; child preferences never create an APNs registration.
CREATE TABLE bound_social_private.notification_preferences (
  owner uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  installation_id uuid NOT NULL,
  revision bigint NOT NULL CHECK (revision>0),
  send_join boolean NOT NULL,
  receive_invites boolean NOT NULL,
  PRIMARY KEY(owner,installation_id)
);
ALTER TABLE bound_social_private.notification_preferences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bound_social_private.notification_preferences FROM PUBLIC,anon,authenticated;
-- Preserve legacy opted-in installations. Modern registrations upload child
-- preferences atomically with their APNs token below.
INSERT INTO bound_social_private.notification_preferences(owner,installation_id,revision,send_join,receive_invites)
  SELECT owner,installation_id,1,true,true FROM bound_social_private.devices;
CREATE TABLE bound_social_private.game_notification_jobs (
  job uuid PRIMARY KEY REFERENCES bound_social_private.jiggle_jobs(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('bound-jiggle','shared-join','shared-start','shared-invite')),
  run uuid
);
ALTER TABLE bound_social_private.game_notification_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bound_social_private.game_notification_jobs FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.bound_notification_preferences(payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='3s' AS $$
DECLARE actor uuid:=auth.uid(); installation uuid; revision_value bigint;
BEGIN
  PERFORM cup117_private.assert_active(actor);
  IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=actor AND NOT is_anonymous
      AND email_confirmed_at IS NOT NULL AND deleted_at IS NULL)
    OR jsonb_typeof(payload) IS DISTINCT FROM 'object'
    OR payload-'installationID'-'revision'-'sendJoin'-'receiveInvites'<>'{}'::jsonb
    OR coalesce(payload->>'installationID','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    OR coalesce(payload->>'revision','') !~ '^[1-9][0-9]{0,17}$'
    OR coalesce(payload->>'sendJoin','') NOT IN ('true','false')
    OR coalesce(payload->>'receiveInvites','') NOT IN ('true','false') THEN RETURN '{"ok":false}'::jsonb; END IF;
  installation:=(payload->>'installationID')::uuid; revision_value:=(payload->>'revision')::bigint;
  PERFORM pg_advisory_xact_lock(505002026);
  -- Only this owner's registered installation may update its child settings.
  IF NOT EXISTS(SELECT 1 FROM bound_social_private.devices WHERE owner=actor AND installation_id=installation AND expires_at>now())
    THEN RETURN '{"ok":false}'::jsonb; END IF;
  INSERT INTO bound_social_private.notification_preferences(owner,installation_id,revision,send_join,receive_invites)
    VALUES(actor,installation,revision_value,(payload->>'sendJoin')::boolean,(payload->>'receiveInvites')::boolean)
    ON CONFLICT(owner,installation_id) DO UPDATE SET revision=EXCLUDED.revision,
      send_join=EXCLUDED.send_join,receive_invites=EXCLUDED.receive_invites
      WHERE notification_preferences.revision<EXCLUDED.revision;
  RETURN '{"ok":true}'::jsonb;
END $$;
REVOKE ALL ON FUNCTION public.bound_notification_preferences(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bound_notification_preferences(jsonb) TO authenticated;

CREATE FUNCTION public.bound_notification_device(payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' SET lock_timeout='3s' AS $$
DECLARE result jsonb; preferences jsonb;
BEGIN
  IF jsonb_typeof(payload) IS DISTINCT FROM 'object'
    OR coalesce(payload->>'sendJoin','') NOT IN ('true','false')
    OR coalesce(payload->>'receiveInvites','') NOT IN ('true','false')
    OR coalesce(payload->>'revision','') !~ '^[1-9][0-9]{0,17}$'
    THEN RETURN '{"ok":false}'::jsonb; END IF;
  result:=public.bound_social_v2('device',payload-'sendJoin'-'receiveInvites');
  IF result->>'ok' IS DISTINCT FROM 'true' OR result->>'ignored'='true' THEN RETURN result; END IF;
  preferences:=public.bound_notification_preferences(payload-'token'-'environment');
  -- A failure rolls back the token as well: a modern registration never has a
  -- window in which its persisted receive preference is not enforced.
  IF preferences->>'ok' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'notification_preferences'; END IF;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.bound_notification_device(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bound_notification_device(jsonb) TO authenticated;

CREATE FUNCTION public.bound_game_notification_dispatch(sender uuid,room uuid,request uuid,kind text,run uuid,installation uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='3s' AS $$
DECLARE result jsonb; state jsonb; prior record; filtered jsonb; job_id uuid;
BEGIN
  IF coalesce(auth.jwt()->>'role','')<>'service_role' OR kind IS NULL OR kind NOT IN ('bound-jiggle','shared-join','shared-start','shared-invite')
    THEN RETURN '{"ok":false,"error":"invalid_request"}'::jsonb; END IF;
  PERFORM cup117_private.assert_active(sender);
  PERFORM pg_advisory_xact_lock(505002026);
  IF kind<>'bound-jiggle' THEN
    SELECT value INTO state FROM public.storage WHERE collection='bound_independent_v2'
      AND user_id='00000000-0000-0000-0000-000000000000'::uuid AND key=run::text;
    IF state IS NULL OR state->>'save_id' IS DISTINCT FROM run::text OR state->>'roomID' IS DISTINCT FROM room::text
      OR state->>'deleted'='true' OR state->>'cancelled'='true' OR NOT coalesce(state->'members' ? sender::text,false)
      OR (kind='shared-start' AND state->'identity'->>'owner' IS DISTINCT FROM sender::text)
      THEN RETURN '{"ok":false,"error":"friend_unavailable"}'::jsonb; END IF;
    IF NOT EXISTS(SELECT 1 FROM bound_social_private.devices d
      JOIN bound_social_private.notification_preferences p ON p.owner=d.owner AND p.installation_id=d.installation_id
      WHERE d.owner=sender AND d.installation_id=installation AND d.expires_at>now()
        AND (kind='shared-invite' OR p.send_join))
      THEN RETURN '{"ok":true,"duplicate":true,"status":"suppressed"}'::jsonb; END IF;
  ELSIF run IS NOT NULL OR installation IS NOT NULL THEN RETURN '{"ok":false,"error":"invalid_request"}'::jsonb;
  END IF;
  SELECT j.id,m.kind,m.run INTO prior FROM bound_social_private.jiggle_jobs j
    LEFT JOIN bound_social_private.game_notification_jobs m ON m.job=j.id
    WHERE j.sender=bound_game_notification_dispatch.sender AND j.request_id=bound_game_notification_dispatch.request;
  IF FOUND AND (coalesce(prior.kind,'bound-jiggle')<>kind OR prior.run IS DISTINCT FROM run)
    THEN RETURN '{"ok":false,"error":"request_conflict"}'::jsonb; END IF;
  -- Preserve membership, moderation, email confirmation, rate limits and the
  -- bounded idempotency queue from the existing notification contract.
  result:=public.bound_jiggle_dispatch(sender,room,request);
  IF result->>'ok' IS DISTINCT FROM 'true' OR result->>'duplicate'='true' THEN RETURN result; END IF;
  job_id:=(result->>'jobID')::uuid;
  INSERT INTO bound_social_private.game_notification_jobs VALUES(job_id,kind,run);
  IF kind<>'shared-join' THEN
    SELECT coalesce(jsonb_agg(device),'[]'::jsonb) INTO filtered FROM jsonb_array_elements(result->'devices') device
      WHERE EXISTS(SELECT 1 FROM bound_social_private.devices d
        LEFT JOIN bound_social_private.notification_preferences p ON p.owner=d.owner AND p.installation_id=d.installation_id
        WHERE d.owner=(result->>'recipientID')::uuid AND d.token=device->>'token' AND coalesce(p.receive_invites,true));
    IF jsonb_array_length(filtered)=0 THEN
      PERFORM public.bound_jiggle_finish(job_id,false,'{}'::text[]);
      RETURN '{"ok":true,"duplicate":true,"status":"suppressed"}'::jsonb;
    END IF;
    result:=jsonb_set(result,'{devices}',filtered);
  END IF;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.bound_game_notification_dispatch(uuid,uuid,uuid,text,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.bound_game_notification_dispatch(uuid,uuid,uuid,text,uuid,uuid) TO service_role;
