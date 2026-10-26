import XCTest
@testable import Delta

private actor CheckpointSettlementRPCFixture {
    let identity: BoundMultiplayerRunIdentity
    let onUpload: @Sendable () throws -> Void
    let tamperConfirmedReceipt: Bool
    private var saved: BoundMultiplayerSavePackage
    private var chunks: [Int: String] = [:]
    private var actions: [String] = []
    private var uploaded: [BoundMultiplayerSavePackage.Payload] = []
    private var accepted = BoundMultiplayerSharedCursor()
    private var lostReply = false
    private let firstChunkFailure: BoundDebugFailure?
    private var injectedChunkFailure = false

    init(saved: BoundMultiplayerSavePackage, tamperConfirmedReceipt: Bool = false, firstChunkFailure: BoundDebugFailure? = nil,
         onUpload: @escaping @Sendable () throws -> Void = {}) {
        self.saved = saved; identity = saved.payload.manifest.identity
        self.tamperConfirmedReceipt = tamperConfirmedReceipt; self.onUpload = onUpload
        self.firstChunkFailure = firstChunkFailure
    }
    func evidence() -> (actions: [String], uploaded: [BoundMultiplayerSavePackage.Payload]) { (actions, uploaded) }
    func perform(_ request: URLRequest) throws -> Data {
        let text = try JSONDecoder().decode(String.self, from: XCTUnwrap(request.httpBody))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let action = try XCTUnwrap(body["action"] as? String); actions.append(action)
        XCTAssertEqual(body["save_id"] as? String, identity.run.uuidString.lowercased())
        if action == "events" {
            let events = try JSONDecoder().decode([BoundMultiplayerSharedEvent].self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(body["events"])))
            XCTAssertFalse(events.contains(where: \.requiresNativeCheckpoint))
            for event in events { accepted.insert(event.id) }
        }
        if action == "save" {
            XCTAssertEqual(body["expectedHead"] as? String, saved.payload.checkpoint.uuidString.lowercased())
            chunks = [:]; try onUpload()
        }
        if action == "saveChunk" {
            if let firstChunkFailure, !injectedChunkFailure {
                injectedChunkFailure = true; throw firstChunkFailure
            }
            chunks[try XCTUnwrap(body["index"] as? Int)] = try XCTUnwrap(body["data"] as? String)
        }
        if action == "saveSeal" {
            let encoded = chunks.keys.sorted().map { chunks[$0]! }.joined()
            let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
            let payload = try JSONDecoder().decode(BoundMultiplayerSavePackage.Payload.self, from: bytes)
            let receipt = try JSONDecoder().decode(BoundMultiplayerCheckpointReceipt.self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(body["receipt"])))
            XCTAssertEqual(payload.predecessor, saved.payload.checkpoint)
            XCTAssertEqual(receipt.payloadSHA256, BoundMultiplayerSaveStore.hash(bytes))
            saved = .init(payload: payload, receipt: receipt); uploaded.append(payload)
            if !lostReply { lostReply = true; throw URLError(.networkConnectionLost) }
        }
        var receipt = saved.receipt
        if lostReply, tamperConfirmedReceipt { receipt.payloadSHA256 = String(repeating: "0", count: 64) }
        let bytes = try BoundMultiplayerSaveStore.encode(saved.payload).count
        let cursors = Dictionary(uniqueKeysWithValues: accepted.origins.map { ($0.key.lowercased(), $0.value) })
        let value: [String: Any] = ["version": 2,
            "identity": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(identity)),
            "save_id": identity.run.uuidString, "committed": true, "cancelled": false, "epoch": 1, "revision": 1,
            "cursors": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(cursors)),
            "deliveries": [:], "events": [], "saves": [identity.owner.uuidString.lowercased(): [
                "receipt": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(receipt)),
                "count": ((bytes + 2) / 3 * 4 + 11_999) / 12_000, "bytes": bytes]]]
        return try JSONSerialization.data(withJSONObject: ["payload": String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self)])
    }
}

