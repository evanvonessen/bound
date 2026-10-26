import Foundation

/// A sequence belongs to its originating account, not to a checkpoint or a
/// connection. Keeping sparse receipts prevents event 12 from hiding event 11.
struct BoundSDKEventCursor: Codable, Equatable, Sendable {
    struct Position: Codable, Equatable, Sendable {
        var contiguous: UInt64 = 0
        var sparse: Set<UInt64> = []
        func contains(_ sequence: UInt64) -> Bool { sequence > 0 && (sequence <= contiguous || sparse.contains(sequence)) }
        mutating func insert(_ sequence: UInt64) {
            guard sequence > contiguous else { return }
            sparse.insert(sequence)
            while contiguous < UInt64.max, sparse.remove(contiguous + 1) != nil { contiguous += 1 }
        }
        var valid: Bool { contiguous < UInt64.max && sparse.count <= 100_000 && sparse.allSatisfy { $0 > contiguous && $0 < UInt64.max } }
    }
    var origins: [String: Position] = [:]
    func contains(_ id: BoundSDKEvent.ID) -> Bool { origins[id.origin.uuidString]?.contains(id.sequence) == true }
    func covers(_ other: Self) -> Bool {
        other.origins.allSatisfy { origin, target in
            let current = origins[origin] ?? Position()
            return current.contiguous >= target.contiguous && target.sparse.allSatisfy(current.contains)
        }
    }
    mutating func insert(_ id: BoundSDKEvent.ID) {
        var position = origins[id.origin.uuidString] ?? Position()
        position.insert(id.sequence); origins[id.origin.uuidString] = position
    }
    mutating func merge(_ other: Self) {
        for (origin, received) in other.origins {
            var position = origins[origin] ?? Position()
            position.contiguous = max(position.contiguous, received.contiguous)
            position.sparse = position.sparse.filter { $0 > position.contiguous }
            for sequence in received.sparse { position.insert(sequence) }
            origins[origin] = position
        }
    }
}

struct BoundSDKEvent: Codable, Equatable, Sendable, Identifiable {
    struct ID: Codable, Equatable, Hashable, Sendable {
        var origin: UUID
        var sequence: UInt64
    }
    var run: UUID
    var id: ID
    var kind: String
    var payload: Data
    var idempotencyKey: String?
}

struct BoundSDKEventAcknowledgement: Codable, Equatable, Sendable {
    var run: UUID
    var receiver: UUID
    var cursor: BoundSDKEventCursor
}

struct BoundSDKEventJournal: Codable, Equatable, Sendable {
    var version = 1
    var run: UUID
    var owner: UUID
    var partner: UUID
    var nextSequence: UInt64 = 1
    var events: [BoundSDKEvent] = []
    var received = BoundSDKEventCursor()
    var acknowledged = BoundSDKEventCursor()
    var applied = BoundSDKEventCursor()
}
