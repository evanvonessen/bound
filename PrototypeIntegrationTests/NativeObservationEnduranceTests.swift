import XCTest
import CryptoKit
import Darwin
import DeltaCore
@testable import Delta

private struct EnduranceGame: GameProtocol {
    let fileURL: URL
    let gameSaveURL: URL
    var type: GameType { .gba }
}

/// Reads happen only on the native callback or the paused core owner. The raw
/// request is diagnostic: an odd publication never supplies counted frames.
private struct EnduranceFrameObservation {
    let raw: Data
    let decodedFrame: UInt32?
    let coreState: String
    static func capture(_ core: EmulatorCore) -> Self {
        // Exact current-profile UI request at EWRAM 0x02000800. VBA's public
        // memory API maps EWRAM to 0x8000; copy its borrowed buffer immediately.
        let borrowed = core.deltaCore.emulatorBridge.readMemory?(at: 0x8800, size: BoundSDKProtocol.UIRequest.byteSize)
        let raw = borrowed.map { Data([UInt8]($0)) } ?? Data()
        return .init(raw: raw, decodedFrame: MultiRedAdapter.readSetupRequest()?.frame,
                     coreState: String(describing: core.state))
    }
    var validHeader: Bool {
        raw.count == BoundSDKProtocol.UIRequest.byteSize && raw.prefix(8) == Data(BoundSDKProtocol.UIRequest.prefix)
    }
    var sequence: UInt32? { validHeader ? BoundSDKBytes.word(raw, BoundSDKProtocol.UIRequest.sequenceOffset) : nil }
    var rawFrame: UInt32? { validHeader ? BoundSDKBytes.word(raw, BoundSDKProtocol.UIRequest.frameOffset) : nil }
    var facts: [String: Any] {
        ["coreState": coreState, "rawByteCount": raw.count, "validHeader": validHeader,
         "sequence": sequence as Any? ?? NSNull(), "rawFrame": rawFrame as Any? ?? NSNull(),
         "decodedFrame": decodedFrame as Any? ?? NSNull(),
         "rawUIHex": raw.map { String(format: "%02x", $0) }.joined()]
    }
}

/// Fixed-size telemetry only. File encoding and writes happen on the paused/main
/// test owner. The first 64 exceptional reads plus the latest read are retained;
/// total deferred/invalid counters report any omitted diagnostic detail.
private final class EnduranceObserver: @unchecked Sendable {
    struct Reading {
        var callbacks: UInt64 = 0
        var nativeFrames: UInt64 = 0
        var observerNanoseconds: UInt64 = 0
        var maximumObserverNanoseconds: UInt64 = 0
        var invalidFrameReads: UInt64 = 0
        var deferredFrameReads: UInt64 = 0
        var frameReadAttempts: UInt64 = 0
        var lastAcceptedCallback: UInt64 = 0
        var awaitingCommit = false
        var frame: UInt32 = 0
    }
    private let lock = NSLock()
    private var value = Reading()
    private var exceptionalReads: [[String: Any]] = []
    private var lastRead: [String: Any] = [:]
    private let host: BoundROMMultiplayerProbe
    private let soul: BoundSoulProbe

