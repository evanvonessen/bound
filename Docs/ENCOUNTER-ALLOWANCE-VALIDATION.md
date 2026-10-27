# Encounter rules local validation — October 27, 2026

Local candidate on the paired `codex/multiplayer-isolation` worktrees. The
workspace restriction keeps commits local: no push, ROM release, backend deploy,
TestFlight, Cloud operation, ordinary save or shared simulator changes.

## Exact pair

- ROM SHA-256: `d7d9ec63064f9ea8dae75fa2ee05817056769f2cc933f4291414267575885583`.
- ROM SHA-1/game ID: `eb96749d9ebb8c9e4300885a59b930e94e23eca3`.
- Ruleset: `066c5838b2d56b6ef6b5db08ec17e25b`; save-state layout 13;
  core state version 10; battery-save version 1.
- The pre-shiny cartridge `fcfaa8a9fb022656994a429be4cba5b9f14ba6c477ec813d2d6a2aa3878edc00`
  remains a frozen layout-12 profile. The six profiles retain separate raw-state
  admission; matching ABI versions do not establish state compatibility.
- The unchanged reconstruction input is
  `689299664a954c12dad66e03c2d18446b348cb31bd98b395c87b9b514b288066`.

The new cartridge changes the Route 4 seller to one shiny Magikarp for ¥75,000,
with no preceding regular gift. The native shiny and one-time purchase flags
remain authoritative. Declining, insufficient money and full storage leave money
and ownership unchanged. The battery format is preserved. Historical raw states
require their own exact profile; no blanket migration is claimed.

## Rules

Each named native met location has one ordinary wild/raid allowance per player.
Grass, water, fishing and all dens sharing that location use the same slot. A
failed or fled encounter spends none. Fixed static encounters and non-egg gifts
are separate categories, pairing Static N ↔ Static N and Gift N ↔ Gift N. Eggs
pair Egg N ↔ Egg N independently of receipt/hatch locations. Celadon permits one
prize Pokémon across all choices and has its own pair. Permanent linked losses
apply to every category; release, boxing, reconnect or older checkpoints never
reopen a slot. The native bag/quick-ball gates reject before spending a ball.

## Completed local checks

Artifacts are beneath the workspace's
`artifacts/multiplayer-isolation/encounter-rules/gameplay/` directory. Maintained
scripts require explicit ROM/state/output inputs and the approved QA launcher
with `BOUND_GAME_SOURCE` set to the isolated game worktree.

| Check | Evidence and scope |
|---|---|
| Native controlled enforcement | 90 checks each against reconstruction, prior bundled and new exact ROM; receipt placement, owned-only faints, catch/prize gates, mode close and real decision-memory separation. |
| Native acquisition/storage | `native-final/report.json`: ten cases use actual catch, party/PC, gift/egg and prize currency endpoints. Presentation is acknowledged in this harness; it is not a full rendered playthrough. |
| Rendered raid and Celadon | `full-gameplay-report.json`: 73 assertions from retained mGBA states/screenshots. Original den NPC and selectors, real boss battle, native capture, rewards and field return. Raid→grass and grass→raid reject with balls unchanged. Celadon purchase, repeat and full-storage rejection pass. |
| Rendered shiny Magikarp | `magikarp/mgba-field-final/verification.json`: native NPC interaction and purchase grant exactly one shiny; repeat, decline and insufficient money change nothing. Native transaction harness additionally covers full PC and freed-slot retry. |
| Swift ledger and simulator | Eight direct ledger cases and 83 native Soul Link simulator tests: numbered categories, hatch aliases, loss isolation, duplicate receipts, monotonic restore and pause/retry enforcement. |
| Profile compatibility | Six hash-verified cartridges are admitted by their own profile, preserve native preferences and reject cross-profile raw states. Generated current contract and frozen prior profile have regression checks. |
| Game/source tools | 19 focused game tests, reproducible uncached ROM build, native cold boot, 48 profile normalization checks, generated-header/SDK sync checks. |
| Existing local suites | 123 model tests, 156 backend validator tests, nine bundler tests, source integrity, privacy and SFML checks passed. Backend code remains local. |

The dedicated simulator is `Bound Encounter Rules QA 20261027`
(`43FF1EBB-2D47-4A72-B1FB-6FEA18D23AE0`). It uses a newly generated matching
VBA-M fixture and the exact bundled cartridge; old raw states were not retagged.
The final unsigned iPhone Release build passed and contains the exact ROM
hash above. The 120 compatibility tests and 83 native Soul Link tests passed
with zero failures or skips. `final-local-delivery.json` records the executable
and bundled-ROM hashes and the local delivery boundary.

## Bugs resolved during acceptance

Acquisition receipts formerly overlapped friendly decision RAM. Shared layout
constants and compile-time guards now keep the buffers disjoint. The original RR
grant implementation is hooked directly, so native scripts cannot bypass receipt
collection. Only aligned owned-party HP writes latch native faints; enemy and NPC
records cannot create permanent owned losses. A defeated raid boss's temporary
zero HP waits for its first healthy owned observation, while an actual owned
faint remains immediately fatal. Durable loss enforcement also applies before an
explicit paused checkpoint retry opens its frame fence.

Rendered full-storage Celadon testing exposed an original-game debit without a
grant. The policy-active clerk guard now checks native storage capacity before
entering the transaction and shows the original no-room message without payment.

## Limits and activation boundary

Fixtures use synthetic native progression, party creation, map placement and
money to reach cases; subsequent rendered interactions use ordinary controls.
Raid rendering predates the isolated final Celadon capacity guard, which was
separately tested in rendered UI and the final acquisition harness. PC health was
verified with native withdrawal conversion in copied RAM; the PC menu and slot
deletion were not exercised. This is not a whole-story playthrough.

Physical two-device/WAN play, authenticated live gift/static event acceptance,
cooperative human raid recovery, full native hatch/evolution/PC menu sequences,
every water/fishing method and every prize/item/TM choice remain unverified.
These limits do not disappear because a controlled boundary or ledger test passes.

The live Nakama backend is unchanged. Its validator requires a later authorized
rollout before accepting new gift/static facts. Local validators retain owner,
checkpoint, idempotence and atomic-commit fences; the existing 864-byte legacy
migration remains unchanged. Both updated apps need BSL3/BSE1. Rollout order is
server validator then both apps; preserve earlier app/server histories. No live
activation or remote ROM availability is claimed. The bundle pin is local-only,
and local builds require the explicit reviewed `BOUND_DEVELOPMENT_ROM` input.
