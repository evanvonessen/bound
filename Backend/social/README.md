# Bound social backend

The initial three `supabase/migrations` files were deployed to Bound on 2026-10-15. They add persistent account usernames, private APNs registration, service-only Jiggle dispatch/finish RPCs, registration revision fences and an ownership index. All 45 captured legacy database function definitions and both legacy Edge Function versions/bundle hashes remained unchanged.

`20261017201648_bound_username_friends_v2.sql` adds exact, case-insensitive username lookup, a unique profile-name index and an opt-in signup claim. The signup trigger returns immediately when `bound_username_v1` is absent, preserving Build 13's email/password signup. The new `bound_social_v2` endpoint delegates existing actions to the unchanged v1 endpoint and creates username-added friendships in the same legacy room table. Its only replacement function is the post-Build-13 `ensure_profile` helper, which preserves existing profiles and assigns an available fallback when an old display name is already claimed. Before deployment, check that existing profiles have no duplicate `lower(btrim(username))` values; the migration intentionally fails rather than renaming existing accounts.

The username migration was deployed on 2026-10-17 as version `20261017201648`. All 48 other pre-existing database function definitions, including Build 13's friend, save-sync and account-deletion functions, remained unchanged. All three Edge Function versions/bundle hashes were unchanged. Existing profile contents and the Auth account count matched their pre-deployment snapshots after the rollback smoke. The deployed smoke passed username add/idempotency, opt-out signup, device registration ordering, rename propagation, and the direct Build 13 invite/list/room/remove lifecycle. Anonymous HTTP availability and invalid-name checks passed, and the security advisor findings were unchanged. No permanent fixture account or relationship was created. This establishes backend compatibility; it does not claim a new physical-device or App Review test.

`live-smoke.rollback.sql` runs isolated fixture operations against deployed functions and rolls them back. It verified profile seeding, invite/accept, username propagation through the legacy list endpoint, room authorization/removal, privileges and device registration ordering. It creates no permanent test accounts and establishes SQL behavior, not native sign-in or APNs delivery.

`index.ts` and `handler.mjs` are the new `bound-jiggle` Edge Function. It verifies caller tokens with Supabase Auth; platform JWT verification is intentionally disabled for this function only. APNs supports separate sandbox and production key tuples, with the legacy generic tuple as a fallback; setup and device verification requirements are in `Docs/BOUND-ACCOUNT-SOCIAL.md`. A recipient device without a configured environment key is not sent through the other APNs environment and the request is returned as `not_configured`. The live endpoint rejects an invalid identity with 401. No real push notification was sent during automated validation.

`bound-jiggle` version 3 was deployed on 2026-10-15 for the separately scoped Bound production and sandbox APNs keys. Both complete environment-specific tuples are configured in Supabase secrets. Their digests match the downloaded key material, and local ES256 signature verification passes for both keys. The 15 mocked handler checks pass. This deployment changed only `bound-jiggle`; the existing `agora-token` and `delete-account` versions/bundles and the inspected SQL definitions remained unchanged. Device delivery still requires a refreshed push-enabled signing profile and authorized test accounts/devices.

Run the contract against a disposable local PostgreSQL instance from the repository root:

```sh
mkdir -p .build/friend-social-validation/pgdata .build/friend-social-validation/socket
/opt/homebrew/bin/initdb -D .build/friend-social-validation/pgdata -A trust --no-locale -E UTF8
/opt/homebrew/bin/pg_ctl -D .build/friend-social-validation/pgdata \
  -l .build/friend-social-validation/postgres.log \
  -o "-c listen_addresses='' -c unix_socket_directories='/Users/admin/developer/bound/.build/friend-social-validation/socket' -p 54883" start
/opt/homebrew/bin/createdb -h /Users/admin/developer/bound/.build/friend-social-validation/socket -p 54883 bound_social_test
/opt/homebrew/bin/psql -X -v ON_ERROR_STOP=1 -h /Users/admin/developer/bound/.build/friend-social-validation/socket -p 54883 -d bound_social_test -f Backend/social/local-fixture.sql
/opt/homebrew/bin/psql -X -v ON_ERROR_STOP=1 -h /Users/admin/developer/bound/.build/friend-social-validation/socket -p 54883 -d bound_social_test -f Backend/social/contract.test.sql
/opt/homebrew/bin/pg_ctl -D .build/friend-social-validation/pgdata stop
```

The fixture defines disposable auth users and a minimal legacy RPC only; it never contacts Supabase. The main contract applies all four migrations and exercises username claims/lookup, duplicate signup rollback, legacy signup passthrough, role grants, revision ordering/tombstones, account-switch revocation safety, and the per-account 20-installation fence cap. The test records and checks the fixture legacy RPC definition hash around migration application. Hosted checks are recorded separately from this local contract.

A second integration pass replays the committed diagnostic snapshot in `live-legacy-functions.fixture.sql`. It was captured on 2026-10-15 14:17:09 PDT from a read-only export; the file header records the source SHA-256 and the catalog definition MD5 hashes. It is normalized for local `psql` replay and is explicitly test input, not a migration. No `.build` snapshot or network access is required. The test adds only response-shaping moderation helper stubs needed by the captured wrapper body.

The pass exercises real invite hashes/codes, counters/quotas, room creation/listing/removal, and migration response compatibility. A minimal `bound_moderation_private.action` stub only allows the saved wrapper body to compile; this pass does not claim to retest moderation behavior:

```sh
/opt/homebrew/bin/dropdb -h /Users/admin/developer/bound/.build/friend-social-validation/socket -p 54883 bound_social_test
/opt/homebrew/bin/createdb -h /Users/admin/developer/bound/.build/friend-social-validation/socket -p 54883 bound_social_test
/opt/homebrew/bin/psql -X -v ON_ERROR_STOP=1 -h /Users/admin/developer/bound/.build/friend-social-validation/socket -p 54883 -d bound_social_test -f Backend/social/live-legacy-contract.test.sql
```

The snapshot is a local input file, not generated or changed by the test. Queue idempotency records are retained for 30 days; older completed or abandoned queue rows are purged during dispatch. Neither test path connects to the hosted project.
