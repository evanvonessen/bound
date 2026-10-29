# Resume, directions and friendly battles — October 28, 2026

## Changes

Live DEX imports can run during foreground activation. Delta's controller queue
may already be waiting for main-thread resume admission; synchronously waiting
for that queue from the main-thread capture creates a circular wait. The capture
now uses the core's serialized pause boundary directly, suppresses capture-only
server save requests, and releases only its own pause after checking the current
core/game, foreground state and normal UI/recovery/activity admission. A failed
parse also releases that pause. An already paused core remains paused.

Friend routing previously required fully projecting the destination room's
arrival scripts before offering any direction. Viridian Pokémon Center's native
specials and first-visit script exceed the read-only interpreter. A verified
walkable approach to its entrance now remains available. Unknown intermediate
maps, blocked exits, map-identity mismatches and actual progression gates remain
rejected. Stopping the player reader cancels outstanding route work and clears
its cached direction. The existing UI distinguishes route unavailability from
an unavailable player.

Friendly battle admission already had the native-dialogue input deadlock fix in
`c581ead8`. This change retains it and reruns entry, full completion, native Run,
transport interruption and owner-state restoration. No new battle protocol or
cartridge changes are needed.

## Exact pair and preservation

- Game source: `9baa64971769f9773a6a34fdf489ce998b634b2c`, RRv4.1M build 503.
- ROM SHA-256: `a215add233d8d2f119e29b435605d3af99d063180d6b77310f178dfcdebf0ba2`.
- Game build identity: `6f70ce7b70d142cee2fbcaa197f48c58fc18f2f2`.
- Generated contract: ABI 1.0, wire 2, checkpoint/battery 1, state layout 16.
- Delta/GBADeltaCore identities, dependency pins and patches are unchanged;
  native VBA-M state version remains 10. No save migration or game publication.
- Existing simulator fixtures are preserved. New private fixture directories
  explicitly select this cartridge; no ROM is bundled with the app or committed.

## Local validation

Evidence is retained under
`artifacts/multiplayer-isolation/resume-directions-battles/` in the workspace.

- Unsigned Release iPhone: passed (`release.log`).
- Final focused app run: 54 tests, zero failures, one optional private-checkpoint
  test skipped (`focused-final.log`). Includes native dialogue handoff, actual
  Pallet/Route 1 crossing and return, Mart entry, arrow rendering and the new
  native capture contention/pause ownership tests.
- Independent capture run: both new native tests passed (`capture-isolated.log`).
  The queue is deliberately held by a resume delegate with a bounded watchdog;
  native KVO must observe the capture pause and playback must recover after a
  diagnostic-ROM parse failure. This is a controlled schedule, not a physical
  phone reproduction or a successful RR DEX parse.
- Before/after reproduction: rebuilding the original capture code with the same
  regression waited 3.002 seconds for the watchdog and left the core paused
  (`capture-before.log`). Both assertions pass with the fix. The original source
  was used only for that diagnostic build; the final source retains the fix.
- Save-boundary, playback/reconnect, presence and continuation suites in the
  initial broader run passed: 19, 44 (one optional skip), 34 and 7 tests,
  respectively. That run also exposed obsolete fixture selection and a typed
  KVO assertion; these were repaired and rerun, not counted as successful then.
- Route graph: synthetic access, unknown-intermediate, blocked-threshold and
  stale-map checks passed; exact topology contains 437 maps and 1,530 portals.
- Fresh native route run: all 42 route checks and 11 native button transitions
  passed, including Pallet/Route 1/Viridian, doors, stairs and a dormant warp.
  Six independently enumerated shortest-path comparisons remain unchanged.
- Paired native battle: A initiates at 8×, B at 1×, full battle completes and both
  original parties/owner state restore (`battle-full-a-fast/summary.json`).
- Paired native recovery: B initiates at 8×, A at 1×, three-second packet blackhole,
  reconnect, native Run and both owner states restore
  (`battle-run-b-fast-reconnect/summary.json`).

## Limits and manual checks

The native pair uses production battle transport over host loopback, not the
live authenticated WAN service. Route fixtures use native map loading plus
explicit synthetic progression stages; they do not prove a naturally played
first new game. Physical two-phone background/lock/foreground, prolonged outages,
process termination and naturally played initial Pallet → Route 1 → Viridian →
Pokémon Center remain untested. The optional private interrupted Mac checkpoint
was unavailable, and the optional actual-app controller-pacing fixture was also
unavailable. Existing save/continuation model tests are not phone testing.

On two devices, resume the same server run; background/lock and return with DEX
shown and hidden, including during dialogue and a pending save. Verify input and
frames resume, an open menu stays paused, and each player's progress persists.
Leave player two in Pallet while player one visits Viridian and its Center, then
walk player two into Route 1 and back; verify the next usable exit and stale/offline
status as player one moves or disconnects. Start friendly battles from either
player at normal and fast-forward speed, with dialogue open at acceptance; cancel
startup, finish a battle, use Run, and background either participant during battle.
Confirm both return with their own party and progress. Apple upload acceptance,
processing and internal TestFlight availability must be reported separately.
