# Local multiplayer isolation candidate

The two repositories remain independent. Development and validation took place
in isolated paired worktrees. On October 26 the user subsequently authorized
commits, GitHub pushes, separate ROM patch assets, the combined `multiplayer.gba`
release, and TestFlight delivery despite the earlier local-only restrictions.
Existing work, saves and historical releases must remain preserved. Shared
simulator refresh, Xcode Cloud actions and live backend deployment remain outside
this publication request.

## Current scope: progression work deferred

The October 26 steering pauses route-driven DEBUG statepoint buttons, automated
progression routes and their dependent acceptance checks. All existing code,
owner-specific candidates, failed attempts, native audits and plans are retained.
No route-generation process or simulator run was active when this pause began.
Continue only the independent SDK ownership, boundary and existing-behavior
validation already in scope; do not start another broad refactor.

The progression registry remains uncertified. The original full task is not
complete, and its progression acceptance gate has not passed. The subsequent
publication request authorizes packaging the already-tested ROM with those limits
disclosed; it does not certify the deferred statepoints or resume route work.
Workspace isolation and save-preservation restrictions continue to apply.

| Point | Preserved result; further work deferred |
| --- | --- |
| 01 — Pallet paired start | Distinct native owner candidates and authenticated paired restore/capture evidence exist; full movement/acquisition/reconnect certification remains incomplete. |
| 02 — Brock | Native early setup, parcel and Oak delivery evidence retained; latest route stops one tile short before the remaining approach. Brock encounter/rewards are unvalidated. |
| 03 — Miguel | Exact native prerequisites, target and doubles audit retained; executor remains a draft, encounter unvalidated. |
| 04 — Ann & Brooks | Exact access, actor and encounter audit retained; executor remains a draft, encounter unvalidated. |
| 05 — Ariana & Archer, Silph | Native assisted-format and prerequisite audit retained; paired encounter unvalidated. |
| 06 — Sabrina | Native doubles, prerequisites and cap audit retained; encounter unvalidated. |
| 07 — Lola & Sheila | Native sun/trigger/access audit retained; encounter unvalidated. |
| 08 — Ramiro | Native rain/trigger/access audit retained; encounter unvalidated. |
| 09 — Zac | Native gym quiz/trigger/sun audit retained; encounter unvalidated. |
| 10 — Archer → Ariana, cave | Native sequence and prerequisite audit retained; consecutive encounters unvalidated. |
| 11 — Giovanni, cave | Native Lance-assisted sequence and transformation audit retained; encounter unvalidated. |
| 12 — Lorelei rain | Native team selector and League audit retained; encounter unvalidated. |
| 13 — Lorelei snow | Native alternate selector and League audit retained; encounter unvalidated. |
| 14 — Champion | Native rival variant, intro boundary and Hall-of-Fame audit retained; encounter and postgame continuation unvalidated. |
| 15 — Pryce | Native secret-room access, frostbite and transformation audit retained; encounter unvalidated. |

This also defers the route-dependent native story-battle driver, genuine peer
faint history-cut acceptance, and natural-loss terminal recovery acceptance.
Unit, protocol and isolated backend results must not be substituted for those
native checks.

## Independent SDK/save/recovery validation before publication

Cache35 is the save/recovery app-source baseline. Broad35 passes 619 of 621 selected
tests, with two expected skips and zero failures (223.032 seconds), including
19 final-save lifecycle and 43 DEBUG session tests. Unsigned Release04 and the
generated SDK import check pass. The Release receipt matches all 350 app-source
hashes. Later native caches change only the native acceptance test harness.

All 11 paired local recovery scenarios have a passing attempt on that same app
source: held custom capture, lost custom reply, held Return, lost Return proof
reply, built-in/custom reload, buddy leave, controller revocation, stale ordinary
selection, lost custom commit across fresh processes, and partial restore across
fresh processes. Accepted attempts include confirmed final saves. The exact
attempt matrix is `artifacts/multiplayer-isolation/sdk-current-native-evidence.json`
under the shared parent; it preserves failed attempts separately.

Custom reload now preserves the first paused capture snapshot across idempotent
completion callbacks and compares its exact raw UI bytes after restore. Those
diagnostic bytes confer no field permission or frame credit. The native harness
uses throwing permission/final-receipt guards so failed evidence cannot authorize
detach or sign-out. This does not change product authority or save formats.

