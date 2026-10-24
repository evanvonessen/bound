import Foundation
import CryptoKit

/// A cartridge reset is different from a coordinator-authorized state restore.
/// UInt32 wraparound is ordinary forward progress, not a reset.
struct BoundROMFrameClock {
    private var previous: UInt32?
    mutating func reset() { previous = nil }
    mutating func observe(_ frame: UInt32) -> Bool {
        defer { previous = frame }
        guard let previous else { return false }
        return Int32(bitPattern: frame &- previous) < 0
    }
}

struct BoundROMRequestCursor {
    enum Action { case ignore, rebase, dispatch }
    var lastHandled: UInt32 = 0
    private var awaitingRestoredSample = false
    mutating func didRestore() { awaitingRestoredSample = true }
    mutating func admit(_ id: UInt32) -> Action {
        if awaitingRestoredSample {
            awaitingRestoredSample = false; lastHandled = id
            return .rebase
        }
        guard id != 0, id != lastHandled else { return .ignore }
        lastHandled = id
        return .dispatch
    }
}

/// Preserve the last acknowledged history and an in-flight monotonic update
/// independently of RAM snapshots. An uncertain server reply can then be
/// reconciled after reopening without accepting an older save as new history.
final class BoundROMHistoryJournal {
    enum Failure: LocalizedError {
        case conflict
        var errorDescription: String? { "Saved run history conflicts with recovery. Original saves were kept." }
    }
    private struct Record: Codable, Equatable {
        var version = 1
        var run: UUID
        var owner: UUID
        var device: UUID
        var acknowledged: Data?
        var pending: Data?
    }
    private let url: URL
    private var record: Record
    private var exists: Bool
    static let historyBytes = 288 * 3
    init(url: URL, run: UUID, owner: UUID, device: UUID) throws {
        self.url = url
        exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 16_384 else { throw Failure.conflict }
            record = try JSONDecoder().decode(Record.self, from: bytes)
            guard record.version == 1, record.run == run, record.owner == owner, record.device == device,
                  record.acknowledged.map(Self.valid) ?? true,
                  record.pending.map(Self.valid) ?? true,
                  Self.extends(record.pending ?? record.acknowledged, record.acknowledged) else { throw Failure.conflict }
        } else { record = Record(run: run, owner: owner, device: device) }
    }
    static func digest(_ bits: Data) -> String {
        SHA256.hash(data: bits).map { String(format: "%02x", $0) }.joined()
    }
    private static func valid(_ bits: Data) -> Bool { bits.count == historyBytes }
    private static func extends(_ newer: Data?, _ older: Data?) -> Bool {
        guard let older else { return true }
        guard let newer, valid(newer), valid(older) else { return false }
        return zip(newer, older).allSatisfy { ($0 & $1) == $1 }
    }
    /// Legacy runs may bootstrap from an exact current or completed-checkpoint
    /// digest. Unrelated server history and lost local deaths remain conflicts.
    func reconcile(server: String?, current: Data, completed: [Data] = [], allowUnanchored: Bool = false) throws {
        guard Self.valid(current), Self.extends(current, record.acknowledged),
              Self.extends(current, record.pending) else { throw Failure.conflict }
        var next = record
        if let server {
            let candidates = [record.acknowledged, record.pending, current].compactMap { $0 }
                + (exists ? [] : completed.filter(Self.valid))
            guard let known = candidates.first(where: { Self.digest($0) == server }),
                  Self.extends(current, known) else { throw Failure.conflict }
            // A previously acknowledged server anchor cannot move backwards.
            guard Self.extends(known, record.acknowledged) else { throw Failure.conflict }
            next.acknowledged = known
            if next.pending.map(Self.digest) == server { next.pending = nil }
        } else {
            guard record.acknowledged == nil, exists || allowUnanchored else { throw Failure.conflict }
        }
        try persist(next)
    }
    /// Must finish durably before starting the server mutation.
    func prepare(_ current: Data) throws {
        guard exists, Self.valid(current), Self.extends(current, record.acknowledged),
              Self.extends(current, record.pending) else { throw Failure.conflict }
        var next = record
        next.pending = current == record.acknowledged ? nil : current
        try persist(next)
    }
    private func persist(_ next: Record) throws {
        guard !exists || next != record else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(next).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        record = next; exists = true
    }
}
