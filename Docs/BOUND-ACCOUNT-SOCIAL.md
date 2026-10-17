# Bound account social features

These additions require **Enable Experimental Features**. Build 13 keeps its
existing friend, moderation, sharing-token and deletion endpoints. The new
`bound_social_v2` RPC adds friends by an exact, case-insensitive account username.
It delegates existing actions to `bound_social_v1`; both the Build 13
`cup050_friends` RPC and the sharing-token/deletion services keep their contracts.
New friendships use the same rooms, so older clients can list and share with
friends added by username. The original invite-code UI remains available with
experimental features off, and its backend endpoints remain available.

Account usernames are unique after trimming surrounding spaces and ignoring
capitalization. Signup checks availability, and an opt-in Auth insert trigger
claims the name in the same transaction as account creation. A unique database
index enforces the rule for concurrent signup and rename attempts. The trigger
only applies when signup sends `data.bound_username_v1`; Build 13's original
email/password-only signup does not enter the new username path. Existing
account usernames are preserved. Older display names can seed a profile, with a
unique fallback if another account already owns that name.

The availability endpoint returns only an exact-name availability result. There
is no username directory or partial-name search. Adding a friend still checks
account eligibility, blocks, suspensions, deletion state, quotas and both
accounts' friend limits. Adding does not start sharing; tapping the saved friend
starts sharing. Account username changes update the account profile, existing
friend labels and outstanding invitations, so the Build 13 list also sees them.

Change the username in Library Settings → Bound account → Username. An open
Friends screen refreshes profile names every 30 seconds and on reopening.
Remove Friend ends the relationship and stops selected sharing. Adding the
friend again can be done by username, or by invitation in the original flow. Block and Report retain their existing
backend validation and semantics.

Sharing that was active before the app entered the background is restored when
the game returns to the foreground. Restoration refreshes account credentials,
obtains a fresh server-issued room lease and retries transient failures with
backoff. A manual stop, account or room change, friend removal, or experimental
opt-out cancels this intent. A cold launch does not independently start sharing.

## Jiggles

The Friends action sends **[Sender's username] wants to play.** to the friend's
opted-in devices. Enable reception in Library Settings → Receive Jiggles.
Notifications use the default sound and normal iOS notification vibration;
Focus, silent mode and the user's notification settings remain in control.
Foreground delivery adds notification haptics and checks the current recipient.

The new `bound-jiggle` Edge Function authenticates the caller with Supabase Auth.
Its service-only RPC checks current account status, friendship, blocks and
suspensions. Requests are idempotent, limited to one per pair per minute and
20 per sender per hour. Tokens stay in a private schema, with at most five
active devices per account. Account deletion cascades through the new tables.
Registration revisions prevent delayed device uploads from undoing revocation.

The Edge Function accepts either a generic APNs key tuple or environment-specific
tuples in Supabase secrets. For separate topic-scoped keys, configure all three
of `BOUND_APNS_SANDBOX_KEY_ID`, `BOUND_APNS_SANDBOX_TEAM_ID` and
`BOUND_APNS_SANDBOX_PRIVATE_KEY` for sandbox, and all three of
`BOUND_APNS_PRODUCTION_KEY_ID`, `BOUND_APNS_PRODUCTION_TEAM_ID` and
`BOUND_APNS_PRODUCTION_PRIVATE_KEY` for production. Each tuple must be complete;
a partial tuple disables that environment and does not fall back to the generic
key. The legacy `BOUND_APNS_KEY_ID`, `BOUND_APNS_TEAM_ID` and
`BOUND_APNS_PRIVATE_KEY` tuple remains supported as a fallback for environments
without an environment-specific tuple. Use APNs authentication keys for Bound's
Apple team and push-enabled App ID `com.evanvonessen.bound`. Do not put private
keys in source control. The handler uses existing project-provided
`SUPABASE_SERVICE_ROLE_KEY` and `CUPCAKE_SUPABASE_PUBLISHABLE_KEY` secrets.
Its platform JWT verifier is disabled because the handler verifies the bearer
token through Auth itself before dispatch. Missing APNs setup returns an
explicit `not_configured` result before reserving a request when no key is
configured. If a recipient has a registered device in an unconfigured
environment, the handler finishes the already-reserved job with whether any
other device accepted the alert, and returns `not_configured`. It never sends
the unconfigured device through the other environment's APNs endpoint or reports
the request as sent.

The app entitlement resolves to development for Debug and production for Release.
The signing profile must also support push. APNs acceptance alone does not prove
the receiving device displayed a notification, played a sound or vibrated.
Those checks require signed builds and two authorized test devices/accounts.

## Validation boundary

On 2026-10-17, the username migration was deployed and passed the live rollback
smoke for username adding and Build 13's original invite-code endpoints. Existing
profile data, Auth account count, legacy service definitions and Edge Function
versions/bundles were preserved. The 25 focused native integration checks, the
signup UI check with experiments both on and off, and the Release iPhone build
passed. These checks used synthetic native credentials and disposable SQL rows;
email delivery and two-device gameplay sharing were not retested in this change.

On 2026-10-15, `bound-jiggle` version 3 was deployed with separate production
and sandbox APNs keys restricted to `com.evanvonessen.bound`. Both complete
credential tuples are stored in Supabase secrets; their saved digests match the
downloaded keys. Protected local backups are outside the repository. Push
Notifications is enabled on Bound's Apple App ID. Existing provisioning profiles
must be refreshed for future signed builds to include that capability.

The 15 mocked handler tests pass, both downloaded P-256 keys generate locally
verified ES256 signatures, and the deployed endpoint rejects unauthenticated
requests with 401. The deployed files match the reviewed source. Existing
sharing/account Edge Functions and database function definitions were unchanged
by this setup. No authenticated friend notification or physical-device delivery,
sound, or vibration check has been performed; those require test accounts and
devices with a push-enabled signed build.

`Backend/social` contains disposable SQL contracts, a diagnostic snapshot of the
legacy friend RPCs, a rollback-only deployed smoke check and mocked APNs handler
tests. Native integration tests use synthetic credentials and transports. These
checks establish model, authorization, compatibility and request behavior; real
device APNs and provider OAuth testing are separate steps. Dropbox setup and
verification requirements are in `Docs/BOUND-CLOUD-SYNC.md`; Google Drive is hidden.
