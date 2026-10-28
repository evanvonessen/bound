# Solid friends and retired ROM deletion

Validated October 28, 2026 in the paired multiplayer-isolation worktrees.

## Changes

- Retired ROM receipts continue blocking re-import and sync, but no longer
  disable Delete. Pending cleanup/install work and confirmation revision checks
  still protect active operations. Deletion remains scoped to the selected game.
- Directional targets respect the camera's sprite bounds. Any partial onscreen
  friend hides the arrow; foreground occlusion does not make a friend offscreen.
- The native movement port receives only the current occupied tile for each
  trainer/Pokémon. Previous tiles remain available for overlap recovery but do
  not create extra solid tiles. Nearby movement never enables `GP_NEGOTIATE`.
- Existing overlap temporarily releases peer collision until the native step
  footprints separate. Both players can leave in any terrain-valid direction,
  including the same direction. No coordinate writes, pushes, or teleports occur.
- Ground elevation zero follows FireRed's native compatibility rule. Ordinary
  floor/carpet transitions keep collision; distinct nonzero bridge levels stay
  separate. The installed ROM's exact-elevation ABI is adapted on the host.
- Let Pass remains optional with its existing saved visibility preference.
  Prediction, interpolation, visibility retention, ROM/core identity, and save
  serialization are unchanged.

## Local evidence

Artifacts are under `artifacts/multiplayer-isolation/solid-friends` in the parent
workspace; private ROMs, emulator states, screenshots, and build products are not
tracked by Git.

- `integration-final.xcresult`: 168 selected cases, 157 passed and 11 skipped.
  Includes 54 movement cases, retired deletion with Let Pass hidden, actual
  Core Data deletion/cascades, unchanged current ROM/save/state bytes, active
  operation fences, stale confirmations, pointer edges/camera/occlusion, and
  existing presence/prediction/persistence regressions.
- `follower-presentation.xcresult`: eight passed; native-position decoding,
  follower identity validation, map projection, depth, and frame restoration.
- `rom-deletion.xcresult`: three exact-current-cartridge checks passed.
  `historical-deletion.xcresult`: real historical-cartridge deletion passed
  with both verified ROM fixtures, preserving current ROM, battery save, save
  state, and unrelated game bytes. These resolve four of the initial skips:
  across the app runs, 169 distinct cases passed and seven remain skipped.
- `movement-elevation-final/results.json`: all 54 production Swift movement
  model cases passed independently of the app test runner.
- `native-04/acceptance.json`: 215 checks and 248 native actions passed with
  Let Pass hidden and no Let Pass requests. There were 40 solid entry blocks,
  208 successful movement actions, and 80 running movement actions. Both roles
  cover trainer/follower occupancy, four approach directions, adjacent rows and
  columns, normal/debug overlapping spawns, immediate opposite exits, repeated
  same-direction movement, staggered observations, restored solidity, native
  furniture, and elevation-zero transitions.
- All 208 successful native actions began on exactly the same frame as the
  corresponding collision-disabled baseline. Native animation completion also
  passed the baseline comparison. Running was confirmed by native avatar flags
  and faster animation completion, not merely by sending the B button.
- `release-final.log`: documented Fastlane `ios verify` Release iPhone build
  passed. SDK synchronization, generated profile verification, 17,061 pinned
  source files, and 99 privacy integration/source hashes also passed.

The first broader rendering selection failed three older Mart/R-button tests
that assume `multiplayer.gba` is bundled. Those unrelated tests were explicitly
excluded from the focused run; no cartridge was added to the app. Other skipped
cases require private gameplay fixtures or disposable live accounts. No claim
is made that the entire integration suite passed.

## Exact pair and limits

- App baseline: `c3e80b0ed32133e37dddd5849fcb84ea61a3ecb8`.
- Unchanged game checkout: `9baa64971769f9773a6a34fdf489ce998b634b2c`.
- Tested RRv4.1M build 503 SHA-256:
  `a215add233d8d2f119e29b435605d3af99d063180d6b77310f178dfcdebf0ba2`.
- Tested movement source SHA-256:
  `840419dbdef740009e7537d2320d1f770a1d7275f3803a963737da6b3d66dff1`.
- ABI 1.0, wire 2, checkpoint/battery format 1, save-state layout 16;
  `com.rileytestut.GBADeltaCore` state version 10. Exact-ROM gates remain intact.

The native matrix runs two mGBA 0.10.5 instances with production Swift movement
sessions/probe, declared host ports, and native button inputs. Follower collision
uses a synthetic kind-1 peer pose; its rendering is checked separately in app
tests. This does not establish physical-device, Delta/VBA-M gameplay, WAN jitter,
or simultaneous packet-race behavior. App tests ran only on a newly created task
simulator. Shared simulators, production data, and the main checkout were not
used for mutation.

To repeat the native matrix, run `PrototypeTools/qa-python
PrototypeTools/test-solid-friends.py` with explicit `BOUND_GAME_SOURCE`, `--rom`,
`--manifest`, `--state-a`, `--state-b`, `--debug-state-a`, `--debug-state-b`, and a
new `--output` path. The state inputs must be exact-ROM native bedroom/debug
spawns; they are verified before execution. The obsolete pass-through acceptance
tool was removed because its assertions contradicted solid collision.

Physical follow-up: with Let Pass hidden on both phones, repeat the four-direction
walking/running approaches and adjacent passages for trainers and Pokémon; then
spawn together, move apart immediately, and move together repeatedly before
separating and reapproaching. Pan each camera edge to check the pointer. Repeat
over separate networks and compare input response, smoothness, and retained
friend rendering during temporary gaps. These device/WAN checks remain untested.

Upload acceptance and TestFlight processing/group availability are recorded
separately by the manual delivery receipt and App Store Connect status check.
