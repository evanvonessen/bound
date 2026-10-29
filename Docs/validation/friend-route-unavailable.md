# Friend-arrow unavailable routes — October 28, 2026

The reported Pallet–Viridian Center sequence reproduced a temporary one-way
failure during the Center exit animation. A stable one-way failure also occurred
after continuing west to a wandering NPC's vacated tile. Both causes are fixed
in the app's destination approach calculation.

## Reproduction

P1 remains at Pallet (10,10). P2 walks through Route 1 into Viridian, enters the
Center, opens the PC, withdraws Pikachu, closes the PC, and walks outside. The
entire journey after initial fixture preparation uses ordinary emulator buttons.
The withdrawal is verified by the exact Pokémon identity in the party, party
count changing from one to two, and the original PC slot becoming empty.

Production state decoding, scene decoding, `BoundPresencePose`, and routing run
against the resulting native snapshots. Both directions are checked separately
at every recorded map transition, including building entry/exit. Additional
samples cover the PC return and every four frames of the Center exit. Hidden
and menu samples are reported separately, not counted as visible arrows.

Before the fix at `250f10ccc7dcb79da5a9fe9bec247d7db697f9b9`:

- Exit frames 88/92 publish P2 at door tile (26,26). Frames 144–156 still publish
  sprite feet over that tile while the native destination tile is already
  (26,27). P1 has no route; P2 routes back to Pallet.
- The hidden middle of the animation is correctly withheld. It is not evidence
  of a displayed arrow failure. At frame 160 the sprite reaches the outside
  tile and the old route recovers.
- Continuing west to (16,22) produces another forward-only failure. It remains
  after standing there for 600 emulator frames. P2 can occupy this tile because
  the wandering NPC has moved, while P1 projects the NPC at its template origin.
- A separate sweep of 1,418 reachable positions across Route 1, Viridian, the
  Mart, and both home floors finds three forward-only failures: Route 1 (6,28),
  Viridian (16,22), and the Mart (6,2). These are hypothetical position probes
  on actual captured terrain, not claims of walking to every tile.

## Fix and validation

The last route segment may approach a verified active doorway or stop next to
a friend's tile occupied by an independently simulated NPC. It reuses the
existing walking search, including its elevation state, rather than treating
an adjacent position as automatically reachable. The target is terminal: the
search cannot continue through its NPC or an automatic warp.

Focused regression checks preserve walls, story scripts, directional barriers,
elevation/bridge restrictions, intermediate NPCs, previous NPC positions,
occupied ledge landings, active versus dormant doors, and automatic warp stops.
Existing native tests also check both directions after eleven seam, house,
staircase, Mart, and dormant-warp input sequences. The broad destination sweep
passes all 2,836 directed queries after the fix.

The final production-presence replay passes 58/58 directed checks, including
reachable exit and correct next-map assertions; the old source fails eight
forward checks. Sixty-six hidden/menu directions are explicitly skipped, and
all 21 required visible checkpoints must decode successfully. The native
route suite passes 95/95 assertions. The final Fastlane `ios verify` Release
iPhone build passes with Xcode at `/Applications/Developer/Xcode.app`.

Exact cartridge: RRv4.1M build 503,
`a215add233d8d2f119e29b435605d3af99d063180d6b77310f178dfcdebf0ba2`.
The paired generated profile and contract retain save-state layout 16,
`com.rileytestut.GBADeltaCore` state version 10, ABI 1.0 and wire version 2.
Game checkout: `9baa6497`. No ROM, game source, core, contract, save format,
backend, or user preferences changed. Native gameplay uses the pinned mGBA
0.10.5 harness and its distinct raw state format, verified against the exact
cartridge CRC; it does not load those states into VBA-M.

## Repeating the checks

Use `PrototypeTools/qa-python` with `BOUND_GAME_SOURCE` set to the isolated
multi_red checkout. Supply the exact ROM, a disposable Pallet (10,10) seed from
`verify-friend-route-exits.py`, and a task-specific output directory. The seed
has the introductory Oak and parcel fixture stages prepared. The journey tool
prepares only synthetic party/storage data and native Infinite Repel before
walking; neither the input state nor cartridge is changed.

```sh
PrototypeTools/qa-python PrototypeTools/verify-friend-route-journey.py \
  --rom "$ROM" --state "$PALLET_SEED" --output "$OUT/journey"

PrototypeTools/qa-python PrototypeTools/verify-friend-route-presence.py \
  --rom "$ROM" --pairs-report "$OUT/journey/pairs.json" \
  --transition-states "$OUT/journey/center-exit" --output "$OUT/presence"

PrototypeTools/qa-python PrototypeTools/verify-friend-route-exits.py \
  --rom "$ROM" --fixtures-report "$NATIVE_FIXTURE_REPORT" \
  --pairs-report "$OUT/journey/pairs.json" --sweep-destinations \
  --output "$OUT/routes"

PrototypeTools/qa-python PrototypeTools/verify-friend-route-access.py \
  --rom "$ROM" --state "$PALLET_SEED" --output "$OUT/access"

PrototypeTools/qa-python PrototypeTools/verify-friend-routes.py \
  --rom "$ROM" --output "$OUT/graph"
```

Add `--source-ref 250f10ccc7dcb79da5a9fe9bec247d7db697f9b9` to the presence or
exit checks for a read-only comparison with the published pre-fix source.
Before/after evidence, native input reports, screenshots, hashes and build logs
are under `artifacts/multiplayer-isolation/friend-route-unavailable`; ROMs and
states remain outside Git.

## Limits

This is native headless gameplay plus the production Swift presentation and
navigation code, not two running iOS apps or physical phones. Live Nakama
transport, WAN timing, UIKit rendering, and on-device VBA-M were not exercised.
A persistent failure while stationary immediately outside the Center at
(26,27) was not reproduced. The broader sweep covers five maps, not every
reachable position in the cartridge; unsupported intermediate scripts retain
their existing conservative behavior.
