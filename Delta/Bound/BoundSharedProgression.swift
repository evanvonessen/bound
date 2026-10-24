import Foundation
import DeltaCore

// BEGIN GENERATED GAME CONTRACT
enum BoundWorldContract {
    static let romSHA256 = "ab40d6b7faa27d56db44915e50183bb60c997fef8502d1cdd5a533b3d141d965"
    static let compatibility = Data([111,178,155,161,64,17,73,237,141,198,250,18,184,92,217,79,1,0,0,0,1,0,1,0])
    static let ruleset = Data([111,178,155,161,64,17,73,237,141,198,250,18,184,92,217,79])
}
// END GENERATED GAME CONTRACT

/// Opaque game checkpoints. Bound transports them without interpreting game rules.
struct BoundWorldState: Equatable, Sendable {
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
struct BoundWorldPacket: Equatable, Sendable {
    static let prefix = Data("BWP2".utf8)
    let sender: UUID
    let receiver: UUID?
    let sequence: UInt64
    let state: BoundWorldState
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
        let state = BoundWorldState(group: data[68], number: data[69], checkpoints: data.subdata(in: 70..<870), boulders: data.subdata(in: 871..<data.count))
        guard state.valid else { return nil }
        return .init(sender: sender, receiver: receiver == zero ? nil : receiver, sequence: sequence, state: state)
    }
}

/// Nonce/sequence admission is separate from cartridge enforcement. Reconnect
/// requires a new acknowledgment; cached packets cannot reopen a barrier.
struct BoundWorldTimeline {
    private(set) var epoch = UUID()
    private(set) var peer: UUID?
    private(set) var state: BoundWorldState?
    private(set) var receivedAt: TimeInterval?
    private var lastSequence: UInt64 = 0
    private var retired: [UUID] = []
    mutating func reset() {
        if let peer { retired.append(peer); retired = Array(retired.suffix(32)) }
        epoch = UUID(); peer = nil; state = nil; receivedAt = nil; lastSequence = 0
    }
    mutating func expire(at now: TimeInterval) {
        if receivedAt != nil && !fresh(at: now) { reset() }
    }
    mutating func receive(_ packet: BoundWorldPacket, at now: TimeInterval) {
        expire(at: now)
        guard packet.state.valid, packet.sequence > 0, packet.sender != epoch else { return }
        if retired.contains(packet.sender) {
            // A unilateral reconnect changes our challenge even if the peer
            // stayed online. Its old sender epoch is safe only when it proves
            // receipt of this new challenge and no replacement peer is bound.
            guard peer == nil, packet.receiver == epoch else { return }
            retired.removeAll { $0 == packet.sender }
        }
        if packet.sender != peer {
            if let peer { retired.append(peer); retired = Array(retired.suffix(32)) }
            peer = packet.sender; lastSequence = 0; state = nil; receivedAt = nil
        }
        guard packet.receiver == epoch, packet.sequence > lastSequence else { return }
        lastSequence = packet.sequence; state = packet.state; receivedAt = now
    }
    func fresh(at now: TimeInterval) -> Bool {
        guard state != nil, let receivedAt else { return false }
        return now >= receivedAt && now - receivedAt < 3
    }
}

/// A game reset/rollback must rotate the network challenge as well as replacing
/// its checkpoint bytes. Repeated output cannot masquerade as a fresh capture.
struct BoundWorldSourceClock {
    private(set) var generation: UInt64 = 0
    private var last: UInt32 = 0, unchanged = 0
    mutating func admit(_ sequence: UInt32) -> Bool {
        guard sequence > 0, sequence & 1 == 0 else { return false }
        if last != 0, sequence < last {
            generation &+= 1; last = sequence; unchanged = 0; return false
        }
        if sequence == last {
            unchanged = min(unchanged + 1, 181)
            if unchanged == 180 { generation &+= 1 }
        } else { last = sequence; unchanged = 0 }
        return unchanged < 180
    }
}

