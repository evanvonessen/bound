import XCTest
import UIKit
import DeltaCore
import GBADeltaCore
@testable import Delta

private struct FriendDialogueGame: GameProtocol {
    let fileURL: URL
    let gameSaveURL: URL
    var type: GameType { .gba }
}

private final class NativeInvitationFrameCounter: @unchecked Sendable {
    private let lock=NSLock()
    private var value: UInt32?
    func observe(_ frame: UInt32?) { lock.lock(); value=frame; lock.unlock() }
    func read() -> UInt32? { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class FriendInteractionTests: XCTestCase {
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

    typealias Session = BoundFriendInteractionSession
    typealias Packet = BoundFriendInteractionPacket
    private func position(_ x: Int, _ y: Int, facing: Int = 4, map: Int = 3, elevation: Int = 0) -> BoundFriendWorldPosition {
        let json: [String: Int] = ["mapGroup": 4, "mapNumber": map, "elevation": elevation, "x": x, "y": y, "facing": facing]
        return try! JSONDecoder().decode(BoundFriendWorldPosition.self, from: JSONSerialization.data(withJSONObject: json))
    }
    @MainActor private final class Peers {
        let a = Session(), b = Session()
        var aID = UUID(), bID = UUID()
        var left: BoundFriendWorldPosition, right: BoundFriendWorldPosition
        var aPackets: [Data] = [], bPackets: [Data] = []
        var online = true
        init(left: BoundFriendWorldPosition, right: BoundFriendWorldPosition) {
            self.left = left; self.right = right
            a.context = { [unowned self] in online ? .init(localSession: aID, peerSession: bID, local: self.left, peer: self.right) : nil }
            b.context = { [unowned self] in online ? .init(localSession: bID, peerSession: aID, local: self.right, peer: self.left) : nil }
            a.start { [unowned self] in aPackets.append($0); return true }
            b.start { [unowned self] in bPackets.append($0); return true }
        }
        func deliver(at now: Double = 10) {
            let fromA = aPackets, fromB = bPackets; aPackets.removeAll(); bPackets.removeAll()
            fromA.forEach { b.receive($0, at: now) }; fromB.forEach { a.receive($0, at: now) }
        }
    }
    private func peers() -> Peers { Peers(left: position(6, 8), right: position(7, 8, facing: 3)) }

    func testExactCardinalTileFacingAndMapElevationAdmission() {
        let origin = position(6, 8)
        XCTAssertTrue(origin.isFacing(position(7, 8)))
        for target in [position(6, 8), position(7, 9), position(8, 8), position(5, 8), position(7, 8, map: 4), position(7, 8, elevation: 1)] {
            XCTAssertFalse(origin.isFacing(target))
        }
        for (facing, x, y) in [(1,6,9),(2,6,7),(3,5,8),(4,7,8)] {
            XCTAssertTrue(position(6,8,facing:facing).isFacing(position(x,y)))
        }
        let p = peers(); XCTAssertTrue(p.a.canInteract)
        p.left = position(6,8,facing:1); XCTAssertFalse(p.a.open(at:10))
        p.left = position(6,8); p.a.canPresent = { false }; XCTAssertFalse(p.a.open(at:10))
    }
    func testBothActivitiesRequirePeerConsentAndConfirmationExactlyOnce() throws {
        for activity in Packet.Activity.allCases {
            let p = peers(); var agreements = [String]()
            p.a.agreed = { kind, _, initiator in XCTAssertEqual(kind, activity); XCTAssertTrue(initiator); agreements.append("A") }
            p.b.agreed = { kind, _, initiator in XCTAssertEqual(kind, activity); XCTAssertFalse(initiator); agreements.append("B") }
            XCTAssertTrue(p.a.open(at:10)); p.a.request(activity, at:10)
            let request = try XCTUnwrap(p.aPackets.first)
            p.deliver(); XCTAssertEqual(p.b.phase, .incoming); XCTAssertTrue(agreements.isEmpty)
            p.b.receive(request,at:10.1); XCTAssertTrue(p.bPackets.isEmpty, "Duplicates must not decline the original request")
            p.b.accept(at:10.2); XCTAssertEqual(p.b.phase, .confirming); XCTAssertTrue(agreements.isEmpty)
            p.deliver(at:10.3); XCTAssertEqual(p.a.phase, .agreed); XCTAssertEqual(p.b.phase, .confirming)
            let confirmation = try XCTUnwrap(p.aPackets.first)
            p.deliver(at:10.4); XCTAssertEqual(p.b.phase, .agreed); XCTAssertEqual(agreements,["A","B"])
            p.b.receive(confirmation,at:10.5); XCTAssertEqual(agreements.count,2)
            p.a.cancel(); p.b.cancel(); p.b.receive(request,at:11)
            XCTAssertEqual(p.a.phase,.idle); XCTAssertEqual(p.b.phase,.idle)
        }
    }
    func testNativeSnapshotPoseGapCannotDropAnAlreadyAcceptedConfirmation() {
        let p=peers();var launches=[String]()
        p.a.agreed={ _,_,_ in launches.append("A") }
        p.b.agreed={ _,_,_ in launches.append("B") }
        p.a.open(at:10);p.a.request(.trade,at:10);p.deliver()
        p.b.accept(at:10.1);p.deliver(at:10.2)
        XCTAssertEqual(p.a.phase,.agreed);XCTAssertEqual(p.b.phase,.confirming)
        p.online=false // Native snapshot briefly withholds pose, not the channel.
        p.a.tick(at:10.3);p.b.tick(at:10.3)
        XCTAssertEqual(p.a.phase,.agreed);XCTAssertEqual(p.b.phase,.confirming)
        p.deliver(at:10.4)
        XCTAssertEqual(p.b.phase,.agreed);XCTAssertEqual(launches,["A","B"])
        p.a.stop();p.b.stop()
        XCTAssertEqual(p.a.phase,.ended);XCTAssertEqual(p.b.phase,.ended)
    }
    func testDeclineCancelAndCrossedInvitationsCannotLaunchActivity() {
        let p = peers(); var launched = false
        p.a.agreed = { _,_,_ in launched = true }; p.b.agreed = { _,_,_ in launched = true }
        p.a.open(at:10); p.a.request(.trade,at:10); p.deliver(); p.b.decline(); p.deliver()
        XCTAssertEqual(p.a.message,"Your friend declined the request"); XCTAssertEqual(p.b.phase,.idle)
        p.a.cancel(); p.a.open(at:20); p.a.request(.battle,at:20); p.deliver(at:20)
        p.a.cancel(); p.deliver(at:20); XCTAssertEqual(p.b.phase,.ended)
        p.b.cancel(); p.a.open(at:30); p.a.request(.trade,at:30); p.a.tick(at:61)
        XCTAssertEqual(p.a.phase,.ended, "Unadmitted requests expire"); XCTAssertEqual(p.a.message,"Invitation expired"); p.a.cancel()
        p.aPackets.removeAll(); p.bPackets.removeAll()
        p.a.open(at:70); p.b.open(at:70); p.a.request(.battle,at:70); p.b.request(.trade,at:70)
        p.deliver(at:70); p.deliver(at:70)
        XCTAssertEqual(p.a.phase,.ended); XCTAssertEqual(p.b.phase,.ended); XCTAssertFalse(launched)
    }
    func testMovementInvalidatesAdmissionButMissingPresenceKeepsInvitation() {
        let p = peers()
        p.a.open(at:10); p.a.request(.battle,at:10); p.deliver()
        p.right = position(8,8,facing:3); p.b.accept(at:10.1); p.a.tick(at:10.1)
        XCTAssertEqual(p.a.phase,.ended); XCTAssertTrue(p.bPackets.isEmpty)
        p.a.cancel(); p.b.cancel(); p.right = position(7,8,facing:3)
        p.a.open(at:20); p.a.request(.trade,at:20); p.deliver(at:20)
        p.online = false; p.a.tick(at:20.1); XCTAssertEqual(p.a.phase,.outgoing)
        p.online = true; p.a.cancel(); p.a.refreshInputGate()
        XCTAssertEqual(BoundFriendWorldInput(input:p.a.inputGate.filter(GBAGameInput.a)), .interact)
        p.a.stop()
        XCTAssertEqual(p.a.inputGate.filter(GBAGameInput.a).type,.game(.gba), "Stopping must release the gate even while idle")
        XCTAssertFalse(p.a.canInteract)
    }
    func testQueuedPromptLeavesUnderlyingNativeDialogueInputAvailable() {
        let p = peers()
        XCTAssertTrue(p.a.open(at: 10))
        p.a.nativeDialogueManaged = true; p.a.nativeDialogueBusy = true
        var reading = BoundFriendDialogueProbe.Reading()
        p.a.nativeDialogueInput = reading.permitsNativeInput(pending: true, acknowledgingEnd: false)
        p.a.refreshInputGate()
        XCTAssertEqual(p.a.inputGate.filter(GBAGameInput.a).type, .game(.gba), "A must finish the original dialogue while multiplayer entry waits")
        XCTAssertEqual(p.a.inputGate.filter(GBAGameInput.b).type, .game(.gba))
        reading.active = true
        p.a.nativeDialogueInput = reading.permitsNativeInput(pending: true, acknowledgingEnd: false)
        p.a.refreshInputGate()
        XCTAssertEqual(BoundFriendWorldInput(input: p.a.inputGate.filter(GBAGameInput.a)), .blockedA, "A newly opening multiplayer prompt keeps its normal first-button protection")
        reading.menuReady = true
        p.a.nativeDialogueInput = reading.permitsNativeInput(pending: true, acknowledgingEnd: false)
        p.a.refreshInputGate()
        XCTAssertEqual(p.a.inputGate.filter(GBAGameInput.a).type, .game(.gba))
    }
    func testRepeatedJoinPreservesActiveTradeConsentAndControls() {
        let p=peers()
        p.a.open(at:10); p.a.request(.trade,at:10)
        p.a.activityProgress("Trade",playing:true)
        p.a.start(send:{ _ in true })
        XCTAssertEqual(p.a.phase,.playing)
        XCTAssertEqual(p.a.activity,.trade)
        XCTAssertEqual(p.a.message,"Trade")
        XCTAssertFalse(p.a.blocksGameplay)
    }

    func testActiveBattleAndTradeConsentSurviveRepeatedTransportLossUntilExplicitCancel() {
        for activity in [Packet.Activity.battle,.trade] {
            let p=peers()
            XCTAssertTrue(p.a.open(at:10)); p.a.request(activity,at:10)
            let consent=p.a.requestID
            p.a.activityProgress(activity.title,playing:true)
            var cancellations=0
            p.a.cancelActivity={ [weak a=p.a] in
                cancellations+=1; a?.activityEnded("Ended by player")
            }
            for epoch in 1...3 {
                p.online=false; p.a.suspend()
                p.a.tick(at:Double(epoch)*3600)
                XCTAssertEqual(p.a.phase,.playing)
                XCTAssertEqual(p.a.requestID,consent)
                XCTAssertEqual(p.a.activity,activity)
                XCTAssertFalse(p.a.requiresResultAcknowledgement)
                XCTAssertEqual(cancellations,0)
                p.online=true; p.aID=UUID(); p.bID=UUID()
                p.a.start(send:{ _ in true })
                XCTAssertEqual(p.a.phase,.playing)
                XCTAssertEqual(p.a.requestID,consent)
            }
            p.online=false; p.a.suspend(); p.a.cancel()
            XCTAssertEqual(cancellations,1)
            XCTAssertEqual(p.a.phase,.ended)
            XCTAssertTrue(p.a.requiresResultAcknowledgement)
        }
    }

    func testRecoveryResultSurvivesDisconnectAndReconnectUntilAcknowledged() {
        let p = peers()
        p.a.open(at:10); p.a.request(.trade,at:10)
        let recovery = "Trade interrupted. Continue from your in-game save."
        p.a.activityEnded(recovery)
        p.a.stop()
        XCTAssertEqual(p.a.phase,.ended)
        XCTAssertEqual(p.a.message,recovery)
        XCTAssertFalse(p.a.blocksGameplay, "An interrupted transaction's retained result cannot block ordinary controls")
        p.a.start(send:{ _ in true })
        XCTAssertEqual(p.a.message,recovery)
        XCTAssertFalse(p.a.canInteract)
        p.a.cancel()
        XCTAssertEqual(p.a.phase,.idle)
        XCTAssertTrue(p.a.canInteract)
    }

    func testWrongSessionWrongCoordinatesAndOldInvitationsAreRejected() throws {
        let p = peers(); p.a.open(at:10); p.a.request(.trade,at:10)
        let request = try XCTUnwrap(Packet.decode(try XCTUnwrap(p.aPackets.first)))
        let wrong = Packet(sender:UUID(),receiver:p.bID,id:request.id,activity:.trade,action:.request,origin:request.origin,target:request.target)
        p.b.receive(try XCTUnwrap(wrong.encoded()),at:10); XCTAssertEqual(p.b.phase,.idle)
        p.bPackets.removeAll(); p.right = position(8,8,facing:3); p.deliver(); XCTAssertEqual(p.b.phase,.idle)
        p.right = position(7,8,facing:3); p.a.cancel(); p.aPackets.removeAll()
        p.a.open(at:11); p.a.request(.trade,at:11); p.deliver(at:11); p.b.decline(); p.deliver(at:11)
        XCTAssertEqual(p.a.phase,.ended)
        XCTAssertNil(Packet.decode(Data(repeating:0,count:1025))); XCTAssertNil(Packet.decode(Data("{}".utf8)))
    }
    func testInputGateCapturesOnlyAAndPreservesMenuShortcutsAndOtherGames() {
        let gate = BoundFriendWorldInputGate()
        gate.update(available:true,blocked:false)
        XCTAssertEqual(BoundFriendWorldInput(input:gate.filter(GBAGameInput.a)),.interact)
        XCTAssertEqual(BoundFriendWorldInput(input:gate.filter(StandardGameControllerInput.a)),.interact)
        XCTAssertEqual(AnyInput(gate.filter(GBAGameInput.b)),AnyInput(GBAGameInput.b))
        gate.update(available:false,blocked:true)
        XCTAssertEqual(BoundFriendWorldInput(input:gate.filter(GBAGameInput.a)),.blockedA)
        XCTAssertEqual(BoundFriendWorldInput(input:gate.filter(GBAGameInput.up)),.blocked)
        XCTAssertEqual(AnyInput(gate.filter(StandardGameControllerInput.menu)),AnyInput(StandardGameControllerInput.menu))
        XCTAssertEqual(ActionInput(input:gate.filter(ActionInput.quickSave)),.quickSave)
        gate.update(available:false,blocked:false)
        XCTAssertEqual(AnyInput(gate.filter(GBAGameInput.a)),AnyInput(GBAGameInput.a))
    }
    func testPhysicalControllerMappingSendsAppOnlyAToBothReceivers() throws {
        var base = DeltaCore.GameControllerInputMapping(gameControllerInputType: .mfi)
        base.set(GBAGameInput.a,forControllerInput:MFiGameController.Input.a)
        base.set(GBAGameInput.b,forControllerInput:MFiGameController.Input.b)
        let gate = BoundFriendWorldInputGate()
        let appMapping = BoundControllerInputMapping(base:base,friendWorldGate:gate)
        let coreMapping = BoundControllerInputMapping(base:base,friendWorldGate:gate)
        gate.update(available:true,blocked:false)
        for mapping in [appMapping,coreMapping] {
            XCTAssertEqual(BoundFriendWorldInput(input:try XCTUnwrap(mapping.input(forControllerInput:MFiGameController.Input.a))),.interact)
            XCTAssertEqual(AnyInput(try XCTUnwrap(mapping.input(forControllerInput:MFiGameController.Input.b))),AnyInput(GBAGameInput.b))
        }
        gate.update(available:false,blocked:false)
        XCTAssertEqual(AnyInput(try XCTUnwrap(coreMapping.input(forControllerInput:MFiGameController.Input.a))),AnyInput(GBAGameInput.a))
    }

    func testInvitationAttachmentDoesNotInterceptGameplayWithoutAPendingNotification() {
        let p=peers(), panel=BoundFriendInteractionPanel(session:peers().a)
        XCTAssertTrue(panel.isHidden)
        let active=BoundFriendInteractionPanel(session:p.a)
        p.a.changed={ active.render() }
        p.a.open(at:10)
        XCTAssertTrue(active.isHidden)
        XCTAssertNil(active.hitTest(CGPoint(x: 10, y: 100), with: nil))
        p.a.request(.trade,at:10); p.deliver()
        XCTAssertTrue(active.isHidden)
        XCTAssertNil(active.hitTest(CGPoint(x: 10, y: 100), with: nil))
    }
    func testAgreementWaitsForNativeWindowCleanupAndRejectsCancelledCompletion() {
        for cancel in [false,true] {
            let p=peers(); var ready:(()->Void)?, launches=0
            p.a.beforeAgreement={ ready=$0 }
            p.a.agreed={ _,_,_ in launches+=1 }
            p.a.open(at:10); p.a.request(.trade,at:10); p.deliver()
            p.b.accept(at:10); p.deliver()
            XCTAssertEqual(p.a.phase,.agreed); XCTAssertEqual(launches,0)
            if cancel { p.a.cancel() }
            ready?(); XCTAssertEqual(launches,cancel ? 0:1)
        }
    }
    func testReconnectKeepsConsentAndCancelledNativeCleanupCannotLaunch() {
        let p = peers(); var cleanup: (() -> Void)?, launched = false
        p.a.beforeAgreement = { cleanup = $0 }
        p.a.agreed = { _, _, _ in launched = true }
        p.a.open(at: 10); p.a.request(.trade, at: 10); p.deliver()
        p.b.accept(at: 10); p.deliver(at: 10)
        XCTAssertEqual(p.a.phase, .agreed)
        p.online = false
        p.a.suspend(); p.a.tick(at: 2000)
        XCTAssertEqual(p.a.phase, .agreed)
        XCTAssertTrue(p.a.blocksGameplay)
        cleanup?(); XCTAssertFalse(launched)
        p.a.start { _ in true }; p.a.tick(at: 2001)
        XCTAssertTrue(p.a.waitingForConnection)
        cleanup?(); XCTAssertFalse(launched, "A rejoined socket alone does not authorize native activity")
        p.online = true; p.a.tick(at: 2002)
        XCTAssertFalse(p.a.waitingForConnection)
        p.a.cancel(); cleanup?(); XCTAssertFalse(launched)
        XCTAssertTrue(p.a.canInteract)
    }

    func testPendingInvitationsReleaseGameplayAndExpireWithoutOpeningAMenu() throws {
        let p = peers()
        p.a.open(at: 10); p.a.request(.battle, at: 10)
        let original = try XCTUnwrap(p.aPackets.first)
        p.deliver()
        for session in [p.a, p.b] {
            XCTAssertFalse(session.blocksGameplay)
            XCTAssertFalse(session.menuPresented)
            XCTAssertEqual(AnyInput(session.inputGate.filter(GBAGameInput.up)), AnyInput(GBAGameInput.up))
        }
        XCTAssertTrue(p.b.open(at: 11)); XCTAssertTrue(p.b.blocksGameplay)
        p.b.decline(); p.deliver(at: 12)
        XCTAssertEqual(p.a.phase, .ended)
        XCTAssertFalse(p.a.requiresResultAcknowledgement)
        XCTAssertTrue(p.a.canInteract)
        p.a.cancel(); p.a.open(at: 20); p.a.request(.trade, at: 20); p.deliver(at: 20)
        p.a.suspend(); p.b.suspend(); p.online = false
        p.a.tick(at: 50); p.b.tick(at: 50)
        XCTAssertEqual(p.a.message, "Invitation expired"); XCTAssertEqual(p.b.message, "Invitation expired")
        XCTAssertFalse(p.a.blocksGameplay); XCTAssertFalse(p.b.blocksGameplay)
        p.online = true; p.a.start { p.aPackets.append($0); return true }; p.b.start { p.bPackets.append($0); return true }
        p.b.receive(original, at: 51)
        XCTAssertEqual(p.b.phase, .ended, "A retired request cannot revive after expiry/reconnect")
    }

    func testAdmissionRechecksOwnerRunAndEligibilityAfterNativeCleanup() {
        for changedScope in [false, true] {
            let p = peers(); var scope = "owner:room:run1", allowed = true
            var cleanup: (() -> Void)?, launched = false
            p.a.admissionIdentity = { scope }; p.a.canPresent = { allowed }
            p.a.beforeAgreement = { cleanup = $0 }; p.a.agreed = { _, _, _ in launched = true }
            p.a.open(at: 10); p.a.request(.trade, at: 10); p.deliver()
            p.b.accept(at: 11); p.deliver(at: 11)
            XCTAssertEqual(p.a.phase, .agreed)
            if changedScope { scope = "owner:room:run2" } else { allowed = false }
            cleanup?()
            XCTAssertFalse(launched); XCTAssertEqual(p.a.phase, .ended)
        }
    }

    func testRetiredRequestCapacityNeverEvictsACancellationOrDropsIntoUnboundedStorage() throws {
        let p = peers(); var original: Data?
        for index in 0..<Session.maximumRetiredRequests {
            XCTAssertTrue(p.a.open(at: Double(index)))
            p.a.request(.trade, at: Double(index))
            if index == 0 { original = p.aPackets.first }
            p.deliver(at: Double(index)); p.b.decline(); p.deliver(at: Double(index)); p.a.cancel()
        }
        XCTAssertFalse(p.a.open(at: 1000), "At capacity new requests fail closed")
        XCTAssertFalse(p.b.canInteract)
        p.b.receive(try XCTUnwrap(original), at: 1001)
        XCTAssertEqual(p.b.phase, .idle, "The first retired ID survives pressure")
    }

    func testChoosingMenuAndSelectedActivitySurviveMissingCoordinatesAndLongWait() {
        for activity in Packet.Activity.allCases {
            let p = peers()
            XCTAssertTrue(p.a.open(at: 10))
            p.online = false
            for time in [10.25, 40, 3600.0] { p.a.tick(at: time) }
            XCTAssertEqual(p.a.phase, .choosing)
            XCTAssertTrue(p.a.blocksGameplay)
            p.a.request(activity, at: 3601)
            XCTAssertEqual(p.a.phase, .outgoing)
            XCTAssertTrue(p.aPackets.isEmpty, "Selection waits for fresh verified positions")
            p.online = true; p.a.tick(at: 3602); p.deliver(at: 3602)
            XCTAssertEqual(p.b.phase, .incoming)
            p.a.stop(); p.deliver(at: 3603)
            XCTAssertEqual(p.a.phase, .ended); XCTAssertEqual(p.b.phase, .ended)
        }
    }

    func testFailedSendsAndLostConfirmationRetryWithoutChangingConsentOrDoubleLaunching() throws {
        for activity in Packet.Activity.allCases {
            let p = peers(); var launches = [String]()
            p.a.agreed = { _, _, _ in launches.append("A") }
            p.b.agreed = { _, _, _ in launches.append("B") }
            p.a.send = { _ in false }
            p.a.open(at: 10); p.a.request(activity, at: 10)
            let id = try XCTUnwrap(p.a.requestID)
            XCTAssertEqual(p.a.phase, .outgoing)
            p.a.send = { p.aPackets.append($0); return true }
            p.a.tick(at: 11); p.deliver(at: 11)
            XCTAssertEqual(p.b.requestID, id)
            p.b.send = { _ in false }; p.b.accept(at: 12)
            XCTAssertEqual(p.b.phase, .confirming)
            p.b.send = { p.bPackets.append($0); return true }
            p.b.tick(at: 13); p.deliver(at: 13)
            p.aPackets.removeAll() // Confirmation was accepted locally but lost in transit.
            p.a.tick(at: 14); p.deliver(at: 14)
            XCTAssertEqual(launches, ["A", "B"])
            p.b.tick(at: 15); p.a.tick(at: 15); p.deliver(at: 15)
            XCTAssertEqual(launches, ["A", "B"])
            p.a.peerPreparedActivity(); p.aPackets.removeAll(); p.a.tick(at: 100)
            XCTAssertTrue(p.aPackets.isEmpty)
            p.a.send = nil; p.b.send = nil
        }
    }

    func testIncomingConsentSurvivesTransportReconnectAndFreshPresenceEpochs() {
        for activity in Packet.Activity.allCases {
            let p = peers(); var launches = 0
            p.a.agreed = { _, _, _ in launches += 1 }; p.b.agreed = { _, _, _ in launches += 1 }
            p.a.open(at: 10); p.a.request(activity, at: 10); p.deliver()
            let id = p.a.requestID
            p.a.suspend(); p.b.suspend(); p.online = false
            p.b.accept(at: 11)
            p.a.tick(at: 20); p.b.tick(at: 20)
            XCTAssertEqual(p.a.phase, .outgoing); XCTAssertEqual(p.b.phase, .confirming)
            p.aID = UUID(); p.bID = UUID(); p.online = true
            p.a.start { p.aPackets.append($0); return true }; p.b.start { p.bPackets.append($0); return true }
            p.a.tick(at: 21); p.b.tick(at: 21); p.deliver(at: 21); p.deliver(at: 21)
            XCTAssertEqual(p.a.requestID, id); XCTAssertEqual(p.b.requestID, id)
            XCTAssertEqual(launches, 2)
            p.a.send = nil; p.b.send = nil
        }
    }

    func testLostCancelAndDeclineAreReplayedWithoutResurrectingInvitation() {
        for decline in [false, true] {
            let p = peers()
            p.a.open(at: 10); p.a.request(.trade, at: 10); p.deliver()
            p.b.send = { _ in false }
            if decline { p.b.decline() } else { p.b.cancel() }
            p.b.send = { p.bPackets.append($0); return true }
            p.a.tick(at: 11); p.deliver(at: 11); p.deliver(at: 11)
            XCTAssertEqual(p.a.phase, .ended); XCTAssertEqual(p.b.phase, .idle)
            XCTAssertEqual(p.a.message, decline ? "Your friend declined the request" : "Your friend cancelled the interaction")
            p.b.send = nil
        }
    }

    func testNativeInvitationWaitsReleaseAllMenuOwnershipAndKeepFramesRunning() async throws {
        continueAfterFailure = false
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MultiplayerValidation")
        let rom = root.appendingPathComponent("RadicalRed.gba")
        guard FileManager.default.fileExists(atPath: rom.path) else {
            throw XCTSkip("Install the private cartridge in the isolated QA simulator")
        }
        let battery = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sav")
        let core = try XCTUnwrap(EmulatorCore(game: FriendDialogueGame(fileURL: rom, gameSaveURL: battery), options: [.metal: true]))
        // The hosted app may still be connecting its first scene after model
        // tests finish. Yield to UIKit before creating the native fixture window.
        var connectedScene: UIWindowScene?
        for _ in 0..<100 {
            connectedScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            if connectedScene != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let scene = try XCTUnwrap(connectedScene)
        let oldWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), owner = UIViewController(), view = GameView()
        window.rootViewController = owner; window.makeKeyAndVisible(); owner.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 150, width: window.bounds.width, height: window.bounds.width * 2 / 3)
        core.add(view)
        let p = peers(), panel = BoundFriendInteractionPanel(session: p.a)
        panel.frame=owner.view.bounds; owner.view.addSubview(panel)
        panel.bind(core: core); p.a.changed = { panel.render() }
        let setup = NativePlayerSceneSetup(core: core), probe = panel.probe
        let frames = NativeInvitationFrameCounter()
        let booted = expectation(description: "Current cartridge New Game ready")
        var ready = false
        core.updateHandler = { core in
            setup.receive(core); probe.receive(core)
            frames.observe(BoundROMRequest.decode(BoundVBABattleBridge.romMultiplayerSnapshot())?.frame)
            if setup.isReady, !ready { ready = true; booted.fulfill() }
        }
        defer {
            p.a.send = nil
            p.a.changed = nil; panel.bind(core: nil); core.updateHandler = nil; _ = core.stop()
            window.isHidden = true; oldWindow?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: battery)
        }
        core.rate = 8; XCTAssertTrue(core.start()); await fulfillment(of: [booted], timeout: 60)
        XCTAssertTrue(core.pause()); core.rate = 1; XCTAssertTrue(core.resume())
        func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("Native friend menu did not reach expected state: \(probe.read())", file: file, line: line)
        }
        func press(_ mask: Int) async throws {
            core.deltaCore.emulatorBridge.activateInput(mask, value: 1, playerIndex: 0)
            try await Task.sleep(for: .milliseconds(100))
            core.deltaCore.emulatorBridge.deactivateInput(mask, playerIndex: 0)
            try await Task.sleep(for: .milliseconds(150))
        }
        try await wait { p.a.canInteract }
        XCTAssertTrue(p.a.open(at: 10))
        try await wait { probe.read().menuReady && probe.read().mode == 0 }
        try await press(128) // Keep the real native cursor on Trade during the outage.
        let cursor = probe.read().cursor
        let chooserID = try XCTUnwrap(probe.read().activeID)
        p.online = false; p.a.suspend(); p.a.tick(at: 3600)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(probe.read().active); XCTAssertTrue(probe.read().menuReady)
        XCTAssertEqual(probe.read().mode, 0); XCTAssertEqual(probe.read().cursor, cursor)
        XCTAssertEqual(probe.read().activeID, chooserID)
        XCTAssertEqual(p.a.phase, .choosing)
        try await press(1)
        try await wait { p.a.phase == .outgoing && !probe.read().active && probe.read().ready }
        XCTAssertEqual(p.a.activity, .trade)
        XCTAssertFalse(p.a.blocksGameplay)
        XCTAssertFalse(p.a.menuPresented)
        XCTAssertFalse(panel.isHidden)
        XCTAssertNil(panel.hitTest(CGPoint(x:100,y:250),with:nil), "The notification must not intercept gameplay outside its buttons")
        let before = try XCTUnwrap(frames.read())
        try await Task.sleep(for: .milliseconds(250))
        let after = try XCTUnwrap(frames.read())
        XCTAssertNotEqual(before, after, "Unanswered invitation must allow native frames")
        p.a.tick(at: ProcessInfo.processInfo.systemUptime + Session.invitationLifetime)
        try await wait { p.a.phase == .ended && !probe.read().active && probe.read().ready }
        XCTAssertFalse(p.a.requiresResultAcknowledgement)
        p.a.cancel(); p.online = true
        p.a.start { p.aPackets.append($0); return true }
        p.aPackets.removeAll()
        XCTAssertTrue(p.b.open()); p.b.request(.trade); p.deliver(at: ProcessInfo.processInfo.systemUptime)
        try await wait { p.a.phase == .incoming && p.a.canInteract }
        XCTAssertFalse(probe.read().active, "Receiving an invitation cannot open a native window")
        XCTAssertFalse(panel.isHidden)
        XCTAssertTrue(p.a.open())
        XCTAssertTrue(panel.isHidden)
        try await wait { probe.read().menuReady && probe.read().mode == 1 }
        try await press(2)
        try await wait { p.a.phase == .idle && !probe.read().active && probe.read().ready }
        p.deliver(at: ProcessInfo.processInfo.systemUptime)
        p.b.cancel(); XCTAssertTrue(p.b.open()); p.b.request(.trade); p.deliver(at: ProcessInfo.processInfo.systemUptime)
        try await wait { p.a.phase == .incoming && p.a.canInteract }
        XCTAssertTrue(p.a.open())
        try await wait { probe.read().menuReady && probe.read().mode == 1 }
        p.a.tick(at: ProcessInfo.processInfo.systemUptime + Session.invitationLifetime)
        try await wait { p.a.phase == .ended && !probe.read().active && probe.read().ready }
        XCTAssertFalse(p.a.blocksGameplay)
        XCTAssertTrue(core.pause())
        // A fresh bedroom save has no Pokémon yet; battle admission also tests
        // party size. This check specifically verifies native field/UI cleanup.
        XCTAssertTrue(BoundVBABattleBridge.friendDialogueReady(), "Cancel releases native script locks and window tasks")
        p.a.send = nil
    }

}

