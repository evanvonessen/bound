import Foundation
import DeltaCore

/// Existing ledger/recovery formats remain unchanged. Marked games keep their
/// working copies exclusively in RAM; the shared-run checkpoint owns durability.
/// Each game's portable paths are isolated so another run cannot read its data.
enum BoundServerMemoryFiles {
    private final class Storage: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var enabled: Set<String> = []
        var files: [String: [String: Data]] = [:]
        var dates: [String: [String: Date]] = [:]
    }
    private static let storage = Storage()
    private static let maximumBytes = 16 * 1024 * 1024
    private static let folders: Set<String> = ["Soul Link", "Friend Battles", "Cooperative Battles"]

    static func setEnabled(_ enabled: Bool, for gameID: String) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        if enabled { storage.enabled.insert(gameID) } else { storage.enabled.remove(gameID) }
    }
    static func isEnabled(for gameID: String) -> Bool {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.enabled.contains(gameID)
    }
    private static func valid(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.count <= 4 && folders.contains(String(parts[0]))
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }
            && path.utf8.count <= 512
    }
    private static func key(_ url: URL) throws -> String {
        let parts = url.standardizedFileURL.pathComponents
        guard let index = parts.lastIndex(where: { folders.contains($0) }) else { throw CocoaError(.fileWriteInvalidFileName) }
        let value = parts[index...].joined(separator: "/")
        guard valid(value) else { throw CocoaError(.fileWriteInvalidFileName) }
        return value
    }
    static func snapshot(gameID: String) -> [String: Data] {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.files[gameID] ?? [:]
    }
    /// Confirmed ROM deletion also releases its working RAM copies. Retain the
    /// server-only storage policy so stale callers cannot fall back to disk.
    static func discard(gameID: String) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.files.removeValue(forKey: gameID)
        storage.dates.removeValue(forKey: gameID)
    }
    static func restore(_ files: [String: Data], gameID: String) throws {
        guard files.count <= 256, files.keys.allSatisfy(valid),
              files.values.reduce(0, { $0 + $1.count }) <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        storage.lock.lock(); defer { storage.lock.unlock() }
        guard storage.enabled.contains(gameID) else { throw CocoaError(.fileWriteNoPermission) }
        storage.files[gameID] = files
        storage.dates[gameID] = files.mapValues { _ in Date() }
    }
    static func read(_ url: URL, gameID: String) throws -> Data {
        storage.lock.lock(); defer { storage.lock.unlock() }
        guard storage.enabled.contains(gameID) else { return try Data(contentsOf: url) }
        guard let data = storage.files[gameID]?[try key(url)] else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }
    static func write(_ data: Data, to url: URL, gameID: String) throws {
        storage.lock.lock(); defer { storage.lock.unlock() }
        guard storage.enabled.contains(gameID) else {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); return
        }
        let path = try key(url)
        var files = storage.files[gameID] ?? [:]
        files[path] = data
        guard files.count <= 256, files.values.reduce(0, { $0 + $1.count }) <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        storage.files[gameID] = files; storage.dates[gameID, default: [:]][path] = Date()
    }
    static func exists(_ url: URL, gameID: String) -> Bool {
        storage.lock.lock(); defer { storage.lock.unlock() }
        guard storage.enabled.contains(gameID) else { return FileManager.default.fileExists(atPath: url.path) }
        guard let path = try? key(url) else { return false }
        return storage.files[gameID]?[path] != nil
    }
    static func remove(_ url: URL, gameID: String) throws {
        storage.lock.lock(); defer { storage.lock.unlock() }
        guard storage.enabled.contains(gameID) else { try FileManager.default.removeItem(at: url); return }
        let path = try key(url)
        storage.files[gameID]?.removeValue(forKey: path); storage.dates[gameID]?.removeValue(forKey: path)
    }
    static func move(_ source: URL, to destination: URL, gameID: String) throws {
        storage.lock.lock(); defer { storage.lock.unlock() }
        guard storage.enabled.contains(gameID) else { try FileManager.default.moveItem(at: source, to: destination); return }
        try write(read(source, gameID: gameID), to: destination, gameID: gameID)
        try remove(source, gameID: gameID)
    }
    static func directory(_ url: URL, gameID: String) throws {
        guard !isEnabled(for: gameID) else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func contents(_ url: URL, gameID: String) throws -> [URL] {
        storage.lock.lock(); defer { storage.lock.unlock() }
        guard storage.enabled.contains(gameID) else {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])
        }
        let prefix = url.lastPathComponent + "/"
        guard folders.contains(url.lastPathComponent) else { throw CocoaError(.fileReadInvalidFileName) }
        return (storage.files[gameID] ?? [:]).keys.compactMap { path in
            guard path.hasPrefix(prefix) else { return nil }
            let name = String(path.dropFirst(prefix.count))
            guard !name.contains("/") else { return nil }
            return url.appendingPathComponent(name)
        }
    }
    static func modifiedAt(_ url: URL, gameID: String) -> Date {
        storage.lock.lock(); defer { storage.lock.unlock() }
        guard storage.enabled.contains(gameID) else {
            return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        guard let path = try? key(url) else { return .distantPast }
        return storage.dates[gameID]?[path] ?? .distantPast
    }
    /// Call with the paused core or from its completed-frame callback.
    static func saveState(core: EmulatorCore, to url: URL, gameID: String) throws {
        guard isEnabled(for: gameID) else { core.saveSaveState(to: url); return }
        let data = MultiRedAdapter.captureState()
        guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try write(data, to: url, gameID: gameID)
    }
    static func loadState(core: EmulatorCore, from url: URL, gameID: String) throws {
        guard isEnabled(for: gameID) else {
            try core.load(DeltaCore.SaveState(fileURL: url, gameType: core.game.type)); return
        }
        guard core.state == .paused, MultiRedAdapter.restoreState(try read(url, gameID: gameID)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    static func battery(core: EmulatorCore, gameID: String) throws -> Data {
        guard isEnabled(for: gameID) else { return try Data(contentsOf: core.game.gameSaveURL) }
        let data = BoundVBABattleBridge.captureServerBattery()
        guard data.count == 131072 else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}
