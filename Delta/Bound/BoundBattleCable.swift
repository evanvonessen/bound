import Foundation

/// The transport retains/destroys the SDK on main. Implementations serialize
/// background data sends against invalidation before destroying that SDK.
protocol BoundBattleChannel: AnyObject, Sendable {
    func send(_ data: Data) -> Bool
    func close()
}

/// Explicit numbering protects the native byte stream from duplicate/reordered
/// messages. A wrong activity never reaches RAM.
final class BoundBattleWire: @unchecked Sendable {
    static let prefix = Data([0x42,0x46,0x53,0x32]) // BFS2: piggybacked cumulative acknowledgements
    private let lock = NSLock()
    private let id: UUID
    private var outgoing: UInt64 = 0
    private var expected: UInt64 = 1
    private var pending: [UInt64:Data] = [:]
    private var pendingBytes = 0
    private var unacknowledged: [UInt64: Data] = [:]
    private var lastTransmitted: [UInt64:TimeInterval] = [:]
    private var unacknowledgedBytes = 0
    private var lastRetry: TimeInterval?
    private var lastReceived = ProcessInfo.processInfo.systemUptime
    private var interruptionReported = false
    private var acknowledgementPending = false
    private var lastAcknowledgedAt: TimeInterval = 0
    private var active = true
    private var continuationFrozen = false
    private var sender: (@Sendable (Data) -> Bool)?
    private var senderGeneration=UUID()
    private let receiveBytes: @Sendable (Data) -> Void
    private let failed: @Sendable () -> Void
    private let interrupted: @Sendable () -> Void
    init(id: UUID, receive: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable () -> Void,
         interrupted: @escaping @Sendable () -> Void = {}) {
        self.id=id; receiveBytes=receive; self.failed=failed; self.interrupted=interrupted
    }
    func setSender(_ sender: @escaping @Sendable (Data) -> Bool) {
        lock.lock(); self.sender=sender; senderGeneration=UUID(); lastRetry=nil; lastTransmitted.removeAll(); interruptionReported=false; lock.unlock()
        tick()
    }
    func suspend() { lock.lock(); sender=nil; senderGeneration=UUID(); lastRetry=nil; lock.unlock() }
    private struct Continuation: Codable {
        let version:Int, id:UUID, outgoing:UInt64, expected:UInt64
        let pending:[UInt64:Data], unacknowledged:[UInt64:Data]
    }
    /// Stop delivery as well as sends before capturing the probe and cartridge.
    /// Late SDK callbacks remain unacknowledged and are retried by the peer.
    func freezeForContinuation() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw CocoaError(.fileWriteUnknown) }
        continuationFrozen=true;sender=nil;senderGeneration=UUID();lastRetry=nil
        return try JSONEncoder().encode(Continuation(version:1,id:id,outgoing:outgoing,expected:expected,
            pending:pending,unacknowledged:unacknowledged.mapValues { Data($0.dropFirst(38)) }))
    }
    func restoreContinuation(_ data:Data)->Bool {
        guard data.count<=400_000,let value=try? JSONDecoder().decode(Continuation.self,from:data),
              value.version==1,value.id==id,value.expected>0,value.expected<UInt64.max,value.outgoing<UInt64.max,
              value.pending.count<=64,value.unacknowledged.count<=64,
              value.pending.allSatisfy({ $0.key>=value.expected && $0.key-value.expected<64 && !$0.value.isEmpty && $0.value.count<=4096 }),
              value.unacknowledged.allSatisfy({ $0.key>0 && $0.key<=value.outgoing && !$0.value.isEmpty && $0.value.count<=4096 }),
              value.pending.values.reduce(0,{ $0+$1.count })<=131072,
              value.unacknowledged.values.reduce(0,{ $0+$1.count })<=131072 else { return false }
        lock.lock();defer { lock.unlock() }
        guard outgoing==0,expected==1,pending.isEmpty,unacknowledged.isEmpty else { return false }
        outgoing=value.outgoing;expected=value.expected;pending=value.pending
        pendingBytes=pending.values.reduce(0,{ $0+$1.count })
        unacknowledged=[:]
        for (sequence,bytes) in value.unacknowledged { unacknowledged[sequence]=packet(sequence:sequence,bytes:bytes) }
        unacknowledgedBytes=value.unacknowledged.values.reduce(0,{ $0+$1.count })
        continuationFrozen=true;acknowledgementPending=true;active=true;sender=nil
        lastReceived=ProcessInfo.processInfo.systemUptime
        return true
    }
    /// The durable continuation must be claimed before allowing any new ACK.
    func thawContinuation() { lock.lock();continuationFrozen=false;lock.unlock() }
    private func packet(sequence: UInt64, bytes: Data) -> Data {
        var data=Self.prefix
        var uuid=id.uuid; withUnsafeBytes(of:&uuid) { data.append(contentsOf:$0) }
        for shift in stride(from:56,through:0,by:-8) { data.append(UInt8(truncatingIfNeeded:sequence >> shift)) }
        for shift in stride(from:56,through:0,by:-8) { data.append(UInt8(truncatingIfNeeded:(expected-1) >> shift)) }
        data.append(UInt8(bytes.count >> 8)); data.append(UInt8(truncatingIfNeeded:bytes.count))
        data.append(bytes); return data
    }
    private func transmit(_ data: Data, using sender: (@Sendable (Data) -> Bool)?, generation:UUID) {
        guard let sender, !sender(data) else { return }
        lock.lock()
        let report=active && generation==senderGeneration && !interruptionReported
        if report { interruptionReported=true }
        lock.unlock()
        if report { interrupted() }
    }
    func send(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty, bytes.count <= 4096 else { return false }
        lock.lock()
        guard active,!continuationFrozen else { lock.unlock(); return false }
        guard unacknowledged.count<64, unacknowledgedBytes+bytes.count<=131072, outgoing<UInt64.max else {
            active=false; lock.unlock(); failed(); return false
        }
        outgoing &+= 1
        let data=packet(sequence:outgoing,bytes:bytes), sender=self.sender, generation=senderGeneration
        unacknowledged[outgoing]=data; unacknowledgedBytes+=bytes.count
        if sender != nil { lastTransmitted[outgoing]=ProcessInfo.processInfo.systemUptime }
        if sender != nil { acknowledgementPending=false; lastAcknowledgedAt=ProcessInfo.processInfo.systemUptime }
        lock.unlock()
        // Success means retained for reliable delivery. A failed socket send
        // cannot discard a native command or consume its sequence number.
        transmit(data,using:sender,generation:generation); return true
    }
    func tick(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        guard active,!continuationFrozen, let sender else { lock.unlock(); return }
        let generation=senderGeneration
        var replay:[Data]=[]
        if lastRetry.map({ now-$0>=0.25 }) ?? true {
            lastRetry=now
            // Repair the oldest gap first without flooding the server's shared
            // battle lane with a whole backlog every retry interval.
            let due=unacknowledged.keys.sorted().filter { lastTransmitted[$0].map { now-$0>=0.25 } ?? true }.prefix(4)
            replay=due.compactMap { key in
                unacknowledged[key].map { packet(sequence:key,bytes:Data($0.dropFirst(38))) }
            }
            for key in due { lastTransmitted[key]=now }
        }
        if replay.isEmpty, acknowledgementPending, now-lastAcknowledgedAt>=0.05 {
            replay=[packet(sequence:0,bytes:Data())]
        }
        if !replay.isEmpty { acknowledgementPending=false; lastAcknowledgedAt=now }
        lock.unlock()
        for packet in replay { transmit(packet,using:sender,generation:generation) }
    }
    func receive(_ data: Data) {
        guard data.count>=38, data.count<=4134, data.starts(with:Self.prefix) else { return }
        var uuid=id.uuid
        let matches=withUnsafeBytes(of:&uuid) { Data($0)==data.subdata(in:4..<20) }
        guard matches else { return }
        let sequence=data[20..<28].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let acknowledgement=data[28..<36].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let count=Int(data[36]) << 8 | Int(data[37])
        guard count<=4096,data.count==38+count,(count==0)==(sequence==0) else { return }
        let bytes=data.subdata(in:38..<data.count)
        lock.lock()
        guard active,!continuationFrozen, acknowledgement<=outgoing else { lock.unlock(); return }
        lastReceived=ProcessInfo.processInfo.systemUptime
        for key in unacknowledged.keys.filter({ $0<=acknowledgement }) {
            if let packet=unacknowledged.removeValue(forKey:key) { unacknowledgedBytes-=packet.count-38 }
            lastTransmitted.removeValue(forKey:key)
        }
        if count==0 { lock.unlock(); return }
        acknowledgementPending=true
        if sequence<expected || pending[sequence] != nil {
            lock.unlock(); return
        }
        guard sequence-expected<64, pendingBytes+bytes.count<=131072 else {
            active=false; pending.removeAll(); pendingBytes=0; lock.unlock(); failed(); return
        }
        pending[sequence]=bytes; pendingBytes+=bytes.count
        var ready:[Data]=[]
        while let bytes=pending.removeValue(forKey:expected) {
            pendingBytes-=bytes.count; ready.append(bytes); expected &+= 1
        }
        // Delivery under this lock preserves ordering even if SDK callbacks race.
        // The receiver only appends to its bounded host command queue.
        for bytes in ready { receiveBytes(bytes) }
        lock.unlock()
    }
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return !unacknowledged.isEmpty }
    var networkAge: TimeInterval { lock.lock(); defer { lock.unlock() }; return ProcessInfo.processInfo.systemUptime-lastReceived }
    var diagnostics:String {
        lock.lock(); defer { lock.unlock() }
        return "sent=\(outgoing) received=\(expected-1) pending=\(pending.count) unacknowledged=\(unacknowledged.count) active=\(active)"
    }
    func close() { lock.lock(); active=false; sender=nil; pending.removeAll(); pendingBytes=0; unacknowledged.removeAll(); lastTransmitted.removeAll(); unacknowledgedBytes=0; lock.unlock() }
}

