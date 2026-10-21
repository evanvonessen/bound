# Multiplayer gameplay checkpoint handoff

Stopped at the user's request on October 20, 2026. This is an incomplete,
compiled implementation checkpoint, **not a passed full-app gameplay milestone**.

## Start here

First inspect the checkout, dirty state and worktrees. **Pull the `multiplayer`
branch from GitHub before beginning, and verify every implementation file in
this handoff is present.** Preserve unrelated work; do not reset, clean, stash,
erase simulators or change another checkout automatically.

```sh
cd /Users/admin/developer/bound
git status --short
git branch --show-current
git worktree list --porcelain
git fetch origin multiplayer
git pull --ff-only origin multiplayer
git log -2 --oneline
```

Run the pull only in the suitable `multiplayer` checkout. The checkpoint's
parent is `ebf686317b28959961b2bbb6339af8c561fcbd76`. Do not assume that parent
is still the branch tip. Other agents have active worktrees for main, Mac,
controller and performance work; leave those alone.

The user's objective is full-app gameplay on `multiplayer` using **VBA-M**:
normal Bound library/Friends/gameplay UI, map transitions, actual native state
creation/restoration and independent progress, followed by a sustained paired
real Agora run. Keep the existing Agora and Supabase setup unchanged. No
physical devices are available. Read root `AGENTS.md` and the gameplay/device
QA guides before continuing. The user asked to stop now and will explicitly
hand this work to a new agent.

## Included implementation

All implementation and documentation files below are committed. Private test
data, credentials, ROMs, states and generated artifacts are intentionally absent
from GitHub and must remain private.

- `Delta/Bound/BoundFullAppGameplayQA.swift`: DEBUG simulator-only, explicit
  `--bound-ui-gameplay-qa` preparation and read-only observation. Consumes/removes
  a one-use access input before decoding; fails closed if removal fails. Uses a
  private memory-only account with no real refresh credential, automatic refresh
  disabled and a refresh transport that always throws. Imports the copied ROM
  through the normal database and seeds only a missing disposable battery.
- `Delta/AppDelegate.swift`: conditional QA import after database startup.
- `Delta/Bound/BoundCompanionPanel.swift`: conditional private QA account and
  notification suppression; normal account behavior otherwise. Real Agora
  remains the transport. QA-only accessibility rectangles expose native input
  locations; XCTest still sends ordinary screen touches.
- `Delta/Emulation/GameViewController.swift`: conditional observation after a
  successful actual `core.load` and the existing reader invalidation.
- `Bound.xcodeproj/project.pbxproj`: registers the QA Swift source.
- `PrototypeUITests/PairedFriendUITests.swift`: adds `FullAppGameplayUITests`.
  `testFullAppLiveGameplay` exercises normal UI sharing, native Save/Load State,
  door transitions, background/foreground and stop. Newly added
  `testNativeMapAndSaveRestore` isolates native routing without RTC/Friends.
- `PrototypeTools/full-app-gameplay.py`: two-UI stage/status coordinator. No pose,
  video or emulator-input endpoint. Reads only QA observation files in explicitly
  supplied disposable simulators. Checks real native state-file hashes and
  positions, peer independence and a 900-second sustained interval. Supports
  `--smoke` and the newly added `--native-only`; these cannot count as full
  Internet acceptance.
- `Docs/BOUND-MULTIPLAYER-GAMEPLAY-QA.md`, this handoff, and the link added in
  `Docs/BOUND-MULTIPLAYER.md` describe preparation, requirements and limits.

No ROM/RAM patching, remote input injection or progress synchronization was
introduced. No backend/schema/RLS/function/configuration, production auth/sync,
SDK, dependency, signing or normal app-data changes were made.

## Verified versus outstanding

Verified at this checkpoint:

- `build-10.log`: latest Debug `BoundCompanionQA build-for-testing` succeeded,
  including both current native UI methods.
- `release.log`: ordinary unsigned generic iPhone Release build succeeded after
  the last app-source change. Subsequent edits were UI-test/tool/docs only.
- The Release executable has no `--bound-ui-gameplay-qa` launch flag. Its bundled
  `cloud-configuration.json` equals the Debug app's resource byte-for-byte.
- All 58 protected setup/auth/sync/config files matched their baseline, and
  `verify_sources.py` verified all 17,060 pinned source files.
- Python syntax and `git diff --check` passed. The final native-only coordinator
  mode is syntax-checked but has not run.
- Receipts 1–5 confirm each created temporary QA friendship was removed, original
  active friend lists restored and one-use inputs removed. Attempt 6 created no
  friendship; attempt 7's creation was denied and original lists were verified.
  No notification/Jiggle, privileged operation or deployment ran.

**Not verified:** no successful full-app paired gameplay run, actual door exit,
native state creation/restore, background recovery or 15-minute soak has been
completed in this milestone. The final controller-coordinate retry and native
preflight are compiled but untested. Current focused integration suites still
need to run. Actual battle gameplay is not implemented in this harness; focused
reader/session tests cover battle invalidation. Do not claim physical-device,
separate-network, performance, interactive-login/keychain or push coverage.

The parent commit already passed real Agora between two hosted VBA-M canvases,
with visible poses/video and token renewals. That prior proof is documented in
`BOUND-MULTIPLAYER-DEVICE-QA.md`; it does not substitute for this full-app run.

## Current failures and next debugging step

1. Initial Friends selectors failed. Native hierarchy proved the correct QA
   friend was listed, but the parent `bound.friend-row` identifier overrides
   child identifiers. The test now selects the existing visible friend button
   by `qaFriendLabel`. It also taps the trailing side of the live-sprite switch
   and asserts value `1`; a center-row tap previously left it off. These fixes
   still need successful end-to-end execution.
