import XCTest
@testable import Delta

private actor DisconnectSaveRPCFixture {
    enum Mode { case loseSealResponse, rejectUpload }
    let identity: BoundMultiplayerRunIdentity
    let mode: Mode
    private var saved: [String: Any]?
    private var actions: [String] = []
    init(identity: BoundMultiplayerRunIdentity, mode: Mode) { self.identity = identity; self.mode = mode }
    func requests() -> [String] { actions }
    func perform(_ request: URLRequest) throws -> Data {
        let text = try JSONDecoder().decode(String.self, from: XCTUnwrap(request.httpBody))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let action = try XCTUnwrap(body["action"] as? String)
        XCTAssertEqual(body["save_id"] as? String, identity.run.uuidString.lowercased())
        actions.append(action)
        if action == "save", mode == .rejectUpload { throw BoundNakamaRunService.Failure.conflict }
        if action == "saveSeal" {
            saved = ["receipt": try XCTUnwrap(body["receipt"]), "count": try XCTUnwrap(body["count"]),
                     "bytes": try XCTUnwrap(body["bytes"])]
            // The server committed the frozen package, but its response never
            // reached the client. The following GET is the only confirmation.
            if mode == .loseSealResponse { throw URLError(.networkConnectionLost) }
        }
        let value: [String: Any] = ["version": 2,
            "identity": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(identity)),
            "save_id": identity.run.uuidString, "committed": true, "cancelled": false, "epoch": 1, "revision": 1,
            "cursors": [:], "deliveries": [:], "saves": saved.map { [identity.owner.uuidString.lowercased(): $0] } ?? [:], "events": []]
        return try JSONSerialization.data(withJSONObject: ["payload": String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self)])
    }
}

