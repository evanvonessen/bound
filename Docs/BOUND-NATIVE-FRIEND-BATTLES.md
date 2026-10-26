# Native friend battles

Walk to the cardinal tile beside a connected friend, face their tile and press
A. Choose Battle in the native game menu; the friend answers its YES/NO dialogue. Bound prepares a private recovery
snapshot, transports the game's two-player link commands over the authenticated
Nakama gameplay connection, and starts the cartridge's native single battle with each current party.
The ordinary game controls select moves and Pokémon. Opening the app menu or
backgrounding preserves an exact paused continuation. Run or deliberate
cancellation ends the friendly battle and restores the local pre-battle world.
A temporary network interruption keeps the same battle on screen and reconnects
in the background. Local menus, text and animations continue; only missing
player decisions wait.
Quick saves are suppressed during battle; quick load ends the battle before
loading the selected state. Each player keeps their own fast-forward setting,
including after a paused continuation is reopened. Trades still use normal speed.

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
manufacture a win/loss. Its temporary eligible party uses native healing, while
the original party remains in the recovery snapshot. Trade uses its own persistent native flow; see
[native friend trades](BOUND-NATIVE-FRIEND-TRADES.md).

## Native entry

`BoundVBABattleBridge` is called only with the core paused or on its completed
frame owner. It verifies the entire loaded 32 MiB ROM and an unused 2 KiB tail.
It installs Bound's small, original ARM7TDMI Thumb entry there and temporarily
branches fourteen native entry points: battle-to-overworld and cable-room return,
physical link exchange, serial VSync, multiplayer ID, send/receive queue counts,
serial enable/disable, the outgoing callback gate, two setup timeout gates,
Radical Red's cleanup flag check and explicit Run selection. No on-disk ROM patch is applied. `NativeBattle/battle-entry.c` calls the existing native task,
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

### Decision-only friendly battles — October 25, 2026

Friendly battles use protocol 2. After native party/link setup, each cartridge
runs its own native battle simulation and presentation. Only confirmed moves,
switches and Run decisions cross the reliable wire; Fight, Back, cursor changes,
text, animations and HP-bar updates do not. Setup, liveness, recovery and a final
result checksum remain protocol messages. Older battle clients are rejected
before entry. Trades and cooperative battles retain their native cable protocol.

`NativeBattle/battle-decisions.c` replaces the friendly battle's native transfer,
execution-bit and frame dispatchers temporarily. It uses a hash-verified empty
ROM region and bounded queues in unused virtual-cable storage, outside the Soul
Link journal. Both peers preserve their native controller orientation. A shared
seed is derived from the activity ID; battle logic owns that RNG independently
of visual callbacks and VBlank. Native overworld weather/terrain do not leak into
the friendly battle; move- and ability-generated conditions remain native.

Each decision includes an ordinal, canonical state fingerprint and bounded native
response. Duplicate delivery is harmless; invalid/stale offers cannot become
native inputs. Forced native actions need no artificial move selection. The
terminal checksum covers both canonical battlers, RNG and normalized outcome;
disagreement restores the original party and is never recorded as a successful
battle. Exact guest state, queued decisions and wire counters survive the existing
durable continuation mechanism.

Retired sessions return a marked terminal receipt when a final result is lost;
receipts do not generate reply loops. A failed local result write retains the
chosen completion/cancellation outcome and pauses the core until persistence
can retry safely. Diagnostic errors do not determine the battle result.

Network replacement fences incoming gameplay until the activity's fresh handshake
completes, while local presentation continues. Menu/background checkpoints still
pause and freeze execution before capturing it. Idle heartbeats stop during an
outage rather than filling the reliable queue. Already-ready setup/trade records
are batched up to 13 per packet without a batching timer.

### Friendly battle message sequence

1. The accepted invitation establishes one activity ID. Both phones prepare
   private recovery snapshots, agree on protocol 2, exchange native parties and
   establish the link. Their deterministic battle seed comes from that ID.
2. Opening Fight, browsing moves, backing out and moving the cursor are local.
   A confirmed move, switch or committed automatic action becomes a bounded
   decision containing its ordinal, battler, native response and state fingerprint.
3. The completed-frame owner puts the decision into the retained reliable wire.
   The Nakama client queues a targeted opcode-3 message asynchronously. Returning
   from that queue does not wait for a socket response or the other screen.
