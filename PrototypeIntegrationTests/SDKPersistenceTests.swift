import XCTest
@testable import Delta

final class SDKPersistenceTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }

    private func fixture() throws -> (BoundMultiplayerSaveStore, BoundMultiplayerRunIdentity, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BoundSDKPersistence-" + UUID().uuidString, isDirectory: true)
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let save = folder.appendingPathComponent("game.sav")
        try Data(repeating: 3, count: 131_072).write(to: save)
        let owner = UUID()
        let identity = BoundMultiplayerRunIdentity(run: UUID(), gameID: "sdk-persistence-fixture", owner: owner,
            partner: UUID(), roomID: "fixture-room", settingsOwner: owner, settings: Data([1, 2, 3]),
            localSeed: 1, partnerSeed: 2, romSHA256: String(repeating: "a", count: 64))
        let store = BoundMultiplayerSaveStore(root: folder.appendingPathComponent("packages"), support: folder, deviceID: UUID())
        try store.begin(identity, gameSaveURL: save)
        return (store, identity, save)
    }

    private func bytes(in folder: URL) throws -> [String: Data] {
        let paths = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in paths {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(folder.path.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }

    func testEventFacetUsesTheExistingJournalBytesAndErrors() throws {
        let (store, identity, _) = try fixture()
        let events = BoundSDKEventPersistence(store: store)
        let own = try store.appendSharedEvent(gameID: identity.gameID, kind: "fixture", payload: Data([1]), idempotencyKey: "first")
        let firstBytes = try bytes(in: store.support)
        XCTAssertEqual(try events.appendSharedEvent(gameID: identity.gameID, kind: "fixture", payload: Data([1]), idempotencyKey: "first"), own)
        XCTAssertEqual(try bytes(in: store.support), firstBytes)
        XCTAssertEqual(try events.journal(gameID: identity.gameID), try store.journal(gameID: identity.gameID))
        XCTAssertEqual(try events.pendingSharedRunIdentities(gameID: identity.gameID), [identity])

        XCTAssertThrowsError(try events.appendSharedEvent(gameID: identity.gameID, kind: "fixture", payload: Data([9]), idempotencyKey: "first")) {
            XCTAssertEqual($0 as? BoundMultiplayerSaveStore.Failure, .conflict)
        }
        XCTAssertThrowsError(try store.appendSharedEvent(gameID: identity.gameID, kind: "fixture", payload: Data([9]), idempotencyKey: "first")) {
            XCTAssertEqual($0 as? BoundMultiplayerSaveStore.Failure, .conflict)
        }
        XCTAssertEqual(try bytes(in: store.support), firstBytes)

        let peer = BoundSDKEvent(run: identity.run, id: .init(origin: identity.partner, sequence: 2), kind: "fixture", payload: Data([2]))
        XCTAssertTrue(try events.receiveAuthoritativeSharedEvent(gameID: identity.gameID, event: peer, identity: identity))
        let receivedBytes = try bytes(in: store.support)
        XCTAssertFalse(try store.receiveAuthoritativeSharedEvent(gameID: identity.gameID, event: peer, identity: identity))
        XCTAssertEqual(try bytes(in: store.support), receivedBytes)
        XCTAssertEqual(try events.pendingSharedEventsToApply(gameID: identity.gameID, identity: identity), [peer])
        XCTAssertEqual(try events.sharedEventAcknowledgement(gameID: identity.gameID), try store.sharedEventAcknowledgement(gameID: identity.gameID))
        XCTAssertTrue(try events.journal(gameID: identity.gameID).received.contains(peer.id))
        XCTAssertFalse(try events.journal(gameID: identity.gameID).applied.contains(peer.id))

        try events.markSharedEventApplied(gameID: identity.gameID, eventID: peer.id, identity: identity)
        XCTAssertTrue(try store.pendingSharedEventsToApply(gameID: identity.gameID).isEmpty)
        var cursor = BoundSDKEventCursor(); cursor.insert(own.id)
        let acknowledgement = BoundSDKEventAcknowledgement(run: identity.run, receiver: identity.partner, cursor: cursor)
        try events.acknowledgeSharedEvents(gameID: identity.gameID, acknowledgement: acknowledgement, identity: identity)
        let acknowledgedBytes = try bytes(in: store.support)
        try store.acknowledgeSharedEvents(gameID: identity.gameID, acknowledgement: acknowledgement, identity: identity)
        XCTAssertEqual(try bytes(in: store.support), acknowledgedBytes)
        XCTAssertTrue(try events.pendingSharedRunIdentities(gameID: identity.gameID).isEmpty)
        XCTAssertTrue(try events.eventsToSend(gameID: identity.gameID).isEmpty)

        var wrong = identity; wrong.run = UUID()
        XCTAssertThrowsError(try events.journal(gameID: identity.gameID, identity: wrong))
        XCTAssertThrowsError(try store.journal(gameID: identity.gameID, identity: wrong))
        XCTAssertEqual(try bytes(in: store.support), acknowledgedBytes)
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertEqual(try BoundSDKEventPersistence(store: reopened).journal(gameID: identity.gameID), try events.journal(gameID: identity.gameID))
    }

    func testEventFacetPreservesHostCheckpointPolicyBeforeBatchLimit() throws {
        let (store, identity, _) = try fixture()
        let events = BoundSDKEventPersistence(store: store)
        for index in 0..<3 {
            let payload = try XCTUnwrap(BoundSoulSharedEvent(run: identity.run, kind: .acquired, slot: "area:\(index)").payload)
            try events.appendSharedEvent(gameID: identity.gameID, kind: "soul", payload: payload)
        }
        let payload = try XCTUnwrap(BoundSoulSharedEvent(run: identity.run, kind: .death, slot: "area:0").payload)
        let death = try events.appendSharedEvent(gameID: identity.gameID, kind: "soul", payload: payload)
        let before = try bytes(in: store.support)
        XCTAssertEqual(try events.eventsToSend(gameID: identity.gameID), try store.sharedEventsToSend(gameID: identity.gameID))
        XCTAssertEqual(try events.eventsToSend(gameID: identity.gameID, peerCursor: .init(), limit: 2,
            identity: identity, excludingCheckpointDependentEvents: true), [death])
        XCTAssertEqual(try events.eventsToSend(gameID: identity.gameID, peerCursor: .init(), limit: 2,
            identity: identity, excludingCheckpointDependentEvents: true),
            try store.sharedEventsToSend(gameID: identity.gameID, peerCursor: .init(), limit: 2, identity: identity, excludingAcquisitions: true))
        XCTAssertEqual(try events.eventsToSend(gameID: identity.gameID, peerCursor: .init(), limit: 0),
            try store.sharedEventsToSend(gameID: identity.gameID, peerCursor: .init(), limit: 0))
        var peerCursor = BoundSDKEventCursor(); peerCursor.insert(death.id)
        XCTAssertTrue(try events.eventsToSend(gameID: identity.gameID, peerCursor: peerCursor, limit: 2,
            excludingCheckpointDependentEvents: true).isEmpty)
        XCTAssertEqual(try bytes(in: store.support), before)
    }

    func testManagedFacetSharesRAMStateAndPreservesAllExistingFiles() throws {
        let (store, original, _) = try fixture()
        let events = BoundSDKEventPersistence(store: store)
        let checkpoints = BoundSDKManagedCheckpointPersistence(store: store)
        _ = try store.journal(gameID: original.gameID)
        let originalFiles = try bytes(in: store.support)
        checkpoints.useServerStorage(gameID: original.gameID)
        XCTAssertNil(try store.manifest(gameID: original.gameID))
        var identity = original; identity.run = UUID()
        try checkpoints.beginServerSession(identity: identity, package: nil, target: .init())
        XCTAssertEqual(try checkpoints.manifest(gameID: identity.gameID), try store.manifest(gameID: identity.gameID))
        let own = try events.appendSharedEvent(gameID: identity.gameID, kind: "fixture", payload: Data([8]))

        // Synthetic markers exercise package storage, not native-state validity.
        let files = ["game.sav": Data(repeating: 7, count: 131_072), "checkpoint.state": Data(repeating: 9, count: 2048)]
        let package = try checkpoints.captureServerCheckpoint(gameID: identity.gameID, files: files, history: String(repeating: "b", count: 64))
        XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), package)
        XCTAssertEqual(package.payload.version, 2)
        XCTAssertEqual(package.payload.files["shared-events.json"]?.data, try BoundMultiplayerSaveStore.encode(store.journal(gameID: identity.gameID)))
        XCTAssertEqual(package.receipt.payloadSHA256, try BoundMultiplayerSaveStore.hash(BoundMultiplayerSaveStore.encode(package.payload)))
        XCTAssertEqual(package.payload.files["game.sav"]?.data, files["game.sav"])
        XCTAssertEqual(try bytes(in: store.support), originalFiles)
        XCTAssertTrue(try events.pendingSharedRunIdentities(gameID: identity.gameID).isEmpty)

        store.useServerStorage(gameID: identity.gameID)
        XCTAssertNil(try checkpoints.manifest(gameID: identity.gameID))
        XCTAssertThrowsError(try events.journal(gameID: identity.gameID)) {
            XCTAssertEqual($0 as? BoundMultiplayerSaveStore.Failure, .incompatible)
        }
        var other = identity; other.owner = identity.partner; other.partner = identity.owner
        XCTAssertThrowsError(try checkpoints.beginServerSession(identity: other, package: package, target: .init())) {
            XCTAssertEqual($0 as? BoundMultiplayerSaveStore.Failure, .ownerMismatch)
        }
        try checkpoints.beginServerSession(identity: identity, package: package, target: .init())
        XCTAssertEqual(try events.journal(gameID: identity.gameID).events, [own])
        XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), package)
        let next = try store.appendSharedEvent(gameID: identity.gameID, kind: "fixture", payload: Data([9]))
        XCTAssertEqual(try events.journal(gameID: identity.gameID).events, [own, next])
        XCTAssertEqual(next.id.sequence, own.id.sequence + 1)
        XCTAssertEqual(try bytes(in: store.support), originalFiles)

        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertEqual(try reopened.manifest(gameID: original.gameID)?.identity, original)
        XCTAssertTrue(try reopened.journal(gameID: original.gameID).events.isEmpty)
    }

    func testFacetsKeepFiniteInitialHistoryTargetAndRequireNativeApplication() throws {
        let (store, identity, _) = try fixture()
        let events = BoundSDKEventPersistence(store: store)
        let checkpoints = BoundSDKManagedCheckpointPersistence(store: store)
        var manifest = try XCTUnwrap(store.manifest(gameID: identity.gameID))
        manifest.requiresInitialHistorySync = true
        let manifestURL = store.directory(gameID: identity.gameID).appendingPathComponent("run.json")
        try BoundMultiplayerSaveStore.encode(manifest).write(to: manifestURL)
        let own = BoundSDKEvent(run: identity.run, id: .init(origin: identity.owner, sequence: 1), kind: "fixture", payload: Data([1]))
        let peer = BoundSDKEvent(run: identity.run, id: .init(origin: identity.partner, sequence: 1), kind: "fixture", payload: Data([2]))
        var target = BoundSDKEventCursor(); target.insert(own.id); target.insert(peer.id)
        XCTAssertEqual(try checkpoints.setInitialHistoryTarget(gameID: identity.gameID, target: target), target)
        let frozenBytes = try bytes(in: store.support)
        var newer = target; newer.insert(.init(origin: identity.partner, sequence: 2))
        XCTAssertEqual(try store.setInitialHistoryTarget(gameID: identity.gameID, target: newer), target)
        XCTAssertEqual(try checkpoints.setInitialHistoryTarget(gameID: identity.gameID, target: newer), target)
        XCTAssertEqual(try bytes(in: store.support), frozenBytes)
        XCTAssertThrowsError(try checkpoints.completeInitialHistorySync(gameID: identity.gameID)) {
            XCTAssertEqual($0 as? BoundMultiplayerSaveStore.Failure, .incomplete)
        }
        try events.receiveAuthoritativeSharedEvent(gameID: identity.gameID, event: own)
        try events.receiveAuthoritativeSharedEvent(gameID: identity.gameID, event: peer)
        XCTAssertTrue(try events.sharedEventAcknowledgement(gameID: identity.gameID).cursor.covers(target))
        XCTAssertThrowsError(try checkpoints.completeInitialHistorySync(gameID: identity.gameID)) {
            XCTAssertEqual($0 as? BoundMultiplayerSaveStore.Failure, .incomplete)
        }
        try events.markSharedEventApplied(gameID: identity.gameID, eventID: own.id)
        XCTAssertThrowsError(try store.completeInitialHistorySync(gameID: identity.gameID))
        try store.markSharedEventApplied(gameID: identity.gameID, eventID: peer.id)
        let complete = try checkpoints.completeInitialHistorySync(gameID: identity.gameID)
        XCTAssertFalse(complete.requiresInitialHistorySync)
        XCTAssertNil(complete.initialHistoryTarget)
        XCTAssertEqual(try checkpoints.manifest(gameID: identity.gameID), complete)
        let completeBytes = try bytes(in: store.support)
        XCTAssertEqual(try store.completeInitialHistorySync(gameID: identity.gameID), complete)
        XCTAssertEqual(try bytes(in: store.support), completeBytes)
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertEqual(try BoundSDKManagedCheckpointPersistence(store: reopened).manifest(gameID: identity.gameID), complete)
    }
}
