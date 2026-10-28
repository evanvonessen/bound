# Approved RRv4.1M distribution

Deployed and verified on October 28, 2026 with explicit user authorization.
The one-time migration approved both existing non-system accounts. Future
accounts remain denied until separately approved. TestFlight and Xcode Cloud
remain outside this task.

The existing Nakama account gateway serves ROM metadata and bytes. Caddy only
reverse proxies these requests; never add a `file_server`, public object URL,
unauthenticated redirect, or static download route for the ROM directory.

`rom-updates.sql` is an immutable migration in the existing transactional ledger.
On its first application it approves every existing non-system account UUID.
It blocks account insertion during that initial snapshot and commits the cohort
and ledger receipt together. Restarting never reruns the grant. Future accounts
have no approval row and are denied; the table's explicit default is also false.
Deleting an account cascades its grant. This approval is independent of backup
approval, local developer controls, account metadata, email, and username.

Operators can subsequently grant or revoke an existing account UUID with
`node developer-access.mjs approve ACCOUNT_UUID` or
`node developer-access.mjs revoke ACCOUNT_UUID`, against the intended database.
There is no HTTP approval API and no future-email approval. Authenticated users
have no database privileges on the approval schema. Revocation prevents the next
request and is checked again before responding after ROM verification. Bytes
already admitted to an ongoing download cannot be recalled.

Every endpoint requires the ordinary Bound bearer session. The gateway also
checks current session expiry, deletion state, and developer approval from
PostgreSQL rather than trusting a cached client claim:

- `GET /rom-updates/access` returns `{ "developerApproved": true|false }`.
- `GET /rom-updates/latest` returns the current private manifest for approved
  accounts. Unapproved users receive HTTP 403 with no release metadata.
- `GET /rom-updates/download?build=500&sha256=...` returns the exact current ROM
  only to an approved account. The build and digest must match the current
  manifest; a superseded refresh returns HTTP 409 so the app can refresh again.

All responses disable caching. Download metadata includes `X-ROM-Build-Number`
and `X-Content-SHA256`; the client must still independently verify bytes, exact
ROM identity, and its paired Bound compatibility before deleting local data.

The publisher owns a private host directory, normally
`/var/lib/bound/rom-updates` (`ROM_UPDATES_HOST_DIRECTORY` in Compose). The gateway
mounts it read only at `/var/lib/bound/rom-updates` (`ROM_UPDATES_ROOT`). The host
directory must exist before Compose starts. Its generation directories and
files must be readable by the gateway container UID 1000; grant no public HTTP
access. Publication is entirely independent of Bound archives/TestFlight.

The on-disk contract is:

```text
ROM_UPDATES_ROOT/
  current -> generations/500-<sha256-prefix>
  generations/500-<sha256-prefix>/
    manifest.json
    RRv4.1M.gba
```

`current` is replaced atomically. The publisher retires the previous generation,
keeping only one published `.gba`. The gateway resolves one generation, opens
regular files without following file symlinks, checks size, SHA-256 and SHA-1,
and streams the retained ROM inode. An already-open old download can complete
after replacement. A replacement racing the initial open may return a safe
retryable 503; it never returns another generation's bytes for the requested
build. Hashing is bounded to two simultaneous ROM readers and uses streaming
buffers rather than loading each cartridge into memory.

Manifest v1 has `schemaVersion`, `buildNumber` (integer, starting at 500),
`sha256`, `gameID` (SHA-1 content identity), `byteCount` (33554432),
`gameCommit`, `boundABIHeaderSHA256`, and the generated game `contract` object.
The build counter is game-owned and independent of `CFBundleVersion`. Matching
ABI alone does not establish exact-ROM/core/save compatibility.

Run `node --test test/rom-updates.test.mjs` for synthetic HTTP/filesystem checks.
For real migration and grant checks, set `BOUND_ROM_TEST_DATABASE_URL` to an
explicitly isolated PostgreSQL admin URL and run
`node --test test/rom-updates.database.test.mjs`. That test creates and destroys
only a randomly named `bound_rom_test_*` database. It never reads production
accounts. Device UI, authenticated live Linode delivery, and physical two-device
testing remain separate acceptance steps after deployment is authorized.