4. Nakama checks the admitted session and room membership, sender, target,
   envelope, payload size and traffic budgets, then forwards the opaque payload
   to the joined target. It does not calculate damage or approve an animation.
5. The other phone checks the expected sender/activity and reliable sequence,
   stages the decision, then verifies the native offer, ordinal and fingerprint
   when its own game reaches that choice. Early decisions wait in the queue;
   duplicates cannot execute twice.
6. Both players may choose in either order. A game with only its own confirmed
   choice waits for the missing opponent choice. Once it has both, it resolves
   the turn locally with the shared battle RNG. Text, damage presentation and
   animations do not wait for peer playback completion or packet ACKs.
7. Delivery ACKs, retries, liveness and ticket renewal run separately. A transport
   outage retains submitted decisions; fresh resume handshakes fence admission
   before replay. Menus and known presentation continue locally. App background
   or Menu may pause the core while preserving its exact continuation.
8. Subsequent turns repeat the decision exchange. At normal completion, the
   phones exchange their final result fingerprints and require agreement before
   successful cleanup. Each restores its own original party/world and stores a
   terminal receipt. Run uses a deliberate end message and can exit without
   waiting for the other player's next selection or introduction.

Server-side authentication and relay admission are distinct from the phones'
native move/state validation. Neither the relay nor the save service receives
an RPC for each text box, animation frame or HP-bar step.

### Native cable setup and retained trade/cooperative transport

Bound replaces physical serial timing with a bounded mailbox in the native
link queue storage. Each completed emulation frame drains outgoing eight-word
commands and admits incoming commands. The original `LinkMain2`,
`ProcessRecvCmds`, block transfer, player/party exchange and battle engine remain
active. Each command carries a sequence and is acknowledged only after the peer
frame consumes it. Own commands loop back after that acknowledgment, preventing
the local game from finishing before the remote game processes its final data.
Acknowledged local commands are delivered in earlier guest frames than remote
replies. Each native block receive slot also stays occupied until the ROM
consumes it: a following block cannot overwrite setup data or a controller
command while the slower peer initializes sprites or plays an animation.
The integrated cartridge retains an early real controller ACK while its native
pending-command bit is set, then applies it once when that command is armed.
The ACK cannot carry into the next command.
Virtual serial enable/disable preserves commands through the native close/reopen
transition between setup and battle. Every command also carries its native
connection generation. A new connection waits for the matching peer generation;
stale commands are discarded, future commands wait on the host, and native
incoming/loopback queues reset when that connection opens. This prevents setup
shutdown commands from closing the subsequent battle. No socket or vendored core
patch is required.

The current Nakama gameplay route carries native commands independently of
Agora friend video. The legacy Agora channel remains supported without changing
its pinned SDK. `BFB1` prepared/connected/finished/ranAway/abort and resume controls use
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
existing wire and cartridge without resetting either sequence. At 16 unconsumed
outgoing commands, backpressure pauses only the native send callback; incoming
commands and consumption acknowledgements continue draining the 32-slot queue.
Normal congestion therefore does not suspend the core or require reconnection.
A fresh activity-bound
challenge/response is required before replaying gameplay; a room/account change,
explicit cancellation, corrupt packet or native link error remains a terminal
boundary with the existing private-state recovery.

## Independent speed and local menus — October 25, 2026

The integrated cartridge builds its exact native move-menu payload alongside
the action menu. Fight, move cursors and Back render locally without a round
trip. After move confirmation, it submits the original Fight response, waits
for the native ChooseMove request, verifies the offer is unchanged, and sends
the stored native response. A changed offer reopens native selection instead
of replaying a stale choice. Link Standby begins after submission while the
required native exchange is pending. RNG, battle resolution, controller command
ordering, acknowledgements and animation-completion boundaries remain native.
This earlier implementation still waited for the slower player's controller
completion. Protocol 2 above replaces that dependency for friendly battles.

The guest send gate and native receive-slot protection permit different emulation
rates without overflowing the
bounded command queue. Network retries, heartbeats and disconnect detection use
`ProcessInfo.systemUptime`, independently of emulated frames. Native instruction
checks also cover setup timers: their frame-count failure branches are
bypassed while the temporary cable is installed, but connection-complete task
cleanup is preserved. The host's two-second elapsed-time guard owns suspension.
The local relay QA
accepts `--rate-a 3 --rate-b 1 --local-menus --latency-ms 100`; its menu checks
measure Fight, Back and Fight again in local frames, and full battles verify
complementary native outcomes, party restoration and continuation recovery.

