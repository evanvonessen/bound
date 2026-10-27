import XCTest
import UIKit
import Combine
@testable import Delta

private final class NakamaTransportWire: BoundNakamaSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let match: String
    private var automaticallyJoin: Bool
    private var pendingJoin: [String: Any]?
    private var receiver: (@Sendable (Result<Data, Error>) -> Void)?
    private var savedReceiver: (@Sendable (Result<Data, Error>) -> Void)?
    private var pending: [Data] = []
    private var observer: (@Sendable (String) -> Void)?
    private var completions: [@Sendable (Error?) -> Void] = []
    private var held = false
    init(match: String, automaticallyJoin: Bool = true) { self.match = match; self.automaticallyJoin = automaticallyJoin }
    func resume() {}
    func observe(_ observer: @escaping @Sendable (String) -> Void) { lock.lock(); self.observer = observer; lock.unlock() }
    func holdSends() { lock.lock(); held = true; lock.unlock() }
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock(); let observer = self.observer, held = self.held
        if held { completions.append(completion) }; lock.unlock()
        observer?(text)
        if !held { completion(nil) }
        if let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
           value["match_join"] != nil, let cid = value["cid"] as? String {
            let response: [String: Any] = ["cid": cid, "match": ["match_id": match]]
            lock.lock(); let automaticallyJoin = self.automaticallyJoin
            if !automaticallyJoin { pendingJoin = response }; lock.unlock()
            if automaticallyJoin { deliver(response) }
        }
    }
    func completeJoin() {
        lock.lock(); automaticallyJoin = true; let response = pendingJoin; pendingJoin = nil; lock.unlock()
        if let response { deliver(response) }
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
    var failFrameSends = true
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
        frameSends += 1; completion(failFrameSends ? .failure(.transport("fixture video outage")) : .success(())); return NakamaFrameCancellation()
    }
}
@MainActor private final class NakamaFrameCancellation: SharingCancellation { func cancel() {} }

