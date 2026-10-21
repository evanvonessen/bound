# Native friend battles

Walk to the cardinal tile beside a connected friend, face their tile and press
A. Choose Battle; the friend must accept. Bound prepares a private recovery
snapshot, transports the game's two-player link commands over the existing Agora
session, and starts the cartridge's native single battle with each current party.
The ordinary game controls select moves and Pokémon. Opening the app menu,
leaving sharing or losing the connection ends the friendly battle and restores
the local pre-battle world. Quick saves and fast-forward are suppressed during
battle; quick load ends the battle before loading the selected state.

This entry supports only the SHA-256-verified Radical Red 4.1 profile already
used by live presence. The player must be in an unlocked normal overworld scene
with a party of 1–6. The native game performs party/link checks. Bound does not
manufacture a win/loss or rewrite party data to simulate a battle. Trade is
still an invitation only.

## Native entry

`BoundVBABattleBridge` is called only with the core paused or on its completed
frame owner. It verifies the entire loaded 32 MiB ROM and an unused 2 KiB tail.
It installs Bound's small, original ARM7TDMI Thumb entry there and temporarily
branches nine native entry points: battle-to-overworld and cable-room return,
physical link exchange, serial VSync, multiplayer ID, send/receive queue counts,
and serial enable/disable. No on-disk ROM patch is applied. `NativeBattle/battle-entry.c` calls the existing native task,
including Radical Red's own battle-start hook. The generated header is checked
with `PrototypeTools/build-battle-entry.py --check` using devkitARM.

