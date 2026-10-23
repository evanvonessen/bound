-- Plain PostgreSQL business data. Nakama remains the only identity authority.
-- These compatibility views contain no passwords, credentials, or independent
-- account lifecycle. Only trusted gateway transactions set request.jwt.claims.
DO $$ DECLARE role_name text; BEGIN
  FOREACH role_name IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
    IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=role_name) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN',role_name);
    END IF;
  END LOOP;
END $$;
CREATE SCHEMA auth;
REVOKE ALL ON SCHEMA auth FROM PUBLIC;
CREATE SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb
$$;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT (auth.jwt()->>'sub')::uuid $$;
CREATE VIEW auth.users AS SELECT id,email,
  CASE WHEN disable_time>to_timestamp(0) THEN disable_time ELSE NULL END AS deleted_at,
  false AS is_anonymous,
  nullif(metadata->>'bound_email_confirmed_at','')::timestamptz AS email_confirmed_at,
  metadata AS raw_user_meta_data
FROM public.users WHERE id<>'00000000-0000-0000-0000-000000000000';
CREATE VIEW auth.sessions AS SELECT key::uuid AS id,user_id,
  to_timestamp((value->>'expiresAt')::bigint) AS not_after
FROM public.storage WHERE collection='bound_auth_sessions_v1'
  AND key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND coalesce((value->>'revoked')::boolean,false)=false;
CREATE VIEW auth.mfa_factors AS SELECT key::uuid AS id,user_id,value->>'status' AS status
FROM public.storage WHERE collection='bound_auth_factors_v1'
  AND key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
GRANT USAGE ON SCHEMA auth TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION auth.uid(),auth.jwt() TO authenticated,service_role;

CREATE SCHEMA cup117_private;
REVOKE ALL ON SCHEMA cup117_private FROM PUBLIC,anon,authenticated;
CREATE TABLE cup117_private.deletions(owner uuid PRIMARY KEY,complete boolean NOT NULL DEFAULT false);
CREATE FUNCTION cup117_private.assert_active(actor uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN
  PERFORM pg_advisory_xact_lock_shared(11720260925);
  IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=actor AND deleted_at IS NULL)
    OR EXISTS(SELECT 1 FROM cup117_private.deletions WHERE owner=actor) THEN
    RAISE EXCEPTION 'account unavailable' USING errcode='42501';
  END IF;
END $$;
CREATE FUNCTION public.cup117_account_active() RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN
  PERFORM cup117_private.assert_active(auth.uid()); RETURN true;
EXCEPTION WHEN insufficient_privilege THEN RETURN false; END $$;
CREATE FUNCTION public.bound_require_mfa() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN
  IF auth.uid() IS NULL OR (coalesce(auth.jwt()->>'aal','aal1')<>'aal2'
      AND EXISTS(SELECT 1 FROM auth.mfa_factors WHERE user_id=auth.uid() AND status='verified')) THEN
    RAISE EXCEPTION 'second_factor_required' USING errcode='42501';
  END IF;
END $$;
CREATE FUNCTION public.bound_account_mfa_allowed() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT auth.uid() IS NOT NULL AND (coalesce(auth.jwt()->>'aal','aal1')='aal2'
    OR NOT EXISTS(SELECT 1 FROM auth.mfa_factors WHERE user_id=auth.uid() AND status='verified'))
$$;
CREATE SCHEMA cup050_private;
REVOKE ALL ON SCHEMA cup050_private FROM PUBLIC,anon,authenticated;
CREATE TABLE cup050_private.rooms(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_a uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  owner_b uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  name_a text NOT NULL,name_b text NOT NULL,active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK(owner_a<>owner_b));
CREATE INDEX ON cup050_private.rooms(owner_a) WHERE active;
CREATE INDEX ON cup050_private.rooms(owner_b) WHERE active;
CREATE TABLE cup050_private.invites(digest bytea PRIMARY KEY,
  creator uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  display_name text NOT NULL,expires_at timestamptz NOT NULL,consumed boolean NOT NULL DEFAULT false);
CREATE TABLE cup050_private.limits(owner uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  window_start timestamptz NOT NULL,requests integer NOT NULL DEFAULT 0,
  creates integer NOT NULL DEFAULT 0,guesses integer NOT NULL DEFAULT 0);

CREATE SCHEMA bound_files_private;
REVOKE ALL ON SCHEMA bound_files_private FROM PUBLIC,anon,authenticated;
-- Keep transfer records after account deletion until cleanup removes the bytes.
CREATE TABLE bound_files_private.transfers(id uuid PRIMARY KEY,
  owner uuid NOT NULL,room uuid REFERENCES cup050_private.rooms(id) ON DELETE SET NULL,
  shared boolean NOT NULL DEFAULT false,size bigint NOT NULL CHECK(size>0),
  sha256 text CHECK(sha256 ~ '^[a-f0-9]{64}$'),state text NOT NULL DEFAULT 'reserved'
    CHECK(state IN('reserved','uploading','ready')),
  created_at timestamptz NOT NULL DEFAULT now(),expires_at timestamptz NOT NULL);
CREATE INDEX ON bound_files_private.transfers(owner,expires_at);
CREATE INDEX ON bound_files_private.transfers(expires_at);
REVOKE ALL ON ALL TABLES IN SCHEMA bound_files_private FROM PUBLIC,anon,authenticated;
