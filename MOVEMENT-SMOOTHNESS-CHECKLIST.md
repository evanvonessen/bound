# Multiplayer movement smoothness

Updated October 29, 2026. Work on `main`; evidence lives in
`../artifacts/multiplayer-isolation/movement-smoothness-20261029/`.

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

## Unresolved / limits

- The recurring consecutive-frame freeze and presentation wobble do not
  reproduce in the final 48-case/86,400-frame simulation. Native movement is
  not pixel-for-pixel identical with multiplayer enabled: 23–33 additional
  isolated one-frame holds per 1,800 frames remain (2.32–3.36 percentage points
  among eligible moving pairs). The declared repeated input loop loses no
  progress; this does not establish arbitrary continuous-route speed parity.
- Six first-batch absolute max-nine checks flag a native startup interval
  shared exactly by controls. Their failed receipts remain preserved; all
  second-batch strict checks pass. No checker threshold was weakened.
- Simulator execution cannot prove physical iPhone scanout, thermals or WAN
  smoothness. Retain these limits even after local acceptance.