These are two-process simulator/local-backend checks, not physical/WAN or full
statepoint certification. Original/current compatibility tests use fresh native
states for same-profile round trips; no archived pre-existing personal/server
save was exercised. The production progression certificate registry remains
empty/disabled. See the shared parent artifact `SDK-CLEANUP-HANDOFF.md` for exact
source/ROM/core identities, current evidence, limits and future integration order.
Historical results below remain tied to their own recorded source and ROM.
Publication adds the pinned `multiplayer.gba` resource, archive hash validation
and automatic-install preservation checks. Broad44 passes 625 of 627 selected
tests, with two expected skips and zero failures. Its Release05 bundle contains
the exact current ROM and no QA input/save resources. The final folder-update
guard also passes all 31 focused ROM/updater tests in cache45. A folder enrollment
cannot retire an older cartridge merely because the matching bundled cartridge
is already installed; pending previously accepted transactions keep their existing
recovery path. Exact publication receipts are retained in the separate publication
validation record.
Unsigned Release06 verifies the final cache45 app and exact bundled cartridge.
The final `reloadCustom-45-01` paired smoke check passes both owners, including
archived-byte restoration and confirmed final saves. The underlying save/recovery
implementation remains byte-identical to the earlier eleven-scenario baseline.

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

At the initial inventory, the host selected one compiled exact-ROM profile. Replacing its generated
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
Physical devices, WAN behavior, paired long sessions, and live backend activation are
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

## Original and combined ROM routes — historical Phase5 baseline

This section records the Phase5 `7e17` baseline. The later stack-safe candidate section below records the current `02f97` route.

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

## Observation worker and recovery

The frame callback captures immutable native observations. A bounded FIFO feeds
one reducer and a separate serialized writer; pending writes can coalesce only
because their replacement includes every accepted fact and history entry.
There are at most 32 queued observations plus one retained pressure handoff.
Timeouts and failed writes retain their inputs, and a computed model is never
published as a successful storage receipt. Existing managed games still write
to their existing in-memory store; this receipt does not establish server
durability or advance the confirmed server head.

Critical acquisition and faint changes fence the next native frame until the
matching receipt is available and the existing safe native policy is applied.
The Bound-owned bridge fence preserves Delta callbacks and pause completion;
it does not change upstream core code or pins. Owner identity, cartridge load
generation and ROM identity prevent a stale fence from controlling a replacement
core. Faint acknowledgement compares the complete native ring before clearing
it. Storage failure and queue pressure keep the affected execution paused.

Checkpoint capture drains accepted observations, applies the event boundary,
and drains again while paused before copying state, managed memory and history.
Only immutable copies are encoded or hashed after resume. Native battle and
cooperative continuation captures use the same ordering; teardown and run
replacement drain the old owner before changing memory or core ownership.

The host Retry action retains the paused execution and its pending facts.
Unchanged account credentials and retained authority permit a local retry
offline. Reauthentication requires a fresh server check of the exact owner,
run, epoch and known checkpoint head; a lost upload response is recognized only
by its exact pending receipt. Unknown newer heads remain conflicts. Newly
received permanent losses are applied while paused, and an authenticated Game
Over transfers to the existing terminal flow. Resume remains subject to the
normal foreground, UI and admitted-activity guards.

Actual VBA tests cover a slow writer followed by a real backing-store failure,
unchanged RAM while a faint receipt is pending, timeout, retained native faint
records, paused retry, and permanent HP enforcement before explicit resume.
They also cover replacement-core rejection of stale owners, same-core restart,
ending a run during a critical hold, and paused state replacement without a
restart. The focused gate passed all 90 tests. The broad hosted suite passed
425 of 427 tests, with the exclusive timing opt-in and Mac launch-mode cases
explicitly skipped. It includes refused updater-close and repeated same-ROM
core replacement regressions. All four generated-source checks and the
unsigned Release iPhone build passed; the bundled ROM remains exactly
`7e170ed0d868cc3353552523c0a417ae600c6c24b0f7c28ff2781925bf6b9ca8`.
Exact authenticated terminal-response interleavings still need the later
paired coordinator integration fixture.

