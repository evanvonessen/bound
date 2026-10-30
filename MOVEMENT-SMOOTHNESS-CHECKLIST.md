# Multiplayer movement smoothness

Updated October 30, 2026. Work on `main`; first-cycle evidence lives in
`../artifacts/multiplayer-isolation/movement-smoothness-20261029/`.

**Reopened:** the user confirms build 225 / ROM 508 still stutters, mainly for
their own character. The first cycle's narrower acceptance was insufficient.
Continue from its evidence under
`../artifacts/multiplayer-isolation/movement-smoothness-cycle2-20261029/`.

**Current cycle status: local acceptance passed; delivery pending.**
The validated pair fixes native field-update deadline overruns, unnecessary
Soul Link pauses on routine friendship changes, and app reader interruptions
during advancing native publications, camera steps and pending sprite images.
Rejected candidates and all failed runs remain preserved below.

Final host acceptance covers16 cohorts/356,400 frames with zero post-startup
moving holds or added total/prefix loss, uninterrupted reader/authority/render/
Soul checks, clean wall timing and verified peer finish ordering. Four passing
independent paired cohorts naturally exercise image recovery, including two
long vertical runs, with zero refusals. Final native-bitmap acceptance covers
16 cases/57,600 frames:100% trainer/background confidence, no mismatches and
exactly zero added holds or progress loss in all eight matched comparisons.
Native100,800 fresh plus129,600 controlled frames,99 camera/reader/image and63
authority regressions,17 functional tests, both native battle variants and
ordinary arm64 iPhone Release checks also pass. Physical phones, WAN and
physical display scanout remain unverified. Commit/push and delivery are next.

## Checked and established

- [x] Read workspace and both repository instructions; preserve unrelated changes,
  production runs, shared simulators, credentials and disabled publishing agents.
- [x] Record starting pair: Bound `052b584e0d3f9afc503661002f58922944375cdc`,
  multi_red `62a921984ca1db2bbf7a7802947a321c5b6f0b07` (published game build 506).
- [x] Preserve the existing project, scheme and Info.plist diff in the evidence
  directory; leave the untracked Xcode Cloud configuration intact.
- [x] Review previous findings instead of restarting the investigation. Native
  collision validation caused the original 72 → 62–64 transitions/960 frames
  regression. Game `9db1869a` reduced that overhead, and `b50eb84c` bounded idle
  native notification work. Eight short 1×/3× active/inactive collision replays
  retained 72 transitions after each fix. This did not validate sustained remote
  movement or physical-device presentation.
- [x] Review checkpoint follow-up `052b584e`: upload lifecycle and interruption
  recovery were validated independently. Do not undo these fixes.

## Investigation and changes

- [x] Reproduce the remaining issue on the current exact app/game pair; measure
  movement cadence and frame timing rather than just final distance.
- [x] Audit remote interpolation, frame-fenced collision publication and guest
  work; document the confirmed cause and rejected hypotheses.
- [x] Confirm the production app disables the old per-step negotiation flag.
  Nearby walking is not waiting for a network grant; do not reintroduce that path.
- [x] Identify a missing presentation test: a 60 Hz main-thread timer samples one
  remote pose that the video compositor repeats across independently timed core
  frames. A deterministic jittered-timer replay reproduces duplicate positions
  and larger jumps at both 60 and 180 core frames/second.
- [x] Profile the current build-506 native collision path on three preserved
  native field seeds. BeforeCallbacks takes 1,556 instructions inactive versus
  4,838 with two actors; collision takes 1,461 versus 3,940. An empty actor list
  still incurs most validation cost. Reusing the sequence cannot avoid the scan
  and would expire the existing lease. No checks have been removed.
- [x] Add a maintained native cadence replay covering exact-ROM cold boot,
  same-ROM anchor restoration, per-frame pixel/tile/guest-frame observations,
  repeated 1×/3× runs and far/near/moving synthetic peers.
- [x] Reproduce a second app timing defect: resetting the 50 ms send interval
  from each late callback sends only 301 updates over 20 seconds in the jitter
  fixture, versus the intended 400. Anchor deadlines and skip missed slots
  without sending bursts.
- [x] Implement candidate frame-time interpolation from an immutable bounded
  presentation snapshot. Preserve authenticated occupancy separately from
  presentation, map seams, follower identity, packet-gap freezing and expiry.
- [x] Implement candidate native aligned word/halfword access, retaining volatile
  semantics and byte fallback for packed/unaligned fields. Keep every validation
  scan and existing lease/seqlock check. Candidate SHA-256:
  `a108f0ca5547a168e1b04c2ad0d7120795e69f351e1bfe41b9c41ac581dee084`.
- [x] Candidate native checks: 504 corruption/authority/alignment/budget checks,
  41 actual field/door checks, 20 ledge/bicycle/surfing checks, 39 focused game
  composition/distribution tests, and two fresh native setup boots pass.
  Callback instructions fall 4,838→3,096; far collision 3,940→2,600; nearby
  open movement remains immediate. Instruction counts alone are not smoothness
  acceptance; repeated simulator comparison remains pending.
- [x] Current-ROM baseline: 16 repeated 960-frame cases at 1×/3× retain 72
  transitions but active collision shifts the step distribution toward 9–11
  frames instead of the native 8–9. No network grant waits occurred.
- [x] Reject candidate 01 as final acceptance: it improves cadence but leaves a
  difference. Preserve its evidence under `game-candidate-01`.
- [x] Correct the measurement boundary. Completed-frame callbacks run after the
  core has continued past video output and can expose mixed camera/sprite state.
  Primary movement measurements now use the real `processFrame` video callback;
  retain completed-frame traces only as secondary diagnostics.
- [x] Candidate 02 keeps full scans while using a sequential 64-byte accumulator
  and aligned native map-header comparison. SHA-256:
  `9a7dd882abef30d7f70145b5a85500ddcf576d41abdc8d02395194f144627440`.
  All 860 native checks, 41 field, 20 special movement, two cold starts and 39
  focused game tests pass. Callback/far/near instruction counts are
  2,522 / 2,213 / 2,149. Save formats and contract are unchanged; exact ROM
  identity remains distinct and no previous state is rebound to it.
- [x] A strict retained-evidence checker rejects all six active-peer cases from
  the original ROM and accepts all 24 candidate-02 cases: 43,200 native video
  frames, 3,240 transitions, exactly three transitions per 40-frame input block,
  no uninterrupted running interval above nine frames, no missing video,
  no multi-frame pixel freeze and no callback gap over 50 ms. Maximum measured
  gap was 26.55 ms. Synthetic stall/missing-frame/false-boundary cases exercise
  the checker itself. Game fix committed locally as `169bd658`.
- [x] Actual remote compositor: three repetitions at 1×/3× reproduce held-pose
  stutter in the control and zero repeated moving poses with frame interpolation.
  All frames resolve and draw visible sprites; screenshots were inspected.
- [x] Direct native pixel diagnostics reveal a separate presentation-reader bug:
  bitmap trainer foot and built OAM stay at x=120 in all 960 frames, while live
  sprite RAM reports x=118/122 in 17 frames. Live camera deltas disagree with
  native bitmap movement on 173/959 transitions. Applied BG scroll deltas agree
  with all 959 confident bitmap comparisons. A naive one-frame correction still
  fails 30 comparisons and is rejected.
- [x] Fix presentation sampling from coherent built OAM and a scoped camera
  anchor advanced by applied scroll; validate initialization, scroll wrapping,
  map seams, fades, state loads and core replacement. Keep raw collision
  authority separate. Re-run actual-pixel acceptance after this final fix.
- [x] Implement the scoped camera/OAM correction. Replaying the exact production
  cache against all 960 independent native bitmap observations yields zero
  camera disagreements; 368 coherent origins match the measured camera. Fresh
  simulator, map-crossing and lifecycle acceptance remains pending.
- [x] Independent review confirms map transforms, scroll wrapping, cache scope
  and native authority guards. Clear the camera anchor when detaching the
  renderer. Correct a send-deadline tolerance edge case that could admit two
  same-time sends after a delayed callback; exact boundary regression passes.
  Final source replay retains 400/400 sends and zero duplicate moving positions
  in all six 60/180 Hz cases.
- [x] Reject the first camera candidate after actual native pixel validation:
  all 960 trainer and 959 background observations are confident, and resolved
  frames match exactly, but 156 scenes are missing. At a tile boundary the
  game's logical current/previous interval collapses before the rendered frame
  catches up; the old interval check rejects the real image and resets the
  camera. Preserve this failure under `pixel-final-01`; keep assertions strict.
- [x] Carry the preceding observed native movement segment through that
  presentation boundary, with existing map/load/core scope and authority guards.
  Exact repeated frames retain only their previously admitted position; changed
  frames still need native segment evidence. Strict native pixel validation now
  passes eight repeated 1×/3× native/active cases (7,680 frames), with no missing
  scenes, backward movement or pixel/camera mismatches.
- [x] Do not accept game candidate 02 as the final movement fix: a second native
  starting phase reveals one 10-frame active-peer interval per 960 frames at
  both 1×/3×, across repetitions. Matched native-only controls remain at 8–9.
  Bitmap comparison confirms an extra displayed hold. Build 507 was published
  after its earlier 24-case gate passed; a further game correction is required.
- [x] Reduce the remaining guest instruction cost, preserve all authority and
  byte-validation checks, and repeat matched controls across starting phases.
- [x] Candidate 03 preserves both complete input scans and passes 1,143 native
  checks, two exact-ROM cold roles and 39 focused tests. Its ROM SHA-256 is
  `8b8062a5e3febe437e71956f25ff9ceb4f3c50fc3744656f0c5bf3e490822561`.
  Callback instructions fall 2,522→1,843; production collision 2,149→1,498.
- [x] Reject candidate 03 after eight matched pixel runs with deterministic
  0/1-frame starting phases: pixels remain accurately decoded, but active peers
  add 11–15 holds per 960 frames, including a two-frame hold in phase 0.
  Phase-0 native controls also show a rare 10-frame tile interval, proving that
  matched native controls and actual pixels are necessary in addition to a
  fixed interval threshold. Keep the failed evidence; do not claim parity.
- [x] Add explicit `--phase-frames` replay coverage and per-case phase receipts;
  exact native callbacks advance with input released before measurement.
- [x] Profile actual GBA bus cycles rather than assuming instruction-count
  parity. Reject ARM/O2/O3, copied scanner code, and large host snapshots after
  measurements show their cost outweighs the savings. Preserve both full scans.
