import XCTest
import UIKit
import Combine
@testable import Delta

private final class NakamaTransportWire: BoundNakamaSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let match: String
    private var receiver: (@Sendable (Result<Data, Error>) -> Void)?
    private var savedReceiver: (@Sendable (Result<Data, Error>) -> Void)?
    private var pending: [Data] = []
    private var observer: (@Sendable (String) -> Void)?
    private var completions: [@Sendable (Error?) -> Void] = []
    private var held = false
    init(match: String) { self.match = match }
    func resume() {}
    func observe(_ observer: @escaping @Sendable (String) -> Void) { lock.lock(); self.observer = observer; lock.unlock() }
    func holdSends() { lock.lock(); held = true; lock.unlock() }
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock(); let observer = self.observer, held = self.held
        if held { completions.append(completion) }; lock.unlock()
        observer?(text)
        if !held { completion(nil) }
        if let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
           value["match_join"] != nil, let cid = value["cid"] as? String { deliver(["cid": cid, "match": ["match_id": match]]) }
    }
    func receive(_ completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        lock.lock(); savedReceiver = completion
        if !pending.isEmpty { let data = pending.removeFirst(); lock.unlock(); completion(.success(data)) }
        else { receiver = completion; lock.unlock() }
    }
    func deliver(_ value: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: value)
        lock.lock(); let receiver = self.receiver; self.receiver = nil
        if receiver == nil { pending.append(bytes) }; lock.unlock(); receiver?(.success(bytes))
    }
    func deliverStaleFailure() {
        lock.lock(); let callback = savedReceiver; lock.unlock(); callback?(.failure(URLError(.networkConnectionLost)))
    }
    func cancel() { lock.lock(); receiver = nil; pending.removeAll(); lock.unlock() }
}

private final class NakamaTransportWirePool: @unchecked Sendable {
    private let lock = NSLock()
    private var wires: [NakamaTransportWire]
    init(_ wires: [NakamaTransportWire]) { self.wires = wires }
    func next() -> NakamaTransportWire { lock.lock(); defer { lock.unlock() }; return wires.removeFirst() }
}

@MainActor private final class NakamaMediaFixture: FriendSharingTransport {
    var publishedFrames = 0
    var receivedFrames = 0
    var starts = 0
    var stops = 0
    var frameSends = 0
    var presenceSends = 0
    var interactionSends = 0
    var battleChannels = 0
    var tokenRenewals = 0
    var renewalAccepted = false
    var started: (() -> Void)?
    var callbacks: [@MainActor (FriendSharingEvent) -> Void] = []
    func start(configuration: FriendSharingConfiguration, remoteView: UIView, event: @escaping @MainActor (FriendSharingEvent) -> Void) {
        starts += 1; callbacks.append(event); event(.joined); started?()
    }
    func stop() { stops += 1 }
    func renewToken(_ token: String) -> Bool { tokenRenewals += 1; return renewalAccepted }
    func sendPresence(_ data: Data) -> Bool { presenceSends += 1; return true }
    func sendInteraction(_ data: Data) -> Bool { interactionSends += 1; return true }
    func makeBattleChannel(receiver: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable () -> Void) -> (any BoundBattleChannel)? {
        battleChannels += 1; return nil
    }
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        frameSends += 1; completion(.failure(.transport("fixture video outage"))); return NakamaFrameCancellation()
    }
}
@MainActor private final class NakamaFrameCancellation: SharingCancellation { func cancel() {} }

