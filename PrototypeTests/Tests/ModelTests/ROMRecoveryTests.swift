import XCTest
@testable import Models

final class ROMRecoveryTests: XCTestCase {
    func testRestoredRequestIsAcknowledgedWithoutReplayingItsCommand() {
        var cursor = BoundROMRequestCursor()
        XCTAssertEqual(cursor.admit(40), .dispatch)
        cursor.didRestore()
        XCTAssertEqual(cursor.admit(12), .rebase)
        XCTAssertEqual(cursor.lastHandled, 12)
        XCTAssertEqual(cursor.admit(12), .ignore)
        XCTAssertEqual(cursor.admit(13), .dispatch)
        XCTAssertEqual(cursor.admit(13), .ignore)
        XCTAssertEqual(cursor.admit(0), .ignore)
    }
    func testResetIsDetectedButCounterWrapAndExplicitRestoreAreNot() {
        var clock = BoundROMFrameClock()
        XCTAssertFalse(clock.observe(100))
        XCTAssertFalse(clock.observe(101))
        XCTAssertTrue(clock.observe(0))
        clock.reset()
        XCTAssertFalse(clock.observe(UInt32.max))
        XCTAssertFalse(clock.observe(0))
        clock.reset()
        XCTAssertFalse(clock.observe(50))
    }
    private func withJournal(_ body: (URL, UUID, UUID, UUID) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("history.json"), UUID(), UUID(), UUID())
    }
    private func history(_ bit: UInt8 = 0) -> Data {
        var data = Data(repeating: 0, count: BoundROMHistoryJournal.historyBytes)
        data[0] = bit; data[600] = bit
        return data
    }
    func testCrashBeforeHistoryRequestReplaysMonotonicLocalProgress() throws {
        try withJournal { url, run, owner, device in
            let before = history(1), after = history(3)
            let journal = try BoundROMHistoryJournal(url: url, run: run, owner: owner, device: device)
            try journal.reconcile(server: BoundROMHistoryJournal.digest(before), current: before)
            // The local ledger/suspension advances, then the process dies before
            // prepare or the RPC. The acknowledged baseline is already durable.
            let reopened = try BoundROMHistoryJournal(url: url, run: run, owner: owner, device: device)
            try reopened.reconcile(server: BoundROMHistoryJournal.digest(before), current: after)
            try reopened.prepare(after)
            try reopened.reconcile(server: BoundROMHistoryJournal.digest(after), current: after)
        }
    }
    func testLostServerReplyCanBeRecoveredAndOlderSaveIsRejected() throws {
        try withJournal { url, run, owner, device in
            let before = history(1), after = history(3), latest = history(7)
            let journal = try BoundROMHistoryJournal(url: url, run: run, owner: owner, device: device)
            try journal.reconcile(server: BoundROMHistoryJournal.digest(before), current: before)
            try journal.prepare(after)
            let reopened = try BoundROMHistoryJournal(url: url, run: run, owner: owner, device: device)
            XCTAssertThrowsError(try reopened.reconcile(server: BoundROMHistoryJournal.digest(after), current: before))
            try reopened.reconcile(server: BoundROMHistoryJournal.digest(after), current: latest)
            XCTAssertThrowsError(try reopened.reconcile(server: BoundROMHistoryJournal.digest(before), current: latest))
        }
    }
    func testUnknownServerHistoryAndDifferentOwnerCannotBeAdopted() throws {
        try withJournal { url, run, owner, device in
            let journal = try BoundROMHistoryJournal(url: url, run: run, owner: owner, device: device)
            try journal.reconcile(server: BoundROMHistoryJournal.digest(history(1)), current: history(1))
            XCTAssertThrowsError(try journal.reconcile(server: BoundROMHistoryJournal.digest(history(2)), current: history(3)))
            XCTAssertThrowsError(try BoundROMHistoryJournal(url: url, run: run, owner: UUID(), device: device))
            XCTAssertThrowsError(try BoundROMHistoryJournal(url: url, run: UUID(), owner: owner, device: device))
            XCTAssertThrowsError(try BoundROMHistoryJournal(url: url, run: run, owner: owner, device: UUID()))
        }
    }
    func testLegacyCheckpointCanProveMissingMonotonicUpdate() throws {
        try withJournal { url, run, owner, device in
            let journal = try BoundROMHistoryJournal(url: url, run: run, owner: owner, device: device)
            XCTAssertThrowsError(try journal.reconcile(server: BoundROMHistoryJournal.digest(history(1)), current: history(3)))
            try journal.reconcile(server: BoundROMHistoryJournal.digest(history(1)), current: history(3), completed: [history(1)])
            XCTAssertThrowsError(try journal.reconcile(server: BoundROMHistoryJournal.digest(history(1)), current: history(0)))
        }
    }
    func testUnanchoredNewRunAndMalformedHistoryStayBounded() throws {
        try withJournal { url, run, owner, device in
            let journal = try BoundROMHistoryJournal(url: url, run: run, owner: owner, device: device)
            XCTAssertThrowsError(try journal.reconcile(server: nil, current: history()))
            try journal.reconcile(server: nil, current: history(), allowUnanchored: true)
            try journal.prepare(history())
            let reopened = try BoundROMHistoryJournal(url: url, run: run, owner: owner, device: device)
            try reopened.reconcile(server: BoundROMHistoryJournal.digest(history()), current: history())
            XCTAssertThrowsError(try reopened.prepare(Data([1])))
            XCTAssertThrowsError(try reopened.reconcile(server: nil, current: history()))
        }
    }
}
