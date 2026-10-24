import XCTest
import DeltaCore
@testable import Delta

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
    func testRecoveryCutRejectsForgottenOrUnproducedNativeCommands() throws {
        func cut(read:UInt16,write:UInt16,consumed:UInt16,generation:UInt16=2,ackGeneration:UInt16?=nil)->BoundCooperativeCableCut {
            var bytes=Data(repeating:0,count:16);put(0x31545543,&bytes,0)
            for (offset,value) in [(4,generation),(6,read),(8,write),(10,consumed),(12,ackGeneration ?? generation)] {
                bytes[offset]=UInt8(truncatingIfNeeded:value);bytes[offset+1]=UInt8(value >> 8)
            }
            return BoundCooperativeCableCut(data:bytes)!
        }
        let a=cut(read:10,write:15,consumed:24),b=cut(read:22,write:26,consumed:13)
        XCTAssertTrue(a.compatible(with:b));XCTAssertTrue(b.compatible(with:a))
        XCTAssertFalse(a.compatible(with:cut(read:22,write:26,consumed:9))) // Peer forgot data already discarded.
        XCTAssertFalse(a.compatible(with:cut(read:22,write:26,consumed:16))) // Peer consumed data absent from our checkpoint.
        XCTAssertFalse(a.compatible(with:cut(read:22,write:26,consumed:13,generation:3)))
        XCTAssertFalse(a.compatible(with:cut(read:22,write:26,consumed:13,ackGeneration:1)))
        XCTAssertTrue(cut(read:65534,write:2,consumed:0).compatible(with:cut(read:65535,write:2,consumed:1)))
    }
    func testUnstartedAdmissionRecoveryRequiresBothExactSelectedCheckpoints() throws {
        let admission=try XCTUnwrap(BoundCooperativeCableCut(admissionPhase:3))
        XCTAssertTrue(admission.isAdmission)
        XCTAssertTrue(admission.compatible(with:try XCTUnwrap(BoundCooperativeCableCut(data:admission.data))))
        for phase:UInt32 in [0,1,2,4,5,6,7,8,9] { XCTAssertNil(BoundCooperativeCableCut(admissionPhase:phase)) }
        var active=Data(repeating:0,count:16);put(0x31545543,&active,0)
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
        session.qaInterruptedCheckpoint(active,state:state,journal:journal)
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
