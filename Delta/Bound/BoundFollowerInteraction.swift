import Foundation
import Combine
import CryptoKit
import DeltaCore

/// Authenticated, bounded transaction messages. Native code owns selection,
/// inventory and effects; the transport only agrees which completed result to
/// commit. Ephemeral presence epochs fence traffic from retired connections.
struct BoundFollowerInteractionPacket: Codable, Equatable, Sendable {
    enum Kind: String, Codable { case request, target, prepare, ready, commit, applied, abort }
    static let prefix=Data("BFC2".utf8)
    let sender: UUID
    let receiver: UUID
    let id: UUID
    let kind: Kind
    let followerID: UInt64
    var anchor: BoundFollowerInteractionSession.Context? = nil
    var before: Data? = nil
    var after: Data? = nil
    var valid: Bool {
        guard sender != receiver,followerID != 0 else { return false }
        switch kind {
        case .request: return anchor?.valid == true && anchor?.followerID == followerID && anchor?.localEpoch == sender && anchor?.peerEpoch == receiver && before == nil && after == nil
        case .target: return before?.count == 100 && after == nil && anchor == nil
        case .prepare: return before?.count == 100 && after?.count == 100 && anchor == nil
        default: return before == nil && after == nil && anchor == nil
        }
    }
    func encoded() -> Data? {
        guard valid,let bytes=try? JSONEncoder().encode(self),bytes.count+4<=1024 else { return nil }
        return Self.prefix+bytes
    }
    static func decode(_ bytes: Data) -> Self? {
        guard bytes.count<=1024,bytes.starts(with:prefix),
              let value=try? JSONDecoder().decode(Self.self,from:bytes.dropFirst(4)),value.valid else { return nil }
        return value
    }
}

/// The same durable continuation owner used by native activities, in a separate
/// namespace. Clean field snapshots never contain temporary ROM target bindings.
struct BoundBerryContinuation: BoundActivityContinuation {
    enum Phase: String, Codable { case choosing, evaluating, prepared, committed, finished, aborted }
    struct Terminal:Codable {let id:UUID;let kind:BoundFollowerInteractionPacket.Kind}
    let ticket: UUID
    let context: BoundNativeContinuationContext
    let gameID: String
    let activityID: UUID
    let cartridge: String
    let followerID: UInt64
    let donor: Bool
    var phase: Phase
    let before: Data
    var after: Data?
    let stateBefore: Data
    var stateAfter: Data?
    let battery: Data
    let heads: BoundContinuationHeads?
    var terminals:[Terminal]=[]
    var valid: Bool {
        context.valid && !gameID.isEmpty && gameID.utf8.count<=512 && cartridge.count==64 && cartridge.allSatisfy(\.isHexDigit)
            && before.count==100 && (after == nil || after?.count==100)
            && stateBefore.count>1024 && stateBefore.count<=16_777_216 && battery.count==131072
            && (stateAfter == nil || (1025...16_777_216).contains(stateAfter!.count))
            && (context.runID == nil || heads != nil)
            && (![.prepared,.committed,.finished].contains(phase) || after != nil && stateAfter != nil)
            && (phase != .evaluating || !donor && after != nil)
            && terminals.count<=32 && terminals.allSatisfy { [.applied,.abort].contains($0.kind) }
    }
}

/// All emulated-memory access belongs to a paused core or the completed frame.
/// A closure boundary also lets transaction tests inject write/transport faults
/// without pretending that their synthetic state is native gameplay evidence.
@MainActor struct BoundBerryWorld {
    var pause: () -> Bool
    var resume: () -> Void
    var capture: () -> Data
    var restore: (Data) -> Bool
    var battery: () -> Data
    var restoreBattery: (Data) -> Bool
    var target: (UInt64) -> Data
    var begin: (Data) -> Bool
    var apply: (Data,Data) -> Bool
    var close: () -> Void
}
final class BoundFollowerBerryProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var coreID:ObjectIdentifier?
    private var result:(consumed:Bool,mon:Data)?
    private var waiting=false
    func configure(core:EmulatorCore?) { lock.lock();defer {lock.unlock()};coreID=core.map(ObjectIdentifier.init);waiting=false;result=nil }
    func started() {lock.lock();waiting=true;result=nil;lock.unlock()}
    func take()->(consumed:Bool,mon:Data)? {lock.lock();defer{lock.unlock()};let value=result;result=nil;return value}
    func receive(_ core:EmulatorCore) {
        lock.lock();defer{lock.unlock()}
        guard waiting,coreID==ObjectIdentifier(core) else{return}
        let value=BoundVBABattleBridge.advanceFollowerBerry()
        if value["finished"] as? Bool == true,let mon=value["pokemon"] as? Data {
            result=(value["consumed"] as? Bool == true,mon);waiting=false
        }
    }
}

