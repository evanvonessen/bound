import XCTest
@testable import Delta

/// Synthetic memory tests cover transaction ordering and failures. The native
/// script/effect comparison lives in NativeBattleRuntimeTests.
@MainActor final class NativeBerryTransactionTests:XCTestCase {
    private var enabled:Any?
    override func setUp(){super.setUp();enabled=UserDefaults.standard.object(forKey:BoundMultiplayerFeatures.key);BoundMultiplayerFeatures.setEnabled(true)}
    override func tearDown(){UserDefaults.standard.set(enabled,forKey:BoundMultiplayerFeatures.key);super.tearDown()}
    @MainActor private final class NativeFixture {
        var state=Data(repeating:0,count:2048),paused=false,starts=0,applies=0
        init(_ personality:UInt8) {
            state[0]=2
            state[100]=personality;state[104]=8;state[119]=2;state[132]=1;state[186]=20;state[188]=20
        }
        var mon:Data {get{state.subdata(in:100..<200)} set{state.replaceSubrange(100..<200,with:newValue)}}
        var world:BoundBerryWorld { .init(pause:{self.paused=true;return true},resume:{self.paused=false},
            capture:{self.state},restore:{self.state=$0;return true},battery:{Data(repeating:0,count:131072)},restoreBattery:{_ in true},
            target:{BoundFollowerInteractionSession.identity(self.mon)==$0 ? self.mon:Data()},
            begin:{_ in self.starts+=1;return true},apply:{after,before in
                guard self.mon==before else{return false};self.applies+=1;self.mon=after;return true
            },close:{}) }
    }
    @MainActor private final class Pair {
        var a=BoundFollowerInteractionSession(),b=BoundFollowerInteractionSession()
        let left=NativeFixture(1),right=NativeFixture(2),first=UUID(),second=UUID(),room=UUID()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("berry-model-"+UUID().uuidString)
        var queue:[(Bool,Data)]=[],history:[(Bool,Data)]=[],drop:Set<BoundFollowerInteractionPacket.Kind>=[]
        var valid=true,donorIsA=true
        init(){configure(a,true);configure(b,false)}
        func position(_ x:Int)->BoundFriendWorldPosition {.init(mapGroup:3,mapNumber:1,elevation:0,x:x,y:4,facing:4)}
        func context(_ isA:Bool)->BoundFollowerInteractionSession.Context {
            .init(localEpoch:isA ? first:second,peerEpoch:isA ? second:first,mapInstance:77,
                actor:position(4),target:position(5),followerID:BoundFollowerInteractionSession.identity(donorIsA ? right.mon:left.mon)!,generation:1)
        }
        func configure(_ session:BoundFollowerInteractionSession,_ isA:Bool){
            session.store = .init(root:root.appendingPathComponent(isA ? "A":"B"))
            session.configureForTesting(gameID:"fixture",cartridge:String(repeating:"a",count:64))
            session.world=(isA ? left:right).world
            session.context={self.valid ? self.context(isA):nil}
            session.receiveContext={self.valid ? self.context(isA):nil}
            session.wireScope={isA ? (self.first,self.second):(self.second,self.first)}
            session.continuationContextProvider={.init(owner:isA ? self.first:self.second,roomID:self.room.uuidString,runID:nil)}
            session.send={self.queue.append((isA,$0));self.history.append((isA,$0));return true}
        }
        func drain(){
            var count=0
            while !queue.isEmpty {
                let (isA,data)=queue.removeFirst();count+=1;precondition(count<200)
                if let p=BoundFollowerInteractionPacket.decode(data),drop.contains(p.kind){continue}
                (isA ? b:a).receive(data)
            }
        }
        func open(){let donor=donorIsA ? a:b;XCTAssertTrue(donor.open());drain();XCTAssertTrue(donor.isPresented)}
        func accept(){
            let donor=donorIsA ? a:b,inventory=donorIsA ? left:right,target=donorIsA ? right:left
            var after=target.mon;after[41]+=70;inventory.state[0]-=1;donor.nativeFinished(consumed:true,mon:after);drain()
        }
        func cleanup(){a.send=nil;b.send=nil;a.context=nil;b.context=nil;a.receiveContext=nil;b.receiveContext=nil;a.wireScope=nil;b.wireScope=nil;a.continuationContextProvider=nil;b.continuationContextProvider=nil;try? FileManager.default.removeItem(at:root)}
    }
    func testNativeResultCommitsBothSidesOnceDespiteRepeatedPackets() throws {
        let p=Pair();defer{p.cleanup()};let donor=p.left.mon,before=p.right.mon
        p.open();XCTAssertFalse(p.a.blocksGameplay,"Native menu owns its ordinary inputs")
        p.accept();XCTAssertEqual(p.left.state[0],1);XCTAssertEqual(p.left.mon,donor)
        XCTAssertNotEqual(p.right.mon,before);XCTAssertFalse(p.a.isActive);XCTAssertFalse(p.b.isActive)
        let final=p.right.mon,history=p.history
        for (isA,bytes) in history {(isA ? p.b:p.a).receive(bytes)};p.drain()
        XCTAssertEqual(p.right.mon,final);XCTAssertEqual(p.left.state[0],1);XCTAssertEqual(p.left.starts,1)
        XCTAssertEqual(p.right.applies,1,"Commit restores the prepared result rather than applying it twice")
        XCTAssertFalse(p.left.paused);XCTAssertFalse(p.right.paused)
        for (_,bytes) in history {XCTAssertLessThanOrEqual(bytes.count,1024);XCTAssertNotNil(BoundFollowerInteractionPacket.decode(bytes))}
    }
    func testEitherPlayerCanFeedOnlyTheOtherPlayersPokemon(){
        for donorIsA in [true,false] {
            let p=Pair();defer{p.cleanup()};p.donorIsA=donorIsA
            let donor=donorIsA ? p.left:p.right,recipient=donorIsA ? p.right:p.left,original=donor.mon
            p.open();p.accept()
            XCTAssertEqual(donor.state[0],1);XCTAssertEqual(recipient.state[0],2)
            XCTAssertEqual(donor.mon,original);XCTAssertEqual(recipient.mon[41],70)
            XCTAssertFalse(p.a.isActive);XCTAssertFalse(p.b.isActive)
        }
    }
    func testDeclineAndMissingBerryNeverConsumeOrAffectEitherParty(){
        for _ in 0..<2 {
            let p=Pair();defer{p.cleanup()};let a=p.left.state,b=p.right.state
            p.open();p.a.nativeFinished(consumed:false,mon:p.right.mon);p.drain()
            XCTAssertEqual(p.left.state,a);XCTAssertEqual(p.right.state,b);XCTAssertFalse(p.a.isActive)
        }
    }
    func testDisconnectBeforeCommitCanRollBackBothPreparedSides(){
        let p=Pair();defer{p.cleanup()};let a=p.left.state,b=p.right.state
        p.open();p.drop=[.ready];p.accept()
        XCTAssertEqual(p.a.record?.phase,.prepared);XCTAssertEqual(p.b.record?.phase,.prepared)
        p.a.dismiss();p.drop=[];p.drain()
        XCTAssertEqual(p.left.state,a);XCTAssertEqual(p.right.state,b)
        XCTAssertFalse(p.left.paused);XCTAssertFalse(p.right.paused)
    }
    func testLostCommitAndAcknowledgementRecoverWithoutLosingOrDuplicatingResult(){
        let p=Pair();defer{p.cleanup()};p.open();p.drop=[.commit];p.accept()
        XCTAssertEqual(p.a.record?.phase,.committed);XCTAssertEqual(p.b.record?.phase,.prepared)
        XCTAssertTrue(p.a.checkpointForContinuation());XCTAssertTrue(p.b.checkpointForContinuation())
        let oldA=p.a,oldB=p.b;oldA.send=nil;oldB.send=nil
        p.a=BoundFollowerInteractionSession();p.b=BoundFollowerInteractionSession();p.configure(p.a,true);p.configure(p.b,false)
        XCTAssertTrue(p.a.restoreContinuationIfAvailable(serverHead:nil));XCTAssertTrue(p.b.restoreContinuationIfAvailable(serverHead:nil))
        p.drop=[.applied];p.a.tick(at:ProcessInfo.processInfo.systemUptime+1);p.drain()
        XCTAssertEqual(p.b.record?.phase,.finished);let result=p.right.mon
        p.drop=[];p.a.tick(at:ProcessInfo.processInfo.systemUptime+2);p.drain()
        XCTAssertEqual(p.a.record?.phase,.finished);XCTAssertEqual(p.left.state[0],1);XCTAssertEqual(p.right.mon,result)
        XCTAssertFalse(p.left.paused);XCTAssertFalse(p.right.paused)
    }
    func testChangedTargetAndRetiredEpochCannotOpenFeeding(){
        let p=Pair();defer{p.cleanup()};XCTAssertTrue(p.a.open());p.valid=false;p.drain()
        XCTAssertEqual(p.left.starts,0);p.a.tick(at:ProcessInfo.processInfo.systemUptime+11)
        XCTAssertFalse(p.a.isActive)
    }
    func testEveryDurableWriteFailureRetriesBeforeAcknowledgingOrResuming(){
        for donor in [true,false] {
            let phases:[BoundBerryContinuation.Phase]=donor ? [.choosing,.prepared,.committed,.finished]:[.evaluating,.prepared,.committed,.finished]
            for phase in phases {
                let p=Pair();defer{p.cleanup()}
                let failing=donor ? p.a:p.b
                var failures=0
                failing.beforePersistForTesting={ value in
                    if value.phase==phase,failures==0 {failures+=1;throw CocoaError(.fileWriteOutOfSpace)}
                }
                XCTAssertTrue(p.a.open());p.drain()
                if phase == .choosing {
                    XCTAssertTrue(p.a.recoveryBlocked);XCTAssertEqual(p.left.starts,0)
                    p.a.tick(at:ProcessInfo.processInfo.systemUptime+1);p.drain()
                }
                XCTAssertTrue(p.a.isPresented);p.accept()
                XCTAssertEqual(failures,1,"Fault must reach \(donor)/\(phase)")
                if phase != .choosing {
                    XCTAssertTrue(failing.recoveryBlocked)
                    XCTAssertTrue((donor ? p.left:p.right).paused)
                    if !donor {XCTAssertNotEqual(p.a.record?.phase,.finished,"No applied ACK may precede durable completion")}
                }
                for step in 2...5 {
                    p.a.tick(at:ProcessInfo.processInfo.systemUptime+Double(step));p.b.tick(at:ProcessInfo.processInfo.systemUptime+Double(step));p.drain()
                }
                XCTAssertEqual(p.a.record?.phase,.finished);XCTAssertEqual(p.b.record?.phase,.finished)
                XCTAssertEqual(p.left.state[0],1);XCTAssertEqual(p.right.mon[41],70)
                XCTAssertEqual(p.left.starts,1);XCTAssertFalse(p.left.paused);XCTAssertFalse(p.right.paused)
            }
        }
    }
    func testLongNativeChoiceRemainsValidAndMovedTargetRefundsBerry(){
        for moved in [false,true] {
            let p=Pair();defer{p.cleanup()};let before=p.left.state,peer=p.right.state
            p.open();p.b.tick(at:ProcessInfo.processInfo.systemUptime+120)
            p.valid = !moved;p.accept()
            if moved {XCTAssertEqual(p.left.state,before);XCTAssertEqual(p.right.state,peer)}
            else {XCTAssertEqual(p.left.state[0],1);XCTAssertEqual(p.right.mon[41],70)}
            XCTAssertFalse(p.left.paused);XCTAssertFalse(p.right.paused)
        }
    }
    func testAbortWriteFailureNeverDiscardsTheRollback(){
        let p=Pair();defer{p.cleanup()};let before=p.left.state
        p.open();var failed=false
        p.a.beforePersistForTesting={value in if value.phase == .aborted,!failed {failed=true;throw CocoaError(.fileWriteOutOfSpace)}}
        p.a.nativeFinished(consumed:false,mon:p.right.mon);p.drain()
        XCTAssertTrue(p.a.recoveryBlocked);XCTAssertFalse(p.a.checkpointForContinuation())
        p.a.tick(at:ProcessInfo.processInfo.systemUptime+1);p.drain()
        XCTAssertEqual(p.left.state,before);XCTAssertFalse(p.left.paused);XCTAssertFalse(p.a.isActive)
    }
    func testFinishedRestoreWaitsForOwnerResumeAndCannotDuplicateOldCommitAfterNextFeed(){
        let p=Pair();defer{p.cleanup()};p.open();p.accept()
        let first=p.history
        p.open();p.accept()
        XCTAssertEqual(p.left.state[0],0);XCTAssertEqual(p.right.mon[41],140)
        for (isA,bytes) in first {(isA ? p.b:p.a).receive(bytes)};p.drain()
        XCTAssertEqual(p.left.state[0],0);XCTAssertEqual(p.right.mon[41],140)
        let old=p.a;old.send=nil
        p.a=BoundFollowerInteractionSession();p.configure(p.a,true)
        var ownerReady=false;p.a.canResume={ownerReady}
        XCTAssertTrue(p.a.restoreContinuationIfAvailable(serverHead:nil));XCTAssertTrue(p.left.paused)
        p.a.tick();XCTAssertTrue(p.left.paused)
        ownerReady=true;p.a.tick();XCTAssertFalse(p.left.paused);XCTAssertFalse(p.a.isActive)
    }
}

