import Foundation
import XCTest
@testable import Delta

@MainActor
final class BoundWorldMovementTests:XCTestCase {
    @MainActor
    private final class Pair {
        let a=BoundWorldMovementSession(),b=BoundWorldMovementSession()
        let first=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
        let second=UUID(uuidString:"00000000-0000-0000-0000-000000000002")!
        var now:TimeInterval=0,frame:UInt32=0
        var ac=BoundMovementTile(x:0,y:0),ap=BoundMovementTile(x:0,y:0)
        var bc=BoundMovementTile(x:2,y:0),bp=BoundMovementTile(x:2,y:0)
        var ar:BoundMovementStep?,br:BoundMovementStep?,adone:UInt32=0,bdone:UInt32=0
        var ag:UInt32=2,bg:UInt32=2,af:[BoundMovementActor]=[],bf:[BoundMovementActor]=[]
        var aPeer:[BoundMovementActor]?,bPeer:[BoundMovementActor]?
        var queue:[(Bool,Data)]=[],history:[BoundMovementPacket]=[],drop:Set<BoundMovementPacket.Kind>=[]
        init() {
            a.send={[weak self] d in self?.sent(true,d);return true}
            b.send={[weak self] d in self?.sent(false,d);return true}
        }
        func sent(_ fromA:Bool,_ bytes:Data) {
            queue.append((fromA,bytes));if let p=BoundMovementPacket.decode(bytes){history.append(p)}
        }
        func step(_ from:Int,_ to:Int,nonce:UInt32=1,generation:UInt32=2,kind:Int=0)->BoundMovementStep {
            .init(nonce:nonce,generation:generation,instance:9,group:3,number:43,elevation:0,
                  from:.init(x:from,y:0),to:.init(x:to,y:0),kind:kind)
        }
        func actor(_ current:BoundMovementTile,_ previous:BoundMovementTile,kind:Int=0,id:UInt64=0)->BoundMovementActor {
            .init(current:current,previous:previous,elevation:0,kind:kind,identity:id)
        }
        func context(_ fromA:Bool)->BoundWorldMovementSession.Context {
            let ownA=[actor(ac,ap)]+af,ownB=[actor(bc,bp)]+bf
            return .init(local:fromA ? first:second,peer:fromA ? second:first,instance:9,group:3,number:43,elevation:0,
                own:fromA ? ownA:ownB,other:fromA ? (aPeer ?? ownB):(bPeer ?? ownA))
        }
        func snapshot(_ fromA:Bool,frame override:UInt32?=nil,sequence:UInt32?=nil)->BoundMovementSnapshot {
            var data=Data(repeating:0,count:256);let put=BoundMovementSnapshot.put
            let request=fromA ? ar:br,generation=fromA ? ag:bg,at=override ?? frame
            put(0x314F5742,&data,0);put(1,&data,4);put(sequence ?? (at*2+2),&data,8);put(at,&data,12)
            put(generation,&data,16);put(request==nil ? 7:15,&data,20)
            data[32]=3;data[33]=43;data[35]=2
            BoundMovementSnapshot.putTile(fromA ? ac:bc,&data,36);BoundMovementSnapshot.putTile(fromA ? ap:bp,&data,40)
            if let request {
                put(request.nonce,&data,52);BoundMovementSnapshot.putTile(request.from,&data,56)
                BoundMovementSnapshot.putTile(request.to,&data,60);data[64]=4;data[67]=UInt8(request.kind);put(at,&data,68)
            }
            put(fromA ? adone:bdone,&data,72);put(9,&data,80)
            return BoundMovementSnapshot(data)!
        }
        func drain() {
            var count=0
            while !queue.isEmpty {
                let (fromA,bytes)=queue.removeFirst();count+=1;precondition(count<1000)
                if let p=BoundMovementPacket.decode(bytes),drop.contains(p.kind){continue}
                (fromA ? b:a).receive(bytes,at:now)
            }
        }
        func tick(_ delta:TimeInterval=0.05,deliver:Bool=true) {
            now+=delta;frame+=1;a.update(context(true),native:snapshot(true),at:now)
            b.update(context(false),native:snapshot(false),at:now);if deliver {drain()}
        }
        func ticks(_ count:Int) {for _ in 0..<count {tick()}}
        func connect() {ticks(5);XCTAssertFalse(a.reconnecting);XCTAssertFalse(b.reconnecting)}
        func permit(_ session:BoundWorldMovementSession)->UInt32 {
            session.probe.hostInput().map{BoundMovementSnapshot.word($0,72)} ?? 0
        }
        func grantB() {br=step(2,1);ticks(6);XCTAssertEqual(permit(b),1)}
    }