/// Only native battle/link command records enter the emulated link queues.
/// Commands retain the cartridge's block and battle processing; no addresses or
/// save-state blobs can be selected by a peer.
enum BoundNativeCommandPacket {
    static let commandBytes=16
    static let maxCommands=13
    static func encode(_ commands:Data,generation:UInt16=1,sequence:UInt16=1)->Data? {
        guard !commands.isEmpty,commands.count<=commandBytes*maxCommands,commands.count%16==0,valid(commands) else { return nil }
        guard generation>0 else { return nil }
        return Data([1,UInt8(truncatingIfNeeded:generation),UInt8(generation>>8),UInt8(truncatingIfNeeded:sequence),UInt8(sequence>>8)])+commands
    }
    static func decode(_ bytes:Data)->Data? {
        if bytes==Data([0]) { return Data() }
        if bytes.first==2,bytes.count==3,generation(bytes) != nil { return Data() }
        if bytes.first==3,bytes.count==5,generation(bytes) != nil { return Data() }
        guard bytes.first==1,bytes.count>=21,generation(bytes) != nil else { return nil }
        let commands=Data(bytes.dropFirst(5))
        guard commands.count<=commandBytes*maxCommands,commands.count%16==0,valid(commands) else { return nil }
        return commands
    }
    static func connection(_ generation:UInt16)->Data { Data([2,UInt8(truncatingIfNeeded:generation),UInt8(generation>>8)]) }
    static func acknowledgement(_ bytes:Data)->Data? {
        guard bytes.first==3,bytes.count==5 else { return nil }; return Data(bytes.dropFirst())
    }
    static func sequence(_ bytes:Data)->UInt16? {
        guard bytes.count>=5,[1,3].contains(bytes[0]) else { return nil }
        return UInt16(bytes[3])|UInt16(bytes[4])<<8
    }
    static func generation(_ bytes:Data)->UInt16? {
        guard bytes.count>=3,[1,2,3].contains(bytes[0]) else { return nil }
        let value=UInt16(bytes[1])|UInt16(bytes[2])<<8
        return value>0 ? value:nil
    }
    private static func valid(_ data:Data)->Bool {
        let allowed:Set<UInt16>=[0x2222,0x2FFE,0x2FFF,0x5FFF,0x6666,0x7777,0x8888,0xBBBB,0xCCCC,0xEFFF]
        for start in stride(from:0,to:data.count,by:16) {
            let code=UInt16(data[start])|UInt16(data[start+1])<<8
            guard allowed.contains(code) else { return false }
            let value=Int(data[start+2])|Int(data[start+3])<<8
            if code==0xBBBB && value>4096 { return false }
            if code==0xCCCC && value>4 { return false }
        }
        return true
    }
}

/// Bound every continuation write before the native block receiver sees it.
/// The native protocol has no offset in continuation records: each advances 14
/// bytes, so an unsolicited or excess continuation must never enter RAM.
struct BoundNativeBlockAdmission {
    private var remaining=0
    var recoveryRemaining:Int { remaining }
    init() {}
    init?(recoveryRemaining:Int) {
        guard (0...293).contains(recoveryRemaining) else { return nil }
        remaining=recoveryRemaining
    }
    mutating func accept(_ commands:Data)->Bool {
        var next=remaining
        for start in stride(from:0,to:commands.count,by:16) {
            let opcode=UInt16(commands[start])|UInt16(commands[start+1])<<8
            if opcode==0xBBBB {
                let size=Int(commands[start+2])|Int(commands[start+3])<<8
                let rounded=((size+13)/14)*14
                guard size>0,size<=4096,size>256 || rounded<=256 else { return false }
                next=(size+13)/14
            } else if opcode==0x8888 {
                guard next>0 else { return false }; next-=1
            }
        }
        remaining=next; return true
    }
}