final class ServerDisconnectSaveTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let peer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let run = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!

    private func event(_ sequence: UInt64, origin: UUID? = nil, bytes: Int = 20) -> BoundMultiplayerSharedEvent {
        .init(run: run, id: .init(origin: origin ?? owner, sequence: sequence), kind: "soul", payload: Data(repeating: 1, count: bytes))
    }
    private func package(events: [BoundMultiplayerSharedEvent] = [], predecessor: UUID? = nil) throws -> BoundMultiplayerSavePackage {
        let identity = BoundMultiplayerRunIdentity(run: run, gameID: "fixture", owner: owner, partner: peer,
            roomID: run.uuidString.lowercased(), settingsOwner: owner, settings: Data(repeating: 0, count: 32),
            localSeed: 1, partnerSeed: 2, romSHA256: String(repeating: "a", count: 64))
        var journal = BoundMultiplayerSharedJournal(run: run, owner: owner, partner: peer)
        journal.events = events; journal.nextSequence = (events.filter { $0.id.origin == owner }.map(\.id.sequence).max() ?? 0) + 1
        for event in events { journal.received.insert(event.id) }
        let payload = BoundMultiplayerSavePackage.Payload(version: 2, manifest: .init(identity: identity, deviceOwner: UUID()),
            checkpoint: UUID(), predecessor: predecessor, sharedEventDigest: String(repeating: "b", count: 64),
            files: ["shared-events.json": .init(try BoundMultiplayerSaveStore.encode(journal)), "game.sav": .init(Data([1, 2, 3]))])
        let receipt = BoundMultiplayerCheckpointReceipt(run: run, checkpoint: payload.checkpoint, owner: owner,
            payloadSHA256: BoundMultiplayerSaveStore.hash(try BoundMultiplayerSaveStore.encode(payload)), sharedEventDigest: payload.sharedEventDigest)
        return .init(payload: payload, receipt: receipt)
    }

    func testHeadFenceAcceptsOnlyKnownOwnUploadsAndDoesNotTreatMissingHeadAsRollbackPermission() {
        let expected = UUID(), pending = UUID(), final = UUID()
        for head in [expected, pending, final] {
            XCTAssertTrue(BoundServerDisconnectSave.permits(head: head, expectedHead: expected, pendingHead: pending, checkpoints: [final]))
        }
        XCTAssertFalse(BoundServerDisconnectSave.permits(head: UUID(), expectedHead: expected, pendingHead: pending, checkpoints: [final]))
        XCTAssertFalse(BoundServerDisconnectSave.permits(head: nil, expectedHead: expected, pendingHead: pending, checkpoints: [final]))
        XCTAssertTrue(BoundServerDisconnectSave.permits(head: nil, expectedHead: nil, pendingHead: pending, checkpoints: [final]))
    }

    func testChangingPredecessorAllocatesNewImmutableCheckpointWithoutChangingFrozenGameBytes() throws {
        let previous = UUID(), actual = UUID(), source = try package(predecessor: previous)
        let rebased = try BoundServerDisconnectSave.rebased(source, predecessor: actual)
        XCTAssertEqual(rebased.payload.manifest, source.payload.manifest)
        XCTAssertEqual(rebased.payload.files, source.payload.files)
        XCTAssertEqual(rebased.payload.predecessor, actual)
        XCTAssertNotEqual(rebased.payload.checkpoint, source.payload.checkpoint)
        XCTAssertEqual(rebased.receipt.run, run)
        XCTAssertEqual(rebased.receipt.checkpoint, rebased.payload.checkpoint)
        XCTAssertEqual(rebased.receipt.payloadSHA256, BoundMultiplayerSaveStore.hash(try BoundMultiplayerSaveStore.encode(rebased.payload)))
        XCTAssertEqual(try BoundServerDisconnectSave.rebased(source, predecessor: previous), source, "identical retry preserves immutable bytes and identifier")
        XCTAssertThrowsError(try BoundServerDisconnectSave.rebased(source, predecessor: source.payload.checkpoint))
    }

    func testPriorVerifiedSparseReceiptsSkipOnlyThoseOwnEventsAndPreserveTheMissingSequence() throws {
        let first = event(1), second = event(2), remote = event(1, origin: peer)
        let source = try package(events: [second, remote, first])
        var verified = BoundMultiplayerSharedCursor(); verified.insert(second.id)
        XCTAssertEqual(try BoundServerDisconnectSave.pendingEvents(in: source, verifiedCursor: verified), [first])
        XCTAssertEqual(try BoundServerDisconnectSave.pendingEvents(in: source, verifiedCursor: .init()), [first, second])
    }

    func testCorruptedJournalOrDuplicateEventIdentityCannotReachTheDisconnectUploader() throws {
        var source = try package(events: [event(1)])
        source.payload.files["shared-events.json"]?.sha256 = String(repeating: "0", count: 64)
        source.receipt.payloadSHA256 = BoundMultiplayerSaveStore.hash(try BoundMultiplayerSaveStore.encode(source.payload))
        XCTAssertThrowsError(try BoundServerDisconnectSave.pendingEvents(in: source, verifiedCursor: .init()))
        let duplicate = try package(events: [event(1), event(1, bytes: 30)])
        XCTAssertThrowsError(try BoundServerDisconnectSave.pendingEvents(in: duplicate, verifiedCursor: .init()))
    }

    func testEventDrainHonorsExistingBatchCountAndByteLimits() throws {
        let small = (1...30).map { event(UInt64($0)) }
        XCTAssertEqual(try BoundServerDisconnectSave.eventBatch(small).count, 16)
        let large = (1...16).map { event(UInt64($0), bytes: 4000) }
        let batch = try BoundServerDisconnectSave.eventBatch(large)
        XCTAssertEqual(batch.count, 2)
        XCTAssertLessThanOrEqual(try BoundMultiplayerSaveStore.encode(batch).count, 14_000)
        XCTAssertThrowsError(try BoundServerDisconnectSave.eventBatch([event(1, bytes: 20_000)]))
    }

    @MainActor func testDisconnectFailureIsAccountScopedAndClearedOnlyBySuccessOrAcknowledgement() throws {
        var identity = try package().payload.manifest.identity
        identity.run = UUID(); identity.gameID = UUID().uuidString
        let failed = BoundServerDisconnectSave.nextAttempt()
        BoundServerDisconnectSave.rememberOutcome(identity: identity, attempt: failed, failure: "Not saved")
        XCTAssertEqual(BoundServerDisconnectSave.failureMessage(run: identity.run), "Not saved")
        XCTAssertEqual(BoundServerDisconnectSave.failureMessage(gameID: identity.gameID, owner: owner), "Not saved")
        XCTAssertNil(BoundServerDisconnectSave.failureMessage(gameID: identity.gameID, owner: peer))
        let saved = BoundServerDisconnectSave.nextAttempt()
        BoundServerDisconnectSave.rememberOutcome(identity: identity, attempt: saved, failure: nil)
        BoundServerDisconnectSave.rememberOutcome(identity: identity, attempt: failed, failure: "Late failed attempt")
        XCTAssertNil(BoundServerDisconnectSave.failureMessage(run: identity.run), "an older failure cannot override a newer confirmed save")
        BoundServerDisconnectSave.rememberOutcome(identity: identity, attempt: BoundServerDisconnectSave.nextAttempt(), failure: "Retry needed")
        BoundServerDisconnectSave.acknowledgeFailure(run: identity.run)
        XCTAssertNil(BoundServerDisconnectSave.failureMessage(run: identity.run))
    }

    @MainActor func testDisconnectOutcomesRetainOnlyTheLatestBoundedRunSet() throws {
        var identity = try package().payload.manifest.identity
        identity.run = UUID(); identity.gameID = UUID().uuidString
        let first = identity.run
        BoundServerDisconnectSave.rememberOutcome(identity: identity, attempt: BoundServerDisconnectSave.nextAttempt(), failure: "Old failure")
        for index in 0..<32 {
            identity.run = UUID()
            BoundServerDisconnectSave.rememberOutcome(identity: identity, attempt: BoundServerDisconnectSave.nextAttempt(), failure: "Failure \(index)")
        }
        XCTAssertNil(BoundServerDisconnectSave.failureMessage(run: first))
        XCTAssertEqual(BoundServerDisconnectSave.failureMessage(gameID: identity.gameID, owner: owner), "Failure 31")
    }

    private func session() throws -> AppCloudSession {
        let bytes = try JSONSerialization.data(withJSONObject: ["sub": owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
        let token = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try AppCloudSession(owner: owner, key: "fixture", token: "e30.\(token).fixture",
                                   backend: .init(kind: .legacy, origin: "https://bound.example"))
    }
    private func service(_ fixture: DisconnectSaveRPCFixture) -> BoundNakamaRunService {
        BoundNakamaRunService(authorizeSaves: { session, _ in
            .init(httpEndpoint: URL(string: "https://bound.example")!, accessToken: "fixture-token", ownerID: session.owner,
                  expiresAt: Date().timeIntervalSince1970 + 90, saveTicket: "fixture-ticket", partnerID: nil, roomID: nil)
        }, perform: { request in try await fixture.perform(request) })
    }

    @MainActor func testLostFinalUploadResponseSettlesCapturedActivityOnlyAfterServerConfirmsSamePackage() async throws {
        let package = try package(), identity = package.payload.manifest.identity
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BoundNativeContinuationStore(root: folder)
        let context = BoundNativeContinuationContext(owner: owner, roomID: identity.roomID, runID: identity.run)
        try store.claim(ticket: UUID(), context: context, gameID: identity.gameID)
        let token = try XCTUnwrap(store.settlement(context: context, gameID: identity.gameID))
        let fixture = DisconnectSaveRPCFixture(identity: identity, mode: .loseSealResponse)
        var confirmations = 0
        let task = BoundServerDisconnectSave.enqueue(package: package, previous: nil, expectedHead: nil, pendingHead: nil,
            session: try session(), service: service(fixture), onConfirmed: { checkpoint in
                XCTAssertEqual(checkpoint, package.payload.checkpoint)
                XCTAssertNotNil(try store.settlement(context: context, gameID: identity.gameID))
                confirmations += 1
                try store.settle(token)
            })
        await task.value
        XCTAssertEqual(confirmations, 1)
        XCTAssertNil(try store.settlement(context: context, gameID: identity.gameID))
        XCTAssertNil(BoundServerDisconnectSave.failureMessage(run: identity.run))
        let actions = await fixture.requests()
        XCTAssertEqual(actions.filter { $0 == "saveSeal" }.count, 1, "A confirmed sealed retry must not replay the upload")
        XCTAssertEqual(actions.filter { $0 == "get" }.count, 4, "The retry verifies the authoritative head after the lost seal response")
    }

    @MainActor func testRejectedFinalUploadNeverSettlesActivityAndRetainsVisibleSaveFailure() async throws {
        let package = try package(), identity = package.payload.manifest.identity
        let fixture = DisconnectSaveRPCFixture(identity: identity, mode: .rejectUpload)
        let task = BoundServerDisconnectSave.enqueue(package: package, previous: nil, expectedHead: nil, pendingHead: nil,
            session: try session(), service: service(fixture), onConfirmed: { _ in XCTFail("An unconfirmed upload cannot retire a consumed activity") })
        await task.value
        XCTAssertNotNil(BoundServerDisconnectSave.failureMessage(run: identity.run))
        let actions = await fixture.requests()
        XCTAssertEqual(actions.filter { $0 == "save" }.count, 1)
        XCTAssertFalse(actions.contains("saveSeal"))
    }

    @MainActor func testFailedContinuationSettlementDoesNotReportFinalSaveSuccess() async throws {
        let package = try package(), identity = package.payload.manifest.identity
        let fixture = DisconnectSaveRPCFixture(identity: identity, mode: .loseSealResponse)
        var confirmations = 0
        let task = BoundServerDisconnectSave.enqueue(package: package, previous: nil, expectedHead: nil, pendingHead: nil,
            session: try session(), service: service(fixture), onConfirmed: { _ in
                confirmations += 1
                throw CocoaError(.fileWriteNoPermission)
            })
        await task.value
        XCTAssertEqual(confirmations, 1)
        XCTAssertNotNil(BoundServerDisconnectSave.failureMessage(run: identity.run), "A durable recovery fence write failure must remain retryable")
    }
}
