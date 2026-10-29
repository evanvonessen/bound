# Coordinator save and recovery validation

Use `PrototypeTools/verify-coordinator-recovery.py` through the approved
`PrototypeTools/qa-python` launcher. All paths and simulator identities are
explicit. The runner creates a new evidence directory and preserves earlier
attempts, ordinary runs, account credentials and emulator fixtures.

The authenticated journeys use the existing task-local Nakama/PostgreSQL/Caddy
gateway at `https://127.0.0.1:58552`, normal synthetic account sign-in, and the
actual Bound `GameViewController`, VBA-M core and coordinator. They cold-boot the
selected exact cartridge; no old-ROM state is converted or given a new identity.
The same two owners share a newly created ordinary run and retain separate
checkpoint heads. No DEBUG statepoint certificate or gameplay authority is
manufactured.

Prerequisites:

- The workspace bound/ and multi_red/ checkouts, both on main.
- The existing local authenticated backend, started by its audited
  `artifacts/multiplayer-isolation/local-backend/phase7-runtime/control.mjs`.
  Its private `run/synthetic-login.json` supplies only the two task accounts.
- Two already booted dedicated simulators named `Bound Coordinator Stability A <suffix>` and
  `Bound Coordinator Stability B <suffix>`, with the task-local Caddy root
  certificate installed in those simulators only. Never install host-wide trust.
- The exact selected ROM and a fresh simulator build from the candidate source.
  The runner records both ROM hashes, source commits, hashes of the working
  app/core/backend/test sources, generated contracts and dependency pins, the
  isolated backend runtime module, application executable and xctestrun, plus
  commands, results and elapsed times.

From the workspace bound/ main checkout, a complete local run is:

```sh
BOUND_GAME_SOURCE=/Users/evandev/dev/bound_multiplayer/multi_red \
PrototypeTools/qa-python PrototypeTools/verify-coordinator-recovery.py \
  --phase all \
  --game-source /Users/evandev/dev/bound_multiplayer/multi_red \
  --rom /absolute/path/to/exact-task-ROM.gba \
  --login-file /Users/evandev/dev/bound_multiplayer/artifacts/multiplayer-isolation/local-backend/phase7-runtime/run/synthetic-login.json \
  --sim-controller TASK_CONTROLLER_UDID --sim-buddy TASK_BUDDY_UDID \
  --derived-data /Users/evandev/dev/bound_multiplayer/artifacts/multiplayer-isolation/THIS_RUN/SimulatorDerivedData \
  --release-derived-data /Users/evandev/dev/bound_multiplayer/artifacts/multiplayer-isolation/THIS_RUN/ReleaseDerivedData \
  --source-packages /absolute/path/to/task/SourcePackages \
  --package-cache /absolute/path/to/task/PackageCache \
  --output /Users/evandev/dev/bound_multiplayer/artifacts/multiplayer-isolation/THIS_RUN/evidence \
  --repetitions 3 --os-background
```

Replace placeholders with audited task paths; mutable build/cache paths must be
under `artifacts/multiplayer-isolation`. The tool never starts a backend, changes
launch services, publishes a ROM, pushes Git, or invokes delivery. Build phases
use the existing `Bound.xcodeproj`, pinned dependencies and Xcode installation.

For an already built candidate, use the same entry point with `--phase journeys`,
`--phase battle`, or `--phase regressions`, supplying `--app` and `--xctestrun`
instead of build/cache paths. Those execution-only phases require independently
verified provenance for the supplied build; use `--phase all` for acceptance.
Each invocation requires a fresh `--output` path.
`--phase release` runs the required unsigned Release iPhone build. The `all`
phase orders simulator build, regressions, native battles, Release build, then
repeated ordinary interruption/recovery journeys on that final candidate. The
regression gate rejects zero tests, omitted suites, skips and expected failures.
Each authenticated stage is preceded by a documented 65-second quiet interval
to respect the isolated gateway's normal general request quota. The runner
prints and records this pacing; it does not retry failed scenarios or change
backend limits. After intentional termination, recovery uses the account's
normal persisted-session restore and refresh, requires the exact owner and valid
credentials, and reauthorizes server operations normally. Missing saved authority
fails recovery rather than falling back to extra password logins. Three repeated
cycles therefore use four password logins per owner (baseline plus preparation),
within the existing ten-per-account/fifteen-minute password quota.