final class BattleCableTests:XCTestCase {
    private final class Box:@unchecked Sendable {
        private let lock=NSLock()
        private var values:[Data]=[]
        func add(_ data:Data) { lock.lock(); values.append(data); lock.unlock() }
        var snapshot:[Data] { lock.lock(); defer { lock.unlock() }; return values }
        func drain()->[Data] { lock.lock(); defer { lock.unlock() }; let copy=values; values.removeAll(); return copy }
    }
    func testContinuationRestoresBothWiresWithAnOutOfOrderGapExactlyOnce() throws {
        let id=UUID(),sent=Box(),received=Box()
        let originalA=BoundBattleWire(id:id,receive:{ _ in XCTFail() },failed:{ XCTFail() })
        let originalB=BoundBattleWire(id:id,receive:{ received.add($0) },failed:{ XCTFail() })
        originalA.setSender { sent.add($0);return true }
        XCTAssertTrue(originalA.send(Data([1])));XCTAssertTrue(originalA.send(Data([2])))
        originalB.receive(sent.snapshot[1]) // Retain the reordered second packet.
        let savedA=try originalA.freezeForContinuation(),savedB=try originalB.freezeForContinuation()
        originalB.receive(sent.snapshot[0])
        XCTAssertTrue(received.snapshot.isEmpty,"Late packets cannot advance a durable saved execution")
        let a=BoundBattleWire(id:id,receive:{ _ in XCTFail() },failed:{ XCTFail() })
        let b=BoundBattleWire(id:id,receive:{ received.add($0) },failed:{ XCTFail() })
        XCTAssertTrue(a.restoreContinuation(savedA));XCTAssertTrue(b.restoreContinuation(savedB))
        a.setSender { b.receive($0);return true };b.setSender { a.receive($0);return true }
        XCTAssertTrue(received.snapshot.isEmpty,"Restoring cannot send or ACK before its durable claim")
        b.thawContinuation();a.thawContinuation()
        let now=ProcessInfo.processInfo.systemUptime
        a.tick(at:now+1);b.tick(at:now+2)
        XCTAssertEqual(received.snapshot,[Data([1]),Data([2])]);XCTAssertFalse(a.hasPending)
        XCTAssertTrue(a.send(Data([3])))
        XCTAssertEqual(received.snapshot,[Data([1]),Data([2]),Data([3])],"New commands continue the previous sequence")
        originalA.close();originalB.close();a.close();b.close()
    }
    func testContinuationRetainsDeduplicationAcrossLostAckAndRejectsAnotherActivity() throws {
        let id=UUID(),sent=Box(),received=Box()
        let a=BoundBattleWire(id:id,receive:{ _ in XCTFail() },failed:{ XCTFail() })
        let b=BoundBattleWire(id:id,receive:{ received.add($0) },failed:{ XCTFail() })
        a.setSender { sent.add($0);return true };XCTAssertTrue(a.send(Data([9])))
        let packet=try XCTUnwrap(sent.snapshot.first);b.receive(packet)
        let saved=try b.freezeForContinuation()
        let reopened=BoundBattleWire(id:id,receive:{ received.add($0) },failed:{ XCTFail() })
        let wrong=BoundBattleWire(id:UUID(),receive:{ _ in XCTFail() },failed:{ XCTFail() })
        XCTAssertFalse(wrong.restoreContinuation(saved));XCTAssertTrue(reopened.restoreContinuation(saved))
        reopened.setSender { a.receive($0);return true }
        reopened.receive(packet);XCTAssertTrue(a.hasPending)
        reopened.thawContinuation();reopened.receive(packet);reopened.tick(at:ProcessInfo.processInfo.systemUptime+1)
        XCTAssertEqual(received.snapshot,[Data([9])],"Reopening cannot apply an already received trade command twice")
        XCTAssertFalse(a.hasPending)
        a.close();b.close();reopened.close();wrong.close()
    }
    func testWireReordersAndDeduplicatesAndRejectsWrongActivity() throws {
        let id=UUID(),sent=Box(),received=Box(),failures=Box()
        let outgoing=BoundBattleWire(id:id,receive:{ _ in },failed:{ XCTFail("Unexpected failure") })
        outgoing.setSender { sent.add($0); return true }
        XCTAssertTrue(outgoing.send(Data([1]))); XCTAssertTrue(outgoing.send(Data([2,3])))
        let incoming=BoundBattleWire(id:id,receive:{ received.add($0) },failed:{ failures.add(Data([1])) })
        let packets=sent.snapshot
        incoming.receive(packets[1]); XCTAssertTrue(received.snapshot.isEmpty)
        incoming.receive(packets[0]); incoming.receive(packets[0]); incoming.receive(packets[1])
        XCTAssertEqual(received.snapshot,[Data([1]),Data([2,3])]); XCTAssertTrue(failures.snapshot.isEmpty)
        let wrong=BoundBattleWire(id:UUID(),receive:{ _ in XCTFail("Wrong activity delivered") },failed:{ XCTFail() })
        wrong.receive(packets[0])
        var malformed=packets[0]; malformed[37]=2
        incoming.receive(malformed)
        incoming.close(); XCTAssertFalse(incoming.send(Data([1])))
        XCTAssertFalse(outgoing.send(Data(repeating:1,count:4097)))
    }
    func testWireFailsClosedOnUnboundedReordering() {
        let id=UUID(),sent=Box(),failures=Box()
        let outgoing=BoundBattleWire(id:id,receive:{ _ in },failed:{ XCTFail() })
        outgoing.setSender { sent.add($0); return true }
        XCTAssertTrue(outgoing.send(Data([1])))
        var tooFar=sent.snapshot[0]; tooFar[27]=65
        let incoming=BoundBattleWire(id:id,receive:{ _ in XCTFail() },failed:{ failures.add(Data([1])) })
        incoming.receive(tooFar); incoming.receive(sent.snapshot[0])
        XCTAssertEqual(failures.snapshot.count,1)
    }
    func testFailedSocketSendRetainsCommandsAndResumesSameSequenceInOrder() throws {
        let id=UUID(),attempts=Box(),received=Box(),interruptions=Box(),replayed=Box()
        let outgoing=BoundBattleWire(id:id,receive:{ _ in XCTFail() },failed:{ XCTFail("Transient failure cannot retire the wire") },
            interrupted:{ interruptions.add(Data([1])) })
        let incoming=BoundBattleWire(id:id,receive:{ received.add($0) },failed:{ XCTFail() })
        outgoing.setSender { attempts.add($0); return false }
        XCTAssertTrue(outgoing.send(Data([1,2])))
        XCTAssertTrue(outgoing.send(Data([3,4])))
        XCTAssertTrue(outgoing.hasPending)
        XCTAssertEqual(interruptions.snapshot.count,1)
        let original=attempts.snapshot
        outgoing.suspend(); XCTAssertTrue(outgoing.send(Data([5,6])))
        incoming.setSender { outgoing.receive($0); return true }
        outgoing.setSender { replayed.add($0); return true }
        let packets=replayed.snapshot
        XCTAssertEqual(packets.count,3)
        XCTAssertEqual(Array(packets.prefix(2)),original,"A socket reset must not assign replacement sequence numbers")
        incoming.receive(packets[2]); incoming.receive(packets[1])
        XCTAssertTrue(received.snapshot.isEmpty)
        incoming.receive(packets[0]); incoming.receive(packets[1]); incoming.receive(packets[2])
        incoming.tick(at:ProcessInfo.processInfo.systemUptime+1)
        XCTAssertEqual(received.snapshot,[Data([1,2]),Data([3,4]),Data([5,6])])
        XCTAssertFalse(outgoing.hasPending)
        outgoing.tick(at:ProcessInfo.processInfo.systemUptime+1)
        XCTAssertEqual(replayed.snapshot.count,3,"Acknowledged native commands must not keep replaying")
    }
    func testLostAcknowledgementReplaysWithoutRepeatingNativeCommand() throws {
        let id=UUID(),sent=Box(),received=Box(),acks=Box()
        let outgoing=BoundBattleWire(id:id,receive:{ _ in XCTFail() },failed:{ XCTFail() })
        let incoming=BoundBattleWire(id:id,receive:{ received.add($0) },failed:{ XCTFail() })
        outgoing.setSender { sent.add($0); return true }
        incoming.setSender { acks.add($0); return true } // Deliberately lose every initial ACK.
        XCTAssertTrue(outgoing.send(Data([0xBB,0x88])))
        incoming.receive(try XCTUnwrap(sent.snapshot.first))
        incoming.tick(at:ProcessInfo.processInfo.systemUptime+1)
        XCTAssertEqual(received.snapshot.count,1); XCTAssertTrue(outgoing.hasPending)
        let lost=try XCTUnwrap(acks.snapshot.first)
        XCTAssertEqual(lost.count,38,"The acknowledgement is an empty wire frame")
        incoming.setSender { outgoing.receive($0); return true }
        outgoing.tick(at:ProcessInfo.processInfo.systemUptime+1)
        incoming.receive(try XCTUnwrap(sent.snapshot.last))
        incoming.tick(at:ProcessInfo.processInfo.systemUptime+2)
        XCTAssertFalse(outgoing.hasPending)
        XCTAssertEqual(received.snapshot,[Data([0xBB,0x88])],"An ACK loss cannot duplicate a native continuation or trade operation")
        outgoing.receive(lost); XCTAssertFalse(outgoing.hasPending)
    }
    func testSynchronousBidirectionalDeliveryAcknowledgesWithoutDeadlock() {
        let id=UUID(),atA=Box(),atB=Box()
        let a=BoundBattleWire(id:id,receive:{ atA.add($0) },failed:{ XCTFail() })
        let b=BoundBattleWire(id:id,receive:{ atB.add($0) },failed:{ XCTFail() })
        a.setSender { b.receive($0); return true }; b.setSender { a.receive($0); return true }
        let now=ProcessInfo.processInfo.systemUptime
        for index in 0..<100 {
            XCTAssertTrue(a.send(Data([UInt8(index)]))); XCTAssertTrue(b.send(Data([UInt8(100+index)])))
            a.tick(at:now+Double(index)); b.tick(at:now+Double(index))
        }
        XCTAssertEqual(atA.snapshot.count,100); XCTAssertEqual(atB.snapshot.count,100)
        XCTAssertFalse(a.hasPending); XCTAssertFalse(b.hasPending)
        a.close(); b.close()
    }
    func testReplacedSenderCannotSuspendItsReplacementAfterAnOldSendFails() {
        let id=UUID(),replayed=Box(),received=Box(),interruptions=Box()
        let outgoing=BoundBattleWire(id:id,receive:{ _ in XCTFail() },failed:{ XCTFail() },interrupted:{ interruptions.add(Data([1])) })
        defer { outgoing.close() }
        let incoming=BoundBattleWire(id:id,receive:{ received.add($0) },failed:{ XCTFail() })
        incoming.setSender { outgoing.receive($0); return true }
        outgoing.setSender { _ in
            outgoing.setSender { replayed.add($0); return true }
            return false // Old socket completion races with the new sender.
        }
        XCTAssertTrue(outgoing.send(Data([9])))
        XCTAssertTrue(interruptions.snapshot.isEmpty,"Failure from a retired channel cannot suspend its replacement")
        XCTAssertEqual(replayed.snapshot.count,1)
        for packet in replayed.snapshot { incoming.receive(packet) }
        incoming.tick(at:ProcessInfo.processInfo.systemUptime+1)
        XCTAssertEqual(received.snapshot,[Data([9])]); XCTAssertFalse(outgoing.hasPending)
    }
    func testRepairBatchesAreRateBoundedAndDrainEveryRetainedCommand() {
        let id=UUID(),sent=Box(),received=Box()
        let outgoing=BoundBattleWire(id:id,receive:{ _ in XCTFail() },failed:{ XCTFail() })
        let incoming=BoundBattleWire(id:id,receive:{ received.add($0) },failed:{ XCTFail() })
        outgoing.suspend()
        for value in 0..<12 { XCTAssertTrue(outgoing.send(Data([UInt8(value)]))) }
        incoming.setSender { outgoing.receive($0); return true }
        outgoing.setSender { sent.add($0); return true }
        let now=ProcessInfo.processInfo.systemUptime
        for batch in 0..<4 {
            let packets=sent.drain()
            XCTAssertLessThanOrEqual(packets.count,4,"Repair traffic cannot burst every unacknowledged native packet at once")
            for packet in packets { incoming.receive(packet) }
            incoming.tick(at:now+Double(batch)+1)
            outgoing.tick(at:now+Double(batch)+1)
        }
        XCTAssertEqual(received.snapshot,(0..<12).map { Data([UInt8($0)]) })
        XCTAssertFalse(outgoing.hasPending)
        XCTAssertTrue(sent.snapshot.isEmpty)
    }
    func testUnacknowledgedQueueIsBoundedAndWrongActivityCannotAcknowledgeIt() throws {
        let id=UUID(),sent=Box(),failures=Box(),acks=Box()
        let outgoing=BoundBattleWire(id:id,receive:{ _ in XCTFail() },failed:{ failures.add(Data([1])) })
        outgoing.setSender { sent.add($0); return true }
        XCTAssertTrue(outgoing.send(Data([1])))
        let other=BoundBattleWire(id:UUID(),receive:{ _ in XCTFail() },failed:{ XCTFail() })
        other.setSender { acks.add($0); return true }
        other.receive(try XCTUnwrap(sent.snapshot.first)); XCTAssertTrue(acks.snapshot.isEmpty)
        var forged=try XCTUnwrap(sent.snapshot.first)
        forged.removeSubrange(38..<forged.count); forged[36]=0; forged[37]=0
        forged.replaceSubrange(20..<28,with:Data(repeating:0,count:8)); forged[35]=1; forged[4] ^= 1
        outgoing.receive(forged); XCTAssertTrue(outgoing.hasPending)
        forged[4] ^= 1; forged[35]=2
        outgoing.receive(forged); XCTAssertTrue(outgoing.hasPending,"A future acknowledgement cannot retire a command the peer has not received")
        for _ in 1..<64 { XCTAssertTrue(outgoing.send(Data([1]))) }
        XCTAssertFalse(outgoing.send(Data([1])))
        XCTAssertEqual(failures.snapshot.count,1)
        outgoing.close(); outgoing.setSender { _ in XCTFail("A retired activity must not replay"); return true }
        outgoing.tick(at:ProcessInfo.processInfo.systemUptime+1)
        XCTAssertFalse(outgoing.hasPending)
    }
    func testNativeBlockAdmissionRejectsUnsolicitedAndExcessWrites() {
        var admission=BoundNativeBlockAdmission()
        var continuation=Data(repeating:0,count:16)
        continuation[0]=0x88; continuation[1]=0x88
        XCTAssertFalse(admission.accept(continuation))
        var initial=Data(repeating:0,count:16)
        initial[0]=0xBB; initial[1]=0xBB; initial[2]=28
        XCTAssertTrue(admission.accept(initial+continuation+continuation))
        XCTAssertFalse(admission.accept(continuation))
        initial[2]=255
        XCTAssertFalse(admission.accept(initial)) // rounded write crosses small buffer
        initial[2]=88; initial[3]=2 // native 600-byte party exchange
        XCTAssertTrue(admission.accept(initial))
        for _ in 0..<43 { XCTAssertTrue(admission.accept(continuation)) }
        XCTAssertFalse(admission.accept(continuation))
    }
    func testNativeCommandsAreBoundedAndCannotSelectMemoryOrTradeActions() throws {
        var command=Data(repeating:0,count:16); command[0]=0xBB; command[1]=0xBB
        command[2]=0x58; command[3]=2 // Native party block: 600 bytes.
        let packet=try XCTUnwrap(BoundNativeCommandPacket.encode(command))
        XCTAssertEqual(BoundNativeCommandPacket.decode(packet),command)
        XCTAssertEqual(BoundNativeCommandPacket.generation(packet),1)
        XCTAssertEqual(BoundNativeCommandPacket.sequence(packet),1)
        let ack=Data([3,4,0,23,0])
        XCTAssertEqual(BoundNativeCommandPacket.decode(ack),Data())
        XCTAssertEqual(BoundNativeCommandPacket.sequence(ack),23)
        XCTAssertEqual(BoundNativeCommandPacket.acknowledgement(ack),Data([4,0,23,0]))
        XCTAssertEqual(BoundNativeCommandPacket.decode(BoundNativeCommandPacket.connection(4)),Data())
        XCTAssertNil(BoundNativeCommandPacket.decode(Data([2,0,0])))
        XCTAssertEqual(BoundNativeCommandPacket.decode(Data([0])),Data())
        command[2]=0xFF; command[3]=0xFF
        XCTAssertNil(BoundNativeCommandPacket.encode(command))
        command[0]=0xDD; command[1]=0xDD // Trade selection has no place in a battle.
        XCTAssertNil(BoundNativeCommandPacket.encode(command))
        XCTAssertNil(BoundNativeCommandPacket.decode(Data([1,2])))
        XCTAssertNil(BoundNativeCommandPacket.encode(Data(repeating:0,count:240)))
    }
    private func nativeRecord(generation:UInt16=1,sequence:UInt16,marker:UInt8=0)->Data {
        var command=Data(repeating:marker,count:16)
        command[0]=0x88;command[1]=0x88
        return Data([UInt8(truncatingIfNeeded:generation),UInt8(generation>>8),
                     UInt8(truncatingIfNeeded:sequence),UInt8(sequence>>8)])+command
    }
    private func expandedNativePackets(_ batches:[BoundNativeCommandPacket.Batch]) throws ->Data {
        var result=Data()
        for batch in batches {
            let generation=try XCTUnwrap(BoundNativeCommandPacket.generation(batch.packet))
            let first=try XCTUnwrap(BoundNativeCommandPacket.sequence(batch.packet))
            let commands=try XCTUnwrap(BoundNativeCommandPacket.decode(batch.packet))
            for offset in stride(from:0,to:commands.count,by:16) {
                let sequence=first &+ UInt16(offset/16)
                result.append(contentsOf:[UInt8(truncatingIfNeeded:generation),UInt8(generation>>8),
                                          UInt8(truncatingIfNeeded:sequence),UInt8(sequence>>8)])
                result.append(commands.subdata(in:offset..<offset+16))
            }
        }
        return result
    }
    func testNativeCommandBatchingPreservesEveryRecordAndSendsPartialFrameImmediately() throws {
        let records=(0..<32).reduce(Data()) { $0+nativeRecord(sequence:UInt16($1+1),marker:UInt8($1)) }
        let batches=try XCTUnwrap(BoundNativeCommandPacket.batches(records))
        XCTAssertEqual(batches.map(\.commandCount),[13,13,6])
        XCTAssertEqual(batches.map { $0.packet.count },[213,213,101])
        XCTAssertEqual(batches.reduce(Data()) { $0+$1.records },records)
        XCTAssertEqual(try expandedNativePackets(batches),records,"Network batching must not change canonical continuation records")
        let partial=try XCTUnwrap(BoundNativeCommandPacket.batches(nativeRecord(sequence:1)))
        XCTAssertEqual(partial.count,1,"A lone action must be sent immediately instead of waiting to fill a batch")
        XCTAssertEqual(partial.first?.commandCount,1)
        XCTAssertEqual(BoundNativeCommandPacket.batches(Data())?.count,0)
    }
    func testNativeCommandBatchingSplitsGenerationsAndSequenceGapsWithoutReordering() throws {
        let records=nativeRecord(sequence:10)+nativeRecord(sequence:11)+nativeRecord(sequence:15)
            + nativeRecord(generation:2,sequence:16)+nativeRecord(generation:2,sequence:17)
        let batches=try XCTUnwrap(BoundNativeCommandPacket.batches(records))
        XCTAssertEqual(batches.map(\.commandCount),[2,1,2])
        XCTAssertEqual(batches.map { BoundNativeCommandPacket.generation($0.packet) },[1,1,2])
        XCTAssertEqual(batches.map { BoundNativeCommandPacket.sequence($0.packet) },[10,15,16])
        XCTAssertEqual(try expandedNativePackets(batches),records)
        let duplicate=nativeRecord(sequence:20)+nativeRecord(sequence:20)+nativeRecord(sequence:19)
        XCTAssertEqual(try XCTUnwrap(BoundNativeCommandPacket.batches(duplicate)).map(\.commandCount),[1,1,1])
        XCTAssertEqual(try expandedNativePackets(XCTUnwrap(BoundNativeCommandPacket.batches(duplicate))),duplicate)
    }
    func testNativeCommandBatchingSupportsSequenceWrapAndRejectsMalformedRecords() throws {
        let records=nativeRecord(sequence:65534)+nativeRecord(sequence:65535)+nativeRecord(sequence:0)+nativeRecord(sequence:1)
        let batches=try XCTUnwrap(BoundNativeCommandPacket.batches(records))
        XCTAssertEqual(batches.map(\.commandCount),[4])
        XCTAssertEqual(try expandedNativePackets(batches),records)
        XCTAssertNil(BoundNativeCommandPacket.batches(Data(records.dropLast())))
        XCTAssertNil(BoundNativeCommandPacket.batches(Data(repeating:0,count:33*20)))
        XCTAssertNil(BoundNativeCommandPacket.batches(nativeRecord(generation:0,sequence:1)))
        var invalid=nativeRecord(sequence:2)
        invalid[4]=0xDD;invalid[5]=0xDD
        XCTAssertNil(BoundNativeCommandPacket.batches(nativeRecord(sequence:1)+invalid),"Validate the entire frame before sending any partial batch")
    }
}

