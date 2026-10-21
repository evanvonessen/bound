-- Retains account factors. Do not roll back enforcement while presenting MFA
-- as protection to enrolled users; disable enrollment in the released app first.
BEGIN;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_db_role_setting r, unnest(r.setconfig) setting
      WHERE r.setrole=(SELECT oid FROM pg_roles WHERE rolname='authenticator')
      AND r.setdatabase=0 AND setting='pgrst.db_pre_request=public.bound_require_mfa')
    OR EXISTS (SELECT 1 FROM pg_db_role_setting r, unnest(r.setconfig) setting
      WHERE r.setrole IN (0,(SELECT oid FROM pg_roles WHERE rolname='authenticator'))
      AND r.setdatabase IN (0,(SELECT oid FROM pg_database WHERE datname=current_database()))
      AND setting LIKE 'pgrst.db_pre_request=%'
      AND NOT (r.setrole=(SELECT oid FROM pg_roles WHERE rolname='authenticator')
        AND r.setdatabase=0 AND setting='pgrst.db_pre_request=public.bound_require_mfa')) THEN
    RAISE EXCEPTION 'Pre-request configuration changed; review before rollback';
  END IF;
END $$;
ALTER ROLE authenticator RESET pgrst.db_pre_request;
DROP POLICY bound_account_mfa_guard ON storage.objects;
DROP POLICY bound_account_mfa_guard ON public.cup040_catalogue;
DROP POLICY bound_account_mfa_guard ON public.bound_note_revisions;
DROP POLICY bound_account_mfa_guard ON public.bound_autosave_revisions;
DROP POLICY bound_account_mfa_guard ON public.bound_roms;
DROP FUNCTION public.bound_require_mfa();
DROP FUNCTION public.bound_account_mfa_allowed();
DROP FUNCTION bound_auth_private.mfa_allowed();
DROP SCHEMA bound_auth_private;
NOTIFY pgrst, 'reload config';
NOTIFY pgrst, 'reload schema';
COMMIT;
