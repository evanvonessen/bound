import Foundation
import DeltaCore

/// Progress predicates only. Never installs a partner's save, script or RAM.
struct BoundWorldState: Equatable, Sendable {
    var group: UInt8
    var number: UInt8
    var flags: Data
    var boulders: Data = Data()
    var valid: Bool {
        group < 43 && flags.count == 800 && boulders.count <= 96 && boulders.count % 6 == 0
        && stride(from: 0, to: boulders.count, by: 6).allSatisfy { boulders[$0] > 0 && boulders[$0] < 255 && boulders[$0 + 1] < 16 }
    }
}
struct BoundWorldPacket: Equatable, Sendable {
    static let prefix = Data("BWP1".utf8)
    let sender: UUID
    let receiver: UUID?
    let sequence: UInt64
    let state: BoundWorldState
    func encoded() -> Data? {
        guard state.valid, sequence > 0 else { return nil }
        var data = Self.prefix
        var senderBytes = sender.uuid, receiverBytes = (receiver ?? Self.zero).uuid
        withUnsafeBytes(of: &senderBytes) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &receiverBytes) { data.append(contentsOf: $0) }
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8(truncatingIfNeeded: sequence >> shift)) }
        data.append(state.group); data.append(state.number); data.append(state.flags)
        data.append(UInt8(state.boulders.count / 6)); data.append(state.boulders)
        return data.count <= 1024 ? data : nil
    }
    private static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static func decode(_ data: Data) -> Self? {
        guard (847...943).contains(data.count), data.starts(with: prefix) else { return nil }
        func uuid(_ offset: Int) -> UUID {
            let b = Array(data[offset..<offset + 16])
            return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        }
        let sender = uuid(4), receiver = uuid(20)
        let sequence = (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[36 + $1]) << ($1 * 8) }
        guard sender != zero, sequence > 0, data.count == 847 + Int(data[846]) * 6 else { return nil }
        let state = BoundWorldState(group: data[44], number: data[45], flags: data.subdata(in: 46..<846), boulders: data.subdata(in: 847..<data.count))
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

/// Only the completed-frame owner touches the core. Network/UI callers update
/// bounded policy mailboxes; the ROM lease expires if the main thread stalls.
final class BoundWorldProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var coreID: ObjectIdentifier?
    private var verified = false, enabled = false, installed = false, reachedField = false
    private var frame = 0
    private var local: BoundWorldState?
    private var peer: BoundWorldState?
    private var fresh = false
    func configure(core: EmulatorCore?) {
        lock.lock(); defer { lock.unlock() }
        coreID = core.map(ObjectIdentifier.init); verified = false; enabled = false; installed = false
        reachedField = false; frame = 0; local = nil; peer = nil; fresh = false; policyDirty = true
    }
    func setVerified(_ value: Bool) { lock.lock(); verified = value; lock.unlock() }
    func read() -> BoundWorldState? { lock.lock(); defer { lock.unlock() }; return local }
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
        if reachedField && (frame % 15 == 1 || local == nil) {
            let value = BoundVBABattleBridge.sharedWorldSnapshot()
            if let flags = value["flags"] as? Data, let group = value["group"] as? UInt8, let number = value["number"] as? UInt8 {
                let state = BoundWorldState(group: group, number: number, flags: flags, boulders: value["boulders"] as? Data ?? Data())
                if state.valid { local = state }
            }
        }
        BoundVBABattleBridge.advanceSharedWorld()
        // Refresh the frame lease only when a new host tick has supplied policy.
        if policyDirty {
            BoundVBABattleBridge.setSharedWorldPeer(peer?.flags ?? Data(), group: UInt(peer?.group ?? 0), number: UInt(peer?.number ?? 0), boulders: peer?.boulders ?? Data(), fresh: fresh)
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
    func bind(core: EmulatorCore?) {
        guard core.map(ObjectIdentifier.init) != coreID else { return }
        coreID = core.map(ObjectIdentifier.init); verification?.cancel(); probe.configure(core: core); peerGone()
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
