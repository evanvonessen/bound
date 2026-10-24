# Native friend battles

Walk to the cardinal tile beside a connected friend, face their tile and press
A. Choose Battle in the native game menu; the friend answers its YES/NO dialogue. Bound prepares a private recovery
snapshot, transports the game's two-player link commands over the authenticated
Nakama gameplay connection, and starts the cartridge's native single battle with each current party.
The ordinary game controls select moves and Pokémon. Opening the app menu,
or deliberately leaving sharing ends the friendly battle and restores
the local pre-battle world. A temporary network interruption keeps the same
battle on screen, pauses native emulation and reconnects in the background.
Quick saves and fast-forward are suppressed during
battle; quick load ends the battle before loading the selected state.

Friendly battles are also available during Soul Link. A core-scoped observation
fence excludes temporary faint events, party HP, team changes and victory history
from the durable run. It starts before native battle preparation and stays active
until the prebattle state is verified restored. Interrupted battle recovery sets
the same fence before guest frames resume; failed recovery retains it. The native
faint buffer is restored with the snapshot, preserving genuine prebattle events.
Already recorded losses remain enforced. Automatic paired checkpoints wait;
explicit saves first end and restore the friendly battle. Recovery snapshots and
run transfers cannot replace each other's temporary state.

This entry supports only the SHA-256-verified Radical Red 4.1 profile already
used by live presence. The player must be in an unlocked normal overworld scene
with a party of 1–6. The native game performs party/link checks. Bound does not
manufacture a win/loss or rewrite party data to simulate a battle. Trade now uses its own persistent native flow; see
[native friend trades](BOUND-NATIVE-FRIEND-TRADES.md).

## Native entry

`BoundVBABattleBridge` is called only with the core paused or on its completed
frame owner. It verifies the entire loaded 32 MiB ROM and an unused 2 KiB tail.
It installs Bound's small, original ARM7TDMI Thumb entry there and temporarily
branches ten native entry points: battle-to-overworld and cable-room return,
physical link exchange, serial VSync, multiplayer ID, send/receive queue counts,
serial enable/disable and Radical Red's cleanup flag check. No on-disk ROM patch is applied. `NativeBattle/battle-entry.c` calls the existing native task,
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

The current Nakama gameplay route carries native commands independently of
Agora friend video. The legacy Agora channel remains supported without changing
its pinned SDK. `BFB1` prepared/connected/finished/abort and resume controls use
the authenticated expected-peer interaction route separately from movement.

`BFS2` frames bind the activity UUID, monotonic sequence, cumulative receipt
acknowledgement and bounded length. The wire retains unacknowledged packets and
retries them after loss or channel replacement; the receiver delivers each
sequence once. Each direction permits at most 64 queued packets and 128 KiB of
payload; individual payloads are at most 4 KiB. Both peers need this protocol.
Admission rejects oversized records, unknown opcodes, invalid block lengths,
unsolicited or excess block continuation writes,
wrong activities and excessive reordering or queued bytes. The mailbox holds
32 commands in each direction; host ingress holds at most 8 KiB of command data
plus 2 KiB of connection/sequence tags. SDK receive
callbacks copy bounded commands only; they never access emulated RAM. The frame
owner alone installs hooks and reads/writes the mailbox. Channel closure fences
SDK destruction. Temporary transport failure or heartbeat silence suspends the
existing wire and cartridge without resetting either sequence. Backpressure
pauses emulation before the native command queue fills. A fresh activity-bound
challenge/response is required before replaying gameplay; a room/account change,
explicit cancellation, corrupt packet or native link error remains a terminal
boundary with the existing private-state recovery.

## Temporary connection loss — October 24, 2026

Temporary loss has no timer that expels either player from a battle. Bound keeps
the activity ID, consent, native memory, command ordering and recovery journal.
Retries run while the connection recovers; incoming duplicate commands and
controls do not start another battle. Foreground resume cannot advance a waiting
cartridge before its authenticated peer is ready. Explicit cancellation is
remembered and repeated if its first notification was lost.

This continuation requires the resident process and cartridge. App termination,
changing games/accounts/rooms, disabling Experimental Multiplayer or explicitly
ending the session still uses the existing recovery path. A process restart
cannot reconstruct arbitrary unsaved live link state from a socket reconnect.
Physical-phone and separate-network validation remains pending; the dated
runtime results below distinguish the current native harness from earlier
full-app acceptance.

The same validation exposed a separate result stall without any outage: Radical
Red's loss cleanup cleared the native link flag before command 55 (`EndLinkBattle`)
was emitted. The host received its result locally while the guest waited with no
outcome. A temporary friendly-battle-only hook at `09090958` preserves native
link flags through that emission. The cartridge still produces the outcome and
terminal command; trade and cooperative hooks are unchanged. Closing the battle
restores the exact original ROM bytes, including the integrated co-op wrapper.

`PrototypeTools/qa-python PrototypeTools/verify-battle-entry.py --rom <ROM>`
reproduces that routing failure and checks the repair against the original and
current integrated ROM hashes. It verifies actual native win/loss/draw payloads,
non-link behavior, and native epilogue register/stack restoration. The generated
entry occupies 964 bytes of its 1008-byte allocation.

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

## Observed results — October 24, 2026

`native-reconnect-battle-ready` passed on both owned simulators in **168.3
seconds** with integrated ROM SHA-256
`d2a206998f67db500f88ccc197fc9977ebd437f714661916abbc7b484e38370a`.
Both transports silently dropped packets for 18 seconds after native entry.
Production liveness detection paused the resident games without an injected
disconnect callback; fresh resume challenges continued the same activity.
Native moves caused actual damage and a knockout, producing matching **won (1)**
and **lost (2)** outcomes. Both wire and native command queues were empty.

Both games restored their exact pre-battle HP and returned to a clean overworld
with temporary hooks removed. Soul Link ledger, loss bits, memorials, timeline
and journal bytes were unchanged, with no recovery error. Original fixture ROM
and seed files remained unchanged. The disposable fixture waits for its native
starter to appear in the ordinary Soul reader before creating the test ledger;
earlier attempts that raced that observation are retained as failed evidence.
This run uses two actual VBA-M cores over a local relay, without live account,
Nakama/Agora, physical-phone or separate-network acceptance. Current full-app
background/foreground and paired native cooperative-battle validation remain
pending.

The hosted focused suite executed **215 tests**, with zero failures and one
optional exclusive-host performance test skipped. The final cooperative resume
challenge passed all 14 cooperative contract tests again. The unsigned Release
iPhone build passed with the 964-byte native cleanup repair. Generated guest,
pinned-source and privacy checks passed.

The native instruction regression reproduced the missing terminal link command
on both the original and current integrated ROM, then verified native win, loss
and draw command routing through the repair. Non-link flag behavior and the
native epilogue's stack and registers remained unchanged. These instruction
checks supplement complete paired-game execution; they are not phone/network
acceptance.

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
final run does not establish a complete interruption matrix. The trade status in this historical battle acceptance predates the
[native trade implementation](BOUND-NATIVE-FRIEND-TRADES.md). The earlier serial-word tunnel drafts and unsuccessful
finish/menu-automation attempts remain private; they are not acceptance evidence.
