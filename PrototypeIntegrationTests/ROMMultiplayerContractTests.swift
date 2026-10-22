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
    func testLobbyRequestCarriesThreeDistinctFriendsAndRejectsMalformedSelection() throws {
        var bytes = Data(repeating: 0, count: 256)
        bytes.replaceSubrange(0..<8, with: [82,85,82,49,1,0,0,0])
        word(2, 8, &bytes); word(BoundROMCommand.lobbyCreate.rawValue, 12, &bytes)
        word(71, 88, &bytes); word(1, 100, &bytes); word(3, 104, &bytes); word(1, 156, &bytes)
        let rooms = [UUID(), UUID(), UUID()]
        for (index, room) in rooms.enumerated() {
            var value = room.uuid
            withUnsafeBytes(of: &value) { bytes.replaceSubrange(108 + index * 16..<124 + index * 16, with: $0) }
        }
        let request = try XCTUnwrap(BoundROMRequest.decode(bytes))
        XCTAssertEqual(request.command, .lobbyCreate); XCTAssertEqual(request.selectedRooms, rooms)
        XCTAssertEqual(request.lobbyMode, 1); XCTAssertTrue(request.soloChoice)
        var bad = bytes; word(4, 104, &bad); XCTAssertNil(BoundROMRequest.decode(bad))
        bad = bytes; word(2, 100, &bad); XCTAssertNil(BoundROMRequest.decode(bad))
        bad = bytes; word(2, 156, &bad); XCTAssertNil(BoundROMRequest.decode(bad))
        bad = bytes; bad.replaceSubrange(124..<140, with: bytes[108..<124]); XCTAssertNil(BoundROMRequest.decode(bad))
        bad = bytes; bad.replaceSubrange(108..<124, with: Data(repeating: 0, count: 16)); XCTAssertNil(BoundROMRequest.decode(bad))
        bad = bytes; word(UInt32.max, 104, &bad); XCTAssertNil(BoundROMRequest.decode(bad))
    }
    private func lobbyMember(_ owner: UUID, uid: UInt, state: String = "joined", partner: UUID? = nil) -> BoundLobbySnapshot.Member {
        .init(ownerID: owner, displayName: String(repeating: "A", count: 40), uid: uid, state: state, ready: true,
              mode: partner == nil ? "solo" : "soulLink", runID: UUID(), partnerOwnerID: partner,
              online: state == "joined", sessionID: UUID(), generation: "1")
    }
    func testLobbyHostKeepsPairLabelsSeparateAndBoundsNativeRoster() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var snapshot = BoundLobbySnapshot(lobbyID: UUID(), creatorID: a, state: "started", revision: "5", members: [
            lobbyMember(a, uid: 1, partner: b), lobbyMember(b, uid: 2, partner: a),
            lobbyMember(c, uid: 3, partner: d), lobbyMember(d, uid: 4, partner: c)])
        var host = BoundROMHostState(); host.lobby = snapshot; host.lobbyOwner = a; host.lobbyJoined = true
        let bytes = host.encoded(sequence: 2)
        XCTAssertEqual(bytes.count, 2048); XCTAssertEqual(uint32(bytes, 1360), 0x3159424C)
        XCTAssertEqual(Array(bytes[1364..<1368]), [1,0,48,1]); XCTAssertEqual(uint32(bytes, 1372), 4)
        XCTAssertEqual(uint32(bytes, 1368) & 15, 15)
        let slots = (0..<4).map { uint32(bytes, 1424 + $0 * 60 + 52) }
        XCTAssertGreaterThan(slots[0], 0); XCTAssertEqual(slots[0], slots[1]); XCTAssertEqual(slots[2], slots[3]); XCTAssertNotEqual(slots[0], slots[2])
        for row in 0..<4 { XCTAssertEqual(bytes[1424 + row * 60 + 47], 0) }
        snapshot.members.append(lobbyMember(UUID(), uid: 5)); host.lobby = snapshot
        XCTAssertEqual(uint32(host.encoded(sequence: 4), 1372), 4, "The cartridge extension can never overflow its four native rows")
        snapshot.members[1].state = "declined"; snapshot.members.removeLast(); host.lobby = snapshot
        XCTAssertEqual(uint32(host.encoded(sequence: 6), 1372), 3, "Declined invitations do not appear as lobby players")
    }
    func testLobbyHostRequiresCurrentTokenForJoinedFlagAndDoesNotInventCreator() {
        let owner = UUID()
        var snapshot = BoundLobbySnapshot(lobbyID: UUID(), creatorID: owner, state: "waiting", revision: "1", members: [lobbyMember(owner, uid: 1)])
        var host = BoundROMHostState(); host.lobby = snapshot; host.lobbyOwner = owner; host.lobbyRejoinAvailable = true
        var bytes = host.encoded(sequence: 2)
        XCTAssertEqual(uint32(bytes, 1368) & 1, 0, "Cached joined membership is not current authenticated transport authority")
        XCTAssertEqual(uint32(bytes, 1368) & 64, 64)
        host.lobbyJoined = true; bytes = host.encoded(sequence: 4)
        XCTAssertEqual(uint32(bytes, 1368) & 1, 1)
        snapshot.creatorID = nil; snapshot.members[0].state = "left"; snapshot.members[0].online = false
        host.lobby = snapshot; host.lobbyOwner = nil; host.lobbyJoined = false
        bytes = host.encoded(sequence: 6)
        XCTAssertEqual(uint32(bytes, 1368) & 3, 0, "Two absent UUIDs cannot grant the native creator flag")
    }
    private func soloRecord(owner: UUID = UUID(), committed: Bool = true) -> BoundSoloRunRecord {
        var settings = Data(repeating: 0, count: 32); settings[0] = 3
        return .init(run: UUID(), owner: owner, gameID: "solo-admission-fixture", romSHA256: BoundWorldContract.romSHA256,
                     seed: 1234, settings: committed ? settings:Data(), ended: false, originalSaveSHA256: nil, version: 1)
    }
    private func soloLedger(_ record: BoundSoloRunRecord) -> BoundSoulLedger {
        var ledger = BoundSoulLedger(run: record.run, binding: BoundSoulSession.soloBinding(owner: record.owner, gameID: record.gameID))
        ledger.soloOwner = record.owner
        return ledger
    }
    func testCommittedSoloAdmissionRequiresOriginalOwnerActiveJournalAndBinding() {
        let record = soloRecord(), ledger = soloLedger(record)
        func admission(_ journal: BoundSoulLedger?, owner: UUID? = nil, error: String? = nil) -> BoundSoloRunAdmission {
            .evaluate(record, owner: owner ?? record.owner, ledger: journal, journalError: error, hasPairedState: false, newGameProof: false)
        }
        XCTAssertEqual(admission(ledger), .play, "Solo authorization requires no peer or lobby")
        XCTAssertEqual(admission(ledger, owner: UUID()), .wrongOwner)
        XCTAssertEqual(admission(nil), .journalRecovery)
        XCTAssertEqual(admission(ledger, error: "Unreadable journal"), .journalRecovery)
        var wrong = ledger; wrong.ended = true; XCTAssertEqual(admission(wrong), .journalRecovery)
        wrong = BoundSoulLedger(run: record.run, binding: String(repeating: "a", count: 64)); wrong.soloOwner = record.owner; XCTAssertEqual(admission(wrong), .journalRecovery)
        wrong = ledger; wrong.soloOwner = nil; XCTAssertEqual(admission(wrong), .journalRecovery)
        wrong = BoundSoulLedger(run: UUID(), binding: ledger.binding); wrong.soloOwner = record.owner; XCTAssertEqual(admission(wrong), .journalRecovery)
        XCTAssertEqual(BoundSoloRunAdmission.evaluate(record, owner: nil, ledger: ledger, journalError: nil,
                                                       hasPairedState: false, newGameProof: false), .wrongOwner)
    }
    func testPendingSoloRestartNeedsFreshNativeSetupProofAndCannotReplaceCorruptJournal() {
        let record = soloRecord(committed: false), ledger = soloLedger(record)
        func admission(_ journal: BoundSoulLedger?, proof: Bool, error: String? = nil) -> BoundSoloRunAdmission {
            .evaluate(record, owner: record.owner, ledger: journal, journalError: error, hasPairedState: false, newGameProof: proof)
        }
        XCTAssertEqual(admission(nil, proof: false), .pendingSetup, "Cold Continue cannot adopt an uncommitted Nuzlocke")
        XCTAssertEqual(admission(nil, proof: true), .setup)
        XCTAssertEqual(admission(ledger, proof: false), .pendingSetup, "Journal-first settings write can recover without discarding its run")
        XCTAssertEqual(admission(ledger, proof: true), .setup)
        XCTAssertEqual(admission(nil, proof: true, error: "Corrupt"), .journalRecovery)
        var progressed = ledger; progressed.dead.insert("area:1")
        XCTAssertEqual(admission(progressed, proof: true), .journalRecovery, "An unfinished manifest cannot reset a previously advanced journal")
        var previous = BoundSoulLedger(run: UUID(), binding: ledger.binding); previous.ended = true
        XCTAssertEqual(admission(previous, proof: true), .setup, "A prior explicitly ended run can be archived when setup commits")
    }
    func testSoloAdmissionRejectsAnyConcurrentPairAuthority() {
        for committed in [false, true] {
            let record = soloRecord(committed: committed)
            XCTAssertEqual(BoundSoloRunAdmission.evaluate(record, owner: record.owner, ledger: soloLedger(record),
                journalError: nil, hasPairedState: true, newGameProof: true), .conflictingRun)
        }
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
