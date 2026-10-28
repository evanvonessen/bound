import Foundation
import CryptoKit
import Combine
import DeltaCore

struct BoundMovementTile: Codable, Equatable, Hashable, Sendable {
    let x:Int, y:Int
    init(_ value:BoundPlayerState.Point) { x=value.x;y=value.y }
    init(x:Int,y:Int) { self.x=x;self.y=y }
    var valid:Bool { (-7...1030).contains(x) && (-7...1030).contains(y) }
    func distance(_ other:Self)->Int { abs(x-other.x)+abs(y-other.y) }
}
struct BoundMovementActor: Equatable, Sendable {
    let current:BoundMovementTile, previous:BoundMovementTile
    let elevation:Int,kind:Int,identity:UInt64
    var tiles:Set<BoundMovementTile> { [current,previous] }
}
struct BoundMovementStep: Codable, Equatable, Sendable {
    let nonce:UInt32,generation:UInt32,instance:UInt64
    let group:Int,number:Int,elevation:Int,kind:Int
    let from:BoundMovementTile,to:BoundMovementTile
    init(nonce:UInt32,generation:UInt32,instance:UInt64,group:Int,number:Int,elevation:Int,
         from:BoundMovementTile,to:BoundMovementTile,kind:Int=0) {
        self.nonce=nonce;self.generation=generation;self.instance=instance
        self.group=group;self.number=number;self.elevation=elevation;self.from=from;self.to=to;self.kind=kind
    }
    var path:Set<BoundMovementTile> {
        var values:Set<BoundMovementTile>=[from,to]
        if kind==1 {values.insert(.init(x:(from.x+to.x)/2,y:(from.y+to.y)/2))}
        return values
    }
    var valid:Bool { nonce>0 && generation>0 && instance>0 && (0...42).contains(group) && (0...255).contains(number)
        && (0...15).contains(elevation) && from.valid && to.valid
        && (from.x==to.x || from.y==to.y) && ((kind==0 && from.distance(to)==1) || (kind==1 && from.distance(to)==2)) }
    func conflicts(_ other:Self)->Bool {
        instance==other.instance && group==other.group && number==other.number && elevation==other.elevation
        && (kind==1 || other.kind==1 ? !path.isDisjoint(with:other.path):(to==other.to || to==other.from || from==other.to))
    }
}
struct BoundMovementSnapshot: Equatable, Sendable {
    let bytes:Data,frame:UInt32,generation:UInt32,flags:UInt32,instance:UInt64,sequence:UInt32
    let group:Int,number:Int,elevation:Int,facing:Int
    let current:BoundMovementTile,previous:BoundMovementTile
    let completed:UInt32
    let request:BoundMovementStep?
    init?(_ source:Data) {
        let d=Data(source)
        guard d.count==256,Self.word(d,0)==0x314F5742,Self.word(d,4)==1,
              Self.word(d,8)>0,Self.word(d,8)&1==0,Self.word(d,20) & ~255==0 else { return nil }
        bytes=d;sequence=Self.word(d,8);frame=Self.word(d,12);generation=Self.word(d,16);flags=Self.word(d,20)
        instance=UInt64(Self.word(d,80))|UInt64(Self.word(d,84))<<32
        group=Int(d[32]);number=Int(d[33]);elevation=Int(d[34]);facing=Int(d[35])
        current=Self.tile(d,36);previous=Self.tile(d,40);completed=Self.word(d,72)
        let step=BoundMovementStep(nonce:Self.word(d,52),generation:generation,instance:instance,
            group:group,number:number,elevation:elevation,from:Self.tile(d,56),to:Self.tile(d,60),kind:Int(d[67]))
        let age=frame &- Self.word(d,68)
        // BeforeCallbacks clears the transient PENDING bit between collision
        // queries. Keep the exact recent request through those frames so a
        // network grant can reach the next native collision query.
        request=flags&7 == 7 && flags&16 == 0 && age<=12 && step.valid
            && current==step.from && completed != step.nonce ? step:nil
    }
    static func word(_ d:Data,_ n:Int)->UInt32 { (0..<4).reduce(0){$0|UInt32(d[n+$1])<<(8*$1)} }
    static func tile(_ d:Data,_ n:Int)->BoundMovementTile {
        .init(x:Int(Int16(bitPattern:UInt16(d[n])|UInt16(d[n+1])<<8)),y:Int(Int16(bitPattern:UInt16(d[n+2])|UInt16(d[n+3])<<8)))
    }
    static func put(_ value:UInt32,_ d:inout Data,_ n:Int) { for i in 0..<4 {d[n+i]=UInt8(truncatingIfNeeded:value>>(8*i))} }
    static func putTile(_ tile:BoundMovementTile,_ d:inout Data,_ n:Int) {
        for (offset,value) in [(n,tile.x),(n+2,tile.y)] {
            let v=UInt16(bitPattern:Int16(value));d[offset]=UInt8(truncatingIfNeeded:v);d[offset+1]=UInt8(v>>8)
        }
    }
}