Fresh-process measurements use the same frozen populated VBA state and match
the ROM, state, observed payload and ledger hashes. The worker run drains
outside each timed callback, recording 4,096 callbacks, 273 admitted/reduced
observations and zero blocked, rejected or erroneous observations.

| Simulator component | Original observer | Copy/policy cache | Worker |
| --- | ---: | ---: | ---: |
| Callback median | 31.625 µs | 16.625 µs | 9.375 µs |
| Callback p95 | 166.459 µs | 137.041 µs | 12.542 µs |
| Peak resident growth | 81.49 MiB | 25.70 MiB | 64.23 MiB |

Moving work off the callback does not eliminate it: the separately measured
worker drain has a median of 11.208 µs and p95 of 170.375 µs. The worker uses more
memory than the copy-only version; bounded queues do not by themselves prove a
long-session memory plateau. These are paused component measurements, not full
upstream-app or phone playback results.

The 64-sample checkpoint component measurement adds a median 0.102 ms final
worker drain. Native state/battery capture is 4.982 ms versus 4.670 ms before
the worker, so this measurement does not establish a shorter checkpoint pause.
JSON/hashing was already outside the managed pause before this work. The
measurement excludes pause scheduling, UI/audio and the authenticated
coordinator; the later paired acceptance gate must exercise that complete path.

### Complete upstream application playback comparison

The isolated full-app Release comparison uses original Delta
`c1d3d068e019e6493eed45654569db3cc5beb86a` and frozen Bound
`5ee68718b2d4907fbf203be3005877e02395a28f`, with the same source-owned
diagnostic ROM, task simulator, Metal renderer, native controller views and
measurement windows. Original Delta's 3,522 runtime source files and Bound's
3,596 runtime source files match their frozen inputs. Artifact-only compiler,
test-target and simulator signing adaptations are recorded separately.

At 1×, original Delta averaged 60.004 emulated callbacks/s, Bound classic 59.996,
and Bound arrangement 59.997. At 3×, the respective rates were 179.996, 179.994
and 180.011. Drawable acquisitions remained approximately 60/s in all modes;
all 18 samples had zero emulation or drawable gaps over 25 ms. Existing callback
work averaged 25.8 µs at 1× and 17.6–18.4 µs at 3× in Bound, compared with
1.175/0.646 µs in original Delta.

Each of the 12 Bound samples also recorded one main-loop gap of 31.691–33.346 ms
within the first 0–50 ms of display-link capture. Original Delta recorded none
over 25 ms. The cause is unresolved and these samples are retained without
filtering. The evidence establishes local diagnostic cadence, not presentation,
input-latency, real-game, multiplayer, video or physical-phone parity. Reproduction
scripts, screenshots, raw intervals, comparison and source receipts are under
`artifacts/multiplayer-isolation/phase6/upstream-delta` in the parent workspace.

A retained-data audit places these gaps at measurement-probe registration,
after the existing gameplay warmup. During each gap VBA still delivers 2–3
callbacks at 1× or six at 3×, and drawable acquisitions continue. This excludes
a whole-emulator stop across the interval, but does not exclude main-thread
input/UI stalls or prove presentation. Arrival timestamps cannot distinguish
display-link scheduling from main-thread work; run-loop timestamps and stack
sampling are still needed. All original samples remain included.

### Phase 7 work in progress

The DEBUG client, fixed backend scope, screen and native host integration are
under development. No native statepoint is certified yet; the fixture admission
registry stays empty until the required native checks pass. A successful parser
or component test is not the paired restore acceptance gate. The local backend
uses synthetic accounts and a loopback HTTPS endpoint; its CA is trusted only
in the two dedicated task simulators. Nothing is deployed or enabled on the live service.

The default-disabled local backend currently passes 135 Nakama
tests and 71 gateway tests (two existing optional database suites were
skipped). The app's real loopback HTTPS probe also passed: two native account
sign-ins, controller creation, explicit buddy join, resume, revocation and
signed-out credential invalidation. Those tests do not load native fixtures.

Client tests cover durable operation reuse, partial restore, custom archives,
Return recovery, revocation and scoped realtime. The latest focused gate passes
30 client tests, six checkpoint settlement tests and 16 disconnect-save tests.
Earlier validation also passed 17 transport tests after restoring ordinary
sharing's explicit friend-change stop.
The new native package regression checks the exact historical Soul sidecar bytes
rather than an unstable re-encoding of Set values. The paired native results
below establish field-safe capture and Return; all 15 point certifications
remain open gates.

