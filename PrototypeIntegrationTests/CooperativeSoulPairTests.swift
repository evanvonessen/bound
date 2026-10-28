import Foundation
import XCTest
@testable import Delta

final class CooperativeSoulPairTests: XCTestCase {
    private func identity(_ value: UInt32) -> BoundSoulIdentity { .init(personality: value, trainer: value+100) }
    private func ledger(own: [UInt32], peer: [UInt32]) -> BoundSoulLedger {
        var value=BoundSoulLedger(run:UUID(),binding:String(repeating:"a",count:64))
        for (index,id) in own.enumerated() {
            let native=identity(id)
            value.records.append(.init(identity:native,slot:"area:\(100+index)",name:"Own",eligible:true))
        }
        value.partnerAcquisitions=Set(peer.indices.map{"area:\(100+$0)"})
        value.partnerLinks=Dictionary(uniqueKeysWithValues:peer.enumerated().map { index,id in
            ("area:\(100+index)",BoundSoulLinkPresentation(species:25,personality:id,name:"Peer",area:100+index,ordinal:index+1,trainerID:id+100))
        })
        return value
    }
    func testBothPerspectivesProduceExactlyTheSameFrozenMap() throws {
        let first=try XCTUnwrap(BoundCooperativeSoulPairs.make(ledger:ledger(own:[1,2,3],peer:[4,5,6]),own:[identity(3),identity(1)],peer:[identity(5),identity(4)]))
        let second=try XCTUnwrap(BoundCooperativeSoulPairs.make(ledger:ledger(own:[4,5,6],peer:[1,2,3]),own:[identity(5),identity(4)],peer:[identity(3),identity(1)]))
        XCTAssertEqual(first,second);XCTAssertEqual(first.count,3);XCTAssertEqual(first.data.count,136)
        XCTAssertEqual(BoundCooperativeSoulPairs(data:first.data),first)
    }
    func testMissingOrAmbiguousPeerIdentityCannotReachReady() throws {
        var value=ledger(own:[1],peer:[4])
        value.partnerLinks?["area:100"]?.trainerID=nil
        XCTAssertNil(BoundCooperativeSoulPairs.make(ledger:value,own:[identity(1)],peer:[identity(4)]))
        value=ledger(own:[1,2],peer:[4,4])
        XCTAssertNil(BoundCooperativeSoulPairs.make(ledger:value,own:[identity(1)],peer:[identity(4)]))
    }
    func testActualSelectedIdentityUsesCurrentHatchAliasAndExcludesDeadMon() throws {
        var value=ledger(own:[1],peer:[4])
        value.records[0].aliases.insert(identity(2));value.records[0].currentIdentity=identity(2)
        XCTAssertNil(BoundCooperativeSoulPairs.make(ledger:value,own:[identity(1)],peer:[identity(4)]))
        XCTAssertEqual(BoundCooperativeSoulPairs.make(ledger:value,own:[identity(2)],peer:[identity(4)])?.count,1)
        value.dead=["area:100"]
        XCTAssertNil(BoundCooperativeSoulPairs.make(ledger:value,own:[identity(2)],peer:[identity(4)]))
    }
    func testUncaughtCounterpartStaysAbsentAndNonSoulBattleKeepsEmptyMap() throws {
        var value=ledger(own:[1],peer:[4])
        value.partnerAcquisitions=["area:101"]
        value.partnerLinks=["area:101":.init(species:25,personality:4,name:"Peer",area:101,ordinal:1,trainerID:104)]
        let sparse=try XCTUnwrap(BoundCooperativeSoulPairs.make(ledger:value,own:[identity(1)],peer:[identity(4)]))
        XCTAssertEqual(sparse.count,0);XCTAssertNotEqual(sparse,BoundCooperativeSoulPairs.empty)
        XCTAssertEqual(BoundCooperativeSoulPairs.make(ledger:nil,own:[identity(1)],peer:[identity(4)]),.empty)
    }
    func testMapRejectsDuplicateEndpointsNoncanonicalPaddingAndChangedDigest() throws {
        let pairs=[(identity(1),identity(4)),(identity(2),identity(5))]
        let map=try XCTUnwrap(BoundCooperativeSoulPairs(pairs:pairs,enabled:true))
        XCTAssertNil(BoundCooperativeSoulPairs(pairs:[pairs[0],pairs[0]],enabled:true))
        XCTAssertNil(BoundCooperativeSoulPairs(pairs:[(identity(1),identity(1))],enabled:true))
        XCTAssertNil(BoundCooperativeSoulPairs(pairs:pairs,enabled:false))
        var bad=map.data;bad[8]^=1;XCTAssertNil(BoundCooperativeSoulPairs(data:bad))
        bad=map.data;bad[135]=1;XCTAssertNil(BoundCooperativeSoulPairs(data:bad))
        for length in 0..<map.data.count {XCTAssertNil(BoundCooperativeSoulPairs(data:map.data.prefix(length)))}
        bad=map.data;bad.append(0);XCTAssertNil(BoundCooperativeSoulPairs(data:bad))
    }
    func testSelectedNativeOrdersAreValidatedBeforeIdentitiesAreUsed() throws {
        var party=Data(repeating:0,count:600)
        party.replaceSubrange(0..<8,with:identity(1).bytes);party.replaceSubrange(200..<208,with:identity(3).bytes)
        XCTAssertEqual(BoundCooperativeSoulPairs.selected(party:party,order:Data([3,1,0]),count:2),[identity(3),identity(1)])
        XCTAssertNil(BoundCooperativeSoulPairs.selected(party:party,order:Data([1,1,0]),count:2))
        XCTAssertNil(BoundCooperativeSoulPairs.selected(party:party,order:Data([7,0,0]),count:1))
        XCTAssertNil(BoundCooperativeSoulPairs.selected(party:party,order:Data([1,0,0]),count:4))
    }
    private func snapshot(map:BoundCooperativeSoulPairs,lost:UInt32,phase:UInt32=5,own:UInt32=1)->BoundCooperativeSnapshot {
        var data=Data(repeating:0,count:2048)
        func put(_ value:UInt32,_ offset:Int) {for n in 0..<4 {data[offset+n]=UInt8(truncatingIfNeeded:value>>(8*n))}}
        put(0x31474443,0);data[4]=1;put(2,8);put(phase,12);put(1,64);put(1,68);data[72]=1
        data.replaceSubrange(128..<136,with:identity(own).bytes)
        put(0x31464C53,1336);put(lost,1472)
        data.replaceSubrange(1440..<1472,with:map.data.subdata(in:8..<40))
        var ids=Data()
        for index in 0..<map.count where lost&(1<<index) != 0 {ids.append(map.data.subdata(in:40+16*index..<56+16*index))}
        put(UInt32(ids.count/8),1340);data.replaceSubrange(1344..<1344+ids.count,with:ids)
        return BoundCooperativeSnapshot(data)!
    }
    func testCurrentSnapshotMustMatchFrozenDigestMaskAndExactAcceptedIdentities() throws {
        let map=try XCTUnwrap(BoundCooperativeSoulPairs(pairs:[(identity(1),identity(4))],enabled:true))
        let good=snapshot(map:map,lost:1)
        XCTAssertTrue(map.accepts(good))
        var bytes=good.bytes;bytes[1440]^=1
        XCTAssertFalse(map.accepts(BoundCooperativeSnapshot(bytes)!))
        bytes=good.bytes;bytes[1472]=2
        XCTAssertFalse(map.accepts(BoundCooperativeSnapshot(bytes)!))
        bytes=good.bytes;bytes[1344]^=1
        XCTAssertFalse(map.accepts(BoundCooperativeSnapshot(bytes)!))
        bytes=good.bytes;bytes[1336]=0
        XCTAssertFalse(map.accepts(BoundCooperativeSnapshot(bytes)!))
    }
    func testRecoveryCannotRollBackDurableSelectedOrBoxedPartnerLoss() throws {
        let map=try XCTUnwrap(BoundCooperativeSoulPairs(pairs:[(identity(1),identity(4))],enabled:true))
        var value=ledger(own:[1],peer:[4]);value.dead=["area:100"]
        XCTAssertFalse(map.permitsRecovery(snapshot:snapshot(map:map,lost:0),ledger:value))
        XCTAssertTrue(map.permitsRecovery(snapshot:snapshot(map:map,lost:1),ledger:value))
        XCTAssertFalse(map.permitsRecovery(snapshot:snapshot(map:map,lost:0,phase:3),ledger:value))
        value=ledger(own:[4],peer:[1]);value.dead=["area:100"]
        XCTAssertFalse(map.permitsRecovery(snapshot:snapshot(map:map,lost:0,own:7),ledger:value),"The linked owner can be boxed outside the six native battle records")
        XCTAssertTrue(map.permitsRecovery(snapshot:snapshot(map:map,lost:1,own:7),ledger:value))
        XCTAssertFalse(map.permitsRecovery(snapshot:snapshot(map:map,lost:1),ledger:nil),"An active map needs the permanent journal before recovery")
    }
    func testNormalCooperativeRecoveryDoesNotReinstateAnEndedChallenge() throws {
        let map=BoundCooperativeSoulPairs.empty,checkpoint=snapshot(map:.empty,lost:0)
        var value=ledger(own:[1],peer:[4]);value.dead=["area:100"];value.ended=true
        XCTAssertTrue(map.permitsRecovery(snapshot:checkpoint,ledger:value))
        XCTAssertTrue(map.permitsRecovery(snapshot:checkpoint,ledger:nil))
        value.ended=false
        XCTAssertFalse(map.permitsRecovery(snapshot:checkpoint,ledger:value),"An active challenge cannot adopt an unprotected normal battle")
        value.offering=true
        XCTAssertTrue(map.permitsRecovery(snapshot:checkpoint,ledger:value))
    }
}
