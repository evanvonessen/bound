# Offline playback and sharing validation

The table below is a historical component microbenchmark, not a comparison with the original Delta app. It uses a plain view controller and changes the viewport when the panel is shown. It omits the shipping app controller, native control layout, five-second warmup, and physical presentation measurements. Do not use its mean callback interval to claim equal smoothness.

The hosted `BoundIntegrationQA` suite runs the actual VBA-M GBA bridge with an original generated cartridge, Metal GameView rendering, the companion SwiftUI panel, detached frame capture, bounded publishing, outgoing CV pixel conversion, decoded-frame mailbox and retained UIImageView canvas. The injected loopback replaces Agora's engine, codec and network. These results do not prove phone scanout, live RTC behavior, thermals or subjective smoothness.

Eight six-second samples ran all four conditions twice, with the second pass in reverse order. Full samples and logs are kept in ignored `.build/verification/latest/benchmark-summary.json` and `integration-repeated.log`.

| Panel | Capture | Mean native callback gap (ms) | p95 gap range (ms) | Largest gap (ms) | Largest p95 owner tap cost (ms) |
|---|---|---:|---:|---:|---:|
| Hidden | Off | 16.680 | 22.51–23.22 | 25.10 | 0.0062 |
| Shown | Off | 16.688 | 21.91–22.43 | 25.32 | 0.0067 |
| Hidden | On | 16.679 | 21.81–23.01 | 25.47 | 0.0262 |
| Shown | On | 16.678 | 22.21–23.05 | 25.20 | 0.0317 |

No large repeatable native-timing regression appears in these short VM samples. One earlier shown/capture sample had a 33.77 ms gap; that outlier did not repeat here, so it is neither hidden nor attributed to a particular feature. Native callback timing measures core update callbacks, not physical display presentation. Capture plus mock publication averaged roughly 28 frames/s; only one send owned resources at a time. This is not SDK throughput evidence.

A deterministic source-jitter regression exposed a capture gate flaw: resetting deadlines to each source arrival admitted 248 of 600 callbacks at 60 Hz ±0.4 ms over ten seconds. Anchored deadlines now admit approximately 300 samples, discard missed slots after stalls and preserve single-flight/epoch ownership. The sharing publisher still enforces its own publication interval.

Other passing integration checks: exact detached RGBA preservation through the actual outgoing CV pool/mailbox/canvas; changing native animation pixels arriving at the canvas; padded-plane I420 conversion; a conversion finishing after stop being rejected; slow send/recovery/background/stop fencing; malformed canvas input preserving the existing image. No account, invite or live RTC engine was used.

## App-layer audit and targeted cleanup (2026-10-06)

The original Delta app revision is `c1d3d068e019e6493eed45654569db3cc5beb86a` (2.0b5/163), DeltaCore `633dfa86967816315fe19b482511dab1ce517f28`, GBADeltaCore `869c34aeca9dd2b3fbd329092bb2743b0ae80c98`, and VBA-M `453fa0decf179360926fb417725a794aa496d6e3`. Comparison against original Git objects found all 8 GBA bridge and 197 VBA-M runtime files identical. Native audio, ring buffer, bitmap renderer, GameView and render-thread scheduling also match their pins. This establishes provenance, not performance equivalence; Bound selects Metal for GBA and adds app-layer work.

The cleanup caches decoded control placements by their actual stored bytes, computes placed-skin identifiers once, and avoids rebuilding wrappers for unchanged geometry/style/placement. It cancels the Friends UI account observer on dismissal/background while preserving the active sharing identity checks. Numeric telemetry no longer invalidates the entire companion SwiftUI view, and invisible Friend content does not present images; the bounded receive mailbox and outgoing sharing remain active. Decoded-frame sampling and SDK diagnostic dictionaries compile out of Release. Ownership-sensitive frame copies and auth checks remain unchanged pending measurements.

Tests cover external placement edits/removal, rotation, save/reset, Controller Mode, stale observer callbacks and account-owner changes, hidden presentation with ongoing publication and prompt resume, exact I420 pixels and stale conversions, and slow-send/stop recovery. A Release iPhone archive additionally verifies the sampling symbol is absent from its matching dSYM. No emulator core, audio, native scheduler, dependency pin or transport behavior was changed by this cleanup.

## Actual-controller pacing harness

`PlaybackSharingTests.testActualAppAndNativeControllerPacing` compares the native DeltaCore controller (OpenGL and Metal) with the actual Bound app controller/coordinator in Classic and Bound arrangements. The native-controller baseline is **not the complete original Delta app**. Viewport and drawable dimensions are recorded so attribution can use matched Classic geometry; the Bound arrangement is a separate shipping-layout case.

Set `BOUND_APP_PACING` to `1` in the test target’s `EnvironmentVariables` in a copy of the generated `.xctestrun`, only in an exclusive VM timing slot after compilation. The test alternates order over three repeats, using the same original fixture, pinned GBA engine, configuration, device and 1x speed, five seconds of warmup and fifteen seconds of measurement per case. `BOUND_APP_PACING=smoke` only validates the harness; its short samples are explicitly marked and are not timing evidence. The default test suite skips this opt-in test. `BOUND_APP_PACING_MODES` selects a comma-separated subset of cases, and `BOUND_APP_PACING_REPEATS=1` allows an external runner to alternate separately built apps between repetitions. The harness refreshes controller settings after window attachment, selects touch controls, verifies running state and 1× speed, freezes callback collection before layout checks, and attaches post-measurement screenshots and raw timestamps.

