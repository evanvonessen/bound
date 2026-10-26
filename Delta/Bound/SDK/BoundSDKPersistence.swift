import Foundation

/// The host remains responsible for ownership, locking, validation and storage.
/// Receipt, native application and verified server durability remain distinct.
protocol BoundSDKEventPersistenceStore: AnyObject {
    associatedtype RunIdentity

    func journal(gameID: String, identity: RunIdentity?) throws -> BoundSDKEventJournal
    func appendSharedEvent(gameID: String, kind: String, payload: Data, idempotencyKey: String?) throws -> BoundSDKEvent
    func receiveAuthoritativeSharedEvent(gameID: String, event: BoundSDKEvent, identity: RunIdentity?) throws -> Bool
    func pendingSharedEventsToApply(gameID: String, identity: RunIdentity?) throws -> [BoundSDKEvent]
    func markSharedEventApplied(gameID: String, eventID: BoundSDKEvent.ID, identity: RunIdentity?) throws
    func sharedEventAcknowledgement(gameID: String, identity: RunIdentity?) throws -> BoundSDKEventAcknowledgement
    func acknowledgeSharedEvents(gameID: String, acknowledgement: BoundSDKEventAcknowledgement, identity: RunIdentity?) throws
    func eventsToSend(gameID: String, peerCursor: BoundSDKEventCursor?, limit: Int,
                      identity: RunIdentity?, excludingCheckpointDependentEvents: Bool) throws -> [BoundSDKEvent]
    func pendingSharedRunIdentities(gameID: String) throws -> [RunIdentity]
}

/// A narrow view of the existing store. It adds no journal, cache or persistence.
struct BoundSDKEventPersistence<Store: BoundSDKEventPersistenceStore> {
    private let store: Store

    init(store: Store) { self.store = store }

    func journal(gameID: String, identity: Store.RunIdentity? = nil) throws -> BoundSDKEventJournal {
        try store.journal(gameID: gameID, identity: identity)
    }

    @discardableResult
    func appendSharedEvent(gameID: String, kind: String, payload: Data,
                           idempotencyKey: String? = nil) throws -> BoundSDKEvent {
        try store.appendSharedEvent(gameID: gameID, kind: kind, payload: payload, idempotencyKey: idempotencyKey)
    }

    /// The caller must supply authenticated authoritative history, as before.
    @discardableResult
    func receiveAuthoritativeSharedEvent(gameID: String, event: BoundSDKEvent,
                                         identity: Store.RunIdentity? = nil) throws -> Bool {
        try store.receiveAuthoritativeSharedEvent(gameID: gameID, event: event, identity: identity)
    }

    func pendingSharedEventsToApply(gameID: String, identity: Store.RunIdentity? = nil) throws -> [BoundSDKEvent] {
        try store.pendingSharedEventsToApply(gameID: gameID, identity: identity)
    }

    func markSharedEventApplied(gameID: String, eventID: BoundSDKEvent.ID,
                                identity: Store.RunIdentity? = nil) throws {
        try store.markSharedEventApplied(gameID: gameID, eventID: eventID, identity: identity)
    }

    func sharedEventAcknowledgement(gameID: String,
                                     identity: Store.RunIdentity? = nil) throws -> BoundSDKEventAcknowledgement {
        try store.sharedEventAcknowledgement(gameID: gameID, identity: identity)
    }

    func acknowledgeSharedEvents(gameID: String, acknowledgement: BoundSDKEventAcknowledgement,
                                  identity: Store.RunIdentity? = nil) throws {
        try store.acknowledgeSharedEvents(gameID: gameID, acknowledgement: acknowledgement, identity: identity)
    }

    func eventsToSend(gameID: String, peerCursor: BoundSDKEventCursor? = nil, limit: Int = 64,
                      identity: Store.RunIdentity? = nil,
                      excludingCheckpointDependentEvents: Bool = false) throws -> [BoundSDKEvent] {
        try store.eventsToSend(gameID: gameID, peerCursor: peerCursor, limit: limit, identity: identity,
                               excludingCheckpointDependentEvents: excludingCheckpointDependentEvents)
    }

    func pendingSharedRunIdentities(gameID: String) throws -> [Store.RunIdentity] {
        try store.pendingSharedRunIdentities(gameID: gameID)
    }
}

extension BoundSDKEventPersistence: Sendable where Store: Sendable {}

/// Managed checkpoint operations do not imply a disk write or server publication.
/// Identity, package format and native compatibility remain opaque host values.
protocol BoundSDKManagedCheckpointPersistenceStore: AnyObject {
    associatedtype RunIdentity
    associatedtype CheckpointPackage
    associatedtype RunManifest

    func useServerStorage(gameID: String)
    func beginServerSession(identity: RunIdentity, package: CheckpointPackage?, target: BoundSDKEventCursor) throws
    func captureServerCheckpoint(gameID: String, files: [String: Data], history: String) throws -> CheckpointPackage
    func manifest(gameID: String) throws -> RunManifest?
    func setInitialHistoryTarget(gameID: String, target: BoundSDKEventCursor) throws -> BoundSDKEventCursor
    func completeInitialHistorySync(gameID: String) throws -> RunManifest
}

/// A second capability view over the same host reference, with no extra state.
struct BoundSDKManagedCheckpointPersistence<Store: BoundSDKManagedCheckpointPersistenceStore> {
    private let store: Store

    init(store: Store) { self.store = store }

    func useServerStorage(gameID: String) { store.useServerStorage(gameID: gameID) }

    func beginServerSession(identity: Store.RunIdentity, package: Store.CheckpointPackage?,
                            target: BoundSDKEventCursor) throws {
        try store.beginServerSession(identity: identity, package: package, target: target)
    }

    func captureServerCheckpoint(gameID: String, files: [String: Data], history: String) throws -> Store.CheckpointPackage {
        try store.captureServerCheckpoint(gameID: gameID, files: files, history: history)
    }

    func manifest(gameID: String) throws -> Store.RunManifest? {
        try store.manifest(gameID: gameID)
    }

    @discardableResult
    func setInitialHistoryTarget(gameID: String, target: BoundSDKEventCursor) throws -> BoundSDKEventCursor {
        try store.setInitialHistoryTarget(gameID: gameID, target: target)
    }

    @discardableResult
    func completeInitialHistorySync(gameID: String) throws -> Store.RunManifest {
        try store.completeInitialHistorySync(gameID: gameID)
    }
}

extension BoundSDKManagedCheckpointPersistence: Sendable where Store: Sendable {}
