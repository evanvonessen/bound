import Foundation
import DeltaCore

// BEGIN GENERATED GAME CONTRACT
enum BoundWorldContract {
    static let romSHA256 = "02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79"
    static let compatibility = Data([111,178,155,161,64,17,73,237,141,198,250,18,184,92,217,79,1,0,0,0,1,0,1,0])
    static let ruleset = Data([111,178,155,161,64,17,73,237,141,198,250,18,184,92,217,79])
}
// END GENERATED GAME CONTRACT

/// Opaque game checkpoints. Bound transports them without interpreting game rules.
struct BoundWorldState: Codable, Equatable, Sendable {
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
    func encoded(compatibility: Data = BoundWorldContract.compatibility) -> Data? {
        guard state.valid else { return nil }
        var body = Data([state.group, state.number]) + state.checkpoints
        body.append(UInt8(state.boulders.count / BoundSDKProtocol.WorldEnvelope.boulderStride)); body.append(state.boulders)
        return BoundSDKWorldEnvelope(sender: sender, receiver: receiver, sequence: sequence,
                                     body: body).encoded(compatibility: compatibility)
    }
    static func decode(_ data: Data, compatibility: Data = BoundWorldContract.compatibility) -> Self? {
        typealias Layout = BoundSDKProtocol.WorldEnvelope
        guard let frame = BoundSDKWorldEnvelope.decode(data, compatibility: compatibility) else { return nil }
        let state = BoundWorldState(group: data[Layout.groupOffset], number: data[Layout.numberOffset],
            checkpoints: data.subdata(in: Layout.checkpointsOffset..<Layout.checkpointsOffset + Layout.checkpointsSize),
            boulders: data.subdata(in: Layout.bouldersOffset..<data.count))
        guard state.valid else { return nil }
        return .init(sender: frame.sender, receiver: frame.receiver, sequence: frame.sequence, state: state)
    }
}

/// Nonce and sequence admission protect fresh remote presentation. Cached
/// snapshots never grant authority over the local cartridge's native progress.
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
/// bounded presentation mailboxes; stale peer data has no gameplay authority.
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
            if let (state, sequence) = MultiRedAdapter.captureWorld() {
                let generation = sourceClock.generation
                let current = sourceClock.admit(sequence)
                if generation != sourceClock.generation { peer = nil; fresh = false; policyDirty = true }
                local = state.valid && current ? state : nil
            } else { local = nil }
        }
        BoundVBABattleBridge.advanceSharedWorld()
        // Refresh the frame lease only when a new host tick has supplied policy.
        if policyDirty {
            MultiRedAdapter.applyWorld(peer, fresh: fresh)
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
    /// The active run's outbox commits this snapshot before it is published.
    /// Storage failure withholds only sharing, never the cartridge's callbacks.
    var beforeSendSnapshot: ((BoundWorldState) throws -> Void)?
    private(set) var timeline = BoundWorldTimeline()
    private(set) var latestSharedWorldState: BoundWorldState?
    private(set) var latestSharedWorldSequence: UInt64 = 0
    private var sharedWorldRecords: [Int: BoundWorldState] = [:]
    private var sharedWorldSequences: [Int: UInt64] = [:]
    private var snapshotReader: (() -> BoundWorldState?)?
    private var sequence: UInt64 = 0
    private var enabled = false
    private var lastSent: TimeInterval = -.infinity
    private var coreID: ObjectIdentifier?
    private var verification: Task<Void, Never>?
    private var gameProfile: BoundGameProfile?
    private var observedGameGeneration: UInt64 = 0
    init(snapshotReader: (() -> BoundWorldState?)? = nil) {
        self.snapshotReader = snapshotReader
        // A supplied reader is a model-test fixture; real cores require file admission.
        gameProfile = snapshotReader == nil ? nil : BoundGameProfiles.current
    }
    func bind(core: EmulatorCore?) {
        guard core.map(ObjectIdentifier.init) != coreID else { return }
        latestSharedWorldState = nil; latestSharedWorldSequence = 0
        sharedWorldRecords = [:]; sharedWorldSequences = [:]
        gameProfile = nil
        coreID = core.map(ObjectIdentifier.init); verification?.cancel(); probe.configure(core: core); observedGameGeneration = 0; peerGone()
        guard let core, core.deltaCore.identifier == "com.rileytestut.GBADeltaCore" else { return }
        let id = ObjectIdentifier(core), url = core.game.fileURL
        verification = Task { [weak self] in
            let profile = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return Optional<BoundGameProfile>.none }
                return try? MultiRedAdapter(rom: data).profile
            }.value
            guard !Task.isCancelled, let self, self.coreID == id else { return }
            self.gameProfile = profile; self.probe.setVerified(profile != nil)
        }
    }
    func peerGone() {
        timeline.reset(); sequence = 0; lastSent = -.infinity
        probe.publishPolicy(enabled: enabled, peer: nil, fresh: false)
    }
    func stop() { enabled = false; peerGone() }
    func receive(_ data: Data) {
        guard enabled, let gameProfile, let packet = BoundWorldPacket.decode(data, compatibility: gameProfile.compatibility) else { return }
        timeline.receive(packet, at: ProcessInfo.processInfo.systemUptime)
    }
    /// A durable event projects the partner's recorded world for presentation.
    /// It deliberately never enters the live timeline or native policy mailbox.
    func resetSharedWorldRecords() {
        latestSharedWorldState = nil; latestSharedWorldSequence = 0
        sharedWorldRecords = [:]; sharedWorldSequences = [:]
    }
    func recordSharedWorldEvent(state: BoundWorldState, sequence: UInt64) {
        guard state.valid, sequence > 0 else { return }
        let map = Int(state.group) * 256 + Int(state.number)
        guard sequence > (sharedWorldSequences[map] ?? 0) else { return }
        sharedWorldSequences[map] = sequence; sharedWorldRecords[map] = state
        if sequence > latestSharedWorldSequence {
            latestSharedWorldSequence = sequence; latestSharedWorldState = state
        }
    }
    func sharedWorldRecord(group: UInt8, number: UInt8) -> BoundWorldState? {
        sharedWorldRecords[Int(group) * 256 + Int(number)]
    }
    func tick(enabled: Bool, connected: Bool, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let generation = probe.gameGeneration
        if generation != observedGameGeneration { observedGameGeneration = generation; peerGone() }
        if self.enabled != enabled { self.enabled = enabled; peerGone() }
        timeline.expire(at: now)
        probe.publishPolicy(enabled: enabled, peer: timeline.state, fresh: connected && timeline.fresh(at: now))
        guard enabled, now - lastSent >= 0.5, let state = snapshotReader?() ?? probe.read(), sequence < UInt64.max else { return }
        let packet = BoundWorldPacket(sender: timeline.epoch, receiver: timeline.peer, sequence: sequence + 1, state: state)
        guard let gameProfile, let data = packet.encoded(compatibility: gameProfile.compatibility) else { return }
        lastSent = now
        do { try beforeSendSnapshot?(state) } catch { return }
        // Offline snapshots still enter the outbox. Acknowledgements and live
        // connection freshness never authorize local movement or map scripts.
        guard connected else { return }
        sequence += 1; _ = send?(data)
    }
}
