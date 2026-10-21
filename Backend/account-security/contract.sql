-- Additive MFA enforcement. Existing RPC signatures, bodies and permissive
-- policies remain intact. Only accounts with a verified factor require AAL2.
BEGIN;
CREATE SCHEMA bound_auth_private;
REVOKE ALL ON SCHEMA bound_auth_private FROM PUBLIC, anon, authenticated;
CREATE FUNCTION bound_auth_private.mfa_allowed()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT coalesce(auth.jwt()->>'role','') <> 'authenticated'
    OR (auth.uid() IS NOT NULL AND (
      coalesce(auth.jwt()->>'aal','aal1') = 'aal2'
      OR NOT EXISTS (SELECT 1 FROM auth.mfa_factors f
        WHERE f.user_id = auth.uid() AND f.status = 'verified')))
$$;
REVOKE ALL ON FUNCTION bound_auth_private.mfa_allowed() FROM PUBLIC;
GRANT USAGE ON SCHEMA bound_auth_private TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION bound_auth_private.mfa_allowed() TO anon, authenticated, service_role;
CREATE FUNCTION public.bound_account_mfa_allowed()
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
  SELECT bound_auth_private.mfa_allowed()
$$;
REVOKE ALL ON FUNCTION public.bound_account_mfa_allowed() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bound_account_mfa_allowed() TO anon, authenticated, service_role;
CREATE FUNCTION public.bound_require_mfa()
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF NOT public.bound_account_mfa_allowed() THEN
    RAISE EXCEPTION 'second_factor_required' USING ERRCODE = '42501';
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.bound_require_mfa() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bound_require_mfa() TO anon, authenticated, service_role;
-- Storage does not execute PostgREST's pre-request hook. A restrictive policy
-- composes with existing owner policies and grants no additional access.
CREATE POLICY bound_account_mfa_guard ON storage.objects AS RESTRICTIVE
  FOR ALL TO authenticated
  USING ((SELECT public.bound_account_mfa_allowed()))
  WITH CHECK ((SELECT public.bound_account_mfa_allowed()));
-- Realtime does not execute the REST hook either. Compose with existing owner
-- checks on every existing client-readable Bound catalogue/revision table.
CREATE POLICY bound_account_mfa_guard ON public.cup040_catalogue AS RESTRICTIVE
  FOR ALL TO authenticated USING ((SELECT public.bound_account_mfa_allowed()))
  WITH CHECK ((SELECT public.bound_account_mfa_allowed()));
CREATE POLICY bound_account_mfa_guard ON public.bound_note_revisions AS RESTRICTIVE
  FOR ALL TO authenticated USING ((SELECT public.bound_account_mfa_allowed()))
  WITH CHECK ((SELECT public.bound_account_mfa_allowed()));
CREATE POLICY bound_account_mfa_guard ON public.bound_autosave_revisions AS RESTRICTIVE
  FOR ALL TO authenticated USING ((SELECT public.bound_account_mfa_allowed()))
  WITH CHECK ((SELECT public.bound_account_mfa_allowed()));
CREATE POLICY bound_account_mfa_guard ON public.bound_roms AS RESTRICTIVE
  FOR ALL TO authenticated USING ((SELECT public.bound_account_mfa_allowed()))
  WITH CHECK ((SELECT public.bound_account_mfa_allowed()));
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_db_role_setting r, unnest(r.setconfig) setting
      WHERE r.setrole IN (0,(SELECT oid FROM pg_roles WHERE rolname='authenticator'))
      AND r.setdatabase IN (0,(SELECT oid FROM pg_database WHERE datname=current_database()))
      AND setting LIKE 'pgrst.db_pre_request=%') THEN
    RAISE EXCEPTION 'Existing pre-request hook; compose and review before deployment';
  END IF;
END $$;
ALTER ROLE authenticator SET pgrst.db_pre_request = 'public.bound_require_mfa';
NOTIFY pgrst, 'reload config';
NOTIFY pgrst, 'reload schema';
COMMIT;