@MainActor final class NakamaSharingTransportTests: XCTestCase {
    func testIndependentFriendButtonsCoverAllFourCombinationsAndFailures() async throws {
        let identity = try identity(), lease = lease
        let room = FriendRoom(roomID: self.room.uuidString, displayName: "Friend")
        let media = NakamaMediaFixture(), unusedMedia = NakamaMediaFixture()
        media.failFrameSends = false
        let wire = NakamaTransportWire(match: match)
        var videoAuthorizations = 0, gameplayAuthorizations = 0, jiggles = 0
        let video = FriendSharingSession(configuration: nil, transport: media, authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, identity in
                videoAuthorizations += 1
                let now = Date().timeIntervalSince1970
                return FriendSharingTokenLease(roomID: room, ownerID: identity.owner, appID: String(repeating: "0", count: 32),
                    channel: "independent-video", uid: 1, remoteUID: 2, token: "fixture-video", issuedAt: now, expiresAt: now + 90)
            }, nakamaFetcher: { _, _ in XCTFail("Video must never authorize gameplay"); return lease })
        let transport = BoundNakamaSharingTransport(media: unusedMedia, client: BoundNakamaClient(socketFactory: { _ in wire }))
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            tokenFetcher: { _, _ in XCTFail("Gameplay must never authorize video"); throw FriendSharingTokenError.unavailable },
            nakamaFetcher: { _, _ in gameplayAuthorizations += 1; return lease }, screenSession: video)
        let onboarding = FriendOnboarding(call: { _, _, _ in .init(ok: true, rooms: [room]) }, sendJiggle: { _, _ in jiggles += 1; return "" })
        defer { onboarding.close(); sharing.stop() }
        func state(_ lane: FriendSharingSession) -> BoundFriendRowConnection {
            .init(roomID: room.roomID, selectedRoomID: lane.configuredRoomID, sharing: lane)
        }
        func settle(_ predicate: () -> Bool) async {
            for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(predicate())
        }
        onboarding.open(sharing: sharing, existing: { identity })
        await settle { !onboarding.busy }
        // Neither enabled.
        XCTAssertEqual(state(video), .inactive); XCTAssertEqual(state(sharing), .inactive)
        XCTAssertEqual(videoAuthorizations, 0); XCTAssertEqual(gameplayAuthorizations, 0)
        // Screen only. A server join without the expected peer is disconnected.
        onboarding.toggleScreenSharing(room)
        XCTAssertEqual(state(video), .connecting)
        await settle { video.joined && jiggles == 1 }
        XCTAssertEqual(state(video), .disconnected)
        media.callbacks.last?(.remoteJoined)
        XCTAssertEqual(state(video), .connected); XCTAssertFalse(sharing.connectionRequested)
        XCTAssertEqual(gameplayAuthorizations, 0); XCTAssertFalse(video.interactions.connected)
        sharing.receivePlaybackFrame(GameFrame(rgba: Data(repeating: 0, count: SharingFrame.byteCount), number: 1, buttons: 0))
        XCTAssertEqual(media.frameSends, 1, "Video-only must receive the displayed emulator frame")
        // A cartridge run owns this partner; its UI toggle connects that scope.
        onboarding.setMultiplayerPartner(roomID: room.roomID)
        // Both enabled, without restarting Agora or sending another Jiggle.
        onboarding.toggleMultiplayer(room)
        XCTAssertEqual(state(sharing), .connecting)
        await settle { sharing.joined }
        wire.deliver(roster(peerOnline: true))
        await settle { sharing.peerConnected }
        XCTAssertEqual(state(sharing), .connected); XCTAssertEqual(state(video), .connected)
        XCTAssertEqual(videoAuthorizations, 1); XCTAssertEqual(media.starts, 1); XCTAssertEqual(jiggles, 1)
        let local = try JSONDecoder().decode(BoundFriendWorldPosition.self, from: Data(
            #"{"mapGroup":4,"mapNumber":1,"elevation":0,"x":6,"y":6,"facing":4}"#.utf8))
        let peer = try JSONDecoder().decode(BoundFriendWorldPosition.self, from: Data(
            #"{"mapGroup":4,"mapNumber":1,"elevation":0,"x":7,"y":6,"facing":3}"#.utf8))
        let context = BoundFriendInteractionSession.Context(localSession: UUID(), peerSession: UUID(), local: local, peer: peer)
        sharing.interactions.context = { context }
        XCTAssertTrue(sharing.interactions.open())
        let consent = sharing.interactions.admissionIdentity?()
        // Multiplayer only, with invitation and packet routing still live.
        onboarding.toggleScreenSharing(room)
        XCTAssertFalse(video.connectionRequested); XCTAssertEqual(state(sharing), .connected)
        sharing.receivePlaybackFrame(GameFrame(rgba: Data(repeating: 0, count: SharingFrame.byteCount), number: 2, buttons: 0))
        XCTAssertEqual(media.frameSends, 1, "Video off must stop publication while gameplay stays online")
        XCTAssertEqual(sharing.interactions.phase, .choosing)
        XCTAssertTrue(sharing.sendMultiplayerPacket(Data("BRM1fixture".utf8)))
        XCTAssertEqual(gameplayAuthorizations, 1)
        media.callbacks.first?(.failed(.init(.connectionLost)))
        XCTAssertFalse(video.connectionFailed, "Late video callbacks cannot resurrect a stopped lane")
        XCTAssertEqual(state(sharing), .connected)
        // Start video again; its failure leaves the gameplay channel intact.
        onboarding.toggleScreenSharing(room)
        await settle { video.joined }
        media.callbacks.last?(.remoteJoined)
        media.callbacks.last?(.failed(.init(.connectionLost)))
        XCTAssertEqual(state(video), .failed); XCTAssertEqual(state(sharing), .connected)
        XCTAssertTrue(sharing.sendMultiplayerPacket(Data("BRM1fixture".utf8)))
        video.stop()
        onboarding.toggleScreenSharing(room)
        await settle { video.joined }
        media.callbacks.last?(.remoteJoined)
        let starts = media.starts, stops = media.stops
        // Manual multiplayer pause keeps video and the invitation, and ROM
        // polling cannot override the user's switch-off decision.
        onboarding.toggleMultiplayer(room)
        XCTAssertEqual(state(sharing), .inactive); XCTAssertEqual(state(video), .connected)
        XCTAssertEqual(sharing.interactions.phase, .choosing)
        XCTAssertFalse(sharing.interactions.connected)
        XCTAssertEqual(sharing.interactions.admissionIdentity?(), consent, "Manual pause retains authenticated invitation ownership")
        XCTAssertEqual(onboarding.multiplayerPartnerRoomID, room.roomID)
        for _ in 0..<3 { onboarding.setMultiplayerPartner(roomID: room.roomID) }
        XCTAssertFalse(sharing.connectionRequested)
        XCTAssertEqual(media.starts, starts); XCTAssertEqual(media.stops, stops)
        onboarding.toggleMultiplayer(room)
        await settle { sharing.joined }
        XCTAssertEqual(sharing.interactions.phase, .choosing)
        XCTAssertTrue(sharing.interactions.connected)
        wire.deliverStaleFailure()
        await settle { sharing.connectionFailed }
        XCTAssertEqual(state(sharing), .failed); XCTAssertEqual(state(video), .connected)
        XCTAssertEqual(media.starts, starts); XCTAssertEqual(media.stops, stops)
        XCTAssertEqual(unusedMedia.starts, 0)
        onboarding.disconnectMultiplayer()
        onboarding.toggleScreenSharing(room)
        XCTAssertFalse(video.connectionRequested); XCTAssertFalse(sharing.connectionRequested)
    }

    func testVideoCanSelectAnotherFriendWithoutReplacingRunAndAccountRemovalClosesBoth() async throws {
        var current: AppCloudSession? = try identity()
        let lease = lease, wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let partner = FriendRoom(roomID: room.uuidString, displayName: "Run Partner")
        let videoFriend = FriendRoom(roomID: UUID().uuidString, displayName: "Video Friend")
        let video = FriendSharingSession(configuration: nil, transport: media, authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, identity in
                let now = Date().timeIntervalSince1970
                return FriendSharingTokenLease(roomID: room, ownerID: identity.owner, appID: String(repeating: "0", count: 32),
                    channel: room, uid: 1, remoteUID: 2, token: "fixture-video", issuedAt: now, expiresAt: now + 90)
            })
        let transport = BoundNakamaSharingTransport(media: NakamaMediaFixture(), client: BoundNakamaClient(socketFactory: { _ in wire }))
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            nakamaFetcher: { _, _ in lease }, screenSession: video)
        let onboarding = FriendOnboarding(call: { _, action, _ in
            .init(ok: true, rooms: action == "list" ? [partner, videoFriend] : nil, blocks: [])
        }, sendJiggle: { _, _ in "" })
        defer { onboarding.close(); sharing.stop() }
        func settle(_ predicate: () -> Bool) async {
            for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(predicate())
        }
        onboarding.open(sharing: sharing, existing: { current })
        await settle { !onboarding.busy }
        onboarding.setMultiplayerPartner(roomID: partner.roomID)
        onboarding.toggleMultiplayer(partner)
        await settle { sharing.joined }
        onboarding.toggleScreenSharing(videoFriend)
        await settle { video.joined }
        XCTAssertEqual(video.configuredRoomID, videoFriend.roomID)
        XCTAssertEqual(sharing.configuredRoomID, partner.roomID)
        XCTAssertTrue(sharing.sendMultiplayerPacket(Data("BRM1fixture".utf8)))
        onboarding.toggleMultiplayer(videoFriend)
        XCTAssertEqual(sharing.configuredRoomID, partner.roomID, "Video selection cannot replace the persisted multiplayer partner")
        XCTAssertTrue(sharing.joined); XCTAssertTrue(video.joined)
        onboarding.block(videoFriend)
        await settle { !onboarding.busy }
        XCTAssertFalse(video.connectionRequested); XCTAssertTrue(sharing.joined)
        XCTAssertEqual(onboarding.multiplayerPartnerRoomID, partner.roomID)
        onboarding.toggleScreenSharing(partner)
        await settle { video.joined }
        current = nil; onboarding.synchronizeAccount()
        XCTAssertFalse(sharing.connectionRequested); XCTAssertFalse(video.connectionRequested)
        XCTAssertNil(sharing.configuredRoomID); XCTAssertNil(video.configuredRoomID)
    }

    func testAgoraMediaHasNoGameplayChannel() {
        let media: any FriendSharingTransport = AgoraSharingTransport()
        XCTAssertFalse(media.sendPresence(Data([1])))
        XCTAssertFalse(media.sendInteraction(Data("BRM1fixture".utf8)))
        XCTAssertNil(media.makeBattleChannel(receiver: { _ in }, failed: {}))
        XCTAssertEqual(media.presenceConnectionCheck.kind, .unavailable)
    }

    func testAgoraPeerMembershipSurvivesFrameRecoveryUntilExpectedPeerLeaves() {
        let callbacks = AgoraSharingCallbacks(remoteUID: 2) { _, _ in }
        callbacks.remoteJoined(uid: 3)
        XCTAssertFalse(callbacks.expectedPeerPresent)
        callbacks.remoteJoined(uid: 2)
        XCTAssertTrue(callbacks.expectedPeerPresent)
        callbacks.suspendFrames(); callbacks.resumeFrames()
        XCTAssertTrue(callbacks.expectedPeerPresent, "Local frame recovery cannot forget the authenticated peer join")
        callbacks.remoteLeft(uid: 3)
        XCTAssertTrue(callbacks.expectedPeerPresent)
        callbacks.remoteLeft(uid: 2)
        XCTAssertFalse(callbacks.expectedPeerPresent)
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
    private func battleFrame() -> Data { BoundBattleWire.prefix + Data(repeating: 1, count: 40) }
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

    private func roster(peerOnline: Bool) -> [String: Any] {
        let envelope: [String: Any] = ["v": 1, "members": [
            ["ownerID": owner.uuidString, "online": true],
            ["ownerID": peer.uuidString, "online": peerOnline]
        ]]
        return ["match_data": ["match_id": match, "op_code": "4",
            "data": try! JSONSerialization.data(withJSONObject: envelope).base64EncodedString()]]
    }

    func testPeerRosterBeforeLocalJoinIsReconciledAfterJoinAcknowledgement() async throws {
        let wire = NakamaTransportWire(match: match, automaticallyJoin: false), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        defer { transport.stop() }
        let requested = expectation(description: "socket join requested")
        wire.observe { if $0.contains("match_join") { requested.fulfill() } }
        let joined = expectation(description: "local join acknowledged"), peerJoined = expectation(description: "cached peer reconciled")
        var events: [FriendSharingEvent] = []
        transport.configureGameplay(lease); transport.setVideoRequired(false)
        transport.start(configuration: mediaConfiguration, remoteView: UIView()) { event in
            events.append(event)
            if event == .joined { joined.fulfill() }
            if event == .remoteJoined { peerJoined.fulfill() }
        }
        await fulfillment(of: [requested], timeout: 2)
        wire.deliver(roster(peerOnline: true))
        wire.completeJoin()
        await fulfillment(of: [joined, peerJoined], timeout: 2)
        XCTAssertEqual(events, [.joined, .remoteJoined])
        XCTAssertEqual(media.starts, 0)
    }

    func testAuthenticatedPeerConnectionFollowsNakamaRosterWithoutVideoAndClearsOnStop() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        let identity = try identity(), lease = lease
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            tokenFetcher: { _, _ in XCTFail("Peer connection cannot require video"); throw FriendSharingTokenError.unavailable },
            nakamaFetcher: { _, _ in lease })
        defer { sharing.stop() }
        sharing.configureAuthenticatedRoom(room.uuidString, identity: { identity })
        let joined = expectation(description: "local socket joined")
        let joinedObservation = sharing.$joined.dropFirst().filter { $0 }.sink { _ in joined.fulfill() }
        sharing.setAutomaticMultiplayerConnection(true)
        await fulfillment(of: [joined], timeout: 2)
        joinedObservation.cancel()
        XCTAssertTrue(sharing.connectionRequested)
        XCTAssertFalse(sharing.peerConnected, "Joining the server alone is not a mutual connection")
        XCTAssertFalse(sharing.remoteVisible)
        XCTAssertEqual(media.starts, 0)

        let changes = expectation(description: "peer joins, leaves, and reconnects")
        changes.expectedFulfillmentCount = 3
        var peerStates: [Bool] = []
        let peerObservation = sharing.$peerConnected.dropFirst().sink { value in
            peerStates.append(value); changes.fulfill()
        }
        wire.deliver(roster(peerOnline: true))
        wire.deliver(roster(peerOnline: false))
        wire.deliver(roster(peerOnline: true))
        await fulfillment(of: [changes], timeout: 2)
        peerObservation.cancel()
        XCTAssertEqual(peerStates, [true, false, true])
        XCTAssertTrue(sharing.peerConnected)
        XCTAssertFalse(sharing.remoteVisible, "A data-only connection has no video canvas")
        XCTAssertEqual(media.starts, 0)

        sharing.stop()
        XCTAssertFalse(sharing.peerConnected)
        XCTAssertFalse(sharing.connectionRequested)
        XCTAssertFalse(sharing.joined)
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
        XCTAssertFalse(transport.videoPublishing, "A stale callback from the failed media attempt cannot restore Live")
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(media.starts, 2)
        XCTAssertTrue(transport.videoPublishing, "Optional video reconnects without restarting gameplay")
        let frame = try SharingFrame(copying: Data(repeating: 0, count: SharingFrame.byteCount), sequence: 1, capturedAt: 0)
        _ = transport.send(frame) { result in if case .failure = result { XCTFail("A media frame error must not stop gameplay") } }
        XCTAssertEqual(media.frameSends, 1); XCTAssertEqual(media.presenceSends, 0)
        XCTAssertTrue(transport.presenceConnectionCheck.streamCreated)
    }

    func testOptionalVideoAuthorizationRetriesAndDisablingOrStoppingCancelsRecovery() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        defer { media.started = nil; transport.stop() }
        let firstVideo = expectation(description: "video recovers after authorization outage")
        let secondVideo = expectation(description: "explicit video request starts again")
        media.started = { if media.starts == 1 { firstVideo.fulfill() } else if media.starts == 2 { secondVideo.fulfill() } }
        var authorizations = 0
        let owner = owner, room = room.uuidString
        transport.videoAuthorization = {
            authorizations += 1
            if authorizations == 1 { throw URLError(.networkConnectionLost) }
            return FriendSharingTokenLease(roomID: room, ownerID: owner, appID: String(repeating: "0", count: 32),
                channel: "fixture-video", uid: 1, remoteUID: 2, token: "fixture-video-token",
                issuedAt: Date().timeIntervalSince1970, expiresAt: Date().timeIntervalSince1970 + 90)
        }
        transport.configureGameplay(lease); transport.setVideoRequired(true)
        transport.start(configuration: mediaConfiguration, remoteView: UIView()) { event in
            if case .failed = event { XCTFail("Optional video recovery cannot terminate gameplay") }
        }
        await fulfillment(of: [firstVideo], timeout: 3)
        XCTAssertEqual(authorizations, 2)
        XCTAssertTrue(transport.videoPublishing)
        XCTAssertTrue(transport.sendPresence(Data([1])))
        let stale = media.callbacks[0]
        stale(.failed(.init(.connectionLost)))
        XCTAssertFalse(transport.videoPublishing)
        transport.setVideoRequired(false)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(authorizations, 2); XCTAssertEqual(media.starts, 1)
        stale(.rejoined)
        XCTAssertFalse(transport.videoPublishing)
        transport.setVideoRequired(true)
        await fulfillment(of: [secondVideo], timeout: 2)
        XCTAssertTrue(transport.videoPublishing)
        stale(.failed(.init(.connectionLost)))
        XCTAssertTrue(transport.videoPublishing, "An old media attempt cannot tear down its replacement")
        media.callbacks[1](.failed(.init(.connectionLost)))
        transport.stop()
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(authorizations, 3); XCTAssertEqual(media.starts, 2)
        XCTAssertFalse(transport.videoPublishing)
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
        let oldChannel = try XCTUnwrap(transport.makeBattleChannel(receiver: { _ in stale.fulfill() }, failed: { stale.fulfill() }))
        let oldVideo = media.callbacks[0]
        transport.stop(); transport.configureGameplay(lease); transport.setVideoRequired(false)
        transport.start(configuration: mediaConfiguration, remoteView: UIView()) { event in
            if event == .joined { second.fulfill() } else { stale.fulfill() }
        }
        await fulfillment(of: [second], timeout: 2)
        XCTAssertFalse(oldChannel.send(battleFrame()), "An old channel cannot enqueue into a new authenticated socket")
        let channel = try XCTUnwrap(transport.makeBattleChannel(receiver: { _ in stale.fulfill() }, failed: { stale.fulfill() }))
        oldChannel.close()
        firstWire.deliverStaleFailure(); oldVideo(.remoteFrame); oldVideo(.failed(.init(.connectionLost)))
        await fulfillment(of: [stale], timeout: 0.1)
        XCTAssertFalse(transport.videoPublishing); XCTAssertTrue(channel.send(battleFrame()))
        XCTAssertEqual(media.starts, 1); channel.close()
    }

    func testReplacingBattleChannelFencesOldSenderAndAllowsAcknowledgementOnlyFrames() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        defer { transport.stop() }
        let joined = expectation(description: "joined"), acknowledgement = expectation(description: "acknowledgement routed")
        let bytes = BoundBattleWire.prefix + Data(repeating: 0, count: 34)
        wire.observe { text in
            guard let (opcode, data) = Self.outgoing(text), opcode == 3 else { return }
            XCTAssertEqual(data, bytes); acknowledgement.fulfill()
        }
        transport.configureGameplay(lease); transport.setVideoRequired(false)
        transport.start(configuration: mediaConfiguration, remoteView: UIView()) { if $0 == .joined { joined.fulfill() } }
        await fulfillment(of: [joined], timeout: 2)
        let old = try XCTUnwrap(transport.makeBattleChannel(receiver: { _ in }, failed: {}))
        let replacement = try XCTUnwrap(transport.makeBattleChannel(receiver: { _ in }, failed: {}))
        XCTAssertFalse(old.send(battleFrame()))
        old.close()
        XCTAssertTrue(replacement.send(bytes), "Closing the old sender must not close its replacement")
        await fulfillment(of: [acknowledgement], timeout: 2)
        replacement.close(); XCTAssertFalse(replacement.send(bytes))
    }

    private func identity(owner: UUID? = nil) throws -> AppCloudSession {
        let owner = owner ?? self.owner
        let bytes = try JSONSerialization.data(withJSONObject: BoundAccountTestFixture.claims(owner: owner, expiry: Date().timeIntervalSince1970 + 3600))
        let payload = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try AppCloudSession(owner: owner, key: "fixture-public-key", token: "fixture.\(payload).signature")
    }

    func testMutualROMSelectionConnectsTwoNakamaClientsWithoutFriendsOrVideo() async throws {
        let wireA = NakamaTransportWire(match: match), wireB = NakamaTransportWire(match: match)
        let mediaA = NakamaMediaFixture(), mediaB = NakamaMediaFixture()
        let transportA = BoundNakamaSharingTransport(media: mediaA, client: BoundNakamaClient(socketFactory: { _ in wireA }))
        let transportB = BoundNakamaSharingTransport(media: mediaB, client: BoundNakamaClient(socketFactory: { _ in wireB }))
        let identityA = try identity(), identityB = try identity(owner: peer)
        let leaseA = lease
        let leaseB = BoundNakamaConfiguration(endpoint: leaseA.endpoint, accessToken: "peer-fixture-token",
            expiresAt: leaseA.expiresAt, matchID: match, roomID: room, ownerID: peer,
            nakamaUserID: peer, joinTicket: "peer-fixture-ticket", members: [owner, peer], peerOwnerID: owner)
        let sharingA = FriendSharingSession(configuration: nil, transport: transportA, authenticatedMode: true,
            tokenFetcher: { _, _ in XCTFail("ROM setup cannot require video"); throw FriendSharingTokenError.unavailable },
            nakamaFetcher: { _, _ in leaseA })
        let sharingB = FriendSharingSession(configuration: nil, transport: transportB, authenticatedMode: true,
            tokenFetcher: { _, _ in XCTFail("ROM setup cannot require video"); throw FriendSharingTokenError.unavailable },
            nakamaFetcher: { _, _ in leaseB })
        let selectedRoom = room.uuidString.lowercased(), match = match, owner = owner, peer = peer
        let onboardingA = FriendOnboarding(call: { _, _, _ in
            .init(ok: true, rooms: [.init(roomID: selectedRoom, displayName: "Bob")])
        }, sendJiggle: { _, _ in XCTFail("No Friends notification is required"); return "" })
        let onboardingB = FriendOnboarding(call: { _, _, _ in
            .init(ok: true, rooms: [.init(roomID: selectedRoom, displayName: "Alice")])
        }, sendJiggle: { _, _ in XCTFail("No Friends notification is required"); return "" })
        defer {
            onboardingA.setMultiplayerServiceActive(false, sharing: sharingA, existing: { identityA })
            onboardingB.setMultiplayerServiceActive(false, sharing: sharingB, existing: { identityB })
            sharingA.stop(); sharingB.stop()
        }
        // The socket fixture supplies the same authenticated envelopes as Nakama.
        wireA.observe { text in
            guard let (opcode, bytes) = Self.outgoing(text), opcode == 2 else { return }
            wireB.deliver(Self.relay(bytes, match: match, sender: owner, receiver: peer))
        }
        wireB.observe { text in
            guard let (opcode, bytes) = Self.outgoing(text), opcode == 2 else { return }
            wireA.deliver(Self.relay(bytes, match: match, sender: peer, receiver: owner))
        }
        var channelA = BoundROMChannel(), channelB = BoundROMChannel()
        sharingA.multiplayerPacketReceiver = { bytes in
            if let packet = BoundROMPacket.decode(bytes) { _ = channelA.admit(packet, at: ProcessInfo.processInfo.systemUptime) }
        }
        sharingB.multiplayerPacketReceiver = { bytes in
            if let packet = BoundROMPacket.decode(bytes) { _ = channelB.admit(packet, at: ProcessInfo.processInfo.systemUptime) }
        }
        XCTAssertFalse(sharingA.active); XCTAssertFalse(sharingB.active)
        XCTAssertTrue(onboardingA.selectMultiplayerPartner(roomID: selectedRoom, sharing: sharingA, existing: { identityA }))
        for _ in 0..<200 where !sharingA.joined { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(sharingA.joined); XCTAssertFalse(sharingB.active)
        XCTAssertNil(channelA.peerEpoch, "One selection alone cannot complete setup")
        XCTAssertTrue(onboardingB.selectMultiplayerPartner(roomID: selectedRoom, sharing: sharingB, existing: { identityB }))
        for _ in 0..<200 where !sharingB.joined { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(sharingB.joined)
        for _ in 0..<100 {
            _ = sharingA.sendMultiplayerPacket(try XCTUnwrap(channelA.packet(.hello, owner: owner, body: "setup")))
            _ = sharingB.sendMultiplayerPacket(try XCTUnwrap(channelB.packet(.hello, owner: peer, body: "setup")))
            try await Task.sleep(nanoseconds: 20_000_000)
            if channelA.peerEpoch != nil && channelB.peerEpoch != nil { break }
        }
        XCTAssertEqual(channelA.peerEpoch, channelB.epoch)
        XCTAssertEqual(channelB.peerEpoch, channelA.epoch)
        XCTAssertEqual(sharingA.connectedRoomID, selectedRoom); XCTAssertEqual(sharingB.connectedRoomID, selectedRoom)
        XCTAssertEqual(mediaA.starts, 0); XCTAssertEqual(mediaB.starts, 0)
    }

    nonisolated private static func relay(_ bytes: Data, match: String, sender: UUID, receiver: UUID) -> [String: Any] {
        let envelope: [String: Any] = ["v": 1, "senderOwnerID": sender.uuidString,
            "targetOwnerID": receiver.uuidString, "body": bytes.base64EncodedString()]
        return ["match_data": ["match_id": match, "op_code": "2",
            "data": try! JSONSerialization.data(withJSONObject: envelope).base64EncodedString()]]
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

    func testReconnectCannotRebindRetainedInteractionToDifferentPeerInSameRoom() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: media, client: BoundNakamaClient(socketFactory: { _ in wire }))
        let identity = try identity(), firstLease = lease
        let replacementPeer = UUID()
        let changedLease = BoundNakamaConfiguration(endpoint: firstLease.endpoint, accessToken: firstLease.accessToken,
            expiresAt: firstLease.expiresAt, matchID: firstLease.matchID, roomID: firstLease.roomID,
            ownerID: firstLease.ownerID, nakamaUserID: firstLease.nakamaUserID, joinTicket: firstLease.joinTicket,
            members: [owner, peer, replacementPeer], peerOwnerID: replacementPeer)
        var authorizations = 0
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            nakamaFetcher: { _, _ in authorizations += 1; return authorizations == 1 ? firstLease : changedLease })
        defer { sharing.stop() }
        sharing.configureAuthenticatedRoom(room.uuidString, identity: { identity })
        sharing.setAutomaticMultiplayerConnection(true)
        for _ in 0..<200 where !sharing.joined { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(sharing.joined)
        sharing.background(); sharing.foreground()
        for _ in 0..<200 where authorizations < 2 || sharing.active { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(authorizations, 2)
        XCTAssertFalse(sharing.active)
        XCTAssertFalse(sharing.connectionRequested)
        XCTAssertEqual(sharing.status, "Friend changed · Reopen multiplayer")
        XCTAssertEqual(media.starts, 0)
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

    func testDisablingMultiplayerLeavesIndependentVideoRunning() async throws {
        let wire = NakamaTransportWire(match: match), media = NakamaMediaFixture()
        let transport = BoundNakamaSharingTransport(media: NakamaMediaFixture(), client: BoundNakamaClient(socketFactory: { _ in wire }))
        let identity = try identity(), lease = lease, room = room.uuidString
        var videoAuthorizations = 0
        let video = FriendSharingSession(configuration: nil, transport: media, authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { _, _ in
                videoAuthorizations += 1
                return FriendSharingTokenLease(roomID: room, ownerID: identity.owner, appID: String(repeating: "0", count: 32),
                    channel: "fixture-video", uid: 1, remoteUID: 2, token: "fixture-video-token",
                    issuedAt: Date().timeIntervalSince1970, expiresAt: Date().timeIntervalSince1970 + 90)
            })
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            nakamaFetcher: { _, _ in lease }, screenSession: video)
        defer { sharing.stop() }
        sharing.configureAuthenticatedRoom(room, identity: { identity })
        video.configureAuthenticatedRoom(room, identity: { identity })
        video.start(); sharing.setAutomaticMultiplayerConnection(true)
        for _ in 0..<200 { if sharing.joined && video.joined { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(sharing.joined); XCTAssertTrue(video.joined)
        let stops = media.stops
        BoundMultiplayerFeatures.setEnabled(false)
        XCTAssertFalse(sharing.connectionRequested)
        XCTAssertFalse(transport.presenceConnectionCheck.streamCreated)
        XCTAssertNil(transport.makeBattleChannel(receiver: { _ in }, failed: {}))
        XCTAssertTrue(video.joined); XCTAssertTrue(video.active)
        XCTAssertEqual(media.starts, 1); XCTAssertEqual(media.stops, stops); XCTAssertEqual(videoAuthorizations, 1)
        BoundMultiplayerFeatures.setEnabled(true)
        XCTAssertFalse(sharing.connectionRequested, "Enabling the experiment alone cannot start either lane")
        XCTAssertTrue(video.joined); XCTAssertEqual(media.starts, 1)
    }
}
