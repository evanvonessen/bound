# Friend directions across maps

Validated October 28, 2026 in the paired multiplayer-isolation worktrees.

## Behavior

The route search distinguishes active native exits from dormant warp records.
Pallet Town's event at `(7,9)` is ordinary floor, so it cannot become a direction
target. Every route checks terrain, native objects, story conditions, the entry
region on the next map, and the final approach to the friend. When only the
friend's destination room cannot be projected, directions stop at that room's
verified source-side threshold. They do not assume its cutscene or interior is
traversable, and unknown intermediate rooms remain closed to routing.

Route selection compares walking distance through the maps, including the last
leg to the friend, rather than minimizing map transitions. Directional ledges
retain their one-way movement. Native dynamic return warps remain part of the
search state. Unsupported intermediate scripts or forced movement withhold a route rather
than inventing a shortcut. Unknown destination scripts no longer erase a proven
approach to the entrance, such as Viridian's Pokémon Center.

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
  cutscenes with unsupported effects previously withheld guidance. The updated
  destination-threshold search retains the usable Mart entrance without
  projecting its cutscene.
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

## Destination-script regression checks

The updated production Swift route search passes 42 checks over the same
hash-verified native snapshots, including Pallet Town, Route 1 and Viridian City
guidance toward a friend in the Pokémon Center. Its entry specials and first-visit
cutscene are unsupported by the read-only script interpreter; this previously
removed the whole route even though its approach was walkable. No prior Route 1
visit or cached result is needed. Oak's genuine introductory gate remains blocked.

The graph checks additionally reject an unknown intermediate room, blocked
threshold and stale map identity. Stopping the reader cancels its pending route
worker and clears the cached target so a previous game cannot restore an old arrow.
The preexisting label says “Route unavailable” when a known friend has no proven
approach; it does not declare that player offline.

The initial 42 checks reused recorded native grids with ROM/state hash checks.
A subsequent full run regenerated the native maps and passed all 42 checks plus
11 real native button sequences for town/route seams, doors, stairs and a dormant
warp. Evidence is under `artifacts/multiplayer-isolation/resume-directions-battles/native-route-exits`.
The fixture tool's `--fixtures-report` option also permits a hash-verified pure
rerun. Physical two-phone, WAN, and a naturally played first-new-game visit remain
untested.

Unknown script effects, unsupported forced terrain, and exceptional warp modes
remain conservative route-unavailable cases. The shortest-route comparison
independently enumerates portal choices but shares the production terrain model;
the native button sequences separately verify representative transition physics.