The ordinary journey first confirms both owners' checkpoints, then repeats both
roles concurrently in fresh test-host processes. Each process verifies the exact
previous confirmed owner receipt before selecting the run. Each repetition first
holds a real successful automatic `saveSeal` response, independently downloads
and verifies that accepted owner package, and persists a credential-free marker
with the attempt, PID and exact receipt. Only that marker authorizes terminating
Bound on the specified task simulator, before response delivery or final-save
teardown. The runner uses Xcode's default single execution and lets its own driver
finish handling the expected app exit naturally, with a 180-second limit. A
same-attempt relaunch is blocked by the existing prepared marker before the test
can authenticate, change preferences or select native state. If driver cleanup
times out, preparation fails and recovery does not begin.
It also requires the prepared PID to be alive immediately before termination and
gone afterward; an earlier arbitrary process failure is rejected.
This stage is reported as `prepared-and-terminated`, never a passed XCTest.

A separate fresh `ordinaryRecovery` process must then confirm the exact accepted
server head and package before selection and prove its PID changed. A read-only
observer on the existing restore callback then requires one actual paused native
restore whose battery, EWRAM and IWRAM exactly match that package, before a new
checkpoint can be captured. It chains the original callback and restores it
afterward. The process must finish with a confirmed owner save. This completed
recovery is the pass signal for the pair.
The preparation marker also carries the prior Experimental Multiplayer Bool or
unset value so recovery restores the test's original preference after the killed
process was unable to run cleanup. Arbitrary crashes, missing markers, delivered
responses or a premature final-save proof fail the termination setup.

Delivery faults
forward real authenticated HTTPS requests unchanged and only hold or discard a
successful `saveSeal` response. A held older upload is released after a newer
native save request and the production temporary-background boundary; it must
not claim that the newer uncaptured state is saved. Foreground recovery must
restore native frame delivery and confirm the newer owner checkpoint. Lost-reply
recovery independently confirms the accepted head, then settles and downloads
the recovered owner checkpoint; settlement may create a newer checkpoint. Every
completed recovery requires a confirmed final save before sign-out.

`--os-background` additionally asks the role runner to launch Settings and then
return to Bound on that same dedicated simulator. Passing evidence must include
the application's observed background and foreground transitions; successful
`simctl launch` commands alone are insufficient.

The native battle phase reuses `native-link-battle.py`: one full battle, and one
opposite-initiator native Run return after a three-second packet blackhole, with
asymmetric playback rates. These use production native command transport over
loopback and verify per-owner restoration. They are separate from the
authenticated ordinary-save scenario and do not establish a combined battle
return through the authenticated backend.

Inspect `summary.json` and each retained role's `result.json`, native proof files
and Xcode logs. The deliberate termination stage retains its nonzero Xcode exit
separately from the validated `simctl terminate` result; only the later normal
XCTest recovery can pass. Any other nonzero exit or missing proof is a failed
attempt, even if later runs pass. The report must retain the exact source/ROM pair and distinguish
compile, component, actual-app, native transport and backend evidence.

Physical devices, WAN behavior, archived personal saves, prolonged outages, and
OS termination with unconfirmed progress are not established by this entry
point. The existing limit remains: offline termination can lose changes after
the last confirmed server checkpoint.

The process-death case covers an accepted but unacknowledged checkpoint, not
unconfirmed offline progress. Capture ordering and cancellation timing also rely
on the focused lifecycle suites. The actual-app timing cases must not be
described as exhaustive capture, process-kill or battle-return coverage.

