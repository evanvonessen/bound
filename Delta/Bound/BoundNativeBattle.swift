import Foundation
import CryptoKit
import DeltaCore
import UIKit

struct BoundBattleControlPacket:Codable {
    static let prefix=Data([0x42,0x46,0x42,0x31]) // BFB1
    enum Kind:String,Codable { case prepared,connected,finished,ranAway,abort,resumeRequest,resumeReady }
    let id:UUID
    let kind:Kind
    var nonce:UUID? = nil
    var acknowledgement:UUID? = nil
    var battleProtocol:Int? = nil
    var battleResult:UInt32? = nil
    var terminalReceipt:Bool? = nil
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
    /// A retired activity answers a lost final result immediately. Receipts
    /// are one-way replies, so two retired peers cannot echo them forever.
    func retainedReply(to request:Self)->Self? {
        guard id==request.id,[.finished,.ranAway,.abort].contains(kind),
              [.resumeRequest,.resumeReady,.prepared,.connected].contains(request.kind)
                || request.kind == .finished && request.terminalReceipt != true else { return nil }
        var reply=self;reply.terminalReceipt=true;return reply
    }
}

/// Result-file retries are separate from the gameplay outcome. A temporary
/// write error cannot turn an already verified battle result into an abort.
struct BoundBattleTerminalPersistence {
    private(set) var needsRetry=false
    mutating func save(_ packet:BoundBattleControlPacket,write:(Data)throws->Void) throws {
        do {
            try write(BoundBattleControlPacket.prefix + JSONEncoder().encode(packet))
            needsRetry=false
        } catch { needsRetry=true;throw error }
    }
}

struct BoundNativeBattleObservation:Sendable,Codable {
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
    let runRequested:Bool
    let decisionError:Int?
    let decisionsSent:Int?
    let decisionsReceived:Int?
    let decisionFrames:Int?
    let terminalFingerprint:UInt32?
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
        runRequested=values["runRequested"] as? Bool ?? false
        decisionError=values["decisionError"] as? Int
        decisionsSent=values["decisionsSent"] as? Int
        decisionsReceived=values["decisionsReceived"] as? Int
        decisionFrames=values["decisionFrames"] as? Int
        terminalFingerprint=values["terminalFingerprint"] as? UInt32
    }
}

/// A device-local continuation can only rejoin the same authenticated run.
struct BoundNativeContinuationContext:Codable,Equatable {
    let owner:UUID
    let roomID:String
    let runID:UUID?
    init(owner:UUID,roomID:String,runID:UUID?) {
        self.owner=owner;self.roomID=roomID.lowercased();self.runID=runID
    }
    var valid:Bool { UUID(uuidString:roomID) != nil }
}

struct BoundContinuationHeads:Codable,Equatable {
    let checkpoints:Set<UUID>
    let permitsNoCheckpoint:Bool
    func permits(_ checkpoint:UUID?)->Bool { checkpoint.map { checkpoints.contains($0) } ?? permitsNoCheckpoint }
}
struct BoundContinuationSettlement {
    let ticket:UUID,claimant:UUID,context:BoundNativeContinuationContext,gameID:String
}
enum BoundContinuationError:LocalizedError {
    case consumed,serverChanged
    var errorDescription:String? {
        switch self {
        case .consumed:return "An interrupted activity needs recovery. Your server save was kept."
        case .serverChanged:return "This activity belongs to an earlier server save. Its recovery was kept."
        }
    }
}
protocol BoundActivityContinuation:Codable {
    var ticket:UUID { get };var context:BoundNativeContinuationContext { get };var gameID:String { get };var activityID:UUID { get };var valid:Bool { get }
}
struct BoundNativeContinuation:BoundActivityContinuation {
    let version:Int,ticket:UUID,context:BoundNativeContinuationContext,gameID:String,rom:String,cartridge:String,id:UUID
    let activity:BoundFriendInteractionPacket.Activity,initiator:Bool,rate:Double
    let localPrepared:Bool,peerPrepared:Bool,localConnected:Bool,peerConnected:Bool,entryQueued:Bool
    let localFinished:Bool,peerFinished:Bool,played:Bool,peerLinkClosed:Bool
    let observation:BoundNativeBattleObservation?
    let state:Data,battery:Data,bridge:Data,probe:Data,wire:Data,backup:Data,journal:Data
    let memoryFiles:[String:Data]
    let heads:BoundContinuationHeads?
    var peerBattleResult:UInt32? = nil
    var activityID:UUID { id }
    var valid:Bool {
        version==1 && context.valid && (context.runID==nil || heads != nil) && !gameID.isEmpty && gameID.utf8.count<=512
            && MultiRedAdapter.profile(romSHA256:rom) != nil && cartridge.count==64 && cartridge.allSatisfy({ $0.isHexDigit }) && rate.isFinite && rate>0 && rate<=32
            && state.count>1024 && state.count<=16_777_216 && battery.count==131072
            && !bridge.isEmpty && bridge.count<=8192 && probe.count<=32768 && wire.count<=400_000
            && backup.count>1024 && backup.count<=16_777_216 && journal.count<=4096
            && memoryFiles.count<=256 && memoryFiles.values.reduce(0,{ $0+$1.count })<=16_777_216
    }
}

