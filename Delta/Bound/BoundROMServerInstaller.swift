import Foundation
import CoreData
import UIKit
import Harmony
import Darwin

/// A device-only consent receipt. Targets must be exact known multi_red hashes;
/// names and user-enrollment metadata never establish deletion eligibility.
struct BoundROMServerInstallJournal {
    struct Target: Codable, Equatable {
        let identity: BoundROMCleanupIdentity
        let filename: String
        let stateIDs: [String]
        let files: [BoundROMCleanupPlan.File]
    }
    struct Job: Codable {
        let id: UUID
        let owner: UUID
        let manifest: BoundROMServerManifest
        let targets: [Target]
        // Recorded before import, so an interrupted rename/artwork operation
        // cannot erase the newly installed incoming ROM on the next retry.
        var localTargetsDone: Bool? = nil
    }
    struct Installed: Codable {
        let manifest: BoundROMServerManifest
        let revision: UUID
        let retiredGameIDs: Set<String>
        var verifiedROMs: [BoundROMCleanupIdentity]? = nil
    }
    let storage: BoundROMUpdateStorage
    var directory: URL { storage.root.appendingPathComponent("Server Install", isDirectory: true) }
    var pendingURL: URL { directory.appendingPathComponent("pending.json") }
    var incomingURL: URL { directory.appendingPathComponent("incoming.gba") }
    var artworkURL: URL { directory.appendingPathComponent("cover.png") }
    var installedURL: URL { directory.appendingPathComponent("installed.json") }

    func pending() throws -> Job? {
        guard FileManager.default.fileExists(atPath: pendingURL.path) else { return nil }
        let value = try JSONDecoder().decode(Job.self, from: Data(contentsOf: pendingURL))
        try value.manifest.validate()
        let recognized = BoundRecognizedROMs.all + (try installed()?.verifiedROMs ?? [])
        let ids = value.targets.map { $0.identity.gameID }
        guard ids.count == Set(ids).count,
              value.targets.allSatisfy({ target in
                  recognized.contains(where: { $0.gameID == target.identity.gameID && $0.sha256 == target.identity.sha256 }) &&
                  target.filename == target.identity.gameID + ".gba"
              }) else { throw BoundROMUpdateError.storage }
        return value
    }
    func installed() throws -> Installed? {
        guard FileManager.default.fileExists(atPath: installedURL.path) else { return nil }
        let value = try JSONDecoder().decode(Installed.self, from: Data(contentsOf: installedURL))
        try value.manifest.validate()
        let verified = value.verifiedROMs ?? []
        guard Set(verified.map(\.gameID)).count == verified.count else { throw BoundROMUpdateError.storage }
        for identity in verified {
            // Persisted receipts can authorize later device-only cleanup, so
            // validate identities again before using them as file components.
            try BoundROMServerManifest(schemaVersion: 1, buildNumber: 500, sha256: identity.sha256,
                gameID: identity.gameID, byteCount: 32 * 1024 * 1024).validate()
        }
        guard !value.retiredGameIDs.contains(value.manifest.gameID),
              value.retiredGameIDs.isSubset(of: Set((BoundRecognizedROMs.all + (value.verifiedROMs ?? [])).map(\.gameID))) else { throw BoundROMUpdateError.storage }
        return value
    }
    func write<T: Encodable>(_ value: T, to url: URL) throws { try write(JSONEncoder().encode(value), to: url) }
    func write(_ job: Job, to url: URL) throws {
        guard url == pendingURL else { throw BoundROMUpdateError.storage }
        if let previous = try pending() {
            guard previous.id == job.id, previous.owner == job.owner, previous.manifest == job.manifest,
                  previous.targets == job.targets,
                  previous.localTargetsDone != true || job.localTargetsDone == true else { throw BoundROMUpdateError.storage }
        }
        try write(JSONEncoder().encode(job), to: url)
    }
    func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize(); try file.close()
        let fd = Darwin.open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw BoundROMUpdateError.storage }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw BoundROMUpdateError.storage }
    }
    func finishCommittedJob() throws {
        // installed.json is already durable. A crash during these removals can
        // finish from that receipt without needing the staged payload again.
        for url in [incomingURL, artworkURL, pendingURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let fd = Darwin.open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw BoundROMUpdateError.storage }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw BoundROMUpdateError.storage }
    }
    func blocks(_ gameID: String) -> Bool {
        do {
            if let job = try pending(), job.manifest.gameID == gameID || job.targets.contains(where: { $0.identity.gameID == gameID }) { return true }
            return try installed()?.retiredGameIDs.contains(gameID) == true
        } catch {
            return BoundRecognizedROMs.all.contains { $0.gameID == gameID } || MultiRedAdapter.profile(gameID: gameID) != nil
        }
    }
    /// Retirement prevents importing or syncing an old identity indefinitely,
    /// but only an unfinished install owns its local deletion. Keep the retired
    /// receipt when the user removes a leftover library entry.
    func blocksDeletion(_ gameID: String) -> Bool {
        do {
            guard let job = try pending() else { return false }
            return job.manifest.gameID == gameID || job.targets.contains { $0.identity.gameID == gameID }
        } catch {
            return BoundRecognizedROMs.all.contains { $0.gameID == gameID } || MultiRedAdapter.profile(gameID: gameID) != nil
        }
    }
}

