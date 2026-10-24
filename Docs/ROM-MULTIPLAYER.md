# ROM-driven experimental multiplayer

Enable Experimental Multiplayer remains off by default. It activates the ROM
friend roster, authenticated gameplay transport, presence and background shared
events. Ordinary Bound friend accounts and Agora video remain independent.
Diagnostics stay behind Enable Developer Features.

## One shared setup

With experimental multiplayer enabled, New Game offers Debug mode before the
native introduction. After selecting Soul
Link and choosing each other from the friend roster, the two players establish a
single run. A randomly selected chooser is recorded once with distinct nonzero
player seeds, exact ROM compatibility and versioned shared settings. The chooser
answers the shared rival, difficulty, randomizer, common-cheat and nickname
questions. The partner has a blank screen displaying only:

> Waiting for your partner to set up the game.

The setup document is stored with compare-and-swap ownership and an epoch before
the chooser advances. Commitment is immutable. Each ROM validates and applies
its configuration through the native setup path; native option/name/seed readback
and application guards make retry harmless. The chooser starts after commitment
and local application. The partner starts after retrieval and local application.
Neither startup requires a partner start acknowledgement or first-field barrier.

Debug Yes chooses Gary, Minimal Grind, default difficulty/randomizers, all five
common cheats (Woyaopp, SO2Toxic, DexAll, TeamPreview and EZCatch), and automatic
nickname prompts off. An unspecified player identity uses the native default.
After connection and configuration, the stock new-game continuation starts in
the bedroom without further setup input. It does not warp an existing save.
Debug mode belongs to this new run; Continue never applies its preset again.

Setup drafts and native setup snapshots survive suspension. B cancels locally
and records cancellation for background delivery. Start opens a takeover
confirmation. Yes can claim an uncommitted setup after the chooser has been absent for 30 seconds;
a new epoch rejects the previous chooser's late writes. Retry preserves the
configuration. Setup/network/application failures expose a recoverable native
action rather than an unbounded invisible wait.

If a former chooser returns inside an obsolete naming prompt after takeover,
Retry restarts only their unapplied native introduction with the same committed
run and seeds. It cannot restart an already initialized cartridge.

## Independent play and background events

Each cartridge owns story flags, trainer defeats, badges, puzzles, boulders,
inventory, rewards and saves. The native flag, collision and trainer handlers
retain their original local behavior. Peer progress and freshness never decide
whether walking, a native battle, a story script or a map transition can proceed.
Remote avatars are presentation only and never create collision obstacles.

Connection loss expires presentation/interaction freshness, queues shared facts
and keeps ordinary native callbacks running. Reconnection exchanges missing
history without a catch-up screen, warps, flag copying or reward grants. A local
integrity error still enters recovery rather than allowing an unrecorded loss.
Disabling experimental multiplayer safely closes its services and preserves
transaction recovery; it does not erase the run.

The durable shared journal assigns each event an origin account and sequence.
Receipt and application are separate persisted operations. A crash between them
replays the effect idempotently. Per-origin contiguous and sparse cursors retain
gaps; duplicates and reordered delivery cannot hide missing events. Nakama keeps
immutable events independently of live matches. Acknowledgements confirm durable
synchronization and never release a gameplay gate.

World snapshots also enter this outbox before sharing, including while offline.
Replayed world history updates presentation records only; it never writes local
story, trainer, inventory or puzzle state.

Soul Link pairs the first eligible encounter by its area slot; eggs use their
defined ordinal slots. A death tombstone survives arrival before its matching
catch and survives restoring an older save. Remote losses apply at the next safe
native field boundary after receipt. During a disconnection, enforcement is
eventual: an unreachable phone cannot receive an instantaneous remote faint.

## Independent saves and optional interactions

Native Save completes this player's version-2 package, internal recovery snapshot,
shared journal and cursor locally. Each player has a separate checkpoint chain.
The short local capture pauses only that core; background server/Dropbox upload
never requires the partner to save, acknowledge, reach a town or share a digest.
Normal reopening validates the local account, device, exact ROM and personal
files before restoring that player's snapshot, even with the partner offline.
Version-1 paired packages remain readable; original files are preserved.
See [save packages](MULTIPLAYER-SAVE-PACKAGES.md).

Trades, friendly battles and cooperative battles retain explicit mutual consent
and bounded invitations. Expiry or an unavailable participant releases invitation
controls. A delayed acceptance callback cannot start an expired activity.
An interrupted native transaction retains its own recovery journal; it does not
introduce a general partner catch-up condition. Raw cross-build emulator states
remain incompatible; native recovery and explicit device transfers retain their
save ownership safeguards.

## Validation boundaries

Required checks include native cold-boot startup for both setup roles, verified
debug option/name/seed values, native movement and trainer entry with stale or
missing peers, independent save/reopen, duplicate/reordered events and death before
catch, old-save rollback, takeover fencing and interrupted transaction cleanup.
Focused iOS integration tests and an unsigned Release iPhone build are required
before publication. Local native/model/Simulator evidence does not establish a
physical two-phone playthrough, phone performance parity or live hostile-network
behavior. The multiplayer variant remains separate from byte-identical baseline
ROM reconstruction.

October 24, 2026 validation passed 191 focused iOS Simulator tests, including an
actual native HP/save-state test that enforces known losses before restored play
resumes. The authenticated Nakama service passed 68 tests; the self-hosted API
passed 51 tests, with two database-dependent checks skipped. The unsigned Release
iPhone build succeeded. Native cartridge checks exercised both setup roles,
same-run Retry after naming-screen takeover, stale/disconnected-peer movement,
trainer entry and older-save loss enforcement. The server runtime and RPC route
were deployed and health-checked; no two-phone live-account playthrough or adverse
network test was performed.
