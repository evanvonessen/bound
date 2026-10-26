# Bound multiplayer milestones

On `main`, first enable **Settings → Enable Experimental Features**, immediately
below Enable Developer Features, on both devices. It defaults to off. Disabling
it stops experimental presence and invitations and restores an active battle;
ordinary account/video sharing stays available. See `BOUND-EXPERIMENTAL-FEATURES.md`.

Branch: `multiplayer`. VBA-M is the primary reader and runtime for this work.
Keep Bound's existing GBADeltaCore identity and pinned VBA-M source. The earlier
mGBA investigation is historical evidence; its serialized state format is not
used by this implementation.

The [full-app gameplay acceptance](BOUND-MULTIPLAYER-GAMEPLAY-QA.md)
passed on October 20, 2026: two ordinary Bound simulator UIs over real Agora,
door/map changes, independent native save-state creation/restoration, background
recovery, sustained >=900-second gameplay with renewals and normal UI stop.
Physical-device and separate-network acceptance remain described in
[device acceptance](BOUND-MULTIPLAYER-DEVICE-QA.md).

## Battle and trade invitations

The [overworld interaction layer](BOUND-MULTIPLAYER-INTERACTIONS.md) starts when
a player stands on the adjacent tile, faces their friend and presses A. It
supports real accept/decline/cancel messages over a separate reliable Agora
stream. **Native battles and Pokémon trades are not implemented yet.** The UI
labels this as invitations only; accepting does not change game data.

## Use the local display

In Settings → Controls, enable **Player state display**, then resume a GBA game.
A compact card over the gameplay area shows the engine, reader status, map
group:number, map-local tile position, and facing. The card does not intercept
game controls. Rotate the device normally; it follows the gameplay viewport.
The preference is off by default, included in Export All Config, and cleared by
Reset Settings to Default. It is a regular setting, independent of retired
experimental-feature preferences.

The supported image is RR4.1 damage-calculator variant SHA-256
`689299664a954c12dad66e03c2d18446b348cb31bd98b395c87b9b514b288066`.
Other GBA images show **Unsupported ROM** and are never decoded. A filename or
Bound's SHA-1 game identifier is not used as a substitute for this check.

## Reader contract

- The ROM file is mapped and SHA-256 checked once per playback binding, off the
  emulation/main threads. Disabled bindings do not start profile loading. A
  profile already loading or cached can be retained when the display is turned
  off; capture remains disabled.
- Capture occurs synchronously on Delta's existing `updateHandler`, after each
  completed VBA-M frame, including frames without rendered video. Existing
  achievement and video-sharing callbacks remain chained.
- GBADeltaCore's read API uses an achievement address space: offset `0` exposes
  32 KiB IWRAM and offset `0x8000` exposes 256 KiB EWRAM. It returns borrowed
  memory. The adapter bounds the two requests and copies both banks into owned
  arrays before the next frame, then resolves GBA addresses inside those copies.
  Raw GBA bus addresses must never be passed directly to that bridge API.
- The exact-ROM decoder follows the live save pointer and player object/sprite
  slots, validates map-header identity against the ROM, normalizes the seven-tile
  border and checks that save/object coordinates agree. During movement, the
  current tile is the destination; the previous tile is retained separately.
- Battle, menu/loading, fade, fully obscured-field and invalid/hidden-player
  samples contain no player position. Two consecutive valid captured frames on
  the same map are required before displaying **Live**. The frame counter is
  local to the reader's current capture generation.
- Pause, stop, app inactivity, ROM switches and restored save states invalidate
  admission. Late results from another binding/generation are discarded.
  A latest-value mailbox is consumed on main at 10 Hz; no per-frame main-queue
  task or unbounded capture queue is created. If frames stop arriving, the card
  drops coordinates and reports **Waiting**.

The reader never writes game RAM or exports a battery save. Networking is owned
by the opt-in live presence session below. Disabled capture performs no RAM
reads. The full bank-copy approach establishes a simple coherent-frame contract;
physical-device cost still needs profiling before claiming a performance bound.

## Record and replay a second player

While a GBA game is open, use the Bound menu's **Settings → Controls → Recorded
player** section:

1. Choose **Record movement**, close Settings and resume the game. Walk a short
   route on the map. The optional player-state card can remain off.
2. Open the pause menu to finish recording, or let the 30-second limit finish it.
3. Move your player somewhere else, then choose **Replay recorded player** in
   the same Settings section and resume. The second player follows the recorded
   route while you move independently. Replay finishes at the recording's end.
