import XCTest
@testable import Delta

final class SharedWorldTests: XCTestCase {
    private func state(_ value: UInt8 = 0) -> BoundWorldState {
        .init(group: 3, number: 43, flags: Data(repeating: value, count: 800))
    }
    func testPacketRoundTripAndMaximumSize() throws {
        var value = state(255)
        value.boulders = Data((0..<16).flatMap { [UInt8($0 + 1),3,10,0,31,0] })
        let packet = BoundWorldPacket(sender: UUID(), receiver: UUID(), sequence: UInt64.max, state: value)
        let data = try XCTUnwrap(packet.encoded())
        XCTAssertEqual(data.count, 943); XCTAssertEqual(BoundWorldPacket.decode(data), packet)
        XCTAssertEqual(BoundWorldPacket.decode(try XCTUnwrap(BoundWorldPacket(sender: UUID(), receiver: nil, sequence: 1, state: state()).encoded()))?.receiver, nil)
    }
    func testMalformedSnapshotsAndTruncationsAreRejected() throws {
        let valid = try XCTUnwrap(BoundWorldPacket(sender: UUID(), receiver: UUID(), sequence: 1, state: state()).encoded())
        for count in 0..<valid.count { XCTAssertNil(BoundWorldPacket.decode(Data(valid.prefix(count)))) }
        var wrong = valid; wrong[44] = 43; XCTAssertNil(BoundWorldPacket.decode(wrong))
        wrong = valid; wrong[846] = 17; XCTAssertNil(BoundWorldPacket.decode(wrong))
        wrong = valid; wrong.append(0); XCTAssertNil(BoundWorldPacket.decode(wrong))
        XCTAssertNil(BoundWorldPacket(sender: UUID(), receiver: nil, sequence: 0, state: state()).encoded())
        var bad = state(); bad.flags.removeLast()
        XCTAssertNil(BoundWorldPacket(sender: UUID(), receiver: nil, sequence: 1, state: bad).encoded())
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
}