- [x] Find the dominant omitted path: an enabled native follower adds about
  10,491 cycles to each BeforeCallbacks and AfterField hook. The native getter
  repeatedly does identical memory work while rereading the same species.
- [x] Prove narrow follower-read equivalence: direct HP matches the exact native
  halfword read; guarded species/egg query falls back for ambiguous 0/412;
  species reuse and the native ability front-end pass 560 getter cases and
  12,328 ability cases, including native override inputs/results and party bytes.
  Preserve the native override/selector functions and refresh frequency.
- [x] Validate the combined port/follower optimization in actual native pixels,
  varied starting phases, field transitions and special movement before shipping.
- [x] Candidate 04 passes the original strict cadence gate in all eight short
  0/1-phase native/active 1×/3× cases: 72 transitions per 960 frames, no held
  tile interval above nine frames, no multi-frame freeze, no missing scene or
  bitmap mismatch. Exact ROM SHA-256:
  `421cd0ed7e103c13508c95b94d9d91c80baacd11808acad3bd84a3a5b5c5b9ea`.
  Do not accept this short run alone: matched single-frame hold counts still
  differ; longer varied-phase/peer runs and field/special gates remain pending.
- [x] Candidate 04's longer 1,800-frame phase sweep reproduces 10-frame held
  movement intervals after changing the starting phase. Preserve the full run
  under `pixel-candidate04-long`; the eight passing short cases were insufficient.
  Phase 2 also reproduces a two-frame freeze in all active-peer modes at both
  speeds, while matched native controls retain only one-frame holds. This is
  the original symptom, not merely a difference in isolated hold frequency.
  Independent bitmap analysis locates all six freezes at frames 860–861;
  those comparisons are confident. All 43,200 scenes resolve with no camera,
  trainer or backward-position discrepancies. Strict cadence rejects 16 cases
  (including four native controls with intrinsic 10-frame intervals).
  Prepare exact native species/Egg/held-item read equivalence to remove the
  remaining repeated getter loops before the next acceptance attempt.
- [x] Candidate 05 uses exact native plaintext metadata reads, preserving
  secure Egg versus BadEgg behavior, ability overrides and refresh frequency.
  Canonical source/ROM matching, 1,145 native checks, 1,680 metadata cases,
  6,676 ability cases, 39 game tests and both exact-ROM cold roles pass.
  Follower-enabled BeforeCallbacks falls 14,586→11,997 GBA cycles and AfterField
  8,167→5,560. Both complete host scans remain. ROM SHA-256:
  `24e391382f8d64119f29fb87c8886955885a88d196c79a79e7e41d2fb79a0f08`.
- [x] Re-run the full failing 24-case phase matrix on candidate 05, then repeat
  acceptance from an independent cold anchor before field/special validation.
- [x] Candidate 05 completes the first 24-case/43,200-frame matrix with no
  consecutive holds, missing scenes, backward steps or pixel/camera errors;
  all trainer and background comparisons are confident. Preserve the strict
  checker's six failures: each is the same initial phase-2 interval (19→29),
  also present pixel-for-pixel and guest-counter-for-counter in native control.
  Every later held-input interval is eight or nine frames. This shared native
  startup event differs from candidate 04's active-only freeze at 860–861.
- [x] Quantify remaining cost honestly: active modes add 27–33 isolated
  one-frame holds per 1,800 frames (2.74–3.36 percentage points among eligible
  moving pairs). All cases still complete 135 tile transitions, three per
  input block. Do not claim identical native timing or zero multiplayer overhead.
- [x] Independent reviews recommend retaining the proven native routines rather
  than entering the middle of the ability override for marginal savings, unless
  the second cold run reproduces an active-only freeze or cadence tail.
- [x] Second independent cold boot: 24 more 1,800-frame cases with 7/31/63-frame
  starting offsets; require no active-only consecutive hold or unexplained tail,
  no pixel/scene defects, and no lost progress. Keep all absolute-gate results.
  All 24 strict cases pass without exceptions: every held interval is eight or
  nine frames, every hold is at most one frame, all cases complete 135 tile
  transitions, and no callback exceeds 50 ms. The final two batches total 48
  cases and 86,400 frames with no recurrence of the consecutive-frame freeze.
- [x] Recheck final-ROM runtime binding and frozen profiles: 13 profile tests
  pass; the runtime interface accepts this compatible release and rejects
  unsupported bindings, capabilities, layouts and corrupt payloads.
- [x] Final exact-ROM native acceptance: 1,166 canonical native checks, 41
  field/door checks, 20 ledge/bicycle/surf checks, fresh cold roles and real
  follower dialogue/walk/warp pass. Three retained follower states each pass
  nine current-source decoder tests, with unchanged snapshots and correct
  enabled/off/warped identity and visibility.
- [x] Repair the standalone follower QA extraction after the new presentation
  snapshot exposed its overly broad source slice. Extract only the wire types
  those tests exercise. Preserve the initial Xcode-path and extraction failure
  logs; final reruns pass with explicit Xcode and no production workaround.
- [x] Independent final app review finds no blocking clock, expiry, camera
  scope, seam, lifecycle or authority defect. The QA bridge is simulator/DEBUG
  only; release behavior excludes it.
- [x] Implement the fix for the reproduced failures while retaining collision, follower,
  save/recovery and independent progression semantics.
- [x] Add repeatable regression coverage that fails before the fix.

## Acceptance and delivery

- [x] Repeated native simulator runs at 1×/3× with idle/moving peers, changing
  directions and relevant lifecycle/network timing variations.
  Final actual-video and Pallet/Route 1 checks pass against candidate 05, with
  no skips/failures. Six fixed presentation cases have zero repeated moving
  poses and all sprites visible; controls reproduce approximately 29%/72%
  repeats at 1×/3×. Final artifacts are under `presentation-final-candidate05`.
- [x] 99 focused simulator presence/collision/checkpoint tests pass without skips
  or failures. Fastlane `ios verify` completes the unsigned Release iPhone build.
- [x] After the final camera, detach and deadline corrections, all 107 focused
  simulator tests pass with zero skips/failures, including eight new camera/OAM
  regressions. Final Fastlane unsigned Release iPhone verification passes.
- [x] Final segment/repeated-frame correction: all 112 focused tests pass with
  no skips/failures. Native Pallet/Route 1 crossing and the repeated actual-video
  control/fix test pass. Six fixed presentation cases retain zero repeated moving
  poses; all sprites remain visible. Pixel checks cover 7,680/7,680 trainer
  frames and 7,672/7,672 background transitions, with zero discrepancies.
  Sender gaps remain bounded (at most three native frames), with no backwards
  samples; raw authority is withheld during undecodable native phases.
- [x] Final app production source, including segment and exact repeated-frame
  handling, passes Fastlane unsigned Release verification (`release-verify-final-03`).
- [x] Verify both retired LaunchAgents remain disabled and unloaded.
- [x] Verify exact ROM, contract, core and state identities and preserve unrelated
  work. No backend deployment is authorized by this task.
  Final ROM is `24e39138…`; contract/save formats and core identity are unchanged.
  `paired-preservation-final05.json` verifies the original project, scheme,
  Info.plist, dependency pins and generated profiles remain byte-identical.
  Both retired LaunchAgents are still disabled and unloaded.
- [x] Commit requested validated changes; push explicitly to `origin/main` and
  independently verify the remote commit.
  Final app source: `721e2e70399116cd75ff8b8ec2c9d552f10b629b`.
  Final game source: `ec65a46387495f65a90955848ce7c8a4ccabd247`.
  Both explicit pushes and independent remote reads match. Unrelated app
  project/scheme/Info.plist edits and untracked Cloud configuration remain intact.
- [x] User explicitly approved the private ROM publication exception. Push
  `169bd658a68483f5f1d3d3f4df162ef1ee3df767` with `HEAD:refs/heads/main` and
  independently verify the remote head. Existing workflow 40973584928 succeeded:
  build 507 exactly matches candidate-02 SHA-256, all 39 CI checks pass, and
  publication/server read-back succeeded. Fast-forward main to the workflow's
  receipt-only commit `a9884bd51b3ea553349cc32b905e77d7458b3cc4`.
- [x] Verify final candidate-05 private publication from workflow 40987725974,
  including exact artifact hash, server read-back and counter receipt.
  Build **508** matches the complete candidate-05 SHA-256. The workflow's
  independent Linode read-back succeeds. Main fast-forwards to receipt-only
  commit `60051f3df6c97c849f0aae3429ab93b0b8346752`, independently remote-verified.
  The game working tree is clean; evidence is under `game-publication-508`.
- [x] Upload the new revision once through Fastlane, preserving the receipt.
  Apple accepted app source `721e2e70` at 2026-10-29 18:49:35 Pacific.
  Published-main preflight, signed archive, signature/privacy checks, local
  distribution export, upload and post-upload Fastlane Release verification
  pass. Receipt: `.build/testflight-delivery/721e2e70399116cd75ff8b8ec2c9d552f10b629b/upload-accepted.json`.
  Non-blocking prebuilt-framework dSYM warnings remain in the upload log.
- [x] Verify assigned upload build number, Apple processing and TestFlight group
  availability separately.
  Apple build **225** is `VALID` and `IN_BETA_TESTING`, with verified membership
  in **Evan Only Internal Testing**, checked at 2026-10-29 18:55:04 Pacific.
  `apple-after-upload-03.json` records Apple's assigned number and availability;
  the original acceptance receipt is retained unchanged. Do not upload this
  accepted source revision again. A final documentation-only commit records
  delivery after the uploaded source commit; it does not require another build.
- [x] Preserve final test artifacts, then shut down and delete only task-owned
  simulator `B066738C-2594-4509-B11C-2F8B5D37981C`. Shared simulators are untouched.

## Second cycle — local movement remains unresolved

- [x] Preserve the shipped app/game pair, earlier traces, original dirty project
  files, and the existing checklist. Both selected repositories remain on main.
- [x] Confirm the user's remaining symptom is mainly their own character.
- [x] Reopen the 23–33 extra isolated holds per 1,800 frames as a failure to
  investigate, rather than accepting only removal of consecutive holds.
- [x] Identify a coverage gap: the 32-held/8-released tape lets both modes finish
  three tiles per block and can conceal sustained movement-speed differences.
- [x] Identify a second coverage gap: emulator `processFrame` observations are
  not proof of displayed-frame continuity. Delta may skip catch-up rendering;
  VideoManager may decline a render while busy. The prior tape also replaced
  the full production update handler with a reduced probe stack.