/// Only the completed-frame owner touches the core. Network/UI callers update
/// bounded policy mailboxes; the ROM lease expires if the main thread stalls.
final class BoundWorldProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var coreID: ObjectIdentifier?
    private var verified = false, enabled = false, installed = false, reachedField = false
    private var frame = 0, sourceClock = BoundWorldSourceClock()
    private var local: BoundWorldState?
    private var peer: BoundWorldState?
    private var fresh = false
    func configure(core: EmulatorCore?) {
        lock.lock(); defer { lock.unlock() }
        coreID = core.map(ObjectIdentifier.init); verified = false; enabled = false; installed = false
        reachedField = false; frame = 0; sourceClock = BoundWorldSourceClock(); local = nil; peer = nil; fresh = false; policyDirty = true
    }
    func setVerified(_ value: Bool) { lock.lock(); verified = value; lock.unlock() }
    func read() -> BoundWorldState? { lock.lock(); defer { lock.unlock() }; return local }
    var gameGeneration: UInt64 { lock.lock(); defer { lock.unlock() }; return sourceClock.generation }
    func receive(_ core: EmulatorCore) {
        lock.lock(); defer { lock.unlock() }
        guard coreID == ObjectIdentifier(core), core.deltaCore.identifier == "com.rileytestut.GBADeltaCore" else { return }
        guard enabled, verified else {
            // Also closes hooks left resident by a same-core rebind.
            BoundVBABattleBridge.closeSharedWorld(); installed = false; local = nil; return
        }
        if !installed {
            guard BoundVBABattleBridge.friendDialogueReady() else { return }
            installed = BoundVBABattleBridge.installSharedWorld()
            guard installed else { return }
            reachedField = true
        }
        frame += 1
        if reachedField {
            let value = BoundVBABattleBridge.sharedWorldSnapshot()
            if let checkpoints = value["checkpoints"] as? Data, let group = value["group"] as? UInt8,
               let number = value["number"] as? UInt8, let sequence = value["sequence"] as? UInt32 {
                let generation = sourceClock.generation
                let current = sourceClock.admit(sequence)
                if generation != sourceClock.generation { peer = nil; fresh = false; policyDirty = true }
                let state = BoundWorldState(group: group, number: number, checkpoints: checkpoints, boulders: value["boulders"] as? Data ?? Data())
                local = state.valid && current ? state : nil
            } else { local = nil }
        }
        BoundVBABattleBridge.advanceSharedWorld()
        // Refresh the frame lease only when a new host tick has supplied policy.
        if policyDirty {
            BoundVBABattleBridge.setSharedWorldPeer(peer?.checkpoints ?? Data(), group: UInt(peer?.group ?? 0), number: UInt(peer?.number ?? 0), boulders: peer?.boulders ?? Data(), fresh: fresh)
            policyDirty = false
        }
    }
    private var policyDirty = true
    func publishPolicy(enabled: Bool, peer: BoundWorldState?, fresh: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled; self.peer = peer; self.fresh = fresh; policyDirty = true
    }
}

@MainActor
final class BoundSharedProgression {
    let probe = BoundWorldProbe()
    var send: ((Data) -> Bool)?
    private(set) var timeline = BoundWorldTimeline()
    private var sequence: UInt64 = 0
    private var enabled = false
    private var lastSent: TimeInterval = -.infinity
    private var coreID: ObjectIdentifier?
    private var verification: Task<Void, Never>?
    private var observedGameGeneration: UInt64 = 0
    func bind(core: EmulatorCore?) {
        guard core.map(ObjectIdentifier.init) != coreID else { return }
        coreID = core.map(ObjectIdentifier.init); verification?.cancel(); probe.configure(core: core); observedGameGeneration = 0; peerGone()
        guard let core, core.deltaCore.identifier == "com.rileytestut.GBADeltaCore" else { return }
        let id = ObjectIdentifier(core), url = core.game.fileURL
        verification = Task { [weak self] in
            let valid = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
                return (try? BoundPlayerROMProfile(rom: data)) != nil
            }.value
            guard !Task.isCancelled, let self, self.coreID == id else { return }
            self.probe.setVerified(valid)
        }
    }
    func peerGone() {
        timeline.reset(); sequence = 0; lastSent = -.infinity
        probe.publishPolicy(enabled: enabled, peer: nil, fresh: false)
    }
    func stop() { enabled = false; peerGone() }
    func receive(_ data: Data) {
        guard enabled, let packet = BoundWorldPacket.decode(data) else { return }
        timeline.receive(packet, at: ProcessInfo.processInfo.systemUptime)
    }
    func tick(enabled: Bool, connected: Bool, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let generation = probe.gameGeneration
        if generation != observedGameGeneration { observedGameGeneration = generation; peerGone() }
        if self.enabled != enabled { self.enabled = enabled; peerGone() }
        timeline.expire(at: now)
        probe.publishPolicy(enabled: enabled, peer: timeline.state, fresh: connected && timeline.fresh(at: now))
        guard enabled, connected, now - lastSent >= 0.5, let state = probe.read(), sequence < UInt64.max else { return }
        sequence += 1
        let packet = BoundWorldPacket(sender: timeline.epoch, receiver: timeline.peer, sequence: sequence, state: state)
        lastSent = now
        if let data = packet.encoded() { _ = send?(data) }
    }
}