4. Use **Stop replay** or **Clear recording** as needed. Leaving the game clears
   the recording. Recordings are memory-only and are not synced or exported.

This milestone supports ordinary on-foot, 16×32 player sprites in the exact ROM
profile above. Unsupported movement/graphics, menus or scripts that lock field
controls, invalid reader states, pause, app inactivity and stale captures hide
the replay. Playback waits during unavailable local scenes. A map or elevation
mismatch hides the recorded player. Loading a save state stops replay and
requires explicitly starting it again; the recorded route is retained.

### Coordinates and artwork

VBA-M remains the only runtime reader. The native sprite's `x/y`, animation
table, image table, flip bits and current faded palette provide pixel positions
and walking frames. Character images are decoded from the user's loaded ROM at
runtime; no ROM artwork, ROM image or recording is bundled.

World positions use native GBA pixels, with feet at tile origin + `(8, 16)`.
During a step, derive each axis of the viewer's camera translation as:

```
(7 - saveTile) * 16 - cameraResidual + sign(cameraResidual) * 16
    + signed16(spriteCoordOffset - totalCameraPixelOffset)
```

The residual is `gFieldCamera.x/y` at `0x03005060/64`; total camera offsets are
at `0x0300506C/68`; sprite offsets are at `0x02021BC8/CA`. Signed wrap is handled
before calculating the translation. Subtract this translation from the local
sprite's screen feet to obtain a smooth map-local pixel position. Validate it
against the current/previous tiles. The recorded route stores world points,
appearance and map/elevation identity; it never stores the viewer's camera.

A 60 Hz main-thread consumer records/presents the latest coherent VBA-M sample
only while recording or replaying. There is no per-frame task queue. Recorded
frame numbers drive playback; small missing samples interpolate only within a
continuous map/elevation segment. Gaps and warps never interpolate. Both duration
and sample count are bounded to 30 seconds / 1,801 samples.

The sprite is a touch-transparent child of the live `GameView`, clipped to its
native 240×160 viewport and scaled with the gameplay view. It does not modify
RAM, the ROM, the framebuffer, save files or native object/sprite slots. Current
foreground BG tilemaps, scroll registers, ROM tile graphics and sprite priority
mask the replay per pixel; nearer visible object sprites also mask it. Note the
game's naming: `gBGTilemapBuffers2` is **BG1**, and `gBGTilemapBuffers1` is **BG2**.
ROM tileset decompression is bounded and cached for at most eight layouts.

The mask uses the ROM's base tiles and ordinary object frames. Animated terrain
tile replacements, reflections, grass effects, bridges with different elevation
rules, large/affine/subsprite objects and image-warping video filters need
additional support and gameplay fixtures. Device performance and exact visual
timing relative to presented Metal frames still require device validation.

## Live friend sprites

Connect to the same friend using Bound's existing **Friends** flow. Enable
**Live player sprites → Show friend on map** on both instances, then resume
supported GBA gameplay. This control also appears in **Settings → Controls**
while a GBA game is open. It starts off and is held in memory for the current
coordinator; it is not exported as account or gameplay data. Reset Settings
turns it off. The diagnostic player-state card can stay off.

The production transport uses a data stream in the existing authenticated
Agora room. Presence requires that friend connection, so its current video
sharing still runs. No new server, database change or credential is introduced.
Only the room's expected peer UID is admitted. The SDK callback copies at most
one bounded pending packet, polled on main even when friend video is hidden.

Each JSON packet is at most 768 bytes, sent at most 20 times per second during
normal operation. It contains protocol/ROM identity, sender and acknowledged
receiver session UUIDs, increasing sequence and monotonic send time, plus an
optional pose: map, elevation, world feet, facing, ROM sprite-frame address,
flip/priority and 32 palette bytes. Each instance SHA-256 verifies its own ROM;
unknown or incompatible profiles cannot advertise a live pose. Sprite tile
artwork is resolved from the receiver's local ROM. No RAM bank, framebuffer,
controller input or save is sent or applied in presence packets. A separate
[shared progression protocol](BOUND-SHARED-WORLD-PROGRESSION.md) now supplies
bounded predicates for native collision and trainer prerequisite gates.

