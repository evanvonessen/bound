import XCTest
@testable import Delta

@MainActor
final class BoundLobbyTests: XCTestCase {
    private func identity(_ owner: UUID) throws -> AppCloudSession {
        let claims = try JSONSerialization.data(withJSONObject: ["sub": owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try AppCloudSession(owner: owner, key: "fixture", token: "fixture." + payload + ".signature")
    }
    private func member(_ owner: UUID, uid: UInt, state: String = "joined", run: UUID? = nil, partner: UUID? = nil) -> BoundLobbySnapshot.Member {
        .init(ownerID: owner, displayName: "Player \(uid)", uid: uid, state: state, ready: false,
              mode: partner == nil ? "solo" : "soulLink", runID: run, partnerOwnerID: partner,
              online: state == "joined", sessionID: UUID(), generation: "1")
    }
    private func lobby(_ owner: UUID, peer: UUID = UUID(), run: UUID? = nil, partner: UUID? = nil) -> BoundLobbySnapshot {
        .init(lobbyID: UUID(), creatorID: owner, state: "waiting", revision: "1", members: [member(owner, uid: 1, run: run, partner: partner), member(peer, uid: 2, state: "invited")])
    }
    private func reply(_ lobby: BoundLobbySnapshot, token: UUID? = nil) -> BoundLobbyResponse {
        .init(ok: true, lobby: lobby, lobbies: nil, memberToken: token, error: nil, serverTime: 1000, expiresAt: 1090)
    }
    private func listing(_ lobbies: [BoundLobbySnapshot]) -> BoundLobbyResponse {
        .init(ok: true, lobby: nil, lobbies: lobbies, memberToken: nil, error: nil, serverTime: nil, expiresAt: nil)
    }
    private func denial(_ error: String) -> BoundLobbyResponse {
        .init(ok: false, lobby: nil, lobbies: nil, memberToken: nil, error: error, serverTime: nil, expiresAt: nil)
    }
    private func settle(_ client: BoundLobbySession) async {
        for _ in 0..<1000 { if !client.busy { return }; await Task.yield() }
        XCTFail("Lobby request did not complete")
    }
    private final class Fixture {
        var replies: [BoundLobbyResponse] = []
        var requests: [(String, [String: Any])] = []
        var wait = false
        var continuation: CheckedContinuation<Void, Never>?
        var failure: Error?
        func call(_ session: AppCloudSession, _ action: String, _ payload: [String: Any]) async throws -> BoundLobbyResponse {
            requests.append((action, payload))
            if wait { await withCheckedContinuation { continuation = $0 } }
            if let failure { self.failure = nil; throw failure }
            guard !replies.isEmpty else { throw URLError(.badServerResponse) }
            return replies.removeFirst()
        }
        func resume() { wait = false; let pending = continuation; continuation = nil; pending?.resume() }
    }

    func testFourSlotsRequireDistinctAuthenticatedOwnersUIDsAndPublicSessions() {
        let owner = UUID(); var value = lobby(owner)
        value.members += [member(UUID(), uid: 3), member(UUID(), uid: 4)]
        XCTAssertTrue(value.valid)
        var bad = value; bad.members.append(member(UUID(), uid: 5)); XCTAssertFalse(bad.valid)
        bad = value; bad.members[1].uid = 1; XCTAssertFalse(bad.valid)
        bad = value; bad.members[1].ownerID = owner; XCTAssertFalse(bad.valid)
        bad = value; bad.members[1].sessionID = value.members[0].sessionID; XCTAssertFalse(bad.valid)
        bad = value; bad.members[0].sessionID = nil; XCTAssertFalse(bad.valid)
        bad = value; bad.members[0].generation = "0"; XCTAssertFalse(bad.valid)
        bad = value; bad.members[0].displayName = "Player\nInjected"; XCTAssertFalse(bad.valid)
        bad = value; bad.members[0].displayName = String(repeating: "A", count: 41); XCTAssertFalse(bad.valid)
        for invalid in ["0", "-1", "+1", "01", "18446744073709551615"] {
            bad = value; bad.revision = invalid; XCTAssertFalse(bad.valid)
        }
    }
    func testSoloAndPairRunMetadataRemainIndependentOfLobbyAndReadyState() {
        let owner = UUID(), peer = UUID(), pair = UUID(), solo = UUID(); var value = lobby(owner, peer: peer, run: pair, partner: peer)
        value.members[1] = member(peer, uid: 2, run: pair, partner: owner)
        value.members += [member(UUID(), uid: 3, run: solo), member(UUID(), uid: 4, state: "invited")]
        value.members[0].ready = true; value.members[1].ready = true; value.members[2].ready = true
        XCTAssertTrue(value.valid); XCTAssertTrue(value.canStart(owner: owner)); XCTAssertFalse(value.canStart(owner: peer))
        value.members[2].state = "left"; value.members[2].online = false; value.members[2].ready = false
        XCTAssertTrue(value.canStart(owner: owner), "Departed solo run does not block the pair")
        value.members[0].partnerOwnerID = owner; XCTAssertFalse(value.valid)
        value.members[0].partnerOwnerID = peer; value.members[0].mode = "solo"; XCTAssertFalse(value.valid)
        value.members.forEach { XCTAssertNotEqual($0.runID, value.lobbyID) }
    }
    func testEmptyDepartedLobbyAllowsNoCreatorAndNeverStarts() {
        let owner = UUID(); var value = lobby(owner)
        value.members[0].state = "left"; value.members[0].online = false; value.creatorID = nil
        XCTAssertTrue(value.valid); XCTAssertFalse(value.canStart(owner: owner))
        value.members[0].state = "joined"; XCTAssertFalse(value.valid)
    }
    func testGetRetainsTokenButRejectsWrongLobbyAndRegressingRevision() async throws {
        let owner = UUID(), fixture = Fixture(), token = UUID(); var value = lobby(owner); value.revision = "5"
        let client = BoundLobbySession(call: fixture.call); client.bind(session: try identity(owner), gameID: "rom-a")
        fixture.replies = [reply(value, token: token), reply(value, token: token), reply(value)]
        client.create(run: nil, solo: true, partnerRoom: nil, extraRooms: [UUID()]); await settle(client)
        client.tick(active: true, now: 1); await settle(client)
        client.tick(active: true, now: 3); await settle(client)
        XCTAssertEqual(fixture.requests.map(\.0), ["create", "heartbeat", "get"])
        XCTAssertEqual(client.memberToken, token)
        var stale = value; stale.revision = "4"; fixture.replies = [reply(stale)]
        client.tick(active: true, now: 5); await settle(client)
        XCTAssertEqual(client.snapshot?.revision, "5"); XCTAssertNotNil(client.message)
        var wrong = value; wrong.lobbyID = UUID(); wrong.revision = "6"; fixture.replies = [reply(wrong)]
        client.tick(active: true, now: 7); await settle(client)
        XCTAssertEqual(client.snapshot?.lobbyID, value.lobbyID); XCTAssertEqual(client.memberToken, token)
    }
    func testLateReplyCannotRestoreLobbyAfterAccountOrCartridgeSwitch() async throws {
        for switchAccount in [false, true] {
            let owner = UUID(), fixture = Fixture(), value = lobby(owner), session = try identity(owner)
            let client = BoundLobbySession(call: fixture.call); client.bind(session: session, gameID: "rom-a")
            fixture.wait = true; fixture.replies = [reply(value, token: UUID())]
            client.create(run: nil, solo: true, partnerRoom: nil, extraRooms: [UUID()])
            for _ in 0..<1000 { if fixture.continuation != nil { break }; await Task.yield() }
            XCTAssertNotNil(fixture.continuation)
            client.bind(session: switchAccount ? try identity(UUID()) : session, gameID: switchAccount ? "rom-a" : "rom-b")
            fixture.resume(); for _ in 0..<50 { await Task.yield() }
            XCTAssertNil(client.snapshot); XCTAssertNil(client.memberToken); XCTAssertFalse(client.busy)
        }
    }
    func testLeaveAndRejoinKeepOriginalRunAndRotateMembershipToken() async throws {
        let owner = UUID(), peer = UUID(), run = UUID(), fixture = Fixture(), oldToken = UUID(), newToken = UUID(), room = UUID().uuidString.lowercased()
        var value = lobby(owner, peer: peer, run: run, partner: peer)
        let client = BoundLobbySession(call: fixture.call); client.bind(session: try identity(owner), gameID: "rom")
        fixture.replies = [reply(value, token: oldToken)]
        client.create(run: run, solo: false, partnerRoom: room, extraRooms: []); await settle(client)
        value.members[0].state = "left"; value.members[0].online = false; value.creatorID = nil; value.revision = "2"
        fixture.replies = [reply(value), listing([value])]
        client.leave(); await settle(client); XCTAssertNil(client.memberToken); XCTAssertFalse(client.joined)
        client.tick(active: true, now: 1); await settle(client)
        value.members[0].state = "joined"; value.members[0].online = true; value.members[0].sessionID = UUID(); value.members[0].generation = "2"; value.creatorID = owner; value.revision = "3"
        fixture.replies = [reply(value, token: newToken)]
        client.accept(run: run, solo: false, partnerRoom: room); await settle(client)
        XCTAssertEqual(fixture.requests.last?.0, "rejoin"); XCTAssertEqual(fixture.requests.last?.1["runID"] as? String, run.uuidString.lowercased())
        XCTAssertEqual(client.snapshot?.member(owner)?.runID, run); XCTAssertEqual(client.memberToken, newToken); XCTAssertNotEqual(client.memberToken, oldToken)
    }
    func testExpiredOrFencedMembershipReturnsToInvitationDiscovery() async throws {
        for error in ["membership_expired", "fenced"] {
            let owner = UUID(), fixture = Fixture(), value = lobby(owner)
            let client = BoundLobbySession(call: fixture.call); client.bind(session: try identity(owner), gameID: "rom")
            fixture.replies = [reply(value, token: UUID()), denial(error), listing([value]), reply(value, token: UUID())]
            client.create(run: nil, solo: true, partnerRoom: nil, extraRooms: [UUID()]); await settle(client)
            client.tick(active: true, now: 1); await settle(client); XCTAssertNil(client.memberToken); XCTAssertFalse(client.joined)
            client.tick(active: true, now: 2); await settle(client); XCTAssertEqual(fixture.requests.last?.0, "list")
            client.accept(run: nil, solo: true, partnerRoom: nil); await settle(client)
            XCTAssertEqual(fixture.requests.last?.0, "rejoin", "An existing joined slot after restart uses explicit rejoin")
            XCTAssertTrue(client.joined)
        }
    }
    func testUncertainCreateRetriesRequestButSuccessfulNewLobbyGetsNewRequest() async throws {
        let owner = UUID(), fixture = Fixture(), room = UUID(); var value = lobby(owner)
        let client = BoundLobbySession(call: fixture.call); client.bind(session: try identity(owner), gameID: "rom")
        fixture.failure = URLError(.networkConnectionLost)
        client.create(run: nil, solo: true, partnerRoom: nil, extraRooms: [room]); await settle(client)
        let first = fixture.requests.last?.1["requestID"] as? String
        fixture.replies = [reply(value, token: UUID())]
        client.create(run: nil, solo: true, partnerRoom: nil, extraRooms: [room]); await settle(client)
        XCTAssertEqual(fixture.requests.last?.1["requestID"] as? String, first)
        value.members[0].state = "left"; value.members[0].online = false; value.creatorID = nil; value.revision = "2"; fixture.replies = [reply(value)]
        client.leave(); await settle(client)
        fixture.replies = [reply(lobby(owner), token: UUID())]
        client.create(run: nil, solo: true, partnerRoom: nil, extraRooms: [room]); await settle(client)
        XCTAssertNotEqual(fixture.requests.last?.1["requestID"] as? String, first)
    }
    func testMutationWithoutTokenOrWrongRunMetadataNeverJoins() async throws {
        let owner = UUID(), fixture = Fixture(), value = lobby(owner)
        let client = BoundLobbySession(call: fixture.call); client.bind(session: try identity(owner), gameID: "rom")
        fixture.replies = [reply(value)]
        client.create(run: nil, solo: true, partnerRoom: nil, extraRooms: [UUID()]); await settle(client)
        XCTAssertNil(client.snapshot); XCTAssertFalse(client.joined)
        var wrong = value; wrong.members[0].runID = UUID(); fixture.replies = [reply(wrong, token: UUID())]
        client.create(run: nil, solo: true, partnerRoom: nil, extraRooms: [UUID()]); await settle(client)
        XCTAssertNil(client.snapshot); XCTAssertFalse(client.joined)
    }
}
