import Foundation
import CryptoKit
import DeltaCore
import UIKit
import Combine

/// Data-only interface exported by the integrated cartridge. These offsets are
/// not native Pokémon RAM bindings; the game owns menus and all gameplay gates.
enum BoundROMCommand: UInt32 {
    case none, listFriends, pair, cancel, submitSettings, checkpoint, resume
    case battle, trade, startSoulLink, endSoulLink, watch, timeline, accept, decline
    case recoveryChoice, page, newGameReady
    case reserved18, reserved19, reserved20, reserved21, reserved22, reserved23, reserved24, reserved25, reserved26, reserved27
    case setupTakeover = 28, setupRetry = 29
}
enum BoundROMStatus: UInt32 { case idle, waiting, accepted, declined, complete, unavailable, busy, recovery, timeline, invitation }

/// Optional actions expire after idle connected time inside a native script.
/// A transport outage does not consume the user's pending request; room/game
/// changes and explicit cancellation still clear it before reconnect dispatch.
struct BoundROMActionQueue {
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

/// Cancellation has a durable identity even before the first server response.
/// Resolved entries remain tombstones so a delayed proposal cannot revive one.
struct BoundROMSetupCancellationQueue: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var identity: BoundMultiplayerRunIdentity
        var epoch: UInt64
        var resolved = false
        var alreadyStarted = false
    }
    var version = 1
    private(set) var entries: [Entry] = []
    var valid: Bool {
        version == 1 && entries.count <= 4096 && Set(entries.map { $0.identity.run }).count == entries.count
        && entries.allSatisfy { $0.identity.valid && (!$0.alreadyStarted || $0.resolved) }
    }
    func contains(_ run: UUID) -> Bool { entries.contains { $0.identity.run == run } }
    func pending(owner: UUID, after run: UUID? = nil) -> Entry? {
        let pending = entries.filter { !$0.resolved && $0.identity.owner == owner }
        guard let run, let index = pending.firstIndex(where:{ $0.identity.run == run }), !pending.isEmpty else { return pending.first }
        return pending[(index + 1) % pending.count]
    }
    mutating func enqueue(identity: BoundMultiplayerRunIdentity, epoch: UInt64) throws {
        guard valid, identity.valid else { throw BoundMultiplayerSaveStore.Failure.corrupt }
        if let existing = entries.first(where: { $0.identity.run == identity.run }) {
            guard existing.identity.owner == identity.owner, existing.identity.partner == identity.partner,
                  existing.identity.roomID == identity.roomID, existing.identity.localSeed == identity.localSeed,
                  existing.identity.partnerSeed == identity.partnerSeed else { throw BoundMultiplayerSaveStore.Failure.conflict }
            return
        }
        guard entries.count < 4096 else { throw BoundMultiplayerSaveStore.Failure.corrupt }
        entries.append(.init(identity: identity, epoch: epoch))
    }
    mutating func resolve(_ run: UUID, alreadyStarted: Bool) throws {
        guard let index = entries.firstIndex(where: { $0.identity.run == run }) else { throw BoundMultiplayerSaveStore.Failure.conflict }
        entries[index].resolved = true
        entries[index].alreadyStarted = entries[index].alreadyStarted || alreadyStarted
    }
}

private enum BoundROMBytes {
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

struct BoundROMRequest: Equatable, Sendable {
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
              let command = BoundROMCommand(rawValue: BoundROMBytes.word(data,12)) else { return nil }
        let sequence = BoundROMBytes.word(data,8)
        guard sequence > 0, sequence & 1 == 0 else { return nil }
        return .init(sequence: sequence, command: command, friendIndex: BoundROMBytes.word(data,16),
            argument: BoundROMBytes.word(data,20), identifier: BoundROMBytes.uuid(data,24),
            settings: data.subdata(in:40..<72), flags: BoundROMBytes.word(data,80),
            frame: BoundROMBytes.word(data,84), requestID: BoundROMBytes.word(data,88), debugSetup: BoundROMBytes.word(data,160) == 1,
            setupError: BoundROMBytes.word(data,164))
    }
}

struct BoundROMHostState: Equatable, Sendable {
    struct Friend: Equatable, Sendable { var room: UUID; var name: String; var status: UInt32 = 0 }
    var enabled = false
    var linked = false
    var connected = false
    var chooser = false
    var setupCommitted = false
    var externalSetup = false
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
        BoundROMBytes.put(sequence, into: &data, at: 8)
        let flags: UInt32 = (enabled ? 1:0) | (linked ? 2:0) | (connected ? 4:0) | (chooser ? 8:0)
            | (setupCommitted ? 16:0) | (recovery ? 32:0) | (saving ? 256:0) | (transferRequired ? 512:0) | (ended ? 1024:0)
            | (restartSetup ? 2048:0) | (externalSetup ? 4096:0)
        BoundROMBytes.put(flags, into: &data, at:12)
        BoundROMBytes.put(acknowledgedRequest, into: &data, at:16)
        BoundROMBytes.put(status.rawValue, into: &data, at:20)
        BoundROMBytes.put(UInt32(min(friends.count,20)), into: &data, at:24)
        BoundROMBytes.put(run, into: &data, at:32)
        BoundROMBytes.put(localSeed, into: &data, at:48)
        BoundROMBytes.put(partnerSeed, into: &data, at:52)
        if settings.count == 32 { data.replaceSubrange(56..<88, with: settings) }
        BoundROMBytes.text(partnerName, into: &data, at:88, size:32)
        BoundROMBytes.text(message, into: &data, at:120, size:192)
        BoundROMBytes.put(180, into: &data, at:312)
        BoundROMBytes.put(page, into: &data, at:316)
        for (index, friend) in friends.prefix(20).enumerated() {
            let offset = 320 + index * 52
            BoundROMBytes.put(friend.room, into: &data, at:offset)
            BoundROMBytes.text(friend.name, into: &data, at:offset + 16, size:32)
            BoundROMBytes.put(friend.status, into: &data, at:offset + 48)
        }
        if enabled, let peerCollision {
            BoundROMBytes.put(1, into: &data, at:1360)
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
        }
        return data
    }
}

/// Remember only successful durable exports. Disk failures must leave the fact
/// eligible for retry; changing runs or restoring storage discards this cache.
struct BoundROMSoulExportCache {
    private var run: UUID?
    private var copied: Set<String> = []
    mutating func reset() { run = nil; copied.removeAll() }
    mutating func export(_ events: [BoundSoulSharedEvent], run: UUID,
                         persist: (String, Data) throws -> Void) throws {
        if self.run != run { self.run = run; copied.removeAll() }
        for event in events where event.run == run && !copied.contains(event.id) {
            guard let payload = event.payload else { throw BoundMultiplayerSaveStore.Failure.corrupt }
            try persist(event.id, payload)
            copied.insert(event.id)
        }
    }
}

/// Keeps the ROM's refresh acknowledgement pending until the server result is
/// committed. A request cancelled by account/lifecycle changes cannot repaint a
/// newer ROM menu, and a failed fetch leaves the last confirmed rows available.
@MainActor
final class BoundROMFriendsRefresh {
    private var requestID: UInt32 = 0
    private var generation = UUID()
    private(set) var status: BoundROMStatus?
    private(set) var message = ""

    func reset() {
        generation = UUID(); status = nil; message = ""
    }
    func cancel() {
        guard status != nil else { return }
        generation = UUID(); status = .unavailable
        message = "Refresh was interrupted. Select Refresh to try again."
    }
    func begin(requestID: UInt32, onboarding: FriendOnboarding) {
        reset()
        self.requestID = requestID
        let generation = generation
        status = .waiting; message = "Refreshing friends..."
        onboarding.refresh { [weak self, weak onboarding] succeeded in
            guard let self, self.generation == generation else { return }
            self.status = succeeded ? .complete : .unavailable
            self.message = succeeded ? "" : (onboarding?.currentIdentity() == nil
                ? "Sign in to Bound to refresh friends."
                : "Could not refresh friends. Select Refresh to try again.")
        }
    }
    func retireIfAcknowledged(_ request: BoundROMRequest?) {
        guard let status, status != .waiting, let request,
              request.command == .none, request.requestID == requestID else { return }
        reset()
    }
    func apply(to host: inout BoundROMHostState, onboarding: FriendOnboarding) {
        guard let status else { return }
        host.status = status; host.message = message
        if status != .waiting { host.acknowledgedRequest = requestID }
        host.friends = onboarding.rooms.compactMap { room in
            UUID(uuidString: room.roomID).map { .init(room: $0, name: room.displayName) }
        }
    }
}

/// All guest memory access stays on the emulator's completed-frame owner.
final class BoundROMMultiplayerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var coreID: ObjectIdentifier?
    private var verified = false, installed = false
    private var desired: Data?
    private var request: BoundROMRequest?
    private var sequence: UInt32 = 0
    func configure(core: EmulatorCore?) {
        lock.lock(); defer { lock.unlock() }
        coreID = core.map(ObjectIdentifier.init); verified = false; installed = false
        desired = nil; request = nil; sequence = 0
    }
    func setVerified(_ value: Bool) { lock.lock(); verified = value; lock.unlock() }
    func publish(_ state: BoundROMHostState) {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 2; if sequence == 0 { sequence = 2 }
        desired = state.encoded(sequence: sequence)
    }
    func read() -> BoundROMRequest? { lock.lock(); defer { lock.unlock() }; return request }
    func discardRequestAfterRestore() { lock.lock(); defer { lock.unlock() }; request = nil }
    func receive(_ core: EmulatorCore) {
        lock.lock(); defer { lock.unlock() }
        guard coreID == ObjectIdentifier(core), verified else { return }
        if !installed { installed = BoundVBABattleBridge.installROMMultiplayer() }
        guard installed else { return }
        if let desired { BoundVBABattleBridge.setROMMultiplayerHost(desired); self.desired = nil }
        request = BoundROMRequest.decode(BoundVBABattleBridge.romMultiplayerSnapshot())
    }
}

/// BRM1 is carried only by the authenticated expected-peer reliable channel.
/// A fresh nonce acknowledgement and monotonic sequence are required for every
/// state-changing message, including replayed durable checkpoint receipts.
struct BoundROMPacket: Equatable, Sendable {
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
        BoundROMBytes.put(owner,into:&data,at:8); BoundROMBytes.put(epoch,into:&data,at:24)
        BoundROMBytes.put(receiver,into:&data,at:40)
        for i in 0..<8 { data[56+i] = UInt8(truncatingIfNeeded:sequence >> (i*8)) }
        data.append(body); return data
    }
    static func decode(_ data: Data) -> Self? {
        guard (64...1024).contains(data.count), data.starts(with:prefix), data[4] == 1,
              data[6] == 0, data[7] == 0, let kind = Kind(rawValue:data[5]) else { return nil }
        let owner = BoundROMBytes.uuid(data,8), epoch = BoundROMBytes.uuid(data,24), receiver = BoundROMBytes.uuid(data,40)
        let sequence = (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[56+$1]) << ($1*8) }
        guard owner != BoundROMBytes.zero, epoch != BoundROMBytes.zero, sequence > 0 else { return nil }
        return .init(kind:kind,owner:owner,epoch:epoch,receiver:receiver == BoundROMBytes.zero ? nil:receiver,
                     sequence:sequence,body:data.subdata(in:64..<data.count))
    }
}

struct BoundROMChannel {
    private(set) var epoch = UUID()
    private(set) var peerEpoch: UUID?
    private(set) var proposedEpoch: UUID?
    private var sequence: UInt64 = 0
    private var receivedSequence: UInt64 = 0
    private var retiredEpochs: Set<UUID> = []
    private(set) var receivedAt: TimeInterval?
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

enum BoundROMCheckpointStage: Equatable { case wait, capture, commit, finish }
enum BoundROMCheckpointReadiness {
    static func stage(localStored: Bool, partnerStored: Bool, peerCommitted: Bool,
                      localPaused: Bool, peerPaused: Bool, peerPendingMatches: Bool,
                      historyMatches: Bool, fresh: Bool, localSafe: Bool = true, peerSafe: Bool = true) -> BoundROMCheckpointStage {
        guard localPaused && fresh else { return .wait }
        if !localStored { return localSafe && peerSafe && peerPaused && peerPendingMatches && historyMatches ? .capture:.wait }
        guard partnerStored else { return .wait }
        return peerCommitted ? .finish:.commit
    }
}

/// Cancellation is a two-party promise that neither player has prepared bytes.
/// Once either durable receipt exists, only the existing recovery/commit path is
/// allowed. A missing acknowledgement is never interpreted as permission to run.
struct BoundROMCheckpointCancellation {
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

/// Coordinates durable services requested by the cartridge. The only inputs to
/// setup are a native new-game choice and the authenticated friend-room channel.
@MainActor
final class BoundROMMultiplayerCoordinator: ObservableObject {
    struct Hello: Codable {
        var room: String
        var newGame: Bool
        var run: UUID?
        var checkpoint: UUID?
        var pending: UUID?
        var history: String?
        var paused: Bool
        var checkpointSafe: Bool?
        var ready: Bool
        var device: UUID
        var fence: UInt64
    }
    struct Setup: Codable {
        var identity: BoundMultiplayerRunIdentity
        var accepted = false
        var settingsCommitted = false
        var peerReady = false // Legacy receipt; never controls local startup.
        var serverEpoch: UInt64?
        var serverCommitted: Bool?
        var snapshotSHA256: String?
        var snapshotSettingsDigest: String?
        var serverDraftDigest: String?
    }
    struct SetupAck: Codable { var run: UUID; var digest: String }
    struct Checkpoint: Codable, Equatable {
        var id: UUID
        var predecessor: UUID?
        var history: String
    }
    struct CheckpointCancel: Codable {
        var run: UUID
        var transaction: Checkpoint
        var acknowledgement: Bool
    }
    let probe = BoundROMMultiplayerProbe()
    private weak var core: EmulatorCore?
    private let sharing: FriendSharingSession
    private let onboarding: FriendOnboarding
    private let account: BoundFriendAccount
    private let store: BoundMultiplayerSaveStore
    private let leaseClient = BoundRunLeaseClient()
    private var grant: BoundRunLeaseGrant?
    private var validatedFence: UInt64?
    private var anchorBaselineValidated = false
    private var baselineHistory: String?
    private var historyJournal: BoundROMHistoryJournal?
    private var romFrameClock = BoundROMFrameClock()
    private var leaseTask: Task<Void, Never>?
    private var leaseOperation = UUID()
    private var leaseRetryAt: TimeInterval = 0
    private var verification: Task<Void, Never>?
    private var game: Game?
    private var timer: Timer?
    private var verified = false
    private var servicesActive = true
    private var transportWasConnected = false
    private var protectedStorage = false
    private var lastInboxScanAt: TimeInterval = -.infinity
    private var host = BoundROMHostState()
    private var channel = BoundROMChannel()
    private var selectedRoom: String?
    private var peerOwner: UUID?
    private var peerHello: Hello?
    private var peerHelloAt: TimeInterval = -.infinity
    private var peerFence: UInt64 = 0
    private var reconciled = false
    private var setup: Setup?
    private var manifest: BoundMultiplayerRunManifest?
    private var incoming: BoundMultiplayerSaveStore.Incoming?
    private var finishedRun: UUID?
    private var backgroundEndedIdentity: BoundMultiplayerRunIdentity?
    private var cancelledSetup: UUID?
    private var setupCancellations = BoundROMSetupCancellationQueue()
    private var setupCancellationLoadError: String?
    private var setupCancellationRetryAt: TimeInterval = 0
    private var lastSetupCancellation: UUID?
    private let setupCancellationServer = BoundNakamaRunService()
    private var endingRun = false
    private var newGameAfterEnd = false
    private var recoveredNewGameChoice = false
    private var requestCursor = BoundROMRequestCursor()
    private var newGame = false
    private var lastSent: TimeInterval = -.infinity
    private var checkpoint: Checkpoint?
    private var checkpointStartedAt: TimeInterval?
    private var checkpointCaptureAttempted = false
    private var checkpointCancellation = BoundROMCheckpointCancellation()
    private var cancelledCheckpoints: [UUID: Checkpoint] = [:]
    private var checkpointRetryAt: TimeInterval = 0
    private var localReceipt: BoundMultiplayerCheckpointReceipt?
    private var partnerReceipt: BoundMultiplayerCheckpointReceipt?
    private var head: BoundMultiplayerSavePackage?
    private var peerCommitted = false
    private var pendingSnapshot: Data?
    private var validatedSnapshot = false
    private var didRestore = false
    private var workingStateAuthorized = false {
        didSet { updateWorkingStateAuthority() }
    }
    private var saveFenceReady = true
    private var pendingAction = BoundROMActionQueue()
    private var error: String?
    private var server = BoundNakamaRunService.shared
    private var serverTask: Task<Void, Never>?
    private let snapshotServer = BoundNakamaRunService()
    private var snapshotTask: Task<Void,Never>?
    private var snapshotOperation = UUID()
    private var snapshotRetryAt: TimeInterval = 0
    private let archivedEventServer = BoundNakamaRunService()
    private var archivedEventTask: Task<Void,Never>?
    private var archivedEventOperation = UUID()
    private var archivedEventRetryAt: TimeInterval = 0
    private var archivedEventIndex = 0
    private var archivedServerCursors: [UUID:BoundMultiplayerSharedCursor] = [:]
    private var serverOperation = UUID()
    private var serverRegisteredRun: UUID?
    private var serverPollAt: TimeInterval = 0
    private var serverUploaded: UUID?
    private var setupRetryAt: TimeInterval = 0
    private var setupNetworkError: String?
    private var setupAction: String?
    private var sharedServerCursor = BoundMultiplayerSharedCursor()
    private var lastWorldDigest: String?
    private var worldProjectionRun: UUID?
    private var soulExportCache = BoundROMSoulExportCache()
    private var journalReplayNeeded = true
    private var independentServerHead: UUID?
    private var manualSavePending = false
    private var serverCaptureAuthorized: UUID?
    private var serverReservedCheckpoint: UUID?
    private var timelinePage = 0
    private let friendsRefresh = BoundROMFriendsRefresh()
    @Published private(set) var needsServerMenu = false
    @Published private(set) var serverMenuBusy = false
    @Published private(set) var serverMenuError: String?
    @Published private(set) var serverRuns: [BoundNakamaRunService.ServerRun] = []
    @Published private(set) var serverFriends: [FriendRoom] = []
    private(set) var serverOnly = false
    private var serverStarting = false
    private var serverActivating = false
    private var nextAutomaticSave: TimeInterval = 0
    private var serverSelection = UUID()
    private var serverProfile: BoundNakamaRunService.PlayerProfile?
    private var serverCapturePending = false
    private var finalServerSaveQueued = false
    private var finalServerSaveTask: Task<Void, Never>?
    private var finalServerSaveRetry: (@MainActor (AppCloudSession) -> Task<Void, Never>)?
    private var finalServerSaveRun: UUID?
    private var finalServerSaveOwner: UUID?
    @Published private(set) var hasUnconfirmedServerSave = false
    private var accountObservation: AnyCancellable?
    var watch: (() -> Void)?
    var didRestoreSnapshot: (() -> Void)?
    var didCompleteCheckpoint: (() -> Void)?

