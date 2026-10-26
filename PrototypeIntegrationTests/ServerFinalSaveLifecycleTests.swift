import XCTest
@preconcurrency import DeltaCore
@testable import Delta

private struct FinalSaveNativeGame: GameProtocol {
    let fileURL: URL
    let type: GameType = .gba
}

private final class FinalSaveCallbackObserver: @unchecked Sendable {
    let core: AnyObject
    let gate: BoundServerSaveRequestGate
    private let lock = NSLock()
    private var callbacks = 0, admitted = 0
    init(core: AnyObject, gate: BoundServerSaveRequestGate) { self.core = core; self.gate = gate }
    func save() {
        let accepted = gate.acceptsCallback(from: core)
        lock.lock(); defer { lock.unlock() }
        callbacks += 1
        if accepted { admitted += 1 }
    }
    func counts() -> (callbacks: Int, admitted: Int) {
        lock.lock(); defer { lock.unlock() }
        return (callbacks, admitted)
    }
}

private actor FinalSaveAuthorityRPC {
    let response: Data
    let online: Bool
    private var authorizations = 0
    private var actions: [String] = []
    init(response: Data, online: Bool = true) { self.response = response; self.online = online }
    func authorize(_ session: AppCloudSession) throws -> BoundNakamaAuthorization.SaveConfiguration {
        authorizations += 1
        guard online else { throw URLError(.notConnectedToInternet) }
        return .init(httpEndpoint: URL(string: "https://bound.example")!, accessToken: "final-save-fixture",
            ownerID: session.owner, expiresAt: Date().timeIntervalSince1970 + 90,
            saveTicket: "final-save-ticket", partnerID: nil, roomID: nil)
    }
    func perform(_ request: URLRequest) throws -> Data {
        let text = try JSONDecoder().decode(String.self, from: XCTUnwrap(request.httpBody))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(body["saveTicket"] as? String, "final-save-ticket")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer final-save-fixture")
        actions.append(try XCTUnwrap(body["action"] as? String))
        return try JSONSerialization.data(withJSONObject: ["payload": String(decoding: response, as: UTF8.self)])
    }
    func counts() -> (Int, [String]) { (authorizations, actions) }
}

@MainActor
private final class FinalSaveGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let retained = waiters; waiters.removeAll()
        retained.forEach { $0.resume() }
    }
}

@MainActor
final class ServerFinalSaveLifecycleTests: XCTestCase {
    private enum ExpectedFailure: Error { case capture, deadline }
    private final class PausedOwner { var facts: [String] = [] }

    func testActualNativeCapturePausesDoNotScheduleAnotherSaveButManualPauseDoes() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rom = directory.appendingPathComponent("capture-save-callback.gba")
        try FileManager.default.copyItem(at: fixture, to: rom)
        let core = try XCTUnwrap(EmulatorCore(game: FinalSaveNativeGame(fileURL: rom), options: [.metal: true]))
        try BoundROMMultiplayerCoordinator.prepareServerCoreForSelection(core)
        let gate = BoundServerSaveRequestGate.bind(core: core)
        let observed = FinalSaveCallbackObserver(core: core, gate: gate)
        core.saveHandler = { _ in observed.save() }
        defer { gate.invalidate(); core.saveHandler = nil; core.stop() }

