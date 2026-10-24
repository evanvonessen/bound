# Cooperative doubles version

Bound supports `multi_red`’s optional doubles cartridge. The isolated `doubles` worktrees hold the matching development version; the ordinary cartridge remains the default. Existing double battles use one human trainer on each friendly bank, including encounters that normally provide an NPC partner. Opponent definitions and ordinary single battles are unchanged. Experimental Multiplayer must be enabled and the authenticated friend connected on the same matching cartridge.

The cartridge owns encounter admission, native team selection, party ownership, opponent generation, combat, EXP, move learning, rewards and evolution. Bound transports native cable commands and the versioned co-op data ABI. Admission binds the selected teams, both fresh encounter tokens and the captured original enemy team before starting cable setup. Each owner selects up to three living Pokémon through the native team menu. Unselected owned Pokémon stay in their original slots; borrowed teammate records never enter the owner’s battery save.

Interrupted native battles retain recovery checkpoints and a journal. Both authenticated owners must agree to recovery with a fresh wire namespace before resuming the paused native state. Battery/autosave writes remain fenced until each owner has restored their complete party and safely returned through native evolution/field cleanup. Recovery does not roll back to the party before battle. Automatic rejoin requires drained incoming native and host queues, cross-matching SHA-256 histories for the consumed command prefix, matching completed EXP rounds, acknowledged command generations and the same durable recovery branch. Bounded output records that have never been sent remain in the native checkpoint and replay once on the fresh wire. Sent but unacknowledged or accepted future commands cannot establish that prefix. The branch changes after each recovery so an older checkpoint cannot join a later battle timeline. Incompatible cuts stay paused with their recovery files intact. Normal manual save states, quick saves, autosaves, independent loads and Handoff remain blocked during an active or interrupted cooperative battle. Switching games preserves the previous game’s recovery; automatic recovery obeys the current pause screen. Explicitly clearing a ROM’s saves also clears that ROM’s cooperative recovery. Soul Link captures owned faints before native loss cleanup can heal them.

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


## Disconnect review (2026-10-24)

The optional cartridge pin is now
`f1c03b0d755d4a52bab6d121e8c8c3d67e691f9d3d02eecbd9bb97fbf19141dd`.
Confirmation validates the sealed owner roster, and moved host heartbeat epochs
retry without cancelling selection. The app waits for committed protection
before advertising cable readiness, waits for the cartridge's disconnect fence
before pausing, and waits for its resume acknowledgement after loading. Pending
owned EXP exchanges retry until the cartridge advances their token. Native field completion closes the logical link before the app restores ordinary serial timing; catch recovery keeps any still-referenced adapter code installed until that return.

Recovery retains bounded, never-sent native output in its checkpoint. A saved
send cursor and cross-matching consumed histories distinguish that output from
sent but unacknowledged records. Incoming future commands, partial blocks,
unacknowledged histories and different recovery branches still fail closed with
the existing files preserved. No earlier owned progress is silently loaded.

`PrototypeTools/test-doubles-reconnect.py` drives two separately named
`Doubles Recovery QA` simulators through native encounter entry, selection,
connection loss, rejoin, fresh emulator/session recovery from durable files,
and delayed old-wire packet injection. Raid entry uses the original native
pre-battle selector as well as cooperative admission. Fixtures copy a native
battery and create only owned parties through original native scripts; opponent
records are never supplied or edited. Detailed receipts stay under ignored
`.build/doubles-reconnect/`, including unsuccessful iterations. These local
loopback tests use synthetic identities, not an authenticated friend service.


The completed two-app receipts are `doubles-26`, `raid-6` and `facility-4`.
All three pass native entry, two disconnect/rejoin cycles (one recreates the
emulator and session from durable files), old-wire packet rejection, native
completion, full original owner identity/order restoration and save-lock release.
Each case also interrupts after combat has progressed. Raid checks both
the shared pre-catch cut and an already-local catch interruption, then verifies
a separate capture on each owner. The original opponent definitions stay intact.

The field receipt exchange now sends each owner's finish message before allowing
that owner to leave the cooperative state, even if a previous control message
was sent less than 250 ms earlier. This prevents one completed owner from closing
before its friend receives the final receipt. The 78 focused app checks and an
unsigned Release iPhone build pass; the embedded cartridge matches the pin. The
cartridge also passes native facility-loss and raid-storm-loss recovery/field
checks. No main branch or permanent download is changed. Matching completed
command/EXP cuts are still required: incompatible histories remain paused with
their files preserved. Physical devices, authenticated internet and long-play
performance remain unverified.
