# Full-app multiplayer gameplay acceptance

## Verified October 20, 2026

Full-app simulator acceptance **passed** on `multiplayer` with the pinned VBA-M
core (`com.rileytestut.GBADeltaCore`) and the existing real Agora transport.
The native-only preflight and short paired rehearsal also passed on both peers.
The full run maintained the acceptance interval for **900.7 seconds**
from the first bidirectional visible connection; both native UI tests and both
Xcode processes succeeded.

Observed through the ordinary app UI:

- Friends selection and the live-sprite switch started actual authenticated sharing.
- Each app created its own native state through Menu → Save State → Add.
  The files have different hashes and positions, and each remained unchanged
  while the other app restored its own state.
- A exited Oak's lab while B stayed inside; both remote sprites hid. B exited,
  and same-map visibility returned outside.
- Actual Menu → Load State restored each app independently to its saved lab
  position, with mismatch hiding and reunion verified by live reader observations.
- Backgrounding A hid its sprite on B; foregrounding restored fresh presence.
- Both peers continued moving and receiving native video and presence during the
  sustained interval, renewed tokens, then stopped sharing through the normal UI.

| Peer | Saved tile | State bytes | Soak tiles | Presence gain | Video gain | Renewals |
| --- | --- | --- | --- | --- | --- | --- |
| A | 6,8 | 43,899 | 7 | 16,469 | 25,202 | 28 |
| B | 7,8 | 43,786 | 7 | 16,439 | 24,938 | 30 |

The saved map was `4:3` on both peers. The tile and file rows describe actual
native snapshots; the gains count only the soak portion after the map/restore/
background scenarios. The separate native preflight verified the finite native
controller geometry, door route and real restores before friendship creation in
this continuation.

Other checks passed: Debug `BoundCompanionQA` and `BoundIntegrationQA`
build-for-testing; 61 focused integration tests with no failures or skips;
the ordinary-app fast-forward persistence UI regression; unsigned generic
iPhone Release build; all 17,060 pinned source files; and `git diff --check`.
The actual-ROM reader and recorded-player tests were included in the 61 tests.
The Release executable excludes `--bound-ui-gameplay-qa`; its bundled cloud
configuration matches Debug and the committed resource byte-for-byte.

The 57 available protected setup/auth/sync/config files matched the original
transferred baseline. Its remaining entry is the original Mac's ignored
`Backend/social/supabase/.temp/cli-latest` cache marker, absent on this Mac.
The original 58-entry manifest was preserved rather than regenerated; that
absent cache marker is not claimed as byte-verified.

The final rehearsal and full run reused one temporary QA friendship. Cleanup
removed it, verified both original active friend lists, removed all one-use
inputs and preserved the fixture ROM/seed hashes. No notification, deployment,
backend/configuration change, signing-setting change or normal app-data change
was made. Runtime Debug products use local simulator ad hoc signing; the
ordinary iPhone Release build is unsigned.

These results cover two simulators on one Mac/network. They do not establish
physical-device performance, separate-network connectivity, interactive login/
keychain persistence, push delivery or adverse-network recovery. Battle and
unsupported-scene admission are covered by focused tests, not a full-app battle
playthrough.

## Private preparation

Build the `BoundCompanionQA` scheme with `build-for-testing` through the ordinary
`Bound.xcodeproj` entry. Create two fresh, explicitly owned simulators. Install
the built `Bound.app` only there. Do not reuse a normal app's data container or
keychain. This simulator recipe uses the ordinary app bundle identifier inside
the two isolated simulators; the separate physical-device QA build described in
[device acceptance](BOUND-MULTIPLAYER-DEVICE-QA.md) is a different recipe.

In each app's private `Documents/FullAppGameplayQA/` directory, stage copies of
the supported `RadicalRed.gba` and a disposable `seed.sav` in Oak's lab (map
`4:3`, tile `7,8`). The DEBUG simulator-only `--bound-ui-gameplay-qa` opt-in
imports the ROM through `DatabaseManager` and seeds only a missing local battery.
It never patches the ROM or RAM. Keep cloud save sync disabled in these fresh
apps.