The final 3×/1× paired run with zero added relay delay passed. Fight/Back/Fight
took 6/6/6 local frames on the 3× peer and 5/6/5 on the 1× peer, including
navigation to Growl. Both peers restored their original party and Soul Link
history after complementary native results. The 53 focused Swift checks, native
menu/ACK and queue/block-flow instruction checks, both Debug cold boots, normal
startup and the Release iPhone build passed. These are simulator and local-relay
results; physical phones and authenticated internet play remain unverified.

The final 1×/3× run passed with 100 ms relay delay and a three-second silent
outage. Detection took 1.992 seconds at 1× and 1.895 seconds at 3×. The same
battle resumed, completed with complementary outcomes, and restored both original
parties and Soul Link history. Both local menu sequences remained within six
emulated frames per transition, and both speed settings survived continuation.

## Temporary connection loss — October 24, 2026

Temporary loss has no timer that expels either player from a battle. Bound keeps
the activity ID, consent, native memory, command ordering and recovery journal.
Retries run while the connection recovers; incoming duplicate commands and
controls do not start another battle. Foreground resume cannot advance a waiting
cartridge before its authenticated peer is ready. Explicit cancellation is
remembered and repeated if its first notification was lost.

Opening Menu, backgrounding and deliberate app exit now write an exact paused
continuation: native state, battery, bridge hooks, command queues and counters,
consent, and the original world rollback journal. It is scoped to the account,
room, run, game and exact ROM. Reopening that run restores it while paused and
requires a fresh peer handshake. A durable single-consumer claim is written
before packets or frames advance, preventing an old trade execution from being
replayed. A failed write keeps the activity paused and blocks destructive exit.
An unexpected foreground crash without a completed pause checkpoint still uses
the existing recovery journal. Account/room changes and explicit cancellation
remain deliberate session boundaries.
Automatic cold continuation is supported by the current server-run launcher.
Legacy local-ROM activities retain Menu/background execution, but destructive
exit is blocked and process-loss recovery is fenced until their local startup
path can authorize an exact continuation; it must not silently restore old RAM.
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
entry remains inside its reserved allocation.

## Friendly state and interruption

Eligible non-egg Pokémon are healed before native link setup sends either party.
Permanently denied Soul Link Pokémon remain excluded; the original party is
restored after the friendly battle. Native Run dispatch is observed before the
peer's action is required, so Run explicitly cancels the friendly battle and
repeats the terminal notification if necessary. Native Run outcomes 0x81–0x83
are also recognized alongside win/loss/draw outcomes.

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

### Decision protocol checks — October 25, 2026

The current adapter uses the integrated ROM SHA-256
`8bf5b9675e0e34e785b0a40eb2d8120a1d2d6874890c4f6d2f43b5d1d3ab90fb`.
`.build/decision-paired-1/summary.json` passed a complete native battle with
3×/1× playback. `.build/decision-paired-reconnect/summary.json` passed with
1×/3× playback, 100 ms one-way relay latency and a three-second silent outage.
Both peers sent five confirmed decisions and **zero native presentation blocks
after the first decision**. Both computed terminal fingerprint `1636687964`,
returned complementary outcomes and restored their original parties and Soul
Link histories. Fight/Back/Fight rendered within 6–8 local frames across the
two runs. Cold-core continuation restoration passed on both peers.

The final production code also passed
`.build/decision-battle-native-input-final/summary.json` with 3×/1× playback,
100 ms one-way latency, a silent outage and the same zero-presentation-block,
matching-result and exact-party-restoration assertions. The menu driver tracks
retained native responses so an input reset cannot lose a one-frame test tap;
it never retries an action already acknowledged by the game.

`.build/decision-run-result-retry-final/summary.json` passed native Run with
3×/1× playback and an ordinary zero-HP starting party. Native healing supplied
the temporary battle party; both original parties were restored exactly. The
faster player exited before the slower player's local introduction finished.
Each session deliberately failed its first terminal-file write, paused before
retrying, then stored the correct `ranAway` receipt on its second attempt.