@MainActor final class BoundFollowerInteractionSession: ObservableObject {
    struct Context: Codable, Equatable, Sendable {
        let localEpoch: UUID
        let peerEpoch: UUID
        let mapInstance: UInt64
        let actor: BoundFriendWorldPosition
        let target: BoundFriendWorldPosition
        let followerID: UInt64
        let generation: UInt32
        var valid: Bool { localEpoch != peerEpoch && mapInstance>0 && actor.isFacing(target) }
    }
    var context:(()->Context?)?
    var receiveContext:(()->Context?)?
    var wireScope:(()->(UUID,UUID)?)?
    var continuationContextProvider:(()->BoundNativeContinuationContext?)?
    var continuationHeadsProvider:((BoundNativeContinuationContext)->BoundContinuationHeads?)?
    var send:((Data)->Bool)?
    var changed:(()->Void)?
    var canResume:(()->Bool)?
    var beforeReplace:(()->Bool)?
    var afterReplace:(() throws ->Void)?
    var beforePersistForTesting:((BoundBerryContinuation) throws ->Void)?
    let probe=BoundFollowerBerryProbe()
    var world:BoundBerryWorld?
    var store=BoundNativeContinuationStore(root:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        .appendingPathComponent("Follower Feeding Continuations",isDirectory:true))
    private(set) var record:BoundBerryContinuation?
    private var pendingWrite:BoundBerryContinuation?
    private var needsResume=false
    private var restoresLocal=false
    private var checkedLocalContext:BoundNativeContinuationContext?
    private var retryRestore=false
    private var restoreHead:UUID?
    private var gameID="",cartridge=""
    private weak var core:EmulatorCore?
    private var request:(id:UUID,anchor:Context,started:TimeInterval)?
    private var offer:(id:UUID,context:Context,mon:Data,started:TimeInterval)?
    private var timer:Timer?
    deinit {
        let timer=timer
        BoundMainActorDisposal.enqueue { timer?.invalidate() }
    }
    private var lastSend:TimeInterval = -.infinity
    private var claimant=UUID()
    private var retired:[UUID:BoundFollowerInteractionPacket.Kind]=[:]
    private var retiredOrder:[UUID]=[]
    @Published private(set) var message=""
    @Published private(set) var recoveryBlocked=false
    var isPresented:Bool { record?.phase == .choosing && !recoveryBlocked }
    var isActive:Bool { request != nil || record.map { ![.finished,.aborted].contains($0.phase) } == true || recoveryBlocked || needsResume }
    var blocksGameplay:Bool { isActive && !isPresented }
    var blocksAutoSave:Bool { isActive }
    var blocksCoreResume:Bool { recoveryBlocked || record.map { [.evaluating,.prepared,.committed].contains($0.phase) } == true }
    var canInteract:Bool { BoundMultiplayerFeatures.isEnabled && !isActive && offer == nil && world != nil && context?()?.valid == true && continuationContextProvider?()?.valid == true }
    func bind(core:EmulatorCore?,gameID:String,restoreLocal:Bool=false) {
        restoresLocal=restoreLocal
        guard self.core !== core || self.gameID != gameID else{return}
        if isActive, !checkpointForContinuation() { return }
        self.core=core;self.gameID=gameID;record=nil;request=nil;offer=nil;recoveryBlocked=false;needsResume=false
        checkedLocalContext=nil
        retired=[:];retiredOrder=[];retryRestore=false
        probe.configure(core:core)
        timer?.invalidate();timer=nil
        guard let core,core.deltaCore.identifier=="com.rileytestut.GBADeltaCore",
              let bytes=try? Data(contentsOf:core.game.fileURL,options:.mappedIfSafe),
              (try? BoundPlayerROMProfile(rom:bytes)) != nil else {world=nil;return}
        cartridge=Self.hash(bytes)
        world = .init(pause:{ [weak core] in core?.state == .paused || core?.pause() == true },
            resume:{ [weak self,weak core] in if self?.canResume?() != false,core?.state == .paused {_=core?.resume()} },
            capture:MultiRedAdapter.captureState,restore:MultiRedAdapter.restoreState,
            battery:BoundVBABattleBridge.captureServerBattery,restoreBattery:BoundVBABattleBridge.restoreServerBattery,
            target:BoundVBABattleBridge.followerBerryTarget,begin:BoundVBABattleBridge.beginFollowerBerry,
            apply:{ BoundVBABattleBridge.commitFollowerBerry($0,replacing:$1) },close:BoundVBABattleBridge.closeFollowerBerry)
        let timer=Timer(timeInterval:0.05,repeats:true) { [weak self] _ in MainActor.assumeIsolated {self?.tick()} }
        RunLoop.main.add(timer,forMode:.common);self.timer=timer
    }
    /// Model fixtures supply their own memory owner and authenticated identity.
    func configureForTesting(gameID:String,cartridge:String) {self.gameID=gameID;self.cartridge=cartridge}
    @discardableResult func open()->Bool {
        guard canInteract,let value=context?() else{return false}
        request=(UUID(),value,ProcessInfo.processInfo.systemUptime);lastSend = -.infinity
        message="";changed?();tick();return true
    }
    func dismiss() {
        guard !recoveryBlocked else{return}
        if let request {emit(.abort,id:request.id,follower:request.anchor.followerID);self.request=nil}
        if let value=record,value.donor,[.choosing,.prepared].contains(value.phase) {abort(value)}
        changed?()
    }
    func suspend() {
        if let request {emit(.abort,id:request.id,follower:request.anchor.followerID);self.request=nil}
        offer=nil
        if record?.phase == .choosing { dismiss() }
        else if isActive { _=checkpointForContinuation() }
        changed?()
    }
    private func persist(_ value:BoundBerryContinuation) throws {
        pendingWrite=value
        try beforePersistForTesting?(value);try store.save(value);record=value;pendingWrite=nil
    }
    private func retire(_ id:UUID,_ kind:BoundFollowerInteractionPacket.Kind) {
        retired[id]=kind;retiredOrder.removeAll{$0==id};retiredOrder.append(id)
        if retiredOrder.count>64 {retired.removeValue(forKey:retiredOrder.removeFirst())}
    }
    private func makeRecord(id:UUID,follower:UInt64,donor:Bool,before:Data,phase:BoundBerryContinuation.Phase,world:BoundBerryWorld) throws -> BoundBerryContinuation {
        guard let context=continuationContextProvider?(),context.valid else {throw CocoaError(.fileWriteNoPermission)}
        var value=BoundBerryContinuation(ticket:UUID(),context:context,gameID:gameID,activityID:id,cartridge:cartridge,followerID:follower,
            donor:donor,phase:phase,before:before,stateBefore:world.capture(),battery:world.battery(),heads:continuationHeadsProvider?(context))
        if let old=record,old.context==context {
            guard [.finished,.aborted].contains(old.phase) else{throw CocoaError(.fileWriteUnknown)}
            // The old reply and the new clean preimage share one atomic write.
            // A crash cannot retire the old record before replacing its state.
            value.terminals=Array((old.terminals+[.init(id:old.activityID,kind:old.phase == .finished ? .applied:.abort)]).suffix(32))
        }
        return value
    }
    func receive(_ bytes:Data) {
        guard BoundMultiplayerFeatures.isEnabled,let packet=BoundFollowerInteractionPacket.decode(bytes),
              let scope=wireScope?(),packet.sender==scope.1,packet.receiver==scope.0 else{return}
        // No acknowledgement may overtake a failed durable write.
        guard !recoveryBlocked else{return}
        if let value=record,value.activityID==packet.id,value.context != continuationContextProvider?() {return}
        if let terminal=record?.terminals.first(where:{$0.id==packet.id}),record?.context==continuationContextProvider?() {
            if packet.kind != .applied && packet.kind != .abort {emit(terminal.kind,id:packet.id,follower:packet.followerID)};return
        }
        if let terminal=retired[packet.id] { if packet.kind != .applied && packet.kind != .abort {emit(terminal,id:packet.id,follower:packet.followerID)};return }
        if record?.activityID != packet.id,let context=continuationContextProvider?(),
           let raw=try? store.terminal(id:packet.id,context:context,gameID:gameID),
           let kind=BoundFollowerInteractionPacket.Kind(rawValue:String(decoding:raw,as:UTF8.self)) {
            retire(packet.id,kind);if packet.kind != .applied && packet.kind != .abort {emit(kind,id:packet.id,follower:packet.followerID)};return
        }
        do {
            switch packet.kind {
            case .request:
                if let value=record,value.activityID==packet.id,[.finished,.aborted].contains(value.phase) {
                    emit(value.phase == .finished ? .applied:.abort,id:packet.id,follower:value.followerID);return
                }
                guard !isActive,let anchor=packet.anchor,let current=receiveContext?(),current.valid,
                      anchor.followerID==current.followerID,anchor.generation==current.generation,
                      anchor.mapInstance==current.mapInstance,anchor.actor==current.actor,anchor.target==current.target,
                      offer == nil || offer?.id==packet.id,let world,world.pause() else{return}
                let mon=world.target(packet.followerID);world.resume()
                guard mon.count==100 else{emit(.abort,id:packet.id,follower:packet.followerID);return}
                offer=(packet.id,current,mon,ProcessInfo.processInfo.systemUptime)
                emit(.target,id:packet.id,follower:packet.followerID,before:mon)
            case .target:
                guard let request,request.id==packet.id,request.anchor.followerID==packet.followerID,
                      context?()==request.anchor,let before=packet.before,Self.identity(before)==packet.followerID,
                      let world,world.pause() else{return}
                let value=try makeRecord(id:packet.id,follower:packet.followerID,donor:true,before:before,phase:.choosing,world:world)
                self.request=nil;try persist(value);try drive(value)
            case .prepare:
                if let value=record,value.activityID==packet.id,!value.donor {
                    guard value.before==packet.before,value.after==packet.after else{return}
                    try drive(value);return
                }
                guard !isActive,let offer,offer.id==packet.id,offer.context.followerID==packet.followerID,
                      let before=packet.before,let after=packet.after,before==offer.mon,
                      Self.identity(before)==packet.followerID,Self.identity(after)==packet.followerID,
                      let current=receiveContext?(),current==offer.context,let world,world.pause() else{
                    emit(.abort,id:packet.id,follower:packet.followerID);return
                }
                guard world.target(packet.followerID)==before else {world.resume();emit(.abort,id:packet.id,follower:packet.followerID);return}
                var value=try makeRecord(id:packet.id,follower:packet.followerID,donor:false,before:before,phase:.evaluating,world:world)
                value.after=after
                // Journal the clean preimage before even temporarily evaluating
                // the peer's result. A failed restore remains recoverable.
                try persist(value);self.offer=nil;try drive(value)
            case .ready:
                guard var value=record,value.activityID==packet.id,value.donor,value.phase == .prepared else{return}
                value.phase = .committed;try persist(value) // Decision is durable before the peer may apply it.
                try drive(value)
            case .commit:
                guard var value=record,value.activityID==packet.id,!value.donor,value.followerID==packet.followerID,
                      [.prepared,.committed,.finished].contains(value.phase) else{return}
                if value.phase != .finished {
                    value.phase = .committed;try persist(value)
                }
                try drive(value)
            case .applied:
                guard let value=record,value.activityID==packet.id,value.donor,value.phase == .committed else{return}
                try finish(value)
            case .abort:
                if request?.id==packet.id {request=nil;changed?()}
                if offer?.id==packet.id {offer=nil}
                guard let value=record,value.activityID==packet.id else {retire(packet.id,.abort);return}
                // An abort cannot retract a durably committed effect.
                if value.phase == .committed || value.phase == .finished {
                    try drive(value)
                } else {abort(value)}
            }
        } catch {blockForRecovery()}
    }
    func nativeFinished(consumed:Bool,mon:Data) {
        guard var value=record,value.donor,value.phase == .choosing,let world,world.pause() else{return}
        world.close()
        guard consumed else{abort(value);return}
        guard mon.count==100,Self.identity(mon)==value.followerID else{abort(value);return}
        value.after=mon;value.stateAfter=world.capture();value.phase = .prepared
        do {try persist(value);lastSend = -.infinity;tick()}
        catch {blockForRecovery()}
    }
    private func blockForRecovery() {
        _=world?.pause();recoveryBlocked=true;message="Recovering feeding…";changed?()
    }
    private func resumeWorld() {
        needsResume=true
        guard canResume?() != false else{return}
        needsResume=false;world?.resume()
    }
    /// Every retry starts at a durable phase. In particular, committed is a
    /// decision, not evidence that the recipient has restored its after-state.
    private func drive(_ source:BoundBerryContinuation) throws {
        guard let world,world.pause() else{throw CocoaError(.fileReadUnknown)}
        switch source.phase {
        case .choosing:
            request=nil
            guard world.begin(source.before) else{abort(source);return}
            probe.started();recoveryBlocked=false;message="";resumeWorld()
        case .evaluating:
            guard let after=source.after,beforeReplace?() != false,world.restore(source.stateBefore) else{throw CocoaError(.fileReadCorruptFile)}
            guard world.apply(after,source.before) else{abort(source);return}
            var value=source;value.stateAfter=world.capture();value.phase = .prepared
            guard world.restore(source.stateBefore) else{throw CocoaError(.fileReadCorruptFile)}
            try afterReplace?();try persist(value);offer=nil;try drive(value)
        case .prepared:
            recoveryBlocked=false;message=""
            emit(source.donor ? .prepare:.ready,id:source.activityID,follower:source.followerID,
                 before:source.donor ? source.before:nil,after:source.donor ? source.after:nil)
        case .committed:
            recoveryBlocked=false;message=""
            if source.donor {emit(.commit,id:source.activityID,follower:source.followerID)}
            else {try finish(source)}
        case .finished:
            recoveryBlocked=false;message="";resumeWorld()
            if !source.donor {emit(.applied,id:source.activityID,follower:source.followerID)}
        case .aborted:
            world.close()
            guard beforeReplace?() != false,world.restoreBattery(source.battery),world.restore(source.stateBefore) else{throw CocoaError(.fileReadCorruptFile)}
            try afterReplace?();retire(source.activityID,.abort)
            recoveryBlocked=false;message="";emit(.abort,id:source.activityID,follower:source.followerID);resumeWorld()
        }
        changed?()
    }
    private func finish(_ source:BoundBerryContinuation) throws {
        guard let world,world.pause(),let after=source.stateAfter,beforeReplace?() != false else{throw CocoaError(.fileReadUnknown)}
        world.close()
        guard world.restoreBattery(source.battery),world.restore(after) else{throw CocoaError(.fileReadCorruptFile)}
        try afterReplace?()
        var value=source;value.phase = .finished;try persist(value)
        try drive(value)
    }
    private func abort(_ source:BoundBerryContinuation) {
        guard source.phase != .committed && source.phase != .finished,let world,world.pause() else{return}
        do {
            var value=source;value.phase = .aborted;try persist(value);try drive(value)
        } catch {blockForRecovery()}
    }
    func tick(at now:TimeInterval=ProcessInfo.processInfo.systemUptime) {
        if restoresLocal,record==nil,core?.state == .running || core?.state == .paused,
           let context=continuationContextProvider?(),context.runID==nil,checkedLocalContext != context {
            checkedLocalContext=context
            _=restoreContinuationIfAvailable(serverHead:nil)
        }
        if needsResume,!recoveryBlocked {resumeWorld();changed?()}
        if let result=probe.take(){nativeFinished(consumed:result.consumed,mon:result.mon)}
        // Native dialogue can remain open indefinitely; the next prepare still
        // revalidates the exact target and world context before consuming it.
        if let request,now-request.started>10 || context?() != request.anchor {dismiss()}
        guard now-lastSend>=0.25 else{return};lastSend=now
        if recoveryBlocked {
            do {
                if retryRestore {_=restoreContinuationIfAvailable(serverHead:restoreHead)}
                else if let value=pendingWrite {try persist(value);try drive(value)}
                else if let value=record {try drive(value)}
            } catch {blockForRecovery()}
            return
        }
        if let request {emit(.request,id:request.id,follower:request.anchor.followerID,anchor:request.anchor)}
        if let value=record {
            switch value.phase {
            case .prepared:
                if value.donor {emit(.prepare,id:value.activityID,follower:value.followerID,before:value.before,after:value.after)}
                else {emit(.ready,id:value.activityID,follower:value.followerID)}
            case .committed:
                do {try drive(value)}catch{blockForRecovery()}
            default:break
            }
        }
    }
    private func emit(_ kind:BoundFollowerInteractionPacket.Kind,id:UUID,follower:UInt64,anchor:Context?=nil,before:Data?=nil,after:Data?=nil) {
        if let value=record,value.activityID==id,value.context != continuationContextProvider?() {return}
        guard let scope=wireScope?(),let bytes=BoundFollowerInteractionPacket(sender:scope.0,receiver:scope.1,id:id,
            kind:kind,followerID:follower,anchor:anchor,before:before,after:after).encoded() else{return}
        _=send?(bytes)
    }
    @discardableResult func checkpointForContinuation()->Bool {
        guard !recoveryBlocked,pendingWrite==nil else{return false}
        if request != nil {dismiss()}
        if record?.phase == .choosing {dismiss()}
        guard let value=record,let world else{return !isActive}
        guard world.pause() else{return false}
        do {try persist(value);return true}catch{recoveryBlocked=true;return false}
    }
    @discardableResult func restoreContinuationIfAvailable(serverHead:UUID?)->Bool {
        guard let context=continuationContextProvider?(),let world else{return false}
        retryRestore=true;restoreHead=serverHead
        do {
            guard var value=try store.load(context:context,gameID:gameID,as:BoundBerryContinuation.self) else{retryRestore=false;return false}
            guard value.cartridge==cartridge else{throw CocoaError(.fileReadCorruptFile)}
            if let heads=value.heads,!heads.permits(serverHead) {
                try store.claim(ticket:value.ticket,context:context,gameID:gameID,claimant:claimant)
                if let token=try store.settlement(context:context,gameID:gameID){try store.settle(token)}
                retryRestore=false
                return false // A later authoritative checkpoint already supersedes this local result.
            }
            guard world.pause(),beforeReplace?() != false else{throw CocoaError(.fileReadUnknown)}
            world.close()
            record=value;pendingWrite=nil
            retryRestore=false
            if value.phase == .choosing || value.phase == .aborted {abort(value);return true}
            if value.phase == .committed || value.phase == .finished {
                // Recipient commits may be retried until its peer acknowledges;
                // restoring the complete after-state cannot add the effect twice.
                if !value.donor || value.phase == .finished {try finish(value)}
                else {
                    guard let after=value.stateAfter,world.restoreBattery(value.battery),world.restore(after) else{throw CocoaError(.fileReadCorruptFile)}
                    try afterReplace?()
                }
            } else if value.phase == .evaluating {
                try drive(value)
            } else {
                guard world.restoreBattery(value.battery),world.restore(value.donor ? value.stateAfter ?? value.stateBefore:value.stateBefore) else{throw CocoaError(.fileReadCorruptFile)}
                try afterReplace?()
            }
            value=record ?? value;lastSend = -.infinity;changed?();return true
        } catch BoundContinuationError.consumed {
            // Berry records are claimed only after a confirmed server save;
            // that installed checkpoint already contains the terminal result.
            retryRestore=false;return false
        } catch {blockForRecovery();return true}
    }
    func continuationSettlement()->BoundContinuationSettlement? {
        guard let value=record,[.finished,.aborted].contains(value.phase) else{return nil}
        return .init(ticket:value.ticket,claimant:claimant,context:value.context,gameID:value.gameID)
    }
    func settleContinuation(_ token:BoundContinuationSettlement) throws {
        if let value=record,value.ticket==token.ticket {
            let kind:BoundFollowerInteractionPacket.Kind=value.phase == .aborted ? .abort:.applied
            try store.saveTerminal(id:value.activityID,data:Data(kind.rawValue.utf8),context:value.context,gameID:value.gameID)
            retire(value.activityID,kind)
        }
        try store.claim(ticket:token.ticket,context:token.context,gameID:token.gameID,claimant:token.claimant)
        try store.settle(token)
        if record?.ticket==token.ticket {record=nil}
    }
    private static func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    static func identity(_ bytes:Data)->UInt64? {
        guard bytes.count==100,let mon=BoundSoulMon.decode(bytes,stride:100).first,!mon.isEgg,(mon.hp ?? 0)>0 else{return nil}
        return UInt64(mon.identity.personality)<<32|UInt64(mon.identity.trainer)
    }
}