@MainActor
enum BoundROMServerInstaller {
    private static var working = false
    private static let fireRedSHA1 = "41cb23d8dccc8ebd7c649cd8fbb58eeace6e2fdc"

    nonisolated static func blocks(_ gameID: String, storage: BoundROMUpdateStorage = .live) -> Bool {
        BoundROMServerInstallJournal(storage: storage).blocks(gameID)
    }
    nonisolated static func blocksSaveState(_ stateID: String, gameID: String?, storage: BoundROMUpdateStorage = .live) -> Bool {
        let journal = BoundROMServerInstallJournal(storage: storage)
        if let gameID, journal.blocks(gameID) { return true }
        // Core Data can nullify the relationship while deleting the selected
        // Game. The captured state ID still prevents a Harmony tombstone.
        do { return try journal.pending()?.targets.contains(where: { $0.stateIDs.contains(stateID) }) == true }
        catch { return gameID.map { journal.blocks($0) } ?? true }
    }
    nonisolated static func installedBuild(gameID: String, storage: BoundROMUpdateStorage = .live) -> Int? {
        guard let installed = try? BoundROMServerInstallJournal(storage: storage).installed(), installed.manifest.gameID == gameID else { return nil }
        return installed.manifest.buildNumber
    }
    nonisolated static func revision(gameID: String, storage: BoundROMUpdateStorage = .live) throws -> UUID? {
        let journal = BoundROMServerInstallJournal(storage: storage)
        if let job = try journal.pending(), job.manifest.gameID == gameID || job.targets.contains(where: { $0.identity.gameID == gameID }) { return job.id }
        if let installed = try journal.installed(), installed.manifest.gameID == gameID || installed.retiredGameIDs.contains(gameID) { return installed.revision }
        return nil
    }

