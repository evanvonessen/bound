import XCTest
import CoreData
import UIKit
@testable import Delta

final class ROMServerInstallJournalTests: XCTestCase {
    @MainActor func testOptInLiveDeniedAccountCannotSeeOrStartUpdate() async throws {
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rom-live-denied-qa.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Requires revoked disposable live QA account") }
        struct Credentials: Decodable { let email: String; let password: String }
        let value = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: file))
        guard value.email.hasPrefix("qa-rom-"), value.email.hasSuffix("@bound.invalid"), BoundFriendAccount.shared.session == nil else {
            XCTFail("Requires signed-out disposable QA identity"); return
        }
        await BoundFriendAccount.shared.signIn(email: value.email, password: value.password)
        let session = try XCTUnwrap(BoundFriendAccount.shared.session)
        defer { BoundFriendAccount.shared.signOut() }
        let updates = BoundROMServerUpdates.shared
        updates.sessionChanged(session)
        for _ in 0..<120 {
            if !updates.busy { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertFalse(updates.busy)
        XCTAssertFalse(updates.approved) // The Settings section uses this same visibility gate.
        XCTAssertNil(updates.latest)
        let journal = BoundROMServerInstallJournal(storage: .live)
        let installed = try XCTUnwrap(journal.installed())
        updates.downloadConfirmed(installed.manifest)
        XCTAssertFalse(updates.busy)
        XCTAssertNil(try journal.pending())
        XCTAssertEqual(try journal.installed()?.revision, installed.revision)
    }
    /// Explicit opt-in only: provision this file solely in the task-owned QA
    /// simulator. Never use an ordinary user's library or account for this test.
    @MainActor func testOptInLiveRefreshDownloadAndInstall() async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let credentials = documents.appendingPathComponent("rom-live-qa.json")
        guard FileManager.default.fileExists(atPath: credentials.path) else { throw XCTSkip("Requires an explicitly provisioned live QA account in the task simulator") }
        struct Credentials: Decodable { let email: String; let password: String }
        let value = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: credentials))
        guard value.email.hasPrefix("qa-rom-"), value.email.hasSuffix("@bound.invalid"),
              BoundFriendAccount.shared.session == nil, SyncManager.shared.coordinator == nil else {
            XCTFail("Requires disposable QA identity and isolated signed-out library"); return
        }
        await BoundFriendAccount.shared.signIn(email: value.email, password: value.password)
        let session = try XCTUnwrap(BoundFriendAccount.shared.session)
        defer { BoundFriendAccount.shared.signOut() }
        let updates = BoundROMServerUpdates.shared
        func settle() async throws {
            for _ in 0..<600 {
                if !updates.busy { return }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            XCTFail("Live update did not settle within five minutes")
        }
        updates.sessionChanged(session)
        try await settle()
        XCTAssertTrue(updates.approved)
        let release = try XCTUnwrap(updates.latest, updates.message ?? "No manifest")
        try release.validateCompatibility()
        let context = DatabaseManager.shared.viewContext
        func game(_ id: String) throws -> Game? {
            let request = Game.fetchRequest() as! NSFetchRequest<Game>
            request.predicate = NSPredicate(format: "identifier == %@", id)
            return try context.fetch(request).first
        }
        let original = documents.appendingPathComponent("MultiRedProfilesQA/original.gba")
        let historicalID = BoundGameProfiles.original.gameID
        let old: Game
        if let installed = try game(release.gameID), BoundROMServerInstaller.installedBuild(gameID: release.gameID) != nil {
            old = installed // Subsequent publication may have identical cartridge bytes.
        } else {
            guard try game(historicalID) == nil, FileManager.default.fileExists(atPath: original.path) else {
                throw XCTSkip("Requires isolated library and the exact historical ROM fixture")
            }
            let input = FileManager.default.temporaryDirectory.appendingPathComponent("Old QA cartridge.gba")
            try Data(contentsOf: original).write(to: input)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DatabaseManager.shared.importGames(at: [input]) { games, errors in
                    if errors.isEmpty && games.contains(where: { $0.identifier == historicalID }) { continuation.resume() }
                    else { continuation.resume(throwing: BoundROMUpdateError.storage) }
                }
            }
            old = try XCTUnwrap(game(historicalID))
        }
        let oldFile = old.fileURL, oldSave = old.gameSaveURL, oldID = old.identifier
        let sentinel = Data("DISPOSABLE OLD SAVE".utf8)
        try sentinel.write(to: oldSave)
        // Refresh without confirmation must preserve the cartridge and save.
        updates.refresh(); try await settle()
        XCTAssertEqual(try Data(contentsOf: oldSave), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        updates.downloadConfirmed(release)
        try await settle()
        XCTAssertNil(updates.message)
        XCTAssertTrue(updates.upToDate)
        if oldID != release.gameID {
            XCTAssertNil(try game(oldID))
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSave.path))
        let installed = try XCTUnwrap(game(release.gameID))
        XCTAssertEqual(installed.name, "RRv4.1M")
        XCTAssertEqual(BoundROMUpdateContent.hash(try Data(contentsOf: installed.fileURL)), release.sha256)
        XCTAssertEqual(BoundROMServerInstaller.installedBuild(gameID: release.gameID), release.buildNumber)
        let artwork = try XCTUnwrap(installed.artworkURL)
        XCTAssertNotNil(UIImage(contentsOfFile: artwork.path))
        updates.refresh(); try await settle()
        XCTAssertTrue(updates.upToDate)
        XCTAssertEqual(updates.latest, release)
    }
    private func fixture() throws -> BoundROMServerInstallJournal {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ServerROMInstall-" + UUID().uuidString)
        let documents = directory.appendingPathComponent("Documents"), support = directory.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return .init(storage: .init(root: support.appendingPathComponent("ROM Updates"), documents: documents, support: support))
    }
    private func manifest(_ build: Int = 500) -> BoundROMServerManifest {
        .init(schemaVersion: 1, buildNumber: build, sha256: BoundGameProfiles.current.romSHA256,
              gameID: BoundGameProfiles.current.gameID, byteCount: 32 * 1024 * 1024)
    }
    private func target(_ files: [BoundROMCleanupPlan.File] = []) throws -> BoundROMServerInstallJournal.Target {
        let identity = try XCTUnwrap(BoundRecognizedROMs.all.first { $0.gameID != BoundGameProfiles.current.gameID })
        return .init(identity: identity, filename: identity.gameID + ".gba", stateIDs: ["fixture-state"], files: files)
    }

    func testConfirmedScopeSurvivesRestartAndBlocksOnlySelectedIdentities() throws {
        let journal = try fixture(), selected = try target(), manifest = manifest()
        let job = BoundROMServerInstallJournal.Job(id: UUID(), owner: UUID(), manifest: manifest, targets: [selected])
        try journal.write(job, to: journal.pendingURL)
        let restarted = BoundROMServerInstallJournal(storage: journal.storage)
        XCTAssertEqual(try restarted.pending()?.id, job.id)
        XCTAssertEqual(try restarted.pending()?.owner, job.owner)
        XCTAssertTrue(restarted.blocks(selected.identity.gameID))
        XCTAssertTrue(restarted.blocks(manifest.gameID))
        XCTAssertFalse(restarted.blocks("ordinary-game"))
        XCTAssertEqual(try BoundROMServerInstaller.revision(gameID: selected.identity.gameID, storage: journal.storage), job.id)
        XCTAssertTrue(BoundROMServerInstaller.blocksSaveState("fixture-state", gameID: nil, storage: journal.storage))
        XCTAssertFalse(BoundROMServerInstaller.blocksSaveState("ordinary-state", gameID: "ordinary-game", storage: journal.storage))
    }

    func testUnrecognizedEnrollmentCannotBecomeADeletionTarget() throws {
        let journal = try fixture()
        let identity = BoundROMCleanupIdentity(sha256: String(repeating: "a", count: 64), gameID: String(repeating: "b", count: 40), evidence: "user-enrolled")
        let selected = BoundROMServerInstallJournal.Target(identity: identity, filename: identity.gameID + ".gba", stateIDs: [], files: [])
        try journal.write(BoundROMServerInstallJournal.Job(id: UUID(), owner: UUID(), manifest: manifest(), targets: [selected]), to: journal.pendingURL)
        XCTAssertThrowsError(try journal.pending())
        XCTAssertFalse(journal.blocks("ordinary-game"))
    }

    func testChangedCapturedSaveIsRetainedAndUnrelatedFilesAreUntouched() throws {
        let journal = try fixture(), cleanup = BoundROMCleanupJournal(storage: journal.storage)
        let selected = journal.storage.documents.appendingPathComponent("selected.sav")
        let ordinary = journal.storage.documents.appendingPathComponent("ordinary.sav")
        try Data([1]).write(to: selected); try Data([8]).write(to: ordinary)
        let captured = try cleanup.inventory([selected])
        try Data([2]).write(to: selected)
        XCTAssertThrowsError(try cleanup.delete(captured))
        XCTAssertEqual(try Data(contentsOf: selected), Data([2]))
        XCTAssertEqual(try Data(contentsOf: ordinary), Data([8]))
    }

    func testInstalledReceiptHasIndependentBuildAndKeepsRetiredROMsFenced() throws {
        let journal = try fixture(), selected = try target(), manifest = manifest(501), revision = UUID()
        try journal.write(BoundROMServerInstallJournal.Installed(manifest: manifest, revision: revision,
                                                                retiredGameIDs: [selected.identity.gameID]), to: journal.installedURL)
        XCTAssertEqual(BoundROMServerInstaller.installedBuild(gameID: manifest.gameID, storage: journal.storage), 501)
        XCTAssertNil(BoundROMServerInstaller.installedBuild(gameID: selected.identity.gameID, storage: journal.storage))
        XCTAssertTrue(journal.blocks(selected.identity.gameID))
        XCTAssertFalse(journal.blocks(manifest.gameID))
        XCTAssertFalse(journal.blocks("ordinary-game"))
        XCTAssertEqual(try BoundROMServerInstaller.revision(gameID: selected.identity.gameID, storage: journal.storage), revision)
    }

    func testDamagedJournalFailsClosedForKnownROMsWithoutBlockingOrdinaryGames() throws {
        let journal = try fixture(), selected = try target()
        try journal.write(Data("incomplete".utf8), to: journal.pendingURL)
        XCTAssertThrowsError(try journal.pending())
        XCTAssertTrue(journal.blocks(selected.identity.gameID))
        XCTAssertTrue(journal.blocks(BoundGameProfiles.current.gameID))
        XCTAssertFalse(journal.blocks("ordinary-game"))
    }

    func testExistingIncomingIdentityIsCapturedAndDeletionPhaseSurvivesRestart() throws {
        let journal = try fixture(), incoming = manifest()
        let identity = try XCTUnwrap(BoundRecognizedROMs.all.first { $0.gameID == incoming.gameID })
        let selected = BoundROMServerInstallJournal.Target(identity: identity, filename: identity.gameID + ".gba", stateIDs: [], files: [])
        var job = BoundROMServerInstallJournal.Job(id: UUID(), owner: UUID(), manifest: incoming, targets: [selected])
        try journal.write(job, to: journal.pendingURL)
        XCTAssertEqual(try journal.pending()?.targets.first?.identity.gameID, incoming.gameID)
        XCTAssertNotEqual(try journal.pending()?.localTargetsDone, true)
        job.localTargetsDone = true
        try journal.write(job, to: journal.pendingURL)
        let restarted = BoundROMServerInstallJournal(storage: journal.storage)
        XCTAssertEqual(try restarted.pending()?.localTargetsDone, true)
        XCTAssertTrue(restarted.blocks(incoming.gameID))
        try restarted.write(BoundROMServerInstallJournal.Installed(manifest: incoming, revision: job.id,
                                                                  retiredGameIDs: []), to: restarted.installedURL)
        try restarted.finishCommittedJob()
        XCTAssertNil(try restarted.pending())
        XCTAssertFalse(restarted.blocks(incoming.gameID))
        XCTAssertEqual(BoundROMServerInstaller.installedBuild(gameID: incoming.gameID, storage: journal.storage), 500)
        XCTAssertEqual(try BoundROMServerInstaller.revision(gameID: incoming.gameID, storage: journal.storage), job.id)
    }

    func testDeletionPhaseCannotMoveBackwardsOrWidenConfirmedTargets() throws {
        let journal = try fixture(), selected = try target()
        let first = BoundROMServerInstallJournal.Job(id: UUID(), owner: UUID(), manifest: manifest(), targets: [selected])
        try journal.write(first, to: journal.pendingURL)
        var completed = first
        completed.localTargetsDone = true
        try journal.write(completed, to: journal.pendingURL)
        XCTAssertThrowsError(try journal.write(first, to: journal.pendingURL))
        let changed = BoundROMServerInstallJournal.Job(id: first.id, owner: first.owner, manifest: first.manifest, targets: [])
        XCTAssertThrowsError(try journal.write(changed, to: journal.pendingURL))
        XCTAssertEqual(try journal.pending()?.localTargetsDone, true)
        XCTAssertEqual(try journal.pending()?.targets, first.targets)
    }

    func testCommittedOlderInstallCanCleanStagingWithoutAdmittingItsOldCartridge() throws {
        let journal = try fixture(), previous = try target().identity
        let oldManifest = BoundROMServerManifest(schemaVersion: 1, buildNumber: 500, sha256: previous.sha256,
                                                gameID: previous.gameID, byteCount: 32 * 1024 * 1024)
        XCTAssertThrowsError(try oldManifest.validateCompatibility())
        let job = BoundROMServerInstallJournal.Job(id: UUID(), owner: UUID(), manifest: oldManifest, targets: [], localTargetsDone: true)
        try journal.write(job, to: journal.pendingURL)
        try journal.write(BoundROMServerInstallJournal.Installed(manifest: oldManifest, revision: job.id, retiredGameIDs: []), to: journal.installedURL)
        try journal.write(Data([1]), to: journal.incomingURL)
        try journal.write(Data([2]), to: journal.artworkURL)
        let save = journal.storage.documents.appendingPathComponent("current.sav")
        try Data([3]).write(to: save)
        try journal.finishCommittedJob()
        XCTAssertNil(try journal.pending())
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.incomingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.artworkURL.path))
        XCTAssertEqual(try journal.installed()?.revision, job.id)
        XCTAssertEqual(try Data(contentsOf: save), Data([3]))
    }

    func testManifestRejectsInvalidSchemaBuildSizeAndHashes() throws {
        let current = manifest()
        XCTAssertNoThrow(try current.validateCompatibility())
        for invalid in [
            BoundROMServerManifest(schemaVersion: 2, buildNumber: 500, sha256: current.sha256, gameID: current.gameID, byteCount: current.byteCount),
            BoundROMServerManifest(schemaVersion: 1, buildNumber: 499, sha256: current.sha256, gameID: current.gameID, byteCount: current.byteCount),
            BoundROMServerManifest(schemaVersion: 1, buildNumber: 500, sha256: current.sha256, gameID: current.gameID, byteCount: 16 * 1024 * 1024),
            BoundROMServerManifest(schemaVersion: 1, buildNumber: 500, sha256: current.sha256.uppercased(), gameID: current.gameID, byteCount: current.byteCount),
            BoundROMServerManifest(schemaVersion: 1, buildNumber: 500, sha256: String(repeating: "z", count: 64), gameID: current.gameID, byteCount: current.byteCount),
            BoundROMServerManifest(schemaVersion: 1, buildNumber: 500, sha256: current.sha256, gameID: String(current.gameID.dropLast()), byteCount: current.byteCount)
        ] { XCTAssertThrowsError(try invalid.validate()) }
    }

    func testManifestCannotAdmitUnknownDigestOrHistoricalPair() throws {
        let current = manifest(), old = try target().identity
        let unknown = BoundROMServerManifest(schemaVersion: 1, buildNumber: 500, sha256: String(repeating: "a", count: 64),
                                            gameID: current.gameID, byteCount: current.byteCount)
        XCTAssertNoThrow(try unknown.validate())
        XCTAssertThrowsError(try unknown.validateCompatibility())
        let historical = BoundROMServerManifest(schemaVersion: 1, buildNumber: 501, sha256: old.sha256,
                                               gameID: old.gameID, byteCount: current.byteCount)
        XCTAssertNoThrow(try historical.validate())
        XCTAssertThrowsError(try historical.validateCompatibility())
    }
}
