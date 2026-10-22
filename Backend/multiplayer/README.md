# Multiplayer run leases

The additive `bound_run_lease_v1(action, payload)` RPC grants one device permission
to advance one player's run. It is independent of ordinary friend video and
does not change ordinary friend or video APIs. The deployed extension also
anchors the last completed checkpoint and current shared history.

The authenticated caller's `auth.uid()` owns the lease; payloads cannot supply an
owner. The RPC checks the live Auth session, confirmed non-anonymous account and
account-deletion guard. A private, RLS-enabled table is inaccessible to client
roles. The public function is an invoker wrapper around a narrowly granted
private function with a fixed empty search path.

- `acquire`: `runID`, `deviceID`, `requestID` UUID strings and `transfer` boolean.
- `renew` / `release` / `end`: `runID`, `deviceID`, `token` UUID strings and positive
  decimal-string `fence`.
- `history`: the same proof, a 64-character lowercase SHA-256 `history`, and
  decimal-string `expectedVersion` from the current grant.
- `checkpoint`: the history payload plus `checkpointID` UUID and `predecessor`
  UUID (or JSON null for the first checkpoint).
- Grants include matching `ownerID`, `runID`, `deviceID`, random `token`,
  monotonic decimal-string `fence`, Unix-second `serverTime` / `expiresAt`,
  `checkpointID`, `checkpointHistory`, `historyDigest`, and decimal-string
  `anchorVersion`. The three content anchors start null, with version zero.

Leases last 60 seconds. An owner advisory lock serializes new rows, acquisitions,
renewals and releases; the `(owner, run_id)` primary key scopes authority to one
player. Repeating the same acquisition returns the original grant without
extending it. An active lease cannot be taken by another device. An expired or
released lease requires `transfer: true` to move to another device; the ROM must
obtain explicit confirmation before sending that request. Every reacquisition
rotates the random token and increments the fence, so old renewals and releases
fail. Each account is limited to 256 run rows. Account deletion cascades rows.

`end` permanently tombstones the owner/run UUID. The same fenced proof may
retry after expiry or release, but a transferred device's old proof fails.
Acquisition, renewal and anchor mutations return `run_ended` thereafter;
release remains idempotent, and a new run must use a new UUID. The app saves
pending end intent durably before requesting this operation. An uncertain
reply may complete that intent after `run_ended` on restart; an old cloud
package without the intent must remain in recovery.

History changes use an atomic version comparison; a stale update cannot replace
a newer acknowledged history. A checkpoint must reference the current server
head as its predecessor and match the current shared-history anchor. Repeating
an already applied history or checkpoint request is idempotent. Successful
changes increment `anchorVersion`; renewal, release and device transfer retain
all anchors. History/checkpoint mutations also renew the current lease for 60
seconds. The app must compare acquired anchors to local/package content before
advancing or submitting a new history, and await server acknowledgement before
resuming after a history change or completing a checkpoint. A CAS conflict must
trigger recovery, not be retried with a newer version and stale content.

`BoundRunLeaseClient` retains acquisition request IDs across uncertain network
failures. `BoundMultiplayerDeviceIdentity` stores the installation UUID with
`AfterFirstUnlockThisDeviceOnly` Keychain protection. The lease token is never
copied into save packages. Packages record their source device identifier, but
restoring them cannot replace the destination's Keychain identity. Grant validity
uses a sleep-continuous monotonic deadline calculated conservatively from the
request start, with a five-second margin. Release and end invalidate existing local copies immediately; late
asynchronous replies cannot revive them. Transfer grants additionally carry the
explicit confirmation flag for save-package adoption. Client operations serialize;
successful renewals and anchor mutations supersede old grant copies, and replies
cannot regress remembered anchors. Network errors do not
prevent local saving, but an expired grant must pause game advancement.

The server stores content hashes and checkpoint IDs, not save files or proof of
their contents. Run, ROM, checkpoint and history compatibility checks still apply
before restoring a package. Include the server fence in peer handshakes; preserve
cloud conflicts.

## Local verification

`lease.test.mjs` runs against a disposable PostgreSQL Unix socket under
`/private/tmp`; it rejects network-host configuration and creates/drops its own
fixture database. Pass `PG_MODULE` if `pg` is outside normal module resolution.

```sh
BOUND_LEASE_TEST_SOCKET=/private/tmp/my-lease-test/socket \
BOUND_LEASE_TEST_PORT=54884 node --test Backend/multiplayer/lease.test.mjs
```

Verified with PostgreSQL 17.6 and `pg` 8.23.1: sixteen independent concurrent
connections wait behind an uncommitted first acquisition and all lose to its
single grant. Tests also cover idempotency, expiry, release, explicit transfer,
stale fences, account isolation, revoked/expired sessions, client privileges,
malformed payloads and account-deletion cleanup. Additional concurrent history
writers verify anchor CAS, checkpoint-parent enforcement, idempotency, transfer
retention and rejection of stale checkpoints/history. Native client tests cover
uncertain retries, reply binding, late renewal after release, serialized anchor
writes and rejection of regressing server replies.
Permanent-end tests cover retry after release/expiry, old-device and wrong-account
rejection, all advancement operations staying closed, and a distinct new run UUID.

Deployed to the verified `bound` project, ref `qevnxhngdtlyihhmvnjv`, `us-west-1`,
matching `BoundFriendAccount.origin`, as hosted migration `20261022092558`
(`bound_run_lease_v1`), `20261022093614` (`bound_run_lease_anchors_v1`), and
`20261022095142` (`bound_run_lease_end_v1`).
Their reviewed sources are the CLI-created local migrations
`20261022090724_bound_run_lease_v1.sql` and
`20261022093123_bound_run_lease_anchors_v1.sql`, and
`20261022095012_bound_run_lease_end_v1.sql`.

Post-deployment verification confirmed RLS, no direct table privileges for
`anon` or `authenticated`, an authenticated-only RPC, the invoker public wrapper,
and rejection of calls without a live authenticated session. Existing public
function definitions and public table count were unchanged. Security advisors
added only the expected [RLS enabled with no policy information](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy)
for the private, deny-all table; preexisting warnings and performance advisories
were unchanged. Hosted signed-in acquisition and physical-device transfer remain
unverified; the acquisition/concurrency checks ran against local PostgreSQL.
No Edge Function, Agora secret or service-role credential changed.
