import Foundation
import CryptoKit
import DeltaCore
import UIKit

struct BoundBattleControlPacket:Codable {
    static let prefix=Data([0x42,0x46,0x42,0x31]) // BFB1
    enum Kind:String,Codable { case prepared,connected,finished,abort,resumeRequest,resumeReady }
    let id:UUID
    let kind:Kind
    var nonce:UUID? = nil
    var acknowledgement:UUID? = nil
    func encoded()->Data? {
        guard let bytes=try? JSONEncoder().encode(self) else { return nil }
        return Self.prefix+bytes
    }
    static func decode(_ data:Data)->Self? {
        guard data.count<=1024,data.starts(with:prefix) else { return nil }
        guard let packet=try? JSONDecoder().decode(Self.self,from:data.dropFirst(prefix.count)) else { return nil }
        if packet.kind == .resumeRequest,packet.nonce == nil { return nil }
        if packet.kind == .resumeReady,packet.nonce == nil || packet.acknowledgement == nil { return nil }
        return packet
    }
}

struct BoundNativeBattleObservation:Sendable {
    let frame:UInt64
    let error:Bool
    let connected:Bool
    let battle:Bool
    let returned:Bool
    let outcome:Int
    let flags:Int
    let tradeOpened:Bool
    let tradeCount:Int
    let callback:Int
    let scriptStatus:Int
    let scriptResult:Int
    let playerHP:[Int]
    let enemyHP:[Int]
    let pendingCommands:Int
    init(frame:UInt64,values:[String:Any]) {
        self.frame=frame
        error=values["error"] as? Bool ?? true; connected=values["connected"] as? Bool ?? false
        battle=values["battle"] as? Bool ?? false; returned=values["returned"] as? Bool ?? false
        outcome=values["outcome"] as? Int ?? 0; flags=values["flags"] as? Int ?? 0
        callback=values["callback"] as? Int ?? 0; scriptStatus=values["scriptStatus"] as? Int ?? -1
        scriptResult=values["scriptResult"] as? Int ?? -1
        tradeOpened=values["tradeOpened"] as? Bool ?? false; tradeCount=values["tradeCount"] as? Int ?? 0
        playerHP=values["playerHP"] as? [Int] ?? []; enemyHP=values["enemyHP"] as? [Int] ?? []
        pendingCommands=values["pendingCommands"] as? Int ?? 0
    }
}

