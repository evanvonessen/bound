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

    func testReleaseBundleContainsNoMultiplayerROMAndStartupDoesNotImportOne() async throws {
        guard SyncManager.shared.coordinator == nil, BoundROMUpdateActivity.canApply else {
            throw XCTSkip("Requires the isolated signed-out QA library with no active core")
        }
        let bundle = Bundle(for: Game.self)
        XCTAssertNil(bundle.url(forResource: "multiplayer", withExtension: "gba"))
        XCTAssertNil(bundle.url(forResource: "rrbin-integrated", withExtension: "gba"))
        let context = DatabaseManager.shared.viewContext
        let before = Set(try context.fetch(Game.fetchRequest()).map(\.identifier))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("NoBundledROM-" + UUID().uuidString)
        let suite = "NoBundledROM-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let storage = BoundROMUpdateStorage(root: temporary.appendingPathComponent("Updater"), documents: temporary, support: temporary)
        let manager = BoundROMUpdateManager(defaults: defaults, storage: storage)
        var attempts = 0
        manager.canApply = { attempts += 1; return false }
        manager.start()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(Set(try context.fetch(Game.fetchRequest()).map(\.identifier)), before)
        XCTAssertEqual(attempts, 0)
        XCTAssertNil(try storage.pending())
    }

    func testLegacyEnabledFolderPreferenceCannotStartAnUpdateOrChangeFilesOrPreferences() async throws {
        guard SyncManager.shared.coordinator == nil else { throw XCTSkip("Requires the isolated signed-out QA app") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyFolderRetirement-" + UUID().uuidString)
        let suite = "LegacyFolderRetirement-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: temporary) }
        let folder = temporary.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A synthetic candidate is sufficient: the retired path must never read
        // or validate a new candidate, even if a legacy preference remains on.
        let candidate = folder.appendingPathComponent("multiplayer.gba"), save = temporary.appendingPathComponent("previous.sav")
        let candidateBytes = Data("unattended candidate must not be read".utf8), saveBytes = Data([1, 2, 3, 4])
        try candidateBytes.write(to: candidate); try saveBytes.write(to: save)
        defaults.set(try folder.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil),
                     forKey: "bound.rom-updates.folder-bookmark.v1")
        defaults.set(true, forKey: "bound.rom-updates.enabled.v1")
        defaults.set("Previous updates", forKey: "bound.rom-updates.folder-name.v1")
        defaults.set("previous-enrollment", forKey: "bound.rom-updates.enrollment-game.v1")
        let storage = BoundROMUpdateStorage(root: temporary.appendingPathComponent("Updater"), documents: temporary, support: temporary)
        try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
        let previous = try BoundROMUpdateContent(data: saveBytes, expectedSHA256: BoundROMUpdateContent.hash(saveBytes), expectedByteCount: saveBytes.count)
        let stateBytes = try JSONEncoder().encode(BoundROMUpdateStorage.State(current: previous, requiresGeneration: true))
        try stateBytes.write(to: storage.stateURL)
        let preferences = defaults.dictionaryRepresentation()
        let manager = BoundROMUpdateManager(defaults: defaults, storage: storage)
        let previousStatus = manager.status
        var resetAttempts = 0
        manager.canApply = { resetAttempts += 1; return false }
        manager.checkNow()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(resetAttempts, 0)
        XCTAssertEqual(manager.status, previousStatus)
        XCTAssertFalse(manager.needsGameSelection)
        XCTAssertNil(try storage.pending())
        XCTAssertEqual(try Data(contentsOf: storage.stateURL), stateBytes)
        XCTAssertEqual(try Data(contentsOf: candidate), candidateBytes)
        XCTAssertEqual(try Data(contentsOf: save), saveBytes)
        XCTAssertTrue((defaults.dictionaryRepresentation() as NSDictionary).isEqual(to: preferences))
    }

    func testPreviouslyAcceptedTransactionStillResumesItsCapturedJournalWithoutReadingLegacyFolder() async throws {
        guard SyncManager.shared.coordinator == nil else { throw XCTSkip("Requires the isolated signed-out QA app") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AcceptedROMRecovery-" + UUID().uuidString)
        let suite = "AcceptedROMRecovery-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let storage = BoundROMUpdateStorage(root: temporary.appendingPathComponent("Updater"), documents: temporary, support: temporary)
        let bytes = Data("already confirmed synthetic cartridge".utf8)
        let incoming = try BoundROMUpdateContent(data: bytes, expectedSHA256: BoundROMUpdateContent.hash(bytes), expectedByteCount: bytes.count)
        let pending = try storage.begin(content: incoming, data: bytes, sources: [], metadata: Data(), resetGameIDs: [])
        let journal = try Data(contentsOf: storage.journalURL)
        let preferences = defaults.dictionaryRepresentation()
        let recovering = BoundROMUpdateManager(defaults: defaults, storage: storage)
        var recoveryAttempts = 0
        recovering.canApply = { recoveryAttempts += 1; return false }
        recovering.checkNow()
        for _ in 0..<100 {
            if recoveryAttempts > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        // The recovery path reaches the safe-apply gate, while leaving every
        // accepted byte intact until the app is able to complete that work.
        XCTAssertEqual(recoveryAttempts, 1)
        XCTAssertEqual(try storage.pending()?.id, pending.id)
        XCTAssertEqual(try Data(contentsOf: storage.journalURL), journal)
        XCTAssertEqual(try Data(contentsOf: storage.incomingURL(pending)), bytes)
        XCTAssertTrue((defaults.dictionaryRepresentation() as NSDictionary).isEqual(to: preferences))
    }

    func testFolderCandidatePrefersMultiplayerAndRetainsLegacyFilename() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = folder.appendingPathComponent("rrbin-integrated.gba"), current = folder.appendingPathComponent("multiplayer.gba")
        try Data([1]).write(to: legacy)
        XCTAssertEqual(BoundROMUpdateManager.candidateFile(in: folder), legacy)
        try Data([2]).write(to: current)
        XCTAssertEqual(BoundROMUpdateManager.candidateFile(in: folder), current)
        XCTAssertEqual(try Data(contentsOf: legacy), Data([1]))
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
