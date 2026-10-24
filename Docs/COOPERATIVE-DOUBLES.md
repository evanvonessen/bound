# Cooperative doubles version

Bound supports `multi_red`’s optional doubles cartridge. The isolated `doubles` worktrees hold the matching development version; the ordinary cartridge remains the default. Existing double battles use one human trainer on each friendly bank, including encounters that normally provide an NPC partner. Opponent definitions and ordinary single battles are unchanged. Experimental Multiplayer must be enabled and the authenticated friend connected on the same matching cartridge.

The cartridge owns encounter admission, native team selection, party ownership, opponent generation, combat, EXP, move learning, rewards and evolution. Bound transports native cable commands and the versioned co-op data ABI. Admission binds the selected teams, both fresh encounter tokens and the captured original enemy team before starting cable setup. Each owner selects up to three living Pokémon through the native team menu. Unselected owned Pokémon stay in their original slots; borrowed teammate records never enter the owner’s battery save.

Interrupted native battles retain recovery checkpoints and a journal. Both authenticated owners must agree to recovery with a fresh wire namespace before resuming the paused native state. Battery/autosave writes remain fenced until each owner has restored their complete party and safely returned through native evolution/field cleanup. Recovery does not roll back to the party before battle. Rejoin verifies that each peer’s consumed command position is inside the other checkpoint’s retained commands and belongs to the same acknowledged generation. Incompatible cuts stay paused with their recovery files intact. Soul Link captures owned faints before native loss cleanup can heal them.

## Build

Build the cartridge using `python3 tools/build_doubles_game.py` from the game worktree. Import its export here with `python3 PrototypeTools/build-shared-world.py --from-game /Users/evandev/dev/doubles/build/doubles-contract`, and update `PrototypeTools/bundled-rom.json` to the exact generated ROM SHA-256. Supply the cartridge as `BOUND_DEVELOPMENT_ROM` for the normal `Bound.xcodeproj` / `Bound` build. This variant uses a local development ROM pin to avoid replacing the permanent main download.

The ABI has a distinct ruleset and raw-state layout. Existing battery saves retain the native format; cold boot is required when switching cartridges, and arbitrary old emulator save states are not compatible. The default integrated cartridge remains a separate, unchanged build.

## Validation

Focused compiled game tests exercise ownership, EXP barriers, trainer reward idempotency, build reproducibility, ABI hashing and the exact allowed cartridge changes. Native headless fixtures exercise natural Sabrina admission, the original NPC-partner tag script and unchanged ordinary single-battle combat fields. The paired cartridge runner uses two separate native mGBA cores and the same physical-cable adapter as Bound.

See the game worktree’s `docs/cooperative-doubles.md` and generated `build/` reports for the current acceptance results. Simulator/compiled/headless checks do not establish real iPhone performance or internet transport reliability. Physical-device pairing, disconnect/rejoin, native evolution and loss recovery must be reported according to the runtime checks actually completed. No TestFlight or Xcode Cloud delivery is part of this work.