Before displaying poses, both peers acknowledge the other's current session.
An unacknowledged hello cannot replace a verified peer; incompatible ROM changes
also invalidate queued poses. Ordinary video sessions publish no presence while
live sprites are opted out.
The receiver keeps at most eight samples, uses a 100 ms interpolation delay,
rejects duplicate/out-of-order/old-session and excessively delayed packets,
and never interpolates across maps, elevations, warps or large sample gaps.
It holds the latest position only briefly, with no extrapolation. A 750 ms
receive timeout clears the peer and starts a fresh handshake. A received
unavailable pose clears immediately. Pause, battle, locked/unsupported scenes,
stale reader frames, app inactivity, core/ROM changes and restored-state
invalidation withdraw local coordinates and hide the local overlay. Transport
recovery, sign-out, room changes and stop clear session state.

Both emulators keep running their own games. The remote sprite uses the local
camera and existing foreground/object masking. This milestone retains the
validated on-foot/16×32/exact-ROM limits documented above.

`LivePresenceTests` covers wire bounds, handshake, clocks, ordering, jitter,
warp/elevation discontinuities, stale/retired sessions, opt-out and friend-session
recovery. `LivePresenceRuntimeTests` is opt-in and runs two separate Bound test
hosts with actual VBA-M cores, separate disposable batteries, independent walks,
and production readers, presence sessions and overlays. Its bounded loopback
HTTP transport substitutes for Agora; it does not prove the Agora data path,
Internet service, physical-device behavior or full-app navigation.

After building `BoundIntegrationQA` with `build-for-testing`, stage the private
ROM and seed in each dedicated Simulator's app container as described below.
Run the paired acceptance harness with unique output paths:

```sh
PrototypeTools/qa-python PrototypeTools/live-presence-relay.py \
  --xctestrun /absolute/path/to/BoundIntegrationQA_iphonesimulator27.0-arm64.xctestrun \
  --sim-a <dedicated-A-UDID> --sim-b <dedicated-B-UDID> \
  --output /absolute/path/to/new-run-directory
```

The harness checks independent walking, A pausing while B keeps playing,
resume, network outage/recovery, and restored-state admission invalidation.
It writes only metadata; test screenshots and disposable saves remain private
in the Simulator. Actual save-state loading and Internet friend sessions need
their own validation.

## Checks

Use the `BoundIntegrationQA` scheme with `BoundIntegrationTests/PlayerStateTests`
for decoder, borrowed-memory ownership, pointer/slot, invalid-state, admission,
display-clearing and preference export/reset checks. The test also supports an
opt-in actual-ROM cold-boot/movement run in the pinned **VBA-M** core.

`BoundIntegrationTests/RecordedPlayerTests` checks pixel camera continuity,
signed wrap, 4bpp sprites/flips, bounded LZ77, recording gaps, map/elevation
agreement, lifecycle clearing and foreground/object occlusion. Its opt-in VBA-M
test records four walking directions, moves the viewer independently, and
checks that the recorded player remains visible and moves while the camera
changes. Screenshots and JSON diagnostics stay in the private fixture directory
and ignored `.build/recorded-player-validation/` output.

The camera recording test now creates a unique blank battery input and uses the
current host ABI to request a native Debug New Game. It checks the actual
trainer, starter and completed setup before walking. The blank input is only
cold initialization data; this test does not establish battery-save restoration
or replace the older reader test's explicit seed-fixture requirement below.

The actual-ROM test reads only private copies installed in the dedicated QA
app's Documents/MultiplayerValidation directory:

- `RadicalRed.gba`: a copy whose SHA-256 must match the exact profile above.
- `seed.sav`: a disposable generated 128 KiB battery fixture in the post-rival
  lab, map `(4, 3)`, tile `(7, 8)`. The historical generated new-game battery
  fixture is reused as input data, not as an emulator state or reader.

The test copies the seed to `vbam-test.sav`, cold-boots VBA-M, navigates Continue
with controller inputs, checks the first map/position, walks in four directions
and checks that positions change. It writes a local `vbam-reader-report.json`
and verifies the ROM and seed battery hashes remain unchanged. These files are
not bundled or committed. A normal test run skips only this opt-in case when
private fixtures have not been installed; actual runtime validation must report
whether that case ran or skipped. Do not use a personal save as this fixture.

Before publishing, run the source-integrity check, focused hosted tests and the
required unsigned Release iPhone build. Build/test output stays under ignored
`.build/multiplayer-validation/`. Simulator/runtime evidence is separate from
physical-device validation.

