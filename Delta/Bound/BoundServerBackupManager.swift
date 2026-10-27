import Foundation
import Combine
import CoreData
import CryptoKit
import UIKit
import Darwin

@MainActor
final class BoundServerBackupManager: ObservableObject {
    enum Provider: String, Codable, CaseIterable { case none, dropbox, server }
    struct Status: Decodable { let approved: Bool; let provider: Provider; let revision: String }
    struct Save: Codable, Identifiable, Equatable, Sendable {
        let gameID: String
        let name: String
        let version: String
        let sha256: String
        let size: Int
        let modifiedAt: String
        var id: String { gameID }
    }
    struct Context {
        let owner: UUID
        fileprivate let session: AppCloudSession
        fileprivate let generation: UUID
    }
    private struct SaveList: Decodable { let saves: [Save] }
    typealias Failure = BoundServerBackupPackage.Failure
    static let shared = BoundServerBackupManager()
    nonisolated static let providerDidChangeNotification = Notification.Name("BoundServerBackupProviderDidChange")
    nonisolated private static let activeOwnerKey = "bound.server-backup.active-owner.v1"
    nonisolated private static func providerKey(_ owner: UUID) -> String { "bound.cloud-backup.provider.v1." + owner.uuidString.lowercased() }
    nonisolated static func isServerSelected(owner: UUID?) -> Bool {
        guard let owner else { return false }
        return UserDefaults.standard.string(forKey: providerKey(owner)) == Provider.server.rawValue
    }
    nonisolated static var serverEnabledForCurrentAccount: Bool {
        isServerSelected(owner: UserDefaults.standard.string(forKey: activeOwnerKey).flatMap(UUID.init(uuidString:)))
    }
    nonisolated static var dropboxAllowedForCurrentAccount: Bool {
        guard let owner = UserDefaults.standard.string(forKey: activeOwnerKey).flatMap(UUID.init(uuidString:)),
              let value = UserDefaults.standard.string(forKey: providerKey(owner)) else { return true }
        return value == Provider.dropbox.rawValue
    }
    @Published private(set) var approved = false
    @Published private(set) var provider = Provider.none
    @Published private(set) var revision = ""
    @Published private(set) var statusText = ""
    @Published private(set) var busy = false
    @Published private(set) var saves: [Save] = []
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var backupTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var accountOwner: UUID?
    private var statusGate = BoundServerBackupStatusGate()
    private var refreshAfterChange = false

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: BoundFriendAccount.willSignOutNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accountChanged() }
        })
        observers.append(center.addObserver(forName: BoundFriendAccount.sessionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accountChanged() }
        })
        observers.append(center.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { [weak self] notification in
            let changed = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey].contains { key in
                (notification.userInfo?[key] as? Set<NSManagedObject>)?.contains { $0 is GameSave || $0 is SaveState } == true
            }
            guard changed else { return }
            Task { @MainActor [weak self] in self?.scheduleBackup() }
        })
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification, DatabaseManager.didStartNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.recoverInterruptedRestores()
                    await self.refresh()
                    self.scheduleBackup()
                }
            })
        }
        accountChanged()
        Task { [weak self] in
            guard let self else { return }
            await self.recoverInterruptedRestores()
        }
    }
    private func accountChanged() {
        generation = UUID(); backupTask?.cancel(); restoreTask?.cancel(); scheduledTask?.cancel(); refreshTask?.cancel()
        accountOwner = BoundFriendAccount.shared.session?.owner
        approved = false; revision = ""; saves = []; busy = false
        if let owner = accountOwner {
            UserDefaults.standard.set(owner.uuidString, forKey: Self.activeOwnerKey)
            provider = Provider(rawValue: UserDefaults.standard.string(forKey: Self.providerKey(owner)) ?? "none") ?? .none
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeOwnerKey); provider = .none
        }
        statusText = accountOwner == nil ? "Sign in to use server backups." : ""
        if statusGate.isChanging { refreshAfterChange = true }
        else { refreshTask = Task { [weak self] in await self?.refresh() } }
    }
    func captureContext() throws -> Context {
        guard let session = BoundFriendAccount.shared.session, session.owner == accountOwner else { throw Failure.accountChanged }
        try session.credentials()
        return Context(owner: session.owner, session: session, generation: generation)
    }
    private func refreshedContext(expected: AppCloudSession? = nil) async throws -> Context {
        guard let identity = expected ?? BoundFriendAccount.shared.session else { throw Failure.accountChanged }
        let epoch = generation
        await BoundFriendAccount.shared.refreshIfNeeded()
        guard epoch == generation, identity.isSameSession(as: BoundFriendAccount.shared.session) else { throw Failure.accountChanged }
        return try captureContext()
    }
    private func check(_ context: Context, requireServer: Bool = false) throws {
        guard !Task.isCancelled, context.generation == generation, context.session.isSameSession(as: BoundFriendAccount.shared.session),
              context.owner == accountOwner else { throw Failure.accountChanged }
        if requireServer { guard approved, provider == .server else { throw Failure.accountChanged } }
    }
    private func send(_ context: Context, path: String, method: String = "GET", body: Data? = nil,
                      headers: [String: String] = [:], beforeSend: (() throws -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        await BoundFriendAccount.shared.refreshIfNeeded()
        try check(context)
        try beforeSend?()
        let request = try context.session.serverBackupRequest(path: path, method: method, body: body, headers: headers)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(context)
        guard let response = response as? HTTPURLResponse, data.count <= BoundServerBackupPackage.maximumBytes else { throw Failure.invalid }
        switch response.statusCode {
        case 200...299: return (data, response)
        case 409, 412: throw Failure.conflict
        case 401: throw Failure.accountChanged
        case 403: throw Failure.unapproved
        case 413: throw Failure.tooLarge
        default: throw Failure.unavailable
        }
    }
    private func apply(_ status: Status, context: Context) throws {
        try check(context)
        let changed = provider != status.provider || approved != status.approved
        provider = status.provider; approved = status.approved; revision = status.revision
        UserDefaults.standard.set(status.provider.rawValue, forKey: Self.providerKey(context.owner))
        if changed {
            NotificationCenter.default.post(name: Self.providerDidChangeNotification, object: self,
                                            userInfo: ["owner": context.owner, "provider": status.provider.rawValue])
        }
    }
    func refresh() async {
        guard BoundFriendAccount.shared.session != nil, let read = statusGate.beginRead() else { return }
        await recoverInterruptedRestores()
        do {
            let context = try await refreshedContext()
            let (data, _) = try await send(context, path: "/backups/v1/status")
            guard statusGate.accepts(read) else { return }
            try apply(JSONDecoder().decode(Status.self, from: data), context: context)
            if provider == .server, approved {
                try await loadSaves(context)
                if statusText.isEmpty { statusText = "Server backups enabled" }
            } else {
                saves = []
                statusText = approved ? "Server backups available" : "Server backups require account approval."
            }
        } catch {
            if !Task.isCancelled, statusGate.accepts(read) { statusText = error.localizedDescription }
        }
    }
    func refreshProvider() async throws -> Provider {
        guard let read = statusGate.beginRead() else { throw Failure.accountChanged }
        let context = try await refreshedContext()
        let (data, _) = try await send(context, path: "/backups/v1/status")
        guard statusGate.accepts(read) else { throw Failure.accountChanged }
        try apply(JSONDecoder().decode(Status.self, from: data), context: context)
        return provider
    }
    func cancelPendingOperationsAndWait() async {
        generation = UUID()
        let backup = backupTask, restore = restoreTask
        backup?.cancel(); restore?.cancel(); scheduledTask?.cancel()
        await backup?.value; await restore?.value
        backupTask = nil; restoreTask = nil; scheduledTask = nil; busy = false
    }
    /// Call after the previous cloud provider has stopped and drained its transfers.
    func setProvider(_ selected: Provider) async throws {
        guard let identity = BoundFriendAccount.shared.session else { throw Failure.accountChanged }
        guard statusGate.beginChange() else { throw Failure.accountChanged }
        defer {
            statusGate.endChange()
            if refreshAfterChange {
                refreshAfterChange = false
                refreshTask = Task { [weak self] in await self?.refresh() }
            }
        }
        await cancelPendingOperationsAndWait()
        guard selected == .dropbox || SyncManager.shared.coordinator == nil else { throw Failure.conflict }
        let context = try await refreshedContext(expected: identity)
        let (data, _) = try await send(context, path: "/backups/v1/status")
        try apply(JSONDecoder().decode(Status.self, from: data), context: context)
        guard selected != .server || approved else { throw Failure.unapproved }
        let body = try JSONSerialization.data(withJSONObject: ["provider": selected.rawValue, "expectedRevision": revision])
        let (updated, _) = try await send(context, path: "/backups/v1/provider", method: "PUT", body: body,
                                        headers: ["Content-Type": "application/json"])
        try apply(JSONDecoder().decode(Status.self, from: updated), context: context)
        guard provider == selected else { throw Failure.conflict }
        statusText = selected == .server ? "Server backups enabled" : ""
        if selected == .server { scheduleBackup() }
    }
    private func loadSaves(_ context: Context) async throws {
        let (data, _) = try await send(context, path: "/backups/v1/saves")
        let list = try JSONDecoder().decode(SaveList.self, from: data)
        guard list.saves.count <= 1000, Set(list.saves.map(\.gameID)).count == list.saves.count,
              list.saves.allSatisfy({ BoundServerBackupPackage.safeComponent($0.gameID) && BoundServerBackupPackage.digest($0.sha256) &&
                  !$0.version.isEmpty && $0.version.utf8.count <= 128 && $0.size > 0 && $0.size <= BoundServerBackupPackage.maximumBytes }) else { throw Failure.invalid }
        try check(context, requireServer: true)
        saves = list.saves.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func scheduleBackup() {
        guard approved, provider == .server, BoundROMUpdateActivity.canApply else { return }
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, BoundROMUpdateActivity.canApply else { return }
            await self?.backupNow()
        }
    }
    func backupNow() async {
        guard !statusGate.isChanging, backupTask == nil, restoreTask == nil, provider == .server, approved, DatabaseManager.shared.isStarted else { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performBackup()
        }
        backupTask = task
        await task.value; backupTask = nil
    }
    private func versionKey(_ context: Context, gameID: String) -> String {
        "bound.server-backup.version.v1." + context.owner.uuidString.lowercased() + "." + gameID
    }
    private func performBackup() async {
        busy = true
        defer { busy = false }
        do {
            let context = try await refreshedContext()
            try check(context, requireServer: true)
            try await loadSaves(context)
            let db = DatabaseManager.shared.newBackgroundContext()
            let gameIDs = try await db.perform { try db.fetch(Game.fetchRequest()).map(\.identifier) }
            var uploaded = 0, deferred = 0
            for gameID in gameIDs {
                try check(context, requireServer: true)
                guard BoundServerBackupPackage.safeComponent(gameID), !Self.hasPendingRestore(gameID: gameID),
                      !BoundROMUpdateManager.shared.isApplying,
                      !BoundROMUpdateActivity.isGameOpen(gameID: gameID) else { deferred += 1; continue }
                let clearRevision = try BoundROMUpdateStorage.live.saveClearRevision(gameID: gameID)
                let romGeneration = BoundROMUpdateRegistry.generation(for: gameID)
                let activityRevision = BoundROMUpdateActivity.bindingRevision
                let package: BoundServerBackupPackage?
                do { package = try await db.perform { try Self.capture(gameID: gameID, owner: context.owner, context: db) } }
                catch Failure.openGame { deferred += 1; continue }
                guard let package else { continue }
                try check(context, requireServer: true)
                guard !BoundROMUpdateManager.shared.isApplying, !BoundROMUpdateActivity.isGameOpen(gameID: gameID),
                      !BoundROMUpdateStorage.live.hasPendingSaveClear(gameID: gameID),
                      package.manifest.generation == romGeneration, BoundROMUpdateRegistry.generation(for: gameID) == romGeneration,
                      activityRevision == BoundROMUpdateActivity.bindingRevision,
                      try BoundROMUpdateStorage.live.saveClearRevision(gameID: gameID) == clearRevision else { deferred += 1; continue }
                let bytes = try await Task.detached(priority: .utility) { try package.zip() }.value
                try check(context, requireServer: true)
                guard !BoundROMUpdateManager.shared.isApplying, !BoundROMUpdateActivity.isGameOpen(gameID: gameID),
                      !BoundROMUpdateStorage.live.hasPendingSaveClear(gameID: gameID),
                      package.manifest.generation == romGeneration, BoundROMUpdateRegistry.generation(for: gameID) == romGeneration,
                      activityRevision == BoundROMUpdateActivity.bindingRevision,
                      try BoundROMUpdateStorage.live.saveClearRevision(gameID: gameID) == clearRevision else { deferred += 1; continue }
                let sha256 = BoundServerBackupPackage.hash(bytes)
                let existing = saves.first { $0.gameID == gameID }
                if existing?.sha256 == sha256 {
                    UserDefaults.standard.set(existing!.version, forKey: versionKey(context, gameID: gameID)); continue
                }
                if let existing, UserDefaults.standard.string(forKey: versionKey(context, gameID: gameID)) != existing.version { throw Failure.conflict }
                let allowedNameCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                let headers = ["Content-Type": "application/zip", "X-Content-SHA256": sha256,
                               "X-Backup-Name": String(package.manifest.name.prefix(256)).addingPercentEncoding(withAllowedCharacters: allowedNameCharacters) ?? "Game",
                               "If-Match": existing?.version ?? "*"]
                let (data, _) = try await send(context, path: "/backups/v1/saves/" + gameID, method: "PUT", body: bytes, headers: headers) {
                    guard !BoundROMUpdateManager.shared.isApplying, !BoundROMUpdateActivity.isGameOpen(gameID: gameID),
                          BoundROMUpdateRegistry.generation(for: gameID) == romGeneration,
                          activityRevision == BoundROMUpdateActivity.bindingRevision,
                          try BoundROMUpdateStorage.live.saveClearRevision(gameID: gameID) == clearRevision else { throw Failure.conflict }
                    try BoundROMUpdateRegistry.validateUpload(gameID: gameID)
                }
                let saved = try JSONDecoder().decode(Save.self, from: data)
                guard saved.gameID == gameID, saved.sha256 == sha256 else { throw Failure.invalid }
                try check(context, requireServer: true)
                UserDefaults.standard.set(saved.version, forKey: versionKey(context, gameID: gameID))
                saves.removeAll { $0.gameID == gameID }; saves.append(saved); uploaded += 1
            }
            statusText = deferred > 0 ? "Backups saved. Close open games to back up their latest saves." : (uploaded > 0 ? "Backups saved" : "Backups up to date")
        } catch {
            if !Task.isCancelled { statusText = error.localizedDescription }
        }
    }
    func delete(gameID: String, expectedOwner: UUID? = nil) async throws {
        let context = try await refreshedContext()
        guard expectedOwner == nil || context.owner == expectedOwner else { throw Failure.accountChanged }
        try await delete(gameID: gameID, context: context)
    }
    /// Cleanup previews must use a fresh authorized inventory, never a cached
    /// list from a previous account or a failed/offline refresh.
    func cleanupInventory(expectedOwner: UUID) async throws -> [Save] {
        let context = try await refreshedContext()
        guard context.owner == expectedOwner else { throw Failure.accountChanged }
        if provider == .server, approved {
            try await loadSaves(context)
            return saves
        }
        return []
    }
    func delete(gameID: String, context: Context) async throws {
        guard BoundServerBackupPackage.safeComponent(gameID) else { throw Failure.invalid }
        _ = try await send(context, path: "/backups/v1/saves/" + gameID, method: "DELETE")
        try check(context)
        UserDefaults.standard.removeObject(forKey: versionKey(context, gameID: gameID))
        saves.removeAll { $0.gameID == gameID }
    }
    func restore(_ save: Save) async {
        guard !statusGate.isChanging, !busy, backupTask == nil, restoreTask == nil else { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performRestore(save)
        }
        restoreTask = task
        await task.value; restoreTask = nil
    }
    private func performRestore(_ save: Save) async {
        busy = true; defer { busy = false }
        do {
            let context = try await refreshedContext(); try check(context, requireServer: true)
            guard !BoundROMUpdateActivity.isGameOpen(gameID: save.gameID) else { throw Failure.openGame }
            let (data, response) = try await send(context, path: "/backups/v1/saves/" + save.gameID)
            guard response.value(forHTTPHeaderField: "X-Backup-Version") == save.version,
                  response.value(forHTTPHeaderField: "X-Content-SHA256") == save.sha256,
                  BoundServerBackupPackage.hash(data) == save.sha256 else { throw Failure.conflict }
            let package = try await Task.detached(priority: .utility) { try BoundServerBackupPackage.unzip(data, owner: context.owner, gameID: save.gameID) }.value
            try check(context, requireServer: true)
            guard !BoundROMUpdateActivity.isGameOpen(gameID: save.gameID) else { throw Failure.openGame }
            try Self.install(package, remoteVersion: save.version)
            UserDefaults.standard.set(save.version, forKey: versionKey(context, gameID: save.gameID))
            statusText = package.manifest.soulLink ? "Backup ready. Open the game to continue multiplayer recovery." : "Backup restored"
        } catch { if !Task.isCancelled { statusText = error.localizedDescription } }
    }
}

