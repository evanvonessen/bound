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
    static let prefix = Data([0x42,0x46,0x53,0x31]) // BFS1
    private let lock = NSLock()
    private let id: UUID
    private var outgoing: UInt64 = 0
    private var expected: UInt64 = 1
    private var pending: [UInt64:Data] = [:]
    private var pendingBytes = 0
    private var active = true
    private var sender: (@Sendable (Data) -> Bool)?
    private let receiveBytes: @Sendable (Data) -> Void
    private let failed: @Sendable () -> Void
    init(id: UUID, receive: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable () -> Void) {
        self.id=id; receiveBytes=receive; self.failed=failed
    }
    func setSender(_ sender: @escaping @Sendable (Data) -> Bool) { lock.lock(); self.sender=sender; lock.unlock() }
    func send(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty, bytes.count <= 4096 else { return false }
        lock.lock()
        guard active, let sender else { lock.unlock(); return false }
        outgoing &+= 1
        var data=Self.prefix
        var uuid=id.uuid; withUnsafeBytes(of:&uuid) { data.append(contentsOf:$0) }
        for shift in stride(from:56,through:0,by:-8) { data.append(UInt8(truncatingIfNeeded:outgoing >> shift)) }
        data.append(UInt8(bytes.count >> 8)); data.append(UInt8(truncatingIfNeeded:bytes.count))
        data.append(bytes)
        // Keep a strong sender; channel invalidation fences SDK destruction.
        lock.unlock()
        return sender(data)
    }
    func receive(_ data: Data) {
        guard data.count>30, data.count<=4126, data.starts(with:Self.prefix) else { return }
        var uuid=id.uuid
        let matches=withUnsafeBytes(of:&uuid) { Data($0)==data.subdata(in:4..<20) }
        guard matches else { return }
        let sequence=data[20..<28].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let count=Int(data[28]) << 8 | Int(data[29])
        guard count>0,count<=4096,data.count==30+count else { return }
        let bytes=data.subdata(in:30..<data.count)
        lock.lock()
        guard active, sequence>=expected, pending[sequence]==nil else { lock.unlock(); return }
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
    var diagnostics:String {
        lock.lock(); defer { lock.unlock() }
        return "sent=\(outgoing) received=\(expected-1) pending=\(pending.count) active=\(active)"
    }
    func close() { lock.lock(); active=false; sender=nil; pending.removeAll(); pendingBytes=0; lock.unlock() }
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
