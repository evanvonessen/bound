# Isolated DEBUG protocol

This implementation is disabled unless the gateway and Nakama runtime both use
`BOUND_DEBUG_MODE=local`, a matching private `BOUND_DEBUG_GATEWAY_SECRET`, and an
explicit `BOUND_DEBUG_ALLOWED_OWNERS` list. The gateway requires loopback HTTP,
database and Nakama configuration. No live deployment is part of this change.

`POST /functions/v1/bound-debug` authenticates the current native account session,
email confirmation and MFA through the existing account service. Creating or
joining a session also checks the existing friend room. The gateway signs a
short-lived request proof; Nakama rechecks the account journal and uses its
version in the mutation CAS. A client toggle, owner UUID or copied session
capability alone cannot authorize a write.

The fixed server-owned collections are `bound_debug_v1`,
`bound_debug_payloads_v1`, `bound_debug_gameplay_v2` and `bound_debug_events_v2`.
Session/generation keys and realtime rooms are derived by the server. Callers
cannot select collections or redirect ordinary run operations into DEBUG.
The scoped gameplay path reuses the existing independent-run engine.

One controller prepares an immutable operation and each joined owner uploads
only their own package. Both seals precede a paired commit. Both native restore
verifications for the same generation precede activity admission. Save blobs,
run identities, event origins and custom capture history remain opaque and
unchanged; metadata and exact byte hashes are checked before activation.

Custom capture first agrees on a source history cut. Both owners retain their
safe boundary until both immutable descriptors exist and `captureComplete`
acknowledges their captured bytes. They then resume the current generation while
the payload uploads. Committing a custom capture only archives it; explicit
reload activates a fresh generation using the archived bytes and history cut.
`captures` discovers these durable archives after restart.

Pending switches block new activities while preserving an already admitted
activity's current-generation connection and ticket renewal. Commit, revocation,
terminal state and expired authorization fence stale gameplay and realtime.
`bound-debug-room-v1` keeps the native binary lane and opcode-5 renewal in a
separate match namespace. Recovery reads remain owner scoped after revocation.

Return requires both owners to report settled, paused source heads before the
controller commits. Each owner restores the current ordinary head, validates
device ownership and confirms it with a guarded `returnVerify`; a bookmark does
not authorize rewinding an ordinary save.

Local validation used the pinned PostgreSQL/Nakama/Caddy stack, real TLS,
synthetic allowlisted accounts, one-use email verification, friend acceptance,
restart persistence and WebSocket delivery. The Nakama suite passed 125 tests;
the gateway suite passed 71 with two existing optional database suites skipped.
Protocol payloads in those backend tests are synthetic, and their native
verification assertions do not certify playable emulator fixtures. Actual
paired app/native fixture acceptance is a separate gate.

Run focused tests from the isolated repository with `npm test --prefix
Backend/nakama` and `npm test --prefix Backend/selfhost`. Runtime artifacts,
credentials, certificates, saves and generated ROMs belong outside Git. The
optional local email sink captures only synthetic verification messages beneath
an explicitly configured private fixture root; it does not send external mail
or bypass confirmation. `BOUND_MIGRATION_MODE=verify` permits an already migrated
runtime role to check immutable migration hashes without running DDL.