An earlier unpaced `candidate-01` attempt completed its first two repeated pairs.
In cycle three, both owners completed the held/lost-response and OS-background
checks, then failed final-save teardown. The controller recorded an authenticated
request rejected with HTTP 429; the buddy recorded a storage failure. Neither
produced `final-native-save.json`. Their logs and available native diagnostic
copies are preserved. These are failed attempts, not passes; quota pressure is
the demonstrated controller condition and does not by itself establish the
buddy's cause. The paced final gate uses fresh task simulators and a new isolated
run; it does not overwrite or silently retry that evidence.

The initial termination harness in `candidate-02` abruptly stopped its Xcode
drivers after terminating both prepared app processes. The next buddy test host
then exited with signal TERM before establishing its XCTest connection; the
controller did not reach test startup promptly. This failed attempt is preserved
as harness/bootstrap evidence, not a product restore failure or successful
recovery. Subsequent attempts require natural driver completion and the early
same-attempt guard described above.

## Stabilization result — October 29, 2026

The reproducible product failure was false save-success reporting. With an
automatic checkpoint accepted remotely but its reply held, a newer native save
request followed by temporary backgrounding remained uncaptured. Releasing the
older reply incorrectly reported `Saved to server.`. The corrected completion
reports success only when its receipt still describes the current head, no newer
capture is pending, and no final-save boundary is outstanding. Otherwise it
continues to report `Saving to server...`.

`before-02-controller/evidence/ordinary-held-reply.json` records the original
false success. Both owners passed the corrected timing case in `status-fixed-01`,
including actual OS background/foreground transitions. This is the demonstrated
bug fixed in this task; no new natural battle hang or confirmed-progress loss
has been attributed to a product defect.

The focused extraction is `BoundServerCheckpointUpload`. It owns the automatic
upload task, generation fence, retry deadline and legacy service, replacing four
coordinator fields with one component. Its interface admits an immutable request,
awaits the current upload, cancels, or detaches. Authorization, chunk/seal upload,
exact receipt and acquisition validation, legacy lease publication and failure
classification moved with that ownership. The coordinator retains native
capture, journal ordering, head selection and presentation. Detach still permits
the exact captured continuation to settle while preventing an old completion
from changing a newer execution. No protocol bytes, generated contract, core
identity, save format, offline-loss policy or preference defaults changed.

After the user's explicit fast-forward approval, both designated isolation
branches advanced to verified main. The task changes were retained in stash
`56cb6adffdb0d4d676124509f455594871911932` and reapplied; the changelog conflict
was resolved by retaining all entries. The ordinary main checkout and its dirty
files were not modified during that step. The user subsequently updated the
workspace instructions to require development directly on main. The task files
were copied into `bound/` on main; the existing isolation worktrees remain intact.
The dirty game `4person` checkout was preserved on its unchanged branch in
`worktrees/multi_red-4person-preserved-20261029` before switching `multi_red/`
to main. All 33 dirty/untracked files matched their preservation hashes. Existing
ignored game outputs and the persistent QA environment stayed in their original
location. The three unrelated Bound Xcode edits have private backups and stash
`400a7ebaed06be690fa6933a8cf4ed4af1ba5bf4`; they are excluded from the task commit
and restored after validation. The final gate launched from these main bases
plus this task's app changes:

