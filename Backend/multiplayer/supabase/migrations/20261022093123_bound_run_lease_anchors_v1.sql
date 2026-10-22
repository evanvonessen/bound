-- Preserve the last acknowledged checkpoint and current shared history across
-- device transfer. The private table and public RPC retain their original ACLs.
ALTER TABLE bound_multiplayer_private.run_leases
  ADD COLUMN checkpoint_id uuid,
  ADD COLUMN checkpoint_parent uuid,
  ADD COLUMN checkpoint_history text,
  ADD COLUMN history_digest text,
  ADD COLUMN anchor_version bigint NOT NULL DEFAULT 0 CHECK (anchor_version >= 0),
  ADD CONSTRAINT checkpoint_anchor_valid CHECK (
    (checkpoint_id IS NULL AND checkpoint_parent IS NULL AND checkpoint_history IS NULL)
    OR (checkpoint_id IS NOT NULL AND checkpoint_history IS NOT NULL AND checkpoint_history ~ '^[0-9a-f]{64}$'
        AND checkpoint_id IS DISTINCT FROM checkpoint_parent)),
  ADD CONSTRAINT history_anchor_valid CHECK (history_digest IS NULL OR history_digest ~ '^[0-9a-f]{64}$');

CREATE OR REPLACE FUNCTION bound_multiplayer_private.run_lease(action text, payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  actor uuid := auth.uid();
  claims jsonb := auth.jwt();
  session_id uuid;
  requested_run uuid; requested_device uuid; requested_id uuid; token uuid; requested_fence bigint;
  requested_checkpoint uuid; requested_parent uuid; requested_history text; requested_version bigint;
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
  IF action IS NULL OR action NOT IN ('acquire','renew','release','history','checkpoint')
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
    IF (action IN ('renew','release') AND payload-'runID'-'deviceID'-'token'-'fence'<>'{}'::jsonb)
       OR jsonb_typeof(payload->'token') IS DISTINCT FROM 'string'
       OR coalesce(payload->>'token','') !~ pattern
       OR jsonb_typeof(payload->'fence') IS DISTINCT FROM 'string'
       OR coalesce(payload->>'fence','') !~ '^[1-9][0-9]{0,18}$'
       OR (length(payload->>'fence')=19 AND payload->>'fence'>'9223372036854775807') THEN
      RETURN '{"ok":false,"error":"invalid_request"}'::jsonb;
    END IF;
    token := (payload->>'token')::uuid; requested_fence := (payload->>'fence')::bigint;
    IF action IN ('history','checkpoint') THEN
      IF jsonb_typeof(payload->'history') IS DISTINCT FROM 'string'
         OR coalesce(payload->>'history','') !~ '^[0-9a-f]{64}$'
         OR jsonb_typeof(payload->'expectedVersion') IS DISTINCT FROM 'string'
         OR coalesce(payload->>'expectedVersion','') !~ '^(0|[1-9][0-9]{0,18})$'
         OR (length(payload->>'expectedVersion')=19 AND payload->>'expectedVersion'>'9223372036854775807') THEN
        RETURN '{"ok":false,"error":"invalid_request"}'::jsonb;
      END IF;
      requested_history := payload->>'history'; requested_version := (payload->>'expectedVersion')::bigint;
      IF action='history' THEN
        IF payload-ARRAY['runID','deviceID','token','fence','history','expectedVersion']<>'{}'::jsonb THEN
          RETURN '{"ok":false,"error":"invalid_request"}'::jsonb;
        END IF;
      ELSE
        IF payload-ARRAY['runID','deviceID','token','fence','history','expectedVersion','checkpointID','predecessor']<>'{}'::jsonb
           OR jsonb_typeof(payload->'checkpointID') IS DISTINCT FROM 'string'
           OR coalesce(payload->>'checkpointID','') !~ pattern
           OR NOT (payload ? 'predecessor')
           OR (payload->'predecessor'<>'null'::jsonb AND (jsonb_typeof(payload->'predecessor') IS DISTINCT FROM 'string'
                OR coalesce(payload->>'predecessor','') !~ pattern)) THEN
          RETURN '{"ok":false,"error":"invalid_request"}'::jsonb;
        END IF;
        requested_checkpoint := (payload->>'checkpointID')::uuid;
        requested_parent := (payload->>'predecessor')::uuid;
        IF requested_checkpoint=requested_parent THEN RETURN '{"ok":false,"error":"invalid_request"}'::jsonb; END IF;
      END IF;
    END IF;
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
    IF action='history' AND lease.history_digest IS DISTINCT FROM requested_history THEN
      IF lease.anchor_version<>requested_version THEN RETURN '{"ok":false,"error":"anchor_conflict"}'::jsonb; END IF;
      IF lease.anchor_version=9223372036854775807 THEN RETURN '{"ok":false,"error":"unavailable"}'::jsonb; END IF;
      UPDATE bound_multiplayer_private.run_leases l SET history_digest=requested_history,anchor_version=l.anchor_version+1
        WHERE l.owner=actor AND l.run_id=requested_run RETURNING l.* INTO lease;
    ELSIF action='checkpoint' THEN
      IF lease.checkpoint_id=requested_checkpoint THEN
        -- A lost response is retryable; an ID never identifies different bytes.
        IF lease.checkpoint_history IS DISTINCT FROM requested_history OR lease.checkpoint_parent IS DISTINCT FROM requested_parent THEN
          RETURN '{"ok":false,"error":"anchor_conflict"}'::jsonb;
        END IF;
      ELSE
        IF lease.anchor_version<>requested_version OR lease.checkpoint_id IS DISTINCT FROM requested_parent
           OR lease.history_digest IS DISTINCT FROM requested_history THEN
          RETURN '{"ok":false,"error":"anchor_conflict"}'::jsonb;
        END IF;
        IF lease.anchor_version=9223372036854775807 THEN RETURN '{"ok":false,"error":"unavailable"}'::jsonb; END IF;
        UPDATE bound_multiplayer_private.run_leases l SET checkpoint_id=requested_checkpoint,
          checkpoint_parent=requested_parent,checkpoint_history=requested_history,anchor_version=l.anchor_version+1
          WHERE l.owner=actor AND l.run_id=requested_run RETURNING l.* INTO lease;
      END IF;
    END IF;
    UPDATE bound_multiplayer_private.run_leases l SET expires_at=stamp+interval '60 seconds'
      WHERE l.owner=actor AND l.run_id=requested_run RETURNING l.* INTO lease;
  END IF;
  RETURN jsonb_build_object('ok',true,'ownerID',actor,'runID',requested_run,'deviceID',requested_device,
    'fence',lease.fence::text,'token',lease.lease_token,'serverTime',extract(epoch from stamp),
    'expiresAt',extract(epoch from lease.expires_at),'checkpointID',lease.checkpoint_id,
    'checkpointHistory',lease.checkpoint_history,'historyDigest',lease.history_digest,'anchorVersion',lease.anchor_version::text);
EXCEPTION WHEN insufficient_privilege THEN
  RETURN '{"ok":false,"error":"unauthorized"}'::jsonb;
END $$;
