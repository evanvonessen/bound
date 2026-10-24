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

A fully offscreen sprite on the same map and elevation becomes a small edge
chevron with the selected friend's name and rounded straight-line distance in
16-pixel tiles. Direction follows the camera center-to-player ray; distance is
between the players' world feet. The whole label stays inset in the viewport.
The overlay ignores input. Offscreen rendering skips sprite pixel rasterization,
and neither indicator layout nor networking runs inside the emulator frame
callback. Camera movement alone restores an already received sprite without
waiting for another peer packet. Different maps/elevations produce neither a
sprite nor an arrow, but their positions remain tracked.

## Disappearance diagnosis

Inspection of the receive buffer, map/elevation admission, camera projection,
foreground masks and sprite clipping found **no two-tile distance cull** in the
current Swift implementation. The confirmed presentation gap was that the
rasterizer clipped all pixels outside 240×160 and hid its overlay, with no
offscreen representation. A defensive interpolation path could also return no
pose on a discontinuity; it now selects the confirmed sample. These changes do
not bypass map, elevation, ROM or packet validation.

The native ROM audit found no remote sprite lifecycle or proximity-based
existence rule either. `source/multiplayer/shared_world/shared_world.c` delegates
collision, trainer and flag operations to the original local game logic.
`source/multiplayer/game/game_runtime.c` publishes local snapshots and reads
shared-world data for presentation policy; Bound owns remote sprite rendering.

The reported approximately two-tile disappearance has not been reproduced on
two physical devices. It must not be attributed conclusively to viewport
clipping without that reproduction: packet loss, a scene-reader failure or a
map/elevation change can still produce distinct absence states. Existing
Connection Check diagnostics report peer-pose availability, map/elevation
agreement, frame resolution and visible pixel count to distinguish them.

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

These deterministic tests do not prove physical-device behavior or upstream
Delta playback parity. Device acceptance still requires two phones moving
independently at 1/3/5/10+ tiles, stationary/moving combinations, all viewport
edges, different maps/elevations, network loss/reconnection, interactions,
foreground occlusion and battles/video sharing during ordinary playback.