- [x] Preserve a frozen shipped-app source tree and build it with continuous-run
  and continuous-walk QA tapes. Endpoint reversals keep input held; acceptance
  compares travel, prefix progress and every isolated hold with matched controls.
  The baseline simulator build passes; exact sources and binary hashes are kept
  under `movement-smoothness-cycle2-20261029`.
- [x] Correct the interpretation of guest counters: the admitted movement probe
  may reuse its last snapshot during an odd seqlock. Add separate raw world
  sequence/frame reads; admitted repeats alone do not prove native CPU stalls.
  All 3,138 active held poses in the baseline show raw sequence advancement at
  both video and completed boundaries. Every post-startup hold follows a
  desired-scroll pause, with desired motion resuming before the applied image.
  The defect is visible motion timing, not proof of stopped publication/CPU.
- [x] Trace installed collision hooks: ordinary object/flags paths do not cause
  duplicate presence authority scans. Actual native step-start work already
  spans VBlank in an inactive fixture, and active presence moves it later.
- [x] Identify common native overhead: `GameFieldFrame.publish()` takes about
  29,801 GBA cycles on the traced fixture, including clearing 896 payload bytes
  in a 960-byte snapshot before overwriting 800 of them. The earlier inactive control retains this work
  and therefore is not an untouched upstream-native performance control.
- [ ] Validate snapshot-copy optimization for identical complete bytes and
  interrupted-publication behavior, then measure its effect on continuous motion.
  Candidate-02 passes 180 native publication differential cases, including full
  2,048-byte output, interrupted reads, pointer alignment/bounds, sequence wrap,
  boulder records and corrupt policies. Its publication cost drops from about
  29,801 to 7,473 GBA cycles. However, the first eight-case continuous replay
  still fails: 600-frame inactive control travels 1,172 pixels with 12 held
  poses, while every active mode travels 1,146 pixels with 25 held poses at
  both 1× and 3×. The overall speed improves, but 26 pixels / 13 extra holds
  remain. This candidate is not accepted or published; investigation continues.
- [x] Reject further partial native improvements: candidate-03 adds aligned
  game-local runtime access and a block copy; candidate-04 skips irrelevant
  elimination-name policy work outside the two supported native menu callbacks.
  Native differential checks pass, but both retain 18 post-startup holds in the
  1,800-frame active mGBA shuttle. Exact failed sources/ROMs remain preserved.
- [x] Attribute the remaining budget problem: the native OAM sorting helper
  consumes approximately 11,600 cycles per ordinary field frame. An initial
  cached-key stable-sort prototype matches 256 native cases, but review finds
  a wireless VBlank sprite mutation that invalidates unrestricted caching.
- [ ] Validate a guarded OAM optimization with original-native fallback for
  unsafe interrupt contexts, nested IRQ stack bounds, exact output differentials
  and repeated real-frame movement. No unguarded cache is accepted.
  A fresh-key monotonic scan saves about 8,308 cycles when the existing order
  is already sorted and passes 1,024 native differential cases. Its diagnostic
  shuttle still has 11 post-startup holds, so it is not accepted. Passive timing
  confirms actual deadline crossings: the original callback has as little as
  3,819 cycles of spare time after variable native pre-dispatch/IRQ work. The
  remaining multiplayer work crosses that deadline; a full hardware frame's
  cycle count is not the available callback budget.
- [x] Reproduce build 508 under continuous held movement and measure cumulative
  travel, traversal cadence and isolated holds against matched native controls.
  All 18 active cases fail in the completed 24-case / 43,200-frame matrix:
  three start phases, 1×/3×, distant/nearby/moving peers. Each loses 78–90 pixels
  and adds 39–45 held poses per 1,800 frames relative to its matched control.
  Exact bitmap checks independently confirm the loss. The first pair is
  inactive 3,324 pixels / 208 tile transitions / 136 held poses versus active
  3,240 pixels / 203 transitions / 178 held poses. Both runner and failed
  acceptance receipts are preserved. "Inactive" still includes publication
  work, not the original unmodified native field routine.
- [x] Add an IRQ-enabled native comparison on a verified outdoor continuous
  shuttle. A diagnostic restoring only the original main/field entry bytes
  completes 1,800 native field callbacks in 1,800 hardware frames, with all
  within-held step intervals exactly eight frames. Other patches remain in
  that diagnostic. Published 508 completes 1,752 / 1,717 calls inactive/active;
  candidate-02 completes 1,789 / 1,782. Its remaining missed updates are real.
  Initial mGBA traces use zero UI host ports, unlike the app's setup port;
  they isolate wrapper cost but do not establish identical live UI workload.
- [x] Confirm the original frame-entry baseline on the shipping VBA core too.
  The guarded, paused same-anchor diagnostic restores only the original two
  entry sequences, hashes the source/resident changes, and verifies restoration
  after each case. It never fabricates BWO data or treats diagnostic state as a
  compatible saved game. On build 508, the 600-frame inactive wrapper run moves
  1,090 pixels with 53 held poses; original entries move 1,178 pixels with nine
  startup/turn holds and all 73 tile intervals exactly eight frames. This
  exposes 88 pixels / 44 extra holds shared even by the inactive control.
  `native-floor-508-discovery/check.json` is explicitly diagnostic evidence,
  not candidate acceptance. All continuous modes now use identical direct
  native object endpoints. The fresh four-case build-508 baseline still fails:
  active presence loses 28 pixels and adds 14 held poses in 600 frames at both
  1× and 3×, with a maximum cumulative deficit of 30 pixels. Failed acceptance
  is retained in `baseline-508-raw-control/check.json`.
- [ ] Measure the full production callback and accepted/rendered frame sequence,
  separating guest CPU overruns from host work and display drops.
  Added opt-in bounded DEBUG tracing around the production callback, compositor,
  renderer acceptance/busy drops and GameView. Simulator Metal supports command
  completion feedback, not drawable presentation feedback; neither is physical
  phone scanout. Independent review caught that a presence-only local transport
  cannot complete the movement-authority handshake; the fixture must exchange
  actual bounded interaction packets and assert admission before paired evidence
  can count. Compile/fixture failures are retained separately from movement tests.
  The corrected trace build passes. Initial 600-frame full-app off/no-peer runs
  pass their fixture gates with no render busy/layout/drawable drops: all 599
  requested graphics frames are accepted and handed to GameView. Owner callback
  means are 0.122 / 0.236 ms; native-frame work means are 1.248 / 1.290 ms.
  Register/OAM position proxies still hold after startup (12 / 13 isolated
  frames); these are not substituted for the independent BGRA movement proof.
  The first paired run fails sustained authority (A 0/600 active frames, B 73/600),
  despite successful initial handshake. Rendering still has no drops. Investigation
  finds the global DEBUG environment starts extra, unbound coordinators under the
  same peer: their nil-context ticks revoke the real owner's input. Relay packet
  totals exceed the measured owners' totals. The fixture is now scoped to the
  explicit test controller, with producer IDs and single-owner assertions; a
  diagnostic rerun confirms one producer per peer, but still fails sustained
  authority (A 496/600 active frames, B 507/600). All nonempty native input
  ports validate; gaps contain deliberate cleared ports, with no native
  generation/instance/map mismatch or malformed actor bytes. Desired authority
  disappears repeatedly during movement, so this is not just startup or a
  render drop. The next context trace proves seven recurring withdrawals begin
  with A's strict reader rejecting a native object tile one step ahead of the
  saved camera tile. Each sends a nil presence packet, which then revokes B's
  authority too. A/B remain active for only 518/533 of 600 frames. Packet ages
  remain below 77 ms, and all 599 render requests are accepted with no busy
  drops. `host-scoped-peer-context-analysis.json` retains the packet-by-packet
  timing and source/binary hashes. A narrowly modeled native transition is
  under investigation; no stale pose retention or relaxed lease is accepted.
- [x] Model the native pending camera step in the reader: admit only a fresh
  one-tile cardinal step whose previous object tile equals the saved camera,
  with native movement states both `2` and both endpoints inside the same
  verified map. Keep map-boundary rebases presentation-only. Native Stage3
  traces confirm all 212 observed build-508 disagreements meet this predicate.
  Eight extracted decoder tests pass; the old decoder fails both new positive
  regressions. Negative cases cover malformed movement, hidden/faded players,
  wrong maps, and boundary crossings. The rebuilt app's first paired 600-frame
  run on unchanged build 508 passes: zero recurring reader failures, nil-pose
  incidents, or live readings without a scene. A/B have authority for 592/588
  frames; all inactive frames are confined to startup (A 4–11, B 1–12).
  `host-reader-fix-peer-context-analysis.json` retains this result. Longer
  independent repeats and the native performance fix are still required.
  Actual VBA completed-frame observations at A frames 217, 226, 243 and 251
  confirm previous tile equals saved camera, movement states `2/2`, and the
  same verified map; all four remain live with a scene and native authority.
  There are no nil packets or inactive-authority frames after frame 60 across
  both peers. All 79 selected reader/presence/interaction tests pass once,
  with zero skips; the two explicit private runtime fixtures are excluded.
- [x] Strengthen the full-host acceptance gate against intermittent withdrawal.
  After a fixed 60-frame startup allowance, every enabled reader must remain
  live with a scene; paired runs also require uninterrupted admitted authority
  and host input, with no inactive committed native publication. The existing
  whole-window coverage requirement remains. Twenty synthetic checks pass,
  including rejection of a single late withdrawal despite greater than 99%
  aggregate coverage. Both corrected traces pass and both old recurring-failure
  traces fail, as expected. New long runs still need to pass this gate.
- [x] Add explicit host render accounting: each post-startup graphics frame
  must be processed, accepted, handed to a view and drawn. Reject busy/layout/
  drawable drops and missing/failed Metal command completion; retain callbacks
  that finish after the measurement marker but belong to measured frame IDs.
  Intentional fast-forward graphics selection is distinguished from normal-speed
  skipped frames. Five maintained negative-control tests pass, and all four
  retained paired traces pass render delivery, consistently isolating the old
  authority failure from renderer loss. Command completion remains distinct
  from physical presentation.
