# Full-app multiplayer gameplay acceptance

**Checkpoint: implementation is compiled, but full-app acceptance has not
passed.** Work stopped at the user's request on October 20, 2026. See the
[continuation handoff](BOUND-MULTIPLAYER-GAMEPLAY-HANDOFF.md) for current failures,
local evidence, private preparation and the next exact actions. Do not interpret
the acceptance requirements below as observed results.

This milestone runs two ordinary Bound apps with the pinned VBA-M core, the
supported private ROM and separate disposable saves. XCTest opens the library,
boots the game, selects the friend in Friends, enables live sprites and records
the connection through the normal controls. Presence and native video travel
through the existing real Agora transport.

The app's Agora/Supabase configuration, authentication implementations, deployed
functions, schema/RLS, SDK versions, dependency pins and save-sync configuration
are unchanged. Use only dedicated test accounts and disposable simulators;
joining an RTC identity already used elsewhere can interrupt its session.

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
python3 -B PrototypeTools/full-app-gameplay.py \
  --xctestrun /absolute/path/to/BoundCompanionQA_iphonesimulator27.0-arm64.xctestrun \
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
creation. This preflight was added and compiled at the checkpoint; it has not
been executed successfully yet and provides no Agora evidence.

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
