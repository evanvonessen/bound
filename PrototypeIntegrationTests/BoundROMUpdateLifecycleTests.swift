import XCTest
@testable import Delta

@MainActor
final class BoundROMUpdateLifecycleTests: XCTestCase {
    func testResetWaitsForManualRestoreAndPreventsNewRestoresUntilFinished() async throws {
        let sync = SyncManager.shared
        guard sync.coordinator == nil else { throw XCTSkip("Requires the isolated signed-out QA app") }
        let finishRestore = try XCTUnwrap(sync.beginManualRecordMutation())
        let entered = expectation(description: "Reset enters after restore finishes")
        var release: (() -> Void)?
        sync.performROMUpdate { finish in release = finish; entered.fulfill() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(release)
        XCTAssertNil(sync.beginManualRecordMutation())
        finishRestore()
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertNil(sync.beginManualRecordMutation())
        try XCTUnwrap(release)()
        // Duplicate callbacks must not release another update's fence.
        release?()
        for _ in 0..<10 { await Task.yield() }
        let next = try XCTUnwrap(sync.beginManualRecordMutation())
        next()
        for _ in 0..<10 { await Task.yield() }
    }

    func testTwoUpdatesRemainSerializedAcrossAsynchronousWork() async throws {
        let sync = SyncManager.shared
        guard sync.coordinator == nil else { throw XCTSkip("Requires the isolated signed-out QA app") }
        var firstFinish: (() -> Void)?
        var secondFinish: (() -> Void)?
        let secondEntered = expectation(description: "Second enters after first finishes")
        sync.performROMUpdate { firstFinish = $0 }
        sync.performROMUpdate { secondFinish = $0; secondEntered.fulfill() }
        XCTAssertNotNil(firstFinish)
        XCTAssertNil(secondFinish)
        firstFinish?()
        await fulfillment(of: [secondEntered], timeout: 3)
        XCTAssertNil(sync.beginManualRecordMutation())
        secondFinish?()
        for _ in 0..<10 { await Task.yield() }
        let next = try XCTUnwrap(sync.beginManualRecordMutation())
        next()
        for _ in 0..<10 { await Task.yield() }
    }
}