    func testPendingCollisionSurvivesInterveningNativeFrameWithoutAuthorizingStaleStep() {
        let pair=Pair();pair.ar=pair.step(0,1)
        var bytes=pair.snapshot(true).bytes
        BoundMovementSnapshot.put(7,&bytes,20)
        XCTAssertEqual(BoundMovementSnapshot(bytes)?.request,pair.ar)
        var stale=bytes;BoundMovementSnapshot.put(13,&stale,12)
        XCTAssertNil(BoundMovementSnapshot(stale)?.request)
        var completed=bytes;BoundMovementSnapshot.put(1,&completed,72)
        XCTAssertNil(BoundMovementSnapshot(completed)?.request)
        var moved=bytes;BoundMovementSnapshot.putTile(.init(x:1,y:0),&moved,36)
        XCTAssertNil(BoundMovementSnapshot(moved)?.request)
        var blocked=bytes;BoundMovementSnapshot.put(23,&blocked,20)
        XCTAssertNil(BoundMovementSnapshot(blocked)?.request)
    }

    func testSnapshotRejectsUncommittedAndWrongEnvelope() {
        let pair=Pair(),value=pair.snapshot(true)
        var bytes=value.bytes;BoundMovementSnapshot.put(3,&bytes,8);XCTAssertNil(BoundMovementSnapshot(bytes))
        bytes=value.bytes;bytes[0]^=1;XCTAssertNil(BoundMovementSnapshot(bytes))
        XCTAssertNil(BoundMovementSnapshot(value.bytes.dropLast()))
    }
    func testHandshakeRequiresFreshChannelEchoBeforeAuthority() {
        let pair=Pair();pair.tick(deliver:false)
        XCTAssertTrue(pair.a.reconnecting);XCTAssertNil(pair.a.probe.hostInput())
        pair.drain();pair.ticks(2)
        XCTAssertFalse(pair.a.reconnecting);XCTAssertFalse(pair.b.reconnecting)
        XCTAssertEqual(pair.a.probe.hostInput()?.count,1024)
    }
    func testSameTileClaimsNeverGiveBothOwnersPermission() {
        let pair=Pair();pair.connect();pair.ar=pair.step(0,1,nonce:11);pair.br=pair.step(2,1,nonce:12)
        for _ in 0..<8 {pair.tick();XCTAssertFalse(pair.permit(pair.a)>0 && pair.permit(pair.b)>0)}
        XCTAssertTrue(pair.permit(pair.a)>0 || pair.permit(pair.b)>0)
    }
    func testSwapIsBlockedByCurrentAndPreviousOccupancy() {
        let pair=Pair();pair.bc = .init(x:1,y:0);pair.bp=pair.bc;pair.connect()
        pair.ar=pair.step(0,1);pair.br=pair.step(1,0);pair.ticks(6)
        XCTAssertEqual(pair.permit(pair.a),0);XCTAssertEqual(pair.permit(pair.b),0)
    }
    func testOfferDoesNotAuthorizeNativeUntilAcceptedCommitArrives() {
        let pair=Pair();pair.connect();pair.drop=[.grant];pair.br=pair.step(2,1);pair.ticks(5)
        XCTAssertTrue(pair.history.contains{$0.kind == .accept});XCTAssertEqual(pair.permit(pair.b),0)
        pair.drop=[];pair.ticks(3);XCTAssertEqual(pair.permit(pair.b),1)
    }
    func testLostGrantExpiresAndRetriesWithoutTrappingHeldDirection() {
        let pair=Pair();pair.connect();pair.drop=[.grant];pair.br=pair.step(2,1);pair.ticks(23)
        XCTAssertEqual(pair.permit(pair.b),0)
        let requests=pair.history.filter{$0.kind == .request};XCTAssertGreaterThan(Set(requests.map(\.token)).count,1)
        pair.drop=[];pair.ticks(8);XCTAssertEqual(pair.permit(pair.b),1)
    }
    func testDelayedOfferAndCommitCannotRefreshExpiredAttempt() {
        let pair=Pair();pair.connect();pair.drop=[.grant];pair.br=pair.step(2,1);pair.ticks(4)
        let old=pair.history.last{$0.kind == .grant}!
        pair.ticks(20);pair.b.receive(old.encoded()!,at:pair.now);pair.tick()
        XCTAssertEqual(pair.permit(pair.b),0)
        pair.drop=[];pair.ticks(6);XCTAssertEqual(pair.permit(pair.b),1)
    }
    func testOneMissingPendingFrameDoesNotReleaseCommittedFootprint() {
        let pair=Pair();pair.connect();pair.grantB();pair.br=nil;pair.ar=pair.step(0,1,nonce:11)
        pair.ticks(3);XCTAssertEqual(pair.permit(pair.a),0)
    }
    func testInFlightReservationSurvivesPermissionDeadlineUntilExactCompletion() {
        let pair=Pair();pair.connect();pair.grantB()
        pair.bc = .init(x:1,y:0);pair.bp = .init(x:2,y:0);pair.br=nil
        pair.aPeer=[pair.actor(.init(x:2,y:0),.init(x:2,y:0))]
        pair.ar=pair.step(0,1,nonce:11);pair.ticks(24)
        XCTAssertEqual(pair.permit(pair.a),0)
        pair.bp=pair.bc;pair.bdone=1;pair.tick();XCTAssertEqual(pair.permit(pair.a),0)
        pair.ticks(4);XCTAssertEqual(pair.permit(pair.a),11)
    }
    func testFollowerFootprintChangesBlockThenAllowSamePendingDirection() {
        let pair=Pair();pair.connect()
        pair.af=[pair.actor(.init(x:1,y:0),.init(x:1,y:0),kind:1,id:99)]
        pair.br=pair.step(2,1);pair.ticks(5);XCTAssertEqual(pair.permit(pair.b),0)
        pair.af=[];pair.ticks(4);XCTAssertEqual(pair.permit(pair.b),1)
    }
    func testExistingOverlapPublishesBothFootprintsWithoutMovingOrSnapping() {
        let pair=Pair();pair.bc=pair.ac;pair.bp=pair.ap;pair.connect();pair.ar=pair.step(0,-1)
        pair.ticks(3);let host=pair.a.probe.hostInput()!
        XCTAssertEqual(BoundMovementSnapshot.word(host,68),1)
        XCTAssertEqual(BoundMovementSnapshot.tile(host,132),pair.bc)
        XCTAssertEqual(pair.ac,.init(x:0,y:0));XCTAssertEqual(pair.bc,.init(x:0,y:0))
    }
    func testStaleControlStreamRevokesAuthorityWhilePresenceRemainsFresh() {
        let pair=Pair();pair.connect();pair.grantB();pair.drop=[.hello,.heartbeat,.request,.offer,.accept,.grant,.started,.release,.released,.cancel,.cancelled]
        pair.ticks(9);XCTAssertTrue(pair.a.reconnecting);XCTAssertTrue(pair.b.reconnecting)
        XCTAssertNil(pair.a.probe.hostInput());XCTAssertNil(pair.b.probe.hostInput())
        pair.drop=[];pair.ticks(6);XCTAssertFalse(pair.a.reconnecting);XCTAssertFalse(pair.b.reconnecting)
    }
    func testRawStateFrameOrSequenceRollbackRotatesChannel() {
        let pair=Pair();pair.connect();pair.grantB()
        let old=pair.history.last{$0.kind == .grant}!
        pair.b.update(pair.context(false),native:pair.snapshot(false,frame:1),at:pair.now)
        XCTAssertTrue(pair.b.reconnecting);XCTAssertNil(pair.b.probe.hostInput())
        pair.b.receive(old.encoded()!,at:pair.now);XCTAssertNil(pair.b.probe.hostInput())
        pair.ticks(5);XCTAssertFalse(pair.b.reconnecting)
        pair.b.update(pair.context(false),native:pair.snapshot(false,sequence:2),at:pair.now)
        XCTAssertTrue(pair.b.reconnecting);XCTAssertNil(pair.b.probe.hostInput())
    }
    func testGenerationChangeAndOwnerCancellationFenceDelayedGrants() {
        let pair=Pair();pair.connect();pair.grantB();let old=pair.history.last{$0.kind == .grant}!
        pair.bg=3;pair.br=pair.step(2,1,nonce:1,generation:3);pair.tick()
        pair.b.receive(old.encoded()!,at:pair.now);XCTAssertEqual(pair.permit(pair.b),0)
        pair.ticks(5);XCTAssertFalse(pair.b.reconnecting)
    }
    func testLetPassRequiresAcknowledgementAndRetriesLostAcknowledgement() {
        let pair=Pair();pair.connect();pair.drop=[.passAck];pair.a.letPass(at:pair.now);pair.drain();pair.ticks(3)
        XCTAssertFalse(pair.a.passing);XCTAssertFalse(pair.b.passing)
        pair.drop=[];pair.ticks(3);XCTAssertTrue(pair.a.passing);XCTAssertTrue(pair.b.passing)
        pair.tick();XCTAssertEqual(BoundMovementSnapshot.word(pair.a.probe.hostInput()!,68),0)
        XCTAssertEqual(BoundMovementSnapshot.word(pair.b.probe.hostInput()!,68),0)
        pair.ticks(45);XCTAssertFalse(pair.a.passing);XCTAssertFalse(pair.b.passing)
    }
    func testSimultaneousLetPassConvergesWithoutRenewingTwoSecondWindow() {
        let pair=Pair();pair.connect();pair.a.letPass(at:pair.now);pair.b.letPass(at:pair.now);pair.drain();pair.ticks(3)
        XCTAssertTrue(pair.a.passing);XCTAssertTrue(pair.b.passing)
        let old=pair.history.last{$0.kind == .passCommit}!
        pair.ticks(45);pair.b.receive(old.encoded()!,at:pair.now);pair.tick()
        XCTAssertFalse(pair.a.passing);XCTAssertFalse(pair.b.passing)
    }
    func testArbiterNeverRenewsOffersAndNeverExpiresCommittedMovement() {
        var arbiter=BoundMovementArbiter();let pair=Pair(),step=pair.step(2,1)
        let key=BoundMovementArbiter.Key(owner:pair.second,token:1)
        XCTAssertTrue(arbiter.offer(key,step:step,at:0));XCTAssertTrue(arbiter.offer(key,step:step,at:0.7))
        XCTAssertFalse(arbiter.commit(key,step:step,at:0.81));XCTAssertTrue(arbiter.isRetired(key))
        let fresh=BoundMovementArbiter.Key(owner:pair.second,token:2)
        XCTAssertTrue(arbiter.offer(fresh,step:step,at:1));XCTAssertTrue(arbiter.commit(fresh,step:step,at:1.1))
        arbiter.expire(at:100);XCTAssertEqual(arbiter.leases.count,1)
        arbiter.finish(fresh,step:step,at:100);arbiter.expire(at:100.09);XCTAssertEqual(arbiter.leases.count,1)
        arbiter.finish(fresh,step:step,at:100.09)
        arbiter.expire(at:100.11);XCTAssertTrue(arbiter.leases.isEmpty)
    }
    func testProbeRenewsOnlyFrameSequenceAndExpiresOnRealTimeStall() {
        var now:TimeInterval=10;let probe=BoundMovementProbe(clock:{now})
        let host=Data(repeating:0,count:1024);probe.publish(host)
        var first=probe.frameInput(at:10.01)!,second=probe.frameInput(at:10.02)!
        XCTAssertNotEqual(BoundMovementSnapshot.word(first,8),BoundMovementSnapshot.word(second,8))
        BoundMovementSnapshot.put(0,&first,8);BoundMovementSnapshot.put(0,&second,8)
        XCTAssertEqual(first,host);XCTAssertEqual(second,host)
        XCTAssertEqual(probe.frameInput(at:10.151)?.count,0)
        now=10.2;probe.publish(host);XCTAssertEqual(probe.frameInput(at:10.21)?.count,1024)
        probe.publish(nil);XCTAssertEqual(probe.frameInput(at:10.22)?.count,0)
    }
    func testMovementTrafficStaysBelowNativeRelayBudget() {
        let pair=Pair();pair.connect();pair.br=pair.step(2,1);let before=pair.history.count
        for _ in 0..<100 {pair.tick(0.01)}
        let sent=Array(pair.history.dropFirst(before))
        XCTAssertLessThanOrEqual(sent.filter{$0.sender==pair.first}.count,50)
        XCTAssertLessThanOrEqual(sent.filter{$0.sender==pair.second}.count,50)
        XCTAssertTrue(sent.allSatisfy{($0.encoded()?.count ?? 1000)<=768})
    }
    func testProbeLatchesRollbackEvenWhenFramesCatchUpBeforeCoordinatorPoll() {
        let pair=Pair(),probe=pair.b.probe
        probe.record(pair.snapshot(false,frame:100,sequence:202))
        let before=probe.epoch();probe.publish(Data(repeating:0,count:1024))
        probe.record(pair.snapshot(false,frame:10,sequence:22))
        probe.record(pair.snapshot(false,frame:101,sequence:204))
        XCTAssertNotEqual(probe.epoch(),before);XCTAssertNil(probe.hostInput())
    }
    func testNativeCounterWrapDoesNotRevokeOtherwiseFreshProbe() {
        let pair=Pair(),probe=BoundMovementProbe(clock:{0})
        probe.record(pair.snapshot(false,frame:UInt32.max-1,sequence:UInt32.max-1))
        let epoch=probe.epoch();probe.publish(Data(repeating:0,count:1024))
        probe.record(pair.snapshot(false,frame:2,sequence:2))
        XCTAssertEqual(probe.epoch(),epoch);XCTAssertEqual(probe.hostInput()?.count,1024)
    }
    func testLostCancellationAcknowledgementRetriesBeforeNewOwnerToken() {
        let pair=Pair();pair.connect();pair.grantB();pair.drop=[.cancelled]
        pair.br=pair.step(2,1,nonce:2);pair.ticks(5)
        XCTAssertEqual(pair.permit(pair.b),0)
        XCTAssertGreaterThan(pair.history.filter{$0.kind == .cancel}.count,1)
        pair.drop=[];pair.ticks(8);XCTAssertEqual(pair.permit(pair.b),2)
    }
    func testNoNativeRequestProducesNoMovementPredictionOrPermit() {
        let pair=Pair();pair.connect();let count=pair.history.count;pair.ticks(10)
        XCTAssertFalse(pair.history.dropFirst(count).contains{[BoundMovementPacket.Kind.request,.offer,.grant].contains($0.kind)})
        XCTAssertEqual(pair.permit(pair.a),0);XCTAssertEqual(pair.permit(pair.b),0)
        XCTAssertEqual(pair.ac,.init(x:0,y:0));XCTAssertEqual(pair.bc,.init(x:2,y:0))
    }
    func testPacketDecoderBoundsIdentityScopeAndPayload() {
        let pair=Pair();pair.connect();pair.grantB();let old=pair.history.last{$0.kind == .grant}!
        XCTAssertEqual(BoundMovementPacket.decode(old.encoded()!),old)
        let invalid=BoundMovementPacket(sender:old.sender,receiver:old.sender,channel:old.channel,acknowledgedChannel:old.acknowledgedChannel,
            sequence:old.sequence,instance:old.instance,generation:old.generation,group:old.group,number:old.number,elevation:old.elevation,
            kind:old.kind,token:old.token,step:old.step)
        XCTAssertNil(invalid.encoded());XCTAssertNil(BoundMovementPacket.decode(Data(repeating:0,count:769)))
    }
    func testOnlyNativeCardinalLedgeKindAllowsTwoTileRequest() {
        let pair=Pair()
        XCTAssertFalse(pair.step(0,2).valid);XCTAssertTrue(pair.step(0,2,kind:1).valid)
        XCTAssertFalse(pair.step(0,1,kind:1).valid);XCTAssertFalse(pair.step(0,3,kind:1).valid)
        let diagonal=BoundMovementStep(nonce:1,generation:2,instance:9,group:3,number:43,elevation:0,
            from:.init(x:0,y:0),to:.init(x:1,y:1),kind:1)
        XCTAssertFalse(diagonal.valid)
        pair.br=pair.step(2,0,kind:1)
        XCTAssertEqual(pair.snapshot(false).request?.kind,1)
        var wrong=pair.snapshot(false).bytes;wrong[67]=2;XCTAssertNil(BoundMovementSnapshot(wrong)?.request)
    }
    func testLedgeSegmentsConflictAtMidpointAndOpposingPath() {
        let pair=Pair(),jump=pair.step(0,2,kind:1)
        let across=BoundMovementStep(nonce:2,generation:2,instance:9,group:3,number:43,elevation:0,
            from:.init(x:1,y:-1),to:.init(x:1,y:0))
        XCTAssertTrue(jump.conflicts(across));XCTAssertTrue(across.conflicts(jump))
        XCTAssertTrue(jump.conflicts(pair.step(2,0,kind:1)))
        XCTAssertTrue(jump.conflicts(pair.step(1,0)))
        XCTAssertFalse(jump.conflicts(pair.step(3,4)))
    }
    func testLedgeWaitsForExactTwoTileCompletionAndKeepsMiddleReserved() {
        let pair=Pair();pair.bc = .init(x:1,y:-1);pair.bp=pair.bc;pair.connect()
        pair.ar=pair.step(0,2,nonce:11,kind:1);pair.ticks(4);XCTAssertEqual(pair.permit(pair.a),11)
        // A nil pending flag is not completion. The native mid-jump pose may
        // already be one tile away, before it reaches the approved landing.
        pair.ar=nil;pair.ac = .init(x:1,y:0);pair.ap = .init(x:0,y:0)
        pair.bPeer=[pair.actor(.init(x:0,y:0),.init(x:0,y:0))]
        pair.br = .init(nonce:12,generation:2,instance:9,group:3,number:43,elevation:0,
            from:.init(x:1,y:-1),to:.init(x:1,y:0));pair.ticks(22)
        XCTAssertEqual(pair.permit(pair.b),0)
        pair.ac = .init(x:2,y:0);pair.ap = .init(x:0,y:0);pair.tick()
        XCTAssertEqual(pair.permit(pair.b),0)
        pair.ap=pair.ac;pair.adone=11;pair.tick();XCTAssertEqual(pair.permit(pair.b),0)
        pair.ticks(5);XCTAssertEqual(pair.permit(pair.b),12)
    }
    func testFollowerAtLedgeMiddleBlocksBeforeNativeGrant() {
        let pair=Pair();pair.bc = .init(x:3,y:0);pair.bp=pair.bc
        pair.bf=[pair.actor(.init(x:1,y:0),.init(x:1,y:0),kind:1,id:77)]
        pair.connect();pair.ar=pair.step(0,2,nonce:11,kind:1);pair.ticks(5)
        XCTAssertEqual(pair.permit(pair.a),0)
        pair.bf=[];pair.ticks(4);XCTAssertEqual(pair.permit(pair.a),11)
    }
    func testOrdinaryOddPublicationPreservesCommittedSnapshotAndDoesNotRewriteHost() {
        let pair=Pair(),probe=BoundMovementProbe(clock:{0})
        probe.record(pair.snapshot(false,frame:10,sequence:22),timeline:7)
        probe.publish(Data(repeating:0,count:1024));let first=probe.frameInput(at:0)!,epoch=probe.epoch()
        for _ in 0..<3 {
            probe.record(nil,publicationInProgress:true,timeline:7)
            XCTAssertEqual(probe.read()?.frame,10);XCTAssertEqual(probe.epoch(),epoch)
            XCTAssertNil(probe.frameInput(at:0.01))
        }
        probe.record(pair.snapshot(false,frame:11,sequence:24),timeline:7)
        let next=probe.frameInput(at:0.02)!
        XCTAssertEqual(BoundMovementSnapshot.word(next,8),BoundMovementSnapshot.word(first,8)+2)
        XCTAssertEqual(probe.epoch(),epoch);XCTAssertEqual(probe.read()?.frame,11)
    }
    func testStalledOddPublicationRevokesAtFourthCompletedFrame() {
        let pair=Pair(),probe=BoundMovementProbe(clock:{0})
        probe.record(pair.snapshot(false),timeline:7);probe.publish(Data(repeating:0,count:1024));let epoch=probe.epoch()
        for _ in 0..<4 {probe.record(nil,publicationInProgress:true,timeline:7)}
        XCTAssertNil(probe.read());XCTAssertNil(probe.hostInput());XCTAssertNotEqual(probe.epoch(),epoch)
        XCTAssertEqual(probe.frameInput(at:0.01)?.count,0)
    }
    func testLoadTimelineChangeDuringOddImmediatelyRevokesAndFencesLatePublish() {
        let pair=Pair(),probe=BoundMovementProbe(clock:{0})
        probe.record(pair.snapshot(false),timeline:7);probe.publish(Data(repeating:0,count:1024));let epoch=probe.epoch()
        probe.record(nil,publicationInProgress:true,timeline:8)
        XCTAssertNil(probe.read());XCTAssertNil(probe.hostInput());XCTAssertNotEqual(probe.epoch(),epoch)
        probe.publish(Data(repeating:0,count:1024),epoch:epoch)
        XCTAssertNil(probe.hostInput());XCTAssertEqual(probe.frameInput(at:0.01)?.count,0)
    }
    func testOddPublicationDoesNotDelayExplicitRevokeOrRealTimeLeaseExpiry() {
        let pair=Pair(),probe=BoundMovementProbe(clock:{0})
        probe.record(pair.snapshot(false),timeline:7);probe.publish(Data(repeating:0,count:1024))
        probe.record(nil,publicationInProgress:true,timeline:7);XCTAssertNil(probe.frameInput(at:0.01))
        XCTAssertEqual(probe.frameInput(at:0.151)?.count,0)
        probe.publish(nil);XCTAssertEqual(probe.frameInput(at:0.02)?.count,0)
    }
    func testInvalidMagicOrProfileRevokesImmediatelyInsteadOfOddGrace() {
        let pair=Pair(),probe=BoundMovementProbe(clock:{0})
        probe.record(pair.snapshot(false),timeline:7);probe.publish(Data(repeating:0,count:1024))
        probe.record(nil,publicationInProgress:false,timeline:7)
        XCTAssertNil(probe.read());XCTAssertNil(probe.hostInput());XCTAssertEqual(probe.frameInput(at:0.01)?.count,0)
    }
    func testOverlappedOwnersClaimingSameFreeNeighborReceiveOneGrant() {
        let pair=Pair();pair.bc=pair.ac;pair.bp=pair.ap;pair.connect()
        pair.ar=pair.step(0,1,nonce:11);pair.br=pair.step(0,1,nonce:12)
        for _ in 0..<8 {pair.tick();XCTAssertFalse(pair.permit(pair.a)>0 && pair.permit(pair.b)>0)}
        XCTAssertTrue(pair.permit(pair.a)>0 || pair.permit(pair.b)>0)
    }
    func testOverlapEscapeMayReduceTwoOldActorBlockersToOne() {
        let pair=Pair();pair.bc=pair.ac;pair.bp=pair.ap
        pair.bf=[pair.actor(.init(x:1,y:0),.init(x:0,y:0),kind:1,id:77)]
        pair.connect();pair.ar=pair.step(0,1,nonce:11);pair.ticks(5)
        XCTAssertEqual(pair.permit(pair.a),11)
    }
    func testOverlapEscapeCannotReplaceOldBlockerWithNewActorOnPath() {
        let pair=Pair();pair.bc=pair.ac;pair.bp=pair.ap
        pair.bf=[pair.actor(.init(x:1,y:0),.init(x:1,y:0),kind:1,id:77)]
        pair.connect();pair.ar=pair.step(0,1,nonce:11);pair.ticks(5)
        XCTAssertEqual(pair.permit(pair.a),0)
        pair.ar=pair.step(0,2,nonce:12,kind:1);pair.ticks(5)
        XCTAssertEqual(pair.permit(pair.a),0)
    }
    func testNativeLedgeDoesNotPermitPartialOverlapEscape() {
        let pair=Pair();pair.bc=pair.ac;pair.bp=pair.ap
        pair.bf=[pair.actor(.init(x:1,y:0),.init(x:0,y:0),kind:1,id:77)]
        pair.connect();pair.ar=pair.step(0,2,nonce:11,kind:1);pair.ticks(5)
        XCTAssertEqual(pair.permit(pair.a),0)
    }
    func testLateOldEpochPublishCannotRevokeFreshCurrentAuthority() {
        var revoked=0
        let pair=Pair(),probe=BoundMovementProbe(clock:{0},revoke:{revoked+=1})
        probe.record(pair.snapshot(false),timeline:7);let old=probe.epoch()
        probe.record(nil,publicationInProgress:true,timeline:8)
        probe.record(pair.snapshot(false,frame:2),timeline:8)
        let fresh=Data(repeating:3,count:1024);probe.publish(fresh,epoch:probe.epoch())
        let before=revoked
        probe.publish(Data(repeating:4,count:1024),epoch:old)
        probe.publish(nil,epoch:old)
        XCTAssertEqual(revoked,before)
        XCTAssertEqual(probe.hostInput(),fresh)
        XCTAssertEqual(probe.frameInput(at:0.01)?.count,1024)
    }
    func testProbeNilRollbackAndReconfigureRequestPreframeRevocation() {
        var revoked=0
        let pair=Pair(),probe=BoundMovementProbe(clock:{0},revoke:{revoked+=1})
        probe.record(pair.snapshot(false,frame:100,sequence:202),timeline:7)
        probe.publish(Data(repeating:0,count:1024));XCTAssertEqual(revoked,0)
        probe.publish(nil);XCTAssertEqual(revoked,1)
        probe.publish(Data(repeating:0,count:1024))
        probe.record(pair.snapshot(false,frame:1,sequence:4),timeline:7)
        XCTAssertEqual(revoked,2);XCTAssertNil(probe.hostInput())
        probe.publish(Data(repeating:0,count:1024))
        probe.configure(core:nil)
        XCTAssertEqual(revoked,3);XCTAssertNil(probe.hostInput());XCTAssertNil(probe.read())
    }
    func testTimelineInvalidationDuringOddRequestsPreframeRevokeImmediately() {
        var revoked=0
        let pair=Pair(),probe=BoundMovementProbe(clock:{0},revoke:{revoked+=1})
        probe.record(pair.snapshot(false),timeline:7);probe.publish(Data(repeating:0,count:1024))
        probe.record(nil,publicationInProgress:true,timeline:7);XCTAssertEqual(revoked,0)
        probe.record(nil,publicationInProgress:true,timeline:8)
        XCTAssertEqual(revoked,1);XCTAssertNil(probe.hostInput());XCTAssertNil(probe.read())
    }
}
