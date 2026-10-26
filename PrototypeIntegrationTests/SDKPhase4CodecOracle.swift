// Frozen pure codec oracle from Bound 579b058b (phase 4).
// Do not regenerate from the SDK: these copies detect structural extraction drift.
import Foundation
@testable import Delta

private enum Phase4ROMBytes {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static func word(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
    static func put(_ value: UInt32, into data: inout Data, at offset: Int) {
        for n in 0..<4 { data[offset + n] = UInt8(truncatingIfNeeded: value >> (n * 8)) }
    }
    static func uuid(_ data: Data, _ offset: Int) -> UUID {
        let b = Array(data[offset..<offset + 16])
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    static func put(_ uuid: UUID?, into data: inout Data, at offset: Int) {
        var bytes = (uuid ?? zero).uuid
        withUnsafeBytes(of: &bytes) { data.replaceSubrange(offset..<offset + 16, with: $0) }
    }
    static func text(_ string: String, into data: inout Data, at offset: Int, size: Int) {
        let clean = string.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let bytes = clean.unicodeScalars.map { scalar -> UInt8 in
            if scalar.value == 10 { return 10 }
            return (32...126).contains(scalar.value) ? UInt8(scalar.value) : 63
        }.prefix(size - 1)
        data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }
}

struct Phase4ROMRequest: Equatable, Sendable {
    let sequence: UInt32
    let command: BoundROMCommand
    let friendIndex: UInt32
    let argument: UInt32
    let identifier: UUID
    let settings: Data
    let flags: UInt32
    let frame: UInt32
    let requestID: UInt32
    var debugSetup = false
    var setupError: UInt32 = 0
    var safeField: Bool { flags & 1 != 0 }
    var newGame: Bool { flags & 2 != 0 }
    var paused: Bool { flags & 4 != 0 }
    var checkpointSafe: Bool { flags & 64 != 0 }
    var permitsFieldInterruption: Bool { safeField && checkpointSafe && !paused && !newGame }
    var permitsAutomaticFieldSave: Bool { permitsFieldInterruption }
    var settingsApplied: Bool { flags & 32 != 0 }
    var requestsPregameSetupRestart: Bool { command == .setupRetry && newGame && !settingsApplied && setupError == 1 }
    var requestsNewMultiplayerRun: Bool { newGame && (command == .pair || command == .startSoulLink) }
    static func decode(_ data: Data) -> Self? {
        guard data.count == 256, data.prefix(8) == Data([82,85,82,49,1,0,0,0]),
              let command = BoundROMCommand(rawValue: Phase4ROMBytes.word(data,12)) else { return nil }
        let sequence = Phase4ROMBytes.word(data,8)
        guard sequence > 0, sequence & 1 == 0 else { return nil }
        return .init(sequence: sequence, command: command, friendIndex: Phase4ROMBytes.word(data,16),
            argument: Phase4ROMBytes.word(data,20), identifier: Phase4ROMBytes.uuid(data,24),
            settings: data.subdata(in:40..<72), flags: Phase4ROMBytes.word(data,80),
            frame: Phase4ROMBytes.word(data,84), requestID: Phase4ROMBytes.word(data,88), debugSetup: Phase4ROMBytes.word(data,160) == 1,
            setupError: Phase4ROMBytes.word(data,164))
    }
}

struct Phase4ROMHostState: Equatable, Sendable {
    struct Friend: Equatable, Sendable { var room: UUID; var name: String; var status: UInt32 = 0 }
    var enabled = false
    var linked = false
    var connected = false
    var chooser = false
    var setupCommitted = false
    var externalSetup = false
    var debugPlayer: UInt8 = 0
    var playerProfile: BoundNakamaRunService.PlayerProfile?
    var restartSetup = false
    var recovery = false
    var saving = false
    var transferRequired = false
    var ended = false
    var acknowledgedRequest: UInt32 = 0
    var status: BoundROMStatus = .idle
    var run: UUID?
    var localSeed: UInt32 = 0
    var partnerSeed: UInt32 = 0
    var settings = Data(repeating: 0, count: 32)
    var partnerName = "friend"
    var message = ""
    var friends: [Friend] = []
    var peerCollision: BoundPresenceCollision?
    var page: UInt32 = 0
    func encoded(sequence: UInt32) -> Data {
        var data = Data(repeating: 0, count: 2048)
        data.replaceSubrange(0..<8, with: [82,85,73,49,1,0,0,0])
        Phase4ROMBytes.put(sequence, into: &data, at: 8)
        let flags: UInt32 = (enabled ? 1:0) | (linked ? 2:0) | (connected ? 4:0) | (chooser ? 8:0)
            | (setupCommitted ? 16:0) | (recovery ? 32:0) | (saving ? 256:0) | (transferRequired ? 512:0) | (ended ? 1024:0)
            | (restartSetup ? 2048:0) | (externalSetup ? 4096:0)
        Phase4ROMBytes.put(flags, into: &data, at:12)
        Phase4ROMBytes.put(acknowledgedRequest, into: &data, at:16)
        Phase4ROMBytes.put(status.rawValue, into: &data, at:20)
        Phase4ROMBytes.put(UInt32(min(friends.count,20)), into: &data, at:24)
        Phase4ROMBytes.put(run, into: &data, at:32)
        Phase4ROMBytes.put(localSeed, into: &data, at:48)
        Phase4ROMBytes.put(partnerSeed, into: &data, at:52)
        if settings.count == 32 { data.replaceSubrange(56..<88, with: settings) }
        Phase4ROMBytes.text(partnerName, into: &data, at:88, size:32)
        Phase4ROMBytes.text(message, into: &data, at:120, size:192)
        Phase4ROMBytes.put(180, into: &data, at:312)
        Phase4ROMBytes.put(page, into: &data, at:316)
        for (index, friend) in friends.prefix(20).enumerated() {
            let offset = 320 + index * 52
            Phase4ROMBytes.put(friend.room, into: &data, at:offset)
            Phase4ROMBytes.text(friend.name, into: &data, at:offset + 16, size:32)
            Phase4ROMBytes.put(friend.status, into: &data, at:offset + 48)
        }
        if enabled, let peerCollision {
            Phase4ROMBytes.put(1, into: &data, at:1360)
            data[1364] = UInt8(peerCollision.mapGroup); data[1365] = UInt8(peerCollision.mapNumber)
            data[1366] = UInt8(peerCollision.elevation)
            for (offset, value) in [(1368, peerCollision.current.x), (1370, peerCollision.current.y),
                                    (1372, peerCollision.previous.x), (1374, peerCollision.previous.y)] {
                let bits = UInt16(bitPattern: Int16(value))
                data[offset] = UInt8(truncatingIfNeeded: bits); data[offset + 1] = UInt8(bits >> 8)
            }
        }
        if let playerProfile, playerProfile.valid {
            data.replaceSubrange(1408..<1416, with: BoundMultiplayerSetupOptions.nativeName(playerProfile.name))
            data[1416] = UInt8(playerProfile.gender); data[1417] = 1
            data[1418] = debugPlayer
        }
        return data
    }
}


struct Phase4ROMPacket: Equatable, Sendable {
    enum Kind: UInt8 { case hello, proposal, accepted, settings, ready, checkpoint, prepared, committed, end, cancel, checkpointCancel }
    static let prefix = Data("BRM1".utf8)
    let kind: Kind
    let owner: UUID
    let epoch: UUID
    let receiver: UUID?
    let sequence: UInt64
    let body: Data
    func encoded() -> Data? {
        guard sequence > 0, body.count <= 960 else { return nil }
        var data = Data(repeating:0,count:64)
        data.replaceSubrange(0..<4,with:Self.prefix); data[4] = 1; data[5] = kind.rawValue
        Phase4ROMBytes.put(owner,into:&data,at:8); Phase4ROMBytes.put(epoch,into:&data,at:24)
        Phase4ROMBytes.put(receiver,into:&data,at:40)
        for i in 0..<8 { data[56+i] = UInt8(truncatingIfNeeded:sequence >> (i*8)) }
        data.append(body); return data
    }
    static func decode(_ data: Data) -> Self? {
        guard (64...1024).contains(data.count), data.starts(with:prefix), data[4] == 1,
              data[6] == 0, data[7] == 0, let kind = Kind(rawValue:data[5]) else { return nil }
        let owner = Phase4ROMBytes.uuid(data,8), epoch = Phase4ROMBytes.uuid(data,24), receiver = Phase4ROMBytes.uuid(data,40)
        let sequence = (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[56+$1]) << ($1*8) }
        guard owner != Phase4ROMBytes.zero, epoch != Phase4ROMBytes.zero, sequence > 0 else { return nil }
        return .init(kind:kind,owner:owner,epoch:epoch,receiver:receiver == Phase4ROMBytes.zero ? nil:receiver,
                     sequence:sequence,body:data.subdata(in:64..<data.count))
    }
}


struct Phase4WorldState: Codable, Equatable, Sendable {
    var group: UInt8
    var number: UInt8
    var checkpoints: Data
    var boulders: Data = Data()
    var valid: Bool {
        group < 43 && checkpoints.count == 800 && boulders.count <= 96 && boulders.count % 6 == 0
        && stride(from: 0, to: boulders.count, by: 6).allSatisfy { boulders[$0] > 0 && boulders[$0] < 255 && boulders[$0 + 1] < 16 }
        && Set(stride(from: 0, to: boulders.count, by: 6).map { boulders[$0] }).count == boulders.count / 6
    }
}
struct Phase4WorldPacket: Equatable, Sendable {
    static let prefix = Data("BWP2".utf8)
    let sender: UUID
    let receiver: UUID?
    let sequence: UInt64
    let state: Phase4WorldState
    func encoded() -> Data? {
        guard state.valid, sequence > 0 else { return nil }
        var data = Self.prefix + BoundWorldContract.compatibility
        var senderBytes = sender.uuid, receiverBytes = (receiver ?? Self.zero).uuid
        withUnsafeBytes(of: &senderBytes) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &receiverBytes) { data.append(contentsOf: $0) }
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8(truncatingIfNeeded: sequence >> shift)) }
        data.append(state.group); data.append(state.number); data.append(state.checkpoints)
        data.append(UInt8(state.boulders.count / 6)); data.append(state.boulders)
        return data.count <= 1024 ? data : nil
    }
    private static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static func decode(_ data: Data) -> Self? {
        guard (871...967).contains(data.count), data.starts(with: prefix),
              data.subdata(in: 4..<28) == BoundWorldContract.compatibility else { return nil }
        func uuid(_ offset: Int) -> UUID {
            let b = Array(data[offset..<offset + 16])
            return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        }
        let sender = uuid(28), receiver = uuid(44)
        let sequence = (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[60 + $1]) << ($1 * 8) }
        guard sender != zero, sequence > 0, data.count == 871 + Int(data[870]) * 6 else { return nil }
        let state = Phase4WorldState(group: data[68], number: data[69], checkpoints: data.subdata(in: 70..<870), boulders: data.subdata(in: 871..<data.count))
        guard state.valid else { return nil }
        return .init(sender: sender, receiver: receiver == zero ? nil : receiver, sequence: sequence, state: state)
    }
}
