import XCTest
import UIKit
@testable import Delta

@MainActor
private final class PresenceFixtureTransport: FriendSharingTransport {
    var publishedFrames = 0
    var receivedFrames = 0
    private var storedFrameTiming: FriendSharingFrameTiming?
    var frameTimingRead: (() -> Void)?
    var frameTiming: FriendSharingFrameTiming? {
        get { frameTimingRead?(); return storedFrameTiming }
        set { storedFrameTiming = newValue }
    }
    var receiver: (@MainActor (Data) -> Void)?
    var event: (@MainActor (FriendSharingEvent) -> Void)?
    var packets: [Data] = []
    var lobbyPresenceReceiver: (@MainActor (UInt, Data) -> Void)?
    var lobbyInteractionReceiver: (@MainActor (UInt, Data?) -> Void)?
    var lobbyPackets: [(UInt, Data)] = []
    var starts = 0
    func setLobbyReceivers(presence: (@MainActor (UInt, Data) -> Void)?, interaction: (@MainActor (UInt, Data?) -> Void)?) {
        lobbyPresenceReceiver = presence; lobbyInteractionReceiver = interaction
    }
    func sendLobby(_ data: Data, to uid: UInt) -> Bool { lobbyPackets.append((uid, data)); return true }
    func updateLobbyConfiguration(_ configuration: FriendSharingConfiguration) -> Bool { true }
    func setPresenceReceiver(_ receiver: (@MainActor (Data) -> Void)?) { self.receiver = receiver }
    func sendPresence(_ data: Data) -> Bool { packets.append(data); return true }
    func start(configuration: FriendSharingConfiguration, remoteView: UIView,
               event: @escaping @MainActor (FriendSharingEvent) -> Void) { self.event = event; starts += 1; event(.joined) }
    func stop() { event = nil }
    func renewToken(_ token: String) -> Bool { true }
    func recordRecoveryTimeout() {}
    func presentLatestFrame() {}
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        completion(.success(())); return PresenceFixtureCancellation()
    }
}
@MainActor private final class PresenceFixtureCancellation: SharingCancellation { func cancel() {} }

@MainActor
final class LivePresenceTests: XCTestCase {
    private var previousExperimentalFeature: Any?
    override func setUp() {
        super.setUp()
        previousExperimentalFeature = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
    }
    override func tearDown() {
        UserDefaults.standard.set(previousExperimentalFeature, forKey: BoundMultiplayerFeatures.key)
        NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
        super.tearDown()
    }

    func reading(x: Int = 104, map: Int = 3, elevation: Int = 0, facing: String = "South") -> BoundPlayerStateReading {
        let sprite = BoundPlayerSprite(width: 16, height: 32, tiles: Data(repeating: 0x11, count: 256),
            palette: Data(repeating: 0, count: 32), flipX: false, flipY: false, priority: 2, romAddress: 0x08123450)
        var player = BoundPlayerState(mapGroup: 4, mapNumber: map, tile: .init(x: x / 16, y: 6),
            previousTile: .init(x: x / 16, y: 6), facing: facing, elevation: elevation, graphicsID: 0,
            runningState: 0, tileTransitionState: 0)
        player.scene = .init(worldFoot: .init(x: x, y: 112), camera: .init(x: 16, y: -24), appearance: sprite,
            background: .init(tiles: Data(repeating: 0, count: 32768), layers: []), objects: [])
        return .init(frame: 12345, status: .live, detail: "Fixture", player: player)
    }
    func packet(_ session: BoundLivePresenceSession, peer: UUID, sequence: UInt64 = 1, time: Double = 10,
                reading: BoundPlayerStateReading? = nil, acknowledge: Bool = true,
                rom: String = BoundPlayerROMProfile.supportedSHA256) throws -> Data {
        try XCTUnwrap(BoundPresencePacket(version: 1, rom: rom, sender: peer,
            receiver: acknowledge ? session.epoch : nil, sequence: sequence, time: time,
            pose: reading.flatMap(BoundPresencePose.init)).encoded())
    }
    func session() -> BoundLivePresenceSession {
        let session = BoundLivePresenceSession(); session.setROMVerified(true)
        session.setEnabled(true); session.start { _ in true }; return session
    }

    private func lobbyMembers() -> [FriendSharingLobbyMember] {
        (1...4).map { .init(ownerID: UUID(), uid: UInt($0), sessionID: UUID()) }
    }

    func testLobbyEnvelopeAuthenticatesRecipientSenderAndMembershipIncarnation() throws {
        let members = lobbyMembers(), lobby = UUID(), data = Data("BRM1private-pair".utf8)
        let route = FriendSharingLobbyRoute(lobbyID: lobby, localUID: 1, members: members)
        let envelope = try XCTUnwrap(FriendSharingLobbyEnvelope(lobbyID: lobby, senderSession: members[1].sessionID,
            receiverSession: members[0].sessionID, payload: data).encoded())
        XCTAssertEqual(FriendSharingLobbyEnvelope.decode(envelope, from: 2, route: route), data)
        XCTAssertNil(FriendSharingLobbyEnvelope.decode(envelope, from: 3, route: route), "A third friend cannot claim the partner's sender session")
        XCTAssertNil(FriendSharingLobbyEnvelope.decode(envelope, from: 2,
            route: .init(lobbyID: lobby, localUID: 3, members: members)), "The other pair cannot receive private run packets")
        var rejoined = members
        rejoined[1] = .init(ownerID: members[1].ownerID, uid: 2, sessionID: UUID())
        XCTAssertNil(FriendSharingLobbyEnvelope.decode(envelope, from: 2,
            route: .init(lobbyID: lobby, localUID: 1, members: rejoined)), "Rejoined UID cannot replay its old incarnation")
        XCTAssertFalse(FriendSharingLobbyRoute(lobbyID: lobby, localUID: 1, members: members + [members[0]]).isValid)
        XCTAssertNil(FriendSharingLobbyEnvelope(lobbyID: lobby, senderSession: UUID(), receiverSession: UUID(),
            payload: Data(repeating: 0, count: 1025)).encoded())
    }

