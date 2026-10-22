-- Additive multiplayer authority. Ordinary friends, Agora video tokens, saves,
-- and every existing RPC keep their existing signatures and behavior.
CREATE SCHEMA bound_multiplayer_private;
REVOKE ALL ON SCHEMA bound_multiplayer_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA bound_multiplayer_private TO authenticated;

CREATE TABLE bound_multiplayer_private.run_leases (
  owner uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  run_id uuid NOT NULL,
  device_id uuid NOT NULL,
  request_id uuid NOT NULL,
  lease_token uuid NOT NULL,
  fence bigint NOT NULL CHECK (fence > 0),
  expires_at timestamptz NOT NULL,
  released boolean NOT NULL DEFAULT false,
  PRIMARY KEY (owner, run_id)
);
ALTER TABLE bound_multiplayer_private.run_leases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bound_multiplayer_private.run_leases FROM PUBLIC, anon, authenticated;

CREATE FUNCTION bound_multiplayer_private.run_lease(action text, payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  actor uuid := auth.uid();
  claims jsonb := auth.jwt();
  session_id uuid;
  requested_run uuid; requested_device uuid; requested_id uuid; token uuid; requested_fence bigint;
  stamp timestamptz;
  lease bound_multiplayer_private.run_leases%rowtype;
  pattern constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
BEGIN
  IF actor IS NULL OR claims->>'role' IS DISTINCT FROM 'authenticated'
     OR coalesce(claims->>'session_id','') !~ pattern THEN
    RETURN '{"ok":false,"error":"unauthorized"}'::jsonb;
  END IF;
  session_id := (claims->>'session_id')::uuid;
  PERFORM cup117_private.assert_active(actor);
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id=actor AND u.deleted_at IS NULL
      AND u.is_anonymous IS FALSE AND u.email_confirmed_at IS NOT NULL)
     OR NOT EXISTS (SELECT 1 FROM auth.sessions s WHERE s.id=session_id AND s.user_id=actor
      AND (s.not_after IS NULL OR s.not_after > clock_timestamp())) THEN
    RETURN '{"ok":false,"error":"unauthorized"}'::jsonb;
  END IF;
  IF action IS NULL OR action NOT IN ('acquire','renew','release')
     OR jsonb_typeof(payload) IS DISTINCT FROM 'object' OR octet_length(payload::text)>768
     OR jsonb_typeof(payload->'runID') IS DISTINCT FROM 'string'
     OR jsonb_typeof(payload->'deviceID') IS DISTINCT FROM 'string'
     OR coalesce(payload->>'runID','') !~ pattern OR coalesce(payload->>'deviceID','') !~ pattern THEN
    RETURN '{"ok":false,"error":"invalid_request"}'::jsonb;
  END IF;
  requested_run := (payload->>'runID')::uuid; requested_device := (payload->>'deviceID')::uuid;
  IF action='acquire' THEN
    IF payload-'runID'-'deviceID'-'requestID'-'transfer'<>'{}'::jsonb
       OR jsonb_typeof(payload->'requestID') IS DISTINCT FROM 'string'
       OR coalesce(payload->>'requestID','') !~ pattern
       OR jsonb_typeof(payload->'transfer') IS DISTINCT FROM 'boolean' THEN
      RETURN '{"ok":false,"error":"invalid_request"}'::jsonb;
    END IF;
    requested_id := (payload->>'requestID')::uuid;
  ELSE
    IF payload-'runID'-'deviceID'-'token'-'fence'<>'{}'::jsonb
       OR jsonb_typeof(payload->'token') IS DISTINCT FROM 'string'
       OR coalesce(payload->>'token','') !~ pattern
       OR jsonb_typeof(payload->'fence') IS DISTINCT FROM 'string'
       OR coalesce(payload->>'fence','') !~ '^[1-9][0-9]{0,18}$'
       OR (length(payload->>'fence')=19 AND payload->>'fence'>'9223372036854775807') THEN
      RETURN '{"ok":false,"error":"invalid_request"}'::jsonb;
    END IF;
    token := (payload->>'token')::uuid; requested_fence := (payload->>'fence')::bigint;
  END IF;
  -- Serialize creation as well as updates. Owner-level locking also makes the
  -- bounded run count atomic; the primary key makes every lookup indexed.
  PERFORM pg_advisory_xact_lock(hashtextextended('bound-run-lease:' || actor::text, 0));
  stamp := clock_timestamp();
  -- A queued acquire must not outlive session revocation while waiting for the
  -- owner lock. Keep the live session row until this operation commits.
  PERFORM 1 FROM auth.sessions s WHERE s.id=session_id AND s.user_id=actor
    AND (s.not_after IS NULL OR s.not_after>stamp) FOR KEY SHARE;
  IF NOT FOUND THEN RETURN '{"ok":false,"error":"unauthorized"}'::jsonb; END IF;
  SELECT l.* INTO lease FROM bound_multiplayer_private.run_leases l
    WHERE l.owner=actor AND l.run_id=requested_run FOR UPDATE;
  IF action='acquire' THEN
    IF FOUND THEN
      IF NOT lease.released AND lease.expires_at>stamp THEN
        IF lease.device_id<>requested_device OR lease.request_id<>requested_id THEN
          RETURN '{"ok":false,"error":"lease_held"}'::jsonb;
        END IF;
        -- Idempotent retry returns the original authority without extending it.
      ELSE
        IF lease.device_id<>requested_device AND NOT (payload->>'transfer')::boolean THEN
          RETURN '{"ok":false,"error":"transfer_required"}'::jsonb;
        END IF;
        IF lease.fence=9223372036854775807 THEN RETURN '{"ok":false,"error":"unavailable"}'::jsonb; END IF;
        UPDATE bound_multiplayer_private.run_leases l SET device_id=requested_device,
          request_id=requested_id, lease_token=gen_random_uuid(), fence=l.fence+1,
          expires_at=stamp+interval '60 seconds', released=false
          WHERE l.owner=actor AND l.run_id=requested_run RETURNING l.* INTO lease;
      END IF;
    ELSE
      IF (SELECT count(*) FROM bound_multiplayer_private.run_leases l WHERE l.owner=actor)>=256 THEN
        RETURN '{"ok":false,"error":"run_limit"}'::jsonb;
      END IF;
      INSERT INTO bound_multiplayer_private.run_leases(owner,run_id,device_id,request_id,lease_token,fence,expires_at)
        VALUES(actor,requested_run,requested_device,requested_id,gen_random_uuid(),1,stamp+interval '60 seconds') RETURNING * INTO lease;
    END IF;
  ELSE
    IF NOT FOUND OR lease.device_id<>requested_device OR lease.lease_token<>token OR lease.fence<>requested_fence THEN
      RETURN '{"ok":false,"error":"fenced"}'::jsonb;
    END IF;
    IF action='release' THEN
      UPDATE bound_multiplayer_private.run_leases l SET released=true,expires_at=least(l.expires_at,stamp)
        WHERE l.owner=actor AND l.run_id=requested_run;
      RETURN '{"ok":true}'::jsonb;
    END IF;
    IF lease.released OR lease.expires_at<=stamp THEN RETURN '{"ok":false,"error":"lease_expired"}'::jsonb; END IF;
    UPDATE bound_multiplayer_private.run_leases l SET expires_at=stamp+interval '60 seconds'
      WHERE l.owner=actor AND l.run_id=requested_run RETURNING l.* INTO lease;
  END IF;
  RETURN jsonb_build_object('ok',true,'ownerID',actor,'runID',requested_run,'deviceID',requested_device,
    'fence',lease.fence::text,'token',lease.lease_token,'serverTime',extract(epoch from stamp),
    'expiresAt',extract(epoch from lease.expires_at));
EXCEPTION WHEN insufficient_privilege THEN
  RETURN '{"ok":false,"error":"unauthorized"}'::jsonb;
END $$;
REVOKE ALL ON FUNCTION bound_multiplayer_private.run_lease(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION bound_multiplayer_private.run_lease(text,jsonb) TO authenticated;

CREATE FUNCTION public.bound_run_lease_v1(action text, payload jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$
  SELECT bound_multiplayer_private.run_lease(action,payload)
$$;
REVOKE ALL ON FUNCTION public.bound_run_lease_v1(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bound_run_lease_v1(text,jsonb) TO authenticated;