    init(sharing: FriendSharingSession, onboarding: FriendOnboarding, account: BoundFriendAccount,
         store: BoundMultiplayerSaveStore = .shared) {
        self.sharing = sharing; self.onboarding = onboarding; self.account = account; self.store = store
        accountObservation = NotificationCenter.default.publisher(for: BoundFriendAccount.sessionDidChangeNotification, object: account)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.serverOnly else { return }
                    self.serverSelection = UUID(); self.serverMenuBusy = false; self.serverRuns = []
                    self.failServerSession(self.account.session == nil ? "Sign in to view server saves." : "Select a server save.")
                }
            }
        do { setupCancellations = try Self.loadSetupCancellations(at: setupCancellationURL) }
        catch { setupCancellationLoadError = "Cancelled setups could not be read. Retry before starting another run." }
        sharing.multiplayerPacketReceiver = { [weak self] in self?.receive($0) }
        sharing.sharedWorld.beforeSendSnapshot = { [weak self] state in
            guard let self else { return }
            try self.persistWorldSnapshot(state)
        }
        let timer = Timer(timeInterval:0.1,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer,forMode:.common); self.timer = timer
    }
    deinit {
        let timer = timer
        BoundMainActorDisposal.enqueue { timer?.invalidate() }
        verification?.cancel(); leaseTask?.cancel(); serverTask?.cancel(); snapshotTask?.cancel(); archivedEventTask?.cancel()
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var identity: BoundMultiplayerRunIdentity? { manifest?.identity ?? setup?.identity ?? incoming?.manifest.identity }
    private var setupURL: URL? { game.map { store.directory(gameID:$0.identifier).appendingPathComponent("setup.json") } }
    private var setupCancellationURL: URL { store.root.appendingPathComponent("Setup Cancellations", isDirectory: true).appendingPathComponent("queue.json") }
    static func loadSetupCancellations(at url: URL) throws -> BoundROMSetupCancellationQueue {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 8_388_608 else { throw BoundMultiplayerSaveStore.Failure.corrupt }
        let value = try JSONDecoder().decode(BoundROMSetupCancellationQueue.self, from: bytes)
        guard value.valid else { throw BoundMultiplayerSaveStore.Failure.corrupt }
        return value
    }
    static func persistSetupCancellations(_ value: BoundROMSetupCancellationQueue, at url: URL) throws {
        guard value.valid else { throw BoundMultiplayerSaveStore.Failure.corrupt }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try BoundMultiplayerSaveStore.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
    }
    var protectsRun: Bool { serverOnly || manifest != nil || setup != nil || error != nil }
    private func updateWorkingStateAuthority() {
        let allowed = !protectedStorage || workingStateAuthorized
        sharing.soulLink.probe.setNativeObservationAllowed(allowed)
        if let game, game.type == .gba {
            saveFenceReady = BoundVBABattleBridge.setROMGameSaveAllowed(allowed && !serverOnly, for:game.gameSaveURL)
            if !saveFenceReady && !allowed {
                core?.pause()
                error = "Save protection is unavailable. Your run is paused."
            }
        } else {
            saveFenceReady = true
        }
    }
    func bind(core: EmulatorCore?, game: Game?) {
        guard self.core !== core || self.game?.identifier != game?.identifier else { return }
        onboarding.setMultiplayerPartner(roomID: nil)
        if let old = self.game { store.setActive(false,gameID:old.identifier) }
        verification?.cancel(); leaseTask?.cancel(); serverTask?.cancel(); leaseTask = nil; grant = nil; validatedFence = nil
        leaseOperation = UUID()
        serverTask?.cancel(); serverTask = nil; serverOperation = UUID()
        if !serverOnly { snapshotTask?.cancel() }
        snapshotTask = nil; snapshotOperation = UUID(); snapshotRetryAt = 0
        archivedEventTask?.cancel(); archivedEventTask = nil; archivedEventOperation = UUID(); archivedEventRetryAt = 0
        archivedServerCursors = [:]; archivedEventIndex = 0
        serverRegisteredRun = nil; serverUploaded = nil; serverPollAt = 0; manualSavePending = false; serverCaptureAuthorized = nil; serverReservedCheckpoint = nil
        anchorBaselineValidated = false; baselineHistory = nil; historyJournal = nil; romFrameClock.reset(); requestCursor = .init()
        self.core = core; self.game = game; verified = false; probe.configure(core:core)
        serverOnly = game?.boundUsesServerMultiplayer == true
        if !serverOnly { server = .shared }
        serverSelection = UUID(); serverStarting = false; serverActivating = false; serverCapturePending = false; finalServerSaveQueued = false; serverProfile = nil
        needsServerMenu = serverOnly; serverMenuBusy = false; serverMenuError = nil; serverRuns = []
        if serverOnly, let game { store.useServerStorage(gameID: game.identifier) }
        servicesActive = core != nil; transportWasConnected = false
        protectedStorage = game.map { store.hasRun(gameID:$0.identifier) } ?? false; lastInboxScanAt = -.infinity
        friendsRefresh.reset()
        host = BoundROMHostState(); channel.reset(); selectedRoom = nil; peerOwner = nil; peerHello = nil
        peerHelloAt = -.infinity; peerFence = 0; reconciled = false; peerCommitted = false
        setupRetryAt = 0; setupNetworkError = nil; setupAction = nil
        sharedServerCursor = .init(); independentServerHead = nil; lastWorldDigest = nil; worldProjectionRun = nil
        soulExportCache.reset(); journalReplayNeeded = true
        setup = nil; manifest = nil; incoming = nil; finishedRun = nil; backgroundEndedIdentity = nil; cancelledSetup = nil; checkpoint = nil; localReceipt = nil; partnerReceipt = nil
        checkpointStartedAt = nil; checkpointCaptureAttempted = false; checkpointCancellation = .init(); cancelledCheckpoints = [:]; checkpointRetryAt = 0
        endingRun = false; newGameAfterEnd = false; recoveredNewGameChoice = false
        newGame = false; error = nil; pendingSnapshot = nil; didRestore = false; head = nil
        validatedSnapshot = false; workingStateAuthorized = false
        pendingAction.clear()
        sharing.soulLink.cartridgeManagesPause = false
        guard let core, let game, game.type == .gba else { return }
        if serverOnly {
            protectedStorage = true; updateWorkingStateAuthority()
            host.externalSetup = true; host.enabled = BoundMultiplayerFeatures.isEnabled
            let id = ObjectIdentifier(core), url = core.game.fileURL
            verification = Task { [weak self] in
                let valid = await Task.detached(priority: .utility) {
                    guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
                    return (try? BoundPlayerROMProfile(rom: bytes)) != nil
                }.value
                guard !Task.isCancelled, let self, self.core.map(ObjectIdentifier.init) == id else { return }
                self.verified = valid; self.probe.setVerified(valid)
                if !valid { self.core?.pause(); self.serverMenuError = "This multiplayer game needs a compatible Bound version." }
                self.probe.publish(self.host)
            }
            return
        }
        do {
            setupCancellations = try Self.loadSetupCancellations(at: setupCancellationURL)
            setupCancellationLoadError = nil
        } catch { setupCancellationLoadError = "Cancelled setups could not be read. Retry before starting another run." }
        do {
            let savedManifest = try store.manifest(gameID:game.identifier)
            if let requested = try store.pendingNewGame(gameID:game.identifier) {
                guard requested == savedManifest?.identity.run else { throw BoundMultiplayerSaveStore.Failure.conflict }
                newGameAfterEnd = true
                if let savedManifest {
                    let ready = try store.isNewGameReady(gameID:game.identifier,run:requested,owner:savedManifest.identity.owner)
                    let started = try store.hasStartedNewGame(gameID:game.identifier,run:requested)
                    guard !started || ready else { throw BoundMultiplayerSaveStore.Failure.corrupt }
                    endingRun = !ready; recoveredNewGameChoice = !started
                }
            }
            newGameAfterEnd = newGameAfterEnd && endingRun
            manifest = savedManifest?.ended == true && !endingRun ? nil:savedManifest
            finishedRun = savedManifest?.ended == true && !endingRun ? savedManifest?.identity.run:nil
            backgroundEndedIdentity = savedManifest?.ended == true ? savedManifest?.identity : nil
            incoming = endingRun ? nil:try store.inspectIncoming(gameID:game.identifier)
            if incoming != nil { finishedRun = nil }
            let replacingEnded = savedManifest?.ended == true && incoming != nil
            if finishedRun == nil, !replacingEnded, let url = setupURL, FileManager.default.fileExists(atPath:url.path) {
                let bytes = try Data(contentsOf:url)
                guard bytes.count <= 16_384 else { throw BoundMultiplayerSaveStore.Failure.corrupt }
                setup = try JSONDecoder().decode(Setup.self,from:bytes)
                guard setup?.identity.valid == true, setup?.identity.gameID == game.identifier else { throw BoundMultiplayerSaveStore.Failure.corrupt }
                if let setup, setupCancellations.contains(setup.identity.run) { try cancelSetup() }
            }
            selectedRoom = identity?.roomID
            if let manifest {
                let ending = store.directory(gameID:game.identifier).appendingPathComponent("pending-end.json")
                if FileManager.default.fileExists(atPath:ending.path) {
                    let run = try JSONDecoder().decode(UUID.self,from:Data(contentsOf:ending))
                    guard run == manifest.identity.run else { throw BoundMultiplayerSaveStore.Failure.corrupt }
                    endingRun = true
                }
            }
            if let saved = manifest ?? incoming?.manifest, saved.deviceOwner != store.deviceID {
                host.transferRequired = true; error = "Use this device to continue the saved run?"
            }
            head = finishedRun == nil && !replacingEnded && !endingRun ? try store.latestComplete(gameID:game.identifier):nil
            let prepared = finishedRun == nil && !replacingEnded && !endingRun ? try store.preparedCheckpoints(gameID:game.identifier).filter { !$0.complete && $0.payload.predecessor == head?.payload.checkpoint }:[]
            guard prepared.count <= 1 else { throw BoundMultiplayerSaveStore.Failure.conflict }
            if let pending = prepared.first {
                checkpoint = .init(id:pending.payload.checkpoint,predecessor:pending.payload.predecessor,history:pending.payload.sharedEventDigest)
                localReceipt = pending.receipt; pendingSnapshot = pending.payload.files["checkpoint.state"]?.data
                checkpointStartedAt = now
            } else { pendingSnapshot = head?.payload.files["checkpoint.state"]?.data }
            if let manifest, manifest.deviceOwner == store.deviceID, !endingRun {
                if let suspension = try store.validateSuspensionForResume(gameID:game.identifier,
                    owner:manifest.identity.owner,romSHA256:BoundWorldContract.romSHA256,gameSaveURL:game.gameSaveURL) {
                    pendingSnapshot = suspension.snapshot; validatedSnapshot = true
                } else if let checkpointID = checkpoint?.id ?? head?.payload.checkpoint {
                    _ = try store.validateCheckpointForResume(gameID:game.identifier,checkpointID:checkpointID,
                        owner:manifest.identity.owner,romSHA256:BoundWorldContract.romSHA256,gameSaveURL:game.gameSaveURL)
                    validatedSnapshot = true
                }
            }
            baselineHistory = historyDigest()
            if manifest != nil, pendingSnapshot == nil, !endingRun {
                throw BoundMultiplayerSaveStore.Failure.incomplete
            }
        } catch { self.error = error.localizedDescription }
        let protected = manifest != nil || incoming != nil || protectedStorage
        sharing.soulLink.cartridgeManagesPause = protected
        let pausedForVerification = protected && core.state == .running && core.pause()
        let id = ObjectIdentifier(core), url = core.game.fileURL
        verification = Task { [weak self] in
            let valid = await Task.detached(priority:.utility) {
                guard let bytes = try? Data(contentsOf:url,options:.mappedIfSafe) else { return false }
                return (try? BoundPlayerROMProfile(rom:bytes)) != nil
            }.value
            guard !Task.isCancelled, let self, self.core.map(ObjectIdentifier.init) == id else { return }
            self.verified = valid; self.probe.setVerified(valid)
            self.sharing.soulLink.cartridgeManagesPause = valid && protected
            if valid && protected {
                self.host.enabled = BoundMultiplayerFeatures.isEnabled; self.host.linked = true
                self.host.connected = false; self.host.run = self.identity?.run
                self.host.recovery = self.error != nil; self.host.message = self.error ?? ""
                self.probe.publish(self.host)
            }
            if valid && self.saveFenceReady && pausedForVerification && self.servicesActive && UIApplication.shared.applicationState == .active { core.resume() }
            if let room = self.selectedRoom { self.onboarding.setMultiplayerPartner(roomID:room) }
        }
    }
    private func persistSetup() throws {
        guard let setup, let url = setupURL else { throw BoundMultiplayerSaveStore.Failure.corrupt }
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try BoundMultiplayerSaveStore.encode(setup).write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        let file = try FileHandle(forWritingTo:url); defer { try? file.close() }; try file.synchronize()
    }
    private func captureSetupDraft() {
        if serverOnly { return }
        guard verified, manifest == nil, var current = setup, let game, let core,
              core.state == .running || core.state == .paused else { return }
        let wasRunning = core.state == .running
        guard core.state == .paused || core.pause() else { return }
        defer { if wasRunning, UIApplication.shared.applicationState == .active { core.resume() } }
        do {
            let path = store.directory(gameID:game.identifier).appendingPathComponent("setup.state")
            core.saveSaveState(to:path)
            let bytes = try Data(contentsOf:path)
            current.snapshotSHA256 = BoundMultiplayerSaveStore.hash(bytes)
            current.snapshotSettingsDigest = BoundMultiplayerSaveStore.hash(current.identity.settings)
            setup = current; try persistSetup()
        } catch { self.error = "Could not preserve setup. Retry before closing." }
    }
    private func restoreSetupDraftIfNeeded() throws {
        guard manifest == nil, let setup, let hash = setup.snapshotSHA256, !didRestore,
              let game, let core else { return }
        // A newer durable draft takes precedence over an earlier native UI
        // snapshot. Keep the old bytes, but never let their RAM erase choices.
        guard setup.snapshotSettingsDigest == BoundMultiplayerSaveStore.hash(setup.identity.settings) else { return }
        let path = store.directory(gameID:game.identifier).appendingPathComponent("setup.state")
        let bytes = try Data(contentsOf:path)
        guard BoundMultiplayerSaveStore.hash(bytes) == hash, setup.identity.romSHA256 == BoundWorldContract.romSHA256 else {
            throw BoundMultiplayerSaveStore.Failure.incompatible
        }
        guard core.state == .paused || core.pause() else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        try core.load(DeltaCore.SaveState(fileURL:path,gameType:.gba))
        didRestoreAuthorizedSnapshot(); didRestore = true; newGame = true; core.resume()
    }
    /// Preserve the exact working game separately from the last two-party
    /// checkpoint. This snapshot never becomes a cloud backup on its own.
    @discardableResult func suspend() -> Bool {
        if serverOnly {
            guard workingStateAuthorized else { return false }
            if finalServerSaveQueued { return true }
            do {
                let pending = head?.payload.checkpoint, expected = independentServerHead, previous = snapshotTask
                guard let session = account.session, let package = try captureServerCheckpoint(final: true) else { return false }
                let verifiedCursor = sharedServerCursor
                finalServerSaveRetry = { session in
                    BoundServerDisconnectSave.enqueue(package: package, previous: previous, expectedHead: expected,
                        pendingHead: pending, session: session, verifiedCursor: verifiedCursor)
                }
                finalServerSaveRun = package.payload.manifest.identity.run; finalServerSaveOwner = session.owner
                finalServerSaveTask = finalServerSaveRetry?(session)
                finalServerSaveQueued = true
                return true
            } catch { serverMenuError = error.localizedDescription; return false }
        }
        guard verified, saveFenceReady, workingStateAuthorized, let manifest, manifest.deviceOwner == store.deviceID,
              manifest.identity.owner == account.session?.owner,
              !sharing.nativeBattle.blocksAutoSave && !sharing.cooperativeDoubles.blocksAutoSave,
              pendingSnapshot == nil || didRestore, let core, let game,
              core.state == .running || core.state == .paused else { return false }
        guard core.state == .paused else { return false }
        do {
            try journalSoulEvents()
            if let state = sharing.sharedWorld.probe.read() { try persistWorldSnapshot(state) }
            let path = store.directory(gameID:game.identifier).appendingPathComponent("suspend.state")
            core.saveSaveState(to:path)
            core.deltaCore.emulatorBridge.saveGameSave(to:game.gameSaveURL)
            try store.captureSuspension(gameID:game.identifier,romSHA256:BoundWorldContract.romSHA256,
                gameSaveURL:game.gameSaveURL,snapshot:Data(contentsOf:path))
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func setServiceActive(_ value: Bool, temporary: Bool = false) {
        if value, serverOnly, finalServerSaveQueued, let run = identity?.run {
            finalServerSaveQueued = false
            let pending = finalServerSaveTask, selection = serverSelection
            core?.pause(); workingStateAuthorized = false; needsServerMenu = true
            Task { [weak self] in
                await pending?.value
                guard let self, self.serverSelection == selection, self.servicesActive, BoundMultiplayerFeatures.isEnabled else { return }
                if let message = BoundServerDisconnectSave.failureMessage(run: run) {
                    self.hasUnconfirmedServerSave = true; self.serverMenuError = message
                    return
                }
                _ = await self.selectServerRun(run)
            }
        }
        if !value {
            friendsRefresh.cancel()
            captureSetupDraft()
            if temporary {
                // Backgrounding retains this exact execution. A final disconnect
                // save would force a server reload on foreground and discard a
                // still-live native battle/trade, even without process death.
                sharing.nativeBattle.suspendTransport()
                sharing.cooperativeDoubles.transportInterrupted()
                if core?.state == .running { core?.pause() }
                if serverOnly {
                    serverCapturePending = true
                    if workingStateAuthorized, !serverStarting, manifest?.requiresInitialHistorySync == false {
                        do { _ = try captureServerCheckpoint() }
                        catch { serverMenuError = error.localizedDescription }
                    }
                } else { suspend() }
            } else {
                // Deliberate owner teardown restores friendly RAM before its
                // last world save, retaining the existing recovery guarantees.
                if sharing.nativeBattle.isActive, sharing.nativeBattle.activity == .battle {
                    sharing.nativeBattle.cancel(resume:false)
                }
                suspend()
            }
        }
        guard value != servicesActive else { return }
        servicesActive = value; channel.reset(); peerHello = nil; peerHelloAt = -.infinity; reconciled = false
        host.connected = false; probe.publish(host)
    }
    private func cancelSetup() throws {
        guard manifest == nil else { return }
        let cancelled = setup?.identity.run
        if let setup {
            // The intent is outside the movable run directory and survives a
            // crash before draft removal, a new setup, or an offline relaunch.
            var queue = try Self.loadSetupCancellations(at: setupCancellationURL)
            try queue.enqueue(identity: setup.identity, epoch: setup.serverEpoch ?? 0)
            try Self.persistSetupCancellations(queue, at: setupCancellationURL)
            setupCancellations = queue; setupCancellationLoadError = nil; setupCancellationRetryAt = 0
        }
        serverTask?.cancel(); serverTask = nil; serverOperation = UUID()
        if let setup, let url = setupURL {
            let archive = url.deletingLastPathComponent().appendingPathComponent("Cancelled Setups",isDirectory:true)
            try FileManager.default.createDirectory(at:archive,withIntermediateDirectories:true)
            try BoundMultiplayerSaveStore.encode(setup).write(to:archive.appendingPathComponent(setup.identity.run.uuidString + ".json"),options:.atomic)
            try FileManager.default.removeItem(at:url)
        }
        if let grant, let session = account.session {
            Task { [leaseClient] in try? await leaseClient.release(grant:grant,session:session) }
        }
        leaseTask?.cancel(); leaseTask = nil; leaseOperation = UUID()
        setup = nil; selectedRoom = nil; peerOwner = nil; peerHello = nil; grant = nil; channel.reset()
        newGame = false; setupAction = nil; setupNetworkError = nil; setupRetryAt = 0; didRestore = false
        cancelledSetup = cancelled ?? cancelledSetup
        host.run = cancelledSetup; host.linked = false; host.connected = false; host.setupCommitted = false
        host.recovery = false; host.saving = false; error = nil
        onboarding.setMultiplayerPartner(roomID:nil); host.status = .declined; host.message = ""
    }
    private func synchronizeSetupCancellations() {
        guard UIApplication.shared.applicationState == .active, serverTask == nil, now >= setupCancellationRetryAt,
              let session = account.session, let pending = setupCancellations.pending(owner: session.owner, after:lastSetupCancellation) else { return }
        lastSetupCancellation = pending.identity.run
        let operation = UUID(); serverOperation = operation; setupCancellationRetryAt = now + 1
        serverTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.serverOperation == operation { self.serverTask = nil } }
            do {
                // Fetching an HTTP ticket must never select a gameplay room or
                // overwrite the active setup/history client's authorization.
                let configuration = try await BoundNakamaAuthorization.fetch(room: pending.identity.roomID, session: session)
                guard !Task.isCancelled, self.serverOperation == operation, self.account.session?.owner == session.owner else { return }
                await self.setupCancellationServer.configure(configuration)
                let state = try await self.setupCancellationServer.sharedSetup(identity: pending.identity, action: "cancelSetup", epoch: pending.epoch)
                guard !Task.isCancelled, self.serverOperation == operation, self.account.session?.owner == session.owner else { return }
                var remote = state.identity.owner == pending.identity.owner ? state.identity : self.flip(state.identity)
                remote.gameID = pending.identity.gameID
                var expected = pending.identity
                remote.settings = Data(); expected.settings = Data(); remote.settingsOwner = expected.settingsOwner
                guard state.version == 2, remote == expected, state.cancelled || state.committed else {
                    throw BoundMultiplayerSaveStore.Failure.conflict
                }
                var queue = try Self.loadSetupCancellations(at: self.setupCancellationURL)
                // A committed response means another cartridge already started;
                // retire the request without rolling back that player's game.
                try queue.resolve(pending.identity.run, alreadyStarted: state.committed)
                try Self.persistSetupCancellations(queue, at: self.setupCancellationURL)
                self.setupCancellations = queue; self.setupCancellationRetryAt = self.now + 1
            } catch {
                guard !Task.isCancelled, self.serverOperation == operation else { return }
                self.setupCancellationRetryAt = self.now + 3
            }
        }
    }
    private func finishRun() throws {
        guard let identity, let game else { return }
        guard account.session?.owner == identity.owner else { throw BoundMultiplayerSaveStore.Failure.ownerMismatch }
        let wasRunning = newGameAfterEnd && core?.state == .running
        if newGameAfterEnd, let core {
            guard core.state == .paused || core.pause() else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        }
        defer {
            if wasRunning, core?.state == .paused, UIApplication.shared.applicationState == .active { core?.resume() }
        }
        if newGameAfterEnd {
            sharing.soulLink.endRun()
            try journalSoulEvents()
            guard !sharing.nativeBattle.protectsTemporaryState && !sharing.cooperativeDoubles.blocksAutoSave else { throw BoundMultiplayerSaveStore.Failure.incomplete }
            try store.finishNewGame(gameID:game.identifier,run:identity.run,owner:identity.owner)
            BoundVBABattleBridge.closeSoulLink()
            sharing.soulLink.bind(core:nil,gameID:game.identifier)
            sharing.soulLink.bind(core:core,gameID:game.identifier)
        } else {
            sharing.soulLink.endRun()
            guard sharing.soulLink.ledger?.ended == true else { throw BoundMultiplayerSaveStore.Failure.incomplete }
            try journalSoulEvents()
            try store.endRun(gameID:game.identifier)
        }
        backgroundEndedIdentity = identity
        finishedRun = identity.run; endingRun = false; manifest = nil; setup = nil; incoming = nil
        host.linked = false; host.connected = false; host.ended = true; host.run = identity.run
        host.setupCommitted = false; host.status = .complete
        error = nil; host.recovery = false; host.transferRequired = false; host.message = ""
        protectedStorage = false
        checkpoint = nil; localReceipt = nil; partnerReceipt = nil; peerCommitted = false; host.saving = false
        checkpointStartedAt = nil; checkpointCaptureAttempted = false; checkpointCancellation = .init(); cancelledCheckpoints = [:]
        pendingSnapshot = nil; validatedSnapshot = false; workingStateAuthorized = false
        head = nil; validatedFence = nil; anchorBaselineValidated = false; baselineHistory = nil; historyJournal = nil
        channel.reset(); peerHello = nil; peerHelloAt = -.infinity; reconciled = false
        if newGameAfterEnd {
            selectedRoom = nil; peerOwner = nil; newGame = false; pendingAction.clear()
            onboarding.setMultiplayerPartner(roomID:nil)
        }
        newGameAfterEnd = false
        sharing.soulLink.cartridgeManagesPause = false
        if let grant, let session = account.session {
            Task { [leaseClient] in try? await leaseClient.release(grant:grant,session:session) }
        }
        grant = nil
        leaseTask?.cancel(); leaseTask = nil; leaseOperation = UUID()
        applyRecoveredNewGameChoice()
        probe.publish(host)
    }
    /// A reopened cartridge has no live request ID for its earlier confirmation.
    /// Keep it in native recovery until it explicitly selects the ended UUID again.
    private func applyRecoveredNewGameChoice() {
        guard recoveredNewGameChoice, finishedRun != nil, manifest == nil else { return }
        host.connected = false; host.recovery = true; host.saving = false; host.status = .recovery
        host.message = "Previous run ended. Choose New Game."
    }
    private func requestEndRun(startNewGame: Bool = false) throws {
        guard let manifest, let game else { return }
        guard account.session?.owner == manifest.identity.owner else { throw BoundMultiplayerSaveStore.Failure.ownerMismatch }
        let wasRunning = core?.state == .running
        try restoreFriendlyBattleBeforeSaving(resume:false)
        guard core?.state == .paused || core?.pause() == true else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        defer { if wasRunning, core?.state == .paused, UIApplication.shared.applicationState == .active { core?.resume() } }
        if workingStateAuthorized { guard suspend() else { throw BoundMultiplayerSaveStore.Failure.incomplete } }
        if startNewGame {
            try store.preserveForNewGame(gameID:game.identifier,run:manifest.identity.run,
                owner:manifest.identity.owner,gameSaveURL:game.gameSaveURL)
            newGameAfterEnd = true
        }
        try finishRun()
    }
    private func advanceEndRun() {
        guard endingRun else { return }
        do { try finishRun() } catch { self.error = error.localizedDescription }
    }
    private func send<T: Encodable>(_ kind: BoundROMPacket.Kind, _ body: T) {
        guard let owner = account.session?.owner, let data = channel.packet(kind,owner:owner,body:body) else { return }
        _ = sharing.sendMultiplayerPacket(data)
    }
    private func selectRoom(_ room: String) -> Bool {
        guard onboarding.selectMultiplayerPartner(roomID: room, sharing: sharing,
            existing: { [weak account] in account?.session }) else {
            host.status = .unavailable; host.message = "Sign in to Bound to connect."
            return false
        }
        cancelledSetup = nil
        if selectedRoom != room {
            channel.reset(); peerOwner = nil; peerHello = nil; peerHelloAt = -.infinity
            peerFence = 0; reconciled = false; transportWasConnected = false
        }
        selectedRoom = room
        return true
    }
    private func ensureLease(transfer: Bool = false) {
        guard !host.transferRequired || transfer else { return }
        guard leaseTask == nil, let identity, let session = account.session, session.owner == identity.owner,
              UIApplication.shared.applicationState == .active, now >= leaseRetryAt else { return }
        if !transfer, let grant, grant.isCurrent, grant.remaining > 25 { return }
        let existing = grant
        let operation = UUID(); leaseOperation = operation
        leaseTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.leaseOperation == operation { self.leaseTask = nil } }
            do {
                let value: BoundRunLeaseGrant
                if let existing, existing.isCurrent { value = try await self.leaseClient.renew(grant:existing,session:session) }
                else { value = try await self.leaseClient.acquire(runID:identity.run,session:session,allowTransfer:transfer) }
                guard !Task.isCancelled, self.leaseOperation == operation,
                      self.identity?.run == identity.run, self.account.session?.owner == identity.owner else { return }
                self.grant = value
                if self.endingRun && self.newGameAfterEnd { self.error = nil }
                if existing?.fence != value.fence {
                    self.anchorBaselineValidated = false
                    if self.workingStateAuthorized { self.baselineHistory = self.historyDigest() }
                }
                if transfer, let game = self.game {
                    let receipt = self.incoming?.receipt ?? self.head?.receipt
                    guard value.checkpointID == receipt?.checkpoint,
                          value.checkpointHistory == receipt?.sharedEventDigest,
                          value.historyDigest == receipt?.sharedEventDigest else { throw BoundMultiplayerSaveStore.Failure.conflict }
                    if self.manifest != nil {
                        self.manifest = try self.store.adoptOwnership(gameID:game.identifier,grant:value)
                        self.historyJournal = nil; self.validatedFence = nil
                        try self.selectStoredSnapshot()
                    }
                    self.host.transferRequired = false; self.error = nil
                }
            } catch {
                guard !Task.isCancelled, self.leaseOperation == operation else { return }
                self.leaseRetryAt = self.now + 3
                if error as? BoundRunLeaseError == .transferRequired {
                    self.host.transferRequired = true; self.error = "Use this device to continue the saved run?"
                } else if error is BoundMultiplayerSaveStore.Failure || error as? BoundRunLeaseError == .anchorConflict {
                    self.error = BoundMultiplayerSaveStore.Failure.conflict.localizedDescription
                } else if error as? BoundRunLeaseError == .runEnded {
                    if self.endingRun {
                        do { self.send(.end,identity.run); try self.finishRun() }
                        catch { self.error = error.localizedDescription }
                    } else { self.error = "This Soul Link run has ended. Original saves were kept." }
                } else if self.endingRun && self.newGameAfterEnd {
                    self.error = "Could not end Soul Link. Retry recovery."
                }
            }
        }
    }
    private var anchorsReady: Bool {
        guard let grant, grant.isCurrent else { return false }
        guard manifest != nil else { return grant.checkpointID == nil }
        guard anchorBaselineValidated, let history = historyDigest() else { return false }
        return grant.checkpointID == head?.payload.checkpoint && grant.historyDigest == history
            && grant.checkpointHistory == head?.payload.sharedEventDigest
    }
    private func validateAnchorBaseline(_ grant: BoundRunLeaseGrant) throws {
        let target = head
        if grant.checkpointID != target?.payload.checkpoint {
            guard let target, target.payload.predecessor == grant.checkpointID else { throw BoundMultiplayerSaveStore.Failure.conflict }
        }
        if let bits = historyBits(), let identity, let game {
            if historyJournal == nil {
                historyJournal = try BoundROMHistoryJournal(
                    url:store.directory(gameID:game.identifier).appendingPathComponent("History Anchors/" + store.deviceID.uuidString + ".json"),
                    run:identity.run,owner:identity.owner,device:store.deviceID)
            }
            var completed: [Data] = []
            if let data = head?.payload.files["soul.json"]?.data,
               let ledger = try? JSONDecoder().decode(BoundSoulLedger.self,from:data), ledger.valid,
               let bits = historyBits(ledger:ledger) {
                completed.append(bits)
            }
            try historyJournal?.reconcile(server:grant.historyDigest,current:bits,
                completed:completed,allowUnanchored:target == nil && (baselineHistory == nil || bits.allSatisfy { $0 == 0 }))
        } else {
            guard grant.historyDigest == nil, baselineHistory == nil else { throw BoundMultiplayerSaveStore.Failure.conflict }
        }
        anchorBaselineValidated = true
    }
    private func synchronizeAnchors() throws {
        guard manifest != nil, let grant, grant.isCurrent, let history = historyDigest(),
              let session = account.session, leaseTask == nil, now >= leaseRetryAt else { return }
        try validateAnchorBaseline(grant)
        let target = head
        // Keep the agreed history anchored until the captured checkpoint has
        // been registered, even if a late monotonic death merge arrives.
        if let checkpoint, localReceipt != nil, target?.payload.checkpoint != checkpoint.id { return }
        guard grant.historyDigest != history || grant.checkpointID != target?.payload.checkpoint else { return }
        guard let submittedHistory = historyBits(), BoundROMHistoryJournal.digest(submittedHistory) == history,
              let historyJournal else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        try historyJournal.prepare(submittedHistory)
        let operation = UUID(); leaseOperation = operation
        leaseTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.leaseOperation == operation { self.leaseTask = nil } }
            do {
                var next = grant
                if let target, next.checkpointID != target.payload.checkpoint {
                    next = try await self.leaseClient.checkpoint(grant:next,checkpointID:target.payload.checkpoint,
                        predecessor:target.payload.predecessor,history:target.payload.sharedEventDigest,session:session)
                }
                if next.historyDigest != history {
                    next = try await self.leaseClient.recordHistory(grant:next,digest:history,session:session)
                }
                guard !Task.isCancelled, self.leaseOperation == operation, self.identity?.run == next.runID,
                      self.account.session?.owner == next.ownerID else { return }
                self.grant = next
                try historyJournal.reconcile(server:next.historyDigest,current:submittedHistory)
            } catch {
                guard !Task.isCancelled, self.leaseOperation == operation else { return }
                self.leaseRetryAt = self.now + 3
                if error as? BoundRunLeaseError == .anchorConflict {
                    self.error = BoundMultiplayerSaveStore.Failure.conflict.localizedDescription
                }
            }
        }
    }
    private func flip(_ value: BoundMultiplayerRunIdentity) -> BoundMultiplayerRunIdentity {
        var result = value; result.owner = value.partner; result.partner = value.owner
        result.localSeed = value.partnerSeed; result.partnerSeed = value.localSeed; return result
    }
    private func setupDigest(_ identity: BoundMultiplayerRunIdentity) -> String {
        var canonical = identity.owner.uuidString < identity.partner.uuidString ? identity : flip(identity)
        canonical.gameID = "" // local database identifiers do not define a shared run
        return BoundMultiplayerSaveStore.hash((try? BoundMultiplayerSaveStore.encode(canonical)) ?? Data())
    }
    static func validSettings(_ data: Data) -> Bool {
        guard data.count == 32, (1...4).contains(data[0]) else { return false }
        if data[0] >= 4 {
            let name = data[12..<20]
            guard let terminator = name.firstIndex(of: 0xFF), terminator > 12,
                  name[..<terminator].allSatisfy({ $0 <= 0xF6 }),
                  name[terminator...].allSatisfy({ $0 == 0xFF }),
                  data[20] <= 1, data[21..<32].allSatisfy({ $0 == 0 }) else { return false }
        } else if !data[12..<32].allSatisfy({ $0 == 0 }) { return false }
        return data[1..<10].allSatisfy { $0 <= 1 }
            && data[10] <= (data[0] >= 2 ? 1 : 0)
            && data[11] <= (data[0] >= 3 ? 1 : 0)
            && Int(data[2]) + Int(data[3]) + Int(data[4]) <= 1
            && !(data[6] == 1 && data[7] == 1)
    }
    private func receive(_ bytes: Data) {
        guard verified, BoundMultiplayerFeatures.isEnabled, let selectedRoom,
              sharing.connectedRoomID == selectedRoom, let owner = account.session?.owner,
              let packet = BoundROMPacket.decode(bytes), packet.owner != owner,
              identity?.partner == nil || identity?.partner == packet.owner else { return }
        if let peerOwner, peerOwner != packet.owner { return }
        guard !serverOnly || packet.kind == .hello else { return }
        guard channel.admit(packet,at:now) else { return }
        peerOwner = packet.owner
        do {
            switch packet.kind {
            case .hello:
                guard let hello = try? JSONDecoder().decode(Hello.self,from:packet.body) else { return }
                if let run = hello.run, setupCancellations.contains(run) { send(.cancel, run); return }
                guard hello.room == selectedRoom else { return }
                // A partner can reopen another run before queued end/history
                // events arrive. Its live hello cannot invalidate this save.
                if let identity, let remoteRun = hello.run, remoteRun != identity.run { return }
                if hello.fence > 0 && hello.fence < peerFence { return }
                peerFence = max(peerFence,hello.fence)
                peerHello = hello; peerHelloAt = now
                reconciled = hello.history != nil && hello.history == historyDigest()
                if newGame, setup == nil, manifest == nil, hello.run != nil, !hello.newGame {
                    host.status = .unavailable; host.message = "Your friend is already in a run."; return
                }
                if setupCancellationLoadError == nil, newGame, hello.newGame, setup == nil, manifest == nil, owner.uuidString < packet.owner.uuidString,
                   let game {
                    let a = UInt32.random(in:1...UInt32.max)
                    var b = UInt32.random(in:1...UInt32.max); while b == a { b = UInt32.random(in:1...UInt32.max) }
                    setup = .init(identity:.init(run:UUID(),gameID:game.identifier,owner:owner,partner:packet.owner,
                        roomID:selectedRoom,settingsOwner:Bool.random() ? owner : packet.owner,settings:Data(),
                        localSeed:a,partnerSeed:b,romSHA256:BoundWorldContract.romSHA256))
                    try persistSetup()
                }
            case .proposal:
                guard let remote = try? JSONDecoder().decode(BoundMultiplayerRunIdentity.self,from:packet.body) else { return }
                if setupCancellations.contains(remote.run) { send(.cancel, remote.run); return }
                guard setupCancellationLoadError == nil, newGame, manifest == nil, remote.valid, remote.owner == packet.owner, remote.partner == owner,
                      remote.roomID == selectedRoom, remote.romSHA256 == BoundWorldContract.romSHA256,
                      remote.settings.isEmpty, packet.owner.uuidString < owner.uuidString, let game else { return }
                var local = flip(remote); local.gameID = game.identifier
                if let setup {
                    var original = setup.identity; original.settings = Data()
                    guard setupDigest(original) == setupDigest(local) else { throw BoundMultiplayerSaveStore.Failure.conflict }
                }
                else { setup = .init(identity:local) }
                setup?.accepted = true; try persistSetup()
                send(.accepted,SetupAck(run:local.run,digest:setupDigest(local)))
            case .accepted:
                guard let ack = try? JSONDecoder().decode(SetupAck.self,from:packet.body) else { return }
                guard let current = setup, current.identity.run == ack.run, setupDigest(current.identity) == ack.digest else { return }
                setup?.accepted = true; try persistSetup()
            case .settings, .ready:
                // Advisory peer packets cannot commit setup or release gameplay.
                // Poll the durable owner-fenced configuration independently.
                setupRetryAt = 0
            case .checkpoint, .prepared, .committed, .checkpointCancel:
                // Durable save proposals and receipts come from the authenticated
                // Nakama RPC, never from a replayable peer message.
                break
            case .end:
                guard let id = try? JSONDecoder().decode(UUID.self,from:packet.body) else { return }
                if manifest?.identity.run == id { try requestEndRun() }
            case .cancel:
                guard let id = try? JSONDecoder().decode(UUID.self,from:packet.body) else { return }
                if setup?.identity.run == id, manifest == nil { try cancelSetup() }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func historyBits(ledger supplied: BoundSoulLedger? = nil) -> Data? {
        guard let identity, let ledger = supplied ?? sharing.soulLink.ledger, ledger.run == identity.run else { return nil }
        let remote = ledger.partnerSlots
        let local = ledger.acquisitionBits, peer = BoundSoulLedger.bits(remote)
        let sorted = identity.owner.uuidString < identity.partner.uuidString ? local + peer : peer + local
        return sorted + ledger.lossBits
    }
    private func historyDigest() -> String? {
        historyBits().map(BoundROMHistoryJournal.digest)
    }
    /// Friendly battle RAM belongs only to its recovery journal. A requested run
    /// save first restores the world; a failed restore keeps every save blocked.
    private func restoreFriendlyBattleBeforeSaving(resume: Bool = true) throws {
        if sharing.nativeBattle.isActive, sharing.nativeBattle.activity == .battle {
            sharing.nativeBattle.cancel(resume:resume)
        }
        guard !sharing.nativeBattle.protectsTemporaryState && !sharing.cooperativeDoubles.blocksAutoSave else {
            throw BoundMultiplayerSaveStore.Failure.incomplete
        }
    }
    private var checkpointHasDurableReceipt: Bool {
        checkpointCaptureAttempted || localReceipt != nil || partnerReceipt != nil || (checkpoint != nil && (serverReservedCheckpoint == checkpoint?.id || head?.payload.checkpoint == checkpoint?.id))
    }
    private func persistedCheckpointMayExist(_ id: UUID) -> Bool {
        guard let game else { return true }
        // Atomic rename can succeed before a later fsync reports failure. Never
        // promise cancellation based solely on an absent in-memory receipt.
        return BoundROMCheckpointCancellation.persistedRecordMayExist(store:store,gameID:game.identifier,checkpoint:id)
    }
    /// Native Save is complete locally. Capture only this cartridge; transport
    /// and partner readiness have no authority over this operation.
    private func saveLocalCheckpoint() throws {
        if serverOnly { try captureServerCheckpoint(); return }
        guard let manifest, let game, let core, workingStateAuthorized,
              manifest.identity.owner == account.session?.owner,
              !sharing.nativeBattle.blocksAutoSave, !sharing.cooperativeDoubles.blocksAutoSave else {
            throw BoundMultiplayerSaveStore.Failure.incomplete
        }
        let wasRunning = core.state == .running
        guard core.state == .paused || core.pause() else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        defer { if wasRunning && UIApplication.shared.applicationState == .active { core.resume() } }
        try journalSoulEvents()
        if let state = sharing.sharedWorld.probe.read() { try persistWorldSnapshot(state) }
        let path = store.directory(gameID:game.identifier).appendingPathComponent("capture.state")
        core.saveSaveState(to:path)
        core.deltaCore.emulatorBridge.saveGameSave(to:game.gameSaveURL)
        var additional = ["checkpoint.state":try Data(contentsOf:path)]
        if let setup { additional["setup.json"] = try BoundMultiplayerSaveStore.encode(setup) }
        let history = try historyDigest() ?? BoundMultiplayerSaveStore.hash(BoundMultiplayerSaveStore.encode(store.sharedEventAcknowledgement(gameID:game.identifier).cursor))
        head = try store.saveLocal(gameID:game.identifier,sharedEventDigest:history,
            gameSaveURL:game.gameSaveURL,additionalFiles:additional)
        checkpoint = nil; localReceipt = nil; partnerReceipt = nil; peerCommitted = false
        host.saving = false; host.status = .complete; host.message = "Saved."
        didCompleteCheckpoint?()
    }
    private func persistWorldSnapshot(_ state: BoundWorldState) throws {
        guard let manifest, manifest.requiresInitialHistorySync == false, let game,
              manifest.identity.owner == account.session?.owner, workingStateAuthorized, state.valid else { return }
        let payload = try BoundMultiplayerSaveStore.encode(state)
        let digest = BoundMultiplayerSaveStore.hash(payload)
        let key = manifest.identity.run.uuidString + ":" + digest
        guard key != lastWorldDigest else { return }
        _ = try store.appendSharedEvent(gameID:game.identifier,kind:"world",payload:payload,idempotencyKey:"world:" + digest)
        lastWorldDigest = key
    }
    private func journalSoulEvents() throws {
        guard let game, let identity, manifest != nil else { return }
        if manifest?.requiresInitialHistorySync != true {
            try soulExportCache.export(sharing.soulLink.probe.sharedEvents(),run:identity.run) { key, payload in
                _ = try store.appendSharedEvent(gameID:game.identifier,kind:"soul",payload:payload,idempotencyKey:key)
            }
        }
        if worldProjectionRun != identity.run {
            journalReplayNeeded = true
            sharing.sharedWorld.resetSharedWorldRecords()
            for event in try store.journal(gameID:game.identifier).events where event.id.origin == identity.partner && event.kind == "world" {
                if let state = try? JSONDecoder().decode(BoundWorldState.self,from:event.payload), state.valid {
                    sharing.sharedWorld.recordSharedWorldEvent(state:state,sequence:event.id.sequence)
                }
            }
            worldProjectionRun = identity.run
        }
        guard journalReplayNeeded else { return }
        for event in try store.pendingSharedEventsToApply(gameID:game.identifier) {
            if event.kind == "world", event.run == identity.run,
               let state = try? JSONDecoder().decode(BoundWorldState.self,from:event.payload), state.valid {
                if event.id.origin == identity.partner { sharing.sharedWorld.recordSharedWorldEvent(state:state,sequence:event.id.sequence) }
                try store.markSharedEventApplied(gameID:game.identifier,eventID:event.id)
                continue
            }
            guard event.run == identity.run, [identity.owner,identity.partner].contains(event.id.origin), event.kind == "soul",
                  let fact = try? JSONDecoder().decode(BoundSoulSharedEvent.self,from:event.payload), fact.valid, fact.run == identity.run else {
                host.message = "Shared event needs a compatible game version."
                if manifest?.requiresInitialHistorySync == true { throw BoundMultiplayerSaveStore.Failure.incompatible }
                continue
            }
            try sharing.soulLink.probe.receiveSharedEvent(event.payload,localOrigin:event.id.origin == identity.owner)
            try store.markSharedEventApplied(gameID:game.identifier,eventID:event.id)
        }
        journalReplayNeeded = false
    }
    static func mergingSetup(_ current: Setup, remote: BoundMultiplayerRunIdentity, epoch: UInt64, committed: Bool) throws -> Setup {
        var current = current
        var value = remote
        var a = value, b = current.identity
        a.settings = Data(); b.settings = Data(); a.settingsOwner = b.settingsOwner
        guard value.valid, a == b, epoch >= (current.serverEpoch ?? 0),
              epoch != current.serverEpoch || value.settingsOwner == current.identity.settingsOwner,
              !committed || Self.validSettings(value.settings) else { throw BoundMultiplayerSaveStore.Failure.conflict }
        if current.serverCommitted == true {
            guard committed, current.identity == value else { throw BoundMultiplayerSaveStore.Failure.conflict }
        }
        if !committed, current.serverEpoch == epoch,
           current.identity.settingsOwner == value.settingsOwner, value.settingsOwner == value.owner,
           !current.identity.settings.isEmpty {
            value.settings = current.identity.settings
        }
        let ownerUnchanged = current.identity.settingsOwner == value.settingsOwner
        current.settingsCommitted = committed || ownerUnchanged && current.settingsCommitted && value.settingsOwner == current.identity.owner
        current.serverDraftDigest = BoundMultiplayerSaveStore.hash(remote.settings)
        current.identity = value; current.serverEpoch = epoch; current.serverCommitted = committed
        return current
    }
    private func applyIndependentSetup(_ state: BoundNakamaRunService.IndependentState) throws {
        guard state.version == 2, let current = setup, state.identity.run == current.identity.run else {
            throw BoundMultiplayerSaveStore.Failure.conflict
        }
        if state.cancelled { try cancelSetup(); return }
        var value = state.identity.owner == current.identity.owner ? state.identity : flip(state.identity)
        value.gameID = current.identity.gameID
        setup = try Self.mergingSetup(current,remote:value,epoch:state.epoch,committed:state.committed)
        try persistSetup(); setupNetworkError = nil
    }
    private func synchronizeSetup() {
        guard serverTask == nil, now >= setupRetryAt, let current = setup, current.accepted,
              manifest == nil, account.session?.owner == current.identity.owner else { return }
        let ownsDraft = current.identity.settingsOwner == current.identity.owner && current.serverCommitted != true
        let draftChanged = !current.identity.settings.isEmpty && BoundMultiplayerSaveStore.hash(current.identity.settings) != current.serverDraftDigest
        let action = setupAction ?? (current.serverEpoch == nil ? "setup" :
            ownsDraft && current.settingsCommitted ? "commit" : ownsDraft && draftChanged ? "draft" : "setup")
        let operation = UUID(); serverOperation = operation; setupRetryAt = now + 1
        serverTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.serverOperation == operation { self.serverTask = nil } }
            do {
                let state = try await self.server.sharedSetup(identity:current.identity,action:action,epoch:current.serverEpoch ?? 0)
                guard !Task.isCancelled, self.serverOperation == operation, self.setup?.identity.run == current.identity.run else { return }
                try self.applyIndependentSetup(state)
                if self.setupAction == action { self.setupAction = nil }
            } catch {
                guard !Task.isCancelled, self.serverOperation == operation else { return }
                self.setupRetryAt = self.now + 3
                if self.setupAction == action { self.setupAction = nil }
                self.setupNetworkError = "Setup unavailable. Retry or cancel."
            }
        }
    }
    private func synchronizeIndependentHistory() {
        guard serverTask == nil, now >= serverPollAt, let identity = manifest?.identity,
              account.session?.owner == identity.owner else { return }
        do { try journalSoulEvents() } catch { self.error = error.localizedDescription; return }
        let operation = UUID(); serverOperation = operation; serverPollAt = now + 1
        let package = head?.payload.version == 2 && serverUploaded != head?.payload.checkpoint ? head : nil
        serverTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.serverOperation == operation { self.serverTask = nil } }
            do {
                guard let session = self.account.session else { return }
                if self.serverOnly { try session.credentials() }
                else { _ = try await self.leaseClient.independentAuthority(runID:identity.run,session:session) }
                if !self.serverOnly, self.serverRegisteredRun != identity.run {
                    let registered = try await self.server.sharedSetup(identity:identity,action:"migrate")
                    guard !Task.isCancelled, self.serverOperation == operation else { return }
                    var canonical = registered.identity.owner == identity.owner ? registered.identity : self.flip(registered.identity)
                    canonical.gameID = identity.gameID
                    guard registered.committed, canonical == identity else { throw BoundMultiplayerSaveStore.Failure.conflict }
                    for legacy in registered.legacyHistory?.values ?? Dictionary<String,BoundNakamaRunService.IndependentState.LegacyHistory>().values {
                        guard legacy.bits.count == 864 else { throw BoundMultiplayerSaveStore.Failure.corrupt }
                        let peerOffset = identity.owner.uuidString < identity.partner.uuidString ? 288 : 0
                        try self.sharing.soulLink.probe.merge(run:identity.run,rows:[],losses:legacy.bits.subdata(in:576..<864),
                            acquired:legacy.bits.subdata(in:peerOffset..<(peerOffset+288)))
                    }
                    self.serverRegisteredRun = identity.run
                    try self.journalSoulEvents()
                }
                let ack = try self.store.sharedEventAcknowledgement(gameID:identity.gameID)
                var pending = self.manifest?.requiresInitialHistorySync == true ? [] : try self.store.sharedEventsToSend(gameID:identity.gameID,peerCursor:self.sharedServerCursor,limit:16)
                if self.serverOnly, !pending.isEmpty { pending = try BoundServerDisconnectSave.eventBatch(pending) }
                let state = try await self.server.sharedEvents(identity:identity,events:pending,cursor:ack.cursor)
                guard !Task.isCancelled, self.serverOperation == operation,
                      (self.identity?.run ?? self.backgroundEndedIdentity?.run) == identity.run else { return }
                let remoteSave = state.saves[identity.owner.uuidString.lowercased()]
                if self.serverOnly {
                    let remoteHead = remoteSave?.receipt.checkpoint
                    if remoteHead != self.independentServerHead && remoteHead != self.head?.payload.checkpoint && self.snapshotTask == nil {
                        throw BoundNakamaRunService.Failure.conflict
                    }
                } else { self.independentServerHead = remoteSave?.receipt.checkpoint }
                if let head = self.head, remoteSave?.receipt.checkpoint == head.payload.checkpoint,
                   remoteSave?.receipt != head.receipt { throw BoundMultiplayerSaveStore.Failure.conflict }
                for event in state.events {
                    self.journalReplayNeeded = true
                    _ = try self.store.receiveAuthoritativeSharedEvent(gameID:identity.gameID,event:event)
                    if self.serverOnly { self.sharedServerCursor.insert(event.id) }
                }
                if self.serverOnly {
                    for event in pending where state.serverCursor.contains(event.id) { self.sharedServerCursor.insert(event.id) }
                } else { self.sharedServerCursor = state.serverCursor }
                if self.manifest?.requiresInitialHistorySync == true {
                    _ = try self.store.setInitialHistoryTarget(gameID:identity.gameID,target:state.serverCursor)
                }
                try self.journalSoulEvents()
                if let manifest = self.manifest, manifest.requiresInitialHistorySync,
                   let target = try self.store.manifest(gameID:identity.gameID)?.initialHistoryTarget {
                    let journal = try self.store.journal(gameID:identity.gameID)
                    if journal.received.covers(target), journal.applied.covers(target) {
                        self.manifest = try self.store.completeInitialHistorySync(gameID:identity.gameID)
                        try self.journalSoulEvents()
                    }
                }
                try self.store.acknowledgeSharedEvents(gameID:identity.gameID,acknowledgement:.init(run:identity.run,receiver:identity.partner,cursor:state.peerCursor(identity.partner)))
                if let package, self.manifest?.requiresInitialHistorySync != true { self.uploadSnapshotInBackground(package) }
            } catch {
                // Local bytes and the outbox already exist. A failed request
                // only schedules another background attempt.
                guard !Task.isCancelled, self.serverOperation == operation else { return }
                self.serverPollAt = self.now + 3
                if self.serverOnly, self.isServerConflict(error) {
                    self.failServerSession("This run changed on another device. Refresh and reopen its server save.")
                } else if error as? BoundRunLeaseError == .transferRequired {
                    self.error = "This run was transferred to another device. Use recovery to continue."
                }
            }
        }
    }
    private func uploadSnapshotInBackground(_ package: BoundMultiplayerSavePackage) {
        guard snapshotTask == nil, now >= snapshotRetryAt, let session = account.session,
              session.owner == package.payload.manifest.identity.owner else { return }
        if serverOnly {
            do {
                guard try BoundServerDisconnectSave.pendingEvents(in: package, verifiedCursor: sharedServerCursor).isEmpty else { return }
            } catch { failServerSession("The shared event journal could not be verified."); return }
        }
        let operation = UUID(); snapshotOperation = operation
        let expected = independentServerHead, serverManaged = serverOnly
        let uploader = serverManaged ? BoundNakamaRunService() : snapshotServer
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.snapshotOperation == operation { self.snapshotTask = nil } }
            do {
                if self.independentServerHead != package.payload.checkpoint {
                    if serverManaged {
                        _ = try await uploader.configureSaves(session: session)
                        _ = try await uploader.uploadIndependent(package, expectedHead: expected, session: session)
                    } else {
                        _ = try await self.snapshotServer.uploadIndependent(package,expectedHead:expected,session:session,authorize:{ [leaseClient = self.leaseClient] in
                            _ = try await leaseClient.independentAuthority(runID:package.payload.manifest.identity.run,session:session)
                        })
                    }
                }
                if !serverManaged, package.payload.manifest.deviceOwner == self.store.deviceID {
                    _ = try await self.leaseClient.publishIndependentCheckpoint(package:package,session:session)
                }
                guard !Task.isCancelled, self.snapshotOperation == operation,
                      self.identity?.run == package.payload.manifest.identity.run else { return }
                self.serverUploaded = package.payload.checkpoint
                self.independentServerHead = package.payload.checkpoint
                if self.serverOnly { self.host.status = .complete; self.host.message = "Saved to server." }
            } catch {
                guard self.snapshotOperation == operation else { return }
                self.snapshotRetryAt = self.now + 3
                if self.serverOnly, self.isServerConflict(error) {
                    self.failServerSession("This run changed on another device. Refresh and reopen its server save.")
                } else if error as? BoundRunLeaseError == .transferRequired {
                    self.error = "This run was transferred to another device. Use recovery to continue."
                }
            }
        }
    }
    private func synchronizeArchivedEvents() {
        guard archivedEventTask == nil, now >= archivedEventRetryAt, UIApplication.shared.applicationState == .active,
              let game, let session = account.session else { return }
        do {
            let current = manifest?.identity.run
            let pending = try store.pendingSharedRunIdentities(gameID:game.identifier).filter { $0.owner == session.owner && $0.run != current }
            guard !pending.isEmpty else { return }
            let identity = pending[archivedEventIndex % pending.count]; archivedEventIndex += 1
            let operation = UUID(); archivedEventOperation = operation; archivedEventRetryAt = now + 3
            archivedEventTask = Task { [weak self] in
                guard let self else { return }
                defer { if self.archivedEventOperation == operation { self.archivedEventTask = nil } }
                do {
                    let configuration = try await BoundNakamaAuthorization.fetch(room:identity.roomID,session:session)
                    guard !Task.isCancelled, self.archivedEventOperation == operation, self.account.session?.owner == identity.owner else { return }
                    await self.archivedEventServer.configure(configuration)
                    let ack = try self.store.sharedEventAcknowledgement(gameID:identity.gameID,identity:identity)
                    let pending = try self.store.sharedEventsToSend(gameID:identity.gameID,peerCursor:self.archivedServerCursors[identity.run] ?? .init(),limit:16,identity:identity)
                    let state = try await self.archivedEventServer.sharedEvents(identity:identity,events:pending,cursor:ack.cursor)
                    guard !Task.isCancelled, self.archivedEventOperation == operation else { return }
                    self.archivedServerCursors[identity.run] = state.serverCursor
                    for event in state.events {
                        _ = try self.store.receiveAuthoritativeSharedEvent(gameID:identity.gameID,event:event,identity:identity)
                    }
                    try self.store.acknowledgeSharedEvents(gameID:identity.gameID,
                        acknowledgement:.init(run:identity.run,receiver:identity.partner,cursor:state.peerCursor(identity.partner)),identity:identity)
                } catch {
                    guard self.archivedEventOperation == operation else { return }
                    self.archivedEventRetryAt = self.now + 5
                }
            }
        } catch { archivedEventRetryAt = now + 5 }
    }
    private func dispatchPendingAction(request: BoundROMRequest?, connected: Bool, at now: TimeInterval) {
        guard let action = pendingAction.ready(request: request, connected: connected, at: now) else { return }
        if action == .watch {
            watch?()
            pendingAction.clear()
        } else if sharing.interactions.open() {
            sharing.interactions.request(action == .battle ? .battle : .trade)
            pendingAction.clear()
        }
    }

    private func handle(_ request: BoundROMRequest) throws {
        let previousRequest = requestCursor.lastHandled
        switch requestCursor.admit(request.requestID) {
        case .ignore: return
        case .rebase:
            host.acknowledgedRequest = request.requestID
            return
        case .dispatch: break
        }
        let previousAcknowledgement = host.acknowledgedRequest
        host.acknowledgedRequest = request.requestID
        friendsRefresh.reset()
        switch request.command {
        case .newGameReady:
            guard manifest == nil, incoming == nil else {
                recoverAfterCartridgeReset()
                return
            }
            cancelledSetup = nil
            host.acknowledgedRequest = previousAcknowledgement
            do {
                if let game, let finishedRun, try store.pendingNewGame(gameID:game.identifier) == finishedRun {
                    if try !store.hasStartedNewGame(gameID:game.identifier,run:finishedRun) {
                        guard let owner = account.session?.owner else { throw BoundMultiplayerSaveStore.Failure.ownerMismatch }
                        try store.acknowledgeNewGameStarted(gameID:game.identifier,run:finishedRun,owner:owner)
                    }
                    error = nil; host.recovery = false
                }
            } catch {
                requestCursor.lastHandled = previousRequest
                throw error
            }
            recoveredNewGameChoice = false
            newGame = true; host.status = .idle; host.acknowledgedRequest = request.requestID
        case .listFriends:
            timelinePage = 0; host.status = .waiting
            host.acknowledgedRequest = previousAcknowledgement
            friendsRefresh.begin(requestID: request.requestID, onboarding: onboarding)
        case .pair, .startSoulLink:
            if let setupCancellationLoadError { host.status = .unavailable; host.message = setupCancellationLoadError; return }
            guard BoundMultiplayerFeatures.isEnabled, request.requestsNewMultiplayerRun, manifest == nil, incoming == nil,
                  let room = onboarding.rooms.first(where: { UUID(uuidString:$0.roomID) == request.identifier }) else {
                host.status = .unavailable; host.message = "Start Soul Link from a new game."; return
            }
            if let setup, setup.identity.roomID != room.roomID { throw BoundMultiplayerSaveStore.Failure.conflict }
            guard selectRoom(room.roomID) else { return }
            // The native request is the source of truth after an app relaunch:
            // its earlier newGameReady event may already have been acknowledged.
            newGame = true; host.partnerName = room.displayName; host.status = .waiting
            host.message = "Waiting for " + room.displayName + ". Press B to cancel."
        case .cancel:
            if manifest == nil {
                if let setup { send(.cancel,setup.identity.run) }
                try cancelSetup()
            }
            else { host.status = .waiting; host.message = "Run preserved. Close the game to suspend." }
        case .submitSettings:
            guard var current = setup, current.accepted, current.identity.settingsOwner == account.session?.owner,
                  !current.settingsCommitted, request.newGame, Self.validSettings(request.settings) else { return }
            current.identity.settings = request.settings; current.settingsCommitted = true
            setup = current; try persistSetup(); captureSetupDraft(); setupRetryAt = 0
        case .checkpoint:
            try saveLocalCheckpoint()
        case .setupTakeover:
            guard manifest == nil, let setup, setup.serverCommitted != true,
                  setup.identity.settingsOwner != account.session?.owner else { return }
            setupAction = "takeover"; setupRetryAt = 0; setupNetworkError = nil
        case .setupRetry:
            setupRetryAt = 0; setupNetworkError = nil
            setupCancellations = try Self.loadSetupCancellations(at: setupCancellationURL); setupCancellationLoadError = nil
            if request.requestsPregameSetupRestart, let manifest, setup?.serverCommitted == true,
               manifest.identity.owner == account.session?.owner, workingStateAuthorized {
                host.restartSetup = true
            }
            if manifest != nil { error = nil }
        case .resume: host.status = .waiting
        case .watch, .battle, .trade:
            guard let room = onboarding.rooms.first(where: { UUID(uuidString:$0.roomID) == request.identifier }),
                  identity == nil || identity?.roomID == room.roomID else {
                host.status = .unavailable; host.message = "Choose your connected friend."; return
            }
            guard selectRoom(room.roomID) else { return }
            pendingAction.enqueue(request.command, at: now); host.status = .complete
        case .timeline, .page:
            if request.command == .timeline { timelinePage = 0 }
            else { timelinePage = max(0,timelinePage + (request.argument == 0 ? -1:1)) }
            host.status = .timeline
        case .accept: sharing.interactions.accept()
        case .decline:
            pendingAction.clear()
            if sharing.interactions.phase == .incoming { sharing.interactions.decline() }
            else { sharing.interactions.cancel() }
            host.status = .complete
        case .endSoulLink:
            guard request.argument <= 1 else { host.status = .unavailable; return }
            if request.argument == 1 {
                guard let game, let owner = account.session?.owner,
                      request.identifier == manifest?.identity.run || request.identifier == finishedRun else {
                    host.status = .unavailable; host.message = "Select the saved run to start a new game."; return
                }
                let wasRecovered = recoveredNewGameChoice
                do {
                    if manifest == nil {
                        // Idempotent replay after completion, including a run ended
                        // with the legacy command before New Game was selected.
                        guard let saved = try store.manifest(gameID:game.identifier), saved.ended,
                              saved.identity.run == request.identifier, saved.identity.owner == owner else {
                            throw BoundMultiplayerSaveStore.Failure.ownerMismatch
                        }
                        guard !sharing.nativeBattle.protectsTemporaryState && !sharing.cooperativeDoubles.blocksAutoSave else { throw BoundMultiplayerSaveStore.Failure.incomplete }
                        try store.preserveForNewGame(gameID:game.identifier,run:request.identifier,owner:owner,gameSaveURL:game.gameSaveURL)
                        manifest = saved; newGameAfterEnd = true; recoveredNewGameChoice = false
                        try finishRun()
                    } else {
                        try requestEndRun(startNewGame:true)
                        recoveredNewGameChoice = false
                    }
                } catch {
                    recoveredNewGameChoice = wasRecovered
                    throw error
                }
            } else if manifest == nil { host.status = .complete }
            else { try requestEndRun() }
        case .recoveryChoice:
            if request.argument == 0 {
                error = nil; validatedFence = nil; sharing.soulLink.retryRecovery()
                checkpointStartedAt = now
                setupRetryAt = 0; setupNetworkError = nil; host.status = .waiting
            }
            else if request.argument == 1, let head {
                try selectCompletedCheckpoint(head.payload.checkpoint)
            } else if request.argument == 2 { suspend(); host.message = "Run suspended. You can close the game." }
            else if request.argument == 3 { leaseRetryAt = 0; ensureLease(transfer:true) }
        case .none, .reserved18, .reserved19, .reserved20, .reserved21, .reserved22, .reserved23, .reserved24, .reserved25, .reserved26, .reserved27: break
        }
    }
    /// A raw cartridge reset must never be captured as the working linked run.
    /// Reload only a previously validated local snapshot, after explicit Retry.
    private func recoverAfterCartridgeReset(resetRequests: Bool = false) {
        if resetRequests { requestCursor = .init(); host.acknowledgedRequest = 0; friendsRefresh.reset() }
        workingStateAuthorized = false
        pendingSnapshot = nil; validatedSnapshot = false; didRestore = false
        pendingAction.clear(); host.connected = false; host.saving = false
        anchorBaselineValidated = false; historyJournal = nil
        let message = "Game restarted. Retry recovery to resume your saved run."
        error = message
        do {
            try selectStoredSnapshot()
        } catch { self.error = error.localizedDescription }
        host.recovery = true; host.status = .recovery; host.message = error ?? message
        probe.publish(host)
    }
    private func selectStoredSnapshot() throws {
        soulExportCache.reset(); journalReplayNeeded = true
        pendingSnapshot = nil; validatedSnapshot = false; didRestore = false
        guard let manifest, let game else { return }
        if let suspension = try store.validateSuspensionForResume(gameID:game.identifier,
            owner:manifest.identity.owner,romSHA256:BoundWorldContract.romSHA256,gameSaveURL:game.gameSaveURL) {
            pendingSnapshot = suspension.snapshot; validatedSnapshot = true
        } else if let checkpointID = checkpoint?.id ?? head?.payload.checkpoint,
                  let package = try store.validateCheckpointForResume(gameID:game.identifier,checkpointID:checkpointID,
                    owner:manifest.identity.owner,romSHA256:BoundWorldContract.romSHA256,gameSaveURL:game.gameSaveURL) {
            pendingSnapshot = package.payload.files["checkpoint.state"]?.data
            validatedSnapshot = pendingSnapshot != nil
        }
    }
    private func selectCompletedCheckpoint(_ id: UUID) throws {
        guard let game, let core, let identity,
              identity.owner == account.session?.owner else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        let wasRunning = core.state == .running
        try restoreFriendlyBattleBeforeSaving(resume:false)
        guard core.state == .paused || core.pause() else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        defer { if wasRunning, UIApplication.shared.applicationState == .active { core.resume() } }
        if workingStateAuthorized { guard suspend() else { throw BoundMultiplayerSaveStore.Failure.incomplete } }
        workingStateAuthorized = false
        store.setActive(false,gameID:game.identifier)
        defer { store.setActive(true,gameID:game.identifier) }
        do {
            let restored = try store.restoreCompletedCheckpoint(gameID:game.identifier,checkpointID:id,
                owner:identity.owner,romSHA256:BoundWorldContract.romSHA256,gameSaveURL:game.gameSaveURL)
            guard let snapshot = restored.payload.files["checkpoint.state"]?.data else { throw BoundMultiplayerSaveStore.Failure.incomplete }
            manifest = try store.validateForResume(gameID:game.identifier,owner:identity.owner,romSHA256:BoundWorldContract.romSHA256)
            soulExportCache.reset(); journalReplayNeeded = true
            head = restored; checkpoint = nil; localReceipt = nil; partnerReceipt = nil; peerCommitted = false
            pendingSnapshot = snapshot; didRestore = false; validatedSnapshot = true
            baselineHistory = restored.payload.sharedEventDigest; anchorBaselineValidated = false; historyJournal = nil
            sharing.soulLink.bind(core:nil,gameID:game.identifier)
            sharing.soulLink.bind(core:core,gameID:game.identifier); sharing.soulLink.cartridgeManagesPause = true
            validatedFence = nil; channel.reset(); reconciled = false
            error = nil; host.status = .waiting
        } catch {
            recoverAfterCartridgeReset()
            throw error
        }
    }
    private func restoreSnapshotIfNeeded() throws {
        guard error == nil, !sharing.nativeBattle.blocksAutoSave && !sharing.cooperativeDoubles.blocksAutoSave,
              !didRestore, manifest?.requiresInitialHistorySync != true, let pendingSnapshot, let core, let game,
              manifest?.deviceOwner == store.deviceID, identity?.owner == account.session?.owner,
              core.state == .running || core.state == .paused else { return }
        if !validatedSnapshot, let checkpointID = checkpoint?.id ?? head?.payload.checkpoint, let identity {
            _ = try store.validateCheckpointForResume(gameID:game.identifier,checkpointID:checkpointID,
                owner:identity.owner,romSHA256:BoundWorldContract.romSHA256,gameSaveURL:game.gameSaveURL)
            validatedSnapshot = true
        }
        guard validatedSnapshot else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        guard core.state == .paused || core.pause() else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        do {
            let path = store.directory(gameID:game.identifier).appendingPathComponent("restore.state")
            try pendingSnapshot.write(to:path,options:.atomic)
            try core.load(DeltaCore.SaveState(fileURL:path,gameType:.gba))
        } catch {
            showRecoveryWhilePaused(error,core:core)
            throw error
        }
        do {
            try journalSoulEvents()
            try sharing.soulLink.probe.prepareRestoredState(core)
        } catch {
            showRecoveryWhilePaused(error,core:core)
            throw error
        }
        worldProjectionRun = nil
        didRestoreAuthorizedSnapshot()
        didRestore = true; workingStateAuthorized = true; didRestoreSnapshot?(); channel.reset()
        reconciled = false
        core.resume()
    }
    func didRestoreAuthorizedSnapshot() {
        romFrameClock.reset()
        // A verified native-battle restore also rewinds frames and requests.
        // Rebase from fresh RAM without changing the run's existing authority.
        probe.discardRequestAfterRestore(); requestCursor.didRestore(); friendsRefresh.reset()
    }
    private func restoreIncomingIfReady() throws {
        guard !sharing.nativeBattle.blocksAutoSave && !sharing.cooperativeDoubles.blocksAutoSave, let game, let core, let grant, grant.isCurrent,
              incoming != nil || store.hasInterruptedRestore(gameID:game.identifier) else { return }
        guard core.state == .paused || core.pause() else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        do { try installIncoming(game:game,grant:grant,core:core) }
        catch { showRecoveryWhilePaused(error,core:core); throw error }
    }
    private func showRecoveryWhilePaused(_ error: Error, core: EmulatorCore) {
        self.error = error.localizedDescription; host.recovery = true; host.connected = false
        host.status = .recovery; host.message = error.localizedDescription; probe.publish(host)
        // The cartridge gate remains latched; resume only its native recovery UI.
        if UIApplication.shared.applicationState == .active { core.resume() }
    }
    private func installIncoming(game: Game, grant: BoundRunLeaseGrant, core: EmulatorCore) throws {
        workingStateAuthorized = false
        store.setActive(false,gameID:game.identifier)
        if store.hasInterruptedRestore(gameID:game.identifier) {
            try store.finishInterruptedRestore(gameID:game.identifier,owner:grant.ownerID,
                romSHA256:BoundWorldContract.romSHA256,gameSaveURL:game.gameSaveURL,grant:grant)
        }
        if let incoming {
            try store.restore(archiveURL:incoming.archiveURL,gameID:game.identifier,owner:grant.ownerID,
                romSHA256:BoundWorldContract.romSHA256,gameSaveURL:game.gameSaveURL,grant:grant)
        }
        incoming = nil; manifest = try store.manifest(gameID:game.identifier)
        if let url = setupURL, FileManager.default.fileExists(atPath:url.path) {
            setup = try JSONDecoder().decode(Setup.self,from:Data(contentsOf:url))
            guard setup?.identity == manifest?.identity else { throw BoundMultiplayerSaveStore.Failure.corrupt }
        }
        head = try store.latestComplete(gameID:game.identifier)
        baselineHistory = head?.payload.sharedEventDigest; anchorBaselineValidated = false; historyJournal = nil
        // An old unstarted restore leaves the original suspension intact;
        // an applied restore retires that pointer and selects its exact head.
        try selectStoredSnapshot()
        sharing.soulLink.bind(core:nil,gameID:game.identifier)
        sharing.soulLink.bind(core:core,gameID:game.identifier); sharing.soulLink.cartridgeManagesPause = true
        validatedFence = nil; channel.reset(); core.resume()
    }
    func tick() {
        if serverOnly { tickServerSession(); return }
        synchronizeSetupCancellations()
        synchronizeArchivedEvents()
        guard verified, saveFenceReady, let core, let game else { return }
        let request = probe.read()
        if request?.settingsApplied == true { host.restartSetup = false }
        if let request, romFrameClock.observe(request.frame), workingStateAuthorized, manifest != nil {
            recoverAfterCartridgeReset(resetRequests:true)
        }
        host.enabled = BoundMultiplayerFeatures.isEnabled
        host.linked = manifest != nil || incoming != nil || protectedStorage
        host.ended = finishedRun != nil && !host.linked && setup == nil
        sharing.soulLink.cartridgeManagesPause = host.linked
        host.recovery = error != nil || manifest?.requiresInitialHistorySync == true || manifest != nil && !workingStateAuthorized
        host.run = identity?.run ?? cancelledSetup ?? finishedRun; host.localSeed = identity?.localSeed ?? 0; host.partnerSeed = identity?.partnerSeed ?? 0
        if let identity, identity.settings.count == 32 { host.settings = identity.settings }
        host.chooser = setup?.accepted == true && setup?.serverEpoch != nil && setup?.identity.settingsOwner == account.session?.owner
        if setup?.accepted == true, setup?.serverEpoch != nil, manifest == nil, error == nil { host.status = .accepted }
        if let setupNetworkError, manifest == nil { host.status = .unavailable; host.message = setupNetworkError }
        host.setupCommitted = manifest != nil
        let transportConnected = sharing.connectedRoomID == selectedRoom && selectedRoom != nil && !sharing.reconnecting
        if transportWasConnected && !transportConnected {
            channel.reset(); peerHello = nil; peerHelloAt = -.infinity; reconciled = false
        }
        transportWasConnected = transportConnected
        host.connected = host.enabled && servicesActive && UIApplication.shared.applicationState == .active
            && transportConnected && channel.fresh(at:now) && error == nil
            && peerHello?.run == identity?.run && now - peerHelloAt < 3
        if !channel.fresh(at:now) { reconciled = false }
        defer {
            host.recovery = error != nil || manifest?.requiresInitialHistorySync == true || manifest != nil && !workingStateAuthorized
            if host.recovery, error == nil { host.status = .recovery; host.message = "Restoring this save..." }
            applyRecoveredNewGameChoice()
            host.peerCollision = host.enabled && servicesActive && UIApplication.shared.applicationState == .active
                ? sharing.livePresence.collision(at: now) : nil
            if host.enabled && servicesActive && !host.recovery && !host.saving {
                friendsRefresh.apply(to: &host, onboarding: onboarding)
            }
            probe.publish(host)
        }
        guard host.enabled && servicesActive && UIApplication.shared.applicationState == .active else { host.connected = false; return }
        guard core.state == .running else { host.connected = false; return }
        if host.linked, let issue = sharing.soulLink.recoveryError { error = issue }
        if let identity, identity.owner != account.session?.owner {
            host.connected = false; host.recovery = true; host.status = .recovery
            host.message = "Sign in to the account that owns this run."; return
        }
        if let room = selectedRoom { onboarding.setMultiplayerPartner(roomID:room) }
        if host.status != .timeline {
            host.friends = onboarding.rooms.compactMap { room in
                UUID(uuidString:room.roomID).map { .init(room:$0,name:room.displayName) }
            }
            if let room = onboarding.rooms.first(where: { $0.roomID == selectedRoom }) { host.partnerName = room.displayName }
        } else {
            let events = Array(sharing.soulLink.probe.timeline.read().events.reversed())
            timelinePage = min(timelinePage,max(0,(events.count - 1)/12))
            host.page = UInt32(timelinePage)
            host.friends = events.dropFirst(timelinePage*12).prefix(12).map { .init(room:BoundROMBytes.zero,name:$0.title) }
        }
        friendsRefresh.retireIfAcknowledged(request)
        do {
            if manifest == nil, incoming == nil, now - lastInboxScanAt > 1 {
                lastInboxScanAt = now; protectedStorage = store.hasRun(gameID:game.identifier)
                if protectedStorage && identity == nil {
                    incoming = try store.inspectIncoming(gameID:game.identifier)
                    if incoming != nil { finishedRun = nil; head = nil; selectedRoom = identity?.roomID }
                    if incoming?.manifest.deviceOwner != store.deviceID, incoming != nil {
                        host.transferRequired = true; error = "Use this device to continue the saved run?"
                    }
                }
                updateWorkingStateAuthority()
            }
            try restoreSetupDraftIfNeeded()
            if let request { try handle(request) }
            if var draft = setup, draft.serverCommitted != true, !draft.settingsCommitted,
               draft.identity.settingsOwner == account.session?.owner, request?.settings.count == 32,
               let settings = request?.settings, settings[0] == 4, settings != draft.identity.settings {
                draft.identity.settings = settings; setup = draft; try persistSetup(); captureSetupDraft()
            }
            if manifest != nil, sharing.soulLink.ledger?.ended == true { try requestEndRun() }
            if endingRun {
                ensureLease(); advanceEndRun(); host.connected = false; host.saving = error == nil
                host.recovery = error != nil; host.status = error == nil ? .waiting:.recovery
                host.message = error ?? "Ending Soul Link..."
                if now - lastSent >= 0.5, let selectedRoom, let device = try? BoundMultiplayerDeviceIdentity.current() {
                    lastSent = now
                    send(.hello,Hello(room:selectedRoom,newGame:false,run:identity?.run,checkpoint:head?.payload.checkpoint,
                        pending:checkpoint?.id,history:historyDigest(),paused:request?.paused == true,checkpointSafe:request?.checkpointSafe == true,ready:false,
                        device:device,fence:grant?.isCurrent == true ? grant!.fence:0))
                }
                return
            }
            if incoming != nil { ensureLease() }
            try restoreIncomingIfReady()
            synchronizeSetup()
            if let current = setup, current.serverCommitted == true, manifest == nil,
               newGame, request?.newGame == true {
                try store.begin(current.identity,gameSaveURL:game.gameSaveURL)
                try persistSetup()
                manifest = try store.validateForResume(gameID:game.identifier,owner:current.identity.owner,romSHA256:BoundWorldContract.romSHA256)
                try sharing.soulLink.startPreparedRun(run:current.identity.run)
                protectedStorage = true
                workingStateAuthorized = true
                newGame = false
                baselineHistory = nil; anchorBaselineValidated = false; historyJournal = nil
                store.setActive(true,gameID:game.identifier); host.status = .complete
                try saveLocalCheckpoint()
            }
            if let manifest {
                guard workingStateAuthorized || pendingSnapshot != nil else { throw BoundMultiplayerSaveStore.Failure.incomplete }
                self.manifest = try store.validateForResume(gameID:game.identifier,owner:manifest.identity.owner,romSHA256:BoundWorldContract.romSHA256)
                store.setActive(true,gameID:game.identifier)
                try restoreSnapshotIfNeeded()
                if sharing.soulLink.ledger == nil { try sharing.soulLink.startPreparedRun(run:manifest.identity.run) }
                try journalSoulEvents()
            }
            dispatchPendingAction(request: request, connected: sharing.connectedRoomID == selectedRoom, at: now)
            synchronizeIndependentHistory()
        } catch { self.error = error.localizedDescription }
        if let error {
            host.connected = false; host.recovery = true; host.status = .recovery; host.message = error
        } else if host.saving { host.message = "Saving..." }
        if !host.enabled { host.connected = false; return }
        if now - lastSent >= 0.5, let selectedRoom, sharing.connectedRoomID == selectedRoom,
           let device = try? BoundMultiplayerDeviceIdentity.current() {
            lastSent = now
            send(.hello,Hello(room:selectedRoom,newGame:newGame && manifest == nil && incoming == nil,run:identity?.run,checkpoint:head?.payload.checkpoint,
                pending:checkpoint?.id,history:historyDigest(),paused:request?.paused == true,
                checkpointSafe:request?.checkpointSafe == true,ready:error == nil && !host.transferRequired && (manifest == nil || workingStateAuthorized),
                device:device,fence:grant?.isCurrent == true ? grant!.fence:0))
            if let finishedRun { send(.end,finishedRun) }
            if let current = setup, manifest == nil {
                if !current.accepted { send(.proposal,current.identity) }
                else if !current.settingsCommitted { send(.accepted,SetupAck(run:current.identity.run,digest:setupDigest(current.identity))) }
                if current.settingsCommitted {
                    if current.identity.settingsOwner == current.identity.owner { send(.settings,current.identity) }
                    send(.ready,SetupAck(run:current.identity.run,digest:setupDigest(current.identity)))
                }
            } else if let current = setup, current.settingsCommitted {
                send(.ready,SetupAck(run:current.identity.run,digest:setupDigest(current.identity)))
            }

        }
        _ = core // retained only weakly outside this tick
    }
}