@MainActor
extension FriendInteractionTests {
    func testDecisionPacketsCarryOnlyBoundedConfirmedInputs() throws {
        var move=Data(repeating:0,count:32)
        move[0]=1;move[4]=42;move[8]=1;move[9]=20;move[10]=0;move[11]=8
        move.replaceSubrange(12..<20,with:[33,10,2,0,1,0,0,0])
        let packet=try XCTUnwrap(BoundBattleDecisionPacket.encode(move))
        XCTAssertEqual(BoundBattleDecisionPacket.decode(packet),move)
        XCTAssertNil(BoundNativeCommandPacket.decode(packet),"Choices cannot enter the old serial command decoder")
        for (offset,value) in [(0,0),(8,2),(9,16),(10,1),(11,17),(12,255),(14,4),(15,2),(16,2),(28,1)] {
            var invalid=move;invalid[offset]=UInt8(value)
            XCTAssertNil(BoundBattleDecisionPacket.encode(invalid),"Rejected field \(offset)")
        }
        XCTAssertNil(BoundBattleDecisionPacket.decode(Data([4,2])+move))
        XCTAssertNil(BoundBattleDecisionPacket.encode(Data()))
        XCTAssertNil(BoundBattleDecisionPacket.encode(move+Data([0])))
        XCTAssertNotNil(BoundBattleDecisionPacket.encode(Data(Array(repeating:move,count:8).joined())))
        XCTAssertNil(BoundBattleDecisionPacket.encode(Data(Array(repeating:move,count:9).joined())))
        var party=move;party[9]=22;party[10]=2;party[11]=5
        party.replaceSubrange(12..<28,with:[34,1,0,0,0]+Array(repeating:UInt8(0),count:11))
        XCTAssertNotNil(BoundBattleDecisionPacket.encode(party))
        party[13]=6;XCTAssertNil(BoundBattleDecisionPacket.encode(party))
    }
    func testFinishedBattleReceiptRetainsProtocolAndResultForReconnect() throws {
        let packet=BoundBattleControlPacket(id:UUID(),kind:.finished,battleProtocol:2,battleResult:0x12345678)
        let decoded=try XCTUnwrap(BoundBattleControlPacket.decode(try XCTUnwrap(packet.encoded())))
        XCTAssertEqual(decoded.id,packet.id);XCTAssertEqual(decoded.battleProtocol,2)
        XCTAssertEqual(decoded.battleResult,packet.battleResult)
        let legacy=try XCTUnwrap(BoundBattleControlPacket.decode(try XCTUnwrap(BoundBattleControlPacket(id:UUID(),kind:.prepared).encoded())))
        XCTAssertNil(legacy.battleProtocol,"An older client must never negotiate decision-only execution")
    }
    func testRetiredBattleAnswersLostFinishedResultWithoutReceiptEcho() throws {
        let id=UUID(),finished=BoundBattleControlPacket(id:id,kind:.finished,battleProtocol:2,battleResult:0x12345678)
        let reply=try XCTUnwrap(finished.retainedReply(to:finished))
        let received=try XCTUnwrap(BoundBattleControlPacket.decode(try XCTUnwrap(reply.encoded())))
        XCTAssertEqual(received.kind,.finished);XCTAssertEqual(received.battleResult,finished.battleResult)
        XCTAssertEqual(received.battleProtocol,2);XCTAssertEqual(received.terminalReceipt,true)
        XCTAssertNil(finished.retainedReply(to:received),"Two retired peers must stop after one terminal receipt")
        XCTAssertNotNil(finished.retainedReply(to:finished),"A lost receipt is repaired by the active peer's next finished retry")
        XCTAssertNil(finished.retainedReply(to:BoundBattleControlPacket(id:UUID(),kind:.finished)))
        for kind in [BoundBattleControlPacket.Kind.ranAway,.abort] {
            let terminal=BoundBattleControlPacket(id:id,kind:kind,battleProtocol:2)
            XCTAssertEqual(terminal.retainedReply(to:finished)?.kind,kind,"A retry cannot convert a cancellation or failure into a win")
        }
        for kind in [BoundBattleControlPacket.Kind.prepared,.connected,.resumeRequest,.resumeReady] {
            XCTAssertEqual(finished.retainedReply(to:BoundBattleControlPacket(id:id,kind:kind))?.battleResult,finished.battleResult)
        }
    }
    func testTerminalPersistenceRetryKeepsVerifiedOutcomeAndRealFailures() throws {
        for kind in [BoundBattleControlPacket.Kind.finished,.abort,.ranAway] {
            var persistence=BoundBattleTerminalPersistence()
            let packet=BoundBattleControlPacket(id:UUID(),kind:kind,battleProtocol:2,battleResult:kind == .finished ? 0x12345678:nil)
            XCTAssertThrowsError(try persistence.save(packet) { _ in throw CocoaError(.fileWriteUnknown) })
            XCTAssertTrue(persistence.needsRetry)
            var stored=Data()
            try persistence.save(packet) { stored=$0 }
            XCTAssertFalse(persistence.needsRetry)
            let recovered=try XCTUnwrap(BoundBattleControlPacket.decode(stored))
            XCTAssertEqual(recovered.kind,kind,"Disk recovery must preserve the actual battle outcome")
            XCTAssertEqual(recovered.id,packet.id);XCTAssertEqual(recovered.battleResult,packet.battleResult)
        }
    }
    func testAcceptedTradeHandsControlsToNativeActivityAndCancelReturnsToAdapter() throws {
        let p=peers(); var canceled=0
        p.a.agreed={ [weak a=p.a] activity,_,_ in
            XCTAssertEqual(activity,.trade)
            a?.activityProgress("Connecting trade…",playing:false)
        }
        p.a.cancelActivity={ [weak a=p.a] in canceled+=1; a?.activityEnded("Trade ended") }
        XCTAssertTrue(p.a.open(at:10)); p.a.request(.trade,at:10); p.deliver()
        p.b.accept(at:10.1); p.deliver(at:10.2)
        XCTAssertEqual(p.a.phase,.connecting); XCTAssertTrue(p.a.blocksGameplay)
        p.a.activityProgress("Trade",playing:true)
        XCTAssertEqual(p.a.phase,.playing); XCTAssertFalse(p.a.blocksGameplay)
        p.a.cancel(); XCTAssertEqual(canceled,1); XCTAssertEqual(p.a.phase,.ended)
    }
}

