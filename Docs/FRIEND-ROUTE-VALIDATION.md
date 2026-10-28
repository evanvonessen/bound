# Friend directions across maps

Validated October 28, 2026 in the paired multiplayer-isolation worktrees.

## Behavior

The route search distinguishes active native exits from dormant warp records.
Pallet Town's event at `(7,9)` is ordinary floor, so it cannot become a direction
target. Every route checks terrain, native objects, story conditions, the entry
region on the next map, and the final approach to the friend. There is no fallback
that assumes unverified remote exits are open.

Route selection compares walking distance through the maps, including the last
leg to the friend, rather than minimizing map transitions. Directional ledges
retain their one-way movement. Native dynamic return warps remain part of the
search state. Unsupported scripts or forced movement withhold a route rather
than inventing a shortcut.

Either player's tile movement requests a new route. Map identity, return-warp,
and elevation changes invalidate the prior result immediately. Searches run on
the existing utility worker; in-map refreshes retain the previous exit while the
new result is computed. This does not change input handling, prediction,
collision, persistence, or the optional Let Pass setting.

Same-map directions still point directly toward the friend. The existing
viewport check hides the arrow whenever the friend is at least partially in
frame, including across a visible connected-map seam.

## Exact pair and evidence

- Game source: `9baa64971769f9773a6a34fdf489ce998b634b2c`.
- RRv4.1M build 503 SHA-256:
  `a215add233d8d2f119e29b435605d3af99d063180d6b77310f178dfcdebf0ba2`.
- Game/core contracts, ROM identity, save formats, and dependency pins are
  unchanged. This is an app-only change.
- Private native fixtures, test logs, result bundles, and delivery records live
  under `artifacts/multiplayer-isolation/friend-route-exits` in the parent
  workspace. No ROM, save, emulator state, or build output is committed.

Native fixtures use disposable state copies and native map-loading/story-setting
functions. They do not represent playing through the story, a physical-device
test, or a live two-player WAN session.

## Acceptance checks

- 35 production route checks cover Pallet Town ↔ Viridian City via Route 1,
  each adjacent crossing, both players moving, house floors, and Viridian Mart
  in both directions. Exhaustive valid seam combinations confirm the chosen
  exits have the shortest walking costs in the tested fixtures: 90 tiles
  northbound and 72 southbound, including directional ledges.
- 11 actual native button sequences verify map changes through outdoor seams,
  doors and stairs, and confirm walking onto Pallet `(7,9)` never warps.
- The baseline bad `(7,9)` target reproduces when Oak blocks the real north
  exit. The same progressed fixture already chose the north exit in the old
  build, but used its unchecked fallback. The new code proves that route through
  native access checks and withholds the blocked pre-Oak route. Pre-parcel
  cutscenes with unsupported effects also withhold guidance.
- Graph checks include a faster route with more map transitions, final approach
  cost, changing the preferred doorway when the friend moves, dynamic elevator
  returns, and the exact cartridge's 437 maps and 1,530 portal records.
- 38 simulator tests pass: directional UI with Let Pass hidden, movement/query
  invalidation, connected-map presentation, onscreen suppression, camera edges,
  occlusion, prediction, and presence retention/reconnect behavior.
- Focused access-policy checks pass for active/dormant warps, four ledge
  directions, blocked landings, seam collision, door arrivals, and elevation
  guards. The documented Fastlane Release iPhone build and generated-contract,
  pinned-source, and privacy-manifest checks also pass.
- Exact-ROM routing queries measured approximately 0.1–7 ms in the optimized
  standalone Mac harness, below the existing 200 ms query cadence. This is not
  a physical iPhone performance measurement.

Unknown script effects, unsupported forced terrain, and exceptional warp modes
remain conservative route-unavailable cases. The shortest-route comparison
independently enumerates portal choices but shares the production terrain model;
the native button sequences separately verify representative transition physics.
