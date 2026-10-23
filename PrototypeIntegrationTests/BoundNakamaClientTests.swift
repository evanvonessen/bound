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

final class BoundNakamaClientTests: XCTestCase {
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
        var bytes = BoundBattleWire.prefix; bytes.append(Data(repeating: 1, count: 32))
        let channel = BoundNakamaBattleChannel(client: client, targetOwnerID: peer)
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
