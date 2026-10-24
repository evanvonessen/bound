import XCTest
@testable import Delta

final class SharedWorldTests: XCTestCase {
    private func state(_ value: UInt8 = 0) -> BoundWorldState {
        .init(group: 3, number: 43, checkpoints: Data(repeating: value, count: 800))
    }
    func testPacketRoundTripAndMaximumSize() throws {
        var value = state(255)
        value.boulders = Data((0..<16).flatMap { [UInt8($0 + 1),3,10,0,31,0] })
        let packet = BoundWorldPacket(sender: UUID(), receiver: UUID(), sequence: UInt64.max, state: value)
        let data = try XCTUnwrap(packet.encoded())
        XCTAssertEqual(data.count, 967); XCTAssertEqual(BoundWorldPacket.decode(data), packet)
        XCTAssertEqual(BoundWorldPacket.decode(try XCTUnwrap(BoundWorldPacket(sender: UUID(), receiver: nil, sequence: 1, state: state()).encoded()))?.receiver, nil)
    }
    func testMalformedSnapshotsAndTruncationsAreRejected() throws {
        let valid = try XCTUnwrap(BoundWorldPacket(sender: UUID(), receiver: UUID(), sequence: 1, state: state()).encoded())
        for count in 0..<valid.count { XCTAssertNil(BoundWorldPacket.decode(Data(valid.prefix(count)))) }
        var wrong = valid; wrong[68] = 43; XCTAssertNil(BoundWorldPacket.decode(wrong))
        wrong = valid; wrong[870] = 17; XCTAssertNil(BoundWorldPacket.decode(wrong))
        wrong = valid; wrong.append(0); XCTAssertNil(BoundWorldPacket.decode(wrong))
        XCTAssertNil(BoundWorldPacket(sender: UUID(), receiver: nil, sequence: 0, state: state()).encoded())
        var bad = state(); bad.checkpoints.removeLast()
        XCTAssertNil(BoundWorldPacket(sender: UUID(), receiver: nil, sequence: 1, state: bad).encoded())
    }
    func testMismatchedGameContractAndLegacyPacketsAreRejected() throws {
        let data = try XCTUnwrap(BoundWorldPacket(sender: UUID(), receiver: nil, sequence: 1, state: state()).encoded())
        for index in [4, 20, 22, 24, 26] {
            var wrong = data; wrong[index] ^= 1
            XCTAssertNil(BoundWorldPacket.decode(wrong), "Different ruleset, ABI, checkpoint or save versions must not connect")
        }
        var legacy = data; legacy[3] = Character("1").asciiValue!
        XCTAssertNil(BoundWorldPacket.decode(legacy))
        var duplicate = state()
        duplicate.boulders = Data([1,3,10,0,31,0,1,3,11,0,31,0])
        XCTAssertFalse(duplicate.valid)
    }
    func testBothPlayersMustCompleteFreshHandshake() {
        var a = BoundWorldTimeline(), b = BoundWorldTimeline()
        b.receive(.init(sender: a.epoch, receiver: nil, sequence: 1, state: state()), at: 1)
        XCTAssertFalse(b.fresh(at: 1)); XCTAssertNil(b.state)
        a.receive(.init(sender: b.epoch, receiver: a.epoch, sequence: 1, state: state(1)), at: 2)
        b.receive(.init(sender: a.epoch, receiver: b.epoch, sequence: 2, state: state()), at: 2)
        XCTAssertTrue(a.fresh(at: 2)); XCTAssertTrue(b.fresh(at: 2))
        XCTAssertFalse(a.fresh(at: 5)); XCTAssertFalse(a.fresh(at: 1))
    }
    func testGameRollbackAndHeapResetInvalidateTheCaptureGeneration() {
        var clock = BoundWorldSourceClock()
        XCTAssertTrue(clock.admit(40)); XCTAssertTrue(clock.admit(42))
        XCTAssertFalse(clock.admit(2)); XCTAssertEqual(clock.generation, 1)
        XCTAssertTrue(clock.admit(4)); XCTAssertFalse(clock.admit(3))
    }
    func testPausedGameOutputCannotRefreshProgressIndefinitely() {
        var clock = BoundWorldSourceClock()
        XCTAssertTrue(clock.admit(2))
        for _ in 0..<179 { XCTAssertTrue(clock.admit(2)) }
        XCTAssertFalse(clock.admit(2)); XCTAssertEqual(clock.generation, 1)
        XCTAssertFalse(clock.admit(2)); XCTAssertEqual(clock.generation, 1)
        XCTAssertTrue(clock.admit(4))
    }
    func testReconnectReplayAndReorderedPacketsCannotOpenGates() {
        var a = BoundWorldTimeline(); let peer = UUID(), oldEpoch = a.epoch
        a.receive(.init(sender: peer, receiver: oldEpoch, sequence: 20, state: state()), at: 1)
        a.receive(.init(sender: peer, receiver: oldEpoch, sequence: 19, state: state(255)), at: 2)
        XCTAssertEqual(a.state, state()); XCTAssertFalse(a.fresh(at: 4))
        a.reset()
        a.receive(.init(sender: peer, receiver: oldEpoch, sequence: 21, state: state(255)), at: 5)
        XCTAssertFalse(a.fresh(at: 5)); XCTAssertNil(a.state)
        let newPeer = UUID()
        a.receive(.init(sender: newPeer, receiver: a.epoch, sequence: 1, state: state(2)), at: 6)
        XCTAssertTrue(a.fresh(at: 6)); XCTAssertEqual(a.state, state(2))
        a.receive(.init(sender: peer, receiver: a.epoch, sequence: 99, state: state(255)), at: 7)
        XCTAssertEqual(a.state, state(2))
    }
    func testDelayedBacklogCannotRefreshAnExpiredChallenge() {
        var timeline = BoundWorldTimeline(); let peer = UUID(), oldEpoch = timeline.epoch
        timeline.receive(.init(sender: peer, receiver: oldEpoch, sequence: 1, state: state(255)), at: 1)
        timeline.receive(.init(sender: peer, receiver: oldEpoch, sequence: 2, state: state(255)), at: 5)
        XCTAssertNotEqual(timeline.epoch, oldEpoch); XCTAssertNil(timeline.state)
        XCTAssertFalse(timeline.fresh(at: 5))
        timeline.receive(.init(sender: peer, receiver: timeline.epoch, sequence: 3, state: state()), at: 6)
        XCTAssertTrue(timeline.fresh(at: 6)); XCTAssertEqual(timeline.state, state())
    }
    func testUnilateralReconnectAcceptsFreshAckFromStillOnlinePartner() {
        var timeline = BoundWorldTimeline(); let peer = UUID()
        timeline.receive(.init(sender: peer, receiver: timeline.epoch, sequence: 10, state: state()), at: 1)
        let oldEpoch = timeline.epoch; timeline.reset()
        timeline.receive(.init(sender: peer, receiver: oldEpoch, sequence: 11, state: state()), at: 2)
        XCTAssertFalse(timeline.fresh(at: 2))
        timeline.receive(.init(sender: peer, receiver: timeline.epoch, sequence: 12, state: state()), at: 3)
        XCTAssertTrue(timeline.fresh(at: 3))
    }
    func testNewPeerAndSaveRollbackRevokeOldProgress() {
        var timeline = BoundWorldTimeline(); let a = UUID(), b = UUID()
        timeline.receive(.init(sender: a, receiver: timeline.epoch, sequence: 1, state: state(255)), at: 1)
        timeline.receive(.init(sender: a, receiver: timeline.epoch, sequence: 2, state: state()), at: 2)
        XCTAssertEqual(timeline.state, state(), "Progress is current earned state, never a monotonic merge of somebody else's save")
        timeline.receive(.init(sender: b, receiver: nil, sequence: 1, state: state(255)), at: 3)
        XCTAssertNil(timeline.state); XCTAssertFalse(timeline.fresh(at: 3))
    }
    @MainActor
    func testSnapshotIsPersistedBeforePublicationAndPersistenceFailureOnlyWithholdsSharing() throws {
        enum StorageFailure: Error { case unavailable }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let local = state(3), session = BoundSharedProgression(snapshotReader: { local })
        var order: [String] = [], published = 0
        session.beforeSendSnapshot = { snapshot in
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            order.append("persisted")
        }
        session.send = { packet in
            XCTAssertEqual(try? JSONDecoder().decode(BoundWorldState.self, from: Data(contentsOf: file)), local)
            XCTAssertEqual(BoundWorldPacket.decode(packet)?.state, local)
            order.append("published"); published += 1; return true
        }
        session.tick(enabled: true, connected: true, at: 1)
        XCTAssertEqual(order, ["persisted", "published"])
        session.beforeSendSnapshot = { _ in order.append("failed"); throw StorageFailure.unavailable }
        session.tick(enabled: true, connected: true, at: 2)
        XCTAssertEqual(order, ["persisted", "published", "failed"])
        XCTAssertEqual(published, 1)
        XCTAssertEqual(local, state(3), "A storage error cannot change this cartridge's flags or puzzle objects")
        XCTAssertNil(session.timeline.state)
    }
    @MainActor
    func testDisconnectedWorldSnapshotsEnterOutboxBeforeAConnectionReturns() {
        let local = state(7), session = BoundSharedProgression(snapshotReader: { local })
        var recorded: [BoundWorldState] = [], published = 0
        session.beforeSendSnapshot = { recorded.append($0) }
        session.send = { _ in published += 1; return true }
        session.tick(enabled: true, connected: false, at: 1)
        XCTAssertEqual(recorded, [local]); XCTAssertEqual(published, 0)
        session.tick(enabled: true, connected: true, at: 2)
        XCTAssertEqual(recorded, [local, local]); XCTAssertEqual(published, 1)
    }
    @MainActor
    func testDurableWorldRecordsKeepLatestPerMapWithoutInjectingRemoteProgress() throws {
        let local = state(), session = BoundSharedProgression(snapshotReader: { local })
        var remote = state(255)
        remote.boulders = Data([1, 3, 10, 0, 31, 0])
        session.recordSharedWorldEvent(state: remote, sequence: 10)
        session.recordSharedWorldEvent(state: state(1), sequence: 9)
        XCTAssertEqual(session.sharedWorldRecord(group: 3, number: 43), remote)
        var anotherMap = state(8); anotherMap.number = 44
        session.recordSharedWorldEvent(state: anotherMap, sequence: 8)
        XCTAssertEqual(session.sharedWorldRecord(group: 3, number: 44), anotherMap)
        XCTAssertEqual(session.latestSharedWorldState, remote)
        XCTAssertEqual(session.latestSharedWorldSequence, 10)
        session.recordSharedWorldEvent(state: anotherMap, sequence: 12)
        XCTAssertEqual(session.latestSharedWorldState, anotherMap)
        XCTAssertEqual(session.latestSharedWorldSequence, 12)
        var duplicate = anotherMap; duplicate.checkpoints = Data(repeating: 0, count: 800)
        session.recordSharedWorldEvent(state: duplicate, sequence: 12)
        XCTAssertEqual(session.latestSharedWorldState, anotherMap, "Duplicate/out-of-order records cannot move presentation backwards")
        var outgoing: BoundWorldState?
        session.send = { outgoing = BoundWorldPacket.decode($0)?.state; return true }
        session.tick(enabled: true, connected: true, at: 1)
        XCTAssertEqual(outgoing, local, "Remote badges, trainer flags, rewards and boulders never enter this cartridge's snapshot")
        XCTAssertNil(session.timeline.state, "Durable replay never grants a live peer handshake or native policy authority")
        XCTAssertNil(session.probe.read())
        session.peerGone()
        XCTAssertEqual(session.latestSharedWorldState, anotherMap, "Disconnect does not erase durable presentation")
    }
}
