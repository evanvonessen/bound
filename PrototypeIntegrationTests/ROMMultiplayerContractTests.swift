import XCTest
@testable import Delta

final class ROMMultiplayerContractTests: XCTestCase {
    @MainActor
    func testCommonCheatChoiceHasVersionedSharedSettingsAndRejectsUnknownBits() {
        var settings = Data(repeating: 0, count: 32)
        settings[0] = 1
        XCTAssertTrue(BoundROMMultiplayerCoordinator.validSettings(settings))
        settings[10] = 1
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings))
        settings[0] = 2
        XCTAssertTrue(BoundROMMultiplayerCoordinator.validSettings(settings))
        settings[10] = 0
        XCTAssertTrue(BoundROMMultiplayerCoordinator.validSettings(settings))
        settings[10] = 2
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings))
        settings[10] = 1; settings[31] = 1
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings))
        settings[31] = 0; settings[2] = 1; settings[3] = 1
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings))
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(Data()))
    }

    @MainActor
    func testAutomaticNicknameChoiceRequiresVersionThreeAndRejectsUnknownSettings() {
        var settings = Data(repeating: 0, count: 32)
        settings[11] = 1
        for version in [UInt8(1), 2] {
            settings[0] = version
            XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings),
                           "Older settings formats cannot silently enable automatic nicknames")
        }
        settings[0] = 3
        for cheats in [UInt8(0), 1] {
            for nicknames in [UInt8(0), 1] {
                settings[10] = cheats; settings[11] = nicknames
                XCTAssertTrue(BoundROMMultiplayerCoordinator.validSettings(settings))
            }
        }
        settings[11] = 2
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings))
        settings[11] = 1
        for reserved in 12..<32 {
            settings[reserved] = 1
            XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings))
            settings[reserved] = 0
        }
        settings[0] = 4
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings))
        settings[0] = 0
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings))
    }

    func testCheckpointCaptureWaitsUntilBothCartridgesFreezeTheSameHistory() {
        func stage(local: Bool = true, peer: Bool = true, pending: Bool = true,
                   history: Bool = true, fresh: Bool = true) -> BoundROMCheckpointStage {
            BoundROMCheckpointReadiness.stage(localStored: false, partnerStored: false, peerCommitted: false,
                localPaused: local, peerPaused: peer, peerPendingMatches: pending, historyMatches: history, fresh: fresh)
        }
        XCTAssertEqual(stage(), .capture)
        XCTAssertEqual(stage(local: false), .wait, "A save request is not proof the local game has frozen")
        XCTAssertEqual(stage(peer: false), .wait, "The peer may still be completing its current gameplay callback")
        XCTAssertEqual(stage(pending: false), .wait, "A different transaction cannot acknowledge this capture")
        XCTAssertEqual(stage(history: false), .wait, "A death or catch in the last frame must reconcile before capture")
        XCTAssertEqual(stage(fresh: false), .wait, "A pre-disconnect frozen heartbeat is insufficient")
    }
    func testPreparedCheckpointCanCommitAfterPeerAlreadyClearedItsPendingTransaction() {
        let stage = BoundROMCheckpointReadiness.stage(localStored: true, partnerStored: true, peerCommitted: false,
            localPaused: true, peerPaused: false, peerPendingMatches: false, historyMatches: false, fresh: true)
        XCTAssertEqual(stage, .commit, "Durable agreeing receipts permit recovery after the peer advances to its committed head")
        XCTAssertEqual(BoundROMCheckpointReadiness.stage(localStored: true, partnerStored: false, peerCommitted: false,
            localPaused: true, peerPaused: true, peerPendingMatches: true, historyMatches: true, fresh: true), .wait,
            "A local prepared file alone must never become a complete checkpoint")
    }
    func testCommittedReplayFinishesAfterHelloReportsNoPendingCheckpoint() {
        XCTAssertEqual(BoundROMCheckpointReadiness.stage(localStored: true, partnerStored: true, peerCommitted: true,
            localPaused: true, peerPaused: false, peerPendingMatches: false, historyMatches: false, fresh: true), .finish,
            "Committed receipt and subsequent no-pending Hello can arrive in the same transport pump")
        XCTAssertEqual(BoundROMCheckpointReadiness.stage(localStored: false, partnerStored: true, peerCommitted: true,
            localPaused: true, peerPaused: false, peerPendingMatches: false, historyMatches: true, fresh: true), .wait,
            "A peer receipt cannot replace missing local save bytes")
        XCTAssertEqual(BoundROMCheckpointReadiness.stage(localStored: true, partnerStored: true, peerCommitted: true,
            localPaused: true, peerPaused: false, peerPendingMatches: false, historyMatches: true, fresh: false), .wait,
            "Restarted transactions still require a fresh authenticated channel")
    }
    private func word(_ value: UInt32, _ offset: Int, _ data: inout Data) {
        for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }
    private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset+$1]) << ($1*8) }
    }
    func testROMRequestRequiresFullStableKnownVersionAndCommand() throws {
        var bytes = Data(repeating: 0, count: 256)
        bytes.replaceSubrange(0..<8, with: [82,85,82,49,1,0,0,0])
        word(2, 8, &bytes); word(BoundROMCommand.checkpoint.rawValue, 12, &bytes)
        word(5, 80, &bytes); word(42, 88, &bytes)
        let request = try XCTUnwrap(BoundROMRequest.decode(bytes))
        XCTAssertEqual(request.command, .checkpoint)
        XCTAssertTrue(request.safeField); XCTAssertTrue(request.paused)
        XCTAssertFalse(request.newGame); XCTAssertEqual(request.requestID, 42)
        XCTAssertNil(BoundROMRequest.decode(bytes.dropLast()))
        word(3, 8, &bytes); XCTAssertNil(BoundROMRequest.decode(bytes))
        word(2, 8, &bytes); word(999, 12, &bytes); XCTAssertNil(BoundROMRequest.decode(bytes))
        word(0, 12, &bytes); bytes[4] = 2; XCTAssertNil(BoundROMRequest.decode(bytes))
    }
    func testHostMenuLimitsRowsAndNullTerminatesText() {
        var host = BoundROMHostState()
        host.enabled = true; host.linked = true; host.saving = true
        host.message = String(repeating: "X", count: 1000)
        host.partnerName = "José"
        host.friends = (0..<24).map { _ in .init(room: UUID(), name: String(repeating: "Y", count: 100)) }
        let bytes = host.encoded(sequence: 2)
        XCTAssertEqual(bytes.count, 2048)
        XCTAssertEqual(uint32(bytes, 24), 20)
        XCTAssertEqual(uint32(bytes, 12) & 0x103, 0x103)
        XCTAssertEqual(bytes[311], 0)
        XCTAssertEqual(String(data: bytes.subdata(in: 88..<92), encoding: .ascii), "Jose")
        for row in 0..<20 { XCTAssertEqual(bytes[320 + row*52 + 16 + 31], 0) }
    }
    func testPeerPacketRejectsOversizeUnknownVersionReservedBitsAndZeroSequence() throws {
        let packet = BoundROMPacket(kind: .prepared, owner: UUID(), epoch: UUID(), receiver: UUID(), sequence: 1, body: Data(repeating: 5, count: 960))
        let bytes = try XCTUnwrap(packet.encoded())
        XCTAssertEqual(bytes.count, 1024)
        XCTAssertEqual(BoundROMPacket.decode(bytes), packet)
        var damaged = bytes; damaged[6] = 1; XCTAssertNil(BoundROMPacket.decode(damaged))
        damaged = bytes; damaged[4] = 2; XCTAssertNil(BoundROMPacket.decode(damaged))
        damaged = bytes; damaged.replaceSubrange(56..<64, with: repeatElement(UInt8(0), count: 8))
        XCTAssertNil(BoundROMPacket.decode(damaged))
        XCTAssertNil(BoundROMPacket(kind: .prepared, owner: packet.owner, epoch: packet.epoch, receiver: nil,
            sequence: 1, body: Data(repeating: 0, count: 961)).encoded())
    }
    private func connect(_ alice: inout BoundROMChannel, _ bob: inout BoundROMChannel, a: UUID, b: UUID) throws {
        let hello = try XCTUnwrap(BoundROMPacket.decode(try XCTUnwrap(alice.packet(.hello, owner: a, body: "hello"))))
        XCTAssertFalse(bob.admit(hello, at: 10))
        let reply = try XCTUnwrap(BoundROMPacket.decode(try XCTUnwrap(bob.packet(.hello, owner: b, body: "hello"))))
        XCTAssertTrue(alice.admit(reply, at: 10))
        let ack = try XCTUnwrap(BoundROMPacket.decode(try XCTUnwrap(alice.packet(.hello, owner: a, body: "hello"))))
        XCTAssertTrue(bob.admit(ack, at: 10))
    }
    func testFreshNonceAcknowledgementAndMonotonicPacketsAreRequired() throws {
        var alice = BoundROMChannel(), bob = BoundROMChannel()
        let a = UUID(), b = UUID()
        try connect(&alice, &bob, a: a, b: b)
        let packet = try XCTUnwrap(BoundROMPacket.decode(try XCTUnwrap(bob.packet(.prepared, owner: b, body: "receipt"))))
        XCTAssertTrue(alice.admit(packet, at: 11))
        XCTAssertFalse(alice.admit(packet, at: 11.1))
        XCTAssertTrue(alice.fresh(at: 13.9)); XCTAssertFalse(alice.fresh(at: 14))
        XCTAssertFalse(alice.fresh(at: 9))
    }
    func testRetiredPeerEpochCannotReenterAfterReconnect() throws {
        var alice = BoundROMChannel(), bob = BoundROMChannel()
        let a = UUID(), b = UUID()
        try connect(&alice, &bob, a: a, b: b)
        var retiredBob = bob
        bob.reset()
        try connect(&bob, &alice, a: b, b: a)
        let replay = try XCTUnwrap(BoundROMPacket.decode(try XCTUnwrap(retiredBob.packet(.prepared, owner: b, body: "old receipt"))))
        XCTAssertFalse(alice.admit(replay, at: 12), "Retired sessions cannot reset the sequence gate")
        XCTAssertEqual(alice.peerEpoch, bob.epoch)
    }
}
