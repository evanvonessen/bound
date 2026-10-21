# Bound account-linked Dropbox

`bound-dropbox` is a server token broker. A confirmed, non-anonymous Bound user
connects Dropbox once using the existing native PKCE consent flow. The code and
verifier are exchanged on the server. Only short-lived Dropbox access tokens and
expiry durations are returned to devices. ROM/save traffic still goes directly
to Dropbox using the existing Harmony backend and dependency pins.

Refresh tokens are AES-256-GCM encrypted with a random nonce and authenticated
owner/app context. The independent encryption key belongs only in Edge Function
secrets. Database rows, backups and the Data API never contain plaintext refresh
tokens. The private table has RLS and no client grants; the exposed invoker RPC is
executable only by service_role and forwards to a private definer with explicit
role, live Auth session, confirmed user and account-deletion checks. No request
can choose an owner; the handler derives it from Auth's verified bearer identity.
Never log request bodies, JWTs, codes, verifiers, tokens, upstream error bodies or
server keys. Retain platform request metadata only.

Every grant operation takes the existing deletion contract's shared advisory
lock and checks its deletion marker. Auth deletion cascades to erase the encrypted
grant. Unlink uses revision tombstones; racing link/token requests cannot restore
a removed connection or deliver a token after a failed final validation. Invalid
refresh grants are removed, while network and upstream service failures retain
the connection. Up to 120 broker database operations per owner/minute are allowed.

## Deployment and activation

Target: `qevnxhngdtlyihhmvnjv`. Preserve existing functions and Auth settings.

1. Apply `contract.sql` transactionally via a migration after checking that
   `auth.sessions.not_after` and `cup117_private.deletions` match the contract.
   The script intentionally fails on pre-existing objects; review a partial or
   prior deployment rather than dropping/replacing its data.
2. Configure Edge Function secrets: existing `SUPABASE_SERVICE_ROLE_KEY` and
   `CUPCAKE_SUPABASE_PUBLISHABLE_KEY`, plus `BOUND_DROPBOX_APP_KEY` matching the
   app's existing Full Dropbox app, and `BOUND_DROPBOX_ENCRYPTION_KEY` containing
   base64 of 32 cryptographically random bytes. Never put this key in the app,
   repository, shell command arguments, build settings or logs. Use a secure
   secret-management channel. Keep a recoverable protected copy: losing it means
   users must reconnect. Rotation requires decrypting/re-encrypting existing rows
   with both keys; replacing the key alone breaks existing connections.
3. Deploy `index.ts` and `handler.mjs` as `bound-dropbox`, `verify_jwt=false`.
   The handler validates the exact bearer token with Auth getUser and checks its
   `session_id` against `auth.sessions` on every database operation. Missing
   configuration fails closed with 503. No new Dropbox app secret is needed.
4. Run database security advisors and two-device QA with an explicitly owned test
   account: connect on A, sign into the same Bound account on B and enable
   Dropbox sync without new consent, disconnect A, restore A, switch A to another
   Bound account, unlink everywhere, revoke Dropbox approval, and delete the QA
   Bound account. Verify cloud save restore and no cross-account token use.
5. Release the updated app after backend verification. The prior native-only
   build cannot restore this connection; its device-only token is not migrated.

The private contract and `bound-dropbox` v1 were deployed on 2026-10-21. The user
completed the server-key setup through the signed-in Supabase dashboard on the
same date. A credential-free live POST then returned the expected
`401 unauthorized`, replacing the prior `503 not_configured`: startup
configuration is accepted and authentication remains required. The public app
key is `qky6pxxx8ks3d2k`. No secret values were read, logged or added to source.
An unauthenticated probe alone does not establish successful Dropbox linking or
file transfer. The native link and two-device acceptance below subsequently
passed against the deployed service.

## User behavior and limits

