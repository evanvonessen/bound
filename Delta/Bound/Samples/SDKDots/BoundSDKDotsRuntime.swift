import Foundation

/// A bounded second-game example, deliberately absent from ordinary account/run routing.
/// The injected transport must identify the peer; this sample supplies no network authentication.
@MainActor protocol BoundSDKDotsTransport: AnyObject { func send(_ bytes: Data) throws }
@MainActor protocol BoundSDKDotsPersistence: AnyObject {
    func load() throws -> Data?
    func commit(_ bytes: Data, replacing expected: Data?) throws
}
@MainActor protocol BoundSDKDotsDurability: AnyObject {
    /// Acknowledgement is relative to this provider's declared storage contract.
    /// The local file implementation below does not establish server/WAN durability.
    var storageContract: String { get }
    func persistAndVerify(_ event: BoundSDKEvent) throws -> Bool
}

@MainActor final class BoundSDKDotsFilePersistence: BoundSDKDotsPersistence {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= BoundSDKDotsRuntime.maximumStoredBytes else { throw BoundSDKDotsAdapter.Failure.corrupt }
        return try Data(contentsOf: url)
    }
    func commit(_ bytes: Data, replacing expected: Data?) throws {
        guard bytes.count <= BoundSDKDotsRuntime.maximumStoredBytes else { throw BoundSDKDotsAdapter.Failure.exhausted }
        // Main-actor ownership serializes all sample stores in this process.
        // Cross-process writers are unsupported; each role owns a distinct file.
        guard try load() == expected else { throw BoundSDKDotsAdapter.Failure.ownership }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == bytes else { throw BoundSDKDotsAdapter.Failure.corrupt }
    }
}

/// Immutable synthetic pulse archive, used only by the explicit sample harness.
@MainActor final class BoundSDKDotsLocalArchive: BoundSDKDotsDurability {
    let storageContract = "sample-local-atomic-file-readback-v1"
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    func persistAndVerify(_ event: BoundSDKEvent) throws -> Bool {
        guard event.kind == BoundSDKDotsRuntime.pulseKind, event.payload == BoundSDKDotsRuntime.pulsePayload,
              event.id.sequence > 0, event.id.sequence <= BoundSDKDotsAdapter.maximum else { throw BoundSDKDotsAdapter.Failure.corrupt }
        let path = directory.appendingPathComponent(event.run.uuidString, isDirectory: true)
            .appendingPathComponent(event.id.origin.uuidString, isDirectory: true)
            .appendingPathComponent("\(event.id.sequence).json")
        let store = BoundSDKDotsFilePersistence(url: path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(event)
        if let existing = try store.load() {
            guard try JSONDecoder().decode(BoundSDKEvent.self, from: existing) == event else { throw BoundSDKDotsAdapter.Failure.corrupt }
        } else { try store.commit(bytes, replacing: nil) }
        return try store.load().map { try JSONDecoder().decode(BoundSDKEvent.self, from: $0) == event } ?? false
    }
}

@MainActor final class BoundSDKDotsRuntime {
    static let maximumStoredBytes = 196_608
    static let maximumEvents = 256
    static let replayBatch = 16
    static let pulseKind = "sdk-dots.pulse.v1"
    static let pulsePayload = Data([1, 0, 0, 0])
    struct State: Codable, Equatable {
        var version = 1
        var profile = BoundSDKDotsAdapter.sha256
        var journal: BoundSDKEventJournal
        var hostGeneration: UInt32 = 0
        var durable = BoundSDKEventCursor()
        var durabilityContract = "unavailable"
    }
    struct Presence: Codable { let x, y: UInt32 }
    private struct Packet: Codable {
        var profile = BoundSDKDotsAdapter.sha256
        let run: UUID
        var event: BoundSDKEvent?
        var receipt: BoundSDKEventAcknowledgement?
        var presence: Presence?
    }
    private(set) var state: State
    private var reliable = BoundSDKReliableSession()
    private var callbacks = BoundSDKGeneration()
    var callbackToken: BoundSDKGeneration.Token { callbacks.token }
    private var hostSequence: UInt32 = 0
    private var peerPosition = Presence(x: 0, y: 0)
    private var positionAt: TimeInterval?
    private let persistence: BoundSDKDotsPersistence
    private let transport: BoundSDKDotsTransport
    private let durability: BoundSDKDotsDurability
    private var persistedBytes: Data?
    var durabilityContract: String { durability.storageContract }
    private var scope: BoundSDKEventJournalRules.Scope { .init(run: state.journal.run, owner: state.journal.owner, partner: state.journal.partner) }