    /// Called only after confirmation of this particular destructive update.
    static func install(data: Data, manifest: BoundROMServerManifest, session: AppCloudSession) async throws {
        guard !working else { throw BoundROMUpdateError.busy }
        working = true; defer { working = false }
        try manifest.validateCompatibility()
        let content = try BoundROMUpdateContent(data: data, expectedSHA256: manifest.sha256)
        guard content.gameID == manifest.gameID, data.count == manifest.byteCount else { throw BoundROMUpdateError.incompatibleROM }
        _ = try MultiRedAdapter(rom: data)
        try verify(session)
        let journal = BoundROMServerInstallJournal(storage: .live)
        if let pending = try journal.pending() {
            guard pending.owner == session.owner, pending.manifest == manifest else { throw BoundROMUpdateError.storage }
            try await finish(pending, journal: journal, session: session)
            return
        }
        // This lookup uses the original FireRed v1.0 USA identity, not the patched
        // ROM's name. Decode the actual image before any previous save is deleted.
        guard let coverURL = try GamesDatabase().metadata(forGameIdentifier: fireRedSHA1)?.artworkURL,
              coverURL.scheme == "https" else { throw BoundROMUpdateError.storage }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let transport = URLSession(configuration: configuration, delegate: BoundROMArtworkNoRedirect(), delegateQueue: nil)
        defer { transport.invalidateAndCancel() }
        let (cover, response) = try await transport.data(from: coverURL)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              cover.count <= 5 * 1024 * 1024, let image = UIImage(data: cover),
              image.size.width > 0, image.size.height > 0, let png = image.pngData() else { throw BoundROMUpdateError.storage }
        try verify(session)
        try await SyncManager.shared.withROMCleanupFence {
            try verify(session)
            guard idle, !journal.storage.hasPendingSaveClear(gameID: manifest.gameID), try journal.storage.pending() == nil,
                  try BoundROMCleanupJournal(storage: journal.storage).read().map({ $0.completed }) != false else { throw BoundROMUpdateError.busy }
            await BoundServerBackupManager.shared.cancelPendingOperationsAndWait()
            try verify(session)
            guard idle else { throw BoundROMUpdateError.busy }
            let targets = try captureTargets(storage: journal.storage)
            try journal.write(data, to: journal.incomingURL)
            try journal.write(png, to: journal.artworkURL)
            let job = BoundROMServerInstallJournal.Job(id: UUID(), owner: session.owner, manifest: manifest, targets: targets)
            try journal.write(job, to: journal.pendingURL)
        }
        guard let job = try journal.pending() else { throw BoundROMUpdateError.storage }
        try await finish(job, journal: journal, session: session)
    }

    /// Replay only the original owner's confirmed scope, without discovering new
    /// deletion targets or inferring consent from a refresh or timer.
    static func resume(session: AppCloudSession) async throws {
        guard !working else { throw BoundROMUpdateError.busy }
        let journal = BoundROMServerInstallJournal(storage: .live)
        guard let job = try journal.pending() else { return }
        working = true; defer { working = false }
        guard job.owner == session.owner else { throw BoundROMCleanupError.accountChanged }
        try verify(session)
        if let installed = try journal.installed(), installed.revision == job.id, installed.manifest == job.manifest {
            // A newer Bound build can finish removing staging metadata for an
            // already committed old install. No ROM/save mutation happens here.
            try journal.finishCommittedJob()
            return
        }
        try job.manifest.validateCompatibility()
        try await finish(job, journal: journal, session: session)
    }

    private static var idle: Bool { BoundROMCleanupLive.idle && !BoundROMCleanupCoordinator.shared.busy }
    private static func verify(_ session: AppCloudSession) throws {
        guard session.isSameSession(as: BoundFriendAccount.shared.session) else { throw BoundROMCleanupError.accountChanged }
        try session.credentials()
    }
    private static func captureTargets(storage: BoundROMUpdateStorage) throws -> [BoundROMServerInstallJournal.Target] {
        let context = DatabaseManager.shared.newBackgroundContext()
        let files = BoundROMCleanupJournal(storage: storage)
        return try context.performAndWait {
            let verified = try BoundROMServerInstallJournal(storage: storage).installed()?.verifiedROMs ?? []
            var targets: [BoundROMServerInstallJournal.Target] = []
            for game in try context.fetch(Game.fetchRequest()) {
                // Only the checked-in inventory or a verified install receipt is eligible.
                // Unknown cartridges and ordinary FireRed games are untouched.
                guard let identity = (BoundRecognizedROMs.all + verified).first(where: { $0.gameID == game.identifier }) else { continue }
                guard game.filename == identity.gameID + ".gba" else { throw BoundROMUpdateError.unsafePath }
                if FileManager.default.fileExists(atPath: game.fileURL.path) {
                    let data = try Data(contentsOf: game.fileURL, options: .mappedIfSafe)
                    let content = try BoundROMUpdateContent(data: data, expectedSHA256: identity.sha256)
                    guard content.gameID == identity.gameID else { throw BoundROMUpdateError.incompatibleROM }
                }
                guard !storage.hasPendingSaveClear(gameID: game.identifier),
                      !BoundServerBackupManager.hasPendingRestore(gameID: game.identifier) else { throw BoundROMUpdateError.busy }
                let roots = try BoundROMCleanupLive.localRoots(game: game, storage: storage)
                targets.append(.init(identity: identity, filename: game.filename,
                                     stateIDs: game.saveStates.map(\.identifier).sorted(), files: try files.inventory(roots)))
            }
            return targets.sorted { $0.identity.gameID < $1.identity.gameID }
        }
    }