    func testLobbyFramingHandlesSplitCombinedAndMalformedRDTWrites() throws {
        let members = lobbyMembers(), lobby = UUID()
        let packet = try XCTUnwrap(FriendSharingLobbyEnvelope(lobbyID: lobby, senderSession: members[1].sessionID,
            receiverSession: members[0].sessionID, payload: Data("BRM1first".utf8)).encoded())
        var framer = FriendSharingLobbyFramer()
        XCTAssertEqual(framer.consume(Data(packet.prefix(3))), [])
        XCTAssertEqual(framer.consume(Data(packet.dropFirst(3)) + packet), [packet, packet])
        XCTAssertNil(framer.consume(Data("invalid".utf8)))
        XCTAssertEqual(framer.consume(packet), [packet], "Invalid input clears its bounded pending buffer")
    }

    func testLobbyMailboxesKeepThreePeersIndependentAndDropDepartedSessions() throws {
        let members = lobbyMembers(), lobby = UUID(), receiver = session()
        let callbacks = AgoraSharingCallbacks(remoteUID: 2) { _, _ in }
        let route = FriendSharingLobbyRoute(lobbyID: lobby, localUID: 1, members: members)
        callbacks.configureLobby(route, remoteUID: 2)
        for uid in UInt(2)...4 {
            let payload = try packet(receiver, peer: UUID(), reading: reading(x: Int(uid) * 16 + 104))
            let wire = try XCTUnwrap(FriendSharingLobbyEnvelope(lobbyID: lobby, senderSession: members[Int(uid)-1].sessionID,
                receiverSession: members[0].sessionID, payload: payload).encoded())
            callbacks.receiveLobbyData(wire, uid: uid)
        }
        XCTAssertEqual(Set(callbacks.takeLobbyPresence().keys), [2, 3, 4])
        let privatePacket = Data("BRM1pair".utf8)
        let wire = try XCTUnwrap(FriendSharingLobbyEnvelope(lobbyID: lobby, senderSession: members[1].sessionID,
            receiverSession: members[0].sessionID, payload: privatePacket).encoded())
        callbacks.receiveLobbyData(wire, uid: 3)
        XCTAssertTrue(callbacks.takeLobbyInteractions().messages.isEmpty)
        callbacks.receiveLobbyData(wire, uid: 2)
        callbacks.configureLobby(.init(lobbyID: lobby, localUID: 1, members: members.filter { $0.uid != 2 }), remoteUID: 3)
        XCTAssertTrue(callbacks.takeLobbyInteractions().messages.isEmpty, "Removing membership clears already queued packets")
        callbacks.receiveLobbyData(wire, uid: 2)
        XCTAssertTrue(callbacks.takeLobbyInteractions().messages.isEmpty)
    }

    func testThreeLiveSpritesUseIndependentFreshnessAndRestoreChallenges() throws {
        let parent = session(), peers = [UInt(2): session(), 3: session(), 4: session()]
        parent.setGroupSessions(peers)
        parent.consume(reading(), at: 20)
        for (uid, presence) in peers {
            presence.receive(try packet(presence, peer: UUID(), reading: reading(x: Int(uid) * 16 + 104)), at: 20)
        }
        XCTAssertEqual(parent.renderingSessions.compactMap { $0.pose(at: 20.01) }.count, 3)
        peers[2]?.peerGone()
        XCTAssertEqual(parent.renderingSessions.compactMap { $0.pose(at: 20.01) }.count, 2, "One friend leaving cannot withdraw the others")
        parent.invalidateLocal()
        XCTAssertTrue(parent.renderingSessions.allSatisfy { $0.pose(at: 20.01) == nil }, "A save restore fences every peer's old poses")
    }

    func testGroupTransportKeepsPairPacketsPrivateAndDoesNotReconnectForOtherPair() async throws {
        let members = lobbyMembers(), lobby = UUID(), now = Date().timeIntervalSince1970
        let claims = try JSONSerialization.data(withJSONObject: ["sub": members[0].ownerID.uuidString.lowercased(), "exp": now + 3600])
        let encoded = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let identity = try AppCloudSession(owner: members[0].ownerID, key: "fixture", token: "e30." + encoded + ".fixture")
        let transport = PresenceFixtureTransport()
        var roster = members
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            lobbyTokenFetcher: { _, _, _ in
                .init(roomID: lobby.uuidString.lowercased(), ownerID: members[0].ownerID,
                      appID: String(repeating: "a", count: 32), channel: "lobby", uid: 1, remoteUID: 2,
                      token: "fixture", issuedAt: Date().timeIntervalSince1970, expiresAt: Date().timeIntervalSince1970 + 60,
                      lobbyID: lobby, members: roster, membershipRevision: "1")
            })
        defer { sharing.stop() }
        sharing.configureAuthenticatedLobby(lobbyID: lobby, memberToken: UUID(), pairedRoomID: "pair-A",
                                            partnerID: members[1].ownerID, identity: { identity })
        sharing.setAutomaticMultiplayerConnection(true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(sharing.connectedRoomID, "pair-A")
        XCTAssertEqual(sharing.connectedLobbyID, lobby)
        XCTAssertEqual(sharing.livePresence.groupSessions.count, 3)
        let payload = Data("BRM1fixture".utf8)
        XCTAssertTrue(sharing.sendMultiplayerPacket(payload))
        XCTAssertEqual(transport.lobbyPackets.last?.0, 2)
        var received: [Data] = []
        sharing.multiplayerPacketReceiver = { received.append($0) }
        transport.lobbyInteractionReceiver?(3, payload)
        transport.lobbyInteractionReceiver?(4, payload)
        XCTAssertTrue(received.isEmpty)
        transport.lobbyInteractionReceiver?(2, payload)
        XCTAssertEqual(received, [payload])
        sharing.livePresence.setROMVerified(true)
        let timestamp = ProcessInfo.processInfo.systemUptime
        var epochs: [UInt: UUID] = [:]
        for (uid, presence) in sharing.livePresence.groupSessions {
            let epoch = UUID(); epochs[uid] = epoch
            let target = reading(x: uid == 3 ? 120 : 152, facing: "West")
            presence.consume(reading(facing: "East"), at: timestamp - 0.06)
            presence.receive(try packet(presence, peer: epoch, time: timestamp - 0.06, reading: target), at: timestamp - 0.06)
            presence.consume(reading(facing: "East"), at: timestamp)
            presence.receive(try packet(presence, peer: epoch, sequence: 2, time: timestamp, reading: target), at: timestamp)
        }
        XCTAssertTrue(sharing.interactions.canInteract, "Press A targets the one friend being faced")
        XCTAssertTrue(sharing.requestLobbyActivity(ownerID: members[2].ownerID, activity: .battle))
        XCTAssertEqual(transport.lobbyPackets.last?.0, 3, "Nearby battle targets a friend outside the Soul Link pair")
        XCTAssertEqual(sharing.connectedRoomID, "pair-A", "Targeted battle cannot replace durable pair ownership")
        let invitation = try XCTUnwrap(transport.lobbyPackets.last.flatMap { BoundFriendInteractionPacket.decode($0.1) })
        XCTAssertEqual(invitation.receiver, epochs[3])
        sharing.interactions.cancel()
        let partnerSession = sharing.livePresence.groupSessions[2]
        sharing.configureAuthenticatedRoom("pair-A", identity: { identity })
        roster.removeAll { $0.uid == 4 }
        sharing.refreshLobbyMembership()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(transport.starts, 1)
        XCTAssertTrue(partnerSession === sharing.livePresence.groupSessions[2])
        XCTAssertEqual(Set(sharing.livePresence.groupSessions.keys), [2, 3])
        XCTAssertEqual(sharing.connectedRoomID, "pair-A")
    }

