import XCTest
@testable import Delta

private actor AutomaticCheckpointOrder {
    private var actions: [String] = []
    func append(_ action: String) { actions.append(action) }
    func read() -> [String] { actions }
}

/// The real Nakama client encodes and chunks each package. This endpoint keeps
/// immutable bytes and receipts, with controlled response loss and suspension.
private actor AutomaticCheckpointRPC {
    enum Reply { case normal, loseFirstSeal, differentReceipt, omitAcquisition, conflict }
    let identity: BoundMultiplayerRunIdentity
    let reply: Reply
    private let runField: String
    private let order: AutomaticCheckpointOrder?
    private var holdSeal: Bool
    private var sealWaiters: [CheckedContinuation<Void, Never>] = []
    private var chunks: [Int: String] = [:]
    private var payloads: [Data] = []
    private var actions: [String] = []
    private var committed = Set<UUID>()
    private var accepted = BoundMultiplayerSharedCursor()
    private var sealCount = 0

    init(identity: BoundMultiplayerRunIdentity, reply: Reply = .normal, holdSeal: Bool = false,
         runField: String = "save_id", order: AutomaticCheckpointOrder? = nil) {
        self.identity = identity; self.reply = reply; self.holdSeal = holdSeal
        self.runField = runField; self.order = order
    }
    func waitForSeal() async throws {
        let deadline = Date().addingTimeInterval(3)
        while sealCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard sealCount > 0 else { throw URLError(.timedOut) }
    }
    func releaseSeal() {
        holdSeal = false
        let waiters = sealWaiters; sealWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    func evidence() -> (payloads: [Data], actions: [String], commits: Int, cursor: BoundMultiplayerSharedCursor) {
        (payloads, actions, committed.count, accepted)
    }
    func perform(_ request: URLRequest) async throws -> Data {
        let text = try JSONDecoder().decode(String.self, from: XCTUnwrap(request.httpBody))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let action = try XCTUnwrap(body["action"] as? String)
        XCTAssertEqual(body[runField] as? String, identity.run.uuidString.lowercased())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer automatic-fixture")
        actions.append(action)
        await order?.append("upload." + action)
        if action == "save" {
            if reply == .conflict { throw BoundNakamaRunService.Failure.conflict }
            chunks = [:]
        }
        if action == "saveChunk" {
            chunks[try XCTUnwrap(body["index"] as? Int)] = try XCTUnwrap(body["data"] as? String)
        }
        var saves: [String: Any] = [:]
        if action == "saveSeal" {
            let bytes = try XCTUnwrap(Data(base64Encoded: chunks.keys.sorted().map { chunks[$0]! }.joined()))
            let payload = try JSONDecoder().decode(BoundMultiplayerSavePackage.Payload.self, from: bytes)
            var receipt = try JSONDecoder().decode(BoundMultiplayerCheckpointReceipt.self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(body["receipt"])))
            XCTAssertEqual(receipt.payloadSHA256, BoundMultiplayerSaveStore.hash(bytes))
            XCTAssertEqual(payload.predecessor?.uuidString.lowercased(), body["expectedHead"] as? String)
            payloads.append(bytes); committed.insert(payload.checkpoint)
            if reply != .omitAcquisition {
                let package = BoundMultiplayerSavePackage(payload: payload, receipt: receipt)
                for event in try BoundServerDisconnectSave.pendingEvents(in: package, verifiedCursor: .init())
                    where event.requiresNativeCheckpoint { accepted.insert(event.id) }
            }
            sealCount += 1
            if holdSeal { await withCheckedContinuation { sealWaiters.append($0) } }
            if reply == .loseFirstSeal, sealCount == 1 { throw URLError(.networkConnectionLost) }
            if reply == .differentReceipt { receipt.payloadSHA256 = String(repeating: "0", count: 64) }
            saves[identity.owner.uuidString.lowercased()] = [
                "receipt": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(receipt)),
                "count": try XCTUnwrap(body["count"]), "bytes": bytes.count]
        }
        let cursors = Dictionary(uniqueKeysWithValues: accepted.origins.map { ($0.key.lowercased(), $0.value) })
        let state: [String: Any] = ["version": 2,
            "identity": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(identity)),
            "save_id": identity.run.uuidString, "committed": true, "cancelled": false, "epoch": 1, "revision": 1,
            "cursors": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(cursors)),
            "deliveries": [:], "events": [], "saves": saves]
        return try JSONSerialization.data(withJSONObject: [
            "payload": String(decoding: JSONSerialization.data(withJSONObject: state), as: UTF8.self)])
    }
}