/// The completed-frame owner is the sole reader/writer of the transient port.
final class BoundMovementProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var coreID:ObjectIdentifier?,desired:Data?,snapshot:BoundMovementSnapshot?
    private let clock:()->TimeInterval
    private let requestRevocation:()->Void
    private var desiredAt:TimeInterval = -.infinity,frameSequence:UInt32=0
    private var observationEpoch:UInt64=0,lastObserved:BoundMovementSnapshot?
    private var loadTimeline:UInt64?,desiredEpoch:UInt64=0,oddFrames=0,publicationInProgress=false
    init(clock:@escaping ()->TimeInterval = {ProcessInfo.processInfo.systemUptime},
         revoke:@escaping ()->Void = {BoundVBABattleBridge.requestWorldMovementRevocation()}) {
        self.clock=clock;requestRevocation=revoke
    }
    func configure(core:EmulatorCore?) {
        lock.lock();defer{lock.unlock()};requestRevocation();coreID=core.map(ObjectIdentifier.init);desired=nil;snapshot=nil
        frameSequence=0;lastObserved=nil;observationEpoch &+= 1;loadTimeline=BoundVBABattleBridge.worldMovementTimeline()
        oddFrames=0;publicationInProgress=false
    }
    func publish(_ bytes:Data?,epoch:UInt64?=nil) {
        lock.lock();defer{lock.unlock()}
        guard epoch.map({$0==observationEpoch}) ?? true else {return}
        if bytes?.count != 1024 {requestRevocation()}
        desired=bytes;desiredAt=clock();desiredEpoch=observationEpoch
    }
    func read()->BoundMovementSnapshot? {lock.lock();defer{lock.unlock()};return snapshot}
    func hostInput()->Data? {lock.lock();defer{lock.unlock()};return desired}
    func epoch()->UInt64 {lock.lock();defer{lock.unlock()};return observationEpoch}
    func record(_ value:BoundMovementSnapshot?,publicationInProgress:Bool=false,timeline:UInt64?=nil) {
        lock.lock();defer{lock.unlock()}
        observe(value,publicationInProgress:publicationInProgress,timeline:timeline ?? loadTimeline ?? 0)
    }
    private func invalidate(forceEpoch:Bool=false) {
        requestRevocation()
        if forceEpoch || desired != nil || snapshot != nil || lastObserved != nil {observationEpoch &+= 1}
        desired=nil;snapshot=nil;lastObserved=nil;oddFrames=0;publicationInProgress=false
    }
    private func observe(_ value:BoundMovementSnapshot?,publicationInProgress writing:Bool,timeline:UInt64) {
        if let previous=loadTimeline,previous != timeline {
            loadTimeline=timeline;invalidate(forceEpoch:true);return
        }
        loadTimeline=timeline
        if value==nil,writing,snapshot != nil {
            oddFrames+=1
            if oddFrames<=3 {publicationInProgress=true;return}
        }
        guard let value else {invalidate();return}
        oddFrames=0;publicationInProgress=false
        if let old=lastObserved {
            if value.generation != old.generation || value.frame &- old.frame>0x80000000 || value.sequence &- old.sequence>0x80000000 {
                requestRevocation()
                desired=nil;observationEpoch &+= 1
            }
        }
        lastObserved=value;snapshot=value
    }
    /// nil leaves the cartridge port untouched while its seqlock writer may
    /// be scanning that same transaction. Empty data explicitly revokes it.
    func frameInput(at now:TimeInterval)->Data? {lock.lock();defer{lock.unlock()};return prepare(at:now)}
    private func prepare(at now:TimeInterval)->Data? {
        guard now.isFinite,now>=desiredAt,now-desiredAt<=0.15,desiredEpoch==observationEpoch,
              var bytes=desired,bytes.count==1024 else{return Data()}
        if publicationInProgress {return nil}
        frameSequence &+= 2;if frameSequence==0 {frameSequence=2}
        BoundMovementSnapshot.put(frameSequence,&bytes,8);return bytes
    }
    func receive(_ core:EmulatorCore) {
        lock.lock();defer{lock.unlock()};guard coreID==ObjectIdentifier(core) else{return}
        let before=BoundVBABattleBridge.worldMovementTimeline()
        let value=BoundMovementSnapshot(BoundVBABattleBridge.worldMovementSnapshot())
        let writing=BoundVBABattleBridge.worldMovementPublicationInProgress()
        let after=BoundVBABattleBridge.worldMovementTimeline()
        if before != after {loadTimeline=after;invalidate(forceEpoch:true)}
        else {observe(value,publicationInProgress:writing,timeline:after)}
        let latest=BoundVBABattleBridge.worldMovementTimeline()
        if latest != loadTimeline {loadTimeline=latest;invalidate(forceEpoch:true)}
        if let input=prepare(at:clock()) {BoundVBABattleBridge.setWorldMovementHost(input)}
    }
}