    func testFourPlayerSoulTrafficStaysWithinTwoPairsDuringFriendlyActivity() async throws {
        let members = lobbyMembers(), lobby = UUID(), runs = [UUID(), UUID()]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("four-soul-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var sessions: [FriendSharingSession] = [], transports: [PresenceFixtureTransport] = []
        defer { sessions.forEach { $0.stop() } }
        for index in 0..<4 {
            let member = members[index], partner = members[index ^ 1]
            let claims = try JSONSerialization.data(withJSONObject: ["sub": member.ownerID.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
            let encoded = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let identity = try AppCloudSession(owner: member.ownerID, key: "fixture", token: "e30." + encoded + ".fixture")
            let transport = PresenceFixtureTransport()
            let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
                lobbyTokenFetcher: { _, _, _ in
                    .init(roomID: lobby.uuidString.lowercased(), ownerID: member.ownerID,
                          appID: String(repeating: "a", count: 32), channel: "four-soul", uid: member.uid, remoteUID: partner.uid,
                          token: "fixture", issuedAt: Date().timeIntervalSince1970, expiresAt: Date().timeIntervalSince1970 + 60,
                          lobbyID: lobby, members: members, membershipRevision: "1")
                })
            sharing.configureAuthenticatedLobby(lobbyID: lobby, memberToken: UUID(), pairedRoomID: "pair-\(index / 2)",
                                                partnerID: partner.ownerID, identity: { identity })
            sharing.setAutomaticMultiplayerConnection(true)
            sessions.append(sharing); transports.append(transport)
        }
        for _ in 0..<30 { await Task.yield() }
        for (index, sharing) in sessions.enumerated() {
            XCTAssertEqual(sharing.connectedLobbyID, lobby)
            sharing.soulLink.probe.configure(core: nil, url: root.appendingPathComponent("\(index).json"))
            try sharing.soulLink.startPreparedRun(run: runs[index / 2])
        }
        var lastSoul: [UInt: BoundSoulPacket] = [:]
        func deliver() {
            for (index, transport) in transports.enumerated() {
                let pending = transport.lobbyPackets; transport.lobbyPackets.removeAll()
                for (target, data) in pending {
                    if let packet = BoundSoulPacket.decode(data) { lastSoul[UInt(index + 1)] = packet }
                    transports[Int(target) - 1].lobbyInteractionReceiver?(UInt(index + 1), data)
                }
            }
        }
        for _ in 0..<5 {
            sessions.forEach { $0.soulLink.tick() }; deliver()
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertTrue(sessions.allSatisfy { $0.soulLink.paired })
        // Only A and C enter friendly activity. Their actual Soul Link partners
        // B and D keep receiving the ordinary run heartbeat.
        sessions[0].soulLink.nativeActivity = { true }; sessions[2].soulLink.nativeActivity = { true }
        for _ in 0..<4 {
            sessions.forEach { $0.soulLink.tick() }; deliver()
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertTrue(sessions.allSatisfy { $0.soulLink.paired })
        XCTAssertEqual(sessions.map { $0.soulLink.ledger?.run }, [runs[0], runs[0], runs[1], runs[1]])
        let template = try XCTUnwrap(lastSoul[2])
        let death = try XCTUnwrap(BoundSoulPacket(version: 2, run: runs[0], kind: .state,
            rows: [.init(slot: "area:100", name: "Fixture", dead: true)],
            losses: BoundSoulLedger.bits(["area:100"]), sender: template.sender, receiver: template.receiver).encoded())
        transports[0].lobbyInteractionReceiver?(3, death)
        XCTAssertTrue(sessions[0].soulLink.probe.read().ledger?.dead.isEmpty == true,
                      "Even a packet with the correct pair run and challenge cannot arrive through another friend's UID")
        transports[0].lobbyInteractionReceiver?(2, death)
        XCTAssertEqual(sessions[0].soulLink.probe.read().ledger?.dead, ["area:100"], "Actual partner deaths remain permanent during friendly activity")
        XCTAssertTrue(sessions[2].soulLink.probe.read().ledger?.dead.isEmpty == true)
        XCTAssertTrue(sessions[3].soulLink.probe.read().ledger?.dead.isEmpty == true)
    }

    func testSoloSessionIgnoresOtherMembersAndPreservesCorruptJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("solo-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("run.json"), probe = BoundSoulProbe(), owner = UUID(), run = UUID()
        probe.configure(core: nil, url: url)
        try probe.startPreparedRun(run: run, binding: String(repeating: "a", count: 64), soloOwner: owner)
        let session = BoundSoulSession(probe: probe)
        session.connected = { false }; session.tick(); session.peerGone(); session.tick()
        XCTAssertTrue(session.active); XCTAssertTrue(session.solo); XCTAssertFalse(session.paired)
        XCTAssertEqual(session.status, "Solo Nuzlocke active")
        let before = try Data(contentsOf: url)
        session.connected = { true }; session.setConnection(owner: owner.uuidString, room: "unrelated-lobby-friend")
        let death = try XCTUnwrap(BoundSoulPacket(version: 2, run: run, kind: .state,
            rows: [.init(slot: "area:100", name: "Foreign", dead: true)], losses: BoundSoulLedger.bits(["area:100"])).encoded())
        session.receive(death)
        XCTAssertTrue(probe.read().ledger?.dead.isEmpty == true)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let corruptURL = root.appendingPathComponent("corrupt.json"), corrupt = Data("damaged journal".utf8)
        try corrupt.write(to: corruptURL)
        let damaged = BoundSoulProbe(); damaged.configure(core: nil, url: corruptURL)
        XCTAssertThrowsError(try damaged.startPreparedRun(run: UUID(), binding: String(repeating: "a", count: 64), soloOwner: owner))
        XCTAssertEqual(try Data(contentsOf: corruptURL), corrupt)
    }

    func testInteractionAdmissionUsesFreshSettledSamplesAndInvalidatesOnRestore() throws {
        let session = session(), peer = UUID()
        session.consume(reading(x:104),at:20)
        session.receive(try packet(session,peer:peer,time:10,reading:reading(x:120)),at:20)
        XCTAssertNil(session.interactionContext(at:20))
        session.consume(reading(x:104),at:20.06)
        session.receive(try packet(session,peer:peer,sequence:2,time:10.06,reading:reading(x:120)),at:20.06)
        XCTAssertNotNil(session.interactionContext(at:20.06))
        XCTAssertNil(session.interactionContext(at:20.3), "An old rendering pose cannot admit an interaction")
        session.consume(reading(x:105),at:20.1)
        XCTAssertNil(session.interactionContext(at:20.1), "Mid-step pixels are not settled tiles")
        session.consume(reading(x:104),at:20.11)
        XCTAssertNil(session.interactionContext(at:20.12))
        session.invalidateLocal()
        XCTAssertNil(session.interactionContext(at:20.15))
    }

    func testNativeDialogueRetainsAppearanceOnlyForFreshMatchingWorldData() throws {
        let session=session(),peer=UUID()
        session.consume(reading(),at:20)
        session.receive(try packet(session,peer:peer,reading:reading(x:120)),at:20)
        session.consume(reading(),at:20.06)
        session.receive(try packet(session,peer:peer,sequence:2,time:10.06,reading:reading(x:120)),at:20.06)
        var player=try XCTUnwrap(reading().player); player.scene=nil
        let withoutSprite=BoundPlayerStateReading(frame:12346,status:.live,detail:"Native window",player:player)
        session.retainsNativeDialoguePose={ true }
        session.consume(withoutSprite,at:20.1)
        XCTAssertNotNil(session.interactionContext(at:20.1))
        XCTAssertNil(session.interactionContext(at:20.4),"Dialogue cannot extend the original freshness deadline")
        session.retainsNativeDialoguePose={ false }
        session.consume(withoutSprite,at:20.11)
        XCTAssertNil(session.interactionContext(at:20.11),"No cached appearance outside an owned dialogue")
        session.consume(reading(),at:20.12)
        session.retainsNativeDialoguePose={ true }
        var moved=try XCTUnwrap(reading(x:136).player); moved.scene=nil
        session.consume(.init(frame:12347,status:.live,detail:"Moved",player:moved),at:20.13)
        XCTAssertNil(session.interactionContext(at:20.13))
        session.consume(reading(),at:20.14)
        session.consume(.inactive(.battle,"Battle",frame:12348),at:20.15)
        XCTAssertNil(session.interactionContext(at:20.15))
    }

    func testWireIsBoundedAndCarriesOnlyPresenceWithROMFrameReference() throws {
        let session = session(), data = try packet(session, peer: UUID(), reading: reading())
        XCTAssertLessThan(data.count, BoundPresencePacket.maximumBytes)
        let decoded = try XCTUnwrap(BoundPresencePacket.decode(data))
        XCTAssertEqual(decoded.pose?.frameAddress, 0x08123450)
        XCTAssertEqual(decoded.pose?.palette.count, 32)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(keys.keys), ["version", "rom", "sender", "receiver", "sequence", "time", "pose"])
        XCTAssertNil(BoundPresencePacket.decode(Data(repeating: 0, count: 769)))
        XCTAssertNil(BoundPresencePacket.decode(Data("{}".utf8)))
        var invalid = keys; invalid["version"] = 2
        XCTAssertNil(BoundPresencePacket.decode(try JSONSerialization.data(withJSONObject: invalid)))
        var pose = try XCTUnwrap(keys["pose"] as? [String: Any]); pose["frameAddress"] = 0x02000000
        invalid = keys; invalid["pose"] = pose
        XCTAssertNil(BoundPresencePacket.decode(try JSONSerialization.data(withJSONObject: invalid)))
        pose["frameAddress"] = 0x08123450; pose["palette"] = Data(repeating: 0, count: 31).base64EncodedString()
        invalid["pose"] = pose
        XCTAssertNil(BoundPresencePacket.decode(try JSONSerialization.data(withJSONObject: invalid)))
        pose["palette"] = Data(repeating: 0, count: 32).base64EncodedString(); pose["x"] = -1
        invalid["pose"] = pose
        XCTAssertNil(BoundPresencePacket.decode(try JSONSerialization.data(withJSONObject: invalid)))
    }

    func testTwoWayHandshakeAndIndependentMonotonicClocks() throws {
        let a = BoundLivePresenceSession(), b = BoundLivePresenceSession()
        var aNow = 10.0, bNow = 910.0
        a.setROMVerified(true); b.setROMVerified(true)
        a.setEnabled(true); b.setEnabled(true)
        a.start { b.receive($0, at: bNow); return true }
        b.start { a.receive($0, at: aNow); return true }
        a.consume(reading(x: 104), at: aNow); b.consume(reading(x: 136), at: bNow)
        a.tick(at: aNow)
        XCTAssertNil(b.pose(at: bNow), "A fresh challenge must be acknowledged")
        b.tick(at: bNow)
        XCTAssertEqual(a.pose(at: aNow)?.x, 136)
        aNow += 0.05; bNow += 0.05; a.tick(at: aNow)
        XCTAssertEqual(b.pose(at: bNow)?.x, 104)
        XCTAssertEqual(a.peerEpoch, b.epoch); XCTAssertEqual(b.peerEpoch, a.epoch)
        for step in 1...30 {
            aNow += 0.05; bNow += 0.05
            // Each reader uses unrelated frame numbers and independent movement.
            a.consume(reading(x: 104 + step), at: aNow); b.consume(reading(x: 136 - step), at: bNow)
            a.tick(at: aNow); b.tick(at: bNow)
        }
        XCTAssertGreaterThan(try XCTUnwrap(b.pose(at: bNow)).x, 125)
        XCTAssertLessThan(try XCTUnwrap(a.pose(at: aNow)).x, 115)
        XCTAssertLessThanOrEqual(a.bufferedSamples, 8); XCTAssertLessThanOrEqual(b.bufferedSamples, 8)
        XCTAssertGreaterThan(a.sentPackets, 20); XCTAssertGreaterThan(b.receivedPackets, 20)
    }

    func testInterpolationRejectsOldPacketsAndNeverInterpolatesAcrossWarpOrElevation() throws {
        let session = session(), peer = UUID()
        session.receive(try packet(session, peer: peer, time: 10, reading: reading()), at: 20)
        session.receive(try packet(session, peer: peer, sequence: 2, time: 10.1, reading: reading(x: 120)), at: 20.1)
        XCTAssertEqual(try XCTUnwrap(session.pose(at: 20.15)).x, 112, accuracy: 0.001)
        session.receive(try packet(session, peer: peer, sequence: 1, time: 10, reading: reading(x: 999)), at: 20.16)
        XCTAssertEqual(session.rejectedPackets, 1)
        session.receive(try packet(session, peer: peer, sequence: 3, time: 10.2, reading: reading(x: 104, map: 4)), at: 20.2)
        XCTAssertEqual(session.bufferedSamples, 1); XCTAssertEqual(session.pose(at: 20.2)?.mapNumber, 4)
        session.receive(try packet(session, peer: peer, sequence: 4, time: 10.3, reading: reading(x: 104, map: 4, elevation: 2)), at: 20.3)
        XCTAssertEqual(session.bufferedSamples, 1); XCTAssertEqual(session.pose(at: 20.3)?.elevation, 2)
        session.receive(try packet(session, peer: peer, sequence: 5, time: 10.4, reading: reading(x: 999, map: 4, elevation: 2)), at: 20.4)
        XCTAssertEqual(session.bufferedSamples, 1); XCTAssertEqual(session.pose(at: 20.4)?.x, 999)
    }

    func testPauseTimeoutRestoreAndReconnectRejectPreviousSession() throws {
        let session = session(), peer = UUID()
        let old = try packet(session, peer: peer, reading: reading())
        session.receive(old, at: 20); XCTAssertNotNil(session.pose(at: 20))
        session.receive(try packet(session, peer: peer, sequence: 2, time: 10.05), at: 20.05)
        XCTAssertNil(session.pose(at: 20.05), "Peer pause withdraws immediately")
        session.receive(try packet(session, peer: peer, sequence: 3, time: 10.1, reading: reading()), at: 20.1)
        XCTAssertNil(session.pose(at: 20.6), "No unbounded extrapolation during a packet gap")
        let epoch = session.epoch; session.tick(at: 21)
        XCTAssertNotEqual(epoch, session.epoch)
        session.receive(old, at: 21); XCTAssertNil(session.pose(at: 21))
        let fresh = try packet(session, peer: peer, sequence: 4, time: 11, reading: reading())
        session.receive(fresh, at: 21); XCTAssertNotNil(session.pose(at: 21))
        session.invalidateLocal(); session.receive(fresh, at: 21.01)
        XCTAssertNil(session.pose(at: 21.01), "Restored state must negotiate a fresh session")
        session.stop(); session.start { _ in true }; session.receive(fresh, at: 21.02)
        XCTAssertNil(session.pose(at: 21.02))
    }

    func testROMMismatchDelayedPacketsAndRetiredPeerCannotReappear() throws {
        let session = session(), peer = UUID()
        session.receive(try packet(session, peer: peer, reading: reading()), at: 20)
        session.receive(try packet(session, peer: peer, sequence: 2, time: 10.05, reading: reading(x: 120)), at: 20.5)
        XCTAssertEqual(session.rejectedPackets, 1)
        let replacement = UUID()
        session.receive(try packet(session, peer: replacement, time: 20, reading: reading(x: 136)), at: 20.6)
        session.receive(try packet(session, peer: peer, sequence: 3, time: 10.7, reading: reading()), at: 20.7)
        XCTAssertEqual(session.peerEpoch, replacement)
        XCTAssertEqual(session.pose(at: 20.7)?.x, 136)
        let queued = try packet(session, peer: replacement, sequence: 3, time: 20.3, reading: reading(x: 136))
        session.receive(try packet(session, peer: replacement, sequence: 2, time: 20.2,
            reading: reading(), rom: String(repeating: "f", count: 64)), at: 20.8)
        XCTAssertNil(session.pose(at: 20.8)); XCTAssertEqual(session.status, "Friend ROM is incompatible")
        session.receive(queued, at: 20.9)
        XCTAssertNil(session.pose(at: 20.9), "A ROM change must invalidate queued compatible poses")
    }

    func testPublishCadencePauseAndOptOut() throws {
        let session = BoundLivePresenceSession(); var outgoing: [Data] = []
        session.setROMVerified(true)
        session.start { outgoing.append($0); return true }
        session.tick(at: 10); XCTAssertTrue(outgoing.isEmpty)
        session.stop(); XCTAssertTrue(outgoing.isEmpty, "Ordinary video sharing must not publish presence while opted out")
        session.start { outgoing.append($0); return true }
        session.setEnabled(true); session.consume(reading(), at: 10)
        for step in 0..<60 { session.tick(at: 10 + Double(step) / 60) }
        XCTAssertEqual(outgoing.count, 20)
        XCTAssertNotNil(BoundPresencePacket.decode(outgoing[0])?.pose)
        XCTAssertNil(BoundPresencePacket.decode(try XCTUnwrap(outgoing.last))?.pose, "Stale reader must stop advertising coordinates")
        session.consume(.inactive(.paused, "Paused"), at: 11); session.tick(at: 11)
        XCTAssertNil(BoundPresencePacket.decode(try XCTUnwrap(outgoing.last))?.pose)
        session.setEnabled(false); XCTAssertFalse(session.needsReader)
        XCTAssertNil(BoundPresencePacket.decode(try XCTUnwrap(outgoing.last))?.pose)
    }

    func testSDKMailboxBoundsExpectedPeerAndClearsOnLoss() {
        let mailbox = AgoraSharingCallbacks(remoteUID: 2) { _, _ in }
        mailbox.receivePresence(Data([1]), uid: 3); XCTAssertNil(mailbox.takeLatestPresence())
        mailbox.receivePresence(Data(repeating: 1, count: 769), uid: 2); XCTAssertNil(mailbox.takeLatestPresence())
        mailbox.receivePresence(Data([1]), uid: 2); mailbox.receivePresence(Data([2]), uid: 2)
        XCTAssertEqual(mailbox.takeLatestPresence(), Data([2])); XCTAssertNil(mailbox.takeLatestPresence())
        mailbox.receivePresence(Data([3]), uid: 2); mailbox.suspendFrames()
        XCTAssertNil(mailbox.takeLatestPresence()); mailbox.receivePresence(Data([4]), uid: 2)
        XCTAssertNil(mailbox.takeLatestPresence())
        mailbox.resumeFrames(); mailbox.receivePresence(Data([5]), uid: 2)
        XCTAssertEqual(mailbox.takeLatestPresence(), Data([5]))
    }

    func testUnverifiedLocalROMCannotAdvertiseCoordinates() throws {
        let session = BoundLivePresenceSession(); var outgoing: [Data] = []
        session.setEnabled(true); session.start { outgoing.append($0); return true }
        session.consume(reading(), at: 10); session.tick(at: 10)
        XCTAssertNil(BoundPresencePacket.decode(try XCTUnwrap(outgoing.last))?.pose)
        XCTAssertNotEqual(BoundPresencePacket.decode(try XCTUnwrap(outgoing.last))?.rom, BoundPlayerROMProfile.supportedSHA256)
        session.setROMVerified(true); session.consume(reading(), at: 11); session.tick(at: 11)
        XCTAssertNotNil(BoundPresencePacket.decode(try XCTUnwrap(outgoing.last))?.pose)
        session.setROMVerified(false); session.tick(at: 12)
        XCTAssertNil(BoundPresencePacket.decode(try XCTUnwrap(outgoing.last))?.pose)
    }

    func testDelayedUnacknowledgedHelloCannotRetireTheVerifiedPeer() throws {
        let session = session(), current = UUID(), old = UUID()
        session.receive(try packet(session, peer: current, reading: reading()), at: 20)
        session.receive(try packet(session, peer: old, reading: reading(x: 999), acknowledge: false), at: 20.05)
        XCTAssertEqual(session.peerEpoch, current)
        XCTAssertEqual(session.pose(at: 20.05)?.x, 104)
        session.receive(try packet(session, peer: current, sequence: 2, time: 10.1, reading: reading(x: 120)), at: 20.1)
        XCTAssertEqual(session.peerEpoch, current)
        XCTAssertNotNil(session.pose(at: 20.1))
        // A genuine restart becomes current once it proves the new challenge.
        session.receive(try packet(session, peer: old, sequence: 2, time: 11, reading: reading(x: 136)), at: 20.15)
        XCTAssertEqual(session.peerEpoch, old); XCTAssertEqual(session.pose(at: 20.15)?.x, 136)
        session.receive(try packet(session, peer: current, sequence: 3, time: 10.2, reading: reading(), acknowledge: false), at: 20.2)
        XCTAssertEqual(session.peerEpoch, old)
    }

    func testPartnerSpectatingFreshnessAndRecovery() {
        let transport = PresenceFixtureTransport()
        let sharing = FriendSharingSession(configuration: .init(appID: String(repeating: "0", count: 32),
            channel: "spectator-test", uid: 1, remoteUID: 2, token: "offline-fixture"),
            transport: transport, authenticatedMode: false)
        sharing.watchPartner()
        XCTAssertFalse(sharing.watchingPartner)
        sharing.start()
        sharing.watchPartner()
        XCTAssertTrue(sharing.watchingPartner)
        sharing.updateSpectatorFreshness(received: 0, now: { 10 })
        XCTAssertFalse(sharing.spectatorLive)
        sharing.updateSpectatorFreshness(received: 1, now: { 11 })
        XCTAssertTrue(sharing.spectatorLive)
        sharing.updateSpectatorFreshness(received: 1, now: { 14 })
        XCTAssertFalse(sharing.spectatorLive)
        sharing.updateSpectatorFreshness(received: 2, now: { 15 })
        XCTAssertTrue(sharing.spectatorLive)
        transport.event?(.reconnecting)
        sharing.updateSpectatorFreshness(received: 2, now: { 15.1 })
        XCTAssertFalse(sharing.spectatorLive)
        sharing.stopWatchingPartner()
        XCTAssertTrue(sharing.active)
        XCTAssertFalse(sharing.watchingPartner)
        sharing.stop()
        XCTAssertFalse(sharing.spectatorLive)
    }

    func testDecodedVideoFreshnessRejectsInvalidFramesAndRequiresFreshPixelsAfterPeerDeparture() {
        let transport = PresenceFixtureTransport()
        let sharing = FriendSharingSession(configuration: .init(appID: String(repeating: "0", count: 32),
            channel: "recovery-test", uid: 1, remoteUID: 2, token: "offline-fixture"), transport: transport, authenticatedMode: false)
        sharing.start(); defer { sharing.stop() }
        transport.frameTiming = .init(received: 10, converted: nil, presented: nil, published: nil)
        sharing.watchPartner()
        sharing.updateSpectatorFreshness(received: 1, now: { 10 })
        XCTAssertFalse(sharing.remoteVisible); XCTAssertFalse(sharing.spectatorLive)
        transport.frameTiming = .init(received: 11, converted: 11, presented: nil, published: nil)
        sharing.updateSpectatorFreshness(received: 2, now: { 11 })
        XCTAssertTrue(sharing.remoteVisible); XCTAssertTrue(sharing.spectatorLive)
        transport.frameTiming = .init(received: 14, converted: 11, presented: nil, published: nil)
        sharing.updateSpectatorFreshness(received: 30, now: { 14 })
        XCTAssertFalse(sharing.remoteVisible); XCTAssertFalse(sharing.spectatorLive)
        transport.event?(.remoteGone)
        sharing.updateSpectatorFreshness(received: 30, now: { 14.1 })
        XCTAssertFalse(sharing.remoteVisible)
        transport.frameTiming = .init(received: 15, converted: 15, presented: nil, published: nil)
        sharing.updateSpectatorFreshness(received: 31, now: { 15 })
        XCTAssertTrue(sharing.remoteVisible)
        transport.event?(.reconnecting)
        sharing.updateSpectatorFreshness(received: 31, now: { 15.1 })
        XCTAssertFalse(sharing.remoteVisible)
        XCTAssertEqual(sharing.status, "Reconnecting…")
        transport.event?(.rejoined)
        sharing.updateSpectatorFreshness(received: 31, now: { 15.2 })
        XCTAssertFalse(sharing.remoteVisible)
    }

    func testVideoFreshnessSamplesClockAfterDecodedFrameTiming() {
        let transport = PresenceFixtureTransport()
        let sharing = FriendSharingSession(configuration: .init(appID: String(repeating: "0", count: 32),
            channel: "fresh-frame-clock-test", uid: 1, remoteUID: 2, token: "offline-fixture"),
            transport: transport, authenticatedMode: false)
        sharing.start(); defer { sharing.stop() }
        sharing.watchPartner()
        // Simulate a conversion completing between the previous display refresh
        // and the receiver callback. Sample the clock after reading that frame.
        var clock = 10.0
        var sampledTiming = false
        transport.frameTiming = .init(received: 10.004, converted: 10.005, presented: nil, published: nil)
        transport.frameTimingRead = { sampledTiming = true; clock = 10.006 }
        sharing.updateSpectatorFreshness(received: 1, now: {
            XCTAssertTrue(sampledTiming, "Reading the clock before the decoded frame can mark fresh video stale")
            return clock
        })
        XCTAssertTrue(sharing.remoteVisible, "A newly converted frame must not be hidden as stale")
        XCTAssertTrue(sharing.spectatorLive)
        transport.frameTimingRead = nil
        clock = 13.004
        sharing.updateSpectatorFreshness(received: 1, now: { clock })
        XCTAssertTrue(sharing.remoteVisible)
        clock = 13.006
        sharing.updateSpectatorFreshness(received: 1, now: { clock })
        XCTAssertFalse(sharing.remoteVisible, "A truly stalled decoded stream still expires after three seconds")
        XCTAssertFalse(sharing.spectatorLive)
    }

    func testSpectatorCanvasDoesNotStealCompanionPixels() {
        let companion = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        let spectator = UIView(frame: companion.frame)
        let first = FriendSharingCanvasPresenter()
        let second = FriendSharingCanvasPresenter()
        let pixels = Data(repeating: 255, count: SharingFrame.byteCount)
        XCTAssertTrue(first.present(pixels, in: companion))
        XCTAssertTrue(second.present(pixels, in: spectator))
        XCTAssertEqual(companion.subviews.count, 1)
        XCTAssertEqual(spectator.subviews.count, 1)
        second.clear()
        XCTAssertTrue(first.isVisible)
        XCTAssertEqual(companion.subviews.count, 1)
        XCTAssertTrue(spectator.subviews.isEmpty)
        first.clear()
    }

    func testFriendSessionOwnsPresenceAuthorizationAndRecoveryLifecycle() throws {
        let transport = PresenceFixtureTransport()
        let sharing = FriendSharingSession(configuration: .init(appID: String(repeating: "0", count: 32),
            channel: "presence-test", uid: 1, remoteUID: 2, token: "offline-fixture"),
            transport: transport, authenticatedMode: false)
        let presence = sharing.livePresence
        presence.setEnabled(true); XCTAssertFalse(presence.connected)
        sharing.start(); XCTAssertTrue(presence.connected)
        let staleReceiver = try XCTUnwrap(transport.receiver)
        presence.consume(reading()); presence.tick()
        XCTAssertFalse(transport.packets.isEmpty)
        transport.event?(.reconnecting); XCTAssertFalse(presence.connected)
        transport.event?(.rejoined); XCTAssertTrue(presence.connected)
        let old = try packet(presence, peer: UUID(), reading: reading())
        sharing.stop(); XCTAssertFalse(presence.connected); XCTAssertNil(transport.receiver)
        staleReceiver(old); XCTAssertNil(presence.pose())
    }

    func testROMServicePacketsUseBoundedReliableQueueAndExpectedPeer() {
        let callbacks = AgoraSharingCallbacks(remoteUID: 2) { _, _ in }
        let packet = Data("BRM1fixture".utf8)
        callbacks.receiveInteraction(packet, uid: 3)
        XCTAssertTrue(callbacks.takeInteractions().messages.isEmpty)
        callbacks.receiveInteraction(Data("BRM1".utf8) + Data(repeating: 0, count: 1024), uid: 2)
        XCTAssertTrue(callbacks.takeInteractions().messages.isEmpty)
        callbacks.receiveInteraction(packet, uid: 2)
        XCTAssertEqual(callbacks.takeInteractions().messages, [packet])
        XCTAssertNil(callbacks.takeLatestPresence(), "ROM actions must never replace the movement mailbox")
        callbacks.suspendFrames()
        callbacks.receiveInteraction(packet, uid: 2)
        XCTAssertTrue(callbacks.takeInteractions().messages.isEmpty)
    }

    func testPresentationDiagnosticsAreOptInAndNeverExportCoordinatesOrArtwork() throws {
        let session = session(), viewer = try XCTUnwrap(reading().player)
        let a = try XCTUnwrap(BoundPresencePose(reading: reading()))
        let b = try XCTUnwrap(BoundPresencePose(reading: reading(x: 120)))
        session.consume(reading(), at: 20)
        session.observePresentation(pose: a, viewer: viewer, frameResolved: true, visiblePixels: 100, at: 20)
        XCTAssertEqual(session.connectionReaderCheck(at: 20).renderedTicks, 0)
        let check = session.connectionCheck
        check.snapshot = { [weak session] in
            guard let session else { return nil }
            var value = BoundPresenceConnectionSample(); value.reader = session.connectionReaderCheck(at: 20); return value
        }
        check.start(schedule: false)
        session.observePresentation(pose: a, viewer: viewer, frameResolved: true, visiblePixels: 100, at: 20)
        session.observePresentation(pose: b, viewer: viewer, frameResolved: true, visiblePixels: 100, at: 20)
        let result = session.connectionReaderCheck(at: 20)
        XCTAssertEqual(result.renderedTicks, 2); XCTAssertEqual(result.movementChanges, 1)
        XCTAssertEqual(result.mapMatches, true); XCTAssertEqual(result.elevationMatches, true)
        XCTAssertEqual(result.visiblePixels, 100)
        XCTAssertEqual(session.connectionReaderCheck(at: 21).visiblePixels, 0, "Stale display metrics cannot claim current visibility")
        session.observePresentation(pose: nil, viewer: nil, frameResolved: false, visiblePixels: 0, at: 20)
        XCTAssertEqual(session.connectionReaderCheck(at: 20).visiblePixels, 0)
        let text = try XCTUnwrap(String(data: check.export(), encoding: .utf8))
        for forbidden in ["frameAddress", "palette", "mapGroup", "mapNumber", "worldFoot", "tiles", "token", "channel"] {
            XCTAssertFalse(text.contains("\"\(forbidden)\""))
        }
    }
}

@MainActor
extension LivePresenceTests {
    func testExperimentalOptInDoesNotReuseRetiredCustomizationKeys() throws {
        let suite = "MultiplayerFeatureGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: BoundExperimentalSettingsPreferences.key)
        defaults.set(true, forKey: BoundLegacyPreferences.experimentalFeaturesKey)
        XCTAssertFalse(defaults.bool(forKey: BoundMultiplayerFeatures.key))
        defaults.set(true, forKey: BoundMultiplayerFeatures.key)
        XCTAssertTrue(try XCTUnwrap(UserDefaults(suiteName: suite)).bool(forKey: BoundMultiplayerFeatures.key))
        defaults.set(false, forKey: BoundMultiplayerFeatures.key)
        XCTAssertTrue(defaults.bool(forKey: BoundExperimentalSettingsPreferences.key))
        XCTAssertTrue(defaults.bool(forKey: BoundLegacyPreferences.experimentalFeaturesKey))
    }

    func testExperimentalDisablePreservesTradeRecoveryInstruction() {
        let transport = PresenceFixtureTransport()
        let sharing = FriendSharingSession(configuration: .init(appID: String(repeating:"0",count:32),
            channel:"trade-recovery-gate",uid:1,remoteUID:2,token:"offline-fixture"),
            transport:transport,authenticatedMode:false)
        defer { sharing.stop() }
        sharing.start()
        let message="Trade interrupted. Continue from your in-game save."
        sharing.interactions.activityEnded(message)
        BoundMultiplayerFeatures.setEnabled(false)
        XCTAssertEqual(sharing.interactions.phase,.ended)
        XCTAssertEqual(sharing.interactions.message,message)
        XCTAssertFalse(sharing.interactions.connected)
        BoundMultiplayerFeatures.setEnabled(true)
        XCTAssertEqual(sharing.interactions.message,message)
        sharing.interactions.cancel()
        XCTAssertEqual(sharing.interactions.phase,.idle)
    }

    func testExperimentalGateBlocksRuntimeEntryAndStopsActiveChannels() throws {
        BoundMultiplayerFeatures.setEnabled(false)
        let transport = PresenceFixtureTransport()
        let sharing = FriendSharingSession(configuration: .init(appID: String(repeating: "0", count: 32),
            channel: "gate-test", uid: 1, remoteUID: 2, token: "offline-fixture"),
            transport: transport, authenticatedMode: false)
        defer { sharing.stop() }
        sharing.start()
        XCTAssertTrue(sharing.active, "Ordinary friend video sharing remains available")
        XCTAssertFalse(sharing.livePresence.connected)
        XCTAssertFalse(sharing.interactions.connected)
        sharing.livePresence.setEnabled(true)
        sharing.livePresence.start { _ in XCTFail("Disabled presence must not send"); return false }
        sharing.interactions.start { _ in XCTFail("Disabled invitations must not send"); return false }
        XCTAssertFalse(sharing.livePresence.enabled)
        XCTAssertFalse(sharing.livePresence.needsReader)
        XCTAssertFalse(sharing.interactions.open())
        let recording = BoundRecordedPlayerSession(); recording.record()
        XCTAssertEqual(recording.mode, .idle)
        for activity in BoundFriendInteractionPacket.Activity.allCases {
            sharing.nativeBattle.begin(activity: activity, id: UUID(), initiator: true)
            XCTAssertFalse(sharing.nativeBattle.isActive)
        }
        XCTAssertFalse(sharing.nativeBattle.isActive)
        XCTAssertFalse(sharing.nativeBattle.blocksAutoSave)

        BoundMultiplayerFeatures.setEnabled(true)
        XCTAssertTrue(sharing.livePresence.connected)
        XCTAssertTrue(sharing.interactions.connected)
        sharing.livePresence.setEnabled(true)
        sharing.livePresence.consume(reading()); sharing.livePresence.tick()
        XCTAssertFalse(transport.packets.isEmpty)
        let lateReceiver = try XCTUnwrap(transport.receiver)
        sharing.livePresence.connectionCheck.start(schedule: false)
        BoundMultiplayerFeatures.setEnabled(false)
        XCTAssertTrue(sharing.active)
        XCTAssertFalse(sharing.livePresence.enabled)
        XCTAssertFalse(sharing.livePresence.connected)
        XCTAssertFalse(sharing.livePresence.connectionCheck.recording)
        XCTAssertFalse(sharing.interactions.connected)
        XCTAssertEqual(sharing.interactions.phase, .idle)
        let received = sharing.livePresence.receivedPackets
        lateReceiver(try packet(sharing.livePresence, peer: UUID(), reading: reading()))
        XCTAssertEqual(sharing.livePresence.receivedPackets, received)
        transport.event?(.reconnecting); transport.event?(.rejoined)
        XCTAssertFalse(sharing.livePresence.connected, "Rejoin cannot bypass the gate")

        BoundMultiplayerFeatures.setEnabled(true)
        XCTAssertTrue(sharing.livePresence.connected)
        XCTAssertTrue(sharing.livePresence.enabled, "The master multiplayer switch enables sprites automatically")
        UserDefaults.standard.removeObject(forKey: BoundMultiplayerFeatures.key)
        NotificationCenter.default.post(name: Settings.didResetNotification, object: nil)
        XCTAssertFalse(sharing.livePresence.connected)
        XCTAssertFalse(sharing.interactions.connected)
    }
}