final class ServerCheckpointSettlementTests: XCTestCase {
    private func fixture() throws -> (BoundMultiplayerSaveStore, BoundMultiplayerRunIdentity) {
        let owner = UUID(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let identity = BoundMultiplayerRunIdentity(run: UUID(), gameID: "settlement-" + UUID().uuidString,
            owner: owner, partner: UUID(), roomID: UUID().uuidString.lowercased(), settingsOwner: owner,
            settings: Data([1, 2, 3]), localSeed: 1, partnerSeed: 2, romSHA256: String(repeating: "a", count: 64))
        let store = BoundMultiplayerSaveStore(root: folder, support: folder, deviceID: UUID())
        store.useServerStorage(gameID: identity.gameID)
        try store.beginServerSession(identity: identity, package: nil, target: .init())
        _ = try store.appendSharedEvent(gameID: identity.gameID, kind: "world", payload: Data([1]), idempotencyKey: "initial")
        return (store, identity)
    }
    private func capture(_ store: BoundMultiplayerSaveStore, _ identity: BoundMultiplayerRunIdentity) throws -> BoundMultiplayerSavePackage {
        try store.captureServerCheckpoint(gameID: identity.gameID, files: [
            "game.sav": Data(repeating: 7, count: 131_072), "checkpoint.state": Data(repeating: 8, count: 2048),
            "memory-files.json": Data("{}".utf8)], history: String(repeating: "b", count: 64))
    }
    private func resign(_ value: BoundMultiplayerSavePackage) throws -> BoundMultiplayerSavePackage {
        var value = value
        value.receipt.run = value.payload.manifest.identity.run
        value.receipt.owner = value.payload.manifest.identity.owner
        value.receipt.checkpoint = value.payload.checkpoint
        value.receipt.sharedEventDigest = value.payload.sharedEventDigest
        value.receipt.payloadSHA256 = BoundMultiplayerSaveStore.hash(try BoundMultiplayerSaveStore.encode(value.payload))
        return value
    }
    private func session(owner: UUID) throws -> AppCloudSession {
        let bytes = try JSONSerialization.data(withJSONObject: ["sub": owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
        let token = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try AppCloudSession(owner: owner, key: "fixture", token: "e30.\(token).fixture",
            backend: .init(kind: .legacy, origin: "https://bound.example"))
    }
    private func service(_ fixture: CheckpointSettlementRPCFixture) -> BoundNakamaRunService {
        BoundNakamaRunService(authorizeSaves: { session, _ in
            .init(httpEndpoint: URL(string: "https://bound.example")!, accessToken: "fixture-token", ownerID: session.owner,
                expiresAt: Date().timeIntervalSince1970 + 90, saveTicket: "fixture-ticket", partnerID: nil, roomID: nil)
        }, perform: { request in try await fixture.perform(request) })
    }

    func testLostSealReturnsExactRebasedCandidateAndAdoptionPreservesFactsReceivedDuringUpload() async throws {
        let (store, identity) = try fixture()
        let confirmed = try capture(store, identity), pending = try capture(store, identity), original = try capture(store, identity)
        let fixture = CheckpointSettlementRPCFixture(saved: confirmed) {
            _ = try store.appendSharedEvent(gameID: identity.gameID, kind: "world", payload: Data([2]), idempotencyKey: "during-upload")
            let peer = BoundMultiplayerSharedEvent(run: identity.run, id: .init(origin: identity.partner, sequence: 1), kind: "world", payload: Data([3]))
            _ = try store.receiveAuthoritativeSharedEvent(gameID: identity.gameID, event: peer)
            try store.markSharedEventApplied(gameID: identity.gameID, eventID: peer.id)
        }
        let settled = try await BoundServerDisconnectSave.settle(package: original, expectedHead: confirmed.payload.checkpoint,
            pendingHead: pending.payload.checkpoint, session: session(owner: identity.owner), verifiedCursor: .init(), service: service(fixture))
        let evidence = await fixture.evidence()
        XCTAssertEqual(evidence.uploaded.count, 1, "A lost seal response must recover the exact candidate through GET")
        XCTAssertEqual(settled.package.payload, evidence.uploaded.first)
        XCTAssertEqual(settled.package.payload.predecessor, confirmed.payload.checkpoint)
        XCTAssertNotEqual(settled.package.payload.checkpoint, original.payload.checkpoint)
        XCTAssertEqual(settled.state.saves[identity.owner.uuidString.lowercased()]?.receipt, settled.package.receipt)
        XCTAssertLessThan(try XCTUnwrap(evidence.actions.firstIndex(of: "events")), try XCTUnwrap(evidence.actions.firstIndex(of: "save")))
        let liveJournal = try store.journal(gameID: identity.gameID), liveManifest = try store.manifest(gameID: identity.gameID)
        XCTAssertEqual(liveJournal.events.count, 3)
        let checkpoint = BoundSDKManagedCheckpointPersistence(store: store)
        try checkpoint.acknowledgeServerCheckpoint(settled.package, replacing: original)
        XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), settled.package)
        XCTAssertEqual(try store.journal(gameID: identity.gameID), liveJournal)
        XCTAssertEqual(try store.manifest(gameID: identity.gameID), liveManifest)
        let next = try capture(store, identity)
        XCTAssertEqual(next.payload.predecessor, settled.package.payload.checkpoint)
        XCTAssertEqual(try JSONDecoder().decode(BoundMultiplayerSharedJournal.self,
            from: XCTUnwrap(next.payload.files["shared-events.json"]?.data)), liveJournal)
    }

    func testLostSealWithDifferentReceiptCannotConfirmCandidate() async throws {
        let (store, identity) = try fixture()
        let confirmed = try capture(store, identity), pending = try capture(store, identity), original = try capture(store, identity)
        let fixture = CheckpointSettlementRPCFixture(saved: confirmed, tamperConfirmedReceipt: true)
        do {
            _ = try await BoundServerDisconnectSave.settle(package: original, expectedHead: confirmed.payload.checkpoint,
                pendingHead: pending.payload.checkpoint, session: session(owner: identity.owner), verifiedCursor: .init(), service: service(fixture))
            XCTFail("A matching checkpoint ID cannot authorize different immutable payload bytes")
        } catch BoundNakamaRunService.Failure.conflict {} catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), original)
    }

    func testDetachedCustomCapturePreservesActiveHeadAndLaterJournalFacts() throws {
        let (store, identity) = try fixture(), active = try capture(store, identity)
        _ = try store.appendSharedEvent(gameID: identity.gameID, kind: "world", payload: Data([2]), idempotencyKey: "before-custom")
        let capturedJournal = try store.journal(gameID: identity.gameID)
        let checkpoint = BoundSDKManagedCheckpointPersistence(store: store)
        let custom = try checkpoint.captureDetachedServerCheckpoint(gameID: identity.gameID,
            files: active.payload.files.filter { $0.key != "shared-events.json" }.mapValues(\.data),
            history: active.payload.sharedEventDigest)
        let frozen = try BoundMultiplayerSaveStore.encode(custom)
        XCTAssertEqual(custom.payload.predecessor, active.payload.checkpoint)
        XCTAssertNotEqual(custom.payload.checkpoint, active.payload.checkpoint)
        XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), active)
        XCTAssertEqual(try store.journal(gameID: identity.gameID), capturedJournal)
        XCTAssertThrowsError(try checkpoint.acknowledgeServerCheckpoint(custom, replacing: custom),
            "An archive-only capture never owns the active head")

        _ = try store.appendSharedEvent(gameID: identity.gameID, kind: "world", payload: Data([3]), idempotencyKey: "after-custom")
        let liveJournal = try store.journal(gameID: identity.gameID), next = try capture(store, identity)
        XCTAssertEqual(next.payload.predecessor, active.payload.checkpoint,
            "Continued gameplay must not depend on an archive-only custom checkpoint")
        XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), next)
        XCTAssertEqual(try JSONDecoder().decode(BoundMultiplayerSharedJournal.self,
            from: XCTUnwrap(next.payload.files["shared-events.json"]?.data)), liveJournal)
        XCTAssertEqual(try JSONDecoder().decode(BoundMultiplayerSharedJournal.self,
            from: XCTUnwrap(custom.payload.files["shared-events.json"]?.data)), capturedJournal)
        XCTAssertEqual(liveJournal.events.count, 3); XCTAssertEqual(capturedJournal.events.count, 2)
        XCTAssertEqual(try BoundMultiplayerSaveStore.encode(custom), frozen)
    }

    func testScopedBusyAndTimeoutRevalidateBeforeRetryAndRecoverLostSeal() async throws {
        for failure in [BoundDebugFailure.busy, .timedOut] {
            let (store, identity) = try fixture(), confirmed = try capture(store, identity), pending = try capture(store, identity)
            let backend = CheckpointSettlementRPCFixture(saved: confirmed, firstChunkFailure: failure)
            let result = try await BoundServerDisconnectSave.settle(package: pending, expectedHead: confirmed.payload.checkpoint,
                pendingHead: pending.payload.checkpoint, session: session(owner: identity.owner), verifiedCursor: .init(), service: service(backend))
            let evidence = await backend.evidence()
            XCTAssertEqual(result.package, pending)
            XCTAssertEqual(evidence.uploaded.count, 1, "The final lost reply is recovered through an exact GET receipt")
            XCTAssertEqual(evidence.actions.filter { $0 == "save" }.count, 2)
            let firstChunk = try XCTUnwrap(evidence.actions.firstIndex(of: "saveChunk"))
            let secondSave = try XCTUnwrap(evidence.actions.lastIndex(of: "save"))
            XCTAssertTrue(evidence.actions[(firstChunk + 1)..<secondSave].contains("get"), "A scoped retry must revalidate the authoritative head")
            XCTAssertEqual(result.state.saves[identity.owner.uuidString.lowercased()]?.receipt, pending.receipt)
        }
    }

    func testScopedStaleAuthorityDoesNotRetryUpload() async throws {
        let (store, identity) = try fixture(), confirmed = try capture(store, identity), pending = try capture(store, identity)
        let backend = CheckpointSettlementRPCFixture(saved: confirmed, firstChunkFailure: .stale)
        do {
            _ = try await BoundServerDisconnectSave.settle(package: pending, expectedHead: confirmed.payload.checkpoint,
                pendingHead: pending.payload.checkpoint, session: session(owner: identity.owner), verifiedCursor: .init(), service: service(backend))
            XCTFail("Stale scoped authority must stop the upload")
        } catch BoundDebugFailure.stale {}
        let evidence = await backend.evidence()
        XCTAssertEqual(evidence.actions.filter { $0 == "save" }.count, 1)
        XCTAssertTrue(evidence.uploaded.isEmpty)
        XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), pending)
    }

    func testAcknowledgementRejectsChangedNativeBytesIdentityHistoryReceiptAndStaleHead() throws {
        let (store, identity) = try fixture(), original = try capture(store, identity)
        let rebased = try BoundServerDisconnectSave.rebased(original, predecessor: UUID())
        let journal = try store.journal(gameID: identity.gameID)
        var native = rebased; native.payload.files["checkpoint.state"] = .init(Data(repeating: 1, count: 2048))
        var changedIdentity = rebased; changedIdentity.payload.manifest.identity.gameID += "-other"
        var history = rebased; history.payload.sharedEventDigest = String(repeating: "c", count: 64)
        var rewrittenID = rebased; rewrittenID.payload.checkpoint = original.payload.checkpoint
        var invalidReceipt = rebased; invalidReceipt.receipt.payloadSHA256 = String(repeating: "0", count: 64)
        for candidate in [try resign(native), try resign(changedIdentity), try resign(history), try resign(rewrittenID), invalidReceipt] {
            XCTAssertThrowsError(try store.acknowledgeServerCheckpoint(candidate, replacing: original))
            XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), original)
            XCTAssertEqual(try store.journal(gameID: identity.gameID), journal)
        }
        let newer = try capture(store, identity)
        XCTAssertThrowsError(try store.acknowledgeServerCheckpoint(rebased, replacing: original))
        XCTAssertEqual(try store.latestComplete(gameID: identity.gameID), newer)
    }
}
