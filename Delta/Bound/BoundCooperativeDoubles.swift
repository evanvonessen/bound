import Foundation
import CryptoKit
import DeltaCore

private func coopWord(_ bytes: Data, _ offset: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
}
private func coopPut(_ value: UInt32, in bytes: inout Data, at offset: Int) {
    for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
}
private func coopUUID(_ id: UUID) -> Data { var value = id.uuid; return withUnsafeBytes(of: &value) { Data($0) } }
private func coopID(_ bytes: Data, _ offset: Int) -> UUID {
    let a = Array(bytes[offset..<offset + 16])
    return UUID(uuid: (a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7],a[8],a[9],a[10],a[11],a[12],a[13],a[14],a[15]))
}
private func coopHash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
private func coopFNV(_ bytes: Data) -> UInt32 { bytes.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 } }

/// Exact device-local execution; unlike a recovery cut this never rewinds a
/// peer that remained in the same encounter while this app was closed.
struct BoundCooperativeContinuation:BoundActivityContinuation {
    let version:Int,ticket:UUID,context:BoundNativeContinuationContext,gameID:String,cartridge:String
    let state:Data,battery:Data,bridge:Data,host:Data,probe:Data,wire:Data
    let memoryFiles:[String:Data]
    let heads:BoundContinuationHeads?
    let snapshot:Data,capture:Data?,local:UUID?,peer:UUID?,encounter:UUID,peerEncounter:UUID?
    let peerTeam:Data?,enemy:Data,proof:Data
    let peerReady:Bool,readySent:Bool,started:Bool,prepared:Bool,peerCableReady:Bool,peerResultsReady:Bool,peerFinished:Bool
    let fixedRole:UInt32?,lastXP:Data,incomingXP:Data,sequence:UInt32,controlCursor:Int
    let checkpointName:String?,journalName:String?,checkpoint:Data?,journal:Data?,agreement:Data,branch:Data
    var activityID:UUID { encounter }
    var valid:Bool {
        version==1 && context.valid && (context.runID==nil || heads != nil) && !gameID.isEmpty && gameID.utf8.count<=512
            && cartridge.count==64 && cartridge.allSatisfy({ $0.isHexDigit })
            && state.count>1024 && state.count<=16_777_216 && battery.count==131072
            && bridge.count<=8192 && host.count==16384 && coopWord(host,0)==0x31484443 && host[4]==1
            && host[5...7].allSatisfy({ $0==0 }) && coopWord(host,8)>0 && coopWord(host,8)&1==0
            && coopWord(host,12) & ~UInt32(15) == 0 && coopWord(host,16)<=180 && coopWord(host,20)<=1 && probe.count<=32768 && wire.count<=400_000
            && memoryFiles.count<=256 && memoryFiles.values.reduce(0,{ $0+$1.count })<=16_777_216
            && BoundCooperativeSnapshot(snapshot).map({ (1...7).contains($0.phase) || $0.phase==9 }) == true && (capture==nil || BoundCooperativeSnapshot(capture!) != nil)
            && (peerTeam==nil || BoundCooperativePacket(data:peerTeam!)?.kind == .team)
            && [0,600].contains(enemy.count) && [0,32].contains(proof.count)
            && [0,192,404].contains(lastXP.count) && [0,192,404].contains(incomingXP.count)
            && (fixedRole==nil || fixedRole!<=1) && controlCursor>=0
            && (checkpoint?.count ?? 0)<=16_777_216 && (journal?.count ?? 0)<=65536 && agreement.count<=8192 && [0,32].contains(branch.count)
            && Self.validName(checkpointName,extension:"state") && Self.validName(journalName,extension:"json")
            && (checkpointName==nil)==(checkpoint==nil) && (journalName==nil)==(journal==nil)
            && (!prepared || !bridge.isEmpty && !wire.isEmpty && peerEncounter != nil && local != nil && peer != nil)
    }
    private static func validName(_ name:String?,extension suffix:String)->Bool {
        guard let name else { return true }
        let url=URL(fileURLWithPath:name)
        return name==url.lastPathComponent && url.pathExtension==suffix && UUID(uuidString:url.deletingPathExtension().lastPathComponent) != nil
    }
}

/// A cartridge-owned encounter. No host request can create a trainer encounter.
struct BoundCooperativeSnapshot: Sendable {
    let bytes: Data
    let phase: UInt32, error: UInt32, role: UInt32, token: UInt32
    let flags: UInt32, trainerA: UInt32, trainerB: UInt32, group: UInt32, number: UInt32
    let count: UInt32, selectedCount: UInt32, partyHash: UInt32, enemyHash: UInt32
    let order: Data, party: Data, enemy: Data, owned: Data, proof: Data, xp: Data
    let xpPhase:UInt32,xpToken:UInt32
    let faintedMask:UInt8
    init?(_ source: Data) {
        let data = Data(source)
        guard data.count == 2048, coopWord(data,0) == 0x31474443, data[4] == 1, data[5...7].allSatisfy({ $0 == 0 }),
              coopWord(data,8) != 0, coopWord(data,8) & 1 == 0, coopWord(data,12) <= 9 else { return nil }
        bytes=data; phase=coopWord(data,12); error=coopWord(data,16); role=coopWord(data,20); token=coopWord(data,24)
        flags=coopWord(data,44); trainerA=coopWord(data,48); trainerB=coopWord(data,52)
        group=coopWord(data,56); number=coopWord(data,60); count=coopWord(data,64); selectedCount=coopWord(data,68)
        order=data.subdata(in:72..<75);faintedMask=data[75]; partyHash=coopWord(data,80); enemyHash=coopWord(data,84)
        proof=data.subdata(in:88..<120); party=data.subdata(in:128..<728); enemy=data.subdata(in:728..<1328)
        owned=party;xpPhase=coopWord(data,1328);xpToken=coopWord(data,1332)
        let kind=coopWord(data,1528), size=coopWord(data,1532)
        guard kind <= 2, (kind == 0 && size == 0) || (kind == 1 && size == 184) || (kind == 2 && size == 396) else { return nil }
        xp=kind == 0 ? Data() : data.subdata(in:1528..<1536 + Int(size))
        guard group < 43, count <= 6, selectedCount <= 3,faintedMask & 0xC0 == 0 else { return nil }
    }
    var selected: Bool { (1...3).contains(selectedCount) && Set(order.prefix(Int(selectedCount))).count == Int(selectedCount) && order.prefix(Int(selectedCount)).allSatisfy({ (1...count).contains(UInt32($0)) }) && order.dropFirst(Int(selectedCount)).allSatisfy({ $0 == 0 }) }
    var encounter: Data { var out=Data(); for value in [flags,trainerA,trainerB,group,number] { var b=Data(repeating:0,count:4); coopPut(value,in:&b,at:0); out.append(b) }; return out }
}

/// Bounded binary messages on the authenticated expected-peer interaction route.
/// Separate team/enemy messages fit the existing 1 KiB transport admission limit.
struct BoundCooperativePacket: Sendable {
    static let prefix=Data("BCD1".utf8)
    enum Kind: UInt32 { case offer=1, team=2, enemy=3, ready=4, cancel=5, xp=6, finished=7, cableReady=8, recoveryOffer=9, recoveryReady=10, resultsReady=11, resumeOffer=12, resumeReady=13 }
    let data: Data
    let kind: Kind
    var sender: UUID { coopID(data,8) }; var receiver: UUID { coopID(data,24) }
    var id: UUID { coopID(data,40) }; var peerID: UUID { coopID(data,56) }
    var token: UInt32 { coopWord(data,72) }; var partyHash: UInt32 { coopWord(data,96) }
    var enemyHash: UInt32 { coopWord(data,100) }; var proof: Data { data.subdata(in:104..<136) }
    var count: UInt32 { coopWord(data,136) }; var order: Data { data.subdata(in:140..<143) }
    var payload: Data { data.subdata(in:148..<data.count) }
    var encounter: Data { data.subdata(in:76..<96) }
    init?(data source: Data) {
        let b=Data(source)
        guard b.count >= 148, b.count <= 1024, b.starts(with:Self.prefix), let k=Kind(rawValue:coopWord(b,4)),
              coopWord(b,144) == b.count-148, coopID(b,8) != coopID(b,24), coopWord(b,72) != 0 else { return nil }
        let size=b.count-148
        guard (k == .team || k == .enemy) ? size == 600 : k == .xp ? [192,404].contains(size) : (k == .recoveryOffer || k == .recoveryReady) ? size == 124 : k == .resumeOffer ? size == 16 : k == .resumeReady ? size == 32 : size == 0 else { return nil }
        if k == .team {
            let n=coopWord(b,136), selected=Int(b[143]), order=Array(b[140..<143])
            guard (1...6).contains(n),(1...3).contains(selected),Set(order.prefix(selected)).count == selected,
                  order.prefix(selected).allSatisfy({ (1...n).contains(UInt32($0)) }),order.dropFirst(selected).allSatisfy({ $0 == 0 }),
                  coopFNV(b.subdata(in:148..<748)) == coopWord(b,96) else { return nil }
        }
        if k == .enemy,coopFNV(b.subdata(in:148..<748)) != coopWord(b,100) { return nil }
        data=b;kind=k
    }
    init(kind:Kind,local:UUID,peer:UUID,id:UUID,peerID:UUID?,snapshot:BoundCooperativeSnapshot,proof:Data=Data(repeating:0,count:32),enemyHash:UInt32?=nil,payload:Data=Data()) {
        var b=Data(repeating:0,count:148); b.replaceSubrange(0..<4,with:Self.prefix)
        coopPut(kind.rawValue,in:&b,at:4); b.replaceSubrange(8..<24,with:coopUUID(local));b.replaceSubrange(24..<40,with:coopUUID(peer))
        b.replaceSubrange(40..<56,with:coopUUID(id)); if let peerID { b.replaceSubrange(56..<72,with:coopUUID(peerID)) }
        coopPut(snapshot.token,in:&b,at:72); b.replaceSubrange(76..<96,with:snapshot.encounter)
        coopPut(snapshot.partyHash,in:&b,at:96);coopPut(enemyHash ?? snapshot.enemyHash,in:&b,at:100)
        b.replaceSubrange(104..<136,with:proof);coopPut(snapshot.count,in:&b,at:136);b.replaceSubrange(140..<143,with:snapshot.order);b[143]=UInt8(snapshot.selectedCount)
        coopPut(UInt32(payload.count),in:&b,at:144);b.append(payload);data=b;self.kind=kind
    }
}