- **Connect Dropbox** requires Bound sign-in. An existing linked grant is restored
  silently. Otherwise Dropbox consent explicitly attaches the connection to the
  currently signed-in Bound account. Existing native-only users reconnect once;
  their old credential is never silently associated with an arbitrary account.
- **Disconnect This Device** / disable sync clears local authorization and Harmony
  metadata while retaining the account link. Re-enable sync to restore access.
- **Unlink Dropbox Everywhere** disconnects this device first, deletes the server
  grant and attempts Dropbox revocation. Files and local games remain intact.
  Network failures during revocation do not restore the deleted grant. Other
  devices may finish requests using already-issued access tokens until Dropbox
  rejects them or they expire; unlink cannot roll back writes already accepted.
- Bound sign-out synchronously prevents new sync, cancels pending OAuth/token
  callbacks and drains existing sync before clearing Harmony's old account state.
  Account switches and cold starts reset Harmony metadata when the Bound owner
  changes. Sign-out also persists a device pause without erasing the saved provider
  choice; signing into another Bound account cannot automatically upload the local
  library. The user explicitly re-enables sync. No Dropbox refresh credential is
  kept on the device.
- The local game library is shared by the installation, as before. Switching
  Bound accounts keeps local games/saves; enabling sync on the other account can
  upload those local games. This change isolates credentials and sync metadata,
  not local libraries.
- Per-device sync enable/disable remains a local preference. On a fresh device,
  sign into Bound and enable Dropbox sync; no Dropbox consent is needed for an
  existing account link. Revoked/invalid credentials require consent again.
- The first new access-token request needs the Bound backend. Local offline
  gameplay remains available. Account deletion removes the stored connection;
  it does not delete Dropbox files or remove Dropbox's app permission entry.
- Temporary broker/network failures, service configuration failures, rate limits
  and pending second-factor sign-in retain Harmony's sync history for retry.
  Cached account metadata alone does not count as an authenticated connection:
  the settings screen offers **Connect Dropbox** again when authorization fails.
  Successful connection starts sync immediately. Deauthentication replaces the
  provider hook for subsequent retries while previously retained callbacks remain
  fenced by their original generation.

## Local checks

- `node --test Backend/dropbox-link/handler.test.mjs` (injected fetch, synthetic
  credentials): encrypted storage, owner/app/key tampering, link and device
  restore, verified identity, malformed requests, session/deletion rejection,
  unlink races, upstream errors, no secret-bearing responses, and revocation.
- `contract.test.mjs` executes the actual SQL in disposable PostgreSQL using
  `@electric-sql/pglite@0.5.10`. Set `PGLITE_MODULE` to its installed `dist/index.js`
  file URL, then run `node --test Backend/dropbox-link/contract.test.mjs`.
  It checks client denial, owner/session isolation, revision fences, revoked and
  expired sessions, deletion markers, rate limiting and FK deletion cleanup.
- Native `BoundDropboxOAuthTests` use injected account storage and transport to
  exercise restore, sign-out, cancellation, late-token fencing, unlink and errors.
  Regression cases also cover recovery after missing server configuration,
  preservation of sync history for retryable failures, rate limiting and MFA.
  No live credentials or one-use Keychain fixture is required.
- Build ordinary `Bound.xcodeproj` / `Bound`, Release, generic iOS destination.
  Simulator checks do not establish physical-device/network or playback parity.

## Real account-linked acceptance

Build `BoundIntegrationQA` for testing, and install the normal Bound app on two
fresh simulators named `Bound Dropbox QA A` and `Bound Dropbox QA B`. Sign in to
the same confirmed Bound account separately on each, completing MFA if enabled.
Leave Delta Sync disabled; the test refuses an existing library or active sync.
Use recent sign-ins with at least 30 minutes remaining on each access session.

```sh
python3 PrototypeTools/live-dropbox-sync.py --xctestrun <built.xctestrun> \
  --sim-a <A-UUID> --link-only --output .build/dropbox-live/link
python3 PrototypeTools/live-dropbox-sync.py --xctestrun <built.xctestrun> \
  --sim-a <A-UUID> --sim-b <B-UUID> --pair --output .build/dropbox-live/pair
```