Both Paired Start candidates passed actual VBA generation, movement, fresh-core
raw-state restore, and native RAM audits with distinct trainers and starters.
They remain outside the certified registry. Their erased battery images do not
prove native SRAM Save/Continue. Managed multiplayer keeps its existing server
checkpoint policy; authenticated checkpoint restoration and actual fresh-process
relaunch provide the applicable save/relaunch evidence. The real coordinator also created and reloaded
a synthetic ordinary server checkpoint. A Soul callback deadlock through a
Core Data-backed game URL was fixed by capturing the URL at owner configuration;
the native regression and real buddy startup/checkpoint both pass. The captured
stack and failed attempt are retained. Paired startup then exposed an upload
ordering race: history completion could start an upload after DEBUG had already
waited for uploads. DEBUG now drains those tasks in dependency order and uses
the existing confirmed-save settlement path. The settlement/disconnect
tests cover lost replies and preservation of facts received during
upload. Both actual owners settled ordinary checkpoints, joined DEBUG, restored
their distinct native Paired Start payloads and verified the same Ready generation.
Custom capture and final DEBUG saving failed in that run: prefixing ordinary save
keys exceeded Nakama's 128-character storage limit. Long DEBUG keys now use a full
SHA256 within the same session/generation scope; existing short keys are unchanged.
The engine regression includes real key-length enforcement and normal save,
download, custom reload and subsequent save operations. Later native attempts
confirmed final DEBUG saves, then exposed two further conflicts: a retained
ordinary bookmark was rejected after a legitimate newer ordinary checkpoint,
and a buddy readiness write invalidated the other owner's captured CAS guards.
Initial bookmark admission remains strict; later operations now validate the
exact retained historical bytes while checking current ordinary authority.
Scoped writes revalidate current authorization and generation before retrying
fresh CAS guards. Revocation, logout, owner readiness and generation changes
still reject stale writes. Actual paired custom capture and Return now pass on
both dedicated simulators, including held replies and confirmed final saves.
Ordinary receipt UUIDs are compared canonically without changing stored payload
bytes or relaxing hash/head checks.

Custom archive capture now builds an immutable package without advancing the
active checkpoint predecessor. Return verification retries validate the same
installed core and current ordinary head without restoring over resumed play.
The focused tests cover accepted-but-lost replies and fresh-client recovery.
Actual paired tests also pass a lost capture reply with confirmed abort, and a
lost Return verification reply with 21 frames of later ordinary play preserved.
An earlier attempt stopped at a busy initial ordinary boundary before creating
DEBUG; its failure and both confirmed final saves remain recorded separately.

The actual two-process restart test passes for both owners. It commits a custom
archive, loses its reply, advances and confirms the active native checkpoint,
then launches fresh app processes. Recovery restores the exact latest active
checkpoint, frame, trainer and Soul state once, retaining the archive without
rewinding to it. Exported reports were checked for account credentials,
capabilities and native payload leakage. These field-safe checks do not certify
the 15 progression fixtures or admitted-activity recovery.

Both built-in and custom reload now pass actual paired native checks. A fresh
generation restores the expected owner-specific baseline; custom reload keeps
the exact archived bytes and history cut. With the buddy's verification withheld
before sending, the controller remains Waiting, local frames advance, and the
server denies cooperative admission. Old generation clients are rejected.
Buddy leave and controller revocation also pass: both devices verify the new
membership epoch, reject obsolete authority, preserve paused native execution
and ordinary saves, then explicitly Return through existing validation.

A second synthetic ordinary run was created through normal native setup and
checkpoint confirmation. Selecting it during a delayed DEBUG download rejects
the old installation and verification, keeps the exact selected identity/RAM,
and remains unchanged after reconciliation. An earlier test expected a visible
stale error even when authority invalidation had cancelled the operation; that
failed attempt is retained. The corrected native test proves the state and
authority properties directly. Partial native restore across process restart
and delayed genuine native peer-loss capture are separate acceptance cases.