/// The one declared host transaction. Counts and native one-based orders are
/// separate fields: choosing three records does not shrink the owner's party.
struct BoundCooperativeHost {
    static func transaction(sequence:UInt32,flags:UInt32,role:UInt32,capture:BoundCooperativeSnapshot?,
                            peerTeam:BoundCooperativePacket?,proof:Data,enemy:Data,xp:Data)->Data {
        var out=Data(repeating:0,count:16384);coopPut(0x31484443,in:&out,at:0);out[4]=1
        coopPut(sequence,in:&out,at:8);coopPut(flags,in:&out,at:12);coopPut(flags == 0 ? 0:180,in:&out,at:16);coopPut(role,in:&out,at:20)
        if let value=capture,let peerTeam,proof.count==32,enemy.count==600 {
            coopPut(max(1,coopWord(proof,0)),in:&out,at:24);out.replaceSubrange(28..<44,with:proof.prefix(16))
            coopPut(peerTeam.count,in:&out,at:44);out.replaceSubrange(48..<51,with:peerTeam.order);out[51]=UInt8(value.count)
            coopPut(value.partyHash,in:&out,at:52);coopPut(coopFNV(enemy),in:&out,at:56)
            for (offset,n) in [(60,value.flags),(64,value.trainerA),(68,value.trainerB),(72,value.group),(76,value.number),(116,value.token)] { coopPut(n,in:&out,at:offset) }
            out.replaceSubrange(80..<112,with:proof);out.replaceSubrange(112..<115,with:value.order);out[115]=peerTeam.data[143]
            out.replaceSubrange(128..<728,with:peerTeam.payload);out.replaceSubrange(1024..<1624,with:enemy)
            if !xp.isEmpty,xp.count<=520 { out.replaceSubrange(2048..<2048+xp.count,with:xp) }
        }
        return out
    }
}

/// Recovery requires fully drained native and host queues at one command cut.
/// An accepted but unconsumed future command cannot survive an older peer state.
struct BoundCooperativeCableCut:Sendable {
    let data:Data
    private func half(_ offset:Int)->UInt16 { UInt16(data[offset]) | UInt16(data[offset+1]) << 8 }
    var isAdmission:Bool { coopWord(data,0)==0x31444143 }
    var generation:UInt16 { half(4) }
    var outRead:UInt16 { half(6) }
    var outWrite:UInt16 { half(8) }
    var peerConsumed:UInt16 { half(10) }
    var consumedGeneration:UInt16 { half(12) }
    var xpPhase:UInt32 { coopWord(data,16) }
    var xpToken:UInt32 { coopWord(data,20) }
    var role:UInt32 { coopWord(data,24) }
    var sentHistory:Data { data.subdata(in:28..<60) }
    var receivedHistory:Data { data.subdata(in:60..<92) }
    init?(data:Data) {
        guard data.count==92,[UInt32(0x32545543),0x31444143].contains(coopWord(data,0)),Self.halfWord(data,14)==0 else { return nil }
        if coopWord(data,0)==0x31444143,!data.dropFirst(4).allSatisfy({ $0==0 }) { return nil }
        self.data=data
        guard outWrite &- outRead<=32,role<=1 else { return nil }
    }
    private static func halfWord(_ data:Data,_ offset:Int)->UInt16 { UInt16(data[offset]) | UInt16(data[offset+1]) << 8 }
    init?(admissionPhase:UInt32) {
        guard admissionPhase==3 else { return nil }
        var bytes=Data(repeating:0,count:92);coopPut(0x31444143,in:&bytes,at:0);self.init(data:bytes)
    }
    init?(mailbox:Data,snapshot:BoundCooperativeSnapshot,hostRecovery:Data) {
        guard mailbox.count==1176,coopWord(mailbox,0)==0x314D4642,
              BoundNativeBattleProbe.recoveryIsQuiescent(hostRecovery,mailbox:mailbox),
              let histories=BoundNativeBattleProbe.recoveryHistories(hostRecovery),snapshot.role<=1,[UInt32(0),4,6].contains(snapshot.xpPhase) else { return nil }
        var out=Data(repeating:0,count:92);coopPut(0x32545543,in:&out,at:0)
        for (target,source) in [(4,16),(6,4),(8,6),(10,20),(12,22),(14,12)] { out.replaceSubrange(target..<target+2,with:mailbox[source..<source+2]) }
        out.replaceSubrange(28..<60,with:histories.0);out.replaceSubrange(60..<92,with:histories.1)
        coopPut(snapshot.xpPhase,in:&out,at:16);coopPut(snapshot.xpToken,in:&out,at:20);coopPut(snapshot.role,in:&out,at:24)
        self.init(data:out)
    }
    func compatible(with peer:Self)->Bool {
        if isAdmission || peer.isAdmission { return isAdmission && peer.isAdmission }
        guard role != peer.role,generation>0,generation==peer.generation,
              consumedGeneration==peer.generation,peer.consumedGeneration==generation,
              outRead==outWrite,peer.outRead==peer.outWrite,
              peer.peerConsumed==outWrite,peerConsumed==peer.outWrite,xpToken==peer.xpToken,
              sentHistory==peer.receivedHistory,receivedHistory==peer.sentHistory else { return false }
        let host=role==0 ? self:peer,guest=role==1 ? self:peer
        return (host.xpPhase==0 && guest.xpPhase==0 && xpToken==0)
            || (host.xpPhase==0 && guest.xpPhase==4 && xpToken>0)
            || (host.xpPhase==6 && guest.xpPhase==6)
    }
}

struct BoundCooperativeRecoveryBranch {
    static func initial(proof:Data)->Data { coopHash(Data("Bound co-op branch v1".utf8)+proof) }
    static func accepts(_ payload:Data,current:Data)->Bool { payload.count==124 && current.count==32 && payload.suffix(32)==current }
    static func next(_ current:Data,local:UUID,peer:UUID)->Data {
        let ids=[local,peer].sorted { $0.uuidString<$1.uuidString }
        return coopHash(current+coopUUID(ids[0])+coopUUID(ids[1]))
    }
}

private struct BoundCooperativeRecovery:Codable {
    let capture:Data
    let proof:Data
    let enemy:Data
    let role:UInt32
    let peerTeam:Data
}

