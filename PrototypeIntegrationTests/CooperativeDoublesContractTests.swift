import XCTest
import UIKit
import DeltaCore
@testable import Delta
@testable import class Delta.GameViewController

private struct CooperativeLifecycleGame:GameProtocol {
    let fileURL:URL
    let gameSaveURL:URL
    var type:GameType { .gba }
}

final class CooperativeDoublesContractTests:XCTestCase {
    private func put(_ value:UInt32,_ data:inout Data,_ offset:Int) {
        for i in 0..<4 { data[offset+i]=UInt8(truncatingIfNeeded:value >> (8*i)) }
    }
    private func snapshot(count:UInt32=1,selected:UInt32=1,order:[UInt8]=[1,0,0])->Data {
        var data=Data(repeating:0,count:2048)
        put(0x31474443,&data,0);data[4]=1;put(2,&data,8);put(3,&data,12)
        put(9,&data,24);put(9,&data,44);put(123,&data,48)
        put(count,&data,64);put(selected,&data,68);data.replaceSubrange(72..<75,with:order)
        for i in 0..<600 { data[128+i]=UInt8(truncatingIfNeeded:i) }
        put(0xBC485D2D,&data,80)
        return data
    }
    func testNativeSelectionAllowsOneToThreeOwnedRecordsAndRejectsAmbiguity() throws {
        XCTAssertTrue(try XCTUnwrap(BoundCooperativeSnapshot(snapshot())).selected)
        XCTAssertTrue(try XCTUnwrap(BoundCooperativeSnapshot(snapshot(count:6,selected:3,order:[6,2,1]))).selected)
        XCTAssertFalse(try XCTUnwrap(BoundCooperativeSnapshot(snapshot(count:6,selected:3,order:[6,6,1]))).selected)
        XCTAssertFalse(try XCTUnwrap(BoundCooperativeSnapshot(snapshot(order:[1,1,0]))).selected)
        var pending=snapshot();put(3,&pending,8)
        XCTAssertNil(BoundCooperativeSnapshot(pending))
    }
    func testPartyEnvelopeFitsAuthenticatedRouteAndRejectsChangedPayload() throws {
        let state=try XCTUnwrap(BoundCooperativeSnapshot(snapshot()))
        let local=UUID(),peer=UUID(),encounter=UUID(),other=UUID()
        let packet=BoundCooperativePacket(kind:.team,local:local,peer:peer,id:encounter,peerID:other,snapshot:state,payload:state.party)
        XCTAssertEqual(packet.data.count,748)
        let decoded=try XCTUnwrap(BoundCooperativePacket(data:packet.data))
        XCTAssertEqual(decoded.sender,local);XCTAssertEqual(decoded.receiver,peer)
        XCTAssertEqual(decoded.id,encounter);XCTAssertEqual(decoded.peerID,other)
        XCTAssertEqual(decoded.payload,state.party);XCTAssertEqual(decoded.order,Data([1,0,0]))
        var changed=packet.data;changed[180]^=1
        XCTAssertNil(BoundCooperativePacket(data:changed))
        changed=packet.data;changed[141]=1
        XCTAssertNil(BoundCooperativePacket(data:changed))
        changed=packet.data;changed[143]=0
        XCTAssertNil(BoundCooperativePacket(data:changed))
        changed=packet.data;changed.append(0)
        XCTAssertNil(BoundCooperativePacket(data:changed))
        XCTAssertNil(BoundCooperativePacket(data:Data(repeating:0,count:1025)))
    }
    func testHostAdmissionKeepsTotalOwnerCountSeparateFromSelectedCount() throws {
        let owner=try XCTUnwrap(BoundCooperativeSnapshot(snapshot(count:6,selected:3,order:[6,2,1])))
        let partner=try XCTUnwrap(BoundCooperativeSnapshot(snapshot(count:4,selected:1,order:[4,0,0])))
        let team=BoundCooperativePacket(kind:.team,local:UUID(),peer:UUID(),id:UUID(),peerID:UUID(),snapshot:partner,payload:partner.party)
        let proof=Data(repeating:0xA5,count:32),enemy=Data(repeating:0x77,count:600)
        let host=BoundCooperativeHost.transaction(sequence:12,flags:3,role:0,capture:owner,peerTeam:team,proof:proof,enemy:enemy,xp:Data())
        XCTAssertEqual(host.count,16384)
        XCTAssertEqual(host[51],6) // Native H->ownCount is the full original party.
        XCTAssertEqual(host[44],4);XCTAssertEqual(host[115],1)
        XCTAssertEqual(host.subdata(in:48..<51),Data([4,0,0]))
        XCTAssertEqual(host.subdata(in:112..<115),Data([6,2,1]))
        XCTAssertEqual(host[116],9) // Fresh local admission echoed independently.
        XCTAssertEqual(host.subdata(in:128..<728),partner.party)
        XCTAssertEqual(host.subdata(in:1024..<1624),enemy)
        XCTAssertEqual(host.subdata(in:80..<112),proof)
    }
    func testRaidAgreementAllowsNativeDenSeedButRequiresMatchingFacilityAndCatchRules() throws {
        var bytes=snapshot();bytes[1336]=2;bytes[1356]=1
        let raid=try XCTUnwrap(BoundCooperativeSnapshot(bytes))
        var other=raid.encounterContext;other[16]=127;other[18]=6;other[19]=80
        XCTAssertTrue(raid.hasCompatibleRules(other))
        other[21]=1;XCTAssertFalse(raid.hasCompatibleRules(other))
        other=raid.encounterContext;other[4]=6;XCTAssertFalse(raid.hasCompatibleRules(other))
        other=raid.encounterContext;other[0]=1;XCTAssertFalse(raid.hasCompatibleRules(other))
        XCTAssertFalse(raid.hasCompatibleRules(Data()))
        let packet=BoundCooperativePacket(kind:.context,local:UUID(),peer:UUID(),id:UUID(),peerID:UUID(),snapshot:raid,payload:raid.encounterContext)
        XCTAssertEqual(packet.data.count,212);XCTAssertEqual(try XCTUnwrap(BoundCooperativePacket(data:packet.data)).payload,raid.encounterContext)
        XCTAssertNil(BoundCooperativePacket(data:packet.data.dropLast()))
        let team=BoundCooperativePacket(kind:.team,local:UUID(),peer:UUID(),id:UUID(),peerID:UUID(),snapshot:raid,payload:raid.party)
        other=raid.encounterContext;other[16]=127
        let host=BoundCooperativeHost.transaction(sequence:8,flags:3,role:1,capture:raid,peerTeam:team,proof:Data(repeating:1,count:32),enemy:raid.enemy,xp:Data(),enemyContext:other)
        XCTAssertEqual(host.subdata(in:728..<792),other)
    }
    func testLocalRaidCatchRecoveryCannotReplaySharedCombatOrAdmission() throws {
        var bytes=snapshot();put(6,&bytes,12);put(6,&bytes,1328);bytes[1336]=2;bytes[1400]=1
        let a=try XCTUnwrap(BoundCooperativeCableCut(localCatch:try XCTUnwrap(BoundCooperativeSnapshot(bytes))))
        put(1,&bytes,20)
        let b=try XCTUnwrap(BoundCooperativeCableCut(localCatch:try XCTUnwrap(BoundCooperativeSnapshot(bytes))))
        XCTAssertTrue(a.isLocalCatch);XCTAssertTrue(a.compatible(with:b));XCTAssertFalse(a.compatible(with:a))
        XCTAssertFalse(a.compatible(with:try XCTUnwrap(BoundCooperativeCableCut(admissionPhase:3))))
        XCTAssertFalse(a.compatible(with:cut(read:0,write:0,consumed:0,role:1,xpPhase:6)))
        bytes[1400]=0;XCTAssertNil(BoundCooperativeCableCut(localCatch:try XCTUnwrap(BoundCooperativeSnapshot(bytes))))
        bytes[1400]=2
        let pending=try XCTUnwrap(BoundCooperativeCableCut(localCatch:try XCTUnwrap(BoundCooperativeSnapshot(bytes))))
        XCTAssertTrue(a.compatible(with:pending),"An acknowledged pre-catch cut can recover alongside a local catch")
        put(9,&bytes,12);put(1,&bytes,16)
        XCTAssertNotNil(BoundCooperativeCableCut(localCatch:try XCTUnwrap(BoundCooperativeSnapshot(bytes))))
        put(7,&bytes,16);XCTAssertNil(BoundCooperativeCableCut(localCatch:try XCTUnwrap(BoundCooperativeSnapshot(bytes))))
        bytes[1400]=3;XCTAssertNil(BoundCooperativeSnapshot(bytes))
        var forged=a.data;forged[6]=1;XCTAssertNil(BoundCooperativeCableCut(data:forged))
    }
    private func cut(read:UInt16,write:UInt16,consumed:UInt16,role:UInt32,generation:UInt16=2,ackGeneration:UInt16?=nil,xpPhase:UInt32=0,xpToken:UInt32=0)->BoundCooperativeCableCut {
        var bytes=Data(repeating:0,count:92);put(0x32545543,&bytes,0)
        for (offset,value) in [(4,generation),(6,read),(8,write),(10,consumed),(12,ackGeneration ?? generation)] {
            bytes[offset]=UInt8(truncatingIfNeeded:value);bytes[offset+1]=UInt8(value >> 8)
        }
        put(xpPhase,&bytes,16);put(xpToken,&bytes,20);put(role,&bytes,24)
        return BoundCooperativeCableCut(data:bytes)!
    }
    func testRecoveryCutRejectsForgottenOrUnproducedNativeCommands() throws {
        let a=cut(read:10,write:10,consumed:22,role:0),b=cut(read:22,write:22,consumed:10,role:1)
        XCTAssertTrue(a.compatible(with:b));XCTAssertTrue(b.compatible(with:a))
        XCTAssertFalse(a.compatible(with:cut(read:22,write:22,consumed:9,role:1)))
        XCTAssertFalse(a.compatible(with:cut(read:22,write:22,consumed:11,role:1)))
        XCTAssertFalse(a.compatible(with:cut(read:22,write:22,consumed:10,role:1,generation:3)))
        XCTAssertFalse(a.compatible(with:cut(read:22,write:22,consumed:10,role:1,ackGeneration:1)))
        XCTAssertFalse(cut(read:10,write:15,consumed:24,role:0).compatible(with:cut(read:22,write:26,consumed:13,role:1)),"Outstanding commands cannot establish a durable common cut")
        XCTAssertTrue(cut(read:10,write:15,consumed:22,role:0).compatible(with:cut(read:22,write:26,consumed:10,role:1)),"Never-sent saved records replay after the agreed consumed prefix")
        XCTAssertTrue(cut(read:0,write:0,consumed:65535,role:0).compatible(with:cut(read:65535,write:65535,consumed:0,role:1)))
        var differentHistory=b.data;differentHistory[60]=1
        XCTAssertFalse(a.compatible(with:try XCTUnwrap(BoundCooperativeCableCut(data:differentHistory))),"Matching wrapped counters cannot authorize a different command history")
    }
    func testRecoveryCutSupportsCompletedOwnedXPAndRejectsInProgressOrDifferentAwards() throws {
        func pair(_ hostPhase:UInt32,_ guestPhase:UInt32,_ hostToken:UInt32,_ guestToken:UInt32)->Bool {
            cut(read:10,write:10,consumed:22,role:0,xpPhase:hostPhase,xpToken:hostToken)
                .compatible(with:cut(read:22,write:22,consumed:10,role:1,xpPhase:guestPhase,xpToken:guestToken))
        }
        XCTAssertTrue(pair(0,0,0,0));XCTAssertTrue(pair(0,4,7,7));XCTAssertTrue(pair(6,6,7,7))
        XCTAssertFalse(pair(0,4,8,7));XCTAssertFalse(pair(0,0,7,7))
        XCTAssertFalse(pair(2,4,7,7));XCTAssertFalse(pair(0,3,7,7));XCTAssertFalse(pair(6,4,7,7))
    }
    func testRecoveryRejectsAcceptedFutureCommandsAndUndrainedNativeOrHostQueues() throws {
        var mailbox=Data(repeating:0,count:1176);put(0x314D4642,&mailbox,0)
        for (at,value) in [(4,10),(6,10),(8,5),(10,5),(14,10),(16,2),(18,2),(20,25),(22,2)] {
            mailbox[at]=UInt8(value);mailbox[at+1]=0
        }
        func host(accepted:Int=25,incoming:Data=Data(),remaining:Int=0,sentThrough:Int=10,ack:Data=Data())->Data {
            try! JSONSerialization.data(withJSONObject:["incoming":incoming.base64EncodedString(),"remaining":remaining,
                "peerGeneration":2,"receivedGeneration":2,"lastAcceptedSequence":accepted,"sentThrough":sentThrough,"pendingAcknowledgement":ack.base64EncodedString(),"sentHistory":Data(repeating:0,count:32).base64EncodedString(),"receivedHistory":Data(repeating:0,count:32).base64EncodedString()])
        }
        XCTAssertTrue(BoundNativeBattleProbe.recoveryIsQuiescent(host(),mailbox:mailbox))
        XCTAssertTrue(BoundNativeBattleProbe.recoveryIsQuiescent(host(ack:Data([2,0,10,0])),mailbox:mailbox),"A duplicate already-applied acknowledgement is harmless")
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(ack:Data([2,0,11,0])),mailbox:mailbox))
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(ack:Data([3,0,10,0])),mailbox:mailbox))
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(accepted:26),mailbox:mailbox),"An accepted future move must not survive an older producing peer checkpoint")
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(incoming:Data(repeating:0,count:20)),mailbox:mailbox))
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(remaining:1),mailbox:mailbox))
        var nativePending=mailbox;nativePending[10]=6
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(),mailbox:nativePending))
        nativePending=mailbox;nativePending[6]=11
        XCTAssertTrue(BoundNativeBattleProbe.recoveryIsQuiescent(host(),mailbox:nativePending),"The saved ring retains never-sent output for one replay")
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(sentThrough:11),mailbox:nativePending),"A sent but unacknowledged record cannot replay against an older peer history")
        nativePending[14]=11
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(),mailbox:nativePending))
        nativePending=mailbox;nativePending[6]=43
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(),mailbox:nativePending),"Cannot replay beyond the bounded native ring")
        nativePending=mailbox;nativePending[14]=9
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(),mailbox:nativePending))
    }
    func testRecoveryBranchRejectsPreResumeHistoryAndKeepsControlEnvelopeBounded() throws {
        let proof=Data(repeating:0xA5,count:32),initial=BoundCooperativeRecoveryBranch.initial(proof:proof)
        let local=UUID(),peer=UUID(),next=BoundCooperativeRecoveryBranch.next(initial,local:local,peer:peer)
        XCTAssertEqual(next,BoundCooperativeRecoveryBranch.next(initial,local:peer,peer:local));XCTAssertNotEqual(initial,next)
        let native=cut(read:10,write:10,consumed:22,role:0)
        XCTAssertFalse(BoundCooperativeRecoveryBranch.accepts(native.data+initial,current:next))
        XCTAssertTrue(BoundCooperativeRecoveryBranch.accepts(native.data+next,current:next))
        let state=try XCTUnwrap(BoundCooperativeSnapshot(snapshot()))
        let packet=BoundCooperativePacket(kind:.recoveryOffer,local:local,peer:peer,id:UUID(),peerID:nil,snapshot:state,proof:proof,payload:native.data+next)
        XCTAssertEqual(packet.data.count,272);XCTAssertNotNil(BoundCooperativePacket(data:packet.data))
        XCTAssertNil(BoundCooperativePacket(data:packet.data.dropLast()))
    }
    func testUnstartedAdmissionRecoveryRequiresBothExactSelectedCheckpoints() throws {
        let admission=try XCTUnwrap(BoundCooperativeCableCut(admissionPhase:3))
        XCTAssertTrue(admission.isAdmission)
        XCTAssertTrue(admission.compatible(with:try XCTUnwrap(BoundCooperativeCableCut(data:admission.data))))
        for phase:UInt32 in [0,1,2,4,5,6,7,8,9] { XCTAssertNil(BoundCooperativeCableCut(admissionPhase:phase)) }
        var active=Data(repeating:0,count:92);put(0x32545543,&active,0)
        let activeCut=try XCTUnwrap(BoundCooperativeCableCut(data:active))
        XCTAssertFalse(admission.compatible(with:activeCut));XCTAssertFalse(activeCut.compatible(with:admission))
        var changed=admission.data;changed[4]=1
        XCTAssertNil(BoundCooperativeCableCut(data:changed))
    }
    @MainActor
    func testRebindingKeepsOldRecoveryAndBothGamesBatteryFences() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let rom=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"BoundDiagnostic",withExtension:"gba"))
        let oldSave=directory.appendingPathComponent("old.sav"),newSave=directory.appendingPathComponent("new.sav")
        let oldCore=try XCTUnwrap(EmulatorCore(game:CooperativeLifecycleGame(fileURL:rom,gameSaveURL:oldSave),options:[.metal:true]))
        let newCore=try XCTUnwrap(EmulatorCore(game:CooperativeLifecycleGame(fileURL:rom,gameSaveURL:newSave),options:[.metal:true]))
        let state=directory.appendingPathComponent(UUID().uuidString+".state"),journal=directory.appendingPathComponent(UUID().uuidString+".json")
        let saved=Data(repeating:0xA5,count:2048),receipt=Data("durable interrupted owner checkpoint".utf8)
        try saved.write(to:state);try receipt.write(to:journal)
        XCTAssertTrue(BoundVBABattleBridge.setCooperativeGameSaveAllowed(false,for:oldSave))
        XCTAssertTrue(BoundVBABattleBridge.setCooperativeGameSaveAllowed(false,for:newSave))
        defer {
            _=BoundVBABattleBridge.setCooperativeGameSaveAllowed(true,for:oldSave)
            _=BoundVBABattleBridge.setCooperativeGameSaveAllowed(true,for:newSave)
        }
        let session=BoundCooperativeDoublesSession(),soul=BoundSoulProbe()
        session.bind(core:oldCore,gameID:UUID().uuidString,soul:soul)
        var active=snapshot();put(5,&active,12)
        session.qaInterruptedCheckpoint(active,state:state,journal:journal,recovering:true)
        var cancelled=0;session.send={ _ in cancelled+=1;return true }
        session.suspend();session.suspend()
        XCTAssertEqual(cancelled,0,"Repeated disable/stop callbacks must preserve the existing recovery transaction")
        XCTAssertTrue(session.blocksAutoSave)
        session.bind(core:newCore,gameID:UUID().uuidString,soul:soul)
        var idle=snapshot();put(0,&idle,12)
        session.qaCompletedFrame(idle)
        XCTAssertFalse(session.blocksAutoSave)
        XCTAssertEqual(try Data(contentsOf:state),saved)
        XCTAssertEqual(try Data(contentsOf:journal),receipt)
        XCTAssertTrue(BoundVBABattleBridge.qaCooperativeGameSaveBlocked(oldSave))
        XCTAssertTrue(BoundVBABattleBridge.qaCooperativeGameSaveBlocked(newSave))
        session.bind(core:nil,gameID:"",soul:soul)
    }
    @MainActor
    func testRecoveredNativeCoreRespectsGameplayResumePermission() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let rom=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"BoundDiagnostic",withExtension:"gba"))
        let core=try XCTUnwrap(EmulatorCore(game:CooperativeLifecycleGame(fileURL:rom,gameSaveURL:directory.appendingPathComponent("game.sav")),options:[.metal:true]))
        let session=BoundCooperativeDoublesSession(),soul=BoundSoulProbe()
        session.bind(core:core,gameID:UUID().uuidString,soul:soul)
        defer { _=core.stop();session.bind(core:nil,gameID:"",soul:soul) }
        XCTAssertTrue(core.start());XCTAssertTrue(core.pause())
        var permitted=false,requests=0
        session.canResume={ requests+=1;return permitted }
        session.qaResumeRecoveredCore()
        XCTAssertEqual(requests,1);XCTAssertEqual(core.state,.paused)
        permitted=true
        session.qaResumeRecoveredCore()
        XCTAssertEqual(requests,2);XCTAssertEqual(core.state,.running)
        XCTAssertTrue(core.pause());permitted=false
        session.qaResumeRecoveredCore()
        XCTAssertEqual(requests,3);XCTAssertEqual(core.state,.paused)
    }
    @MainActor
    func testManualStateControlsRejectMixedPartyAndRecoverySnapshots() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rom=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"BoundDiagnostic",withExtension:"gba"))
        let controller=GameViewController()
        controller.game=CooperativeLifecycleGame(fileURL:rom,gameSaveURL:directory.appendingPathComponent("game.sav"))
        defer { controller.game=nil }
        XCTAssertTrue(controller.boundAllowsManualStateSave)
        XCTAssertTrue(controller.boundPermitsIndependentStateLoad)
        let session=controller.boundCompanionForTesting.sharing.cooperativeDoubles
        for phase:UInt32 in [1,2,3,4,5,6,7,9] {
            var bytes=snapshot();put(phase,&bytes,12)
            session.qaInterruptedCheckpoint(bytes,state:directory.appendingPathComponent("retained.state"),journal:directory.appendingPathComponent("retained.json"))
            XCTAssertFalse(controller.boundAllowsManualStateSave,"Phase \(phase) must not export temporary ownership")
            XCTAssertFalse(controller.boundPermitsIndependentStateLoad,"Phase \(phase) must keep its recovery transaction")
        }
    }
    @MainActor
    func testNativeCommandHistoryDeduplicatesReplayAndDistinguishesPayload() throws {
        let rom=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"BoundDiagnostic",withExtension:"gba"))
        let core=try XCTUnwrap(EmulatorCore(game:CooperativeLifecycleGame(fileURL:rom,gameSaveURL:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".sav")),options:[.metal:true]))
        let probe=BoundNativeBattleProbe();probe.configure(core:core)
        var command=Data(repeating:0,count:16);command[0]=0x22;command[1]=0x22
        let packet=try XCTUnwrap(BoundNativeCommandPacket.encode(command,generation:2,sequence:1))
        XCTAssertTrue(probe.receiveNetworkPacket(packet))
        let first=try XCTUnwrap(BoundNativeBattleProbe.recoveryHistories(probe.recoveryData()))
        XCTAssertTrue(probe.receiveNetworkPacket(packet))
        XCTAssertEqual(first.1,try XCTUnwrap(BoundNativeBattleProbe.recoveryHistories(probe.recoveryData())).1)
        command[15]=7
        let other=BoundNativeBattleProbe();other.configure(core:core)
        XCTAssertTrue(other.receiveNetworkPacket(try XCTUnwrap(BoundNativeCommandPacket.encode(command,generation:2,sequence:1))))
        XCTAssertNotEqual(first.1,try XCTUnwrap(BoundNativeBattleProbe.recoveryHistories(other.recoveryData())).1)
    }
    func testNativeBlockContinuationAdmissionSurvivesCheckpoint() throws {
        var admission=BoundNativeBlockAdmission()
        var header=Data(repeating:0,count:16);header[0]=0xBB;header[1]=0xBB;header[2]=28
        XCTAssertTrue(admission.accept(header));XCTAssertEqual(admission.recoveryRemaining,2)
        var recovered=try XCTUnwrap(BoundNativeBlockAdmission(recoveryRemaining:admission.recoveryRemaining))
        var continuation=Data(repeating:0,count:16);continuation[0]=0x88;continuation[1]=0x88
        XCTAssertTrue(recovered.accept(continuation));XCTAssertTrue(recovered.accept(continuation))
        XCTAssertFalse(recovered.accept(continuation))
        XCTAssertNil(BoundNativeBlockAdmission(recoveryRemaining:294))
    }
}