/// The legacy lease service independently anchors history before the sealed
/// checkpoint. Its transport shares an order log with the snapshot endpoint.
private actor AutomaticCheckpointLeaseRPC {
    let owner: UUID
    let order: AutomaticCheckpointOrder
    private let token = UUID()
    private var version = 0
    private var history: String?
    private var checkpoint: String?

    init(owner: UUID, order: AutomaticCheckpointOrder) { self.owner = owner; self.order = order }
    func perform(_ request: URLRequest) async throws -> Data {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let action = try XCTUnwrap(body["action"] as? String)
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        await order.append("lease." + action)
        switch action {
        case "acquire":
            XCTAssertEqual(payload["transfer"] as? Bool, false)
        case "history":
            history = try XCTUnwrap(payload["history"] as? String); version += 1
        case "checkpoint":
            XCTAssertEqual(payload["history"] as? String, history)
            XCTAssertNil(payload["predecessor"] as? String)
            checkpoint = try XCTUnwrap(payload["checkpointID"] as? String); version += 1
        default:
            XCTFail("Unexpected lease operation: \(action)")
            throw BoundRunLeaseError.unavailable
        }
        let now = Date().timeIntervalSince1970
        return try JSONSerialization.data(withJSONObject: ["ok": true, "ownerID": owner.uuidString,
            "runID": try XCTUnwrap(payload["runID"]), "deviceID": try XCTUnwrap(payload["deviceID"]),
            "token": token.uuidString, "fence": "1", "serverTime": now, "expiresAt": now + 60,
            "anchorVersion": String(version), "checkpointID": checkpoint.map { $0 as Any } ?? NSNull(),
            "checkpointHistory": checkpoint == nil ? NSNull() : history.map { $0 as Any } ?? NSNull(),
            "historyDigest": history.map { $0 as Any } ?? NSNull()])
    }
}

@MainActor
private final class AutomaticCheckpointResult {
    var confirmations: [[BoundMultiplayerSharedEvent.ID]] = []
    var failures: [BoundServerCheckpointUpload.Failure] = []
    var settlements = 0
    var sessionCurrent = true
}

@MainActor
private final class AutomaticCheckpointGate {
    var entered = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func open() {
        opened = true
        let retained = waiters; waiters.removeAll(); retained.forEach { $0.resume() }
    }
}

private final class AutomaticCheckpointLifetime {
    let released: () -> Void
    init(released: @escaping () -> Void) { self.released = released }
    deinit { released() }
}

