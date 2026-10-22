# Shared world progression (Radical Red 4.1)

Enable Experimental Features, connect to a friend and enable Live Friend Sprites
on both devices. The supported exact-ROM multiplayer profile now uses both
players' progress for physical world barriers. Each player still earns their own
wins, badges and obstacle clears; no partner save or completed flag is installed.

## Gates

- Nugget Bridge's five trainers are ordered Cale (`0x6e`), Ali (`0x7b`), Timmy
  (`0x5c`), Reli (`0x7a`), Ethan (`0x90`). Every later native trainer command checks
  **all** earlier wins on both sides, including when joining with an advanced save.
  A denied battle uses a native field dialogue: “Wait for your friend / to reach
  this point.” The bridge corridor also remains physically blocked after your
  own win, including stepping forward from the trainer's sight line.
  Both the manual `trainerbattle` command (`0x5c`) and the final
  `dotrainerbattle` launch (`0x5d`) enforce this. Automatic sightline encounters
  bypass the first command, so the final launch rechecks the actual configured
  opponent and partner freshness, including expiry during intro dialogue.
- Native `checktrainerflag` script prerequisites require both wins. Personal
  trainer flags and the game's already-defeated handling remain personal.
- Defeated stationary normal/double trainers retain a shared collision gate
  along their original sight corridor until the partner wins too. Returning to
  the arrival side remains possible when the native previous tile identifies it.
- Flag-controlled map objects remain collision obstacles at their native template
  tile after local removal while the partner still has the object. This covers
  temporary Cut/Rock Smash objects and permanent removed story blockers. Temporary
  flags are scoped to the partner's current map, never reused across maps.
- Moved Strength boulders retain collision at the partner's position. The first
  native push remains available; a boulder still present locally keeps its normal
  native collision/push behavior. Offscreen saved object templates are included;
  boulders already hidden/cleared by their own flag are excluded.
- Native badge checks outside battle require both badges, preserving local badge
  ownership and ordinary personal badge behavior during battle.

The collision hook covers native walking/bike/surf collision queries. It does
not draw a second copy of an absent obstacle or replay the other player's Cut
animation. It does not synchronize NPC scripts, rewards, inventory, scene
variables, forced scripted warps or the whole world. Arbitrary custom story
scripts and every late-game route are not established by these checks; extending
those requires verified native predicates, rather than substituting partner RAM.

## Admission and lifecycle

`BWP1` is a separate binary message on the existing authenticated, expected-peer
Agora interaction stream. It carries 800 bytes of bounded event/trainer predicates,
map identity and up to sixteen boulder positions. Maximum 943 bytes, with send attempts bounded to twice
per second even when the transport fails. Presence packets still contain only poses.
Both local ROMs must pass the existing exact SHA-256 profile. No backend/config,
signing, account or dependency changes are needed.

Each binding/reconnect gets a new UUID challenge. Only an acknowledgment of the
current challenge admits progress; increasing sequences reject duplicates and
reordering. A one-sided reconnect permits the still-online peer to acknowledge
the new challenge. A replacement peer cannot be overwritten by a retired sender.
Snapshots expire after three seconds and rotate the challenge, so delayed
reliable-stream backlog cannot reopen a gate. A completed-frame lease also expires if
main-thread policy delivery stalls. Without fresh progress, native player movement
and trainer launches wait; native battles and menus keep running. Explicitly
ending multiplayer or disabling the feature restores ordinary solo behavior.
Waiting dialogue uses only native opcodes/text in inactive link-queue RAM
(`03004200`), which ordinary save states serialize. It remains dismissible after
a restore without multiplayer ROM hooks; native link setup initializes the queue
before a trade/battle.

Only the completed-frame owner accesses the bridge. The new original Thumb shim
occupies verified empty loaded-ROM bytes `09ff6000..09ff8000`, separate from Soul
Link, invitation and native trade/battle code. It changes no cartridge file and
writes no save progress. Base-hash verification removes owned patches from a copy,
so Soul Link, invitations and native trades/battles can coexist. Save-state
rollback reports current progress; there is no monotonic union of earned flags.

## Verification

`PrototypeTools/build-shared-world.py --check` verifies reproducible original glue.
`PrototypeTools/verify-shared-world.py --rom <private-ROM> --output <ignored-report>`
executes the real ARM predicates, native trainer dispatcher/check command and
expanded flag accessors. The terrain engine return is controlled in that test;
it is not a full game playthrough. Dependencies for this optional check are
Unicorn 2.1.4, installed only in ignored disposable tooling.

`SharedWorldTests` covers bounded packets, malformed/truncated messages, both
handshakes, stale/reordered/retired packets, one-sided reconnect and save rollback.
`NativeBattleRuntimeTests/testActualSharedWorldCollisionAndNativeCoexistence`
uses the supplied private simulator fixture (`BOUND_WORLD_RUNTIME=1`), cold-boots
VBA-M, installs both hook owners, verifies native link admission, and checks actual
movement is blocked with no peer and released with matching progress. It verifies
original flags/ROM/seed preservation, plus saving/restoring the native waiting
window after removing both ROM hook owners. Native invitation, interaction, presence,
cable and Soul Link regressions remain part of the focused test run.

`NativeBattleRuntimeTests/testActualSharedWorldSightlineLaunchWaits` exercises
the second launch command and its save-state recovery in the actual VBA-M core.
The isolated multi_red native gameplay fixture also uses real Route24 movement
and automatic trainer approach: one local trainer-1 win shows the wait dialogue;
matching peer progress opens movement and starts Lass Ali's Jigglypuff battle.
The fixture warps to the bridge and seeds the local win, with controlled peer
snapshots. It does not simulate a natural pair of completed wins over a network.

Sightline-fix verification: **62 focused integration tests, zero failures or
skips**, **53 ARM checks**, and a reproducible **2,140-byte** capsule. The native
launch dispatch slot is checked, owned and restored alongside the existing
hooks. The capsule matches multi_red's maintained source and generated bytes.
Debug simulator and unsigned iPhone Release builds pass; all 17,061 pinned
source files still verify. The dedicated simulator uses disposable ROM/save
fixtures and preserves their input bytes.

Two physical devices, separate networks, paired normal-app Nugget Bridge battles,
complete Strength puzzles and all custom story gates remain runtime acceptance
limits. Simulator/ARM checks must not be described as those playthroughs.

Initial 2026-10-21 publication verification, before the sightline fix:
**61 focused integration tests, zero failures**;
**45 ARM gate/ABI checks**; Debug simulator and unsigned iPhone Release builds
passed. Actual native movement stop/release, hook coexistence and restoring the
waiting dialogue without ROM hooks passed. All **17,061** pinned source files,
932-byte native link guest and 376-byte Soul Link guest remain unchanged. The
source, Debug and Release cloud configuration hashes match. Detailed local logs
and receipts remain ignored under `.build/shared-world-*` in the feature worktree.