    init(host: BoundROMMultiplayerProbe, soul: BoundSoulProbe, frame: UInt32) {
        self.host = host; self.soul = soul; value.frame = frame
    }
    func receive(_ core: EmulatorCore) {
        let start = DispatchTime.now().uptimeNanoseconds
        BoundFrameMemory.perform { host.receive(core); soul.receive(core) }
        let duration = DispatchTime.now().uptimeNanoseconds - start
        lock.lock()
        value.callbacks += 1
        value.observerNanoseconds += duration
        value.maximumObserverNanoseconds = max(value.maximumObserverNanoseconds, duration)
        let callback = value.callbacks
        let sampleFrame = callback % 60 == 0 || value.awaitingCommit
        lock.unlock()
        if sampleFrame {
            BoundFrameMemory.perform { recordBoundary(.capture(core), source: "nativeCallback", callback: callback) }
        }
    }
    /// VBA ends a video frame at VCOUNT160, independently of ROM uiPublish's
    /// odd/write/even transaction. An exact odd header is deferred to the next
    /// callback; it contributes zero frames. The existing 120-frame maximum and
    /// a 120-callback sampling deadline remain strict; neither permits a reset.
    func recordBoundary(_ observation: EnduranceFrameObservation, source: String, callback: UInt64) {
        lock.lock(); defer { lock.unlock() }
        value.frameReadAttempts += 1
        var facts = observation.facts
        facts["source"] = source; facts["callback"] = callback
        facts["previousCommittedFrame"] = value.frame
        facts["lastAcceptedCallback"] = value.lastAcceptedCallback
        func exceptional(_ reason: String, invalid: Bool) {
            facts["reason"] = reason
            if invalid { value.invalidFrameReads += 1 }
            if exceptionalReads.count < 64 { exceptionalReads.append(facts) }
            else { facts["earlierDiagnosticDetailOmitted"] = true }
        }
        defer { lastRead = facts }
        guard observation.validHeader else { exceptional("missingOrInvalidRawHeader", invalid: true); return }
        guard let sequence = observation.sequence, sequence != 0 else { exceptional("zeroSequence", invalid: true); return }
        guard callback >= value.lastAcceptedCallback, callback - value.lastAcceptedCallback <= 120 else {
            exceptional("committedReadCallbackDeadline", invalid: true); return
        }
        if sequence & 1 != 0 {
            guard observation.decodedFrame == nil else { exceptional("uncommittedFrameWasDecoded", invalid: true); return }
            value.deferredFrameReads += 1; value.awaitingCommit = true
            exceptional("uncommittedPublicationDeferred", invalid: false)
            return
        }
        guard let frame = observation.decodedFrame, frame == observation.rawFrame else {
            exceptional("committedAdapterReadMissingOrInconsistent", invalid: true); return
        }
        let delta = frame &- value.frame
        facts["committedDelta"] = delta
        guard delta <= 120 else { exceptional("committedCounterResetOrDiscontinuity", invalid: true); return }
        value.nativeFrames += UInt64(delta); value.frame = frame
        value.lastAcceptedCallback = callback; value.awaitingCommit = false
        facts["reason"] = "committed"
    }
    func read() -> Reading { lock.lock(); defer { lock.unlock() }; return value }
    func diagnostics() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["lastRead": lastRead, "exceptionalReads": exceptionalReads]
    }
}