/// The completed-frame owner alone polls native connection state, installs game
/// entry and samples battle RAM. Main consumes one bounded observation mailbox.
final class BoundNativeBattleProbe:@unchecked Sendable {
    private let lock=NSLock()
    private var coreID:ObjectIdentifier?
    private var entryPlayer:Int?
    private var peerDisconnectPending=false
    private var latest:BoundNativeBattleObservation?
    private var frame:UInt64=0
    private var incoming=Data()
    private var blockAdmission=BoundNativeBlockAdmission()
    private var peerGeneration:UInt16=0,receivedGeneration:UInt16=0,announcedGeneration:UInt16=0,lastAcceptedSequence:UInt16=0
    private var pendingAcknowledgement=Data(),lastAcknowledgement=Data()
    private var sentHistory=Data(repeating:0,count:32),receivedHistory=Data(repeating:0,count:32)
    private var sender:(@Sendable (Data)->Bool)?
    private var senderEnabled=false
    private var failed:(@Sendable ()->Void)?
    private var interrupted:(@Sendable ()->Void)?
    private var transportSuspended=false,backpressureReported=false
    private var lastSent:TimeInterval=0
    private var lastReceived=ProcessInfo.processInfo.systemUptime
    private var sentCommands=0,receivedCommands=0
    func configure(core:EmulatorCore?) {
        lock.lock(); defer { lock.unlock() }
        coreID=core.map(ObjectIdentifier.init); entryPlayer=nil; peerDisconnectPending=false; latest=nil; frame=0
        incoming.removeAll(); blockAdmission=BoundNativeBlockAdmission(); sender=nil; senderEnabled=false; failed=nil; lastSent=0
        interrupted=nil;transportSuspended=false;backpressureReported=false
        peerGeneration=0; receivedGeneration=0; announcedGeneration=0;lastAcceptedSequence=0
        pendingAcknowledgement.removeAll(); lastAcknowledgement.removeAll()
        sentHistory=Data(repeating:0,count:32);receivedHistory=Data(repeating:0,count:32)
        lastReceived=ProcessInfo.processInfo.systemUptime; sentCommands=0; receivedCommands=0
    }
    func setSender(_ sender:@escaping @Sendable (Data)->Bool,failed:@escaping @Sendable ()->Void,
                   interrupted:(@Sendable ()->Void)? = nil) {
        lock.lock(); self.sender=sender; self.failed=failed; self.interrupted=interrupted; lock.unlock()
    }
    func suspendTransport() { lock.lock(); transportSuspended=true; lock.unlock() }
    /// Called with the retained core paused, before resuming its frame owner.
    func resumeTransport() {
        lock.lock(); transportSuspended=false;backpressureReported=false
        lastReceived=ProcessInfo.processInfo.systemUptime;lastSent=0;announcedGeneration=0;lastAcknowledgement=Data()
        lock.unlock()
    }
    func enableSender() {
        lock.lock(); senderEnabled=true; lastReceived=ProcessInfo.processInfo.systemUptime; lock.unlock()
    }
    func receiveNetworkPacket(_ packet:Data)->Bool {
        guard let commands=BoundNativeCommandPacket.decode(packet) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard coreID != nil,incoming.count+commands.count/16*20<=10240 else { return false }
        if let generation=BoundNativeCommandPacket.generation(packet) {
            peerGeneration=max(peerGeneration,generation)
            if let ack=BoundNativeCommandPacket.acknowledgement(packet) { pendingAcknowledgement=ack }
            if !commands.isEmpty {
                if generation<receivedGeneration { return true }
                guard let sequence=BoundNativeCommandPacket.sequence(packet) else { return false }
                if generation>receivedGeneration { blockAdmission=BoundNativeBlockAdmission(); receivedGeneration=generation;lastAcceptedSequence=sequence &- 1 }
                var first=0
                while first<commands.count,Int16(bitPattern:(sequence &+ UInt16(first/16)) &- lastAcceptedSequence)<=0 { first+=16 }
                let fresh=commands.subdata(in:first..<commands.count)
                guard blockAdmission.accept(fresh) else { return false }
                for start in stride(from:first,to:commands.count,by:16) {
                    incoming.append(UInt8(truncatingIfNeeded:generation)); incoming.append(UInt8(generation>>8))
                    let index=sequence &+ UInt16(start/16)
                    incoming.append(UInt8(truncatingIfNeeded:index)); incoming.append(UInt8(index>>8))
                    let command=commands.subdata(in:start..<start+16)
                    incoming.append(command);lastAcceptedSequence=index
                    let canonical=Data([UInt8(truncatingIfNeeded:generation),UInt8(generation>>8),UInt8(truncatingIfNeeded:index),UInt8(index>>8)])+command
                    receivedHistory=Data(SHA256.hash(data:receivedHistory+canonical))
                }
                receivedCommands+=(commands.count-first)/16
            }
        }
        lastReceived=ProcessInfo.processInfo.systemUptime; return true
    }
    private struct RecoveryState:Codable {
        let incoming:Data
        let remaining:Int
        let peerGeneration:UInt16
        let receivedGeneration:UInt16
        let lastAcceptedSequence:UInt16
        let pendingAcknowledgement:Data
        let sentHistory:Data
        let receivedHistory:Data
    }
    /// Captured after the core and network wire are fenced. Native mailbox and
    /// host continuation admission are one recovery transaction.
    func recoveryData()->Data {
        lock.lock();defer { lock.unlock() }
        return (try? JSONEncoder().encode(RecoveryState(incoming:incoming,remaining:blockAdmission.recoveryRemaining,
            peerGeneration:peerGeneration,receivedGeneration:receivedGeneration,lastAcceptedSequence:lastAcceptedSequence,
            pendingAcknowledgement:pendingAcknowledgement,sentHistory:sentHistory,receivedHistory:receivedHistory))) ?? Data()
    }
    func restoreRecoveryData(_ bytes:Data)->Bool {
        guard bytes.count<=32768,let value=try? JSONDecoder().decode(RecoveryState.self,from:bytes),
              value.incoming.count<=10240,value.incoming.count%20==0,
              [0,4].contains(value.pendingAcknowledgement.count),value.sentHistory.count==32,value.receivedHistory.count==32,
              let admission=BoundNativeBlockAdmission(recoveryRemaining:value.remaining) else { return false }
        lock.lock();defer { lock.unlock() }
        incoming=value.incoming;blockAdmission=admission;peerGeneration=value.peerGeneration
        receivedGeneration=value.receivedGeneration;lastAcceptedSequence=value.lastAcceptedSequence
        pendingAcknowledgement=value.pendingAcknowledgement;announcedGeneration=0;lastAcknowledgement=Data()
        sentHistory=value.sentHistory;receivedHistory=value.receivedHistory
        lastReceived=ProcessInfo.processInfo.systemUptime
        return true
    }
    static func recoveryIsQuiescent(_ bytes:Data,mailbox:Data)->Bool {
        guard bytes.count<=32768,mailbox.count==1176,
              let value=try? JSONDecoder().decode(RecoveryState.self,from:bytes),
              value.incoming.isEmpty,value.remaining==0,value.pendingAcknowledgement.isEmpty,
              value.sentHistory.count==32,value.receivedHistory.count==32 else { return false }
        func half(_ at:Int)->UInt16 { UInt16(mailbox[at]) | UInt16(mailbox[at+1]) << 8 }
        return half(12)==0 && half(4)==half(6) && half(14)==half(4) && half(8)==half(10)
            && half(16)>0 && half(16)==half(18) && value.peerGeneration==half(16)
            && value.receivedGeneration==half(16) && value.lastAcceptedSequence==half(20)
    }
    static func recoveryHistories(_ bytes:Data)->(Data,Data)? {
        guard bytes.count<=32768,let value=try? JSONDecoder().decode(RecoveryState.self,from:bytes),
              value.sentHistory.count==32,value.receivedHistory.count==32 else { return nil }
        return (value.sentHistory,value.receivedHistory)
    }
    var networkAge:TimeInterval { lock.lock(); defer { lock.unlock() }; return ProcessInfo.processInfo.systemUptime-lastReceived }
    var diagnostics:String { lock.lock(); defer { lock.unlock() }; return "sentCommands=\(sentCommands) receivedCommands=\(receivedCommands) pending=\(incoming.count/20)" }
    func disconnectFinishedPeer() { lock.lock(); peerDisconnectPending=true; lock.unlock() }
    func enter(player:Int) { lock.lock(); entryPlayer=player; lock.unlock() }
    func receive(_ core:EmulatorCore) {
        lock.lock()
        guard coreID==ObjectIdentifier(core),!transportSuspended else { lock.unlock(); return }
        let player=entryPlayer; entryPlayer=nil
        let disconnectPeer=peerDisconnectPending; peerDisconnectPending=false
        let send=senderEnabled ? sender:nil,failure=failed
        lock.unlock()
        if let player { _=BoundVBABattleBridge.installBattle(forPlayer:UInt(player)) }
        if disconnectPeer { BoundVBABattleBridge.requestPeerDisconnect() }
        lock.lock()
        BoundVBABattleBridge.setPeerGeneration(UInt(peerGeneration))
        if pendingAcknowledgement.count==4 {
            let ack=pendingAcknowledgement
            BoundVBABattleBridge.acknowledgeGeneration(UInt(ack[0])|UInt(ack[1])<<8,sequence:UInt(ack[2])|UInt(ack[3])<<8)
            pendingAcknowledgement.removeAll()
        }
        let pending=Data(incoming.prefix(260))
        if !pending.isEmpty {
            let accepted=Int(BoundVBABattleBridge.receiveCommands(pending))
            if accepted>0 { incoming.removeFirst(accepted) }
        }
        lock.unlock()
        let generation=UInt16(BoundVBABattleBridge.connectionGeneration())
        let outgoing=BoundVBABattleBridge.takeOutgoingCommands()
        var delivered=0,bad=false,didSend=false
        let acknowledged=BoundVBABattleBridge.peerAcknowledgement()
        if !acknowledged.isEmpty,acknowledged != lastAcknowledgement,send != nil {
            if send?(Data([3])+acknowledged)==true { lastAcknowledgement=acknowledged; didSend=true } else { bad=true }
        }
        if generation>announcedGeneration,send != nil {
            if send?(BoundNativeCommandPacket.connection(generation))==true { announcedGeneration=generation; didSend=true }
            else { bad=true }
        }
        if !outgoing.isEmpty {
            for start in stride(from:0,to:outgoing.count,by:20) {
                let connection=UInt16(outgoing[start])|UInt16(outgoing[start+1])<<8
                let sequence=UInt16(outgoing[start+2])|UInt16(outgoing[start+3])<<8
                let commands=outgoing.subdata(in:start+4..<start+20)
                guard let packet=BoundNativeCommandPacket.encode(commands,generation:connection,sequence:sequence),send?(packet)==true else {
                    let code=commands.prefix(2).reduce(UInt16(0)) { ($0>>8)|(UInt16($1)<<8) }
                    NSLog("Bound native command send failed: %04x",code); bad=true; break
                }
                lock.lock();sentHistory=Data(SHA256.hash(data:sentHistory+outgoing.subdata(in:start..<start+20)));lock.unlock()
                delivered+=1; didSend=true
            }
        } else if send != nil,ProcessInfo.processInfo.systemUptime-lastSent>=1 {
            if send?(Data([0])) != true { bad=true } else { didSend=true }
        }
        let values=BoundVBABattleBridge.advanceAndObserve()
        lock.lock()
        if didSend { lastSent=ProcessInfo.processInfo.systemUptime }
        sentCommands+=delivered; frame &+= 1
        latest = .init(frame:frame,values:values)
        // Stop before the native 32-record queue can overflow, even when a
        // socket silently drops packets without reporting its outage yet.
        let stalled=(latest?.pendingCommands ?? 0)>=16 && !backpressureReported
        if stalled { backpressureReported=true }
        let interruption=interrupted
        lock.unlock()
        if bad { failure?() }
        else if stalled { interruption?() }
    }
    func take()->BoundNativeBattleObservation? { lock.lock(); defer { lock.unlock() }; let value=latest; latest=nil; return value }
}

