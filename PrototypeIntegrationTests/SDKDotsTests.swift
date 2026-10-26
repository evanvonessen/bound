import XCTest
import DeltaCore
@testable import Delta

@MainActor private final class DotsTransport: BoundSDKDotsTransport {
    var packets: [Data] = []
    var fails = false
    func send(_ bytes: Data) throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        packets.append(bytes)
    }
    func take() -> [Data] { defer { packets.removeAll() }; return packets }
}
@MainActor private final class DotsStore: BoundSDKDotsPersistence {
    var bytes: Data?
    var fails = false
    func load() throws -> Data? { bytes }
    func commit(_ bytes: Data, replacing expected: Data?) throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        guard self.bytes == expected else { throw CocoaError(.fileWriteUnknown) }
        self.bytes = bytes
    }
}
@MainActor private final class DotsNoDurability: BoundSDKDotsDurability {
    let storageContract = "unavailable"
    func persistAndVerify(_ event: BoundSDKEvent) throws -> Bool { false }
}
private struct DotsGame: GameProtocol {
    let fileURL, gameSaveURL: URL
    var type: GameType { System.gba.gameType }
}

@MainActor final class SDKDotsTests: XCTestCase {
    private let run = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let owner = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let peer = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!

    private func modelSnapshot(emitted: UInt32 = 0, applied: UInt32 = 0, generation: UInt32 = 1, reversed: Bool = false) -> BoundSDKDotsAdapter.Snapshot {
        .init(sequence: 2, flags: 0, x: 40, y: 72, frame: 1, pending: emitted, emitted: emitted, durable: 0,
            peerApplied: applied, peerCount: applied, generation: generation, hostSequence: 2, receipt: 0, rejected: 0,
            journalRevision: 1, run: run, owner: reversed ? peer : owner, peer: reversed ? owner : peer)
    }
    private func runtime(store: BoundSDKDotsPersistence, transport: DotsTransport, durability: BoundSDKDotsDurability? = nil,
                         reversed: Bool = false) throws -> BoundSDKDotsRuntime {
        try BoundSDKDotsRuntime(run: run, owner: reversed ? peer : owner, peer: reversed ? owner : peer,
            persistence: store, transport: transport, durability: durability ?? DotsNoDurability())
    }
    private func deliver(_ transport: DotsTransport, to target: BoundSDKDotsRuntime, from source: UUID, now: TimeInterval = 1) throws {
        for packet in transport.take() { _ = try target.receive(packet, admittedPeer: source, token: target.callbackToken, now: now) }
    }
    private func handshake(_ a: BoundSDKDotsRuntime, _ at: DotsTransport, _ b: BoundSDKDotsRuntime, _ bt: DotsTransport) throws {
        try a.hello(); try deliver(at, to: b, from: owner)
        try b.hello(); try deliver(bt, to: a, from: peer)
        try a.hello(); try deliver(at, to: b, from: owner)
    }

    func testReceiptDoesNotMeanNativeApplicationOrDurability() throws {
        let at = DotsTransport(), bt = DotsTransport()
        let a = try runtime(store: DotsStore(), transport: at)
        let b = try runtime(store: DotsStore(), transport: bt, reversed: true)
        try handshake(a, at, b, bt)
        try a.observe(modelSnapshot(emitted: 1)); try a.replay()
        try deliver(at, to: b, from: owner); try deliver(bt, to: a, from: peer)
        let id = BoundSDKEvent.ID(origin: owner, sequence: 1)
        XCTAssertTrue(a.state.journal.acknowledged.contains(id))
        XCTAssertTrue(b.state.journal.received.contains(id))
        XCTAssertFalse(b.state.journal.applied.contains(id))
        XCTAssertFalse(a.state.durable.contains(id))
        try a.persistPending()
        XCTAssertFalse(a.state.durable.contains(id))
        let host = try a.host(for: modelSnapshot(emitted: 1), now: 1)
        XCTAssertEqual(BoundSDKBytes.word(host, 132), 0)
        XCTAssertEqual(BoundSDKBytes.word(host, 136), 1)
    }