@MainActor
final class NativeObservationEnduranceTests: XCTestCase {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private static let romSHA = "02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79"
    private static let gameID = "4b792d8f8b86e1a65b27965bb523fe0a48a20190"
    // Historical phase6 state is never reused after the callback-stack fix.
    // A fresh, independently reviewed native state supplies the runtime pin.
    private static let legacyStateSHA = "1c071561afc9fa518e4ef200d8077ef68eb076f5fa174ebb2001ecaf76e2bcfc"
    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func resources() throws -> (resident: UInt64, cpu: Double) {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var usage = rusage()
        try require(result == KERN_SUCCESS && getrusage(RUSAGE_SELF, &usage) == 0, "Process resource counters unavailable")
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return (UInt64(info.resident_size), cpu)
    }
    private func nativeRAM(_ core: EmulatorCore) throws -> Data {
        guard let memory = BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }) else {
            throw Failure("Native RAM snapshot unavailable at paused owner boundary")
        }
        return Data(memory.workRAM) + Data(memory.internalRAM)
    }

    private func frameObservation(sequence: UInt32, frame: UInt32, decoded: UInt32?) -> EnduranceFrameObservation {
        var raw = Data(repeating: 0, count: BoundSDKProtocol.UIRequest.byteSize)
        raw.replaceSubrange(0..<8, with: BoundSDKProtocol.UIRequest.prefix)
        BoundSDKBytes.put(sequence, into: &raw, at: BoundSDKProtocol.UIRequest.sequenceOffset)
        BoundSDKBytes.put(frame, into: &raw, at: BoundSDKProtocol.UIRequest.frameOffset)
        return .init(raw: raw, decodedFrame: decoded, coreState: "paused-test-fixture")
    }

    func testEnduranceAccountingDefersOddPublicationWithoutCountingIt() {
        let observer = EnduranceObserver(host: .init(), soul: .init(), frame: 1000)
        observer.recordBoundary(frameObservation(sequence: 5, frame: 1001, decoded: nil), source: "pausedFixture", callback: 60)
        XCTAssertEqual(observer.read().nativeFrames, 0)
        XCTAssertEqual(observer.read().frame, 1000)
        XCTAssertEqual(observer.read().invalidFrameReads, 0)
        XCTAssertEqual(observer.read().deferredFrameReads, 1)
        XCTAssertTrue(observer.read().awaitingCommit)
        observer.recordBoundary(frameObservation(sequence: 6, frame: 1002, decoded: 1002), source: "nextCallbackFixture", callback: 61)
        XCTAssertEqual(observer.read().nativeFrames, 2)
        XCTAssertEqual(observer.read().frame, 1002)
        XCTAssertFalse(observer.read().awaitingCommit)
        XCTAssertEqual(observer.read().invalidFrameReads, 0)
    }

    func testEnduranceAccountingRejectsResetMissingCommittedReadAndDiscontinuity() {
        for observation in [frameObservation(sequence: 6, frame: 0, decoded: 0),
                            frameObservation(sequence: 6, frame: 1121, decoded: 1121),
                            frameObservation(sequence: 6, frame: 1001, decoded: nil),
                            frameObservation(sequence: 0, frame: 1001, decoded: nil),
                            frameObservation(sequence: 5, frame: 1001, decoded: 1001),
                            EnduranceFrameObservation(raw: Data(), decodedFrame: nil, coreState: "fixture")] {
            let observer = EnduranceObserver(host: .init(), soul: .init(), frame: 1000)
            observer.recordBoundary(observation, source: "invalidFixture", callback: 60)
            XCTAssertEqual(observer.read().nativeFrames, 0)
            XCTAssertEqual(observer.read().frame, 1000)
            XCTAssertEqual(observer.read().invalidFrameReads, 1)
        }
        let observer = EnduranceObserver(host: .init(), soul: .init(), frame: 1000)
        observer.recordBoundary(frameObservation(sequence: 6, frame: 1120, decoded: 1120), source: "existingMaximumFixture", callback: 120)
        XCTAssertEqual(observer.read().nativeFrames, 120)
        XCTAssertEqual(observer.read().invalidFrameReads, 0)
    }

    func testEnduranceRequiresCommitWithinExistingCallbackDeadline() {
        let observer = EnduranceObserver(host: .init(), soul: .init(), frame: 1000)
        for callback in UInt64(60)...120 {
            observer.recordBoundary(frameObservation(sequence: 5, frame: 1001, decoded: nil),
                                    source: "uncommittedFixture", callback: callback)
        }
        XCTAssertEqual(observer.read().nativeFrames, 0)
        XCTAssertEqual(observer.read().invalidFrameReads, 0)
        observer.recordBoundary(frameObservation(sequence: 6, frame: 1002, decoded: 1002),
                                source: "lateCommitFixture", callback: 121)
        XCTAssertEqual(observer.read().nativeFrames, 0)
        XCTAssertEqual(observer.read().invalidFrameReads, 1)
        XCTAssertLessThanOrEqual((observer.diagnostics()["exceptionalReads"] as? [[String: Any]])?.count ?? 999, 64)
    }

    /// One hour of native field execution, not an hour of real-time multiplayer.
    /// This intentionally supplies no input, synthetic events, writer failures,
    /// networking, native activity, or private state from an ordinary user run.
    func testActualVBAHourKeepsObservationQueuesBoundedAcrossSixtyPauses() async throws {
        guard ProcessInfo.processInfo.environment["BOUND_NATIVE_OBSERVATION_ENDURANCE"] == "1" else {
            throw XCTSkip("Opt in with BOUND_NATIVE_OBSERVATION_ENDURANCE=1 on an exclusively owned simulator")
        }
        guard let expectedStateSHA = ProcessInfo.processInfo.environment["BOUND_NATIVE_ENDURANCE_STATE_SHA256"],
              expectedStateSHA.count == 64, expectedStateSHA.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              expectedStateSHA != Self.legacyStateSHA else {
            throw Failure("A fresh reviewed native state SHA256 is required; no historical state fallback")
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inputs = documents.appendingPathComponent("Phase10NativeEnduranceQA/input")
        let romURL = inputs.appendingPathComponent("current.gba"), stateURL = inputs.appendingPathComponent("observer.state")
        let rom = try Data(contentsOf: romURL, options: .mappedIfSafe), state = try Data(contentsOf: stateURL)
        try require(hash(rom) == Self.romSHA && hash(state) == expectedStateSHA, "Requires the exact approved current ROM and fresh native state pair")
        let profile = try MultiRedAdapter(rom: rom).profile
        try require(profile == BoundGameProfiles.current && profile.gameID == Self.gameID, "Exact current adapter profile required")
        let output = documents.appendingPathComponent("Phase10NativeEnduranceQA").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sampleURL = output.appendingPathComponent("samples.jsonl")
        try Data().write(to: sampleURL)
        let samples = try FileHandle(forWritingTo: sampleURL)
        defer { try? samples.close() }
        func append(_ value: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            bytes.append(10); try samples.write(contentsOf: bytes)
        }
        func write(_ value: [String: Any], _ name: String) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(name), options: .atomic)
        }
        let previousFeature = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer {
            UserDefaults.standard.set(previousFeature, forKey: BoundMultiplayerFeatures.key)
            NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
        }
        let battery = output.appendingPathComponent("work.sav")
        try Data(repeating: 0xFF, count: 131072).write(to: battery)
        guard let core = EmulatorCore(game: EnduranceGame(fileURL: romURL, gameSaveURL: battery), options: [.metal: true]) else {
            throw Failure("VBA core unavailable")
        }
        let gameID = "phase10-endurance-" + UUID().uuidString.lowercased(), soul = BoundSoulProbe(), host = BoundROMMultiplayerProbe()
        BoundServerMemoryFiles.setEnabled(true, for: gameID)
        try BoundServerMemoryFiles.restore([:], gameID: gameID)
        defer {
            _ = core.pause(); core.updateHandler = nil
            BoundVBABattleBridge.closeSoulLink(); _ = core.stop()
            // Only this test's unique RAM namespace and disposable core are released.
            try? BoundServerMemoryFiles.restore([:], gameID: gameID)
            BoundServerMemoryFiles.setEnabled(false, for: gameID)
        }
        let cycles = 60, framesPerCycle: UInt64 = 3600, warmupFrames: UInt64 = 600
        let rate = core.deltaCore.supportedRates.upperBound
        let frameSeconds = core.deltaCore.emulatorBridge.frameDuration
        let nominalWall = Double(UInt64(cycles) * framesPerCycle + warmupFrames) * frameSeconds / rate
        let wallLimit = nominalWall * 1.5 + 120
        core.audioManager.isEnabled = false; core.rate = rate
        var completedCycles = 0, sampleCount = 0
        let started = ProcessInfo.processInfo.systemUptime
        var residentSamples: [(seconds: Double, bytes: Double)] = []
        var measuredStart: EnduranceObserver.Reading?, measuredResources: (resident: UInt64, cpu: Double)?
        var observer: EnduranceObserver?
        try write(["version": 1, "status": "started", "pid": ProcessInfo.processInfo.processIdentifier,
            "romSHA256": Self.romSHA, "gameID": Self.gameID, "stateSHA256": expectedStateSHA,
            "cycles": cycles, "nativeFramesPerCycle": framesPerCycle, "warmupNativeFrames": warmupFrames,
            "rate": rate, "supportedRates": [core.deltaCore.supportedRates.lowerBound, rate],
            "nativeFrameSeconds": frameSeconds, "nominalWallSeconds": nominalWall, "wallLimitSeconds": wallLimit,
            "sampleIntervalWallSeconds": 1, "frameReadEveryCallbacks": 60,
            "frameAccounting": "Only committed UI-frame deltas count; an exact nonzero odd publication defers to the next callback with a 120-callback deadline and unchanged 120-frame delta limit. Paused raw bytes/RAM must remain identical.",
            "queueBound": 33, "queueBoundSource": "BoundSDKObservationPipeline default capacity32 plus one retained handoff",
            "fixtureProvenance": "Fresh independently reviewed current-ROM actual VBA idle field state with one live starter; exact input pin supplied by the isolated runner; no state conversion",
            "scope": "Local stationary field, active Soul observation, RAM backing store, accelerated native CPU; no network, audio, UI rendering view, input, fault injection, or paired-session claim",
            "memoryAcceptance": "Report all RSS samples and trend; no arbitrary RSS threshold. Queue, retained model, and backing-store growth have exact invariant checks."], "configuration.json")
        do {
            try require(core.deltaCore.identifier == "com.rileytestut.GBADeltaCore" && rate >= 1 && frameSeconds > 0, "Unsupported native core/rate")
            try BoundROMMultiplayerCoordinator.prepareServerCoreForSelection(core)
            core.deltaCore.emulatorBridge.audioRenderer = nil
            try require(MultiRedAdapter.restoreState(state), "Frozen actual VBA state rejected")
            try require(soul.configure(core: core, url: output.appendingPathComponent("Soul Link/run.json"), gameID: gameID), "Soul owner could not bind")
            soul.setVerified(true); soul.setPreviewEnabled(true)
            host.configure(core: core); host.setVerified(true)
            var value = BoundROMHostState(); value.enabled = true; value.ended = true; value.status = .complete
            host.publish(value); host.receive(core)
            try soul.prepareCheckpoint(core: core)
            try soul.startPreparedRun(run: UUID(), binding: String(repeating: "a", count: 64))
            try soul.prepareCheckpoint(core: core)
            guard let initialFrame = MultiRedAdapter.readSetupRequest()?.frame else { throw Failure("Native UI frame unavailable") }
            let driver = EnduranceObserver(host: host, soul: soul, frame: initialFrame); observer = driver
            core.updateHandler = { core in driver.receive(core) }
            var nextSample = ProcessInfo.processInfo.systemUptime
            func sample(_ kind: String, cycle: Int) throws {
                let time = ProcessInfo.processInfo.systemUptime - started, reading = driver.read(), resource = try resources()
                let metrics = soul.observationMetrics(), snapshot = soul.read(), timeline = soul.timeline.read()
                let memory = BoundServerMemoryFiles.snapshot(gameID: gameID)
                let row: [String: Any] = ["sample": sampleCount, "kind": kind, "cycle": cycle, "wallSeconds": time,
                    "residentBytes": resource.resident, "processCPUSeconds": resource.cpu,
                    "callbacks": reading.callbacks, "nativeFrames": reading.nativeFrames, "nativeUIFrame": reading.frame,
                    "observerNanoseconds": reading.observerNanoseconds, "maximumObserverNanoseconds": reading.maximumObserverNanoseconds,
                    "invalidFrameReads": reading.invalidFrameReads, "deferredFrameReads": reading.deferredFrameReads,
                    "frameReadAttempts": reading.frameReadAttempts, "awaitingCommittedFrame": reading.awaitingCommit,
                    "lastAcceptedCallback": reading.lastAcceptedCallback, "worker": metrics,
                    "ledgerRecords": snapshot.ledger?.records.count ?? 0, "sharedFacts": soul.sharedEvents().count,
                    "timelineEvents": timeline.events.count, "memoryFileCount": memory.count,
                    "memoryFileBytes": memory.values.reduce(0) { $0 + $1.count },
                    "observationError": snapshot.error as Any? ?? NSNull(), "timelineError": timeline.error as Any? ?? NSNull(),
                    "coreState": String(describing: core.state)]
                try append(row); sampleCount += 1
                residentSamples.append((time, Double(resource.resident)))
                try require(snapshot.error == nil && timeline.error == nil, "Observation/history error; no automatic retry hides a failed fence")
                try require(reading.invalidFrameReads == 0, "Native frame counter missing, reset, or discontinuous")
                try require(metrics["highWater", default: 0] <= 33 && metrics["rejected", default: 0] == 0, "Observation FIFO bound/admission failed")
            }
            func run(until target: UInt64, cycle: Int) async throws {
                try require(core.state == .paused && core.resume(), "Normal core resume failed")
                var lastProgress = ProcessInfo.processInfo.systemUptime, lastFrames = driver.read().nativeFrames
                while driver.read().nativeFrames < target {
                    try Task.checkCancellation()
                    let now = ProcessInfo.processInfo.systemUptime
                    if now >= nextSample { try sample("running", cycle: cycle); nextSample = now + 1 }
                    try require(core.state == .running, "Native execution paused unexpectedly")
                    try require(now - started < wallLimit, "Bounded wall deadline reached before native horizon")
                    let frames = driver.read().nativeFrames
                    if frames != lastFrames { lastFrames = frames; lastProgress = now }
                    try require(now - lastProgress < 15, "Native frames stopped advancing")
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            try await run(until: warmupFrames, cycle: -1)
            try require(core.pause(), "Warmup pause failed"); try soul.prepareCheckpoint(core: core)
            driver.recordBoundary(.capture(core), source: "warmupPaused", callback: driver.read().callbacks)
            let baseline = soul.read(), timeline = soul.timeline.read().events, events = soul.sharedEvents()
            let backing = BoundServerMemoryFiles.snapshot(gameID: gameID)
            let native = BoundVBABattleBridge.soulLinkSnapshot()
            guard let baselineLedger = baseline.ledger, baselineLedger.valid, !baselineLedger.ended,
                  baseline.ready, baselineLedger.records.count == 1,
                  let party = native["party"] as? Data, let boxes = native["boxes"] as? Data else {
                throw Failure("Fixture must contain one observed live starter and an active valid ledger")
            }
            try require(boxes.count == 43500 && !baseline.partyWipedOut && !events.isEmpty, "Populated native observation fixture required")
            measuredStart = driver.read(); measuredResources = try resources()
            let baselineMetrics = soul.observationMetrics()
            let initialState = MultiRedAdapter.captureState()
            try require(!initialState.isEmpty, "Initial actual VBA state capture failed")
            try initialState.write(to: output.appendingPathComponent("initial.state"))
            try sample("baseline", cycle: -1); try samples.synchronize()
            for cycle in 0..<cycles {
                let before = driver.read(), target = before.nativeFrames + framesPerCycle
                try await run(until: target, cycle: cycle)
                let pauseStart = DispatchTime.now().uptimeNanoseconds
                try require(core.pause(), "Repeated normal pause failed")
                let paused = DispatchTime.now().uptimeNanoseconds
                let preDrainMetrics = soul.observationMetrics()
                try soul.prepareCheckpoint(core: core, timeout: 5)
                let drained = DispatchTime.now().uptimeNanoseconds
                let pausedUI = EnduranceFrameObservation.capture(core)
                driver.recordBoundary(pausedUI, source: "checkpointPaused", callback: driver.read().callbacks)
                let current = soul.read(), metrics = soul.observationMetrics(), currentNative = BoundVBABattleBridge.soulLinkSnapshot()
                let ram = try nativeRAM(core), ramHash = hash(ram)
                let pausedCoreState = String(describing: core.state)
                try await Task.sleep(for: .milliseconds(25))
                let heldRAMHash = hash(try nativeRAM(core)), heldUI = EnduranceFrameObservation.capture(core)
                let coreStillPaused = core.state == .paused
                let uiUnchanged = pausedUI.raw == heldUI.raw && pausedUI.decodedFrame == heldUI.decodedFrame
                let ramUnchanged = heldRAMHash == ramHash
                let pauseHeld = coreStillPaused && uiUnchanged && ramUnchanged
                let stableModel = current.ledger == baselineLedger && soul.sharedEvents() == events && soul.timeline.read().events == timeline
                let stableBacking = BoundServerMemoryFiles.snapshot(gameID: gameID) == backing
                let stableNative = currentNative["party"] as? Data == party && currentNative["boxes"] as? Data == boxes
                try append(["kind": "pause", "cycle": cycle, "pauseNanoseconds": paused - pauseStart,
                    "drainNanoseconds": drained - paused, "nativeFrames": driver.read().nativeFrames - before.nativeFrames,
                    "preDrainWorker": preDrainMetrics, "postDrainWorker": metrics, "ramSHA256": ramHash,
                    "heldRAMSHA256": heldRAMHash, "pausedCoreState": pausedCoreState,
                    "coreStillPaused": coreStillPaused, "rawUIUnchanged": uiUnchanged, "ramUnchanged": ramUnchanged,
                    "pausedUI": pausedUI.facts, "heldUI": heldUI.facts, "frameDiagnostics": driver.diagnostics(),
                    "pauseHeld": pauseHeld, "modelUnchanged": stableModel, "backingUnchanged": stableBacking,
                    "nativePartyAndBoxesUnchanged": stableNative])
                try sample("drained", cycle: cycle); try samples.synchronize()
                try require(pauseHeld && stableModel && stableBacking && stableNative, "Paused native/model/backing invariants changed")
                try require(current.ready && !current.partyWipedOut && current.error == nil, "Field ledger became invalid")
                try require(metrics["queued"] == 0 && metrics["admitted"] == metrics["reduced"], "Successful checkpoint left accepted observations undrained")
                try require(metrics["blockedCallbacks"] == baselineMetrics["blockedCallbacks"], "Ordinary endurance crossed a failed/pressure fence")
                try require(driver.read().nativeFrames - before.nativeFrames >= framesPerCycle, "Callbacks were counted without the required actual native frames")
                completedCycles += 1
            }
            let final = driver.read(), start = measuredStart!, finalResources = try resources(), resourceStart = measuredResources!
            try require(final.nativeFrames - start.nativeFrames >= UInt64(cycles) * framesPerCycle, "Full native horizon missing")
            try require(hash(try Data(contentsOf: romURL, options: .mappedIfSafe)) == Self.romSHA && hash(try Data(contentsOf: stateURL)) == expectedStateSHA, "Fixture input bytes changed")
            let finalState = MultiRedAdapter.captureState()
            try require(!finalState.isEmpty, "Final actual VBA state capture failed")
            try finalState.write(to: output.appendingPathComponent("final.state"))
            try JSONEncoder().encode(BoundServerMemoryFiles.snapshot(gameID: gameID)).write(to: output.appendingPathComponent("final-memory.json"))
            let meanTime = residentSamples.map(\.seconds).reduce(0, +) / Double(residentSamples.count)
            let meanBytes = residentSamples.map(\.bytes).reduce(0, +) / Double(residentSamples.count)
            let numerator = residentSamples.reduce(0.0) { $0 + ($1.seconds - meanTime) * ($1.bytes - meanBytes) }
            let denominator = residentSamples.reduce(0.0) { $0 + pow($1.seconds - meanTime, 2) }
            try write(["status": "passed", "completedCycles": completedCycles, "resourceSamples": sampleCount,
                "actualNativeFrames": final.nativeFrames - start.nativeFrames,
                "emulatedSecondsAtNominalRate": Double(final.nativeFrames - start.nativeFrames) * frameSeconds,
                "wallSecondsIncludingWarmupAndPauses": ProcessInfo.processInfo.systemUptime - started,
                "processCPUSecondsAfterWarmup": finalResources.cpu - resourceStart.cpu,
                "residentStartBytes": resourceStart.resident, "residentEndBytes": finalResources.resident,
                "residentPeakBytes": residentSamples.map(\.bytes).max() ?? 0,
                "allSamplesResidentLinearSlopeBytesPerWallSecond": denominator > 0 ? numerator / denominator : 0,
                "memoryVerdict": "Measurement only; review complete samples and slope. Exact queue/model/backing growth invariants passed.",
                "worker": soul.observationMetrics(), "actualCallbacks": final.callbacks - start.callbacks,
                "deferredFrameReads": final.deferredFrameReads, "frameDiagnostics": driver.diagnostics(),
                "observerNanoseconds": final.observerNanoseconds - start.observerNanoseconds,
                "limitations": "Stationary local actual VBA; no UI view/audio/network/remote stale-session or physical-device long-play evidence."], "result.json")
        } catch {
            let stateBeforeFailurePause = String(describing: core.state)
            let failurePauseReturned = core.pause()
            var failureNative: [String: Any] = ["stateBeforePause": stateBeforeFailurePause,
                "pauseReturned": failurePauseReturned, "stateAfterPause": String(describing: core.state)]
            if core.state == .paused {
                failureNative["ui"] = EnduranceFrameObservation.capture(core).facts
                if let bytes = try? nativeRAM(core) {
                    failureNative["ramSHA256"] = hash(bytes)
                    try? bytes.write(to: output.appendingPathComponent("failure-ram.bin"), options: .atomic)
                }
                let bytes = MultiRedAdapter.captureState()
                failureNative["stateBytes"] = bytes.count
                if !bytes.isEmpty {
                    failureNative["stateSHA256"] = hash(bytes)
                    try? bytes.write(to: output.appendingPathComponent("failure.state"), options: .atomic)
                }
            }
            try? write(["native": failureNative, "frames": observer?.diagnostics() ?? [:]], "failure-diagnostics.json")
            try? append(["kind": "failure", "errorType": String(reflecting: type(of: error)), "error": String(describing: error),
                "completedCycles": completedCycles, "worker": soul.observationMetrics(),
                "nativeFrames": observer?.read().nativeFrames ?? 0, "coreState": String(describing: core.state)])
            try? samples.synchronize()
            try? write(["status": "failed", "completedCycles": completedCycles, "resourceSamples": sampleCount,
                "errorType": String(reflecting: type(of: error)), "error": String(describing: error),
                "wallSeconds": ProcessInfo.processInfo.systemUptime - started], "result.json")
            throw error
        }
    }
}