@MainActor
final class BoundNativeBattleSession {
    let probe=BoundNativeBattleProbe()
    private weak var core:EmulatorCore?
    private weak var interactions:BoundFriendInteractionSession?
    private var gameID=""
    private var id:UUID?
    private var initiator=false
    private(set) var activity=BoundFriendInteractionPacket.Activity.battle
    private var channel:(any BoundBattleChannel)?
    private var wire:BoundBattleWire?
    private var timer:Timer?
    private var earlyPreparation:UUID?
    private var localPrepared=false,peerPrepared=false
    private var localConnected=false,peerConnected=false,entryQueued=false
    private var localFinished=false,peerFinished=false,played=false,peerLinkClosed=false
    private(set) var isTransportSuspended=false
    var activityID:UUID? { id }
    private var pausedForTransport=false
    private var transportGeneration=UUID(),resumeNonce=UUID()
    private var peerResumeNonce:UUID?
    private var retiredResumeNonces:[UUID]=[]
    private var resumeAcknowledged=false,sentResumeReady=false
    private var lastControl:TimeInterval=0,lastPeerControl=ProcessInfo.processInfo.systemUptime,lastChannelAttempt:TimeInterval=0
    private var retired:[UUID:BoundBattleControlPacket.Kind]=[:]
    private var retiredOrder:[UUID]=[]
    private var backupURL:URL?
    private var journalURL:URL?
    private var originalRate=1.0
    private struct Recovery { let state:URL; let journal:URL; let digest:String; let friendlyBattle:Bool; var tradeBattery:Data? = nil }
    private var recovery:Recovery?
    private var recoveryFailed=false
    private(set) var observation:BoundNativeBattleObservation?
    private(set) var lastCancellation=""
    private(set) var lastFailure=""
    private(set) var lastCableDiagnostic=""
    private(set) var completedBattles=0
    private(set) var restoredBattles=0
    private(set) var completedTrades=0
    var makeChannel:((@escaping @Sendable (Data)->Void,@escaping @Sendable ()->Void)->(any BoundBattleChannel)?)?
    var sendControl:((Data)->Bool)?
    var tradeCompleted: ((UUID, Int) -> Void)?
    var restored:(()->Void)?
    var canResume:(()->Bool)?
    var releaseGameplayInputs:(()->Void)?
    var soulProbe:BoundSoulProbe?
    var isActive:Bool { id != nil || recovery != nil }
    var protectsTemporaryState:Bool { isActive || recoveryFailed }
    var blocksAutoSave:Bool { protectsTemporaryState || interactions?.nativeDialogueBusy == true }

