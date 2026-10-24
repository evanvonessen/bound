# Cooperative doubles version

Bound supports `multi_red`’s optional doubles cartridge. The isolated `doubles` worktrees hold the matching development version; the ordinary cartridge remains the default. Existing double battles use one human trainer on each friendly bank, including encounters that normally provide an NPC partner. Opponent definitions and ordinary single battles are unchanged. Experimental Multiplayer must be enabled and the authenticated friend connected on the same matching cartridge.

The cartridge owns encounter admission, native team selection, party ownership, opponent generation, combat, EXP, move learning, rewards and evolution. Bound transports native cable commands and the versioned co-op data ABI. Admission binds the selected teams, both fresh encounter tokens and the captured original enemy team before starting cable setup. Each owner selects up to three living Pokémon through the native team menu. Unselected owned Pokémon stay in their original slots; borrowed teammate records never enter the owner’s battery save.

Interrupted native battles retain recovery checkpoints and a journal. Both authenticated owners must agree to recovery with a fresh wire namespace before resuming the paused native state. Battery/autosave writes remain fenced until each owner has restored their complete party and safely returned through native evolution/field cleanup. Recovery does not roll back to the party before battle. Automatic rejoin requires mutually drained native and host command queues, cross-matching SHA-256 command histories, matching completed EXP rounds, acknowledged command generations and the same durable recovery branch. The branch changes after each recovery so an older checkpoint cannot join a later battle timeline. Incompatible cuts stay paused with their recovery files intact. Normal manual save states, quick saves, autosaves, independent loads and Handoff remain blocked during an active or interrupted cooperative battle. Switching games preserves the previous game’s recovery; automatic recovery obeys the current pause screen. Explicitly clearing a ROM’s saves also clears that ROM’s cooperative recovery. Soul Link captures owned faints before native loss cleanup can heal them.

## Build

Build the cartridge using `python3 tools/build_doubles_game.py` from the game worktree. Import its export here with `python3 PrototypeTools/build-shared-world.py --from-game /Users/evandev/dev/doubles/build/doubles-contract`, and update `PrototypeTools/bundled-rom.json` to the exact generated ROM SHA-256. Supply the cartridge as `BOUND_DEVELOPMENT_ROM` for the normal `Bound.xcodeproj` / `Bound` build. This variant uses a local development ROM pin to avoid replacing the permanent main download.

The ABI has a distinct ruleset and raw-state layout. Existing battery saves retain the native format; cold boot is required when switching cartridges, and arbitrary old emulator save states are not compatible. The default integrated cartridge remains a separate, unchanged build.

## Validation

The complete reconstruction gate passed 452 tests, all retained runtime comparisons and the original ROM hash. Focused compiled game checks cover ownership, EXP barriers, reward idempotency, reproducible optional/default builds, ABI hashing and exact allowed cartridge changes. Native fixtures cover ordinary single battles, heap/audio safety, selection cancellation and the Mega script cursor fix.

Two separate native mGBA cores completed both natural Sabrina doubles and the original NPC-partner encounter with the same physical-cable adapter as Bound. Both players received native EXP, learned moves, evolved their own selected Pokémon, earned the original payout and trainer flags, and returned with their complete party and unchanged bench records. A complete loss preserved owned faint evidence through native blackout healing and restored both owners’ original parties. Generated reports identify the exact cartridge tested.

See the game worktree’s `docs/cooperative-doubles.md` and generated `build/` reports for the current acceptance results. Simulator/compiled/headless checks do not establish real iPhone performance or internet transport reliability. Physical-device pairing, internet disconnect/relaunch and long-play acceptance remain separate from these local runtime checks. No TestFlight or Xcode Cloud delivery is part of this work.


## Follow-up review

The doubles worktrees now pin cartridge
`ab40d6b7faa27d56db44915e50183bb60c997fef8502d1cdd5a533b3d141d965`.
The cartridge admits ordinary mode-9 continuation/partner setups while excluding
actual tutorials, preserves native single-foe fallbacks, and retains the original
provider's double-battle flags for native rewards. Opponent definitions are
unchanged. Native coverage checks all 35 double-marked records in the verified
743-entry trainer table, plus all seventeen configured trainer modes.

Fresh Sabrina and NPC-partner victories, frozen-core recovery, both ownership
exhaustion directions and native four-move replacement have passed local checks.
The updated app passed all 76 cooperative/ROM/Soul Link/Handoff checks and an
unsigned Release iPhone build; its embedded cartridge hash matches the pin.
See the game's `build/doubles-review/` receipts and documentation for exact scope.
No main branch or permanent ROM download is changed by this review. Physical
pairing, authenticated internet and durable application relaunch remain unverified.


## Raid and facility doubles

The current optional cartridge pin is
`bd92f48c9f4f33810f409f134fb44c1eda34f312efeeacd642804c22d75f34ee`.
Existing raid and battle-facility doubles now use both connected owners,
including native NPC-partner and rental formats. Original opponents, boss
parameters and native facility selection rules are retained. Singles stay native.

Authenticated agreement and recovery bind the native encounter rules as well as
both teams and the original opponents. After shared raid combat, each owner runs
their own native catch, Bag, party/PC storage and rewards. Committed pre-catch and
local-catch recovery cuts prevent replaying shared combat. The cartridge retains
native outcome rules, including win-only evolution and the raid storm ending.

The additional review fixes forced raid switches, cancellation across heap reset,
raid storm terminal exchange, facility can-lose return, and field input during
native connection setup. Paired core checks cover separate party/PC catches,
ball spending, local OTs, uncatchable raids, storm loss, rental/NPC facilities and
facility loss. Native provider comparisons cover 20 facility/raid cases and
cancellation, alongside the existing complete double-marked trainer inventory.
The matching app passes 78 selected integration tests and an unsigned Release
iPhone build. Exact cartridge and input-state identities are retained in the
game's `build/doubles-expansion/` receipts.

Both repositories remain on `codex/doubles` in the doubles worktrees. Main and
the permanent ROM download remain unchanged. Physical devices, authenticated
internet interruption/relaunch, every facility streak/tier and long-play
performance still need acceptance testing.
