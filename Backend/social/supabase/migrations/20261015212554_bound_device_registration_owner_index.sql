-- Support per-owner registration-fence quotas and auth.users ON DELETE CASCADE.
BEGIN;
CREATE INDEX registration_fences_owner_idx
  ON bound_social_private.registration_fences(owner);
COMMIT;
