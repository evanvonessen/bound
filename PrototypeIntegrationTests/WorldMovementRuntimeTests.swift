import XCTest
import UIKit
import SwiftUI
import CryptoKit
import DeltaCore
import GBADeltaCore
@testable import Delta

private struct MovementRuntimeGame:GameProtocol {
    let fileURL:URL,gameSaveURL:URL
    var type:GameType { .gba }
}
private final class MovementRuntimeController:NSObject,GameController {
    let name="World movement native input QA"
    var playerIndex:Int?=0
    let inputType=GameControllerInputType.mfi
    var defaultInputMapping:GameControllerInputMappingProtocol? {nil}
}
private final class MovementRuntimeClock:@unchecked Sendable {
    private let lock=NSLock()
    private var value:TimeInterval=100
    func read()->TimeInterval {lock.lock();defer{lock.unlock()};return value}
    func set(_ next:TimeInterval) {lock.lock();value=next;lock.unlock()}
}
private final class MovementRuntimeFrames:@unchecked Sendable {
    private let lock=NSLock()
    private var count:UInt64=0,enabled=true
    private var stepOrigin:BoundMovementTile?,stepFrame:UInt32=0,stepFinished=false
    private var stepSnapshot:BoundMovementSnapshot?
    let probe:BoundMovementProbe
    init(probe:BoundMovementProbe){self.probe=probe}
    func enable(_ value:Bool){lock.lock();enabled=value;lock.unlock()}
    func read()->UInt64 {lock.lock();defer{lock.unlock()};return count}
    func armStep(_ snapshot:BoundMovementSnapshot) {
        lock.lock();stepOrigin=snapshot.current;stepFrame=BoundMovementSnapshot.word(snapshot.bytes,12)
        stepFinished=false;stepSnapshot=nil;lock.unlock()
    }
    func stepResult()->(Bool,BoundMovementSnapshot?) {
        lock.lock();defer{lock.unlock()};return(stepFinished,stepSnapshot)
    }
    func cancelStep(){lock.lock();stepOrigin=nil;lock.unlock()}
    func receive(_ core:EmulatorCore) {
        lock.lock();let apply=enabled;lock.unlock()
        if apply {probe.receive(core)}
        lock.lock();let origin=stepOrigin,initialFrame=stepFrame,finished=stepFinished;lock.unlock()
        if let origin,!finished {
            let snapshot=BoundMovementSnapshot(BoundVBABattleBridge.worldMovementSnapshot())
            // Delta's read-only bank maps EWRAM at0x8000, after IWRAM.
            let avatar=core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x3707D,size:1)
            var physical:BoundMovementTile?
            if let avatar,let index=avatar.first,index<16,
               let bytes=core.deltaCore.emulatorBridge.readMemory?(at:0x8000+0x36E38+Int(index)*36+16,size:4),bytes.count==4 {
                let x=Int(Int16(bitPattern:UInt16(bytes[0])|UInt16(bytes[1])<<8))-7
                let y=Int(Int16(bitPattern:UInt16(bytes[2])|UInt16(bytes[3])<<8))-7
                physical = .init(x:x,y:y)
            }
            let blocked=snapshot.map{BoundMovementSnapshot.word($0.bytes,12) != initialFrame && $0.flags&(32|64|16) != 0} ?? false
            if physical.map({$0 != origin}) == true || blocked {
                // Release on the emulation callback, before another native
                // step can begin. MainActor polling can span multiple frames.
                core.deltaCore.emulatorBridge.deactivateInput(32,playerIndex:0)
                lock.lock();stepFinished=true;stepSnapshot=snapshot;lock.unlock()
            }
        }
        lock.lock();count &+= 1;lock.unlock()
    }
}