// Two-process acceptance uses the real VBA-M core, cooperative session, durable
// journal and native wire. Only the external channel/identities are loopback QA.
private final class DoublesLoopback: @unchecked Sendable {
    let role:String,port:Int
    private let lock=NSLock()
    private var receiver:(@Sendable (Data)->Void)?
    private var channelID=UUID()
    private let http:URLSession
    init(role:String,port:Int) {
        self.role=role;self.port=port
        let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=2;c.timeoutIntervalForResource=3
        http=URLSession(configuration:c)
    }
    func url(_ path:String)->URL { URL(string:"http://127.0.0.1:\(port)\(path)")! }
    func send(_ data:Data,kind:String)->Bool {
        var request=URLRequest(url:url("/packet/\(role)/\(kind)"));request.httpMethod="POST";request.httpBody=data
        let result=DoublesHTTPResult(),semaphore=DispatchSemaphore(value:0)
        http.dataTask(with:request) { _,response,_ in result.success=(response as? HTTPURLResponse)?.statusCode==200;semaphore.signal() }.resume()
        return semaphore.wait(timeout:.now()+3) == .success && result.success
    }
    func open(_ receiver:@escaping @Sendable (Data)->Void)->any BoundBattleChannel {
        let id=UUID();lock.lock();channelID=id;self.receiver=receiver;lock.unlock()
        return DoublesLoopbackChannel(relay:self,id:id)
    }
    func close(_ id:UUID) { lock.lock();if channelID==id { receiver=nil };lock.unlock() }
    @MainActor func poll(session:BoundCooperativeDoublesSession,report:[String:Any]) async throws -> String {
        var request=URLRequest(url:url("/poll/\(role)"));request.httpMethod="POST";request.httpBody=try JSONSerialization.data(withJSONObject:report)
        let (bytes,response)=try await http.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode==200,let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],let stage=object["stage"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        for row in object["packets"] as? [[String:String]] ?? [] {
            guard let encoded=row["data"],let data=Data(base64Encoded:encoded) else { continue }
            if row["kind"]=="control" { session.receive(data) }
            else { deliver(data) }
        }
        return stage
    }
    private func deliver(_ data:Data) { lock.lock();let target=receiver;lock.unlock();target?(data) }
}
private final class DoublesHTTPResult:@unchecked Sendable { var success=false }
private final class DoublesLoopbackChannel:BoundBattleChannel,@unchecked Sendable {
    let relay:DoublesLoopback,id:UUID
    init(relay:DoublesLoopback,id:UUID){self.relay=relay;self.id=id}
    func send(_ data:Data)->Bool { relay.send(data,kind:"native") }
    func close(){relay.close(id)}
}
private final class DoublesReconnectDriver:@unchecked Sendable {
    private let lock=NSLock()
    private var ticks=0,keys=[Int](),last=0,pilot=false,catchAllowed=false,boot=true,confirm=false,admitting=false
    private var switchKey=0
    private var admissionMenuFrame:Int?,admissionSelected=false
    private var pending:(Int,Int,Int)?,applied = -1
    private var values=[String:Any]()
    func booted(){lock.lock();boot=false;lock.unlock()}
    func fixture(_ stage:Int,encounter:Int,role:Int){lock.lock();pending=(stage,encounter,role);admitting=encounter != 0 && stage==(encounter==1 ? 3:2);lock.unlock()}
    func press(_ key:Int){lock.lock();keys += Array(repeating:key,count:8)+Array(repeating:0,count:60);lock.unlock()}
    func finishSelection(){lock.lock();confirm=true;lock.unlock()}
    func play(_ active:Bool,catching:Bool=false){lock.lock();pilot=active;catchAllowed=catching;lock.unlock()}
    func read()->(Int,Int,[String:Any]){lock.lock();defer{lock.unlock()};return(ticks,applied,values)}
    func receive(_ core:EmulatorCore,probe:BoundCooperativeProbe,cable:BoundNativeBattleProbe) {
        cable.receive(core);probe.receive(core)
        let native=BoundVBABattleBridge.qaCooperativeStatus(),snapshot=probe.read().0
        lock.lock();ticks+=1;values=native
        if let (stage,encounter,role)=pending,BoundVBABattleBridge.qaPrepareCooperativeFixture(UInt(stage),encounter:UInt(encounter),player:UInt(role)) {applied=stage;pending=nil}
        if (snapshot?.phase ?? 0)>0 {admitting=false}
        if admitting,snapshot?.phase==0,native["menu"] as? Int==4,!admissionSelected {
            if admissionMenuFrame==nil {admissionMenuFrame=ticks}
            if ticks-(admissionMenuFrame ?? ticks)>180 {
                admissionSelected=true
                for key in [1,1,16,1,1,32,128,1,1,8,1] {keys += Array(repeating:key,count:8)+Array(repeating:0,count:60)}
            }
        }
        if native["callback"] as? Int==0x080565B5,native["script"] as? Int==0,native["locked"] as? Int==0,
           [1,7].contains(native["outcome"] as? Int ?? 0) {pilot=false}
        var key=0
        if boot {key=(1300..<1302).contains(ticks) ? 8 : (1600..<1602).contains(ticks)||(2200..<2202).contains(ticks) ? 1:0}
        else if !keys.isEmpty {key=keys.removeFirst()}
        else if admitting,snapshot?.phase==0,(native["menu"] as? Int != 4 || admissionSelected),ticks%30<4 {key=1}
        else if confirm,snapshot?.phase==2,ticks%68<8 {key=1}
        else if pilot,snapshot?.phase==5,native["callback"] as? Int==0x0811EBA1,native["menu"] as? Int==1,
                [22,56].contains(native["ownCommand"] as? Int ?? 0) {
            let allowed=native["allowed"] as? Int ?? 0,slot=native["slot"] as? Int ?? 0
            if ticks%30==0 {switchKey=allowed==0 ? 0:(allowed & (1<<slot)==0 ? 128:1)}
            if ticks%30<4 {key=switchKey}
        }
        else if pilot {
            let local=snapshot?.localStage==1 && snapshot?.encounterContext.first==2
            if !local || catchAllowed {
                if ticks%30<4 {key=1}
                if local,native["callback"] as? Int != 0x08011101,(native["bag"] as? Int ?? 0)>0,(native["pocket"] as? Int ?? 0) != 2,ticks%30<4 {key=16}
                if local,native["outcome"] as? Int==7,ticks%30<4 {key=2}
            }
        }
        let previous=last;last=key;lock.unlock()
        for bit in [1,2,8,16,32,64,128] where (key&bit) != (previous&bit) {
            if key&bit != 0 {core.deltaCore.emulatorBridge.activateInput(bit,value:1,playerIndex:0)}
            else {core.deltaCore.emulatorBridge.deactivateInput(bit,playerIndex:0)}
        }
    }
}

