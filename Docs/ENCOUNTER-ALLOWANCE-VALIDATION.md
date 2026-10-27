# Encounter allowance candidate — October 27, 2026

Local changes on `codex/multiplayer-isolation` in the paired isolation workspace.
No publication, TestFlight, server deployment, ordinary player data, or shared
simulator changes are part of this candidate.

## Scope and identities

The implementation is in Bound's existing exact-ROM runtime Soul Link adapter.
No game source or cartridge file changes are required. The paired game checkout
remains `35d7b2abe295225f9f621584bf20ad83563c3c58`; the app starting revision is
`36ffa9058349957307ff645841c1e806c0e796cd`.

The native harness checks both exact inputs:

- Reconstruction SHA-256: `689299664a954c12dad66e03c2d18446b348cb31bd98b395c87b9b514b288066`.
- Current bundled multiplayer cartridge SHA-256: `fcfaa8a9fb022656994a429be4cba5b9f14ba6c477ec813d2d6a2aa3878edc00`.

The latter retains its existing SDK ABI and save-state layout 12. Native battery
save layout, core dependencies, and ROM identity stay unchanged. Optional local
journal ordinal metadata does not retrospectively reclassify old catches.
An unchanged ABI does not certify arbitrary old raw emulator states: no new
natural save/cold-restore or physical-device compatibility claim is made here.

## Local checks

Use `BOUND_GAME_SOURCE` pointing to the isolated game checkout and the approved
`PrototypeTools/qa-python` launcher.

- PASS: `verify-encounter-ledger.py`: seven XCTest cases execute the maintained Swift
  ledger directly. Covers exemption/area separation, one prize across choices,
  separate per-player egg ordinals, hatch identity changes, loss isolation,
  duplicate receipts, journal round-trip, monotonic restore, and malformed input.
- PASS: `verify-encounter-native.py`: 66 controlled Thumb checks on each exact ROM.
  Exercises the compiled enforcement shim, original native bag/quick-ball
  callers and original native script interpreter. Success/storage, map/flag,
  and graphical callbacks are observed boundaries, not complete gameplay.
- PASS: `build-soul-link.py --check` and `--qa --check`: generated shim consistency.
- PASS: required unsigned Release iPhone build (`release-verified.log`), with derived data under the isolated
  task artifact directory. Logs and machine-readable native receipts are in
  `artifacts/multiplayer-isolation/encounter-rules` at the workspace root.

The modified simulator-native gift expectations distinguish an actual field
script gift from a wild catch. Those simulator tests have not been executed for
this candidate. Existing tests are not evidence of a completed new playthrough.

## Required gameplay acceptance

Use fresh isolated test runs on two updated apps, never ordinary player saves.

1. Catch a wild Pokémon, then attempt fishing/surfing and a den in the same
   named area. Repeat in a fresh run with the raid catch first. Both bag and
   last-ball shortcut must refuse further catches without spending a ball.
2. Fail a catch, flee, and lose a raid; the first successful catch remains free.
   Check different floors and multiple dens with the same native area name.
3. Obtain Eevee, Magikarp, gifted shiny Magikarp and a fixed legendary before
   and after ordinary catches. Each must leave the area's wild/raid slot intact.
   Gifts pair by their own order; static encounters pair by a separate order.
   Fainting Gift 1 or Static 1 must disable the partner's matching pair only.
4. Each player receives Egg 1 and Egg 2 in different cities and party orders.
   Link by acquisition ordinal. Hatch with native OT changes, box, evolve,
   restart and reconnect. Losing Egg 1 must affect the partner's Egg 1 only.
5. Obtain one Celadon prize, then try every other Pokémon choice after closing
   and reopening the clerk. Currency must remain unchanged on rejection.
   Item/TM clerks must remain usable. Repeat after saving/restarting inside the
   prize room and after entering an already active room with cached NPC data.
6. Release/box/trade away an acquired Pokémon (where trading is permitted),
   reconnect, restart and restore an older checkpoint. No allowance reopens.
7. Exercise cooperative raid reward, checkpoint and interrupted recovery. The
   acquisition receipt must be durable before receipt acknowledgement or restore.
8. Exercise normal single-player play and ending Soul Link. Native restrictions
   and clerk behavior must return to their ordinary state.

Natural capture/storage completion, completed prize purchase, cooperative raid
playthrough, new app-level checkpoint/restore, long-session RAM lifetime,
physical two-device play and WAN testing remain untested. Controlled local
checks do not establish these outcomes.

## Final pairing policy

Eggs retain Egg 1 ↔ Egg 1 and Egg 2 ↔ Egg 2. Gifts similarly pair Gift 1 ↔ Gift 1,
and static encounters pair Static 1 ↔ Static 1, by acquisition order within their
separate categories. All linked pair losses remain permanent. Celadon prizes
have their own single pair, independent of all four categories. No policy choice
is pending. Native battery and game source are unchanged.

Six additional actual-source codec/readiness tests cover complete gift/static bitmaps,
boundary ordinals, worst-case names, truncation, duplicates and malformed data.
BSL3 fences older peers; BSE1 sends complete facts independently of rotating names.

## Local backend validation and activation boundary

The local Nakama validator accepts canonical gift/static slots and retains the
existing authenticated owner, native-checkpoint, idempotence and atomic-commit
fences. All 156 backend tests pass, including eight additional rule tests.
Legacy history migration remains 864 bytes; new category authority is the
existing durable per-origin soul JSON event journal.

The live backend is unchanged. Its validator must be updated through a later
authorized rollout before it can accept the new gift/static facts. No live
activation or end-to-end production validation is claimed. Both apps also need
the updated BSL3/BSE1 support.

Rollout order is the backward-compatible server validator first, then both
updated apps. Older apps cannot interpret new gift/static slot histories; do
not roll them onto runs that have acquired those new records. Preserve the
current app/server pair and its history for recovery. This local work does not
authorize any rollout or delivery.
