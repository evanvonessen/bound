import Foundation
import Combine
import CoreData
import CryptoKit
import SwiftUI
import Darwin

struct BoundROMCleanupIdentity: Codable, Equatable {
    let sha256: String
    let gameID: String
    let evidence: String
}

enum BoundROMCleanupError: LocalizedError {
    case busy, accountChanged, signIn
    var errorDescription: String? {
        switch self {
        case .busy: return "Close open games and finish pending saves before clearing ROMs."
        case .accountChanged: return "Sign in to the account that confirmed this ROM cleanup."
        case .signIn: return "Sign in to review account-owned cloud saves before clearing ROMs."
        }
    }
}

/// The confirmation owns this immutable scope. Retries never enumerate new targets.
struct BoundROMCleanupPlan: Codable, Equatable, Identifiable {
    struct File: Codable, Equatable {
        let path: String // Documents/... or Support/... relative to the current sandbox
        let sha256: String
        let bytes: Int64
    }
    struct Run: Codable, Equatable {
        let id: UUID
        let revision: UInt64
        let participants: [UUID]
    }
    struct Target: Codable, Equatable, Identifiable {
        let identity: BoundROMCleanupIdentity
        let name: String
        let filename: String?
        let files: [File]
        let stateIDs: [String]
        let cloud: BoundSaveClearCloudContext
        let dropbox: [BoundDropboxSaveDeletion.Entry]
        let runs: [Run]
        let serverBackup: Bool
        var id: String { identity.gameID }
    }
    let id: UUID
    let owner: UUID?
    let preserved: BoundROMCleanupIdentity
    let targets: [Target]
    var bytes: Int64 { targets.flatMap(\.files).reduce(0) { $0 + $1.bytes } }
    var summary: String {
        let header = "Keep the current supported ROM and all its saves (" + preserved.sha256 + ").\n\nPermanently remove:"
        let rows = targets.map { target in
            let runs = target.runs.map { $0.id.uuidString }.joined(separator: ", ")
            let files = target.files.map(\.path).joined(separator: "\n")
            let cloudFiles = target.dropbox.map { $0.name + " [" + ($0.id ?? "") + "]" }.joined(separator: "\n")
            return target.name + "\nSHA-256: " + target.identity.sha256 + "\n" +
                "Local ROM/save/state files: \(target.files.count), \(target.files.reduce(0) { $0 + $1.bytes }) bytes\n" + files +
                "\nDropbox files: \(target.dropbox.count)\n" + cloudFiles +
                "\nNakama runs: \(target.runs.count)\n" + runs +
                (target.serverBackup ? "\nAll account-owned server backups for this exact game identity." : "")
        }.joined(separator: "\n\n")
        let warnings = (targets.contains { !$0.runs.isEmpty } ? "Deleting these shared Nakama runs permanently removes both your progress and your partner’s progress.\n\n" : "") +
            (targets.contains { !$0.dropbox.isEmpty } ? "Dropbox permanent purge requires provider permission. Failed cloud deletions remain pending for retry; they are not reported as complete.\n\n" : "")
        return header + "\n\n" + warnings + rows +
            "\n\nNo archive is created. Offline or failed cloud deletions retain this exact scope for retry."
    }
}