@MainActor
final class NativeContinuationTests:XCTestCase {
    private func record(context:BoundNativeContinuationContext,ticket:UUID=UUID())->BoundNativeContinuation {
        BoundNativeContinuation(version:1,ticket:ticket,context:context,gameID:"continuation-fixture",rom:BoundPlayerROMProfile.supportedSHA256,
            cartridge:String(repeating:"a",count:64),id:UUID(),activity:.trade,initiator:true,rate:1,
            localPrepared:true,peerPrepared:true,localConnected:true,peerConnected:true,entryQueued:true,
            localFinished:false,peerFinished:false,played:true,peerLinkClosed:false,observation:nil,
            state:Data(repeating:1,count:1025),battery:Data(repeating:0xFF,count:131072),bridge:Data([1]),
            probe:Data(),wire:Data(),backup:Data(repeating:2,count:1025),journal:Data(),memoryFiles:[:],heads:BoundContinuationHeads(checkpoints:[],permitsNoCheckpoint:true))
    }
    func testDurableContinuationIsScopedAndClaimedBeforeReuse() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=BoundNativeContinuationStore(root:folder)
        let context=BoundNativeContinuationContext(owner:UUID(),roomID:UUID().uuidString,runID:UUID())
        let value=record(context:context);try store.save(value)
        XCTAssertEqual(try store.load(context:context,gameID:value.gameID)?.ticket,value.ticket)
        let otherOwner=BoundNativeContinuationContext(owner:UUID(),roomID:context.roomID,runID:context.runID)
        let otherRun=BoundNativeContinuationContext(owner:context.owner,roomID:context.roomID,runID:UUID())
        XCTAssertNil(try store.load(context:otherOwner,gameID:value.gameID))
        XCTAssertNil(try store.load(context:otherRun,gameID:value.gameID))
        XCTAssertNil(try store.load(context:context,gameID:"another-game"))
        let claimant=UUID()
        try store.claim(ticket:value.ticket,context:context,gameID:value.gameID,claimant:claimant)
        try store.claim(ticket:value.ticket,context:context,gameID:value.gameID,claimant:claimant)
        XCTAssertThrowsError(try store.claim(ticket:value.ticket,context:context,gameID:value.gameID),"Another reopened core cannot claim the same trade execution")
        XCTAssertThrowsError(try store.load(context:context,gameID:value.gameID),"A crash after resuming cannot silently load the pre-trade server save")
        let settlement=try XCTUnwrap(store.settlement(context:context,gameID:value.gameID))
        try store.settle(settlement)
        XCTAssertNil(try store.load(context:context,gameID:value.gameID),"Only confirmed post-activity world durability retires the recovery fence")
        let next=record(context:context);try store.save(next)
        XCTAssertEqual(try store.load(context:context,gameID:next.gameID)?.ticket,next.ticket,"A later intentional pause creates a fresh continuation")
    }
    func testTerminalBeforeClaimPreventsCancelledExecutionFromReopening() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=BoundNativeContinuationStore(root:folder)
        let context=BoundNativeContinuationContext(owner:UUID(),roomID:UUID().uuidString,runID:UUID())
        let value=record(context:context);try store.save(value)
        try store.saveTerminal(id:value.id,data:Data("abort".utf8),context:context,gameID:value.gameID)
        XCTAssertThrowsError(try store.load(context:context,gameID:value.gameID),"A crash between terminal write and claim cannot rejoin the cancelled trade")
    }
    func testHeadsFenceNewerWorldAndOldSettlementCannotConsumeNewExecution() throws {
        let oldHead=UUID(),pendingHead=UUID(),newerHead=UUID()
        let heads=BoundContinuationHeads(checkpoints:[oldHead,pendingHead],permitsNoCheckpoint:false)
        XCTAssertTrue(heads.permits(oldHead));XCTAssertTrue(heads.permits(pendingHead))
        XCTAssertFalse(heads.permits(newerHead));XCTAssertFalse(heads.permits(nil))
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=BoundNativeContinuationStore(root:folder)
        let context=BoundNativeContinuationContext(owner:UUID(),roomID:UUID().uuidString,runID:UUID()),game="continuation-fixture"
        let first=record(context:context);try store.save(first);try store.claim(ticket:first.ticket,context:context,gameID:game)
        let olderUpload=try XCTUnwrap(store.settlement(context:context,gameID:game))
        let second=record(context:context);try store.save(second);try store.claim(ticket:second.ticket,context:context,gameID:game)
        try store.settle(olderUpload)
        XCTAssertThrowsError(try store.load(context:context,gameID:game),"An older in-flight world upload cannot settle a later trade")
    }
    func testTerminalReceiptsSurviveRelaunchAndStayScopedAndBounded() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=BoundNativeContinuationStore(root:folder)
        let context=BoundNativeContinuationContext(owner:UUID(),roomID:UUID().uuidString,runID:UUID())
        let ids=(0..<35).map { _ in UUID() }
        for id in ids { try store.saveTerminal(id:id,data:Data("finished".utf8),context:context,gameID:"game") }
        let reopened=BoundNativeContinuationStore(root:folder)
        XCTAssertNil(try reopened.terminal(id:ids[0],context:context,gameID:"game"))
        XCTAssertEqual(try reopened.terminal(id:ids[34],context:context,gameID:"game"),Data("finished".utf8),"A late peer may finish after the other app has restarted")
        let other=BoundNativeContinuationContext(owner:context.owner,roomID:context.roomID,runID:UUID())
        XCTAssertNil(try reopened.terminal(id:ids[34],context:other,gameID:"game"))
        XCTAssertThrowsError(try store.saveTerminal(id:UUID(),data:Data(repeating:0,count:8193),context:context,gameID:"game"))
    }
    func testMalformedContinuationCannotBecomeAnEmptyOrFreshSession() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=BoundNativeContinuationStore(root:folder)
        let context=BoundNativeContinuationContext(owner:UUID(),roomID:UUID().uuidString,runID:UUID())
        let value=record(context:context);try store.save(value)
        let file=try XCTUnwrap(FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).first { $0.pathExtension=="json" })
        try Data("{}".utf8).write(to:file,options:.atomic)
        XCTAssertThrowsError(try store.load(context:context,gameID:value.gameID))
        let invalid=record(context:BoundNativeContinuationContext(owner:context.owner,roomID:"unbound",runID:context.runID))
        XCTAssertThrowsError(try store.save(invalid))
    }
    func testNativeRunUsesOnlyCartridgeProducedTerminalResults() {
        for value in [1,2,3,0x81,0x82,0x83] { XCTAssertEqual(BoundNativeBattleSession.terminalOutcome(value),value & 0x7F) }
        for value in [-1,0,4,0x80,0x84,0x101,0x181] { XCTAssertNil(BoundNativeBattleSession.terminalOutcome(value)) }
    }
    func testRestoredConsentDoesNotStartANewNativeActivity() {
        let session=BoundFriendInteractionSession(),id=UUID()
        session.agreed={ _,_,_ in XCTFail("Restored consent must not create a replacement battle or trade") }
        session.restoreActivity(.trade,id:id,initiator:false)
        XCTAssertEqual(session.requestID,id);XCTAssertEqual(session.activity,.trade);XCTAssertEqual(session.phase,.connecting)
        XCTAssertTrue(session.blocksGameplay);XCTAssertFalse(session.requiresResultAcknowledgement)
        session.activityProgress("Trade",playing:true)
        XCTAssertEqual(session.phase,.playing);XCTAssertEqual(session.requestID,id)
    }
}