        core.save() // A genuine/manual save still requests an upload.
        XCTAssertEqual(observed.counts().admitted, 1)
        for _ in 0..<3 {
            XCTAssertTrue(core.resume())
            XCTAssertTrue(BoundServerSaveRequestGate.withCapturePause(core: core) { core.pause() })
            XCTAssertEqual(core.state, .paused)
        }
        XCTAssertEqual(observed.counts().callbacks, 4, "The actual Delta pause path must have invoked saveHandler each time")
        XCTAssertEqual(observed.counts().admitted, 1, "Capture pauses must not feed another checkpoint request")
        XCTAssertTrue(core.resume()); XCTAssertTrue(core.pause())
        XCTAssertEqual(observed.counts().callbacks, 5)
        XCTAssertEqual(observed.counts().admitted, 2, "A pause outside the capture scope remains a save request")
    }

    func testCapturePauseScopeKeepsOtherThreadNativeSavesAndUnwindsNestedFailure() {
        let source = NSObject(), other = NSObject()
        let gate = BoundServerSaveRequestGate.bind(core: source), otherGate = BoundServerSaveRequestGate.bind(core: other)
        defer { gate.invalidate(); otherGate.invalidate() }
        let observed = FinalSaveCallbackObserver(core: source, gate: gate)
        let completed = DispatchSemaphore(value: 0)
        XCTAssertThrowsError(try BoundServerSaveRequestGate.withCapturePause(core: source) {
            XCTAssertFalse(gate.acceptsCallback(from: source))
            XCTAssertTrue(otherGate.acceptsCallback(from: other), "Capture cannot suppress another core")
            DispatchQueue.global(qos: .userInitiated).async { observed.save(); completed.signal() }
            XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(observed.counts().admitted, 1, "The native thread's real save is independent of the caller's pause save")
            try BoundServerSaveRequestGate.withCapturePause(core: source) {
                XCTAssertFalse(gate.acceptsCallback(from: source)); throw ExpectedFailure.capture
            }
        })
        XCTAssertTrue(gate.acceptsCallback(from: source), "Throwing/nested scopes must not leave save requests disabled")
    }

    func testQueuedSaveCallbackCannotReachSameCoreRebindOrReplacement() async {
        let source = NSObject(), replacement = NSObject()
        let old = BoundServerSaveRequestGate.bind(core: source)
        XCTAssertTrue(old.acceptsCallback(from: source))
        var delivered = 0
        let queued = Task { @MainActor in if old.isCurrent(core: source) { delivered += 1 } }
        let rebound = BoundServerSaveRequestGate.bind(core: source)
        await queued.value
        XCTAssertEqual(delivered, 0, "A callback admitted before a same-core rebind belongs to the old binding")
        XCTAssertFalse(old.acceptsCallback(from: source)); XCTAssertTrue(rebound.acceptsCallback(from: source))
        let next = BoundServerSaveRequestGate.bind(core: replacement)
        defer { rebound.invalidate(); next.invalidate() }
        XCTAssertFalse(rebound.isCurrent(core: replacement))
        old.invalidate() // Retirement of an old binding cannot erase the replacement.
        XCTAssertTrue(rebound.isCurrent(core: source)); XCTAssertTrue(next.isCurrent(core: replacement))
        rebound.invalidate(); XCTAssertFalse(rebound.isCurrent(core: source))
        XCTAssertTrue(next.acceptsCallback(from: replacement))
    }
    private var retryIdentity: BoundMultiplayerRunIdentity {
        .init(run: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!, gameID: "final-save-fixture",
            owner: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            partner: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            roomID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", settingsOwner: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            settings: Data(repeating: 0, count: 32), localSeed: 1, partnerSeed: 2, romSHA256: String(repeating: "a", count: 64))
    }
    private func retryReceipt(_ checkpoint: UUID) -> BoundMultiplayerCheckpointReceipt {
        .init(run: retryIdentity.run, checkpoint: checkpoint, owner: retryIdentity.owner,
            payloadSHA256: String(repeating: "b", count: 64), sharedEventDigest: String(repeating: "c", count: 64))
    }
    private func retrySession(owner: UUID? = nil) throws -> AppCloudSession {
        let owner = owner ?? retryIdentity.owner
        let claims = try JSONSerialization.data(withJSONObject: ["sub": owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
        let token = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try AppCloudSession(owner: owner, key: "fixture", token: "e30.\(token).fixture",
            backend: .init(kind: .legacy, origin: "https://bound.example"))
    }
    private func retryResponse(receipt: BoundMultiplayerCheckpointReceipt, epoch: UInt64 = 1,
                               terminal: Bool = false) throws -> Data {
        var body: [String: Any] = ["version": 2, "save_id": retryIdentity.run.uuidString,
            "identity": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(retryIdentity)),
            "committed": true, "cancelled": false, "epoch": epoch, "revision": 7,
            "cursors": [:], "deliveries": [:], "events": [],
            "saves": [retryIdentity.owner.uuidString.lowercased(): [
                "receipt": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(receipt)), "count": 1, "bytes": 100]]]
        if terminal { body["gameOver"] = ["id": UUID().uuidString, "returnRequested": false, "returned": [], "deleted": false] }
        return try JSONSerialization.data(withJSONObject: body)
    }
    private func retryService(_ rpc: FinalSaveAuthorityRPC) -> BoundNakamaRunService {
        .init(authorizeSaves: { session, _ in try await rpc.authorize(session) }, perform: { try await rpc.perform($0) })
    }
    private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { XCTFail("Async final-save boundary did not settle"); throw ExpectedFailure.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func testHistoryAndExistingUploadDrainBeforeSingleCaptureWithFinalAncestry() async throws {
        let historyGate = FinalSaveGate(), uploadGate = FinalSaveGate()
        defer { historyGate.open(); uploadGate.open() }
        var events = ["own catch"], confirmedHead = "H0", log: [String] = []
        var captureCount = 0, capturedEvents: [String] = [], capturedHead: String?
        var lifetimeEnded = 0
        let boundary = BoundServerFinalSaveBoundary(lifetime: { _ in
            log.append("lifetime begins"); return { lifetimeEnded += 1; log.append("lifetime ends") }
        })
        let history = Task { @MainActor in
            log.append("history waiting"); await historyGate.wait()
            events.append("accepted peer loss"); log.append("history applied")
        }
        let upload = Task { @MainActor in
            log.append("previous upload waiting"); await uploadGate.wait()
            confirmedHead = "H1"; log.append("previous upload confirmed")
        }
        XCTAssertFalse(boundary.begin(drainRequired: true, drain: {
            await history.value; await upload.value
        }, capture: {
            captureCount += 1; capturedEvents = events; capturedHead = confirmedHead
            log.append("immutable capture")
        }, failed: { _ in XCTFail("Unexpected preparation failure") }))
        // Repeated stop/game=nil requests cannot replace the first source owner
        // or substitute a second snapshot while its history is still pending.
        XCTAssertFalse(boundary.begin(drainRequired: false, drain: {}, capture: {
            XCTFail("A second close replaced the admitted final capture")
        }, failed: { _ in XCTFail("Second close should not start work") }))
        historyGate.open()
        try await eventually { events.count == 2 }
        XCTAssertEqual(captureCount, 0)
        XCTAssertEqual(lifetimeEnded, 0, "Background ownership must span the entire drain")
        uploadGate.open()
        try await eventually { boundary.captured }
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(capturedEvents, ["own catch", "accepted peer loss"])
        XCTAssertEqual(capturedHead, "H1", "Ancestry is sampled after the previously owned upload")
        XCTAssertLessThan(try XCTUnwrap(log.firstIndex(of: "history applied")), try XCTUnwrap(log.firstIndex(of: "immutable capture")))
        XCTAssertLessThan(try XCTUnwrap(log.firstIndex(of: "previous upload confirmed")), try XCTUnwrap(log.firstIndex(of: "immutable capture")))
        XCTAssertEqual(lifetimeEnded, 1)
        // An upload failure/retry uses the retained candidate. Calling begin or
        // retry after capture must never observe newer mutable source facts.
        events.append("later fact"); confirmedHead = "H2"
        XCTAssertTrue(boundary.retry())
        XCTAssertTrue(boundary.begin(drainRequired: false, drain: {}, capture: { captureCount += 1 }, failed: { _ in }))
        XCTAssertEqual(captureCount, 1); XCTAssertEqual(capturedHead, "H1")
        XCTAssertEqual(capturedEvents, ["own catch", "accepted peer loss"])
        boundary.release()
        XCTAssertFalse(boundary.ownsSource)
    }

    func testBackgroundExpirationRetainsSourceAndRetriesAfterAcceptedHistoryFinishes() async throws {
        let gate = FinalSaveGate(); defer { gate.open() }
        var expire: (@MainActor () -> Void)?, failures = 0, captures = 0, ends = 0
        var journal: [String] = [], frozen: [String] = []
        let history = Task { @MainActor in await gate.wait(); journal.append("durable remote fact") }
        let boundary = BoundServerFinalSaveBoundary(lifetime: { handler in expire = handler; return { ends += 1 } })
        XCTAssertFalse(boundary.begin(drainRequired: true, drain: { await history.value },
            capture: { captures += 1; frozen = journal }, failed: { _ in failures += 1 }))
        expire?()
        XCTAssertEqual(boundary.phase, .failed); XCTAssertTrue(boundary.ownsSource)
        XCTAssertEqual(captures, 0); XCTAssertEqual(failures, 1); XCTAssertEqual(ends, 1)
        gate.open(); await history.value
        await Task.yield()
        XCTAssertEqual(captures, 0, "Expired preparation may not capture after its old await returns")
        XCTAssertFalse(boundary.retry())
        try await eventually { boundary.captured }
        XCTAssertEqual(captures, 1); XCTAssertEqual(frozen, ["durable remote fact"])
        XCTAssertEqual(ends, 2); XCTAssertNil(boundary.failure)
        boundary.release()
    }

    func testReleasedGenerationCannotCaptureOrClearReplacementOwnership() async throws {
        let oldGate = FinalSaveGate(), newGate = FinalSaveGate()
        defer { oldGate.open(); newGate.open() }
        var oldCapture = 0, newCapture = 0, errors = 0
        let boundary = BoundServerFinalSaveBoundary(lifetime: { _ in {} })
        _ = boundary.begin(drainRequired: true, drain: { await oldGate.wait() },
                           capture: { oldCapture += 1 }, failed: { _ in errors += 1 })
        boundary.release() // Explicit authorized discard/replacement boundary.
        _ = boundary.begin(drainRequired: true, drain: { await newGate.wait() },
                           capture: { newCapture += 1 }, failed: { _ in errors += 1 })
        oldGate.open(); await Task.yield(); await Task.yield()
        XCTAssertEqual(boundary.phase, .draining); XCTAssertEqual(oldCapture, 0); XCTAssertEqual(newCapture, 0)
        newGate.open(); try await eventually { boundary.captured }
        XCTAssertEqual(oldCapture, 0); XCTAssertEqual(newCapture, 1); XCTAssertEqual(errors, 0)
        boundary.release()
    }

    func testCaptureFailureDoesNotPretendQueuedAndRetryUsesRetainedWork() async throws {
        var attempts = 0, completed = 0, failed = 0, lifetimeEnds = 0
        let boundary = BoundServerFinalSaveBoundary(lifetime: { _ in { lifetimeEnds += 1 } })
        XCTAssertFalse(boundary.begin(drainRequired: false, drain: {}, capture: {
            attempts += 1
            if attempts == 1 { throw ExpectedFailure.capture }
            completed += 1
        }, failed: { _ in failed += 1 }))
        XCTAssertEqual(boundary.phase, .failed); XCTAssertTrue(boundary.ownsSource)
        XCTAssertFalse(boundary.captured); XCTAssertEqual(completed, 0)
        XCTAssertTrue(boundary.retry())
        XCTAssertEqual(attempts, 2); XCTAssertEqual(completed, 1); XCTAssertEqual(failed, 1)
        XCTAssertEqual(lifetimeEnds, 2); XCTAssertNil(boundary.failure)
        boundary.release()
    }

    func testPreparationLifetimeTransfersOnlyAfterUploaderOwnsImmutableCapture() {
        var events: [String] = []
        let boundary = BoundServerFinalSaveBoundary(lifetime: { _ in
            events.append("preparation begin"); return { events.append("preparation end") }
        })
        XCTAssertTrue(boundary.begin(drainRequired: false, drain: { XCTFail("No producer was pending") }, capture: {
            events.append("capture"); events.append("uploader lifetime begin")
        }, failed: { _ in XCTFail("Unexpected failure") }))
        XCTAssertEqual(events, ["preparation begin", "capture", "uploader lifetime begin", "preparation end"])
        boundary.release()
    }

    func testUnavailableBackgroundLifetimeRetainsFailureWithoutCapture() {
        var attempts = 0, captureCount = 0, failures = 0
        let boundary = BoundServerFinalSaveBoundary(lifetime: { _ in
            attempts += 1
            if attempts == 1 { throw BoundServerFinalSaveBoundary.Failure.backgroundUnavailable }
            return {}
        })
        XCTAssertFalse(boundary.begin(drainRequired: false, drain: {}, capture: { captureCount += 1 }, failed: { _ in failures += 1 }))
        XCTAssertEqual(captureCount, 0); XCTAssertEqual(failures, 1); XCTAssertTrue(boundary.ownsSource)
        XCTAssertTrue(boundary.retry()); XCTAssertEqual(captureCount, 1)
        boundary.release()
    }

    func testExpirationDuringLifetimeAcquisitionCannotCaptureAndEndsReturnedHandle() {
        var captures = 0, failures = 0, ends = 0
        let boundary = BoundServerFinalSaveBoundary(lifetime: { expire in
            expire()
            return { ends += 1 }
        })
        XCTAssertFalse(boundary.begin(drainRequired: false, drain: {}, capture: { captures += 1 },
                                      failed: { _ in failures += 1 }))
        XCTAssertEqual(boundary.phase, .failed)
        XCTAssertEqual(captures, 0); XCTAssertEqual(failures, 1); XCTAssertEqual(ends, 1)
        boundary.release()
        XCTAssertEqual(ends, 1)
    }

    func testDisposedPreparationEndsBackgroundLifetimeWithoutCapturing() async throws {
        let gate = FinalSaveGate(); defer { gate.open() }
        var captures = 0, ends = 0
        var boundary: BoundServerFinalSaveBoundary? = .init(lifetime: { _ in { ends += 1 } })
        _ = boundary?.begin(drainRequired: true, drain: { await gate.wait() },
                            capture: { captures += 1 }, failed: { _ in XCTFail("Disposed work cannot publish") })
        boundary = nil
        BoundMainActorDisposal.drainPending()
        XCTAssertEqual(ends, 1)
        gate.open(); await Task.yield(); await Task.yield()
        XCTAssertEqual(captures, 0); XCTAssertEqual(ends, 1)
    }

    func testPausedOwnerStaysRetainedWhileDrainOrFailureNeedsRecovery() async throws {
        let gate = FinalSaveGate(); defer { gate.open() }
        var owner: PausedOwner? = PausedOwner()
        weak var retained = owner
        let boundary = BoundServerFinalSaveBoundary(lifetime: { _ in {} })
        _ = boundary.begin(drainRequired: true, drain: { [owner] in
            _ = owner; await gate.wait()
        }, capture: { throw ExpectedFailure.capture }, failed: { _ in })
        owner = nil
        XCTAssertNotNil(retained, "A weak coordinator binding cannot be the sole owner during async drain")
        gate.open(); try await eventually { boundary.phase == .failed }
        XCTAssertNotNil(retained, "Failed capture retains the same native owner for explicit recovery")
        boundary.release()
        try await eventually { retained == nil }
    }

    func testSelectionHandoffKeepsSourceTokenUntilAcceptedHistoryAndFinalReceiptSettle() async throws {
        let historyGate = FinalSaveGate(), uploadGate = FinalSaveGate(), finalReceipt = FinalSaveGate()
        defer { historyGate.open(); uploadGate.open(); finalReceipt.open() }
        let source = UUID()
        var selection = source, events = ["own catch"], predecessor = "old head"
        var captured: ([String], String)?, captures = 0, confirmed = false, handoffComplete = false
        let history = Task { @MainActor in await historyGate.wait(); events.append("accepted peer loss") }
        let previousUpload = Task { @MainActor in await uploadGate.wait(); predecessor = "confirmed head" }
        let boundary = BoundServerFinalSaveBoundary(lifetime: { _ in {} })
        _ = boundary.begin(drainRequired: true, drain: {
            await history.value; await previousUpload.value
        }, capture: {
            guard selection == source else { throw CancellationError() }
            captures += 1; captured = (events, predecessor)
        }, failed: { _ in XCTFail("Selection changed the source before capture") })
        let handoff = Task { @MainActor in
            let destination = try await BoundServerFinalSaveBoundary.nextSelection(after: selection,
                current: { selection }, settle: { token in
                    XCTAssertEqual(token, source)
                    await boundary.task?.value
                    guard boundary.captured else { throw ExpectedFailure.capture }
                    await finalReceipt.wait(); confirmed = true
                    boundary.release()
                })
            selection = destination; handoffComplete = true
        }
        historyGate.open(); await history.value
        XCTAssertEqual(selection, source); XCTAssertNil(captured)
        uploadGate.open(); try await eventually { boundary.captured }
        XCTAssertEqual(selection, source, "Captured bytes alone do not authorize a new selection")
        XCTAssertFalse(confirmed); XCTAssertFalse(handoffComplete)
        XCTAssertEqual(captured?.0, ["own catch", "accepted peer loss"])
        XCTAssertEqual(captured?.1, "confirmed head")
        finalReceipt.open(); try await handoff.value
        XCTAssertTrue(confirmed); XCTAssertTrue(handoffComplete)
        XCTAssertNotEqual(selection, source); XCTAssertEqual(captures, 1)
    }

    func testSelectionPreparationFailureRetainsSourceForRetryBeforeDestinationAdmission() async throws {
        let gate = FinalSaveGate(); defer { gate.open() }
        let source = UUID()
        var selection = source, attempts = 0, captured = false
        let boundary = BoundServerFinalSaveBoundary(lifetime: { _ in {} })
        _ = boundary.begin(drainRequired: true, drain: { await gate.wait() }, capture: {
            guard selection == source else { throw CancellationError() }
            attempts += 1
            if attempts == 1 { throw ExpectedFailure.capture }
            captured = true
        }, failed: { _ in })
        let attempt = Task { @MainActor in
            try await BoundServerFinalSaveBoundary.nextSelection(after: selection, current: { selection }, settle: { _ in
                await boundary.task?.value
                guard boundary.captured else { throw boundary.failure ?? ExpectedFailure.capture }
            })
        }
        gate.open()
        do { selection = try await attempt.value; XCTFail("Failed preparation admitted another run") }
        catch ExpectedFailure.capture {}
        XCTAssertEqual(selection, source); XCTAssertEqual(boundary.phase, .failed)
        XCTAssertTrue(boundary.ownsSource); XCTAssertFalse(captured)
        _ = boundary.retry(); await boundary.task?.value
        XCTAssertTrue(captured); XCTAssertEqual(attempts, 2)
        let destination = try await BoundServerFinalSaveBoundary.nextSelection(after: selection, current: { selection }, settle: { _ in
            guard boundary.captured else { throw ExpectedFailure.capture }
            boundary.release()
        })
        XCTAssertEqual(selection, source); selection = destination
        XCTAssertNotEqual(selection, source)
    }

    func testSelectionHandoffCannotOverwriteExternallyReplacedExecutionAfterAwait() async throws {
        let gate = FinalSaveGate(); defer { gate.open() }
        let source = UUID(), replacement = UUID()
        var selection = source
        let handoff = Task { @MainActor in
            try await BoundServerFinalSaveBoundary.nextSelection(after: source, current: { selection }, settle: { _ in
                await gate.wait()
            })
        }
        // Account/core replacement has its own authority. Completion of the
        // old drain cannot publish its proposed destination over that owner.
        selection = replacement; gate.open()
        do { selection = try await handoff.value; XCTFail("Stale selection replaced a newer execution") }
        catch is CancellationError {}
        XCTAssertEqual(selection, replacement)
    }

    func testSameOwnerReauthenticationAuthorizesRetainedFinalPreparationWithoutReload() async throws {
        let first = try retrySession(), renewed = try retrySession(), device = UUID(), head = UUID()
        XCTAssertFalse(first.isSameSession(as: renewed))
        let pending = retryReceipt(UUID())
        let authority = BoundObservationRecoveryAuthority(identity: retryIdentity, epoch: 1, confirmedHead: head, pendingReceipt: pending)
        let rpc = FinalSaveAuthorityRPC(response: try retryResponse(receipt: pending))
        var authorizedSession = first, captureSelection = UUID()
        let currentSession = renewed, selection = UUID()
        let retainedFacts = ["accepted own catch", "accepted peer loss"]
        var captures: [[String]] = []
        let boundary = BoundServerFinalSaveBoundary(lifetime: { _ in {} })
        XCTAssertFalse(boundary.begin(drainRequired: false, drain: {}, capture: {
            guard authorizedSession.isSameSession(as: currentSession), captureSelection == selection else { throw ExpectedFailure.capture }
            captures.append(retainedFacts)
        }, failed: { _ in }))
        XCTAssertEqual(boundary.phase, .failed)
        let sourceSelection = selection
        let result = try await authority.revalidateFinalSave(session: renewed, originalSession: first,
            workingStateAuthorized: false, current: authority, retainedDevice: device, currentDevice: device,
            service: retryService(rpc), stillCurrent: { boundary.phase == .failed && selection == sourceSelection && renewed.isSameSession(as: currentSession) })
        XCTAssertEqual(result?.identity, retryIdentity)
        XCTAssertEqual(result?.saves[retryIdentity.owner.uuidString.lowercased()]?.receipt, pending,
            "The exact retained pending receipt can explain a lost upload response")
        authorizedSession = renewed; captureSelection = selection
        XCTAssertTrue(boundary.retry()); XCTAssertEqual(captures, [retainedFacts])
        let counts = await rpc.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, ["get"])
        XCTAssertEqual(authority.confirmedHead, head, "Validation cannot adopt a new upload predecessor")
        boundary.release()
    }

    func testFinalPreparationRejectsForeignOwnerDeviceEpochHeadAndTerminalWithoutLosingFacts() async throws {
        let original = try retrySession(), renewed = try retrySession(), device = UUID(), head = UUID(), pending = retryReceipt(UUID())
        let authority = BoundObservationRecoveryAuthority(identity: retryIdentity, epoch: 1, confirmedHead: head, pendingReceipt: pending)
        var changedPending = pending; changedPending.payloadSHA256 = String(repeating: "d", count: 64)
        let cases: [(AppCloudSession, UUID, UInt64, BoundMultiplayerCheckpointReceipt, Bool, Int)] = [
            (try retrySession(owner: retryIdentity.partner), device, 1, retryReceipt(head), false, 0),
            (renewed, UUID(), 1, retryReceipt(head), false, 0),
            (renewed, device, 2, retryReceipt(head), false, 1),
            (renewed, device, 1, retryReceipt(UUID()), false, 1),
            (renewed, device, 1, changedPending, false, 1),
            (renewed, device, 1, retryReceipt(head), true, 1)
        ]
        for (session, currentDevice, epoch, receipt, terminal, requests) in cases {
            let rpc = FinalSaveAuthorityRPC(response: try retryResponse(receipt: receipt, epoch: epoch, terminal: terminal))
            var owner: PausedOwner? = PausedOwner()
            owner?.facts = ["unuploaded native progress", "permanent peer loss"]
            weak var retainedOwner = owner
            var captures = 0
            let boundary = BoundServerFinalSaveBoundary(lifetime: { _ in {} })
            _ = boundary.begin(drainRequired: false, drain: {}, capture: { [owner] in
                _ = owner; throw ExpectedFailure.capture
            }, failed: { _ in })
            owner = nil
            do {
                _ = try await authority.revalidateFinalSave(session: session, originalSession: original,
                    workingStateAuthorized: false, current: authority, retainedDevice: device, currentDevice: currentDevice,
                    service: retryService(rpc), stillCurrent: { true })
                captures += 1; XCTFail("Rejected authority reached final capture")
            } catch {}
            XCTAssertEqual(captures, 0); XCTAssertEqual(boundary.phase, .failed); XCTAssertTrue(boundary.ownsSource)
            XCTAssertNotNil(retainedOwner)
            XCTAssertEqual(retainedOwner?.facts, ["unuploaded native progress", "permanent peer loss"])
            XCTAssertEqual(authority.confirmedHead, head); XCTAssertEqual(authority.pendingReceipt, pending)
            let counts = await rpc.counts(); XCTAssertEqual(counts.0, requests); XCTAssertEqual(counts.1, requests == 0 ? [] : ["get"])
            boundary.release()
            XCTAssertNil(retainedOwner)
        }
    }

    func testFinalPreparationUnchangedAuthorityCanRetryOffline() async throws {
        let session = try retrySession(), device = UUID(), head = UUID()
        let authority = BoundObservationRecoveryAuthority(identity: retryIdentity, epoch: 1, confirmedHead: head, pendingReceipt: nil)
        let rpc = FinalSaveAuthorityRPC(response: Data(), online: false)
        let result = try await authority.revalidateFinalSave(session: session, originalSession: session,
            workingStateAuthorized: true, current: authority, retainedDevice: device, currentDevice: device,
            service: retryService(rpc), stillCurrent: { true })
        XCTAssertNil(result)
        let counts = await rpc.counts(); XCTAssertEqual(counts.0, 0); XCTAssertTrue(counts.1.isEmpty)
    }

    func testFinalPreparationCannotRenewAuthorityAfterSourceChangesDuringRequest() async throws {
        let original = try retrySession(), renewed = try retrySession(), device = UUID(), head = UUID()
        let authority = BoundObservationRecoveryAuthority(identity: retryIdentity, epoch: 1, confirmedHead: head, pendingReceipt: nil)
        let rpc = FinalSaveAuthorityRPC(response: try retryResponse(receipt: retryReceipt(head)))
        var currentChecks = 0, authorityRenewed = false
        do {
            _ = try await authority.revalidateFinalSave(session: renewed, originalSession: original,
                workingStateAuthorized: false, current: authority, retainedDevice: device, currentDevice: device,
                service: retryService(rpc), stillCurrent: { currentChecks += 1; return currentChecks <= 3 })
            authorityRenewed = true; XCTFail("Stale reply renewed capture authority")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(authorityRenewed)
        let counts = await rpc.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, ["get"])
    }
}
