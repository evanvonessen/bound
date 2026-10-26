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
        let url = try XCTUnwrap(Bundle(for: Game.self).url(forResource: "multiplayer", withExtension: "gba"))
        let content = try BoundROMUpdateContent(data: Data(contentsOf: url), expectedSHA256: BoundPlayerROMProfile.supportedSHA256)
        let context = DatabaseManager.shared.viewContext
        let request = Game.fetchRequest() as! NSFetchRequest<Game>
        request.predicate = NSPredicate(format: "identifier == %@", content.gameID)
        for _ in 0..<100 {
            if try context.count(for: request) == 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(try context.count(for: request), 1)
        try await BoundROMUpdateManager.shared.installBundledROM(from: url, name: BoundROMUpdateManager.bundledROMName(buildNumber: "999"))
        XCTAssertEqual(try context.count(for: request), 1)
    }

    func testBundledInstallAndEnabledFolderPreserveCurrentAndOlderSavesAndCustomNames() async throws {
        guard SyncManager.shared.coordinator == nil, BoundROMUpdateActivity.canApply else {
            throw XCTSkip("Requires the isolated signed-out QA library with no active core")
        }
        let manager = BoundROMUpdateManager.shared
        let bundle = try XCTUnwrap(Bundle(for: Game.self).url(forResource: "multiplayer", withExtension: "gba"))
        try await manager.installBundledROM(from: bundle, name: "Multi Red — Build 999")
        let context = DatabaseManager.shared.viewContext, request = Game.fetchRequest() as! NSFetchRequest<Game>
        request.predicate = NSPredicate(format: "identifier == %@", BoundGameProfiles.current.gameID)
        let current = try XCTUnwrap(context.fetch(request).first)
        let previousName = current.name, currentROM = current.fileURL, battery = current.gameSaveURL
        let originalROM = try Data(contentsOf: currentROM), previousBattery = try? Data(contentsOf: battery)
        let state = DatabaseManager.saveStatesDirectoryURL(for: current).appendingPathComponent(UUID().uuidString + ".state")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // Disposable library-only GBA input. It is never admitted to a core.
        let olderBytes = Data(("Bundled import preservation " + UUID().uuidString).utf8)
        let olderInput = temporary.appendingPathComponent("Existing cartridge.gba")
        try olderBytes.write(to: olderInput)
        let older: Game = try await withCheckedThrowingContinuation { continuation in
            DatabaseManager.shared.importGames(at: [olderInput]) { games, errors in
                guard errors.isEmpty, games.count == 1, let game = games.first else {
                    continuation.resume(throwing: BoundROMUpdateError.storage); return
                }
                continuation.resume(returning: game)
            }
        }
        let olderROM = older.fileURL, olderBattery = older.gameSaveURL
        let olderState = DatabaseManager.saveStatesDirectoryURL(for: older).appendingPathComponent(UUID().uuidString + ".state")
        defer {
            current.name = previousName; context.delete(older); try? context.save()
            try? originalROM.write(to: currentROM, options: .atomic)
            if let previousBattery { try? previousBattery.write(to: battery, options: .atomic) }
            else { try? FileManager.default.removeItem(at: battery) }
            for file in [state, olderROM, olderBattery, olderState, temporary] { try? FileManager.default.removeItem(at: file) }
        }
        current.name = "My multiplayer cartridge"; older.name = "My earlier cartridge"; try context.save()
        let sentinels: [(URL, Data)] = [(battery, Data([1, 2, 3])), (state, Data([4, 5, 6])),
                                      (olderBattery, Data([7, 8, 9])), (olderState, Data([10, 11, 12]))]
        for (file, bytes) in sentinels { try bytes.write(to: file, options: .atomic) }
        try await manager.installBundledROM(from: bundle, name: "Multi Red — Build 1000")
        // A metadata-only/cloud library row must also receive its missing ROM
        // without touching any content-addressed battery or state files.
        try FileManager.default.removeItem(at: currentROM)
        try await manager.installBundledROM(from: bundle, name: "Multi Red — Build 1001")
        XCTAssertEqual(try context.count(for: request), 1)
        XCTAssertEqual(current.name, "My multiplayer cartridge")
        XCTAssertEqual(older.name, "My earlier cartridge")
        XCTAssertFalse(older.isDeleted)
        XCTAssertEqual(try Data(contentsOf: currentROM), originalROM)
        XCTAssertEqual(try Data(contentsOf: olderROM), olderBytes)
        for (file, bytes) in sentinels { XCTAssertEqual(try Data(contentsOf: file), bytes) }

        let suite = "BundledFolderPreservation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = temporary.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try originalROM.write(to: folder.appendingPathComponent("multiplayer.gba"))
        defaults.set(try folder.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil),
                     forKey: "bound.rom-updates.folder-bookmark.v1")
        defaults.set(true, forKey: "bound.rom-updates.enabled.v1")
        defaults.set("Previous updates", forKey: "bound.rom-updates.folder-name.v1")
        defaults.set(older.identifier, forKey: "bound.rom-updates.enrollment-game.v1")
        let storage = BoundROMUpdateStorage(root: temporary.appendingPathComponent("Updater"),
                                           documents: temporary, support: temporary)
        try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
        let previous = try BoundROMUpdateContent(data: olderBytes, expectedSHA256: BoundROMUpdateContent.hash(olderBytes),
                                                expectedByteCount: olderBytes.count)
        let stateBytes = try JSONEncoder().encode(BoundROMUpdateStorage.State(current: previous, requiresGeneration: true))
        try stateBytes.write(to: storage.stateURL)
        let preferences = defaults.dictionaryRepresentation()
        let folderManager = BoundROMUpdateManager(defaults: defaults, storage: storage)
        var resetAttempts = 0
        // If the guard regresses, stop before destructive work and fail the
        // test. The real candidate reader/install path still runs unchanged.
        folderManager.canApply = { resetAttempts += 1; return false }
        folderManager.checkNow()
        for _ in 0..<100 {
            if folderManager.status == "Included ROM is up to date." || resetAttempts > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(folderManager.status, "Included ROM is up to date.")
        XCTAssertEqual(resetAttempts, 0)
        XCTAssertNil(try storage.pending())
        XCTAssertEqual(try Data(contentsOf: storage.stateURL), stateBytes)
        XCTAssertTrue((defaults.dictionaryRepresentation() as NSDictionary).isEqual(to: preferences))
        XCTAssertEqual(current.name, "My multiplayer cartridge"); XCTAssertEqual(older.name, "My earlier cartridge")
        XCTAssertFalse(older.isDeleted)
        for (file, bytes) in sentinels { XCTAssertEqual(try Data(contentsOf: file), bytes) }
        XCTAssertEqual(try Data(contentsOf: olderROM), olderBytes)

        // Already accepted work keeps its original recovery ordering. The
        // bundled-content bypass must not conceal or clear a pending journal.
        let incoming = try BoundROMUpdateContent(data: originalROM, expectedSHA256: BoundPlayerROMProfile.supportedSHA256)
        let pending = try storage.begin(content: incoming, data: originalROM, sources: [], metadata: Data(),
                                        resetGameIDs: [previous.gameID, incoming.gameID])
        let journal = try Data(contentsOf: storage.journalURL)
        let recovering = BoundROMUpdateManager(defaults: defaults, storage: storage)
        recovering.canApply = { resetAttempts += 1; return false }
        recovering.checkNow()
        for _ in 0..<100 {
            if resetAttempts > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(resetAttempts, 1)
        XCTAssertEqual(try storage.pending()?.id, pending.id)
        XCTAssertEqual(try Data(contentsOf: storage.journalURL), journal)
        XCTAssertEqual(try Data(contentsOf: storage.stateURL), stateBytes)
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