/// Atomic metadata only: no ROM, state, token or deleted save is retained here.
struct BoundROMCleanupJournal {
    struct Job: Codable {
        let plan: BoundROMCleanupPlan
        var localDone: Set<String> = []
        var cloudDone: Set<String> = []
        var completed = false
        var errors: [String: String] = [:]
    }
    let storage: BoundROMUpdateStorage
    var url: URL { storage.root.appendingPathComponent("ROM Cleanup/job.json") }
    private func completedURL(_ gameID: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("Completed/" + BoundROMUpdateContent.hash(Data(gameID.utf8)) + ".json")
    }
    func read() throws -> Job? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: url))
        let ids = job.plan.targets.map(\.id)
        guard Set(ids).count == ids.count, !ids.contains(job.plan.preserved.gameID),
              Set(job.localDone).isSubset(of: Set(ids)), Set(job.cloudDone).isSubset(of: Set(ids)) else { throw BoundROMUpdateError.storage }
        return job
    }
    func write(_ job: Job) throws {
        let ids = Set(job.plan.targets.map(\.id))
        guard ids.count == job.plan.targets.count, !ids.contains(job.plan.preserved.gameID),
              job.plan.targets.allSatisfy({ $0.identity.sha256 != job.plan.preserved.sha256 }),
              job.localDone.isSubset(of: ids), job.cloudDone.isSubset(of: ids) else { throw BoundROMUpdateError.storage }
        if let previous = try read(), !previous.completed {
            guard previous.plan == job.plan else { throw BoundROMUpdateError.storage }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if job.completed {
            for target in job.plan.targets {
                let receipt = completedURL(target.id)
                try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(job.plan.id).write(to: receipt, options: .atomic)
                let file = try FileHandle(forWritingTo: receipt); try file.synchronize(); try file.close()
            }
            if let first = job.plan.targets.first {
                let directory = Darwin.open(completedURL(first.id).deletingLastPathComponent().path, O_RDONLY)
                guard directory >= 0 else { throw BoundROMUpdateError.storage }
                let result = fsync(directory); Darwin.close(directory)
                guard result == 0 else { throw BoundROMUpdateError.storage }
            }
        }
        try JSONEncoder().encode(job).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close()
        let fd = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw BoundROMUpdateError.storage }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw BoundROMUpdateError.storage }
    }
    func blocks(_ gameID: String) -> Bool {
        do { return try read().map { !$0.completed && $0.plan.targets.contains { $0.id == gameID } } ?? false }
        catch {
            // A damaged receipt cannot enable a recognized old cartridge or its downloads.
            return gameID != BoundGameProfiles.current.gameID && BoundRecognizedROMs.all.contains { $0.gameID == gameID }
        }
    }
    func revision(_ gameID: String) throws -> UUID? {
        if let job = try read(), job.plan.targets.contains(where: { $0.id == gameID }) { return job.plan.id }
        let receipt = completedURL(gameID)
        guard FileManager.default.fileExists(atPath: receipt.path) else { return nil }
        return try JSONDecoder().decode(UUID.self, from: Data(contentsOf: receipt))
    }
    func resolve(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1, ["Documents", "Support"].contains(parts[0]),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw BoundROMUpdateError.unsafePath }
        var result = parts[0] == "Documents" ? storage.documents : storage.support
        for part in parts.dropFirst() {
            result.appendPathComponent(part)
            if (try? result.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw BoundROMUpdateError.unsafePath }
        }
        guard !result.path.hasPrefix(url.deletingLastPathComponent().path + "/") else { throw BoundROMUpdateError.unsafePath }
        return result
    }
    func inventory(_ urls: [URL]) throws -> [BoundROMCleanupPlan.File] {
        var result: [String: BoundROMCleanupPlan.File] = [:]
        func visit(_ url: URL) throws {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw BoundROMUpdateError.unsafePath }
            if values.isDirectory == true {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try visit(child) }
            } else {
                guard values.isRegularFile == true else { throw BoundROMUpdateError.unsafePath }
                let absolute = url.standardizedFileURL.path
                let bases = [("Documents", storage.documents), ("Support", storage.support)]
                guard let base = bases.first(where: { absolute.hasPrefix($0.1.standardizedFileURL.path + "/") }) else { throw BoundROMUpdateError.unsafePath }
                let path = base.0 + "/" + absolute.dropFirst(base.1.standardizedFileURL.path.count + 1)
                _ = try resolve(path)
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                result[path] = .init(path: path, sha256: BoundROMUpdateContent.hash(data), bytes: Int64(data.count))
            }
        }
        for url in urls { try visit(url) }
        return result.values.sorted { $0.path < $1.path }
    }
    func delete(_ files: [BoundROMCleanupPlan.File]) throws {
        for file in files {
            let url = try resolve(file.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard try BoundROMUpdateContent.hash(Data(contentsOf: url, options: .mappedIfSafe)) == file.sha256 else { throw BoundROMUpdateError.changedBackup }
            try FileManager.default.removeItem(at: url)
            var parent = url.deletingLastPathComponent()
            while parent != storage.documents && parent != storage.support && parent.path != storage.root.path {
                guard (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true else { break }
                try FileManager.default.removeItem(at: parent); parent.deleteLastPathComponent()
            }
        }
    }
}

@MainActor
enum BoundROMCleanupLive {
    static func latest() throws -> BoundROMCleanupIdentity {
        let url = DatabaseManager.gamesDirectoryURL.appendingPathComponent(BoundGameProfiles.current.gameID + ".gba")
        guard let identity = BoundRecognizedROMs.all.first(where: { $0.gameID == BoundGameProfiles.current.gameID && $0.sha256 == BoundGameProfiles.current.romSHA256 }) else { throw BoundROMUpdateError.incompatibleROM }
        if FileManager.default.fileExists(atPath: url.path) {
            let content = try BoundROMUpdateContent(data: Data(contentsOf: url), expectedSHA256: identity.sha256)
            guard content.gameID == identity.gameID else { throw BoundROMUpdateError.incompatibleROM }
        }
        return identity
    }
    static var idle: Bool {
        BoundROMUpdateActivity.canApply && !BoundROMUpdateManager.shared.isApplying &&
        !BoundROMUpdateManager.shared.isChecking && DatabaseManager.shared.isStarted
    }
    static func operations(storage: BoundROMUpdateStorage) -> BoundROMCleanupCoordinator.Operations {
        let journal = BoundROMCleanupJournal(storage: storage)
        return .init(prepare: {
            try await SyncManager.shared.withROMCleanupFence {
                guard idle, try storage.pending() == nil else { throw BoundROMUpdateError.busy }
                await BoundServerBackupManager.shared.cancelPendingOperationsAndWait()
                let preserved = try latest(), owner = BoundFriendAccount.shared.session?.owner
                guard owner != nil else { throw BoundROMCleanupError.signIn }
                let identities = BoundRecognizedROMs.all.filter { $0.gameID != preserved.gameID && $0.sha256 != preserved.sha256 }
                let locals = try localInventory(storage: storage, preserved: preserved, identities: identities)
                let cloud = try await SyncManager.shared.prepareROMCleanupCloud(gameIDs: identities.map(\.gameID),
                    states: locals.mapValues { $0.3 })
                var runs: [String: [BoundROMCleanupPlan.Run]] = [:]
                if let session = BoundFriendAccount.shared.session {
                    let service = BoundNakamaRunService(); _ = try await service.configureSaves(session: session)
                    for identity in identities {
                        let listed = try await service.listSaves(gameID: identity.gameID)
                        for run in listed {
                            guard run.game_id == identity.gameID, run.identity.gameID == identity.gameID,
                                  run.identity.romSHA256 == identity.sha256, run.identity.run == run.id,
                                  run.participants.contains(session.owner) else { throw BoundROMUpdateError.incompatibleROM }
                        }
                        runs[identity.gameID] = listed.map { .init(id: $0.id, revision: $0.revision, participants: $0.participants) }
                    }
                }
                let backups = Set(try await BoundServerBackupManager.shared.cleanupInventory(expectedOwner: owner!).map(\.gameID))
                var targets: [BoundROMCleanupPlan.Target] = []
                for identity in identities {
                    guard let scope = cloud[identity.gameID] else { throw BoundROMUpdateError.storage }
                    let local = locals[identity.gameID], remoteRuns = runs[identity.gameID] ?? []
                    guard local != nil || !scope.1.isEmpty || !remoteRuns.isEmpty || backups.contains(identity.gameID) else { continue }
                    let files = try journal.inventory(local?.2 ?? [])
                    guard files.allSatisfy({ $0.sha256 != preserved.sha256 && !$0.path.split(separator: "/").contains(Substring(preserved.gameID)) }) else { throw BoundROMUpdateError.incompatibleROM }
                    targets.append(.init(identity: identity, name: local?.0 ?? "Multi Red " + identity.sha256.prefix(12),
                        filename: local?.1, files: files, stateIDs: local?.3 ?? [], cloud: scope.0, dropbox: scope.1,
                        runs: remoteRuns, serverBackup: scope.0.serverBackupOwner != nil))
                }
                guard BoundFriendAccount.shared.session?.owner == owner, idle else { throw BoundROMUpdateError.busy }
                return .init(id: UUID(), owner: owner, preserved: preserved, targets: targets.sorted { $0.id < $1.id })
            }
        }, idle: { idle }, owner: { BoundFriendAccount.shared.session?.owner }, local: { target in
            try await SyncManager.shared.withROMCleanupFence {
                let preserved = try latest()
                guard idle, target.id != preserved.gameID, target.identity.sha256 != preserved.sha256,
                      BoundFriendAccount.shared.session?.owner == target.cloud.owner else { throw BoundROMUpdateError.busy }
                await BoundServerBackupManager.shared.cancelPendingOperationsAndWait()
                guard idle, BoundFriendAccount.shared.session?.owner == target.cloud.owner else { throw BoundROMUpdateError.busy }
                NotificationCenter.default.post(name: BoundROMUpdateManager.saveClearBegan, object: target.id)
                let context = DatabaseManager.shared.newBackgroundContext()
                try context.performAndWait {
                    let request = Game.fetchRequest()
                    request.predicate = NSPredicate(format: "identifier == %@", target.id)
                    let records = try context.fetch(request)
                    guard records.count <= 1 else { throw BoundROMUpdateError.storage }
                    if let game = records.first {
                        guard game.filename == target.filename, Set(game.saveStates.map(\.identifier)).isSubset(of: Set(target.stateIDs)) else { throw BoundROMUpdateError.changedBackup }
                        if FileManager.default.fileExists(atPath: game.fileURL.path) {
                            guard try BoundROMUpdateContent.hash(Data(contentsOf: game.fileURL)) == target.identity.sha256 else { throw BoundROMUpdateError.incompatibleROM }
                        }
                    }
                    try journal.delete(target.files)
                    for game in records {
                        game.previewSaveState = nil
                        for state in game.saveStates { context.delete(state) }
                        if let save = game.gameSave { context.delete(save); game.gameSave = nil }
                        // Files were checked and permanently removed above; avoid Game's eager deletion hook.
                        game.filename = ""; context.delete(game)
                    }
                    if context.hasChanges { try context.save() }
                }
                BoundMultiplayerSaveStore.shared.discardServerSession(gameID: target.id)
                BoundServerMemoryFiles.discard(gameID: target.id)
            }
        }, cloud: { target in
            try await SyncManager.shared.withROMCleanupFence {
                let preserved = try latest()
                guard idle, target.id != preserved.gameID, target.identity.sha256 != preserved.sha256,
                      BoundFriendAccount.shared.session?.owner == target.cloud.owner else { throw BoundROMUpdateError.busy }
                if target.serverBackup, let owner = target.cloud.serverBackupOwner {
                    try await BoundServerBackupManager.shared.delete(gameID: target.id, expectedOwner: owner)
                }
                if !target.runs.isEmpty {
                    guard let session = BoundFriendAccount.shared.session, session.owner == target.cloud.owner else { throw BoundROMUpdateError.busy }
                    let service = BoundNakamaRunService(); _ = try await service.configureSaves(session: session)
                    for run in target.runs { try await service.deleteSave(run.id, expectedRevision: run.revision) }
                }
                try await SyncManager.shared.deleteROMCleanupDropbox(entries: target.dropbox, context: target.cloud)
                try await SyncManager.shared.removeLocalSaveSyncRecords(gameID: target.id, context: target.cloud)
            }
        })
    }
    static func localInventory(storage: BoundROMUpdateStorage, preserved: BoundROMCleanupIdentity,
                               identities: [BoundROMCleanupIdentity]) throws -> [String: (String, String, [URL], [String])] {
        let context = DatabaseManager.shared.newBackgroundContext()
        return try context.performAndWait { () -> [String: (String, String, [URL], [String])] in
            let currentRequest = Game.fetchRequest()
            currentRequest.predicate = NSPredicate(format: "identifier == %@", preserved.gameID)
            let current = try context.fetch(currentRequest)
            guard current.count <= 1 else { throw BoundROMUpdateError.incompatibleROM }
            if let game = current.first {
                guard try BoundROMUpdateContent.hash(Data(contentsOf: game.fileURL)) == preserved.sha256 else { throw BoundROMUpdateError.incompatibleROM }
            }
            var result: [String: (String, String, [URL], [String])] = [:]
            for game in try context.fetch(Game.fetchRequest()) {
                guard let identity = identities.first(where: { $0.gameID == game.identifier }) else { continue }
                guard !BoundServerBackupManager.hasPendingRestore(gameID: game.identifier),
                      try storage.pendingSaveClear(gameID: game.identifier) == nil else { throw BoundROMUpdateError.busy }
                if FileManager.default.fileExists(atPath: game.fileURL.path) {
                    let data = try Data(contentsOf: game.fileURL, options: .mappedIfSafe)
                    guard BoundROMUpdateContent.hash(data) == identity.sha256,
                          Insecure.SHA1.hash(data: data).map({ String(format: "%02x", $0) }).joined() == identity.gameID else { continue }
                }
                let roots = try localRoots(game: game, storage: storage)
                result[identity.gameID] = (game.name, game.filename, roots, game.saveStates.map(\.identifier).sorted())
            }
            return result
        }
    }
    static func localRoots(game: Game, storage: BoundROMUpdateStorage) throws -> [URL] {
        let fm = FileManager.default, store = BoundMultiplayerSaveStore.shared
        let stem = BoundMultiplayerSaveStore.hash(Data(game.identifier.utf8))
        var paths = [game.fileURL, game.gameSaveURL, game.gameSaveURL.deletingPathExtension().appendingPathExtension("rtc"),
            DatabaseManager.saveStatesDirectoryURL.appendingPathComponent(game.identifier), store.directory(gameID: game.identifier),
            storage.support.appendingPathComponent("Soul Link/" + stem + ".json"),
            storage.support.appendingPathComponent("Soul Link/" + stem + ".timeline.json")]
        paths += try storage.cooperativeRecoveryFiles(gameID: game.identifier)
        for category in ["Finished Runs", "New Game Originals"] {
            let folder = store.root.appendingPathComponent(category)
            if fm.fileExists(atPath: folder.path) {
                for directory in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    let receipt = directory.appendingPathComponent(category == "Finished Runs" ? "run.json" : "receipt.json")
                    guard let data = try? Data(contentsOf: receipt), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let identity = value["identity"] as? [String: Any], identity["gameID"] as? String == game.identifier else { continue }
                    paths.append(directory)
                }
            }
        }
        let recovery = storage.support.appendingPathComponent("Friend Battles")
        if fm.fileExists(atPath: recovery.path) {
            for file in try fm.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String], value["gameID"] == game.identifier else { continue }
                guard let name = value["state"], name == URL(fileURLWithPath: name).lastPathComponent,
                      UUID(uuidString: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent) != nil, name.hasSuffix(".state") else { throw BoundROMUpdateError.unsafePath }
                paths += [file, recovery.appendingPathComponent(name)]
            }
        }
        // Older save-clear copies have an explicit source map. Delete only the copies
        // whose exact source belongs to this game, leaving mixed-version archives intact.
        let sources = try paths.map { try storage.source(for: $0, remove: true).path }
        let cleared = storage.root.appendingPathComponent("Cleared Saves")
        if fm.fileExists(atPath: cleared.path) {
            for folder in try fm.contentsOfDirectory(at: cleared, includingPropertiesForKeys: nil) {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("sources.json")),
                      let saved = try? JSONDecoder().decode([BoundROMUpdateStorage.Source].self, from: data) else { continue }
                for (index, source) in saved.enumerated() where sources.contains(source.path) { paths.append(folder.appendingPathComponent(String(index))) }
            }
        }
        let backups = storage.root.appendingPathComponent("Backups")
        if fm.fileExists(atPath: backups.path) {
            for folder in try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil) {
                for source in sources { paths.append(folder.appendingPathComponent("Originals/" + source)) }
                let incoming = folder.appendingPathComponent("incoming.gba")
                if let data = try? Data(contentsOf: incoming), BoundROMUpdateContent.hash(data) == BoundRecognizedROMs.all.first(where: { $0.gameID == game.identifier })?.sha256 { paths.append(incoming) }
            }
        }
        return paths
    }
}

