import XCTest
@testable import Delta

final class MultiplayerSavePackageTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }
    private func fixture(device: UUID = UUID()) throws -> (BoundMultiplayerSaveStore, BoundMultiplayerRunIdentity, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BoundSavePackageTests-" + UUID().uuidString, isDirectory: true)
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let save = folder.appendingPathComponent("game.sav")
        try Data(repeating: 3, count: 131_072).write(to: save)
        let owner = UUID()
        let identity = BoundMultiplayerRunIdentity(run: UUID(), gameID: "game-fixture", owner: owner, partner: UUID(),
            roomID: "friend-room", settingsOwner: owner, settings: Data([1, 2, 3]), localSeed: 1, partnerSeed: 2,
            romSHA256: String(repeating: "a", count: 64))
        let store = BoundMultiplayerSaveStore(root: folder.appendingPathComponent("packages"), support: folder, deviceID: device)
        try store.begin(identity, gameSaveURL: save)
        return (store, identity, save)
    }
    private func peer(_ receipt: BoundMultiplayerCheckpointReceipt, identity: BoundMultiplayerRunIdentity) -> BoundMultiplayerCheckpointReceipt {
        .init(run: receipt.run, checkpoint: receipt.checkpoint, owner: identity.partner,
              payloadSHA256: String(repeating: "b", count: 64), sharedEventDigest: receipt.sharedEventDigest)
    }
    @discardableResult
    private func complete(_ store: BoundMultiplayerSaveStore, _ identity: BoundMultiplayerRunIdentity, _ save: URL,
                          parent: UUID? = nil) throws -> BoundMultiplayerSavePackage {
        let receipt = try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: parent,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save)
        return try store.commit(gameID: identity.gameID, checkpointID: receipt.checkpoint, partnerReceipt: peer(receipt, identity: identity))
    }
    private func writeSoul(_ store: BoundMultiplayerSaveStore, _ identity: BoundMultiplayerRunIdentity, dead: [String]) throws -> URL {
        let url = store.support.appendingPathComponent("Soul Link/" + BoundMultiplayerSaveStore.hash(Data(identity.gameID.utf8)) + ".json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["run": identity.run.uuidString, "dead": dead]).write(to: url, options: .atomic)
        return url
    }
    func testServerStorageDisregardsLocalRunAndWritesNoCheckpointFiles() throws {
        let (store, old, save) = try fixture()
        let original = try Data(contentsOf: store.directory(gameID: old.gameID).appendingPathComponent("run.json"))
        store.useServerStorage(gameID: old.gameID)
        XCTAssertNil(try store.manifest(gameID: old.gameID))
        var identity = old; identity.run = UUID()
        try store.beginServerSession(identity: identity, package: nil, target: .init())
        let event = try store.appendSharedEvent(gameID: identity.gameID, kind: "world", payload: Data([1]), idempotencyKey: "one")
        let files = ["game.sav": Data(repeating: 7, count: 131072), "checkpoint.state": Data(repeating: 9, count: 2048), "memory-files.json": Data("{}".utf8)]
        let package = try store.captureServerCheckpoint(gameID: identity.gameID, files: files, history: String(repeating: "a", count: 64))
        XCTAssertEqual(package.payload.manifest.identity.run, identity.run)
        XCTAssertEqual(try store.journal(gameID: identity.gameID).events, [event])
        XCTAssertEqual(try Data(contentsOf: store.directory(gameID: old.gameID).appendingPathComponent("run.json")), original)
        XCTAssertEqual(try Data(contentsOf: save), Data(repeating: 3, count: 131072))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cloudURL(gameID: identity.gameID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(gameID: identity.gameID).appendingPathComponent("Checkpoints").path))
    }

    func testWithheldAcquisitionsCannotStarveLaterDeathEventsInBoundedBatches() throws {
        let (store, identity, _) = try fixture()
        for index in 0..<20 {
            _ = try store.appendSharedEvent(gameID: identity.gameID, kind: "soul",
                payload: XCTUnwrap(BoundSoulSharedEvent(run: identity.run, kind: .acquired, slot: "area:\(index)").payload))
        }
        let death = try store.appendSharedEvent(gameID: identity.gameID, kind: "soul",
            payload: XCTUnwrap(BoundSoulSharedEvent(run: identity.run, kind: .death, slot: "area:0").payload))
        XCTAssertEqual(try store.sharedEventsToSend(gameID: identity.gameID, peerCursor: .init(), limit: 16,
            excludingAcquisitions: true), [death])
        XCTAssertEqual(try store.sharedEventsToSend(gameID: identity.gameID, peerCursor: .init(), limit: 16).count, 16)
    }
    func testServerSessionRestoresOnlyAuthenticatedPlayerAndGapAwareJournal() throws {
        let (store, identity, _) = try fixture()
        store.useServerStorage(gameID: identity.gameID)
        try store.beginServerSession(identity: identity, package: nil, target: .init())
        let event = try store.appendSharedEvent(gameID: identity.gameID, kind: "world", payload: Data([3]))
        let package = try store.captureServerCheckpoint(gameID: identity.gameID,
            files: ["game.sav": Data(repeating: 8, count: 131072), "checkpoint.state": Data(repeating: 4, count: 2048)], history: String(repeating: "c", count: 64))
        store.useServerStorage(gameID: identity.gameID)
        XCTAssertNil(try store.latestComplete(gameID: identity.gameID))
        var other = identity; other.owner = identity.partner; other.partner = identity.owner
        XCTAssertThrowsError(try store.beginServerSession(identity: other, package: package, target: .init()))
        try store.beginServerSession(identity: identity, package: package, target: .init())
        XCTAssertEqual(try store.journal(gameID: identity.gameID).events, [event])
        let next = try store.appendSharedEvent(gameID: identity.gameID, kind: "world", payload: Data([4]))
        XCTAssertEqual(next.id.sequence, event.id.sequence + 1)
        XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), package)
    }
    @MainActor func testExternalSetupOptionsEncodeNativeQuestionsAndPersonalIdentity() {
        var options = BoundMultiplayerSetupOptions()
        options.name = "Leaf"; options.gender = 1; options.rival = "Gary"; options.difficulty = 2
        options.partnerName = "Ash"; options.partnerGender = 0
        options.cheats = true; options.nicknames = false; options.randomAbilities = true
        XCTAssertTrue(options.valid)
        XCTAssertTrue(BoundROMMultiplayerCoordinator.validSettings(options.settings))
        XCTAssertEqual(options.settings[3], 1)
        XCTAssertEqual(options.settings[10], 1)
        XCTAssertEqual(options.settings[11], 0)
        var host = BoundROMHostState(); host.externalSetup = true; host.playerProfile = options.profile
        let bytes = host.encoded(sequence: 2)
        XCTAssertEqual(bytes[13] & 16, 16)
        XCTAssertEqual(bytes.subdata(in: 1408..<1416), BoundMultiplayerSetupOptions.nativeName("Leaf"))
        XCTAssertEqual(bytes[1416], 1); XCTAssertEqual(bytes[1417], 1)
        host.playerProfile = options.partnerProfile
        let partnerBytes = host.encoded(sequence: 4)
        XCTAssertEqual(partnerBytes.subdata(in: 1408..<1416), BoundMultiplayerSetupOptions.nativeName("Ash"))
        XCTAssertEqual(partnerBytes[1416], 0)
        options.partnerName = "TOOLONG8"
        XCTAssertFalse(options.valid)
        XCTAssertTrue(options.profile.valid, "An old save's own-profile prompt does not depend on the friend's draft")
        options.partnerName = "Ash"; options.partnerGender = 2
        XCTAssertFalse(options.valid)
    }
    @MainActor func testGameOverDeletionChoiceIsSharedAndOnlyDebugCanDisableIt() {
        var options = BoundMultiplayerSetupOptions()
        XCTAssertFalse(options.deleteSaveOnGameOver, "The debug control defaults off")
        XCTAssertEqual(options.settings[0], 5)
        XCTAssertEqual(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: options.settings), true)

        options.debug = true
        XCTAssertEqual(options.settings[20], 1)
        XCTAssertEqual(options.settings[21], 1)
        XCTAssertEqual(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: options.settings), false)
        let shared = options.settings
        XCTAssertEqual(shared.count, 32)
        XCTAssertEqual(shared[21], 1)
        XCTAssertEqual(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: shared), false)
        options.deleteSaveOnGameOver = true
        XCTAssertEqual(options.settings[21], 0)
        XCTAssertEqual(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: options.settings), true)
        options.deleteSaveOnGameOver = false

        options.debug = false
        XCTAssertEqual(options.settings[21], 0, "A hidden debug choice cannot disable ordinary run deletion")
        XCTAssertEqual(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: options.settings), true)
        options.debug = true
        XCTAssertEqual(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: options.settings), false,
                       "Changing the preset preserves the user's draft choice")

        var invalid = shared; invalid[20] = 0
        XCTAssertNil(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: invalid))
        invalid = shared; invalid[21] = 2
        XCTAssertNil(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: invalid))
        invalid = shared; invalid[22] = 1
        XCTAssertNil(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: invalid))
        invalid = shared; invalid[0] = 6
        XCTAssertNil(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: invalid))
        XCTAssertNil(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: Data()))
    }
    @MainActor func testLegacyGameOverSettingsDefaultToDeletionWithoutAcceptingAnOverride() {
        for version in UInt8(1)...3 {
            var settings = Data(repeating: 0, count: 32); settings[0] = version
            XCTAssertEqual(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: settings), true)
            settings[21] = 1
            XCTAssertNil(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: settings))
        }
        var settings = BoundMultiplayerSetupOptions().settings; settings[0] = 4
        XCTAssertEqual(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: settings), true)
        settings[20] = 1; settings[21] = 1
        XCTAssertNil(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: settings))
    }
    func testConfigurationNeverRerollsAndPreservesSoloBattery() throws {
        let (store, identity, save) = try fixture()
        XCTAssertEqual(try store.manifest(gameID: identity.gameID)?.identity, identity)
        try store.begin(identity, gameSaveURL: save)
        var changed = identity; changed.localSeed = 10
        XCTAssertThrowsError(try store.begin(changed, gameSaveURL: save))
        XCTAssertEqual(try Data(contentsOf: store.directory(gameID: identity.gameID).appendingPathComponent("pre-run-solo.sav")), try Data(contentsOf: save))
    }
    func testPreparedCheckpointIsDurableButCannotBeCloudExported() throws {
        let (store, identity, save) = try fixture()
        let receipt = try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: nil,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save)
        XCTAssertEqual(try store.preparedCheckpoints(gameID: identity.gameID).map(\.receipt), [receipt])
        XCTAssertNil(try store.latestComplete(gameID: identity.gameID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cloudURL(gameID: identity.gameID).path))
        XCTAssertThrowsError(try store.validateCloudExport(gameID: identity.gameID))
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertEqual(try reopened.preparedCheckpoints(gameID: identity.gameID).first?.receipt, receipt)
    }
    func testCancellationChecksDiskWhenPreparedReceiptWasNotReturnedToCaller() throws {
        let (store, identity, save) = try fixture()
        let checkpoint = UUID()
        XCTAssertFalse(BoundROMCheckpointCancellation.persistedRecordMayExist(store: store,
            gameID: identity.gameID, checkpoint: checkpoint))
        // Model an atomic prepared write followed by an uncertain return/fsync:
        // the coordinator has no receipt, but the persisted record is present.
        _ = try store.prepare(gameID: identity.gameID, checkpointID: checkpoint, predecessor: nil,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save)
        let durable = BoundROMCheckpointCancellation.persistedRecordMayExist(store: store,
            gameID: identity.gameID, checkpoint: checkpoint)
        XCTAssertTrue(durable)
        var cancellation = BoundROMCheckpointCancellation()
        XCTAssertEqual(cancellation.request(at: 0, durable: durable), .recover)
        XCTAssertEqual(cancellation.receive(acknowledgement: false, durable: durable), .recover)
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        let retained = try XCTUnwrap(reopened.checkpoint(gameID: identity.gameID, id: checkpoint))
        XCTAssertFalse(retained.complete)
        let complete = try reopened.commit(gameID: identity.gameID, checkpointID: checkpoint,
            partnerReceipt: peer(retained.receipt, identity: identity))
        XCTAssertTrue(complete.complete, "The uncertain prepare remains recoverable rather than being discarded")
        XCTAssertTrue(BoundROMCheckpointCancellation.persistedRecordMayExist(store: reopened,
            gameID: identity.gameID, checkpoint: checkpoint))
    }
    func testCancellationFailsClosedWhenPreparedRecordCannotBeRead() throws {
        let (store, identity, save) = try fixture()
        let receipt = try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: nil,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save)
        let prepared = store.directory(gameID: identity.gameID).appendingPathComponent("Checkpoints")
            .appendingPathComponent(receipt.checkpoint.uuidString + ".prepared.json")
        try Data("incomplete file".utf8).write(to: prepared)
        XCTAssertTrue(BoundROMCheckpointCancellation.persistedRecordMayExist(store: store,
            gameID: identity.gameID, checkpoint: receipt.checkpoint),
            "Unreadable prepared bytes are uncertainty, never permission to cancel and resume")
    }
    func testBothReceiptsMustAgreeAndPreviousCheckpointsRemain() throws {
        let (store, identity, save) = try fixture()
        let first = try complete(store, identity, save)
        try Data(repeating: 4, count: 131_072).write(to: save)
        let receipt = try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: first.payload.checkpoint,
            sharedEventDigest: String(repeating: "d", count: 64), gameSaveURL: save)
        var wrong = peer(receipt, identity: identity); wrong.sharedEventDigest = String(repeating: "e", count: 64)
        XCTAssertThrowsError(try store.commit(gameID: identity.gameID, checkpointID: receipt.checkpoint, partnerReceipt: wrong))
        XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), first)
        let second = try store.commit(gameID: identity.gameID, checkpointID: receipt.checkpoint, partnerReceipt: peer(receipt, identity: identity))
        XCTAssertEqual(try store.checkpoint(gameID: identity.gameID, id: first.payload.checkpoint), first)
        let archive = try JSONDecoder().decode(BoundMultiplayerSaveStore.CloudArchive.self, from: Data(contentsOf: store.cloudURL(gameID: identity.gameID)))
        XCTAssertEqual(archive.checkpoints, [second, first])
        XCTAssertTrue(try store.preparedCheckpoints(gameID: identity.gameID).isEmpty)
    }
    func testRetryIsIdempotentAndDivergentParentIsRejected() throws {
        let (store, identity, save) = try fixture()
        let first = try complete(store, identity, save)
        let retry = try store.prepare(gameID: identity.gameID, checkpointID: first.payload.checkpoint, predecessor: nil,
            sharedEventDigest: first.payload.sharedEventDigest, gameSaveURL: save)
        XCTAssertEqual(retry, first.receipt)
        XCTAssertEqual(try store.commit(gameID: identity.gameID, checkpointID: first.payload.checkpoint,
            partnerReceipt: try XCTUnwrap(first.partnerReceipt)), first)
        XCTAssertThrowsError(try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: nil,
            sharedEventDigest: first.payload.sharedEventDigest, gameSaveURL: save))
    }
    func testUploadSnapshotsCannotMixWithLaterCheckpoint() throws {
        let (store, identity, save) = try fixture()
        let first = try complete(store, identity, save)
        let frozen = try store.snapshotCloudExport(gameID: identity.gameID)
        let bytes = try Data(contentsOf: frozen.appendingPathComponent("complete.boundrun"))
        try Data(repeating: 6, count: 131_072).write(to: save)
        _ = try complete(store, identity, save, parent: first.payload.checkpoint)
        XCTAssertEqual(try Data(contentsOf: frozen.appendingPathComponent("complete.boundrun")), bytes)
        XCTAssertEqual(try Data(contentsOf: frozen.appendingPathComponent("game.sav")), Data(repeating: 3, count: 131_072))
        XCTAssertNotEqual(try Data(contentsOf: store.cloudURL(gameID: identity.gameID)), bytes)
    }
    func testRestoreRejectsActiveGameWrongAccountROMAndDevice() throws {
        let (store, identity, save) = try fixture()
        _ = try complete(store, identity, save)
        let url = store.cloudURL(gameID: identity.gameID)
        store.setActive(true, gameID: identity.gameID)
        XCTAssertThrowsError(try store.restore(archiveURL: url, gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        store.setActive(false, gameID: identity.gameID)
        XCTAssertThrowsError(try store.restore(archiveURL: url, gameID: identity.gameID, owner: UUID(), romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertThrowsError(try store.restore(archiveURL: url, gameID: identity.gameID, owner: identity.owner, romSHA256: String(repeating: "f", count: 64), gameSaveURL: save))
        let other = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: UUID())
        XCTAssertThrowsError(try other.validateForResume(gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256))
        XCTAssertThrowsError(try other.restore(archiveURL: url, gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
    }
    func testRestoreRejectsTamperingWithoutChangingWorkingSave() throws {
        let (store, identity, save) = try fixture()
        _ = try complete(store, identity, save)
        let original = try Data(contentsOf: save)
        var archive = try JSONDecoder().decode(BoundMultiplayerSaveStore.CloudArchive.self, from: Data(contentsOf: store.cloudURL(gameID: identity.gameID)))
        archive.checkpoints[0].payload.files["game.sav"]?.data[0] = 255
        let incoming = try store.stageDownload(gameID: identity.gameID, version: "tampered").appendingPathComponent("complete.boundrun")
        try BoundMultiplayerSaveStore.encode(archive).write(to: incoming)
        XCTAssertThrowsError(try store.restore(archiveURL: incoming, gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertEqual(try Data(contentsOf: save), original)
        XCTAssertEqual(store.pendingImports(gameID: identity.gameID).map { $0.resolvingSymlinksInPath() }, [incoming.resolvingSymlinksInPath()])
    }
    func testRestoreCannotUndoDeathOrUnsavedPersonalProgress() throws {
        let (store, identity, save) = try fixture()
        let journal = try writeSoul(store, identity, dead: [])
        _ = try complete(store, identity, save)
        let url = store.cloudURL(gameID: identity.gameID)
        _ = try writeSoul(store, identity, dead: ["area:1"])
        let death = try Data(contentsOf: journal)
        XCTAssertThrowsError(try store.restore(archiveURL: url, gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertEqual(try Data(contentsOf: journal), death)
        _ = try writeSoul(store, identity, dead: [])
        try Data(repeating: 9, count: 131_072).write(to: save)
        XCTAssertThrowsError(try store.restore(archiveURL: url, gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertEqual(try Data(contentsOf: save), Data(repeating: 9, count: 131_072))
    }
    func testNativeRecoveryIsIncludedWithVerifiedReferencedState() throws {
        let (store, identity, save) = try fixture()
        let folder = store.support.appendingPathComponent("Friend Battles", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString, state = Data(repeating: 7, count: 2048)
        try state.write(to: folder.appendingPathComponent(id + ".state"))
        let journal: [String: String] = ["gameID": identity.gameID, "rom": identity.romSHA256, "state": id + ".state", "sha256": BoundMultiplayerSaveStore.hash(state), "activity": "trade", "tradeStarted": "true"]
        try JSONSerialization.data(withJSONObject: journal).write(to: folder.appendingPathComponent(id + ".json"))
        let package = try complete(store, identity, save)
        XCTAssertEqual(package.payload.files["recovery/" + id + ".state"]?.data, state)
        XCTAssertNotNil(package.payload.files["recovery/" + id + ".json"])
    }
    func testImportedComplementaryHistoryNormalizesCursorsAndRetainsPermanentLosses() throws {
        let (source, identity, sourceSave) = try fixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BoundComplementaryRestore-" + UUID().uuidString, isDirectory: true)
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destinationSave = folder.appendingPathComponent("game.sav")
        try Data(contentsOf: sourceSave).write(to: destinationSave)
        let destination = BoundMultiplayerSaveStore(root: folder.appendingPathComponent("packages"), support: folder, deviceID: source.deviceID)
        try destination.begin(identity, gameSaveURL: destinationSave)

        // Same-device backup copies can retain complementary valid journals.
        // Both original journals pass the store's existing validation.
        var own: [BoundMultiplayerSharedEvent] = []
        for value: UInt8 in [1, 2] {
            let event = try source.appendSharedEvent(gameID: identity.gameID, kind: "fixture", payload: Data([value]), idempotencyKey: "local-\(value)")
            XCTAssertEqual(try destination.appendSharedEvent(gameID: identity.gameID, kind: "fixture", payload: Data([value]), idempotencyKey: "local-\(value)"), event)
            own.append(event)
        }
        func death(_ sequence: UInt64, slot: String) throws -> BoundMultiplayerSharedEvent {
            .init(run: identity.run, id: .init(origin: identity.partner, sequence: sequence), kind: "soul",
                  payload: try XCTUnwrap(BoundSoulSharedEvent(run: identity.run, kind: .death, slot: slot).payload))
        }
        let peer1 = try death(1, slot: "area:1"), peer2 = try death(2, slot: "area:2"), peer4 = try death(4, slot: "area:4")
        try source.receiveSharedEvent(gameID: identity.gameID, event: peer2)
        try source.markSharedEventApplied(gameID: identity.gameID, eventID: peer2.id)
        try source.receiveSharedEvent(gameID: identity.gameID, event: peer4)
        try destination.receiveSharedEvent(gameID: identity.gameID, event: peer1)
        try destination.markSharedEventApplied(gameID: identity.gameID, eventID: peer1.id)
        var sourceAck = BoundMultiplayerSharedCursor(); sourceAck.insert(own[1].id)
        var destinationAck = BoundMultiplayerSharedCursor(); destinationAck.insert(own[0].id)
        try source.acknowledgeSharedEvents(gameID: identity.gameID,
            acknowledgement: .init(run: identity.run, receiver: identity.partner, cursor: sourceAck))
        try destination.acknowledgeSharedEvents(gameID: identity.gameID,
            acknowledgement: .init(run: identity.run, receiver: identity.partner, cursor: destinationAck))

        let stem = BoundMultiplayerSaveStore.hash(Data(identity.gameID.utf8))
        func soulURL(_ store: BoundMultiplayerSaveStore) -> URL {
            store.support.appendingPathComponent("Soul Link/" + stem + ".json")
        }
        var sourceSoul = BoundSoulLedger(run: identity.run, binding: String(repeating: "b", count: 64))
        sourceSoul.dead = ["area:2"]; sourceSoul.nextEgg = 3
        var destinationSoul = BoundSoulLedger(run: identity.run, binding: sourceSoul.binding)
        destinationSoul.dead = ["area:1"]; destinationSoul.nextEgg = 5
        for (store, ledger) in [(source, sourceSoul), (destination, destinationSoul)] {
            try FileManager.default.createDirectory(at: soulURL(store).deletingLastPathComponent(), withIntermediateDirectories: true)
            try BoundMultiplayerSaveStore.encode(ledger).write(to: soulURL(store))
        }
        XCTAssertEqual(try source.journal(gameID: identity.gameID).received.origins[identity.partner.uuidString], BoundMultiplayerSharedCursor.Position(sparse: [2, 4]))
        XCTAssertEqual(try destination.journal(gameID: identity.gameID).received.origins[identity.partner.uuidString], BoundMultiplayerSharedCursor.Position(contiguous: 1))
        XCTAssertNil(try destination.latestComplete(gameID: identity.gameID))
        let originalJournal = try BoundMultiplayerSaveStore.encode(destination.journal(gameID: identity.gameID))
        let originalSoul = try Data(contentsOf: soulURL(destination))
        let originalBattery = try Data(contentsOf: destinationSave)

        // Synthetic state markers exercise storage/recovery, not native playback.
        let package = try source.saveLocal(gameID: identity.gameID, sharedEventDigest: String(repeating: "c", count: 64),
            gameSaveURL: sourceSave, additionalFiles: ["checkpoint.state": Data(repeating: 9, count: 2048)])
        let archive = source.cloudURL(gameID: identity.gameID)
        let archiveBytes = try Data(contentsOf: archive)
        try destination.restore(archiveURL: archive, gameID: identity.gameID, owner: identity.owner,
            romSHA256: identity.romSHA256, gameSaveURL: destinationSave)

        XCTAssertFalse(destination.hasInterruptedRestore(gameID: identity.gameID))
        XCTAssertEqual(try destination.latestComplete(gameID: identity.gameID), package)
        XCTAssertNotNil(try destination.validateForResume(gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256))
        let journal = try destination.journal(gameID: identity.gameID)
        XCTAssertEqual(Set(journal.events.map(\.id)), Set((own + [peer1, peer2, peer4]).map(\.id)))
        for event in own + [peer1, peer2, peer4] { XCTAssertEqual(journal.events.first { $0.id == event.id }, event) }
        XCTAssertEqual(journal.events.count, 5)
        XCTAssertEqual(journal.nextSequence, 3)
        XCTAssertEqual(journal.received.origins[identity.partner.uuidString], BoundMultiplayerSharedCursor.Position(contiguous: 2, sparse: [4]))
        XCTAssertEqual(journal.applied.origins[identity.partner.uuidString], BoundMultiplayerSharedCursor.Position(contiguous: 2))
        XCTAssertEqual(journal.acknowledged.origins[identity.owner.uuidString], BoundMultiplayerSharedCursor.Position(contiguous: 2))
        XCTAssertFalse(journal.received.contains(.init(origin: identity.partner, sequence: 3)))
        XCTAssertEqual(try destination.pendingSharedEventsToApply(gameID: identity.gameID), [peer4])
        let mergedSoul = try JSONDecoder().decode(BoundSoulLedger.self, from: Data(contentsOf: soulURL(destination)))
        XCTAssertEqual(mergedSoul.dead, ["area:1", "area:2"])
        XCTAssertEqual(mergedSoul.nextEgg, 5)
        XCTAssertEqual(try Data(contentsOf: archive), archiveBytes)
        let originals = try FileManager.default.contentsOfDirectory(at: destination.directory(gameID: identity.gameID)
            .appendingPathComponent("Restored Originals"), includingPropertiesForKeys: nil)
        XCTAssertEqual(originals.count, 1)
        let retained = try XCTUnwrap(originals.first).appendingPathComponent("originals")
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("shared-events.json")), originalJournal)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("soul.json")), originalSoul)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("game.sav")), originalBattery)

        let reopened = BoundMultiplayerSaveStore(root: destination.root, support: destination.support, deviceID: destination.deviceID)
        XCTAssertEqual(try reopened.journal(gameID: identity.gameID), journal)
        try reopened.restore(archiveURL: archive, gameID: identity.gameID, owner: identity.owner,
            romSHA256: identity.romSHA256, gameSaveURL: destinationSave)
        XCTAssertEqual(try reopened.journal(gameID: identity.gameID), journal)
        XCTAssertEqual(try reopened.checkpoint(gameID: identity.gameID, id: package.payload.checkpoint), package)
        XCTAssertEqual(try Data(contentsOf: archive), archiveBytes)
    }
    func testCompatibleRestoreKeepsOriginalsAndCorruptHeadFailsClosed() throws {
        let (store, identity, save) = try fixture()
        _ = try writeSoul(store, identity, dead: ["area:2"])
        _ = try complete(store, identity, save)
        try store.restore(archiveURL: store.cloudURL(gameID: identity.gameID), gameID: identity.gameID,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save)
        let preserved = store.directory(gameID: identity.gameID).appendingPathComponent("Restored Originals")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: preserved.path).count, 1)
        try Data("corrupt".utf8).write(to: store.directory(gameID: identity.gameID).appendingPathComponent("head.json"))
        XCTAssertThrowsError(try store.validateForResume(gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256))
    }
    func testInterruptedRestoreBlocksResumeAndReplaysValidatedPackage() throws {
        let (store, identity, save) = try fixture()
        let package = try complete(store, identity, save)
        let transaction = store.directory(gameID: identity.gameID).appendingPathComponent("Restore", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try BoundMultiplayerSaveStore.encode(package).write(to: transaction.appendingPathComponent("pending.boundrun"))
        try Data(repeating: 8, count: 131_072).write(to: save)
        XCTAssertTrue(store.hasInterruptedRestore(gameID: identity.gameID))
        XCTAssertThrowsError(try store.validateForResume(gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256))
        try store.finishInterruptedRestore(gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save)
        XCTAssertFalse(store.hasInterruptedRestore(gameID: identity.gameID))
        XCTAssertEqual(try Data(contentsOf: save), package.payload.files["game.sav"]?.data)
        XCTAssertNotNil(try store.validateForResume(gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256))
    }
    func testRestoreInterruptedBeforeJournalKeepsOriginalsAndAllowsRetry() throws {
        let (store, identity, save) = try fixture()
        let soul = try writeSoul(store, identity, dead: ["area:2"])
        _ = try complete(store, identity, save)
        let original = try Data(contentsOf: save), originalSoul = try Data(contentsOf: soul)
        let transaction = store.directory(gameID: identity.gameID).appendingPathComponent("Restore")
        let backups = transaction.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: save, to: backups.appendingPathComponent("game.sav"))
        try FileManager.default.copyItem(at: soul, to: backups.appendingPathComponent("soul.json"))
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertTrue(reopened.hasInterruptedRestore(gameID: identity.gameID))
        try reopened.finishInterruptedRestore(gameID: identity.gameID, owner: identity.owner,
            romSHA256: identity.romSHA256, gameSaveURL: save)
        XCTAssertFalse(reopened.hasInterruptedRestore(gameID: identity.gameID))
        XCTAssertEqual(try Data(contentsOf: save), original)
        XCTAssertEqual(try Data(contentsOf: soul), originalSoul)
        let preserved = try FileManager.default.contentsOfDirectory(at: store.directory(gameID: identity.gameID)
            .appendingPathComponent("Restored Originals"), includingPropertiesForKeys: nil)
        XCTAssertEqual(preserved.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved[0].appendingPathComponent("originals/game.sav")), original)
        try reopened.restore(archiveURL: store.cloudURL(gameID: identity.gameID), gameID: identity.gameID,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save)
        XCTAssertNotNil(try reopened.validateForResume(gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256))
    }
    func testInactiveRestoreStagingDoesNotBlockResumeAndCorruptActiveJournalStaysProtected() throws {
        let (store, identity, save) = try fixture()
        _ = try complete(store, identity, save)
        let folder = store.directory(gameID: identity.gameID)
        let staging = folder.appendingPathComponent("Restore Staging/unfinished/originals")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: save, to: staging.appendingPathComponent("game.sav"))
        XCTAssertFalse(store.hasInterruptedRestore(gameID: identity.gameID))
        XCTAssertNotNil(try store.validateForResume(gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256))
        let active = folder.appendingPathComponent("Restore")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let broken = Data("broken journal".utf8)
        try broken.write(to: active.appendingPathComponent("pending.boundrun"))
        XCTAssertThrowsError(try store.finishInterruptedRestore(gameID: identity.gameID, owner: identity.owner,
            romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertThrowsError(try store.restore(archiveURL: store.cloudURL(gameID: identity.gameID), gameID: identity.gameID,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertTrue(store.hasInterruptedRestore(gameID: identity.gameID))
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("pending.boundrun")), broken)
        XCTAssertEqual(try Data(contentsOf: save), Data(repeating: 3, count: 131_072))
    }
    func testExplicitCompletedCheckpointRestoresMatchingBatteryAndStateAndRetiresSuspension() throws {
        let (store, identity, save) = try fixture()
        _ = try writeSoul(store, identity, dead: [])
        let state = Data(repeating: 10, count: 2048)
        let receipt = try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: nil,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save, additionalFiles: ["checkpoint.state": state])
        let package = try store.commit(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            partnerReceipt: peer(receipt, identity: identity))
        XCTAssertThrowsError(try store.restoreCompletedCheckpoint(gameID: identity.gameID, checkpointID: UUID(),
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        store.setActive(true, gameID: identity.gameID)
        XCTAssertThrowsError(try store.restoreCompletedCheckpoint(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        store.setActive(false, gameID: identity.gameID)
        let workingBattery = Data(repeating: 8, count: 131_072)
        try workingBattery.write(to: save)
        let suspension = try store.captureSuspension(gameID: identity.gameID, romSHA256: identity.romSHA256,
            gameSaveURL: save, snapshot: Data(repeating: 11, count: 2048))
        let retained = store.directory(gameID: identity.gameID).appendingPathComponent("Suspensions/" + suspension.package.payload.checkpoint.uuidString + ".json")
        let originalSuspension = try Data(contentsOf: retained)
        let restored = try store.restoreCompletedCheckpoint(gameID: identity.gameID, checkpointID: package.payload.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save)
        XCTAssertEqual(restored, package)
        XCTAssertEqual(restored.payload.files["checkpoint.state"]?.data, state)
        XCTAssertEqual(try Data(contentsOf: save), package.payload.files["game.sav"]?.data)
        XCTAssertNil(try store.suspension(gameID: identity.gameID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertNotNil(try store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        let originals = try FileManager.default.contentsOfDirectory(at: store.directory(gameID: identity.gameID)
            .appendingPathComponent("Restored Originals"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(originals.first).appendingPathComponent("originals/game.sav")), workingBattery)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(originals.first).appendingPathComponent("originals/suspension.json")), originalSuspension)
    }
    func testExplicitCompletedCheckpointCannotBypassPreparedSuccessorOrNewHistory() throws {
        let (store, identity, save) = try fixture()
        let soul = try writeSoul(store, identity, dead: [])
        let first = try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: nil,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save,
            additionalFiles: ["checkpoint.state": Data(repeating: 10, count: 2048)])
        let head = try store.commit(gameID: identity.gameID, checkpointID: first.checkpoint, partnerReceipt: peer(first, identity: identity))
        try Data(repeating: 8, count: 131_072).write(to: save)
        _ = try writeSoul(store, identity, dead: ["area:9"])
        let death = try Data(contentsOf: soul)
        XCTAssertThrowsError(try store.restoreCompletedCheckpoint(gameID: identity.gameID, checkpointID: first.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertEqual(try Data(contentsOf: soul), death)
        for additions: [String: Any] in [
            ["records": [["identity": ["personality": 1, "trainer": 2], "slot": "area:4", "eligible": true]]],
            ["partnerAcquisitions": ["area:4"]], ["nextEgg": 2]
        ] {
            var journal: [String: Any] = ["run": identity.run.uuidString, "dead": [String]()]
            journal.merge(additions) { _, new in new }
            let bytes = try JSONSerialization.data(withJSONObject: journal)
            try bytes.write(to: soul)
            XCTAssertThrowsError(try store.restoreCompletedCheckpoint(gameID: identity.gameID, checkpointID: first.checkpoint,
                owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
            XCTAssertEqual(try Data(contentsOf: soul), bytes)
        }
        _ = try writeSoul(store, identity, dead: [])
        let second = try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: head.payload.checkpoint,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save,
            additionalFiles: ["checkpoint.state": Data(repeating: 11, count: 2048)])
        XCTAssertThrowsError(try store.restoreCompletedCheckpoint(gameID: identity.gameID, checkpointID: first.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertEqual(try Data(contentsOf: save), Data(repeating: 8, count: 131_072))
        XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), head)
        XCTAssertEqual(try store.checkpoint(gameID: identity.gameID, id: second.checkpoint)?.receipt, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(gameID: identity.gameID).appendingPathComponent("Restore Staging").path))
    }
    func testIncomingPackageMarkerCannotBeTreatedAsSoloOrOverwriteAnExistingRun() throws {
        let (store, identity, save) = try fixture()
        let fresh = BoundMultiplayerSaveStore(root: store.support.appendingPathComponent("new-device-packages"), support: store.support, deviceID: store.deviceID)
        _ = try fresh.stageDownload(gameID: identity.gameID, version: "download-in-progress")
        XCTAssertTrue(fresh.hasRun(gameID: identity.gameID))
        XCTAssertThrowsError(try fresh.begin(identity, gameSaveURL: save))
        XCTAssertThrowsError(try fresh.validateForResume(gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256))
        XCTAssertThrowsError(try fresh.validateCloudExport(gameID: identity.gameID))
    }
    func testExplicitEndKeepsPackagesAndNewRunArchivesOriginals() throws {
        let (store, identity, save) = try fixture()
        let package = try complete(store, identity, save)
        XCTAssertThrowsError(try store.endRun(gameID: identity.gameID))
        let journal = try writeSoul(store, identity, dead: ["area:1"])
        try JSONSerialization.data(withJSONObject: ["run": identity.run.uuidString, "ended": true, "dead": ["area:1"]]).write(to: journal)
        try store.endRun(gameID: identity.gameID)
        XCTAssertEqual(try store.manifest(gameID: identity.gameID)?.ended, true)
        XCTAssertFalse(store.hasRun(gameID: identity.gameID))
        XCTAssertNil(try store.validateForResume(gameID: identity.gameID, owner: identity.owner, romSHA256: identity.romSHA256))
        XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), package)
        XCTAssertThrowsError(try store.begin(identity, gameSaveURL: save))
        var next = identity; next.run = UUID(); next.localSeed = 10
        try store.begin(next, gameSaveURL: save)
        XCTAssertEqual(try store.manifest(gameID: identity.gameID)?.identity, next)
        let archived = store.root.appendingPathComponent("Finished Runs/" + identity.run.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.appendingPathComponent("complete.boundrun").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.appendingPathComponent("pre-run-solo.sav").path))
    }
    func testNewGameArchivesCorruptRecoveryWithoutCapturingOrRequiringSnapshot() throws {
        let (store, identity, save) = try fixture()
        let folder = store.directory(gameID: identity.gameID)
        let broken = Data("unfinished checkpoint".utf8)
        try broken.write(to: folder.appendingPathComponent("head.json"))
        let journal = try writeSoul(store, identity, dead: [])
        try Data("damaged soul journal".utf8).write(to: journal)
        let incoming = try store.stageDownload(gameID: identity.gameID, version: "unfinished")
        try broken.write(to: incoming.appendingPathComponent("complete.boundrun"))
        let restore = folder.appendingPathComponent("Restore", isDirectory: true)
        try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: true)
        try broken.write(to: restore.appendingPathComponent("pending.boundrun"))
        let originalBattery = try Data(contentsOf: save)
        XCTAssertThrowsError(try store.latestComplete(gameID: identity.gameID))
        try store.preserveForNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner, gameSaveURL: save)
        XCTAssertEqual(try store.pendingNewGame(gameID: identity.gameID), identity.run)
        XCTAssertFalse(try store.isNewGameReady(gameID: identity.gameID, run: identity.run, owner: identity.owner))
        XCTAssertEqual(try store.manifest(gameID: identity.gameID)?.ended, false, "Consent alone cannot mark a server run ended")
        try store.finishNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner)
        XCTAssertTrue(try store.isNewGameReady(gameID: identity.gameID, run: identity.run, owner: identity.owner))
        XCTAssertFalse(store.hasRun(gameID: identity.gameID))
        XCTAssertFalse(store.hasInterruptedRestore(gameID: identity.gameID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(try Data(contentsOf: save), originalBattery, "Cold boot RAM must never overwrite the old battery")
        let archive = store.root.appendingPathComponent("New Game Originals/" + identity.run.uuidString)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("Package/head.json")), broken)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("Personal/soul.json")), Data("damaged soul journal".utf8))
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("Personal/game.sav")), originalBattery)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("Package/Restore/pending.boundrun")), broken)
    }
    func testNewGameIntentSurvivesReopenAndCompletionIsIdempotent() throws {
        let (store, identity, save) = try fixture()
        let journal = try writeSoul(store, identity, dead: ["area:1"])
        try store.preserveForNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner, gameSaveURL: save)
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertEqual(try reopened.pendingNewGame(gameID: identity.gameID), identity.run)
        try reopened.finishNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner)
        // A delayed acknowledgement must not detach a fresh game's files.
        let freshJournal = Data("new game bytes".utf8)
        try freshJournal.write(to: journal)
        try reopened.finishNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner)
        XCTAssertEqual(try Data(contentsOf: journal), freshJournal)
        var next = identity; next.run = UUID(); next.localSeed = 10
        try reopened.begin(next, gameSaveURL: save)
        XCTAssertEqual(try reopened.manifest(gameID: identity.gameID)?.identity.run, next.run)
        XCTAssertNil(try reopened.pendingNewGame(gameID: identity.gameID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("Finished Runs/" + identity.run.uuidString + "/new-game-ready.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("New Game Originals/" + identity.run.uuidString + "/Personal/soul.json").path))
    }
    func testNativeNewGameAcknowledgementConsumesIntentForSoloReopen() throws {
        let (store, identity, save) = try fixture()
        XCTAssertThrowsError(try store.acknowledgeNewGameStarted(gameID: identity.gameID, run: identity.run, owner: identity.owner))
        try store.preserveForNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner, gameSaveURL: save)
        XCTAssertThrowsError(try store.acknowledgeNewGameStarted(gameID: identity.gameID, run: identity.run, owner: identity.owner))
        XCTAssertFalse(try store.hasStartedNewGame(gameID: identity.gameID, run: identity.run))
        try store.finishNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner)
        XCTAssertThrowsError(try store.acknowledgeNewGameStarted(gameID: identity.gameID, run: identity.run, owner: UUID()))
        try store.acknowledgeNewGameStarted(gameID: identity.gameID, run: identity.run, owner: identity.owner)
        // A vanilla run does not call begin(): its next cold boot must still
        // remember that the confirmed fresh game already reached Oak.
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertTrue(try reopened.hasStartedNewGame(gameID: identity.gameID, run: identity.run))
        XCTAssertTrue(try reopened.isNewGameReady(gameID: identity.gameID, run: identity.run, owner: identity.owner))
        XCTAssertEqual(try reopened.manifest(gameID: identity.gameID)?.ended, true)
        XCTAssertFalse(reopened.hasRun(gameID: identity.gameID))
        try reopened.acknowledgeNewGameStarted(gameID: identity.gameID, run: identity.run, owner: identity.owner)
    }
    func testNewGameRequiresMatchingOwnerRunDeviceAndPreservedArchive() throws {
        let (store, identity, save) = try fixture()
        XCTAssertThrowsError(try store.preserveForNewGame(gameID: identity.gameID, run: UUID(), owner: identity.owner, gameSaveURL: save))
        XCTAssertThrowsError(try store.preserveForNewGame(gameID: identity.gameID, run: identity.run, owner: UUID(), gameSaveURL: save))
        let foreign = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: UUID())
        XCTAssertThrowsError(try foreign.preserveForNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner, gameSaveURL: save))
        XCTAssertThrowsError(try store.finishNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner))
        try store.preserveForNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner, gameSaveURL: save)
        let archivedSave = store.root.appendingPathComponent("New Game Originals/" + identity.run.uuidString + "/Personal/game.sav")
        try Data("damaged archive".utf8).write(to: archivedSave)
        XCTAssertThrowsError(try store.finishNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner))
        XCTAssertEqual(try store.manifest(gameID: identity.gameID)?.ended, false)
        XCTAssertTrue(store.hasRun(gameID: identity.gameID))
    }
    func testNewGameResumesInterruptedPersonalFileRetirement() throws {
        let (store, identity, save) = try fixture()
        let journal = try writeSoul(store, identity, dead: [])
        try store.preserveForNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner, gameSaveURL: save)
        // Model a process exit after one personal file moved, before run.json
        // and the completion receipt were committed.
        let retired = store.directory(gameID: identity.gameID).appendingPathComponent("Restarted Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        let retained = retired.appendingPathComponent("interrupted-soul.json")
        try FileManager.default.moveItem(at: journal, to: retained)
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        try reopened.finishNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner)
        XCTAssertTrue(try reopened.isNewGameReady(gameID: identity.gameID, run: identity.run, owner: identity.owner))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    }
    func testIncomingSelectionUsesCheckpointAncestryAndPreservesBranches() throws {
        let (store, identity, save) = try fixture()
        let first = try complete(store, identity, save)
        let initial = try Data(contentsOf: store.cloudURL(gameID: identity.gameID))
        try Data(repeating: 4, count: 131_072).write(to: save)
        let second = try complete(store, identity, save, parent: first.payload.checkpoint)
        let fresh = BoundMultiplayerSaveStore(root: store.support.appendingPathComponent("incoming-only"), support: store.support, deviceID: store.deviceID)
        let one = try fresh.stageDownload(gameID: identity.gameID, version: "older").appendingPathComponent("complete.boundrun")
        let two = try fresh.stageDownload(gameID: identity.gameID, version: "descendant").appendingPathComponent("complete.boundrun")
        try initial.write(to: one)
        try Data(contentsOf: store.cloudURL(gameID: identity.gameID)).write(to: two)
        XCTAssertEqual(try fresh.inspectIncoming(gameID: identity.gameID)?.receipt, second.receipt)
        var branch = second
        branch.payload.checkpoint = UUID(); branch.receipt.checkpoint = branch.payload.checkpoint
        branch.receipt.payloadSHA256 = BoundMultiplayerSaveStore.hash(try BoundMultiplayerSaveStore.encode(branch.payload))
        branch.partnerReceipt?.checkpoint = branch.payload.checkpoint
        let third = try fresh.stageDownload(gameID: identity.gameID, version: "branch").appendingPathComponent("complete.boundrun")
        try BoundMultiplayerSaveStore.encode(BoundMultiplayerSaveStore.CloudArchive(checkpoints: [branch, first])).write(to: third)
        XCTAssertThrowsError(try fresh.inspectIncoming(gameID: identity.gameID))
        XCTAssertEqual(fresh.pendingImports(gameID: identity.gameID).count, 3)
    }
    func testInternalRecoverySnapshotIsHashedAndUnknownFilesAreRejected() throws {
        let (store, identity, save) = try fixture()
        XCTAssertThrowsError(try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: nil,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save, additionalFiles: ["../../credentials": Data()]))
        let state = Data(repeating: 9, count: 2048)
        let receipt = try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: nil,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save, additionalFiles: ["checkpoint.state": state])
        let package = try store.commit(gameID: identity.gameID, checkpointID: receipt.checkpoint, partnerReceipt: peer(receipt, identity: identity))
        XCTAssertEqual(package.payload.files["checkpoint.state"]?.data, state)
        XCTAssertEqual(package.payload.files["checkpoint.state"]?.sha256, BoundMultiplayerSaveStore.hash(state))
    }
    func testLocalSuspensionSurvivesCrashWithoutPublishingIncompleteProgress() throws {
        let (store, identity, save) = try fixture()
        _ = try writeSoul(store, identity, dead: ["area:2"])
        let state = Data(repeating: 11, count: 2048)
        let suspended = try store.captureSuspension(gameID: identity.gameID, romSHA256: identity.romSHA256,
            gameSaveURL: save, snapshot: state)
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertEqual(try reopened.validateSuspensionForResume(gameID: identity.gameID, owner: identity.owner,
            romSHA256: identity.romSHA256, gameSaveURL: save), suspended)
        XCTAssertEqual(try reopened.suspension(gameID: identity.gameID)?.snapshot, state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cloudURL(gameID: identity.gameID).path))
        XCTAssertTrue(try store.preparedCheckpoints(gameID: identity.gameID).isEmpty)
        _ = try store.captureSuspension(gameID: identity.gameID, romSHA256: identity.romSHA256,
            gameSaveURL: save, snapshot: Data(repeating: 12, count: 2048))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory(gameID: identity.gameID).appendingPathComponent("Suspensions").path).count, 2)
    }
    func testSuspensionCannotMixROMOrEraseNewDeathsAndNewCheckpointSupersedesIt() throws {
        let (store, identity, save) = try fixture()
        let journal = try writeSoul(store, identity, dead: [])
        let state = Data(repeating: 11, count: 2048)
        XCTAssertThrowsError(try store.captureSuspension(gameID: identity.gameID, romSHA256: String(repeating: "e", count: 64), gameSaveURL: save, snapshot: state))
        _ = try store.captureSuspension(gameID: identity.gameID, romSHA256: identity.romSHA256, gameSaveURL: save, snapshot: state)
        XCTAssertThrowsError(try store.validateSuspensionForResume(gameID: identity.gameID, owner: identity.owner,
            romSHA256: String(repeating: "e", count: 64), gameSaveURL: save))
        _ = try writeSoul(store, identity, dead: ["area:2"])
        let permanentDeath = try Data(contentsOf: journal)
        XCTAssertNotNil(try store.validateSuspensionForResume(gameID: identity.gameID, owner: identity.owner,
            romSHA256: identity.romSHA256, gameSaveURL: save), "Background deaths cannot block the player's matching local snapshot")
        XCTAssertEqual(try Data(contentsOf: journal), permanentDeath)
        let updated = try store.captureSuspension(gameID: identity.gameID, romSHA256: identity.romSHA256, gameSaveURL: save, snapshot: state)
        XCTAssertEqual(updated.package.payload.files["soul.json"]?.data, permanentDeath)
        _ = try complete(store, identity, save)
        XCTAssertNil(try store.suspension(gameID: identity.gameID))
    }
    func testCheckpointResumeValidatesPreparedAndCompletePersonalFilesBeforePeerMerge() throws {
        let (store, identity, save) = try fixture()
        let journal = try writeSoul(store, identity, dead: [])
        let setup = Data("{\"accepted\":true}".utf8)
        let setupURL = store.directory(gameID: identity.gameID).appendingPathComponent("setup.json")
        try setup.write(to: setupURL)
        let state = Data(repeating: 13, count: 2048)
        let receipt = try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: nil,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save,
            additionalFiles: ["checkpoint.state": state, "setup.json": setup])
        XCTAssertEqual(try store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save)?.receipt, receipt)
        let complete = try store.commit(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            partnerReceipt: peer(receipt, identity: identity))
        let validated = try XCTUnwrap(store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertEqual(validated, complete)
        XCTAssertThrowsError(try store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            owner: UUID(), romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertThrowsError(try store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            owner: identity.owner, romSHA256: String(repeating: "e", count: 64), gameSaveURL: save))
        _ = try writeSoul(store, identity, dead: ["peer:area:3"])
        let merged = try Data(contentsOf: journal)
        XCTAssertEqual(validated.payload.files["checkpoint.state"]?.data, state)
        XCTAssertThrowsError(try store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertEqual(try Data(contentsOf: journal), merged)
        XCTAssertEqual(try store.checkpoint(gameID: identity.gameID, id: receipt.checkpoint), complete)
    }
    func testCheckpointResumeRejectsUnexpectedJournalAndChangedSetupWithoutRewritingEither() throws {
        let (store, identity, save) = try fixture()
        let setup = Data("{\"accepted\":true}".utf8)
        let setupURL = store.directory(gameID: identity.gameID).appendingPathComponent("setup.json")
        try setup.write(to: setupURL)
        let receipt = try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: nil,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save,
            additionalFiles: ["checkpoint.state": Data(repeating: 13, count: 2048), "setup.json": setup])
        let journal = try writeSoul(store, identity, dead: ["area:5"])
        XCTAssertThrowsError(try store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])?["dead"] as? [String], ["area:5"])
        try FileManager.default.removeItem(at: journal)
        let changedSetup = Data("{\"accepted\":false}".utf8)
        try changedSetup.write(to: setupURL)
        XCTAssertThrowsError(try store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertEqual(try Data(contentsOf: setupURL), changedSetup)
    }
    func testCompletedRestoreRestoresSetupForReadyHandshakeReplay() throws {
        let (store, identity, save) = try fixture()
        let setup = Data("{\"accepted\":true,\"peerReady\":true}".utf8)
        let setupURL = store.directory(gameID: identity.gameID).appendingPathComponent("setup.json")
        try setup.write(to: setupURL)
        let receipt = try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: nil,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save,
            additionalFiles: ["checkpoint.state": Data(repeating: 13, count: 2048), "setup.json": setup])
        _ = try store.commit(gameID: identity.gameID, checkpointID: receipt.checkpoint, partnerReceipt: peer(receipt, identity: identity))
        try FileManager.default.removeItem(at: setupURL)
        try store.restore(archiveURL: store.cloudURL(gameID: identity.gameID), gameID: identity.gameID,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save)
        XCTAssertEqual(try Data(contentsOf: setupURL), setup)
        XCTAssertNotNil(try store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
    }
    func testTwoPersonalStoresRecoverLostCommitReceiptWithoutDuplicatingHistory() throws {
        let (first, firstIdentity, firstSave) = try fixture()
        let secondFolder = first.support.appendingPathComponent("partner-device", isDirectory: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let secondSave = secondFolder.appendingPathComponent("game.sav")
        try Data(repeating: 8, count: 131_072).write(to: secondSave)
        var secondIdentity = firstIdentity
        secondIdentity.owner = firstIdentity.partner; secondIdentity.partner = firstIdentity.owner
        secondIdentity.localSeed = firstIdentity.partnerSeed; secondIdentity.partnerSeed = firstIdentity.localSeed
        let second = BoundMultiplayerSaveStore(root: secondFolder.appendingPathComponent("packages"), support: secondFolder, deviceID: UUID())
        try second.begin(secondIdentity, gameSaveURL: secondSave)
        let firstJournal = try writeSoul(first, firstIdentity, dead: ["area:6"])
        let secondJournal = try writeSoul(second, secondIdentity, dead: ["area:6"])
        let history = String(repeating: "d", count: 64), checkpoint = UUID()
        let firstReceipt = try first.prepare(gameID: firstIdentity.gameID, checkpointID: checkpoint, predecessor: nil,
            sharedEventDigest: history, gameSaveURL: firstSave, additionalFiles: ["checkpoint.state": Data(repeating: 1, count: 2048)])
        let secondReceipt = try second.prepare(gameID: secondIdentity.gameID, checkpointID: checkpoint, predecessor: nil,
            sharedEventDigest: history, gameSaveURL: secondSave, additionalFiles: ["checkpoint.state": Data(repeating: 2, count: 2048)])
        XCTAssertNotEqual(firstReceipt.payloadSHA256, secondReceipt.payloadSHA256)
        let firstComplete = try first.commit(gameID: firstIdentity.gameID, checkpointID: checkpoint, partnerReceipt: secondReceipt)
        // The final packet is lost and both processes exit. The completed peer
        // retransmits its own durable receipt, which finishes the prepared peer.
        let reopenedFirst = BoundMultiplayerSaveStore(root: first.root, support: first.support, deviceID: first.deviceID)
        let reopenedSecond = BoundMultiplayerSaveStore(root: second.root, support: second.support, deviceID: second.deviceID)
        XCTAssertEqual(try reopenedFirst.latestComplete(gameID: firstIdentity.gameID), firstComplete)
        XCTAssertNil(try reopenedSecond.latestComplete(gameID: secondIdentity.gameID))
        XCTAssertEqual(try reopenedSecond.preparedCheckpoints(gameID: secondIdentity.gameID).map(\.receipt), [secondReceipt])
        let secondComplete = try reopenedSecond.commit(gameID: secondIdentity.gameID, checkpointID: checkpoint,
            partnerReceipt: try XCTUnwrap(reopenedFirst.latestComplete(gameID: firstIdentity.gameID)).receipt)
        let firstBytes = try Data(contentsOf: firstJournal), secondBytes = try Data(contentsOf: secondJournal)
        for _ in 0..<3 {
            XCTAssertEqual(try reopenedFirst.commit(gameID: firstIdentity.gameID, checkpointID: checkpoint,
                partnerReceipt: secondComplete.receipt), firstComplete)
            XCTAssertEqual(try reopenedSecond.commit(gameID: secondIdentity.gameID, checkpointID: checkpoint,
                partnerReceipt: firstComplete.receipt), secondComplete)
        }
        XCTAssertEqual(try Data(contentsOf: firstJournal), firstBytes)
        XCTAssertEqual(try Data(contentsOf: secondJournal), secondBytes)
        XCTAssertEqual(try Data(contentsOf: firstSave), Data(repeating: 3, count: 131_072))
        XCTAssertEqual(try Data(contentsOf: secondSave), Data(repeating: 8, count: 131_072))
        XCTAssertTrue(try reopenedFirst.preparedCheckpoints(gameID: firstIdentity.gameID).isEmpty)
        XCTAssertTrue(try reopenedSecond.preparedCheckpoints(gameID: secondIdentity.gameID).isEmpty)
    }
    func testSuspensionRetentionKeepsLatestThreeAndOlderUnresolvedNativeRecovery() throws {
        let (store, identity, save) = try fixture()
        let folder = store.support.appendingPathComponent("Friend Battles", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString, state = Data(repeating: 7, count: 2048)
        let stateURL = folder.appendingPathComponent(id + ".state"), journalURL = folder.appendingPathComponent(id + ".json")
        try state.write(to: stateURL)
        try JSONSerialization.data(withJSONObject: ["gameID": identity.gameID, "rom": identity.romSHA256,
            "state": id + ".state", "sha256": BoundMultiplayerSaveStore.hash(state)]).write(to: journalURL)
        let recovery = try store.captureSuspension(gameID: identity.gameID, romSHA256: identity.romSHA256,
            gameSaveURL: save, snapshot: Data(repeating: 1, count: 2048))
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.removeItem(at: journalURL)
        var captures: [BoundMultiplayerSaveStore.Suspension] = []
        for byte in UInt8(2)...6 {
            captures.append(try store.captureSuspension(gameID: identity.gameID, romSHA256: identity.romSHA256,
                gameSaveURL: save, snapshot: Data(repeating: byte, count: 2048)))
        }
        let snapshots = store.directory(gameID: identity.gameID).appendingPathComponent("Suspensions")
        let retained = try Set(FileManager.default.contentsOfDirectory(atPath: snapshots.path))
        let expected = Set((captures.suffix(3).map { $0.package.payload.checkpoint } + [recovery.package.payload.checkpoint]).map { $0.uuidString + ".json" })
        XCTAssertEqual(retained, expected)
        XCTAssertEqual(try store.suspension(gameID: identity.gameID), captures.last)
        let old = try JSONDecoder().decode(BoundMultiplayerSaveStore.Suspension.self,
            from: Data(contentsOf: snapshots.appendingPathComponent(recovery.package.payload.checkpoint.uuidString + ".json")))
        XCTAssertEqual(old.package.payload.files["recovery/" + id + ".state"]?.data, state)
    }
    func testWorkingRevisionIncludesVictoryAndMemorialChangesAndOnlyThisGamesRecovery() throws {
        let (store, identity, _) = try fixture()
        let initial = try store.workingRevision(gameID: identity.gameID)
        let soul = try writeSoul(store, identity, dead: ["area:3"])
        let death = try store.workingRevision(gameID: identity.gameID)
        XCTAssertNotEqual(initial, death)
        try JSONSerialization.data(withJSONObject: ["run": identity.run.uuidString, "dead": ["area:3"],
            "memorials": [["slot": "area:3", "announced": true]]]).write(to: soul)
        let memorial = try store.workingRevision(gameID: identity.gameID)
        XCTAssertNotEqual(death, memorial)
        let timeline = soul.deletingPathExtension().appendingPathExtension("timeline.json")
        try JSONSerialization.data(withJSONObject: ["events": [["id": "victory:1"]]]).write(to: timeline)
        let victory = try store.workingRevision(gameID: identity.gameID)
        XCTAssertNotEqual(memorial, victory)
        let folder = store.support.appendingPathComponent("Friend Battles", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString, journal = folder.appendingPathComponent(id + ".json")
        var values = ["gameID": "unrelated", "rom": identity.romSHA256, "state": id + ".state",
                      "sha256": String(repeating: "a", count: 64)]
        try JSONSerialization.data(withJSONObject: values).write(to: journal)
        XCTAssertEqual(try store.workingRevision(gameID: identity.gameID), victory)
        values["gameID"] = identity.gameID
        try JSONSerialization.data(withJSONObject: values).write(to: journal)
        XCTAssertNotEqual(try store.workingRevision(gameID: identity.gameID), victory)
    }
    func testEndedRunIgnoresItsOldDownloadsAndInspectsDifferentRunWithoutAdoptingIt() throws {
        let (store, identity, save) = try fixture()
        _ = try complete(store, identity, save)
        let original = try Data(contentsOf: store.cloudURL(gameID: identity.gameID))
        let journal = try writeSoul(store, identity, dead: [])
        try JSONSerialization.data(withJSONObject: ["run": identity.run.uuidString, "ended": true, "dead": []]).write(to: journal)
        try store.endRun(gameID: identity.gameID)
        let stale = try store.stageDownload(gameID: identity.gameID, version: "old").appendingPathComponent("complete.boundrun")
        try original.write(to: stale)
        XCTAssertNil(try store.inspectIncoming(gameID: identity.gameID))
        XCTAssertFalse(store.hasRun(gameID: identity.gameID))
        var newer = try JSONDecoder().decode(BoundMultiplayerSaveStore.CloudArchive.self, from: original)
        let nextRun = UUID()
        newer.checkpoints[0].payload.manifest.identity.run = nextRun
        newer.checkpoints[0].receipt.run = nextRun
        newer.checkpoints[0].partnerReceipt?.run = nextRun
        newer.checkpoints[0].receipt.payloadSHA256 = BoundMultiplayerSaveStore.hash(try BoundMultiplayerSaveStore.encode(newer.checkpoints[0].payload))
        let next = try store.stageDownload(gameID: identity.gameID, version: "new", run: nextRun).appendingPathComponent("complete.boundrun")
        XCTAssertTrue(store.hasRun(gameID: identity.gameID))
        try BoundMultiplayerSaveStore.encode(newer).write(to: next)
        XCTAssertTrue(store.hasRun(gameID: identity.gameID))
        XCTAssertEqual(try store.inspectIncoming(gameID: identity.gameID)?.manifest.identity.run, newer.checkpoints[0].payload.manifest.identity.run)
        XCTAssertThrowsError(try store.restore(archiveURL: next, gameID: identity.gameID,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertEqual(try store.manifest(gameID: identity.gameID)?.identity.run, identity.run)
        XCTAssertEqual(try Data(contentsOf: save), Data(repeating: 3, count: 131_072))
    }
    func testIndependentSaveCompletesOfflineAndMigratesPairedHistoryWithoutPartnerReceipt() throws {
        let (store, identity, save) = try fixture()
        let legacy = try complete(store, identity, save)
        try Data(repeating: 9, count: 131_072).write(to: save)
        let id = UUID(), digest = String(repeating: "d", count: 64)
        let local = try store.saveLocal(gameID: identity.gameID, checkpointID: id, sharedEventDigest: digest,
            gameSaveURL: save, additionalFiles: ["checkpoint.state": Data(repeating: 4, count: 2048)])
        XCTAssertTrue(local.complete)
        XCTAssertEqual(local.payload.version, 2)
        XCTAssertNil(local.partnerReceipt)
        XCTAssertEqual(local.payload.predecessor, legacy.payload.checkpoint)
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertEqual(try reopened.latestComplete(gameID: identity.gameID), local)
        XCTAssertEqual(try reopened.saveLocal(gameID: identity.gameID, checkpointID: id,
            sharedEventDigest: digest, gameSaveURL: save), local)
        XCTAssertEqual(try reopened.validateCheckpointForResume(gameID: identity.gameID, checkpointID: id,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save), local)
        let archive = try JSONDecoder().decode(BoundMultiplayerSaveStore.CloudArchive.self,
            from: Data(contentsOf: store.cloudURL(gameID: identity.gameID)))
        XCTAssertEqual(archive.checkpoints, [local, legacy])
        XCTAssertEqual(try reopened.checkpoint(gameID: identity.gameID, id: legacy.payload.checkpoint), legacy)
    }
    func testEventOutboxPersistsBeforeTransmissionAndIdempotencyDoesNotAllocateAnotherSequence() throws {
        let (store, identity, _) = try fixture()
        let first = try store.appendSharedEvent(gameID: identity.gameID, kind: "death", payload: Data("area:9".utf8), idempotencyKey: "death:area:9")
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertEqual(try reopened.sharedEventsToSend(gameID: identity.gameID), [first])
        XCTAssertEqual(try reopened.appendSharedEvent(gameID: identity.gameID, kind: "death", payload: first.payload,
            idempotencyKey: "death:area:9"), first)
        XCTAssertEqual(try reopened.journal(gameID: identity.gameID).nextSequence, 2)
        XCTAssertThrowsError(try reopened.appendSharedEvent(gameID: identity.gameID, kind: "death", payload: Data(), idempotencyKey: "death:area:9"))
        XCTAssertTrue(try reopened.pendingSharedEventsToApply(gameID: identity.gameID).isEmpty)
    }
    func testIndependentResumeStillValidatesAccountDeviceROMAndImmutableConfiguration() throws {
        let (store, identity, save) = try fixture()
        let package = try store.saveLocal(gameID: identity.gameID, sharedEventDigest: String(repeating: "d", count: 64),
            gameSaveURL: save, additionalFiles: ["checkpoint.state": Data(repeating: 7, count: 2048)])
        XCTAssertThrowsError(try store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: package.payload.checkpoint,
            owner: UUID(), romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertThrowsError(try store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: package.payload.checkpoint,
            owner: identity.owner, romSHA256: String(repeating: "f", count: 64), gameSaveURL: save))
        let foreign = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: UUID())
        XCTAssertThrowsError(try foreign.validateCheckpointForResume(gameID: identity.gameID, checkpointID: package.payload.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        let manifestURL = store.directory(gameID: identity.gameID).appendingPathComponent("run.json")
        let original = try Data(contentsOf: manifestURL)
        for changed in ["seed", "partner", "run", "game"] {
            var manifest = try XCTUnwrap(store.manifest(gameID: identity.gameID))
            switch changed {
            case "seed": manifest.identity.localSeed = 9
            case "partner": manifest.identity.partner = UUID()
            case "run": manifest.identity.run = UUID()
            default: manifest.identity.gameID = "another-game"
            }
            try BoundMultiplayerSaveStore.encode(manifest).write(to: manifestURL)
            XCTAssertThrowsError(try store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: package.payload.checkpoint,
                owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save))
            try original.write(to: manifestURL)
        }
        XCTAssertEqual(try store.validateCheckpointForResume(gameID: identity.gameID, checkpointID: package.payload.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save), package)
    }
    func testEndedOutboxSurvivesNewGameArchivalAndStillAcceptsDurablePartnerAcknowledgements() throws {
        let (store, identity, save) = try fixture()
        let ended = try store.appendSharedEvent(gameID: identity.gameID, kind: "soul-link", payload: Data("ended".utf8), idempotencyKey: "ended")
        let soul = try writeSoul(store, identity, dead: [])
        try JSONSerialization.data(withJSONObject: ["run": identity.run.uuidString, "ended": true, "dead": []]).write(to: soul)
        try store.endRun(gameID: identity.gameID)
        XCTAssertEqual(try store.sharedEventsToSend(gameID: identity.gameID), [ended])
        XCTAssertEqual(try store.sharedEventAcknowledgement(gameID: identity.gameID).run, identity.run)
        XCTAssertThrowsError(try store.appendSharedEvent(gameID: identity.gameID, kind: "death", payload: Data()))
        try store.preserveForNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner, gameSaveURL: save)
        try store.finishNewGame(gameID: identity.gameID, run: identity.run, owner: identity.owner)
        var next = identity; next.run = UUID()
        try store.begin(next, gameSaveURL: save)
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertEqual(try reopened.pendingSharedRunIdentities(gameID: identity.gameID), [identity])
        XCTAssertEqual(try reopened.sharedEventsToSend(gameID: identity.gameID, identity: identity), [ended])
        XCTAssertTrue(try reopened.journal(gameID: identity.gameID).events.isEmpty)
        let otherDevice = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: UUID())
        XCTAssertThrowsError(try otherDevice.journal(gameID: identity.gameID, identity: identity))
        var cursor = BoundMultiplayerSharedCursor(); cursor.insert(ended.id)
        try reopened.acknowledgeSharedEvents(gameID: identity.gameID,
            acknowledgement: .init(run: identity.run, receiver: identity.partner, cursor: cursor), identity: identity)
        XCTAssertTrue(try reopened.pendingSharedRunIdentities(gameID: identity.gameID).isEmpty)
        XCTAssertTrue(try reopened.sharedEventsToSend(gameID: identity.gameID, identity: identity).isEmpty)
        XCTAssertEqual(try reopened.manifest(gameID: identity.gameID)?.identity.run, next.run)
    }
    func testEventReceiptsKeepGapsAndDurableNativeReplaySurvivesCrashAndDuplicateDelivery() throws {
        let (store, identity, _) = try fixture()
        func event(_ sequence: UInt64) -> BoundMultiplayerSharedEvent {
            .init(run: identity.run, id: .init(origin: identity.partner, sequence: sequence), kind: "death",
                  payload: Data("area:\(sequence)".utf8))
        }
        let second = event(2), first = event(1)
        XCTAssertTrue(try store.receiveSharedEvent(gameID: identity.gameID, event: second))
        let ack = try store.sharedEventAcknowledgement(gameID: identity.gameID)
        XCTAssertEqual(ack.cursor.origins[identity.partner.uuidString]?.contiguous, 0)
        XCTAssertEqual(ack.cursor.origins[identity.partner.uuidString]?.sparse, [2])
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertEqual(try reopened.pendingSharedEventsToApply(gameID: identity.gameID), [second])
        XCTAssertFalse(try reopened.receiveSharedEvent(gameID: identity.gameID, event: second))
        try reopened.markSharedEventApplied(gameID: identity.gameID, eventID: second.id)
        XCTAssertTrue(try reopened.receiveSharedEvent(gameID: identity.gameID, event: first))
        XCTAssertEqual(try reopened.sharedEventAcknowledgement(gameID: identity.gameID).cursor.origins[identity.partner.uuidString]?.contiguous, 2)
        XCTAssertEqual(try reopened.pendingSharedEventsToApply(gameID: identity.gameID), [first])
        var conflicting = second; conflicting.payload = Data("changed".utf8)
        XCTAssertThrowsError(try reopened.receiveSharedEvent(gameID: identity.gameID, event: conflicting))
        var foreign = event(3); foreign.run = UUID()
        XCTAssertThrowsError(try reopened.receiveSharedEvent(gameID: identity.gameID, event: foreign))
        XCTAssertEqual(try reopened.pendingSharedEventsToApply(gameID: identity.gameID), [first])
    }
    func testAuthoritativeOwnHistoryReplaysBeforeResumeAndNeverReusesAnImportedEventIdentity() throws {
        let (store, identity, _) = try fixture()
        let event = BoundMultiplayerSharedEvent(run: identity.run, id: .init(origin: identity.owner, sequence: 2),
            kind: "soul-link", payload: Data("older-device-death".utf8), idempotencyKey: "death:area:8")
        XCTAssertThrowsError(try store.receiveSharedEvent(gameID: identity.gameID, event: event))
        XCTAssertTrue(try store.receiveAuthoritativeSharedEvent(gameID: identity.gameID, event: event))
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertEqual(try reopened.pendingSharedEventsToApply(gameID: identity.gameID), [event])
        XCTAssertEqual(try reopened.journal(gameID: identity.gameID).received.origins[identity.owner.uuidString]?.sparse, [2])
        XCTAssertEqual(try reopened.journal(gameID: identity.gameID).nextSequence, 3)
        XCTAssertFalse(try reopened.receiveAuthoritativeSharedEvent(gameID: identity.gameID, event: event))
        var changed = event; changed.payload = Data()
        XCTAssertThrowsError(try reopened.receiveAuthoritativeSharedEvent(gameID: identity.gameID, event: changed))
        try reopened.markSharedEventApplied(gameID: identity.gameID, eventID: event.id)
        let next = try reopened.appendSharedEvent(gameID: identity.gameID, kind: "soul-link", payload: Data([3]))
        XCTAssertEqual(next.id.sequence, 3)
        XCTAssertTrue(try reopened.pendingSharedEventsToApply(gameID: identity.gameID).isEmpty)
    }
    func testTransferredHistoryTargetIsDurableFiniteAndRequiresAppliedReceiptsFromBothOrigins() throws {
        let (store, identity, _) = try fixture()
        var manifest = try XCTUnwrap(store.manifest(gameID: identity.gameID)); manifest.requiresInitialHistorySync = true
        try BoundMultiplayerSaveStore.encode(manifest).write(to: store.directory(gameID: identity.gameID).appendingPathComponent("run.json"))
        let own = BoundMultiplayerSharedEvent(run: identity.run, id: .init(origin: identity.owner, sequence: 1), kind: "soul-link", payload: Data([1]))
        let peer = BoundMultiplayerSharedEvent(run: identity.run, id: .init(origin: identity.partner, sequence: 1), kind: "soul-link", payload: Data([2]))
        var target = BoundMultiplayerSharedCursor(); target.insert(own.id); target.insert(peer.id)
        XCTAssertEqual(try store.setInitialHistoryTarget(gameID: identity.gameID, target: target), target)
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertTrue(try XCTUnwrap(reopened.manifest(gameID: identity.gameID)).requiresInitialHistorySync)
        var newer = target; newer.insert(.init(origin: identity.partner, sequence: 2))
        XCTAssertEqual(try reopened.setInitialHistoryTarget(gameID: identity.gameID, target: newer), target)
        XCTAssertThrowsError(try reopened.completeInitialHistorySync(gameID: identity.gameID))
        try reopened.receiveAuthoritativeSharedEvent(gameID: identity.gameID, event: own)
        try reopened.receiveAuthoritativeSharedEvent(gameID: identity.gameID, event: peer)
        try reopened.markSharedEventApplied(gameID: identity.gameID, eventID: peer.id)
        XCTAssertThrowsError(try reopened.completeInitialHistorySync(gameID: identity.gameID), "Own-origin saved deaths also require replay")
        try reopened.markSharedEventApplied(gameID: identity.gameID, eventID: own.id)
        let complete = try reopened.completeInitialHistorySync(gameID: identity.gameID)
        XCTAssertFalse(complete.requiresInitialHistorySync); XCTAssertNil(complete.initialHistoryTarget)
    }
    func testAcknowledgementsAreDurableAndMissingEarlierEventsRetryUntilAcknowledged() throws {
        let (store, identity, _) = try fixture()
        let first = try store.appendSharedEvent(gameID: identity.gameID, kind: "catch", payload: Data([1]))
        let second = try store.appendSharedEvent(gameID: identity.gameID, kind: "death", payload: Data([2]))
        var cursor = BoundMultiplayerSharedCursor(); cursor.insert(second.id)
        let partial = BoundMultiplayerSharedAcknowledgement(run: identity.run, receiver: identity.partner, cursor: cursor)
        try store.acknowledgeSharedEvents(gameID: identity.gameID, acknowledgement: partial)
        let reopened = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: store.deviceID)
        XCTAssertEqual(try reopened.sharedEventsToSend(gameID: identity.gameID), [first])
        cursor.insert(first.id)
        try reopened.acknowledgeSharedEvents(gameID: identity.gameID,
            acknowledgement: .init(run: identity.run, receiver: identity.partner, cursor: cursor))
        XCTAssertTrue(try reopened.sharedEventsToSend(gameID: identity.gameID).isEmpty)
        try reopened.acknowledgeSharedEvents(gameID: identity.gameID, acknowledgement: partial)
        XCTAssertTrue(try reopened.sharedEventsToSend(gameID: identity.gameID).isEmpty, "An old acknowledgement cannot regress the outbox")
        var wrong = partial; wrong.run = UUID()
        XCTAssertThrowsError(try reopened.acknowledgeSharedEvents(gameID: identity.gameID, acknowledgement: wrong))
        cursor.insert(.init(origin: identity.owner, sequence: 8))
        XCTAssertThrowsError(try reopened.acknowledgeSharedEvents(gameID: identity.gameID,
            acknowledgement: .init(run: identity.run, receiver: identity.partner, cursor: cursor)))
    }
    func testRestoringOlderIndependentSaveRetainsPermanentLossesPendingEventsAndLocalSequence() throws {
        let (store, identity, save) = try fixture()
        let stem = BoundMultiplayerSaveStore.hash(Data(identity.gameID.utf8))
        let soulURL = store.support.appendingPathComponent("Soul Link/" + stem + ".json")
        try FileManager.default.createDirectory(at: soulURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var ledger = BoundSoulLedger(run: identity.run, binding: String(repeating: "b", count: 64))
        try JSONEncoder().encode(ledger).write(to: soulURL)
        let old = try store.saveLocal(gameID: identity.gameID, sharedEventDigest: String(repeating: "c", count: 64),
            gameSaveURL: save, additionalFiles: ["checkpoint.state": Data(repeating: 10, count: 2048)])
        ledger.dead.insert("area:9")
        try JSONEncoder().encode(ledger).write(to: soulURL)
        let local = try store.appendSharedEvent(gameID: identity.gameID, kind: "death", payload: Data("area:9".utf8))
        let remote = BoundMultiplayerSharedEvent(run: identity.run, id: .init(origin: identity.partner, sequence: 2),
            kind: "death", payload: Data("area:10".utf8))
        try store.receiveSharedEvent(gameID: identity.gameID, event: remote)
        try Data(repeating: 8, count: 131_072).write(to: save)
        _ = try store.saveLocal(gameID: identity.gameID, sharedEventDigest: String(repeating: "d", count: 64),
            gameSaveURL: save, additionalFiles: ["checkpoint.state": Data(repeating: 11, count: 2048)])
        _ = try store.restoreCompletedCheckpoint(gameID: identity.gameID, checkpointID: old.payload.checkpoint,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save)
        XCTAssertEqual(try Data(contentsOf: save), old.payload.files["game.sav"]?.data)
        XCTAssertTrue(try JSONDecoder().decode(BoundSoulLedger.self, from: Data(contentsOf: soulURL)).dead.contains("area:9"))
        XCTAssertEqual(try store.sharedEventsToSend(gameID: identity.gameID), [local])
        XCTAssertEqual(try store.pendingSharedEventsToApply(gameID: identity.gameID), [remote])
        let next = try store.appendSharedEvent(gameID: identity.gameID, kind: "catch", payload: Data("area:20".utf8))
        XCTAssertEqual(next.id.sequence, 2, "Loading an older checkpoint cannot reuse an event identity")
        XCTAssertEqual(try store.journal(gameID: identity.gameID).received.origins[identity.partner.uuidString]?.sparse, [2])
    }
#if canImport(Delta)
    @MainActor
    func testOwnershipAdoptionRetagsCurrentSuspensionAndRetriesInterruptedManifestWrite() async throws {
        let (store, identity, save) = try fixture()
        _ = try writeSoul(store, identity, dead: [])
        let receipt = try store.prepare(gameID: identity.gameID, checkpointID: UUID(), predecessor: nil,
            sharedEventDigest: String(repeating: "c", count: 64), gameSaveURL: save,
            additionalFiles: ["checkpoint.state": Data(repeating: 10, count: 2048)])
        let package = try store.commit(gameID: identity.gameID, checkpointID: receipt.checkpoint,
            partnerReceipt: peer(receipt, identity: identity))
        let originalManifest = try XCTUnwrap(store.manifest(gameID: identity.gameID))
        try Data(repeating: 8, count: 131_072).write(to: save)
        let snapshot = Data(repeating: 11, count: 2048)
        let oldSuspension = try store.captureSuspension(gameID: identity.gameID, romSHA256: identity.romSHA256,
            gameSaveURL: save, snapshot: snapshot)
        let suspensionURL = store.directory(gameID: identity.gameID).appendingPathComponent("Suspensions/" + oldSuspension.package.payload.checkpoint.uuidString + ".json")
        let originalSuspension = try Data(contentsOf: suspensionURL)
        let current = BoundMultiplayerSaveStore(root: store.root, support: store.support, deviceID: UUID())
        let payload = try JSONSerialization.data(withJSONObject: BoundAccountTestFixture.claims(owner: identity.owner, expiry: Date().timeIntervalSince1970 + 3600))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let session = try AppCloudSession(owner: identity.owner, key: "fixture", token: "fixture." + payload + ".signature")
        let device = current.deviceID, owner = identity.owner, run = identity.run
        let client = BoundRunLeaseClient(perform: { _ in
            let now = Date().timeIntervalSince1970
            return try JSONSerialization.data(withJSONObject: ["ok": true, "ownerID": owner.uuidString,
                "runID": run.uuidString, "deviceID": device.uuidString, "token": UUID().uuidString,
                "fence": "2", "serverTime": now, "expiresAt": now + 60, "anchorVersion": "2",
                "checkpointID": package.payload.checkpoint.uuidString, "checkpointHistory": package.payload.sharedEventDigest,
                "historyDigest": package.payload.sharedEventDigest])
        }, device: { device })
        let grant = try await client.acquire(runID: run, session: session, allowTransfer: true)
        let adopted = try current.adoptOwnership(gameID: identity.gameID, grant: grant)
        XCTAssertEqual(adopted.deviceOwner, device)
        var resumed = try XCTUnwrap(current.validateSuspensionForResume(gameID: identity.gameID,
            owner: owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertEqual(resumed.manifest.deviceOwner, device)
        XCTAssertEqual(resumed.snapshot, snapshot)
        XCTAssertEqual(resumed.package.payload.checkpoint, oldSuspension.package.payload.checkpoint)
        XCTAssertEqual(resumed.package.payload.files, oldSuspension.package.payload.files)
        let archiveRoot = store.directory(gameID: identity.gameID).appendingPathComponent("Ownership Transfers")
        let archives = try FileManager.default.contentsOfDirectory(at: archiveRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(try Data(contentsOf: archives[0].appendingPathComponent(suspensionURL.lastPathComponent)), originalSuspension)
        // Simulate interruption after the suspension write but before run.json.
        try BoundMultiplayerSaveStore.encode(originalManifest).write(to: store.directory(gameID: identity.gameID).appendingPathComponent("run.json"))
        XCTAssertEqual(try current.adoptOwnership(gameID: identity.gameID, grant: grant).deviceOwner, device)
        resumed = try XCTUnwrap(current.validateSuspensionForResume(gameID: identity.gameID,
            owner: owner, romSHA256: identity.romSHA256, gameSaveURL: save))
        XCTAssertEqual(resumed.snapshot, snapshot)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: archiveRoot.path).count, 1)
        _ = try current.captureSuspension(gameID: identity.gameID, romSHA256: identity.romSHA256, gameSaveURL: save, snapshot: snapshot)
        XCTAssertEqual(try current.latestComplete(gameID: identity.gameID), package, "Peer checkpoint receipts remain immutable")
        _ = try current.restoreCompletedCheckpoint(gameID: identity.gameID, checkpointID: package.payload.checkpoint,
            owner: owner, romSHA256: identity.romSHA256, gameSaveURL: save)
        XCTAssertEqual(try current.manifest(gameID: identity.gameID)?.deviceOwner, device)
        // Replay the active-transaction shape after a later ordinary acquisition,
        // whose grant no longer carries the original transfer permission.
        let restored = try FileManager.default.contentsOfDirectory(at: current.directory(gameID: identity.gameID)
            .appendingPathComponent("Restored Originals"), includingPropertiesForKeys: nil)
        let transaction = current.directory(gameID: identity.gameID).appendingPathComponent("Restore")
        try FileManager.default.copyItem(at: XCTUnwrap(restored.first), to: transaction)
        try Data(repeating: 9, count: 131_072).write(to: save)
        let ordinary = try await client.acquire(runID: run, session: session)
        try current.finishInterruptedRestore(gameID: identity.gameID, owner: owner,
            romSHA256: identity.romSHA256, gameSaveURL: save, grant: ordinary)
        XCTAssertEqual(try current.manifest(gameID: identity.gameID)?.deviceOwner, device)
        XCTAssertEqual(try Data(contentsOf: save), package.payload.files["game.sav"]?.data)
    }
    @MainActor
    func testAnchoredTransferArchivesEndedRunAndPreservesItsPersonalFiles() async throws {
        let (store, identity, save) = try fixture()
        _ = try complete(store, identity, save)
        let oldSoul = try writeSoul(store, identity, dead: ["area:1"])
        try JSONSerialization.data(withJSONObject: ["run": identity.run.uuidString, "ended": true, "dead": ["area:1"]]).write(to: oldSoul)
        let oldSoulBytes = try Data(contentsOf: oldSoul)
        try store.endRun(gameID: identity.gameID)
        let remoteFolder = store.support.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteFolder, withIntermediateDirectories: true)
        let remoteSave = remoteFolder.appendingPathComponent("game.sav")
        try Data(repeating: 14, count: 131_072).write(to: remoteSave)
        var next = identity; next.run = UUID()
        let remote = BoundMultiplayerSaveStore(root: remoteFolder.appendingPathComponent("packages"), support: remoteFolder, deviceID: UUID())
        try remote.begin(next, gameSaveURL: remoteSave)
        let newSoul = try writeSoul(remote, next, dead: ["area:7"])
        let package = try complete(remote, next, remoteSave)
        let incoming = try store.stageDownload(gameID: identity.gameID, version: "next-run").appendingPathComponent("complete.boundrun")
        try Data(contentsOf: remote.cloudURL(gameID: identity.gameID)).write(to: incoming)
        let payload = try JSONSerialization.data(withJSONObject: BoundAccountTestFixture.claims(owner: identity.owner, expiry: Date().timeIntervalSince1970 + 3600))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let session = try AppCloudSession(owner: identity.owner, key: "fixture", token: "fixture." + payload + ".signature")
        let device = store.deviceID, owner = identity.owner, run = next.run
        func acquire(history: String) async throws -> BoundRunLeaseGrant {
            let client = BoundRunLeaseClient(perform: { _ in
                let now = Date().timeIntervalSince1970
                return try JSONSerialization.data(withJSONObject: ["ok": true, "ownerID": owner.uuidString,
                    "runID": run.uuidString, "deviceID": device.uuidString, "token": UUID().uuidString,
                    "fence": "1", "serverTime": now, "expiresAt": now + 60, "anchorVersion": "2",
                    "checkpointID": package.payload.checkpoint.uuidString, "checkpointHistory": package.payload.sharedEventDigest,
                    "historyDigest": history])
            }, device: { device })
            return try await client.acquire(runID: run, session: session, allowTransfer: true)
        }
        let newerHistory = try await acquire(history: String(repeating: "e", count: 64))
        XCTAssertThrowsError(try store.restore(archiveURL: incoming, gameID: identity.gameID,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save, grant: newerHistory))
        XCTAssertEqual(try store.manifest(gameID: identity.gameID)?.identity.run, identity.run)
        let grant = try await acquire(history: package.payload.sharedEventDigest)
        try store.restore(archiveURL: incoming, gameID: identity.gameID,
            owner: identity.owner, romSHA256: identity.romSHA256, gameSaveURL: save, grant: grant)
        XCTAssertEqual(try store.manifest(gameID: identity.gameID)?.identity, next)
        XCTAssertEqual(try store.manifest(gameID: identity.gameID)?.deviceOwner, device)
        XCTAssertEqual(try Data(contentsOf: save), Data(repeating: 14, count: 131_072))
        XCTAssertEqual(try Data(contentsOf: oldSoul), try Data(contentsOf: newSoul))
        let archived = store.root.appendingPathComponent("Finished Runs/" + identity.run.uuidString)
        XCTAssertEqual(try Data(contentsOf: archived.appendingPathComponent("Ended Personal Files/soul.json")), oldSoulBytes)
        XCTAssertEqual(try Data(contentsOf: archived.appendingPathComponent("Ended Personal Files/game.sav")), Data(repeating: 3, count: 131_072))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.appendingPathComponent("complete.boundrun").path))
        let interrupted = store.directory(gameID: identity.gameID).appendingPathComponent("Restore", isDirectory: true)
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        try BoundMultiplayerSaveStore.encode(package).write(to: interrupted.appendingPathComponent("pending.boundrun"))
        try Data(repeating: 15, count: 131_072).write(to: save)
        XCTAssertThrowsError(try store.finishInterruptedRestore(gameID: identity.gameID, owner: identity.owner,
            romSHA256: identity.romSHA256, gameSaveURL: save, grant: newerHistory))
        XCTAssertEqual(try Data(contentsOf: save), Data(repeating: 15, count: 131_072))
        try store.finishInterruptedRestore(gameID: identity.gameID, owner: identity.owner,
            romSHA256: identity.romSHA256, gameSaveURL: save, grant: grant)
        XCTAssertEqual(try Data(contentsOf: save), Data(repeating: 14, count: 131_072))
    }
#endif
}