@MainActor
final class CooperativeDoublesReconnectTests:XCTestCase {
    func testTwoAppsDisconnectRejoinAndReloadNativeBattles() async throws {
        let env=ProcessInfo.processInfo.environment
        guard let role=env["BOUND_DOUBLES_ROLE"],["A","B"].contains(role),let port=env["BOUND_DOUBLES_PORT"].flatMap(Int.init),let kind=env["BOUND_DOUBLES_ENCOUNTER"].flatMap(Int.init),(0...2).contains(kind),let fixture=env["BOUND_DOUBLES_FIXTURES"] else {throw XCTSkip("Run PrototypeTools/test-doubles-reconnect.py with two dedicated QA simulators")}
        let root=URL(fileURLWithPath:fixture,isDirectory:true),rom=root.appendingPathComponent("rrbin-doubles.gba"),seed=root.appendingPathComponent("seed.sav")
        _=try BoundPlayerROMProfile(rom:Data(contentsOf:rom))
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let battery=folder.appendingPathComponent("owner.sav");try Data(contentsOf:seed).write(to:battery)
        let old=UserDefaults.standard.object(forKey:BoundMultiplayerFeatures.key);BoundMultiplayerFeatures.setEnabled(true)
        let local=UUID(uuidString:role=="A" ? "00000000-0000-0000-0000-000000000001":"00000000-0000-0000-0000-000000000002")!,peer=UUID(uuidString:role=="A" ? "00000000-0000-0000-0000-000000000002":"00000000-0000-0000-0000-000000000001")!
        let relay=DoublesLoopback(role:role,port:port),soul=BoundSoulProbe(),gameID=UUID().uuidString
        var session=BoundCooperativeDoublesSession(),core=try XCTUnwrap(EmulatorCore(game:CooperativeLifecycleGame(fileURL:rom,gameSaveURL:battery),options:[.metal:true])),driver=DoublesReconnectDriver()
        var online=true,booting=true,reloads=0,recovered=0,lastStage="",before=[Data](),prepared=false,triggered=false,selectFrame:Int?,history=[String]()
        func configure() {
            session.context={ (local,peer) };session.connected={ online };session.canResume={ online }
            session.changed={ value in history.append(value);if history.count>12 {history.removeFirst()};print("DOUBLES_STATUS "+value) }
            session.send={ relay.send($0,kind:"control") };session.makeChannel={ receive,_ in relay.open(receive) }
            session.bind(core:core,gameID:gameID,soul:soul)
            let current=session.probe,currentCable=session.cable,currentDriver=driver
            if !booting {driver.booted()}
            core.updateHandler={ currentDriver.receive($0,probe:current,cable:currentCable) }
            core.audioManager.isEnabled=false;core.rate=booting ? 8:1
        }
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let oldWindow=scene.windows.first(where:\.isKeyWindow),window=UIWindow(windowScene:scene),owner=UIViewController(),view=GameView()
        window.rootViewController=owner;window.makeKeyAndVisible();view.frame=window.bounds;owner.view.addSubview(view);core.add(view)
        configure()
        defer {
            window.isHidden=true;oldWindow?.makeKeyAndVisible()
            online=false;session.bind(core:nil,gameID:"",soul:soul);_=core.stop()
            _=BoundVBABattleBridge.setCooperativeGameSaveAllowed(true,for:battery)
            UserDefaults.standard.set(old,forKey:BoundMultiplayerFeatures.key)
        }
        XCTAssertTrue(core.start())
        let deadline=ProcessInfo.processInfo.systemUptime+660
        while ProcessInfo.processInfo.systemUptime<deadline {
            let (_,applied,native)=driver.read(),snapshot=session.probe.read().0
            let field=native["callback"] as? Int==0x080565B5 && native["script"] as? Int==0 && native["locked"] as? Int==0
            if booting,field,driver.read().0>2300 {
                booting=false;core.rate=1;driver.booted();driver.fixture(0,encounter:kind,role:role=="A" ? 0:1)
            }
            if !booting,!prepared,applied>=0,field {
                if applied==0 {driver.fixture(1,encounter:kind,role:role=="A" ? 0:1)}
                else if applied==1,kind==1 {driver.fixture(2,encounter:kind,role:role=="A" ? 0:1)}
                else {prepared=true;if let party=native["party"] as? Data {before=(0..<(kind==1 ? 3:6)).map {party.subdata(in:$0*100..<$0*100+8)}}}
            }
            var report:[String:Any]=["history":history,"prepared":prepared,"phase":snapshot?.phase ?? 0,"error":snapshot?.error ?? 0,"localStage":snapshot?.localStage ?? 0,"recovering":session.recoveryPending,"status":session.status,"reloads":reloads,"recovered":recovered,"field":field,"outcome":native["outcome"] as? Int ?? 0,"required":native["required"] as? Int ?? 0,"ownCount":native["ownCount"] as? Int ?? 0,"menu":native["menu"] as? Int ?? 0,"slot":native["slot"] as? Int ?? 0]
            for key in ["hostSeq","hostFlags","hostLease","residentLease","cancelled"] {report[key]=native[key]}
            report["xpPhase"]=snapshot?.xpPhase;report["xpToken"]=snapshot?.xpToken;report["incomingXP"]=session.qaIncomingXPBytes
            for key in ["hostXP","indexes","exec","ownCommand","callback","script","locked","allowed"] {report[key]=native[key]}
            report["enabled"]=BoundMultiplayerFeatures.isEnabled
            if let selection=native["selection"] as? Data {report["selection"]=selection.base64EncodedString()}
            if session.recoveryPending,let cut=session.qaRecoveryCut {report["cut"]=cut.base64EncodedString()}
            else if let snapshot,let cut=BoundCooperativeCableCut(localCatch:snapshot) ?? BoundCooperativeCableCut(mailbox:BoundVBABattleBridge.cooperativeCableSnapshot(),snapshot:snapshot,hostRecovery:session.cable.recoveryData()) {report["cut"]=cut.data.base64EncodedString()}
            let stage=try await relay.poll(session:session,report:report)
            if stage != lastStage {
                if stage.hasPrefix("offline") {online=false;driver.play(false);session.suspend()}
                if stage=="rejoin"||stage=="rejoin-reload"||stage=="catch-rejoin"||stage=="play"||stage=="catch-play" {online=true}
                if stage=="play" {driver.play(true,catching:kind != 1)}
                if stage=="catch-play" {driver.play(true,catching:true)}
                lastStage=stage
            }
            if stage=="start",prepared,!triggered {
                triggered=true;driver.fixture(kind==1 ? 3:2,encounter:kind,role:role=="A" ? 0:1)
            }
            if snapshot?.phase==2,selectFrame==nil {selectFrame=driver.read().0}
            if snapshot?.phase==2,let selectFrame,driver.read().0-selectFrame>180,!session.recoveryPending {
                // Only once: native Enter for each chosen owner, then native OK.
                if !selectionSent {
                    selectionSent=true
                    for key in [1,1,16,1,1,32,128,1,1,8,1] {driver.press(key)}
                    driver.finishSelection()
                }
            }
            if stage=="offline-reload",session.recoveryPending,session.qaRecoveryCut != nil,reloads==0 {
                XCTAssertTrue(BoundVBABattleBridge.qaCooperativeGameSaveBlocked(battery))
                session.bind(core:nil,gameID:"",soul:soul);_=core.stop()
                session=BoundCooperativeDoublesSession();driver=DoublesReconnectDriver()
                core=try XCTUnwrap(EmulatorCore(game:CooperativeLifecycleGame(fileURL:rom,gameSaveURL:battery),options:[.metal:true]))
                core.add(view);XCTAssertTrue(core.start());XCTAssertTrue(core.pause());configure();reloads+=1
                XCTAssertTrue(session.recoveryPending,"Fresh app session must discover the durable native checkpoint")
            }
            if (stage=="rejoin"||stage=="rejoin-reload"),!session.recoveryPending,snapshot?.phase==5 {recovered=stage=="rejoin" ? max(recovered,1):max(recovered,2)}
            if stage=="done" {
                XCTAssertTrue(field);XCTAssertFalse(BoundVBABattleBridge.qaCooperativeGameSaveBlocked(battery));XCTAssertFalse(session.recoveryPending);XCTAssertEqual(reloads,1);XCTAssertGreaterThanOrEqual(recovered,2)
                let party=try XCTUnwrap(native["party"] as? Data),count=try XCTUnwrap(native["count"] as? Int)
                XCTAssertEqual(count,before.count+(kind==1 ? 1:0))
                XCTAssertEqual(before,(0..<before.count).map {party.subdata(in:$0*100..<$0*100+8)})
                XCTAssertEqual(native["outcome"] as? Int,kind==1 ? 7:1)
                return
            }
            if stage=="failed" {XCTFail("Paired reconnect coordinator failed: \(session.status)");return}
            try await Task.sleep(for:.milliseconds(25))
        }
        XCTFail("Timed out: \(session.status)")
    }
    private var selectionSent=false
}