@MainActor
final class BoundROMCleanupCoordinator: ObservableObject {
    struct Operations {
        var prepare: () async throws -> BoundROMCleanupPlan
        var idle: () -> Bool
        var owner: () -> UUID?
        var local: (BoundROMCleanupPlan.Target) async throws -> Void
        var cloud: (BoundROMCleanupPlan.Target) async throws -> Void
    }
    static let shared = BoundROMCleanupCoordinator()
    @Published private(set) var preview: BoundROMCleanupPlan?
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    private let journal: BoundROMCleanupJournal
    private let operations: Operations
    var pending: Bool { (try? journal.read())?.completed == false }
    init(storage: BoundROMUpdateStorage = .live, operations: Operations? = nil) {
        self.journal = .init(storage: storage)
        self.operations = operations ?? BoundROMCleanupLive.operations(storage: storage)
        if FileManager.default.fileExists(atPath: journal.url.path), (try? journal.read()) == nil {
            status = "The cleanup record needs recovery. No new deletion scope was created."
        } else if pending { status = "ROM cleanup is incomplete. Clear ROMs retries the confirmed scope." }
    }
    func prepare() async {
        guard !busy else { return }
        if pending { await retry(); return }
        busy = true; defer { busy = false }
        do {
            guard operations.idle() else { throw BoundROMCleanupError.busy }
            let plan = try await operations.prepare()
            guard plan.owner == operations.owner() else { throw BoundROMCleanupError.accountChanged }
            guard operations.idle() else { throw BoundROMCleanupError.busy }
            preview = plan.targets.isEmpty ? nil : plan
            status = plan.targets.isEmpty ? "No recognized older ROMs or saves found." : ""
        } catch { status = error.localizedDescription }
    }
    func cancel() { preview = nil }
    func confirm() async {
        guard !busy, let preview else { return }
        do {
            guard operations.idle() else { throw BoundROMCleanupError.busy }
            guard preview.owner == operations.owner() else { throw BoundROMCleanupError.accountChanged }
            try journal.write(.init(plan: preview))
            self.preview = nil
            await retry()
        } catch { status = error.localizedDescription }
    }
    func retry() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            guard operations.idle(), var job = try journal.read(), !job.completed else { throw BoundROMCleanupError.busy }
            guard job.plan.owner == operations.owner() else { throw BoundROMCleanupError.accountChanged }
            for target in job.plan.targets {
                do {
                    guard operations.idle() else { throw BoundROMCleanupError.busy }
                    guard job.plan.owner == operations.owner() else { throw BoundROMCleanupError.accountChanged }
                    if !job.localDone.contains(target.id) {
                        try await operations.local(target); job.localDone.insert(target.id); try journal.write(job)
                    }
                    if !job.cloudDone.contains(target.id) {
                        try await operations.cloud(target); job.cloudDone.insert(target.id); try journal.write(job)
                    }
                    job.errors.removeValue(forKey: target.id)
                } catch { job.errors[target.id] = error.localizedDescription }
                try journal.write(job)
            }
            job.completed = job.localDone.count == job.plan.targets.count && job.cloudDone.count == job.plan.targets.count
            try journal.write(job)
            status = job.completed ? "Older ROMs and their selected saves were permanently deleted." :
                "Cleanup incomplete. " + job.errors.values.sorted().joined(separator: " ") + " Clear ROMs retries only the confirmed scope."
        } catch { status = error.localizedDescription }
    }
}

struct BoundROMCleanupConfirmation: View {
    @ObservedObject var cleanup: BoundROMCleanupCoordinator
    var body: some View {
        NavigationStack {
            ScrollView { Text(cleanup.preview?.summary ?? "").font(.footnote).textSelection(.enabled).padding() }
                .navigationTitle("Clear ROMs")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cleanup.cancel() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Delete Permanently", role: .destructive) { Task { await cleanup.confirm() } }.disabled(cleanup.busy)
                    }
                }
        }.accessibilityIdentifier("bound.clear-roms-confirmation")
    }
}