    private static func finish(_ job: BoundROMServerInstallJournal.Job, journal: BoundROMServerInstallJournal,
                               session: AppCloudSession) async throws {
        try verify(session)
        guard job.owner == session.owner else { throw BoundROMCleanupError.accountChanged }
        if let installed = try journal.installed(), installed.revision == job.id, installed.manifest == job.manifest {
            try journal.finishCommittedJob()
            return
        }
        let data = try Data(contentsOf: journal.incomingURL)
        let content = try BoundROMUpdateContent(data: data, expectedSHA256: job.manifest.sha256)
        _ = try MultiRedAdapter(rom: data)
        guard content.gameID == job.manifest.gameID,
              let cover = UIImage(contentsOfFile: journal.artworkURL.path), cover.size.width > 0 else { throw BoundROMUpdateError.storage }
        try await SyncManager.shared.withROMCleanupFence {
            try verify(session)
            guard idle else { throw BoundROMUpdateError.busy }
            await BoundServerBackupManager.shared.cancelPendingOperationsAndWait()
            try verify(session)
            guard idle else { throw BoundROMUpdateError.busy }
            let cleanup = BoundROMCleanupJournal(storage: journal.storage)
            if job.localTargetsDone != true {
              for target in job.targets {
                try verify(session)
                guard idle else { throw BoundROMUpdateError.busy }
                NotificationCenter.default.post(name: BoundROMUpdateManager.saveClearBegan, object: target.identity.gameID)
                let context = DatabaseManager.shared.newBackgroundContext()
                try context.performAndWait {
                    let request = Game.fetchRequest()
                    request.predicate = NSPredicate(format: "identifier == %@", target.identity.gameID)
                    let records = try context.fetch(request)
                    guard records.count <= 1 else { throw BoundROMUpdateError.storage }
                    if let game = records.first {
                        guard game.filename == target.filename,
                              Set(game.saveStates.map(\.identifier)).isSubset(of: Set(target.stateIDs)) else { throw BoundROMUpdateError.changedBackup }
                        let actual = try cleanup.inventory(BoundROMCleanupLive.localRoots(game: game, storage: journal.storage))
                        // Missing files can be from a partial retry. New/changed
                        // files were not part of the captured confirmation scope.
                        guard actual.allSatisfy({ target.files.contains($0) }) else { throw BoundROMUpdateError.changedBackup }
                    }
                    try cleanup.delete(target.files)
                    for game in records {
                        game.previewSaveState = nil
                        for state in game.saveStates { context.delete(state) }
                        if let save = game.gameSave { context.delete(save); game.gameSave = nil }
                        game.filename = ""; context.delete(game)
                    }
                    if context.hasChanges { try context.save() }
                }
                BoundMultiplayerSaveStore.shared.discardServerSession(gameID: target.identity.gameID)
                BoundServerMemoryFiles.discard(gameID: target.identity.gameID)
              }
              try await removeLocalSyncRows(job.targets)
              var completed = job
              completed.localTargetsDone = true
              // Consent scope stays immutable; only this monotonic phase bit
              // advances after every captured old ROM/save is gone locally.
              try journal.write(completed, to: journal.pendingURL)
            }
            try verify(session)
            guard idle else { throw BoundROMUpdateError.busy }
            // The generic import helper correctly blocks an ordinary missing-ROM
            // repair while this journal owns the incoming identity. Here the
            // journal itself may restore its verified staged bytes on retry.
            let repair = DatabaseManager.shared.newBackgroundContext()
            try repair.performAndWait {
                let request = Game.fetchRequest()
                request.predicate = NSPredicate(format: "identifier == %@", job.manifest.gameID)
                let records = try repair.fetch(request)
                guard records.count <= 1 else { throw BoundROMUpdateError.storage }
                if let game = records.first, !FileManager.default.fileExists(atPath: game.fileURL.path) {
                    guard game.filename == job.manifest.gameID + ".gba" else { throw BoundROMUpdateError.unsafePath }
                    try data.write(to: game.fileURL, options: .atomic)
                }
            }
            try await BoundROMUpdateManager.shared.installBundledROM(from: journal.incomingURL, name: "RRv4.1M")
            let context = DatabaseManager.shared.newBackgroundContext()
            try context.performAndWait {
                let request = Game.fetchRequest()
                request.predicate = NSPredicate(format: "identifier == %@", job.manifest.gameID)
                let games = try context.fetch(request)
                guard games.count == 1, let game = games.first else { throw BoundROMUpdateError.storage }
                game.name = "RRv4.1M"
                let destination = DatabaseManager.artworkURL(for: game)
                try Data(contentsOf: journal.artworkURL).write(to: destination, options: .atomic)
                game.artworkURL = destination
                try context.save()
            }
            var retired = try journal.installed()?.retiredGameIDs ?? []
            retired.formUnion(job.targets.map { $0.identity.gameID }); retired.remove(job.manifest.gameID)
            var verifiedROMs = try journal.installed()?.verifiedROMs ?? []
            if !verifiedROMs.contains(where: { $0.gameID == job.manifest.gameID }) {
                verifiedROMs.append(.init(sha256: job.manifest.sha256, gameID: job.manifest.gameID,
                    evidence: "Validated Linode runtime interface v1"))
            }
            try journal.write(BoundROMServerInstallJournal.Installed(manifest: job.manifest, revision: job.id,
                retiredGameIDs: retired, verifiedROMs: verifiedROMs), to: journal.installedURL)
            try journal.finishCommittedJob()
        }
    }