@MainActor private final class MovementRuntimeWorker {
    let core:EmulatorCore,output:URL,image:Data,state:Data
    let probe:BoundMovementProbe,frames:MovementRuntimeFrames,clock:MovementRuntimeClock
    private let host=BoundROMMultiplayerProbe()
    init(name:String) throws {
        let clock=MovementRuntimeClock();self.clock=clock
        let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Phase6SoulQA-"+String(BoundWorldContract.romSHA256.prefix(12)))
        let rom=root.appendingPathComponent("current.gba"),frozen=root.appendingPathComponent("observer.state")
        guard FileManager.default.fileExists(atPath:rom.path),FileManager.default.fileExists(atPath:frozen.path) else {
            throw XCTSkip("Requires the dedicated exact-ROM Phase6SoulQA fixture")
        }
        image=try Data(contentsOf:rom);state=try Data(contentsOf:frozen)
        guard SHA256.hash(data:image).map({String(format:"%02x",$0)}).joined()==BoundWorldContract.romSHA256 else {
            throw NSError(domain:"WorldMovementFixtureHash",code:1)
        }
        output=root.appendingPathComponent(name+"-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let battery=output.appendingPathComponent("work.sav")
        try Data(repeating:255,count:131072).write(to:battery)
        core=try XCTUnwrap(EmulatorCore(game:MovementRuntimeGame(fileURL:rom,gameSaveURL:battery),options:[.metal:true]))
        core.audioManager.isEnabled=false
        try BoundROMMultiplayerCoordinator.prepareServerCoreForSelection(core)
        guard MultiRedAdapter.restoreState(state) else {throw NSError(domain:"WorldMovementRestore",code:1)}
        probe=BoundMovementProbe(clock:{clock.read()});frames=MovementRuntimeFrames(probe:probe)
        probe.configure(core:core);host.configure(core:core);host.setVerified(true)
        var status=BoundROMHostState();status.enabled=true;status.ended=true;status.status = .complete;host.publish(status)
        let host=host,frames=frames
        core.updateHandler={core in BoundFrameMemory.perform{host.receive(core);frames.receive(core)}}
        core.rate=1;_=core.pause()
        BoundFrameMemory.perform{host.receive(core);probe.receive(core)}
    }
    func close(){_=core.pause();BoundVBABattleBridge.setWorldMovementHost(Data());BoundVBABattleBridge.closeSoulLink();_=core.stop()}
    func memory() throws->BoundGBAMemorySnapshot {
        try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory:{core.deltaCore.emulatorBridge.readMemory?(at:$0,size:$1)}))
    }
    func snapshot() throws->BoundMovementSnapshot {try XCTUnwrap(BoundMovementSnapshot(BoundVBABattleBridge.worldMovementSnapshot()))}
    func publish(_ data:Data?) {
        XCTAssertEqual(core.state,.paused)
        probe.publish(data)
        // Prime the completed-frame port before introducing the first input.
        // A connected live session normally already has this admitted data.
        BoundFrameMemory.perform{probe.receive(core)}
    }
    func admit(_ data:Data) async throws {
        let previous=BoundMovementSnapshot.word(try snapshot().bytes,76)
        publish(data)
        // Writing PH does not synchronously ingest native PC_INPUT. A restored
        // CPU can be between BeforeCallbacks and its collision query. Wait for
        // native acknowledgement before introducing a connected peer's input.
        for _ in 0..<90 {
            try await advance(1)
            let accepted=try snapshot()
            if accepted.flags&6==6 && BoundMovementSnapshot.word(accepted.bytes,76) != previous {return}
        }
        throw NSError(domain:"WorldMovementNativeAdmissionTimeout",code:1)
    }
    func rewind() throws {
        _=core.pause()
        for key in [1,2,8,16,32,64,128]{core.deltaCore.emulatorBridge.deactivateInput(key,playerIndex:0)}
        BoundVBABattleBridge.setWorldMovementHost(Data());XCTAssertTrue(MultiRedAdapter.restoreState(state))
        probe.configure(core:core);frames.enable(true);clock.set(100)
        BoundFrameMemory.perform{host.receive(core);probe.receive(core)}
    }
    func advance(_ count:UInt64) async throws {
        let target=frames.read()+count
        XCTAssertTrue(core.resume())
        for _ in 0..<600 {
            if frames.read()>=target {
                _=core.pause()
                // A video frame can end midway through a native callback.
                // An odd BWO sequence is a legal partial writer. Observe only
                // a completed native publication before asserting its fields.
                if BoundMovementSnapshot(BoundVBABattleBridge.worldMovementSnapshot()) != nil {return}
                XCTAssertTrue(core.resume())
            }
            try await Task.sleep(for:.milliseconds(10))
        }
        _=core.pause();throw NSError(domain:"WorldMovementFrameTimeout",code:Int(count))
    }
    func press(_ mask:Int,held:UInt64=4,release:UInt64=20) async throws {
        core.deltaCore.emulatorBridge.activateInput(mask,value:1,playerIndex:0)
        try await advance(held);core.deltaCore.emulatorBridge.deactivateInput(mask,playerIndex:0)
        try await advance(release)
    }
    @discardableResult func leftStep() async throws->BoundMovementSnapshot {
        let start=try snapshot();frames.armStep(start)
        core.deltaCore.emulatorBridge.activateInput(32,value:1,playerIndex:0)
        defer{frames.cancelStep();core.deltaCore.emulatorBridge.deactivateInput(32,playerIndex:0)}
        XCTAssertTrue(core.resume())
        for _ in 0..<600 {
            if frames.stepResult().0 {break}
            try await Task.sleep(for:.milliseconds(10))
        }
        _=core.pause();guard frames.stepResult().0 else {throw NSError(domain:"WorldMovementNativeStepStartTimeout",code:1)}
        core.deltaCore.emulatorBridge.deactivateInput(32,playerIndex:0)
        if BoundMovementSnapshot(BoundVBABattleBridge.worldMovementSnapshot()) == nil {try await advance(1)}
        let observed:BoundMovementSnapshot
        if let captured=frames.stepResult().1 {observed=captured} else {observed=try snapshot()}
        if try snapshot().current != start.current {
            for _ in 0..<90 {
                let now=try snapshot(),ram=try memory().workRAM
                if now.current==now.previous && ram[0x3707A]==0 && ram[0x3707B]==0 {return observed}
                try await advance(1)
            }
            throw NSError(domain:"WorldMovementNativeStepSettleTimeout",code:1)
        }
        return observed
    }
    func hostData(_ s:BoundMovementSnapshot,actors:[BoundMovementActor],flags:UInt32=1,sequence:UInt32=42)->Data {
        var d=Data(repeating:0,count:1024)
        func put(_ value:UInt32,_ at:Int){BoundMovementSnapshot.put(value,&d,at)}
        put(0x31574C42,0);put(1,4);put(sequence,8);put(flags,12);put(15,16);put(s.generation,20);put(1,24);put(2,28)
        for at in [32,48]{put(UInt32(truncatingIfNeeded:s.instance),at);put(UInt32(truncatingIfNeeded:s.instance>>32),at+4)}
        d[64]=UInt8(s.group);d[65]=UInt8(s.number);d[66]=UInt8(s.elevation);put(UInt32(actors.count),68)
        for (index,a) in actors.enumerated() {
            let at=128+index*32;put(1,at);BoundMovementSnapshot.putTile(a.current,&d,at+4);BoundMovementSnapshot.putTile(a.previous,&d,at+8)
            d[at+12]=UInt8(a.elevation);d[at+13]=UInt8(a.kind)
            put(UInt32(truncatingIfNeeded:a.identity),at+20);put(UInt32(truncatingIfNeeded:a.identity>>32),at+24)
        }
        return d
    }
    func actor(_ s:BoundMovementSnapshot,dx:Int=0,kind:Int=0)->BoundMovementActor {
        let tile=BoundMovementTile(x:s.current.x+dx,y:s.current.y)
        return .init(current:tile,previous:tile,elevation:s.elevation,kind:kind,identity:kind==1 ? 0x1234567887654321:0)
    }
    func report(_ name:String,_ values:[String:Any]) throws {
        var v=values;v["romSHA256"]=BoundWorldContract.romSHA256
        try JSONSerialization.data(withJSONObject:v,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent(name+".json"))
    }
}

