import XCTest
@testable import Delta

final class ROMMultiplayerContractTests: XCTestCase {
    func testQueuedActionsWaitForIdleFieldAndExpireWhileBlocked() {
        func request(_ flags: UInt32) -> BoundROMRequest {
            .init(sequence: 2, command: .none, friendIndex: 0, argument: 0, identifier: UUID(),
                  settings: Data(repeating: 0, count: 32), flags: flags, frame: 1, requestID: 1)
        }
        for command in [BoundROMCommand.battle, .trade, .watch] {
            var queue = BoundROMActionQueue()
            queue.enqueue(command, at: 100)
            let blockedFlags: [UInt32] = [1, 0, 65 | 4, 65 | 2]
            for flags in blockedFlags {
                XCTAssertNil(queue.ready(request: request(flags), connected: true, at: 101))
            }
            XCTAssertNil(queue.ready(request: nil, connected: true, at: 102))
            XCTAssertNil(queue.ready(request: request(65), connected: false, at: 103))
            XCTAssertEqual(queue.ready(request: request(65), connected: true, at: 104), command)
            queue.clear()
            XCTAssertNil(queue.ready(request: request(65), connected: true, at: 105), "Cancelled actions cannot run later")
            for connected in [true, false] {
                queue.enqueue(command, at: 200)
                XCTAssertNil(queue.ready(request: request(1), connected: connected, at: 215))
                XCTAssertNil(queue.command, "Expiry must run even during dialogue or disconnection")
                XCTAssertNil(queue.ready(request: request(65), connected: true, at: 216))
            }
            queue.enqueue(command, at: 300)
            XCTAssertNil(queue.ready(request: request(65), connected: true, at: 315), "Expiry precedes dispatch on reconnect")
        }
    }

    func testSoulOutboxCopiesEachFactOnceAndRetriesAnInterruptedDurableWrite() throws {
        let run = UUID(), otherRun = UUID()
        let catchEvent = BoundSoulSharedEvent(run: run, kind: .acquired, slot: "area:1")
        let death = BoundSoulSharedEvent(run: run, kind: .death, slot: "area:1")
        let foreign = BoundSoulSharedEvent(run: otherRun, kind: .death, slot: "area:1")
        var cache = BoundROMSoulExportCache(), persisted: [String] = []
        XCTAssertThrowsError(try cache.export([catchEvent, death], run: run) { id, _ in
            if id == death.id { throw CocoaError(.fileWriteUnknown) }
            persisted.append(id)
        })
        XCTAssertEqual(persisted, [catchEvent.id])
        try cache.export([catchEvent, death, foreign], run: run) { id, _ in persisted.append(id) }
        XCTAssertEqual(persisted, [catchEvent.id, death.id], "Only the failed write retries; a different run cannot enter this outbox")
        for _ in 0..<100 {
            try cache.export([catchEvent, death], run: run) { _, _ in XCTFail("Unchanged gameplay ticks must perform no outbox I/O") }
        }
        cache.reset()
        try cache.export([catchEvent, death], run: run) { id, _ in persisted.append(id) }
        XCTAssertEqual(persisted.count, 4, "Reopening or replacing storage revalidates every durable fact")
        try cache.export([foreign], run: otherRun) { id, _ in persisted.append(id) }
        XCTAssertEqual(persisted.last, foreign.id)
    }

    func testNativePairSelectionCarriesItsOwnNewGameAuthorizationAfterHostRestart() {
        func request(_ command: BoundROMCommand, flags: UInt32) -> BoundROMRequest {
            .init(sequence: 2, command: command, friendIndex: 0, argument: 0, identifier: UUID(),
                  settings: Data(repeating: 0, count: 32), flags: flags, frame: 200, requestID: 8)
        }
        XCTAssertTrue(request(.pair, flags: 2 | 4).requestsNewMultiplayerRun)
        XCTAssertTrue(request(.startSoulLink, flags: 2 | 4).requestsNewMultiplayerRun)
        XCTAssertFalse(request(.pair, flags: 1).requestsNewMultiplayerRun, "An existing game cannot become a new run")
        XCTAssertFalse(request(.newGameReady, flags: 2).requestsNewMultiplayerRun, "An intro alone cannot select a friend")
        XCTAssertFalse(request(.battle, flags: 2).requestsNewMultiplayerRun)
    }

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

