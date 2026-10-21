-- Apply transactionally before deploying change-account-email. This contract
-- does not alter auth.users, Auth triggers, or global confirmation settings.
BEGIN;
CREATE SCHEMA bound_account_email_private;
REVOKE ALL ON SCHEMA bound_account_email_private FROM PUBLIC, anon, authenticated;
CREATE TABLE bound_account_email_private.operations (
  owner uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  operation uuid,
  session_id uuid,
  old_email text,
  new_email text,
  expires_at timestamptz,
  window_start timestamptz NOT NULL DEFAULT now(),
  attempts integer NOT NULL DEFAULT 0
);
ALTER TABLE bound_account_email_private.operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON bound_account_email_private.operations FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION bound_account_email_private.email_operation(action text, payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' SET lock_timeout = '5s' AS $$
DECLARE target uuid := (payload->>'owner')::uuid;
  caller_session uuid := (payload->>'session')::uuid;
  entry bound_account_email_private.operations%rowtype;
  current_email text;
BEGIN
  IF coalesce(auth.jwt()->>'role','') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  -- Coordinates checks with the existing deletion contract. The HTTP Auth
  -- update remains a separate transaction; see README for the in-flight limit.
  PERFORM pg_advisory_xact_lock_shared(11720260925);
  IF action = 'release' THEN
    UPDATE bound_account_email_private.operations
      SET operation=NULL,session_id=NULL,old_email=NULL,new_email=NULL,expires_at=NULL
      WHERE owner=target AND operation=(payload->>'operation')::uuid AND session_id=caller_session;
    RETURN '{"ok":true}'::jsonb;
  END IF;
  SELECT lower(btrim(u.email,E' \t\r\n')) INTO current_email FROM auth.users u
    JOIN auth.sessions s ON s.user_id=u.id
    WHERE u.id=target AND s.id=caller_session AND u.deleted_at IS NULL
    AND u.is_anonymous=false AND u.email_confirmed_at IS NOT NULL
    AND (s.not_after IS NULL OR s.not_after>now());
  IF current_email IS NULL OR EXISTS (SELECT 1 FROM cup117_private.deletions WHERE owner=target) THEN
    RETURN '{"error":"unauthorized"}'::jsonb;
  END IF;
  IF current_email IS DISTINCT FROM payload->>'email' THEN
    RETURN '{"error":"account_changed"}'::jsonb;
  END IF;
  IF action NOT IN ('begin','validate') OR payload->>'newEmail' IS NULL
      OR octet_length(payload->>'newEmail') NOT BETWEEN 3 AND 254 THEN
    RAISE EXCEPTION 'invalid operation';
  END IF;
  INSERT INTO bound_account_email_private.operations(owner) VALUES(target) ON CONFLICT DO NOTHING;
  SELECT * INTO entry FROM bound_account_email_private.operations WHERE owner=target FOR UPDATE;
  IF action = 'begin' THEN
    IF entry.expires_at>now() THEN RETURN '{"error":"change_in_progress"}'::jsonb; END IF;
    IF entry.window_start<now()-interval '15 minutes' THEN
      UPDATE bound_account_email_private.operations SET window_start=now(),attempts=1 WHERE owner=target;
    ELSIF entry.attempts>=5 THEN RETURN '{"error":"rate_limited"}'::jsonb;
    ELSE UPDATE bound_account_email_private.operations SET attempts=attempts+1 WHERE owner=target;
    END IF;
    UPDATE bound_account_email_private.operations SET operation=gen_random_uuid(),
      session_id=caller_session,old_email=current_email,new_email=payload->>'newEmail',
      expires_at=now()+interval '2 minutes' WHERE owner=target RETURNING * INTO entry;
    RETURN jsonb_build_object('ok',true,'operation',entry.operation);
  END IF;
  IF entry.operation IS DISTINCT FROM (payload->>'operation')::uuid OR entry.session_id IS DISTINCT FROM caller_session
      OR entry.old_email IS DISTINCT FROM current_email OR entry.new_email IS DISTINCT FROM payload->>'newEmail'
      OR entry.expires_at IS NULL OR entry.expires_at<=now() THEN
    RETURN '{"error":"account_changed"}'::jsonb;
  END IF;
  RETURN '{"ok":true}'::jsonb;
END $$;
REVOKE ALL ON FUNCTION bound_account_email_private.email_operation(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA bound_account_email_private TO service_role;
GRANT EXECUTE ON FUNCTION bound_account_email_private.email_operation(text,jsonb) TO service_role;
CREATE FUNCTION public.bound_account_email(action text,payload jsonb)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path = '' AS $$
  SELECT bound_account_email_private.email_operation(action,payload)
$$;
REVOKE ALL ON FUNCTION public.bound_account_email(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bound_account_email(text,jsonb) TO service_role;
COMMIT;