- [ ] Remove the remaining causes without weakening authority, save semantics,
  native game policy or the acceptance criteria; repeat independent long runs.
  Maintained-source candidate-05 (`ab2f86e…`) still fails both cores: seven
  post-startup holds / 1,800 native hardware frames, and four pixels / two
  extra holds in each 600-frame VBA active comparison at 1× and 3×. Its
  separate same-anchor native-entry comparison is equal, but that cold start
  differs from the active comparison; a single matching floor run is not
  acceptance. The candidate source, compiler inputs and failed receipts are
  immutable under `game-audit/candidate05-source` and `candidate05-vba-discovery`.
  Its full sprite output differential passes 512 cases. Independent review
  found the fixture ties context to IME parity, leaving optimized IME=1
  cases uncovered; corrected Cartesian coverage now passes all 544 cases.
  Candidate-06 defers unused non-boulder template reads and saves 532 cycles
  but still has seven holds. Candidate-07's relocated O2 UI routine is slower
  and has been reverted, with its evidence preserved. Candidate-08's compact
  coordinate/priority loops reduce native holds to three, but still fail.
  Its first miss is a camera/step spike: 155,700 callback cycles against a
  143,479-cycle budget, versus 138,786 for the native-entry baseline. Further
  work now targets the measured native follower/daycare metadata calls at that
  spike, rather than treating smaller average cost as sufficient acceptance.
- [x] Audit the native timing seed before trusting overlay comparisons: its
  live CPU/stack is halted in unchanged BIOS/native VBlank-wait code, with no
  relocated runtime continuation or active callback. Historical runtime
  addresses below SP are stale, not live frames. The audit retains controlled
  overlay scope and does not establish exact-candidate cold-state acceptance.
  Fresh cold VBA testing independently reproduces candidate-05's remaining loss.
- [x] Preserve native follower policy while optimizing measured metadata calls.
  The selector's HP read must pass through the installed elimination policy;
  a draft direct HP read was rejected. Corrected tests cover first-slot,
  second-slot and both-slot denial, including identical graphics with different
  personality IDs. Scoped getter/ability replacements retain the native
  selector and its fallback. Candidate-10 reduces the native shuttle to one
  missed update in 1,800 frames, but still fails and is not accepted.
  Its remaining heavy step exceeds the actual callback budget by 2,768 cycles.
- [x] Audit ownership before adopting the fast species-presence helper. The
  generic helper can overlap host party writes at completed-frame boundaries;
  no corruption was reproduced, but exact generic equivalence is unproven.
  Restrict the next candidate to the three verified daycare records derived
  from the current SaveBlock1, with native fallback elsewhere. Preserve the
  rejected global prototype and its evidence. An owned animation-loop prototype
  also removes repeated address arithmetic while preserving callback order and
  fresh checks after callback mutation. Candidate-11 combines those changes and
  still misses one update in 1,800 frames; its remaining deadline excess is
  1,174 cycles. It is rejected. Daycare scope/fallback and recursive native
  animation controls pass; further work targets the measured remaining cost.
- [x] Reject a native-only success using the shipping VBA core. Candidate-12
  (`0feb9f5f…`) first matches the original-entry native replay: 1,800 updates,
  3,580 pixels and zero post-startup holds. Fresh native normal/debug setup,
  544 sprite comparisons and 4,741 metadata/animation checks pass. However,
  VBA reproduces six extra holds and 12 pixels of lost progress at both 1×
  and 3× over 1,800 frames: inactive 3,576 pixels / 10 holds, active 3,564 /
  16. The strict checker rejects it. In a separate cold start, the same-anchor
  three-mode diagnostic gives original entries 3,578 pixels / nine holds,
  inactive wrapper 3,572 / 12, and active 3,564 / 16 at both rates. This
  proves remaining common overhead as well as the additional active loss.
  The original native-seed timing margin was only 619 cycles; that single
  passing replay was insufficient. All exact sources, builds, failed receipts
  and floor diagnostics are retained under `candidate12-*`.
- [x] Exercise native vertical reordering early: the verified clear corridor
  x36/y20–22 has 112 native sort fallbacks in 1,800 frames. Candidate-11 and
  original entries both complete all 1,800 updates with 3,596 confident pixels
  and no post-startup holds. The first route entered grass and triggered an
  encounter; that rejected fixture remains preserved and is not acceptance.
- [x] Reject candidate-13 after another shipping-core reproduction. Reordered
  pure UI queries and an exact eight-word idle-manager guard save about 2,000
  cycles per callback; a native follower form shortcut preserves all possible
  held-form items and non-null move queries. The controlled native replay
  completes 1,800 updates without holds, with a 2,469-cycle minimum margin;
  180 full-RAM/UI comparisons, 29,606 movement/form checks and 544 sprite
  comparisons pass. The fresh VBA run still loses eight pixels and adds four
  held frames: inactive 3,578 pixels / nine holds, active 3,570 / 13. This
  remains a failure, retained in `candidate13-vba-discovery`, not acceptance.
- [ ] Measure the remaining native deadline misses in the shipping VBA core
  using a separately compiled, opt-in diagnostic. Keep guest instructions,
  guest cycle accounting, ROM/state formats and ordinary emulator execution
  unchanged; bounded host-side timing observations are diagnostic only.
  Continue cold, held-item, later-party-slot and longer native stress in
  parallel. A short replay with a small timing margin is insufficient.
- [x] Capture actual VBA guest-cycle traces for candidate-13. Three matched
  cases validate exact 280,896-cycle video periods, call/IRQ pairing and zero
  dropped/overflowed/invalidated records (`candidate13-vba-guest-timing-01`).
  They reproduce recurring holds and identify a concrete coverage failure:
  every observed `GameSpriteFrame` call takes the original native fallback.
  The frozen VBA anchor has idle SIOCNT `0x0000`, whereas the optimization's
  guard requires `0x2000`; all other checked anchor fields match. The pinned
  VBA core ignores SIOCNT writes when no link driver exists. Preserve its
  upstream behavior and investigate admitting that safe idle context with
  complete IRQ/DMA/native-link guards. Instrumented wall time is not movement
  acceptance; an uninstrumented repeated rerun remains mandatory.
- [x] Validate the candidate-14 guard correction before broad acceptance.
  Exact idle SIOCNT `0` or `0x2000` is admitted only with `RCNT == 0` and all
  prior IRQ/DMA/RFU/native-context checks retained. Independent review pins the
  inactive native handler paths; 672 native sprite comparisons cover both idle
  representations, both IME states and unsupported serial/GPIO/JoyBus contexts.
  The ordinary VBA build passes all four 1,800-frame native/active comparisons
  at 1× and 3×: each travels 3,578 pixels, with the same nine startup holds
  and zero post-startup holds or active progress deficit. Runtime binding tests
  pass against the frozen app-12 table and published 508. Retain this as the
  first causal shipping-core pass, not final acceptance: later-party-slot,
  long/cold-phase and combined full-host coverage are still outstanding.
- [x] Reject candidate-14 as final after an independent cold diagnostic run.
  The fast sprite path is now actually used on every measured callback and
  falls from median 32,245 to 16,002 cycles, but active movement still holds
  once at frame 940. The same-anchor control does not. Callback 939 misses
  the native wait deadline by 509 cycles under high preceding audio load;
  the extra work is steady before-callback/collision validation, not a
  friendship event. All trace integrity checks pass. This is preserved under
  `candidate14-vba-guest-timing-analysis-01`, alongside the earlier normal
  four-case pass; one passing anchor was insufficient.
- [x] Isolate the separate larger-party periodic spike. The native 128-step
  loop updates friendship for all six records, including fainted members.
  Slot-five callback 1,025 spends 39,789 cycles there, with about 29,400 in
  repeated metadata getters. Artifact-only scoped read adapters preserve
  Random, friendship arithmetic and SetMonData ordering, and remove this
  second missed update. A static field-38 assumption was rejected by the
  native differential and corrected before any main change. The remaining
  uniform validation cost still requires a separate fix.
- [x] Prove an artifact-only faster complete reserved-tail scan: the 64-byte
  transient stack routine saves 363 cycles per 832-byte scan. All three
  fresh scans remain. 865 read-order/corruption/ABI cases and 1,160 actual
  native interrupt, nested-call and mid-routine save/resume cases pass.
  No persistent RAM, save format, host authority or core timing change is
  involved. Combined full-field and actual VBA validation remain pending.
- [x] Freeze candidate-15 (`3b2f649c…`) with the complete faster validation
  scan and scoped native friendship adapters. Its six-slot native replay
  completes 1,800 callbacks and 3,580 pixels without post-startup holds;
  the minimum measured deadline margin is 697 cycles. The maintained native
  friendship differential passes 3,840 cases. This remains exploratory until
  actual VBA and combined coordinator/Soul policy runs pass repeatedly.
  The 112-record contract preserves the embedded Soul query address and passes
  the exact current/published-508 compatibility verifier. App ABI, profiles,
  profile freeze, SDK, Soul shim and host-gate checks pass; a fresh ordinary
  simulator build is in progress, with interpreter timing instrumentation off.
- [x] Reject candidate-15 after extending the six-slot native replay to 7,200
  frames: a later hold at frame 4,442 yields 7,199 callbacks and 14,378 pixels.
  The earlier 1,800-frame pass is insufficient. Preserve the long failure for
  deadline attribution before further changes. Actual full-field scanner/body
  minimum stack pointer is `0x03007C30`; no natural VBlank occurred within the
  scanner in that run, so its separate interrupt/save-resume proof remains
  qualified. The ordinary app-15 simulator build completed successfully.
  The matching 7,200-frame original-entry control was not yet run at discovery:
  treat this as an unresolved long-run hold, not a proven extra regression
  until that exact-anchor control and deadline attribution complete.
  The retained older original-entry control also has one hold and identical
  total travel, at a different phase. Because it is based on 508, this is only
  provisional. An exact candidate-15 image differing solely in the two native
  entry patches is prepared for the definitive control.
- [x] Freeze candidate-16 (`5bc8b3d3…`) with the independently checked
  aligned elimination query and fresh empty-set fast path after cooperative
  policy. The stable cartridge query address and all 112 restoration rows are
  preserved; its presence/sprite/step code is byte-identical to candidate-15.
  Its first ordinary VBA matrix passes all 16 cases: 1,800 frames, phases 0/1,
  native/far/near/moving peers and 1×/3×. All 12 active comparisons have exactly
  zero total, cumulative-prefix and held-frame deficit against their controls.
  Exact final-16 import, published-508 bindings, profile freeze, ABI, SDK and
  unchanged app Soul shim checks pass. Long/cold and final host acceptance
  remain outstanding.
- [x] Reject candidate-16 after extending the exact same-anchor VBA control to
  7,200 frames. Native and original-entry controls each travel 14,378 pixels
  with only their nine startup holds; active far travels 14,376 with an extra
  hold at row 3,732. Every bitmap/camera check passes, and the native entry
  patches restore exactly afterward. The anchor contains one healthy Pokémon,
  so fainted-only work cannot resolve this path. Diagnostic wall timing is
  excluded because other native work ran concurrently.
  The exact candidate-15 two-entry-only six-slot control also completes all
  7,200 callbacks without a hold; active 15/16 each miss once at 4,442. This
  supersedes the provisional older-control comparison. Both residuals remain
  open despite the shorter 16-case pass.
