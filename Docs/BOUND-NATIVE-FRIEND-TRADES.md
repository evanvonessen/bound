# Native friend trades

Integrated into `main` from `codex/friend-trading`. Native trade runtime evidence
and remaining device/network verification limits are recorded below.

Enable **Settings → Enable Experimental Features** on both devices. Connect in
Friends, turn on **Show friend on map**, walk to the cardinal tile beside the
friend, face them and press **A → Trade**. The friend must accept the invitation.
The same validated Radical Red 4.1 ROM and VBA-M core are required on both sides.

Confirm the game's save and link prompts using normal A/B controls. In the
cartridge trade menu, select a Pokémon, choose **Trade**, review the offered pair
and confirm on both devices. The game performs its exchange, animation, evolution
checks and linked save. Use the native **Cancel** entry on the party screen and
confirm when both players have finished; this returns to the original world.
The cartridge's own eligibility rules remain active, including keeping another
Pokémon available for battle. Bound does not bypass those rules.

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

These are native-engine and local-relay checks. This continuation did not run a
live Agora trade or a normal-app UI trade end to end, physical devices/separate
networks, mail/egg/trade-evolution cases, repeated exchanges, or a complete
power-loss/critical-save recovery matrix. The underlying real Agora battle and
walk-up invitation evidence remains in their respective handoffs. No account,
friendship, backend or cloud setup was created or changed by this validation.
Private receipts, working saves, screenshots and failed attempts remain ignored.