Validated on October 20, 2026 with Xcode 27.0 and an iPhone 18 Pro simulator:

- All 18 focused hosted tests passed with no skips: `PlayerStateTests`,
  `ConfigurationExportTests` and `SettingsResetTests`.
- The actual-ROM test ran in VBA-M, reached map `4:3` at `(7, 8)`, observed
  movement and all four facings, displayed **Live**, and cleared coordinates on
  pause. It used the production profile loader, probe and HUD in a hosted test
  canvas; this is not a physical-device or full-app UI-navigation receipt.
- `PrototypeTools/verify_sources.py` verified 17,060 pinned source files.
- The unsigned `Bound` Release build for generic iOS succeeded. No physical
  device performance or multiplayer network session has been validated.

The recorded-player milestone was also validated on October 20, 2026:

- All 25 focused tests passed with no skips, including both private actual-ROM
  VBA-M cases. The new case recorded and replayed four walking directions,
  observed 12 distinct sprite frames, moved the viewer independently and
  captured two separately positioned player sprites with a scrolling camera.
- Recording worked with the diagnostic card disabled. Pause hid the replay,
  restored-state invalidation stopped it, and the input ROM/seed hashes remained
  unchanged. Unit checks additionally cover recording gaps/end-of-track,
  map/elevation gating and per-pixel foreground/object masking.
- Source integrity verified 17,060 pinned files and the unsigned Release iPhone
  build passed in an isolated checkout containing this milestone on `7dd7163b`.
  This excludes the accidental performance commit. The hosted test canvas is
  simulator evidence; full-app UI navigation and device performance remain
  separate validation work.

The live-presence milestone was validated on October 20, 2026:

- All 42 focused hosted tests passed without failures or skips, including the
  private actual-ROM VBA-M reader/replay cases, ten presence tests, settings
  export/reset and seven existing video-sharing/recovery checks.
- The paired runtime case passed in two separate Bound hosts with actual VBA-M
  cores and separate disposable batteries. A/B displayed 62/59 distinct remote
  positions and 83/89 camera positions. Each capture showed two independently
  positioned sprites. The largest relayed packet was 426 bytes.
- A paused while B continued playing; both overlays cleared appropriately.
  Resume, transport outage/recovery, restored-state admission invalidation and
  stop passed. ROM, seed and each disposable battery hash remained unchanged.
  The diagnostic card stayed off during the live exchange.
- Source integrity verified 17,060 pinned files and the unsigned `Bound` Release
  build for generic iOS succeeded. Runtime proof uses the test-only loopback
  transport and hosted game canvas. Authenticated Agora data-stream delivery,
  Internet sessions, full-app navigation, actual save-state loading and physical
  device performance/presentation remain separate acceptance work.

## Following milestones

The device-acceptance preparation adds opt-in connection reports and a
separate QA app identity without changing the existing cloud setup. See
[device QA preparation and pending acceptance](BOUND-MULTIPLAYER-DEVICE-QA.md).
Real authenticated Agora delivery has now passed on two Bound simulators with
actual VBA-M gameplay, native video, multiple token renewals, pause/resume and
explicit disconnect/rejoin. Both final native tests and Xcode processes passed;
the local pose relay was disabled. Temporary QA friendships were removed and
original active friend lists restored. Cloud settings/deployments were unchanged.
Two physical devices are unavailable; physical and separate-network acceptance
remains open.

Door exits and native save-state restoration now pass through the ordinary
Bound UI over real Agora; see the full-app acceptance evidence above. Broader
connected-map routes, bike/surf/ledge movement and late-game scripts still need
additional fixtures. The live presence implementation feeds this renderer through
the existing friend room. Further acceptance includes authenticated Agora across
separate networks, physical-device cost/presentation timing and those broader
world fixtures. Each player's earned progress remains independent;
[shared world gates](BOUND-SHARED-WORLD-PROGRESSION.md) can wait for both players.

## Soul Link party-wipe return — October 24, 2026

A full usable-party wipe ends a normal Soul Link run. One faint alone does not.
Friendly battle RAM is fenced out; eggs and boxed Pokémon do not count as living
party members. Cooperative battles use the cartridge's owned-party projection,
excluding borrowed partner records. Unknown HP does not count as a faint.