@MainActor
final class ServerAutomaticCheckpointTests: XCTestCase {
    private func package(acquisition: Bool = false, world: Bool = false) throws -> BoundMultiplayerSavePackage {
        let owner = UUID(), run = UUID(), partner = UUID()
        let identity = BoundMultiplayerRunIdentity(run: run, gameID: "automatic-" + UUID().uuidString,
            owner: owner, partner: partner, roomID: UUID().uuidString.lowercased(), settingsOwner: owner,
            settings: Data(repeating: 0, count: 32), localSeed: 1, partnerSeed: 2, romSHA256: String(repeating: "a", count: 64))
        var journal = BoundMultiplayerSharedJournal(run: run, owner: owner, partner: partner)
        if acquisition {
            let bytes = try XCTUnwrap(BoundSoulSharedEvent(run: run, kind: .acquired, slot: "area:100").payload)
            journal.events.append(.init(run: run, id: .init(origin: owner, sequence: 1), kind: "soul", payload: bytes))
        }
        if world {
            journal.events.append(.init(run: run, id: .init(origin: owner, sequence: UInt64(journal.events.count + 1)),
                kind: "world", payload: Data([1, 2, 3])))
        }
        journal.nextSequence = UInt64(journal.events.count + 1)
        for event in journal.events { journal.received.insert(event.id) }
        let payload = BoundMultiplayerSavePackage.Payload(version: 2, manifest: .init(identity: identity, deviceOwner: UUID()),
            checkpoint: UUID(), predecessor: nil, sharedEventDigest: String(repeating: "b", count: 64),
            files: ["game.sav": .init(Data(repeating: 7, count: 131_072)),
                    "checkpoint.state": .init(Data(repeating: 8, count: 2048)),
                    "shared-events.json": .init(try BoundMultiplayerSaveStore.encode(journal))])
        let receipt = BoundMultiplayerCheckpointReceipt(run: run, checkpoint: payload.checkpoint, owner: owner,
            payloadSHA256: BoundMultiplayerSaveStore.hash(try BoundMultiplayerSaveStore.encode(payload)),
            sharedEventDigest: payload.sharedEventDigest)
        return .init(payload: payload, receipt: receipt)
    }
    private func service(_ rpc: AutomaticCheckpointRPC) -> BoundNakamaRunService {
        BoundNakamaRunService(authorizeSaves: { session, _ in
            .init(httpEndpoint: URL(string: "https://bound.example")!, accessToken: "automatic-fixture", ownerID: session.owner,
                expiresAt: Date().timeIntervalSince1970 + 90, saveTicket: "automatic-ticket", partnerID: nil, roomID: nil)
        }, perform: { request in try await rpc.perform(request) })
    }
    private func request(_ package: BoundMultiplayerSavePackage, rpc: AutomaticCheckpointRPC,
                         result: AutomaticCheckpointResult, verified: BoundMultiplayerSharedCursor = .init(),
                         settle: (@MainActor () throws -> Void)? = nil) throws -> BoundServerCheckpointUpload.Request {
        let owner = package.payload.manifest.identity.owner
        let session = try session(owner: owner), client = service(rpc)
        return .init(package: package, expectedHead: package.payload.predecessor, session: session,
            verifiedCursor: verified, destination: .managed(makeService: { client },
                isSessionCurrent: { result.sessionCurrent }, settleCapturedContinuation: {
                    try settle?(); result.settlements += 1
                }), isAlreadyConfirmed: { false })
    }
    private func session(owner: UUID) throws -> AppCloudSession {
        let claims = try JSONSerialization.data(withJSONObject: ["sub": owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
        let token = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try AppCloudSession(owner: owner, key: "fixture", token: "e30.\(token).fixture",
            backend: .init(kind: .legacy, origin: "https://bound.example"))
    }
    private func callbacks(_ result: AutomaticCheckpointResult,
                           discovery: @escaping @MainActor () async -> Bool = { false }) -> BoundServerCheckpointUpload.Callbacks {
        .init(isCurrentRun: { true }, confirmed: { result.confirmations.append($0) },
            discoverGameOver: discovery, failed: { result.failures.append($0) })
    }
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    func testHeldUploadRejectsDuplicateAdmissionAndConfirmsExactAcquisition() async throws {
        let package = try package(acquisition: true), result = AutomaticCheckpointResult()
        let rpc = AutomaticCheckpointRPC(identity: package.payload.manifest.identity, holdSeal: true)
        let upload = BoundServerCheckpointUpload(), request = try request(package, rpc: rpc, result: result)
        XCTAssertTrue(upload.start(request, callbacks: callbacks(result)))
        try await rpc.waitForSeal()
        XCTAssertTrue(upload.isUploading)
        XCTAssertFalse(upload.start(request, callbacks: callbacks(result)))
        XCTAssertEqual(result.settlements, 0); XCTAssertTrue(result.confirmations.isEmpty)
        await rpc.releaseSeal(); await upload.awaitCurrent()
        XCTAssertFalse(upload.isUploading); XCTAssertEqual(result.settlements, 1)
        XCTAssertEqual(result.confirmations, [[.init(origin: package.payload.manifest.identity.owner, sequence: 1)]])
        let evidence = await rpc.evidence()
        XCTAssertEqual(evidence.payloads, [try BoundMultiplayerSaveStore.encode(package.payload)])
    }

    func testLostSealRetriesSameImmutableBytesAndDoesNotDuplicateAcquisition() async throws {
        let package = try package(acquisition: true), result = AutomaticCheckpointResult()
        let rpc = AutomaticCheckpointRPC(identity: package.payload.manifest.identity, reply: .loseFirstSeal)
        var now: TimeInterval = 10
        let upload = BoundServerCheckpointUpload(clock: { now }), request = try request(package, rpc: rpc, result: result)
        XCTAssertTrue(upload.start(request, callbacks: callbacks(result))); await upload.awaitCurrent()
        XCTAssertTrue(result.confirmations.isEmpty); XCTAssertEqual(result.settlements, 0)
        now = 12.99; XCTAssertFalse(upload.start(request, callbacks: callbacks(result)))
        now = 13; XCTAssertTrue(upload.start(request, callbacks: callbacks(result))); await upload.awaitCurrent()
        let evidence = await rpc.evidence(), bytes = try BoundMultiplayerSaveStore.encode(package.payload)
        XCTAssertEqual(evidence.payloads, [bytes, bytes]); XCTAssertEqual(evidence.commits, 1)
        XCTAssertEqual(evidence.actions.filter { $0 == "saveSeal" }.count, 2)
        XCTAssertFalse(evidence.actions.contains("events"))
        XCTAssertEqual(evidence.cursor, BoundMultiplayerSharedCursor(origins: [package.payload.manifest.identity.owner.uuidString: .init(contiguous: 1)]))
        XCTAssertEqual(result.settlements, 1); XCTAssertEqual(result.confirmations.count, 1)
    }

    func testDifferentReceiptAndMissingAcquisitionProofNeverSettleOrConfirm() async throws {
        for reply in [AutomaticCheckpointRPC.Reply.differentReceipt, .omitAcquisition] {
            let package = try package(acquisition: true), result = AutomaticCheckpointResult()
            let rpc = AutomaticCheckpointRPC(identity: package.payload.manifest.identity, reply: reply)
            let upload = BoundServerCheckpointUpload(), request = try request(package, rpc: rpc, result: result)
            XCTAssertTrue(upload.start(request, callbacks: callbacks(result))); await upload.awaitCurrent()
            XCTAssertTrue(result.confirmations.isEmpty); XCTAssertEqual(result.settlements, 0)
            XCTAssertEqual(result.failures, reply == .differentReceipt ? [.conflict] : [])
            XCTAssertFalse(upload.start(request, callbacks: callbacks(result)), "Rejected proof retains retry backoff")
        }
    }

    func testCancellationAndAccountReplacementCannotSettleLateSuccessfulResponse() async throws {
        for cancel in [true, false] {
            let package = try package(), result = AutomaticCheckpointResult()
            let rpc = AutomaticCheckpointRPC(identity: package.payload.manifest.identity, holdSeal: true)
            let upload = BoundServerCheckpointUpload(), request = try request(package, rpc: rpc, result: result)
            XCTAssertTrue(upload.start(request, callbacks: callbacks(result)))
            let interrupt = Task { @MainActor in
                try await rpc.waitForSeal()
                if cancel { upload.cancel() } else { result.sessionCurrent = false }
                await rpc.releaseSeal()
            }
            await upload.awaitCurrent(); try await interrupt.value
            XCTAssertFalse(upload.isUploading); XCTAssertEqual(result.settlements, 0)
            XCTAssertTrue(result.confirmations.isEmpty); XCTAssertTrue(result.failures.isEmpty)
        }
    }

    func testCancellationBeforeTaskStartsReleasesRetainedOwnerWithoutAuthorizing() async throws {
        let package = try package(), result = AutomaticCheckpointResult()
        let rpc = AutomaticCheckpointRPC(identity: package.payload.manifest.identity), upload = BoundServerCheckpointUpload()
        let base = try request(package, rpc: rpc, result: result), client = service(rpc)
        let released = expectation(description: "Cancelled admitted transaction releases its retained owner")
        var serviceCreations = 0
        do {
            let lifetime = AutomaticCheckpointLifetime { released.fulfill() }
            let request = BoundServerCheckpointUpload.Request(package: base.package, expectedHead: base.expectedHead,
                session: base.session, verifiedCursor: base.verifiedCursor,
                destination: .managed(makeService: { [lifetime] in
                    _ = lifetime; serviceCreations += 1; return client
                }, isSessionCurrent: { true }, settleCapturedContinuation: { result.settlements += 1 }),
                isAlreadyConfirmed: { false })
            XCTAssertTrue(upload.start(request, callbacks: callbacks(result)))
            upload.cancel()
        }
        await fulfillment(of: [released], timeout: 3)
        XCTAssertFalse(upload.isUploading); XCTAssertEqual(serviceCreations, 0)
        XCTAssertEqual(result.settlements, 0); XCTAssertTrue(result.confirmations.isEmpty)
        let evidence = await rpc.evidence()
        XCTAssertTrue(evidence.actions.isEmpty)
    }

    func testDetachedUploadSettlesCapturedClaimButPreservesNewerClaimAndPresentation() async throws {
        for replaceClaim in [false, true] {
            let package = try package(), identity = package.payload.manifest.identity, result = AutomaticCheckpointResult()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = BoundNativeContinuationStore(root: root)
            let context = BoundNativeContinuationContext(owner: identity.owner, roomID: identity.roomID, runID: identity.run)
            try store.claim(ticket: UUID(), context: context, gameID: identity.gameID)
            let captured = try XCTUnwrap(store.settlement(context: context, gameID: identity.gameID))
            let rpc = AutomaticCheckpointRPC(identity: identity, holdSeal: true), upload = BoundServerCheckpointUpload()
            let request = try request(package, rpc: rpc, result: result, settle: { try store.settle(captured) })
            XCTAssertTrue(upload.start(request, callbacks: callbacks(result)))
            let replacement = UUID()
            let detach = Task { @MainActor in
                try await rpc.waitForSeal()
                if replaceClaim { try store.claim(ticket: replacement, context: context, gameID: identity.gameID) }
                upload.detach()
                XCTAssertFalse(upload.isUploading)
                await rpc.releaseSeal()
            }
            await upload.awaitCurrent(); try await detach.value
            XCTAssertEqual(result.settlements, 1); XCTAssertTrue(result.confirmations.isEmpty)
            XCTAssertEqual(try store.settlement(context: context, gameID: identity.gameID)?.ticket, replaceClaim ? replacement : nil)
        }
    }

    func testLateConflictDiscoveryCannotFailOrClearReplacementUpload() async throws {
        let original = try package(), oldResult = AutomaticCheckpointResult(), discovery = AutomaticCheckpointGate()
        let failing = AutomaticCheckpointRPC(identity: original.payload.manifest.identity, reply: .conflict)
        let upload = BoundServerCheckpointUpload()
        let first = try request(original, rpc: failing, result: oldResult)
        XCTAssertTrue(upload.start(first, callbacks: callbacks(oldResult, discovery: { await discovery.wait(); return false })))
        let replacement = try package(), newResult = AutomaticCheckpointResult()
        let held = AutomaticCheckpointRPC(identity: replacement.payload.manifest.identity, holdSeal: true)
        let second = try request(replacement, rpc: held, result: newResult)
        let replace = Task { @MainActor in
            try await self.eventually { discovery.entered }
            upload.cancel(resetRetry: true)
            XCTAssertTrue(upload.start(second, callbacks: self.callbacks(newResult)))
            try await held.waitForSeal()
            discovery.open()
        }
        await upload.awaitCurrent(); try await replace.value
        XCTAssertTrue(upload.isUploading, "The old defer cannot clear the replacement handle")
        XCTAssertTrue(oldResult.failures.isEmpty); XCTAssertTrue(newResult.confirmations.isEmpty)
        await held.releaseSeal(); await upload.awaitCurrent()
        XCTAssertEqual(newResult.confirmations.count, 1); XCTAssertFalse(upload.isUploading)
    }

    func testHistoryAdmissionWaitsForOrdinaryEventsAndRejectsCorruptedJournal() async throws {
        let package = try package(acquisition: true, world: true), result = AutomaticCheckpointResult()
        let rpc = AutomaticCheckpointRPC(identity: package.payload.manifest.identity), upload = BoundServerCheckpointUpload()
        XCTAssertFalse(upload.start(try request(package, rpc: rpc, result: result), callbacks: callbacks(result)))
        var verified = BoundMultiplayerSharedCursor()
        verified.insert(.init(origin: package.payload.manifest.identity.owner, sequence: 2))
        XCTAssertTrue(upload.start(try request(package, rpc: rpc, result: result, verified: verified), callbacks: callbacks(result)))
        await upload.awaitCurrent()
        XCTAssertEqual(result.confirmations.count, 1)
        var corrupt = package
        corrupt.payload.files["shared-events.json"] = .init(Data("invalid".utf8))
        XCTAssertFalse(upload.start(try request(corrupt, rpc: rpc, result: result), callbacks: callbacks(result)))
        XCTAssertEqual(result.failures, [.invalidJournal])
    }

    func testContinuationPersistenceFailureRemainsRetryableWithoutSaveSuccess() async throws {
        let package = try package(), result = AutomaticCheckpointResult()
        let rpc = AutomaticCheckpointRPC(identity: package.payload.manifest.identity)
        var now: TimeInterval = 0, attempts = 0
        let upload = BoundServerCheckpointUpload(clock: { now })
        let request = try request(package, rpc: rpc, result: result, settle: {
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileWriteNoPermission) }
        })
        XCTAssertTrue(upload.start(request, callbacks: callbacks(result))); await upload.awaitCurrent()
        XCTAssertTrue(result.confirmations.isEmpty); XCTAssertEqual(result.settlements, 0)
        now = 3
        XCTAssertTrue(upload.start(request, callbacks: callbacks(result))); await upload.awaitCurrent()
        XCTAssertEqual(attempts, 2); XCTAssertEqual(result.settlements, 1); XCTAssertEqual(result.confirmations.count, 1)
        let evidence = await rpc.evidence()
        XCTAssertEqual(evidence.commits, 1)
    }