    func testPersistenceFailureRetainsOutboxAndReconnectRejectsOldCallback() throws {
        let store = DotsStore(), transport = DotsTransport()
        let a = try runtime(store: store, transport: transport)
        store.fails = true
        XCTAssertThrowsError(try a.observe(modelSnapshot(emitted: 1)))
        XCTAssertEqual(a.state.journal.nextSequence, 1)
        store.fails = false
        try a.observe(modelSnapshot(emitted: 1))
        transport.fails = true; XCTAssertThrowsError(try a.replay())
        XCTAssertEqual(a.state.journal.events.count, 1)
        transport.fails = false
        let oldToken = a.callbackToken, generation = a.state.hostGeneration
        try a.reconnect()
        XCTAssertEqual(a.state.hostGeneration, generation + 1)
        XCTAssertEqual(a.state.journal.nextSequence, 2)
        XCTAssertFalse(try a.receive(Data(), admittedPeer: peer, token: oldToken, now: 1))
        let newTransport = DotsTransport()
        let reopened = try runtime(store: store, transport: newTransport)
        XCTAssertEqual(reopened.state.hostGeneration, generation + 2)
        XCTAssertEqual(reopened.state.journal.events, a.state.journal.events)
        XCTAssertThrowsError(try a.reconnect(), "A retired runtime cannot overwrite the new generation")
        XCTAssertThrowsError(try a.host(for: modelSnapshot(emitted: 1), now: 2))
        let oldPacketCount = transport.packets.count, oldState = a.state
        XCTAssertThrowsError(try a.hello())
        XCTAssertThrowsError(try a.publishPresence(x: 90, y: 70))
        XCTAssertEqual(transport.packets.count, oldPacketCount, "Retired metadata must not reach the transport")
        XCTAssertEqual(a.state, oldState)
        let peerTransport = DotsTransport()
        let peerRuntime = try runtime(store: DotsStore(), transport: peerTransport, reversed: true)
        try handshake(reopened, newTransport, peerRuntime, peerTransport)
        try reopened.publishPresence(x: 91, y: 71)
        XCTAssertEqual(newTransport.packets.count, 1, "The new persisted owner still handshakes and sends")
    }

    func testSparsePeerReceiptWaitsForGapAndDuplicateIsIdempotent() throws {
        let at = DotsTransport(), bt = DotsTransport(), store = DotsStore()
        let a = try runtime(store: store, transport: at)
        let b = try runtime(store: DotsStore(), transport: bt, reversed: true)
        try handshake(a, at, b, bt)
        // A synthetic admitted peer exercises the actual envelope and SDK journal path.
        try b.hello()
        let hello = try XCTUnwrap(BoundSDKReliableEnvelope.decode(try XCTUnwrap(bt.take().first)))
        func eventFrame(_ pulse: UInt64, wireSequence: UInt64) throws -> Data {
            let event = BoundSDKEvent(run: run, id: .init(origin: peer, sequence: pulse),
                kind: BoundSDKDotsRuntime.pulseKind, payload: BoundSDKDotsRuntime.pulsePayload, idempotencyKey: nil)
            struct Packet: Encodable { let profile: String; let run: UUID; let event: BoundSDKEvent }
            return try XCTUnwrap(BoundSDKReliableEnvelope(kind: 2, owner: peer, epoch: hello.epoch,
                receiver: hello.receiver, sequence: wireSequence,
                body: JSONEncoder().encode(Packet(profile: BoundSDKDotsAdapter.sha256, run: run, event: event))).encoded())
        }
        let second = try eventFrame(2, wireSequence: hello.sequence + 1)
        XCTAssertFalse(try a.receive(second, admittedPeer: UUID(), token: a.callbackToken, now: 1))
        XCTAssertTrue(try a.receive(second, admittedPeer: peer, token: a.callbackToken, now: 1))
        XCTAssertEqual(BoundSDKBytes.word(try a.host(for: modelSnapshot(), now: 1), 128), 0)
        let first = try eventFrame(1, wireSequence: hello.sequence + 2)
        XCTAssertTrue(try a.receive(first, admittedPeer: peer, token: a.callbackToken, now: 1))
        XCTAssertEqual(BoundSDKBytes.word(try a.host(for: modelSnapshot(), now: 1), 128), 1)
        XCTAssertFalse(try a.receive(first, admittedPeer: peer, token: a.callbackToken, now: 1))
        XCTAssertTrue(try a.receive(eventFrame(1, wireSequence: hello.sequence + 3), admittedPeer: peer, token: a.callbackToken, now: 1))
        XCTAssertEqual(a.state.journal.events.count, 2)
        try a.observe(modelSnapshot(applied: 1))
        XCTAssertTrue(a.state.journal.applied.contains(.init(origin: peer, sequence: 1)))
        XCTAssertFalse(a.state.journal.applied.contains(.init(origin: peer, sequence: 2)))
        XCTAssertEqual(BoundSDKBytes.word(try a.host(for: modelSnapshot(applied: 1), now: 1), 128), 2)
        // A restored earlier native checkpoint still replays retained host history.
        XCTAssertEqual(BoundSDKBytes.word(try a.host(for: modelSnapshot(), now: 1), 128), 1)
    }