All 83 distinct focused interaction, cable, continuation, ROM contract and
handoff tests passed, including terminal retry/no-echo regressions. The final
Debug test build, unsigned Release iPhone build, both generated adapter checks,
17,061 pinned-source checks and privacy-manifest checks passed.

`verify-battle-decisions.py` executes the adapter's ARM instructions for local
presentation, confirmed/canceled decisions, queue bounds, invalid input,
deterministic RNG, terminal orientation and field-weather/terrain isolation.
`verify-battle-decision-selection.py` additionally executes the exact cartridge
dispatcher on both admitted ROM profiles: normal moves, Encore, Struggle,
NoMoreMoving and normal/forced party order. Controlled prerequisites in those
instruction fixtures do not establish complete gameplay coverage for every
move, ability or item.

These paired checks use two owned simulators and the production reliable wire
over host loopback. Physical phones, separate networks, authenticated Friends
entry and device frame pacing remain pending for this protocol.

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

## Run, party eligibility and durable continuation — October 24, 2026

The current checks use integrated ROM SHA-256
`433e308025f5ec0dfc389f323092de35fbbc19dfcb9046656d4de0245523e271`
and the 992-byte generated native guest. Both paired checks checkpointed an
active battle to the production continuation store, detached its session owner,
stopped and restarted the emulator core, and created a new session owner.
Production restoration preserved the exact party, native ring cursors, queued
commands and observation before a fresh peer handshake resumed execution.
Malformed metadata, oversized integer fields and the wrong bridge mode were
rejected before the valid continuation was restored.

- `.build/native-owner-run-fainted-v5/summary.json` passed in **50.24 seconds**.
  Both ordinary, non-Soul parties began at 0 HP and reached the actual action
  menu at 21 HP, with the peer's exchanged Pokémon also at 21 HP. A selected
  Run through normal native inputs while B selected no move. The explicit Run
  marker ended both battles cleanly without synthesizing a win/loss; both exact
  original parties, including their prebattle 0 HP, were restored.
- `.build/native-owner-ko-soul-denied-v5/summary.json` passed in **148.26 seconds**.
  Each original party contained a permanently denied 0-HP lead and an eligible
  Pokémon at 1 HP. Only the eligible Pokémon entered, healed to 21 HP on both
  screens. Actual moves produced a knockout and native loss **2** / win **1**.
  Both original 600-byte parties, HP, Soul ledger, loss bits, memorials, timeline
  and journal bytes were unchanged after the clean overworld return.

`.build/native-run-instruction-both-v5.json` also verifies the actual original and v5
cartridge Run selection/outcome routines and terminal-command routing. Run is
observed only for native action 3; dispatch arguments, stack and the adjacent
peer-disconnect marker are preserved. Native outcomes 0x81–0x83 remain distinct
from the unilateral Run control. The generated guest check passes.

These are two real VBA-M cores using the production local continuation and
command paths over a host loopback relay. They do not establish physical-phone,
separate-network, authenticated Friends UI, OS process termination, or phone
frame-pacing acceptance. Paired cooperative gameplay restoration remains
unvalidated; the shipping standard v5 cartridge does not enable its cooperative
ABI. Earlier receipts below remain evidence for their named builds.

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


### October 25 two-player regression rerun

After the connected-sprite regression, the current main integration completed a
fresh 3× host / 1× guest battle over the local reliable relay. Fight/Back/Fight
took 6/5/5 local frames on the host and 6/6/6 on the guest; Growl cursor navigation
also passed. Native outcomes were 1/2, with both original parties and Soul Link
histories unchanged afterward. Both peers passed cold-owner continuation and
retained their respective battle rates. The output is ignored
`.build/paired-battle-fast-host/summary.json`.

The reversed 1× host / 3× guest run also passed with 100 ms added relay latency
and a three-second silent outage. Detection took 1.988 seconds at 1× and 1.936
seconds at 3×. Both peers resumed the same battle, retained their rates and
restored their original parties and Soul Link histories after complementary
native outcomes. Local Fight/Back/Fight and Growl navigation passed throughout.
The output is `.build/paired-battle-recovery/summary.json`. These are paired
simulator/local-relay results, not authenticated Nakama or physical-phone proof.