The first phase uses native consent and the real broker without starting Harmony
or transferring files. Complete the account's Dropbox consent on A. The paired
phase uses background authentication on both installations: A uploads a generated
diagnostic ROM and 128 KiB battery save, B restores both byte-for-byte and updates
the save, and A restores the changed bytes. It requires matching Bound owners
and Dropbox connection IDs with distinct Auth session IDs, silent reconnect,
and denial after signing out an in-memory account copy.

Fixtures contain only one-use test metadata. Native sessions stay in each
device's Keychain; credentials never enter the coordinator, relay or report.
The tests use a uniquely named empty QA folder and separate Harmony metadata,
then remove only generated records and that folder. They preserve the account
link, normal saved sessions and ordinary sync history. The coordinator writes
redacted summaries under ignored `.build`; absent fixtures skip both native live
tests before reading accounts or contacting the network. Do not interpret those
skips as live acceptance. Two simulators share this Mac's network and do not
establish physical-device or independent-network behavior.

### Live validation — October 21, 2026

- Native Dropbox sign-in/consent and PKCE exchange through `bound-dropbox` passed
  on A. A read-only aggregate check found one active AES-GCM v1 encrypted link;
  neither plaintext refresh tokens nor encryption keys were read.
- The paired test passed on both independent native installations: same Bound
  owner, distinct Auth sessions, same Dropbox connection. B restored the
  generated ROM and 128 KiB save byte-for-byte without another consent flow;
  B uploaded different generated save bytes and A restored them exactly.
- Both devices passed device-disconnect/silent-reconnect and rejection after
  signing out an in-memory account copy. Their normal saved Bound sessions were
  unchanged. Generated records and the unique QA folder were removed; the real
  account link remains available for normal app use.
- The first pair completed file transfer but exposed a test-only asynchronous
  teardown/reconnect race. The handler now completes cancellation synchronously;
  the repeated full run passed with all assertions retained.
- Evidence: `.build/dropbox-live/native-link-1/` and
  `.build/dropbox-live/pair-2/summary.json` plus each device's `.xcresult`.
  Neither run skipped its live case. The ordinary regression run separately
  passed 16 native cases and intentionally skipped the two opt-in live cases;
  22 broker tests, the real SQL contract and an unsigned Release iPhone build
  also passed. All 17,061 pinned source files verified.
- This proves the account-linked broker and Harmony transfer paths on two
  simulators over the Mac's real network. Physical phones, independent networks,
  all app navigation and public Dropbox production availability were not tested.

### Historical implementation validation

- 20 handler tests passed; the real SQL contract passed in disposable PostgreSQL
  (PGlite), including client permission denial, session/owner fences and deletion.
- 17 focused iOS integration tests passed (13 Dropbox OAuth/broker tests and
  4 account-persistence tests), using an isolated simulator and ad-hoc signing.
  Result: `.build/dropbox-link/final-tests.xcresult`; log:
  `.build/dropbox-link/final-native-tests.log`. The temporary simulator was removed.
- The final unsigned Release iPhone build passed through `Bound.xcodeproj` / Bound.
  Log: `.build/dropbox-link/final-release.log`.
- All 17,061 pinned source files passed integrity verification; dependency pins,
  patches and upstream module identities were preserved. `git diff --check` passed.
- The separate `swift test --package-path PrototypeTests` harness could not build
  because its existing model target does not include `BoundSocialAPI` and
  `BoundSocialError`, which the unchanged social-account methods reference. The
  native account-persistence suite above passed. No unrelated harness changes were
  made to hide this limitation.
- Current combined validation is recorded in `../account-security/README.md`.
  These historical checks did not exercise real Dropbox consent, two-device
  account-linked save restore or physical iPhone/network behavior.
  Existing build 12 native-only credentials and endpoints were left intact.
