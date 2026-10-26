# Local multiplayer isolation candidate

This coordinated task is local only. No push, deployment, ROM publication,
shared-simulator refresh, TestFlight, or Xcode Cloud action is authorized.
The two repositories remain independent. The parent workspace instructions and
the user's ordered task override standing delivery instructions.

## Starting pair

| Component | Recorded baseline |
| --- | --- |
| Bound commit | `00bb9324a28d473867d4d5be2c891bf7cefa298a` |
| multi_red commit | `8d8a12d3f8e81fac70dfc8498bc88814078722bc` |
| Combined gameplay input SHA-256 | `689299664a954c12dad66e03c2d18446b348cb31bd98b395c87b9b514b288066` |
| Existing integrated ROM SHA-256 | `8bf5b9675e0e34e785b0a40eb2d8120a1d2d6874890c4f6d2f43b5d1d3ab90fb` |
| Existing ABI / wire | 1.0 / 2 |
| Existing checkpoint / battery / raw-state layout | 1 / 1 / 5 |
| Existing setup settings | 5 |
| ABI header SHA-256 | `b8fcef0e0c265f6cedc074cf7f24747bbdd84d67c82e0c3ad7e4296c9e996ed1` |
| Contract SHA-256 | `9dc546452bb7932ee124911f81f11e4e7c6ccf605b84642425d3c77ecb0018e8` |

Both remote main refs were fetched before creating
`codex/multiplayer-isolation`. Bound local main matched remote main. multi_red
local main (`8741e216580667da5cc6e26d3944a16f49984695`) was 19 commits behind;
the isolated game branch starts at remote main. The primary game's dirty
`4person` checkout and other branches are excluded and preserved.

Core pins remain DeltaCore `633dfa86967816315fe19b482511dab1ce517f28`,
GBADeltaCore `869c34aeca9dd2b3fbd329092bb2743b0ae80c98`, and VBA-M
`453fa0decf179360926fb417725a794aa496d6e3`. The GBA core identifies as
`com.rileytestut.GBADeltaCore`, version 1.0/build 1, with native serialization
`SAVE_GAME_VERSION_10`. Battery compatibility and raw-state compatibility are
separate; ABI equality never authorizes cross-ROM restore.

## Baseline behavior and gates

The initial pair has independent progression, owner-specific server checkpoints,
durable gap-aware event history, and native friendly battles. Its contract does
not enable cooperative doubles. Enabling the existing cooperative builder exposes
two competing claims on native ROM offset `0x2E33C`; this must be composed with
both completion responsibilities retained and overlap detection intact.

Stabilization must reproduce the old pair, build the combined cooperative ROM
deterministically, record every hook/reserved region, pass focused native checks,
and pass an unsigned Release iPhone build before structural SDK changes.

The current host selects one compiled exact-ROM profile. Replacing its generated
hash would reject old runs. Supporting both requires the original exact-ROM
descriptor/adapter/layout route; an ABI-only or hash-only allowlist is not enough.
No save conversion, event-origin reset, cursor reset, ownership reassignment,
namespace change, or core replacement is permitted.

## Validation isolation

Use the paired worktrees beneath the parent workspace and explicit
`BOUND_GAME_SOURCE`. Use the approved QA launchers. The game worktree's ignored
`.venv` link reads the preserved repaired runtime; no runtime reinstall was needed.
Build caches, logs, fixtures, temporary files, package caches, and DerivedData
belong to the task. Never run simulator-selection defaults in `verify.sh`.

Local untracked evidence is under `artifacts/multiplayer-isolation` in the parent
workspace. Relocation evidence records matching file metadata and selected
content hashes, preserved heads/status/refs, repaired worktree links, and disabled
publisher/simulator LaunchAgents. Raw ROMs, saves, states, and build output are
excluded from commits.

## Acceptance evidence still required

- Save package formats, per-owner checkpoint heads, journal gaps/replay,
  receipt/application acknowledgements, permanent losses, activity recovery,
  ownership conflicts, and preservation of legacy local files.
- Ordinary single-player saving, accounts, settings/customization, and video.
- Byte-identical old/extracted codecs and malformed-input decisions.
- Measured invitation/frame/checkpoint improvements and bounded queues.
- Scoped DEBUG authorization, durable paired restore, custom coordinated capture,
  return to original runs, and all 15 individual native progression statepoints.
- A second source-owned sample ROM and a deterministic patch round trip.

Existing unit/instruction fixtures are synthetic and do not certify native
encounters. The expected current `build/gameplay_validation/battle.state` is
absent. An archived state exists but its compatibility/provenance is unverified.
Physical devices, WAN behavior, long sessions, and live backend activation are
not yet tested. A failing mandatory local gate blocks the corresponding claim.

