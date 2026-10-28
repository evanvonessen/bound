import XCTest
import CoreData
import SwiftUI
import UIKit
@testable import Delta

@MainActor
final class BoundROMCleanupTests: XCTestCase {
    private func storage() throws -> BoundROMUpdateStorage {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ROMCleanupQA-" + UUID().uuidString)
        let documents = base.appendingPathComponent("Documents"), support = base.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return .init(root: support.appendingPathComponent("ROM Updates"), documents: documents, support: support)
    }
    private var latest: BoundROMCleanupIdentity { .init(sha256: String(repeating: "a", count: 64), gameID: "latest", evidence: "fixture") }
    private func target(_ id: String, storage: BoundROMUpdateStorage) throws -> BoundROMCleanupPlan.Target {
        let url = storage.documents.appendingPathComponent(id + ".gba")
        try Data(("old ROM " + id).utf8).write(to: url)
        let save = storage.documents.appendingPathComponent(id + ".sav")
        try Data(("old save " + id).utf8).write(to: save)
        return .init(identity: .init(sha256: BoundROMUpdateContent.hash(try Data(contentsOf: url)), gameID: id, evidence: "verified fixture"),
            name: "Manually imported cartridge", filename: url.lastPathComponent,
            files: try BoundROMCleanupJournal(storage: storage).inventory([url, save]), stateIDs: [],
            cloud: .init(owner: nil, connection: nil, dropboxAccountID: nil, includesDropbox: false, saveStateIDs: []),
            dropbox: [], runs: [], serverBackup: false)
    }
    func testNothingIsDeletedUntilConfirmationAndCancelPreservesEveryByte() async throws {
        let storage = try storage(), old = try target("old", storage: storage)
        let plan = BoundROMCleanupPlan(id: UUID(), owner: nil, preserved: latest, targets: [old])
        var mutations = 0
        let cleanup = BoundROMCleanupCoordinator(storage: storage, operations: .init(prepare: { plan }, idle: { true }, owner: { nil },
            local: { _ in mutations += 1 }, cloud: { _ in mutations += 1 }))
        await cleanup.prepare(); XCTAssertEqual(cleanup.preview, plan); XCTAssertEqual(mutations, 0)
        XCTAssertNil(try BoundROMCleanupJournal(storage: storage).read())
        cleanup.cancel(); await cleanup.confirm()
        XCTAssertEqual(mutations, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.documents.appendingPathComponent("old.gba").path))
    }
    func testPermanentLocalReclamationPreservesLatestAndUnidentifiedFilesAndRetriesFrozenCloudScope() async throws {
        let storage = try storage(), old = try target("old", storage: storage)
        let keep = storage.documents.appendingPathComponent("latest.sav"), unrelated = storage.documents.appendingPathComponent("Multi Red unrelated.gba")
        try Data("latest save".utf8).write(to: keep); try Data("unidentified".utf8).write(to: unrelated)
        let plan = BoundROMCleanupPlan(id: UUID(), owner: nil, preserved: latest, targets: [old])
        var inventories = 0, available = false, cloudAttempts: [String] = []
        let operations = BoundROMCleanupCoordinator.Operations(prepare: { inventories += 1; return plan }, idle: { true }, owner: { nil },
            local: { try BoundROMCleanupJournal(storage: storage).delete($0.files) }, cloud: {
                cloudAttempts.append($0.id); if !available { throw BoundROMUpdateError.storage }
            })
        let first = BoundROMCleanupCoordinator(storage: storage, operations: operations)
        await first.prepare(); await first.confirm()
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.documents.appendingPathComponent("old.gba").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.documents.appendingPathComponent("old.sav").path))
        XCTAssertEqual(try Data(contentsOf: keep), Data("latest save".utf8)); XCTAssertEqual(try Data(contentsOf: unrelated), Data("unidentified".utf8))
        XCTAssertTrue(first.pending); XCTAssertTrue(storage.hasPendingSaveClear(gameID: "old")); XCTAssertFalse(storage.hasPendingSaveClear(gameID: "latest"))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateDownload(gameID: "old", generation: nil, isSave: false, storage: storage))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateDownload(gameID: "old", generation: nil, isSave: true, storage: storage))
        XCTAssertNoThrow(try BoundROMUpdateRegistry.validateDownload(gameID: "latest", generation: nil, isSave: true, storage: storage))
        // A version discovered after confirmation is outside the durable deletion scope.
        _ = try target("newly-discovered-old", storage: storage)
        available = true
        let restarted = BoundROMCleanupCoordinator(storage: storage, operations: operations)
        await restarted.prepare() // Pending work retries directly; no new inventory or confirmation.
        XCTAssertEqual(inventories, 1); XCTAssertEqual(cloudAttempts, ["old", "old"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.documents.appendingPathComponent("newly-discovered-old.gba").path))
        XCTAssertFalse(restarted.pending); XCTAssertFalse(storage.hasPendingSaveClear(gameID: "old"))
        XCTAssertEqual(try storage.saveClearRevision(gameID: "old"), plan.id)
        XCTAssertEqual(try BoundROMCleanupJournal(storage: storage).read()?.plan, plan)
        let newTarget = try target("third", storage: storage)
        let nextPlan = BoundROMCleanupPlan(id: UUID(), owner: nil, preserved: latest, targets: [newTarget])
        try BoundROMCleanupJournal(storage: storage).write(.init(plan: nextPlan))
        XCTAssertEqual(try storage.saveClearRevision(gameID: "old"), plan.id, "Later cleanup scopes retain earlier stale-callback fences")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.root.appendingPathComponent("Cleared Saves").path), "Cleanup must not archive deleted bytes")
    }
    func testActiveGameplayAccountChangesChangedFilesAndSymlinksFailClosed() async throws {
        let storage = try storage(), old = try target("old", storage: storage), owner = UUID()
        let plan = BoundROMCleanupPlan(id: UUID(), owner: owner, preserved: latest, targets: [old])
        var idle = false, currentOwner: UUID? = owner, calls = 0
        let operations = BoundROMCleanupCoordinator.Operations(prepare: { plan }, idle: { idle }, owner: { currentOwner }, local: { _ in calls += 1 }, cloud: { _ in calls += 1 })
        let cleanup = BoundROMCleanupCoordinator(storage: storage, operations: operations)
        await cleanup.prepare(); XCTAssertNil(cleanup.preview)
        idle = true; await cleanup.prepare(); currentOwner = UUID(); await cleanup.confirm()
        XCTAssertEqual(calls, 0); XCTAssertNil(try BoundROMCleanupJournal(storage: storage).read())
        currentOwner = owner; await cleanup.confirm(); XCTAssertEqual(calls, 2)
        let second = try target("changed", storage: storage)
        try Data("newer pending save".utf8).write(to: storage.documents.appendingPathComponent("changed.gba"))
        XCTAssertThrowsError(try BoundROMCleanupJournal(storage: storage).delete(second.files))
        let link = storage.documents.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: storage.support)
        XCTAssertThrowsError(try BoundROMCleanupJournal(storage: storage).inventory([link]))
        XCTAssertThrowsError(try BoundROMCleanupJournal(storage: storage).resolve("Documents/../outside"))
    }
    func testJournalRejectsLatestTargetsAndAnyExpansionOfConfirmedPlan() throws {
        let storage = try storage(), old = try target("old", storage: storage), journal = BoundROMCleanupJournal(storage: storage)
        let plan = BoundROMCleanupPlan(id: UUID(), owner: nil, preserved: latest, targets: [old])
        try journal.write(.init(plan: plan))
        let another = try target("other", storage: storage)
        XCTAssertThrowsError(try journal.write(.init(plan: .init(id: plan.id, owner: nil, preserved: latest, targets: [old, another]))))
        XCTAssertThrowsError(try journal.write(.init(plan: .init(id: plan.id, owner: nil, preserved: old.identity, targets: [old]))))
        XCTAssertEqual(try journal.read()?.plan.targets.map(\.id), ["old"])
    }
    func testRecognitionCatalogueKeepsEverySupportedExactProfileAndUsesNoNames() {
        XCTAssertEqual(Set(BoundRecognizedROMs.all.map(\.sha256)).count, BoundRecognizedROMs.all.count)
        for profile in BoundGameProfiles.all {
            XCTAssertTrue(BoundRecognizedROMs.all.contains { $0.gameID == profile.gameID && $0.sha256 == profile.romSHA256 })
        }
    }
    func testOriginalClearSavesCannotExpandOrArchiveAPendingROMCleanup() throws {
        let storage = try storage(), old = try target("old", storage: storage)
        let plan = BoundROMCleanupPlan(id: UUID(), owner: nil, preserved: latest, targets: [old])
        try BoundROMCleanupJournal(storage: storage).write(.init(plan: plan))
        let model = DatabaseManager.shared.managedObjectModel
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let game = Game(context: context); game.identifier = old.id; game.name = old.name; game.filename = "old.gba"
        let manager = BoundROMUpdateManager(defaults: .standard, storage: storage)
        var message: String?
        manager.clearSaves(for: game) { message = $0?.localizedDescription }
        XCTAssertEqual(message, BoundROMUpdateError.clearingROMs.localizedDescription)
        XCTAssertEqual(try BoundROMCleanupJournal(storage: storage).read()?.plan, plan)
        XCTAssertTrue(try storage.pendingSaveClears().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.root.appendingPathComponent("Cleared Saves").path))
        context.reset()
    }
    func testConfirmedRetryCannotRunUnderAnotherAccount() async throws {
        let storage = try storage(), target = try target("account-owned", storage: storage), owner = UUID()
        let plan = BoundROMCleanupPlan(id: UUID(), owner: owner, preserved: latest, targets: [target])
        var current: UUID? = owner, available = false, attempts = 0
        let operations = BoundROMCleanupCoordinator.Operations(prepare: { plan }, idle: { true }, owner: { current },
            local: { _ in }, cloud: { _ in attempts += 1; if !available { throw BoundROMUpdateError.storage } })
        let cleanup = BoundROMCleanupCoordinator(storage: storage, operations: operations)
        await cleanup.prepare(); await cleanup.confirm(); XCTAssertTrue(cleanup.pending); XCTAssertEqual(attempts, 1)
        current = UUID(); available = true
        let restored = BoundROMCleanupCoordinator(storage: storage, operations: operations)
        await restored.retry(); XCTAssertTrue(restored.pending); XCTAssertEqual(attempts, 1)
        current = owner; await restored.retry(); XCTAssertFalse(restored.pending); XCTAssertEqual(attempts, 2)
    }
    func testNakamaDeletionUsesTheConfirmedRunAndRevisionAndExplicitSharedConsent() async throws {
        let owner = UUID(), run = UUID()
        let payload = try JSONSerialization.data(withJSONObject: ["sub": owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
        let token = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let session = try AppCloudSession(owner: owner, key: "fixture", token: "e30.\(token).fixture", backend: .init(kind: .legacy, origin: "https://bound.example"))
        let service = BoundNakamaRunService(authorizeSaves: { identity, _ in
            XCTAssertEqual(identity.owner, owner)
            return .init(httpEndpoint: URL(string: "https://bound.example")!, accessToken: "fixture-token", ownerID: owner,
                expiresAt: Date().timeIntervalSince1970 + 90, saveTicket: "fixture-ticket", partnerID: nil, roomID: nil)
        }, perform: { request in
            let text = try JSONDecoder().decode(String.self, from: XCTUnwrap(request.httpBody))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(body["action"] as? String, "delete"); XCTAssertEqual(body["save_id"] as? String, run.uuidString.lowercased())
            XCTAssertEqual(body["expectedRevision"] as? Int, 42); XCTAssertEqual(body["confirmSharedDeletion"] as? Bool, true)
            XCTAssertNil(body["ownerID"]); XCTAssertNil(body["gameID"])
            return try JSONSerialization.data(withJSONObject: ["payload": "{}"])
        })
        _ = try await service.configureSaves(session: session); try await service.deleteSave(run, expectedRevision: 42)
    }
    func testManualSettingsControlAndSingleConfirmationRenderWithPartnerWarningFirst() async throws {
        let storage = try storage(), original = try target("old", storage: storage), run = UUID()
        let shared = BoundROMCleanupPlan.Target(identity: original.identity, name: original.name, filename: original.filename,
            files: original.files, stateIDs: [], cloud: original.cloud, dropbox: [],
            runs: [.init(id: run, revision: 42, participants: [UUID(), UUID()])], serverBackup: false)
        let plan = BoundROMCleanupPlan(id: UUID(), owner: nil, preserved: latest, targets: [shared])
        let warning = try XCTUnwrap(plan.summary.range(of: "both your progress and your partner’s progress"))
        XCTAssertLessThan(warning.lowerBound, try XCTUnwrap(plan.summary.range(of: shared.name)).lowerBound)
        XCTAssertTrue(plan.summary.contains(run.uuidString)); XCTAssertTrue(plan.summary.contains("old.sav"))
        var mutations = 0
        let cleanup = BoundROMCleanupCoordinator(storage: storage, operations: .init(prepare: { plan }, idle: { true }, owner: { nil }, local: { _ in mutations += 1 }, cloud: { _ in mutations += 1 }))
        await cleanup.prepare()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ROMCleanupVisualQA")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func capture<V: View>(_ view: V, name: String) async throws {
            let host = UIHostingController(rootView: view); host.overrideUserInterfaceStyle = .dark
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 740)
            for _ in 0..<5 { host.view.layoutIfNeeded(); await Task.yield(); try await Task.sleep(for: .milliseconds(40)) }
            let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let data = try XCTUnwrap(image.pngData()); XCTAssertGreaterThan(data.count, 1000)
            try data.write(to: output.appendingPathComponent(name + ".png"))
            let attachment = XCTAttachment(image: image); attachment.lifetime = .keepAlways; add(attachment)
        }
        try await capture(SettingsView(), name: "settings-clear-roms")
        try await capture(BoundROMCleanupConfirmation(cleanup: cleanup), name: "single-confirmation")
        XCTAssertEqual(mutations, 0, "Rendering and dismissing a preview never deletes data")
    }
    func testSignedOutCannotTreatAnUnknownCloudInventoryAsEmpty() async throws {
        guard BoundFriendAccount.shared.session == nil else { throw XCTSkip("Requires isolated signed-out QA app") }
        for _ in 0..<100 where !BoundROMCleanupLive.idle { try await Task.sleep(for: .milliseconds(20)) }
        do { _ = try await BoundROMCleanupLive.operations(storage: .live).prepare(); XCTFail("Cloud ownership must be established before confirmation") }
        catch { XCTAssertTrue(error is BoundROMCleanupError); XCTAssertEqual(error.localizedDescription, BoundROMCleanupError.signIn.localizedDescription) }
    }
    func testActualLibraryDeletionPreservesInstalledCurrentROMEntryLatestSavesAndUnrelatedGame() async throws {
        guard SyncManager.shared.coordinator == nil, BoundROMUpdateActivity.canApply else { throw XCTSkip("Requires the isolated signed-out QA app") }
        let fixtures = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MultiRedProfilesQA")
        let latestURL = try BoundROMTestFixture.currentURL()
        _ = try BoundROMTestFixture.currentData()
        let historical = ProcessInfo.processInfo.environment["BOUND_QA_ORIGINAL_ROM_FIXTURE"].map { URL(fileURLWithPath: $0) }
            ?? fixtures.appendingPathComponent("original.gba")
        guard FileManager.default.fileExists(atPath: historical.path) else {
            throw XCTSkip("Exact real-cartridge cleanup requires the verified original profile cartridge via BOUND_QA_ORIGINAL_ROM_FIXTURE or isolated MultiRedProfilesQA/original.gba; it is not bundled")
        }
        let identity = try XCTUnwrap(BoundRecognizedROMs.all.first { $0.gameID == BoundGameProfiles.original.gameID })
        let bytes = try Data(contentsOf: historical)
        let verifiedHistorical = try BoundROMUpdateContent(data: bytes, expectedSHA256: identity.sha256)
        guard verifiedHistorical.gameID == identity.gameID else { throw BoundROMUpdateError.incompatibleROM }
        let context = DatabaseManager.shared.viewContext
        func game(_ id: String) throws -> Game? {
            let request = Game.fetchRequest() as! NSFetchRequest<Game>; request.predicate = NSPredicate(format: "identifier == %@", id)
            return try context.fetch(request).first
        }
        guard try game(identity.gameID) == nil else { throw XCTSkip("Requires an isolated QA library without a pre-existing historical entry") }
        let existing = try game(BoundGameProfiles.current.gameID), previousName = existing?.name
        try await BoundROMUpdateManager.shared.installBundledROM(from: latestURL, name: "RRv4.1M")
        let current = try XCTUnwrap(game(BoundGameProfiles.current.gameID)), originalROM = try Data(contentsOf: current.fileURL)
        let previousSave = try? Data(contentsOf: current.gameSaveURL)
        let currentSave = Data("LATEST SAVE MUST SURVIVE CLEANUP".utf8)
        try currentSave.write(to: current.gameSaveURL)
        defer {
            if existing == nil {
                if !current.isDeleted { context.delete(current); try? context.save() }
            } else {
                if let previousName { current.name = previousName; try? context.save() }
                if let previousSave { try? previousSave.write(to: current.gameSaveURL) }
                else { try? FileManager.default.removeItem(at: current.gameSaveURL) }
            }
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CleanupImports-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let oldInput = temporary.appendingPathComponent("Manually imported.gba"), otherInput = temporary.appendingPathComponent("Multi Red unrelated.gba")
        try bytes.write(to: oldInput); try Data(("unidentified ROM " + UUID().uuidString).utf8).write(to: otherInput)
        let imported: Set<Game> = try await withCheckedThrowingContinuation { continuation in
            DatabaseManager.shared.importGames(at: [oldInput, otherInput]) { games, errors in
                if errors.isEmpty { continuation.resume(returning: games) } else { continuation.resume(throwing: BoundROMUpdateError.storage) }
            }
        }
        let old = try XCTUnwrap(imported.first { $0.identifier == identity.gameID }), other = try XCTUnwrap(imported.first { $0.identifier != identity.gameID })
        let otherBytes = try Data(contentsOf: other.fileURL), oldURL = old.fileURL, oldSave = old.gameSaveURL
        try Data("historical save".utf8).write(to: oldSave)
        let oldState = SaveState(context: context); oldState.game = old; oldState.type = .general
        let latestState = SaveState(context: context); latestState.game = current; latestState.type = .general
        let oldStateURL = oldState.fileURL, oldImageURL = oldState.imageFileURL, latestStateURL = latestState.fileURL
        try Data("old state".utf8).write(to: oldStateURL); try Data("old thumbnail".utf8).write(to: oldImageURL)
        try Data("latest state".utf8).write(to: latestStateURL); try context.save()
        defer {
            context.delete(latestState)
            for item in imported where !item.isDeleted { context.delete(item) }; try? context.save()
            for url in [oldURL, oldSave, temporary] { try? FileManager.default.removeItem(at: url) }
        }
        let storage = BoundROMUpdateStorage.live
        for _ in 0..<100 where !BoundROMCleanupLive.idle { try await Task.sleep(for: .milliseconds(20)) }
        let operations = BoundROMCleanupLive.operations(storage: storage)
        let preserved = try BoundROMCleanupLive.latest()
        let identities = BoundRecognizedROMs.all.filter { $0.gameID != preserved.gameID }
        let inventory = try BoundROMCleanupLive.localInventory(storage: storage, preserved: preserved, identities: identities)
        let candidate = try XCTUnwrap(inventory[identity.gameID])
        XCTAssertNil(inventory[current.identifier]); XCTAssertNil(inventory[other.identifier])
        XCTAssertEqual(preserved.gameID, current.identifier)
        let target = BoundROMCleanupPlan.Target(identity: identity, name: candidate.0, filename: candidate.1,
            files: try BoundROMCleanupJournal(storage: storage).inventory(candidate.2), stateIDs: candidate.3,
            cloud: .init(owner: nil, connection: nil, dropboxAccountID: nil, includesDropbox: false, saveStateIDs: candidate.3),
            dropbox: [], runs: [], serverBackup: false)
        XCTAssertTrue(target.files.contains { $0.sha256 == identity.sha256 })
        let latestRAM = BoundServerMemoryFiles.snapshot(gameID: current.identifier)
        BoundServerMemoryFiles.setEnabled(true, for: old.identifier)
        try BoundServerMemoryFiles.restore(["Soul Link/cleanup-fixture.json": Data("old working copy".utf8)], gameID: old.identifier)
        defer { BoundServerMemoryFiles.setEnabled(false, for: identity.gameID) }
        try await operations.local(target)
        XCTAssertTrue(BoundServerMemoryFiles.snapshot(gameID: identity.gameID).isEmpty)
        XCTAssertEqual(BoundServerMemoryFiles.snapshot(gameID: current.identifier), latestRAM)
        context.refreshAllObjects()
        XCTAssertNil(try game(identity.gameID)); XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: oldSave.path))
        XCTAssertEqual(try game(current.identifier)?.objectID, current.objectID)
        XCTAssertEqual(try Data(contentsOf: current.fileURL), originalROM); XCTAssertEqual(try Data(contentsOf: current.gameSaveURL), currentSave)
        XCTAssertEqual(try Data(contentsOf: other.fileURL), otherBytes)
        XCTAssertNotNil(try game(other.identifier))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldStateURL.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: oldImageURL.path))
        XCTAssertEqual(try Data(contentsOf: latestStateURL), Data("latest state".utf8))
    }
}
