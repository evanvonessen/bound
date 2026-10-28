import Foundation
import XCTest
@testable import Delta

final class BattleLossTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_000)
    func testSeveralFaintsBecomeOneNoticeOnlyAfterBattleEnds() throws {
        var journal = BoundBattleLossJournal()
        try journal.observe(inBattle: true, eligible: true, previousDead: ["area:100"], dead: ["area:100"], at: date)
        try journal.observe(inBattle: true, eligible: true, previousDead: ["area:100"], dead: ["area:100", "egg:1"], at: date)
        try journal.observe(inBattle: true, eligible: true, previousDead: ["area:100", "egg:1"], dead: ["area:100", "egg:1", "gift:1"], at: date)
        XCTAssertNil(journal.pending)
        try journal.observe(inBattle: false, eligible: true, previousDead: ["area:100", "egg:1", "gift:1"], dead: ["area:100", "egg:1", "gift:1"], at: date)
        XCTAssertEqual(journal.notices.count, 1)
        XCTAssertEqual(journal.pending?.slots, ["egg:1", "gift:1"])
    }
    func testBattleJournalSurvivesDisconnectAndProcessRestart() throws {
        var journal = BoundBattleLossJournal()
        let id = UUID()
        try journal.observe(inBattle: true, eligible: true, previousDead: [], dead: ["static:1"], at: date, battleID: id)
        journal = try JSONDecoder().decode(BoundBattleLossJournal.self, from: JSONEncoder().encode(journal))
        try journal.observe(inBattle: false, eligible: true, previousDead: ["static:1"], dead: ["static:1"], at: date)
        XCTAssertEqual(journal.pending?.id, id)
        XCTAssertEqual(journal.pending?.slots, ["static:1"])
    }
    func testFriendlyOrBorrowedPartyExclusionRemainsForEntireBattle() throws {
        for exclusionAtEntry in [true, false] {
            var journal = BoundBattleLossJournal()
            try journal.observe(inBattle: true, eligible: !exclusionAtEntry, previousDead: [], dead: [], at: date)
            try journal.observe(inBattle: true, eligible: false, previousDead: [], dead: ["area:101"], at: date)
            try journal.observe(inBattle: false, eligible: true, previousDead: ["area:101"], dead: ["area:101"], at: date)
            XCTAssertTrue(journal.notices.isEmpty)
        }
    }
    func testRemoteCosmeticNoticeCannotCreateLossAndIsRetriedAfterAuthorityArrives() throws {
        var journal = BoundBattleLossJournal()
        let notice = BoundBattleLossNotice(id: UUID(), slots: ["area:101"], completedAt: date)
        XCTAssertThrowsError(try journal.admit(notice, dead: []))
        XCTAssertTrue(journal.notices.isEmpty)
        XCTAssertTrue(try journal.admit(notice, dead: ["area:101"]))
        XCTAssertFalse(try journal.admit(notice, dead: ["area:101"]))
        XCTAssertEqual(journal.notices.count, 1)
    }
    func testSimultaneousLinkedLossesAndRepeatedRemoteBatchesNeverDuplicateRows() throws {
        var journal = BoundBattleLossJournal()
        let first = BoundBattleLossNotice(id: UUID(), slots: ["area:101"], completedAt: date)
        let second = BoundBattleLossNotice(id: UUID(), slots: ["area:101", "gift:1"], completedAt: date)
        XCTAssertTrue(try journal.admit(first, dead: ["area:101", "gift:1"]))
        XCTAssertTrue(try journal.admit(second, dead: ["area:101", "gift:1"]))
        XCTAssertFalse(try journal.admit(second, dead: ["area:101", "gift:1"]))
        XCTAssertEqual(journal.notices.flatMap(\.slots), ["area:101", "gift:1"])
        XCTAssertTrue(journal.valid)
    }
    func testAcknowledgedNoticesStayAcknowledgedAcrossCheckpointRollback() throws {
        let notice = BoundBattleLossNotice(id: UUID(), slots: ["area:101"], completedAt: date)
        var current = BoundBattleLossJournal()
        try current.admit(notice, dead: ["area:101"])
        let checkpoint = current
        current.markAnnounced(notice.id)
        try current.retain(checkpoint)
        XCTAssertNil(current.pending)
        var restored = checkpoint
        try restored.retain(current)
        XCTAssertNil(restored.pending)
    }
    func testFieldAndNextBattleCannotRepeatHistoricalLossOrInferFromOutcome() throws {
        var journal = BoundBattleLossJournal()
        try journal.observe(inBattle: false, eligible: true, previousDead: [], dead: ["area:101"], at: date)
        XCTAssertNil(journal.pending, "A remote or historical tombstone without a battle is not a local battle outcome")
        try journal.observe(inBattle: true, eligible: true, previousDead: ["area:101"], dead: ["area:101"], at: date)
        try journal.observe(inBattle: false, eligible: true, previousDead: ["area:101"], dead: ["area:101"], at: date)
        XCTAssertNil(journal.pending)
    }
    func testMalformedIdentityAndLossRollbackAreRejected() throws {
        var journal = BoundBattleLossJournal()
        XCTAssertThrowsError(try journal.observe(inBattle: true, eligible: true, previousDead: ["area:101"], dead: [], at: date))
        XCTAssertThrowsError(try journal.admit(.init(id: UUID(), slots: ["area:001"], completedAt: date), dead: ["area:001"]))
        XCTAssertThrowsError(try journal.admit(.init(id: UUID(), slots: ["area:101", "area:101"], completedAt: date), dead: ["area:101"]))
        XCTAssertTrue(journal.valid)
    }
    func testRemoteDeathDuringOwnBattleKeepsItsRemoteBatch() throws {
        var journal = BoundBattleLossJournal()
        try journal.observe(inBattle: true, eligible: true, previousDead: [], dead: [], at: date)
        // The transport merged this remote tombstone before the next local
        // observation; it is already in previousDead, so it is not a local loss.
        try journal.observe(inBattle: true, eligible: true, previousDead: ["area:101"], dead: ["area:101"], at: date)
        try journal.observe(inBattle: true, eligible: true, previousDead: ["area:101"], dead: ["area:101", "gift:1"], at: date)
        try journal.observe(inBattle: false, eligible: true, previousDead: ["area:101", "gift:1"], dead: ["area:101", "gift:1"], at: date)
        XCTAssertEqual(journal.pending?.slots, ["gift:1"])
        let remote = BoundBattleLossNotice(id: UUID(), slots: ["area:101"], completedAt: date)
        XCTAssertTrue(try journal.admit(remote, dead: ["area:101", "gift:1"]))
        XCTAssertEqual(journal.notices.map(\.slots), [["gift:1"], ["area:101"]])
    }
    func testSixOwnedFaintsFitOneNoticeAndSevenAreInvalid() throws {
        var journal = BoundBattleLossJournal()
        let slots = Set((101...106).map { "area:\($0)" })
        try journal.observe(inBattle: true, eligible: true, previousDead: [], dead: slots, at: date)
        try journal.observe(inBattle: false, eligible: true, previousDead: slots, dead: slots, at: date)
        XCTAssertEqual(journal.pending?.slots.count, 6)
        XCTAssertFalse(BoundBattleLossNotice(id: UUID(), slots: (101...107).map { "area:\($0)" }, completedAt: date).valid)
    }
    func testCosmeticPacketRoundTripAndMalformedPacketsCannotSupplyEvidence() throws {
        let notice = BoundBattleLossNotice(id: UUID(), slots: ["area:101", "egg:1", "gift:1", "static:1"], completedAt: date)
        let packet = BoundBattleLossPacket(run: UUID(), sender: UUID(), receiver: UUID(), sequence: UInt64.max, notice: notice)
        let bytes = try XCTUnwrap(packet.encoded())
        XCTAssertEqual(bytes.count, 96)
        let decoded = try XCTUnwrap(BoundBattleLossPacket.decode(bytes))
        XCTAssertEqual(decoded.run, packet.run); XCTAssertEqual(decoded.sender, packet.sender); XCTAssertEqual(decoded.receiver, packet.receiver)
        XCTAssertEqual(decoded.sequence, UInt64.max); XCTAssertEqual(decoded.notice, notice)
        for length in 0..<bytes.count { XCTAssertNil(BoundBattleLossPacket.decode(bytes.prefix(length))) }
        var bad = bytes; bad.append(0); XCTAssertNil(BoundBattleLossPacket.decode(bad))
        for (offset, byte) in [(4, UInt8(2)), (5, 7), (6, 1), (7, 1)] {
            bad = bytes; bad[offset] = byte; XCTAssertNil(BoundBattleLossPacket.decode(bad))
        }
        bad = bytes; bad.replaceSubrange(8..<16, with: Data(repeating: 0, count: 8)); XCTAssertNil(BoundBattleLossPacket.decode(bad))
        bad = bytes; bad[90] = bad[88]; bad[91] = bad[89]; XCTAssertNil(BoundBattleLossPacket.decode(bad))
        bad = bytes; bad[88] = 0; bad[89] = 25; XCTAssertNil(BoundBattleLossPacket.decode(bad))
        bad = bytes; bad.replaceSubrange(80..<88, with: Data([0,0,0,0,0,0,0xF8,0x7F])); XCTAssertNil(BoundBattleLossPacket.decode(bad))
        XCTAssertNil(BoundBattleLossPacket(run: packet.run, sender: packet.sender, receiver: packet.receiver, sequence: 0, notice: notice).encoded())
    }
    func testConsecutiveBattleIDsSeparateLossesWhenExitObservationIsCoalesced() throws {
        var journal = BoundBattleLossJournal()
        let first = UUID(), second = UUID()
        try journal.observe(inBattle: true, eligible: true, previousDead: [], dead: ["area:101"], at: date, battleID: first)
        try journal.observe(inBattle: true, eligible: true, previousDead: ["area:101"], dead: ["area:101", "gift:1"], at: date, battleID: second)
        XCTAssertEqual(journal.notices.map(\.id), [first])
        XCTAssertEqual(journal.notices.first?.slots, ["area:101"])
        XCTAssertEqual(journal.battle?.slots, ["gift:1"])
        try journal.observe(inBattle: false, eligible: true, previousDead: ["area:101", "gift:1"], dead: ["area:101", "gift:1"], at: date, battleID: second)
        XCTAssertEqual(journal.notices.map(\.id), [first, second])
        XCTAssertEqual(journal.notices.map(\.slots), [["area:101"], ["gift:1"]])
    }
    func testCoalescedExcludedBattleCannotLeakLossesIntoNextOwnedBattle() throws {
        var journal = BoundBattleLossJournal()
        try journal.observe(inBattle: true, eligible: false, previousDead: [], dead: ["area:101"], at: date, battleID: UUID())
        let second = UUID()
        try journal.observe(inBattle: true, eligible: true, previousDead: ["area:101"], dead: ["area:101", "gift:1"], at: date, battleID: second)
        XCTAssertTrue(journal.notices.isEmpty)
        try journal.observe(inBattle: false, eligible: true, previousDead: ["area:101", "gift:1"], dead: ["area:101", "gift:1"], at: date, battleID: second)
        XCTAssertEqual(journal.notices.map(\.id), [second])
        XCTAssertEqual(journal.notices.first?.slots, ["gift:1"])
    }
}
