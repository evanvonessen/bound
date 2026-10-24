import XCTest
@testable import Delta

private final class NakamaSocketFixture: BoundNakamaSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: (@Sendable (Result<Data, Error>) -> Void)?
    private var incoming: [Data] = []
    private var pending: [@Sendable (Error?) -> Void] = []
    private var held = false
    private var observer: (@Sendable (String) -> Void)?
    private var cancellationCount = 0
    let matchID: String
    init(matchID: String) { self.matchID = matchID }
    func resume() {}
    func observe(_ observer: @escaping @Sendable (String) -> Void) { lock.lock(); self.observer = observer; lock.unlock() }
    func holdSends() { lock.lock(); held = true; lock.unlock() }
    func completeNext() {
        lock.lock(); let next = pending.isEmpty ? nil : pending.removeFirst(); lock.unlock(); next?(nil)
    }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancellationCount > 0 }
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock(); let hold = held, observer = self.observer
        if hold { pending.append(completion) }; lock.unlock()
        observer?(text)
        if !hold { completion(nil) }
        if let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
           value["match_join"] != nil, let cid = value["cid"] as? String {
            deliver(["cid": cid, "match": ["match_id": matchID]])
        }
    }
    func receive(_ completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        lock.lock()
        if !incoming.isEmpty { let data = incoming.removeFirst(); lock.unlock(); completion(.success(data)) }
        else { receiver = completion; lock.unlock() }
    }
    func deliver(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value)
        lock.lock(); let receiver = self.receiver; self.receiver = nil
        if receiver == nil { incoming.append(data) }; lock.unlock(); receiver?(.success(data))
    }
    func cancel() { lock.lock(); cancellationCount += 1; receiver = nil; lock.unlock() }
}

private actor NakamaRPCRecordingFixture {
    private var captured: [URLRequest] = []
    private var authorizationCount = 0
    private let response: Data
    init(response: Data) { self.response = response }
    func perform(_ request: URLRequest) -> Data { captured.append(request); return response }
    func requests() -> [URLRequest] { captured }
    func authorize() { authorizationCount += 1 }
    func authorizations() -> Int { authorizationCount }
}

