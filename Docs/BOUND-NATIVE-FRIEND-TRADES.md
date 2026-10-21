# Native friend trades

Integrated into `main` from `codex/friend-trading`. Native trade runtime evidence
and remaining device/network verification limits are recorded below.

Enable **Settings → Enable Experimental Features** on both devices. Connect in
Friends, turn on **Show friend on map**, walk to the cardinal tile beside the
friend, face them and press **A**, then choose **Trade** in the game. The friend answers
the native **YES/NO** dialogue with ordinary game controls. **NO** or **B**
declines without opening the trade link or changing either party.
The same validated Radical Red 4.1 ROM and VBA-M core are required on both sides.

Confirm the game's save and link prompts using normal A/B controls. In the
cartridge trade menu, select a Pokémon, choose **Trade**, review the offered pair
and confirm on both devices. The game performs its exchange, animation, evolution
checks and linked save. Use the native **Cancel** entry on the party screen and
confirm when both players have finished; this returns to the original world.
The cartridge's own eligibility rules remain active, including keeping another
Pokémon available for battle. Bound does not bypass those rules.

## In-game invitations

The walk-up Battle/Trade/Cancel menu, incoming YES/NO, waiting/cancellation and
result acknowledgement use the cartridge's own field-script windows. There is
no UIKit invitation card, app alert or app acceptance button. The existing panel
attachment is permanently hidden and only coordinates a bounded completed-frame
mailbox. Normal controller touches and physical controller mappings reach the
native choices while the script freezes movement. Initial A is consumed before
it can activate an underlying NPC or sign.

The exact-hash bridge stages original text and script commands in the unused
ROM tail at 09FFFD00, outside the existing battle guest and trade-entry script.
For the chooser only, it temporarily lends native multichoice slot zero at
083E04B0 the Battle/Trade/Cancel labels. YES/NO uses the native script opcode
6E (0806BA80), ScriptMenu_YesNo (0809CDEC), and its ordinary input task
(0809CE54). The chooser uses native multichoice/input routines at 0809C9B4
and 0809CC98. Native releaseall/end closes the field message and restores control;
the selection is latched by native copybyte before releaseall/end can expose the
shared result variable to ordinary field tasks. Its two-byte scratch lies in the
inactive link queue and is restored along with the table and unused tail before
any native link snapshot or entry.
The on-disk ROM and save are untouched by this invitation layer.

After explicit acceptance, confirmation is fenced by the invitation/session ID
and original anchor, rather than requiring a render pose during the peer's
brief snapshot pause. An early prepared control is held only for that consented
invitation; game-data sequence 1 is sent only after both native receivers exist. A real disconnect still ends the invitation; confirmation
retains its bounded timeout. A received acceptance waits for the local dialogue to close before invoking the
unchanged trade coordinator. Canceled/stale completions cannot start an activity.
Cancellation dismisses the native window through B; production code never
synthesizes YES or A. Quick/automatic state capture stays blocked while a staged
invitation could be captured. Interrupted-trade title/Continue inputs remain
available before a native result can be shown in the overworld. New core binding
forgets the previous cartridge's pending dialogue/selection.

Interaction admission and pending anchors retain the original 200 ms freshness
limit. Native field windows temporarily make the local sprite image unavailable;
during an owned dialogue only, the last appearance is retained when fresh native
world data confirms the same map, tile, elevation and facing. Movement, fades,
battles, other menus, missing frames and changed sessions still invalidate it.

