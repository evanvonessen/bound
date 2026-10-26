import Foundation

/// Volatile peer handshake and replay fence. These sequences are transport
/// session state; resetting them must never reset an account event journal.
struct BoundSDKReliableSession: Sendable {
    private(set) var epoch: UUID
    private(set) var peerEpoch: UUID?
    private(set) var proposedEpoch: UUID?
    private var sequence: UInt64 = 0
    private var receivedSequence: UInt64 = 0
    private var retiredEpochs: Set<UUID> = []
    private(set) var receivedAt: TimeInterval?
    init(epoch: UUID = UUID()) { self.epoch = epoch }
    var receiver: UUID? { proposedEpoch ?? peerEpoch }
    var canSend: Bool { sequence < UInt64.max }
    mutating func nextSequence() -> UInt64? {
        guard sequence < UInt64.max else { return nil }
        sequence += 1
        return sequence
    }
    mutating func admit(epoch peer: UUID, receiver: UUID?, sequence: UInt64,
                        hello: Bool, at now: TimeInterval) -> Bool {
        guard peer != epoch, !retiredEpochs.contains(peer) else { return false }
        guard receiver == epoch else {
            if hello { proposedEpoch = peer }
            return false
        }
        if peerEpoch != peer {
            if let peerEpoch { retiredEpochs.insert(peerEpoch) }
            guard retiredEpochs.count <= 64 else { return false }
            peerEpoch = peer; receivedSequence = 0
        }
        proposedEpoch = nil
        guard sequence > receivedSequence else { return false }
        receivedSequence = sequence; receivedAt = now; return true
    }
    func fresh(at now: TimeInterval) -> Bool {
        receivedAt.map { now >= $0 && now - $0 < 3 } ?? false
    }
}
