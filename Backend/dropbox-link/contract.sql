-- Apply transactionally before deploying bound-dropbox. No client can read grants.
BEGIN;
CREATE SCHEMA bound_dropbox_private;
REVOKE ALL ON SCHEMA bound_dropbox_private FROM PUBLIC, anon, authenticated;
CREATE TABLE bound_dropbox_private.links (
  owner uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  revision uuid NOT NULL DEFAULT gen_random_uuid(),
  ciphertext text CHECK (octet_length(ciphertext) <= 32768),
  window_start timestamptz NOT NULL DEFAULT now(),
  requests integer NOT NULL DEFAULT 0
);
ALTER TABLE bound_dropbox_private.links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bound_dropbox_private.links FROM PUBLIC, anon, authenticated, service_role;
-- The deletion contract already takes this lock exclusively. Account deletion
-- drains grant operations, then its marker blocks all further token issuance.
CREATE FUNCTION bound_dropbox_private.grant_operation(action text, payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' SET lock_timeout = '5s' AS $$
DECLARE target uuid := (payload->>'owner')::uuid;
  session_id uuid := (payload->>'session')::uuid;
  link bound_dropbox_private.links%rowtype;
BEGIN
  IF coalesce(auth.jwt()->>'role','') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_advisory_xact_lock_shared(11720260925);
  IF NOT EXISTS (SELECT 1 FROM auth.users u JOIN auth.sessions s ON s.user_id = u.id
      WHERE u.id = target AND s.id = session_id AND u.deleted_at IS NULL
      AND NOT u.is_anonymous AND u.email_confirmed_at IS NOT NULL
      AND (s.not_after IS NULL OR s.not_after > now()))
      OR EXISTS (SELECT 1 FROM cup117_private.deletions WHERE owner = target) THEN
    RETURN '{"error":"unauthorized"}'::jsonb;
  END IF;
  INSERT INTO bound_dropbox_private.links(owner) VALUES (target) ON CONFLICT DO NOTHING;
  SELECT * INTO link FROM bound_dropbox_private.links WHERE owner = target FOR UPDATE;
  IF link.window_start < now() - interval '1 minute' THEN
    UPDATE bound_dropbox_private.links SET window_start = now(), requests = 1 WHERE owner = target;
  ELSIF link.requests >= 120 THEN
    RETURN '{"error":"rate_limited"}'::jsonb;
  ELSE
    UPDATE bound_dropbox_private.links SET requests = requests + 1 WHERE owner = target;
  END IF;
  IF action = 'snapshot' THEN
    RETURN jsonb_build_object('revision',link.revision,'ciphertext',link.ciphertext);
  END IF;
  IF (payload->>'revision')::uuid IS DISTINCT FROM link.revision THEN
    RETURN '{"error":"connection_changed"}'::jsonb;
  END IF;
  IF action = 'validate' THEN
    RETURN jsonb_build_object('ok',true);
  ELSIF action = 'store' THEN
    IF payload->>'ciphertext' IS NULL OR octet_length(payload->>'ciphertext') NOT BETWEEN 32 AND 32768 THEN
      RAISE EXCEPTION 'invalid grant';
    END IF;
    UPDATE bound_dropbox_private.links SET ciphertext = payload->>'ciphertext', revision = gen_random_uuid()
      WHERE owner = target RETURNING revision INTO link.revision;
    RETURN jsonb_build_object('ok',true,'revision',link.revision);
  ELSIF action IN ('unlink','invalidate') THEN
    -- Keep a tombstone revision so concurrent link/refresh requests cannot restore it.
    UPDATE bound_dropbox_private.links SET ciphertext = NULL, revision = gen_random_uuid() WHERE owner = target;
    RETURN jsonb_build_object('ok',true,'ciphertext',link.ciphertext);
  END IF;
  RAISE EXCEPTION 'invalid operation';
END $$;
REVOKE ALL ON FUNCTION bound_dropbox_private.grant_operation(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA bound_dropbox_private TO service_role;
GRANT EXECUTE ON FUNCTION bound_dropbox_private.grant_operation(text,jsonb) TO service_role;
-- Only this invoker wrapper is in the exposed schema. Ownership and live session
-- checks are mandatory inside the private definer; no user-supplied owner enters it.
CREATE FUNCTION public.bound_dropbox_grant(action text, payload jsonb)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$
  SELECT bound_dropbox_private.grant_operation(action,payload)
$$;
REVOKE ALL ON FUNCTION public.bound_dropbox_grant(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bound_dropbox_grant(text,jsonb) TO service_role;
COMMIT;
