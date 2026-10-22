# Game-owned shared world progression (ABI 1)

This worktree requires the matching `rrbin-integrated.gba` build from
`/Users/evandev/dev/integratedred`. The cartridge contains the progression rules,
native entry points, snapshot producer and permanent waiting dialogue. Bound
imports generated release metadata, reads a versioned game snapshot and writes
only the declared peer-data port. It no longer ships or installs the shared
world C payload. The original unchanged ROM remains a separate solo artifact.

Build/import instructions and the precise contract are in
`/Users/evandev/dev/integratedred/docs/integrated-multiplayer.md`. Update the
game and app together using the matching exported interface.

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

`BWP2` is a separate binary message on the existing authenticated, expected-peer
Agora interaction stream. It includes a ruleset UUID, ABI and checkpoint/save
versions, 800 opaque checkpoint bytes, map identity and up to sixteen boulder
positions. Maximum 967 bytes, with send attempts bounded to twice
per second even when the transport fails. Presence packets still contain only poses.
Both local ROMs must pass the generated exact integrated-release SHA-256 profile.
Unknown versions, BWP1 and mismatched rulesets are rejected. No backend/config,
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
Waiting dialogue resides permanently in the game ROM and remains dismissible
after restoring a waiting state with the host session ended. The game reserves
2 KiB through its native allocator for two committed output buffers. Bound can
read the previous complete frame while the game writes the next one.

The peer-data port is outside emulator save states, so loading an old state
cannot restore expired peer authority. A game-output rewind/reset rotates the
network challenge; stalled output expires after 180 completed core frames.
The 128 KiB battery-save format is unchanged. Raw emulator states require the
exact integrated ROM build; use a cold boot and Continue for existing batteries.

Only the completed-frame owner accesses the bridge. Game instructions are
composed into `09ff0000..09ff4000` during the cartridge build. Bound writes only
the declared 1 KiB host-data port at `09ff4000`; it does not change the cartridge
file or earned save progress. Base-hash verification reconstructs the original
view in a temporary copy for existing native bridge admission. Soul Link,
invitations and native trade/battle retain their separate adapters.

## Verification

`PrototypeTools/build-shared-world.py --check` verifies imported metadata and
Swift compatibility constants. `PrototypeTools/verify-shared-world.py
--game-source ../integratedred --rom ../integratedred/build/rrbin-integrated.gba
--output <ignored-report>` delegates ARM execution to the game-owned verifier.
There is no second gameplay implementation or app-generated gameplay capsule.

`SharedWorldTests` covers BWP2 bounds and compatibility rejection, handshake,
stale/reordered/retired packets, reconnect, save rollback, frozen output and
game-output generation changes. The native VBA-M tests cold-boot the matching
ROM with a disposable battery, exercise actual movement stop/release and both
trainer entry paths, and restore the permanent waiting dialogue after the host
session ends. Immutable cartridge hashes must match before and after every
shared-world attach/update/detach. Native invitation, interaction, presence,
cable and Soul Link regressions are included.

The integrated multi_red gameplay fixture additionally proves actual Route 24
movement and automatic trainer approach: one seeded local trainer-1 win shows
the wait dialogue; matching peer progress opens movement and starts Lass Ali's
Jigglypuff battle. Loading a prior ready state with a disconnected current host
port cannot restore permission. Native warp and local-win seeding prepare these
fixtures; controlled peer input is held fresh. This is not a natural networked
pair of completed victories.

This variant passed 65 selected integration tests with no failures or skips,
67 game-owned ARMv4T checks, Debug simulator and unsigned iPhone Release builds,
and integrity checks for all 17,061 pinned source files.

Final evidence is recorded in `Docs/INTEGRATED-MULTIPLAYER-VALIDATION.json`, with
full build logs and XCTest bundles retained under this worktree's `.build/`.
Earlier 61/62-test reports and app-installed capsule receipts document the prior
architecture and do not establish this cartridge variant.

Two physical devices, separate networks, paired normal-app Nugget Bridge battles,
complete Strength puzzles and all custom story gates remain runtime acceptance
limits. Simulator/ARM checks must not be described as those playthroughs.

## Paired Bound check

The two-player simulator check passed with audio disabled. Two independent
Bound/VBA-M processes exchanged their real checkpoint snapshots through the
production `BoundSharedProgression` and BWP2 handshake over a local reliable
relay. Both players completed the native first-trainer battle. Trainer #2 showed
the game's waiting dialogue for neither win, A-only and B-only; both players
entered trainer #2's native battle only after both first wins were present.

The fixture uses native Route 24 warps, initially cleared bridge flags, a
level-14 disposable Chikorita with boosted cached stats, and player A's own
before/after-win emulator states to exercise both asymmetric cases. No host code
awards the victory flags. The valid paired run took about 140 seconds. Screenshots,
working batteries, raw states, XCTest bundles and prior failed fixture attempts
are retained under `.build/paired-bridge-*`. The compact receipt is
[PAIRED-NUGGET-BRIDGE-VALIDATION.json](PAIRED-NUGGET-BRIDGE-VALIDATION.json).
This does not establish physical-device, Agora or normal-app invitation flow
acceptance. Full QA evidence remains in the preserved worktrees.
