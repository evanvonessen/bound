import Foundation
import CryptoKit
import Darwin

/// Only the exact integrated cartridge supported by this Bound build can be installed.
struct BoundROMUpdateContent: Equatable, Codable {
    static let byteCount = 32 * 1024 * 1024
    let gameID: String
    let sha256: String
    init(data: Data, expectedSHA256: String, expectedByteCount: Int = Self.byteCount) throws {
        guard data.count == expectedByteCount else { throw BoundROMUpdateError.invalidROM }
        let digest = Self.hash(data)
        guard digest == expectedSHA256 else { throw BoundROMUpdateError.incompatibleROM }
        gameID = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        sha256 = digest
    }
    /// A user may explicitly replace an older integrated ROM in the same family.
    /// This is enrollment only; incoming updates still require the current exact hash.
    static func enrollment(data: Data, gameID: String) throws -> Self {
        if let profile = MultiRedAdapter.profile(gameID: gameID) {
            let content = try Self(data: data, expectedSHA256: profile.romSHA256)
            guard content.gameID == profile.gameID else { throw BoundROMUpdateError.invalidROM }
            return content
        }
        let descriptor = 33_513_216
        guard data.count == byteCount,
              data.subdata(in: 0xAC..<0xB0) == Data("BPRE".utf8),
              data.subdata(in: descriptor..<descriptor + 8) == Data("RRMPI001".utf8),
              data.subdata(in: descriptor + 20..<descriptor + 36) == BoundWorldContract.ruleset else { throw BoundROMUpdateError.invalidROM }
        let content = try Self(data: data, expectedSHA256: hash(data))
        guard content.gameID == gameID else { throw BoundROMUpdateError.invalidROM }
        return content
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Metadata lookup does not admit ROM bytes. It only prevents the updater
    /// from merging two separately supported exact-ROM storage identities.
    private var isHistoricalProfile: Bool {
        BoundGameProfiles.all.contains { $0 != BoundGameProfiles.current && $0.gameID == gameID && $0.romSHA256 == sha256 }
    }
    func validateKnownProfileIdentity() throws {
        if let profile = MultiRedAdapter.profile(gameID: gameID), profile.romSHA256 != sha256 {
            throw BoundROMUpdateError.incompatibleROM
        }
        if let profile = MultiRedAdapter.profile(romSHA256: sha256), profile.gameID != gameID {
            throw BoundROMUpdateError.incompatibleROM
        }
    }
    static func preservesPrevious(_ previous: Self?, incoming: Self) -> Bool {
        previous?.isHistoricalProfile == true && incoming.gameID == BoundGameProfiles.current.gameID &&
        incoming.sha256 == BoundGameProfiles.current.romSHA256
    }
    static func resetGameIDs(previous: Self?, incoming: Self) throws -> Set<String> {
        try previous?.validateKnownProfileIdentity(); try incoming.validateKnownProfileIdentity()
        guard let previous, previous != incoming else { return [] }
        if preservesPrevious(previous, incoming: incoming) { return [] }
        // A recognized original cannot be retired by an unrelated cartridge.
        guard !previous.isHistoricalProfile else { throw BoundROMUpdateError.incompatibleROM }
        return [previous.gameID, incoming.gameID]
    }
}

enum BoundROMUpdateError: LocalizedError {
    case invalidROM, incompatibleROM, unsafePath, changedBackup, storage, retired, staleSave, busy, olderROM, syncPending, multiplayerPending, clearingSaves, clearingROMs
    var errorDescription: String? {
        switch self {
        case .invalidROM: return "Choose a folder containing the complete multiplayer.gba file (or rrbin-integrated.gba)."
        case .incompatibleROM: return "This ROM needs a matching Bound update."
        case .unsafePath: return "The update contains an unsupported file path."
        case .changedBackup: return "Save files changed during backup. Close the game and retry."
        case .storage: return "The ROM update needs recovery. Your backup was kept."
        case .retired: return "This ROM was replaced by an automatic update."
        case .staleSave: return "This save belongs to an earlier ROM reset."
        case .busy: return "Close the game to finish the ROM update."
        case .olderROM: return "This ROM was already replaced. Keep the newer ROM in the folder."
        case .syncPending: return "Finish syncing this ROM's current saves before updating."
        case .multiplayerPending: return "Finish multiplayer recovery before updating."
        case .clearingSaves: return "This ROM has an unfinished cleanup. Open its cleanup controls to retry."
        case .clearingROMs: return "ROM cleanup is incomplete. Retry the confirmed installation in Account, Friends, & Sync."
        }
    }
}

/// Journal and backups live outside Harmony's database and save directories.
/// The journal is committed before mutation and kept until the database and files
/// agree. Replaying an interrupted reset only removes its original captured files.
final class BoundROMUpdateStorage {
    struct State: Codable, Equatable {
        var current: BoundROMUpdateContent?
        var retiredGameIDs: Set<String> = []
        var requiresGeneration = false
        // Omitted in ordinary/older receipts. A separately retained cartridge
        // must keep any reset fence it already had before current advances.
        var preservedGenerations: [String: String]?
        private enum CodingKeys: String, CodingKey { case current, retiredGameIDs, requiresGeneration, preservedGenerations }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(current, forKey: .current)
            try values.encode(retiredGameIDs, forKey: .retiredGameIDs)
            try values.encode(requiresGeneration, forKey: .requiresGeneration)
            if let preservedGenerations, !preservedGenerations.isEmpty {
                try values.encode(preservedGenerations, forKey: .preservedGenerations)
            }
        }
        func requiredGeneration(for gameID: String) -> String? {
            if current?.gameID == gameID, requiresGeneration { return current?.sha256 }
            return preservedGenerations?[gameID]
        }
    }
    struct Source: Codable, Equatable {
        let path: String // Documents/... or Support/..., relative to the current sandbox
        let remove: Bool
    }
    struct Entry: Codable, Equatable {
        let source: Source
        var files: [String: String] // relative name -> SHA256; empty name means a single file
        var directory: Bool
    }
    struct PreservedIncoming: Codable, Equatable {
        var battery = false
        var stateIDs: Set<String> = []
    }
    struct Transaction: Codable {
        let id: UUID
        let content: BoundROMUpdateContent
        let nextState: State
        let resetGameIDs: Set<String>
        let sources: [Source]
        let metadata: Data
        var preservedIncoming = PreservedIncoming()
        var entries: [Entry] = []
        var backupComplete = false
        var filesReset = false
    }
    struct SaveClear: Codable, Equatable {
        let id: UUID
        let gameID: String
        let gameName: String
        /// Captured before deletion so a retry cannot target a different account.
        let cloudContext: Data
    }
    let root: URL
    let documents: URL
    let support: URL
    private let fm = FileManager.default
    var stateURL: URL { root.appendingPathComponent("state.json") }
    var journalURL: URL { root.appendingPathComponent("pending.json") }
    private var saveClearsURL: URL { root.appendingPathComponent("Pending Save Clears", isDirectory: true) }
    private func saveClearURL(gameID: String) -> URL {
        saveClearsURL.appendingPathComponent(BoundROMUpdateContent.hash(Data(gameID.utf8)) + ".json")
    }
    private func completedSaveClearURL(gameID: String) -> URL {
        root.appendingPathComponent("Completed Save Clears", isDirectory: true)
            .appendingPathComponent(BoundROMUpdateContent.hash(Data(gameID.utf8)) + ".json")
    }
    /// Invalidates work captured before a clear, including callbacks arriving after completion.
    func saveClearRevision(gameID: String) throws -> UUID? {
        if let revision = try BoundROMServerInstaller.revision(gameID: gameID, storage: self) { return revision }
        if let cleanup = try BoundROMCleanupJournal(storage: self).revision(gameID) { return cleanup }
        if let pending = try pendingSaveClear(gameID: gameID) { return pending.id }
        let url = completedSaveClearURL(gameID: gameID)
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(UUID.self, from: Data(contentsOf: url))
    }
    func hasPendingSaveClear(gameID: String) -> Bool {
        fm.fileExists(atPath: saveClearURL(gameID: gameID).path) || BoundROMCleanupJournal(storage: self).blocks(gameID) ||
            BoundROMServerInstaller.blocks(gameID, storage: self)
    }
    func hasDeletionConflict(gameID: String) -> Bool {
        fm.fileExists(atPath: saveClearURL(gameID: gameID).path) || BoundROMCleanupJournal(storage: self).blocks(gameID) ||
            BoundROMServerInstallJournal(storage: self).blocksDeletion(gameID)
    }
    func pendingSaveClear(gameID: String) throws -> SaveClear? {
        guard fm.fileExists(atPath: saveClearURL(gameID: gameID).path) else { return nil }
        let value = try JSONDecoder().decode(SaveClear.self, from: Data(contentsOf: saveClearURL(gameID: gameID)))
        guard value.gameID == gameID else { throw BoundROMUpdateError.storage }
        return value
    }
    func pendingSaveClears() throws -> [SaveClear] {
        guard fm.fileExists(atPath: saveClearsURL.path) else { return [] }
        return try fm.contentsOfDirectory(at: saveClearsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                let value = try JSONDecoder().decode(SaveClear.self, from: Data(contentsOf: url))
                guard url == saveClearURL(gameID: value.gameID) else { throw BoundROMUpdateError.storage }
                return value
            }
    }
    func beginSaveClear(gameID: String, gameName: String, cloudContext: Data) throws -> SaveClear {
        if let pending = try pendingSaveClear(gameID: gameID) { return pending }
        let value = SaveClear(id: UUID(), gameID: gameID, gameName: gameName, cloudContext: cloudContext)
        try write(JSONEncoder().encode(value), to: saveClearURL(gameID: gameID))
        return value
    }
    func completeSaveClear(_ value: SaveClear) throws {
        guard try pendingSaveClear(gameID: value.gameID) == value else { throw BoundROMUpdateError.storage }
        let completed = completedSaveClearURL(gameID: value.gameID)
        try write(JSONEncoder().encode(value.id), to: completed)
        try fm.removeItem(at: saveClearURL(gameID: value.gameID))
        try synchronizeDirectory(saveClearsURL)
    }
    init(root: URL, documents: URL, support: URL) {
        self.root = root; self.documents = documents; self.support = support
    }
    static var live: BoundROMUpdateStorage {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return .init(root: support.appendingPathComponent("ROM Updates", isDirectory: true), documents: documents, support: support)
    }
    func cooperativeRecoveryFiles(gameID:String) throws -> [URL] {
        let folder=support.appendingPathComponent("Cooperative Battles",isDirectory:true)
        guard fm.fileExists(atPath:folder.path) else { return [] }
        var files:[URL]=[]
        for journal in try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) where journal.pathExtension=="json" {
            guard let bytes=try? Data(contentsOf:journal),bytes.count<=65536,
                  let entry=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],entry["gameID"] as? String==gameID else { continue }
            guard UUID(uuidString:journal.deletingPathExtension().lastPathComponent) != nil,
                  let name=entry["state"] as? String,name==URL(fileURLWithPath:name).lastPathComponent,
                  URL(fileURLWithPath:name).pathExtension=="state",
                  UUID(uuidString:URL(fileURLWithPath:name).deletingPathExtension().lastPathComponent) != nil else { throw BoundROMUpdateError.unsafePath }
            files += [journal,folder.appendingPathComponent(name)]
        }
        return files
    }
    /// Keep a verified local recovery copy; remove only explicitly selected paths.
    func clearSaveFiles(_ urls: [URL], cooperativeGameSaveURL:URL?=nil, commit: () throws -> Void) throws {
        let sources = try urls.map { try source(for: $0, remove: true) }
        let backup = root.appendingPathComponent("Cleared Saves/" + UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var copies: [(URL, URL)] = []
        for (index, source) in sources.enumerated() {
            let original = try resolve(source.path)
            guard fm.fileExists(atPath: original.path) else { continue }
            let copy = backup.appendingPathComponent(String(index))
            let before = try inventory(original)
            try fm.copyItem(at: original, to: copy)
            guard try inventory(copy) == before, try inventory(original) == before else { throw BoundROMUpdateError.changedBackup }
            copies.append((original, copy))
        }
        try JSONEncoder().encode(sources).write(to: backup.appendingPathComponent("sources.json"), options: .atomic)
        do {
            for (original, _) in copies { try fm.removeItem(at: original) }
            try commit()
        } catch {
            for (original, copy) in copies where !fm.fileExists(atPath: original.path) {
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: copy, to: original)
            }
            throw error
        }
        if let cooperativeGameSaveURL { _=BoundVBABattleBridge.setCooperativeGameSaveAllowed(true,for:cooperativeGameSaveURL) }
    }

    func state() throws -> State {
        guard fm.fileExists(atPath: stateURL.path) else { return .init() }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
    }
    func pending() throws -> Transaction? {
        guard fm.fileExists(atPath: journalURL.path) else { return nil }
        return try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: journalURL))
    }
    func effectiveState() throws -> State { try pending()?.nextState ?? state() }
    func backupDirectory(_ transaction: Transaction) -> URL {
        root.appendingPathComponent("Backups", isDirectory: true).appendingPathComponent(transaction.id.uuidString, isDirectory: true)
    }
    func incomingURL(_ transaction: Transaction) -> URL { backupDirectory(transaction).appendingPathComponent("incoming.gba") }
    func source(for url: URL, remove: Bool) throws -> Source {
        let path = url.standardizedFileURL.path
        for (prefix, base) in [("Documents", documents), ("Support", support)] {
            let basePath = base.standardizedFileURL.path + "/"
            if path.hasPrefix(basePath) {
                let value = Source(path: prefix + "/" + path.dropFirst(basePath.count), remove: remove)
                _ = try resolve(value.path)
                return value
            }
        }
        throw BoundROMUpdateError.unsafePath
    }
    func resolve(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              parts[0] == "Documents" || parts[0] == "Support" else { throw BoundROMUpdateError.unsafePath }
        var url = parts[0] == "Documents" ? documents : support
        for part in parts.dropFirst() {
            url.appendPathComponent(part)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw BoundROMUpdateError.unsafePath }
        }
        guard url.standardizedFileURL.path != root.standardizedFileURL.path,
              !url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw BoundROMUpdateError.unsafePath }
        return url
    }
    @discardableResult func begin(content: BoundROMUpdateContent, data: Data, sources: [Source], metadata: Data,
                                 resetGameIDs: Set<String>, enrollment: BoundROMUpdateContent? = nil, preservedIncoming: PreservedIncoming = .init()) throws -> Transaction {
        guard try pending() == nil, BoundROMUpdateContent.hash(data) == content.sha256 else { throw BoundROMUpdateError.storage }
        let previousStateBytes = fm.fileExists(atPath: stateURL.path) ? try Data(contentsOf: stateURL) : nil
        var previous = try previousStateBytes.map { try JSONDecoder().decode(State.self, from: $0) } ?? .init()
        if previous.current == nil { previous.current = enrollment }
        try previous.current?.validateKnownProfileIdentity(); try content.validateKnownProfileIdentity()
        guard !previous.retiredGameIDs.contains(content.gameID) else { throw BoundROMUpdateError.olderROM }
        if let old = previous.current, old.gameID == content.gameID, old.sha256 != content.sha256 { throw BoundROMUpdateError.invalidROM }
        let preservesPrevious = BoundROMUpdateContent.preservesPrevious(previous.current, incoming: content)
        if preservesPrevious {
            guard resetGameIDs.isEmpty, sources.allSatisfy({ !$0.remove }) else { throw BoundROMUpdateError.incompatibleROM }
        }
        var next = previous
        if preservesPrevious, previous.requiresGeneration, let old = previous.current {
            var generations = next.preservedGenerations ?? [:]
            generations[old.gameID] = old.sha256; next.preservedGenerations = generations
        }
        if let old = previous.current, old != content, !preservesPrevious { next.retiredGameIDs.insert(old.gameID) }
        next.retiredGameIDs.remove(content.gameID)
        next.current = content
        next.requiresGeneration = previous.current == content ? previous.requiresGeneration : !resetGameIDs.isEmpty
        let transaction = Transaction(id: UUID(), content: content, nextState: next, resetGameIDs: resetGameIDs,
            sources: sources, metadata: metadata, preservedIncoming: preservedIncoming)
        try validateOriginalPreservation(transaction)
        let folder = backupDirectory(transaction)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let previousStateBytes {
            try write(previousStateBytes, to: folder.appendingPathComponent("previous-updater-state.json"))
        }
        try write(data, to: incomingURL(transaction))
        try write(metadata, to: folder.appendingPathComponent("library-metadata.json"))
        try save(transaction)
        return transaction
    }
    func save(_ transaction: Transaction) throws { try write(JSONEncoder().encode(transaction), to: journalURL) }
    /// Older pending journals may already describe a destructive reset. Keep
    /// them and their backups for recovery instead of replaying that reset.
    private func validateOriginalPreservation(_ transaction: Transaction) throws {
        try transaction.content.validateKnownProfileIdentity()
        for profile in BoundGameProfiles.all where profile != BoundGameProfiles.current {
            guard !transaction.resetGameIDs.contains(profile.gameID) else { throw BoundROMUpdateError.incompatibleROM }
            if transaction.nextState.retiredGameIDs.contains(profile.gameID), !(try state()).retiredGameIDs.contains(profile.gameID) {
                throw BoundROMUpdateError.incompatibleROM
            }
        }
    }
    func makeBackup(_ transaction: inout Transaction) throws {
        try validateOriginalPreservation(transaction)
        if transaction.backupComplete { try verifyBackup(transaction); return }
        let folder = backupDirectory(transaction).appendingPathComponent("Originals", isDirectory: true)
        // No source has been removed yet. Rebuilding a partial copy is safe.
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries = [Entry]()
        for source in transaction.sources {
            let url = try resolve(source.path)
            guard fm.fileExists(atPath: url.path) else { continue }
            let destination = folder.appendingPathComponent(source.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let before = try inventory(url)
            try fm.copyItem(at: url, to: destination)
            try synchronizeTree(destination)
            let after = try inventory(url), copy = try inventory(destination)
            guard before == after, before == copy else { throw BoundROMUpdateError.changedBackup }
            entries.append(.init(source: source, files: before.files, directory: before.directory))
        }
        try synchronizeTree(folder)
        transaction.entries = entries; transaction.backupComplete = true
        try save(transaction)
        try write(JSONEncoder().encode(transaction), to: backupDirectory(transaction).appendingPathComponent("backup.json"))
    }
    func resetFiles(_ transaction: inout Transaction) throws {
        try validateOriginalPreservation(transaction)
        guard transaction.backupComplete else { throw BoundROMUpdateError.storage }
        try verifyBackup(transaction)
        if transaction.filesReset { return }
        for entry in transaction.entries where entry.source.remove {
            let source = try resolve(entry.source.path)
            guard fm.fileExists(atPath: source.path) else { continue }
            let current = try inventory(source)
            guard current.directory == entry.directory,
                  current.files.allSatisfy({ entry.files[$0.key] == $0.value }) else { throw BoundROMUpdateError.changedBackup }
            try fm.removeItem(at: source)
            try synchronizeDirectory(source.deletingLastPathComponent())
        }
        transaction.filesReset = true; try save(transaction)
    }
    func installROM(_ transaction: Transaction, destination: URL) throws {
        try validateOriginalPreservation(transaction)
        let source = incomingURL(transaction)
        let data = try Data(contentsOf: source)
        guard BoundROMUpdateContent.hash(data) == transaction.content.sha256 else { throw BoundROMUpdateError.storage }
        if fm.fileExists(atPath: destination.path), BoundROMUpdateContent.hash(try Data(contentsOf: destination)) == transaction.content.sha256 { return }
        try write(data, to: destination)
    }
    func complete(_ transaction: Transaction) throws {
        try validateOriginalPreservation(transaction)
        guard transaction.backupComplete, transaction.filesReset else { throw BoundROMUpdateError.storage }
        try write(JSONEncoder().encode(transaction.nextState), to: stateURL)
        try write(JSONEncoder().encode(transaction), to: backupDirectory(transaction).appendingPathComponent("completed.json"))
        try fm.removeItem(at: journalURL)
        try synchronizeDirectory(root)
    }
    /// A durable completed receipt makes a resurrected pending journal cleanup
    /// only. Never reset fresh gameplay merely because unlink was interrupted.
    func finishCompleted(_ transaction: Transaction) throws -> Bool {
        let url = backupDirectory(transaction).appendingPathComponent("completed.json")
        guard fm.fileExists(atPath: url.path) else { return false }
        let completed = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: url))
        guard completed.id == transaction.id, completed.content == transaction.content,
              completed.nextState == transaction.nextState, completed.backupComplete, completed.filesReset else { throw BoundROMUpdateError.storage }
        if fm.fileExists(atPath: journalURL.path) {
            try fm.removeItem(at: journalURL); try synchronizeDirectory(root)
        }
        return true
    }
    func verifyBackup(_ transaction: Transaction) throws {
        for entry in transaction.entries {
            let url = backupDirectory(transaction).appendingPathComponent("Originals").appendingPathComponent(entry.source.path)
            let saved = try inventory(url)
            guard saved.directory == entry.directory, saved.files == entry.files else { throw BoundROMUpdateError.storage }
        }
    }
    private struct Inventory: Equatable { var directory: Bool; var files: [String: String] }
    private func inventory(_ url: URL) throws -> Inventory {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw BoundROMUpdateError.unsafePath }
        if values.isRegularFile == true { return .init(directory: false, files: ["": BoundROMUpdateContent.hash(try Data(contentsOf: url))]) }
        guard values.isDirectory == true else { throw BoundROMUpdateError.unsafePath }
        var result = [String: String]()
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { throw BoundROMUpdateError.storage }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw BoundROMUpdateError.unsafePath }
            if values.isRegularFile == true {
                result[String(item.path.dropFirst(url.path.count + 1))] = BoundROMUpdateContent.hash(try Data(contentsOf: item))
            }
        }
        return .init(directory: true, files: result)
    }
    private func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.synchronize()
        var directory = url.deletingLastPathComponent()
        while directory.path.hasPrefix(documents.path + "/") || directory.path.hasPrefix(support.path + "/") {
            try synchronizeDirectory(directory)
            directory.deleteLastPathComponent()
        }
        if directory == documents || directory == support { try synchronizeDirectory(directory) }
    }
    private func synchronizeTree(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw BoundROMUpdateError.unsafePath }
        if values.isDirectory == true {
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try synchronizeTree(child) }
            try synchronizeDirectory(url)
        } else {
            let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.synchronize()
        }
    }
    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw BoundROMUpdateError.storage }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw BoundROMUpdateError.storage }
    }
}