final class BoundNakamaClientTests: XCTestCase {
    func testAuthorizationFailuresKeepHTTPStatusAndHaveReadableMessages() throws {
        let url = URL(string: "https://bound.example/functions/v1/nakama-session")!
        let request = URLRequest(url: url)
        for status in [400, 401, 403, 404, 408, 429, 500, 503] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            XCTAssertThrowsError(try FriendSharingTokens.validateResponse(response, for: request)) { error in
                XCTAssertEqual(error as? FriendSharingTokenError, .rejected(statusCode: status))
                XCTAssertFalse(error.localizedDescription.contains("FriendSharingTokenError"))
                XCTAssertFalse(error.localizedDescription.contains("error 0"))
                XCTAssertFalse(error.localizedDescription.contains("bound.example"))
            }
        }
        XCTAssertEqual(FriendSharingTokenError.rejected(statusCode: 401).localizedDescription, "Sign in again to use multiplayer.")
        XCTAssertEqual(FriendSharingTokenError.rejected(statusCode: 503).localizedDescription,
                       "The multiplayer server is temporarily unavailable. Please try again.")
        XCTAssertNoThrow(try FriendSharingTokens.validateResponse(
            XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)), for: request))
    }

    func testAuthorizationRejectsRedirectsAndNonHTTPResponses() throws {
        let url = URL(string: "https://bound.example/functions/v1/nakama-session")!
        let request = URLRequest(url: url)
        let redirected = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://other.example/")!, statusCode: 200,
                                                      httpVersion: nil, headerFields: nil))
        let nonHTTP = URLResponse(url: url, mimeType: "application/json", expectedContentLength: 0, textEncodingName: nil)
        for response in [redirected as URLResponse, nonHTTP] {
            XCTAssertThrowsError(try FriendSharingTokens.validateResponse(response, for: request)) { error in
                XCTAssertEqual(error as? FriendSharingTokenError, .invalidResponse)
            }
        }
    }

    func testOnlyTransientAuthorizationFailuresRetryDisconnectSaves() {
        for status in [408, 429, 500, 503] { XCTAssertTrue(FriendSharingTokenError.rejected(statusCode: status).retryable) }
        for status in [400, 401, 403, 404] { XCTAssertFalse(FriendSharingTokenError.rejected(statusCode: status).retryable) }
        XCTAssertTrue(FriendSharingTokenError.unavailable.retryable)
        XCTAssertFalse(FriendSharingTokenError.invalidResponse.retryable)
        XCTAssertFalse(FriendSharingTokenError.unavailable.localizedDescription.contains("error 0"))
    }

    func testNewSaveSendsBothTrainerProfilesAndRetainsThePartnerProfile() async throws {
        let owner = owner, peer = peer, room = room, run = UUID()
        let first = BoundNakamaRunService.PlayerProfile(name: "RED", gender: 0)
        let second = BoundNakamaRunService.PlayerProfile(name: "LEAF", gender: 1)
        let payload = try JSONSerialization.data(withJSONObject: ["sub": owner.uuidString.lowercased(),
                                                                  "exp": Date().timeIntervalSince1970 + 3600])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let session = try AppCloudSession(owner: owner, key: "fixture", token: "e30.\(encoded).fixture",
                                         backend: .init(kind: .legacy, origin: "https://bound.example"))
        let identity = BoundMultiplayerRunIdentity(run: run, gameID: "fixture", owner: owner, partner: peer,
            roomID: room.uuidString.lowercased(), settingsOwner: owner, settings: Data(repeating: 0, count: 32),
            localSeed: 1, partnerSeed: 2, romSHA256: String(repeating: "a", count: 64))
        let service = BoundNakamaRunService(authorizeSaves: { identity, selectedRoom in
            XCTAssertEqual(identity.owner, owner); XCTAssertEqual(selectedRoom, room.uuidString.lowercased())
            return .init(httpEndpoint: URL(string: "https://bound.example")!, accessToken: "fixture-token", ownerID: owner,
                         expiresAt: Date().timeIntervalSince1970 + 90, saveTicket: "fixture-ticket", partnerID: peer, roomID: room)
        }, perform: { request in
            XCTAssertEqual(request.url?.path, "/v2/rpc/bound_independent_v2")
            let text = try JSONDecoder().decode(String.self, from: XCTUnwrap(request.httpBody))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(body["action"] as? String, "create")
            XCTAssertEqual(body["partnerID"] as? String, peer.uuidString.lowercased())
            let profile = try XCTUnwrap(body["profile"] as? [String: Any])
            let partner = try XCTUnwrap(body["partnerProfile"] as? [String: Any])
            XCTAssertEqual(profile["name"] as? String, "RED"); XCTAssertEqual(profile["gender"] as? Int, 0)
            XCTAssertEqual(partner["name"] as? String, "LEAF"); XCTAssertEqual(partner["gender"] as? Int, 1)
            let result: [String: Any] = ["version": 2, "identity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)),
                "committed": true, "cancelled": false, "epoch": 1, "revision": 1, "cursors": [:], "deliveries": [:], "saves": [:], "events": [],
                "save_id": run.uuidString, "profiles": [owner.uuidString.lowercased(): profile, peer.uuidString.lowercased(): partner]]
            let bytes = try JSONSerialization.data(withJSONObject: result)
            return try JSONSerialization.data(withJSONObject: ["payload": String(decoding: bytes, as: UTF8.self)])
        })
        _ = try await service.configureSaves(session: session, room: room.uuidString.lowercased())
        let result = try await service.createSave(gameID: "fixture", romSHA256: identity.romSHA256, settings: identity.settings,
                                                  profile: first, partnerProfile: second, requestID: UUID())
        XCTAssertEqual(result.profiles?[owner.uuidString.lowercased()], first)
        XCTAssertEqual(result.profiles?[peer.uuidString.lowercased()], second)
    }

    func testGameOverUsesExactSaveAndEventAndAcceptsDeletedStatusWithoutGameplayIdentity() async throws {
        let owner = owner, peer = peer, run = UUID(), event = UUID()
        let payload = try JSONSerialization.data(withJSONObject: ["sub": owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
        let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let session = try AppCloudSession(owner: owner, key: "fixture", token: "e30.\(encoded).fixture",
                                         backend: .init(kind: .legacy, origin: "https://bound.example"))
        let state = BoundNakamaRunService.GameOverState(id: event, returnRequested: true, returned: [owner, peer], deleted: true)
        let response = try JSONSerialization.data(withJSONObject: ["payload": String(decoding: JSONEncoder().encode(state), as: UTF8.self)])
        let fixture = NakamaRPCRecordingFixture(response: response)
        let service = BoundNakamaRunService(authorizeSaves: { identity, _ in
            XCTAssertEqual(identity.owner, owner)
            return .init(httpEndpoint: URL(string: "https://bound.example")!, accessToken: "fixture-token", ownerID: owner,
                         expiresAt: Date().timeIntervalSince1970 + 90, saveTicket: "fixture-ticket", partnerID: nil, roomID: nil)
        }, perform: { request in await fixture.perform(request) })
        _ = try await service.configureSaves(session: session)
        for action in ["gameOver", "gameOverReturn", "gameOverMenu", "gameOverStatus"] {
            let actual = try await service.gameOver(saveID: run, action: action, eventID: event)
            XCTAssertEqual(actual, state)
        }
        let discovered = try await service.gameOver(saveID: run, action: "gameOverStatus")
        XCTAssertEqual(discovered, state)
        let requests = await fixture.requests()
        XCTAssertEqual(requests.count, 5)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.url?.path, "/v2/rpc/bound_independent_v2")
            let body = try JSONDecoder().decode(String.self, from: XCTUnwrap(request.httpBody))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            XCTAssertEqual(json["save_id"] as? String, run.uuidString.lowercased())
            XCTAssertEqual(json["saveTicket"] as? String, "fixture-ticket")
            XCTAssertEqual(json["eventID"] as? String, index == 4 ? nil : event.uuidString.lowercased())
            XCTAssertNil(json["returned"]); XCTAssertNil(json["ownerID"])
        }
        for action in ["delete", "gameOverMenu"] {
            do { _ = try await service.gameOver(saveID: run, action: action); XCTFail("Invalid lifecycle request must not send") }
            catch { XCTAssertTrue(error is BoundNakamaRunService.Failure) }
        }
        let afterRejected = await fixture.requests()
        XCTAssertEqual(afterRejected.count, 5)
        do { _ = try await service.gameOver(saveID: run, action: "gameOverMenu", eventID: UUID()); XCTFail("A stale event must fail closed") }
        catch { XCTAssertTrue(error is BoundNakamaRunService.Failure) }
    }

    func testIndependentSaveDecodesOptionalGameOverWithoutBreakingOlderResponses() async throws {
        let identity = independentIdentity()
        let terminal = BoundNakamaRunService.GameOverState(id: UUID(), returnRequested: false, returned: [], deleted: false)
        let field = try JSONSerialization.jsonObject(with: JSONEncoder().encode(terminal))
        for (fields, expected) in [([String: Any](), Optional<BoundNakamaRunService.GameOverState>.none), (["gameOver": field], terminal)] {
            let fixture = NakamaRPCRecordingFixture(response: try independentResponse(identity: identity, fields: fields))
            let service = BoundNakamaRunService { request in await fixture.perform(request) }
            await service.configure(configuration())
            let value = try await service.sharedSetup(identity: identity)
            XCTAssertEqual(value.gameOver, expected)
        }
    }

    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let peer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let room = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let user = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let match = "55555555-5555-4555-8555-555555555555.bound"
    private func configuration(endpoint: String = "wss://bound.example/ws?format=json&status=false", expiresAt: TimeInterval? = nil) -> BoundNakamaConfiguration {
        .init(endpoint: URL(string: endpoint)!, accessToken: "private-access-token", expiresAt: expiresAt ?? Date().timeIntervalSince1970 + 90,
              matchID: match, roomID: room, ownerID: owner, nakamaUserID: user,
              joinTicket: "private-membership-ticket", members: [owner, peer], peerOwnerID: peer)
    }
    private func outgoing(_ text: String) -> (opcode: Int, envelope: [String: Any])? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let packet = root["match_data_send"] as? [String: Any], let code = packet["op_code"] as? String,
              let opcode = Int(code), let encoded = packet["data"] as? String, let bytes = Data(base64Encoded: encoded),
              let envelope = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return nil }
        return (opcode, envelope)
    }
    private func incoming(opcode: Int, envelope: [String: Any]) -> [String: Any] {
        let bytes = try! JSONSerialization.data(withJSONObject: envelope)
        return ["match_data": ["match_id": match, "op_code": String(opcode), "data": bytes.base64EncodedString()]]
    }

    func testConfigurationRequiresTLSBoundedLeaseAndRoomIdentityAndRedactsCredentials() throws {
        let value = configuration()
        XCTAssertTrue(value.isValid(room: room, owner: owner))
        XCTAssertFalse(value.isValid(room: UUID(), owner: owner))
        XCTAssertFalse(configuration(endpoint: "ws://bound.example/ws?format=json").isValid())
        XCTAssertFalse(configuration(endpoint: "wss://bound.example/ws?format=json&token=injected").isValid())
        XCTAssertFalse(configuration(endpoint: "wss://bound.example/ws?format=json&format=json").isValid())
        XCTAssertFalse(configuration(expiresAt: Date().timeIntervalSince1970 - 1).isValid())
        XCTAssertFalse(configuration(expiresAt: Date().timeIntervalSince1970 + 300).isValid())
        XCTAssertFalse(String(reflecting: value).contains(value.accessToken))
        XCTAssertFalse(String(describing: value.customMirror).contains(value.joinTicket))
        let url = try XCTUnwrap(value.socketURL)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "token" })?.value, value.accessToken)
        XCTAssertEqual(query.first(where: { $0.name == "status" })?.value, "false")
    }

    func testJoinsWithSignedTicketAndSendsTargetedBattleWithoutBlockingOnSocketCompletion() async throws {
        let socket = NakamaSocketFixture(matchID: match), client = BoundNakamaClient(socketFactory: { _ in socket })
        defer { client.stop() }
        let joined = expectation(description: "joined"), battleSent = expectation(description: "battle encoded")
        let owner = owner, peer = peer
        socket.observe { text in
            if let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let join = root["match_join"] as? [String: Any] {
                XCTAssertEqual((join["metadata"] as? [String: String])?["bound_ticket"], "private-membership-ticket")
            }
            guard let packet = self.outgoing(text), packet.opcode == 3 else { return }
            XCTAssertEqual(packet.envelope["targetOwnerID"] as? String, peer.uuidString.lowercased())
            XCTAssertNil(packet.envelope["senderOwnerID"])
            battleSent.fulfill()
        }
        try client.start(configuration: configuration()) { event in if case .joined = event { joined.fulfill() } }
        await fulfillment(of: [joined], timeout: 2)
        socket.holdSends()
        // BFS2 ACK-only frame: activity UUID, zero sequence, cumulative ACK,
        // and zero payload length. This smallest real frame must be admitted.
        var bytes = BoundBattleWire.prefix, activity = UUID().uuid
        withUnsafeBytes(of: &activity) { bytes.append(contentsOf: $0) }
        bytes.append(Data(repeating: 0, count: 18))
        let channel = BoundNakamaBattleChannel(client: client, targetOwnerID: peer)
        XCTAssertEqual(bytes.count, 38)
        XCTAssertFalse(channel.send(Data(bytes.dropLast())))
        XCTAssertTrue(channel.send(bytes))
        await fulfillment(of: [battleSent], timeout: 2)
        // Socket completion remains withheld: callers still enqueue immediately.
        XCTAssertTrue(channel.send(bytes))
        channel.close(); XCTAssertFalse(channel.send(bytes))
        XCTAssertFalse(client.sendBattle(bytes, targetOwnerID: owner))
    }

    func testPresenceMailboxKeepsOnlyNewestPendingPose() async throws {
        let socket = NakamaSocketFixture(matchID: match), client = BoundNakamaClient(socketFactory: { _ in socket })
        defer { client.stop() }
        let joined = expectation(description: "joined"), first = expectation(description: "first pose"), newest = expectation(description: "newest pose")
        socket.observe { text in
            guard let packet = self.outgoing(text), packet.opcode == 1, let body = packet.envelope["body"] as? String, let data = Data(base64Encoded: body) else { return }
            if data == Data([1]) { first.fulfill() }
            else if data == Data([3]) { newest.fulfill() }
            else { XCTFail("Superseded pose should not be sent") }
        }
        try client.start(configuration: configuration()) { event in if case .joined = event { joined.fulfill() } }
        await fulfillment(of: [joined], timeout: 2)
        socket.holdSends()
        XCTAssertTrue(client.sendPresence(Data([1])))
        await fulfillment(of: [first], timeout: 2)
        XCTAssertTrue(client.sendPresence(Data([2]))); XCTAssertTrue(client.sendPresence(Data([3])))
        socket.completeNext()
        await fulfillment(of: [newest], timeout: 2)
    }

    func testReliableOverflowFailsAndFencesFurtherSends() async throws {
        let socket = NakamaSocketFixture(matchID: match), client = BoundNakamaClient(socketFactory: { _ in socket })
        defer { client.stop() }
        let joined = expectation(description: "joined"), first = expectation(description: "first command"), failed = expectation(description: "bounded failure")
        socket.observe { text in if self.outgoing(text)?.opcode == 2 { first.fulfill() } }
        try client.start(configuration: configuration()) { event in
            if case .joined = event { joined.fulfill() }
            if case .failed(let reason) = event { XCTAssertEqual(reason, .queueFull); failed.fulfill() }
        }
        await fulfillment(of: [joined], timeout: 2)
        socket.holdSends(); XCTAssertTrue(client.sendInteraction(Data([1])))
        await fulfillment(of: [first], timeout: 2)
        for _ in 0..<BoundNakamaClient.maximumReliablePackets { XCTAssertTrue(client.sendInteraction(Data([2]))) }
        XCTAssertFalse(client.sendInteraction(Data([3])))
        XCTAssertFalse(client.sendPresence(Data([4])))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(socket.cancelled)
        XCTAssertFalse(client.sendInteraction(Data([5])))
    }

    func testAuthenticatesSenderAndDecodesRosterWithoutTrustingClientIdentity() async throws {
        let socket = NakamaSocketFixture(matchID: match), client = BoundNakamaClient(socketFactory: { _ in socket })
        defer { client.stop() }
        let joined = expectation(description: "joined"), roster = expectation(description: "roster"), message = expectation(description: "peer data"), failed = expectation(description: "foreign sender rejected")
        let peer = peer, owner = owner
        try client.start(configuration: configuration()) { event in
            switch event {
            case .joined: joined.fulfill()
            case .roster(let members): XCTAssertEqual(members, [.init(ownerID: owner, online: true), .init(ownerID: peer, online: true)]); roster.fulfill()
            case .message(let opcode, let data, let sender): XCTAssertEqual(opcode, 2); XCTAssertEqual(data, Data([9])); XCTAssertEqual(sender, peer); message.fulfill()
            case .failed(let reason): XCTAssertEqual(reason, .invalidMessage); failed.fulfill()
            case .retainedPresence: XCTFail("Unexpected retained snapshot")
            }
        }
        await fulfillment(of: [joined], timeout: 2)
        socket.deliver(incoming(opcode: 4, envelope: ["v": 1, "members": [["ownerID": owner.uuidString, "online": true], ["ownerID": peer.uuidString, "online": true]]]))
        socket.deliver(incoming(opcode: 2, envelope: ["v": 1, "senderOwnerID": peer.uuidString, "body": Data([9]).base64EncodedString()]))
        await fulfillment(of: [roster, message], timeout: 2)
        socket.deliver(incoming(opcode: 2, envelope: ["v": 1, "senderOwnerID": UUID().uuidString, "body": Data([9]).base64EncodedString()]))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertTrue(socket.cancelled)
    }

    func testRetainedSnapshotsAreSeparateFromFreshPeerMessages() async throws {
        let socket = NakamaSocketFixture(matchID: match), client = BoundNakamaClient(socketFactory: { _ in socket })
        defer { client.stop() }
        let joined = expectation(description:"joined"), retained = expectation(description:"retained snapshot")
        let peer = peer
        try client.start(configuration:configuration()) { event in
            if case .joined = event { joined.fulfill() }
            if case .retainedPresence(let data, let owner, let age) = event {
                XCTAssertEqual(data,Data([1,2])); XCTAssertEqual(owner,peer); XCTAssertEqual(age,12)
                retained.fulfill()
            }
            if case .message = event { XCTFail("Snapshot cannot be admitted as live gameplay") }
        }
        await fulfillment(of:[joined],timeout:2)
        socket.deliver(incoming(opcode:6,envelope:["v":1,"positions":[["ownerID":peer.uuidString,"age":12,"body":Data([1,2]).base64EncodedString()]]]))
        await fulfillment(of:[retained],timeout:2)
    }

    func testDurableRunRPCUsesCurrentTicketWithoutOpeningAGameplaySocket() async throws {
        let owner = owner, peer = peer, room = room, run = UUID()
        let service = BoundNakamaRunService { request in
            XCTAssertEqual(request.url?.absoluteString,"https://bound.example/v2/rpc/bound_run_v1")
            XCTAssertEqual(request.httpMethod,"POST")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer private-access-token")
            let json = try JSONDecoder().decode(String.self,from:XCTUnwrap(request.httpBody))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any])
            XCTAssertEqual(body["ticket"] as? String,"private-membership-ticket")
            XCTAssertEqual(body["action"] as? String,"session")
            XCTAssertEqual(body["runID"] as? String,run.uuidString.lowercased())
            return try JSONSerialization.data(withJSONObject:["payload":"{\"version\":1,\"revision\":1,\"ended\":false}"])
        }
        await service.configure(configuration())
        let identity = BoundMultiplayerRunIdentity(run:run,gameID:"fixture",owner:owner,partner:peer,
            roomID:room.uuidString,settingsOwner:owner,settings:Data(),localSeed:1,partnerSeed:2,romSHA256:String(repeating:"a",count:64))
        let state = try await service.session(identity:identity,history:String(repeating:"a",count:64),bits:Data([1]),head:nil)
        XCTAssertEqual(state.revision,1); XCTAssertNil(state.pending); XCTAssertNil(state.head)
        var foreign = identity; foreign.owner = peer
        do {
            _ = try await service.session(identity:foreign,history:String(repeating:"a",count:64),bits:Data([1]),head:nil)
            XCTFail("Foreign account cannot use the room ticket")
        } catch { XCTAssertTrue(error is BoundNakamaRunService.Failure) }
    }

    private func independentIdentity() -> BoundMultiplayerRunIdentity {
        .init(run: UUID(), gameID: "local-game", owner: owner, partner: peer, roomID: room.uuidString,
              settingsOwner: owner, settings: Data(repeating: 0, count: 32), localSeed: 1, partnerSeed: 2,
              romSHA256: String(repeating: "a", count: 64))
    }
    private func independentResponse(identity: BoundMultiplayerRunIdentity, fields: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["version": 2, "identity": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(identity)),
            "committed": true, "cancelled": false, "epoch": 1, "revision": 1,
            "cursors": [:], "deliveries": [:], "saves": [:], "events": []]
        value.merge(fields) { _, latest in latest }
        return try JSONSerialization.data(withJSONObject: ["payload": String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self)])
    }
    private func independentBody(_ request: URLRequest) throws -> [String: Any] {
        XCTAssertEqual(request.url?.absoluteString, "https://bound.example/v2/rpc/bound_independent_v2")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer private-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let text = try JSONDecoder().decode(String.self, from: XCTUnwrap(request.httpBody))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(value["ticket"] as? String, "private-membership-ticket")
        return value
    }
    func testIndependentSetupUsesAuthenticatedRPCAndDecodesAnEmptyPartnerStateWithoutReadiness() async throws {
        let identity = independentIdentity()
        let fixture = NakamaRPCRecordingFixture(response: try independentResponse(identity: identity, fields: ["committed": false]))
        let service = BoundNakamaRunService { request in await fixture.perform(request) }
        await service.configure(configuration())
        let state = try await service.sharedSetup(identity: identity)
        XCTAssertEqual(state.identity, identity); XCTAssertFalse(state.committed)
        XCTAssertTrue(state.cursors.isEmpty); XCTAssertTrue(state.deliveries.isEmpty); XCTAssertTrue(state.saves.isEmpty); XCTAssertTrue(state.events.isEmpty)
        let captured = await fixture.requests()
        XCTAssertEqual(captured.count, 1)
        let body = try independentBody(XCTUnwrap(captured.first))
        XCTAssertEqual(body["action"] as? String, "setup")
        XCTAssertEqual(body["runID"] as? String, identity.run.uuidString.lowercased())
        XCTAssertNil(body["peerReady"]); XCTAssertNil(body["checkpoint"])
        let proposed = try XCTUnwrap(body["identity"] as? [String: Any])
        XCTAssertEqual(proposed["localSeed"] as? Int, 1); XCTAssertEqual(proposed["partnerSeed"] as? Int, 2)
        var foreign = identity; foreign.owner = peer
        do { _ = try await service.sharedSetup(identity: foreign); XCTFail("A foreign account cannot reuse this room ticket") }
        catch { XCTAssertTrue(error is BoundNakamaRunService.Failure) }
        let afterRejected = await fixture.requests()
        XCTAssertEqual(afterRejected.count, 1)
    }
    func testIndependentEventsEncodeNestedIDsAndOfflineCursorBeyondUploadedBatchAndDecodeSparseRemoteHistory() async throws {
        let identity = independentIdentity()
        let local = (1...50).map { sequence in
            BoundMultiplayerSharedEvent(run: identity.run, id: .init(origin: owner, sequence: UInt64(sequence)),
                kind: "soul-link", payload: Data([UInt8(sequence)]), idempotencyKey: "death:\(sequence)")
        }
        let remote = BoundMultiplayerSharedEvent(run: identity.run, id: .init(origin: peer, sequence: 2),
            kind: "soul-link", payload: Data("death-before-catch".utf8))
        let fields: [String: Any] = ["cursors": [owner.uuidString.lowercased(): ["contiguous": 16, "sparse": []],
            peer.uuidString.lowercased(): ["contiguous": 0, "sparse": [2]]],
            "deliveries": [peer.uuidString.lowercased(): [owner.uuidString.lowercased(): 8]],
            "legacyHistory": [:], "events": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode([remote]))]
        let fixture = NakamaRPCRecordingFixture(response: try independentResponse(identity: identity, fields: fields))
        let service = BoundNakamaRunService { request in await fixture.perform(request) }
        await service.configure(configuration())
        var cursor = BoundMultiplayerSharedCursor(); local.forEach { cursor.insert($0.id) }; cursor.insert(remote.id)
        let state = try await service.sharedEvents(identity: identity, events: local, cursor: cursor)
        XCTAssertEqual(state.events, [remote])
        XCTAssertEqual(state.serverCursor.origins[owner.uuidString]?.contiguous, 16)
        XCTAssertEqual(state.serverCursor.origins[peer.uuidString]?.sparse, [2])
        XCTAssertEqual(state.peerCursor(peer).origins[owner.uuidString]?.contiguous, 8)
        let captured = await fixture.requests()
        let body = try independentBody(XCTUnwrap(captured.first))
        XCTAssertEqual(body["action"] as? String, "events")
        XCTAssertEqual((body["after"] as? [String: Int])?[owner.uuidString.lowercased()], 50)
        let sent = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 16)
        XCTAssertEqual((sent[0]["id"] as? [String: Any])?["sequence"] as? Int, 1)
        XCTAssertEqual((sent[0]["id"] as? [String: Any])?["origin"] as? String, owner.uuidString)
        XCTAssertNil(sent[0]["sequence"])
        XCTAssertEqual(sent[0]["payload"] as? String, local[0].payload.base64EncodedString())
    }
    func testOfflineWorldEventsAreBatchedWithinTheRPCByteLimitWithoutDroppingTheNextEvent() async throws {
        let identity = independentIdentity()
        let events = (1...16).map { sequence in
            BoundMultiplayerSharedEvent(run: identity.run, id: .init(origin: owner, sequence: UInt64(sequence)),
                kind: "world", payload: Data(repeating: UInt8(sequence), count: 3600))
        }
        let fixture = NakamaRPCRecordingFixture(response: try independentResponse(identity: identity))
        let service = BoundNakamaRunService { request in await fixture.perform(request) }
        await service.configure(configuration())
        _ = try await service.sharedEvents(identity: identity, events: events, cursor: .init())
        let captured = await fixture.requests()
        let body = try independentBody(XCTUnwrap(captured.first))
        let sent = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertGreaterThan(sent.count, 0)
        XCTAssertLessThan(sent.count, events.count)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: body).count, 20000)
        let next = Array(events.dropFirst(sent.count))
        _ = try await service.sharedEvents(identity: identity, events: next, cursor: .init())
        let retryRequests = await fixture.requests()
        let retryBody = try independentBody(XCTUnwrap(retryRequests.last))
        let retryEvents = try XCTUnwrap(retryBody["events"] as? [[String: Any]])
        XCTAssertEqual((retryEvents.first?["id"] as? [String: Any])?["sequence"] as? Int, sent.count + 1)
    }
    func testIndependentUploadChunksOnlyOnePlayersSaveAndCarriesExpectedServerHeadOnEveryRequest() async throws {
        let identity = independentIdentity(), checkpoint = UUID(), predecessor = UUID()
        let files: [String: BoundMultiplayerSavePackage.Blob] = ["game.sav": .init(Data(repeating: 7, count: 131_072)),
            "checkpoint.state": .init(Data(repeating: 8, count: 2048))]
        let payload = BoundMultiplayerSavePackage.Payload(version: 2, manifest: .init(identity: identity, deviceOwner: user),
            checkpoint: checkpoint, predecessor: predecessor, sharedEventDigest: String(repeating: "b", count: 64), files: files)
        let bytes = try BoundMultiplayerSaveStore.encode(payload), encoded = bytes.base64EncodedString()
        let receipt = BoundMultiplayerCheckpointReceipt(run: identity.run, checkpoint: checkpoint, owner: owner,
            payloadSHA256: BoundMultiplayerSaveStore.hash(bytes), sharedEventDigest: payload.sharedEventDigest)
        let package = BoundMultiplayerSavePackage(payload: payload, receipt: receipt)
        XCTAssertTrue(package.complete); XCTAssertNil(package.partnerReceipt)
        let count = (encoded.utf8.count + 11999) / 12000
        let upload: [String: Any] = ["receipt": try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(receipt)), "bytes": bytes.count, "count": count]
        let fixture = NakamaRPCRecordingFixture(response: try independentResponse(identity: identity,
            fields: ["saves": [owner.uuidString.lowercased(): upload]]))
        let service = BoundNakamaRunService { request in await fixture.perform(request) }
        await service.configure(configuration())
        let state = try await service.uploadIndependent(package, expectedHead: predecessor, authorize: { await fixture.authorize() })
        XCTAssertEqual(Set(state.saves.keys), [owner.uuidString.lowercased()])
        XCTAssertEqual(state.saves[owner.uuidString.lowercased()]?.receipt, receipt)
        let captured = await fixture.requests()
        XCTAssertEqual(captured.count, count + 2)
        let authorizations = await fixture.authorizations()
        XCTAssertEqual(authorizations, count + 2, "Long uploads recheck local device authority before every chunk and seal")
        let bodies = try captured.map(independentBody)
        XCTAssertEqual(bodies.first?["action"] as? String, "save")
        XCTAssertEqual(bodies.last?["action"] as? String, "saveSeal")
        var chunks = [Int: String]()
        for body in bodies {
            XCTAssertEqual(body["expectedHead"] as? String, predecessor.uuidString.lowercased())
            XCTAssertEqual(body["checkpoint"] as? String, checkpoint.uuidString.lowercased())
            XCTAssertEqual(body["bytes"] as? Int, bytes.count)
            XCTAssertNil(body["partnerReceipt"]); XCTAssertNil(body["peerReady"])
            if body["action"] as? String == "saveChunk" {
                chunks[try XCTUnwrap(body["index"] as? Int)] = try XCTUnwrap(body["data"] as? String)
            }
        }
        XCTAssertEqual(chunks.count, count)
        XCTAssertEqual((0..<count).compactMap { chunks[$0] }.joined(), encoded)
    }

    func testStopDropsQueuedTrafficAndTicketRenewalUsesReservedOpcode() async throws {
        let socket = NakamaSocketFixture(matchID: match), client = BoundNakamaClient(socketFactory: { _ in socket })
        let joined = expectation(description: "joined"), renewed = expectation(description: "renewed")
        socket.observe { text in
            guard let packet = self.outgoing(text), packet.opcode == 5 else { return }
            XCTAssertEqual(packet.envelope["ticket"] as? String, "renewed-private-ticket")
            XCTAssertNil(packet.envelope["body"]); renewed.fulfill()
        }
        try client.start(configuration: configuration()) { event in if case .joined = event { joined.fulfill() } }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertTrue(client.renewTicket("renewed-private-ticket", expiresAt: Date().timeIntervalSince1970 + 90))
        await fulfillment(of: [renewed], timeout: 2)
        client.stop()
        XCTAssertTrue(socket.cancelled)
        XCTAssertFalse(client.sendPresence(Data([1])))
        XCTAssertFalse(client.renewTicket("ticket", expiresAt: Date().timeIntervalSince1970 + 90))
    }
}