    func testPresenceExpiryAndExplicitPauseAreIndependent() throws {
        let at = DotsTransport(), bt = DotsTransport()
        let a = try runtime(store: DotsStore(), transport: at), b = try runtime(store: DotsStore(), transport: bt, reversed: true)
        try handshake(a, at, b, bt)
        try b.publishPresence(x: 88, y: 64); try deliver(bt, to: a, from: peer)
        let live = try a.host(for: modelSnapshot(), now: 1)
        XCTAssertEqual(BoundSDKBytes.word(live, 120), 1)
        XCTAssertEqual(BoundSDKBytes.word(live, 112), 88)
        let stale = try a.host(for: modelSnapshot(), now: 5, paused: true)
        XCTAssertEqual(BoundSDKBytes.word(stale, 120), 0)
        XCTAssertEqual(BoundSDKBytes.word(stale, 140), 1)
        XCTAssertEqual(BoundSDKBytes.word(try a.host(for: modelSnapshot(), now: 6), 140), 0)
    }

    func testExactProfileAndStoredOwnershipFailClosed() throws {
        XCTAssertThrowsError(try BoundSDKDotsAdapter.admit(Data(repeating: 0, count: 2602)))
        let store = DotsStore(); _ = try runtime(store: store, transport: DotsTransport())
        XCTAssertThrowsError(try runtime(store: store, transport: DotsTransport(), reversed: true))
        var invalid = try JSONDecoder().decode(BoundSDKDotsRuntime.State.self, from: XCTUnwrap(store.bytes))
        invalid.hostGeneration = BoundSDKDotsAdapter.maximum
        store.bytes = try JSONEncoder().encode(invalid)
        XCTAssertThrowsError(try runtime(store: store, transport: DotsTransport()))
    }