The partial-restore preparation now passes: only the controller installs and
verifies the durable generation; the buddy loses the committed download reply,
retains ordinary native execution, and receives no cooperative admission.
Both outgoing checkpoints are confirmed before process exit. The subsequent
fresh-process test exposed a restore-ordering error: replaying a newer shared
event made the applied cursor differ from the original fixture descriptor.
Exact native battery, trainer, ledger and cursor validation now happens before
replay; the same paused core then applies current authoritative history before
verification can finish. The corrected paired run passes. The controller
recovers its latest confirmed frame/head once, and the buddy installs its own
baseline once and applies a real newer peer world event. Both reach Ready,
ordinary fences remain unchanged, and both final DEBUG saves are confirmed.
Earlier failed attempts remain recorded. This proves newer world-history replay;
the delayed genuine native Soul Link loss/capture case still awaits a legitimate
multi-party fixture.

### Source-owned SDK sample

SDK Dots is a 2,602-byte homebrew cartridge with declared presence, one reliable
event, and lifecycle capabilities. Two clean builds match SHA-256
`958456f9a7e088eb2543e8cfcc0fb1825175113747adb1e93513b269642da0ec`.
It uses the generated SDK mailbox and envelope definitions without Radical Red
addresses or Pokémon semantics. Native mGBA checks cover fourteen cases.

The first hosted Bound gate passes seven sample tests and the subsequent Radical
Red Core Data ownership regression. Its actual VBA run covers local input before
host binding, receipt versus durable confirmation, native peer application,
duplicate rejection, presence expiry with continued local input, pause/resume,
battery export and a fresh core with an unconfirmed event retained. Persistence
is an explicitly injected atomic local archive; this does not establish an
authenticated backend integration, two native peers, or WAN behavior. A later
code review found stale-instance metadata-send and late native-claim gaps.
Outgoing packets now require current persisted ownership, and native mailbox
claims require the exact loaded core's audio/video renderer identities as well
as its lifecycle generation. The follow-up gate passes all 118 selected
save/client/persistence/sample tests, including actual rejection of a late
claim from an obsolete paused core after a new core loads the same URL.

The following broader gate passes 581 of 583 selected tests, with the existing
exclusive playback-timing and Mac-launch-mode cases skipped. It includes the
changed companion/tab preferences, controller routing, account persistence,
ordinary playback, native observation recovery and save paths. This remains
local simulator evidence, not the final prototype acceptance gate.

### Native fixture blocker and candidate update

Both owner-specific Route 1 candidates pass native VBA generation and audit.
The controller's Route 2 preparation uses native Rare Candy and move learning,
then follows the parcel route. Strict checks now account for verified native
walking friendship changes while preserving every other party byte.

Actual Bag exit corrupts native music-player data, causing the later Viridian
Mart door transition to stall. The integration's callback wrapper retains a
288-byte stack frame across the unchanged native dispatcher, compared with
four bytes in the original. The UI phase's inlined setup scratch is a concrete
stack-headroom risk. A minimal `uiTick` no-inline candidate reduces the retained
wrapper frame to 16 bytes. Compiled UI checks and dynamic callback-order/stack
checks pass; a second empty-cache build reproduces the ROM, header, contract
and complete manifest byte for byte. Fresh mGBA Bag/door execution passes.
Fresh VBA Bag leveling and the complete door regression now pass for both
owners, including native move learning, the exact Mart interior and parcel
dialogue, the intact six-node music chain and undefeated target trainers.
Strict movement/door-stage checks first exposed fixture-driver assumptions;
those failed attempts remain preserved. No new runtime RAM repair or weakened
destination check is used.

The next current-ROM route attempts acquire the parcel naturally for both
owners and exit the Mart, but both stop at the same Route 1 navigation mismatch:
the settled tile is `(18,35)`, while the recipe requires `(12,39)`. Independent
native audits preserve the correct parcel, party, items, level cap, undefeated
targets and intact music chain. These are failed route attempts, not completed
Route 2 or Brock fixtures; the input path is being corrected.