private extension BoundServerBackupManager {
    nonisolated static func readFile(_ url: URL, maximum: Int = BoundServerBackupPackage.maximumBytes) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else { throw Failure.invalid }
        guard size <= maximum else { throw Failure.tooLarge }
        let bytes = try Data(contentsOf: url)
        guard bytes.count == size else { throw Failure.invalid }
        return bytes
    }
    nonisolated static func romHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func game(_ gameID: String, context: NSManagedObjectContext) throws -> Game {
        let request = Game.fetchRequest(); request.predicate = NSPredicate(format: "identifier == %@", gameID); request.fetchLimit = 1
        guard let game = try context.fetch(request).first else { throw Failure.missingGame }
        return game
    }
    nonisolated static func hasNativeRecovery(gameID: String) throws -> Bool {
        let fm = FileManager.default
        for name in ["Friend Battles", "Cooperative Battles"] {
            let directory = BoundROMUpdateStorage.live.support.appendingPathComponent(name)
            guard fm.fileExists(atPath: directory.path) else { continue }
            for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                let data = try readFile(url)
                guard data.count <= 65536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let recorded = object["gameID"] as? String else { return true }
                if recorded == gameID { return true }
            }
        }
        return false
    }
    nonisolated static func capture(gameID: String, owner: UUID, context: NSManagedObjectContext) throws -> BoundServerBackupPackage? {
        let game = try game(gameID, context: context)
        guard !game.boundUsesServerMultiplayer else { return nil }
        guard gameID != Game.melonDSBIOSIdentifier, gameID != Game.melonDSDSiBIOSIdentifier else { return nil }
        try BoundROMUpdateRegistry.validateUpload(gameID: gameID)
        if try hasNativeRecovery(gameID: gameID) { throw Failure.recovery }
        let fm = FileManager.default, store = BoundMultiplayerSaveStore.shared
        let soulLink = store.hasRun(gameID: gameID)
        var files: [String: Data] = [:], states: [BoundServerBackupPackage.State] = []
        var remaining = BoundServerBackupPackage.maximumBytes
        func add(_ path: String, _ url: URL) throws {
            let data = try readFile(url, maximum: remaining)
            remaining -= data.count; files[path] = data
        }
        if soulLink {
            guard let manifest = try store.manifest(gameID: gameID), manifest.identity.owner == owner else { throw Failure.recovery }
            let snapshot = try store.snapshotCloudExport(gameID: gameID)
            defer { try? fm.removeItem(at: snapshot) }
            try add("game.sav", snapshot.appendingPathComponent("game.sav"))
            try add("complete.boundrun", snapshot.appendingPathComponent("complete.boundrun"))
        } else {
            if fm.fileExists(atPath: game.gameSaveURL.path) {
                try add("game.sav", game.gameSaveURL)
                if let sha1 = game.gameSave?.sha1 {
                    try BoundROMUpdateResetPolicy.validateBatteryForUpload(files["game.sav"], expectedSHA1: sha1)
                }
            }
            let rtc = game.gameSaveURL.deletingPathExtension().appendingPathExtension("rtc")
            if fm.fileExists(atPath: rtc.path) { try add("game.rtc", rtc) }
            guard game.saveStates.count <= BoundServerBackupPackage.maximumStates else { throw Failure.tooLarge }
            for state in game.saveStates.sorted(by: { $0.identifier < $1.identifier }) {
                guard let core = state.coreIdentifier, let version = state.coreVersion else { throw Failure.incompatible }
                states.append(.init(identifier: state.identifier, filename: state.filename, name: state.name, type: state.type.rawValue,
                                    coreIdentifier: core, coreVersion: version, createdAt: state.creationDate, modifiedAt: state.modifiedDate))
                try add("states/" + state.identifier + ".state", state.fileURL)
                if fm.fileExists(atPath: state.imageFileURL.path) { try add("states/" + state.identifier + ".png", state.imageFileURL) }
            }
        }
        guard files["game.sav"] != nil || !states.isEmpty else { return nil }
        let manifest = BoundServerBackupPackage.Manifest(owner: owner, gameID: gameID, name: game.name, gameType: game.type.rawValue,
            romSHA256: try romHash(game.fileURL), generation: BoundROMUpdateRegistry.generation(for: gameID), soulLink: soulLink,
            states: states, files: files.mapValues(BoundServerBackupPackage.Blob.init))
        let result = BoundServerBackupPackage(manifest: manifest, files: files)
        try result.validate(owner: owner, gameID: gameID)
        return result
    }

    struct OriginalState: Codable {
        let id: String, filename: String
        let name: String?, core: String?, coreVersion: String?
        let type: Int16
        let createdAt: Date, modifiedAt: Date
        init(_ state: SaveState) {
            id = state.identifier; filename = state.filename; name = state.name; type = state.type.rawValue
            core = state.coreIdentifier; coreVersion = state.coreVersion; createdAt = state.creationDate; modifiedAt = state.modifiedDate
        }
    }
    struct RestoreJournal: Codable {
        let owner: UUID, gameID: String
        let states: [OriginalState]
        let saveExisted: Bool, modifiedAt: Date?, sha1: String?
        let files: [String: String]
    }
    nonisolated static var restoreRoot: URL {
        BoundROMUpdateStorage.live.support.appendingPathComponent("Server Backup Restores", isDirectory: true)
    }
    nonisolated static func restoreDirectory(gameID: String) -> URL {
        restoreRoot.appendingPathComponent(BoundServerBackupPackage.hash(Data(gameID.utf8)), isDirectory: true)
    }
    nonisolated static func snapshotFiles(game: Game) throws -> [String: Data] {
        var result: [String: Data] = [:]; let fm = FileManager.default
        var remaining = BoundServerBackupPackage.maximumBytes
        func add(_ path: String, _ url: URL) throws {
            let data = try readFile(url, maximum: remaining)
            remaining -= data.count; result[path] = data
        }
        for (name, url) in [("battery", game.gameSaveURL), ("rtc", game.gameSaveURL.deletingPathExtension().appendingPathExtension("rtc"))] {
            if fm.fileExists(atPath: url.path) { try add(name, url) }
        }
        let directory = DatabaseManager.saveStatesDirectoryURL(for: game)
        if fm.fileExists(atPath: directory.path) {
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                guard !name.hasPrefix("."), !name.contains("/"), !name.contains("\\") else { throw Failure.invalid }
                try add("states/" + name, file)
            }
        }
        return result
    }
    nonisolated static func archiveCompletedRestore(_ folder: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return }
        let history = restoreRoot.appendingPathComponent("History", isDirectory: true)
        try fm.createDirectory(at: history, withIntermediateDirectories: true)
        try fm.moveItem(at: folder, to: history.appendingPathComponent(UUID().uuidString, isDirectory: true))
    }
    nonisolated static func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Failure.unavailable }
    }
    static func install(_ package: BoundServerBackupPackage, remoteVersion: String) throws {
        let context = DatabaseManager.shared.newBackgroundContext()
        try context.performAndWait {
            let manifest = package.manifest, game = try game(manifest.gameID, context: context)
            guard !game.boundUsesServerMultiplayer else { throw Failure.incompatible }
            guard !hasPendingRestore(gameID: game.identifier), !BoundROMUpdateStorage.live.hasPendingSaveClear(gameID: game.identifier) else { throw Failure.recovery }
            try BoundROMUpdateRegistry.validateDownload(gameID: game.identifier, generation: manifest.generation, isSave: true)
            guard game.type.rawValue == manifest.gameType, try romHash(game.fileURL) == manifest.romSHA256 else { throw Failure.incompatible }
            guard try !hasNativeRecovery(gameID: game.identifier) else { throw Failure.recovery }
            if manifest.soulLink {
                guard let bytes = package.files["complete.boundrun"], let battery = package.files["game.sav"] else { throw Failure.invalid }
                let archive = try JSONDecoder().decode(BoundMultiplayerSaveStore.CloudArchive.self, from: bytes)
                guard let checkpoint = archive.checkpoints.first, checkpoint.payload.manifest.identity.owner == manifest.owner,
                      checkpoint.payload.manifest.identity.gameID == game.identifier,
                      checkpoint.payload.files["game.sav"]?.data == battery else { throw Failure.invalid }
                // Validate receipts and every checkpoint in isolation before touching the real recovery inbox.
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let validator = BoundMultiplayerSaveStore(root: temporary, support: temporary, deviceID: UUID())
                let validationFolder = try validator.stageDownload(gameID: game.identifier, version: remoteVersion)
                try bytes.write(to: validationFolder.appendingPathComponent("complete.boundrun"), options: .atomic)
                guard try validator.inspectIncoming(gameID: game.identifier) != nil else { throw Failure.invalid }
                let folder = try BoundMultiplayerSaveStore.shared.stageDownload(gameID: game.identifier,
                    version: "server-" + remoteVersion, run: checkpoint.payload.manifest.identity.run)
                try battery.write(to: folder.appendingPathComponent("game.sav"), options: .atomic)
                try bytes.write(to: folder.appendingPathComponent("complete.boundrun"), options: .atomic)
                _ = try BoundMultiplayerSaveStore.shared.inspectIncoming(gameID: game.identifier)
                return
            }
            let soulLedger = BoundROMUpdateStorage.live.support.appendingPathComponent("Soul Link/" + BoundServerBackupPackage.hash(Data(game.identifier.utf8)) + ".json")
            guard !BoundMultiplayerSaveStore.shared.hasRun(gameID: game.identifier), !FileManager.default.fileExists(atPath: soulLedger.path) else { throw Failure.recovery }
            for state in manifest.states {
                let request = SaveState.fetchRequest(); request.predicate = NSPredicate(format: "identifier == %@", state.identifier)
                if let existing = try context.fetch(request).first, existing.game?.identifier != game.identifier { throw Failure.invalid }
                if game.saveStates.contains(where: { $0.filename == state.filename && $0.identifier != state.identifier }) { throw Failure.invalid }
            }
            let originals = try snapshotFiles(game: game)
            let folder = restoreDirectory(gameID: game.identifier)
            try archiveCompletedRestore(folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (path, data) in originals {
                let target = folder.appendingPathComponent("originals/" + path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try durableWrite(data, to: target)
                guard try readFile(target) == data else { throw Failure.invalid }
            }
            let journal = RestoreJournal(owner: manifest.owner, gameID: game.identifier, states: game.saveStates.map(OriginalState.init),
                saveExisted: game.gameSave != nil, modifiedAt: game.gameSave?.modifiedDate, sha1: game.gameSave?.sha1,
                files: originals.mapValues(BoundServerBackupPackage.hash))
            try durableWrite(JSONEncoder().encode(journal), to: folder.appendingPathComponent("pending.json"))
            do {
                if let data = package.files["game.sav"] {
                    try data.write(to: game.gameSaveURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    let save = game.gameSave ?? GameSave(context: context)
                    save.identifier = game.identifier; save.game = game; save.modifiedDate = Date()
                    save.sha1 = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
                let rtc = game.gameSaveURL.deletingPathExtension().appendingPathExtension("rtc")
                if let data = package.files["game.rtc"] { try data.write(to: rtc, options: .atomic) }
                else if package.files["game.sav"] != nil, FileManager.default.fileExists(atPath: rtc.path) { try FileManager.default.removeItem(at: rtc) }
                for value in manifest.states {
                    let state = game.saveStates.first { $0.identifier == value.identifier } ?? SaveState(context: context)
                    state.identifier = value.identifier; state.filename = value.filename; state.game = game
                    state.name = value.name; state.type = SaveStateType(rawValue: value.type)!
                    state.coreIdentifier = value.coreIdentifier; state.coreVersion = value.coreVersion
                    state.creationDate = value.createdAt; state.modifiedDate = value.modifiedAt
                    try package.files["states/" + value.identifier + ".state"]!.write(to: state.fileURL, options: .atomic)
                    if let image = package.files["states/" + value.identifier + ".png"] { try image.write(to: state.imageFileURL, options: .atomic) }
                    else if FileManager.default.fileExists(atPath: state.imageFileURL.path) { try FileManager.default.removeItem(at: state.imageFileURL) }
                }
                try context.save()
                try FileManager.default.removeItem(at: folder.appendingPathComponent("pending.json"))
                try? archiveCompletedRestore(folder)
            } catch {
                context.rollback()
                try rollback(journal, folder: folder, context: context)
                throw error
            }
        }
    }
    nonisolated static func rollback(_ journal: RestoreJournal, folder: URL, context: NSManagedObjectContext) throws {
        let game = try game(journal.gameID, context: context), fm = FileManager.default
        var files: [String: Data] = [:]
        for (path, hash) in journal.files {
            guard path == "battery" || path == "rtc" || (path.hasPrefix("states/") && path.split(separator: "/").count == 2 && !path.contains("..") && !path.contains("\\")) else { throw Failure.invalid }
            let data = try readFile(folder.appendingPathComponent("originals/" + path))
            guard BoundServerBackupPackage.hash(data) == hash else { throw Failure.invalid }
            files[path] = data
        }
        for state in game.saveStates where !journal.states.contains(where: { $0.id == state.identifier }) { context.delete(state) }
        for value in journal.states {
            let state = game.saveStates.first { $0.identifier == value.id } ?? SaveState(context: context)
            state.identifier = value.id; state.filename = value.filename; state.name = value.name; state.game = game
            state.type = SaveStateType(rawValue: value.type) ?? .general; state.coreIdentifier = value.core; state.coreVersion = value.coreVersion
            state.creationDate = value.createdAt; state.modifiedDate = value.modifiedAt
        }
        if journal.saveExisted {
            let save = game.gameSave ?? GameSave(context: context)
            save.identifier = game.identifier; save.game = game; save.modifiedDate = journal.modifiedAt ?? .distantPast; save.sha1 = journal.sha1
        } else if let save = game.gameSave { context.delete(save) }
        try context.save()
        let directory = DatabaseManager.saveStatesDirectoryURL(for: game)
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, target) in [("battery", game.gameSaveURL), ("rtc", game.gameSaveURL.deletingPathExtension().appendingPathExtension("rtc"))] {
            if let data = files[name] { try data.write(to: target, options: .atomic) }
            else if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        }
        for (path, data) in files where path.hasPrefix("states/") { try data.write(to: directory.appendingPathComponent(String(path.dropFirst(7))), options: .atomic) }
        try fm.removeItem(at: folder.appendingPathComponent("pending.json"))
        try? archiveCompletedRestore(folder)
    }
    func recoverInterruptedRestores() async {
        guard DatabaseManager.shared.isStarted else { return }
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: Self.restoreRoot, includingPropertiesForKeys: nil)) ?? [] {
            let pending = folder.appendingPathComponent("pending.json")
            guard fm.fileExists(atPath: pending.path) else { continue }
            do {
                let journal = try JSONDecoder().decode(RestoreJournal.self, from: Data(contentsOf: pending))
                guard !BoundROMUpdateActivity.isGameOpen(gameID: journal.gameID),
                      folder.standardizedFileURL.path == Self.restoreDirectory(gameID: journal.gameID).standardizedFileURL.path else { continue }
                // Rollback restores the device's original local data, regardless of who is now signed in.
                let context = DatabaseManager.shared.newBackgroundContext()
                try context.performAndWait { try Self.rollback(journal, folder: folder, context: context) }
            } catch { statusText = "A previous restore needs recovery. Your original saves are retained." }
        }
    }
}

extension BoundServerBackupManager {
    nonisolated static func hasPendingRestore(gameID: String) -> Bool {
        FileManager.default.fileExists(atPath: restoreDirectory(gameID: gameID).appendingPathComponent("pending.json").path)
    }
}