extension BoundROMMultiplayerCoordinator {
    enum ServerCoreFailure: LocalizedError {
        case startup
        var errorDescription: String? { "The game could not start. Close and reopen it." }
    }
    static func prepareServerCoreForSelection(_ core: EmulatorCore) throws {
        // The setup menu intentionally prevents Delta's automatic startup.
        // Initialize the native core before applying a new run's settings.
        if core.state == .stopped, !core.start() { throw ServerCoreFailure.startup }
        guard core.state == .paused || core.pause() else { throw ServerCoreFailure.startup }
    }
    func beginServerGameSetup() {
        if !hasUnconfirmedServerSave { serverMenuError = nil }
        refreshServerFriends()
    }
    func serverFriendName(roomID: String) -> String {
        onboarding.rooms.first { $0.roomID.lowercased() == roomID.lowercased() }?.displayName ?? "Shared Run"
    }
    func refreshServerFriends() {
        onboarding.refresh { [weak self] _ in self?.serverFriends = self?.onboarding.rooms ?? [] }
        serverFriends = onboarding.rooms
    }
    func refreshServerRuns() async {
        guard serverOnly, let game, let session = account.session else { serverMenuError = "Sign in to view server saves."; return }
        guard !serverMenuBusy else { return }
        let selection = serverSelection, client = BoundNakamaRunService()
        serverMenuBusy = true; serverMenuError = nil
        defer { if serverSelection == selection, session.isSameSession(as: account.session) { serverMenuBusy = false } }
        refreshServerFriends()
        do {
            _ = try await client.configureSaves(session: session)
            let runs = try await client.listSaves(gameID: game.identifier)
            guard serverSelection == selection, session.isSameSession(as: account.session) else { return }
            serverRuns = runs
            serverMenuError = BoundServerDisconnectSave.failureMessage(gameID: game.identifier, owner: session.owner)
        } catch {
            guard serverSelection == selection, session.isSameSession(as: account.session) else { return }
            serverMenuError = error.localizedDescription
        }
    }
    private func prepareServerSelection(_ selection: UUID) async throws {
        if workingStateAuthorized, !suspend() { throw BoundMultiplayerSaveStore.Failure.incomplete }
        core?.pause(); workingStateAuthorized = false
        serverTask?.cancel(); serverTask = nil; serverOperation = UUID()
        await finalServerSaveTask?.value
        guard selection == serverSelection else { throw CancellationError() }
        if let run = finalServerSaveRun, let message = BoundServerDisconnectSave.failureMessage(run: run) {
            hasUnconfirmedServerSave = true; serverMenuError = message
            throw BoundNakamaRunService.Failure.unavailable
        }
        finalServerSaveTask = nil; finalServerSaveRetry = nil; finalServerSaveRun = nil; finalServerSaveOwner = nil; finalServerSaveQueued = false
        hasUnconfirmedServerSave = false
        snapshotTask?.cancel(); snapshotTask = nil; snapshotOperation = UUID(); snapshotRetryAt = 0
        pendingAction.clear(); channel.reset(); peerHello = nil
    }
    func retryFinalServerSave() async {
        guard !serverMenuBusy, let retry = finalServerSaveRetry, let run = finalServerSaveRun else { return }
        guard let session = account.session, session.owner == finalServerSaveOwner else {
            serverMenuError = "Sign in to the account that owns the unsaved progress."; return
        }
        let selection = serverSelection
        serverMenuBusy = true; finalServerSaveTask = retry(session)
        await finalServerSaveTask?.value
        guard selection == serverSelection else { return }
        serverMenuBusy = false
        serverMenuError = BoundServerDisconnectSave.failureMessage(run: run)
        hasUnconfirmedServerSave = serverMenuError != nil
        if !hasUnconfirmedServerSave { await refreshServerRuns() }
    }
    func discardUnconfirmedServerSave() {
        guard !serverMenuBusy else { return }
        if let run = finalServerSaveRun { BoundServerDisconnectSave.acknowledgeFailure(run: run) }
        finalServerSaveTask = nil; finalServerSaveRetry = nil; finalServerSaveRun = nil; finalServerSaveOwner = nil; finalServerSaveQueued = false
        hasUnconfirmedServerSave = false; workingStateAuthorized = false; serverMenuError = nil
    }
    func createServerRun(room: FriendRoom, options: BoundMultiplayerSetupOptions, requestID: UUID) async {
        guard serverOnly, verified, !serverMenuBusy, options.valid, let game, let session = account.session else { return }
        serverMenuBusy = true; serverMenuError = nil
        let selection = UUID(), client = BoundNakamaRunService(); serverSelection = selection
        do {
            try await prepareServerSelection(selection)
            _ = try await client.configureSaves(session: session, room: room.roomID)
            guard serverSelection == selection, session.isSameSession(as: account.session) else { return }
            let state = try await client.createSave(gameID: game.identifier, romSHA256: BoundWorldContract.romSHA256,
                settings: options.settings, profile: options.profile, partnerProfile: options.partnerProfile, requestID: requestID)
            guard serverSelection == selection, session.isSameSession(as: account.session) else { return }
            try await activateServerRun(state, profile: options.profile, selection: selection, client: client, session: session)
        } catch {
            guard serverSelection == selection, session.isSameSession(as: account.session) else { return }
            core?.pause(); workingStateAuthorized = false; serverMenuBusy = false
            if !hasUnconfirmedServerSave { serverMenuError = error.localizedDescription }
        }
    }
    /// false means this participant has never chosen their own character.
    @discardableResult func selectServerRun(_ saveID: UUID, profile: BoundNakamaRunService.PlayerProfile? = nil) async -> Bool {
        guard serverOnly, verified, !serverMenuBusy, let session = account.session else { return true }
        serverMenuBusy = true; serverMenuError = nil
        let selection = UUID(), client = BoundNakamaRunService(); serverSelection = selection
        do {
            try await prepareServerSelection(selection)
            _ = try await client.configureSaves(session: session)
            var state = try await client.getSave(saveID)
            guard serverSelection == selection, session.isSameSession(as: account.session) else { return true }
            if let profile { state = try await client.setProfile(profile, saveID: saveID) }
            guard serverSelection == selection, session.isSameSession(as: account.session) else { return true }
            guard let selectedProfile = state.profiles?[session.owner.uuidString.lowercased()] else {
                serverMenuBusy = false; return false
            }
            try await activateServerRun(state, profile: selectedProfile, selection: selection, client: client, session: session)
        } catch {
            guard serverSelection == selection, session.isSameSession(as: account.session) else { return true }
            core?.pause(); workingStateAuthorized = false; serverMenuBusy = false
            if !hasUnconfirmedServerSave { serverMenuError = error.localizedDescription }
        }
        return true
    }
    func clearServerRuns() async {
        guard serverOnly, !serverMenuBusy, let session = account.session else { return }
        serverMenuBusy = true; serverMenuError = nil
        // Only delete the rows/revisions explicitly covered by confirmation.
        let confirmed = serverRuns, selection = serverSelection, client = BoundNakamaRunService()
        defer { if serverSelection == selection, session.isSameSession(as: account.session) { serverMenuBusy = false } }
        do {
            _ = try await client.configureSaves(session: session)
            for run in confirmed {
                guard serverSelection == selection, session.isSameSession(as: account.session) else { return }
                try await client.deleteSave(run.save_id, expectedRevision: run.revision)
            }
            guard serverSelection == selection, session.isSameSession(as: account.session) else { return }
            serverRuns = []
        } catch {
            guard serverSelection == selection, session.isSameSession(as: account.session) else { return }
            serverMenuError = "A run changed or could not be deleted. Refresh before trying again."
        }
    }
    private func activateServerRun(_ state: BoundNakamaRunService.IndependentState,
                                   profile: BoundNakamaRunService.PlayerProfile, selection: UUID,
                                   client: BoundNakamaRunService, session: AppCloudSession) async throws {
        guard let game, let core, state.save_id == state.identity.run, state.committed, !state.cancelled,
              state.identity.owner == account.session?.owner, state.identity.gameID == game.identifier,
              state.identity.romSHA256 == BoundWorldContract.romSHA256, profile.valid else { throw BoundMultiplayerSaveStore.Failure.incompatible }
        serverActivating = true
        defer { if selection == serverSelection { serverActivating = false } }
        let upload = state.saves[state.identity.owner.uuidString.lowercased()]
        let package: BoundMultiplayerSavePackage?
        if let upload { package = try await client.downloadIndependent(identity: state.identity, upload: upload) }
        else { package = nil }
        guard selection == serverSelection, session.isSameSession(as: account.session) else { throw CancellationError() }
        server = client
        let memory: [String: Data]
        if let blob = package?.payload.files["memory-files.json"] {
            guard BoundMultiplayerSaveStore.hash(blob.data) == blob.sha256 else { throw BoundMultiplayerSaveStore.Failure.corrupt }
            memory = try JSONDecoder().decode([String: Data].self, from: blob.data)
        } else { memory = [:] }
        sharing.cooperativeDoubles.bind(core: nil, gameID: game.identifier, soul: sharing.soulLink.probe)
        sharing.nativeBattle.bind(core: nil, gameID: game.identifier, interactions: sharing.interactions)
        if package == nil {
            // A new UUID must never inherit a previously loaded player's RAM.
            host = BoundROMHostState(); probe.publish(host)
            _ = core.stop(); probe.configure(core: core); probe.setVerified(true)
            requestCursor = .init(); romFrameClock.reset()
        }
        try Self.prepareServerCoreForSelection(core)
        try BoundServerMemoryFiles.restore(memory, gameID: game.identifier)
        try store.beginServerSession(identity: state.identity, package: package, target: state.serverCursor)
        if let package {
            guard let battery = package.payload.files["game.sav"]?.data, let snapshot = package.payload.files["checkpoint.state"]?.data,
                  BoundVBABattleBridge.restoreServerBattery(battery), BoundVBABattleBridge.restoreServerState(snapshot) else { throw BoundMultiplayerSaveStore.Failure.corrupt }
            didRestoreAuthorizedSnapshot(); didRestoreSnapshot?()
        }
        sharing.soulLink.bind(core: nil, gameID: game.identifier)
        sharing.soulLink.bind(core: core, gameID: game.identifier)
        sharing.soulLink.setConnection(owner: state.identity.owner.uuidString, room: state.identity.roomID)
        try sharing.soulLink.startPreparedRun(run: state.identity.run)
        manifest = try store.manifest(gameID: game.identifier); head = package; serverUploaded = package?.payload.checkpoint
        independentServerHead = upload?.receipt.checkpoint; serverRegisteredRun = state.identity.run
        serverProfile = profile; selectedRoom = state.identity.roomID; peerOwner = state.identity.partner
        setup = .init(identity: state.identity, accepted: true, settingsCommitted: true, serverEpoch: state.epoch, serverCommitted: true)
        error = nil; pendingSnapshot = nil; didRestore = true; protectedStorage = true; workingStateAuthorized = true
        sharedServerCursor = .init(); journalReplayNeeded = true; soulExportCache.reset(); worldProjectionRun = nil
        serverStarting = package == nil; host.externalSetup = serverStarting; host.playerProfile = profile
        nextAutomaticSave = now; serverCapturePending = package == nil; serverPollAt = 0
        host.setupCommitted = true; host.linked = true; host.run = state.identity.run
        host.settings = state.identity.settings; host.localSeed = state.identity.localSeed; host.partnerSeed = state.identity.partnerSeed
        host.enabled = BoundMultiplayerFeatures.isEnabled; host.recovery = manifest?.requiresInitialHistorySync == true
        host.status = .complete; host.message = ""; probe.publish(host)
        _ = onboarding.selectMultiplayerPartner(roomID: state.identity.roomID, sharing: sharing, existing: { [weak self] in self?.account.session })
        // Server history is reconciled before releasing restored gameplay.
        if manifest?.requiresInitialHistorySync == true {
            while manifest?.requiresInitialHistorySync == true {
                let ack = try store.sharedEventAcknowledgement(gameID: game.identifier)
                let history = try await server.sharedEvents(identity: state.identity, events: [], cursor: ack.cursor)
                guard selection == serverSelection, session.isSameSession(as: account.session) else { throw CancellationError() }
                for event in history.events {
                    _ = try store.receiveAuthoritativeSharedEvent(gameID: game.identifier, event: event)
                    sharedServerCursor.insert(event.id)
                }
                journalReplayNeeded = true; try journalSoulEvents()
                let journal = try store.journal(gameID: game.identifier)
                if journal.received.covers(state.serverCursor), journal.applied.covers(state.serverCursor) {
                    manifest = try store.completeInitialHistorySync(gameID: game.identifier)
                } else if history.events.isEmpty { throw BoundMultiplayerSaveStore.Failure.incomplete }
            }
        }
        if package != nil { try sharing.soulLink.probe.prepareRestoredState(core) }
        sharing.nativeBattle.bind(core: core, gameID: game.identifier, interactions: sharing.interactions)
        sharing.cooperativeDoubles.bind(core: core, gameID: game.identifier, soul: sharing.soulLink.probe)
        host.recovery = false; probe.publish(host)
        if servicesActive, UIApplication.shared.applicationState == .active { core.resume() }
        if !serverStarting { serverMenuBusy = false; needsServerMenu = false }
    }
    @discardableResult
    private func captureServerCheckpoint(final: Bool = false) throws -> BoundMultiplayerSavePackage? {
        guard serverOnly, let manifest, let game, let core, workingStateAuthorized, !serverStarting,
              !manifest.requiresInitialHistorySync, core.state == .paused || core.state == .running else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        if !final, snapshotTask != nil || head?.payload.checkpoint != serverUploaded {
            serverCapturePending = true
            if let head { uploadSnapshotInBackground(head) }
            return nil
        }
        let wasRunning = core.state == .running
        guard core.state == .paused || core.pause() else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        let state: Data, battery: Data, memory: [String: Data], history: String
        // Recheck the cartridge's completed frame after stopping the core: a
        // dialogue can begin between the timer's observation and this pause.
        // Explicit suspension still captures the full interrupted state.
        if !final, !sharing.nativeBattle.blocksAutoSave, !sharing.cooperativeDoubles.blocksAutoSave,
           BoundROMRequest.decode(BoundVBABattleBridge.romMultiplayerSnapshot())?.permitsAutomaticFieldSave != true {
            serverCapturePending = true
            if wasRunning, UIApplication.shared.applicationState == .active { core.resume() }
            return nil
        }
        do {
            // A temporary battle's emulator RAM is never the world save. Its
            // recovery cut travels beside the last safe world snapshot instead.
            if sharing.nativeBattle.blocksAutoSave || sharing.cooperativeDoubles.blocksAutoSave {
                guard let safe = head, let savedState = safe.payload.files["checkpoint.state"]?.data,
                      let savedBattery = safe.payload.files["game.sav"]?.data else { throw BoundMultiplayerSaveStore.Failure.incomplete }
                state = savedState; battery = savedBattery
            } else {
                state = BoundVBABattleBridge.captureServerState(); battery = BoundVBABattleBridge.captureServerBattery()
            }
            try journalSoulEvents()
            if let world = sharing.sharedWorld.probe.read() { try persistWorldSnapshot(world) }
            memory = BoundServerMemoryFiles.snapshot(gameID: game.identifier)
            history = try historyDigest() ?? BoundMultiplayerSaveStore.hash(BoundMultiplayerSaveStore.encode(store.sharedEventAcknowledgement(gameID: game.identifier).cursor))
        } catch {
            if wasRunning, UIApplication.shared.applicationState == .active { core.resume() }; throw error
        }
        if wasRunning, UIApplication.shared.applicationState == .active { core.resume() }
        guard !state.isEmpty, battery.count == 131072 else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        let files = ["checkpoint.state": state, "game.sav": battery, "memory-files.json": try JSONEncoder().encode(memory)]
        let package = try store.captureServerCheckpoint(gameID: game.identifier, files: files, history: history)
        if !final {
            head = package; serverCapturePending = false; nextAutomaticSave = now + 15
            host.status = .waiting; host.message = "Saving to server..."
            uploadSnapshotInBackground(package)
        }
        return package
    }
    func nativeServerSaveRequested() {
        guard serverOnly else { return }
        serverCapturePending = true
    }
    private func isServerConflict(_ error: Error) -> Bool {
        if case BoundNakamaRunService.Failure.conflict = error { return true }
        if case BoundMultiplayerSaveStore.Failure.conflict = error { return true }
        if case BoundMultiplayerSaveStore.Failure.ownerMismatch = error { return true }
        return false
    }
    private func failServerSession(_ message: String) {
        serverSelection = UUID(); serverActivating = false
        core?.pause(); workingStateAuthorized = false; needsServerMenu = true; serverStarting = false
        snapshotTask?.cancel(); snapshotTask = nil; snapshotOperation = UUID()
        serverTask?.cancel(); serverTask = nil; serverOperation = UUID()
        serverMenuBusy = false; serverMenuError = message; host.recovery = true; host.connected = false
        probe.publish(host)
    }
    private func tickServerSession() {
        guard verified, saveFenceReady, let core, let game else { return }
        host.enabled = BoundMultiplayerFeatures.isEnabled; host.linked = manifest != nil
        defer { probe.publish(host) }
        guard host.enabled, servicesActive, UIApplication.shared.applicationState == .active else {
            host.connected = false
            if !host.enabled { core.pause(); needsServerMenu = true }
            return
        }
        guard !serverActivating else { return }
        guard let identity, let manifest else { host.externalSetup = false; host.setupCommitted = false; return }
        guard account.session?.owner == identity.owner else { failServerSession("Sign in to the account that owns this run."); return }
        let request = probe.read()
        if let request, romFrameClock.observe(request.frame), workingStateAuthorized, !serverStarting {
            failServerSession("Game restarted. Select the server save to resume."); return
        }
        if serverStarting, request?.settingsApplied == true, request?.safeField == true {
            serverStarting = false; host.externalSetup = false; serverMenuBusy = false; needsServerMenu = false
            serverCapturePending = true
        }
        let connected = sharing.connectedRoomID == selectedRoom && !sharing.reconnecting
        if transportWasConnected && !connected { serverCapturePending = true; channel.reset(); peerHello = nil }
        transportWasConnected = connected
        host.connected = connected && channel.fresh(at: now) && peerHello?.run == identity.run
        host.peerCollision = sharing.livePresence.collision(at: now)
        host.recovery = !workingStateAuthorized || manifest.requiresInitialHistorySync
        host.playerProfile = serverProfile
        guard workingStateAuthorized else { return }
        if let request, request.command == .checkpoint {
            switch requestCursor.admit(request.requestID) {
            case .dispatch: host.acknowledgedRequest = request.requestID; serverCapturePending = true
            case .rebase: host.acknowledgedRequest = request.requestID
            case .ignore: break
            }
        } else if let request, [.watch, .battle, .trade, .timeline, .page, .accept, .decline].contains(request.command) {
            do { try handle(request) } catch { serverMenuError = error.localizedDescription }
        } else if let request, request.command != .none, requestCursor.admit(request.requestID) != .ignore {
            // Retired setup commands still release the cartridge's request latch.
            host.acknowledgedRequest = request.requestID
            host.status = .unavailable; host.message = "Manage runs in Bound."
        }
        dispatchPendingAction(request: request, connected: connected, at: now)
        if host.status == .timeline {
            let events = Array(sharing.soulLink.probe.timeline.read().events.reversed())
            timelinePage = min(timelinePage, max(0, (events.count - 1) / 12)); host.page = UInt32(timelinePage)
            host.friends = events.dropFirst(timelinePage * 12).prefix(12).map { .init(room: BoundROMBytes.zero, name: $0.title) }
        } else {
            host.friends = onboarding.rooms.compactMap { room in UUID(uuidString: room.roomID).map { .init(room: $0, name: room.displayName) } }
        }
        if !serverStarting, (request?.permitsAutomaticFieldSave == true || sharing.nativeBattle.blocksAutoSave || sharing.cooperativeDoubles.blocksAutoSave), serverCapturePending || now >= nextAutomaticSave {
            do { try captureServerCheckpoint() } catch { serverMenuError = error.localizedDescription; nextAutomaticSave = now + 3 }
        }
        synchronizeIndependentHistory()
        if let head, head.payload.checkpoint != serverUploaded { uploadSnapshotInBackground(head) }
        if connected, now - lastSent >= 0.5 {
            lastSent = now
            send(.hello, Hello(room: identity.roomID, newGame: false, run: identity.run, checkpoint: head?.payload.checkpoint,
                pending: nil, history: historyDigest(), paused: request?.paused == true, checkpointSafe: request?.checkpointSafe,
                ready: workingStateAuthorized, device: store.deviceID, fence: 0))
        }
        _ = game
    }
}