## Stabilization evidence

The standard ROM reproduced the original `8bf5b967...` hash before and after
the completion-hook repair. The combined candidate is
`7e170ed0d868cc3353552523c0a417ae600c6c24b0f7c28ff2781925bf6b9ca8`;
its ABI header is
`533b8035e4a12d9b0ca1fdbd0b704195efb279275b4a8c6a8e6a33886a85ec0e`
and contract is
`a7db98d2d0f15b3b5114fbd41b9f82b1386147070e29fd953aff3bc1f7e4673e`.
The cooperative state layout is 6; other format versions remain unchanged.

Passed locally: 16 composition/reproducibility checks, 11 compiled cooperative
XP tests, 14 heap-retention cases, 14 standard and 17 combined native menu/
completion groups, paired host contract/native instruction checks, 108 Nakama
VM tests (including 9 frozen synthetic persistence regressions), 122 Swift model
tests, and an unsigned Release iPhone build using the exact combined candidate.
The model harness needed missing platform-neutral declarations and updated
expectations for the already-shipping Connections panel; production behavior
was not changed by those test repairs.

Every native hook and reserved region is in the untracked task artifact
`phase4/game/stabilization-report.json`. The original host profile is retained
in `phase4/host/original-profile`. This gate establishes a reproducible pair,
not full gameplay or old-run compatibility: the new profile still requires the
multi-profile adapter route described above before old-run acceptance.

## SDK codec extraction

The schema owner is `multi_red/source/multiplayer/sdk/protocol-v1.json`.
`PrototypeTools/sync-bound-sdk.py` imports or checks the generated C/Swift
definitions and their schema, generator, library and profile digests. It requires
an explicit `BOUND_GAME_SOURCE` and checks the selected cartridge contract.
The schema digest is
`3314fbe6797a8b5d05f3f6267b6eaf01489b7e743c246ae57595e9781400a148`;
the generator digest is
`582c4115c0aa53ced7e349a76578a0b3c38139018656ffaa2b78d626ff493b19`.

SDK bytes, UI frames and reliable/world envelopes now serve the existing host
wrappers. Native committed-mailbox helpers are shared with the ROM. Pokémon
validation, maps, settings and native boundaries remain in their existing
owners. No journal, save, wire or ROM identity changed. Both standard and
combined ROMs and their legacy ABI headers match the phase-4 bytes exactly.

Frozen old implementations are test-only oracles. The host comparisons cover
malformed lengths, every request/envelope byte, reserved commands, sequence
boundaries, text and 2,048 host-flag combinations. Native checks cover 65,545
scalar vectors and 589,905 sequence comparisons. All five kinds of stale
generated import are rejected. Game tests cover 23 codec/build/cache cases and
33 compiled-validator cases, including four torn-input cases. There is one
live implementation for writes, sends and native effects.

## Event and lifecycle extraction

`SDK/BoundSDKEvent.swift` and `BoundSDKEventJournalRules.swift` own the existing
event values and pure journal transitions. Existing names remain aliases;
SaveStore still owns authentication, locks, filesystem transactions and the
managed in-memory store. Soul Link payload meaning and acquisition checkpoint
policy remain outside the SDK. Receipt, application, peer acknowledgement and
verified server persistence are distinct; a managed journal receipt alone is
not durable.

`BoundSDKReliableSession`, deferred actions, checkpoint cancellation, generation
tokens and retry delays serve the existing host wrappers. The sharing bridge
uses `BoundSDKRoomTransport` with Nakama as its provider. Wire formats, queue
bounds, timer values, native dispatch and independent video/session generations
remain unchanged. A transport accepting a packet does not establish persistence.

The focused hosted gate passed 152 tests, including 16 new oracle/interface
tests and existing save/recovery, Nakama, ROM and foreground reconnect checks.
The initial compiler attempt lacked an import in a test-only oracle; its log
is retained. A frozen cursor-merge comparison also exposed an existing adjacent
sparse-gap restoration rejection. This structural commit deliberately retains
that decision; correcting it requires a separate behavior change and regression.
The full extraction Release/save gate follows adapter and persistence work.

## Original and combined ROM routes

`MultiRedAdapter` admits complete owned files by exact SHA-256. Immutable
generated profiles bind their content-addressed game IDs, rulesets, layouts and
cooperative capability. Native profiles retain separate descriptors, dynamic
ranges and complete base-hook restoration tables. The original profile is
frozen from `00bb9324`; it is not regenerated from the newer game source.