The previous `7e170ed0...` ROM, profiles, states and acceptance artifacts remain
preserved. Bound now imports candidate
`02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79`,
game ID `4b792d8f8b86e1a65b27965bb523fe0a48a20190`. The original supported
`8bf5b967...` profile is unchanged. The new pair passes 26 native profile checks
and 122 hosted tests, including fresh native restoration of each supported
profile and rejection of the other profile's raw state without mutation.
Both fresh Pallet/Route 1 owner candidates pass native generation and audit;
they are not final certified statepoints. Matching layout 6 never authorizes
relabeling the earlier candidate's raw states.

The broad current-ROM gate also passes: 581 of 583 selected tests, with the
same two expected opt-in skips and no failures. Its coupled QA inputs use the
fresh current-ROM state and battery; the old inputs remain preserved. This
does not certify the progression statepoints or replace their encounter tests.

The first 216,000-frame/60-pause endurance attempt used the freshly generated,
independently audited controller state `5643d563...`. It failed after 70,140
observed native frames and 18 completed cycles when the frame reader reported
a missing/discontinuous counter at the next pause; that pause's hold check was
also false. Queue high-water remained one, with no rejected observations or
blocked callbacks and unchanged model/backing/party/boxes. The failure is
preserved; its exact cause is unproven because that attempt did not retain the
raw failed read. Source inspection identified a test defect: VBA can finish a
video frame while the ROM's UI publication sequence is odd. Such a read must
defer with zero frame credit, rather than be treated as a committed counter.
The corrected test retains the 120-frame delta and 120-callback commit bounds,
compares both raw UI snapshots and full RAM hashes across each pause, and
captures native state and read diagnostics on failure. Three focused accounting
tests pass. The first attempt is not a long-session pass. This test covers
stationary local observation, with no network or paired-play claim.

The corrected full run passes 219,418 observed native frames and all 60 pause /
drain cycles. It defers 153 valid odd publications without counting them as
frames; there are no invalid reads, rejected observations or blocked callbacks.
All 14,727 admitted observations reduce, and the queue ends empty with a
high-water mark of one. An independent audit verifies every cycle's paused RAM,
UI snapshot, model, backing storage, party and boxes. Over 1,224.90 wall seconds,
RSS grows from 539.48 to 542.72 MiB, peaking at 564.80 MiB. This is a bounded
measurement, not proof of no leak or a comparative speed benchmark. The first
failed attempt remains a failure.

At the earlier current-ROM gate, the candidate passed an unsigned Release iPhone build and three
authenticated ordinary-run baselines (both owners plus a second controller
run). Paired custom capture with a held reply passes on both owners. The next
paired Return attempt reaches verified Return on both owners but fails the
buddy's final-save teardown check. A read-only database audit finds two
overlapping buddy uploads with the same predecessor and different native
payloads; only one became the server head. That attempt (`returnHold-01`)
exposed unfenced background checkpoint producers and remains a failure; a later
stored head does not retroactively establish its final receipt.

The final-save boundary now closes admission to new producers, drains accepted
history and existing uploads, and captures one immutable package using the
settled ancestry. Failed preparation retains its paused source for Retry.
The fresh `returnHold-27-01` run passes on both owners, including confirmed
final native saves before sign-out. Nine hosted lifecycle tests pass in cache27.
Further review found ordinary selection changed the source token before its
drain completed; cache29 moves destination publication after confirmation and
adds three sequencing regressions. Same-owner reauthentication and the combined hosted/Release validation later passed in cache32, as recorded below; paired acceptance is tracked per exact source.

The `returnVerifyLostReply-27-01` attempt fails before its intended fault:
ordinary proof and both final saves pass, but no initial paired prepare is sent.
It is not evidence about lost-reply recovery. Cache29 restores normal execution
after the harness's temporary inspection pause through the UI resume gate,
waits for the ordinary field boundary, and records the initial load outcome.
The original failure remains preserved; the later cache32 Return cases below provide fresh passes.

Cache29 subsequently passes the broad suite: 608 passes, two expected skips,
no failures (610 selected, 209.56 seconds). Cache30 passes all 85 focused
save/recovery tests, including four same-owner reauthentication regressions.
These results do not override a separate native recovery failure:
`returnVerifyLostReply-29-01` reaches paired Ready, and the buddy passes, but
the controller fails Return verification and final-save confirmation.