    @MainActor
    func testSharedRivalNameRequiresVersionFourCanonicalNativeNameAndReservedZeros() {
        var settings = Data(repeating: 0, count: 32)
        settings[0] = 4
        settings.replaceSubrange(12..<20, with: [0xBC, 0xC6, 0xCF, 0xBF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertTrue(BoundROMMultiplayerCoordinator.validSettings(settings))
        for version in UInt8(1)...3 {
            settings[0] = version
            XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings))
        }
        settings[0] = 4
        for invalid in UInt8(0xF7)...0xFE {
            settings[12] = invalid
            XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings), "Native control codes cannot enter a shared name")
        }
        settings[12] = 0xBC
        settings[17] = 0
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings), "Padding after the terminator must be canonical")
        settings[17] = 0xFF
        for debug in [UInt8(0), 1] {
            settings[20] = debug
            XCTAssertTrue(BoundROMMultiplayerCoordinator.validSettings(settings), "Version four carries the shared debug-start choice")
        }
        settings[20] = 2
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings))
        settings[20] = 0
        for reserved in 21..<32 {
            settings[reserved] = 1
            XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings))
            settings[reserved] = 0
        }
        settings.replaceSubrange(12..<20, with: repeatElement(UInt8(0xFF), count: 8))
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings), "The rival must have a name")
        settings.replaceSubrange(12..<20, with: repeatElement(UInt8(0xBB), count: 8))
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings), "Seven characters and a terminator is the maximum")
        settings[19] = 0xFF
        XCTAssertTrue(BoundROMMultiplayerCoordinator.validSettings(settings))
    }

    @MainActor
    func testDebugStartupChoiceRequiresVersionFourAndPreservesNativeOptions() {
        var settings = Data(repeating: 0, count: 32)
        settings[20] = 1
        for version in UInt8(1)...3 {
            settings[0] = version
            XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings), "Legacy records cannot silently opt into debug startup")
        }
        settings[0] = 4
        settings[1] = 1 // Minimal Grind, with native difficulty/randomizer defaults.
        settings[10] = 1 // The five custom cheats.
        settings[11] = 0 // Automatic Pokemon name-change behavior is disabled.
        settings.replaceSubrange(12..<20, with: [0xC1, 0xD5, 0xE6, 0xED, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertTrue(BoundROMMultiplayerCoordinator.validSettings(settings))
        settings[1] = 2
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings), "Debug startup still validates native option bits")
        settings[1] = 1; settings[21] = 1
        XCTAssertFalse(BoundROMMultiplayerCoordinator.validSettings(settings), "Debug does not relax unused-byte validation")
    }

    @MainActor
    private func setupFixture() -> BoundROMMultiplayerCoordinator.Setup {
        let owner = UUID(), partner = UUID()
        var options = Data(repeating: 0, count: 32)
        options[0] = 4; options[1] = 1; options[10] = 1; options[20] = 1
        options.replaceSubrange(12..<20, with: [0xC1, 0xD5, 0xE6, 0xED, 0xFF, 0xFF, 0xFF, 0xFF])
        return .init(identity: .init(run: UUID(), gameID: "local-game", owner: owner, partner: partner,
            roomID: UUID().uuidString, settingsOwner: owner, settings: options, localSeed: 17, partnerSeed: 29,
            romSHA256: String(repeating: "a", count: 64)), accepted: true, settingsCommitted: true,
            peerReady: false, serverEpoch: 1, serverCommitted: false)
    }

    @MainActor
    func testDelayedSetupPollCannotEraseChoicesSubmittedWhileItWasInFlight() throws {
        let submitted = setupFixture()
        var stalePoll = submitted.identity; stalePoll.settings = Data()
        let merged = try BoundROMMultiplayerCoordinator.mergingSetup(submitted, remote: stalePoll, epoch: 1, committed: false)
        XCTAssertEqual(merged.identity.settings, submitted.identity.settings)
        XCTAssertTrue(merged.settingsCommitted)
        XCTAssertFalse(merged.serverCommitted ?? true)
        let committed = try BoundROMMultiplayerCoordinator.mergingSetup(merged, remote: merged.identity, epoch: 1, committed: true)
        XCTAssertTrue(committed.serverCommitted == true)
        XCTAssertFalse(committed.peerReady, "Committing a configuration requires no peer-start receipt")
        XCTAssertEqual(committed.identity.localSeed, 17)
        XCTAssertEqual(committed.identity.partnerSeed, 29)
    }
    @MainActor
    func testDelayedSetupPollPreservesPartialOwnerDraftWithoutCommittingIt() throws {
        var draft = setupFixture()
        draft.settingsCommitted = false
        draft.identity.settings[10] = 0
        var stalePoll = draft.identity; stalePoll.settings = Data()
        let merged = try BoundROMMultiplayerCoordinator.mergingSetup(draft, remote: stalePoll, epoch: 1, committed: false)
        XCTAssertEqual(merged.identity.settings, draft.identity.settings)
        XCTAssertFalse(merged.settingsCommitted, "Preserving the owner's draft cannot commit choices not yet submitted")
        XCTAssertFalse(merged.serverCommitted ?? true)
        XCTAssertEqual(merged.serverDraftDigest, BoundMultiplayerSaveStore.hash(stalePoll.settings),
            "The next background draft update can distinguish these unsent choices from the delayed server response")
    }

    @MainActor
    func testTakeoverDiscardsFormerChooserDraftAndFencesDelayedResponses() throws {
        let initial = setupFixture()
        var takeover = initial.identity
        takeover.settingsOwner = initial.identity.partner; takeover.settings = Data()
        XCTAssertThrowsError(try BoundROMMultiplayerCoordinator.mergingSetup(initial, remote: takeover, epoch: 1, committed: false),
            "Ownership cannot change without a new server fence")
        let changed = try BoundROMMultiplayerCoordinator.mergingSetup(initial, remote: takeover, epoch: 2, committed: false)
        XCTAssertEqual(changed.identity.settingsOwner, initial.identity.partner)
        XCTAssertTrue(changed.identity.settings.isEmpty)
        XCTAssertFalse(changed.settingsCommitted)
        XCTAssertEqual(changed.serverEpoch, 2)
        XCTAssertThrowsError(try BoundROMMultiplayerCoordinator.mergingSetup(changed, remote: initial.identity, epoch: 1, committed: true),
            "The previous chooser's delayed commit cannot replace the new fence")
        XCTAssertEqual(changed.identity.localSeed, initial.identity.localSeed)
        XCTAssertEqual(changed.identity.partnerSeed, initial.identity.partnerSeed)
    }

    @MainActor
    func testCommittedSetupIsImmutableAndPartnerCanRetrieveItWithoutStartReceipt() throws {
        var local = setupFixture()
        local.identity.settingsOwner = local.identity.partner
        local.settingsCommitted = false
        var complete = local.identity
        complete.settings = setupFixture().identity.settings
        local.identity.settings = Data()
        let retrieved = try BoundROMMultiplayerCoordinator.mergingSetup(local, remote: complete, epoch: 1, committed: true)
        XCTAssertTrue(retrieved.settingsCommitted)
        XCTAssertTrue(retrieved.serverCommitted == true)
        XCTAssertFalse(retrieved.peerReady)
        XCTAssertEqual(try BoundROMMultiplayerCoordinator.mergingSetup(retrieved, remote: complete, epoch: 1, committed: true).identity, complete,
            "Retrieving the same committed configuration is harmless")
        var changed = complete; changed.settings[10] = 0
        XCTAssertThrowsError(try BoundROMMultiplayerCoordinator.mergingSetup(retrieved, remote: changed, epoch: 1, committed: true))
        XCTAssertThrowsError(try BoundROMMultiplayerCoordinator.mergingSetup(retrieved, remote: complete, epoch: 1, committed: false))
        changed = complete; changed.localSeed += 1
        XCTAssertThrowsError(try BoundROMMultiplayerCoordinator.mergingSetup(retrieved, remote: changed, epoch: 1, committed: true))
    }

    @MainActor
    func testSetupCancellationSurvivesOfflineReopenAndDoesNotBlockFreshRunWithSameFriend() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        let identity = setupFixture().identity
        var queue = BoundROMSetupCancellationQueue()
        try queue.enqueue(identity: identity, epoch: 0) // First setup RPC has not replied.
        try BoundROMMultiplayerCoordinator.persistSetupCancellations(queue, at: file)
        var reopened = try BoundROMMultiplayerCoordinator.loadSetupCancellations(at: file)
        XCTAssertEqual(reopened.pending(owner: identity.owner)?.identity, identity)
        XCTAssertEqual(reopened.pending(owner: identity.owner)?.epoch, 0)
        XCTAssertNil(reopened.pending(owner: identity.partner), "Only the original account may send a pending cancellation")
        // A failed HTTP request does not remove the persisted retry.
        XCTAssertEqual(try BoundROMMultiplayerCoordinator.loadSetupCancellations(at: file), reopened)
        try reopened.enqueue(identity: identity, epoch: 3)
        XCTAssertEqual(reopened.entries.count, 1, "Retransmission preserves the original cancellation intent")
        try reopened.resolve(identity.run, alreadyStarted: false)
        try BoundROMMultiplayerCoordinator.persistSetupCancellations(reopened, at: file)
        reopened = try BoundROMMultiplayerCoordinator.loadSetupCancellations(at: file)
        XCTAssertNil(reopened.pending(owner: identity.owner))
        XCTAssertTrue(reopened.contains(identity.run), "A late Hello or proposal remains fenced after server acknowledgement")
        var fresh = identity; fresh.run = UUID()
        XCTAssertFalse(reopened.contains(fresh.run), "Selecting the same friend again may create a new run")
        try reopened.enqueue(identity: fresh, epoch: 1)
        XCTAssertEqual(reopened.pending(owner: identity.owner)?.identity.run, fresh.run)
    }

    @MainActor
    func testSetupCancellationCommitRaceRetiresRetryWithoutRemovingTombstoneOrOtherIntents() throws {
        let identity = setupFixture().identity
        var other = identity; other.run = UUID(); other.roomID = UUID().uuidString
        var queue = BoundROMSetupCancellationQueue()
        try queue.enqueue(identity: identity, epoch: 1)
        try queue.enqueue(identity: other, epoch: 2)
        try queue.resolve(identity.run, alreadyStarted: true)
        XCTAssertEqual(queue.entries.first?.alreadyStarted, true, "A server commit cannot be rolled back by cancellation")
        XCTAssertTrue(queue.contains(identity.run))
        XCTAssertEqual(queue.pending(owner: identity.owner)?.identity, other)
        try queue.resolve(identity.run, alreadyStarted: false)
        XCTAssertEqual(queue.entries.first?.alreadyStarted, true, "An older response cannot erase the committed outcome")
        var conflict = identity; conflict.partnerSeed += 1
        XCTAssertThrowsError(try queue.enqueue(identity: conflict, epoch: 1))
        XCTAssertThrowsError(try queue.resolve(UUID(), alreadyStarted: false))
        XCTAssertEqual(try JSONDecoder().decode(BoundROMSetupCancellationQueue.self, from: JSONEncoder().encode(queue)), queue)
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
    func testBattleOrDialoguePauseCannotBeMistakenForCheckpointReadiness() {
        for (localSafe, peerSafe) in [(false, true), (true, false), (false, false)] {
            XCTAssertEqual(BoundROMCheckpointReadiness.stage(localStored: false, partnerStored: false,
                peerCommitted: false, localPaused: true, peerPaused: true, peerPendingMatches: true,
                historyMatches: true, fresh: true, localSafe: localSafe, peerSafe: peerSafe), .wait,
                "A generic pause screen is insufficient: both cartridges must freeze a native safe field frame")
        }
        XCTAssertEqual(BoundROMCheckpointReadiness.stage(localStored: true, partnerStored: true,
            peerCommitted: true, localPaused: true, peerPaused: false, peerPendingMatches: false,
            historyMatches: false, fresh: true, localSafe: false, peerSafe: false), .finish,
            "An already durable commit must remain recoverable without recapturing a changed field")
    }

    func testLateRivalBattleCancelsBeforeEitherPlayerPrepares() {
        var waitingPlayer = BoundROMCheckpointCancellation()
        let battlingPlayer = BoundROMCheckpointCancellation()
        XCTAssertEqual(waitingPlayer.action(at: 1, startedAt: 0, localSafe: true, peerSafe: false, durable: false), .request)
        XCTAssertEqual(waitingPlayer.request(at: 1, durable: false), .request)
        XCTAssertEqual(waitingPlayer.action(at: 2, startedAt: 0, localSafe: true, peerSafe: true, durable: false), .wait,
            "A later safe heartbeat cannot restart capture after cancellation has been sent")
        XCTAssertEqual(battlingPlayer.receive(acknowledgement: false, durable: false), .acknowledge,
            "The battling player can promise no prepared save and release its request")
        XCTAssertEqual(waitingPlayer.receive(acknowledgement: true, durable: false), .finish)
    }

    func testCheckpointCancellationRequiresAcknowledgementAndHandlesCrossedRequests() {
        var first = BoundROMCheckpointCancellation(), second = BoundROMCheckpointCancellation()
        XCTAssertEqual(first.receive(acknowledgement: true, durable: false), .wait,
            "An unsolicited acknowledgement cannot end an active checkpoint")
        XCTAssertEqual(first.request(at: 10, durable: false), .request)
        XCTAssertEqual(second.request(at: 10, durable: false), .request)
        XCTAssertEqual(first.receive(acknowledgement: false, durable: false), .acknowledge)
        XCTAssertEqual(second.receive(acknowledgement: false, durable: false), .acknowledge)
        XCTAssertEqual(first.receive(acknowledgement: true, durable: false), .finish)
        XCTAssertEqual(second.receive(acknowledgement: true, durable: false), .finish)
    }

    func testCheckpointCancellationNeverDiscardsAPreparedOrCommittedReceipt() {
        var cancellation = BoundROMCheckpointCancellation()
        XCTAssertEqual(cancellation.request(at: 1, durable: true), .recover)
        XCTAssertNil(cancellation.requestedAt, "A durable transaction never enters the cancellable state")
        XCTAssertEqual(cancellation.request(at: 2, durable: false), .request)
        XCTAssertEqual(cancellation.receive(acknowledgement: false, durable: true), .recover)
        XCTAssertEqual(cancellation.receive(acknowledgement: true, durable: true), .recover,
            "A peer's cancellation acknowledgement cannot roll back bytes prepared while it was in flight")
        XCTAssertEqual(cancellation.action(at: 3, startedAt: 0, localSafe: true, peerSafe: true, durable: true), .recover)
    }

    func testUnresponsiveCheckpointIsBoundedWithoutTreatingTimeoutAsConsent() {
        var cancellation = BoundROMCheckpointCancellation()
        XCTAssertEqual(cancellation.action(at: 7.9, startedAt: 0, localSafe: true, peerSafe: nil, durable: false), .wait)
        XCTAssertEqual(cancellation.action(at: 8, startedAt: 0, localSafe: true, peerSafe: nil, durable: false), .request)
        XCTAssertEqual(cancellation.request(at: 8, durable: false), .request)
        XCTAssertEqual(cancellation.request(at: 12, durable: false), .request)
        XCTAssertEqual(cancellation.requestedAt, 8, "Retransmission cannot extend the deadline")
        XCTAssertEqual(cancellation.action(at: 16, startedAt: 0, localSafe: true, peerSafe: nil, durable: false), .recover,
            "A missing abort acknowledgement preserves the pause instead of resuming a possibly prepared peer")
        let prepared = BoundROMCheckpointCancellation()
        XCTAssertEqual(prepared.action(at: 30, startedAt: 0, localSafe: false, peerSafe: false, durable: true), .recover,
            "Prepared bytes are retained and the indefinite saving message becomes explicit recovery")
    }

    func testCheckpointSafeFlagIsSeparateFromGenericPauseAndFieldFlags() throws {
        var bytes = Data(repeating: 0, count: 256)
        bytes.replaceSubrange(0..<8, with: [82, 85, 82, 49, 1, 0, 0, 0])
        word(2, 8, &bytes); word(5, 80, &bytes)
        let old = try XCTUnwrap(BoundROMRequest.decode(bytes))
        XCTAssertTrue(old.safeField); XCTAssertTrue(old.paused); XCTAssertFalse(old.checkpointSafe)
        word(69, 80, &bytes)
        XCTAssertTrue(try XCTUnwrap(BoundROMRequest.decode(bytes)).checkpointSafe)
        XCTAssertEqual(BoundROMPacket.Kind.cancel.rawValue, 9, "Existing packet kinds keep their wire values")
        XCTAssertEqual(BoundROMPacket.Kind.checkpointCancel.rawValue, 10)
    }

    func testAutomaticFieldSaveWaitsForDialogueAndMenusToFinish() throws {
        var bytes = Data(repeating: 0, count: 256)
        bytes.replaceSubrange(0..<8, with: [82, 85, 82, 49, 1, 0, 0, 0])
        word(2, 8, &bytes)
        // Native item text retains the field callbacks, but its script owns
        // input until the final receipt and warning have been dismissed.
        for flags: UInt32 in [0, 1, 33, 64, 65 | 4, 65 | 2] {
            word(flags, 80, &bytes)
            XCTAssertFalse(try XCTUnwrap(BoundROMRequest.decode(bytes)).permitsAutomaticFieldSave, "flags: \(flags)")
        }
        for flags: UInt32 in [65, 65 | 32] {
            word(flags, 80, &bytes)
            XCTAssertTrue(try XCTUnwrap(BoundROMRequest.decode(bytes)).permitsAutomaticFieldSave)
        }
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
    func testNativeSetupRecoveryCommandsAndDebugChoiceKeepTheirWireOffsets() throws {
        XCTAssertEqual(BoundROMCommand.setupTakeover.rawValue, 28)
        XCTAssertEqual(BoundROMCommand.setupRetry.rawValue, 29)
        var bytes = Data(repeating: 0, count: 256)
        bytes.replaceSubrange(0..<8, with: [82,85,82,49,1,0,0,0])
        word(2, 8, &bytes); word(28, 12, &bytes); word(6, 80, &bytes); word(1, 160, &bytes)
        let takeover = try XCTUnwrap(BoundROMRequest.decode(bytes))
        XCTAssertEqual(takeover.command, .setupTakeover)
        XCTAssertTrue(takeover.debugSetup)
        XCTAssertTrue(takeover.newGame)
        XCTAssertFalse(takeover.requestsNewMultiplayerRun, "Taking over a draft cannot create a second run")
        word(29, 12, &bytes); word(0, 160, &bytes)
        let retry = try XCTUnwrap(BoundROMRequest.decode(bytes))
        XCTAssertEqual(retry.command, .setupRetry)
        XCTAssertFalse(retry.debugSetup)
        XCTAssertFalse(retry.requestsPregameSetupRestart)
        word(1, 164, &bytes)
        XCTAssertTrue(try XCTUnwrap(BoundROMRequest.decode(bytes)).requestsPregameSetupRestart)
        word(38, 80, &bytes)
        XCTAssertFalse(try XCTUnwrap(BoundROMRequest.decode(bytes)).requestsPregameSetupRestart,
            "Retry cannot restart a cartridge that has already applied its setup")
        word(1, 80, &bytes)
        XCTAssertFalse(try XCTUnwrap(BoundROMRequest.decode(bytes)).requestsPregameSetupRestart,
            "An ordinary field error cannot authorize a new-game restart")
        var host = BoundROMHostState()
        host.restartSetup = true
        XCTAssertEqual(uint32(host.encoded(sequence: 2), 12), 2048)
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