| Item | Exact identity |
| --- | --- |
| Bound base | `28b2c455b9439f2296d404346fe76a8df490be30`, app 1.0 / project build number 173 |
| Game source | `f50b08a6da562f329ed5d25f73634e925716ea3c`, RRv4.1M build 506 receipt for source `b50eb84c9f5c72e9f327d54f2a308c2e71e9e663` |
| ROM SHA-256 | `70b9d94c1d83f34f0d022a95f14ebc4865556e4f2d067bf2adc61736ef5bbd6b` |
| ROM game ID / SHA-1 | `027ec305690efe2f1a4a093e36158f5e995fd7e5` |
| DeltaCore tree | `ceddac272e97699654381aa5d8f063f7a7fe8cf3` |
| GBADeltaCore tree | `c4a9cf4a90be88e62af5951cba5a5962cc49a70a` |
| Contracts | ABI 1.0, wire 2, checkpoint 1, battery 1, multiplayer layout 16, VBA-M state 10 |
| Local backend module SHA-256 | `2075397bc8413ecca37bb7b910efbc561bb7549d861f61439de00bdcc744ca94` |

During validation and publication preparation, instruction-only commits advanced
Bound main through `c020111bab76a32484b27ba383e665459839754b` to
`19c8c5d5a96e51f7123cc4a2b69426adbd2fbc1b`, and game main to
`62a921984ca1db2bbf7a7802947a321c5b6f0b07`. Each changes only `AGENTS.md`;
product, test, game and contract sources are identical to the launch bases.
The completed app commit descends from `19c8c5d5`. The unchanged game source
at `62a92198` produces the same exact build-506 ROM above.

Evidence is retained under
`artifacts/multiplayer-isolation/coordinator-stability-20261029`. Both selected
ROMs were rebuilt from empty task caches. Initial diagnosis used Bound
`35134fd8` / game `9baa6497`, ROM
`a215add233d8d2f119e29b435605d3af99d063180d6b77310f178dfcdebf0ba2`;
its exported ABI header exactly matched the app's frozen profile. The final ROM
matches the current build-506 receipt. Its exported header differs from that
older frozen header only in ROM hash and two native code-range ends. The
existing runtime-interface verifier admits the final ROM's own exact profile;
no frozen profile was rewritten and no old-ROM save was relabeled. The final
export's contract/header hashes match the prior main validation documented in
`Docs/validation/native-battle-loss-ui.md`.
Baseline checks passed: 156 Nakama tests, 131 model tests, 11 game tests and 13
profile-freeze checks. The generated SDK check passed. An initial model check
failed on sandbox cache access; the retry used explicit task caches and passed.
An early simulator test compile and the first delivery-fault hook failed during
harness development; their logs remain alongside the successful corrected runs.

The final main-checkout gate passed its simulator build, 118 integration
regressions (zero skips or failures), both representative paired native battle
scenarios, and unsigned Release iPhone build. The ten new component tests exercise held and lost
replies, immutable idempotent retries/acquisitions, wrong receipts, cancellation,
retained-owner release, session replacement, detached continuation ownership,
stale conflict discovery, journal admission and legacy lease publication order.
`main-candidate-01/summary.json` records full acceptance: both owners' baseline
journeys and three paired accepted-checkpoint termination/recovery cycles passed.
All six fresh-process recoveries proved the exact accepted battery and native
RAM restore, held/lost reply handling, actual OS background/foreground recovery,
and a confirmed final owner save. Intentional terminations remain labeled
`prepared-and-terminated`; the later recoveries are the successful tests.
The earlier `candidate-04` also passed this complete gate on the preserved
isolation checkout. The primary-main run revalidated the copied candidate.

`source-hashes.json` records 4,806 exact candidate inputs, unchanged at the end
of the main gate; its SHA-256 is
`39d16d27f2fbf2f5560976a189cef4c31cc201783ac06e0a3f45902d9f2bb160`.
The supplemental `binary-hashes.json` records the Debug library, test bundle
and Release executable. `committed-candidate.json` binds the resulting commit
to those tested source inputs before the unrelated Xcode edits are restored.

`candidate-03` passed the current-main simulator build, 118 regressions, both
paired native battles and Release build. Its first ordinary launcher failed
before app startup because this Xcode rejects `-test-iterations 1`. The explicit
iteration options were removed; the runner now uses the default single execution.
The failed invocation remains preserved and is not ordinary-journey evidence.
