import XCTest
@testable import Delta

@MainActor final class FollowerInteractionTests:XCTestCase {
    private func position(_ x:Int)->BoundFriendWorldPosition { .init(mapGroup:3,mapNumber:1,elevation:0,x:x,y:4,facing:4) }
    func testBerryIsBoundedCosmeticAndRejectsReplayChangedLeaderAndStaleEpoch() throws {
        let previous=UserDefaults.standard.object(forKey:BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(previous,forKey:BoundMultiplayerFeatures.key) }
        let a=BoundFollowerInteractionSession(),b=BoundFollowerInteractionSession(),first=UUID(),second=UUID()
        var targetID:UInt64=42,epoch=second,events=[UInt64](),sent=[Data]()
        a.context={ .init(localEpoch:first,peerEpoch:epoch,mapInstance:77,actor:self.position(4),target:self.position(5),followerID:targetID,generation:1) }
        b.receiveContext={ .init(localEpoch:second,peerEpoch:first,mapInstance:77,actor:self.position(4),target:self.position(5),followerID:42,generation:1) }
        a.send={ sent.append($0);b.receive($0);return true };b.onReaction={ events.append($0) }
        XCTAssertTrue(a.open());a.offerBerry();XCTAssertFalse(a.isPresented)
        XCTAssertEqual(sent.count,1);XCTAssertEqual(sent[0].count,100);XCTAssertLessThanOrEqual(sent[0].count,512)
        XCTAssertEqual(events,[42]);b.receive(sent[0]);XCTAssertEqual(events,[42])
        XCTAssertTrue(a.open());targetID=99;a.offerBerry();XCTAssertEqual(sent.count,1,"Changed target closes presentation without sending an action")
        targetID=42;epoch=UUID();XCTAssertTrue(a.open());a.offerBerry();XCTAssertEqual(events,[42],"Freshness epoch mismatch cannot produce a remote reaction")
        var bad=sent[0];bad[5]=1;XCTAssertNil(BoundFollowerInteractionPacket.decode(bad))
        XCTAssertNil(BoundFollowerInteractionPacket.decode(sent[0]+Data([0])))
        a.suspend();b.suspend()
    }
    func testLetPassIsExplicitAndDoesNotEnterBattleOrBerryProtocol() {
        let session=BoundFollowerInteractionSession();var passes=0,sends=0
        session.letPass={ passes+=1 };session.send={ _ in sends+=1;return true }
        session.requestLetPass();XCTAssertEqual(passes,0)
        session.canLetPass=true;session.requestLetPass();XCTAssertEqual(passes,1);XCTAssertEqual(sends,0)
        XCTAssertFalse(session.blocksGameplay);session.suspend()
    }
}
