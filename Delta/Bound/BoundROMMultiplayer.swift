import Foundation
import CryptoKit
import DeltaCore
import UIKit

/// Data-only interface exported by the integrated cartridge. These offsets are
/// not native Pokémon RAM bindings; the game owns menus and all gameplay gates.
enum BoundROMCommand: UInt32 {
    case none, listFriends, pair, cancel, submitSettings, checkpoint, resume
    case battle, trade, startSoulLink, endSoulLink, watch, timeline, accept, decline
    case recoveryChoice, page, newGameReady
}
enum BoundROMStatus: UInt32 { case idle, waiting, accepted, declined, complete, unavailable, busy, recovery, timeline, invitation }

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
    var safeField: Bool { flags & 1 != 0 }
    var newGame: Bool { flags & 2 != 0 }
    var paused: Bool { flags & 4 != 0 }
    var checkpointSafe: Bool { flags & 64 != 0 }
    static func decode(_ data: Data) -> Self? {
        guard data.count == 256, data.prefix(8) == Data([82,85,82,49,1,0,0,0]),
              let command = BoundROMCommand(rawValue: BoundROMBytes.word(data,12)) else { return nil }
        let sequence = BoundROMBytes.word(data,8)
        guard sequence > 0, sequence & 1 == 0 else { return nil }
        return .init(sequence: sequence, command: command, friendIndex: BoundROMBytes.word(data,16),
            argument: BoundROMBytes.word(data,20), identifier: BoundROMBytes.uuid(data,24),
            settings: data.subdata(in:40..<72), flags: BoundROMBytes.word(data,80),
            frame: BoundROMBytes.word(data,84), requestID: BoundROMBytes.word(data,88))
    }
}

struct BoundROMHostState: Equatable, Sendable {
    struct Friend: Equatable, Sendable { var room: UUID; var name: String; var status: UInt32 = 0 }
    var enabled = false
    var linked = false
    var connected = false
    var chooser = false
    var setupCommitted = false
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
        return data
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
final class BoundROMMultiplayerCoordinator {
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
        var peerReady = false
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
    private var cancelledSetup: UUID?
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
    private var pendingAction: BoundROMCommand?
    private var pendingActionAt: TimeInterval = 0
    private var error: String?
    private let server = BoundNakamaRunService.shared
    private var serverTask: Task<Void, Never>?
    private var serverOperation = UUID()
    private var serverRegisteredRun: UUID?
    private var serverPollAt: TimeInterval = 0
    private var serverUploaded: UUID?
    private var manualSavePending = false
    private var serverCaptureAuthorized: UUID?
    private var serverReservedCheckpoint: UUID?
    private var timelinePage = 0
    private let friendsRefresh = BoundROMFriendsRefresh()
    var watch: (() -> Void)?
    var didRestoreSnapshot: (() -> Void)?
    var didCompleteCheckpoint: (() -> Void)?

