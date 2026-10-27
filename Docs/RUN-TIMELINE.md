# Run timeline

Run Timeline now lives in the **History** multiview screen and is visible only
when **Enable Developer Tools** is on. The screen's separate **Connections** tab
requires the current game's Debug Mode. Either allowed tab keeps History
available; disabling a selected tab falls back to the other. With neither allowed,
History is removed from portrait, landscape and Mac navigation.

The old Friends and cartridge Timeline entry points remain retired. The same
per-game journal and existing filters are used in multiview; visibility and tab
switches never clear or migrate stored events. Durable events, recovery and old
protocol command numbers remain intact. The former Connections placement key
now identifies History, so saved placement and controller preferences survive.
The DEBUG statepoints page is no longer a navigation choice; its unfinished
implementation, backend, fixtures and tests remain preserved.

The verified completed-frame probe records newly acquired Pokémon (including
gifts, eggs and boxed catches) after its initial baseline. Existing Pokémon are
not presented as newly caught. The acquisition category uses “Acquired” because
party/box snapshots do not distinguish catches, gifts and received trades.
Linked deaths come from dated durable Soul Link memorials, including partner
losses. Historical undated memorials are not assigned invented timestamps.
Confirmed native trade completion records the completed exchange count; canceled
or interrupted trades do not count as completed. Soul Link still prohibits
trades during an active challenge; the history also covers ordinary friend play.
Battle victories require an observed battle followed by a win outcome, excluding
link and demonstration battles. Trainer and wild wins have separate labels.

This is local game history, not a synchronized partner event feed. It does not
reconstruct events predating installation or claim to recover completed trades
whose process died before the completion callback. Timeline timestamps are local
observation times. Loading a save or attaching mid-battle does not reconstruct
past wins. Replaying and winning a battle can produce another observed victory.
Custom rules remain canceled and unchanged.

Acquisition identities, trade session IDs and run/slot death keys prevent repeats
across polls and restarts. Journals are written atomically before publication.
Corrupt journals are preserved and reported in the viewer rather than replaced.
Capacity is bounded at 20,000 events/identities; failure affects history only,
never the game save or Soul Link enforcement. History currently follows a library
game across new-game resets; old entries are preserved. No delete action is added.

Battle-type/outcome constants use the existing FireRed ABI; reference:
https://github.com/pret/pokefirered/blob/master/include/constants/battle.h.
Type flags are latched during battle because the game may clear them on return.

## Historical validation

70 silent simulator tests passed: 41 SoulLinkTests (including history baseline,
restart persistence, duplicate prevention, loss/escape/link/tutorial exclusion,
corrupt-file preservation and rendered UI), 18 LivePresenceTests, 10
SharedWorldTests and the actual native Soul Link HP/state-recovery test.
The timeline screenshot and result bundle are retained in ignored
`.build/run-timeline*` outputs. The dependency verifier confirmed 17,061 pinned
files unchanged; shared-world and Soul Link generated code checks passed.
The unsigned Release iPhone build passed. These checks do not
claim a real two-device trade session or physical-device UI verification.
