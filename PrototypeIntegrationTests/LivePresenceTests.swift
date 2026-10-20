import XCTest
import UIKit
@testable import Delta

@MainActor
private final class PresenceFixtureTransport: FriendSharingTransport {
    var publishedFrames = 0
    var receivedFrames = 0
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
                rom: String = BoundPlayerROMProfile.supportedSHA256) throws -> Data {
        try XCTUnwrap(BoundPresencePacket(version: 1, rom: rom, sender: peer,
            receiver: acknowledge ? session.epoch : nil, sequence: sequence, time: time,
            pose: reading.flatMap(BoundPresencePose.init)).encoded())
    }
    func session() -> BoundLivePresenceSession {
        let session = BoundLivePresenceSession(); session.setROMVerified(true)
        session.setEnabled(true); session.start { _ in true }; return session
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
}
