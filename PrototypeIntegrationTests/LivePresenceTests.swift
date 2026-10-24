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
    func setPresenceReceiver(_ receiver: (@MainActor (Data) -> Void)?) { self.receiver = receiver }
    func sendPresence(_ data: Data) -> Bool { packets.append(data); return true }
    func start(configuration: FriendSharingConfiguration, remoteView: UIView,
               event: @escaping @MainActor (FriendSharingEvent) -> Void) { self.event = event; event(.joined) }
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

    func reading(x: Int = 104, map: Int = 3, elevation: Int = 0) -> BoundPlayerStateReading {
        let sprite = BoundPlayerSprite(width: 16, height: 32, tiles: Data(repeating: 0x11, count: 256),
            palette: Data(repeating: 0, count: 32), flipX: false, flipY: false, priority: 2, romAddress: 0x08123450)
        var player = BoundPlayerState(mapGroup: 4, mapNumber: map, tile: .init(x: x / 16, y: 6),
            previousTile: .init(x: x / 16, y: 6), facing: "South", elevation: elevation, graphicsID: 0,
            runningState: 0, tileTransitionState: 0)
        player.scene = .init(worldFoot: .init(x: x, y: 112), camera: .init(x: 16, y: -24), appearance: sprite,
            background: .init(tiles: Data(repeating: 0, count: 32768), layers: []), objects: [])
        return .init(frame: 12345, status: .live, detail: "Fixture", player: player)
    }
    func packet(_ session: BoundLivePresenceSession, peer: UUID, sequence: UInt64 = 1, time: Double = 10,
                reading: BoundPlayerStateReading? = nil, acknowledge: Bool = true,
                rom: String = BoundPlayerROMProfile.supportedSHA256, withdrawn: Bool = false) throws -> Data {
        var value = BoundPresencePacket(version: 1, rom: rom, sender: peer,
            receiver: acknowledge ? session.epoch : nil, sequence: sequence, time: time,
            pose: reading.flatMap(BoundPresencePose.init))
        if withdrawn { value.withdrawn = true }
        return try XCTUnwrap(value.encoded())
    }
    func session() -> BoundLivePresenceSession {
        let session = BoundLivePresenceSession(); session.setROMVerified(true)
        session.setEnabled(true); session.start { _ in true }; return session
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

    func testDistanceNeverRemovesPeerAndOffscreenUpdatesSurviveCameraReentry() throws {
        let session = session(), peer = UUID()
        let viewer = try XCTUnwrap(reading().player)
        session.consume(reading(), at: 20)
        for (index, tiles) in [1, 3, 5, 10, 30, 1].enumerated() {
            let now = 20 + Double(index) * 0.1
            let x = 104 + tiles * 16
            session.receive(try packet(session, peer: peer, sequence: UInt64(index + 1),
                time: now - 10, reading: reading(x: x)), at: now)
            let pose = try XCTUnwrap(session.pose(at: now + 0.11))
            XCTAssertEqual(pose.x, Double(x), "Distance and large updates only affect interpolation")
            XCTAssertTrue(pose.isSpatiallyComparable(to: viewer))
        }
        XCTAssertEqual(session.receivedPackets, 6)
        XCTAssertEqual(session.rejectedPackets, 0)
        XCTAssertEqual(session.pose(at: 20.61)?.x, 120)
    }

    func testDifferentMapsAndElevationsRemainTrackedWithoutComparableDirections() throws {
        let session = session(), peer = UUID(), viewer = try XCTUnwrap(reading().player)
        session.receive(try packet(session, peer: peer, reading: reading(x: 500, map: 8)), at: 20)
        let otherMap = try XCTUnwrap(session.pose(at: 20))
        XCTAssertEqual(otherMap.x, 500)
        XCTAssertFalse(otherMap.isSpatiallyComparable(to: viewer))
        session.receive(try packet(session, peer: peer, sequence: 2, time: 10.1,
                                   reading: reading(x: 600, elevation: 2)), at: 20.1)
        let otherElevation = try XCTUnwrap(session.pose(at: 20.1))
        XCTAssertEqual(otherElevation.x, 600)
        XCTAssertFalse(otherElevation.isSpatiallyComparable(to: viewer))
        session.receive(try packet(session, peer: peer, sequence: 3, time: 10.2,
                                   reading: reading(x: 120)), at: 20.2)
        XCTAssertTrue(try XCTUnwrap(session.pose(at: 20.2)).isSpatiallyComparable(to: viewer))
    }

    func testPauseTimeoutRestoreAndReconnectRejectPreviousSession() throws {
        let session = session(), peer = UUID()
        let old = try packet(session, peer: peer, reading: reading())
        session.receive(old, at: 20); XCTAssertNotNil(session.pose(at: 20))
        session.receive(try packet(session, peer: peer, sequence: 2, time: 10.05), at: 20.05)
        XCTAssertNotNil(session.pose(at: 20.05), "A temporarily paused reader retains its avatar")
        XCTAssertNil(session.collision(at: 20.05))
        session.receive(try packet(session, peer: peer, sequence: 3, time: 10.1, reading: reading()), at: 20.1)
        XCTAssertEqual(session.pose(at: 20.6)?.x, 104, "A brief gap holds the confirmed position without extrapolation")
        XCTAssertNotNil(session.pose(at: 20.851), "A stale avatar remains visible during the reconnect grace")
        XCTAssertNil(session.collision(at: 20.851))
        let epoch = session.epoch; session.tick(at: 21)
        XCTAssertNotEqual(epoch, session.epoch)
        session.receive(old, at: 21); XCTAssertNotNil(session.pose(at: 21))
        XCTAssertNil(session.collision(at: 21), "Cached presentation never authorizes stale collision")
        let fresh = try packet(session, peer: peer, sequence: 4, time: 11, reading: reading())
        session.receive(fresh, at: 21); XCTAssertNotNil(session.pose(at: 21))
        session.invalidateLocal(); session.receive(fresh, at: 21.01)
        XCTAssertNil(session.pose(at: 21.01), "Restored state must negotiate a fresh session")
        session.stop(); session.start { _ in true }; session.receive(fresh, at: 21.02)
        XCTAssertNil(session.pose(at: 21.02))
    }

    func testPacketJitterKeepsStationarySpriteWithoutBlockingUntilExplicitWithdrawal() throws {
        let session = session(), peer = UUID()
        var withdrawals = 0
        session.peerWithdrew = { withdrawals += 1 }
        session.receive(try packet(session, peer: peer, time: 10, reading: reading()), at: 20)
        for elapsed in [0.05, 0.35, 0.5, 0.74] {
            XCTAssertEqual(session.pose(at: 20 + elapsed)?.x, 104)
            XCTAssertNil(session.collision(at: 20 + elapsed), "A remote avatar never owns local collision")
        }
        session.receive(try packet(session, peer: peer, sequence: 2, time: 10.74, reading: reading()), at: 20.74)
        XCTAssertEqual(session.pose(at: 21.2)?.x, 104, "A stationary heartbeat renews its position")
        XCTAssertNil(session.collision(at: 21.2))
        XCTAssertEqual(withdrawals, 0, "Missing packets are not deliberate departure")
        session.receive(try packet(session, peer: peer, sequence: 3, time: 11.21, withdrawn: true), at: 21.21)
        XCTAssertNil(session.pose(at: 21.21)); XCTAssertNil(session.collision(at: 21.21))
        XCTAssertEqual(withdrawals, 1)
    }

    func testRemoteAvatarsNeverBlockDivergentPuzzleOrStoryWorlds() throws {
        let session = session(), peer = UUID()
        session.receive(try packet(session, peer: peer, reading: reading(x: 104)), at: 20)
        session.receive(try packet(session, peer: peer, sequence: 2, time: 10.05, reading: reading(x: 112)), at: 20.05)
        XCTAssertNil(session.collision(at: 20.05), "Even a fresh walking sprite may overlap a different local puzzle")
        XCTAssertEqual(session.pose(at: 20.05)?.x, 104)
        var host = BoundROMHostState(); host.enabled = true; host.peerCollision = session.collision(at: 20.05)
        let encoded = host.encoded(sequence: 2)
        XCTAssertTrue(encoded[1360..<1376].allSatisfy { $0 == 0 })
        host.enabled = false
        XCTAssertTrue(host.encoded(sequence: 4)[1360..<1376].allSatisfy { $0 == 0 })
        XCTAssertNil(session.collision(at: 20.801))
        session.invalidateLocal(); XCTAssertNil(session.collision(at: 20.06))
        var diagonal = try XCTUnwrap(BoundPresencePose(reading: reading(x: 112)))
        diagonal.y = 120
        XCTAssertNil(BoundPresenceCollision(pose: diagonal))
        diagonal.y = 112; diagonal.x = 1_000_000
        XCTAssertNil(BoundPresenceCollision(pose: diagonal))
    }

    func testServerSnapshotHasADeadlineAndNeverGrantsInteractionAuthority() throws {
        let session = session(), peer = UUID()
        let snapshot = try packet(session, peer: peer, reading: reading(x:136))
        session.restorePresentation(snapshot, age:20, at:100)
        XCTAssertEqual(session.pose(at:100)?.x,136)
        XCTAssertNil(session.collision(at:100))
        XCTAssertNil(session.interactionContext(at:100))
        XCTAssertNil(session.peerEpoch)
        XCTAssertNil(session.pose(at:140))
        session.restorePresentation(snapshot, age:60, at:200)
        XCTAssertNil(session.pose(at:200))
    }

    func testReconnectRetainsPresentationButExplicitStopAndRestoreClearIt() throws {
        let session = session(), peer = UUID()
        session.receive(try packet(session,peer:peer,reading:reading()),at:20)
        session.stop(keepPresentation:true)
        XCTAssertEqual(session.pose(at:21)?.x,104)
        XCTAssertNil(session.collision(at:21))
        session.start { _ in true }
        XCTAssertEqual(session.pose(at:22)?.x,104)
        XCTAssertNil(session.interactionContext(at:22))
        session.invalidateLocal()
        XCTAssertNil(session.pose(at:22))
        session.restorePresentation(try packet(session,peer:peer,reading:reading()),age:0,at:23)
        session.stop()
        XCTAssertNil(session.pose(at:23))
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
