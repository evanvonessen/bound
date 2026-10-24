# Cooperative doubles version

Bound supports `multi_red`’s optional doubles cartridge. The isolated `doubles` worktrees hold the matching development version; the ordinary cartridge remains the default. Existing double battles use one human trainer on each friendly bank, including encounters that normally provide an NPC partner. Opponent definitions and ordinary single battles are unchanged. Experimental Multiplayer must be enabled and the authenticated friend connected on the same matching cartridge.

The cartridge owns encounter admission, native team selection, party ownership, opponent generation, combat, EXP, move learning, rewards and evolution. Bound transports native cable commands and the versioned co-op data ABI. Admission binds the selected teams, both fresh encounter tokens and the captured original enemy team before starting cable setup. Each owner selects up to three living Pokémon through the native team menu. Unselected owned Pokémon stay in their original slots; borrowed teammate records never enter the owner’s battery save.

Temporary network loss retains the live cartridge and pauses its current team selection, battle, move-learning or result screen. Reconnection preserves the same encounter identity, selected parties, native command queues, EXP and ownership journal. An authenticated nonce exchange confirms both resident peers before emulation resumes. Presence challenge rotation does not replace the agreed encounter. Bounded `BFS2` wire replay retries lost commands and admits each sequence once, and pending EXP records retry using the cartridge's existing token/payload idempotency. Native finalization also retries; explicit cancellation is repeated if its first notification was lost. A temporary outage has no time-based expulsion.

Process loss, explicit disconnection and native integrity errors retain recovery checkpoints and a journal. Both authenticated owners must agree to recovery with a fresh wire namespace before restoring a saved native state. Battery/autosave writes remain fenced until each owner has restored their complete party and safely returned through native evolution/field cleanup. Recovery does not roll back to the party before battle. Checkpoint recovery requires mutually drained native and host command queues, cross-matching SHA-256 command histories, matching completed EXP rounds, acknowledged command generations and the same durable recovery branch. The branch changes after each recovery so an older checkpoint cannot join a later battle timeline. Incompatible cuts stay paused with their recovery files intact. Normal manual save states, quick saves, autosaves, independent loads and Handoff remain blocked during an active or interrupted cooperative battle. Switching games preserves the previous game’s recovery; live continuation and recovery obey the current pause screen. Explicitly clearing a ROM’s saves also clears that ROM’s cooperative recovery. Soul Link captures owned faints before native loss cleanup can heal them.

The October 24 live-reconnection changes do not claim physical-device or separate-network acceptance. The retained checkpoint-recovery requirements above remain applicable after process loss; ordinary packet loss does not require rewinding to a compatible saved command cut.

## Build

Build the cartridge using `python3 tools/build_doubles_game.py` from the game worktree. Import its export here with `python3 PrototypeTools/build-shared-world.py --from-game /Users/evandev/dev/doubles/build/doubles-contract`, and update `PrototypeTools/bundled-rom.json` to the exact generated ROM SHA-256. Supply the cartridge as `BOUND_DEVELOPMENT_ROM` for the normal `Bound.xcodeproj` / `Bound` build. This variant uses a local development ROM pin to avoid replacing the permanent main download.

The ABI has a distinct ruleset and raw-state layout. Existing battery saves retain the native format; cold boot is required when switching cartridges, and arbitrary old emulator save states are not compatible. The default integrated cartridge remains a separate, unchanged build.

## Validation

On October 24, all 14 `CooperativeDoublesContractTests` passed, including retained
encounters across a simulated hour offline, pause ownership, input release,
reentrant cancellation and rejection of delayed confirmations from replaced
transport attempts. These hosted tests use a diagnostic cartridge and do not
establish paired native cooperative-battle or physical-phone acceptance.

The complete reconstruction gate passed 452 tests, all retained runtime comparisons and the original ROM hash. Focused compiled game checks cover ownership, EXP barriers, reward idempotency, reproducible optional/default builds, ABI hashing and exact allowed cartridge changes. Native fixtures cover ordinary single battles, heap/audio safety, selection cancellation and the Mega script cursor fix.

Two separate native mGBA cores completed both natural Sabrina doubles and the original NPC-partner encounter with the same physical-cable adapter as Bound. Both players received native EXP, learned moves, evolved their own selected Pokémon, earned the original payout and trainer flags, and returned with their complete party and unchanged bench records. A complete loss preserved owned faint evidence through native blackout healing and restored both owners’ original parties. Generated reports identify the exact cartridge tested.

See the game worktree’s `docs/cooperative-doubles.md` and generated `build/` reports for the current acceptance results. Simulator/compiled/headless checks do not establish real iPhone performance or internet transport reliability. Physical-device pairing, internet disconnect/relaunch and long-play acceptance remain separate from these local runtime checks. No TestFlight or Xcode Cloud delivery is part of this work.