| Profile | Game ID | State layout | Cooperative doubles |
| --- | --- | --- | --- |
| Original `8bf5b967...` | `5e572144dc845a8b3576b38672447c6507d9f47d` | 5 | No |
| Combined `7e170ed0...` | `a08fc3e61882d725c15e848a44fb00ac2802db42` | 6 | Yes |

Player/scene interpretation, cartridge UI/world access, native activity entry
and state capture/restore delegate through the adapter boundary to the existing
implementations. Active host services carry the admitted profile rather than
assuming the newly bundled ROM. Native VBA-state restore also checks the saved
world ruleset/layout before mutating a managed core; unrelated diagnostic ROMs
retain their existing core/title validation.

The updater installs the combined ROM separately, retaining the original
library records, files and reset-generation restriction. Its optional
`preservedGenerations` receipt field is absent for ordinary updates; old receipts
still decode. Exact pre-update receipt bytes are retained in the transaction
backup. This is not a run or save conversion. Older hosts do not understand this
extra updater fence, so downgrade requires coordinated recovery of the original
ROM, library/files and retained receipt. Previously retired data is not silently
revived, and interrupted destructive transactions targeting the original fail
closed with their backups intact.

Passed: 26 native full-ROM/profile checks and the focused hosted gate (231
tests, 229 passed, two explicitly skipped native-chooser/Mac-only cases). The
four adapter tests include actual original and combined VBA-M cold boots,
same-profile state round trips and cross-profile state rejection without core
mutation. The first hosted attempt exposed a synthetic cooperative test missing
its admitted profile and stale controller-test expectations predating the
Connections panel; both test fixtures were corrected. No production workaround
was added. Full extraction Release and broader acceptance remain later gates.

Paused continuation restore also admits the exact cartridge synchronously before
mutating state, cancels an outstanding cooperative profile verifier, and reapplies
the immutable profile after probe configuration. This avoids a bind/restore race;
the final hosted gate includes these ordering checks.

## Persistence boundary

The coordinator uses `BoundSDKEventPersistence` and
`BoundSDKManagedCheckpointPersistence` for event journals and managed checkpoint
operations. Both facets retain the same existing `BoundMultiplayerSaveStore`;
they add no cache, second writer, migration or new storage location. The SDK
uses associated identity/package/manifest types, while the host owns their
existing representations and the acquisition checkpoint policy.

Legacy archives, device grants, file transactions and interrupted-activity
recovery stay on the concrete store. Native capture, server authorization and
upload timing remain with their existing callers. A managed in-memory receipt
does not prove server persistence or advance a confirmed head.

The final extraction gate passed 364 hosted tests (362 passed, the same two
native-chooser/Mac-only skips), 108 backend regressions, all four generated
contract/model checks, and an unsigned Release iPhone build. Four persistence
tests verify unchanged existing files and idempotent journal bytes, shared
managed RAM state, host acquisition policy before batching, and finite history
targets that require native application. The Release bundle contains the exact
`7e170ed0...` combined ROM. These gates establish the structural extraction;
full paired gameplay, DEBUG fixtures and device/WAN acceptance follow separately.

## Measured responsiveness work

The first behavior commit repairs cursor union normalization: an imported
contiguous prefix now consumes already received adjacent sparse events. The
public two-store restore test failed before the change and passed unchanged
afterward; 65 hosted save/event tests and 11 standalone event tests passed.
No journal format, event identity, owner check or acknowledgement meaning changed.

The PC observer validates every pointer and compares all 43,500 bytes each
field callback, retaining immutable bytes when unchanged. It caches denied
policy until ledger assignment. On the same paused, populated actual VBA state,
fresh-process simulator runs (128 warmup, 4,096 measured samples) reduced native
snapshot median from 12.833 to 2.500 microseconds and complete observer median
from 31.625 to 16.625 microseconds. Peak RSS growth was 81.49 versus 25.70 MiB;
payload and ledger hashes matched. Three native tests and 56 Soul Link tests
passed. These are isolated observer costs, not physical-phone playback parity
or a comparison with the complete upstream Delta application.

Friendly invitations use a nonmodal pending notification. Explicit A/tap opens
the native menu; submitting closes it through the native cleanup path. Pending
requests expire after 30 seconds, including disconnected time; admitted activity
recovery is retained. Admission checks authenticated owner/room/run, eligibility
and verified positions again after native cleanup. Cancellation IDs are never
evicted while the session can receive them: its 256-request capacity rejects new
invitations rather than reviving retired ones or growing memory without bound.

Native menu readiness now includes the actual Yes/No startup timer and
multichoice fade/delay gates, so the first accepted A/B edge is handled. All 28
invitation tests passed, including actual VBA pending-frame progress, explicit
menu opening, cancellation/expiry cleanup and notification hit testing. Exact
native instruction probes and 23 compiled readiness checks also passed.
