import XCTest
import UIKit
import DeltaCore
import GBADeltaCore
@testable import Delta

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
        let aID = UUID(), bID = UUID()
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
    func testDeclineCancelTimeoutAndCrossedInvitationsCannotLaunchActivity() {
        let p = peers(); var launched = false
        p.a.agreed = { _,_,_ in launched = true }; p.b.agreed = { _,_,_ in launched = true }
        p.a.open(at:10); p.a.request(.trade,at:10); p.deliver(); p.b.decline(); p.deliver()
        XCTAssertEqual(p.a.message,"Your friend declined the request"); XCTAssertEqual(p.b.phase,.idle)
        p.a.cancel(); p.a.open(at:20); p.a.request(.battle,at:20); p.deliver(at:20)
        p.a.cancel(); p.deliver(at:20); XCTAssertEqual(p.b.phase,.ended)
        p.b.cancel(); p.a.open(at:30); p.a.request(.trade,at:30); p.a.tick(at:61)
        XCTAssertEqual(p.a.message,"Request timed out"); p.a.cancel()
        p.aPackets.removeAll(); p.bPackets.removeAll()
        p.a.open(at:70); p.b.open(at:70); p.a.request(.battle,at:70); p.b.request(.trade,at:70)
        p.deliver(at:70); p.deliver(at:70)
        XCTAssertEqual(p.a.phase,.ended); XCTAssertEqual(p.b.phase,.ended); XCTAssertFalse(launched)
    }
    func testMovementLostPresenceAndConnectionChangesInvalidateAdmission() {
        let p = peers()
        p.a.open(at:10); p.a.request(.battle,at:10); p.deliver()
        p.right = position(8,8,facing:3); p.b.accept(at:10.1); p.a.tick(at:10.1)
        XCTAssertEqual(p.a.phase,.ended); XCTAssertTrue(p.bPackets.isEmpty)
        p.a.cancel(); p.b.cancel(); p.right = position(7,8,facing:3)
        p.a.open(at:20); p.a.request(.trade,at:20); p.deliver(at:20)
        p.online = false; p.a.tick(at:20.1); XCTAssertEqual(p.a.phase,.ended)
        p.online = true; p.a.cancel(); p.a.refreshInputGate()
        XCTAssertEqual(BoundFriendWorldInput(input:p.a.inputGate.filter(GBAGameInput.a)), .interact)
        p.a.stop()
        XCTAssertEqual(p.a.inputGate.filter(GBAGameInput.a).type,.game(.gba), "Stopping must release the gate even while idle")
        XCTAssertFalse(p.a.canInteract)
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

    func testReliableMailboxCannotLoseInvitationsToMovementOrUntrustedPeers() {
        let callbacks = AgoraSharingCallbacks(remoteUID:2) { _,_ in }
        let p = peers(); p.a.open(at:10); p.a.request(.battle,at:10)
        let packet = p.aPackets[0]
        callbacks.receiveInteraction(packet,uid:9); XCTAssertTrue(callbacks.takeInteractions().messages.isEmpty)
        callbacks.receiveInteraction(packet,uid:2)
        for index in 0..<100 { callbacks.receivePresence(Data([UInt8(index)]),uid:2) }
        XCTAssertEqual(callbacks.takeInteractions().messages,[packet]); XCTAssertEqual(callbacks.takeLatestPresence(),Data([99]))
        for _ in 0..<65 { callbacks.receiveInteraction(packet,uid:2) }
        let overflow = callbacks.takeInteractions(); XCTAssertTrue(overflow.failed); XCTAssertTrue(overflow.messages.isEmpty)
        callbacks.resetFrames(enabled:true); callbacks.receiveInteraction(packet,uid:2)
        callbacks.suspendFrames(); XCTAssertTrue(callbacks.takeInteractions().messages.isEmpty)
        callbacks.receiveInteraction(packet,uid:2); XCTAssertTrue(callbacks.takeInteractions().messages.isEmpty)
    }
    func testInteractionPanelHasRealActionsAndExplainsPersistentTradeScope() {
        let p = peers(), panel = BoundFriendInteractionPanel(session: peers().a)
        XCTAssertTrue(panel.isHidden)
        let active = BoundFriendInteractionPanel(session:p.a)
        p.a.changed = { active.render() }
        p.a.open(at:10); active.frame = CGRect(x:0,y:0,width:393,height:852); active.layoutIfNeeded()
        XCTAssertFalse(active.isHidden)
        func descendants(_ view:UIView)->[UIView] { view.subviews.flatMap { [$0]+descendants($0) } }
        let views = descendants(active)
        let battle = views.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "bound.friend-interaction.battle" }
        XCTAssertNotNil(battle); battle?.sendActions(for:.touchUpInside)
        XCTAssertEqual(p.a.phase,.outgoing); XCTAssertEqual(p.a.activity,.battle)
        XCTAssertTrue(views.compactMap { $0 as? UILabel }.contains { $0.text?.contains("Pokémon selection, confirmation and saving") == true })
        p.a.cancel(); XCTAssertTrue(active.isHidden)
    }
}

final class BattleCableTests:XCTestCase {
    private final class Box:@unchecked Sendable {
        private let lock=NSLock()
        private var values:[Data]=[]
        func add(_ data:Data) { lock.lock(); values.append(data); lock.unlock() }
        var snapshot:[Data] { lock.lock(); defer { lock.unlock() }; return values }
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
        var malformed=packets[0]; malformed[29]=2
        incoming.receive(malformed)
        incoming.close(); XCTAssertFalse(incoming.send(Data([1])))
        XCTAssertFalse(outgoing.send(Data(repeating:1,count:4097)))
    }
    func testRDTCallbacksMayFragmentAndCombineWireFrames() throws {
        let sent=Box(),id=UUID()
        let wire=BoundBattleWire(id:id,receive:{ _ in },failed:{ XCTFail() })
        wire.setSender { sent.add($0); return true }
        XCTAssertTrue(wire.send(Data([8,0,1,2,3,4,5,6])))
        XCTAssertTrue(wire.send(Data([4,4,0,0])))
        let packets=sent.snapshot,combined=packets[0]+packets[1]
        var split=BoundBattleRDTFramer(),result:[Data]=[]
        for byte in combined { result += try XCTUnwrap(split.consume(Data([byte]))) }
        XCTAssertEqual(result,packets)
        var joined=BoundBattleRDTFramer()
        XCTAssertEqual(joined.consume(combined),packets)
        var invalid=BoundBattleRDTFramer()
        XCTAssertNil(invalid.consume(Data(repeating:255,count:30)))
        var huge=BoundBattleRDTFramer()
        XCTAssertNil(huge.consume(Data(repeating:0,count:131073)))
    }
    func testWireFailsClosedOnUnboundedReordering() {
        let id=UUID(),sent=Box(),failures=Box()
        let outgoing=BoundBattleWire(id:id,receive:{ _ in },failed:{ XCTFail() })
        outgoing.setSender { sent.add($0); return true }
        for _ in 0..<65 { XCTAssertTrue(outgoing.send(Data([1]))) }
        let incoming=BoundBattleWire(id:id,receive:{ _ in XCTFail() },failed:{ failures.add(Data([1])) })
        incoming.receive(sent.snapshot[64]); incoming.receive(sent.snapshot[0])
        XCTAssertEqual(failures.snapshot.count,1)
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
}

@MainActor
extension FriendInteractionTests {
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