The preserved read-only audit identifies a fast backend CAS rejection, followed
by retries of an older Return receipt while ordinary checkpoints advance.
It also records 68 complete controller uploads, including 62 after Return,
in a strict predecessor chain with unchanged battery/journal data. Source
inspection finds that checkpoint capture pauses the core, whose save callback
queues another checkpoint. This is a feedback loop, distinct from the earlier
two-competing-upload failure. The failed CAS key was not logged, so a particular
shared row cannot be named as the collision. Native state, battery, memory,
intent and exact upload payloads are retained under that attempt's `diagnosis/`.
Cache32 suppresses only the synchronous save callback caused by an owned
checkpoint pause; manual and native-thread requests remain admitted, and stale
callbacks cannot cross a core binding. Return acknowledgement obtains a fresh
live receipt on each retry, waits for an owned upload, rejects foreign or altered
receipts, and keeps bounded reconciliation running after DEBUG revocation.
Ordinary gameplay and saves continue; no older state is reloaded to retry proof.

The combined cache32 broad run passes 619 tests with two expected skips and no
failures (621 selected, 209.31 seconds), including 19 lifecycle tests and 43
DEBUG session tests. An actual Delta-core regression checks capture, manual and
native-thread save callbacks. The unsigned Release iPhone build and generated
SDK import checks also pass. Exact app/test source is preserved with the frozen
product receipt. The fresh `returnVerifyLostReply-32-01` and `returnHold-32-01`
cases pass both owners, including final-save confirmation. Other cases were still
unvalidated at that historical snapshot; the current source-matched matrix above
supersedes that pending status. `customHold-33-01` failed before the custom operation: the buddy downloaded a valid payload but never reached scoped installation/verification, and its final save was unconfirmed. The first local restore exception was missing; diagnostic-only cache34 records it before reconciliation clears the error. Exact retained files and checksums are preserved under that attempt. Earlier failed attempts remain failed.

### Retained DEBUG sessions across a profile update

Admitted operations now keep their immutable compatibility for descriptor
validation, Soul sidecar lookup and committed game identity. Return to Previous
Run uses the installed generation's exact manifest profile even after a newer
profile becomes current. Fresh loads, reloads and custom captures still require
the current profile. Return preserves the original bookmarks and validates the
latest ordinary heads through the matching old ROM/core; it cannot reinterpret
an old raw state under the new cartridge.

The backend passes 141 tests; gateway tests pass 71 with two existing optional
skips. The tested module is active only in the isolated local Nakama instance.
A read-only comparison across the restart found all 16,897 retained DEBUG rows
and three ordinary bookmark-run rows unchanged in key, version and value hash.
The prior runtime and logs remain preserved. No historical sessions were
revoked, marked returned or rewritten merely to change the current profile.

New hosted regressions exposed a separate app-side validator defect: it rejected
retained immutable operations and descriptors from the exact supported original
profile before Return can proceed. The minimal fix accepts known exact profiles
for immutable metadata while keeping new preparations current-only. The red
baseline is retained. All three focused historical-profile regressions pass in
cache27. That complete 73-test run still failed one unrelated request-count
assertion; cache28 corrects it to require the exact new scoped terminal read and
unchanged operation, manifest, host mutations and admission state.

The subsequent terminal-proof module passes all 147 backend tests, with 71
gateway passes and two expected optional skips. Its one-time isolated runtime
update preserves all 17,879 existing DEBUG rows and four ordinary rows by key,
version and value hash. Six hosted terminal client tests pass. This protocol
requires authenticated owner/device/epoch/generation proof of an actual terminal
event; it does not manufacture a native loss or convert raw states. Natural-loss
native acceptance remains explicitly deferred with the progression work.

### Stopped-frame restore boundary follow-up

Cache35 rechecks the native boundary after pausing, before acquiring a restore hold or starting outgoing save settlement. On an explicit temporary rejection, only a previously running unchanged source may resume through the existing authority/observation/UI checks. Existing pause owners and capture/transport failures stay held. This is a source-level recovery improvement, not a confirmed diagnosis of the uninstrumented buddy33 failure. Broad35 passes 619/621 (two expected skips, no failures, 223.032 seconds); unsigned Release04 passes the same app source. A deterministic native read-fault test in `customHold-37-01` verifies running-source resumption and retention of an existing pause, without supplying native authority or writing RAM. The current aggregate is `sdk-current-native-evidence.json`; `gate-run35.json` remains a historical batch result.
