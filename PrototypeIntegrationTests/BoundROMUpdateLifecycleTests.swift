import XCTest
import CoreData
@testable import Delta

@MainActor
final class BoundROMUpdateLifecycleTests: XCTestCase {
    func testPendingSaveClearBlocksGameplayAndPreviewBindingForOnlyThatROM() throws {
        guard SyncManager.shared.coordinator == nil else { throw XCTSkip("Requires the isolated signed-out QA app") }
        let modelURL = try XCTUnwrap(Bundle(for: DatabaseManager.self).url(forResource: "Delta", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        defer { context.reset() }
        let game = Game(entity: try XCTUnwrap(model.entitiesByName["Game"]), insertInto: context)
        game.identifier = "save-clear-fixture-" + UUID().uuidString
        game.name = "Save Clear Fixture"
        game.filename = game.identifier + ".gba"
        game.type = .gba

        // This fabricated game never enters the library and owns no save files.
        let storage = BoundROMUpdateStorage.live
        let pending = try storage.beginSaveClear(gameID: game.identifier, gameName: game.name, cloudContext: Data())
        defer { try? storage.completeSaveClear(pending) }
        let gameplay = GameViewController()
        let preview = PreviewGameViewController()
        gameplay.game = game
        preview.game = game
        XCTAssertNil(gameplay.game)
        XCTAssertNil(gameplay.emulatorCore)
        XCTAssertNil(preview.game)
        XCTAssertNil(preview.emulatorCore)
        XCTAssertTrue(BoundROMUpdateManager.shared.hasPendingSaveClear(for: game.identifier))
        XCTAssertFalse(BoundROMUpdateManager.shared.hasPendingSaveClear(for: "unrelated-" + game.identifier))
    }

    func testBundledROMIsImportedWithoutDuplicatingExistingGame() async throws {
        let content = try BoundROMUpdateContent(data: Data(contentsOf: XCTUnwrap(Bundle(for: Game.self).url(forResource: "rrbin-integrated", withExtension: "gba"))), expectedSHA256: BoundPlayerROMProfile.supportedSHA256)
        let context = DatabaseManager.shared.viewContext
        let request = Game.fetchRequest() as! NSFetchRequest<Game>
        request.predicate = NSPredicate(format: "identifier == %@", content.gameID)
        for _ in 0..<100 {
            if try context.count(for: request) == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try context.count(for: request), 1)
        BoundROMUpdateManager.shared.checkNow()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(try context.count(for: request), 1)
    }

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