/// Never uploaded as a world save. A durable claim makes an old execution
/// unusable before any ACK or native frame can advance after reopening it.
struct BoundNativeContinuationStore {
    private struct Claim:Codable { let ticket:UUID,claimant:UUID;let settled:Bool }
    private static let claimLock=NSLock()
    let root:URL
    init(root:URL=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        .appendingPathComponent("Native Activity Continuations",isDirectory:true)) { self.root=root }
    private func url(context:BoundNativeContinuationContext,gameID:String,extension suffix:String)->URL {
        let key=context.owner.uuidString+"|"+context.roomID+"|"+(context.runID?.uuidString ?? "")+"|"+gameID
        let hash=SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()
        return root.appendingPathComponent(hash).appendingPathExtension(suffix)
    }
    private func readClaim(_ path:URL) throws -> Claim? {
        guard FileManager.default.fileExists(atPath:path.path) else { return nil }
        guard (try path.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=1024 else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(Claim.self,from:Data(contentsOf:path))
    }
    private func write(_ data:Data,to path:URL) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try data.write(to:path,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        let handle=try FileHandle(forWritingTo:path);defer { try? handle.close() };try handle.synchronize()
        var directory=root,values=URLResourceValues();values.isExcludedFromBackup=true
        try directory.setResourceValues(values)
    }
    func save<Value:BoundActivityContinuation>(_ value:Value) throws {
        guard value.valid else { throw CocoaError(.fileWriteInvalidFileName) }
        try write(JSONEncoder().encode(value),to:url(context:value.context,gameID:value.gameID,extension:"json"))
    }
    func load(context:BoundNativeContinuationContext,gameID:String) throws -> BoundNativeContinuation? {
        try load(context:context,gameID:gameID,as:BoundNativeContinuation.self)
    }
    func load<Value:BoundActivityContinuation>(context:BoundNativeContinuationContext,gameID:String,as type:Value.Type) throws -> Value? {
        let path=url(context:context,gameID:gameID,extension:"json")
        guard FileManager.default.fileExists(atPath:path.path) else { return nil }
        guard (try path.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=72_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        let value=try JSONDecoder().decode(type,from:Data(contentsOf:path))
        guard value.valid,value.context==context,value.gameID==gameID else { throw CocoaError(.fileReadCorruptFile) }
        let claim=try readClaim(url(context:context,gameID:gameID,extension:"claim"))
        if claim?.ticket==value.ticket {
            guard claim?.settled==true else { throw BoundContinuationError.consumed }
            return nil
        }
        if try terminal(id:value.activityID,context:context,gameID:gameID) != nil { throw BoundContinuationError.consumed }
        return value
    }
    func settlement(context:BoundNativeContinuationContext,gameID:String) throws -> BoundContinuationSettlement? {
        guard let claim=try readClaim(url(context:context,gameID:gameID,extension:"claim")),!claim.settled else { return nil }
        return BoundContinuationSettlement(ticket:claim.ticket,claimant:claim.claimant,context:context,gameID:gameID)
    }
    func settle(_ token:BoundContinuationSettlement) throws {
        Self.claimLock.lock();defer { Self.claimLock.unlock() }
        let path=url(context:token.context,gameID:token.gameID,extension:"claim")
        guard let claim=try readClaim(path),claim.ticket==token.ticket,claim.claimant==token.claimant else { return }
        try write(JSONEncoder().encode(Claim(ticket:claim.ticket,claimant:claim.claimant,settled:true)),to:path)
    }
    private struct Terminal:Codable { let id:UUID,data:Data }
    private func terminals(context:BoundNativeContinuationContext,gameID:String) throws -> [Terminal] {
        let path=url(context:context,gameID:gameID,extension:"terminals")
        guard FileManager.default.fileExists(atPath:path.path) else { return [] }
        guard (try path.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=400_000 else { throw CocoaError(.fileReadCorruptFile) }
        let values=try JSONDecoder().decode([Terminal].self,from:Data(contentsOf:path))
        guard values.count<=32,values.allSatisfy({ $0.data.count<=8192 }) else { throw CocoaError(.fileReadCorruptFile) }
        return values
    }
    func terminal(id:UUID,context:BoundNativeContinuationContext,gameID:String) throws -> Data? {
        try terminals(context:context,gameID:gameID).first(where:{ $0.id==id })?.data
    }
    func saveTerminal(id:UUID,data:Data,context:BoundNativeContinuationContext,gameID:String) throws {
        guard context.valid,data.count<=8192 else { throw CocoaError(.fileWriteInvalidFileName) }
        var values=try terminals(context:context,gameID:gameID).filter { $0.id != id }
        values.append(Terminal(id:id,data:data));values=Array(values.suffix(32))
        try write(JSONEncoder().encode(values),to:url(context:context,gameID:gameID,extension:"terminals"))
    }
    func claim(ticket:UUID,context:BoundNativeContinuationContext,gameID:String,claimant:UUID=UUID()) throws {
        Self.claimLock.lock();defer { Self.claimLock.unlock() }
        let path=url(context:context,gameID:gameID,extension:"claim")
        let previous=try readClaim(path)
        if let previous,previous.ticket==ticket,previous.claimant != claimant { throw CocoaError(.fileWriteNoPermission) }
        try write(JSONEncoder().encode(Claim(ticket:ticket,claimant:claimant,settled:false)),to:path)
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
    private var incomingDecisions=Data()
    private var usesDecisions=false
    private var blockAdmission=BoundNativeBlockAdmission()
    private var peerGeneration:UInt16=0,receivedGeneration:UInt16=0,announcedGeneration:UInt16=0,lastAcceptedSequence:UInt16=0
    private var pendingAcknowledgement=Data(),lastAcknowledgement=Data()
    private var sentHistory=Data(repeating:0,count:32),receivedHistory=Data(repeating:0,count:32)
    private var sender:(@Sendable (Data)->Bool)?
    private var senderEnabled=false
    private var failed:(@Sendable ()->Void)?
    private var interrupted:(@Sendable ()->Void)?
    private var transportSuspended=false
    private var lastSent:TimeInterval=0
    private var lastReceived=ProcessInfo.processInfo.systemUptime
    private var sentCommands=0,receivedCommands=0
    private var sentDecisions=0,receivedDecisions=0,nativeBlocksAfterDecision=0
    func configure(core:EmulatorCore?,decisions:Bool=false) {
        lock.lock(); defer { lock.unlock() }
        coreID=core.map(ObjectIdentifier.init); entryPlayer=nil; peerDisconnectPending=false; latest=nil; frame=0
        incoming.removeAll(); blockAdmission=BoundNativeBlockAdmission(); sender=nil; senderEnabled=false; failed=nil; lastSent=0
        incomingDecisions.removeAll();usesDecisions=decisions
        interrupted=nil;transportSuspended=false
        peerGeneration=0; receivedGeneration=0; announcedGeneration=0;lastAcceptedSequence=0
        pendingAcknowledgement.removeAll(); lastAcknowledgement.removeAll()
        sentHistory=Data(repeating:0,count:32);receivedHistory=Data(repeating:0,count:32)
        lastReceived=ProcessInfo.processInfo.systemUptime; sentCommands=0; receivedCommands=0
        sentDecisions=0;receivedDecisions=0;nativeBlocksAfterDecision=0
    }
    func setSender(_ sender:@escaping @Sendable (Data)->Bool,failed:@escaping @Sendable ()->Void,
                   interrupted:(@Sendable ()->Void)? = nil) {
        lock.lock(); self.sender=sender; self.failed=failed; self.interrupted=interrupted; lock.unlock()
    }
    func suspendTransport() { lock.lock(); transportSuspended=true; lock.unlock() }
    /// Called with the retained core paused, before resuming its frame owner.
    func resumeTransport() {
        lock.lock(); transportSuspended=false
        lastReceived=ProcessInfo.processInfo.systemUptime;lastSent=0;announcedGeneration=0;lastAcknowledgement=Data()
        lock.unlock()
    }
    func enableSender() {
        lock.lock(); senderEnabled=true; lastReceived=ProcessInfo.processInfo.systemUptime; lock.unlock()
    }
    func receiveNetworkPacket(_ packet:Data)->Bool {
        if packet.first == 4 {
            guard let records=BoundBattleDecisionPacket.decode(packet) else { return false }
            lock.lock();defer { lock.unlock() }
            guard usesDecisions,coreID != nil,incomingDecisions.count+records.count<=32*32 else { return false }
            incomingDecisions.append(records)
            receivedDecisions+=records.count/32
            for start in stride(from:0,to:records.count,by:32) {
                receivedHistory=Data(SHA256.hash(data:receivedHistory+Data([4])+records.subdata(in:start..<start+32)))
            }
            lastReceived=ProcessInfo.processInfo.systemUptime;return true
        }
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
        let entryPlayer:Int?
        let senderEnabled:Bool?
        let peerDisconnectPending:Bool?
        let frame:UInt64?
        let decisions:Data?
        let usesDecisions:Bool?
    }
    /// Captured after the core and network wire are fenced. Native mailbox and
    /// host continuation admission are one recovery transaction.
    func recoveryData()->Data {
        lock.lock();defer { lock.unlock() }
        return (try? JSONEncoder().encode(RecoveryState(incoming:incoming,remaining:blockAdmission.recoveryRemaining,
            peerGeneration:peerGeneration,receivedGeneration:receivedGeneration,lastAcceptedSequence:lastAcceptedSequence,
            pendingAcknowledgement:pendingAcknowledgement,sentHistory:sentHistory,receivedHistory:receivedHistory,
            entryPlayer:entryPlayer,senderEnabled:senderEnabled,peerDisconnectPending:peerDisconnectPending,frame:frame,
            decisions:incomingDecisions,usesDecisions:usesDecisions))) ?? Data()
    }
    func restoreRecoveryData(_ bytes:Data)->Bool {
        guard bytes.count<=32768,let value=try? JSONDecoder().decode(RecoveryState.self,from:bytes),
              value.incoming.count<=10240,value.incoming.count%20==0,
              [0,4].contains(value.pendingAcknowledgement.count),value.sentHistory.count==32,value.receivedHistory.count==32,
              value.entryPlayer == nil || [0,1].contains(value.entryPlayer!),
              (value.decisions?.count ?? 0)<=1024,(value.decisions?.count ?? 0)%32==0,
              (value.usesDecisions ?? false)==usesDecisions,
              let admission=BoundNativeBlockAdmission(recoveryRemaining:value.remaining) else { return false }
        lock.lock();defer { lock.unlock() }
        incoming=value.incoming;blockAdmission=admission;peerGeneration=value.peerGeneration
        incomingDecisions=value.decisions ?? Data()
        receivedGeneration=value.receivedGeneration;lastAcceptedSequence=value.lastAcceptedSequence
        pendingAcknowledgement=value.pendingAcknowledgement;announcedGeneration=0;lastAcknowledgement=Data()
        sentHistory=value.sentHistory;receivedHistory=value.receivedHistory
        entryPlayer=value.entryPlayer;senderEnabled=value.senderEnabled ?? senderEnabled
        peerDisconnectPending=value.peerDisconnectPending ?? false;frame=value.frame ?? frame
        lastReceived=ProcessInfo.processInfo.systemUptime
        return true
    }
    static func recoveryIsQuiescent(_ bytes:Data,mailbox:Data)->Bool {
        guard bytes.count<=32768,mailbox.count==1176,
              let value=try? JSONDecoder().decode(RecoveryState.self,from:bytes),
              value.incoming.isEmpty,value.remaining==0,value.pendingAcknowledgement.isEmpty,
              value.decisions?.isEmpty != false,
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
    var decisionDiagnostics:[String:Int] {
        lock.lock();defer { lock.unlock() }
        return ["sent":sentDecisions,"received":receivedDecisions,"nativeBlocksAfterDecision":nativeBlocksAfterDecision]
    }
    func disconnectFinishedPeer() { lock.lock(); peerDisconnectPending=true; lock.unlock() }
    func enter(player:Int) { lock.lock(); entryPlayer=player; lock.unlock() }
    func receive(_ core:EmulatorCore) {
        lock.lock()
        guard coreID==ObjectIdentifier(core) else { lock.unlock(); return }
        let player=transportSuspended ? nil:entryPlayer
        if !transportSuspended { entryPlayer=nil }
        let disconnectPeer=peerDisconnectPending; peerDisconnectPending=false
        let send=senderEnabled ? sender:nil,failure=failed
        let connectedTransport = !transportSuspended
        lock.unlock()
        if let player { _=BoundVBABattleBridge.installBattle(forPlayer:UInt(player)) }
        if disconnectPeer { BoundVBABattleBridge.requestPeerDisconnect() }
        lock.lock()
        if !transportSuspended { BoundVBABattleBridge.setPeerGeneration(UInt(peerGeneration)) }
        if !transportSuspended,pendingAcknowledgement.count==4 {
            let ack=pendingAcknowledgement
            BoundVBABattleBridge.acknowledgeGeneration(UInt(ack[0])|UInt(ack[1])<<8,sequence:UInt(ack[2])|UInt(ack[3])<<8)
            pendingAcknowledgement.removeAll()
        }
        let pending=Data(incoming.prefix(260))
        if !transportSuspended,!pending.isEmpty {
            let accepted=Int(BoundVBABattleBridge.receiveCommands(pending))
            if accepted>0 { incoming.removeFirst(accepted) }
        }
        if !transportSuspended,!incomingDecisions.isEmpty {
            let accepted=Int(BoundVBABattleBridge.receiveDecisions(Data(incomingDecisions.prefix(256))))
            if accepted>0 { incomingDecisions.removeFirst(accepted) }
        }
        lock.unlock()
        let generation=UInt16(BoundVBABattleBridge.connectionGeneration())
        let outgoing=BoundVBABattleBridge.takeOutgoingCommands()
        var delivered=0,bad=false,didSend=false
        let decisions=usesDecisions ? BoundVBABattleBridge.takeOutgoingDecisions():Data()
        if !decisions.isEmpty {
            if let packet=BoundBattleDecisionPacket.encode(decisions),send?(packet)==true {
                lock.lock()
                for start in stride(from:0,to:decisions.count,by:32) {
                    sentHistory=Data(SHA256.hash(data:sentHistory+Data([4])+decisions.subdata(in:start..<start+32)))
                }
                sentDecisions+=decisions.count/32
                lock.unlock();didSend=true
            } else { bad=true }
        }
        let acknowledged=BoundVBABattleBridge.peerAcknowledgement()
        if !acknowledged.isEmpty,acknowledged != lastAcknowledgement,send != nil {
            if send?(Data([3])+acknowledged)==true { lastAcknowledgement=acknowledged; didSend=true } else { bad=true }
        }
        if generation>announcedGeneration,send != nil {
            if send?(BoundNativeCommandPacket.connection(generation))==true { announcedGeneration=generation; didSend=true }
            else { bad=true }
        }
        if !outgoing.isEmpty {
            if let batches=BoundNativeCommandPacket.batches(outgoing) {
                for batch in batches {
                    guard send?(batch.packet)==true else {
                        NSLog("Bound native command batch send failed");bad=true;break
                    }
                    lock.lock()
                    for start in stride(from:0,to:batch.records.count,by:20) {
                        sentHistory=Data(SHA256.hash(data:sentHistory+batch.records.subdata(in:start..<start+20)))
                        if usesDecisions,sentDecisions>0,batch.records[start+4]==0xBB,batch.records[start+5]==0xBB {
                            nativeBlocksAfterDecision+=1
                        }
                    }
                    lock.unlock()
                    delivered+=batch.commandCount;didSend=true
                }
            } else { NSLog("Bound native command records are invalid");bad=true }
        } else if connectedTransport,send != nil,ProcessInfo.processInfo.systemUptime-lastSent>=1 {
            if send?(Data([0])) != true { bad=true } else { didSend=true }
        }
        let values=BoundVBABattleBridge.advanceAndObserve()
        lock.lock()
        if didSend { lastSent=ProcessInfo.processInfo.systemUptime }
        sentCommands+=delivered; frame &+= 1
        latest = .init(frame:frame,values:values)
        // The guest throttles its send callback at 16 records while continuing
        // to consume remote commands. Congestion is not a disconnect; the
        // session's monotonic-clock liveness check handles actual outages.
        lock.unlock()
        if bad { failure?() }
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
    private var peerBattleResult:UInt32?
    private var terminalPersistence=BoundBattleTerminalPersistence()
    private struct PendingFinish { let packet:BoundBattleControlPacket;let message:String;let resume:Bool }
    private var pendingFinish:PendingFinish?
    #if DEBUG
    var beforeTerminalWriteForTesting:(()throws->Void)?
    #endif
    private(set) var isTransportSuspended=false
    var activityID:UUID? { id }
    private var pausedForTransport=false
    private var transportGeneration=UUID(),resumeNonce=UUID()
    private var peerResumeNonce:UUID?
    private var retiredResumeNonces:[UUID]=[]
    private var resumeAcknowledged=false,sentResumeReady=false
    private var lastControl:TimeInterval=0,lastPeerControl=ProcessInfo.processInfo.systemUptime,lastChannelAttempt:TimeInterval=0
    private var retired:[UUID:BoundBattleControlPacket]=[:]
    private var retiredOrder:[UUID]=[]
    private var backupURL:URL?
    private var journalURL:URL?
    private var originalRate=1.0
    var continuationContext:BoundNativeContinuationContext?
    var continuationContextProvider:(()->BoundNativeContinuationContext?)?
    var continuationHeadsProvider:((BoundNativeContinuationContext)->BoundContinuationHeads?)?
    private var pendingSettlement:BoundContinuationSettlement?
    func continuationSettlement()->BoundContinuationSettlement? { !isActive && !recoveryFailed ? pendingSettlement:nil }
    func settleContinuation(_ token:BoundContinuationSettlement) throws { try continuationStore.settle(token) }
    static func settlePersistedContinuation(_ token:BoundContinuationSettlement) throws { try BoundNativeContinuationStore().settle(token) }
    private var activeContinuationContext:BoundNativeContinuationContext?
    private var continuationTicket:UUID?
    private var continuationWriteBlocked=false
    private let continuationStore=BoundNativeContinuationStore()
    private let continuationClaimant=UUID()
    var hasSavedContinuation:Bool { continuationTicket != nil }
    private struct Recovery { let state:URL; let journal:URL; let digest:String; let friendlyBattle:Bool; var tradeBattery:Data? = nil }
    private var recovery:Recovery?
    private var recoveryFailed=false
    private(set) var observation:BoundNativeBattleObservation?
    private(set) var lastCancellation=""
    private(set) var lastFailure=""
    private(set) var lastCableDiagnostic=""
    private(set) var lastDecisionDiagnostics:[String:Int]=[:]
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
    var blocksCoreResume:Bool { pausedForTransport || continuationTicket != nil || continuationWriteBlocked || recoveryFailed }
    var blocksAutoSave:Bool { protectsTemporaryState || interactions?.nativeDialogueBusy == true }

    private func contractSHA256(for core: EmulatorCore) throws -> String {
        let hash = Self.hash(try Data(contentsOf: core.game.fileURL, options: .mappedIfSafe))
        return try contractSHA256(cartridge: hash)
    }
    private func contractSHA256(cartridge: String) throws -> String {
        if let profile=MultiRedAdapter.profile(romSHA256:cartridge) { return profile.romSHA256 }
        // Preserve the ordinary unmarked base-ROM native path and its existing
        // continuation marker. Unknown files must never inherit that marker.
        guard cartridge=="689299664a954c12dad66e03c2d18446b348cb31bd98b395c87b9b514b288066" else {
            throw MultiRedAdapter.Failure.unsupportedROM
        }
        return BoundWorldContract.romSHA256
    }
    func bind(core:EmulatorCore?,gameID:String,interactions:BoundFriendInteractionSession) {
        if self.core !== core || self.gameID != gameID {
            if recovery != nil { timer?.invalidate(); timer=nil; recovery=nil; probe.configure(core:nil) }
            if continuationTicket != nil { detachSavedContinuation() }
            else { cancel(resume:false) }
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
        originalRate=core.rate;activeContinuationContext=continuationContext ?? continuationContextProvider?()
        continuationTicket=nil;continuationWriteBlocked=false
        self.id=id; self.activity=activity; self.initiator=initiator; lastFailure=""; lastCancellation=""; observation=nil
        localPrepared=false; peerPrepared=earlyPreparation==id; earlyPreparation=nil; localConnected=false; peerConnected=false
        localFinished=false; peerFinished=false; entryQueued=false; played=false; peerLinkClosed=false
        isTransportSuspended=false;pausedForTransport=false;peerResumeNonce=nil
        peerBattleResult=nil
        terminalPersistence=BoundBattleTerminalPersistence()
        pendingFinish=nil
        retiredResumeNonces.removeAll()
        resumeAcknowledged=false;sentResumeReady=false;lastControl=0;lastPeerControl=ProcessInfo.processInfo.systemUptime
        interactions?.activityProgress(activity == .trade ? "Connecting trade…" : "Connecting battle…",playing:false)
        guard core.pause(),BoundVBABattleBridge.verifyBattleEntryReady() else { fail("Game is not ready for a link \(activity.rawValue)"); return }
        do { try soulProbe?.prepareCheckpoint(core:core) }
        catch {
            lastFailure="Soul Link needs recovery before this activity. Keep the game paused."
            _=emit(.abort);finish(message:lastFailure,resume:false,terminal:.abort);return
        }
        if activity == .battle { soulProbe?.setFriendlyBattleActive(true, for:core) }
        if activity == .trade { core.rate=core.deltaCore.supportedRates.lowerBound }
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
            let value:[String:Any]=["gameID":gameID,"rom":try contractSHA256(for:core),
                "state":backup.lastPathComponent,"sha256":Self.hash(bytes),"activity":activity.rawValue]
            try BoundServerMemoryFiles.write(JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),to:journal,gameID:gameID)
            journalURL=journal
            if !BoundServerMemoryFiles.isEnabled(for:gameID) {
                var resource=URLResourceValues(); resource.isExcludedFromBackup=true
                var protectedFolder=folder; try protectedFolder.setResourceValues(resource)
            }
        } catch { fail("Couldn’t prepare a recovery snapshot"); return }
        probe.configure(core:core,decisions:activity == .battle)
        configureWire(id:id)
        let prepared = activity == .trade ? MultiRedAdapter.prepareTrade(player:initiator ? 0:1)
            : MultiRedAdapter.prepareBattle(player:initiator ? 0:1)
        guard prepared else {
            fail("Couldn’t prepare the native \(activity.rawValue) link"); return
        }
        if activity == .battle {
            BoundVBABattleBridge.configureDecisions(withSeed:Self.decisionSeed(id))
        }
        localPrepared=true
        _=core.resume()
        let timer=Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.advance() } }
        RunLoop.main.add(timer,forMode:.common); self.timer=timer
        if bindTransportChannel() { _=emit(.prepared) } else { suspendTransport() }
        advance()
    }
    private func configureWire(id:UUID) {
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
        let safeWire=BoundBattleWire(id:id,receive:{ [probe] bytes in
            if !probe.receiveNetworkPacket(bytes) { failure() }
        },failed:failure,interrupted:interrupted)
        self.wire=safeWire
        probe.setSender({ bytes in safeWire.send(bytes) },failed:failure,interrupted:interrupted)
    }
    private static func decisionSeed(_ id:UUID)->UInt {
        var bytes=id.uuid
        let digest=withUnsafeBytes(of:&bytes) { SHA256.hash(data:Data($0)) }
        let seed=digest.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element)<<($1.offset*8) }
        return UInt(seed == 0 ? 1:seed)
    }
    private func startTimer() {
        timer?.invalidate()
        let timer=Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.advance() } }
        RunLoop.main.add(timer,forMode:.common);self.timer=timer
    }
    /// Legacy local-save launch has no authorized pre-start continuation loader.
    /// Keep a durable fence so its old rollback path cannot silently replace an
    /// interrupted trade while the user is outside the resident game.
    func protectLocalLifecycle()->Bool {
        if let pending=pendingFinish {
            finish(message:pending.message,resume:pending.resume,terminal:pending.packet.kind)
            if pendingFinish != nil { return false }
        }
        guard id != nil else { return true }
        suspendTransport();pauseForContinuation()
        do {
            guard let journalURL,let bytes=try? BoundServerMemoryFiles.read(journalURL,gameID:gameID),
                  var value=try JSONSerialization.jsonObject(with:bytes) as? [String:String] else { throw CocoaError(.fileReadCorruptFile) }
            value["localContinuation"]="true"
            try BoundServerMemoryFiles.write(JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),to:journalURL,gameID:gameID)
            return true
        } catch { lastFailure="Couldn’t protect this activity. Keep the game open.";return false }
    }
    func showLocalExitUnavailable() {
        lastFailure="Keep this local save open to continue the activity."
        interactions?.activityProgress(lastFailure,playing:false)
    }
    /// A Menu/background checkpoint is the exact native execution, including
    /// reliable packet counters. World checkpoints deliberately exclude it.
    @discardableResult func checkpointForContinuation()->Bool {
        if let pending=pendingFinish {
            finish(message:pending.message,resume:pending.resume,terminal:pending.packet.kind)
            if pendingFinish != nil { return false }
        }
        guard let id else { return !recoveryFailed }
        if continuationTicket != nil { return true }
        suspendTransport()
        pauseForContinuation()
        guard let core,core.state == .paused,let context=activeContinuationContext,context.valid,
              let wire,let backupURL,let journalURL else {
            lastFailure="Keep this game open until its activity can be saved";return false
        }
        do {
            continuationWriteBlocked=true
            try soulProbe?.prepareCheckpoint(core:core)
            let transport=try wire.freezeForContinuation()
            let cartridge=Self.hash(try Data(contentsOf:core.game.fileURL,options:.mappedIfSafe))
            let value=BoundNativeContinuation(version:1,ticket:UUID(),context:context,gameID:gameID,
                rom:try contractSHA256(cartridge:cartridge),cartridge:cartridge,id:id,activity:activity,initiator:initiator,rate:activity == .battle ? core.rate:originalRate,
                localPrepared:localPrepared,peerPrepared:peerPrepared,localConnected:localConnected,peerConnected:peerConnected,
                entryQueued:entryQueued,localFinished:localFinished,peerFinished:peerFinished,played:played,peerLinkClosed:peerLinkClosed,
                observation:observation,state:MultiRedAdapter.captureState(),battery:BoundVBABattleBridge.captureServerBattery(),
                bridge:BoundVBABattleBridge.captureNativeSession(),probe:probe.recoveryData(),wire:transport,
                backup:try BoundServerMemoryFiles.read(backupURL,gameID:gameID),journal:try BoundServerMemoryFiles.read(journalURL,gameID:gameID),
                memoryFiles:BoundServerMemoryFiles.snapshot(gameID:gameID),heads:continuationHeadsProvider?(context),peerBattleResult:peerBattleResult)
            try continuationStore.save(value)
            continuationTicket=value.ticket;continuationWriteBlocked=false
            return true
        } catch {
            // An atomic write can succeed before its flush reports an error.
            // Keep execution frozen until a complete replacement is durable;
            // thawing here could leave a replayable snapshot of a live trade.
            lastFailure="Couldn’t save this activity. Keep the game open and try again."
            interactions?.activityProgress(lastFailure,playing:false)
            return false
        }
    }
    /// Called after the authorized run has loaded, while its core is paused.
    /// Restoring does not consume the record until the user returns to gameplay.
    @discardableResult func restoreContinuationIfAvailable(serverHead:UUID?=nil) throws -> Bool {
        if id != nil { return true }
        guard let core,core.state == .paused,let context=continuationContext else { return false }
        guard let value=try continuationStore.load(context:context,gameID:gameID) else { return false }
        guard context.runID==nil || value.heads?.permits(serverHead)==true else { throw BoundContinuationError.serverChanged }
        let cartridge=Self.hash(try Data(contentsOf:core.game.fileURL,options:.mappedIfSafe))
        guard value.rom == (try contractSHA256(cartridge:cartridge)), value.cartridge==cartridge else { throw CocoaError(.fileReadCorruptFile) }
        try soulProbe?.prepareForNativeMemoryReplacement(core:core)
        timer?.invalidate();timer=nil;recovery=nil;probe.configure(core:nil)
        BoundVBABattleBridge.close()
        do {
            guard MultiRedAdapter.restoreState(value.state),
                  BoundVBABattleBridge.restoreServerBattery(value.battery),
                  BoundVBABattleBridge.restoreNativeSession(value.bridge) else { throw CocoaError(.fileReadCorruptFile) }
            if value.activity == .battle { BoundVBABattleBridge.configureDecisions(withSeed:Self.decisionSeed(value.id)) }
            if BoundServerMemoryFiles.isEnabled(for:gameID) { try BoundServerMemoryFiles.restore(value.memoryFiles,gameID:gameID) }
            let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
                .appendingPathComponent("Friend Battles",isDirectory:true)
            try BoundServerMemoryFiles.directory(folder,gameID:gameID)
            let backup=folder.appendingPathComponent(value.id.uuidString+".state")
            let journal=folder.appendingPathComponent(value.id.uuidString+".json")
            guard let metadata=try JSONSerialization.jsonObject(with:value.journal) as? [String:String],
                  metadata["gameID"]==gameID,metadata["rom"]==value.rom,metadata["state"]==backup.lastPathComponent,
                  metadata["sha256"]==Self.hash(value.backup),metadata["activity"]==value.activity.rawValue else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try BoundServerMemoryFiles.write(value.backup,to:backup,gameID:gameID)
            try BoundServerMemoryFiles.write(value.journal,to:journal,gameID:gameID)
            probe.configure(core:core,decisions:value.activity == .battle);configureWire(id:value.id)
            guard probe.restoreRecoveryData(value.probe),wire?.restoreContinuation(value.wire)==true else { throw CocoaError(.fileReadCorruptFile) }
            id=value.id;activity=value.activity;initiator=value.initiator;originalRate=value.rate
            localPrepared=value.localPrepared;peerPrepared=value.peerPrepared;localConnected=value.localConnected;peerConnected=value.peerConnected
            entryQueued=value.entryQueued;localFinished=value.localFinished;peerFinished=value.peerFinished;played=value.played;peerLinkClosed=value.peerLinkClosed
            peerBattleResult=value.peerBattleResult
            observation=value.observation;backupURL=backup;journalURL=journal;recoveryFailed=false
            activeContinuationContext=context;continuationTicket=value.ticket;continuationWriteBlocked=false
            core.rate=activity == .battle ? value.rate:core.deltaCore.supportedRates.lowerBound
            isTransportSuspended=true;pausedForTransport=true;resumeNonce=UUID();peerResumeNonce=nil;retiredResumeNonces=[]
            resumeAcknowledged=false;sentResumeReady=false;lastControl=0;lastChannelAttempt=0;lastPeerControl=ProcessInfo.processInfo.systemUptime
            probe.suspendTransport();core.deltaCore.emulatorBridge.resetInputs()
            if activity == .battle { soulProbe?.setFriendlyBattleActive(true,for:core) }
            try soulProbe?.refreshAfterNativeMemoryReplacement(core:core)
            interactions?.restoreActivity(activity,id:value.id,initiator:initiator)
            startTimer()
            return true
        } catch {
            channel?.close();wire?.close();channel=nil;wire=nil;probe.configure(core:nil)
            recoveryFailed=true
            lastFailure="This activity needs recovery. Its saved continuation was kept."
            throw error
        }
    }
    private func claimContinuation()->Bool {
        guard !continuationWriteBlocked else { return false }
        guard let ticket=continuationTicket else { return true }
        guard let context=activeContinuationContext else { return false }
        do {
            try continuationStore.claim(ticket:ticket,context:context,gameID:gameID,claimant:continuationClaimant)
            continuationTicket=nil;wire?.thawContinuation();return true
        } catch {
            lastFailure="Couldn’t reopen this activity. Try again."
            interactions?.activityProgress(lastFailure,playing:false);return false
        }
    }
    private func detachSavedContinuation() {
        timer?.invalidate();timer=nil;transportGeneration=UUID()
        channel?.close();wire?.close();channel=nil;wire=nil
        if let core,core.state == .running { _=core.pause() }
        probe.configure(core:nil);BoundVBABattleBridge.close()
        id=nil;continuationTicket=nil;continuationWriteBlocked=false;activeContinuationContext=nil;backupURL=nil;journalURL=nil
        isTransportSuspended=false;pausedForTransport=false
    }
    /// Keep the same cartridge execution, native link queues, consent ID and
    /// trade journal. Only the physical transport is replaced during an outage.
    func suspendTransport() {
        guard id != nil, let core else { return }
        if !isTransportSuspended {
            if let peerResumeNonce { retiredResumeNonces=Array((retiredResumeNonces+[peerResumeNonce]).suffix(32)) }
            isTransportSuspended=true;resumeNonce=UUID();peerResumeNonce=nil
            resumeAcknowledged=false;sentResumeReady=false
            probe.suspendTransport()
            // Losing a socket is not losing the local game. Its own menus,
            // text and animation keep running; native decision/commit barriers
            // retain work that actually requires the other player's input.
            interactions?.activityProgress("Reconnecting…",playing:played || activity == .trade && entryQueued)
        }
        transportGeneration=UUID();channel?.close();channel=nil;wire?.suspend()
        lastChannelAttempt=0;lastControl=0
    }
    private func pauseForContinuation() {
        pausedForTransport=true
        releaseGameplayInputs?()
        if core?.state == .running { _=core?.pause() }
        if core?.state == .paused { core?.deltaCore.emulatorBridge.resetInputs() }
    }
    func resumeTransport() {
        guard id != nil,isTransportSuspended else { return }
        retryTransport(at:ProcessInfo.processInfo.systemUptime)
    }
    private func bindTransportChannel()->Bool {
        guard !continuationWriteBlocked,continuationTicket==nil,let wire,let id else { return false }
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
        if pausedForTransport,core.state == .running { _ = core.pause() }
        if pausedForTransport,core.state == .paused { core.deltaCore.emulatorBridge.resetInputs() }
        guard canResume?() ?? true,claimContinuation() else { return }
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
            if let terminal=retired[packet.id] ?? persistedTerminal(packet.id),let reply=terminal.retainedReply(to:packet) {
                if let bytes=reply.encoded() { _=sendControl?(bytes) }
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
        if activity == .battle,[.prepared,.connected,.resumeRequest,.resumeReady].contains(packet.kind),packet.battleProtocol != 2 {
            fail("Both players need the updated battle version");return
        }
        switch packet.kind {
        case .prepared: peerPrepared=true; interactions?.peerPreparedActivity()
        case .connected: peerConnected=true
        case .finished:
            peerFinished=true;peerBattleResult=packet.battleResult
            if let pending=pendingFinish,pending.packet.kind == .finished,activity == .battle,played,
               pending.packet.battleResult != packet.battleResult {
                fail("The battle results differed. Your original party was kept.");return
            }
        case .ranAway:
            guard activity == .battle else { return }
            finish(message:"Battle ended",resume:true,terminal:.ranAway);return
        case .abort:
            lastFailure="Your friend ended the \(activity.rawValue)"
            finish(message:lastFailure,resume:true,terminal:.abort); return
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
            guard !continuationWriteBlocked,continuationTicket==nil,canResume?() ?? true else { return }
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
        if let pending=pendingFinish {
            finish(message:pending.message,resume:pending.resume,terminal:pending.packet.kind);return
        }
        if recovery != nil { recoverIfRunning(); return }
        guard id != nil else { return }
        // The peer may already have closed its channel after completing. Its
        // retained terminal reply is sufficient once our native game finished.
        if localFinished && peerFinished {
            guard continuationTicket==nil || (canResume?() ?? true) else { return }
            if activity == .battle,played,
               (observation?.terminalFingerprint == nil || observation?.terminalFingerprint == 0 ||
                observation?.terminalFingerprint != peerBattleResult) {
                fail("The battle results differed. Your original party was kept.");return
            }
            let outcome=Self.terminalOutcome(observation?.outcome ?? 0) ?? 0
            if activity == .trade {
                finish(message:observation?.tradeCount ?? 0 > 0 ? "Trade complete · Pokémon saved" : "Trade ended",resume:true,terminal:.finished)
                return
            }
            finish(message:!played ? "Battle could not start" : outcome==1 ? "Battle won" : outcome==2 ? "Battle lost" : outcome==3 ? "Battle draw" : "Battle ended",resume:true,terminal:played ? .finished:.abort)
            return
        }
        let now=ProcessInfo.processInfo.systemUptime
        if isTransportSuspended { retryTransport(at:now) }
        else { wire?.tick(at:now) }
        if !isTransportSuspended,now-lastControl>=1 {
            lastControl=now
            let entered = activity == .battle ? (observation?.decisionFrames ?? 0)>0 : observation?.tradeOpened==true
            if !entered {
                if localPrepared { _=emit(.prepared) }
                if localConnected { _=emit(.connected) }
            }
            if localFinished { _=emit(.finished) }
        }
        if let value=probe.take() {
            observation=value
            if activity == .battle,value.runRequested {
                _=emit(.ranAway);finish(message:"Battle ended",resume:true,terminal:.ranAway);return
            }
            if value.error {
                NSLog("Bound native %@ connection failed: decision error %d",activity.rawValue,value.decisionError ?? 0)
                fail("Native \(activity.rawValue) connection failed");return
            }
            if value.connected && localPrepared && peerPrepared && !localConnected { localConnected=true; _=emit(.connected) }
            if !value.connected && entryQueued { fail("\(activity.title) cable disconnected"); return }
            if (activity == .battle ? value.battle : value.tradeOpened) && !played {
                played=true
                interactions?.activityProgress(activity == .trade ? "Trade" : "Battle",playing:true)
            }
            // The remote game has finished and our native engine independently
            // has a result. Emulate its cable closure; never write an outcome.
            if activity == .battle,played,peerFinished,!peerLinkClosed,!value.returned,Self.terminalOutcome(value.outcome) != nil {
                peerLinkClosed=true; probe.disconnectFinishedPeer()
            }
            if value.returned && !localFinished {
                localFinished=true; _=emit(.finished)
            }
        }
        if !isTransportSuspended,now-lastPeerControl>2,(!entryQueued || probe.networkAge>2) { suspendTransport() }
        if isTransportSuspended { return }
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
    /// FireRed encodes a native link Run result as the ordinary side result
    /// with bit 7 set. Other nonterminal/unknown values remain inadmissible.
    static func terminalOutcome(_ value:Int)->Int? {
        guard [1,2,3,0x81,0x82,0x83].contains(value) else { return nil }
        return value & 0x7F
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
        guard let id,let data=BoundBattleControlPacket(id:id,kind:kind,nonce:nonce,acknowledgement:acknowledgement,
            battleProtocol:activity == .battle ? 2:nil,
            battleResult:kind == .finished && activity == .battle ? observation?.terminalFingerprint:nil).encoded() else { return false }
        return sendControl?(data)==true
    }
    func cancel(resume:Bool=true,source:String=#fileID,line:Int=#line) {
        earlyPreparation=nil
        guard id != nil else { return }
        lastCancellation="\(source):\(line)"
        _=emit(.abort); finish(message:"\(activity.title) ended",resume:resume,terminal:.abort)
    }
    private func fail(_ message:String) {
        guard id != nil else { return }
        lastFailure=message; _=emit(.abort); finish(message:message,resume:true,terminal:.abort)
    }
    private func persistedTerminal(_ id:UUID)->BoundBattleControlPacket? {
        guard let context=activeContinuationContext ?? continuationContext ?? continuationContextProvider?(),
              let bytes=try? continuationStore.terminal(id:id,context:context,gameID:gameID) else { return nil }
        if let packet=BoundBattleControlPacket.decode(bytes),packet.id==id,
           [.finished,.ranAway,.abort].contains(packet.kind) { return packet }
        guard let text=String(data:bytes,encoding:.utf8),let kind=BoundBattleControlPacket.Kind(rawValue:text),
              [.finished,.ranAway,.abort].contains(kind) else { return nil }
        return BoundBattleControlPacket(id:id,kind:kind)
    }
    private func finish(message:String,resume:Bool,terminal:BoundBattleControlPacket.Kind) {
        guard let finishedID = id else { return }
        if pendingFinish == nil || pendingFinish?.packet.kind != .abort && terminal == .abort
            || pendingFinish?.packet.kind == .finished && terminal == .ranAway {
            let packet=BoundBattleControlPacket(id:finishedID,kind:terminal,battleProtocol:activity == .battle ? 2:nil,
                battleResult:terminal == .finished && activity == .battle ? observation?.terminalFingerprint:nil)
            pendingFinish=PendingFinish(packet:packet,message:message,resume:resume)
        }
        guard let pending=pendingFinish else { return }
        let terminalPacket=pending.packet,message=pending.message,resume=pending.resume
        if let context=activeContinuationContext {
            do {
                try terminalPersistence.save(terminalPacket) { data in
                    #if DEBUG
                    try beforeTerminalWriteForTesting?()
                    #endif
                    try continuationStore.saveTerminal(id:finishedID,data:data,context:context,gameID:gameID)
                }
            } catch {
                suspendTransport();pauseForContinuation()
                interactions?.activityProgress("Couldn’t save the activity result. Retrying…",playing:played)
                return
            }
        }
        guard claimContinuation() else { pauseForContinuation();return }
        if let core {
            if core.state == .running { _=core.pause() }
            do { try soulProbe?.drainBeforeMemoryReplacement(core:core) }
            catch { pauseForContinuation();interactions?.activityProgress("Soul Link needs recovery. Keep the game paused.",playing:played);return }
        }
        pendingFinish=nil
        pendingSettlement=activeContinuationContext.flatMap { try? continuationStore.settlement(context:$0,gameID:gameID) }
        retired[finishedID]=terminalPacket
        retiredOrder.append(finishedID)
        if retiredOrder.count>32 { retired.removeValue(forKey:retiredOrder.removeFirst()) }
        id=nil;activeContinuationContext=nil; timer?.invalidate(); timer=nil
        isTransportSuspended=false;pausedForTransport=false;transportGeneration=UUID()
        // Fence background delivery before pausing the sole native RAM owner.
        lastDecisionDiagnostics=probe.decisionDiagnostics
        lastCableDiagnostic=(wire?.diagnostics ?? "no wire")+" "+probe.diagnostics+" decisions=\(lastDecisionDiagnostics)"
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
                try soulProbe?.prepareForNativeMemoryReplacement(core:core)
                try BoundServerMemoryFiles.loadState(core:core,from:backupURL,gameID:gameID)
                let check=BoundVBABattleBridge.advanceAndObserve()
                recovered=(check["callback"] as? Int)==0x080565B5 && (check["battle"] as? Bool)==false && BoundVBABattleBridge.verifyBattleReady()
                if recovered {
                    if activity == .battle { soulProbe?.setFriendlyBattleActive(false,for:core) }
                    try soulProbe?.refreshAfterNativeMemoryReplacement(core:core)
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
        backupURL=nil; journalURL=nil; if activity == .trade { core.rate=originalRate }
        interactions?.activityEnded(recovered ? message : "Recovery snapshot kept. Reopen this game to restore it.")
        if didRestore {
            if activity == .battle {
                restoredBattles += 1
                if played && localFinished && peerFinished && terminalPacket.kind == .finished { completedBattles += 1 }
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
        if !finished {
            do {
                try soulProbe?.prepareForNativeMemoryReplacement(core:core)
                guard core.stop(),core.start(),core.pause() else { throw CocoaError(.fileReadUnknown) }
                try soulProbe?.refreshAfterNativeMemoryReplacement(core:core)
                success=true
            } catch { success=false }
        }
        if activity == .trade { core.rate=originalRate }
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
            let selectedContract=try contractSHA256(for:core)
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
                      value["gameID"]==gameID,value["rom"]==selectedContract,
                      let name=value["state"],name==URL(fileURLWithPath:name).lastPathComponent,
                      UUID(uuidString:URL(fileURLWithPath:name).deletingPathExtension().lastPathComponent) != nil,
                      let digest=value["sha256"],digest.count==64 else { continue }
                if value["localContinuation"]=="true" {
                    recoveryFailed=true;lastFailure="This local activity needs recovery. Its saved continuation was kept."
                    interactions?.activityEnded(lastFailure);return
                }
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
            try soulProbe?.prepareForNativeMemoryReplacement(core:core)
            let bytes=try BoundServerMemoryFiles.read(recovery.state,gameID:gameID)
            guard Self.hash(bytes)==recovery.digest else { throw CocoaError(.fileReadCorruptFile) }
            _=try BoundPlayerROMProfile(rom:Data(contentsOf:core.game.fileURL,options:.mappedIfSafe))
            if let battery=recovery.tradeBattery {
                guard core.stop() else { throw CocoaError(.fileReadUnknown) }
                if BoundServerMemoryFiles.isEnabled(for:gameID) {
                    guard core.start(),core.pause(),BoundVBABattleBridge.restoreServerBattery(battery) else { throw CocoaError(.fileReadUnknown) }
                } else {
                    try battery.write(to:core.game.gameSaveURL,options:.atomic)
                    guard core.start(),core.pause() else { throw CocoaError(.fileReadUnknown) }
                }
                try soulProbe?.refreshAfterNativeMemoryReplacement(core:core)
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
            if recovery.friendlyBattle { soulProbe?.setFriendlyBattleActive(false,for:core) }
            try soulProbe?.refreshAfterNativeMemoryReplacement(core:core)
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