enum BoundROMUpdateResetPolicy {
    struct Proof {
        let generation: String?
        let localNormal: Bool
        let remoteNormal: Bool
        let conflicted: Bool
        let locked: Bool
    }
    enum Decision: Equatable { case resetLocal, adopt, waitForSync }
    static func incoming(generation: String, objectCount: Int, proofs: [Proof]) -> Decision {
        guard objectCount == 1, proofs.count <= 1 else { return .waitForSync }
        guard let proof = proofs.first, proof.generation == generation else { return .resetLocal }
        guard proof.localNormal, proof.remoteNormal, !proof.conflicted, !proof.locked else { return .waitForSync }
        return .adopt
    }
    static func validateCanonicalBattery(_ data: Data?, expectedSHA1: String?, unresolvedImport: Bool,
                                         interruptedRestore: Bool, remoteRun: String?, canonicalRun: String?,
                                         canonicalROM: String?, generation: String) throws {
        guard !unresolvedImport, !interruptedRestore else { throw BoundROMUpdateError.multiplayerPending }
        if let remoteRun {
            guard canonicalRun?.lowercased() == remoteRun.lowercased(), canonicalROM == generation else { throw BoundROMUpdateError.multiplayerPending }
        } else if canonicalRun != nil { throw BoundROMUpdateError.multiplayerPending }
        do { try validateBatteryForUpload(data, expectedSHA1: expectedSHA1) }
        catch { throw BoundROMUpdateError.syncPending }
    }
    static func deletesGameSave(gameID: String, incomingID: String) -> Bool { gameID != incomingID }
    static func validateBatteryForUpload(_ data: Data?, expectedSHA1: String?) throws {
        guard let data, !data.isEmpty,
              Insecure.SHA1.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedSHA1 else { throw BoundROMUpdateError.staleSave }
    }
}