2. Boot then failed because XCTest resolved controller rectangles to infinity.
   The current `press` helper enumerates matching native buttons, waits up to
   ten seconds for finite geometry and freezes the screen rectangle before
   synthesizing the touch. It captures screenshot/hierarchy on failure. This
   latest retry has not yet reached a conclusive native run.
3. Attempt 5 also hit severe host load and simulator keyboard-service startup
   timeouts. Do not mistake these for transport failures. The startup allowance
   is now 360 seconds. In this environment, `xcrun simctl boot` timed out while
   invoking the exact selected simulator binary booted the same peer in 0.6s:
   `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl`.
   The private helper now uses that direct path. Do not change global Xcode
   selection or restart shared simulator services.
4. Attempt 6 selected Xcode's bundled Python after prepending its tool directory
   to PATH and failed closed on Keychain access. The approved interpreter is
   `/opt/homebrew/bin/python3`; use its absolute path. No unlock/ACL change or
   credential fallback was attempted. The PATH change was process-local.
5. Attempt 7 authenticated but temporary pairing was denied. Five prior creates
   in this run and the existing legacy contract's five-creates-per-hour cap are
   consistent with quota exhaustion; no privileged server quota inspection was
   performed. Respect the existing limit. Do not reset quotas, change the API,
   rotate accounts or use another pairing path to bypass it. First finish the
   no-pairing native preflight; retry live pairing after the normal window resets.

The seed lab is map `4:3`, tile `7,8`. The candidate door route aligns x=6 and
moves down toward y=12, based on the base FireRed map reference. It has **not**
been validated in actual full-app gameplay against this exact ROM. Diagnose
through actual UI/reader observations and adjust the walking route if needed.

## Local-only continuation assets on this Mac

Everything here is ignored/private and must not be staged:

- `.build/full-app-gameplay-validation/`: logs, receipts 1–7, attempted paired
  runs 1–5, failure screenshots/hierarchies, `protected-before.json`,
  `source-integrity.log`, `build-1.log` through `build-10.log`, `release.log`.
- `tested-source.json` fingerprints the earlier build-9 source. UI/tool source
  changed afterward: refresh the manifest for any new final run; do not claim
  that old fingerprint covers build 10 or the latest coordinator.
- `.build/LivePresenceQA/`: built ordinary Debug app and
  `Build/Products/BoundCompanionQA_iphonesimulator27.0-arm64.xctestrun`.
- `.build/LivePresenceRelease/`: ordinary unsigned iPhone Release product.
- `.build/full-app-gameplay-validation/run-private.py`: uncommitted private
  launcher. Uses the previously authorized exact development-account Keychain
  helper, normal authentication/API/token operations and cleanup receipts. No
  credential values are in its source. Read the existing helper's authorization
  policy before reuse; never enumerate Keychain items, unlock or relax ACLs.

Owned disposable iOS 27 simulators are recorded in `simulators.json`:

- A: `08D09BA7-D506-4ABF-8A18-BE042CE63AC2`
- B: `87D7234B-ACD7-4AA8-92FB-45F0B2E35E87`

Both shut down successfully at the stop checkpoint; recheck state before
booting. Keep their data and evidence. Leave the preexisting QA source
simulator `5105277D-7DF1-4BE5-B37C-4D1C1ECF5443` and all unrelated simulators alone.
The source simulator holds read-only originals under
`Documents/MultiplayerValidation/{RadicalRed.gba,seed.sav}`; use only copies.

The private launcher was most recently prepared to run the new native-only
preflight, but it has **not been started**. On this same authorized Mac:

```sh
umask 077
PATH='/Applications/Xcode_27.app/Contents/Developer/usr/bin:'"$PATH" \
  BOUND_QA_RUN=8 BOUND_GAMEPLAY_DURATION=1 BOUND_GAMEPLAY_NATIVE=1 \
  PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 -B \
  .build/full-app-gameplay-validation/run-private.py \
  > .build/full-app-gameplay-validation/run-8.log 2>&1
```

This mode uses a random unused room UUID, skips friendship creation and selects
the native-only UI method. It still obtains normal access-only QA sessions for
the observer. Use fresh run numbers and output directories for every attempt.

## Finish in this order

1. Pull and verify the committed files, inspect ownership/state, then run the
   native-only preflight. Resolve finite input geometry, actual door traversal
   and actual native Save/Load State behavior. Preserve failed evidence.
2. After the regular quota window resets, prepare the dedicated QA friendship
   through the existing API. Avoid repeatedly creating/removing friendships
   during local selector debugging. Consider one privately scoped suite that
   retains a single temporary friendship across rehearsal/final attempts and
   guarantees removal and baseline verification in final cleanup.
3. Run the paired real Agora rehearsal, then a full run with duration >=900 and
   no smoke/native-only flag. Verify same-map visibility, mismatch hiding,
   independent real states, background recovery, native screenshots, continuing
   movement/video/pose counters and renewals, and normal UI stop. The generic
   coordinator currently terminates its Xcode children on failure; check/stop
   only its owned app and runner before retrying, not shared simulator services.
4. Run focused `PlayerStateTests`, `RecordedPlayerTests`, `LivePresenceTests`,
   `PresenceConnectionCheckTests` and relevant sharing/account integration
   regressions through `BoundIntegrationQA`. Run an appropriate ordinary UI
   regression. Rebuild Release if app source changes. Recheck protected hashes
   and pins; review the diff for private assets.
5. Update docs with actual results and limits, commit and push to `multiplayer`,
   verifying remote HEAD and clean status. Preserve normal Agora/Supabase setup,
   signing, user data and unrelated work throughout.