struct BoundMovementPacket: Codable, Equatable, Sendable {
    enum Kind:String,Codable {
        case hello,heartbeat,request,offer,accept,grant,started,release,released,cancel,cancelled
        case pass,passAck,passCommit,passCommitted
    }
    static let prefix=Data("BMR1".utf8)
    let sender:UUID,receiver:UUID,channel:UUID,acknowledgedChannel:UUID?
    let sequence:UInt64,instance:UInt64,generation:UInt32
    let group:Int,number:Int,elevation:Int,kind:Kind,token:UInt64
    let step:BoundMovementStep?
    private var valid:Bool {
        guard sender != receiver,sequence>0,instance>0,generation>0,
              (0...42).contains(group),(0...255).contains(number),(0...15).contains(elevation) else{return false}
        if let step {guard step.valid,step.instance==instance,step.group==group,step.number==number,step.elevation==elevation else{return false}}
        switch kind {
        case .hello:return token==0 && step==nil
        case .heartbeat:return token==0 && step==nil && acknowledgedChannel != nil
        case .pass,.passAck,.passCommit,.passCommitted:return token>0 && step==nil && acknowledgedChannel != nil
        default:return token>0 && step != nil && acknowledgedChannel != nil
        }
    }
    func encoded()->Data? {
        guard valid,let body=try? JSONEncoder().encode(self),body.count+4<=768 else{return nil}
        return Self.prefix+body
    }
    static func decode(_ bytes:Data)->Self? {
        guard bytes.starts(with:prefix),bytes.count<=768,
              let value=try? JSONDecoder().decode(Self.self,from:bytes.dropFirst(4)),value.valid else{return nil}
        return value
    }
}