@MainActor final class WorldMovementRuntimeTests:XCTestCase {
    private var previous:Any?
    override func setUp(){super.setUp();previous=UserDefaults.standard.object(forKey:BoundMultiplayerFeatures.key);BoundMultiplayerFeatures.setEnabled(true)}
    override func tearDown(){UserDefaults.standard.set(previous,forKey:BoundMultiplayerFeatures.key);NotificationCenter.default.post(name:BoundMultiplayerFeatures.didChange,object:nil);super.tearDown()}
    private func required() throws {
        guard ProcessInfo.processInfo.environment["BOUND_ENCOUNTER_GAMEPLAY"]=="1" else {throw XCTSkip("Requires isolated current-ROM runtime fixture")}
        continueAfterFailure=false
    }
    func testActualNativeWorldPortBlocksReleasesOverlapsAndCompletesAgreedStep() async throws {
        try required();let w=try MovementRuntimeWorker(name:"world-native-movement");defer{w.close()}
        let initial=try w.snapshot();XCTAssertNotEqual(initial.flags&1,0)
        XCTAssertEqual(initial.group,3);XCTAssertEqual(initial.number,0,"Fixture must expose the verified native Pallet floor")
        let target=BoundMovementTile(x:initial.current.x-1,y:initial.current.y)
        try await w.leftStep();XCTAssertEqual(try w.snapshot().current,target,"Native baseline must walk on the real floor")
        var checked=[String]()
        for kind in [0,1] {
            try w.rewind();let s=try w.snapshot();try await w.admit(w.hostData(s,actors:[w.actor(s,dx:-1,kind:kind)]))
            let attempt=try await w.leftStep();let blocked=try w.snapshot();XCTAssertEqual(blocked.current,s.current);XCTAssertNotNil(attempt.request)
            XCTAssertNotEqual(attempt.flags&32,0);checked.append(kind==0 ? "player blocked":"follower blocked")
            w.publish(nil);try await w.leftStep()
            XCTAssertEqual(try w.snapshot().current,target,"Revocation must release an already held blocker")
        }
        try w.rewind();let overlap=try w.snapshot();try await w.admit(w.hostData(overlap,actors:[w.actor(overlap)],flags:3))
        let overlapAttempt=try await w.leftStep();XCTAssertEqual(try w.snapshot().current,overlap.current,"Overlapped peers still coordinate simultaneous escape")
        let escape=try XCTUnwrap(overlapAttempt.request)
        var escapeGrant=w.hostData(overlap,actors:[w.actor(overlap)],flags:3)
        BoundMovementSnapshot.put(escape.nonce,&escapeGrant,72);BoundMovementSnapshot.put(escape.generation,&escapeGrant,76)
        BoundMovementSnapshot.putTile(escape.from,&escapeGrant,80);BoundMovementSnapshot.putTile(escape.to,&escapeGrant,84)
        try await w.admit(escapeGrant);try await w.leftStep()
        XCTAssertEqual(try w.snapshot().current,target,"Exact grant releases overlap without an asynchronous position change")
        try w.rewind();let near=try w.snapshot();try await w.admit(w.hostData(near,actors:[w.actor(near,dx:-2)],flags:3))
        let pending=try await w.leftStep();XCTAssertEqual(try w.snapshot().current,near.current)
        let step=try XCTUnwrap(pending.request);XCTAssertNotEqual(pending.flags&64,0)
        var grant=w.hostData(pending,actors:[w.actor(pending,dx:-2)],flags:3)
        BoundMovementSnapshot.put(step.nonce,&grant,72);BoundMovementSnapshot.put(step.generation,&grant,76)
        BoundMovementSnapshot.putTile(step.from,&grant,80);BoundMovementSnapshot.putTile(step.to,&grant,84)
        try await w.admit(grant);try await w.leftStep()
        let arrived=try w.snapshot();XCTAssertEqual(arrived.current,target);XCTAssertEqual(arrived.completed,step.nonce)
        try w.report("movement",["passed":true,"checked":checked+["overlap escape","near gate","granted native arrival"],"completedNonce":arrived.completed,"nativeGeneration":arrived.generation,"scope":"Real VBA-M frames and DPad; synthetic declared peer occupancy/grant, no position writes"])
    }
    func testActualNativePortAtomicValidationTTLMapAndBagTransition() async throws {
        try required();let w=try MovementRuntimeWorker(name:"world-native-port");defer{w.close()}
        let s=try w.snapshot();w.frames.enable(false)
        let valid=w.hostData(s,actors:[w.actor(s,dx:-1)],sequence:42)
        BoundVBABattleBridge.setWorldMovementHost(valid);try await w.advance(1)
        XCTAssertEqual(BoundMovementSnapshot.word(try w.snapshot().bytes,76),42);XCTAssertNotEqual(try w.snapshot().flags&4,0)
        var odd=valid;BoundMovementSnapshot.put(43,&odd,8)
        for rejected in [odd,Data(valid.prefix(17))] {
            BoundVBABattleBridge.setWorldMovementHost(rejected);try await w.advance(1)
            XCTAssertEqual(BoundMovementSnapshot.word(try w.snapshot().bytes,76),42,"Invalid publication must preserve the committed host transaction")
        }
        try await w.advance(16);XCTAssertEqual(try w.snapshot().flags&4,0,"Unchanged native input expires within15 frames")
        try await w.leftStep();XCTAssertEqual(try w.snapshot().current,.init(x:s.current.x-1,y:s.current.y))
        try w.rewind();let fresh=try w.snapshot();var wrong=w.hostData(fresh,actors:[w.actor(fresh,dx:-1)])
        wrong[48] ^= 1;w.publish(wrong);try await w.advance(3);XCTAssertEqual(try w.snapshot().flags&4,0)
        wrong=w.hostData(fresh,actors:[w.actor(fresh,dx:-1)]);wrong[64]=UInt8((fresh.group+1)%43)
        w.publish(wrong);try await w.advance(3);XCTAssertEqual(try w.snapshot().flags&4,0,"A different current native map cannot admit peer occupancy")
        w.publish(w.hostData(fresh,actors:[w.actor(fresh,dx:-4)]));try await w.advance(2)
        try await w.press(8);let menu=try w.memory().workRAM,count=Int(menu[0x370F5]),cursor=Int(menu[0x370F4])
        XCTAssertTrue((1...9).contains(count));let order=Array(menu[0x370F6..<0x370F6+count]),bag=try XCTUnwrap(order.firstIndex(of:2))
        XCTAssertLessThan(cursor,count)
        for _ in 0..<count*3 {
            if Int(try w.memory().workRAM[0x370F4])==bag {break}
            try await w.press(128)
        }
        XCTAssertEqual(Int(try w.memory().workRAM[0x370F4]),bag)
        try await w.press(1,release:80)
        let bagSnapshot=try w.snapshot();XCTAssertEqual(bagSnapshot.flags&(1|4),0);XCTAssertNil(bagSnapshot.request,"Native menu/fade removes movement authority")
        try w.report("port",["passed":true,"checks":["atomic odd/short rejection","native15-frame TTL","different current map","different map instance","Bag transition removes authority"],"snapshot":bagSnapshot.bytes.base64EncodedString()])
    }
    func testActualCosmeticBerryLeavesPausedRAMUnchangedAndProductionFilterSuppressesA() async throws {
        try required();let w=try MovementRuntimeWorker(name:"world-cosmetic-berry");defer{w.close()}
        let paused=try w.memory()
        let nativeMons=BoundSoulMon.decode(Data(paused.workRAM[0x24284..<0x24284+600]),stride:100)
        let leader=try XCTUnwrap(nativeMons.first{!$0.isEgg && ($0.hp ?? 0)>0})
        // Explicit cosmetic protocol target only. This does not claim that the
        // Viridian service is enabled or this native mon is following. Actual
        // enabled-follower selection/rendering has its separate native fixture.
        let fixtureID=UInt64(leader.identity.personality)<<32|UInt64(leader.identity.trainer),fixtureGeneration:UInt32=1
        let s=try w.snapshot(),a=UUID(),b=UUID(),sender=BoundFollowerInteractionSession(),receiver=BoundFollowerInteractionSession()
        defer{sender.suspend();receiver.suspend()}
        let actor=BoundFriendWorldPosition(mapGroup:s.group,mapNumber:s.number,elevation:s.elevation,x:s.current.x,y:s.current.y,facing:4)
        let target=BoundFriendWorldPosition(mapGroup:s.group,mapNumber:s.number,elevation:s.elevation,x:s.current.x+1,y:s.current.y,facing:1)
        sender.context={.init(localEpoch:a,peerEpoch:b,mapInstance:s.instance,actor:actor,target:target,followerID:fixtureID,generation:fixtureGeneration)}
        receiver.receiveContext={.init(localEpoch:b,peerEpoch:a,mapInstance:s.instance,actor:actor,target:target,followerID:fixtureID,generation:fixtureGeneration)}
        var packets=[Data](),reactions=[UInt64]()
        sender.send={packets.append($0);receiver.receive($0);return true};receiver.onReaction={reactions.append($0)}
        let ramBefore=Data(paused.workRAM)+Data(paused.internalRAM)
        XCTAssertTrue(sender.open());sender.offerBerry();XCTAssertEqual(packets.count,1);XCTAssertTrue(packets[0].starts(with:Data("BFC1".utf8)))
        receiver.receive(packets[0]);XCTAssertEqual(reactions,[fixtureID]);XCTAssertTrue(receiver.reaction.contains("♥"))
        let renderer=ImageRenderer(content:BoundFollowerInteractionView(session:receiver));renderer.proposedSize = .init(width:340,height:150)
        let image=try XCTUnwrap(renderer.uiImage),png=try XCTUnwrap(image.pngData())
        try png.write(to:w.output.appendingPathComponent("cosmetic-heart.png"))
        let ramAfter=try w.memory();XCTAssertEqual(Data(ramAfter.workRAM)+Data(ramAfter.internalRAM),ramBefore,"Open, berry send/receive, replay rejection and heart rendering must not touch paused native RAM")
        let gate=BoundFriendWorldInputGate(),controller=MovementRuntimeController();gate.updateSocial(available:true,blocked:false)
        let interact=gate.filter(GBAGameInput.a);XCTAssertEqual(BoundFriendWorldInput(input:interact),.interact)
        w.core.gameController(controller,didActivate:interact,value:1);try await w.advance(3)
        var keys=try w.memory().internalRAM;XCTAssertEqual(keys[0x311C]&1,0,"Production app-only namespace cannot press native A")
        w.core.gameController(controller,didDeactivate:interact);gate.updateSocial(available:true,blocked:true)
        let blocked=gate.filter(GBAGameInput.a);XCTAssertEqual(BoundFriendWorldInput(input:blocked),.blockedA)
        w.core.gameController(controller,didActivate:blocked,value:1);try await w.advance(3)
        keys=try w.memory().internalRAM;XCTAssertEqual(keys[0x311C]&1,0)
        w.core.gameController(controller,didDeactivate:blocked)
        try w.report("cosmetic",["passed":true,"nativeRAMBytesCompared":ramBefore.count,"packetBytes":packets[0].count,"fixtureIdentity":String(fixtureID),"productionANamespaceSuppressed":true,"scope":"Explicit synthetic cosmetic target using an actual healthy party identity; no active native follower claim. Native core paused through all berry/UI actions"])
    }
    func testActualPreFrameRevocationAndWallClockExpiryClearOnlyDeclaredHostPort() async throws {
        try required()
        #if targetEnvironment(simulator)
        let w=try MovementRuntimeWorker(name:"world-preframe-revocation");defer{w.close()}
        let s=try w.snapshot();try await w.admit(w.hostData(s,actors:[w.actor(s,dx:-1)]))
        w.frames.enable(false)
        let zero=Data(repeating:0,count:1024),committed=BoundVBABattleBridge.qaWorldMovementHost()
        XCTAssertEqual(committed.count,1024);XCTAssertNotEqual(committed,zero)
        let before=try w.memory(),ram=Data(before.workRAM)+Data(before.internalRAM)
        BoundVBABattleBridge.requestWorldMovementRevocation()
        XCTAssertEqual(BoundVBABattleBridge.qaWorldMovementHost(),committed,"Paused revocation queues a fence; it does not race a ROM writer")
        var paused=try w.memory();XCTAssertEqual(Data(paused.workRAM)+Data(paused.internalRAM),ram)
        // Exactly one original core frame through the production swizzled
        // selector, with the core paused and automatic probe refresh disabled.
        w.core.deltaCore.emulatorBridge.runFrame(processVideo:false)
        XCTAssertEqual(BoundVBABattleBridge.qaWorldMovementHost(),zero,"The queued revoke clears before the next native frame")

        let valid=w.hostData(s,actors:[w.actor(s,dx:-1)],sequence:100)
        BoundVBABattleBridge.setWorldMovementHost(valid)
        let deadlineRAM=try w.memory(),deadlineBytes=Data(deadlineRAM.workRAM)+Data(deadlineRAM.internalRAM)
        try await Task.sleep(for:.milliseconds(220))
        XCTAssertEqual(BoundVBABattleBridge.qaWorldMovementHost(),valid,"Wall-clock expiration waits for the core's frame fence")
        paused=try w.memory();XCTAssertEqual(Data(paused.workRAM)+Data(paused.internalRAM),deadlineBytes)
        w.core.deltaCore.emulatorBridge.runFrame(processVideo:false)
        XCTAssertEqual(BoundVBABattleBridge.qaWorldMovementHost(),zero,"The first actual frame clears data older than150ms")

        BoundVBABattleBridge.requestWorldMovementRevocation()
        BoundVBABattleBridge.setWorldMovementHost(valid)
        w.core.deltaCore.emulatorBridge.runFrame(processVideo:false)
        XCTAssertEqual(BoundVBABattleBridge.qaWorldMovementHost(),valid,"Fresh committed host data supersedes an older queued revocation")
        try w.report("preframe",["passed":true,"queuedRevocationClearedFirstFrame":true,"wallClockExpiryClearedFirstFrame":true,"freshPublicationSupersededOlderRevoke":true,"pausedNativeRAMBytesCompared":ram.count,"scope":"Read-only actual1024B ROM-port inspection, production pre-frame selector, no CPU coordinate or RAM writes"])
        #else
        throw XCTSkip("Requires the Debug simulator read-only host-port getter")
        #endif
    }
}