Source references: [field-script commands](https://github.com/pret/pokefirered/blob/master/asm/macros/event.inc)
and [native script menus](https://github.com/pret/pokefirered/blob/master/src/script_menu.c).
Exact-profile addresses and runtime checks are separate from those references.

## Native implementation

`BoundNativeBattleSession` now coordinates both native link activities; its
existing name and recovery folder remain for compatibility with battle journals.
Both activities use the existing bounded, generation-tagged native command
transport and the Agora reliable command channel. Invitation IDs bind the
activity, prepared/connected/finished/abort controls and the link wire. There is
no new backend, cloud configuration, SDK or emulator-core patch.

The exact-profile trade entry calls native CableClub_AskSaveTheGame (special 35),
TryTradeLinkup (29, 080810CC), and StartWiredCableClubTrade (34, 080819B8).
A declined save prompt returns without entering trade. Trade setup never
synthesizes A presses: native save, link, Pokémon selection and final confirmation
are player inputs. The original menu owns offers and validation; the original
TradeMons/evolution/save routines own Pokémon, original trainer, mail, friendship,
Pokédex and save changes. No production host routine constructs exchanged Pokémon.

Trade uses the seven existing physical-link hooks, leaving both battle return
hooks uninstalled. One trade-only hook makes native
SetContinueGameWarpStatusToDynamicWarp (0804C1C0) a no-op, so saving does not select
a stale Pokémon Center return warp. A second adapts ReturnToFieldFromMultiplayer
(08056854) to reset multiplayer field state, select the ordinary local callback,
initialize/unlock scripts and call the native local return/fade (080568FC).
The linked-room return would otherwise emit physical overworld key commands;
those remain rejected by the bounded command admission. Native map/position,
party and completed-save data remain intact. The shared guest is 932 bytes. All hooks and the
unused ROM-tail entry are removed before normal world play or a cartridge reboot.
The on-disk ROM remains untouched and must match the full supported digest.

Native menu entry is observed at 0804C718/0804C728, the menu callback at 0804D638,
and the native save/end callback at 08053E8C. A completed exchange is counted
only after that save/end path returns to menu creation. A mere invitation,
selection, confirmation or party change is not reported as a completed trade.

Source references, separate from exact-profile address/runtime evidence:
[pret cable_club.c](https://github.com/pret/pokefirered/blob/master/src/cable_club.c),
[trade.c](https://github.com/pret/pokefirered/blob/master/src/trade.c),
[trade_scene.c](https://github.com/pret/pokefirered/blob/master/src/trade_scene.c),
[load_save.c](https://github.com/pret/pokefirered/blob/master/src/load_save.c), and
[overworld.c](https://github.com/pret/pokefirered/blob/master/src/overworld.c).
These references do not by themselves establish modified-ROM compatibility.

## Persistence and interruption

Friendly battles still restore their private pre-battle state. Trades have a
separate recovery rule. Before native trade entry is queued,
the activity writes a `tradeStarted` marker to its private recovery journal.
After that boundary, **the pre-trade party is never automatically restored**.

A normal return keeps the actual exchanged party, native save and world state.
Opening the app menu, disabling Experimental Features, backgrounding, leaving
sharing or losing the link after trade entry closes the cable and reboots from
the native cartridge save. The player selects Continue. The game owns selection
of its valid save after an interrupted linked save. An explicit cancellation before the menu opened can safely restore the
pre-session snapshot because no Pokémon could be offered; the coordinator reads
the fenced native observation before making that decision. Crash recovery after
entry was queued always boots the cartridge save, even if the UI timer had not
yet observed the native menu.

If the app stops unexpectedly, binding the same game discovers its journal
before automatic state loading. For a started trade it preserves the cartridge
save, verifies the ROM and retained snapshot digest, and boots the native save;
it does not load the old party from that snapshot. Recovery remains available
with Experimental Features off. A failed recovery keeps its journal/snapshot
and blocks automatic/quick state capture. Ordinary game, snapshot and backup
storage remain separate. This follows the cartridge's linked-save semantics,
not a server-authoritative cross-account trade ledger.

## Validation workflow

`PrototypeTools/native-link-battle.py --trade --relay` and
`NativeBattleRuntimeTests.testActualNativeTrade` exercise the production activity
coordinator and wire on two explicitly owned simulators. The driver uses native
inputs, offers distinct trainer identities/nicknames, verifies the unoffered
party member remains unchanged, exits to the real overworld with hooks removed,
and cold-boots a new core from the resulting cartridge save to check persistence.
The two-member test parties are created only through a DEBUG/Simulator helper
in disposable working saves. Original ROM and seed files are checksum-checked
and never modified. Release excludes the fixture helper.

Private attempts and evidence live under `.build/` in the trading worktree.
The first attempt exposed a test-driver address-format error. The next reached
the native menu and reproduced its refusal to trade the fixture's only Pokémon;
the disposable test party was then expanded to meet the native requirement.
A subsequent fixture correction respected this ROM's unencrypted party format.
The first complete exchange/save then exposed the linked-room return issuing
unsupported physical overworld commands; the local field-return adapter addresses
that path. Failed/interrupted attempts are retained and are not acceptance evidence.

## Full friend-to-friend reliability checks

`PrototypeTools/full-app-gameplay.py --trade complete` drives the normal Friends
selection, live map visibility, adjacent-tile/facing/A invitation, acceptance,
native save/link prompts, Pokémon selection, confirmation, exchange and return
through two full app UIs over real Agora. It checks both offered trainer/nickname
identities, the unchanged unoffered party member, playable worlds and released
save restrictions. It does not substitute a loopback cable for the Agora path.

The same coordinator supports `--trade menu-disconnect`, `--trade
exchange-disconnect`, and `--trade saved-disconnect`. The initiator backgrounds
the app before offering, during the native animation before completion, or after
the native exchange/save returns to the party menu. Both peers use native
Continue inputs after recovery; the last two modes verify that the pair of saves
contains either the original pair or the exchanged pair as appropriate, rejecting
duplicated or lost offer identities. Fixture preparation and party/menu
observations are DEBUG/Simulator-only and run on the completed-frame owner;
all invitations, selections, confirmations and recovery inputs use normal UI.

Trade recovery/completion messages now survive transport shutdown, reconnect and
Experimental Features disable until the player acknowledges Return to game.
Repeated join callbacks preserve an already active activity's consent and input
handoff. Cancellation diagnostics identify the calling source without account or
credential data. The UIKit tests wait for stable control rectangles after a
foreground transition before touching them.

## Observed results — October 21, 2026

`native-trade-5` passed in **93.2 seconds** on the two owned iOS simulators, with
25 ms controlled one-way relay delay. Each game used native selection and final
confirmation, completed its native animation/save, returned to its actual local
overworld with hooks removed, and cold-booted a new core from the cartridge save.
The received nickname and original trainer identity matched the peer's offer;
the unoffered second party member remained byte-identical before and after the
exchange and cold boot. The original ROM and seed files remained unchanged.

`native-trade-cancel-1` passed in **30.2 seconds** with the same relay delay.
The initiator canceled from the native menu before offering; the peer handled
that abort, and both original parties persisted through cartridge reboot, with
state capture unblocked afterward. `trade-battle-entry-regression` passed in
12.1 seconds, verifying that real native battle entry/cancel/restoration still
works with the shared 932-byte guest. No battle binding addresses changed.

All **66 focused integration tests** passed in `trade-focused-final.log` and its
result bundle. They include trade activity/control handoff, invitation and
command admission, Experimental Features gates for both activities, settings
reset, controller routing and presence. The first focused pass correctly caught
an obsolete assertion describing trades as invitation-only; the copy assertion
was updated and the suite passed on retry. Debug test builds and the unsigned
iPhone Release build passed (`trading-build-9.log`, `trading-release-2.log`).
All 17,061 current pinned source files and the generated guest header verify.
The exact 932-byte guest and identical cloud configuration are present in Debug
and Release; Release excludes the simulator party-fixture helper.

Main integration with account-sync/security commit `916d491f` passed a new
**153-test focused regression run** (trading, battles, controls, settings,
presence and account persistence/security), with zero failures. The merged
Debug test build, unsigned iPhone Release build, 17,061 pinned-source checks
and generated guest check passed. Bundled cloud configuration hashes match.
Private merge logs use the `trade-merge-` prefix.

The earlier implementation evidence above used native-engine/local-relay tests;
it did not establish a normal-app Agora trade. The subsequent reliability run
adds that evidence below. Physical devices/separate networks,
mail/egg/trade-evolution cases, repeated exchanges within one native menu, and a
complete power-loss/critical-save recovery matrix remain outside acceptance.
Private receipts, working saves, screenshots and failed attempts remain ignored.

## Full-app Agora evidence — October 21, 2026

- `paired-1003`: complete native trade, **131.8 seconds**. Both offered identities
  arrived at the peer, the unoffered members stayed unchanged, and both games
  returned to their real overworlds with one completed trade.
- `paired-1003-retry-2`: disconnect before offering, **74.1 seconds**. Both
  players continued from their cartridge saves with the original parties and
  released save restrictions.
- `paired-1004`: disconnect during the native animation before its completion
  counter, **88.1 seconds**. Both continued from the original cartridge parties;
  the paired identity check found neither loss nor duplication.
- `paired-1004-saved-disconnect`: disconnect after the native linked save,
  **134.2 seconds**. Both players used Continue after recovery and retained the
  peer's offered Pokémon, with the unoffered members unchanged and saving
  unblocked. The `1004` suite passed both disconnect scenarios on its first run.

The earlier failed attempts are retained. `1001` failed to open the invitation
with an observer that paused the core; the observer now belongs to the frame
owner. `1002` encountered an unplanned cancellation during animation before
cancellation-source diagnostics existed; it is not successful trade evidence.
The initial before-offer checks in `1003` exposed XCTest's offscreen/stale
recovery-dialog hit rectangles after foregrounding. Stable rectangle checks
and an independently observed dialog dismissal fixed that driver path.

Each suite uses the two existing dedicated development accounts and normal
friend APIs, reuses its temporary friendship for bounded retries, removes it
and one-use inputs afterward, and checks restoration of the original friend
lists. No account was created and no rate limit was changed or bypassed. The
current 57-file protected setup baseline and original ROM/seed hashes remained
unchanged; the transferred historical baseline is preserved separately.
No backend, cloud configuration, dependency pin or signing configuration changed.

Final reliability checks: **156 focused integration tests** passed with zero
failures (`trade-reliable-focused.xcresult`), including repeated joins, recovery
message acknowledgement and Experimental Features disable/re-enable. The final
Debug test build and unsigned iPhone Release build passed. All 17,061 pinned
source files and the unchanged 932-byte native guest verify; source, Debug and
Release cloud configuration SHA-256 hashes match.

## Native invitation verification — October 21, 2026

The focused native-dialogue check cold-boots a disposable seed in actual VBA-M,
selects Trade in the native chooser, answers YES, answers NO, presses B, and
cancels a pending menu. Every path returns to the unlocked overworld with the
original menu table and supported ROM digest restored. Original ROM/seed hashes
remain unchanged. Invitation handoff tests also verify that native-window cleanup
precedes agreement delivery and a canceled completion cannot start the trade.

Failed full-app attempts are retained separately. Diagnostics identified native
field windows making the sprite image unavailable while fresh position data
remained valid. A trial of a longer pending freshness limit did not fix that
rendering dependency and was reverted. Owned native windows now retain only a
stationary appearance proven by fresh world data.

The acceptance checks also exposed ordered prepared controls arriving before the
peer finished dismissing its field window, and the first wire heartbeat being
sent before that peer installed its native receiver. Preparation now stays bound
to the accepted invitation, and sequenced game data waits for the existing
two-sided connected barrier. Native trade guest code, save prompts and exchange
routines remain unchanged. UI checks verify the actual native cursor before
selecting Trade, YES or NO, and wait for acceptance before pressing A on save
prompts.

Final checks: **68 focused tests passed**, including native chooser/YES/NO/B,
cancellation, same-core rebind cleanup, consent fencing, presence, settings and
Soul Link regressions. Debug test builds and the unsigned iPhone Release build
passed. All 17,061 pinned source files, the unchanged 932-byte native trade/battle
guest and source/Debug/Release cloud configuration hashes match.

On two dedicated simulators over **real Agora**, `paired-1103-retry-1` verified
NO returning both players to idle without a native activity, followed by YES
entering the actual native Trade menu on both players. Neither invitation used
an app card or app acceptance button. The run was intentionally stopped during
the exchange stage after desktop control reported the Mac locked; it is not
full-app Agora exchange-completion evidence. Earlier failed attempts are retained.
The previous QA-device shutdown is recorded separately, and the final invitation
check used newly created task-owned devices.

`native-invitation-trade-regression` then passed on both dedicated simulators in
**92.6 seconds** with a controlled 25 ms local relay delay. The native exchange,
linked save and return completed; a new emulator cold-booted each cartridge save
and retained the peer's offered nickname/original trainer. Both unoffered party
members stayed unchanged. This separately verifies the preserved trading flow;
it does not replace the missing full-app Agora exchange-completion check.

The original ROM/seed, all 57 current protected setup files and original active
friend lists were preserved. Temporary friendships and one-use inputs were
removed. Three newer main-branch account/Dropbox files differed from the old
transferred QA baseline; their unchanged HEAD blobs were verified, the historical
manifest retained, and the current baseline recorded before the final runs. No
backend, signing, cloud configuration or dependency settings changed. Physical
devices and separate networks remain unverified for the new invitation UI.

## Completed native invitation acceptance on published main — October 21, 2026

After the Mac was unlocked, `paired-1201` passed in **149.2 seconds** on the
same two task-owned simulators, using an exact build of published main
`b14f292fc038f8b512fbb92fa7a772480a2e2b8c` and **real Agora**. NO returned
both players to idle with no native trade started. A subsequent YES opened the
native Trade menu on both players, completed the exchange and native linked
save, and returned both games to their own playable overworlds with saving
unblocked. The received nickname and original-trainer markers matched the
peer's offer, both native completion counts were one, and both unoffered party
members remained unchanged. All invitation choices stayed in native game
windows; no app acceptance card or button was used.

This closes the full-app exchange-completion gap for the native invitation UI
recorded above. This run checked the native linked save and returned game state;
it did not cold-boot a new emulator instance. The separate cold-boot persistence
check remains `native-invitation-trade-regression`, described above. Physical
phones and separate networks remain unverified.

The main-based Debug UI test build passed. The delivery retry also produced a
verified signed Release archive of that same commit, with all 17,061 pinned
source files and source/archive privacy checks passing. Xcode then rejected
export with `Failed to Use Accounts`; this is not an accepted upload or a
TestFlight delivery. App Store Connect confirmed the authorized group still
contains only the existing internal tester, with build 176 as its newest
available build. Cloud remained blocked by its monthly usage limit.

`live-receipt-1201.json` records unchanged original ROM/seed files and all 57
protected setup files, removal of the temporary friendship and one-use inputs,
and restoration of both original active friend lists. Both owned QA simulators
were shut down afterward. Private logs and receipts remain ignored under
`.build/full-app-gameplay-validation/` in the main-based validation worktree.
