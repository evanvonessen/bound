import Foundation
import CryptoKit
import DeltaCore
import UIKit

struct BoundBattleControlPacket:Codable {
    static let prefix=Data([0x42,0x46,0x42,0x31]) // BFB1
    enum Kind:String,Codable { case prepared,connected,finished,abort }
    let id:UUID
    let kind:Kind
    func encoded()->Data? {
        guard let bytes=try? JSONEncoder().encode(self) else { return nil }
        return Self.prefix+bytes
    }
    static func decode(_ data:Data)->Self? {
        guard data.count<=1024,data.starts(with:prefix) else { return nil }
        return try? JSONDecoder().decode(Self.self,from:data.dropFirst(prefix.count))
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
    init(frame:UInt64,values:[String:Any]) {
        self.frame=frame
        error=values["error"] as? Bool ?? true; connected=values["connected"] as? Bool ?? false
        battle=values["battle"] as? Bool ?? false; returned=values["returned"] as? Bool ?? false
        outcome=values["outcome"] as? Int ?? 0; flags=values["flags"] as? Int ?? 0
        callback=values["callback"] as? Int ?? 0; scriptStatus=values["scriptStatus"] as? Int ?? -1
        scriptResult=values["scriptResult"] as? Int ?? -1
        tradeOpened=values["tradeOpened"] as? Bool ?? false; tradeCount=values["tradeCount"] as? Int ?? 0
        playerHP=values["playerHP"] as? [Int] ?? []; enemyHP=values["enemyHP"] as? [Int] ?? []
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
    private var peerGeneration:UInt16=0,receivedGeneration:UInt16=0,announcedGeneration:UInt16=0
    private var pendingAcknowledgement=Data(),lastAcknowledgement=Data()
    private var sender:(@Sendable (Data)->Bool)?
    private var failed:(@Sendable ()->Void)?
    private var lastSent:TimeInterval=0
    private var lastReceived=ProcessInfo.processInfo.systemUptime
    private var sentCommands=0,receivedCommands=0
    func configure(core:EmulatorCore?) {
        lock.lock(); defer { lock.unlock() }
        coreID=core.map(ObjectIdentifier.init); entryPlayer=nil; peerDisconnectPending=false; latest=nil; frame=0
        incoming.removeAll(); blockAdmission=BoundNativeBlockAdmission(); sender=nil; failed=nil; lastSent=0
        peerGeneration=0; receivedGeneration=0; announcedGeneration=0
        pendingAcknowledgement.removeAll(); lastAcknowledgement.removeAll()
        lastReceived=ProcessInfo.processInfo.systemUptime; sentCommands=0; receivedCommands=0
    }
    func setSender(_ sender:@escaping @Sendable (Data)->Bool,failed:@escaping @Sendable ()->Void) {
        lock.lock(); self.sender=sender; self.failed=failed; lock.unlock()
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
                if generation>receivedGeneration { blockAdmission=BoundNativeBlockAdmission(); receivedGeneration=generation }
                guard blockAdmission.accept(commands) else { return false }
                guard let sequence=BoundNativeCommandPacket.sequence(packet) else { return false }
                for start in stride(from:0,to:commands.count,by:16) {
                    incoming.append(UInt8(truncatingIfNeeded:generation)); incoming.append(UInt8(generation>>8))
                    let index=sequence &+ UInt16(start/16)
                    incoming.append(UInt8(truncatingIfNeeded:index)); incoming.append(UInt8(index>>8))
                    incoming.append(commands.subdata(in:start..<start+16))
                }
                receivedCommands+=commands.count/16
            }
        }
        lastReceived=ProcessInfo.processInfo.systemUptime; return true
    }
    var networkAge:TimeInterval { lock.lock(); defer { lock.unlock() }; return ProcessInfo.processInfo.systemUptime-lastReceived }
    var diagnostics:String { lock.lock(); defer { lock.unlock() }; return "sentCommands=\(sentCommands) receivedCommands=\(receivedCommands) pending=\(incoming.count/20)" }
    func disconnectFinishedPeer() { lock.lock(); peerDisconnectPending=true; lock.unlock() }
    func enter(player:Int) { lock.lock(); entryPlayer=player; lock.unlock() }
    func receive(_ core:EmulatorCore) {
        lock.lock()
        guard coreID==ObjectIdentifier(core) else { lock.unlock(); return }
        let player=entryPlayer; entryPlayer=nil
        let disconnectPeer=peerDisconnectPending; peerDisconnectPending=false
        let send=sender,failure=failed
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
    private var localPrepared=false,peerPrepared=false
    private var localConnected=false,peerConnected=false,entryQueued=false
    private var localFinished=false,peerFinished=false,played=false,peerLinkClosed=false
    private var deadline:TimeInterval=0
    private var backupURL:URL?
    private var journalURL:URL?
    private var originalRate=1.0
    private struct Recovery { let state:URL; let journal:URL; let digest:String; var tradeBattery:Data? = nil }
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
    var restored:(()->Void)?
    var canResume:(()->Bool)?
    var isActive:Bool { id != nil || recovery != nil }
    var blocksAutoSave:Bool { isActive || recoveryFailed }

    func bind(core:EmulatorCore?,gameID:String,interactions:BoundFriendInteractionSession) {
        if self.core !== core || self.gameID != gameID {
            if recovery != nil { timer?.invalidate(); timer=nil; recovery=nil; probe.configure(core:nil) }
            cancel(resume:false); self.core=core; self.gameID=gameID; recoveryFailed=false
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
        localPrepared=false; peerPrepared=false; localConnected=false; peerConnected=false
        localFinished=false; peerFinished=false; entryQueued=false; played=false; peerLinkClosed=false
        deadline=ProcessInfo.processInfo.systemUptime+30
        interactions?.activityProgress(activity == .trade ? "Connecting trade…" : "Connecting battle…",playing:false)
        guard core.pause(),BoundVBABattleBridge.verifyBattleReady() else { fail("Game is not ready for a link \(activity.rawValue)"); return }
        core.rate=core.deltaCore.supportedRates.lowerBound
        do {
            let folder=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
                .appendingPathComponent("Friend Battles",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let backup=folder.appendingPathComponent(id.uuidString+".state")
            core.saveSaveState(to:backup)
            let bytes=try Data(contentsOf:backup)
            guard bytes.count>1024 else { throw CocoaError(.fileReadCorruptFile) }
            backupURL=backup
            let journal=folder.appendingPathComponent(id.uuidString+".json")
            let value:[String:Any]=["gameID":gameID,"rom":BoundPlayerROMProfile.supportedSHA256,
                "state":backup.lastPathComponent,"sha256":Self.hash(bytes),"activity":activity.rawValue]
            try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:journal,options:.atomic)
            journalURL=journal
            var resource=URLResourceValues(); resource.isExcludedFromBackup=true
            var protectedFolder=folder; try protectedFolder.setResourceValues(resource)
        } catch { fail("Couldn’t prepare a recovery snapshot"); return }
        let failure:@Sendable ()->Void = { [weak self] in
            Task { @MainActor in
                guard let self,self.id==id else { return }
                self.fail("\(self.activity.title) connection lost")
            }
        }
        probe.configure(core:core)
        let safeWire=BoundBattleWire(id:id,receive:{ [probe] bytes in
            if !probe.receiveNetworkPacket(bytes) { failure() }
        },failed:failure)
        guard let channel=makeChannel?({ data in safeWire.receive(data) },failure) else {
            fail("\(activity.title) data connection unavailable"); return
        }
        self.channel=channel; self.wire=safeWire
        safeWire.setSender { [channel] data in channel.send(data) }
        probe.setSender({ bytes in safeWire.send(bytes) },failed:failure)
        let prepared = activity == .trade ? BoundVBABattleBridge.prepareTrade(forPlayer:initiator ? 0:1)
            : BoundVBABattleBridge.prepareBattle(forPlayer:initiator ? 0:1)
        guard prepared else {
            fail("Couldn’t prepare the native \(activity.rawValue) link"); return
        }
        localPrepared=true; _=emit(.prepared)
        _=core.resume()
        let timer=Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.advance() } }
        RunLoop.main.add(timer,forMode:.common); self.timer=timer
        advance()
    }
    func receive(_ data:Data) {
        guard let packet=BoundBattleControlPacket.decode(data),packet.id==id else { return }
        switch packet.kind {
        case .prepared: peerPrepared=true
        case .connected: peerConnected=true
        case .finished: peerFinished=true
        case .abort: fail("Your friend ended the \(activity.rawValue)"); return
        }
        advance()
    }
    private func advance() {
        if recovery != nil { recoverIfRunning(); return }
        guard id != nil else { return }
        let now=ProcessInfo.processInfo.systemUptime
        if now>deadline { fail("\(activity.title) connection timed out"); return }
        if let value=probe.take() {
            observation=value
            if value.error { fail("Native \(activity.rawValue) connection failed"); return }
            if value.connected && localPrepared && peerPrepared && !localConnected { localConnected=true; _=emit(.connected) }
            if !value.connected && entryQueued { fail("\(activity.title) cable disconnected"); return }
            if (activity == .battle ? value.battle : value.tradeOpened) && !played {
                played=true; deadline=now+7200
                interactions?.activityProgress(activity == .trade ? "Trade" : "Battle",playing:true)
            }
            // The remote game has finished and our native engine independently
            // has a result. Emulate its cable closure; never write an outcome.
            if activity == .battle,played,peerFinished,!peerLinkClosed,!value.returned,[1,2,3].contains(value.outcome) {
                peerLinkClosed=true; probe.disconnectFinishedPeer()
            }
            if value.returned && !localFinished {
                localFinished=true; deadline=now+15; _=emit(.finished)
            }
        }
        if entryQueued && probe.networkAge>15 { fail("\(activity.title) data connection timed out"); return }
        if localConnected && peerConnected && !entryQueued {
            if activity == .trade {
                // Durable before any native trade code or input can run, including
                // when the main actor is delayed while emulation keeps advancing.
                do { try markTradeStarted() }
                catch { fail("Couldn’t protect the trade save"); return }
            }
            entryQueued=true; deadline=now+(activity == .trade ? 300:120); probe.enter(player:initiator ? 0:1)
            interactions?.activityProgress(activity == .trade ? "Use A to save and confirm the native trade link…" : "Starting battle…",playing:activity == .trade)
        }
        if localFinished && peerFinished {
            let outcome=observation?.outcome ?? 0
            if activity == .trade {
                finish(message:observation?.tradeCount ?? 0 > 0 ? "Trade complete · Pokémon saved" : "Trade ended",resume:true)
                return
            }
            finish(message:!played ? "Battle could not start" : outcome==1 ? "Battle won" : outcome==2 ? "Battle lost" : outcome==3 ? "Battle draw" : "Battle ended",resume:true)
        }
    }
    private func markTradeStarted() throws {
        guard let journalURL,let bytes=try? Data(contentsOf:journalURL),
              var value=try JSONSerialization.jsonObject(with:bytes) as? [String:String] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        value["tradeStarted"]="true"
        try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:journalURL,options:.atomic)
    }
    private func emit(_ kind:BoundBattleControlPacket.Kind)->Bool {
        guard let id,let data=BoundBattleControlPacket(id:id,kind:kind).encoded() else { return false }
        return sendControl?(data)==true
    }
    func cancel(resume:Bool=true,source:String=#fileID,line:Int=#line) {
        guard id != nil else { return }
        lastCancellation="\(source):\(line)"
        _=emit(.abort); finish(message:"\(activity.title) ended",resume:resume)
    }
    private func fail(_ message:String) {
        guard id != nil else { return }
        lastFailure=message; _=emit(.abort); finish(message:message,resume:true)
    }
    private func finish(message:String,resume:Bool) {
        guard id != nil else { return }
        id=nil; timer?.invalidate(); timer=nil
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
            finishTrade(core:core,message:message,resume:resume)
            return
        }
        var didRestore=false
        var recovered=backupURL==nil
        if let backupURL,core.state != .stopped {
            do {
                try core.load(DeltaCore.SaveState(fileURL:backupURL,gameType:core.game.type))
                let check=BoundVBABattleBridge.advanceAndObserve()
                recovered=(check["callback"] as? Int)==0x080565B5 && (check["battle"] as? Bool)==false && BoundVBABattleBridge.verifyBattleReady()
                if recovered {
                    didRestore=true
                    // Remove the recovery instruction before its state. A crash
                    // between removals leaves an inert orphan, not a stale restore.
                    if let journalURL { try FileManager.default.removeItem(at:journalURL) }
                    try? FileManager.default.removeItem(at:backupURL)
                }
            } catch { recovered=false }
        }
        recoveryFailed = !recovered
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
    private func finishTrade(core:EmulatorCore,message:String,resume:Bool) {
        // Native trade owns party swap, mail, Dex, evolution and its linked save
        // protocol. Retain those changes; a battle-style state rollback duplicates
        // or destroys exchanged Pokémon. Interrupted trades boot the native save.
        let finished=localFinished && peerFinished && observation?.returned == true
        var success=finished
        if !finished { success=core.stop() && core.start() }
        core.rate=originalRate
        if success {
            if finished { completedTrades += observation?.tradeCount ?? 0 }
            do {
                if let journalURL { try FileManager.default.removeItem(at:journalURL) }
                if let backupURL { try? FileManager.default.removeItem(at:backupURL) }
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
            let folder=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
                .appendingPathComponent("Friend Battles",isDirectory:true)
            guard let files=try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.contentModificationDateKey]) else { return }
            let candidates=files.filter { $0.pathExtension=="json" }.sorted {
                ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for journal in candidates.prefix(64) {
                guard let bytes=try? Data(contentsOf:journal),bytes.count<=4096,
                      let value=try? JSONSerialization.jsonObject(with:bytes) as? [String:String],
                      value["gameID"]==gameID,value["rom"]==BoundPlayerROMProfile.supportedSHA256,
                      let name=value["state"],name==URL(fileURLWithPath:name).lastPathComponent,
                      UUID(uuidString:URL(fileURLWithPath:name).deletingPathExtension().lastPathComponent) != nil,
                      let digest=value["sha256"],digest.count==64 else { continue }
                var pending = Recovery(state:folder.appendingPathComponent(name),journal:journal,digest:digest)
                if value["activity"] == "trade",value["tradeStarted"] == "true" {
                    // Bind runs before loading automatic states. Preserve the actual
                    // cartridge save, never flash data from a pre-trade save state.
                    recoveryFailed=true
                    let battery=try Data(contentsOf:core.game.gameSaveURL)
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
            let bytes=try Data(contentsOf:recovery.state)
            guard Self.hash(bytes)==recovery.digest else { throw CocoaError(.fileReadCorruptFile) }
            _=try BoundPlayerROMProfile(rom:Data(contentsOf:core.game.fileURL,options:.mappedIfSafe))
            if let battery=recovery.tradeBattery {
                guard core.stop() else { throw CocoaError(.fileReadUnknown) }
                try battery.write(to:core.game.gameSaveURL,options:.atomic)
                guard core.start() else { throw CocoaError(.fileReadUnknown) }
                try FileManager.default.removeItem(at:recovery.journal)
                try? FileManager.default.removeItem(at:recovery.state)
                self.recovery=nil; timer?.invalidate(); timer=nil
                interactions?.activityEnded("Continue from your in-game save after the interrupted trade.")
                if !(canResume?() ?? true) { _=core.pause() }
                return
            }
            try core.load(DeltaCore.SaveState(fileURL:recovery.state,gameType:core.game.type))
            let check=BoundVBABattleBridge.advanceAndObserve()
            guard (check["callback"] as? Int)==0x080565B5,(check["battle"] as? Bool)==false else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.removeItem(at:recovery.journal)
            try? FileManager.default.removeItem(at:recovery.state)
            self.recovery=nil; timer?.invalidate(); timer=nil
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