The harness records core callbacks including the original app callback, main-runloop wakeups, settled-layout cost and drawable observations. Its test-only wrapper observes the drawable returned by the renderer's existing `nextDrawable` call; it does not acquire an extra drawable or alter the core. The iPhone SDK supports actual presented timestamps. The Simulator SDK omits that API, so simulator results are labeled **drawable acquisitions, not presentation**. Neither callback nor acquisition counts prove displayed/unique frames. Audio underruns, input-to-display latency, GPU/energy/thermal behavior and real network sharing still require separate measurements. The separate pinned-upstream app-runtime comparison below uses local compatibility packaging. No simulator result establishes physical-phone equivalence.

## Matched upstream app-runtime comparison (2026-10-06)

A separate baseline restores 347 original app/UI/framework files from the pinned Git objects listed above. Their bytes and symlink targets were rechecked before execution. Its app target excludes Bound-only sources and Agora linkage. It uses the current project/dependency compatibility packaging, so this is the pinned upstream app/core runtime, not an official distributed Delta binary. The comparison uses the actual app `GameViewController` in both builds, rather than the plain DeltaCore controller.

Both optimized Release builds used Xcode 27.0 (27A266a), arm64, testability enabled, iOS 27 Simulator, a 402×874-point portrait display, the same original diagnostic cartridge, visible native touch controls, and verified 1× speed. Sharing was off; Bound's offline Friend panel was visible. Stock upstream uses OpenGL; a second upstream case enables its existing Metal option to match Bound's renderer. Upstream and Bound Classic have identical gameplay `[0, 130.765333, 402, 268]` and controller `[0, 529.530667, 402, 344.469333]` rectangles. Bound arrangement moves gameplay to y=261.7875 while retaining its size. All Metal cases use 1206×804 drawables. Native screenshots confirm the control skins and rendered diagnostic output.

The simulator remained booted between cases. Measurement began only after three successive low-activity host checks; no compiler or separate automation appeared in the sampled process traces. Host load during the measured windows ranged from 2.20 to 5.05 on eight logical CPUs. Three paired repetitions alternated app order and reversed case order on the middle repetition. Each case had five seconds of warmup followed by fifteen seconds of measurement: twelve timed samples and 10,804 core callbacks in total. Smoke samples are excluded.

| Actual app / renderer | Mean callback gap range (ms) | p95 range (ms) | p99 range (ms) | Largest gap (ms) | Gaps >50 ms |
|---|---:|---:|---:|---:|---:|
| Upstream, stock OpenGL | 16.667–16.672 | 20.063–20.799 | 21.319–21.384 | 28.259 | 0 |
| Upstream, matched Metal | 16.666–16.668 | 19.024–19.926 | 20.275–20.762 | 23.665 | 0 |
| Bound Classic, Metal | 16.666–16.667 | 19.206–19.942 | 20.310–21.115 | 22.170 | 0 |
| Bound arrangement, Metal | 16.666–16.668 | 19.568–20.685 | 21.127–21.436 | 23.458 | 0 |

Bound Classic's paired p99 differences against upstream Metal ranged from −0.452 to +0.514 ms, without a consistent slowdown. Bound arrangement's p99 was 0.632–0.853 ms higher in all three pairs; its drawable-acquisition tails showed a similar small increase. Mean gaps were essentially unchanged. No case exceeded 50 ms; the stock-OpenGL run had the only gap above 25 ms. None of the investigation flags declared before measurement was triggered: repeated >1% mean slowdown, consistent >1 ms p95 or >2 ms p99 slowdown, or a repeated increase in >50 ms gaps. These flags are not an equivalence test, and the small consistent Bound-arrangement tail difference is retained rather than described as parity.

Thirty forced settled-layout passes after each timing window averaged 0.050–0.060 ms for upstream Metal, 0.142–0.173 ms for Bound Classic, and 0.242–0.317 ms for Bound arrangement. Bound therefore has measurable additional layout cost. These forced-pass measurements are not a per-frame cost estimate. The current data does not justify another runtime change solely to reduce this small absolute cost.

Full per-run summaries, paired differences, raw callback/drawable/main-loop timestamps, resource traces, screenshots, build hashes and harness snapshots are retained under ignored `.build/verification/matched-pacing/resumed/`; original-file hashes and preparation scripts are in its parent directory. Every raw trace count matches its summary. Earlier attempts remain preserved separately and are excluded: one assigned the game before skin loading had a window and measured mismatched geometry; another changed the launch order and failed core-startup assertions. The corrected app-runtime smoke, both existing native-controller smoke cases, and all six timed test invocations passed. The ordinary unsigned Release iPhone build also passed, with no QA launch markers or `ALTDeviceID` in the app.

This supports **no large pacing regression in this short portrait simulator workload**, not performance parity or physical-phone smoothness. It uses a lightweight diagnostic cartridge, three repetitions and compatibility-packaged upstream sources. Simulator drawable acquisitions are not displayed or unique frames. It does not measure landscape pacing, demanding commercial games, audio underruns, input latency, thermals/energy, physical scanout or live RTC sharing. The earlier native UI/rotation tests and offline sharing integration checks address separate functional behavior.