Verified exact-profile bindings include ScriptContext_SetupScript (08069AE4),
TryBattleLinkup (08081064), Task_StartWiredCableClubBattle (08081318), the Radical
Red start hook (09042DB8), CB2_InitBattle (0800FD9C), the cable-battle return
callback (08081668), and native ReturnFromBattleToOverworld (08015B58). The
implementation uses address facts and native routines;
it does not embed recovered Nintendo code. Upstream references are
[pret/pokefirered cable_club.c](https://github.com/pret/pokefirered/blob/master/src/cable_club.c),
[battle_main.c](https://github.com/pret/pokefirered/blob/master/src/battle_main.c),
[link.c](https://github.com/pret/pokefirered/blob/master/src/link.c),
[link.h](https://github.com/pret/pokefirered/blob/master/include/link.h),
[script.c](https://github.com/pret/pokefirered/blob/master/src/script.c), and
[cable room scripts](https://github.com/pret/pokefirered/blob/master/data/scripts/cable_club.inc).
These references alone do not establish compatibility with a modified ROM;
exact-profile disassembly and runtime acceptance are separate evidence.

## Transport and ownership

Bound replaces physical serial timing with a bounded mailbox in the native
link queue storage. Each completed emulation frame drains outgoing eight-word
commands and admits incoming commands. The original `LinkMain2`,
`ProcessRecvCmds`, block transfer, player/party exchange and battle engine remain
active. Each command carries a sequence and is acknowledged only after the peer
frame consumes it. Own commands loop back after that acknowledgment, preventing
the local game from finishing before the remote game processes its final data.
Virtual serial enable/disable preserves commands through the native close/reopen
transition between setup and battle. Every command also carries its native
connection generation. A new connection waits for the matching peer generation;
stale commands are discarded, future commands wait on the host, and native
incoming/loopback queues reset when that connection opens. This prevents setup
shutdown commands from closing the subsequent battle. No socket or vendored core
patch is required.

The installed Agora 4.6.4 reliable data transmission API carries these commands
as priority `cmd` messages, capped at 256 bytes and paced below 80 packets/second.
The client enables the installed SDK's RDT connection flags before joining. This
API is marked technical preview by the SDK. No SDK version, cloud configuration
or backend resource changes. `BFB1` prepared/connected/finished/abort controls use
the existing reliable ordered stream separately from movement.

`BFS1` frames bind the activity UUID, monotonic sequence and bounded length.
Admission rejects oversized records, unknown opcodes, invalid block lengths,
unsolicited or excess block continuation writes,
wrong activities and excessive reordering or queued bytes. The mailbox holds
32 commands in each direction; host ingress holds at most 8 KiB of command data
plus 2 KiB of connection/sequence tags. SDK receive
callbacks copy bounded commands only; they never access emulated RAM. The frame
owner alone installs hooks and reads/writes the mailbox. Channel closure fences
SDK destruction. A missing heartbeat, overflow or native link error restores the
private pre-battle state.

## Friendly state and interruption

Before entry, Bound saves a private native state with a matching game ID, ROM
profile and SHA-256 journal in Application Support/Friend Battles. The folder
is excluded from cloud backup. A successful end restores this state, checks the
normal overworld callback, removes only that battle's snapshot/journal, rebinds
the reader and resumes when the app can run. Normal save slots are untouched.
The return hooks run at the native return-to-overworld boundary and avoid the
physical-link shutdown and link-room record/autosave path. The parked callback
continues native tasks so queued final battle-controller messages drain before
both peers acknowledge completion. When a peer finishes and the local native
engine has independently computed a result, the frame owner forwards its cable
closure through the native CloseLink routine (080098B8). This lets the remaining
link-room end sequence complete without changing either native outcome. Native outcomes
are sampled from the actual game and displayed after both peers finish.

An interrupted battle retains its journal until restoration succeeds. Reopening
the same game checks the profile and snapshot digest before restoring it on the
first completed native frame. A failed recovery retains the snapshot and blocks
automatic state capture. This mechanism is local recovery; it is not a durable
battle history or trade transaction protocol.

## Verification

The bounded local engine harness is `PrototypeTools/native-link-battle.py` with
`NativeBattleRuntimeTests.testActualNativeLinkBattle`. It uses two explicitly
supplied owned simulators and separate working battery saves, normal game boot,
native moves, actual damage, native outcomes and restoration. It does not use
an account, friendship, RTC connection or synthetic battle result.

The ordinary-app acceptance is `FullAppGameplayUITests.testActualFriendBattle`
through `PrototypeTools/full-app-gameplay.py --battles-only --duration 1`. It
uses real native controller touches, the adjacent-player/A entry, consent,
real Agora native commands, party damage, a normal knockout, matching outcomes
and restored distinct locations.
Credentials, ROMs, saves, screenshots and test receipts remain in ignored local
validation storage. See the current results below for executed coverage.

## Observed results — October 20, 2026

The final normal-app Agora knockout acceptance, `paired-21-retry-1`, passed in
**314.7 seconds** with two owned iOS simulators. Both players used Friends,
walked to adjacent tiles, used A to request Battle and accepted consent. Native
controller touches selected moves; both games observed real damage and held-item
healing. The native game produced **won (1)** and **lost (2)** outcomes after a
knockout. Each app recorded one completed battle and one successful restore,
returned to its distinct original tile (6,8 and 7,8 on map 4:3), and resumed a
live overworld reader with the interaction closed and no battle failure.

The private receipt `live-receipt-21.json` confirms fixture ROM/seed hashes,
removal of the temporary QA friendship and one-use inputs, original friend-list
restoration, and all 57 present protected setup files unchanged. The absent
source-Mac CLI cache marker is recorded explicitly. All 17,060 pinned source
files also verify unchanged. Cloud resources in source, Debug and Release match.
The generated 864-byte entry is present identically in both compiled products;
Release excludes the simulator-only QA launch flag and controls.

The final Debug builds and unsigned iPhone Release build passed. All **44**
focused protocol, interaction, presence and controller checks passed, recorded in
`command-focused-2.log` / `.xcresult`; final build evidence is
`command-companion-build-8.log`, `command-build-5.log`, and
`command-release-8.log`, under ignored local validation storage.

This is single-battle acceptance with the private one-Pokémon fixture. Physical
phones, separate networks, wider party/move/ability coverage, and the native
Run/forfeit path remain unverified. Interruption recovery is implemented, but the
final run does not establish a complete interruption matrix. Trade still does
not exchange Pokémon. The earlier serial-word tunnel drafts and unsuccessful
finish/menu-automation attempts remain private; they are not acceptance evidence.
