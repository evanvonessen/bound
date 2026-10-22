import Foundation

/// A solo run owns its seed, rules and original battery save. Lobby membership
/// never supplies a partner or changes this identity.
struct BoundSoloRunRecord: Codable, Equatable, Sendable {
    let run: UUID
    let owner: UUID
    let gameID: String
    let romSHA256: String
    let seed: UInt32
    var settings: Data
    var ended: Bool
    let originalSaveSHA256: String?
    let version: Int
    var id: UUID { run }
}

@MainActor
final class BoundSoloRunStore {
    enum Failure: LocalizedError, Equatable {
        case corrupt, ownerMismatch, incompatible, settingsLocked, ended, missing
        var errorDescription: String? {
            switch self {
            case .corrupt: return "The solo Nuzlocke save needs recovery. Original files were kept."
            case .ownerMismatch: return "Sign in to the account that owns this Nuzlocke run."
            case .incompatible: return "This Nuzlocke run needs its original ROM."
            case .settingsLocked: return "This Nuzlocke run's settings are already saved."
            case .ended: return "This Nuzlocke run has ended."
            case .missing: return "No solo Nuzlocke run was found."
            }
        }
    }
    static let shared = BoundSoloRunStore()
    let root: URL
    private let fm = FileManager.default
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Solo Nuzlocke", isDirectory: true)
    }
    func directory(gameID: String) -> URL {
        root.appendingPathComponent(BoundMultiplayerSaveStore.hash(Data(gameID.utf8)), isDirectory: true)
    }
    private func validateGame(_ gameID: String) throws {
        guard !gameID.isEmpty, gameID.utf8.count <= 256 else { throw Failure.corrupt }
    }
    private func checkDirectory(_ url: URL, create: Bool = false) throws {
        if !fm.fileExists(atPath: url.path) {
            // fileExists follows dangling symlinks, so also inspect lstat-backed
            // attributes before creating a directory over an unexpected entry.
            if (try? fm.attributesOfItem(atPath: url.path)) != nil { throw Failure.corrupt }
            if create { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            else { return }
        }
        if fm.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.corrupt }
        }
    }
    private func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= maximum else { throw Failure.corrupt }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw Failure.corrupt }
        return data
    }
    private func write(_ data: Data, to url: URL) throws {
        if let attributes = try? fm.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType != .typeRegular { throw Failure.corrupt }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    private func persist(_ record: BoundSoloRunRecord) throws {
        try write(BoundMultiplayerSaveStore.encode(record), to: directory(gameID: record.gameID).appendingPathComponent("manifest.json"))
    }
    func load(gameID: String) throws -> BoundSoloRunRecord? {
        try validateGame(gameID); try checkDirectory(root)
        let folder = directory(gameID: gameID)
        try checkDirectory(folder)
        guard fm.fileExists(atPath: folder.path) else { return nil }
        let manifest = folder.appendingPathComponent("manifest.json")
        // A half-written begin is retained for recovery, never silently replaced.
        guard fm.fileExists(atPath: manifest.path),
              let record = try? JSONDecoder().decode(BoundSoloRunRecord.self, from: read(manifest, maximum: 16384)),
              record.version == 1, record.gameID == gameID, record.seed != 0,
              record.settings.isEmpty || BoundROMMultiplayerCoordinator.validSettings(record.settings) else { throw Failure.corrupt }
        guard record.romSHA256 == BoundWorldContract.romSHA256 else { throw Failure.incompatible }
        let original = folder.appendingPathComponent("original.sav")
        if let hash = record.originalSaveSHA256 {
            guard BoundMultiplayerSaveStore.isDigest(hash),
                  BoundMultiplayerSaveStore.hash(try read(original, maximum: 2 * 1024 * 1024)) == hash else { throw Failure.corrupt }
        } else if (try? fm.attributesOfItem(atPath: original.path)) != nil { throw Failure.corrupt }
        return record
    }
    func begin(gameID: String, owner: UUID, gameSaveURL: URL) throws -> BoundSoloRunRecord {
        try validateGame(gameID)
        if let existing = try load(gameID: gameID) {
            guard existing.owner == owner else { throw Failure.ownerMismatch }
            if !existing.ended { return existing }
            let archives = root.appendingPathComponent("Ended", isDirectory: true)
            try checkDirectory(archives, create: true)
            let destination = archives.appendingPathComponent(existing.run.uuidString, isDirectory: true)
            guard (try? fm.attributesOfItem(atPath: destination.path)) == nil else { throw Failure.corrupt }
            try fm.moveItem(at: directory(gameID: gameID), to: destination)
        }
        let original: Data?
        if (try? fm.attributesOfItem(atPath: gameSaveURL.path)) != nil { original = try read(gameSaveURL, maximum: 2 * 1024 * 1024) }
        else { original = nil }
        try checkDirectory(root, create: true)
        let folder = directory(gameID: gameID)
        guard (try? fm.attributesOfItem(atPath: folder.path)) == nil else { throw Failure.corrupt }
        try checkDirectory(folder, create: true)
        if let original { try write(original, to: folder.appendingPathComponent("original.sav")) }
        let record = BoundSoloRunRecord(run: UUID(), owner: owner, gameID: gameID, romSHA256: BoundWorldContract.romSHA256,
            seed: UInt32.random(in: 1...UInt32.max), settings: Data(), ended: false,
            originalSaveSHA256: original.map(BoundMultiplayerSaveStore.hash), version: 1)
        try persist(record)
        return record
    }
    func commit(gameID: String, owner: UUID, settings: Data) throws -> BoundSoloRunRecord {
        guard var record = try load(gameID: gameID) else { throw Failure.missing }
        guard record.owner == owner else { throw Failure.ownerMismatch }
        guard !record.ended else { throw Failure.ended }
        guard BoundROMMultiplayerCoordinator.validSettings(settings) else { throw Failure.corrupt }
        guard record.settings.isEmpty || record.settings == settings else { throw Failure.settingsLocked }
        if record.settings != settings { record.settings = settings; try persist(record) }
        return record
    }
    @discardableResult func end(gameID: String, owner: UUID) throws -> BoundSoloRunRecord {
        guard var record = try load(gameID: gameID) else { throw Failure.missing }
        guard record.owner == owner else { throw Failure.ownerMismatch }
        if !record.ended { record.ended = true; try persist(record) }
        return record
    }
}

/// Harmony may ask from its Core Data queue. A local solo run has no complete
/// cloud package yet: battery-only transfers must not bypass its death journal.
/// Missing/corrupt metadata inside an existing run folder remains protected.
enum BoundSoloSyncGuard {
    struct LocalOnly: LocalizedError {
        var errorDescription: String? { "Solo Nuzlocke saves stay on this device. Cloud transfer is unavailable for this run." }
    }
    static func protects(gameID: String, root: URL? = nil) -> Bool {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Solo Nuzlocke", isDirectory: true)
        let directory = base.appendingPathComponent(BoundMultiplayerSaveStore.hash(Data(gameID.utf8)), isDirectory: true)
        guard (try? FileManager.default.attributesOfItem(atPath: directory.path)) != nil else { return false }
        guard let directoryValues = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { return true }
        let url = directory.appendingPathComponent("manifest.json")
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 16384,
              let data = try? Data(contentsOf: url), data.count <= 16384,
              let record = try? JSONDecoder().decode(BoundSoloRunRecord.self, from: data),
              record.gameID == gameID, record.version == 1 else { return true }
        return !record.ended
    }
    static func requireCloudAllowed(gameID: String) throws {
        guard !protects(gameID: gameID) else { throw LocalOnly() }
    }
}