@MainActor final class NakamaSharingTransportTests: XCTestCase {
    func testAgoraMediaHasNoGameplayChannel() {
        let media: any FriendSharingTransport = AgoraSharingTransport()
        XCTAssertFalse(media.sendPresence(Data([1])))
        XCTAssertFalse(media.sendInteraction(Data("BRM1fixture".utf8)))
        XCTAssertNil(media.makeBattleChannel(receiver: { _ in }, failed: {}))
        XCTAssertEqual(media.presenceConnectionCheck.kind, .unavailable)
    }

    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let peer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let room = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let user = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let match = "55555555-5555-4555-8555-555555555555.bound"
    private var previousExperimentalFeature: Any?
    override func setUp() {
        super.setUp(); previousExperimentalFeature = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
    }
    override func tearDown() {
        UserDefaults.standard.set(previousExperimentalFeature, forKey: BoundMultiplayerFeatures.key)
        NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil); super.tearDown()
    }
    private var lease: BoundNakamaConfiguration {
        .init(endpoint: URL(string: "wss://bound.example/ws?format=json&status=false")!, accessToken: "fixture-access-token",
              expiresAt: Date().timeIntervalSince1970 + 90, matchID: match, roomID: room,
              ownerID: owner, nakamaUserID: user, joinTicket: "fixture-join-ticket", members: [owner, peer], peerOwnerID: peer)
    }
    private var mediaConfiguration: FriendSharingConfiguration {
        .init(appID: String(repeating: "0", count: 32), channel: "fixture-video", uid: 1, remoteUID: 2, token: "fixture-video-token")
    }
    private func battleFrame() -> Data { BoundBattleWire.prefix + Data(repeating: 1, count: 32) }
    nonisolated private static func outgoing(_ text: String) -> (Int, Data)? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let packet = root["match_data_send"] as? [String: Any], let code = packet["op_code"] as? String,
              let opcode = Int(code), let encoded = packet["data"] as? String, let envelopeBytes = Data(base64Encoded: encoded),
              let envelope = (try? JSONSerialization.jsonObject(with: envelopeBytes)) as? [String: Any],
              let body = envelope["body"] as? String, let bytes = Data(base64Encoded: body) else { return nil }
        return (opcode, bytes)
    }
    private func incoming(opcode: Int, bytes: Data) -> [String: Any] {
        let envelope: [String: Any] = ["v": 1, "senderOwnerID": peer.uuidString, "targetOwnerID": owner.uuidString, "body": bytes.base64EncodedString()]
        return ["match_data": ["match_id": match, "op_code": String(opcode), "data": try! JSONSerialization.data(withJSONObject: envelope).base64EncodedString()]]
    }

    func testDataOnlyRoomRoutesEveryGameplayLaneThroughNakamaWithoutStartingVideo() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        defer { transport.stop() }
        let joined = expectation(description: "gameplay joined"), presence = expectation(description: "Nakama pose"), interaction = expectation(description: "Nakama interaction"), battle = expectation(description: "Nakama battle")
        wire.observe { text in
            guard let (opcode, _) = Self.outgoing(text) else { return }
            switch opcode { case 1: presence.fulfill(); case 2: interaction.fulfill(); case 3: battle.fulfill(); default: XCTFail("Unexpected opcode") }
        }
        transport.configureGameplay(lease); transport.setVideoRequired(false)
        transport.start(configuration: mediaConfiguration, remoteView: UIView()) { if $0 == .joined { joined.fulfill() } }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertEqual(media.starts, 0); XCTAssertFalse(transport.videoPublishing)
        XCTAssertTrue(transport.sendPresence(Data([1, 2, 3])))
        XCTAssertTrue(transport.sendInteraction(Data("BRM1fixture".utf8)))
        let channel = try XCTUnwrap(transport.makeBattleChannel(receiver: { _ in }, failed: {}))
        XCTAssertTrue(channel.send(battleFrame()))
        await fulfillment(of: [presence, interaction, battle], timeout: 2)
        let frame = try SharingFrame(copying: Data(repeating: 0, count: SharingFrame.byteCount), sequence: 1, capturedAt: 0)
        _ = transport.send(frame) { if case .failure = $0 { XCTFail("Disabled video send must settle successfully") } }
        XCTAssertEqual(media.starts, 0); XCTAssertEqual(media.frameSends, 0)
        XCTAssertEqual(media.presenceSends, 0); XCTAssertEqual(media.interactionSends, 0); XCTAssertEqual(media.battleChannels, 0)
        channel.close()
    }

    func testBattleEnqueueAndReceiveContinueWhileMainActorAndSocketSendCompletionAreUnavailable() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        defer { transport.stop() }
        let joined = expectation(description: "joined"), sent = expectation(description: "sent"), received = expectation(description: "battle received off main")
        wire.observe { text in if Self.outgoing(text)?.0 == 3 { sent.fulfill() } }
        transport.configureGameplay(lease)
        transport.start(configuration: mediaConfiguration, remoteView: UIView()) { if $0 == .joined { joined.fulfill() } }
        await fulfillment(of: [joined], timeout: 2)
        wire.holdSends()
        let bytes = battleFrame()
        let channel = try XCTUnwrap(transport.makeBattleChannel(receiver: { data in
            XCTAssertFalse(Thread.isMainThread); XCTAssertEqual(data, bytes); received.fulfill()
        }, failed: { XCTFail("Healthy gameplay must remain active") }))
        let accepted = await Task.detached { channel.send(bytes) }.value
        XCTAssertTrue(accepted)
        await fulfillment(of: [sent], timeout: 2)
        // A withheld send completion cannot block the socket receive lane.
        wire.deliver(incoming(opcode: 3, bytes: bytes))
        await fulfillment(of: [received], timeout: 2)
        channel.close(); XCTAssertFalse(channel.send(bytes))
        XCTAssertEqual(media.starts, 0)
    }

    func testVideoFailureCannotFailOrMoveGameplayToMedia() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        defer { transport.stop() }
        let joined = expectation(description: "joined"), pose = expectation(description: "gameplay still sends")
        wire.observe { text in if Self.outgoing(text)?.0 == 1 { pose.fulfill() } }
        transport.configureGameplay(lease); transport.setVideoRequired(true)
        transport.start(configuration: mediaConfiguration, remoteView: UIView()) { event in
            if event == .joined { joined.fulfill() }
            if case .failed = event { XCTFail("Optional video failure leaked into gameplay") }
        }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertEqual(media.starts, 1); XCTAssertTrue(transport.videoPublishing)
        media.callbacks[0](.failed(.init(.connectionLost)))
        XCTAssertFalse(transport.videoPublishing)
        XCTAssertTrue(transport.sendPresence(Data([1])))
        await fulfillment(of: [pose], timeout: 2)
        media.callbacks[0](.rejoined)
        let frame = try SharingFrame(copying: Data(repeating: 0, count: SharingFrame.byteCount), sequence: 1, capturedAt: 0)
        _ = transport.send(frame) { result in if case .failure = result { XCTFail("A media frame error must not stop gameplay") } }
        XCTAssertEqual(media.frameSends, 1); XCTAssertEqual(media.presenceSends, 0)
        XCTAssertTrue(transport.presenceConnectionCheck.streamCreated)
    }

    func testRejectedOptionalVideoRenewalStopsVideoAndKeepsGameplay() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        defer { transport.videoStateChanged = nil; transport.stop() }
        let joined = expectation(description: "gameplay joined"), videoStopped = expectation(description: "expired video stopped")
        var authorizations = 0
        let owner = owner, room = room.uuidString
        transport.videoAuthorization = {
            authorizations += 1
            return FriendSharingTokenLease(roomID: room, ownerID: owner, appID: String(repeating: "0", count: 32),
                channel: "fixture-video", uid: 1, remoteUID: 2, token: "fixture-video-token",
                issuedAt: Date().timeIntervalSince1970, expiresAt: Date().timeIntervalSince1970 + 31)
        }
        transport.videoStateChanged = {
            if media.tokenRenewals == 1 && !transport.videoPublishing { videoStopped.fulfill() }
        }
        transport.configureGameplay(lease); transport.setVideoRequired(true)
        transport.start(configuration: mediaConfiguration, remoteView: UIView()) { event in
            if event == .joined { joined.fulfill() }
            if case .failed = event { XCTFail("Optional video renewal rejection must not fail gameplay") }
        }
        await fulfillment(of: [joined, videoStopped], timeout: 3)
        XCTAssertEqual(authorizations, 2); XCTAssertEqual(media.tokenRenewals, 1)
        XCTAssertFalse(transport.videoPublishing); XCTAssertTrue(transport.presenceConnectionCheck.streamCreated)
        XCTAssertTrue(transport.sendPresence(Data([1])))
    }

    func testStopRestartFencesOldSocketAndVideoCallbacks() async throws {
        let firstWire = NakamaTransportWire(match: match), secondWire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let pool = NakamaTransportWirePool([firstWire, secondWire])
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in pool.next() }))
        defer { transport.stop() }
        let first = expectation(description: "first joined"), second = expectation(description: "second joined"), stale = expectation(description: "stale callbacks ignored")
        stale.isInverted = true
        transport.configureGameplay(lease); transport.setVideoRequired(true)
        transport.start(configuration: mediaConfiguration, remoteView: UIView()) { if $0 == .joined { first.fulfill() } }
        await fulfillment(of: [first], timeout: 2)
        let oldVideo = media.callbacks[0]
        transport.stop(); transport.configureGameplay(lease); transport.setVideoRequired(false)
        transport.start(configuration: mediaConfiguration, remoteView: UIView()) { event in
            if event == .joined { second.fulfill() } else { stale.fulfill() }
        }
        await fulfillment(of: [second], timeout: 2)
        let channel = try XCTUnwrap(transport.makeBattleChannel(receiver: { _ in stale.fulfill() }, failed: { stale.fulfill() }))
        firstWire.deliverStaleFailure(); oldVideo(.remoteFrame); oldVideo(.failed(.init(.connectionLost)))
        await fulfillment(of: [stale], timeout: 0.1)
        XCTAssertFalse(transport.videoPublishing); XCTAssertTrue(channel.send(battleFrame()))
        XCTAssertEqual(media.starts, 1); channel.close()
    }

    private func identity() throws -> AppCloudSession {
        let bytes = try JSONSerialization.data(withJSONObject: BoundAccountTestFixture.claims(owner: owner, expiry: Date().timeIntervalSince1970 + 3600))
        let payload = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try AppCloudSession(owner: owner, key: "fixture-public-key", token: "fixture.\(payload).signature")
    }

    func testAuthenticatedAutomaticMultiplayerFetchesNakamaOnlyAndStopsOnBackground() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        let identity = try identity(), lease = lease, room = room.uuidString.lowercased()
        var authorizations = 0
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            tokenFetcher: { _, _ in XCTFail("Data-only multiplayer must not request Agora authorization"); throw FriendSharingTokenError.unavailable },
            nakamaFetcher: { requestedRoom, requestedIdentity in
                authorizations += 1; XCTAssertEqual(requestedRoom, room); XCTAssertTrue(requestedIdentity.isSameSession(as: identity)); return lease
            })
        defer { sharing.stop() }
        sharing.configureAuthenticatedRoom(room, identity: { identity })
        let joined = expectation(description: "authenticated gameplay joined")
        let observation = sharing.$joined.dropFirst().filter { $0 }.sink { _ in joined.fulfill() }
        sharing.setAutomaticMultiplayerConnection(true)
        await fulfillment(of: [joined], timeout: 2)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(authorizations, 1); XCTAssertEqual(media.starts, 0)
        XCTAssertTrue(sharing.active); XCTAssertTrue(sharing.joined); XCTAssertFalse(sharing.videoPublishing)
        sharing.background()
        XCTAssertFalse(sharing.active); XCTAssertFalse(sharing.joined)
        XCTAssertFalse(transport.sendPresence(Data([1])))
    }

    func testStoppedAuthorizationCannotOpenAnObsoleteRoom() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        let identity = try identity(), lease = lease
        let requested = expectation(description: "authorization pending"), reopened = expectation(description: "cancelled authorization ignored")
        reopened.isInverted = true
        var pendingAuthorization: CheckedContinuation<BoundNakamaConfiguration, Error>?
        wire.observe { _ in reopened.fulfill() }
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            tokenFetcher: { _, _ in XCTFail("Nakama authorization must not fall back to Agora"); throw FriendSharingTokenError.unavailable },
            nakamaFetcher: { _, _ in
                try await withCheckedThrowingContinuation { pendingAuthorization = $0; requested.fulfill() }
            })
        defer { sharing.stop() }
        sharing.configureAuthenticatedRoom(room.uuidString, identity: { identity })
        sharing.setAutomaticMultiplayerConnection(true)
        await fulfillment(of: [requested], timeout: 2)
        sharing.stop()
        try XCTUnwrap(pendingAuthorization).resume(returning: lease)
        await fulfillment(of: [reopened], timeout: 0.1)
        XCTAssertFalse(sharing.active); XCTAssertFalse(sharing.joined); XCTAssertEqual(media.starts, 0)
    }

    func testDisablingMultiplayerClosesAutomaticRoomWithoutStartingVideo() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        let identity = try identity(), lease = lease
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            tokenFetcher: { _, _ in XCTFail("Disabling an automatic room must not start video"); throw FriendSharingTokenError.unavailable },
            nakamaFetcher: { _, _ in lease })
        defer { sharing.stop() }
        sharing.configureAuthenticatedRoom(room.uuidString, identity: { identity })
        let joined = expectation(description: "automatic room joined")
        let observation = sharing.$joined.dropFirst().filter { $0 }.sink { _ in joined.fulfill() }
        sharing.setAutomaticMultiplayerConnection(true)
        await fulfillment(of: [joined], timeout: 2)
        withExtendedLifetime(observation) {}
        BoundMultiplayerFeatures.setEnabled(false)
        XCTAssertFalse(sharing.active); XCTAssertFalse(sharing.joined)
        XCTAssertFalse(transport.sendPresence(Data([1]))); XCTAssertNil(transport.makeBattleChannel(receiver: { _ in }, failed: {}))
        XCTAssertEqual(media.starts, 0)
    }

    func testDisablingMultiplayerRestartsManualSharingAsVideoOnly() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        let identity = try identity(), lease = lease, room = room.uuidString
        var nakamaAuthorizations = 0, videoAuthorizations = 0
        let initialVideo = expectation(description: "initial optional video"), resumedVideo = expectation(description: "manual video resumes")
        media.started = { if media.starts == 1 { initialVideo.fulfill() } else if media.starts == 2 { resumedVideo.fulfill() } }
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            tokenFetcher: { _, _ in
                videoAuthorizations += 1
                return FriendSharingTokenLease(roomID: room, ownerID: identity.owner, appID: String(repeating: "0", count: 32),
                    channel: "fixture-video", uid: 1, remoteUID: 2, token: "fixture-video-token",
                    issuedAt: Date().timeIntervalSince1970, expiresAt: Date().timeIntervalSince1970 + 90)
            }, nakamaFetcher: { _, _ in nakamaAuthorizations += 1; return lease })
        defer { sharing.stop(); media.started = nil }
        sharing.configureAuthenticatedRoom(room, identity: { identity })
        let joined = expectation(description: "manual gameplay joined")
        let observation = sharing.$joined.dropFirst().filter { $0 }.prefix(1).sink { _ in joined.fulfill() }
        sharing.start()
        await fulfillment(of: [joined, initialVideo], timeout: 2)
        withExtendedLifetime(observation) {}
        XCTAssertTrue(sharing.active); XCTAssertTrue(transport.presenceConnectionCheck.streamCreated)
        BoundMultiplayerFeatures.setEnabled(false)
        await fulfillment(of: [resumedVideo], timeout: 2)
        XCTAssertTrue(sharing.active); XCTAssertTrue(sharing.joined); XCTAssertTrue(sharing.videoPublishing)
        XCTAssertFalse(transport.presenceConnectionCheck.streamCreated)
        XCTAssertFalse(transport.sendPresence(Data([1]))); XCTAssertNil(transport.makeBattleChannel(receiver: { _ in }, failed: {}))
        XCTAssertEqual(nakamaAuthorizations, 1); XCTAssertGreaterThanOrEqual(videoAuthorizations, 2)
    }
}