    /// Forget only the selected local tombstones while the coordinator is
    /// drained; leaving them would delete remote files at the next sync.
    private static func removeLocalSyncRows(_ targets: [BoundROMServerInstallJournal.Target]) async throws {
        guard let controller = SyncManager.shared.recordController, controller.isStarted else { return }
        await controller.waitForRecordedChanges()
        let gameIDs = Set(targets.map { $0.identity.gameID }), stateIDs = Set(targets.flatMap(\.stateIDs))
        let context = controller.newBackgroundContext()
        try context.performAndWait {
            let request = NSFetchRequest<ManagedRecord>(entityName: "ManagedRecord")
            request.predicate = NSPredicate(format: "recordedObjectType IN %@", ["Game", "GameSave", "SaveState"])
            for record in try context.fetch(request) {
                let metadata = record.remoteRecord?.value(forKey: "metadata") as? [HarmonyMetadataKey: String] ?? [:]
                let selected = record.recordedObjectType == "SaveState" ?
                    (stateIDs.contains(record.recordedObjectIdentifier) || gameIDs.contains(metadata[.verifiedGameID] ?? metadata[.gameID] ?? "")) :
                    gameIDs.contains(record.recordedObjectIdentifier)
                if selected { context.delete(record) }
            }
            if context.hasChanges { try context.save() }
        }
    }
}

private final class BoundROMArtworkNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
