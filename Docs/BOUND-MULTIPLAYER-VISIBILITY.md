# Multiplayer player visibility

## Presence and presentation

Presence remains independent of camera distance. `BoundLivePresenceSession`
receives, validates and retains world positions even when the remote player is
outside the local viewport or on another map/elevation. Its existing monotonic
sequences, session challenges, ROM verification, stale-packet rejection and
reconnect presentation grace remain in force. No acknowledgment was added to
movement. The transport still coalesces stale position updates.

The 32-pixel continuity threshold compares successive samples from the remote
player. It does not compare the remote player with the local player. A larger
step replaces the smoothing history and presents the confirmed new position;
it never removes the player. Recorded playback likewise holds its last sample
across a large same-map step instead of creating an empty interpolation frame.
Actual recording gaps and incompatible map/elevation transitions stay hidden.

`BoundPlayerViewport` projects remote world feet through the viewer's current
camera. Rasterization and viewport classification use the same rounded sprite
origin. A sprite intersecting the original 240×160 viewport is rasterized with
the existing background/object occlusion, flips and animation frame. It is not
replaced with an arrow when a tree, NPC or native field window covers it.

A fully offscreen sprite on the same or cardinally connected map and elevation becomes a small edge
chevron with the selected friend's name and rounded straight-line distance in
16-pixel tiles. Direction follows the camera center-to-player ray; distance is
between the players' world feet. The whole label stays inset in the viewport.
The overlay ignores input. Offscreen rendering skips sprite pixel rasterization,
and neither indicator layout nor networking runs inside the emulator frame
callback. Camera movement alone restores an already received sprite without
waiting for another peer packet. Native cardinal map connections translate a
friend's map-local coordinates into the viewer's map before projection. Door,
warp and dive destinations, disconnected maps and different elevations produce
neither a sprite nor an arrow, but their positions remain tracked. Presentation
projection never grants cross-map interaction authority.

## Disappearance diagnosis

The October 24 report of a friend partially or completely disappearing **inside
the viewport** exposed a separate BG0 window-mask bug. Native
`ClearWindowTilemap` selects transparent tile 0 but preserves its palette:
cleared border/text cells contain `0xE000`/`0xF000`, not necessarily zero. Bound
incorrectly treated any nonzero entry as an occupied window tile. The cleared
dialogue rectangle therefore kept erasing the friend's pixels as either player
or the camera moved through it. Coordinates and incoming poses remained valid.

Window occupancy now tests the ten-bit tile index, ignoring palette and flip
attributes. Real open windows, borders, foreground map pixels and nearer native
objects retain their occlusion. This fixes the false mask without moving the
friend, changing the native framebuffer or relaxing packet/map validation.

There is no two-tile distance cull in the current receive or projection code.
The earlier work added an offscreen representation and removed an empty-pose
interpolation case. Those changes did not fix this window-mask defect, and the
earlier synthetic camera tests did not model native cleared-window attributes.

The native ROM audit found no remote sprite lifecycle or proximity-based
existence rule either. `source/multiplayer/shared_world/shared_world.c` delegates
collision, trainer and flag operations to the original local game logic.
`source/multiplayer/game/game_runtime.c` publishes local snapshots and reads
shared-world data for presentation policy; Bound owns remote sprite rendering.

The later Pallet Town → Route 1 report exposed a different reader defect. Bound
required the player's object spawn-map bytes to equal the current map. The
native seamless camera transition keeps that object alive: function
`UpdateObjectEventCoordsForCameraUpdate` (`0x0805F82C`) rebases its origin,
current and previous coordinates, but leaves its spawn map unchanged. The reader
therefore rejected every subsequent Route 1 frame and retained the last Pallet
pose; returning to Pallet made the stale identity check pass again.

The current map now comes from the save location and its matching verified map
header. Unique player-object ownership, sprite ownership, coordinate agreement,
fade/battle guards and consecutive completed-frame validation remain required.
Signed border pixels are accepted during a step across a map seam. Cardinal
connection geometry is read from the verified ROM and cached outside the frame
owner. Nearest connection paths take precedence over longer paths; conflicting
equally short paths are withheld because some cartridge loops do not form one
consistent global grid. Interior warps are never treated as geometric edges.

Physical-device verification remains pending. Packet loss, a scene-reader
failure or an unrelated map/elevation change can still produce distinct absence states.
Existing Connection Check diagnostics report peer-pose availability,
map/elevation agreement, frame resolution and visible pixel count to distinguish
them.

## Expanded rendering

The current pipeline receives the native GBA's 240×160 framebuffer and reads
the map layers/objects needed to mask overlays. Enlarging the `GameView` only
scales those pixels. It does not make the ROM load or render additional map
content, sprites or animations. Reconstructing a larger map renderer would need
additional ROM scene logic, map loading and camera validation and could diverge
from the original game. Expanded rendering is therefore not implemented. The
native viewport, core and performance baseline remain unchanged.

## Regression and device validation

`LivePresenceTests` covers retained coordinates at 1, 3, 5, 10 and 30 tiles,
large position steps, map/elevation changes, packet sequencing and existing
disconnect/reconnect validation. `RecordedPlayerTests` covers camera-only
reentry, partially visible edge sprites, arrow direction/inset placement, live
distance changes, overlay switching and foreground occlusion.

The window-clear regressions exercise all 64 combinations of palette/flip
attributes on tile 0, native dialogue open/close, and every pixel of horizontal
and vertical camera movement through the cleared bedroom dialogue rectangle and
the viewport edges. The open/close and camera regressions fail before the fix.
The opt-in VBA-M recording test also checks actual native cleared window cells
while walking in all four directions. Both native reader/replay tests now use
the current Bound New Game host ABI, wait for the intro to release controls,
and enable/restore their diagnostic preferences. Their exact-ROM/battery
fixtures remain private and are copied before use. A native bedroom mGBA capture independently
confirmed that the retained palette-only entries refer to a fully transparent
BG0 tile 0.

October 24 validation: 47 focused presence, reader and rasterizer tests passed,
including both native VBA-M tests with integrated ROM SHA-256
`d2a206998f67db500f88ccc197fc9977ebd437f714661916abbc7b484e38370a`.
The Release iPhone build and pinned-source/privacy checks passed.

The connected-map regressions cover continued movement after the current map
changes while object spawn identity remains unchanged, return crossings,
Pallet/Route 1/Viridian offsets, all four cardinal directions, negative border
pixels, disconnected interiors and ambiguous connection paths.
The expanded presence, reader and rasterizer suites passed all 51 tests against
the integrated v5 cartridge on October 24.
`PrototypeTools/qa-python PrototypeTools/test-presence-map-boundaries.py --rom
<owned-integrated-rom>` also executes the original cartridge rebase function
for six crossing/return offsets and proves that it preserves spawn identity.
These new checks do not constitute a paired physical-device map-crossing test.

These deterministic tests do not prove physical-device behavior or upstream
Delta playback parity. Device acceptance still requires two phones moving
independently at 1/3/5/10+ tiles, stationary/moving combinations, all viewport
edges, different maps/elevations, network loss/reconnection, interactions,
foreground occlusion and battles/video sharing during ordinary playback.
