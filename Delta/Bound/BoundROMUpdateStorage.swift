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
}

enum BoundROMUpdateError: LocalizedError {
    case invalidROM, incompatibleROM, unsafePath, changedBackup, storage, retired, staleSave, busy, olderROM, syncPending, multiplayerPending
    var errorDescription: String? {
        switch self {
        case .invalidROM: return "Choose a folder containing the complete rrbin-integrated.gba file."
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
    let root: URL
    let documents: URL
    let support: URL
    private let fm = FileManager.default
    var stateURL: URL { root.appendingPathComponent("state.json") }
    var journalURL: URL { root.appendingPathComponent("pending.json") }
    init(root: URL, documents: URL, support: URL) {
        self.root = root; self.documents = documents; self.support = support
    }
    static var live: BoundROMUpdateStorage {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return .init(root: support.appendingPathComponent("ROM Updates", isDirectory: true), documents: documents, support: support)
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
        var previous = try state()
        if previous.current == nil { previous.current = enrollment }
        guard !previous.retiredGameIDs.contains(content.gameID) else { throw BoundROMUpdateError.olderROM }
        if let old = previous.current, old.gameID == content.gameID, old.sha256 != content.sha256 { throw BoundROMUpdateError.invalidROM }
        var next = previous
        if let old = previous.current, old != content { next.retiredGameIDs.insert(old.gameID) }
        next.retiredGameIDs.remove(content.gameID)
        next.current = content
        next.requiresGeneration = previous.current == content ? previous.requiresGeneration : !resetGameIDs.isEmpty
        let transaction = Transaction(id: UUID(), content: content, nextState: next, resetGameIDs: resetGameIDs,
            sources: sources, metadata: metadata, preservedIncoming: preservedIncoming)
        let folder = backupDirectory(transaction)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write(data, to: incomingURL(transaction))
        try write(metadata, to: folder.appendingPathComponent("library-metadata.json"))
        try save(transaction)
        return transaction
    }
    func save(_ transaction: Transaction) throws { try write(JSONEncoder().encode(transaction), to: journalURL) }
    func makeBackup(_ transaction: inout Transaction) throws {
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
        let source = incomingURL(transaction)
        let data = try Data(contentsOf: source)
        guard BoundROMUpdateContent.hash(data) == transaction.content.sha256 else { throw BoundROMUpdateError.storage }
        if fm.fileExists(atPath: destination.path), BoundROMUpdateContent.hash(try Data(contentsOf: destination)) == transaction.content.sha256 { return }
        try write(data, to: destination)
    }
    func complete(_ transaction: Transaction) throws {
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
        guard let state = try? storage.effectiveState(), state.requiresGeneration,
              state.current?.gameID == gameID else { return nil }
        return state.current?.sha256
    }
    static func validateDownload(gameID: String, generation: String?, isSave: Bool, storage: BoundROMUpdateStorage = .live, remoteLocked: Bool = false) throws {
        if isSave, generation != nil, remoteLocked { throw BoundROMUpdateError.syncPending }
        let state = try storage.effectiveState()
        if state.retiredGameIDs.contains(gameID) { throw BoundROMUpdateError.retired }
        if isSave, let pending = try storage.pending(), pending.resetGameIDs.contains(gameID) { throw BoundROMUpdateError.staleSave }
        if isSave, state.requiresGeneration, state.current?.gameID == gameID, generation != state.current?.sha256 { throw BoundROMUpdateError.staleSave }
    }
    static func validateRestore(gameID: String, generation: String?, version: String, currentVersion: String?, isLocked: Bool, storage: BoundROMUpdateStorage = .live) throws {
        let state = try storage.effectiveState()
        if state.retiredGameIDs.contains(gameID) { throw BoundROMUpdateError.retired }
        guard state.requiresGeneration, state.current?.gameID == gameID else { return }
        guard generation == state.current?.sha256, version == currentVersion, !isLocked else { throw BoundROMUpdateError.staleSave }
        if let pending = try storage.pending(), pending.resetGameIDs.contains(gameID) { throw BoundROMUpdateError.syncPending }
    }
    static func validateUpload(gameID: String) throws {
        if try BoundROMUpdateStorage.live.effectiveState().retiredGameIDs.contains(gameID) { throw BoundROMUpdateError.retired }
    }
}
