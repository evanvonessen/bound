import Foundation
import CryptoKit
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Out-of-order status reads cannot replace a newer read or a committed provider change.
struct BoundServerBackupStatusGate {
    private var request = UUID()
    private(set) var isChanging = false
    mutating func beginRead() -> UUID? {
        guard !isChanging else { return nil }
        request = UUID(); return request
    }
    func accepts(_ token: UUID) -> Bool { !isChanging && token == request }
    mutating func beginChange() -> Bool {
        guard !isChanging else { return false }
        isChanging = true; request = UUID(); return true
    }
    mutating func endChange() { request = UUID(); isChanging = false }
}

/// Only save payloads are permitted. ROMs and account credentials never enter an archive.
struct BoundServerBackupPackage: Sendable {
    static let maximumBytes = 64 * 1024 * 1024
    // Includes JSON escaping for all 128 states' bounded display/core metadata.
    static let maximumManifestBytes = 2 * 1024 * 1024
    static let maximumStates = 128
    struct State: Codable, Equatable, Sendable {
        var identifier: String
        var filename: String
        var name: String?
        var type: Int16
        var coreIdentifier: String
        var coreVersion: String
        var createdAt: Date
        var modifiedAt: Date
    }
    struct Blob: Codable, Equatable, Sendable {
        var size: Int
        var sha256: String
        init(_ data: Data) { size = data.count; sha256 = BoundServerBackupPackage.hash(data) }
    }
    struct Manifest: Codable, Equatable, Sendable {
        var version = 1
        var owner: UUID
        var gameID: String
        var name: String
        var gameType: String
        var romSHA256: String
        var generation: String?
        var soulLink: Bool
        var states: [State]
        var files: [String: Blob]
    }
    enum Failure: LocalizedError {
        case invalid, tooLarge, incompatible, missingGame, openGame, recovery, conflict, unavailable, unapproved, accountChanged
        var errorDescription: String? {
            switch self {
            case .invalid: return "This server backup is damaged. Your local saves were kept."
            case .tooLarge: return "This game's backup exceeds the 64 MB limit."
            case .incompatible: return "Import the matching game version before restoring this backup."
            case .missingGame: return "Import this game before restoring its backup."
            case .openGame: return "Close the game before backing up or restoring its saves."
            case .recovery: return "Finish multiplayer recovery before restoring this game's saves."
            case .conflict: return "A newer server backup exists. Restore it before uploading from this device."
            case .unavailable: return "Server backups are unavailable. Try again later."
            case .unapproved: return "Server backups require account approval."
            case .accountChanged: return "The signed-in account or backup provider changed. Try again."
            }
        }
    }
    var manifest: Manifest
    var files: [String: Data]

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value != "." && value != ".." &&
            value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95].contains($0) }
    }
    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func validate(owner: UUID, gameID: String) throws {
        let value = manifest
        guard value.version == 1, value.owner == owner, value.gameID == gameID,
              Self.safeComponent(gameID), !value.name.isEmpty, value.name.utf8.count <= 1024,
              !value.gameType.isEmpty, value.gameType.utf8.count <= 256, Self.digest(value.romSHA256),
              value.generation.map({ $0.utf8.count <= 128 }) ?? true,
              value.states.count <= Self.maximumStates,
              Set(value.states.map(\.identifier)).count == value.states.count,
              Set(value.states.map(\.filename)).count == value.states.count else { throw Failure.invalid }
        var allowed: Set<String> = ["game.sav", "game.rtc"]
        if value.soulLink {
            guard value.states.isEmpty, files["game.sav"] != nil, files["complete.boundrun"] != nil else { throw Failure.invalid }
            allowed = ["game.sav", "complete.boundrun"]
        }
        for state in value.states {
            guard Self.safeComponent(state.identifier), Self.safeComponent(state.filename), (0...3).contains(state.type),
                  !state.coreIdentifier.isEmpty, state.coreIdentifier.utf8.count <= 256,
                  !state.coreVersion.isEmpty, state.coreVersion.utf8.count <= 128,
                  state.name.map({ $0.utf8.count <= 1024 }) ?? true,
                  state.createdAt.timeIntervalSince1970.isFinite, state.modifiedAt.timeIntervalSince1970.isFinite,
                  files["states/" + state.identifier + ".state"] != nil else { throw Failure.invalid }
            allowed.insert("states/" + state.identifier + ".state")
            allowed.insert("states/" + state.identifier + ".png")
        }
        guard !files.isEmpty, Set(files.keys) == Set(value.files.keys), Set(files.keys).isSubset(of: allowed) else { throw Failure.invalid }
        var total = 0
        for (path, data) in files {
            guard let blob = value.files[path], blob.size == data.count, blob.sha256 == Self.hash(data), !data.isEmpty else { throw Failure.invalid }
            guard data.count <= Self.maximumBytes - total else { throw Failure.tooLarge }
            total += data.count
        }
    }
    func manifestData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= Self.maximumManifestBytes else { throw Failure.tooLarge }
        return data
    }
}

#if canImport(ZIPFoundation)
extension BoundServerBackupPackage {
    func zip() throws -> Data {
        try validate(owner: manifest.owner, gameID: manifest.gameID)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        var entries = files; entries["manifest.json"] = try manifestData()
        for path in entries.keys.sorted() {
            let data = entries[path]!
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 modificationDate: Date(timeIntervalSince1970: 315532800), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
            }
        }
        let result = try Data(contentsOf: url)
        guard result.count <= Self.maximumBytes else { throw Failure.tooLarge }
        return result
    }
    static func unzip(_ data: Data, owner: UUID, gameID: String) throws -> Self {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        let archive = try Archive(url: url, accessMode: .read)
        var files: [String: Data] = [:]
        var total = 0
        // The payload limit excludes metadata, just as validate() does when exporting.
        let maximumExpandedBytes = maximumBytes + maximumManifestBytes
        for entry in archive {
            guard entry.type == .file, files[entry.path] == nil, files.count < maximumStates * 2 + 4,
                  entry.uncompressedSize <= UInt64(maximumExpandedBytes - total),
                  entry.path != "manifest.json" || entry.uncompressedSize <= UInt64(maximumManifestBytes),
                  entry.path == "manifest.json" || entry.path == "game.sav" || entry.path == "game.rtc" || entry.path == "complete.boundrun" ||
                    (entry.path.hasPrefix("states/") && entry.path.split(separator: "/").count == 2 &&
                     ["state", "png"].contains((entry.path as NSString).pathExtension)) else { throw Failure.invalid }
            var bytes = Data()
            let checksum = try archive.extract(entry) { chunk in
                guard chunk.count <= maximumExpandedBytes - total else { throw Failure.tooLarge }
                if entry.path == "manifest.json", bytes.count + chunk.count > maximumManifestBytes { throw Failure.invalid }
                bytes.append(chunk); total += chunk.count
            }
            guard checksum == entry.checksum, bytes.count == Int(entry.uncompressedSize) else { throw Failure.invalid }
            files[entry.path] = bytes
        }
        guard let manifestBytes = files.removeValue(forKey: "manifest.json") else { throw Failure.invalid }
        let result = Self(manifest: try JSONDecoder().decode(Manifest.self, from: manifestBytes), files: files)
        try result.validate(owner: owner, gameID: gameID)
        return result
    }
}
#endif
