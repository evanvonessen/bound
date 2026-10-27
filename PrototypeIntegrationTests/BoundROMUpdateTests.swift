import XCTest
import CryptoKit
@testable import Delta

final class BoundROMUpdateTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let storage: BoundROMUpdateStorage
        func file(_ path: String, _ bytes: Data) throws -> URL {
            let url = storage.documents.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            return url
        }
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ROMUpdates-" + UUID().uuidString)
        let documents = root.appendingPathComponent("Documents"), support = root.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(root: root, storage: .init(root: support.appendingPathComponent("ROM Updates"), documents: documents, support: support))
    }
    private func content(_ byte: UInt8) throws -> (BoundROMUpdateContent, Data) {
        let data = Data(repeating: byte, count: 64)
        return (try .init(data: data, expectedSHA256: BoundROMUpdateContent.hash(data), expectedByteCount: data.count), data)
    }
    private func profileContent(_ profile: BoundGameProfile) throws -> BoundROMUpdateContent {
        try JSONDecoder().decode(BoundROMUpdateContent.self, from: JSONSerialization.data(withJSONObject: [
            "gameID": profile.gameID, "sha256": profile.romSHA256
        ]))
    }
    private func finish(_ storage: BoundROMUpdateStorage, _ value: BoundROMUpdateStorage.Transaction) throws {
        var transaction = value
        try storage.makeBackup(&transaction)
        try storage.resetFiles(&transaction)
        try storage.complete(transaction)
    }
    private func proof(_ generation: String?, localNormal: Bool = true, remoteNormal: Bool = true,
                       conflicted: Bool = false, locked: Bool = false) -> BoundROMUpdateResetPolicy.Proof {
        .init(generation: generation, localNormal: localNormal, remoteNormal: remoteNormal, conflicted: conflicted, locked: locked)
    }

    func testClearSavesIncludesOnlySelectedCooperativeRecoveryAndReleasesItsFenceAfterCommit() throws {
        let f=try fixture(),folder=f.storage.support.appendingPathComponent("Cooperative Battles")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let selected=try f.file("Database/Games/selected.sav",Data([1])),otherSave=try f.file("Database/Games/other.sav",Data([2]))
        func recovery(_ gameID:String)->(URL,URL) {
            (folder.appendingPathComponent(UUID().uuidString+".json"),folder.appendingPathComponent(UUID().uuidString+".state"))
        }
        let target=recovery("selected"),other=recovery("other")
        for (id,pair) in [("selected",target),("other",other)] {
            try JSONSerialization.data(withJSONObject:["gameID":id,"state":pair.1.lastPathComponent,"phase":5,"token":42]).write(to:pair.0)
            try Data([3,4]).write(to:pair.1)
        }
        let paths=try f.storage.cooperativeRecoveryFiles(gameID:"selected")
        XCTAssertEqual(Set(paths),Set([target.0,target.1]))
        XCTAssertTrue(BoundVBABattleBridge.setCooperativeGameSaveAllowed(false,for:selected))
        XCTAssertTrue(BoundVBABattleBridge.setCooperativeGameSaveAllowed(false,for:otherSave))
        defer { _=BoundVBABattleBridge.setCooperativeGameSaveAllowed(true,for:selected);_=BoundVBABattleBridge.setCooperativeGameSaveAllowed(true,for:otherSave) }
        XCTAssertThrowsError(try f.storage.clearSaveFiles([selected]+paths,cooperativeGameSaveURL:selected) { throw BoundROMUpdateError.storage })
        XCTAssertEqual(try Data(contentsOf:target.1),Data([3,4]));XCTAssertTrue(FileManager.default.fileExists(atPath:target.0.path))
        XCTAssertTrue(BoundVBABattleBridge.qaCooperativeGameSaveBlocked(selected))
        try f.storage.clearSaveFiles([selected]+paths,cooperativeGameSaveURL:selected) {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.0.path));XCTAssertFalse(FileManager.default.fileExists(atPath:target.1.path))
        XCTAssertFalse(BoundVBABattleBridge.qaCooperativeGameSaveBlocked(selected))
        XCTAssertTrue(BoundVBABattleBridge.qaCooperativeGameSaveBlocked(otherSave))
        XCTAssertEqual(try Data(contentsOf:otherSave),Data([2]));XCTAssertEqual(try Data(contentsOf:other.1),Data([3,4]))
        XCTAssertTrue(FileManager.default.fileExists(atPath:other.0.path))
    }
    func testClearSavesRejectsCooperativeRecoveryStatePathEscape() throws {
        let f=try fixture(),folder=f.storage.support.appendingPathComponent("Cooperative Battles")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let journal=folder.appendingPathComponent(UUID().uuidString+".json")
        try JSONSerialization.data(withJSONObject:["gameID":"selected","state":"../"+UUID().uuidString+".state","phase":5]).write(to:journal)
        XCTAssertThrowsError(try f.storage.cooperativeRecoveryFiles(gameID:"selected"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:journal.path))
    }
    func testClearSavesOnlyRemovesSelectedFilesAndRetainsBackup() throws {
        let f = try fixture()
        let selected = try f.file("Database/Games/selected.sav", Data([1, 2]))
        let other = try f.file("Database/Games/other.sav", Data([3]))
        let rom = try f.file("Database/Games/selected.gba", Data([4]))
        let state = try f.file("Database/Save States/selected/manual", Data([5]))
        var committed = false
        try f.storage.clearSaveFiles([selected, state.deletingLastPathComponent()]) { committed = true }
        XCTAssertTrue(committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        XCTAssertEqual(try Data(contentsOf: other), Data([3]))
        XCTAssertEqual(try Data(contentsOf: rom), Data([4]))
        let backups = try FileManager.default.contentsOfDirectory(at: f.storage.root.appendingPathComponent("Cleared Saves"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("0")), Data([1, 2]))
    }

    func testClearSavesRestoresFilesIfDatabaseCommitFails() throws {
        let f = try fixture()
        let selected = try f.file("Database/Games/selected.sav", Data([1, 2]))
        XCTAssertThrowsError(try f.storage.clearSaveFiles([selected]) { throw BoundROMUpdateError.storage })
        XCTAssertEqual(try Data(contentsOf: selected), Data([1, 2]))
    }

    func testClearSavesRejectsPathsOutsideSaveStorage() throws {
        let f = try fixture()
        XCTAssertThrowsError(try f.storage.clearSaveFiles([f.root.appendingPathComponent("outside")]) {})
    }

    func testPendingSaveClearSurvivesRelaunchAndBlocksOnlySelectedROMSync() throws {
        let f = try fixture()
        let pending = try f.storage.beginSaveClear(gameID: "selected", gameName: "Selected", cloudContext: Data("owner-A".utf8))
        let restarted = BoundROMUpdateStorage(root: f.storage.root, documents: f.storage.documents, support: f.storage.support)
        XCTAssertEqual(try restarted.pendingSaveClear(gameID: "selected"), pending)
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateDownload(gameID: "selected", generation: nil, isSave: true, storage: restarted))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateRestore(gameID: "selected", generation: nil, version: "old", currentVersion: "old", isLocked: false, storage: restarted))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateUpload(gameID: "selected", storage: restarted))
        XCTAssertNoThrow(try BoundROMUpdateRegistry.validateDownload(gameID: "other", generation: nil, isSave: true, storage: restarted))
        XCTAssertNoThrow(try BoundROMUpdateRegistry.validateUpload(gameID: "other", storage: restarted))
        XCTAssertNoThrow(try BoundROMUpdateRegistry.validateDownload(gameID: "selected", generation: nil, isSave: false, storage: restarted))
    }

    func testSaveClearRetryRetainsOriginalCloudAccountAndOnlyCompletesItsROM() throws {
        let f = try fixture()
        let first = try f.storage.beginSaveClear(gameID: "selected", gameName: "Selected", cloudContext: Data("owner-A".utf8))
        let other = try f.storage.beginSaveClear(gameID: "other", gameName: "Other", cloudContext: Data())
        let retry = try f.storage.beginSaveClear(gameID: "selected", gameName: "Changed name", cloudContext: Data("owner-B".utf8))
        XCTAssertEqual(retry, first)
        try f.storage.completeSaveClear(first)
        XCTAssertFalse(f.storage.hasPendingSaveClear(gameID: "selected"))
        XCTAssertEqual(try f.storage.pendingSaveClears(), [other])
        XCTAssertNoThrow(try BoundROMUpdateRegistry.validateUpload(gameID: "selected", storage: f.storage))
    }

    func testCompletedClearStillInvalidatesPreviouslyQueuedSaveWork() throws {
        let f = try fixture()
        let before = try f.storage.saveClearRevision(gameID: "selected")
        let pending = try f.storage.beginSaveClear(gameID: "selected", gameName: "Selected", cloudContext: Data())
        XCTAssertNotEqual(try f.storage.saveClearRevision(gameID: "selected"), before)
        try f.storage.completeSaveClear(pending)
        XCTAssertEqual(try f.storage.saveClearRevision(gameID: "selected"), pending.id)
        let again = try f.storage.beginSaveClear(gameID: "selected", gameName: "Selected", cloudContext: Data())
        XCTAssertNotEqual(again.id, pending.id)
        XCTAssertThrowsError(try f.storage.completeSaveClear(pending))
        XCTAssertTrue(f.storage.hasPendingSaveClear(gameID: "selected"))
    }

    func testUnreadableSaveClearReceiptKeepsROMBlocked() throws {
        let f = try fixture()
        _ = try f.storage.beginSaveClear(gameID: "selected", gameName: "Selected", cloudContext: Data())
        let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: f.storage.root.appendingPathComponent("Pending Save Clears"), includingPropertiesForKeys: nil).first)
        try Data("invalid".utf8).write(to: url, options: .atomic)
        XCTAssertTrue(f.storage.hasPendingSaveClear(gameID: "selected"))
        XCTAssertThrowsError(try f.storage.pendingSaveClear(gameID: "selected"))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateDownload(gameID: "selected", generation: nil, isSave: true, storage: f.storage))
        XCTAssertFalse(f.storage.hasPendingSaveClear(gameID: "other"))
    }

    func testBundledCartridgeMatchesCommittedContract() throws {
        let bundle = Bundle(for: Game.self)
        let url = try XCTUnwrap(bundle.url(forResource: "multiplayer", withExtension: "gba"))
        let data = try Data(contentsOf: url)
        _ = try BoundROMUpdateContent(data: data, expectedSHA256: BoundPlayerROMProfile.supportedSHA256)
        _ = try BoundPlayerROMProfile(rom: data)
    }

    func testROMCandidateRejectsPartialAndWrongContentWithoutTouchingOriginals() throws {
        let f = try fixture(), bytes = Data(repeating: 3, count: 64)
        let original = try f.file("Games/original.sav", Data([8, 9]))
        let expected = BoundROMUpdateContent.hash(bytes)
        XCTAssertThrowsError(try BoundROMUpdateContent(data: bytes, expectedSHA256: expected))
        XCTAssertThrowsError(try BoundROMUpdateContent(data: bytes, expectedSHA256: String(repeating: "a", count: 64), expectedByteCount: 64))
        XCTAssertEqual(try Data(contentsOf: original), Data([8, 9]))
        XCTAssertNil(try f.storage.pending())
        let value = try BoundROMUpdateContent(data: bytes, expectedSHA256: expected, expectedByteCount: 64)
        XCTAssertEqual(value.gameID, Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    func testInitialEnrollmentPreservesExistingSaveAndDoesNotResetAgain() throws {
        let f = try fixture(), (rom, data) = try content(1)
        let battery = try f.file("Games/current.sav", Data([4, 5]))
        let source = try f.storage.source(for: battery, remove: false)
        let transaction = try f.storage.begin(content: rom, data: data, sources: [source], metadata: Data(), resetGameIDs: [])
        try finish(f.storage, transaction)
        XCTAssertEqual(try Data(contentsOf: battery), Data([4, 5]))
        XCTAssertEqual(try f.storage.state().current, rom)
        XCTAssertFalse(try f.storage.state().requiresGeneration)
        XCTAssertNil(try f.storage.pending())
        // Re-enrolling the same content does not create a reset generation.
        let same = try f.storage.begin(content: rom, data: data, sources: [source], metadata: Data(), resetGameIDs: [], enrollment: rom)
        try finish(f.storage, same)
        XCTAssertEqual(try Data(contentsOf: battery), Data([4, 5]))
        XCTAssertFalse(try f.storage.state().requiresGeneration)
    }

    func testMixedIncomingSavesPreserveFreshBatteryManualStateAndRecoveryAcrossRestart() throws {
        let f = try fixture(), (old, _) = try content(1), (next, data) = try content(2)
        let battery = try f.file("Games/new.sav", Data([1, 2, 3]))
        let fresh = try f.file("States/new/manual-new", Data([4]))
        let auto = try f.file("States/new/auto-old", Data([5]))
        let manual = try f.file("States/new/manual-old", Data([6]))
        let recovery = try f.file("Recovery/new.state", Data([7]))
        let unrelated = try f.file("Games/unrelated.sav", Data([8]))
        let sources = try [(battery, false), (fresh, false), (auto, true), (manual, true), (recovery, false)].map {
            try f.storage.source(for: $0.0, remove: $0.1)
        }
        var transaction = try f.storage.begin(content: next, data: data, sources: sources, metadata: Data("metadata".utf8),
            resetGameIDs: [old.gameID, next.gameID], enrollment: old,
            preservedIncoming: .init(battery: true, stateIDs: ["manual-new"]))
        try f.storage.makeBackup(&transaction)
        // Simulate termination after the first removal and before filesReset.
        try FileManager.default.removeItem(at: auto)
        let restarted = BoundROMUpdateStorage(root: f.storage.root, documents: f.storage.documents, support: f.storage.support)
        var replay = try XCTUnwrap(restarted.pending())
        XCTAssertTrue(replay.preservedIncoming.battery)
        XCTAssertEqual(replay.preservedIncoming.stateIDs, ["manual-new"])
        try restarted.makeBackup(&replay)
        try restarted.resetFiles(&replay)
        XCTAssertFalse(FileManager.default.fileExists(atPath: auto.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manual.path))
        XCTAssertEqual(try Data(contentsOf: battery), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: fresh), Data([4]))
        XCTAssertEqual(try Data(contentsOf: recovery), Data([7]))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([8]))
        let savedOld = restarted.backupDirectory(replay).appendingPathComponent("Originals/Documents/States/new/manual-old")
        XCTAssertEqual(try Data(contentsOf: savedOld), Data([6]))
        try restarted.complete(replay)
        XCTAssertNil(try restarted.pending())
        XCTAssertEqual(try restarted.state().current, next)
        XCTAssertTrue(try restarted.state().retiredGameIDs.contains(old.gameID))
    }

    func testCompletedReceiptOnlyCleansResurrectedJournalAndKeepsFreshGameplay() throws {
        let f = try fixture(), (old, _) = try content(1), (next, data) = try content(2)
        let battery = try f.file("Games/new.sav", Data([1]))
        var transaction = try f.storage.begin(content: next, data: data,
            sources: [f.storage.source(for: battery, remove: true)], metadata: Data(),
            resetGameIDs: [old.gameID, next.gameID], enrollment: old)
        try f.storage.makeBackup(&transaction)
        try f.storage.resetFiles(&transaction)
        let pendingBytes = try Data(contentsOf: f.storage.journalURL)
        try f.storage.complete(transaction)
        try Data([9, 9]).write(to: battery)
        try pendingBytes.write(to: f.storage.journalURL)
        let replay = try XCTUnwrap(f.storage.pending())
        XCTAssertTrue(try f.storage.finishCompleted(replay))
        XCTAssertNil(try f.storage.pending())
        XCTAssertEqual(try Data(contentsOf: battery), Data([9, 9]))
    }

    func testChangedSourceOrCorruptBackupNeverDeletesOriginal() throws {
        let f = try fixture(), (old, _) = try content(1), (next, data) = try content(2)
        let battery = try f.file("Games/old.sav", Data([1]))
        var transaction = try f.storage.begin(content: next, data: data,
            sources: [f.storage.source(for: battery, remove: true)], metadata: Data(),
            resetGameIDs: [old.gameID, next.gameID], enrollment: old)
        try f.storage.makeBackup(&transaction)
        try Data([2]).write(to: battery)
        XCTAssertThrowsError(try f.storage.resetFiles(&transaction))
        XCTAssertEqual(try Data(contentsOf: battery), Data([2]))
        try Data([1]).write(to: battery)
        let backup = f.storage.backupDirectory(transaction).appendingPathComponent("Originals/Documents/Games/old.sav")
        try Data([7]).write(to: backup)
        XCTAssertThrowsError(try f.storage.resetFiles(&transaction))
        XCTAssertEqual(try Data(contentsOf: battery), Data([1]))
        XCTAssertNotNil(try f.storage.pending())
    }

    func testRetiredROMCannotBeReintroducedAsAnUpdate() throws {
        let f = try fixture(), (old, oldData) = try content(1), (next, nextData) = try content(2)
        let transaction = try f.storage.begin(content: next, data: nextData, sources: [], metadata: Data(),
            resetGameIDs: [old.gameID, next.gameID], enrollment: old)
        try finish(f.storage, transaction)
        XCTAssertThrowsError(try f.storage.begin(content: old, data: oldData, sources: [], metadata: Data(),
            resetGameIDs: [old.gameID, next.gameID]))
        XCTAssertEqual(try f.storage.state().current, next)
        XCTAssertNil(try f.storage.pending())
    }

    func testOriginalAndCurrentProfilesStaySeparateWithoutChangingOrdinaryResetPolicy() throws {
        let original = try profileContent(BoundGameProfiles.original), current = try profileContent(BoundGameProfiles.current)
        XCTAssertTrue(BoundROMUpdateContent.preservesPrevious(original, incoming: current))
        XCTAssertEqual(try BoundROMUpdateContent.resetGameIDs(previous: original, incoming: current), [])
        let (ordinary, _) = try content(1), (updated, _) = try content(2)
        XCTAssertEqual(try BoundROMUpdateContent.resetGameIDs(previous: ordinary, incoming: updated), [ordinary.gameID, updated.gameID])
        XCTAssertThrowsError(try BoundROMUpdateContent.resetGameIDs(previous: original, incoming: updated))
        for mismatched in [
            ["gameID": original.gameID, "sha256": current.sha256],
            ["gameID": ordinary.gameID, "sha256": original.sha256],
            ["gameID": current.gameID, "sha256": ordinary.sha256]
        ] {
            let wrong = try JSONDecoder().decode(BoundROMUpdateContent.self, from: JSONSerialization.data(withJSONObject: mismatched))
            XCTAssertThrowsError(try BoundROMUpdateContent.resetGameIDs(previous: wrong, incoming: current))
            XCTAssertThrowsError(try BoundROMUpdateContent.resetGameIDs(previous: ordinary, incoming: wrong))
        }
        let bundle = Bundle(for: Game.self)
        let data = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "multiplayer", withExtension: "gba")))
        XCTAssertEqual(try BoundROMUpdateContent.enrollment(data: data, gameID: current.gameID), current)
        XCTAssertThrowsError(try BoundROMUpdateContent.enrollment(data: data, gameID: original.gameID))
        XCTAssertThrowsError(try BoundROMUpdateContent(data: data, expectedSHA256: original.sha256))
    }

    func testEveryRetainedExactProfileIsPreservedByCandidateEnrollment() throws {
        let incoming = try profileContent(BoundGameProfiles.current)
        let (unrelated, _) = try content(2)
        for profile in BoundGameProfiles.all where profile != BoundGameProfiles.current {
            let previous = try profileContent(profile)
            XCTAssertTrue(BoundROMUpdateContent.preservesPrevious(previous, incoming: incoming))
            XCTAssertEqual(try BoundROMUpdateContent.resetGameIDs(previous: previous, incoming: incoming), [])
            XCTAssertThrowsError(try BoundROMUpdateContent.resetGameIDs(previous: previous, incoming: unrelated))
        }
    }

    func testSideBySideUpdatePreservesOriginalFilesAndExistingGenerationFenceAcrossRestart() throws {
        let f = try fixture(), original = try profileContent(BoundGameProfiles.original)
        let data = try Data(contentsOf: XCTUnwrap(Bundle(for: Game.self).url(forResource: "multiplayer", withExtension: "gba")))
        let current = try BoundROMUpdateContent(data: data, expectedSHA256: BoundGameProfiles.current.romSHA256)
        let oldState = BoundROMUpdateStorage.State(current: original, requiresGeneration: true)
        try FileManager.default.createDirectory(at: f.storage.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(oldState).write(to: f.storage.stateURL)
        let originalReceiptBytes = try Data(contentsOf: f.storage.stateURL)
        let battery = try f.file("Database/Games/" + original.gameID + ".sav", Data([1, 2, 3]))
        let snapshot = try f.file("Database/Save States/" + original.gameID + "/manual.state", Data([4, 5]))
        let sources = try [battery, snapshot].map { try f.storage.source(for: $0, remove: false) }
        let value = try f.storage.begin(content: current, data: data, sources: sources, metadata: Data(),
            resetGameIDs: BoundROMUpdateContent.resetGameIDs(previous: original, incoming: current))
        XCTAssertTrue(value.resetGameIDs.isEmpty)
        XCTAssertFalse(value.nextState.retiredGameIDs.contains(original.gameID))
        XCTAssertEqual(try Data(contentsOf: f.storage.backupDirectory(value).appendingPathComponent("previous-updater-state.json")), originalReceiptBytes)
        try finish(f.storage, value)
        let reopened = BoundROMUpdateStorage(root: f.storage.root, documents: f.storage.documents, support: f.storage.support)
        XCTAssertEqual(try Data(contentsOf: battery), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: snapshot), Data([4, 5]))
        XCTAssertEqual(try reopened.state().current, current)
        XCTAssertEqual(BoundROMUpdateRegistry.generation(for: original.gameID, storage: reopened), original.sha256)
        XCTAssertNil(BoundROMUpdateRegistry.generation(for: current.gameID, storage: reopened))
        XCTAssertNoThrow(try BoundROMUpdateRegistry.validateUpload(gameID: original.gameID, storage: reopened))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateDownload(gameID: original.gameID, generation: nil, isSave: true, storage: reopened))
        XCTAssertNoThrow(try BoundROMUpdateRegistry.validateDownload(gameID: original.gameID, generation: original.sha256, isSave: true, storage: reopened))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateRestore(gameID: original.gameID, generation: original.sha256,
            version: "old", currentVersion: "head", isLocked: false, storage: reopened))
        XCTAssertNoThrow(try BoundROMUpdateRegistry.validateRestore(gameID: original.gameID, generation: original.sha256,
            version: "head", currentVersion: "head", isLocked: false, storage: reopened))
    }

    func testOldDestructivePendingUpdateCannotResetOrNewlyRetireTheOriginalProfile() throws {
        let f = try fixture(), original = try profileContent(BoundGameProfiles.original), current = try profileContent(BoundGameProfiles.current)
        let battery = try f.file("Database/Games/" + original.gameID + ".sav", Data([7, 8]))
        var transaction = BoundROMUpdateStorage.Transaction(id: UUID(), content: current,
            nextState: .init(current: current, retiredGameIDs: [original.gameID], requiresGeneration: true),
            resetGameIDs: [original.gameID, current.gameID], sources: [try f.storage.source(for: battery, remove: true)], metadata: Data())
        try f.storage.save(transaction)
        XCTAssertThrowsError(try f.storage.makeBackup(&transaction))
        transaction.backupComplete = true
        XCTAssertThrowsError(try f.storage.resetFiles(&transaction))
        XCTAssertThrowsError(try f.storage.installROM(transaction, destination: battery))
        transaction.filesReset = true
        XCTAssertThrowsError(try f.storage.complete(transaction))
        XCTAssertEqual(try Data(contentsOf: battery), Data([7, 8]))
        XCTAssertNotNil(try f.storage.pending())
        // Historical retirement is not silently cleared just because its gameID
        // appears in the new adapter registry.
        try FileManager.default.removeItem(at: f.storage.journalURL)
        try JSONEncoder().encode(transaction.nextState).write(to: f.storage.stateURL)
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateDownload(gameID: original.gameID, generation: original.sha256, isSave: false, storage: f.storage))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateUpload(gameID: original.gameID, storage: f.storage))
    }

    func testOlderUpdaterReceiptsDecodeWithoutAddingGenerationMetadata() throws {
        let (current, _) = try content(1)
        let bytes = try JSONSerialization.data(withJSONObject: [
            "current": ["gameID": current.gameID, "sha256": current.sha256],
            "retiredGameIDs": [], "requiresGeneration": false
        ])
        let state = try JSONDecoder().decode(BoundROMUpdateStorage.State.self, from: bytes)
        XCTAssertNil(state.preservedGenerations)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        XCTAssertNil(object["preservedGenerations"])
        var empty = state; empty.preservedGenerations = [:]
        let emptyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(empty)) as? [String: Any])
        XCTAssertNil(emptyObject["preservedGenerations"])
    }

    func testPathsCannotEscapeSandboxOrBackUpUpdaterJournalItself() throws {
        let f = try fixture()
        XCTAssertThrowsError(try f.storage.resolve("Documents/../outside"))
        XCTAssertThrowsError(try f.storage.resolve("Support/ROM Updates"))
        XCTAssertThrowsError(try f.storage.resolve("Support/ROM Updates/pending.json"))
        let outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = f.storage.documents.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try f.storage.resolve("Documents/linked/save.sav"))
    }

    func testPerRecordProofAdoptsFreshCloudProgressAndResetsOldLocalStates() {
        let fresh = proof("new"), old = proof("old")
        XCTAssertEqual(BoundROMUpdateResetPolicy.incoming(generation: "new", objectCount: 1, proofs: [fresh]), .adopt)
        XCTAssertEqual(BoundROMUpdateResetPolicy.incoming(generation: "new", objectCount: 1, proofs: [old]), .resetLocal)
        XCTAssertEqual(BoundROMUpdateResetPolicy.incoming(generation: "new", objectCount: 1, proofs: []), .resetLocal)
        for pending in [proof("new", localNormal: false), proof("new", remoteNormal: false),
                        proof("new", conflicted: true), proof("new", locked: true)] {
            XCTAssertEqual(BoundROMUpdateResetPolicy.incoming(generation: "new", objectCount: 1, proofs: [pending]), .waitForSync)
        }
    }

    func testCanonicalBatteryAdoptionDefersUnresolvedMultiplayerImportAndMismatchedBytes() throws {
        let hash = Insecure.SHA1.hash(data: Data([1, 2, 3])).map { String(format: "%02x", $0) }.joined()
        func check(_ unresolved: Bool = false, _ interrupted: Bool = false, remote: String? = "run", canonical: String? = "run", bytes: Data? = Data([1, 2, 3])) throws {
            try BoundROMUpdateResetPolicy.validateCanonicalBattery(bytes, expectedSHA1: hash,
                unresolvedImport: unresolved, interruptedRestore: interrupted, remoteRun: remote,
                canonicalRun: canonical, canonicalROM: "generation", generation: "generation")
        }
        XCTAssertNoThrow(try check())
        XCTAssertNoThrow(try check(remote: nil, canonical: nil))
        XCTAssertThrowsError(try check(true))
        XCTAssertThrowsError(try check(false, true))
        XCTAssertThrowsError(try check(canonical: "old-run"))
        XCTAssertThrowsError(try check(canonical: nil))
        XCTAssertThrowsError(try check(remote: nil))
        XCTAssertThrowsError(try check(bytes: Data([9])))
        XCTAssertThrowsError(try check(bytes: nil))
    }

    func testResetNeverDeletesIncomingCanonicalCloudSaveRecordOrUploadsMissingBattery() throws {
        XCTAssertFalse(BoundROMUpdateResetPolicy.deletesGameSave(gameID: "new", incomingID: "new"))
        XCTAssertTrue(BoundROMUpdateResetPolicy.deletesGameSave(gameID: "old", incomingID: "new"))
        XCTAssertThrowsError(try BoundROMUpdateResetPolicy.validateBatteryForUpload(nil, expectedSHA1: "old"))
        XCTAssertThrowsError(try BoundROMUpdateResetPolicy.validateBatteryForUpload(Data([1]), expectedSHA1: "old"))
        let data = Data([1, 2, 3]), hash = Insecure.SHA1.hash(data: Data([1, 2, 3])).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try BoundROMUpdateResetPolicy.validateBatteryForUpload(data, expectedSHA1: hash))
    }

    func testResetGenerationBlocksStaleDownloadsAndHistoricalRestoresOnlyForManagedGame() throws {
        let f = try fixture(), (old, _) = try content(1), (next, data) = try content(2)
        let transaction = try f.storage.begin(content: next, data: data, sources: [], metadata: Data(),
            resetGameIDs: [old.gameID, next.gameID], enrollment: old)
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateDownload(gameID: next.gameID, generation: next.sha256, isSave: true, storage: f.storage))
        try finish(f.storage, transaction)
        XCTAssertEqual(BoundROMUpdateRegistry.generation(for: next.gameID, storage: f.storage), next.sha256)
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateDownload(gameID: old.gameID, generation: nil, isSave: false, storage: f.storage))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateDownload(gameID: next.gameID, generation: nil, isSave: true, storage: f.storage))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateDownload(gameID: next.gameID, generation: next.sha256, isSave: true, storage: f.storage, remoteLocked: true))
        XCTAssertNoThrow(try BoundROMUpdateRegistry.validateDownload(gameID: next.gameID, generation: next.sha256, isSave: true, storage: f.storage))
        XCTAssertNoThrow(try BoundROMUpdateRegistry.validateDownload(gameID: "unrelated", generation: nil, isSave: true, storage: f.storage))
        XCTAssertNoThrow(try BoundROMUpdateRegistry.validateRestore(gameID: next.gameID, generation: next.sha256, version: "head", currentVersion: "head", isLocked: false, storage: f.storage))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateRestore(gameID: next.gameID, generation: next.sha256, version: "old", currentVersion: "head", isLocked: false, storage: f.storage))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateRestore(gameID: next.gameID, generation: nil, version: "head", currentVersion: "head", isLocked: false, storage: f.storage))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateRestore(gameID: next.gameID, generation: next.sha256, version: "head", currentVersion: "head", isLocked: true, storage: f.storage))
        XCTAssertThrowsError(try BoundROMUpdateRegistry.validateRestore(gameID: old.gameID, generation: nil, version: "old", currentVersion: "head", isLocked: false, storage: f.storage))
        XCTAssertNoThrow(try BoundROMUpdateRegistry.validateRestore(gameID: "unrelated", generation: nil, version: "old", currentVersion: "head", isLocked: true, storage: f.storage))
    }
}
