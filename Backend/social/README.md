# Bound social backend

The three `supabase/migrations` files were deployed to Bound on 2026-10-15. They add persistent account usernames, private APNs registration, service-only Jiggle dispatch/finish RPCs, registration revision fences and an ownership index. All 45 captured legacy database function definitions and both legacy Edge Function versions/bundle hashes remained unchanged.

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

The fixture defines disposable auth users and a minimal legacy RPC only; it never contacts Supabase. The main contract applies all three migrations and exercises revision ordering/tombstones, account-switch revocation safety, and the per-account 20-installation fence cap. The test records and checks the fixture legacy RPC definition hash around migration application. Hosted checks are recorded separately from this local contract.

A second integration pass replays the committed diagnostic snapshot in `live-legacy-functions.fixture.sql`. It was captured on 2026-10-15 14:17:09 PDT from a read-only export; the file header records the source SHA-256 and the catalog definition MD5 hashes. It is normalized for local `psql` replay and is explicitly test input, not a migration. No `.build` snapshot or network access is required. The test adds only response-shaping moderation helper stubs needed by the captured wrapper body.

The pass exercises real invite hashes/codes, counters/quotas, room creation/listing/removal, and migration response compatibility. A minimal `bound_moderation_private.action` stub only allows the saved wrapper body to compile; this pass does not claim to retest moderation behavior:

```sh
/opt/homebrew/bin/dropdb -h /Users/admin/developer/bound/.build/friend-social-validation/socket -p 54883 bound_social_test
/opt/homebrew/bin/createdb -h /Users/admin/developer/bound/.build/friend-social-validation/socket -p 54883 bound_social_test
/opt/homebrew/bin/psql -X -v ON_ERROR_STOP=1 -h /Users/admin/developer/bound/.build/friend-social-validation/socket -p 54883 -d bound_social_test -f Backend/social/live-legacy-contract.test.sql
```

The snapshot is a local input file, not generated or changed by the test. Queue idempotency records are retained for 30 days; older completed or abandoned queue rows are purged during dispatch. Neither test path connects to the hosted project.