    init(sharing: FriendSharingSession, onboarding: FriendOnboarding, account: BoundFriendAccount,
         store: BoundMultiplayerSaveStore = .shared) {
        self.sharing = sharing; self.onboarding = onboarding; self.account = account; self.store = store
        sharing.multiplayerPacketReceiver = { [weak self] in self?.receive($0) }
        let timer = Timer(timeInterval:0.1,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer,forMode:.common); self.timer = timer
    }
    deinit {
        let timer = timer
        BoundMainActorDisposal.enqueue { timer?.invalidate() }
        verification?.cancel(); leaseTask?.cancel(); serverTask?.cancel()
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var identity: BoundMultiplayerRunIdentity? { manifest?.identity ?? setup?.identity ?? incoming?.manifest.identity }
    private var setupURL: URL? { game.map { store.directory(gameID:$0.identifier).appendingPathComponent("setup.json") } }
    var protectsRun: Bool { manifest != nil || setup != nil || error != nil }
    private func updateWorkingStateAuthority() {
        let allowed = !protectedStorage || workingStateAuthorized
        sharing.soulLink.probe.setNativeObservationAllowed(allowed)
        if let game, game.type == .gba {
            saveFenceReady = BoundVBABattleBridge.setROMGameSaveAllowed(allowed, for:game.gameSaveURL)
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
        if let old = self.game { store.setActive(false,gameID:old.identifier) }
        verification?.cancel(); leaseTask?.cancel(); serverTask?.cancel(); leaseTask = nil; grant = nil; validatedFence = nil
        leaseOperation = UUID()
        serverTask?.cancel(); serverTask = nil; serverOperation = UUID()
        serverRegisteredRun = nil; serverUploaded = nil; serverPollAt = 0; manualSavePending = false; serverCaptureAuthorized = nil; serverReservedCheckpoint = nil
        anchorBaselineValidated = false; baselineHistory = nil; historyJournal = nil; romFrameClock.reset(); requestCursor = .init()
        self.core = core; self.game = game; verified = false; probe.configure(core:core)
        servicesActive = core != nil; transportWasConnected = false
        protectedStorage = game.map { store.hasRun(gameID:$0.identifier) } ?? false; lastInboxScanAt = -.infinity
        friendsRefresh.reset()
        host = BoundROMHostState(); channel.reset(); selectedRoom = nil; peerOwner = nil; peerHello = nil
        peerHelloAt = -.infinity; peerFence = 0; reconciled = false; peerCommitted = false
        setup = nil; manifest = nil; incoming = nil; finishedRun = nil; cancelledSetup = nil; checkpoint = nil; localReceipt = nil; partnerReceipt = nil
        checkpointStartedAt = nil; checkpointCaptureAttempted = false; checkpointCancellation = .init(); cancelledCheckpoints = [:]; checkpointRetryAt = 0
        endingRun = false; newGameAfterEnd = false; recoveredNewGameChoice = false
        newGame = false; error = nil; pendingSnapshot = nil; didRestore = false; head = nil
        validatedSnapshot = false; workingStateAuthorized = false
        pendingAction = nil
        sharing.soulLink.cartridgeManagesPause = false
        guard let core, let game, game.type == .gba else { return }
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
            incoming = endingRun ? nil:try store.inspectIncoming(gameID:game.identifier)
            if incoming != nil { finishedRun = nil }
            let replacingEnded = savedManifest?.ended == true && incoming != nil
            if finishedRun == nil, !replacingEnded, let url = setupURL, FileManager.default.fileExists(atPath:url.path) {
                let bytes = try Data(contentsOf:url)
                guard bytes.count <= 16_384 else { throw BoundMultiplayerSaveStore.Failure.corrupt }
                setup = try JSONDecoder().decode(Setup.self,from:bytes)
                guard setup?.identity.valid == true, setup?.identity.gameID == game.identifier else { throw BoundMultiplayerSaveStore.Failure.corrupt }
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
    /// Preserve the exact working game separately from the last two-party
    /// checkpoint. This snapshot never becomes a cloud backup on its own.
    @discardableResult func suspend() -> Bool {
        guard verified, saveFenceReady, workingStateAuthorized, let manifest, manifest.deviceOwner == store.deviceID,
              manifest.identity.owner == account.session?.owner,
              !sharing.nativeBattle.blocksAutoSave && !sharing.cooperativeDoubles.blocksAutoSave,
              pendingSnapshot == nil || didRestore, let core, let game,
              core.state == .running || core.state == .paused else { return false }
        guard core.state == .paused else { return false }
        do {
            let path = store.directory(gameID:game.identifier).appendingPathComponent("suspend.state")
            core.saveSaveState(to:path)
            core.deltaCore.emulatorBridge.saveGameSave(to:game.gameSaveURL)
            try store.captureSuspension(gameID:game.identifier,romSHA256:BoundWorldContract.romSHA256,
                gameSaveURL:game.gameSaveURL,snapshot:Data(contentsOf:path))
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func setServiceActive(_ value: Bool) {
        if !value {
            friendsRefresh.cancel()
            // Owner teardown suspends the run before stopping its friend
            // services. Restore friendly RAM first, while keeping it paused.
            if sharing.nativeBattle.isActive, sharing.nativeBattle.activity == .battle {
                sharing.nativeBattle.cancel(resume:false)
            }
            suspend()
        }
        guard value != servicesActive else { return }
        servicesActive = value; channel.reset(); peerHello = nil; peerHelloAt = -.infinity; reconciled = false
        host.connected = false; probe.publish(host)
    }
    private func cancelSetup() throws {
        guard manifest == nil else { return }
        let cancelled = setup?.identity.run
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
        cancelledSetup = cancelled ?? cancelledSetup
        host.run = cancelledSetup; host.linked = false; host.connected = false; host.setupCommitted = false
        host.recovery = false; host.saving = false; error = nil
        onboarding.setMultiplayerPartner(roomID:nil); host.status = .declined; host.message = ""
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
            guard !sharing.nativeBattle.protectsTemporaryState && !sharing.cooperativeDoubles.blocksAutoSave else { throw BoundMultiplayerSaveStore.Failure.incomplete }
            try store.finishNewGame(gameID:game.identifier,run:identity.run,owner:identity.owner)
            BoundVBABattleBridge.closeSoulLink()
            sharing.soulLink.bind(core:nil,gameID:game.identifier)
            sharing.soulLink.bind(core:core,gameID:game.identifier)
        } else {
            sharing.soulLink.endRun()
            guard sharing.soulLink.ledger?.ended == true else { throw BoundMultiplayerSaveStore.Failure.incomplete }
            try store.endRun(gameID:game.identifier)
        }
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
            selectedRoom = nil; peerOwner = nil; newGame = false; pendingAction = nil
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
        if endingRun && (!startNewGame || newGameAfterEnd) {
            if startNewGame {
                error = nil; host.recovery = false; host.saving = true; host.status = .waiting; leaseRetryAt = 0
            }
            return
        }
        let wasRunning = core?.state == .running
        try restoreFriendlyBattleBeforeSaving(resume:false)
        defer {
            if wasRunning, core?.state == .paused, !sharing.nativeBattle.protectsTemporaryState && !sharing.cooperativeDoubles.blocksAutoSave,
               UIApplication.shared.applicationState == .active { core?.resume() }
        }
        if !startNewGame || workingStateAuthorized {
            guard core?.state == .paused || core?.pause() == true else { throw BoundMultiplayerSaveStore.Failure.incomplete }
            guard suspend() else { throw BoundMultiplayerSaveStore.Failure.incomplete }
        }
        if startNewGame {
            // Cold boot RAM is not an authorized save. Preserve raw stored
            // recovery, including damaged/incomplete files, without capturing it.
            try store.preserveForNewGame(gameID:game.identifier,run:manifest.identity.run,
                owner:manifest.identity.owner,gameSaveURL:game.gameSaveURL)
            newGameAfterEnd = true
        }
        let path = store.directory(gameID:game.identifier).appendingPathComponent("pending-end.json")
        try BoundMultiplayerSaveStore.encode(manifest.identity.run).write(to:path,options:.atomic)
        let file = try FileHandle(forWritingTo:path); defer { try? file.close() }; try file.synchronize()
        endingRun = true; error = nil; host.recovery = false; host.saving = true; host.status = .waiting
        leaseRetryAt = 0
        probe.publish(host)
    }
    private func advanceEndRun() {
        guard endingRun, leaseTask == nil, let grant, grant.isCurrent,
              let session = account.session, now >= leaseRetryAt else { return }
        let operation = UUID(); leaseOperation = operation
        leaseTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.leaseOperation == operation { self.leaseTask = nil } }
            do {
                if let identity = self.identity { try await self.server.end(identity:identity) }
                try await self.leaseClient.end(grant:grant,session:session)
                guard !Task.isCancelled, self.leaseOperation == operation,
                      self.identity?.run == grant.runID, self.account.session?.owner == grant.ownerID else { return }
                self.send(.end,grant.runID); try self.finishRun()
            } catch {
                guard !Task.isCancelled, self.leaseOperation == operation else { return }
                self.leaseRetryAt = self.now + 3
                if error as? BoundRunLeaseError == .runEnded {
                    do { self.send(.end,grant.runID); try self.finishRun() }
                    catch { self.error = error.localizedDescription }
                } else if self.newGameAfterEnd {
                    self.error = "Could not end Soul Link. Retry recovery."
                }
            }
        }
    }
    private func send<T: Encodable>(_ kind: BoundROMPacket.Kind, _ body: T) {
        guard let owner = account.session?.owner, let data = channel.packet(kind,owner:owner,body:body) else { return }
        _ = sharing.sendMultiplayerPacket(data)
    }
    private func selectRoom(_ room: String) {
        cancelledSetup = nil
        if selectedRoom != room {
            channel.reset(); peerOwner = nil; peerHello = nil; peerHelloAt = -.infinity
            peerFence = 0; reconciled = false; transportWasConnected = false
        }
        selectedRoom = room; onboarding.setMultiplayerPartner(roomID:room, userInitiated:true)
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
                  data[20..<32].allSatisfy({ $0 == 0 }) else { return false }
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
        guard channel.admit(packet,at:now) else { return }
        peerOwner = packet.owner
        do {
            switch packet.kind {
            case .hello:
                let hello = try JSONDecoder().decode(Hello.self,from:packet.body)
                guard hello.room == selectedRoom else { return }
                if hello.fence > 0 && hello.fence < peerFence { return }
                peerFence = max(peerFence,hello.fence)
                peerHello = hello; peerHelloAt = now
                reconciled = hello.history != nil && hello.history == historyDigest()
                if newGame, setup == nil, manifest == nil, hello.run != nil, !hello.newGame {
                    host.status = .unavailable; host.message = "Your friend is already in a run."; return
                }
                if let identity, hello.run != nil, hello.run != identity.run { throw BoundMultiplayerSaveStore.Failure.conflict }
                if let manifest, hello.run == manifest.identity.run, hello.checkpoint != head?.payload.checkpoint,
                   checkpoint == nil, !(hello.pending == head?.payload.checkpoint && hello.checkpoint == head?.payload.predecessor) {
                    throw BoundMultiplayerSaveStore.Failure.conflict
                }
                if newGame, hello.newGame, setup == nil, manifest == nil, owner.uuidString < packet.owner.uuidString,
                   let game {
                    let a = UInt32.random(in:1...UInt32.max)
                    var b = UInt32.random(in:1...UInt32.max); while b == a { b = UInt32.random(in:1...UInt32.max) }
                    setup = .init(identity:.init(run:UUID(),gameID:game.identifier,owner:owner,partner:packet.owner,
                        roomID:selectedRoom,settingsOwner:Bool.random() ? owner : packet.owner,settings:Data(),
                        localSeed:a,partnerSeed:b,romSHA256:BoundWorldContract.romSHA256))
                    try persistSetup()
                }
            case .proposal:
                let remote = try JSONDecoder().decode(BoundMultiplayerRunIdentity.self,from:packet.body)
                guard newGame, manifest == nil, remote.valid, remote.owner == packet.owner, remote.partner == owner,
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
                let ack = try JSONDecoder().decode(SetupAck.self,from:packet.body)
                guard let current = setup, current.identity.run == ack.run, setupDigest(current.identity) == ack.digest else { return }
                setup?.accepted = true; try persistSetup()
            case .settings:
                let remote = try JSONDecoder().decode(BoundMultiplayerRunIdentity.self,from:packet.body)
                guard let current = setup, current.accepted, remote.owner == packet.owner,
                      remote.settingsOwner == packet.owner, Self.validSettings(remote.settings) else { return }
                var local = flip(remote); local.gameID = current.identity.gameID
                var a = local, b = current.identity; a.settings = Data(); b.settings = Data()
                guard a == b else { throw BoundMultiplayerSaveStore.Failure.conflict }
                if current.settingsCommitted, current.identity.settings != local.settings { throw BoundMultiplayerSaveStore.Failure.conflict }
                setup?.identity = local; setup?.settingsCommitted = true; try persistSetup()
            case .ready:
                let ack = try JSONDecoder().decode(SetupAck.self,from:packet.body)
                guard let current = setup, current.settingsCommitted, ack.run == current.identity.run,
                      ack.digest == setupDigest(current.identity) else { return }
                setup?.peerReady = true; try persistSetup()
            case .checkpoint, .prepared, .committed, .checkpointCancel:
                // Durable save proposals and receipts come from the authenticated
                // Nakama RPC, never from a replayable peer message.
                break
            case .end:
                let id = try JSONDecoder().decode(UUID.self,from:packet.body)
                if manifest?.identity.run == id { try requestEndRun() }
            case .cancel:
                let id = try JSONDecoder().decode(UUID.self,from:packet.body)
                if setup?.identity.run == id, manifest == nil { try cancelSetup() }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func historyBits(ledger supplied: BoundSoulLedger? = nil) -> Data? {
        guard let identity, let ledger = supplied ?? sharing.soulLink.ledger, ledger.run == identity.run,
              let remote = ledger.partnerAcquisitions else { return nil }
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
    private func installCheckpoint(_ value: Checkpoint) {
        if checkpoint?.id != value.id {
            checkpointStartedAt = now; checkpointCaptureAttempted = false; checkpointCancellation = .init()
            serverCaptureAuthorized = nil
        }
        checkpoint = value; host.saving = true; host.status = .waiting
    }
    private static let checkpointRecoveryMessage = "Paired save could not finish. Retry recovery to keep both saves safe."
    private func checkpointRecovery() {
        host.saving = false
        if error == nil { error = Self.checkpointRecoveryMessage }
    }
    private func cancelCheckpoint() {
        guard let checkpoint, let identity = manifest?.identity, serverTask == nil else { return }
        guard !checkpointHasDurableReceipt else { checkpointRecovery(); return }
        let operation = UUID(); serverOperation = operation
        serverTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.serverOperation == operation { self.serverTask = nil } }
            do {
                let state = try await self.server.cancel(identity:identity,checkpoint:checkpoint.id)
                guard !Task.isCancelled, self.serverOperation == operation, self.identity?.run == identity.run else { return }
                try self.applyServer(state)
            } catch {
                guard self.serverOperation == operation else { return }
                self.checkpointRecovery()
            }
        }
    }
    private func rememberCheckpointCancellation(_ cancelled: Checkpoint) {
        cancelledCheckpoints[cancelled.id] = cancelled
        // Nonce/sequence admission rejects old-channel replays; retain recent
        // transaction IDs for retransmissions inside this channel as well.
        if cancelledCheckpoints.count > 64, let old = cancelledCheckpoints.keys.first(where: { $0 != cancelled.id }) {
            cancelledCheckpoints.removeValue(forKey:old)
        }
    }
    private func finishCheckpointCancellation(_ cancelled: Checkpoint) {
        rememberCheckpointCancellation(cancelled)
        if checkpoint?.id == cancelled.id {
            if error == Self.checkpointRecoveryMessage { error = nil }
            checkpoint = nil; checkpointStartedAt = nil; checkpointCaptureAttempted = false; checkpointCancellation = .init()
            host.saving = false; host.status = .unavailable
            host.message = "Save deferred. Both players must be free to move."
            checkpointRetryAt = now + 10
        }
    }
    /// Only an explicit cartridge Save action starts this server transaction.
    @discardableResult private func requestCheckpoint() -> Bool {
        if checkpoint == nil, serverTask != nil {
            manualSavePending = true; host.saving = true; return true
        }
        guard checkpoint == nil, serverTask == nil, now >= checkpointRetryAt,
              let manifest, let history = historyDigest(), serverRegisteredRun == manifest.identity.run,
              channel.fresh(at:now), now - peerHelloAt < 3,
              probe.read()?.checkpointSafe == true, peerHello?.checkpointSafe == true,
              !sharing.nativeBattle.blocksAutoSave && !sharing.cooperativeDoubles.blocksAutoSave else { return false }
        let operation = UUID(); serverOperation = operation
        host.saving = true
        serverTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.serverOperation == operation { self.serverTask = nil } }
            do {
                let state = try await self.server.begin(identity:manifest.identity,history:history,predecessor:self.head?.payload.checkpoint)
                guard !Task.isCancelled, self.serverOperation == operation, self.identity?.run == manifest.identity.run else { return }
                try self.applyServer(state)
            } catch {
                guard self.serverOperation == operation else { return }
                self.host.saving = false; self.host.status = .unavailable
                self.host.message = error.localizedDescription; self.checkpointRetryAt = self.now + 3
            }
        }
        return true
    }
    private func applyServer(_ state: BoundNakamaRunService.State) throws {
        guard state.version == 1, let identity else { throw BoundNakamaRunService.Failure.conflict }
        if state.ended { try requestEndRun(); return }
        serverRegisteredRun = nil
        if let saved = state.head, let head, saved.id == head.payload.checkpoint {
            guard saved.history == head.payload.sharedEventDigest,
                  saved.upload(for:identity.owner)?.receipt == head.receipt else { throw BoundNakamaRunService.Failure.conflict }
        }
        if let committed = state.head, committed.id != head?.payload.checkpoint, committed.id != checkpoint?.id {
            guard incoming != nil else { throw BoundNakamaRunService.Failure.conflict }
            return
        }
        if let committed = state.head, committed.id == checkpoint?.id {
            guard let own = committed.upload(for:identity.owner), let peer = committed.upload(for:identity.partner),
                  own.receipt == localReceipt, peer.receipt.sharedEventDigest == checkpoint?.history else {
                throw BoundNakamaRunService.Failure.conflict
            }
            partnerReceipt = peer.receipt; peerCommitted = true; checkpointStartedAt = now
        } else if let pending = state.pending {
            guard pending.predecessor == head?.payload.checkpoint else { throw BoundNakamaRunService.Failure.conflict }
            if checkpoint == nil {
                guard probe.read()?.checkpointSafe == true, !sharing.nativeBattle.blocksAutoSave,
                      !sharing.cooperativeDoubles.blocksAutoSave else {
                    throw BoundMultiplayerSaveStore.Failure.incomplete
                }
                installCheckpoint(.init(id:pending.id,predecessor:pending.predecessor,history:pending.history))
            } else if checkpoint?.id != pending.id { throw BoundNakamaRunService.Failure.conflict }
            else if localReceipt == nil { checkpoint?.history = pending.history }
            if pending.reservations?.isEmpty == false { serverReservedCheckpoint = pending.id }
            if pending.reservations?[identity.owner.uuidString.lowercased()] == true { serverCaptureAuthorized = pending.id }
        } else if let checkpoint, !checkpointHasDurableReceipt {
            finishCheckpointCancellation(checkpoint)
        }
        serverRegisteredRun = identity.run
    }
    private func synchronizeServer() {
        guard serverTask == nil, now >= serverPollAt, let identity = manifest?.identity,
              let history = historyDigest(), let bits = historyBits(), account.session?.owner == identity.owner else { return }
        let operation = UUID(); serverOperation = operation; serverPollAt = now + 1
        let package = checkpoint.flatMap { value in
            localReceipt != nil && serverUploaded != value.id ? try? store.checkpoint(gameID:identity.gameID,id:value.id) : nil
        }
        serverTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.serverOperation == operation { self.serverTask = nil } }
            do {
                let state: BoundNakamaRunService.State
                if let package {
                    state = try await self.server.upload(package)
                } else {
                    state = try await self.server.session(identity:identity,history:history,bits:bits,head:self.head,world:self.sharing.sharedWorld.probe.read())
                }
                guard !Task.isCancelled, self.serverOperation == operation, self.identity?.run == identity.run else { return }
                if let package { self.serverUploaded = package.payload.checkpoint; self.checkpointStartedAt = self.now }
                if let committed = state.head, committed.id != self.head?.payload.checkpoint,
                   self.checkpoint == nil, let grant = self.grant, let session = self.account.session {
                    let restored = try await self.server.download(identity:identity,checkpoint:committed)
                    let renewed = try await self.leaseClient.checkpoint(grant:grant,checkpointID:committed.id,
                        predecessor:committed.predecessor,history:committed.history,session:session)
                    guard !Task.isCancelled, self.serverOperation == operation, self.identity?.run == identity.run else { return }
                    self.grant = renewed
                    let store = self.store
                    let previous = self.head
                    try await Task.detached(priority:.utility) {
                        let folder = try store.stageDownload(gameID:identity.gameID,version:committed.id.uuidString,run:identity.run)
                        // Restore requires the known predecessor inside the
                        // archive, not just a matching predecessor UUID.
                        var chain = [restored]
                        if let previous, restored.payload.predecessor == previous.payload.checkpoint { chain.append(previous) }
                        let archive = BoundMultiplayerSaveStore.CloudArchive(checkpoints:chain)
                        try BoundMultiplayerSaveStore.encode(archive).write(to:folder.appendingPathComponent("complete.boundrun"),options:.atomic)
                    }.value
                    guard !Task.isCancelled, self.serverOperation == operation else { return }
                    self.incoming = try self.store.inspectIncoming(gameID:identity.gameID)
                }
                try self.applyServer(state)
            } catch {
                guard !Task.isCancelled, self.serverOperation == operation else { return }
                self.serverPollAt = self.now + 3
                if self.localReceipt != nil {
                    self.host.message = "Waiting for server save. Reconnect to retry."
                    self.checkpointStartedAt = self.now
                }
            }
        }
    }
    private func advanceCheckpoint(_ request: BoundROMRequest?) throws {
        guard var checkpoint, let manifest, let game, let core else { return }
        if checkpointStartedAt == nil { checkpointStartedAt = now }
        if localReceipt != nil, serverTask != nil { checkpointStartedAt = now }
        let peerSafe = now - peerHelloAt < 3 ? peerHello?.checkpointSafe : nil
        switch checkpointCancellation.action(at:now,startedAt:checkpointStartedAt!,
            localSafe:request?.checkpointSafe == true && !sharing.nativeBattle.blocksAutoSave && !sharing.cooperativeDoubles.blocksAutoSave,
            peerSafe:peerSafe,durable:checkpointHasDurableReceipt) {
        case .request: cancelCheckpoint(); return
        case .recover: checkpointRecovery(); return
        default: break
        }
        guard checkpointCancellation.requestedAt == nil, grant?.isCurrent == true else { return }
        host.saving = true
        let history = historyDigest()
        // The server selects the common history before either package is uploaded.
        checkpoint = self.checkpoint ?? checkpoint
        let stage = peerCommitted && localReceipt != nil && partnerReceipt != nil ? BoundROMCheckpointStage.finish : BoundROMCheckpointReadiness.stage(localStored:localReceipt != nil,partnerStored:partnerReceipt != nil,
            peerCommitted:peerCommitted,localPaused:request?.paused == true,peerPaused:peerHello?.paused == true,
            peerPendingMatches:peerHello?.pending == checkpoint.id,
            historyMatches:history == checkpoint.history && peerHello?.history == history
                && anchorBaselineValidated && grant?.historyDigest == checkpoint.history,
            fresh:channel.fresh(at:now) && now - peerHelloAt < 3,
            localSafe:request?.checkpointSafe == true && !sharing.nativeBattle.blocksAutoSave && !sharing.cooperativeDoubles.blocksAutoSave,
            peerSafe:peerHello?.checkpointSafe == true)
        guard stage != .wait else { return }
        if stage == .capture {
            // Reserve on the server before touching local files. Otherwise a
            // peer cancellation could race a durable capture not yet uploaded.
            if serverCaptureAuthorized != checkpoint.id {
                guard serverTask == nil else { return }
                let operation = UUID(); serverOperation = operation
                serverTask = Task { [weak self] in
                    guard let self else { return }
                    defer { if self.serverOperation == operation { self.serverTask = nil } }
                    do {
                        let state = try await self.server.prepare(identity:manifest.identity,checkpoint:checkpoint.id,history:checkpoint.history)
                        guard !Task.isCancelled, self.serverOperation == operation, self.checkpoint?.id == checkpoint.id else { return }
                        try self.applyServer(state)
                        self.serverCaptureAuthorized = checkpoint.id; self.checkpointStartedAt = self.now
                    } catch {
                        guard self.serverOperation == operation else { return }
                        self.checkpointRecovery()
                    }
                }
                return
            }
            guard workingStateAuthorized else { return }
            let wasRunning = core.state == .running
            guard core.state == .paused || core.pause() else { throw BoundMultiplayerSaveStore.Failure.incomplete }
            defer { if wasRunning { core.resume() } }
            let path = store.directory(gameID:game.identifier).appendingPathComponent("capture.state")
            core.saveSaveState(to:path)
            let state = try Data(contentsOf:path)
            core.deltaCore.emulatorBridge.saveGameSave(to:game.gameSaveURL)
            var additional = ["checkpoint.state":state]
            if let setup { additional["setup.json"] = try BoundMultiplayerSaveStore.encode(setup) }
            checkpointCaptureAttempted = true
            localReceipt = try store.prepare(gameID:game.identifier,checkpointID:checkpoint.id,
                predecessor:checkpoint.predecessor,sharedEventDigest:checkpoint.history,gameSaveURL:game.gameSaveURL,additionalFiles:additional)
        }
        if let partnerReceipt {
            if head?.payload.checkpoint != checkpoint.id {
                head = try store.commit(gameID:game.identifier,checkpointID:checkpoint.id,partnerReceipt:partnerReceipt)
                didCompleteCheckpoint?()
            }
            if peerCommitted {
                if let localReceipt { send(.committed,localReceipt) }
                self.checkpoint = nil; localReceipt = nil; self.partnerReceipt = nil; peerCommitted = false
                checkpointStartedAt = nil; checkpointCaptureAttempted = false; checkpointCancellation = .init()
                host.saving = false; host.status = .complete; serverUploaded = nil
            }
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
            guard BoundMultiplayerFeatures.isEnabled, newGame, manifest == nil,
                  let room = onboarding.rooms.first(where: { UUID(uuidString:$0.roomID) == request.identifier }) else {
                host.status = .unavailable; host.message = "Start Soul Link from a new game."; return
            }
            if let setup, setup.identity.roomID != room.roomID { throw BoundMultiplayerSaveStore.Failure.conflict }
            selectRoom(room.roomID); host.partnerName = room.displayName; host.status = .waiting
            host.message = "Waiting for friend to catch up. Press B to cancel."
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
            setup = current; try persistSetup()
        case .checkpoint:
            if requestCheckpoint() { host.status = .waiting }
            else if checkpoint == nil {
                host.status = .unavailable; host.message = "Save deferred. Both players must be free to move."
            }
        case .resume: host.status = .waiting
        case .watch, .battle, .trade:
            guard let room = onboarding.rooms.first(where: { UUID(uuidString:$0.roomID) == request.identifier }),
                  identity == nil || identity?.roomID == room.roomID else {
                host.status = .unavailable; host.message = "Choose your connected friend."; return
            }
            selectRoom(room.roomID)
            pendingAction = request.command; pendingActionAt = now; host.status = .complete
        case .timeline, .page:
            if request.command == .timeline { timelinePage = 0 }
            else { timelinePage = max(0,timelinePage + (request.argument == 0 ? -1:1)) }
            host.status = .timeline
        case .accept: sharing.interactions.accept()
        case .decline: sharing.interactions.decline()
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
                if checkpointHasDurableReceipt { checkpointCancellation = .init() }
                else if checkpointCancellation.requestedAt != nil { checkpointCancellation = .init(); cancelCheckpoint() }
                leaseRetryAt = 0; ensureLease(); host.status = .waiting
            }
            else if request.argument == 1, let head {
                try selectCompletedCheckpoint(head.payload.checkpoint)
            } else if request.argument == 2 { suspend(); host.message = "Run suspended. You can close the game." }
            else if request.argument == 3 { leaseRetryAt = 0; ensureLease(transfer:true) }
        case .none: break
        }
    }
    /// A raw cartridge reset must never be captured as the working linked run.
    /// Reload only a previously validated local snapshot, after explicit Retry.
    private func recoverAfterCartridgeReset(resetRequests: Bool = false) {
        if resetRequests { requestCursor = .init(); host.acknowledgedRequest = 0; friendsRefresh.reset() }
        workingStateAuthorized = false
        pendingSnapshot = nil; validatedSnapshot = false; didRestore = false
        pendingAction = nil; host.connected = false; host.saving = false
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
        guard let game, let core, let identity, let grant, grant.isCurrent,
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
              !didRestore, anchorBaselineValidated, let pendingSnapshot, let core, let game, grant?.isCurrent == true,
              peerHello?.run == identity?.run, peerHello?.fence ?? 0 > 0,
              now - peerHelloAt < 3, channel.fresh(at:now),
              peerHello?.checkpoint == head?.payload.checkpoint || peerHello?.pending == checkpoint?.id && checkpoint != nil,
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
        guard verified, saveFenceReady, let core, let game else { return }
        let request = probe.read()
        if let request, romFrameClock.observe(request.frame), workingStateAuthorized, manifest != nil {
            recoverAfterCartridgeReset(resetRequests:true)
        }
        host.enabled = BoundMultiplayerFeatures.isEnabled
        host.linked = manifest != nil || incoming != nil || protectedStorage
        host.ended = finishedRun != nil && !host.linked && setup == nil
        sharing.soulLink.cartridgeManagesPause = host.linked
        host.recovery = error != nil
        host.run = identity?.run ?? cancelledSetup ?? finishedRun; host.localSeed = identity?.localSeed ?? 0; host.partnerSeed = identity?.partnerSeed ?? 0
        if let identity, identity.settings.count == 32 { host.settings = identity.settings }
        host.chooser = setup?.accepted == true && setup?.identity.settingsOwner == account.session?.owner
        if setup?.accepted == true, manifest == nil, error == nil { host.status = .accepted }
        host.setupCommitted = manifest != nil
        let transportConnected = sharing.connectedRoomID == selectedRoom && selectedRoom != nil && !sharing.reconnecting
        if transportWasConnected && !transportConnected {
            channel.reset(); peerHello = nil; peerHelloAt = -.infinity; reconciled = false
        }
        transportWasConnected = transportConnected
        host.connected = host.enabled && servicesActive && UIApplication.shared.applicationState == .active
            && transportConnected && channel.fresh(at:now) && anchorsReady && error == nil
            && peerHello?.run == identity?.run && (peerHello?.fence ?? 0) > 0 && now - peerHelloAt < 3
            && peerHello?.ready == true
            && (manifest == nil || sharing.soulLink.paired && reconciled && peerHello?.history == historyDigest())
            && (manifest == nil || workingStateAuthorized && serverRegisteredRun == identity?.run)
            && peerHello?.checkpoint == head?.payload.checkpoint
            && (peerHello?.pending == nil || peerHello?.pending.map { cancelledCheckpoints[$0] != nil } == true) && checkpoint == nil
        if !channel.fresh(at:now) { reconciled = false }
        defer {
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
            if let request { try handle(request) }
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
            if host.enabled { ensureLease() }
            try restoreIncomingIfReady()
            if let current = setup, current.settingsCommitted, current.peerReady, manifest == nil,
               newGame, request?.newGame == true, grant?.isCurrent == true {
                try store.begin(current.identity,gameSaveURL:game.gameSaveURL)
                try persistSetup()
                manifest = try store.validateForResume(gameID:game.identifier,owner:current.identity.owner,romSHA256:BoundWorldContract.romSHA256)
                try sharing.soulLink.startPreparedRun(run:current.identity.run)
                protectedStorage = true
                workingStateAuthorized = true
                newGame = false
                baselineHistory = nil; anchorBaselineValidated = false; historyJournal = nil
                store.setActive(true,gameID:game.identifier); host.status = .complete
            }
            if let manifest, let grant, grant.isCurrent {
                guard workingStateAuthorized || pendingSnapshot != nil else {
                    throw BoundMultiplayerSaveStore.Failure.incomplete
                }
                if validatedFence != grant.fence {
                    self.manifest = try store.validateForResume(gameID:game.identifier,owner:manifest.identity.owner,romSHA256:BoundWorldContract.romSHA256)
                    validatedFence = grant.fence
                }
                store.setActive(true,gameID:game.identifier)
                try validateAnchorBaseline(grant)
                try restoreSnapshotIfNeeded()
                if sharing.soulLink.ledger == nil { try sharing.soulLink.startPreparedRun(run:manifest.identity.run) }
            }
            if let action = pendingAction, request?.safeField == true, request?.paused == false {
                if now - pendingActionAt > 15 {
                    pendingAction = nil
                    sharing.interactions.activityEnded(action == .watch ? "Friend video is unavailable." : "Stand beside your friend and face them.")
                }
                else if sharing.connectedRoomID == selectedRoom {
                    if action == .watch { watch?(); if sharing.watchingPartner { pendingAction = nil } }
                    else if sharing.interactions.open() {
                        sharing.interactions.request(action == .battle ? .battle:.trade); pendingAction = nil
                    }
                }
            }
            if manualSavePending, serverTask == nil {
                manualSavePending = false
                if !requestCheckpoint() { host.saving = false; host.status = .unavailable }
            }
            synchronizeServer()
            try advanceCheckpoint(request)
            try synchronizeAnchors()
        } catch { self.error = error.localizedDescription }
        if let error {
            host.connected = false; host.recovery = true; host.status = .recovery; host.message = error
        } else if host.saving { host.message = "Saving both players..." }
        if !host.enabled { host.connected = false; return }
        if now - lastSent >= 0.5, let selectedRoom, sharing.connectedRoomID == selectedRoom,
           let device = try? BoundMultiplayerDeviceIdentity.current() {
            lastSent = now
            send(.hello,Hello(room:selectedRoom,newGame:newGame && manifest == nil && incoming == nil,run:identity?.run,checkpoint:head?.payload.checkpoint,
                pending:checkpoint?.id,history:historyDigest(),paused:request?.paused == true,
                checkpointSafe:request?.checkpointSafe == true,ready:anchorsReady && error == nil && !host.transferRequired && (manifest == nil || workingStateAuthorized),
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