/// Offers expire. A committed footprint survives until its owner reports the
/// actual native completion/cancellation, or the whole control channel closes.
struct BoundMovementArbiter {
    struct Key:Hashable {let owner:UUID,token:UInt64}
    enum Phase {case offered,committed,tail}
    struct Lease:Equatable {let key:Key,step:BoundMovementStep;var phase:Phase,deadline:TimeInterval}
    private(set) var leases:[Lease]=[]
    private var retired:[UUID:UInt64]=[:]
    private(set) var lastOwner:UUID?
    mutating func clear(){leases=[];retired=[:];lastOwner=nil}
    mutating func expire(at now:TimeInterval) {
        for value in leases where value.phase != .committed && value.deadline<=now {retire(value.key)}
        leases.removeAll{$0.phase != .committed && $0.deadline<=now}
    }
    private mutating func retire(_ key:Key) {retired[key.owner]=max(retired[key.owner] ?? 0,key.token)}
    func isRetired(_ key:Key)->Bool {(retired[key.owner] ?? 0)>=key.token}
    func lease(_ key:Key)->Lease? {leases.first{$0.key==key}}
    mutating func offer(_ key:Key,step:BoundMovementStep,at now:TimeInterval)->Bool {
        expire(at:now)
        if let old=lease(key) {return old.step==step && old.phase != .tail}
        guard step.valid,!isRetired(key),leases.count<8,
              !leases.contains(where:{$0.key != key && ($0.key.owner==key.owner || $0.step.conflicts(step))}) else{return false}
        leases.append(.init(key:key,step:step,phase:.offered,deadline:now+0.8));return true
    }
    mutating func commit(_ key:Key,step:BoundMovementStep,at now:TimeInterval)->Bool {
        expire(at:now)
        guard let i=leases.firstIndex(where:{$0.key==key && $0.step==step && $0.phase != .tail}) else{return false}
        leases[i].phase = .committed;leases[i].deadline = .infinity;lastOwner=key.owner;return true
    }
    mutating func finish(_ key:Key,step:BoundMovementStep,at now:TimeInterval) {
        retire(key)
        if let i=leases.firstIndex(where:{$0.key==key && $0.step==step}) {
            if leases[i].phase != .tail {leases[i].phase = .tail;leases[i].deadline=now+0.1}
        }
    }
}

