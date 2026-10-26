import XCTest
@testable import Delta

private actor ObservationRecoveryRPCFixture {
    let response: Data
    let online: Bool
    private var authorizations = 0
    private var actions: [String] = []
    init(response: Data, online: Bool = true) { self.response = response; self.online = online }
    func authorize(_ session: AppCloudSession) throws -> BoundNakamaAuthorization.SaveConfiguration {
        authorizations += 1
        guard online else { throw URLError(.notConnectedToInternet) }
        return .init(httpEndpoint: URL(string: "https://bound.example")!, accessToken: "fixture-token",
            ownerID: session.owner, expiresAt: Date().timeIntervalSince1970 + 90,
            saveTicket: "fixture-ticket", partnerID: nil, roomID: nil)
    }
    func perform(_ request: URLRequest) throws -> Data {
        let text = try JSONDecoder().decode(String.self, from: XCTUnwrap(request.httpBody))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(fields["saveTicket"] as? String, "fixture-ticket")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        actions.append(try XCTUnwrap(fields["action"] as? String))
        return try JSONSerialization.data(withJSONObject: ["payload": String(decoding: response, as: UTF8.self)])
    }
    func counts() -> (Int, [String]) { (authorizations, actions) }
}

@MainActor final class ObservationRecoveryTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let peer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private var identity: BoundMultiplayerRunIdentity {
        .init(run: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!, gameID: "recovery-fixture",
            owner: owner, partner: peer, roomID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", settingsOwner: owner,
            settings: Data(repeating: 0, count: 32), localSeed: 1, partnerSeed: 2, romSHA256: String(repeating: "a", count: 64))
    }
    private func receipt(_ checkpoint: UUID) -> BoundMultiplayerCheckpointReceipt {
        .init(run: identity.run, checkpoint: checkpoint, owner: owner,
            payloadSHA256: String(repeating: "b", count: 64), sharedEventDigest: String(repeating: "c", count: 64))
    }
    private func response(identity value: BoundMultiplayerRunIdentity? = nil,
                          receipt: BoundMultiplayerCheckpointReceipt? = nil, epoch: UInt64 = 1,
                          committed: Bool = true, cancelled: Bool = false, saveID: UUID? = nil,
                          gameOver: BoundNakamaRunService.GameOverState? = nil) throws -> Data {
        let ownSave: [String: Any] = try receipt.map {
            [owner.uuidString.lowercased(): ["receipt": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode($0)),
                                           "count": 1, "bytes": 100]]
        } ?? [:]
        var fields: [String: Any] = ["version": 2,
            "identity": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(value ?? identity)),
            "save_id": (saveID ?? identity.run).uuidString, "committed": committed, "cancelled": cancelled,
            "epoch": epoch, "revision": 7, "cursors": [:], "deliveries": [:], "events": [], "saves": ownSave]
        if let gameOver { fields["gameOver"] = try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(gameOver)) }
        return try JSONSerialization.data(withJSONObject: fields)
    }
    private func decode(_ data: Data) throws -> BoundNakamaRunService.IndependentState {
        try JSONDecoder().decode(BoundNakamaRunService.IndependentState.self, from: data)
    }
    private func session(owner value: UUID? = nil) throws -> AppCloudSession {
        let value = value ?? owner
        let bytes = try JSONSerialization.data(withJSONObject: ["sub": value.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
        let token = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try AppCloudSession(owner: value, key: "fixture", token: "e30.\(token).fixture",
            backend: .init(kind: .legacy, origin: "https://bound.example"))
    }
    private func service(_ fixture: ObservationRecoveryRPCFixture) -> BoundNakamaRunService {
        .init(authorizeSaves: { session, _ in try await fixture.authorize(session) },
              perform: { request in try await fixture.perform(request) })
    }

    func testReauthenticationUsesFreshSaveAuthorityWithoutReloadingOrUploading() async throws {
        let confirmed = UUID(), pending = receipt(UUID())
        let fence = BoundObservationRecoveryAuthority(identity: identity, epoch: 1, confirmedHead: confirmed, pendingReceipt: pending)
        let firstSession = try session(), reauthenticated = try session()
        XCTAssertFalse(firstSession.isSameSession(as: reauthenticated), "Same owner reauthentication is a new credential generation")
        let fixture = ObservationRecoveryRPCFixture(response: try response(receipt: receipt(confirmed)))
        let state = try await fence.revalidate(session: reauthenticated, service: service(fixture), stillCurrent: { true })
        XCTAssertEqual(state.identity, identity)
        let counts = await fixture.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, ["get"], "Recovery validates the retained execution; it does not download or overwrite it")
        XCTAssertEqual(fence.confirmedHead, confirmed, "GET never replaces the later upload CAS predecessor")
    }

    func testRetainedSameSessionAndExecutionRetriesOfflineWithoutAnyAuthorizationRequest() async throws {
        let fence = BoundObservationRecoveryAuthority(identity: identity, epoch: 1,
            confirmedHead: UUID(), pendingReceipt: receipt(UUID()))
        let currentSession = try session()
        let fixture = ObservationRecoveryRPCFixture(response: Data(), online: false)
        let state = try await fence.revalidateIfRequired(session: currentSession, originalSession: currentSession,
            workingStateAuthorized: true, current: fence, service: service(fixture), stillCurrent: { true })
        XCTAssertNil(state, "Local persistence recovery must preserve independent offline gameplay")
        let counts = await fixture.counts()
        XCTAssertEqual(counts.0, 0); XCTAssertTrue(counts.1.isEmpty)
    }

    func testRevokedAuthorityNewSessionOrChangedHeadCannotUseOfflineRetry() async throws {
        let confirmed = UUID(), pending = receipt(UUID()), originalSession = try session()
        let fence = BoundObservationRecoveryAuthority(identity: identity, epoch: 1,
            confirmedHead: confirmed, pendingReceipt: pending)
        let changedHead = BoundObservationRecoveryAuthority(identity: identity, epoch: 1,
            confirmedHead: pending.checkpoint, pendingReceipt: pending)
        let cases: [(AppCloudSession, AppCloudSession?, Bool, BoundObservationRecoveryAuthority)] = [
            (originalSession, originalSession, false, fence),
            (try session(), originalSession, true, fence),
            (originalSession, nil, true, fence),
            (originalSession, originalSession, true, changedHead)
        ]
        for (currentSession, previousSession, authorized, currentFence) in cases {
            let fixture = ObservationRecoveryRPCFixture(response: try response(receipt: receipt(confirmed)), online: false)
            do {
                _ = try await fence.revalidateIfRequired(session: currentSession, originalSession: previousSession,
                    workingStateAuthorized: authorized, current: currentFence, service: service(fixture), stillCurrent: { true })
                XCTFail("Changed authority must not resume without server revalidation")
            } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
            let counts = await fixture.counts()
            XCTAssertEqual(counts.0, 1); XCTAssertTrue(counts.1.isEmpty)
        }
    }

    func testLostUploadResponseRequiresExactPendingReceiptAndRetainsCASPredecessor() throws {
        let confirmed = UUID(), pending = receipt(UUID())
        let fence = BoundObservationRecoveryAuthority(identity: identity, epoch: 1, confirmedHead: confirmed, pendingReceipt: pending)
        XCTAssertNoThrow(try fence.validate(decode(response(receipt: pending))))
        var wrongBytes = pending; wrongBytes.payloadSHA256 = String(repeating: "d", count: 64)
        XCTAssertThrowsError(try fence.validate(decode(response(receipt: wrongBytes))))
        XCTAssertThrowsError(try fence.validate(decode(response(receipt: receipt(UUID())))))
        XCTAssertThrowsError(try fence.validate(decode(response())))
        XCTAssertEqual(fence.confirmedHead, confirmed)
        XCTAssertEqual(fence.pendingReceipt, pending)
        let fresh = BoundObservationRecoveryAuthority(identity: identity, epoch: 1, confirmedHead: nil, pendingReceipt: pending)
        XCTAssertNoThrow(try fresh.validate(decode(response())))
        XCTAssertNoThrow(try fresh.validate(decode(response(receipt: pending))))
    }

    func testRevalidationRejectsChangedIdentityEpochAndCancelledRun() throws {
        let confirmed = UUID()
        let fence = BoundObservationRecoveryAuthority(identity: identity, epoch: 1, confirmedHead: confirmed, pendingReceipt: nil)
        var variants = [BoundMultiplayerRunIdentity]()
        var changed = identity; changed.owner = peer; variants.append(changed)
        changed = identity; changed.gameID = "other-game"; variants.append(changed)
        changed = identity; changed.romSHA256 = String(repeating: "d", count: 64); variants.append(changed)
        changed = identity; changed.localSeed += 1; variants.append(changed)
        changed = identity; changed.settings.append(1); variants.append(changed)
        for changed in variants {
            XCTAssertThrowsError(try fence.validate(decode(response(identity: changed, receipt: receipt(confirmed)))))
        }
        XCTAssertThrowsError(try fence.validate(decode(response(receipt: receipt(confirmed), epoch: 2))))
        XCTAssertThrowsError(try fence.validate(decode(response(receipt: receipt(confirmed), committed: false))))
        XCTAssertThrowsError(try fence.validate(decode(response(receipt: receipt(confirmed), cancelled: true))))
        XCTAssertThrowsError(try fence.validate(decode(response(receipt: receipt(confirmed), saveID: UUID()))))
    }

    func testDifferentOwnerCannotRequestRecoveryAuthority() async throws {
        let fence = BoundObservationRecoveryAuthority(identity: identity, epoch: 1, confirmedHead: nil, pendingReceipt: nil)
        let fixture = ObservationRecoveryRPCFixture(response: try response())
        do {
            _ = try await fence.revalidate(session: session(owner: peer), service: service(fixture), stillCurrent: { true })
            XCTFail("A partner account must not authorize the retained owner's execution")
        } catch { XCTAssertTrue(error is BoundMultiplayerSaveStore.Failure) }
        let counts = await fixture.counts()
        XCTAssertEqual(counts.0, 0); XCTAssertTrue(counts.1.isEmpty)
    }

    func testAccountOrSelectionReplacementDuringEitherAwaitRejectsStaleAuthority() async throws {
        let fence = BoundObservationRecoveryAuthority(identity: identity, epoch: 1, confirmedHead: nil, pendingReceipt: nil)
        for lastCurrentCheck in [1, 2] {
            let fixture = ObservationRecoveryRPCFixture(response: try response())
            var checks = 0
            do {
                _ = try await fence.revalidate(session: session(), service: service(fixture), stillCurrent: {
                    checks += 1; return checks <= lastCurrentCheck
                })
                XCTFail("A response from an obsolete session/selection must not grant execution authority")
            } catch { XCTAssertTrue(error is CancellationError) }
            let counts = await fixture.counts()
            XCTAssertEqual(counts.0, 1)
            XCTAssertEqual(counts.1, lastCurrentCheck == 1 ? [] : ["get"])
        }
    }

    func testAuthenticatedTerminalResultStillRequiresExactOwnerIdentityEpochAndKnownHead() async throws {
        let confirmed = UUID()
        let fence = BoundObservationRecoveryAuthority(identity: identity, epoch: 1, confirmedHead: confirmed, pendingReceipt: nil)
        let terminal = BoundNakamaRunService.GameOverState(id: UUID(), returnRequested: true, returned: [peer], deleted: false)
        let fixture = ObservationRecoveryRPCFixture(response: try response(receipt: receipt(confirmed), gameOver: terminal))
        let state = try await fence.revalidate(session: session(), service: service(fixture), stillCurrent: { true })
        XCTAssertEqual(state.gameOver, terminal, "The coordinator can drain facts and enter its existing terminal flow without resuming")
        let counts = await fixture.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, ["get"])
        var otherOwner = identity; otherOwner.owner = peer
        XCTAssertThrowsError(try fence.validate(decode(response(identity: otherOwner, receipt: receipt(confirmed), gameOver: terminal))))
        XCTAssertThrowsError(try fence.validate(decode(response(receipt: receipt(confirmed), epoch: 2, gameOver: terminal))))
        XCTAssertThrowsError(try fence.validate(decode(response(receipt: receipt(UUID()), gameOver: terminal))),
            "Terminal status cannot bless an unknown advanced checkpoint")
        let invalid = BoundNakamaRunService.GameOverState(id: terminal.id, returnRequested: true, returned: [UUID()], deleted: false)
        XCTAssertThrowsError(try fence.validate(decode(response(receipt: receipt(confirmed), gameOver: invalid))))
    }
}