    init(run: UUID, owner: UUID, peer: UUID, persistence: BoundSDKDotsPersistence,
         transport: BoundSDKDotsTransport, durability: BoundSDKDotsDurability) throws {
        guard ![run, owner, peer].contains(BoundSDKBytes.zero), owner != peer else { throw BoundSDKDotsAdapter.Failure.ownership }
        self.persistence = persistence; self.transport = transport; self.durability = durability
        state = State(journal: .init(run: run, owner: owner, partner: peer), durabilityContract: durability.storageContract)
        if let bytes = try persistence.load() {
            guard bytes.count <= Self.maximumStoredBytes else { throw BoundSDKDotsAdapter.Failure.corrupt }
            state = try JSONDecoder().decode(State.self, from: bytes)
            persistedBytes = bytes
        }
        guard state.journal.run == run, state.journal.owner == owner, state.journal.partner == peer else { throw BoundSDKDotsAdapter.Failure.ownership }
        try validate(state)
        try reconnect()
    }
    private func validate(_ value: State) throws {
        guard value.version == 1, value.profile == BoundSDKDotsAdapter.sha256,
              value.durabilityContract == durability.storageContract,
              value.journal.events.count <= Self.maximumEvents, value.hostGeneration <= BoundSDKDotsAdapter.maximum,
              Set(value.durable.origins.keys).isSubset(of: [value.journal.owner.uuidString]),
              value.durable.origins.values.allSatisfy(\.valid), value.journal.received.covers(value.durable),
              value.journal.events.allSatisfy({ $0.kind == Self.pulseKind && $0.payload == Self.pulsePayload && $0.id.sequence <= BoundSDKDotsAdapter.maximum }) else { throw BoundSDKDotsAdapter.Failure.corrupt }
        try BoundSDKEventJournalRules.validate(value.journal, scope: scope)
    }
    private func commit(_ next: State) throws {
        try validate(next)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(next)
        guard bytes.count <= Self.maximumStoredBytes else { throw BoundSDKDotsAdapter.Failure.exhausted }
        try persistence.commit(bytes, replacing: persistedBytes)
        persistedBytes = bytes; state = next
    }
    private func requireCurrentStore() throws {
        guard try persistence.load() == persistedBytes else { throw BoundSDKDotsAdapter.Failure.ownership }
    }
    /// Rotates transport callbacks and a persisted native generation without changing event IDs.
    func reconnect() throws {
        guard state.hostGeneration < BoundSDKDotsAdapter.maximum else { throw BoundSDKDotsAdapter.Failure.exhausted }
        var next = state; next.hostGeneration += 1
        try commit(next)
        hostSequence = 0; reliable = BoundSDKReliableSession(); callbacks.invalidate(); positionAt = nil
    }
    func hello() throws { try send(kind: 1, packet: Packet(run: state.journal.run)) }
    func publishPresence(x: UInt32, y: UInt32) throws {
        guard x <= 232, y <= 152 else { throw BoundSDKDotsAdapter.Failure.corrupt }
        try send(kind: 4, packet: Packet(run: state.journal.run, presence: .init(x: x, y: y)))
    }
    private func send(kind: UInt8, packet: Packet) throws {
        try requireCurrentStore()
        guard let sequence = reliable.nextSequence() else { throw BoundSDKDotsAdapter.Failure.exhausted }
        let body = try JSONEncoder().encode(packet)
        guard let bytes = BoundSDKReliableEnvelope(kind: kind, owner: state.journal.owner, epoch: reliable.epoch,
            receiver: reliable.receiver, sequence: sequence, body: body).encoded() else { throw BoundSDKDotsAdapter.Failure.corrupt }
        try transport.send(bytes)
    }
    /// The caller's authenticated connection must supply its admitted peer, not a packet field.
    /// Local tests inject that connection; production account admission is outside this sample.
    @discardableResult func receive(_ bytes: Data, admittedPeer: UUID, token: BoundSDKGeneration.Token, now: TimeInterval) throws -> Bool {
        guard callbacks.admits(token), admittedPeer == state.journal.partner, bytes.count <= 16_384,
              let frame = BoundSDKReliableEnvelope.decode(bytes), frame.owner == admittedPeer,
              (1...4).contains(frame.kind) else { return false }
        try requireCurrentStore()
        let packet = try JSONDecoder().decode(Packet.self, from: frame.body)
        guard packet.profile == BoundSDKDotsAdapter.sha256, packet.run == state.journal.run else { return false }
        switch frame.kind {
        case 1: guard packet.event == nil, packet.receipt == nil, packet.presence == nil else { return false }
        case 2:
            guard let event = packet.event, event.run == state.journal.run, event.id.origin == admittedPeer,
                  event.kind == Self.pulseKind, event.payload == Self.pulsePayload,
                  event.id.sequence > 0, event.id.sequence <= BoundSDKDotsAdapter.maximum,
                  packet.receipt == nil, packet.presence == nil else { return false }
        case 3: guard packet.receipt != nil, packet.event == nil, packet.presence == nil else { return false }
        default: guard let position = packet.presence, position.x <= 232, position.y <= 152,
                       packet.event == nil, packet.receipt == nil else { return false }
        }
        var session = reliable
        guard session.admit(epoch: frame.epoch, receiver: frame.receiver, sequence: frame.sequence, hello: frame.kind == 1, at: now) else {
            // A valid hello can propose a reciprocal epoch without admitting gameplay.
            if frame.kind == 1 { reliable = session }
            return false
        }
        var next = state
        if let event = packet.event { _ = try BoundSDKEventJournalRules.receive(event, authoritative: false, into: &next.journal) }
        if let receipt = packet.receipt { try BoundSDKEventJournalRules.acknowledge(receipt, in: &next.journal) }
        if next != state { try commit(next) }
        reliable = session
        if let position = packet.presence { peerPosition = position; positionAt = now }
        if packet.event != nil {
            try send(kind: 3, packet: Packet(run: state.journal.run, receipt: BoundSDKEventJournalRules.acknowledgement(for: state.journal)))
        }
        return true
    }
    /// Observe actual native application before advancing the applied cursor.
    func observe(_ snapshot: BoundSDKDotsAdapter.Snapshot) throws {
        guard snapshot.bound, snapshot.run == state.journal.run, snapshot.owner == state.journal.owner,
              snapshot.peer == state.journal.partner, snapshot.generation <= state.hostGeneration else { throw BoundSDKDotsAdapter.Failure.ownership }
        var next = state
        if UInt64(snapshot.emitted) == next.journal.nextSequence, snapshot.pending == snapshot.emitted {
            _ = try BoundSDKEventJournalRules.append(kind: Self.pulseKind, payload: Self.pulsePayload,
                idempotencyKey: "pulse:\(snapshot.emitted)", to: &next.journal)
        }
        guard UInt64(snapshot.emitted) == next.journal.nextSequence - 1,
              UInt64(snapshot.durable) <= (next.durable.origins[state.journal.owner.uuidString]?.contiguous ?? 0),
              UInt64(snapshot.peerApplied) <= (next.journal.received.origins[state.journal.partner.uuidString]?.contiguous ?? 0) else { throw BoundSDKDotsAdapter.Failure.corrupt }
        for event in next.journal.events where event.id.origin == next.journal.partner && event.id.sequence <= snapshot.peerApplied {
            try BoundSDKEventJournalRules.markApplied(event.id, in: &next.journal)
        }
        if next != state { try commit(next) }
    }
    /// Bounded outbox replay. Receipt suppresses retransmission but never authorizes native pruning.
    func replay() throws {
        try requireCurrentStore()
        for event in BoundSDKEventJournalRules.eventsToSend(in: state.journal, peerCursor: nil, limit: Self.replayBatch, including: { _ in true }) {
            try send(kind: 2, packet: Packet(run: state.journal.run, event: event))
        }
    }
    func persistPending() throws {
        try requireCurrentStore()
        for event in state.journal.events.filter({ $0.id.origin == state.journal.owner && !state.durable.contains($0.id) }).prefix(Self.replayBatch) {
            guard try durability.persistAndVerify(event) else { continue }
            var next = state; next.durable.insert(event.id); try commit(next)
        }
    }
    /// Native publication is separate from persistence and network I/O. Only one peer pulse is replayed per cut.
    func host(for snapshot: BoundSDKDotsAdapter.Snapshot, now: TimeInterval, paused: Bool = false) throws -> Data {
        try requireCurrentStore()
        if snapshot.bound { try observe(snapshot) }
        else if !state.journal.events.isEmpty { throw BoundSDKDotsAdapter.Failure.ownership }
        guard hostSequence < BoundSDKDotsAdapter.maximum - 1 else { throw BoundSDKDotsAdapter.Failure.exhausted }
        hostSequence += 2
        var input = BoundSDKDotsAdapter.Input(run: state.journal.run, owner: state.journal.owner, peer: state.journal.partner,
            generation: state.hostGeneration, sequence: hostSequence)
        let peerNext = UInt64(snapshot.peerApplied) + 1
        if state.journal.received.contains(.init(origin: state.journal.partner, sequence: peerNext)) { input.delivery = UInt32(peerNext) }
        input.durable = UInt32(state.durable.origins[state.journal.owner.uuidString]?.contiguous ?? 0)
        input.receipt = UInt32(state.journal.acknowledged.origins[state.journal.owner.uuidString]?.contiguous ?? 0)
        if reliable.fresh(at: now), let at = positionAt, now >= at, now - at < 3 {
            input.x = peerPosition.x; input.y = peerPosition.y; input.lease = UInt32(max(1, 180 - Int((now - at) * 60)))
        }
        input.paused = paused
        return try BoundSDKDotsAdapter.host(input)
    }
}
