import XCTest
@testable import Delta

@MainActor final class FollowerInteractionTests:XCTestCase {
    func testLetPassVisibilityBridgesFreshnessGapsAndTileBoundaryJitter() {
        var visibility = BoundLetPassVisibility()
        XCTAssertTrue(visibility.update(enabled: true, distance: 2, at: 1))
        XCTAssertTrue(visibility.update(enabled: true, distance: nil, at: 1.2))
        XCTAssertTrue(visibility.update(enabled: true, distance: 3, at: 1.3))
        XCTAssertTrue(visibility.update(enabled: true, distance: 2, at: 1.4))
        XCTAssertTrue(visibility.update(enabled: true, distance: nil, at: 1.8))
        XCTAssertFalse(visibility.update(enabled: true, distance: nil, at: 1.91))
        XCTAssertFalse(visibility.update(enabled: true, distance: 3, at: 2))
        XCTAssertTrue(visibility.update(enabled: true, distance: 2, at: 2.1))
        XCTAssertFalse(visibility.update(enabled: true, distance: 4, at: 2.2))
        XCTAssertTrue(visibility.update(enabled: true, distance: 0, at: 2.3))
        XCTAssertFalse(visibility.update(enabled: false, distance: nil, at: 2.31))
    }
    func testStandingNearbyDoesNotFlickerAcrossRepeatedPacketGaps() {
        var visibility = BoundLetPassVisibility()
        for tick in 0..<600 {
            let distance: Int? = tick % 6 == 0 ? 2 : nil
            XCTAssertTrue(visibility.update(enabled: true, distance: distance, at: Double(tick) * 0.05))
        }
        XCTAssertFalse(visibility.update(enabled: false, distance: nil, at: 30))
        XCTAssertFalse(visibility.update(enabled: true, distance: nil, at: 30.1), "Reconnect needs a fresh nearby sample")
        XCTAssertTrue(visibility.update(enabled: true, distance: 1, at: 30.2))
        XCTAssertFalse(visibility.update(enabled: true, distance: nil, at: 31), "A departed peer must not leave a permanent button")
    }

    func testHiddenLetPassImmediatelyClearsPresentationAndCannotSend() {
        let previous = UserDefaults.standard.object(forKey: BoundLetPassButton.key)
        defer { UserDefaults.standard.set(previous, forKey: BoundLetPassButton.key) }
        UserDefaults.standard.removeObject(forKey: BoundLetPassButton.key)
        XCTAssertTrue(BoundLetPassButton.isShown)
        let session = BoundFollowerInteractionSession()
        var passes = 0
        session.letPass = { passes += 1 }
        session.updateLetPass(available: true, distance: 0, at: 1)
        XCTAssertTrue(session.canLetPass)
        UserDefaults.standard.set(false, forKey: BoundLetPassButton.key)
        session.requestLetPass()
        XCTAssertEqual(passes, 0)
        session.updateLetPass(available: true, distance: 0, at: 1.01)
        XCTAssertFalse(session.canLetPass)
        XCTAssertFalse(session.blocksGameplay)
        UserDefaults.standard.set(true, forKey: BoundLetPassButton.key)
        session.updateLetPass(available: true, distance: 1, at: 2)
        XCTAssertTrue(session.canLetPass)
        session.suspend()
        session.updateLetPass(available: true, distance: nil, at: 2.01)
        XCTAssertFalse(session.canLetPass)
    }
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
        let previous = UserDefaults.standard.object(forKey: BoundLetPassButton.key)
        defer { UserDefaults.standard.set(previous, forKey: BoundLetPassButton.key) }
        UserDefaults.standard.set(true, forKey: BoundLetPassButton.key)
        let session=BoundFollowerInteractionSession();var passes=0,sends=0
        session.letPass={ passes+=1 };session.send={ _ in sends+=1;return true }
        session.requestLetPass();XCTAssertEqual(passes,0)
        session.canLetPass=true;session.requestLetPass();XCTAssertEqual(passes,1);XCTAssertEqual(sends,0)
        XCTAssertFalse(session.blocksGameplay);session.suspend()
    }
}