- [x] Implement the narrow app friendship-fence correction and freeze a test
  build. Only byte41 may differ, with every other party byte and complete
  observation context unchanged. Valid stable fainted records and unchanged
  egg siblings are covered; changed eggs, malformed records, HP/identity
  changes and other critical facts still fence. Full raw submission, reduction,
  durable receipt matching and checkpoint behavior remain intact. Five focused
  tests, 17 extracted context checks and independent review pass.
  The new host fixture observes the actual fence before/after the owner,
  snapshots counters exactly after frame60 and the final measured callback,
  and can verify a fainted-first/living-second party every frame. Nine gate
  tests pass; runtime acceptance of this app change is still pending.
- [x] Exercise the friendship correction in the compiled ordinary app:
  five focused XCTest regressions pass with zero skips, and a quiet paired
  3,600-frame healthy-party run passes authority, actual Soul policy, frame
  fence and render-delivery gates. A has three routine friendship changes
  strictly after frame60 and before measurement end; critical-party, blocked
  and critical-callback counters do not increase. Every post-startup native
  video frame is observed, with 7,078 pixels and one isolated native hold.
  This establishes the app fence correction, not final native smoothness.
- [x] Preserve the failed fainted-party fixture rather than count it as a
  movement pass. It records two real routine friendship changes with no fence
  closures, but A remains stationary through frame804 and both peers briefly
  withdraw authority. Native publication progression indicates modal callback
  ownership; the setup loss notice remains unannounced. Exact modal state was
  not recorded, so this is a supported inference. The next fixture requires
  real native A acknowledgement of the exact pending notice and retains its
  durable death/history before measurement. No authority timeout is relaxed.
  The setup correction passes source parsing and ten gate tests; it is unbuilt.
- [x] Execute the combined full-host fixture on app/ROM candidate-15. Two
  paired 600-frame runs, follower on and Soul policy respectively on/off, pass
  actual hook/ledger, sustained authority and render-delivery checks. Native
  sprite plus camera observations show 540 post-startup two-pixel movements
  with Soul on; the off control has one isolated hold and 539 movements.
  These separate cold launches have different phases and do not establish
  final long-run acceptance. The first run's host-load qualification is retained
  in its evidence; no physical scanout or WAN claim is made.
- [x] Reproduce an additional full-host pause on published 508 with the new
  active Soul/follower fixture. Peer A has 172 measured native holds and one
  host callback (1,150) with no native emulation or video process; the render
  gate correctly fails. Its durable ledger/policy/history is unchanged, and
  the skipped callback follows the 128th completed step. Source inspection
  identifies the Soul critical fence treating every party-byte change as
  critical. The actual native friendship setter changes only byte 41;
  32 setter and 112 native friendship calls confirm this on 508 and candidate16.
  Do not assume conventional checksum updates: the native checksum store is
  disabled. A narrow friendship-only exception is being implemented; all
  identity, HP, egg, box, event and malformed changes must remain fenced.
  A quiet candidate16 full-host 1,800-frame run passes existing gates with one
  isolated native hold, but does not prove the friendship event occurred.
  New DEBUG fence observations and nine gate tests are ready; final runs must
  retain an actual routine-change counter and show zero closed-fence callbacks.
- [x] Add a full-host active Soul policy fixture using the production probe,
  a task-owned durable ledger and observed native hooks. It requires correct
  hook/header/sequence state on every post-startup frame and verifies teardown;
  negative controls and independent lifecycle review pass. Actual simulator
  validation remains pending. Existing owner callback counts alone did not
  establish active policy, so the older receipts are not treated as covering it.
- [x] Expand candidate-13 beyond the original follower fixture. Ordinary held
  items and an actual held-form item in the first party slot complete 1,800
  native updates in the controlled seed, but moving the living follower to
  slot five reproduces two missed updates (frames 770 and 1,027), 1,798
  callbacks and 3,576 pixels. Keep that failure in `game-audit/held-stress`.
  A tiny stack-executed reserved-tail scanner saves only 249 cycles per scan;
  its 865 differential checks pass, but it remains an artifact experiment
  pending evidence that the gain warrants its extra stack/IRQ complexity.
- [x] Repeat the reader fix independently with a longer full-host paired run.
  Published ROM 508 plus the frozen reader-fix app passes 1,800 frames per peer
  in `host-reader-fix-peer-long-02`: all 1,740 post-startup frames retain live
  reader/authority and reach rendering on both peers. No observed render-stage
  interval exceeds two 60 Hz periods; the maximum is 25.4 ms. These wall-clock
  distributions are now retained separately from frame-completeness checks.
  This validates the coordinator fix again, not candidate-13's guest timing or
  physical presentation. Final exact-ROM/rate/walk repeats remain required.
- [x] Close the combined follower/coordinator coverage gap in the next app
  fixture. `--follower 1` uses the native service dialogue before the measured
  lane; both on and off variants require the expected native follower state
  on every post-startup frame. Twelve independent negative-control checks
  pass. The previous host runs retained the cold-boot follower setting; their
  receipts do not establish combined follower-on performance. The new fixture
  is source-reviewed and parsed; simulator execution remains pending.
- [x] Separate standalone timing from live policy-hook cost. The continuous
  VBA replay does not install the app's Soul Link shim, so that shim cannot
  explain its candidate-13 failure. The new trace records resident-hook state
  explicitly. A separate 80-case shim audit preserves native HP output/RAM/ABI
  and measures substantially higher cost with active elimination policy;
  preserve it as full-host investigation, not standalone replay evidence.
- [x] Close the malformed daycare-pointer alias found by independent review.
  Candidate-12 admits the shortcut only at the exact native SaveBlock1 base
  `0x0202552C`; every alternate base uses the original helper. Native setter
  and startup ownership establish that fixed base. The scoped follower read
  adapters preserve synchronous output/policy/ABI and never rewrite secure
  party bytes; 96 interruption tests preserve newer party data. They do not
  claim identical asynchronous write ordering to the old redundant writebacks.
- [ ] Keep published build 508 compatible when importing the final generated
  runtime contract. Added exact complete-table admission for its 105 restoration
  records alongside the current table; mixed/subset/corrupt tables remain
  rejected. The pre-import production-header test passes. New hooks require
  additional restoration records, so final current/legacy pair tests and an
  import remain required. The executable-consumer audit finds one embedded
  cartridge query in Soul Link; its address remains identical in 508 and all
  candidates through 11. The pair verifier now pins that target, actual compiled
  shim imports and all bridge data locations. This does not admit cross-ROM
  save states or mixed-ROM peers.
  Candidate-12's full 111-record table and published 508's frozen 105-record
  table pass the production-header verifier together, including every-record
  corruption, mixed sets and exact-ROM hash isolation. ABI/profile/SDK/Soul
  Link checks and all 13 profile-freeze tests pass. The app import and its
  successful frozen simulator build are exploratory, not final delivery.
- [ ] Validate the final exact pair, publish main and the approved private ROM
  update if affected, and upload a new revision through Fastlane once validated.

## Unresolved / limits

- [x] Reject private18 after its long last-living-party control reproduced an
  ordinary-step deadline miss at frame 5,170. Removing the unused native
  checksum calculation fixed the periodic friendship spike, but did not leave
  enough margin on ordinary steps. Keep the failed replay and exact native-entry
  control in `game-audit/candidate18-prototype` and `game-audit/held-stress`.
- [x] Candidate19 also avoids redundant positive-HP queries for physically
  fainted members inside the owned native follower-selection call. Positive HP
  still goes through the currently installed policy getter. All 168 selector
  comparisons preserve native/Soul output, RAM and ABI. Three independent
  7,200-frame native stress cohorts (ordinary held item, five fainted members,
  and held-form item) each finish 7,200 callbacks and 14,380 pixels without a
  post-startup held frame. The maintained rebuild matches the tested prototype.
  Exact SHA256: `83f35342daaad5c0798095eff9adab6168e2f70135ae37af3dc49debad38747a`.
- [x] Import candidate19's complete 113-record runtime contract. Generated
  ABI/profile/SDK/Soul checks, 13 profile-freeze tests and current/508 complete
  runtime binding checks pass. Preserve the first binding-check invocation's
  missing-manifest error; the corrected explicit published508 manifest passes.
- [x] Reject candidate19 after varying the native starting phase: last-living
  slot-five runs at pre-roll 31/127 lose one frame, and pre-roll 1,023 loses two.
  Their exact two-entry controls lose none. The worst measured deficit is
  2,603 cycles, despite all three initial phase-zero 7,200-frame runs passing.
  Continue reducing uniform work; the earlier 874-cycle artifact trial alone
  is insufficient. Source remains frozen while the next change is investigated.
- [x] Candidate19 simulator build and clean unsigned Release iPhone Fastlane
  verify pass. Independent production reviews found no correctness blocker.
  Xcode updated to 27.2 during this cycle; its required component update was
  completed through Xcode, preserving simulator data/accounts. Two attempted
  launches stopped before XCTest. The new 27.2 xctestrun supersedes the stale
  cloned 27.1 file, recorded in `candidate19-app-source-receipt-v2.json`.
  These compilation passes are not movement acceptance.
- [x] Re-run candidate19 app regressions under the completed Xcode 27.2 setup:
  79 reader/presence tests and all five friendship-fence tests pass, without
  skips. Corrected full-host fainted setup visibly acknowledges the exact
  native loss notice on both peers and retains the durable death/history.
  The real 3× pipeline passes the corrected every-native-frame processing gate.
- [x] Retain candidate19's full-host residual as a failed movement result.
  A 3,600-frame fainted/Soul-on peer run passes authority, policy and render
  delivery, but native pixels lose four pixels/two isolated frames against the
  matching off control (7,076 versus 7,080 pixels after startup). Both have an
  actual friendship change, no new critical callbacks, and every observed
  frame fence open. Separate cold launches do not establish identical IRQ
  phases, but the comparison rejects movement acceptance. The healthy no-peer
  3× run has 7,080 pixels, no held frames and two actual friendship changes.
  These exploratory runs overlapped native diagnostics, so wall timing is not
  final performance evidence. See `candidate19-fainted-peer-long-discovery-01-analysis`.
