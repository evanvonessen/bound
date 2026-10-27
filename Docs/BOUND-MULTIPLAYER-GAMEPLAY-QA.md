# Full-app multiplayer gameplay acceptance

## Music ownership prevention — October 25, 2026

The follow-up causal trace found an unsafe multiplayer interruption, beyond the
door's stuck-state recovery. `friendDialogueReady` previously checked native
field callbacks and script/control locks, but not the field-message mode at
`0x0203709C` or native window-0 `IsTextPrinterActive` byte at `0x0202004F`.
An unlocked field can still have an asynchronous text printer, including after
its visible message is hidden. Replacing window 0 discards that printer's
remaining text controls.

Native `RenderText`'s PAUSE_MUSIC branch at `0x08005A96` calls
`m4aMPlayStop` at `0x081DD93C`. Its write at `0x081DD954` deliberately sets the
paused bit while retaining track bits. The corresponding RESUME_MUSIC branch
at `0x08005AA4` reaches `m4aMPlayContinue`, whose write at `0x081DD008` clears
that bit. These are valid native operations. An interrupted printer can lose
the second operation, leaving a later native map fade waiting forever.
The text pause/resume branches, text-printer implementation, message-hide
routine, MP2K stop/continue functions and map fade/stop predicate were verified
byte-for-byte against the original reconstruction (`68929966…`). Multiplayer
did not change those audio routines; its additional caller omitted their text
ownership precondition.

The native causal tests create the pause through actual message controls,
not by writing audio status. A disposable native printer task keeps the
asynchronous owner advancing after its window is hidden, isolating replacement
from destruction of the draw task. The same scenario is run with a simulator-only
seam restoring the old admission rule and with the production guard. Old
admission allows the friend prompt to replace the printer and leaves the song
paused. Correct admission queues the prompt, lets A finish the original text,
and observes the original native music resume before opening the prompt and
entering the Mart. This comparison runs in music state 2, where the prior
door-recovery workaround (states 5–7) cannot run.

The prevention now covers native friend prompts, battle/trade preparation and
installation, and Debug R. The host withholds the cartridge's checkpoint-safe
claim while a native message or printer is active, so old cartridges receive
the stronger ownership check too. Pending multiplayer prompts retain ordinary
native A/B input until the underlying owner finishes; opening multiplayer
text still keeps its first-button protection. No ROM identity or save format
changes are needed.

The affected checkpoint's last printer text was the multiplayer friend prompt,
consistent with this reproduced loss of ownership. A checkpoint cannot recover
the original overwritten message or its full historical timing, so that exact
past input sequence remains unrecorded. The test establishes a causal fault in
our multiplayer admission, not proof of which NPC message preceded that save.

Validation: all 117 focused tests passed without failures or skips in
`.build/music-owner-verified.xcresult` (log:
`/private/tmp/bound-music-owner-verified.log`). Both causal cases start with
normally playing native music (`0x1FF`); only the real native text command
pauses it. The fixed case finishes its native resume, admits the queued prompt
and enters the Mart. The legacy-admission control loses the resume before any
door fade. Input tests also verify that queued entry preserves A/B while a
newly opening multiplayer window retains its existing first-button protection.
Debug R checks text ownership on the preceding frame too, because native key
handling can close a printer before the completed-frame callback observes it.

The traversal harness now allows up to three native 2px running steps per host
sample during its 3× fast-forward phase; the normal-speed seam crossings keep
the tighter bound. No production map-rendering behavior changed in this pass.
The Release iPhone build, 17,061 pinned-source checks and 99 source/integration
hashes plus two SDK privacy manifests passed. The legacy-admission test seam and
native text fixture helpers are absent from Release. Fixed-build Mac UI,
physical devices and live two-device network checks remain pending.

## Mart transition and Debug return — October 25, 2026

Historical record: the Debug R warp described below was removed on October 26.
R now remains native in both Debug and ordinary games. The stopped-music repair
remains and was retested against the current paired ROM. See
[nearby-only validation](validation/nearby-only-interactions.md).

The reported build 201 Mac checkpoint reproduced a native door transition
stalled after its fade to black, with the player hidden. The door task at
`0x0807E719` was waiting for map music to stop. MP2K's BGM status at
`0x03007304` was `0x8000003F`: its stopped bit was set while the low active-track
bits remained set. Native `IsBGMStopped` checked only those low bits, but the
stopped audio player could no longer advance the fade that would clear them.

`BoundVBABattleBridge.advanceROMFieldRecovery` runs on the completed-frame
callback for the verified integrated cartridge. In native field callbacks,
outside active link operations/invitations, it clears stale low track bits
only when the music state is awaiting a stop (5–7) and MP2K is already stopped.
The native music and door tasks then finish normally. It never forces a map,
palette, script, task or visibility state forward. Live songs and ordinary
fades retain their native timing. This applies to other native field transitions
using the same music-stop path, not only the Viridian door.