@MainActor
final class BoundWorldMovementSession:ObservableObject {
    struct Context:Equatable {
        let local:UUID,peer:UUID,instance:UInt64,group:Int,number:Int,elevation:Int
        let own:[BoundMovementActor],other:[BoundMovementActor]
        var isArbiter:Bool {local.uuidString<peer.uuidString}
        var valid:Bool {
            func actors(_ values:[BoundMovementActor])->Bool {
                values.count>0 && values.count<=2 && values.first?.kind==0 && Set(values.map(\.kind)).count==values.count
                && values.allSatisfy{(0...1).contains($0.kind) && (0...15).contains($0.elevation)
                    && $0.current.valid && $0.previous.valid && $0.current.distance($0.previous)<=2}
            }
            return local != peer && instance>0 && (0...42).contains(group) && (0...255).contains(number)
                && (0...15).contains(elevation) && actors(own) && actors(other)
        }
        func sameWorld(_ other:Self)->Bool {
            local==other.local && peer==other.peer && instance==other.instance && group==other.group
                && number==other.number && elevation==other.elevation
        }
    }
    private struct Attempt {
        enum Phase {case waiting,offered,committed,finishing}
        let key:BoundMovementArbiter.Key,step:BoundMovementStep,deadline:TimeInterval
        var phase:Phase = .waiting,started=false,completed=false
    }
    private struct PeerRequest {let key:BoundMovementArbiter.Key,step:BoundMovementStep,created:TimeInterval}
    private struct Pass {
        enum Phase {case awaitingAck,awaitingCommit,awaitingCommitted,active}
        let token:UInt64,initiator:UUID,deadline:TimeInterval
        var phase:Phase,until:TimeInterval=0
    }
    let probe=BoundMovementProbe()
    var send:((Data)->Bool)?
    @Published private(set) var passing=false
    @Published private(set) var reconnecting=true
    private var context:Context?,native:BoundMovementSnapshot?,arbiter=BoundMovementArbiter()
    private var attempt:Attempt?,peerRequest:PeerRequest?,pass:Pass?
    private var channel=UUID(),peerChannel:UUID?,peerGeneration:UInt32?
    private var generation:UInt32=0,sequence:UInt64=0,serial:UInt64=0,nativeSequence:UInt32=0
    private var received:[UUID:UInt64]=[:]
    private var retiredPass:[UUID:UInt64]=[:]
    private var lastNative:(frame:UInt32,sequence:UInt32)?,clock:TimeInterval=0,sentTimes:[TimeInterval]=[]
    private var probeEpoch:UInt64=0
    private var lastEcho:TimeInterval = -.infinity,lastHeartbeat:TimeInterval = -.infinity,lastAction:TimeInterval = -.infinity
    func reset() {
        context=nil;native=nil;generation=0;lastNative=nil;restartChannel();probe.publish(nil)
    }
    private func restartChannel() {
        channel=UUID();peerChannel=nil;peerGeneration=nil;lastEcho = -.infinity
        lastHeartbeat = -.infinity;lastAction = -.infinity;reconnecting=true
        clearReservations();probe.publish(nil)
    }
    private func clearReservations() {
        arbiter.clear();attempt=nil;peerRequest=nil;retiredPass=[:];pass=nil;passing=false;probe.publish(nil)
    }
    private func nextToken()->UInt64? {guard serial<UInt64.max else{return nil};serial+=1;return serial}
    private func ready(at now:TimeInterval)->Bool {peerChannel != nil && now>=lastEcho && now-lastEcho<=0.3}
    private func transmit(_ kind:BoundMovementPacket.Kind,_ step:BoundMovementStep?=nil,token:UInt64=0) {
        sentTimes.removeAll{$0<=clock-1}
        guard let c=context,sequence<UInt64.max,sentTimes.count<50 else{return};sequence+=1
        let packet=BoundMovementPacket(sender:c.local,receiver:c.peer,channel:channel,acknowledgedChannel:peerChannel,
            sequence:sequence,instance:c.instance,generation:generation,group:c.group,number:c.number,elevation:c.elevation,
            kind:kind,token:token,step:step)
        if let bytes=packet.encoded(){sentTimes.append(clock);_=send?(bytes)}
    }
    private func nearAndStationary(_ c:Context)->Bool {
        guard let own=c.own.first,let other=c.other.first else{return false}
        return own.current==own.previous && other.current==other.previous && own.current.distance(other.current)<=2
    }
    func letPass(at now:TimeInterval=ProcessInfo.processInfo.systemUptime) {
        guard now.isFinite,now>=clock,let c=context,ready(at:now),nearAndStationary(c),pass==nil,let token=nextToken() else{return}
        clock=now
        pass = .init(token:token,initiator:c.local,deadline:now+0.8,phase:.awaitingAck)
        transmit(.pass,token:token);lastAction=now
    }
    func receive(_ data:Data,at now:TimeInterval=ProcessInfo.processInfo.systemUptime) {
        guard now.isFinite,now>=clock,let c=context,let p=BoundMovementPacket.decode(data),p.sender==c.peer,p.receiver==c.local,
              p.instance==c.instance,p.group==c.group,p.number==c.number,p.elevation==c.elevation,
              p.sequence>(received[c.peer] ?? 0) else{return}
        clock=now
        if p.kind == .hello {
            if peerChannel != p.channel || peerGeneration != p.generation {
                clearReservations();peerChannel=p.channel;peerGeneration=p.generation;lastEcho = -.infinity;reconnecting=true
            }
        } else {guard p.channel==peerChannel,p.generation==peerGeneration else{return}}
        // A fresh UUID echo fences every delayed packet from a previous visit,
        // native heap generation, disconnect, or control-channel timeout.
        guard p.kind == .hello || p.acknowledgedChannel==channel else{return}
        received[c.peer]=p.sequence
        if received.count>8 {received=received.filter{$0.key==c.peer}}
        if p.acknowledgedChannel==channel {lastEcho=now}
        if p.kind == .hello {transmit(.heartbeat);return}
        guard ready(at:now) else{return}
        let key=BoundMovementArbiter.Key(owner:c.peer,token:p.token)
        switch p.kind {
        case .hello,.heartbeat:break
        case .request:
            guard c.isArbiter,let step=p.step,step.generation==p.generation,c.other.first?.tiles.contains(step.from)==true else{return}
            if arbiter.isRetired(key) {transmit(.cancelled,step,token:p.token);return}
            if peerRequest?.key != key {peerRequest = .init(key:key,step:step,created:now)}
        case .offer:
            guard !c.isArbiter,let old=attempt,old.key.token==p.token,old.step==p.step,now<old.deadline,old.phase != .finishing else {
                if let step=p.step {transmit(.cancel,step,token:p.token)};return
            }
            if old.phase == .waiting {attempt?.phase = .offered}
            transmit(.accept,old.step,token:p.token)
        case .accept:
            guard c.isArbiter,let step=p.step else{return}
            if arbiter.commit(key,step:step,at:now){transmit(.grant,step,token:p.token)}
            else {transmit(.cancelled,step,token:p.token)}
        case .grant:
            guard !c.isArbiter,let old=attempt,old.key.token==p.token,old.step==p.step,
                  old.phase == .offered || old.phase == .committed else {
                if let step=p.step {transmit(.cancel,step,token:p.token)};return
            }
            guard old.started || now<old.deadline else {finishLocal(completed:false,at:now);return}
            attempt?.phase = .committed
            if old.started {transmit(.started,old.step,token:p.token)}
        case .started:
            // The reservation was committed before the owner could publish a
            // native permit. This message is diagnostic, never new authority.
            break
        case .release,.cancel:
            guard c.isArbiter,let step=p.step else{return}
            arbiter.finish(key,step:step,at:now)
            if peerRequest?.key==key {peerRequest=nil}
            transmit(p.kind == .release ? .released:.cancelled,step,token:p.token)
        case .released,.cancelled:
            guard !c.isArbiter,let old=attempt,old.key.token==p.token,old.step==p.step else{return}
            // A negative offer acknowledgement also retires an unstarted
            // request, allowing a new token for the same held native direction.
            if old.phase == .finishing || p.kind == .cancelled && !old.started {
                attempt=nil
            }
        case .pass,.passAck,.passCommit,.passCommitted:receivePass(p,context:c,at:now)
        }
    }
    private func receivePass(_ p:BoundMovementPacket,context c:Context,at now:TimeInterval) {
        switch p.kind {
        case .pass:
            guard nearAndStationary(c),(retiredPass[c.peer] ?? 0)<p.token else{return}
            if let old=pass {
                if old.initiator==c.peer && old.token==p.token {transmit(.passAck,token:p.token);return}
                if old.initiator.uuidString<c.peer.uuidString {return}
            }
            pass = .init(token:p.token,initiator:c.peer,deadline:now+0.8,phase:.awaitingCommit)
            transmit(.passAck,token:p.token)
        case .passAck:
            guard var value=pass,value.initiator==c.local,value.token==p.token,
                  value.phase == .awaitingAck || value.phase == .awaitingCommitted,now<value.deadline else{return}
            if value.phase == .awaitingAck {value.phase = .awaitingCommitted;value.until=now+2;passing=true;arbiter.clear();attempt=nil;peerRequest=nil}
            pass=value;transmit(.passCommit,token:p.token)
        case .passCommit:
            guard var value=pass,value.initiator==c.peer,value.token==p.token else{return}
            if value.phase == .awaitingCommit {
                guard now<value.deadline else{return}
                value.phase = .active;value.until=now+2;pass=value;passing=true;arbiter.clear();attempt=nil;peerRequest=nil
            }
            guard value.phase == .active else{return};transmit(.passCommitted,token:p.token)
        case .passCommitted:
            guard var value=pass,value.initiator==c.local,value.token==p.token,value.phase == .awaitingCommitted else{return}
            value.phase = .active;pass=value
        default:break
        }
    }
    func update(_ next:Context?,at now:TimeInterval=ProcessInfo.processInfo.systemUptime) {
        update(next,native:probe.read(),at:now)
    }
    /// Observation boundary shared by the frame probe and the pure coordinator
    /// tests. It only publishes host data; it never writes emulated positions.
    func update(_ next:Context?,native value:BoundMovementSnapshot?,at now:TimeInterval) {
        guard now.isFinite,now>=clock,let next,next.valid,let value,value.flags&1 != 0,value.generation>0,
              value.instance==next.instance,value.group==next.group,value.number==next.number,value.elevation==next.elevation else {reset();return}
        clock=now
        if context.map({!$0.sameWorld(next)}) ?? true {reset()}
        context=next;native=value
        let rollback=lastNative.map{value.frame &- $0.frame>0x80000000 || value.sequence &- $0.sequence>0x80000000} ?? false
        let observedEpoch=probe.epoch()
        if generation != value.generation || rollback || observedEpoch != probeEpoch {
            generation=value.generation;probeEpoch=observedEpoch;restartChannel()
        }
        lastNative=(value.frame,value.sequence)
        if !reconnecting && !ready(at:now) {restartChannel()}
        reconnecting = !ready(at:now)
        if now-lastHeartbeat>=0.1 {transmit(reconnecting ? .hello:.heartbeat);lastHeartbeat=now}
        guard !reconnecting else {probe.publish(nil);return}
        arbiter.expire(at:now)
        if let p=pass {
            if (p.phase == .active && now>=p.until) || (p.phase != .active && now>=p.deadline) {
                retiredPass[p.initiator]=max(retiredPass[p.initiator] ?? 0,p.token);pass=nil;passing=false
            }
            else if now-lastAction>=0.05 {
                transmit(p.phase == .awaitingAck ? .pass:p.phase == .awaitingCommit ? .passAck:p.phase == .awaitingCommitted ? .passCommit:.passCommitted,token:p.token)
                lastAction=now
            }
        }
        if !passing {
            if var old=attempt,old.phase != .finishing {
                if value.completed==old.step.nonce {finishLocal(completed:true,at:now)}
                else {
                    if value.previous==old.step.from && old.step.path.contains(value.current) && value.current != value.previous {old.started=true;attempt=old}
                    if !old.started && (old.step.generation != value.generation || now>=old.deadline || (value.request != nil && value.request != old.step)) {finishLocal(completed:false,at:now)}
                }
            }
            if attempt==nil,let step=value.request,let token=nextToken() {
                attempt = .init(key:.init(owner:next.local,token:token),step:step,deadline:now+0.8)
            }
            if next.isArbiter {grantPending(context:next,at:now)}
            if now-lastAction>=0.05 {
                if let old=attempt {
                    if old.phase == .finishing {transmit(old.completed ? .release:.cancel,old.step,token:old.key.token)}
                    else if !next.isArbiter {transmit(old.phase == .waiting ? .request:old.phase == .offered ? .accept:old.started ? .started:.accept,old.step,token:old.key.token)}
                }
                if next.isArbiter,let request=peerRequest,let lease=arbiter.lease(request.key) {
                    transmit(lease.phase == .offered ? .offer:.grant,request.step,token:request.key.token)
                }
                lastAction=now
            }
        }
        publish(native:value,context:next,at:now)
    }
    private func grantPending(context c:Context,at now:TimeInterval) {
        let peerFirst=arbiter.lastOwner==c.local
        for remote in peerFirst ? [true,false]:[false,true] {
            if remote,let request=peerRequest {
                if now-request.created>=0.8 && arbiter.lease(request.key)?.phase != .committed {
                    arbiter.finish(request.key,step:request.step,at:now);peerRequest=nil
                    transmit(.cancelled,request.step,token:request.key.token)
                } else if targetAvailable(request.step,actors:c.own) {_=arbiter.offer(request.key,step:request.step,at:now)}
            } else if !remote,let old=attempt,old.phase == .waiting,now<old.deadline,
                      targetAvailable(old.step,actors:c.other),arbiter.offer(old.key,step:old.step,at:now),
                      arbiter.commit(old.key,step:old.step,at:now) {attempt?.phase = .committed}
        }
    }
    private func finishLocal(completed:Bool,at now:TimeInterval) {
        guard var old=attempt,let c=context else{return}
        old.phase = .finishing;old.completed=completed;attempt=old
        if c.isArbiter {arbiter.finish(old.key,step:old.step,at:now);attempt=nil}
        else {transmit(completed ? .release:.cancel,old.step,token:old.key.token)}
    }
    private func targetAvailable(_ step:BoundMovementStep,actors:[BoundMovementActor])->Bool {
        let entered=step.path.subtracting([step.from])
        let origin=Set(actors.indices.filter{actors[$0].elevation==step.elevation && actors[$0].tiles.contains(step.from)})
        let blocked=Set(actors.indices.filter{actors[$0].elevation==step.elevation && !actors[$0].tiles.isDisjoint(with:entered)})
        // A negotiated escape may reduce an overlap, preserving native actor
        // masks. It may never exchange an old blocker for a different actor.
        return blocked.isEmpty || (step.kind==0 && !origin.isEmpty && blocked.isStrictSubset(of:origin))
    }
    private func publish(native:BoundMovementSnapshot,context c:Context,at now:TimeInterval) {
        var out=Data(repeating:0,count:1024);nativeSequence &+= 2;if nativeSequence==0 {nativeSequence=2}
        let put=BoundMovementSnapshot.put
        put(0x31574C42,&out,0);put(1,&out,4);put(nativeSequence,&out,8);put(passing ? 1:3,&out,12);put(15,&out,16)
        put(native.generation,&out,20);put(Self.epoch(c.local),&out,24);put(Self.epoch(c.peer),&out,28)
        for n in [32,48] {put(UInt32(truncatingIfNeeded:c.instance),&out,n);put(UInt32(c.instance>>32),&out,n+4)}
        out[64]=UInt8(c.group);out[65]=UInt8(c.number);out[66]=UInt8(c.elevation)
        let actors=passing ? []:Array(c.other.prefix(2));put(UInt32(actors.count),&out,68)
        let permit=passing ? native.request:attempt.flatMap{$0.phase == .committed && !$0.started && now<$0.deadline ? $0.step:nil}
        if let permit,permit==native.request {
            put(permit.nonce,&out,72);put(permit.generation,&out,76)
            BoundMovementSnapshot.putTile(permit.from,&out,80);BoundMovementSnapshot.putTile(permit.to,&out,84);put(passing ? 3:0,&out,88)
        }
        for (i,a) in actors.enumerated() {
            let n=128+i*32;put(1,&out,n);BoundMovementSnapshot.putTile(a.current,&out,n+4);BoundMovementSnapshot.putTile(a.previous,&out,n+8)
            out[n+12]=UInt8(a.elevation);out[n+13]=UInt8(a.kind)
            put(UInt32(truncatingIfNeeded:a.identity),&out,n+20);put(UInt32(a.identity>>32),&out,n+24)
        }
        probe.publish(out,epoch:probeEpoch)
    }
    static func epoch(_ id:UUID)->UInt32 {
        var value=id.uuid;let bytes=withUnsafeBytes(of:&value){Data($0)}
        let hash=Array(SHA256.hash(data:bytes));let n=(0..<4).reduce(UInt32(0)){$0|UInt32(hash[$1])<<(8*$1)};return n==0 ? 1:n
    }
}