- [x] Private20 combines freshly checked base-pointer access for presence/UI
  with the native flag getter's original entry. It preserves all 113 restoration
  records and passes complete app19/current/published508 binding checks.
  The actual VBA 7,200-frame same-anchor diagnostic now exactly matches native
  and raw-entry controls: 14,378 pixels in all three, zero total/prefix/bitmap
  deficit and no extra held poses. Its receipt remains diagnostic, not final
  candidate acceptance (`candidate20-app19-vba-native-floor-long-02`).
- [x] Reject private20 after expanding the native route to vertical movement.
  Phases 31/127 each add one held frame; exact native-entry controls add none.
  Their late callbacks miss by 1,250/328 cycles and do not invoke native OAM
  sort fallback. Three previously failing horizontal phases are clean, which
  does not override this new failure. Main game source remains candidate19.
  The wider ARM reserved-tail scanner is slower (1,310 versus 1,226 cycles)
  and rejected. Further work targets measured native flag/sprite costs.
- [x] Recover simulator availability after the Xcode component transition.
  Apple's official 27.2 runtime download/install also restored registration of
  the existing 27.0 runtime; both original task simulators and their data remain
  intact and are running again. No account, signing credential, production
  run or unrelated simulator data was removed. The stale-startup attempts did
  not execute tests or contribute passing results.
- [x] Private20's full-app fainted-party comparison is clean: both peer and off
  controls travel 7,080 pixels with zero held frames after startup; the peer
  records three routine friendship changes and no new critical/blocked callbacks.
  This closes the earlier horizontal full-host residual in that case, while
  the confirmed vertical failure still rejects the candidate overall.
- [x] Private21's stackless expanded-flag read passes 84,545 native comparisons
  and clears the three long vertical last-living-party cases. Expanded testing
  then finds a new ordinary/form-held-item phase-31 miss: exact native controls
  have 7,200 callbacks and 14,380 pixels, while active runs lose one frame/two
  pixels. Keep candidate21 rejected. The next experiment preserves exact
  native replay/record handling while reducing normal/zero-flag overhead.
- [x] Add independently reviewed actual-VBA vertical replay coverage. Its 38
  self-checks pass, and all 16 retained horizontal cases remain checker-equivalent.
  Continuous input, Y bitmap motion, fixed-column lane, endpoints and same-axis
  controls are checked strictly. A separate test build will validate the new
  fixture on rejected ROMs before it is used for final acceptance.
- [x] Audit publication boundaries before considering removal of repeated work.
  World publication already occurs once per field invocation; presence/UI
  commits carry distinct state and can be observed between commits. Keep them;
  skipping a commit is not an established equivalent optimization.
- [x] Reject candidate22's animation-counter batching after the native callback
  register check fails; remove the batching rather than weakening the check.
  Candidate23 preserves native callback state and reduces measured flag/sprite
  work with fresh per-call reads, native policy continuations and an IRQ-tested
  ARM key scan. All publication/authority boundaries remain intact.
- [x] Freeze candidate23 on game main and import its exact 113-record contract
  and ROM pin into the app. ROM SHA256 is
  `124da58c42470d018f85ccdc3a1a49d5d3e957eba85c46c0617293f96c3ed1cf`.
  Nine native 7,200-frame cohorts (64,800 frames) have no added holds, including
  horizontal/vertical movement, form items, last-living party slot and varied
  phases. The final 14,400 frames start from a fresh exact-ROM cold boot and
  actual native follower service. Functional, IRQ/reentry, policy, no-cache
  rebuild and publication-input reconstruction checks pass. See
  `game-audit/candidate23-native-acceptance.{json,md}` in the cycle2 artifacts.
- [x] Candidate23's actual-VBA horizontal same-anchor diagnostic matches both
  native controls across 7,200 frames: 14,378 pixels, no extra held frames,
  no prefix/bitmap loss. This uses the previously frozen app19 build and remains
  explicitly diagnostic (`candidate23-app19-horizontal-floor-discovery-01`).
- [x] Retain the first vertical app-fixture failures: its row23 endpoint enters
  grass and triggers battle; its background columns lack sufficient texture.
  Correct the route to pavement rows20–22 and sample textured Mart columns.
  Match the trainer from same-frame native OAM/VRAM and mask only follower
  pixels confirmed in the framebuffer. Preserve confidence/visible-pixel gates;
  negative wrong-position/overbroad-mask checks pass. Actual corrected-fixture
  validation remains pending (`vertical-fixture-correction/receipt.json`).
- [ ] Complete repeated exact candidate23 app acceptance, clean Release build,
  paired functional/native battle checks, commit/push and delivery.
- [x] Build the exact candidate23 QA app and clean Release iPhone artifact.
  Both builds pass; the release binary contains no QA timing/trace observers.
  Preserve all initial unrelated project/scheme/plist changes and dependency
  pins. Final flag semantics are reproduced by the maintained verifier in
  92,816 paired native cases, including 5,008 positive policy cases.
- [x] Validate the corrected vertical fixture in the actual final app. Candidate23
  passes the 600-frame pilot with all trainer samples and no added holds, lost
  progress or uncertain background pairs. The published508 negative control
  remains structurally valid and fails the movement gate: 42 extra held frames
  and 84 pixels lost over 1,800 frames. This is a valid reproduced regression,
  unlike the earlier invalid grass-route runs.
- [x] Complete final exact-pair long native-entry diagnostics on both axes:
  7,200 frames each for active, inactive and raw-entry controls (43,200 total).
  All four comparisons have zero extra holds, total/prefix progress deficit
  and bitmap deficit. These are explicitly diagnostic controls, not substitutes
  for the repeated production matrix and full-host acceptance.
- [x] Complete the exact candidate23 production replay matrix: 48 cases and
  172,800 frames across horizontal/vertical continuous running, 1x/3x playback,
  native/far/near/moving peer modes and pre-rolls0/31/127. Both 24-case strict
  reports pass. All 36 matched comparisons have no added holds or total/prefix
  progress loss. Independently scan every cumulative-motion trace: no held
  frames after the first60 native frames in any case, including native controls.
  See `candidate23-final-matrix-hold-audit.json` and the two final matrix checks.
- [x] Expand walking/follower controls and retain a remaining failure. Walking
  with the follower and running without it each match controls at1x/3x. Walking
  without the follower at3x, phase127, adds one actual held frame at video700
  and loses one bitmap-confirmed pixel; native3x and both1x cases do not.
  This is outside startup. The numeric finite-window gate alone would pass,
  but the identified added hold reopens candidate23 movement acceptance.
  See `candidate23-final-controls-01/walk-follower-off/check.json`.
- [x] Final reader/presence tests79 and friendship-fence tests5 pass without
  skips. Native berry effects pass. Correct a task-only runner's stale data
  container path after XCTest reinstall; fresh exact-ROM state was preserved.
  The next collision phase fails initial snapshot admission in all4 tests;
  fixture initialization is under separate investigation. Do not count those
  failed/missing functional checks as accepted.
- [x] Resolve the collision fixture failure with a bounded native advance when
  the first snapshot is unavailable. The exact saved state had odd sequence603
  and a PC inside its producer; production rejection was correct. With the
  QA-only warmup, all17 final native functional tests pass without skips
  (`candidate23-final-functional-03`). Preserve both prior failed receipts.
- [x] Investigate the remaining walking hold using stricter exact-state replay.
  Two fresh7,200-frame controls and three repeats of the original anchor at3x
  have no later holds; this does not erase the retained frame700 failure.
  The diagnostic requires identical ROM, core binaries and serializer/source
  provenance. A rebuilt core was rejected before launch; a separate QA package
  retains the exact original core frameworks with the new test bundle.
  Twelve additional original1x-to-3x order cases also have no later holds.
  The saved anchor and case order are not sufficient to deterministically
  reproduce the original frame700 overrun; retain that uncertainty.
- [x] Identify the cold follower-disabled native context: one healthy Pokémon,
  followerOFF, IE4/5 and uninitialized RFU state. It takes the original sprite
  path. A separately guarded wired-idle optimization is being tested privately;
  candidate23 remains on main and no cycle2 delivery has occurred.
- [x] Private24's separate cold wired-idle guard passes1,488 native whole-stage
  equivalence cases and7,056 wired IRQ/reentry/save-resume cases. Four fresh
  exact24 cold walking cohorts (28,800frames) have no later holds and exercise
  the optimized path every frame. The minimum observed work margin rises from
  about10,425 to26,784 cycles. These are native discovery results; actual-app
  repeats, main adoption and final delivery are still pending.

- [x] Adopt candidate24 and import its exact 113-record contract and ROM pin.
  SHA256 is `c5cb5345cdb0a2d6ea941253320ed64e4afd8e62c6fd3107288b68b4cab7d5cf`.
  All three maintained IRQ/reentry gates pass with the complete key/order
  table covered. Actual-app walking discovery adds86,400 frames across1x/3x,
  cold phases31/127/511, active/inactive controls and raw-entry diagnostics;
  no post-startup holds appear. These runs use the frozen app23 production
  runtime with candidate24's verified dynamic contract, not a final24 build.
- [x] Expand to the full paired host and retain another failure. The off
  control moves7,080 pixels without holds; the peer run loses2 pixels at
  frame1893, midway through an admitted step. All surrounding input, authority,
  Soul fences and render stages remain healthy; three routine friendship
  changes cause no critical gate. This supports a native presentation deadline
  miss, but the trace lacks guest timing needed to identify the function.
  See `candidate24-host-residual-audit/README.md`. Final24 build and delivery
  remain on hold while the exact installed Soul hooks and native context are
  reproduced. No cycle2 changes have been committed or delivered.
- [ ] Resolve the full-host native hold, repeat exact-pair acceptance and
  functional/native battle checks, then complete authorized delivery.
- [x] Close a native replay coverage gap by installing the actual five Soul
  hooks and enabled shared-world policy. A fresh7,200-frame phase31 replay
  reproduces a held frame at6042 with active multiplayer: native work exceeds
  its deadline by3,838 cycles with Soul and shared progression. The same
  inactive control is clean. All sprite fast-path guards remain admitted;
  missing sprite-guard eligibility is not the cause of this case.
- [x] Repeated paired app testing catches a separate authority withdrawal.
  Four advancing odd publications at1033–1036 exhaust the host's three-sample
  tolerance and revoke movement despite a live reader and producer progress.
  A bounded fix is in progress; incomplete snapshots must not grant authority
  or refresh the existing wall-clock/native-frame expiry.