The same bridge consumes a new R press in an admitted Debug game with an idle,
visible field and applied settings. It starts an ordinary native warp script to
Pallet Town (`3:0`, tile `16,14`, outside Oak’s lab). Native dialogue, battle,
trade, invitations, save/recovery/transfer/end states and fades exclude the
shortcut; it never replaces an active story script. Normal games ignore the
shortcut. The script lives in idle link scratch and survives native checkpoint
serialization. A held-key edge is tracked on the emulator owner because native
scripts can consume the one-frame `newKeys` value before Bound's callback.
Holding R does not trigger repeated warps or queue a warp after a blocked action.

The connected-map regression also exposed a combined presentation phase: on
Route 1 → Pallet, the ObjectEvent still held tile `(12,40)` / previous `(12,39)`
while the newly rebased camera was `(12,-1)`. The renderer now accepts the exact
connected-map offset when either the destination or previous tile matches the
camera. Existing one-tile, running-state and map-identity checks still apply;
the boundary's native pixel residuals use the rebased destination tile rather
than the lagging saved camera tile. Interaction admission remains strict.
The regression avoids grass encounters
and waits for its setup warp to finish before measuring boundary rendering.

Both fixes preserve the build 201 integrated ROM hash
`8bf5b9675e0e34e785b0a40eb2d8120a1d2d6874890c4f6d2f43b5d1d3ab90fb`
and existing server-state format. An app update is sufficient; the affected
checkpoint does not require a new cartridge or a reset. No user checkpoint or
app data is included in source control.

Validation: 93 focused simulator tests passed with zero failures or skips,
including fresh Mart entry, a stopped-music fault injected before the door,
the previously stuck Mac checkpoint, Debug-off R behavior, parcel-dialogue
protection, holding R through the return warp and restored field controls.
The connected-map presentation, player-reader, live-presence and ROM-contract
suites passed together. Receipt: `.build/mart-field-recovery-acceptance.xcresult`;
log: `/private/tmp/bound-mart-field-recovery-acceptance.log`.
The unsigned Release iPhone build, 17,061 pinned-source checks and 99
source/integration hashes plus two SDK privacy manifests passed. The private
checkpoint is optional QA input; the injected fault regression requires only
the owned cartridge and creates a disposable battery. Fixed-build Mac UI,
physical iPhones and live two-device network validation remain pending.

## Checkpoint recovery regressions — October 24, 2026

The updated Nakama client, save-package, disconnect-save and Soul Link suites
passed 142 tests with no failures or skips. They cover withholding new catch
facts until their native checkpoint is sealed, death delivery while catches are
pending, lost upload replies, and history polls delayed across one or more local
seals. A late poll cannot retry an obsolete package or replace a newer confirmed
head; a fresh stable poll still rejects a different device's checkpoint.

The backend passed 99 tests, including the pre-starter/post-starter checkpoint
transition, atomic acquisition/head publication, failed storage transactions,
concurrent death events, immutable replay conflicts and older-client API
compatibility. These checks do not reconstruct missing Pokémon from historical
slot-only events or establish two-phone crash/reconnect behavior.
The final Debug build, unsigned Release iPhone build, 17,061 pinned-source
checks and 99 source/integration hashes plus two SDK privacy manifests passed.

## Native snapshot memory regression — October 24, 2026

`NativeBattleRuntimeTests.testActualFrameSnapshotsReleaseTemporaryMemory`
passed on the owned QA A simulator with integrated v5 cartridge
`433e308025f5ec0dfc389f323092de35fbbc19dfcb9046656d4de0245523e271`.
The test admits a fresh game on a disposable battery, pauses the core in the
overworld, and reads the actual native Soul Link snapshot repeatedly from one
worker turn. No save, party, frame or caller-retained buffer changes between
observations. It opts in with `BOUND_FRAME_MEMORY_RUNTIME=1`.

The control accumulated **46,759,936 bytes** of resident memory over 1,024
snapshots without a per-frame autorelease pool. The production
`BoundFrameMemory.perform` scope completed 4,096 snapshots with **0 additional
bytes of measured peak resident memory** after warmup. All 5,376 observations,
including warmup, contained the expected 43,500 PC-box bytes and a valid native
overworld. This proves the temporary Foundation objects are drained between
Bound frame callbacks; upstream Delta core sources and pins remain unchanged.

Receipt: `.build/native-frame-memory-v5.xcresult`; execution log:
`/private/tmp/bound-frame-memory-runtime.log`. The single focused runtime test
passed in 2.474 seconds. These measurements establish a reproduced allocation
bug and its bounded-memory regression, not physical-device performance or the
cause of a particular phone termination. The reported iPhone 14 Pro Max crash
log was unavailable because that device was not connected; the connected
iPhone 17 Pro Max had no matching crash or jetsam report for that day.

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