    func testReplayIsBoundedAndLocalArchiveRejectsChangedImmutableEvent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SDKDots-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DotsStore(), transport = DotsTransport()
        let archive = BoundSDKDotsLocalArchive(directory: directory)
        var state = BoundSDKDotsRuntime.State(journal: .init(run: run, owner: owner, partner: peer), durabilityContract: archive.storageContract)
        for index in 1...20 {
            _ = try BoundSDKEventJournalRules.append(kind: BoundSDKDotsRuntime.pulseKind, payload: BoundSDKDotsRuntime.pulsePayload,
                idempotencyKey: "pulse:\(index)", to: &state.journal)
        }
        store.bytes = try JSONEncoder().encode(state)
        let runtime = try runtime(store: store, transport: transport, durability: archive)
        try runtime.replay()
        XCTAssertEqual(transport.take().count, BoundSDKDotsRuntime.replayBatch)
        try runtime.persistPending()
        XCTAssertEqual(runtime.state.durable.origins[owner.uuidString]?.contiguous, 16)
        try runtime.persistPending()
        XCTAssertEqual(runtime.state.durable.origins[owner.uuidString]?.contiguous, 20)
        let first = try XCTUnwrap(state.journal.events.first)
        XCTAssertTrue(try archive.persistAndVerify(first))
        var altered = first; altered.idempotencyKey = "changed"
        XCTAssertThrowsError(try archive.persistAndVerify(altered))
        let reopened = try self.runtime(store: store, transport: DotsTransport(), durability: archive)
        XCTAssertEqual(reopened.state.durable, runtime.state.durable)
    }

    /// Opt-in: root stages only the audited homebrew, never an ordinary cartridge/save.
    /// One real VBA core plus an injected peer. This is not a two-device/network test.
    func testActualVBAIndependentInputPulsePersistenceAndOwnerGeneration() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let input = ProcessInfo.processInfo.environment["BOUND_SDK_DOTS_ROM"].map { URL(fileURLWithPath: $0) }
            ?? documents.appendingPathComponent("SDKDots/sdk-dots.gba")
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("Stage exact SDK Dots artifact at Documents/SDKDots/sdk-dots.gba or BOUND_SDK_DOTS_ROM") }
        let romBytes = try Data(contentsOf: input); try BoundSDKDotsAdapter.admit(romBytes)
        let directory = documents.appendingPathComponent("SDKDots/results/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rom = directory.appendingPathComponent("sample.gba"), battery = directory.appendingPathComponent("sample.sav")
        try romBytes.write(to: rom); try Data(repeating: 0xff, count: 32768).write(to: battery)
        try BoundSDKDotsCore.prepareForStart()
        let core = try XCTUnwrap(EmulatorCore(game: DotsGame(fileURL: rom, gameSaveURL: battery), options: [.metal: true]))
        core.audioManager.isEnabled = false
        XCTAssertTrue(core.start()); XCTAssertTrue(core.pause())
        defer { core.deltaCore.emulatorBridge.resetInputs(); _ = core.stop() }
        let port = try BoundSDKDotsCore(core: core)
        defer { port.release() }
        func frames(_ count: Int) { for _ in 0..<count { core.deltaCore.emulatorBridge.runFrame(processVideo: false) } }
        func press(_ mask: Int, count: Int = 4) {
            core.deltaCore.emulatorBridge.activateInput(mask, value: 1, playerIndex: 0)
            frames(count)
            core.deltaCore.emulatorBridge.deactivateInput(mask, playerIndex: 0)
            frames(2)
        }
        frames(8)
        let initial = try port.read()
        press(16, count: 8)
        XCTAssertGreaterThan(try port.read().x, initial.x, "D-pad progresses before any transport or host binding")
        let at = DotsTransport(), bt = DotsTransport()
        let store = BoundSDKDotsFilePersistence(url: directory.appendingPathComponent("host-journal.json"))
        let archive = BoundSDKDotsLocalArchive(directory: directory.appendingPathComponent("pulse-archive"))
        let a = try runtime(store: store, transport: at, durability: archive)
        let b = try runtime(store: DotsStore(), transport: bt, reversed: true)
        try port.publish(a.host(for: port.read(), now: 1)); frames(3)
        XCTAssertEqual(try port.read().run, run)
        press(1)
        let pulse = try port.read(); XCTAssertEqual(pulse.pending, 1); XCTAssertEqual(pulse.emitted, 1)
        try a.observe(pulse)
        try handshake(a, at, b, bt); try a.replay()
        try deliver(at, to: b, from: owner); try deliver(bt, to: a, from: peer)
        try port.publish(a.host(for: port.read(), now: 1)); frames(3)
        XCTAssertEqual(try port.read().receipt, 1)
        XCTAssertEqual(try port.read().pending, 1, "Transport receipt cannot delete the native durable outbox")
        XCTAssertEqual(try port.read().durable, 0)
        try a.persistPending()
        XCTAssertEqual(a.durabilityContract, "sample-local-atomic-file-readback-v1")
        try port.publish(a.host(for: port.read(), now: 1)); frames(3)
        XCTAssertEqual(try port.read().durable, 1); XCTAssertEqual(try port.read().pending, 0)
        // The peer is injected, while application and SRAM commit are on the actual VBA core.
        try b.observe(modelSnapshot(emitted: 1, reversed: true)); try b.replay()
        try deliver(bt, to: a, from: peer)
        let peerPulse = BoundSDKEvent.ID(origin: peer, sequence: 1)
        XCTAssertTrue(a.state.journal.received.contains(peerPulse))
        XCTAssertFalse(a.state.journal.applied.contains(peerPulse))
        try port.publish(a.host(for: port.read(), now: 1)); frames(3)
        XCTAssertEqual(try port.read().peerApplied, 1); XCTAssertEqual(try port.read().peerCount, 1)
        try a.observe(port.read()); XCTAssertTrue(a.state.journal.applied.contains(peerPulse))
        try port.publish(a.host(for: port.read(), now: 1)); frames(3)
        XCTAssertEqual(try port.read().peerCount, 1)
        try b.publishPresence(x: 100, y: 80); try deliver(bt, to: a, from: peer)
        try port.publish(a.host(for: port.read(), now: 1)); frames(3)
        XCTAssertEqual(try port.read().flags & 1, 1)
        frames(185)
        XCTAssertEqual(try port.read().flags & 1, 0)
        let beforeMove = try port.read().x; press(16)
        XCTAssertGreaterThan(try port.read().x, beforeMove)
        try port.publish(a.host(for: port.read(), now: 5, paused: true)); frames(3)
        let frozenX = try port.read().x; press(16)
        XCTAssertEqual(try port.read().x, frozenX)
        try port.publish(a.host(for: port.read(), now: 6)); frames(3); press(16)
        XCTAssertGreaterThan(try port.read().x, frozenX)
        press(1); XCTAssertEqual(try port.read().pending, 2)
        try a.observe(port.read())
        let saved = directory.appendingPathComponent("export.sav")
        core.deltaCore.emulatorBridge.saveGameSave(to: saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        let beforeStop = try port.read()
        XCTAssertTrue(core.stop()); XCTAssertThrowsError(try port.read())
        // Same URL and shared native bridge, new load generation: old owner stays rejected.
        let restored = try XCTUnwrap(EmulatorCore(game: DotsGame(fileURL: rom, gameSaveURL: saved), options: [.metal: true]))
        restored.audioManager.isEnabled = false
        XCTAssertTrue(restored.start()); XCTAssertTrue(restored.pause()); defer { _ = restored.stop() }
        for _ in 0..<8 { restored.deltaCore.emulatorBridge.runFrame(processVideo: false) }
        XCTAssertThrowsError(try port.read())
        let restoredPort = try BoundSDKDotsCore(core: restored)
        defer { restoredPort.release() }
        let cold = try restoredPort.read()
        XCTAssertEqual(cold.pending, 2); XCTAssertEqual(cold.emitted, beforeStop.emitted)
        XCTAssertEqual(cold.durable, 1)
        XCTAssertEqual(cold.peerApplied, 1); XCTAssertEqual(cold.peerCount, 1)
        let reopened = try runtime(store: store, transport: DotsTransport(), durability: archive)
        XCTAssertGreaterThan(reopened.state.hostGeneration, a.state.hostGeneration)
        try restoredPort.publish(reopened.host(for: cold, now: 10))
        for _ in 0..<3 { restored.deltaCore.emulatorBridge.runFrame(processVideo: false) }
        XCTAssertEqual(try restoredPort.read().generation, reopened.state.hostGeneration)
        // A late claimant must match the actual bridge renderers, not just a
        // still-paused older EmulatorCore and the same URL. Only one native
        // loop runs: restored is paused before replacement starts.
        restoredPort.release()
        let replacement = try XCTUnwrap(EmulatorCore(game: DotsGame(fileURL: rom, gameSaveURL: directory.appendingPathComponent("replacement.sav")), options: [.metal: true]))
        replacement.audioManager.isEnabled = false
        XCTAssertEqual(restored.state, .paused)
        XCTAssertTrue(replacement.start()); XCTAssertTrue(replacement.pause())
        defer { _ = replacement.stop() }
        for _ in 0..<8 { replacement.deltaCore.emulatorBridge.runFrame(processVideo: false) }
        XCTAssertEqual(restored.state, .paused)
        XCTAssertThrowsError(try BoundSDKDotsCore(core: restored), "An obsolete paused core cannot claim the new same-URL generation")
        XCTAssertThrowsError(try restoredPort.read())
        let replacementPort = try BoundSDKDotsCore(core: replacement)
        defer { replacementPort.release() }
        _ = try replacementPort.read()
        let evidence: [String: Any] = ["version": 1, "romSHA256": BoundSDKDotsAdapter.sha256,
            "core": BoundSDKDotsAdapter.coreID, "coreStateVersion": 10, "nativeCore": "VBA-M",
            "oneNativeCoreAtATime": true, "injectedPeer": true, "durabilityContract": archive.storageContract,
            "coldbootPending": cold.pending, "coldbootDurable": cold.durable,
            "authenticatedBackend": false, "physicalDeviceWAN": false]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("native-evidence.json"), options: .atomic)
    }
}