@MainActor final class FollowerInteractionTests:XCTestCase {
    func testRetiredLetPassPreferenceCannotEnableBehavior() {
        let previous = UserDefaults.standard.object(forKey: BoundLetPassButton.key)
        defer { UserDefaults.standard.set(previous, forKey: BoundLetPassButton.key) }
        for value in [false, true] {
            UserDefaults.standard.set(value, forKey: BoundLetPassButton.key)
            XCTAssertFalse(BoundLetPassButton.isShown)
        }
    }
    private func position(_ x:Int)->BoundFriendWorldPosition { .init(mapGroup:3,mapNumber:1,elevation:0,x:x,y:4,facing:4) }
    func testNativeBerryProtocolIsBoundedAndRejectsRetiredCosmeticOffers() throws {
        let first=UUID(),second=UUID()
        let anchor=BoundFollowerInteractionSession.Context(localEpoch:first,peerEpoch:second,mapInstance:77,
            actor:position(4),target:position(5),followerID:42,generation:1)
        let packet=BoundFollowerInteractionPacket(sender:first,receiver:second,id:UUID(),kind:.request,followerID:42,anchor:anchor)
        let bytes=try XCTUnwrap(packet.encoded())
        XCTAssertLessThanOrEqual(bytes.count,1024);XCTAssertEqual(BoundFollowerInteractionPacket.decode(bytes),packet)
        XCTAssertNil(BoundFollowerInteractionPacket.decode(bytes+Data([0])))
        XCTAssertNil(BoundFollowerInteractionPacket.decode(Data("BFC1".utf8)+Data(repeating:0,count:96)))
        let bad=BoundFollowerInteractionPacket(sender:first,receiver:first,id:UUID(),kind:.request,followerID:42,anchor:anchor)
        XCTAssertNil(bad.encoded())
    }
}
