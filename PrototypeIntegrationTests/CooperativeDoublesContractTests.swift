import XCTest
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
        func host(accepted:Int=25,incoming:Data=Data(),remaining:Int=0)->Data {
            try! JSONSerialization.data(withJSONObject:["incoming":incoming.base64EncodedString(),"remaining":remaining,
                "peerGeneration":2,"receivedGeneration":2,"lastAcceptedSequence":accepted,"pendingAcknowledgement":"","sentHistory":Data(repeating:0,count:32).base64EncodedString(),"receivedHistory":Data(repeating:0,count:32).base64EncodedString()])
        }
        XCTAssertTrue(BoundNativeBattleProbe.recoveryIsQuiescent(host(),mailbox:mailbox))
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(accepted:26),mailbox:mailbox),"An accepted future move must not survive an older producing peer checkpoint")
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(incoming:Data(repeating:0,count:20)),mailbox:mailbox))
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(remaining:1),mailbox:mailbox))
        var nativePending=mailbox;nativePending[10]=6
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(),mailbox:nativePending))
        nativePending=mailbox;nativePending[6]=11
        XCTAssertFalse(BoundNativeBattleProbe.recoveryIsQuiescent(host(),mailbox:nativePending))
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