Through an authorized private credential helper, stage an owner-only, one-use
`access-session.json` containing `owner`, `key`, `token`, `roomID`, `peer` (`A` or
`B`) and a shared random `run` UUID. Use fresh normal access sessions from two
dedicated accounts with an existing authorized QA friendship. Never use admin
credentials or an Agora certificate, copy a normal Bound session, or place
credentials in command-line arguments, source, logs or artifacts. The caller
owns cleanup of any temporary friendship and unconsumed inputs after failure.

The app consumes and removes this input before decoding it. Access-only QA
accounts use memory storage, no automatic refresh and a refresh transport that
fails closed. No refresh credential is staged. This bypasses interactive login
and keychain persistence, so it does not validate those flows. QA suppresses
Jiggle delivery only; friend listing, selection, token requests, RTC join,
renewal, presence and video use their normal implementations.

## Run both native UIs

```sh
umask 077
PrototypeTools/qa-python -B PrototypeTools/full-app-gameplay.py \
  --xctestrun /absolute/path/to/BoundCompanionQA_iphonesimulator27.1-arm64.xctestrun \
  --sim-a OWNED_QA_SIMULATOR_A --sim-b OWNED_QA_SIMULATOR_B \
  --output .build/new-full-app-gameplay-run --duration 900
```

The loopback coordinator has only stage/status endpoints. It never carries a
pose, video frame or gameplay input. XCTest touches native controller locations;
the QA accessibility rectangles expose existing controls without injecting
emulator input. Read-only simulator observations identify the actual running
core, reader, local map/tile, received counters and visible sprite pixels.

Acceptance requires both native tests and both Xcode processes to succeed:

1. Independent live movement and sprites on the same lab map over real Agora.
2. Actual **Menu → Save State → Add**, then selecting that native state on each
   app. The two real snapshot files must exist and retain different positions
   and hashes.
3. A exits the lab through its door while B stays inside. Both remote sprites
   hide. B exits and same-map visibility returns outside.
4. Actual **Menu → Load State** restores A to its saved lab position while B
   continues outside; B's snapshot file remains unchanged. B restores its own
   different position and visibility returns inside; A's snapshot is unchanged.
5. A backgrounds while B keeps running. B hides A's sprite; foregrounding A
   admits fresh presence and restores visibility.
6. At least 900 seconds from the first bidirectional visible connection,
   including the scenarios above, with movement and at least two token renewals
   on each peer, followed by a normal UI stop that clears sharing and sprites.

`--smoke --duration 1` is an explicit short rehearsal. It exercises the scenarios
but cannot count as sustained acceptance. The emulator continuously animates;
the UI runner skips Xcode's animation-idle heuristic and checks actual controls
and reader transitions instead. `-collect-test-diagnostics never` avoids the
previously observed simulator-diagnostics finalization hang without suppressing
test failures.

`--native-only --duration 1` selects `testNativeMapAndSaveRestore` on both peers
without opening Friends or joining RTC. Use it to debug native boot, controller
coordinates, the door route and state restoration before consuming another
temporary pairing. The private preparation still supplies the QA observer's
access-only input, but can use a random unused room UUID and must skip friendship
creation. This preflight passed on both peers during the validated
continuation. Native-only mode itself provides no Agora evidence.

All observations, screenshots, ROMs, batteries, states, one-use inputs and SDK
logs stay private and ignored. QA observations include raw map/tile values and
public QA display labels for selectors; they are separate from Bound's typed,
whitelisted connection-check export. The QA observer and account preparation
are compiled out of Release and physical-device builds.

Two simulators on one host establish full-app behavior over real Agora. They do
not establish physical-device performance, separate-network connectivity,
interactive login, push delivery or adverse-network recovery. Battle and other
unsupported-scene admission remain covered by focused reader/session tests
unless separately exercised in actual gameplay.