/// The completed-frame owner performs all port access and durable checkpoints.
/// Networking only replaces bounded data mailboxes.
final class BoundCooperativeProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var gameProfile: BoundGameProfile?
    func setProfile(_ profile: BoundGameProfile?) { lock.lock(); gameProfile=profile; lock.unlock() }
    private var coreID:ObjectIdentifier?, host=Data(), latest:BoundCooperativeSnapshot?
    private var checkpoint:URL?, journal:URL?, gameID="", lastDurable=Data(), durable=false
    private var lastError:String?, soul:BoundSoulProbe?, agreement=Data(),branch=Data()
    private weak var cable:BoundNativeBattleProbe?
    func configure(core:EmulatorCore?,gameID:String,soul:BoundSoulProbe?) {
        lock.lock();defer { lock.unlock() }
        gameProfile=nil;coreID=core.map(ObjectIdentifier.init);self.gameID=gameID;self.soul=soul;host=Data();latest=nil;checkpoint=nil;journal=nil;lastDurable=Data();durable=false;lastError=nil;branch=Data()
    }
    func setHost(_ data:Data) { lock.lock();host=data;lock.unlock() }
    func protect(state:URL,journal:URL,agreement:Data,branch:Data,cable:BoundNativeBattleProbe) {
        lock.lock();checkpoint=state;self.journal=journal;self.agreement=agreement;self.branch=branch;self.cable=cable;durable=false;lock.unlock()
    }
    func continuationHost()->Data { lock.lock();defer { lock.unlock() };return host }
    func restoreContinuation(snapshot:BoundCooperativeSnapshot,host:Data) {
        lock.lock();defer { lock.unlock() };latest=snapshot;self.host=host
    }
    func clearProtection() { lock.lock();checkpoint=nil;journal=nil;agreement=Data();branch=Data();durable=false;lastDurable=Data();lock.unlock() }
    func recoveryLocation()->(URL?,URL?) { lock.lock();defer { lock.unlock() };return(checkpoint,journal) }
    func read()->(BoundCooperativeSnapshot?,Bool,String?) { lock.lock();defer { lock.unlock() };return(latest,durable,lastError) }
    func receive(_ core:EmulatorCore) {
        lock.lock();defer { lock.unlock() }
        guard gameProfile?.supportsCooperativeDoubles == true,coreID == ObjectIdentifier(core),core.deltaCore.identifier == "com.rileytestut.GBADeltaCore",BoundVBABattleBridge.installCooperativeDoubles() else { return }
        if host.count == 16384 { BoundVBABattleBridge.setCooperativeHost(host) }
        guard let value=BoundCooperativeSnapshot(BoundVBABattleBridge.cooperativeSnapshot()) else { return }
        latest=value
        let active=(4...7).contains(value.phase) || value.phase == 9
        soul?.setCooperativeBattleActive(active,for:core)
        if active {
            var fainted:Set<BoundSoulIdentity>=[]
            for index in 0..<6 where value.faintedMask & (1 << index) != 0 {
                if let identity=BoundSoulIdentity.read(value.party,at:index*100) { fainted.insert(identity) }
            }
            soul?.observeCooperativeParty(value.owned,fainted:fainted,for:core)
            if let state=soul?.read(),state.ledger?.ended == false,let error=state.error { lastError=error;return }
            // The cartridge's owned latch is committed before clearing native
            // mixed-team events; a friend's identity cannot become a local loss.
            BoundVBABattleBridge.acknowledgeSoulLinkFaints()
        }
        guard let checkpoint,let journal,value.phase >= 3,value.phase != 8 else { return }
        // Full emulator checkpoints occur at phase/XP/faint boundaries, never
        // for every damage tick. Soul Link commits small owned-only tombstones.
        var identity=Data(value.xp.prefix(12));identity.append(value.faintedMask)
        for index in 0..<6 where value.owned[index*100+86] == 0 && value.owned[index*100+87] == 0 {
            identity.append(value.owned.subdata(in:index*100..<index*100+8))
        }
        for n in [value.phase,value.token,value.error] { var b=Data(repeating:0,count:4);coopPut(n,in:&b,at:0);identity.append(b) }
        guard !durable || identity != lastDurable else { return }
        do {
            // An uncommitted write never replaces the last recoverable state.
            let next=checkpoint.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".state")
            try BoundServerMemoryFiles.saveState(core:core,to:next,gameID:gameID)
            let bytes=try BoundServerMemoryFiles.read(next,gameID:gameID)
            guard bytes.count > 1024 else { throw CocoaError(.fileReadCorruptFile) }
            let entry:[String:Any]=["gameID":gameID,"state":next.lastPathComponent,"sha256":coopHash(bytes).map { String(format:"%02x",$0) }.joined(),"phase":value.phase,"token":value.token,"snapshot":value.bytes.base64EncodedString(),"rom":gameProfile?.romSHA256 ?? "",
                "agreement":agreement.base64EncodedString(),"branch":branch.base64EncodedString(),"cable":(cable?.recoveryData() ?? Data()).base64EncodedString(),
                "nativeCable":BoundVBABattleBridge.cooperativeCableSnapshot().base64EncodedString()]
            try BoundServerMemoryFiles.write(JSONSerialization.data(withJSONObject:entry,options:[.sortedKeys]),to:journal,gameID:gameID)
            self.checkpoint=next
            try? BoundServerMemoryFiles.remove(checkpoint,gameID:gameID)
            lastDurable=identity;durable=true;lastError=nil
        } catch { lastError="Cooperative recovery could not be saved" }
    }
    #if DEBUG && targetEnvironment(simulator)
    func qaCompletedFrame(_ bytes:Data) { lock.lock();latest=BoundCooperativeSnapshot(bytes);lock.unlock() }
    #endif
    /// The main owner has fenced emulation before a disconnect checkpoint.
    func checkpointNow(_ core:EmulatorCore) {
        lock.lock();lastDurable=Data();durable=false;lock.unlock()
        receive(core)
    }
}

