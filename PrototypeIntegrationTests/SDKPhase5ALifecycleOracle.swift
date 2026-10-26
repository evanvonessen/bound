import Foundation
@testable import Delta

// Frozen from d5bcf18b. Test-only; never sends, applies, or persists.
struct SDKPhase5AChannel {
    private(set) var epoch = UUID()
    private(set) var peerEpoch: UUID?
    private(set) var proposedEpoch: UUID?
    private var sequence: UInt64 = 0
    private var receivedSequence: UInt64 = 0
    private var retiredEpochs: Set<UUID> = []
    private(set) var receivedAt: TimeInterval?
    init(epoch: UUID) { self.epoch = epoch }
    init() {}
    mutating func reset() { self = Self() }
    mutating func packet<T: Encodable>(_ kind: BoundROMPacket.Kind, owner: UUID, body: T) -> Data? {
        guard sequence < UInt64.max, let bytes = try? BoundMultiplayerSaveStore.encode(body) else { return nil }
        sequence += 1
        return BoundROMPacket(kind:kind,owner:owner,epoch:epoch,receiver:proposedEpoch ?? peerEpoch,sequence:sequence,body:bytes).encoded()
    }
    mutating func admit(_ packet: BoundROMPacket, at now: TimeInterval) -> Bool {
        guard packet.epoch != epoch, !retiredEpochs.contains(packet.epoch) else { return false }
        guard packet.receiver == epoch else {
            if packet.kind == .hello { proposedEpoch = packet.epoch }
            return false
        }
        if peerEpoch != packet.epoch {
            if let peerEpoch { retiredEpochs.insert(peerEpoch) }
            guard retiredEpochs.count <= 64 else { return false }
            peerEpoch = packet.epoch; receivedSequence = 0
        }
        proposedEpoch = nil
        guard packet.sequence > receivedSequence else { return false }
        receivedSequence = packet.sequence; receivedAt = now; return true
    }
    func fresh(at now: TimeInterval) -> Bool {
        receivedAt.map { now >= $0 && now - $0 < 3 } ?? false
    }
}

struct SDKPhase5AActionQueue {
    private(set) var command: BoundROMCommand?
    private var observedAt: TimeInterval = 0
    private var connectedElapsed: TimeInterval = 0
    private var wasConnected = false
    mutating func enqueue(_ command: BoundROMCommand, at now: TimeInterval) {
        self.command = command; observedAt = now; connectedElapsed = 0; wasConnected = false
    }
    mutating func clear() { command = nil; connectedElapsed = 0; wasConnected = false }
    mutating func ready(request: BoundROMRequest?, connected: Bool, at now: TimeInterval) -> BoundROMCommand? {
        if connected && wasConnected { connectedElapsed += max(0, now - observedAt) }
        observedAt = now; wasConnected = connected
        if connectedElapsed >= 15 { clear() }
        guard connected, request?.permitsFieldInterruption == true else { return nil }
        return command
    }
}

struct SDKPhase5ACancellation {
    enum Action: Equatable { case wait, request, acknowledge, finish, recover }
    static let timeout: TimeInterval = 8
    static func persistedRecordMayExist(store: BoundMultiplayerSaveStore, gameID: String, checkpoint: UUID) -> Bool {
        do { return try store.checkpoint(gameID:gameID,id:checkpoint) != nil }
        catch { return true }
    }
    private(set) var requestedAt: TimeInterval?
    mutating func request(at now: TimeInterval, durable: Bool) -> Action {
        guard !durable else { return .recover }
        if requestedAt == nil { requestedAt = now }
        return .request
    }
    func receive(acknowledgement: Bool, durable: Bool) -> Action {
        guard !durable else { return .recover }
        if acknowledgement { return requestedAt == nil ? .wait : .finish }
        return .acknowledge
    }
    func action(at now: TimeInterval, startedAt: TimeInterval, localSafe: Bool,
                peerSafe: Bool?, durable: Bool) -> Action {
        if let requestedAt {
            return durable || now - requestedAt >= Self.timeout ? .recover : .wait
        }
        if durable { return now - startedAt >= 30 ? .recover : .wait }
        return !localSafe || peerSafe == false || now - startedAt >= Self.timeout ? .request : .wait
    }
}