/// Read directly from atomic receipts because Harmony invokes model hooks from
/// background contexts, before a settings screen or manager need be instantiated.
enum BoundROMUpdateRegistry {
    static func generation(for gameID: String, storage: BoundROMUpdateStorage = .live) -> String? {
        guard let state = try? storage.effectiveState() else { return nil }
        return state.requiredGeneration(for: gameID)
    }
    static func validateDownload(gameID: String, generation: String?, isSave: Bool, storage: BoundROMUpdateStorage = .live, remoteLocked: Bool = false) throws {
        if BoundROMServerInstaller.blocks(gameID, storage: storage) { throw BoundROMUpdateError.clearingROMs }
        if BoundROMCleanupJournal(storage: storage).blocks(gameID) { throw BoundROMUpdateError.clearingROMs }
        if isSave, storage.hasPendingSaveClear(gameID: gameID) { throw BoundROMUpdateError.clearingSaves }
        if isSave, generation != nil, remoteLocked { throw BoundROMUpdateError.syncPending }
        let state = try storage.effectiveState()
        if state.retiredGameIDs.contains(gameID) { throw BoundROMUpdateError.retired }
        if isSave, let pending = try storage.pending(), pending.resetGameIDs.contains(gameID) { throw BoundROMUpdateError.staleSave }
        if isSave, let required = state.requiredGeneration(for: gameID), generation != required { throw BoundROMUpdateError.staleSave }
    }
    static func validateRestore(gameID: String, generation: String?, version: String, currentVersion: String?, isLocked: Bool, storage: BoundROMUpdateStorage = .live) throws {
        if storage.hasPendingSaveClear(gameID: gameID) { throw BoundROMUpdateError.clearingSaves }
        let state = try storage.effectiveState()
        if state.retiredGameIDs.contains(gameID) { throw BoundROMUpdateError.retired }
        guard let required = state.requiredGeneration(for: gameID) else { return }
        guard generation == required, version == currentVersion, !isLocked else { throw BoundROMUpdateError.staleSave }
        if let pending = try storage.pending(), pending.resetGameIDs.contains(gameID) { throw BoundROMUpdateError.syncPending }
    }
    static func validateUpload(gameID: String, storage: BoundROMUpdateStorage = .live) throws {
        if storage.hasPendingSaveClear(gameID: gameID) { throw BoundROMUpdateError.clearingSaves }
        if try storage.effectiveState().retiredGameIDs.contains(gameID) { throw BoundROMUpdateError.retired }
    }
}
