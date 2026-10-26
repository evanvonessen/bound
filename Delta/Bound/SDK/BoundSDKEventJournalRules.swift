import Foundation

/// Pure event transitions. The host owns authentication, native application and
/// the persistence transaction; changing a value here does not establish durability.
enum BoundSDKEventJournalRules {
    enum Failure: Error, Equatable { case corrupt, conflict, ownerMismatch }
    struct Scope {
        let run: UUID
        let owner: UUID
        let partner: UUID
    }
    struct AppendResult {
        let event: BoundSDKEvent
        let inserted: Bool
    }

    static func validate(_ value: BoundSDKEventJournal, scope: Scope) throws {
        guard value.version == 1, value.run == scope.run, value.owner == scope.owner, value.partner == scope.partner,
              value.nextSequence > 0, value.nextSequence < UInt64.max, value.events.count <= 100_000,
              Set(value.events.map(\.id)).count == value.events.count else { throw Failure.corrupt }
        let participants = Set([scope.owner.uuidString, scope.partner.uuidString])
        for cursor in [value.received, value.acknowledged, value.applied] {
            guard Set(cursor.origins.keys).isSubset(of: participants), cursor.origins.values.allSatisfy(\.valid) else { throw Failure.corrupt }
        }
        var received = BoundSDKEventCursor()
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
        for cursor in [value.acknowledged, value.applied] {
            for (origin, position) in cursor.origins {
                let stored = received.origins[origin] ?? .init()
                guard position.contiguous <= stored.contiguous,
                      position.sparse.allSatisfy(stored.contains) else { throw Failure.corrupt }
            }
        }
    }

    private static func validateEvent(_ event: BoundSDKEvent, scope: Scope) throws {
        guard event.run == scope.run, [scope.owner, scope.partner].contains(event.id.origin),
              event.id.sequence > 0, event.id.sequence < UInt64.max,
              !event.kind.isEmpty, event.kind.utf8.count <= 128, event.payload.count <= 65_536,
              event.idempotencyKey.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true else { throw Failure.corrupt }
    }

    /// The caller has already applied its local effect. Identical retries must
    /// return without allocating a sequence or requiring another persistence write.
    static func append(kind: String, payload: Data, idempotencyKey: String?,
                       to value: inout BoundSDKEventJournal) throws -> AppendResult {
        if let key = idempotencyKey, let prior = value.events.first(where: { $0.id.origin == value.owner && $0.idempotencyKey == key }) {
            guard prior.kind == kind, prior.payload == payload else { throw Failure.conflict }
            return .init(event: prior, inserted: false)
        }
        let event = BoundSDKEvent(run: value.run, id: .init(origin: value.owner, sequence: value.nextSequence),
            kind: kind, payload: payload, idempotencyKey: idempotencyKey)
        guard value.nextSequence < UInt64.max - 1 else { throw Failure.corrupt }
        value.nextSequence += 1; value.events.append(event); value.received.insert(event.id)
        value.applied.insert(event.id)
        return .init(event: event, inserted: true)
    }

    /// Own-origin history requires the host's authenticated server path.
    /// Accepted history remains pending native application.
    static func receive(_ event: BoundSDKEvent, authoritative: Bool,
                        into value: inout BoundSDKEventJournal) throws -> Bool {
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

    static func pendingApplication(in value: BoundSDKEventJournal) -> [BoundSDKEvent] {
        value.events.filter { !value.applied.contains($0.id) }.sorted { lhs, rhs in
            lhs.id.origin == rhs.id.origin ? lhs.id.sequence < rhs.id.sequence : lhs.id.origin.uuidString < rhs.id.origin.uuidString
        }
    }

    static func markApplied(_ eventID: BoundSDKEvent.ID, in value: inout BoundSDKEventJournal) throws {
        guard value.received.contains(eventID) else { throw Failure.conflict }
        value.applied.insert(eventID)
    }

    static func acknowledgement(for value: BoundSDKEventJournal) -> BoundSDKEventAcknowledgement {
        .init(run: value.run, receiver: value.owner, cursor: value.received)
    }

    static func acknowledge(_ acknowledgement: BoundSDKEventAcknowledgement,
                            in value: inout BoundSDKEventJournal) throws {
        guard acknowledgement.run == value.run, acknowledgement.receiver == value.partner else { throw Failure.ownerMismatch }
        // Only our origin can be acknowledged by this peer. Its own cursor
        // cannot authorize pruning events we have not received.
        let position = acknowledgement.cursor.origins[value.owner.uuidString] ?? .init()
        guard position.valid, position.contiguous < value.nextSequence,
              position.sparse.allSatisfy({ $0 < value.nextSequence }) else { throw Failure.conflict }
        value.acknowledged.merge(.init(origins: [value.owner.uuidString: position]))
    }

    static func eventsToSend(in value: BoundSDKEventJournal, peerCursor: BoundSDKEventCursor?, limit: Int,
                             including: (BoundSDKEvent) -> Bool) -> [BoundSDKEvent] {
        let cursor = peerCursor ?? value.acknowledged
        return Array(value.events.filter { $0.id.origin == value.owner && !cursor.contains($0.id) && including($0) }
            .sorted { $0.id.sequence < $1.id.sequence }.prefix(max(0, min(limit, 256))))
    }

    /// The host validates both journals before merging and validates the result
    /// before committing it. Checkpoint rollback must retain newer event history.
    static func mergeRetained(_ current: BoundSDKEventJournal, into result: inout BoundSDKEventJournal) throws {
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