    func testLeasedUploadAuthorizesBeforeChunksAndPublishesOnlyItsDeviceAfterSeal() async throws {
        for ownsDevice in [true, false] {
            let package = try package(), identity = package.payload.manifest.identity
            let device = ownsDevice ? package.payload.manifest.deviceOwner : UUID()
            let order = AutomaticCheckpointOrder(), result = AutomaticCheckpointResult()
            let rpc = AutomaticCheckpointRPC(identity: identity, runField: "runID", order: order)
            let authority = AutomaticCheckpointLeaseRPC(owner: identity.owner, order: order)
            let lease = BoundRunLeaseClient(perform: { try await authority.perform($0) }, device: { device })
            let service = BoundNakamaRunService(authorizeSaves: { _, _ in
                XCTFail("Legacy uploads use their existing room configuration")
                throw BoundNakamaRunService.Failure.unavailable
            }, perform: { try await rpc.perform($0) })
            await service.configure(.init(endpoint: URL(string: "wss://bound.example/ws?format=json")!,
                accessToken: "automatic-fixture", expiresAt: Date().timeIntervalSince1970 + 90,
                matchID: "automatic-fixture", roomID: try XCTUnwrap(UUID(uuidString: identity.roomID)),
                ownerID: identity.owner, nakamaUserID: UUID(), joinTicket: "automatic-room-ticket",
                members: [identity.owner, identity.partner], peerOwnerID: identity.partner))
            let upload = BoundServerCheckpointUpload(legacyService: service)
            let request = BoundServerCheckpointUpload.Request(package: package, expectedHead: nil,
                session: try session(owner: identity.owner), verifiedCursor: .init(),
                destination: .leased(client: lease, deviceID: device), isAlreadyConfirmed: { false })
            XCTAssertTrue(upload.start(request, callbacks: callbacks(result)))
            await upload.awaitCurrent()
            let actions = await order.read(), evidence = await rpc.evidence()
            XCTAssertEqual(Array(actions.prefix(2)), ["lease.acquire", "upload.save"])
            XCTAssertTrue(actions.contains("upload.saveChunk"))
            if ownsDevice {
                XCTAssertEqual(Array(actions.suffix(3)), ["upload.saveSeal", "lease.history", "lease.checkpoint"])
            } else {
                XCTAssertEqual(actions.last, "upload.saveSeal")
                XCTAssertEqual(actions.filter { $0.hasPrefix("lease.") }, ["lease.acquire"],
                    "Another device's package cannot move this device's transfer checkpoint")
            }
            XCTAssertEqual(evidence.payloads, [try BoundMultiplayerSaveStore.encode(package.payload)])
            XCTAssertEqual(result.confirmations.count, 1); XCTAssertTrue(result.failures.isEmpty)
            XCTAssertEqual(result.settlements, 0, "Legacy publication does not settle managed activity tokens")
        }
    }
}