    func bind(core:EmulatorCore?,gameID:String,interactions:BoundFriendInteractionSession) {
        if self.core !== core || self.gameID != gameID {
            if recovery != nil { timer?.invalidate(); timer=nil; recovery=nil; probe.configure(core:nil) }
            cancel(resume:false)
            if let oldCore = self.core { soulProbe?.setFriendlyBattleActive(false, for:oldCore) }
            earlyPreparation=nil; self.core=core; self.gameID=gameID; recoveryFailed=false
        }
        self.interactions=interactions
        if core != nil,!isActive { findRecovery() }
    }
    func begin(activity:BoundFriendInteractionPacket.Activity,id:UUID,initiator:Bool) {
        guard BoundMultiplayerFeatures.isEnabled else { return }
        guard !isActive,!recoveryFailed,let core,core.state == .running,
              core.deltaCore.identifier == "com.rileytestut.GBADeltaCore" else {
            interactions?.activityEnded("Game is not ready for a link \(activity.rawValue)"); return
        }
        originalRate=core.rate
        self.id=id; self.activity=activity; self.initiator=initiator; lastFailure=""; lastCancellation=""; observation=nil
        localPrepared=false; peerPrepared=earlyPreparation==id; earlyPreparation=nil; localConnected=false; peerConnected=false
        localFinished=false; peerFinished=false; entryQueued=false; played=false; peerLinkClosed=false
        isTransportSuspended=false;pausedForTransport=false;peerResumeNonce=nil
        retiredResumeNonces.removeAll()
        resumeAcknowledged=false;sentResumeReady=false;lastControl=0;lastPeerControl=ProcessInfo.processInfo.systemUptime
        interactions?.activityProgress(activity == .trade ? "Connecting trade…" : "Connecting battle…",playing:false)
        guard core.pause(),BoundVBABattleBridge.verifyBattleEntryReady() else { fail("Game is not ready for a link \(activity.rawValue)"); return }
        if activity == .battle { soulProbe?.setFriendlyBattleActive(true, for:core) }
        core.rate=core.deltaCore.supportedRates.lowerBound
        do {
            let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
                .appendingPathComponent("Friend Battles",isDirectory:true)
            try BoundServerMemoryFiles.directory(folder,gameID:gameID)
            let backup=folder.appendingPathComponent(id.uuidString+".state")
            try BoundServerMemoryFiles.saveState(core:core,to:backup,gameID:gameID)
            let bytes=try BoundServerMemoryFiles.read(backup,gameID:gameID)
            guard bytes.count>1024 else { throw CocoaError(.fileReadCorruptFile) }
            backupURL=backup
            let journal=folder.appendingPathComponent(id.uuidString+".json")
            let value:[String:Any]=["gameID":gameID,"rom":BoundPlayerROMProfile.supportedSHA256,
                "state":backup.lastPathComponent,"sha256":Self.hash(bytes),"activity":activity.rawValue]
            try BoundServerMemoryFiles.write(JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),to:journal,gameID:gameID)
            journalURL=journal
            if !BoundServerMemoryFiles.isEnabled(for:gameID) {
                var resource=URLResourceValues(); resource.isExcludedFromBackup=true
                var protectedFolder=folder; try protectedFolder.setResourceValues(resource)
            }
        } catch { fail("Couldn’t prepare a recovery snapshot"); return }
        let failure:@Sendable ()->Void = { [weak self] in
            Task { @MainActor in
                guard let self,self.id==id else { return }
                self.fail("\(self.activity.title) command stream needs recovery")
            }
        }
        let interrupted:@Sendable ()->Void = { [weak self] in
            Task { @MainActor in
                guard let self,self.id==id else { return }
                self.suspendTransport()
            }
        }
        probe.configure(core:core)
        let safeWire=BoundBattleWire(id:id,receive:{ [probe] bytes in
            if !probe.receiveNetworkPacket(bytes) { failure() }
        },failed:failure,interrupted:interrupted)
        self.wire=safeWire
        probe.setSender({ bytes in safeWire.send(bytes) },failed:failure,interrupted:interrupted)
        let prepared = activity == .trade ? BoundVBABattleBridge.prepareTrade(forPlayer:initiator ? 0:1)
            : BoundVBABattleBridge.prepareBattle(forPlayer:initiator ? 0:1)
        guard prepared else {
            fail("Couldn’t prepare the native \(activity.rawValue) link"); return
        }
        localPrepared=true
        _=core.resume()
        let timer=Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.advance() } }
        RunLoop.main.add(timer,forMode:.common); self.timer=timer
        if bindTransportChannel() { _=emit(.prepared) } else { suspendTransport() }
        advance()
    }
    /// Keep the same cartridge execution, native link queues, consent ID and
    /// trade journal. Only the physical transport is replaced during an outage.
    func suspendTransport() {
        guard id != nil, let core else { return }
        if !isTransportSuspended {
            if let peerResumeNonce { retiredResumeNonces=Array((retiredResumeNonces+[peerResumeNonce]).suffix(32)) }
            isTransportSuspended=true;resumeNonce=UUID();peerResumeNonce=nil
            resumeAcknowledged=false;sentResumeReady=false
            pausedForTransport=core.state == .running
            releaseGameplayInputs?()
            probe.suspendTransport()
            if pausedForTransport { _=core.pause() }
            if core.state == .paused { core.deltaCore.emulatorBridge.resetInputs() }
            interactions?.activityProgress("Waiting for your friend…",playing:false)
        }
        transportGeneration=UUID();channel?.close();channel=nil;wire?.suspend()
        lastChannelAttempt=0;lastControl=0
    }
    func resumeTransport() {
        guard id != nil,isTransportSuspended else { return }
        retryTransport(at:ProcessInfo.processInfo.systemUptime)
    }
    private func bindTransportChannel()->Bool {
        guard let wire,let id else { return false }
        let generation=UUID();transportGeneration=generation
        let interrupted:@Sendable ()->Void={ [weak self] in Task { @MainActor in
            guard let self,self.id==id,self.transportGeneration==generation else { return }
            self.suspendTransport()
        } }
        guard let channel=makeChannel?({ bytes in wire.receive(bytes) },interrupted) else { return false }
        self.channel=channel;wire.setSender { [channel] bytes in channel.send(bytes) }
        return true
    }
    private func retryTransport(at now:TimeInterval) {
        guard isTransportSuspended,let activeID=id,let core,core.state != .stopped else { return }
        let nonce=resumeNonce
        // Lifecycle/UI callbacks may try to resume playback before the peer is
        // ready. Reassert ownership without resetting or restoring the game.
        if core.state == .running { pausedForTransport=true;_ = core.pause() }
        if core.state == .paused { core.deltaCore.emulatorBridge.resetInputs() }
        guard canResume?() ?? true else { return }
        if channel==nil,now-lastChannelAttempt>=1 {
            lastChannelAttempt=now
            guard bindTransportChannel() else { return }
        }
        guard channel != nil else { return }
        wire?.tick(at:now)
        if now-lastControl>=0.5 {
            lastControl=now
            _=emit(.resumeRequest,nonce:resumeNonce)
            guard id==activeID,isTransportSuspended,resumeNonce==nonce else { return }
            if let peerResumeNonce { sentResumeReady=emit(.resumeReady,nonce:resumeNonce,acknowledgement:peerResumeNonce) || sentResumeReady }
        }
        guard id==activeID,isTransportSuspended,resumeNonce==nonce,resumeAcknowledged,sentResumeReady else { return }
        isTransportSuspended=false;lastPeerControl=now;lastControl=0
        probe.resumeTransport()
        interactions?.activityProgress(played ? activity.title : "Connecting \(activity.rawValue)…",playing:played || activity == .trade && entryQueued)
        if pausedForTransport,core.state == .paused { _=core.resume() }
        pausedForTransport=false
    }
    func receive(_ data:Data) {
        guard let packet=BoundBattleControlPacket.decode(data) else { return }
        if packet.id != id {
            if let terminal=retired[packet.id],[.resumeRequest,.resumeReady,.prepared,.connected].contains(packet.kind) {
                if let bytes=BoundBattleControlPacket(id:packet.id,kind:terminal).encoded() { _=sendControl?(bytes) }
                return
            }
            // Ordered confirm/prepared messages can arrive together while our
            // native invitation is still closing. Keep only that consented ID.
            guard id==nil,let interactions,interactions.requestID==packet.id,
                  [.confirming,.agreed].contains(interactions.phase) else { return }
            if packet.kind == .prepared { earlyPreparation=packet.id; interactions.peerPreparedActivity() }
            else if packet.kind == .abort {
                earlyPreparation=nil; interactions.activityEnded("Your friend ended the interaction")
            }
            return
        }
        lastPeerControl=ProcessInfo.processInfo.systemUptime
        switch packet.kind {
        case .prepared: peerPrepared=true; interactions?.peerPreparedActivity()
        case .connected: peerConnected=true
        case .finished: peerFinished=true
        case .abort:
            lastFailure="Your friend ended the \(activity.rawValue)"
            finish(message:lastFailure,resume:true); return
        case .resumeRequest:
            guard let nonce=packet.nonce,!retiredResumeNonces.contains(nonce) else { return }
            if !isTransportSuspended {
                // A late retry from the just-completed handshake is answered
                // without repeatedly pausing the same recovered game.
                if peerResumeNonce==nonce {
                    _=emit(.resumeReady,nonce:resumeNonce,acknowledgement:nonce); return
                }
                suspendTransport()
            }
            if peerResumeNonce != nonce {
                if let peerResumeNonce { retiredResumeNonces=Array((retiredResumeNonces+[peerResumeNonce]).suffix(32)) }
                sentResumeReady=false;resumeAcknowledged=false
            }
            peerResumeNonce=nonce
            if channel==nil { _=bindTransportChannel() }
            sentResumeReady=emit(.resumeReady,nonce:resumeNonce,acknowledgement:nonce) || sentResumeReady
        case .resumeReady:
            guard isTransportSuspended,let nonce=packet.nonce,packet.acknowledgement==resumeNonce,
                  !retiredResumeNonces.contains(nonce) else { return }
            if peerResumeNonce != nonce {
                if let peerResumeNonce { retiredResumeNonces=Array((retiredResumeNonces+[peerResumeNonce]).suffix(32)) }
                sentResumeReady=false
            }
            peerResumeNonce=nonce;resumeAcknowledged=true
            // Requests and the retry timer send our acknowledgement. Replying
            // to a Ready here creates an unbounded echo with synchronous relays.
        }
        advance()
    }
    private func advance() {
        if recovery != nil { recoverIfRunning(); return }
        guard id != nil else { return }
        // The peer may already have closed its channel after completing. Its
        // retained terminal reply is sufficient once our native game finished.
        if localFinished && peerFinished {
            let outcome=observation?.outcome ?? 0
            if activity == .trade {
                finish(message:observation?.tradeCount ?? 0 > 0 ? "Trade complete · Pokémon saved" : "Trade ended",resume:true)
                return
            }
            finish(message:!played ? "Battle could not start" : outcome==1 ? "Battle won" : outcome==2 ? "Battle lost" : outcome==3 ? "Battle draw" : "Battle ended",resume:true)
            return
        }
        let now=ProcessInfo.processInfo.systemUptime
        if isTransportSuspended { retryTransport(at:now);return }
        wire?.tick(at:now)
        if now-lastControl>=1 {
            lastControl=now
            if localPrepared { _=emit(.prepared) }
            if localConnected { _=emit(.connected) }
            if localFinished { _=emit(.finished) }
        }
        if let value=probe.take() {
            observation=value
            if value.error { fail("Native \(activity.rawValue) connection failed"); return }
            if value.connected && localPrepared && peerPrepared && !localConnected { localConnected=true; _=emit(.connected) }
            if !value.connected && entryQueued { fail("\(activity.title) cable disconnected"); return }
            if (activity == .battle ? value.battle : value.tradeOpened) && !played {
                played=true
                interactions?.activityProgress(activity == .trade ? "Trade" : "Battle",playing:true)
            }
            // The remote game has finished and our native engine independently
            // has a result. Emulate its cable closure; never write an outcome.
            if activity == .battle,played,peerFinished,!peerLinkClosed,!value.returned,[1,2,3].contains(value.outcome) {
                peerLinkClosed=true; probe.disconnectFinishedPeer()
            }
            if value.returned && !localFinished {
                localFinished=true; _=emit(.finished)
            }
        }
        if now-lastPeerControl>2 || entryQueued && probe.networkAge>2 { suspendTransport(); return }
        if localConnected && peerConnected && !entryQueued {
            // Both receivers now exist. Sending sequence 1 before this barrier
            // loses it while the peer is still dismissing its native invitation.
            probe.enableSender()
            if activity == .trade {
                // Durable before any native trade code or input can run, including
                // when the main actor is delayed while emulation keeps advancing.
                do { try markTradeStarted() }
                catch { fail("Couldn’t protect the trade save"); return }
            }
            entryQueued=true; probe.enter(player:initiator ? 0:1)
            interactions?.activityProgress(activity == .trade ? "Use A to save and confirm the native trade link…" : "Starting battle…",playing:activity == .trade)
        }
    }
    private func markTradeStarted() throws {
        guard let journalURL,let bytes=try? BoundServerMemoryFiles.read(journalURL,gameID:gameID),
              var value=try JSONSerialization.jsonObject(with:bytes) as? [String:String] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        value["tradeStarted"]="true"
        try BoundServerMemoryFiles.write(JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),to:journalURL,gameID:gameID)
    }
    private func emit(_ kind:BoundBattleControlPacket.Kind,nonce:UUID?=nil,acknowledgement:UUID?=nil)->Bool {
        guard let id,let data=BoundBattleControlPacket(id:id,kind:kind,nonce:nonce,acknowledgement:acknowledgement).encoded() else { return false }
        return sendControl?(data)==true
    }
    func cancel(resume:Bool=true,source:String=#fileID,line:Int=#line) {
        earlyPreparation=nil
        guard id != nil else { return }
        lastCancellation="\(source):\(line)"
        _=emit(.abort); finish(message:"\(activity.title) ended",resume:resume)
    }
    private func fail(_ message:String) {
        guard id != nil else { return }
        lastFailure=message; _=emit(.abort); finish(message:message,resume:true)
    }
    private func finish(message:String,resume:Bool) {
        guard let finishedID = id else { return }
        retired[finishedID]=localFinished && peerFinished ? .finished:.abort
        retiredOrder.append(finishedID)
        if retiredOrder.count>32 { retired.removeValue(forKey:retiredOrder.removeFirst()) }
        id=nil; timer?.invalidate(); timer=nil
        isTransportSuspended=false;pausedForTransport=false;transportGeneration=UUID()
        // Fence background delivery before pausing the sole native RAM owner.
        lastCableDiagnostic=(wire?.diagnostics ?? "no wire")+" "+probe.diagnostics
        NSLog("Bound battle cable: %@",lastCableDiagnostic)
        channel?.close(); wire?.close(); channel=nil; wire=nil
        guard let core else { interactions?.activityEnded(message); return }
        if core.state == .running { _=core.pause() }
        // Inspect on the fenced frame owner before close clears the observation.
        // Even a delayed UI timer cannot roll back an already opened trade.
        let tradeWasOpened=activity == .trade && (played || BoundVBABattleBridge.advanceAndObserve()["tradeOpened"] as? Bool == true)
        probe.configure(core:nil)
        BoundVBABattleBridge.close()
        if tradeWasOpened {
            finishTrade(core:core,message:message,resume:resume, tradeID: finishedID)
            return
        }
        var didRestore=false
        var recovered=backupURL==nil
        if let backupURL,core.state != .stopped {
            do {
                try BoundServerMemoryFiles.loadState(core:core,from:backupURL,gameID:gameID)
                let check=BoundVBABattleBridge.advanceAndObserve()
                recovered=(check["callback"] as? Int)==0x080565B5 && (check["battle"] as? Bool)==false && BoundVBABattleBridge.verifyBattleReady()
                if recovered {
                    didRestore=true
                    // Remove the recovery instruction before its state. A crash
                    // between removals leaves an inert orphan, not a stale restore.
                    if let journalURL { try BoundServerMemoryFiles.remove(journalURL,gameID:gameID) }
                    try? BoundServerMemoryFiles.remove(backupURL,gameID:gameID)
                }
            } catch { recovered=false }
        }
        recoveryFailed = !recovered
        if recovered, activity == .battle { soulProbe?.setFriendlyBattleActive(false, for:core) }
        backupURL=nil; journalURL=nil; core.rate=originalRate
        interactions?.activityEnded(recovered ? message : "Recovery snapshot kept. Reopen this game to restore it.")
        if didRestore {
            if activity == .battle {
                restoredBattles += 1
                if played && localFinished && peerFinished { completedBattles += 1 }
            }
            restored?()
        }
        if recovered,resume,canResume?() ?? true,core.state == .paused { _=core.resume() }
    }
    private func finishTrade(core:EmulatorCore,message:String,resume:Bool, tradeID: UUID) {
        // Native trade owns party swap, mail, Dex, evolution and its linked save
        // protocol. Retain those changes; a battle-style state rollback duplicates
        // or destroys exchanged Pokémon. Interrupted trades boot the native save.
        let finished=localFinished && peerFinished && observation?.returned == true
        var success=finished
        if !finished { success=core.stop() && core.start() }
        core.rate=originalRate
        if success {
            if finished {
                let count = observation?.tradeCount ?? 0
                completedTrades += count
                if count > 0 { tradeCompleted?(tradeID, count) }
            }
            do {
                if let journalURL { try BoundServerMemoryFiles.remove(journalURL,gameID:gameID) }
                if let backupURL { try? BoundServerMemoryFiles.remove(backupURL,gameID:gameID) }
                self.journalURL=nil; self.backupURL=nil
                interactions?.activityEnded(finished ? message : "Trade interrupted. Continue from your in-game save.")
                restored?()
            } catch { success=false }
        }
        recoveryFailed = !success
        if !success { interactions?.activityEnded("Trade recovery kept. Reopen this game to continue from its in-game save.") }
        if !resume || !(canResume?() ?? true) { if core.state == .running { _=core.pause() } }
        else if success,core.state == .paused { _=core.resume() }
    }
    private func findRecovery() {
        guard let core else { return }
        do {
            let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
                .appendingPathComponent("Friend Battles",isDirectory:true)
            guard let files=try? BoundServerMemoryFiles.contents(folder,gameID:gameID) else { return }
            let candidates=files.filter { $0.pathExtension=="json" }.sorted {
                BoundServerMemoryFiles.modifiedAt($0,gameID:gameID)
                    > BoundServerMemoryFiles.modifiedAt($1,gameID:gameID)
            }
            for journal in candidates.prefix(64) {
                guard let bytes=try? BoundServerMemoryFiles.read(journal,gameID:gameID),bytes.count<=4096,
                      let value=try? JSONSerialization.jsonObject(with:bytes) as? [String:String],
                      value["gameID"]==gameID,value["rom"]==BoundPlayerROMProfile.supportedSHA256,
                      let name=value["state"],name==URL(fileURLWithPath:name).lastPathComponent,
                      UUID(uuidString:URL(fileURLWithPath:name).deletingPathExtension().lastPathComponent) != nil,
                      let digest=value["sha256"],digest.count==64 else { continue }
                var pending = Recovery(state:folder.appendingPathComponent(name),journal:journal,digest:digest,
                                       friendlyBattle:value["activity"] != "trade")
                if pending.friendlyBattle { soulProbe?.setFriendlyBattleActive(true, for:core) }
                if value["activity"] == "trade",value["tradeStarted"] == "true" {
                    // Bind runs before loading automatic states. Preserve the actual
                    // cartridge save, never flash data from a pre-trade save state.
                    recoveryFailed=true
                    let battery=try BoundServerMemoryFiles.battery(core:core,gameID:gameID)
                    guard battery.count == 131072 else {
                        interactions?.activityEnded("Trade save needs recovery. The original snapshots were kept.")
                        return
                    }
                    pending.tradeBattery=battery
                }
                recovery=pending
                recoveryFailed=false; probe.configure(core:core)
                let timer=Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.advance() } }
                RunLoop.main.add(timer,forMode:.common); self.timer=timer
                return
            }
        } catch {
            if recoveryFailed {
                lastFailure="Trade cartridge save could not be read"
                interactions?.activityEnded("Trade save needs recovery. The original snapshots were kept.")
            }
        }
    }
    private func recoverIfRunning() {
        guard let recovery,let core,core.state != .stopped,probe.take() != nil else { return }
        if core.state == .running { _=core.pause() }
        probe.configure(core:nil); BoundVBABattleBridge.close()
        do {
            let bytes=try BoundServerMemoryFiles.read(recovery.state,gameID:gameID)
            guard Self.hash(bytes)==recovery.digest else { throw CocoaError(.fileReadCorruptFile) }
            _=try BoundPlayerROMProfile(rom:Data(contentsOf:core.game.fileURL,options:.mappedIfSafe))
            if let battery=recovery.tradeBattery {
                guard core.stop() else { throw CocoaError(.fileReadUnknown) }
                if BoundServerMemoryFiles.isEnabled(for:gameID) {
                    guard core.start(),core.pause(),BoundVBABattleBridge.restoreServerBattery(battery) else { throw CocoaError(.fileReadUnknown) }
                } else {
                    try battery.write(to:core.game.gameSaveURL,options:.atomic)
                    guard core.start() else { throw CocoaError(.fileReadUnknown) }
                }
                try BoundServerMemoryFiles.remove(recovery.journal,gameID:gameID)
                try? BoundServerMemoryFiles.remove(recovery.state,gameID:gameID)
                self.recovery=nil; timer?.invalidate(); timer=nil
                interactions?.activityEnded("Continue from your in-game save after the interrupted trade.")
                if !(canResume?() ?? true) { _=core.pause() }
                else if core.state == .paused { _=core.resume() }
                return
            }
            try BoundServerMemoryFiles.loadState(core:core,from:recovery.state,gameID:gameID)
            let check=BoundVBABattleBridge.advanceAndObserve()
            guard (check["callback"] as? Int)==0x080565B5,(check["battle"] as? Bool)==false else { throw CocoaError(.fileReadCorruptFile) }
            try BoundServerMemoryFiles.remove(recovery.journal,gameID:gameID)
            try? BoundServerMemoryFiles.remove(recovery.state,gameID:gameID)
            self.recovery=nil; timer?.invalidate(); timer=nil
            if recovery.friendlyBattle { soulProbe?.setFriendlyBattleActive(false, for:core) }
            interactions?.activityEnded("Your game was restored after an interrupted friendly battle")
            restored?()
            if canResume?() ?? true,core.state == .paused { _=core.resume() }
        } catch {
            recoveryFailed=true; self.recovery=nil; timer?.invalidate(); timer=nil
            lastFailure="Recovery snapshot could not be loaded"
            interactions?.activityEnded("Couldn’t restore the recovery snapshot. The original snapshot was kept.")
        }
    }
    private static func hash(_ data:Data)->String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
}