The Game Over overlay says “Press A to return to menu.” A persists return intent
and presents the menu. The server deletes that exact run only after both
authenticated participants acknowledge visible menus; offline returns retry from
owner-scoped durable receipts. The terminal run rejects new gameplay writes.
Minimal tombstone metadata supports retries after deletion without retaining
gameplay snapshots. Menu acknowledgements wait until covering sheets are closed
and the app is active.

Settings version 5 adds a Debug-only “Game Over on Party Wipe” toggle, default
off. Off disables the whole automatic Game Over/delete flow. Normal mode and
legacy settings keep the flow enabled. Byte 21 is the inverted Debug override;
the app, cartridge and server validate the same contract.

## Map visibility review — October 25, 2026

Live sprite presentation no longer requires matching player elevations. The
native sprite priority still controls scenery occlusion; collision and friend
interaction admission retain their existing map/elevation checks. Unconnected
rooms are still separate. Elevation mismatch previously returned no sprite even
when both positions were inside the same visible map.

`RecordedPlayerTests.testActualPalletRouteOneCrossingKeepsDecodedScene` cold-boots
the current owned cartridge in VBA-M, uses a native warp to Pallet's entrance,
then walks north into Route 1 and south back into Pallet with ordinary input.
The disposable fixture skips Oak's initial stop using native `setvar 0x4050, 1`;
it does not alter map connections or movement. Captured RAM scenes travel through
the presence encoder/receiver and render from both the waiting and moving
player's viewpoints. The test checks scene availability, map changes and pixel
coverage, allowing the visible native area-name popup to cover sprite pixels.
Frames and the initial native map image are saved only in the QA app container.

The separate elevation regression exercises every native elevation value while
preserving interaction checks. These are local simulator and protocol checks;
they do not establish physical-phone or separate-network acceptance of the
reported Pallet/Route 1 disappearance.

This pass also ran 108 focused integration tests and the ordinary Release iPhone
build. Two isolated simulators passed a friendly battle with an initially fainted
party, a three-second silent packet outage, Run and restoration of the original
party. They also completed a trade interrupted during exchange by the same silent
outage, returned to the field, and reopened the received Pokémon from native
server-state/battery captures. Those paired tests use a host-loopback relay, not
the live service or physical phones. No additional battle/trade defect was
reproduced in these cases.


### Connected running regression (October 25, 2026)

`PrototypeTools/live-presence-relay.py --boundaries` runs two separate VBA-M
cores in disposable simulators through the production friend session, presence
packets, profile loader, frame probe and native video compositor. It uses fresh
native Debug New Game setup (including Infinite Repel) and a QA native warp to the Pallet/Route 1 entrance. A runs
with shoes at 3× while B remains at 1×, then B runs while A stands still. Each case starts at the same entrance; between cases the first runner returns
there through the native QA warp. No pause or warp occurs during measurement.
Four north/south excursions and
horizontal running exercise the connected seam; each observer records every
composited frame, including unavailable poses. Input changes occur only on the
emulator owner. The fixture ROM and seed hashes must remain unchanged.

Assertions cover missing scene/peer frames, in-view sprite disappearance with
native clipping and map-name UI accounted for, actual Route 1 traversal, and
zero stationary-peer world-coordinate drift after projecting into a fixed map.
The relay writes scalar reports only. It is a local test transport, not an
authenticated Nakama or separate-network test, and does not establish physical
phone playback parity. Cross-map-group and one-way geometry remain covered by
focused connection tests; the native route exercised here is Pallet/Route 1.

The repeated native run exposed a second boundary-frame ordering case: the save
and map header have switched, but ObjectEvent coordinates are still in the old
map basis. Presentation now accepts only a one-tile exit from a directly
connected map that translates exactly onto the saved camera position. Ordinary
interaction decoding remains strict. Arbitrary mismatches, interior positions,
nonadjacent maps and larger jumps still fail admission.

The final paired run passed both cases: 3,433 observed presentation frames,
331 frames projecting across the seam, and 425 clear in-view road frames.
There were zero missing scenes, missing projected peers, unexpected visible
sprite disappearances or missing-pose samples. The stationary peer's position
had zero world-coordinate spread from each running viewer. Five repeated native
boundary runs also passed. The 107 focused scene/presence/battle/setup tests,
four fast-forward preference tests, native Debug and ordinary cold starts for
both roles, native menu/ACK checks, source/privacy checks and unsigned Release
iPhone build passed. Local output is in ignored `.build/paired-boundary-verified/`
and `.build/paired-regression-verified.xcresult`.
