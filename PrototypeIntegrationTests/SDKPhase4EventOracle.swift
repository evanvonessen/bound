// Frozen event values and pure transitions from Bound 579b058b, before SDK extraction.
// Source SHA256: 4818f1242197aec5cccf88b9b91e16346da5ec28a3e64382ca6ac07a156cf5b8
// Do not regenerate from SDK implementations. Persistence remains covered by store tests.
import Foundation

/// A sequence belongs to its originating account, not to a checkpoint or a
/// connection. Keeping sparse receipts prevents event 12 from hiding event 11.
struct Phase4EventCursor: Codable, Equatable, Sendable {
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
    func contains(_ id: Phase4Event.ID) -> Bool { origins[id.origin.uuidString]?.contains(id.sequence) == true }
    func covers(_ other: Self) -> Bool {
        other.origins.allSatisfy { origin, target in
            let current = origins[origin] ?? Position()
            return current.contiguous >= target.contiguous && target.sparse.allSatisfy(current.contains)
        }
    }
    mutating func insert(_ id: Phase4Event.ID) {
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

struct Phase4Event: Codable, Equatable, Sendable, Identifiable {
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

struct Phase4EventAcknowledgement: Codable, Equatable, Sendable {
    var run: UUID
    var receiver: UUID
    var cursor: Phase4EventCursor
}

struct Phase4EventJournal: Codable, Equatable, Sendable {
    var version = 1
    var run: UUID
    var owner: UUID
    var partner: UUID
    var nextSequence: UInt64 = 1
    var events: [Phase4Event] = []
    var received = Phase4EventCursor()
    var acknowledged = Phase4EventCursor()
    var applied = Phase4EventCursor()
}


// Method bodies below are copied from the pre-extraction store. Only the IO/lock
// shell, argument/type names and inserted-result bookkeeping have been adapted.
enum Phase4EventOracle {
    enum Failure: Error, Equatable { case corrupt, conflict, ownerMismatch }
    struct Scope { let run: UUID; let owner: UUID; let partner: UUID }
    struct AppendResult { let event: Phase4Event; let inserted: Bool }
    static func validate(_ value: Phase4EventJournal, scope: Scope) throws {
        guard value.version == 1, value.run == scope.run, value.owner == scope.owner, value.partner == scope.partner,
              value.nextSequence > 0, value.nextSequence < UInt64.max, value.events.count <= 100_000,
              Set(value.events.map(\.id)).count == value.events.count else { throw Failure.corrupt }
        let participants = Set([scope.owner.uuidString, scope.partner.uuidString])
        for cursor in [value.received, value.acknowledged, value.applied] {
            guard Set(cursor.origins.keys).isSubset(of: participants), cursor.origins.values.allSatisfy(\.valid) else { throw Failure.corrupt }
        }
        var received = Phase4EventCursor()
        var keys = Set<String>()
        for event in value.events {
            try validateEvent(event, scope: scope)
            if event.id.origin == scope.owner {
                guard event.id.sequence < value.nextSequence else { throw Failure.corrupt }
                if let key = event.idempotencyKey, !keys.insert(key).inserted { throw Failure.corrupt }
            }
            received.insert(event.id)
        }
        let maximumLocal = value.events.filter { $0.id.origin == scope.owner }.map { $0.id.sequence }.max() ?? 0
        guard received == value.received, maximumLocal == value.nextSequence - 1 else { throw Failure.corrupt }
        for event in value.events where value.applied.contains(event.id) || value.acknowledged.contains(event.id) {
            guard value.received.contains(event.id) else { throw Failure.corrupt }
        }
        // Neither acknowledgement nor an apply marker may invent a missing ID.
        for cursor in [value.acknowledged, value.applied] {
            for (origin, position) in cursor.origins {
                let stored = received.origins[origin] ?? .init()
                guard position.contiguous <= stored.contiguous,
                      position.sparse.allSatisfy(stored.contains) else { throw Failure.corrupt }
            }
        }
    }
    private static func validateEvent(_ event: Phase4Event, scope: Scope) throws {
        guard event.run == scope.run, [scope.owner, scope.partner].contains(event.id.origin),
              event.id.sequence > 0, event.id.sequence < UInt64.max,
              !event.kind.isEmpty, event.kind.utf8.count <= 128, event.payload.count <= 65_536,
              event.idempotencyKey.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true else { throw Failure.corrupt }
    }

    static func append(kind: String, payload: Data, idempotencyKey: String?, to value: inout Phase4EventJournal) throws -> AppendResult {
        if let key = idempotencyKey, let prior = value.events.first(where: { $0.id.origin == value.owner && $0.idempotencyKey == key }) {
            guard prior.kind == kind, prior.payload == payload else { throw Failure.conflict }
            return .init(event: prior, inserted: false)
        }
        let event = Phase4Event(run: value.run, id: .init(origin: value.owner, sequence: value.nextSequence),
            kind: kind, payload: payload, idempotencyKey: idempotencyKey)
        guard value.nextSequence < UInt64.max - 1 else { throw Failure.corrupt }
        value.nextSequence += 1; value.events.append(event); value.received.insert(event.id)
        // Local effects were committed by the native ledger before this outbox
        // entry. Only incoming effects require replay.
        value.applied.insert(event.id)
        return .init(event: event, inserted: true)
    }
    static func receive(_ event: Phase4Event, authoritative: Bool, into value: inout Phase4EventJournal) throws -> Bool {
        guard event.id.origin == value.partner || authoritative && event.id.origin == value.owner else { throw Failure.ownerMismatch }
        if let prior = value.events.first(where: { $0.id == event.id }) {
            guard prior == event else { throw Failure.conflict }
            return false
        }
        if event.id.origin == value.owner {
            guard event.id.sequence < UInt64.max - 1 else { throw Failure.corrupt }
            value.nextSequence = max(value.nextSequence, event.id.sequence + 1)
        }
        value.events.append(event); value.received.insert(event.id)
        return true
    }
    static func pendingApplication(in value: Phase4EventJournal) -> [Phase4Event] {
        return value.events.filter { !value.applied.contains($0.id) }.sorted { lhs, rhs in
            lhs.id.origin == rhs.id.origin ? lhs.id.sequence < rhs.id.sequence : lhs.id.origin.uuidString < rhs.id.origin.uuidString
        }
    }
    static func markApplied(_ eventID: Phase4Event.ID, in value: inout Phase4EventJournal) throws {
        guard value.received.contains(eventID) else { throw Failure.conflict }
        value.applied.insert(eventID)
    }
    static func acknowledgement(for value: Phase4EventJournal) -> Phase4EventAcknowledgement {
        return .init(run: value.run, receiver: value.owner, cursor: value.received)
    }
    static func acknowledge(_ acknowledgement: Phase4EventAcknowledgement, in value: inout Phase4EventJournal) throws {
        guard acknowledgement.run == value.run, acknowledgement.receiver == value.partner else { throw Failure.ownerMismatch }
        // A peer can acknowledge only our origin. Its own receipt cursor may
        // contain events we have not received yet and cannot authorize pruning.
        let position = acknowledgement.cursor.origins[value.owner.uuidString] ?? .init()
        guard position.valid, position.contiguous < value.nextSequence,
              position.sparse.allSatisfy({ $0 < value.nextSequence }) else { throw Failure.conflict }
        value.acknowledged.merge(.init(origins: [value.owner.uuidString: position]))
    }
    static func eventsToSend(in value: Phase4EventJournal, peerCursor: Phase4EventCursor?, limit: Int, including: (Phase4Event) -> Bool) -> [Phase4Event] {
        let cursor = peerCursor ?? value.acknowledged
        return Array(value.events.filter { $0.id.origin == value.owner && !cursor.contains($0.id)
            && including($0) }
            .sorted { $0.id.sequence < $1.id.sequence }.prefix(max(0, min(limit, 256))))
    }
    static func mergeRetained(_ current: Phase4EventJournal, into result: inout Phase4EventJournal) throws {
        var known = Dictionary(uniqueKeysWithValues: current.events.map { ($0.id, $0) })
        for event in result.events {
            if let old = known[event.id], old != event { throw Failure.conflict }
            known[event.id] = event
        }
        result.events = known.values.sorted {
            $0.id.origin == $1.id.origin ? $0.id.sequence < $1.id.sequence : $0.id.origin.uuidString < $1.id.origin.uuidString
        }
        result.nextSequence = max(result.nextSequence, current.nextSequence)
        result.received.merge(current.received)
        result.applied.merge(current.applied)
        result.acknowledged.merge(current.acknowledged)
    }
}
