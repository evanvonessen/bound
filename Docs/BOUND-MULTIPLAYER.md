# Bound player-state milestone

Branch: `multiplayer`. VBA-M is the primary reader and runtime for this work.
Keep Bound's existing GBADeltaCore identity and pinned VBA-M source. The earlier
mGBA investigation is historical evidence; its serialized state format is not
used by this implementation.

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

The reader never writes game RAM or exports a battery save. It does not send
network packets or create remote sprites. Disabled capture performs no RAM
reads. The full bank-copy approach establishes a simple coherent-frame contract;
physical-device cost still needs profiling before claiming a performance bound.

## Checks

Use the `BoundIntegrationQA` scheme with `BoundIntegrationTests/PlayerStateTests`
for decoder, borrowed-memory ownership, pointer/slot, invalid-state, admission,
display-clearing and preference export/reset checks. The test also supports an
opt-in actual-ROM cold-boot/movement run in the pinned **VBA-M** core.

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

## Following milestones

Additional fixtures are needed for doors, connected maps, bike/surf/ledge
movement, late-game scripts and save-state restoration in actual VBA-M gameplay.
Only after the local reader is verified should a presence transport and remote
avatar renderer consume its values. Those need map/session agreement, timeout
handling, camera transforms, interpolation and foreground-layer occlusion while
keeping each player's local progress independent.