@MainActor
final class BoundCooperativeDoublesSession {
    private struct TerminalEncounter {
        let local:UUID,peer:UUID,id:UUID,peerID:UUID?
        let capture:BoundCooperativeSnapshot,proof:Data
        let kind:BoundCooperativePacket.Kind
    }
    private struct DurableTerminal:Codable {
        let local:UUID,peer:UUID,id:UUID,peerID:UUID?,capture:Data,proof:Data,kind:UInt32
    }
    let probe=BoundCooperativeProbe(), cable=BoundNativeBattleProbe()
    private var gameProfile: BoundGameProfile?
    private var profileVerification: Task<Void, Never>?
    private weak var core:EmulatorCore?
    private weak var soul:BoundSoulProbe?
    var continuationContext:BoundNativeContinuationContext?
    var continuationHeadsProvider:((BoundNativeContinuationContext)->BoundContinuationHeads?)?
    private var pendingSettlement:BoundContinuationSettlement?
    func continuationSettlement()->BoundContinuationSettlement? { !blocksAutoSave ? pendingSettlement:nil }
    func settleContinuation(_ token:BoundContinuationSettlement) throws { try continuationStore.settle(token) }
    static func settlePersistedContinuation(_ token:BoundContinuationSettlement) throws {
        try BoundNativeContinuationStore(root:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Cooperative Activity Continuations",isDirectory:true)).settle(token)
    }
    private var activeContinuationContext:BoundNativeContinuationContext?
    private var continuationTicket:UUID?,continuationWriteBlocked=false
    private let continuationClaimant=UUID()
    private let continuationStore=BoundNativeContinuationStore(root:FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Cooperative Activity Continuations",isDirectory:true))
    var hasSavedContinuation:Bool { continuationTicket != nil }
    var blocksCoreResume:Bool { waitingForConnection || continuationWriteBlocked }
    private var gameID="",timer:Timer?,snapshot:BoundCooperativeSnapshot?,capture:BoundCooperativeSnapshot?
    private var local:UUID?,peer:UUID?,encounter=UUID(),peerEncounter:UUID?
    private var peerTeam:BoundCooperativePacket?,enemy=Data(),proof=Data(),peerReady=false,readySent=false,started=false
    private var prepared=false,peerCableReady=false,peerResultsReady=false,peerFinished=false,cancellingBeforeEntry=false,fixedRole:UInt32?
    private var recoveryNonce=UUID(),peerRecoveryNonce:UUID?,recoveryPeerReady=false,recoveryReadySent=false
    private var recoveryCable=Data(),recoveryDigest="",recoveryAgreement=Data(),recoveryLoaded=false
    private var recoveryCut:BoundCooperativeCableCut?
    private var recoveryBranch=Data()
    private var channel:(any BoundBattleChannel)?,wire:BoundBattleWire?
    private var checkpoint:URL?,journal:URL?,lastXP=Data(),incomingXP=Data(),sequence:UInt32=0
    private var controlCursor=0
    private var lastSent:TimeInterval=0,lastPeer=ProcessInfo.processInfo.systemUptime,lastXPSent:TimeInterval=0
    private var interruptedAt:TimeInterval?,resumeAfterTransport=false
    private var retryChannelAt:TimeInterval=0
    private var channelGeneration=UUID(),wireGeneration=UUID(),transportNonce=UUID(),peerTransportNonce:UUID?
    private var retiredTransportNonces:[UUID]=[]
    private var terminalEncounters:[UUID:TerminalEncounter]=[:],terminalOrder:[UUID]=[]
    private var peerTransportReady=false,sentTransportReady=false
    private let clock:()->TimeInterval
    private(set) var waitingForConnection=false
    private(set) var status="" { didSet { if status != oldValue { changed?(status) } } }
    private(set) var recoveryPending=false
    var changed:((String)->Void)?
    var context:(()->(UUID,UUID)?)?
    var connected:(()->Bool)?
    var canResume:(()->Bool)?
    var releaseGameplayInputs:(()->Void)?
    var makeChannel:((@escaping @Sendable (Data)->Void,@escaping @Sendable ()->Void)->(any BoundBattleChannel)?)?
    var send:((Data)->Bool)?
    var isActive:Bool { snapshot.map { (1...7).contains($0.phase) || $0.phase == 9 } ?? false }
    var blocksAutoSave:Bool { isActive || recoveryPending }
    private var isHost:Bool { if let fixedRole { return fixedRole == 0 };guard let local,let peer else { return false };return local.uuidString < peer.uuidString }
    init(clock:@escaping ()->TimeInterval={ ProcessInfo.processInfo.systemUptime }) { self.clock=clock }
    func bind(core:EmulatorCore?,gameID:String,soul:BoundSoulProbe) {
        guard self.core !== core || self.gameID != gameID else { return }
        // Delta may already have stopped the old core and replaced its bridge.
        // Preserve its last durable receipt without reading the new game's RAM.
        if continuationTicket==nil,self.core?.state != .stopped { suspend() }
        timer?.invalidate();timer=nil;channel?.close();wire?.close();channel=nil;wire=nil
        if let oldCore=self.core {
            self.soul?.setCooperativeBattleActive(false,for:oldCore)
            BoundVBABattleBridge.closeCooperativeCable()
        }
        continuationTicket=nil;continuationWriteBlocked=false;activeContinuationContext=nil
        snapshot=nil;capture=nil;local=nil;peer=nil;peerEncounter=nil;peerTeam=nil
        enemy=Data();proof=Data();started=false;prepared=false;fixedRole=nil;cancellingBeforeEntry=false
        peerReady=false;readySent=false;peerCableReady=false;peerResultsReady=false;peerFinished=false
        recoveryPending=false;recoveryLoaded=false;recoveryPeerReady=false;recoveryReadySent=false
        recoveryCut=nil;recoveryBranch=Data();recoveryCable=Data();recoveryDigest="";recoveryAgreement=Data();peerRecoveryNonce=nil
        checkpoint=nil;journal=nil;lastXP=Data();incomingXP=Data();encounter=UUID();recoveryNonce=UUID()
        lastSent=0;lastPeer=clock();lastXPSent=0;controlCursor=0;status=""
        waitingForConnection=false;interruptedAt=nil;resumeAfterTransport=false;retryChannelAt=0
        channelGeneration=UUID();wireGeneration=UUID();transportNonce=UUID();peerTransportNonce=nil;peerTransportReady=false;sentTransportReady=false
        retiredTransportNonces=[]
        profileVerification?.cancel();gameProfile=nil
        self.core=core;self.gameID=gameID;self.soul=soul
        probe.configure(core:core,gameID:gameID,soul:soul);cable.configure(core:nil)
        if let core,core.deltaCore.identifier == "com.rileytestut.GBADeltaCore" {
            let id=ObjectIdentifier(core),url=core.game.fileURL
            profileVerification=Task { [weak self] in
                let admitted=await Task.detached(priority:.utility) {
                    guard let data=try? Data(contentsOf:url,options:.mappedIfSafe) else { return Optional<BoundGameProfile>.none }
                    return try? MultiRedAdapter(rom:data).profile
                }.value
                guard !Task.isCancelled,let self,self.core.map(ObjectIdentifier.init)==id,self.gameID==gameID,
                      let admitted,admitted.supportsCooperativeDoubles else { return }
                self.gameProfile=admitted;self.probe.setProfile(admitted);self.findRecovery()
            }
            let timer=Timer(timeInterval:0.05,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.advance() } }
            RunLoop.main.add(timer,forMode:.common);self.timer=timer
        }
    }
    #if DEBUG && targetEnvironment(simulator)
    func qaInterruptedCheckpoint(_ bytes:Data,state:URL,journal:URL,recovering:Bool=false) {
        guard let value=BoundCooperativeSnapshot(bytes) else { return }
        gameProfile=BoundGameProfiles.current;probe.setProfile(gameProfile)
        snapshot=value;capture=value;checkpoint=state;self.journal=journal;started=true;prepared=true;recoveryPending=recovering
    }
    func qaCompletedFrame(_ bytes:Data) {
        // Synthetic lifecycle fixtures explicitly supply the current ABI; real
        // callbacks require the complete owned-file admission above.
        gameProfile=BoundGameProfiles.current;probe.setProfile(gameProfile)
        probe.qaCompletedFrame(bytes);advance()
    }
    func qaResumeRecoveredCore() { if let core { resumeIfPermitted(core) } }
    #endif
    private func resetEncounter(_ value:BoundCooperativeSnapshot,local:UUID,peer:UUID) {
        activeContinuationContext=continuationContext
        self.local=local;self.peer=peer;capture=value;encounter=UUID();peerEncounter=nil;peerTeam=nil;enemy=isHost ? value.enemy:Data()
        proof=Data();peerReady=false;readySent=false;started=false;prepared=false;peerCableReady=false;peerResultsReady=false;peerFinished=false;fixedRole=isHost ? 0:1;lastXP=Data();incomingXP=Data();lastPeer=clock();lastSent=0;lastXPSent=0;controlCursor=0
        transportNonce=UUID();peerTransportNonce=nil;peerTransportReady=false;sentTransportReady=false
        retiredTransportNonces=[]
    }
    func receive(_ data:Data) {
        guard let packet=BoundCooperativePacket(data:data) else { return }
        if let terminal=terminalEncounters[packet.peerID] ?? persistedTerminal(packet.peerID),packet.sender == terminal.peer,packet.receiver == terminal.local,
           terminal.peerID == nil || packet.id == terminal.peerID,packet.encounter == terminal.capture.encounter {
            if ![.cancel,.finished].contains(packet.kind) {
                _=send?(BoundCooperativePacket(kind:terminal.kind,local:terminal.local,peer:terminal.peer,
                    id:terminal.id,peerID:packet.id,snapshot:terminal.capture,proof:terminal.proof).data)
            }
            return
        }
        if packet.kind == .recoveryOffer || packet.kind == .recoveryReady { receiveRecovery(packet);return }
        guard let value=snapshot,let local,let peer,
              packet.sender == peer,packet.receiver == local,packet.encounter == value.encounter,
              peerEncounter == nil || peerEncounter == packet.id else { return }
        if ![.offer,.resumeOffer].contains(packet.kind),packet.peerID != encounter { return }
        if packet.kind == .resumeOffer,packet.peerID != encounter,
           !coopUUID(packet.peerID).allSatisfy({ $0 == 0 }) { return }
        peerEncounter=packet.id;lastPeer=clock()
        switch packet.kind {
        case .offer: break
        case .team:
            if let old=peerTeam,(old.payload != packet.payload || old.order != packet.order || old.count != packet.count || old.token != packet.token) { interrupt("Friend’s selected team changed");return }
            peerTeam=packet
        case .enemy: if !isHost { enemy=packet.payload }
        case .ready: if let expected=agreementProof(),packet.proof == expected { peerReady=true }
        case .xp:
            guard started,packet.proof == proof else { return }
            let xp=packet.payload
            guard xp.count >= 8,[UInt32(1),2].contains(coopWord(xp,0)),coopWord(xp,4) == xp.count-8 else { return }
            incomingXP=xp
        case .cancel: interrupt("Cooperative battle interrupted");return
        case .finished: if packet.proof==proof,proof.count==32 { peerFinished=true;peerResultsReady=true;peerCableReady=true }
        case .resultsReady: if packet.proof==proof,proof.count==32 { peerResultsReady=true;peerCableReady=true }
        case .cableReady: if packet.proof == proof,proof.count == 32 { peerCableReady=true }
        case .resumeOffer:
            guard !prepared && !started || packet.proof == proof else { return }
            let nonce=coopID(packet.payload,0)
            guard !retiredTransportNonces.contains(nonce) else { return }
            if peerTransportNonce != nonce {
                if let previous=peerTransportNonce { retiredTransportNonces=Array((retiredTransportNonces+[previous]).suffix(32)) }
                transportInterrupted();peerTransportNonce=nonce
                peerTransportReady=false;sentTransportReady=false
            }
            sendTransportReady(nonce)
        case .resumeReady:
            guard waitingForConnection,let peerTransportNonce,
                  coopID(packet.payload,0) == peerTransportNonce,
                  coopID(packet.payload,16) == transportNonce,
                  !prepared && !started || packet.proof == proof else { return }
            peerTransportReady=true
        case .recoveryOffer,.recoveryReady: break
        }
        advance()
    }
    private func agreementProof()->Data? {
        guard let value=capture,value.selected,let local,let peer,let peerEncounter,let peerTeam,enemy.count == 600 else { return nil }
        var bytes=Data("Bound cooperative doubles v1".utf8)
        for id in isHost ? [local,peer,encounter,peerEncounter]:[peer,local,peerEncounter,encounter] { bytes.append(coopUUID(id)) }
        bytes.append(value.encounter)
        var own=coopHash(value.party)+value.order,other=coopHash(peerTeam.payload)+peerTeam.order
        for n in [value.count,value.token] { var b=Data(repeating:0,count:4);coopPut(n,in:&b,at:0);own.append(b) }
        for n in [peerTeam.count,peerTeam.token] { var b=Data(repeating:0,count:4);coopPut(n,in:&b,at:0);other.append(b) }
        bytes.append(isHost ? own+other:other+own);bytes.append(coopHash(enemy))
        bytes.append(Data((gameProfile?.romSHA256 ?? "").utf8))
        return coopHash(bytes)
    }
    private func transmit(_ kind:BoundCooperativePacket.Kind,payload:Data=Data())->Bool {
        guard let value=capture,let local,let peer else { return false }
        return send?(BoundCooperativePacket(kind:kind,local:local,peer:peer,id:encounter,peerID:peerEncounter,snapshot:value,
            proof:proof.count == 32 ? proof:Data(repeating:0,count:32),enemyHash:enemy.count == 600 ? coopFNV(enemy):nil,payload:payload).data) == true
    }
    private func advance() {
        guard gameProfile?.supportsCooperativeDoubles == true else { return }
        if recoveryPending { advanceRecovery();return }
        let (next,durable,error)=probe.read()
        if let error { interrupt(error);return }
        guard let value=next else { return }
        let old=snapshot;snapshot=value
        guard let core else { return }
        if cancellingBeforeEntry {
            if value.phase==0 || value.phase==8 { finish();cancellingBeforeEntry=false }
            else { publish(flags:4) }
            return
        }
        if (value.phase == 0 || value.phase == 8),prepared || started { finish() }
        if capture == nil,(1...7).contains(value.phase),let local,let peer {
            resetEncounter(value,local:local,peer:peer)
        }
        guard BoundMultiplayerFeatures.isEnabled else {
            if started || (1...7).contains(value.phase) { suspend() }
            publish(flags:0);return
        }
        guard connected?() == true else {
            if started || (1...7).contains(value.phase) { transportInterrupted() }
            else { publish(flags:0) }
            return
        }
        if waitingForConnection {
            if core.state == .running { resumeAfterTransport=true;_=core.pause() }
            resumeTransportIfReady()
            guard !waitingForConnection else { return }
        }
        wire?.tick()
        if value.phase == 0 || value.phase == 8 {
            if started { finish() }
            if !started && !prepared { fixedRole=nil }
            if let identities=context?() { local=identities.0;peer=identities.1;publish(flags:1) }
            else { publish(flags:0) }
            return
        }
        // The transport authenticates the room and account. A presence rejoin
        // rotates its field-pose challenge, but cannot replace a resident
        // encounter's identities or already agreed teams.
        guard let identities=(local.flatMap { l in peer.map { (l,$0) } }) ?? context?() else {
            transportInterrupted();return
        }
        if (!started && old?.token != value.token) || local == nil {
            guard !started else { interrupt("Cooperative encounter changed");return }
            resetEncounter(value,local:identities.0,peer:identities.1)
        }
        if !started { capture=value }
        if value.phase == 9 { interrupt("Cooperative recovery kept. Reconnect with your friend.");return }
        if value.phase == 7 {
            let now=clock()
            if now-lastPeer>2 { transportInterrupted();return }
            if now-lastSent>=0.25 { _=transmit(.finished);lastSent=now }
            publish(flags:peerFinished ? 1:11);status="Finishing cooperative battle"
            return
        }
        if value.error != 0 { interrupt("Cooperative battle needs recovery");return }
        if started {
            if cable.take()?.error == true { interrupt("Cooperative native connection needs recovery");return }
            if cable.networkAge>2 { transportInterrupted();return }
        }
        if clock()-lastPeer>2 { transportInterrupted();return }
        let now=clock()
        if now-lastSent >= 0.25 {
            var delivered=true
            if started {
                delivered=transmit(value.phase==6 && durable ? .resultsReady:.cableReady)
            } else if prepared {
                delivered=transmit(.ready) && transmit(.cableReady)
            } else if peerEncounter==nil || !value.selected {
                delivered=transmit(.offer)
            } else {
                if let agreed=agreementProof() { proof=agreed }
                var messages:[(BoundCooperativePacket.Kind,Data)]=[(.team,value.party)]
                if isHost { messages.append((.enemy,enemy)) }
                if proof.count==32 { messages.append((.ready,Data())) }
                // Two packets per250ms bounds pre-entry control to8/s while
                // rotating full teams/enemies until the agreement is proved.
                for _ in 0..<min(2,messages.count) {
                    let message=messages[controlCursor % messages.count];controlCursor+=1
                    let sent=transmit(message.0,payload:message.1);delivered=delivered && sent
                    if message.0 == .ready { readySent=readySent || sent }
                }
            }
            lastSent=now
            if !delivered { transportInterrupted();return }
        }
        if value.selected,readySent,peerReady,!prepared {
            do {
                try protect(core:core)
                guard prepareCable() else { throw CocoaError(.featureUnsupported) }
                prepared=true;_ = transmit(.cableReady)
            } catch { interrupt("Couldn’t prepare cooperative recovery");return }
        }
        if prepared,peerCableReady { started=true;status="Cooperative battle" }
        // The ROM identifies XP barriers by token and imports identical records
        // idempotently. Retrying a pending barrier cannot award XP twice, while
        // a locally accepted send may still have been lost during a socket gap.
        if started,!value.xp.isEmpty,value.xp != lastXP || now-lastXPSent>=0.5 {
            if transmit(.xp,payload:value.xp) { lastXP=value.xp;lastXPSent=now }
        }
        if value.phase==6,durable {
            publish(flags:peerResultsReady ? 11:3)
        } else { publish(flags:started ? 3:1) }
    }
    private func resumeIfPermitted(_ core:EmulatorCore) {
        guard self.core === core,core.state == .paused,canResume?() == true else { return }
        _=core.resume()
    }
    /// Retain the resident cartridge, command queues and ownership journal.
    /// A network interruption never selects a recovery snapshot or rolls back XP.
    func transportInterrupted() {
        guard !recoveryPending,isActive || started || prepared else { return }
        if !waitingForConnection {
            waitingForConnection=true;interruptedAt=clock();transportNonce=UUID()
            peerTransportReady=false;sentTransportReady=false
            resumeAfterTransport=core?.state == .running
            releaseGameplayInputs?()
        }
        if core?.state == .running { resumeAfterTransport=true;_=core?.pause() }
        if let core,core.state == .paused { core.deltaCore.emulatorBridge.resetInputs() }
        channelGeneration=UUID();channel?.close();channel=nil;wire?.suspend()
        cable.suspendTransport();retryChannelAt=0
        status="Waiting for your friend"
    }
    func transportResumed() {
        guard waitingForConnection else { return }
        resumeTransportIfReady()
    }
    private func sendTransportReady(_ nonce:UUID) {
        guard continuationTicket==nil,!continuationWriteBlocked else { return }
        let currentEncounter=encounter,currentNonce=transportNonce
        let delivered=transmit(.resumeReady,payload:coopUUID(currentNonce)+coopUUID(nonce))
        guard waitingForConnection,encounter == currentEncounter,transportNonce == currentNonce,
              peerTransportNonce == nonce else { return }
        sentTransportReady=sentTransportReady || delivered
    }
    private func resumeTransportIfReady() {
        guard waitingForConnection,connected?() == true,BoundMultiplayerFeatures.isEnabled,
              let core,core.state != .stopped else { return }
        if core.state == .running { resumeAfterTransport=true;_=core.pause() }
        if core.state == .paused { core.deltaCore.emulatorBridge.resetInputs() }
        guard canResume?() == true,claimContinuation() else { return }
        let now=clock()
        if capture == nil,let snapshot,let identities=context?() {
            resetEncounter(snapshot,local:identities.0,peer:identities.1)
        }
        let currentEncounter=encounter,currentNonce=transportNonce
        // Phase 7 already contains the cartridge's completed owner projection.
        // A terminal peer may have closed its wire after completing too; its
        // matching Finished control is sufficient to release native cleanup.
        let completing=snapshot?.phase == 7 && peerFinished
        if prepared,!completing,channel == nil,now >= retryChannelAt {
            retryChannelAt=now+1
            guard bindTransportChannel() else { return }
        }
        if now-lastSent>=0.25 {
            lastSent=now
            _=transmit(.resumeOffer,payload:coopUUID(transportNonce))
            guard waitingForConnection,encounter == currentEncounter,transportNonce == currentNonce else { return }
            if let peerTransportNonce { sendTransportReady(peerTransportNonce) }
        }
        wire?.tick()
        guard waitingForConnection,encounter == currentEncounter,transportNonce == currentNonce else { return }
        guard completing || peerTransportReady && sentTransportReady && (!prepared || channel != nil) else { return }
        guard !resumeAfterTransport || canResume?() == true else { return }
        waitingForConnection=false;interruptedAt=nil;lastPeer=now
        cable.resumeTransport()
        status=started ? "Cooperative battle":"Preparing cooperative battle"
        if resumeAfterTransport {
            resumeIfPermitted(core)
            guard core.state == .running else { waitingForConnection=true;cable.suspendTransport();return }
            resumeAfterTransport=false
        }
    }
    private func bindTransportChannel()->Bool {
        guard continuationTicket==nil,!continuationWriteBlocked,let wire else { return false }
        let generation=UUID();channelGeneration=generation
        let interrupted:@Sendable ()->Void={ [weak self] in Task { @MainActor in
            guard let self,self.channelGeneration == generation else { return }
            self.transportInterrupted()
        } }
        guard let channel=makeChannel?({ bytes in wire.receive(bytes) },interrupted) else { return false }
        self.channel=channel;wire.setSender { [channel] bytes in channel.send(bytes) }
        return true
    }
    private func configureCableWire(recovery:Bool=false)->Bool {
        guard let core,let peerEncounter else { return false }
        let generation=UUID();wireGeneration=generation
        let failure:@Sendable ()->Void={ [weak self] in Task { @MainActor in
            guard let self,self.wireGeneration == generation else { return }
            self.interrupt("Cooperative native connection needs recovery")
        } }
        let interrupted:@Sendable ()->Void={ [weak self] in Task { @MainActor in
            guard let self,self.wireGeneration == generation else { return }
            self.transportInterrupted()
        } }
        cable.configure(core:core)
        if recovery,recoveryCut?.isAdmission != true,!cable.restoreRecoveryData(recoveryCable) { return false }
        let ids=(recovery ? [recoveryNonce,peerRecoveryNonce ?? peerEncounter]:[encounter,peerEncounter]).sorted { $0.uuidString < $1.uuidString }
        var namespace=proof;namespace.append(coopUUID(ids[0]));namespace.append(coopUUID(ids[1]))
        let safe=BoundBattleWire(id:coopID(coopHash(namespace),0),receive:{ [cable] bytes in if !cable.receiveNetworkPacket(bytes) { failure() } },failed:failure,interrupted:interrupted)
        wire=safe
        cable.setSender({ bytes in safe.send(bytes) },failed:failure,interrupted:interrupted)
        return true
    }
    private func prepareCable(recovery:Bool=false)->Bool {
        guard let core,let peerEncounter else { return false }
        guard configureCableWire(recovery:recovery) else { return false }
        let channelReady=bindTransportChannel()
        let running=core.state == .running
        if running { _=core.pause() }
        let prepared=BoundVBABattleBridge.prepareCooperativeCable(forPlayer:isHost ? 0:1)
        var checkpointReady=true
        if prepared && !recovery {
            probe.checkpointNow(core)
            let (_,durable,error)=probe.read();checkpointReady=durable && error==nil
            if checkpointReady { cable.enableSender() }
        }
        if running && !recovery { resumeIfPermitted(core) }
        if prepared && checkpointReady && !channelReady && !recovery { transportInterrupted() }
        return prepared && checkpointReady
    }
    private func publish(flags:UInt32) {
        sequence &+= 2;if sequence == 0 { sequence=2 }
        probe.setHost(BoundCooperativeHost.transaction(sequence:sequence,flags:flags,role:isHost ? 0:1,
            capture:capture,peerTeam:peerTeam,proof:proof,enemy:enemy,xp:incomingXP))
    }
    private func protect(core:EmulatorCore) throws {
        let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Cooperative Battles",isDirectory:true)
        try BoundServerMemoryFiles.directory(folder,gameID:gameID)
        guard BoundVBABattleBridge.setCooperativeGameSaveAllowed(false,for:core.game.gameSaveURL) else { throw CocoaError(.fileWriteNoPermission) }
        checkpoint=folder.appendingPathComponent(encounter.uuidString+".state");journal=folder.appendingPathComponent(encounter.uuidString+".json")
        guard let checkpoint,let journal else { throw CocoaError(.fileWriteUnknown) }
        let running=core.state == .running;if running { _=core.pause() }
        defer { if running { resumeIfPermitted(core) } }
        try BoundServerMemoryFiles.saveState(core:core,to:checkpoint,gameID:gameID)
        let saved=try BoundServerMemoryFiles.read(checkpoint,gameID:gameID);guard saved.count > 1024 else { throw CocoaError(.fileReadCorruptFile) }
        guard let capture,let peerTeam,proof.count==32,enemy.count==600 else { throw CocoaError(.fileReadCorruptFile) }
        let agreement=try JSONEncoder().encode(BoundCooperativeRecovery(capture:capture.bytes,proof:proof,enemy:enemy,role:isHost ? 0:1,peerTeam:peerTeam.data))
        recoveryAgreement=agreement;recoveryBranch=BoundCooperativeRecoveryBranch.initial(proof:proof)
        let entry:[String:String]=["gameID":gameID,"state":checkpoint.lastPathComponent,"rom":(gameProfile?.romSHA256 ?? ""),"sha256":coopHash(saved).map { String(format:"%02x",$0) }.joined(),"agreement":agreement.base64EncodedString(),"branch":recoveryBranch.base64EncodedString(),"snapshot":capture.bytes.base64EncodedString(),"cable":cable.recoveryData().base64EncodedString()]
        try BoundServerMemoryFiles.write(JSONSerialization.data(withJSONObject:entry,options:[.sortedKeys]),to:journal,gameID:gameID)
        probe.protect(state:checkpoint,journal:journal,agreement:agreement,branch:recoveryBranch,cable:cable)
    }
    func protectLocalLifecycle()->Bool {
        guard isActive || started || prepared else { return true }
        transportInterrupted();resumeAfterTransport=true
        guard let journal=probe.recoveryLocation().1 ?? journal else { return true }
        do {
            var value=try JSONSerialization.jsonObject(with:BoundServerMemoryFiles.read(journal,gameID:gameID)) as? [String:Any]
            guard value != nil else { throw CocoaError(.fileReadCorruptFile) }
            value?["localContinuation"]=true
            try BoundServerMemoryFiles.write(JSONSerialization.data(withJSONObject:value!,options:[.sortedKeys]),to:journal,gameID:gameID)
            return true
        } catch { status="Couldn’t protect this battle. Keep the game open.";return false }
    }
    func showLocalExitUnavailable() { status="Keep this local save open to continue the battle." }
    @discardableResult func checkpointForContinuation()->Bool {
        guard isActive || started || prepared else { return !recoveryPending }
        if continuationTicket != nil { return true }
        transportInterrupted();resumeAfterTransport=true
        guard !recoveryPending,let core,core.state == .paused,let context=activeContinuationContext ?? continuationContext,
              let snapshot=probe.read().0 ?? snapshot else { status="Keep this game open until its battle can be saved";return false }
        self.snapshot=snapshot
        do {
            continuationWriteBlocked=true
            let transport=try wire?.freezeForContinuation() ?? Data()
            let locations=probe.recoveryLocation(),stateURL=locations.0 ?? checkpoint,journalURL=locations.1 ?? journal
            let value=BoundCooperativeContinuation(version:1,ticket:UUID(),context:context,gameID:gameID,
                cartridge:coopHash(try Data(contentsOf:core.game.fileURL,options:.mappedIfSafe)).map { String(format:"%02x",$0) }.joined(),
                state:MultiRedAdapter.captureState(),battery:BoundVBABattleBridge.captureServerBattery(),
                bridge:prepared ? BoundVBABattleBridge.captureCooperativeSession():Data(),host:probe.continuationHost(),probe:cable.recoveryData(),wire:transport,
                memoryFiles:BoundServerMemoryFiles.snapshot(gameID:gameID),heads:continuationHeadsProvider?(context),snapshot:snapshot.bytes,capture:capture?.bytes,
                local:local,peer:peer,encounter:encounter,peerEncounter:peerEncounter,peerTeam:peerTeam?.data,enemy:enemy,proof:proof,
                peerReady:peerReady,readySent:readySent,started:started,prepared:prepared,peerCableReady:peerCableReady,
                peerResultsReady:peerResultsReady,peerFinished:peerFinished,fixedRole:fixedRole,lastXP:lastXP,incomingXP:incomingXP,
                sequence:sequence,controlCursor:controlCursor,checkpointName:stateURL?.lastPathComponent,journalName:journalURL?.lastPathComponent,
                checkpoint:try stateURL.map { try BoundServerMemoryFiles.read($0,gameID:gameID) },
                journal:try journalURL.map { try BoundServerMemoryFiles.read($0,gameID:gameID) },agreement:recoveryAgreement,branch:recoveryBranch)
            try continuationStore.save(value)
            activeContinuationContext=context;continuationTicket=value.ticket;continuationWriteBlocked=false
            return true
        } catch {
            status="Couldn’t save this battle. Keep the game open and try again.";return false
        }
    }
    @discardableResult func restoreContinuationIfAvailable(serverHead:UUID?=nil) throws -> Bool {
        if continuationTicket != nil { return true }
        guard let core,core.state == .paused,let context=continuationContext,
              let value=try continuationStore.load(context:context,gameID:gameID,as:BoundCooperativeContinuation.self) else { return false }
        guard context.runID==nil || value.heads?.permits(serverHead)==true else { throw BoundContinuationError.serverChanged }
        let admitted=try MultiRedAdapter(rom:Data(contentsOf:core.game.fileURL,options:.mappedIfSafe)).profile
        guard admitted.supportsCooperativeDoubles,value.cartridge==admitted.romSHA256,
              let savedSnapshot=BoundCooperativeSnapshot(value.snapshot) else { throw CocoaError(.fileReadCorruptFile) }
        // Restore is already holding the paused core. Keep this exact admission
        // through the operation and prevent a late bind task rescanning recovery.
        profileVerification?.cancel();profileVerification=nil;gameProfile=admitted
        channel?.close();wire?.close();channel=nil;wire=nil;cable.configure(core:nil);BoundVBABattleBridge.closeCooperativeCable()
        do {
            guard MultiRedAdapter.restoreState(value.state),BoundVBABattleBridge.restoreServerBattery(value.battery),
                  BoundVBABattleBridge.installCooperativeDoubles(),
                  !value.prepared || BoundVBABattleBridge.restoreCooperativeSession(value.bridge) else { throw CocoaError(.fileReadCorruptFile) }
            if BoundServerMemoryFiles.isEnabled(for:gameID) { try BoundServerMemoryFiles.restore(value.memoryFiles,gameID:gameID) }
            snapshot=savedSnapshot;capture=value.capture.flatMap(BoundCooperativeSnapshot.init)
            local=value.local;peer=value.peer;encounter=value.encounter;peerEncounter=value.peerEncounter;peerTeam=value.peerTeam.flatMap { BoundCooperativePacket(data:$0) }
            enemy=value.enemy;proof=value.proof;peerReady=value.peerReady;readySent=value.readySent;started=value.started;prepared=value.prepared
            peerCableReady=value.peerCableReady;peerResultsReady=value.peerResultsReady;peerFinished=value.peerFinished
            fixedRole=value.fixedRole;lastXP=value.lastXP;incomingXP=value.incomingXP;sequence=value.sequence;controlCursor=value.controlCursor
            recoveryAgreement=value.agreement;recoveryBranch=value.branch;recoveryPending=false;recoveryLoaded=false;cancellingBeforeEntry=false
            let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Cooperative Battles",isDirectory:true)
            try BoundServerMemoryFiles.directory(folder,gameID:gameID)
            checkpoint=value.checkpointName.map { folder.appendingPathComponent($0) };journal=value.journalName.map { folder.appendingPathComponent($0) }
            if let checkpoint,let bytes=value.checkpoint { try BoundServerMemoryFiles.write(bytes,to:checkpoint,gameID:gameID) }
            if let journal,let bytes=value.journal { try BoundServerMemoryFiles.write(bytes,to:journal,gameID:gameID) }
            if prepared {
                guard configureCableWire(),cable.restoreRecoveryData(value.probe),wire?.restoreContinuation(value.wire)==true else { throw CocoaError(.fileReadCorruptFile) }
            }
            probe.configure(core:core,gameID:gameID,soul:soul)
            probe.setProfile(admitted)
            if let checkpoint,let journal { probe.protect(state:checkpoint,journal:journal,agreement:recoveryAgreement,branch:recoveryBranch,cable:cable) }
            probe.restoreContinuation(snapshot:savedSnapshot,host:value.host);BoundVBABattleBridge.setCooperativeHost(value.host)
            activeContinuationContext=context;continuationTicket=value.ticket;continuationWriteBlocked=false
            waitingForConnection=true;resumeAfterTransport=true;transportNonce=UUID();peerTransportNonce=nil;retiredTransportNonces=[]
            peerTransportReady=false;sentTransportReady=false;lastSent=0;lastPeer=clock();retryChannelAt=0
            cable.suspendTransport();core.deltaCore.emulatorBridge.resetInputs()
            soul?.setCooperativeBattleActive(prepared || started,for:core)
            _=BoundVBABattleBridge.setCooperativeGameSaveAllowed(false,for:core.game.gameSaveURL)
            status="Waiting for your friend"
            return true
        } catch {
            continuationWriteBlocked=true;waitingForConnection=true
            status="This battle needs recovery. Its saved continuation was kept."
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
        } catch { status="Couldn’t reopen this battle. Try again.";return false }
    }
    func suspend() {
        guard claimContinuation() else { return }
        guard !recoveryPending else { return }
        guard isActive || started else { return }
        _=transmit(.cancel)
        interrupt("Cooperative recovery kept. Reconnect with your friend.")
    }
    private func persistedTerminal(_ id:UUID)->TerminalEncounter? {
        guard let context=activeContinuationContext ?? continuationContext,
              let bytes=try? continuationStore.terminal(id:id,context:context,gameID:gameID),
              let value=try? JSONDecoder().decode(DurableTerminal.self,from:bytes),
              let capture=BoundCooperativeSnapshot(value.capture),let kind=BoundCooperativePacket.Kind(rawValue:value.kind),
              [.cancel,.finished].contains(kind),value.proof.count==32,value.id==id else { return nil }
        return TerminalEncounter(local:value.local,peer:value.peer,id:value.id,peerID:value.peerID,capture:capture,proof:value.proof,kind:kind)
    }
    private func retireEncounter(_ kind:BoundCooperativePacket.Kind)->Bool {
        guard let local,let peer,let capture else { return true }
        let terminal=TerminalEncounter(local:local,peer:peer,id:encounter,peerID:peerEncounter,capture:capture,
            proof:proof.count == 32 ? proof:Data(repeating:0,count:32),kind:kind)
        if let context=activeContinuationContext {
            do {
                let value=DurableTerminal(local:local,peer:peer,id:encounter,peerID:peerEncounter,capture:capture.bytes,proof:terminal.proof,kind:kind.rawValue)
                try continuationStore.saveTerminal(id:encounter,data:JSONEncoder().encode(value),context:context,gameID:gameID)
            } catch { transportInterrupted();status="Couldn’t save the battle result. Try again.";return false }
        }
        if terminalEncounters[encounter] == nil { terminalOrder.append(encounter) }
        terminalEncounters[encounter]=terminal
        if terminalOrder.count>32 { terminalEncounters.removeValue(forKey:terminalOrder.removeFirst()) }
        return true
    }
    private func interrupt(_ message:String) {
        guard claimContinuation() else { return }
        guard retireEncounter(.cancel) else { return }
        status=message
        let wasWaiting=waitingForConnection,resume=resumeAfterTransport
        waitingForConnection=false;interruptedAt=nil;resumeAfterTransport=false;channelGeneration=UUID();wireGeneration=UUID()
        if recoveryPending {
            channel?.close();wire?.close();channel=nil;wire=nil;prepared=false
            recoveryPeerReady=false;recoveryReadySent=false
            return
        }
        guard started,(snapshot?.phase ?? 0)>=4 else {
            started=false;publish(flags:4);cancellingBeforeEntry=true
            channel?.close();wire?.close();channel=nil;wire=nil;cable.configure(core:nil)
            if wasWaiting,resume,let core { resumeIfPermitted(core) }
            return
        }
        recoveryPending=true;recoveryNonce=UUID();peerRecoveryNonce=nil;recoveryPeerReady=false;recoveryReadySent=false;recoveryLoaded=false
        fixedRole=isHost ? 0:1;publish(flags:4)
        // Keep the live checkpoint, including earned XP and faint tombstones.
        // Never load the pre-entry snapshot or run friendly-battle rollback.
        channel?.close();wire?.close();channel=nil;wire=nil
        if let core {
            if core.state == .running { _=core.pause() }
            probe.checkpointNow(core)
        }
        let locations=probe.recoveryLocation();checkpoint=locations.0 ?? checkpoint;journal=locations.1 ?? journal
        prepared=false
        let (_,durable,error)=probe.read()
        let retained=durable && error==nil && (journal.map { adoptRecovery(from:$0,expectedProof:proof) } ?? false)
        if !retained { recoveryCut=nil;status="Recovery kept. Compatible cable checkpoint required." }
        cable.configure(core:nil)
    }
    private func finish() {
        guard claimContinuation() else { return }
        let completed=started
        guard retireEncounter(completed ? .finished:.cancel) else { return }
        pendingSettlement=activeContinuationContext.flatMap { try? continuationStore.settlement(context:$0,gameID:gameID) }
        channelGeneration=UUID();wireGeneration=UUID()
        channel?.close();wire?.close();channel=nil;wire=nil;cable.configure(core:nil)
        if let core {
            let running=core.state == .running;if running { _=core.pause() }
            if completed,BoundVBABattleBridge.advanceAndObserve()["outcome"] as? Int == 1,proof.count==32 {
                soul?.timeline.append(id:"coop-victory:"+proof.map { String(format:"%02x",$0) }.joined(),kind:.victory,title:"Cooperative trainer battle won")
            }
            BoundVBABattleBridge.closeCooperativeCable();soul?.setCooperativeBattleActive(false,for:core)
            _=BoundVBABattleBridge.setCooperativeGameSaveAllowed(true,for:core.game.gameSaveURL)
            if running { resumeIfPermitted(core) }
        }
        let locations=probe.recoveryLocation();checkpoint=locations.0 ?? checkpoint;journal=locations.1 ?? journal
        if let journal { try? BoundServerMemoryFiles.remove(journal,gameID:gameID) }
        if let checkpoint { try? BoundServerMemoryFiles.remove(checkpoint,gameID:gameID) }
        probe.clearProtection()
        journal=nil;checkpoint=nil;started=false;prepared=false;fixedRole=nil;recoveryPending=false;status=completed ? "Cooperative battle complete":"Cooperative battle ended"
        waitingForConnection=false;interruptedAt=nil;resumeAfterTransport=false;peerTransportNonce=nil
        local=nil;peer=nil
    }
    private func findRecovery() {
        let folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Cooperative Battles",isDirectory:true)
        guard let files=try? BoundServerMemoryFiles.contents(folder,gameID:gameID) else { return }
        let ordered=files.filter { $0.pathExtension == "json" }.sorted {
            BoundServerMemoryFiles.modifiedAt($0,gameID:gameID) >
            BoundServerMemoryFiles.modifiedAt($1,gameID:gameID)
        }
        for url in ordered.prefix(64) { if adoptRecovery(from:url) { return } }
    }
    private func adoptRecovery(from url:URL,expectedProof:Data?=nil)->Bool {
        let folder=url.deletingLastPathComponent()
        guard let bytes=try? BoundServerMemoryFiles.read(url,gameID:gameID),bytes.count<=65536,
              let entry=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],entry["gameID"] as? String==gameID,
              entry["rom"] as? String==(gameProfile?.romSHA256 ?? ""),
              let encoded=entry["agreement"] as? String,let agreement=Data(base64Encoded:encoded),
              let record=try? JSONDecoder().decode(BoundCooperativeRecovery.self,from:agreement),record.proof.count==32,record.enemy.count==600,record.role<=1,
              expectedProof==nil || expectedProof==record.proof,
              let capture=BoundCooperativeSnapshot(record.capture),capture.selected,
              let team=BoundCooperativePacket(data:record.peerTeam),team.kind == .team,team.encounter==capture.encounter,
              let name=entry["state"] as? String,name==URL(fileURLWithPath:name).lastPathComponent,
              UUID(uuidString:URL(fileURLWithPath:name).deletingPathExtension().lastPathComponent) != nil,
              let digest=entry["sha256"] as? String,digest.count==64,
              let encodedCable=entry["cable"] as? String,let cable=Data(base64Encoded:encodedCable),cable.count<=32768,
              let encodedSnapshot=entry["snapshot"] as? String,let snapshotData=Data(base64Encoded:encodedSnapshot),
              let savedSnapshot=BoundCooperativeSnapshot(snapshotData),[UInt32(3),4,5,6,7,9].contains(savedSnapshot.phase),
              let encodedBranch=entry["branch"] as? String,let branch=Data(base64Encoded:encodedBranch),branch.count==32 else { return false }
        if entry["localContinuation"] as? Bool == true {
            continuationWriteBlocked=true;recoveryPending=true
            status="This local battle needs recovery. Its saved continuation was kept."
            return true
        }
        self.capture=capture;peerTeam=team;proof=record.proof;enemy=record.enemy;fixedRole=record.role;snapshot=savedSnapshot
        journal=url;checkpoint=folder.appendingPathComponent(name);recoveryAgreement=agreement;recoveryCable=cable;recoveryDigest=digest;recoveryBranch=branch
        if savedSnapshot.phase==3 { recoveryCut=BoundCooperativeCableCut(admissionPhase:3) }
        else if let encoded=entry["nativeCable"] as? String,let raw=Data(base64Encoded:encoded) {
            recoveryCut=BoundCooperativeCableCut(mailbox:raw,snapshot:savedSnapshot,hostRecovery:cable)
        } else { recoveryCut=nil }
        recoveryPending=true;recoveryNonce=UUID();peerRecoveryNonce=nil;recoveryPeerReady=false;recoveryReadySent=false;recoveryLoaded=false
        status="Waiting for friend to recover cooperative battle"
        if let core { _=BoundVBABattleBridge.setCooperativeGameSaveAllowed(false,for:core.game.gameSaveURL) }
        return true
    }
    private func recoveryPacket(_ kind:BoundCooperativePacket.Kind)->Data? {
        guard let capture,let pair=context?(),let recoveryCut,recoveryBranch.count==32,proof.count==32 else { return nil }
        var bytes=BoundCooperativePacket(kind:kind,local:pair.0,peer:pair.1,id:recoveryNonce,peerID:peerRecoveryNonce,
            snapshot:capture,proof:proof,enemyHash:coopFNV(enemy),payload:recoveryCut.data+recoveryBranch).data
        coopPut(isHost ? 0:1,in:&bytes,at:136)
        bytes[143]=UInt8(snapshot?.phase ?? 9)
        return bytes
    }
    private func receiveRecovery(_ packet:BoundCooperativePacket) {
        guard recoveryPending,BoundMultiplayerFeatures.isEnabled,connected?() == true,
              let identities=context?(),packet.sender==identities.1,packet.receiver==identities.0,
              packet.proof==proof,packet.encounter==capture?.encounter,packet.count==(isHost ? 1:0),
              peerRecoveryNonce==nil || peerRecoveryNonce==packet.id else { return }
        if packet.kind == .recoveryReady,packet.peerID != recoveryNonce { return }
        guard BoundCooperativeRecoveryBranch.accepts(packet.payload,current:recoveryBranch),let recoveryCut,let peerCut=BoundCooperativeCableCut(data:Data(packet.payload.prefix(92))),recoveryCut.compatible(with:peerCut) else {
            status="Cooperative checkpoints differ. Both recoveries were kept.";return
        }
        let ownBefore=snapshot?.phase==3,peerBefore=packet.data[143]==3
        guard ownBefore==peerBefore else { status="Cooperative checkpoints differ before battle entry. Recovery kept.";return }
        peerRecoveryNonce=packet.id;local=identities.0;peer=identities.1
        if packet.kind == .recoveryReady { recoveryPeerReady=true }
        lastPeer=ProcessInfo.processInfo.systemUptime
        advanceRecovery()
    }
    private func advanceRecovery() {
        guard let core,core.state != .stopped else { return }
        if core.state == .running { _=core.pause() }
        guard BoundMultiplayerFeatures.isEnabled,connected?() == true,let identities=context?() else { return }
        guard recoveryCut != nil else { status="Recovery kept. Compatible cable checkpoint required.";return }
        if local != identities.0 || peer != identities.1 {
            channel?.close();wire?.close();channel=nil;wire=nil;cable.configure(core:nil)
            local=identities.0;peer=identities.1;recoveryNonce=UUID();peerRecoveryNonce=nil
            recoveryPeerReady=false;recoveryReadySent=false;prepared=false
        }
        let now=ProcessInfo.processInfo.systemUptime
        let due=now-lastSent>=0.25
        if due,let offer=recoveryPacket(.recoveryOffer) { _=send?(offer);lastSent=now }
        guard peerRecoveryNonce != nil else { return }
        if !prepared {
            // A fresh wire namespace rejects delayed pre-disconnect packets.
            peerEncounter=peerRecoveryNonce
            guard prepareCable(recovery:true) else { status="Cooperative cable recovery unavailable";return }
            prepared=true
        }
        if due,let ready=recoveryPacket(.recoveryReady) { let sent=send?(ready)==true;recoveryReadySent=recoveryReadySent || sent }
        guard recoveryReadySent,recoveryPeerReady,!recoveryLoaded,
              let checkpoint,let journal,let saved=try? BoundServerMemoryFiles.read(checkpoint,gameID:gameID),
              coopHash(saved).map({ String(format:"%02x",$0) }).joined()==recoveryDigest else { return }
        do {
            guard try MultiRedAdapter(rom:Data(contentsOf:core.game.fileURL,options:.mappedIfSafe)).profile == gameProfile else { throw CocoaError(.fileReadCorruptFile) }
            try BoundServerMemoryFiles.loadState(core:core,from:checkpoint,gameID:gameID)
            if recoveryCut?.isAdmission == true {
                guard let restored=BoundCooperativeSnapshot(BoundVBABattleBridge.cooperativeSnapshot()),restored.phase==3,
                      let capture,restored.encounter==capture.encounter,restored.partyHash==capture.partyHash,
                      restored.party==capture.party,restored.order==capture.order,restored.role==(isHost ? 0:1) else { throw CocoaError(.fileReadCorruptFile) }
                // Both authenticated peers attested the same unstarted admission.
                // Recreate only the transport; the resident encounter stays intact.
                BoundVBABattleBridge.closeCooperativeCable()
                guard BoundVBABattleBridge.prepareCooperativeCable(forPlayer:isHost ? 0:1) else { throw CocoaError(.fileReadCorruptFile) }
            } else {
                guard BoundVBABattleBridge.resumeCooperativeCable(forPlayer:isHost ? 0:1) else { throw CocoaError(.fileReadCorruptFile) }
            }
            guard let peerRecoveryNonce else { throw CocoaError(.fileReadCorruptFile) }
            let nextBranch=BoundCooperativeRecoveryBranch.next(recoveryBranch,local:recoveryNonce,peer:peerRecoveryNonce)
            guard var entry=(try JSONSerialization.jsonObject(with:BoundServerMemoryFiles.read(journal,gameID:gameID))) as? [String:Any] else { throw CocoaError(.fileReadCorruptFile) }
            entry["branch"]=nextBranch.base64EncodedString()
            try BoundServerMemoryFiles.write(JSONSerialization.data(withJSONObject:entry,options:[.sortedKeys]),to:journal,gameID:gameID)
            recoveryBranch=nextBranch;encounter=recoveryNonce;peerEncounter=peerRecoveryNonce
            probe.protect(state:checkpoint,journal:journal,agreement:recoveryAgreement,branch:recoveryBranch,cable:cable)
            publish(flags:3);probe.checkpointNow(core)
            let (_,durable,error)=probe.read()
            guard durable,error==nil else { recoveryCut=nil;throw CocoaError(.fileWriteUnknown) }
            recoveryLoaded=true;recoveryPending=false;started=true;prepared=true;peerCableReady=true;lastXP=Data();incomingXP=Data()
            cable.enableSender()
            status="Cooperative battle recovered"
            resumeIfPermitted(core)
        } catch { status="Cooperative recovery could not be loaded. Checkpoint kept." }
    }
}