- [x] Diagnose the no-peer fixture's repeated reader resets: its relay fills
  a64-message ordered queue for the deliberately absent recipient, then
  alternates disconnect/reconnect. Add explicit recipient configuration and
  counted unrouted sends for that fixture. Paired ordering, ACK/retry and queue
  overflow behavior stay intact. Relay self-tests pass, including256 absent-peer
  sends without a fabricated response. The same-binary3,600-frame replay now
  passes every reader/fence gate, travels7,080 pixels with zero holds or prefix
  deficit, and handles three routine friendship changes. It records128
  unrouted sends and no retained queue; no production reader change was needed.
  See `candidate24-no-peer-fixture-audit/report.json`.
- [x] Fix advancing odd-publication admission without consuming incomplete
  actor/request data or renewing PH authority. Waiting remains anchored to the
  last coherent sample's150ms and15-frame bounds; stuck writers still revoke
  on the fourth sample. Revalidate fresh requests before writing delayed grants
  and reject rollback, timeline/profile loss and ambiguous sequence distances.
  All63 maintained source tests pass; the original four-odd failure fails the
  baseline. A new exact24 QA app builds with all19,163 inputs unchanged.
- [x] Run the new app's paired600-frame port diagnostic: both strict reports
  pass. Preserve actual paused ROM/RAM/IO/core-state context and file hashes
  after paired readiness for native replay workload verification. This is
  diagnostic evidence, not long movement acceptance. Long paired and compiled
  protocol tests are continuing (`candidate24-host-context-peer-diagnostic-01`).
- [x] Run all63 movement protocol/probe tests in the actual new QA app: all
  pass with zero skips. The paired port diagnostic observes real odd waits
  without PH renewal: one two-frame chain consumes lease15→14, then renews
  only after a coherent publication. It does not happen to exercise four odd
  samples; that exact failure remains covered by the deterministic regression.
- [x] Retain the next long paired failure after the odd-publication fix.
  The3,600-frame run has zero native holds and7,080 pixels of movement, but
  A's live reader loses its scene at1473 and authority withdraws shortly after.
  BWO is coherent throughout; no cached snapshot is lost. This is a distinct
  incomplete presentation read, not evidence that the odd-wait fix failed.
  Preserve the strict failure and add bounded, opt-in nil-scene memory/decoder
  capture before changing scene validation. Diagnostic captures cannot count
  as performance acceptance; the runner/analyzer negative controls enforce it.
- [x] Build and verify the scene-diagnostic app, with all19,163 inputs matching
  its frozen source. Four fresh3,600-frame1x paired runs do not reproduce the
  scene loss; keep the prior failure open. Both emulator frameworks have
  identical executable sections, addresses, sizes and core sources between
  the failing build and diagnostic build; changed core code is ruled out.
- [x] Reproduce and capture the same scene loss at1473 in a3x paired run.
  The decoder rejects native camera residual−16 before camera-cache resolution.
  Current/prior tile and applied-scroll data otherwise support the continuing
  step. Keep this exact RAM/cache capture for a failing-before/fixed-after
  regression (`candidate24-scene-peer-3x-diagnostic-01`). Production repair and
  repeated runtime acceptance are pending.
- [x] Expand the next full-host build's bounded acceptance window to7,200
  native frames so it can cross the retained6042 native failure. Increase trace
  storage proportionally; retain the same dropped-event and every-frame gates.
  Native map-lookup experiments now clear the healthy full-policy6042 hold,
  but the fainted-party variant still fails. Do not adopt or deliver that
  partial result; retain all realistic Soul/world/cooperative/links workload.
- [x] Reproduce the captured1473 scene loss in the complete production decoder,
  then fix the exact intermediate CameraUpdate phase. Admit only its normal
  callback, settled moving tile, matching native speed/live-built displacement
  and applied/desired scroll. Require an existing same-scope/map/instance camera;
  retain current/prior movement segment bounds and reset behavior. The raw±16
  remainder cannot establish an origin. Captured replay now returns the correct
  camera(−418,−248) and foot(538,336);14 source-level tests and independent review
  pass. Evidence: `candidate24-residual-replay/`.
- [x] Build Camera24 with the production camera fix and7,200-frame host tape.
  All19,163 recorded inputs remain unchanged during the successful build.
  All95 compiled camera/reader/presence/interaction tests pass with zero skips.
  Fresh1x and3x paired7,200-frame runs each pass every scene, authority, policy,
  fence and delivery check. Both moving traces have zero native holds and14,280
  poststartup pixels; neither has a host/view interval above two nominal frames.
  This validates the camera repair but does not supersede24's native workload
  failure or establish final matched-control acceptance. Preserve both runs at
  `camera24-host-peer-{1x,3x}-01` and their analyses.
- [x] Combined private25 map-lookup changes clear the exact healthy and
  first-fainted full-policy7,200-frame native cohorts:14,382 pixels and zero
  poststartup holds in each, with minimum callback margins+3,073/+1,926 cycles.
  Broader phases, vertical routes, party slots and final paired-app validation
  remain pending. Main still contains rejected24; nothing new is published.
- [x] Audit other native camera speeds before broadening the repair. Ordinary
  walking/running reach±16 with speed1/2 as supported. Bicycle/surf scenes are
  excluded by a pre-existing avatar guard before this decoder branch; native
  collision checks do not prove their app scene continuity. No captured ordinary
  phase justifies accepting larger/malformed remainders. Keep that scope limit.
- [x] Correct the QA timing report's nominal video.process interval at3x:
  that callback observes every native frame, while rendering observes every
  third. This changes diagnostic units only; all16 host gate tests pass.
- [x] Reject private25 after expanding native validation: eight7,200-frame
  full-policy cohorts pass, and one21,600-frame vertical cohort passes, but
  phase2047 reproduces a hold at13354. At critical13352 the matched inactive
  callback has+7,473 cycles; active has−735 under the exact same deadline.
  A later uncertain bitmap pair hides the2-pixel loss in naive aggregate totals;
  preserve prefix/hold evidence and do not call those totals parity.
- [x] Extend bounded full-host QA to21,600 frames and add the exact vertical
  lane x36/y20..22. Raise only the opt-in DEBUG trace cap to2,000,000 so its
  proportional allocation can retain every event; keep dropped-event rejection.
  Twelve analyzer tests pass, and all measurements from four retained1x/3x
  horizontal traces remain identical. Swift parsing and16 host gates pass;
  the expanded fixture still needs a new compiled simulator build.
- [x] Preserve private Soul identity-read experiments.888 compiled cases pass
  for aligned/packed identities and validated empty policies, but native savings
  are too small. A later clean replay changes audio/IRQ phase and cannot by
  itself establish a fix. Keep production Soul shim source unchanged.
- [x] Repair delivery source-integrity metadata for intentional QA observers:
  document the local patch, update only seven owned source hashes, and pin two
  new timing helpers. All nine files reconstruct exactly from their reviewed
  baseline; upstream versions/identities and unrelated pins stay unchanged.
  The maintained source gate verifies17,063 files. Clean Release verification
  and final upload still wait for final movement acceptance.
- [x] Validate private26's native renderer tail: replace three scheduling calls
  with the same three ordered native byte writes.672 differential cases,
  including72 write-boundary mutations, preserve data reads/writes, stack, ABI
  and flags; independent branch/interrupt review passes. Measured saving is102
  cycles per drawn tile. No policy, collision or scheduling write is removed.
- [x] Complete two64,800-frame26 replays with original production Soul code:
 129,600 frames and zero poststartup holds. Preserve two earlier roughly53,000
  frame runs as incomplete observer-budget stops, not passes or game failures.
  Separately cold-boot exact26, use native follower/warp/party setup, and pass
  another64,800-frame vertical fainted-party run plus five7,200-frame party/item
  cohorts:100,800 exact26 fresh-state frames, zero holds. Field41, special20
  (ledge/bicycle/surf), follower15 and27 decoder checks pass. Independent source
  reconstruction and the maintained129-record verifier remain pending.
- [x] Build the extended Long24 QA fixture with all19,164 inputs unchanged.
  Its first vertical600-frame paired XCTest passes, but the external checker
  still assumes row20 and rejects the valid vertical route. Keep that failed
  receipt; add axis-specific integer bounds and negative checks. A fresh repeat
  passes both peers' strict gates and the independent vertical analyzer:
  zero holds,1,080 poststartup pixels and the full32-pixel route. This validates
  the new fixture only; rejected24 does not become an accepted game candidate.
- [x] Finish candidate26 native acceptance and adopt frozen source on main:
  33,350 map/drawing pairs and220 mutation cases,1,170 presence,1,488 sprite,
  180 publication,471 UI,41 field,20 special-movement,15 follower and39
  composition/distribution tests pass. Independent uncached rebuild reproduces
  exact multiplayer bytes and the unchanged normal variant. Preserve complete
  evidence at `game-audit/candidate26-native-acceptance.json` and the23-file
  source receipt. No game commit, publication or upload has occurred.
- [x] Import exact26 ROM SHA256 `e5490e5c58ef86d55cc0d06052806ca727edc44c822d5240fb99d593af24ed43`
  and SHA1 `d245b88c8ad9fdc58ff9427f8cd4da3bfa8bd201` with the guarded-source
  manifest. Verify129 restoration records, unchanged data ABI and stable Soul
  query, complete current/legacy508 runtime admission, frozen historical
  profiles,13 profile-freeze tests, SDK rejection/primitive checks, both Soul
  shims and16 host gates. The new paired simulator build is next.

- [x] Build final candidate26 QA app and verify19,164 unchanged build inputs;
  preserve `candidate26-app-build-proof.json`. Run95 compiled camera/reader/
  presence regressions and63 compiled movement-authority regressions: all pass,
  zero skips. These are functional regression results, not cadence acceptance.
- [x] Preserve Release preflight01 failure on stale privacy-review source hashes.
  Review the three DEBUG-only observer additions: Release token sequences and
  privacy declarations are unchanged. Update only their reviewed hashes and
  rationale; derive a Release-only snapshot with exactly two metadata-file
  deltas from the frozen QA source. Release02 source/privacy preflight passes;
  the unsigned arm64 iPhone Release build and22 binary-path observer-exclusion
  checks pass. No DEBUG/timing macros remain in ordinary Release settings;
  frozen source inputs and unrelated main project changes are preserved.

- [x] Final26 cold-boot functional gate passes17 selected tests with zero skips:
  native berry effects, collision/TTL/map/menu/revocation and follower transactions.
  Preserve `candidate26-functional-01`. Battle attempt01 stops before gameplay
  because its A fixture lacks `seed.sav`; preserve failure, add a fresh all-FF
  task-only seed without overwriting data, and rerun in a new output directory.

- [x] Final26 Soul-denied full native battle passes both peers with damage,
  original-party restoration and cold-core/new-owner durable continuation.
  Fainted battle01 instead stops at frames163/162 after owner restoration.
  Trace the fixture: it intentionally disables Soul observation, then passes the
  disabled probe to a helper that reloads it with default observation enabled.
  Its native owner remains nil, so no friendly exclusion accompanies the reload;
  policy installation during the armed native battle is refused and pauses it.
  This pre-existing test lifecycle mismatch is not a candidate26 gameplay fix.
  Preserve the bounded interrupted failure; correct the fixture and rebuild QA.

- [x] Correct only the native-battle test helper to restore its actually attached
  Soul owner; assert owner identity after restoration. Rebuild QA2 with19,164
  unchanged inputs. Source-delta proof shows no production change, retaining
  the ordinary Release and95+63+17 functional evidence. Corrected fainted02
  completes both peers with combat, party restoration and durable continuation;
  Soul-denied03 also passes both peers, retaining the real attached-owner path.
  Native battle results verify combat, original parties and cold-owner recovery;
  no skipped case is accepted.

- [x] Final26 full-host matrix healthy1 group passes its7200-frame off control,
  two independent paired launches and enabled/no-peer launch: zero post-startup
  holds and zero active total/prefix progress deficit. Both paired repeats also
  have zero wall-clock intervals above two nominal periods in every reviewed
  native/process/handoff/per-view commit/completion stream. The remaining3x,
  long fainted and walking groups must still pass; this group is not acceptance.

- [x] Final matrix passes healthy3 off/peer and the21,600-frame vertical
  fainted1 off control, with zero native holds and no wall interval above two
  nominal periods. The matching paired run fails strict sustained authority:
  A is live with a nil scene at measured frame10,490, then loses host input/
  authority; B loses authority shortly afterward without a local reader failure.
  Both tests finish21,600 frames, no trace drops, no blocked Soul fence/callbacks,
  and no post-startup critical Soul change. A has43,080 post-startup pixels,
  zero native holds and zero total/prefix deficit; all18 friendship changes remain
  routine. Matrix's missing-gate/Soul-fence messages are cascading absent-summary
  fields after the authority exception, not measured Soul failures. Preserve
  `candidate26-final-host-matrix-01` as rejected overall, plus exact event window
  `candidate26-long-reader-failure.json`. Start an explicitly diagnostic long
  vertical repeat to capture the missing scene's RAM and cache decision.

- [x] Diagnostic vertical repeat captures one live/nil-scene failure at4,074
  (different native phase from the original10,490; not claimed byte-identical).
  Exact RAM and full actual-source decoder replay reproduce the failure before
  changes. Only the early animation-index guard fails: sprite command index255,
  animation20, valid16×32 shape/flags/position and camera residual0,0. Native
  SeekSpriteAnim(index0) writes index−1 before ContinueAnim wraps to0; animation
  and image-copy updates are not atomic. Retained copy-request history names old
  image11, while the new animation starts at image9, so guessing new frame0 is
  incorrect. The capture lacks prior appearance/OBJ VRAM; that provenance limit
  remains explicit. Implement scoped one-observation retention of the last fully
  verified player image, fresh palette/position and unchanged scene guards;
  add negative regressions and measured-window recovery counters before reruns.

- [x] Freeze the pending-player-image fix: same-scene/sprite identity, one
  pending observation, refresh only after a complete normal scene, fresh palette/
  OAM attributes, reset/refusal invalidation and unchanged camera/native bounds.
  Four maintained full-scene tests pass. Full captured-memory replay changes from
  nil scene to camera(−464,−264)/foot(584,352), oldimage11; the seeded prior image
  remains explicitly reconstructed from retained copy history, not captured VRAM.
  Before/after native banks are unchanged; cold/reset/repeated pending cases
  reject. Add DEBUG recovery counters at before/startup/end boundaries so final
  runtime acceptance can prove this path executes. QA3/Release rebuild and the
  full repeated simulator acceptance remain outstanding.

- [x] Image-fix QA build passes with all19,164 inputs unchanged;99 actual
  compiled camera/reader/presence/image regressions pass with zero skips. Fresh
  ordinary arm64 iPhone Release also passes source/privacy gates and22 binary
  inspections, with all QA observers/new image diagnostic counters absent.
  Begin full matrix02 from this exact frozen pair; no automatic retries or
  weakened thresholds. Final review additionally requires multiple actual
  post-startup image retentions including the long vertical route, zero image
  refusals, and clean wall-clock cadence—not just an aggregate pass flag.

- [x] Reject image-fix full matrix02 on the independent long3x paired repeat.
  The first ten cohorts pass, including one actual pending-image retention;
  the repeat exercises four retentions with no image refusal and every reader
  scene present, but A briefly withdraws host input/authority. Native progress
  still has zero holds and zero total/prefix loss; Soul counters/fences remain
  clean. Preserve the failed cohort and inspect the first authority transition
  before any further acceptance run. Missing downstream gate summaries are
  consequences of the strict authority exception, not proof of render/Soul loss.

- [x] Trace matrix02's terminal failure to fixture lifecycle: B completes51.10ms
  before A; its brief pause synchronously publishes an inactive reader, clears
  local presence and withdraws A's authority45.81ms later. A's only failures
  are frames21,599–21,600; no odd-writer chain, scene loss, native hold, timing
  gap or Soul fence occurs. Five actual image retentions across two cohorts
  have zero refusals, but the failed cohort remains excluded from acceptance.
  Keep the full frame owner running through the finished rendezvous and pause
  only after both measured tapes finish. Preserve end/pause timestamps; do not
  exclude final frames. This changes only the test fixture, not production.

- [x] Corrected fixture QA build passes with all19,164 inputs unchanged.
  Source delta from the Image build is only RecordedPlayerTests and this
  checklist, retaining the99 compiled regression and ordinary Release evidence.
  Preserve the first sandbox cache-access failure and successful authorized
  build02 separately. Start three targeted vertical3x cohorts:21,600-frame
  off control plus two independent paired runs with follower/Soul/fainted party.
  Keep all native/authority/render gates; require natural image-path exercise.

- [x] Targeted corrected-fixture vertical3x batch passes all three cohorts:
  108,000 native frames including stationary peers, no moving-player holds or
  total/prefix deficit, no authority/reader/render/Soul failures and no wall
  gap above two nominal periods. Both independent active A cohorts naturally
  exercise one pending-image retention after startup; all refusals remain zero.
  Each peer's final pause is strictly after both measured ends (minimum4.755ms).
  This establishes repeated actual execution of the image fix, including the
  long vertical path; it supplements rather than replaces the full matrix.
  Preserve `candidate26-targeted-vertical-image-host-01` and begin matrix03
  on the same frozen app/ROM with all13 original cohorts and unchanged gates.

- [x] Matrix03's first six healthy-party cohorts pass:1x off, two independent
  peers, no-peer, and3x off/peer. Zero post-startup moving holds/added total or
  prefix loss, no strict scene/authority/render/Soul failures, no wall interval
  above two nominal periods. Both-peer finish ordering passes throughout.
  One normal-speed peer naturally exercises image retention with no refusal,
  complementing the two targeted long-vertical recoveries. Long fainted and
  walking cohorts remain unfinished; these six passes are not final acceptance.

- [x] Full matrix03 passes all13 cohorts,248,400 native frames including both
  paired owners. All moving controls and active traces have zero post-startup
  holds and zero added total/prefix loss; every strict reader, authority,
  render-delivery and Soul gate passes. Independent review finds no wall gaps
  above two nominal periods and confirms every final pause follows both ends.
  The prior terminal-race cohort now completes all21,600 frames with authority.
  Matrix03 naturally exercises two image retentions across two independent
  paired A cohorts, with zero refusals. Together with the targeted vertical
  batch, four independent successful cohorts exercise the fix four times.
  Start final actual-native-bitmap comparisons:16 cases/57,600 frames across
  both axes, phases31/127, rates1x/3x, native versus far-peer controls.

- [x] Final horizontal bitmap execution passes all8 cases/28,800 frames:
  100% trainer/background confidence, zero mismatches/missing/overlay samples,
  and exactly zero total/prefix/held-pose difference in all four native/far
  comparisons. Each pair retains the same nine native startup holds and7,178px
  travel. The first checker invocation incorrectly selected result.json instead
  of its output directory; preserve that input-directory failure and wrapper
  result. Corrected `horizontal-check-02.json` verifies the same retained
  execution without rerunning it. Start vertical with the corrected invocation;
  aggregate final receipt will be `candidate26-final-bitmap-01/final-result.json`.

- [x] Final vertical bitmap execution and independent review pass all8 cases.
  Combined bitmap result is16 cases/57,600 frames with100% trainer/background
  confidence, zero uncertain/missing/overlay/mismatch samples, and exactly zero
  added total/prefix/held-pose difference in all eight comparisons. Vertical
  native/far pairs each retain one identical startup hold and7,194px travel.
  Exact ROM, source receipt and all24 compiled binary identities match the
  final host tests. Preserve both corrected check receipts, final-result.json
  and independent-review.json; no runtime threshold was weakened.

- [x] Cycle2 local movement acceptance is complete. The shipped pair's
  recurring continuous-input loss no longer reproduces in the final expanded
  native, full-owner paired and bitmap simulations. Earlier candidates remain
  rejected, including24/25 and the pre-image-fix matrix01. Candidate26 passes
  100,800 fresh exact-ROM and129,600 controlled native frames,356,400 final
  host frames and57,600 final bitmap frames. This establishes tested simulator
  behavior; it does not claim physical-device or WAN parity.
- [ ] Verify final source/stage boundaries; commit and push app to origin/main.
- [ ] Upload the validated app through manual Fastlane beta; verify Apple
  acceptance, processing and internal TestFlight availability separately.
- [ ] After compatible TestFlight availability, commit and push the exact game
  source; verify private Linode publication, read-back and build-counter receipt.
- [ ] Commit the final delivery record without duplicating an accepted upload.
- The first cycle's 48-case/86,400-frame simulation did not reproduce its
  earlier consecutive-frame freeze or presentation wobble, but its released
  input windows hid cumulative continuous-motion loss. That result is retained
  as historical evidence and is not final movement acceptance.
- Six first-batch absolute max-nine checks flag a native startup interval
  shared exactly by controls. Their failed receipts remain preserved; all
  second-batch strict checks pass. No checker threshold was weakened.
- Simulator execution cannot prove physical iPhone scanout, thermals or WAN
  smoothness. Retain these limits even after local acceptance.
