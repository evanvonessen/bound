import Foundation
import Combine
import UIKit
import QuartzCore

/// Captured-resource cleanup avoids the isolated-deinit backdeployment trampoline.
/// Registration can happen on any thread; resource access happens only on MainActor.
/// Draining before RTC creation prevents an old same-turn disposal destroying a
/// replacement singleton. Owners must still stop a running session before replacement.
final class BoundMainActorDisposal: @unchecked Sendable {
    private static let queue = BoundMainActorDisposal()
    private let lock = NSLock()
    private var actions: [@MainActor () -> Void] = []
    @MainActor private static var draining = false
    static func enqueue(_ action: @escaping @MainActor () -> Void) {
        queue.lock.lock(); queue.actions.append(action); queue.lock.unlock()
        Task { @MainActor in drainPending() }
    }
    @MainActor static func drainPending() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while true {
            queue.lock.lock()
            let pending = queue.actions; queue.actions.removeAll(keepingCapacity: true)
            queue.lock.unlock()
            guard !pending.isEmpty else { return }
            pending.forEach { $0() }
        }
    }
}

/// Optional diagnostic I/O has one pending value per kind. Slow console/disk
/// consumers cannot grow a queue or block display and SDK callback owners.
private final class FriendSharingDiagnosticOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Bound sharing diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pendingLog: String?
    private var pendingFile: (Data, URL)?
    private var running = false
    func submit(log: String? = nil, file: (Data, URL)? = nil) {
        lock.lock()
        if let log { pendingLog = log }
        if let file { pendingFile = file }
        let start = !running; running = true
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                let log = pendingLog, file = pendingFile
                pendingLog = nil; pendingFile = nil
                guard log != nil || file != nil else { running = false; lock.unlock(); return }
                lock.unlock()
                if let log { NSLog("%@", log) }
                if let file { try? file.0.write(to: file.1, options: .atomic) }
            }
        }
    }
}

/// Agora 4.6.4 supports 30 fps sending on iOS; presentation follows the display.
enum FriendSharingCadence {
    static let framesPerSecond = 30
    static let interval: TimeInterval = 1.0 / Double(framesPerSecond)
    static let presentationFramesPerSecond = 60
}

/// Only elapsed time between source events may leave the app. This origin belongs
/// to the SDK transport lifetime, not the shorter pause/recovery publication run.
struct FriendSharingCaptureClock {
    private var origin: TimeInterval?
    private var previousReading: TimeInterval?
    private var previousCapture: TimeInterval?

    mutating func capture(at reading: TimeInterval) throws -> TimeInterval {
        guard reading.isFinite, reading >= 0,
              previousReading.map({ reading >= $0 }) ?? true else {
            throw SharingFrameError.invalidCaptureTime
        }
        let elapsed = reading - (origin ?? reading)
        // Several source events can share a clock reading. Keep strict source
        // ordering without adding a millisecond for every coalesced source frame.
        let capture = previousCapture.map { max(elapsed, $0.nextUp) } ?? elapsed
        guard capture.isFinite else { throw SharingFrameError.invalidCaptureTime }
        origin = origin ?? reading
        previousReading = reading
        previousCapture = capture
        return capture
    }
}

/// Elapsed-time gates do not double telemetry work when presentation moves to 60 Hz,
/// and a delayed display callback never drains a backlog of counter updates.
struct FriendSharingReceiveCadence {
    private var statisticsAt: TimeInterval?
    private var evidenceAt: TimeInterval?
    mutating func tick(at time: TimeInterval) -> (statistics: Bool, evidence: Bool) {
        let statistics = statisticsAt.map { time - $0 + 1e-9 >= 0.1 } ?? true
        let evidence = evidenceAt.map { time - $0 + 1e-9 >= 1 } ?? false
        if statistics { statisticsAt = time }
        if evidenceAt == nil || evidence { evidenceAt = time }
        return (statistics, evidence)
    }
}

@MainActor
final class FriendSharingDisplayLink: SharingCancellation {
    @MainActor private final class Target: NSObject {
        weak var owner: FriendSharingDisplayLink?
        @objc func tick(_ link: CADisplayLink) { owner?.action?(link.timestamp) }
    }
    private var link: CADisplayLink?
    private var action: (@MainActor (TimeInterval) -> Void)?
    init(action: @escaping @MainActor (TimeInterval) -> Void) {
        self.action = action
        let target = Target()
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        self.link = link; target.owner = self
        link.preferredFramesPerSecond = FriendSharingCadence.presentationFramesPerSecond
        link.add(to: .main, forMode: .common)
    }
    func cancel() { BoundMainActorDisposal.drainPending(); link?.invalidate(); link = nil; action = nil }
    deinit {
        let link = link
        // Explicit resource transfer avoids isolated-deinit backdeployment on older runtimes.
        BoundMainActorDisposal.enqueue { link?.invalidate() }
    }
}

@MainActor
final class FriendSharingTimer: SharingCancellation {
    private var timer: Timer?
    private var action: (@MainActor () -> Void)?

    init(after delay: TimeInterval, repeating: Bool = false, action: @escaping @MainActor () -> Void) {
        self.action = action
        timer = Timer(timeInterval: max(0.001, delay), repeats: repeating) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let callback = self.action
                if !repeating { self.cancel() }
                callback?()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func cancel() { BoundMainActorDisposal.drainPending(); timer?.invalidate(); timer = nil; action = nil }

    deinit {
        let timer = timer
        BoundMainActorDisposal.enqueue { timer?.invalidate() }
    }
}

@MainActor
final class FriendSharingScheduler: SharingScheduler {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func schedule(at deadline: TimeInterval, action: @escaping @MainActor () -> Void) -> any SharingCancellation {
        FriendSharingTimer(after: max(0, deadline - now), action: action)
    }
}

@MainActor
struct FriendSharingFrameTiming {
    let received: TimeInterval?
    let converted: TimeInterval?
    let presented: TimeInterval?
    let published: TimeInterval?
}

@MainActor
protocol FriendSharingTransport: SharingTransport {
    var videoPublishing: Bool { get }
    var presenceConnectionCheck: BoundPresenceTransportCheck { get }
    func setPresenceReceiver(_ receiver: (@MainActor (Data) -> Void)?)
    func setRetainedPresenceReceiver(_ receiver: (@MainActor (Data, TimeInterval) -> Void)?)
    func sendPresence(_ data: Data) -> Bool
    func pollPresence()
    func setInteractionReceiver(_ receiver: (@MainActor (Data?) -> Void)?)
    func sendInteraction(_ data: Data) -> Bool
    func pollInteractions()
    func makeBattleChannel(receiver: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable () -> Void) -> (any BoundBattleChannel)?
    var publishedFrames: Int { get }
    var receivedFrames: Int { get }
    var diagnostics: [String: Any] { get }
    var frameTiming: FriendSharingFrameTiming? { get }
    func start(configuration: FriendSharingConfiguration, remoteView: UIView,
               event: @escaping @MainActor (FriendSharingEvent) -> Void)
    func stop()
    func clearPresentation()
    func presentLatestFrame()
    func renewToken(_ token: String) -> Bool
    func recordRecoveryTimeout()
}

extension FriendSharingTransport {
    var videoPublishing: Bool { true }
    var presenceConnectionCheck: BoundPresenceTransportCheck { .init() }
    func setPresenceReceiver(_ receiver: (@MainActor (Data) -> Void)?) {}
    func setRetainedPresenceReceiver(_ receiver: (@MainActor (Data, TimeInterval) -> Void)?) {}
    func sendPresence(_ data: Data) -> Bool { false }
    func pollPresence() {}
    func setInteractionReceiver(_ receiver: (@MainActor (Data?) -> Void)?) {}
    func sendInteraction(_ data: Data) -> Bool { false }
    func pollInteractions() {}
    func makeBattleChannel(receiver: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable () -> Void) -> (any BoundBattleChannel)? { nil }
    var diagnostics: [String: Any] { [:] }
    var frameTiming: FriendSharingFrameTiming? { nil }
    func clearPresentation() {}
    func presentLatestFrame() {}
    func renewToken(_ token: String) -> Bool { false }
    func recordRecoveryTimeout() {}
}

@MainActor
final class FriendSharingSession: ObservableObject {
    // Independent RTC lifetime: gameplay reconnects and manual pauses cannot
    // replace its token, channel, capture queue or remote canvas.
    private let mediaOnly: Bool
    private var mediaSession: FriendSharingSession?
    private var mediaObservation: AnyCancellable?
    var screenSharing: FriendSharingSession {
        if mediaOnly || (!authenticatedMode && configuration != nil) { return self }
        if let mediaSession { return mediaSession }
        let session = FriendSharingSession(configuration: nil, transport: AgoraSharingTransport(),
            authenticatedMode: true, mediaOnly: true)
        attachScreenSharing(session)
        return session
    }
    private func attachScreenSharing(_ session: FriendSharingSession) {
        mediaSession = session
        mediaObservation = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        session.setRemotePresentationEnabled(remotePresentationEnabled)
    }
    @Published private(set) var connectionFailed = false
    let connectionFeed: BoundConnectionFeed
    let livePresence = BoundLivePresenceSession()
    let interactions = BoundFriendInteractionSession()
    let nativeBattle = BoundNativeBattleSession()
    let cooperativeDoubles = BoundCooperativeDoublesSession()
    let soulLink = BoundSoulSession()
    let sharedWorld = BoundSharedProgression()
    private let diagnosticOutput = FriendSharingDiagnosticOutput()
    @Published private(set) var status = "Friend screen"
    @Published private(set) var active = false
    @Published private(set) var joined = false
    @Published private(set) var peerConnected = false
    @Published private(set) var reconnecting = false
    @Published private(set) var videoPublishing = false
    // Numeric counters feed diagnostics, not the production companion UI.
    private(set) var receivedFrames = 0
    private(set) var publishedFrames = 0
    @Published private(set) var remoteVisible = false
    private(set) var configuration: FriendSharingConfiguration?
    private(set) var authenticatedMode: Bool
    private var roomProvider: () -> String?
    private let tokenFetcher: @MainActor (String, AppCloudSession) async throws -> FriendSharingTokenLease
    private let nakamaFetcher: @MainActor (String, AppCloudSession) async throws -> BoundNakamaConfiguration
    private var debugRealtimeScope: BoundDebugRealtimeScope?
    private var debugRealtimeProvider: (@MainActor (String, AppCloudSession) async throws -> BoundNakamaConfiguration)?
    private var debugRealtimeRevision = UUID()
    private var debugRealtimeAttempts = 0
    private var debugSwitchPending = false
    private var debugActivityAdmission: BoundDebugAdmission?
    private var debugAdmissionDeadline: (any SharingCancellation)?
    private var debugContinuingNative = false, debugContinuingCooperative = false
    private var debugActivitiesAllowed: Bool {
        guard !debugSwitchPending else { return false }
        guard let scope = debugRealtimeScope else { return true }
        guard let admission = debugActivityAdmission else { return false }
        return admission.sessionID == scope.sessionID && admission.membershipEpoch == scope.membershipEpoch
            && admission.generation == scope.generation && admission.manifestDigest == scope.manifestDigest
            && admission.expiresAt > Date().timeIntervalSince1970
    }
    func setDebugSwitchPending(_ pending: Bool) {
        if pending && !debugSwitchPending {
            debugContinuingNative = nativeBattle.isActive
            debugContinuingCooperative = cooperativeDoubles.isActive
        }
        debugSwitchPending = pending; interactions.refreshInputGate()
    }
    func setDebugActivityAdmission(_ admission: BoundDebugAdmission?) {
        if debugActivityAdmission != nil, admission == nil {
            debugContinuingNative = nativeBattle.isActive
            debugContinuingCooperative = cooperativeDoubles.isActive
        }
        debugActivityAdmission = admission
        debugAdmissionDeadline?.cancel(); debugAdmissionDeadline = nil
        if let admission {
            let revision = debugRealtimeRevision
            debugAdmissionDeadline = scheduler.schedule(at: scheduler.now + max(0, admission.expiresAt - Date().timeIntervalSince1970)) { [weak self] in
                guard let self, self.debugRealtimeRevision == revision, self.debugActivityAdmission == admission else { return }
                self.setDebugActivityAdmission(nil)
            }
        }
        interactions.refreshInputGate()
    }

    /// A scope without a provider is an explicit fence, never ordinary-room
    /// authorization. Clearing the scope is reserved for ordinary return.
    func setDebugRealtimeProvider(scope: BoundDebugRealtimeScope?,
        provider: (@MainActor (String, AppCloudSession) async throws -> BoundNakamaConfiguration)?) {
        let changed = debugRealtimeScope != scope || (debugRealtimeProvider == nil) != (provider == nil)
        if debugRealtimeScope != scope {
            debugActivityAdmission = nil; debugAdmissionDeadline?.cancel(); debugAdmissionDeadline = nil
            debugContinuingNative = false; debugContinuingCooperative = false
        }
        debugRealtimeScope = scope; debugRealtimeProvider = provider
        guard changed else { return }
        debugRealtimeRevision = UUID(); debugRealtimeAttempts = 0
        tokenTask?.cancel(); tokenTask = nil; tokenDeadline?.cancel(); tokenDeadline = nil
        guard let nakama = transport as? BoundNakamaSharingTransport else { return }
        nakama.suspendGameplay(fenced: scope != nil)
        guard active else { return }
        joined = false; peerConnected = false; reconnecting = true
        recoveryDeadline?.cancel(); recoveryDeadline = nil; recoveryID = nil
        sharedWorld.peerGone(); soulLink.peerGone(); interactions.suspend()
        nativeBattle.suspendTransport(); cooperativeDoubles.transportInterrupted()
        livePresence.stop(keepPresentation: true)
        // A withheld provider may remain fenced indefinitely without a retry
        // spinning against the ordinary authorization endpoint.
        if scope != nil && provider == nil { tokenExpiry = nil; status = "Waiting for DEBUG session"; return }
        requestNakamaToken(initial: true)
    }
    var isConfigured: Bool { authenticatedMode || configuration != nil }
    var authenticatedSession: (() -> AppCloudSession?)?
    var multiplayerPacketReceiver: ((Data) -> Void)?
    var connectedRoomID: String? { active ? authRoom : nil }
    var connectionRequested: Bool { active || foregroundReconnectIntent != nil }
    var configuredRoomID: String? { authenticatedMode ? roomProvider() : nil }
    private var automaticMultiplayerConnection = false
    private var startedForMultiplayer = false
    private var tokenTask: Task<Void, Never>?
    private var tokenDeadline: (any SharingCancellation)?
    private var tokenOwner: UUID?
    private var reconnectPeerOwner: UUID?
    private var authRoom: String?
    private var tokenExpiry: TimeInterval?
    private var tokenRenewals = 0
    let remoteView = UIView()
    private var videoFrameCount = 0
    private var videoLastFrame: TimeInterval?
    private var lastConvertedFrame: TimeInterval?

    private func invalidateRemoteVideo() {
        videoLastFrame = nil
        videoFrameCount = transport.receivedFrames
        lastConvertedFrame = transport.frameTiming?.converted
        remoteVisible = false
    }

    func updateVideoFreshness(received: Int, now: () -> TimeInterval = CACurrentMediaTime) {
        // Decoding can finish after the display link's frame timestamp. Sample
        // host time after the timing snapshot so a new frame cannot look stale.
        let timing = transport.frameTiming
        let timestamp = now()
        if let timing {
            // SDK arrival counts include invalid/busy conversions. Only a new,
            // detached pixel frame may refresh the production Live indicator.
            if let converted = timing.converted, converted != lastConvertedFrame {
                lastConvertedFrame = converted
                videoLastFrame = converted
            }
        } else if received != videoFrameCount {
            // Deterministic transports without SDK timing report decoded frames.
            videoLastFrame = received > 0 ? timestamp : nil
        }
        videoFrameCount = received
        let fresh = joined && !reconnecting && videoLastFrame.map {
            timestamp >= $0 && timestamp - $0 < 3
        } == true
        if remoteVisible != (remotePresentationEnabled && fresh) { remoteVisible = remotePresentationEnabled && fresh }
        guard active else { return }
        if reconnecting { status = "Reconnecting…" }
        else if joined {
            status = transport is BoundNakamaSharingTransport && !videoPublishing
                ? "Multiplayer connected" : fresh ? "Receiving game video" : "Waiting for fresh friend video"
        }
    }

    private let transport: any FriendSharingTransport
    private let sharing: SharingSession
    private let scheduler: any SharingScheduler
    private var recoveryDeadline: (any SharingCancellation)?
    private var recoveryID: UUID?
    private var recoveryAttempts = 0
    private var recoveryCompletions = 0
    private var recoveryTimeouts = 0
    private var receiverDisplayLink: FriendSharingDisplayLink?
    private var remotePresentationEnabled = true
    func setRemotePresentationEnabled(_ enabled: Bool) {
        remotePresentationEnabled = enabled; mediaSession?.setRemotePresentationEnabled(enabled)
        if !enabled { transport.clearPresentation(); remoteVisible = false }
    }
    private var sequence: UInt64 = 0
    private var captureClock = FriendSharingCaptureClock()
    private var publicationToken: SharingSessionToken?
    private var sourceFrameNumber: UInt64 = 0
    private var sourceButtons: UInt32 = 0
    private var sourceFramesAccepted = 0
    private var receiverCadence = FriendSharingReceiveCadence()
    private var lastDisplayTick: TimeInterval?
    private var largestDisplayGap: TimeInterval = 0
    private var generation = UUID()
    private var backgrounded = false
    private let applicationIsBackgrounded: () -> Bool
    private struct ForegroundReconnectIntent: Equatable {
        let room: String
        let owner: UUID
    }
    private var featureObservers: [NSObjectProtocol] = []
    private var pausedMultiplayerScope: ForegroundReconnectIntent?
    private var foregroundReconnectIntent: ForegroundReconnectIntent?
    private var foregroundReconnectRetry: (any SharingCancellation)?
    private var foregroundReconnectAttempts = 0

    init(configuration: FriendSharingConfiguration? = .load(), transport: (any FriendSharingTransport)? = nil,
         scheduler: (any SharingScheduler)? = nil,
         authenticatedMode: Bool = FriendSharingConfiguration.authenticationRequested,
         mediaOnly: Bool = false,
         roomProvider: @escaping () -> String? = { FriendSharingTokens.room() },
         tokenFetcher: @escaping @MainActor (String, AppCloudSession) async throws -> FriendSharingTokenLease = { try await FriendSharingTokens.fetch(room: $0, session: $1) },
         nakamaFetcher: @escaping @MainActor (String, AppCloudSession) async throws -> BoundNakamaConfiguration = { try await BoundNakamaAuthorization.fetch(room: $0, session: $1) },
         connectionFeed: BoundConnectionFeed? = nil,
         screenSession: FriendSharingSession? = nil,
         applicationIsBackgrounded: @escaping () -> Bool = { UIApplication.shared.applicationState == .background }) {
        self.mediaOnly = mediaOnly
        // No surface is mounted in Account settings. Only the multiview owner
        // enables presentation; temporary local QA transports retain their canvas.
        self.remotePresentationEnabled = !authenticatedMode && configuration != nil && !mediaOnly
        self.connectionFeed = connectionFeed ?? BoundConnectionFeed()
        self.applicationIsBackgrounded = applicationIsBackgrounded
        self.authenticatedMode = authenticatedMode
        self.roomProvider = roomProvider; self.tokenFetcher = tokenFetcher
        self.nakamaFetcher = nakamaFetcher
        self.configuration = authenticatedMode ? nil : configuration
        let resolvedTransport: any FriendSharingTransport
        if let supplied = transport { resolvedTransport = supplied }
        else if !authenticatedMode, configuration != nil { resolvedTransport = AgoraSharingTransport() }
        else { resolvedTransport = BoundNakamaSharingTransport() }
        self.transport = resolvedTransport
        let scheduler = scheduler ?? FriendSharingScheduler()
        self.scheduler = scheduler
        self.sharing = try! SharingSession(transport: resolvedTransport, scheduler: scheduler,
                                          minimumPublicationInterval: FriendSharingCadence.interval)
        if let nakama = resolvedTransport as? BoundNakamaSharingTransport {
            nakama.videoAuthorization = { [weak self] in
                guard let self, let room = self.authRoom, let owner = self.tokenOwner,
                      let identity = self.authenticatedSession?(), identity.owner == owner else { throw FriendSharingTokenError.unavailable }
                let lease = try await self.tokenFetcher(room, identity)
                guard lease.valid(room: room, owner: owner), self.authenticatedSession?()?.isSameSession(as: identity) == true else {
                    throw FriendSharingTokenError.unavailable
                }
                return lease
            }
            nakama.videoStateChanged = { [weak self, weak nakama] in
                self?.videoPublishing = nakama?.videoPublishing == true
                if nakama?.videoPublishing != true { self?.invalidateRemoteVideo() }
            }
        }
        if let screenSession { attachScreenSharing(screenSession) }
        remoteView.backgroundColor = .black
        nativeBattle.makeChannel = { [weak self] receiver, failed in
            guard let self, self.gameplayTransportAvailable else { return nil }
            return self.transport.makeBattleChannel(receiver: receiver, failed: failed)
        }
        nativeBattle.sendControl = { [weak self] data in
            guard let self, self.gameplayTransportAvailable else { return false }
            return self.transport.sendInteraction(data)
        }
        nativeBattle.soulProbe = soulLink.probe
        cooperativeDoubles.changed = { [weak self] message in if !message.isEmpty { self?.status=message } }
        cooperativeDoubles.makeChannel = { [weak self] receiver, failed in
            guard let self, self.gameplayTransportAvailable else { return nil }
            return self.transport.makeBattleChannel(receiver:receiver,failed:failed)
        }
        cooperativeDoubles.send = { [weak self] data in
            guard let self, self.gameplayTransportAvailable else { return false }
            return self.transport.sendInteraction(data)
        }
        cooperativeDoubles.connected = { [weak self] in
            guard let self else { return false }
            return !self.mediaOnly && self.active && self.joined && !self.reconnecting && !self.backgrounded && !self.nativeBattle.blocksAutoSave
                && (self.debugActivitiesAllowed || self.debugContinuingCooperative && self.cooperativeDoubles.isActive)
        }
        cooperativeDoubles.context = { [weak livePresence] in
            guard let presence=livePresence,let peer=presence.peerEpoch else { return nil }
            return (presence.epoch,peer)
        }
        sharedWorld.send = { [weak self] data in self?.transport.sendInteraction(data) == true }
        soulLink.send = { [weak self] data in self?.transport.sendInteraction(data) == true }
        soulLink.connected = { [weak self] in
            guard let self else { return false }
            return !self.mediaOnly && self.active && self.joined && !self.reconnecting && !self.backgrounded
        }
        soulLink.nativeActivity = { [weak self] in self?.nativeBattle.isActive == true || self?.cooperativeDoubles.isActive == true }
        interactions.agreed = { [weak self] activity, id, initiator in
            guard let self, self.debugActivitiesAllowed else { return }
            guard !self.cooperativeDoubles.blocksAutoSave else {
                self.interactions.activityEnded("Finish the cooperative battle first");return
            }
            guard self.soulLink.permitsNativeActivity(activity) else {
                self.interactions.activityEnded("Trades with friends are unavailable during Soul Link."); return
            }
            self.nativeBattle.begin(activity: activity, id: id, initiator: initiator)
        }
        interactions.cancelActivity = { [weak nativeBattle] in nativeBattle?.cancel() }
        interactions.context = { [weak livePresence] in livePresence?.interactionContext() }
        interactions.admissionIdentity = { [weak self] in
            guard let self, self.debugActivitiesAllowed || self.debugContinuingNative && self.nativeBattle.isActive else { return nil }
            let context=self.nativeBattle.continuationContext ?? self.nativeBattle.continuationContextProvider?()
            if self.authenticatedMode {
                // Transport gaps retain the authenticated consent scope. The
                // interaction state machine separately requires fresh presence
                // and a connected channel before it can admit an activity.
                guard self.active || self.hasValidForegroundReconnectIntent || self.pausedMultiplayerScope != nil,
                      let owner=self.tokenOwner ?? self.foregroundReconnectIntent?.owner ?? self.pausedMultiplayerScope?.owner,
                      let room=self.authRoom ?? self.foregroundReconnectIntent?.room ?? self.pausedMultiplayerScope?.room,
                      self.authenticatedSession?()?.owner == owner,
                      self.roomProvider() == room else { return nil }
                if let context, context.owner != owner || context.roomID != room.lowercased() { return nil }
                return owner.uuidString + ":" + room.lowercased() + ":" + (context?.runID?.uuidString ?? "")
            }
            // The existing explicit local QA transport has no account token.
            // Keep its distinct owner/peer/channel identity without granting it
            // access to authenticated runs or server authorization.
            guard self.active, let configuration=self.configuration else { return nil }
            return "local:\(configuration.uid):\(configuration.remoteUID):\(configuration.channel):\(context?.runID?.uuidString ?? "")"
        }
        livePresence.peerWithdrew = { [weak self] in
            self?.connectionFeed.friendDisconnected(epoch: self?.livePresence.peerEpoch)
            self?.cooperativeDoubles.suspend()
            self?.nativeBattle.cancel()
            self?.interactions.stop(message: "Your friend disconnected")
        }
        livePresence.retainsNativeDialoguePose = { [weak interactions] in
            guard let interactions,interactions.nativeDialogueManaged else { return false }
            return interactions.menuPresented || interactions.phase == .agreed || interactions.nativeDialogueBusy
        }
        interactions.contextDiagnostic = { [weak livePresence] in livePresence?.interactionDiagnostic() ?? "presence unavailable" }
        livePresence.connectionCheck.snapshot = { [weak self] in self?.presenceConnectionSample() }
        if isConfigured { status = "Game sharing ready" }
        for name in [BoundMultiplayerFeatures.didChange, Settings.didResetNotification] {
            featureObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshExperimentalFeatures() }
            })
        }
    }

    private func refreshExperimentalFeatures() {
        guard !mediaOnly else { return }
        if BoundMultiplayerFeatures.isEnabled {
            if active, authenticatedMode, transport is BoundNakamaSharingTransport {
                stopLane(reason: .sessionChanged); beginStart(); return
            }
            livePresence.setEnabled(true)
            if active && joined && !reconnecting && !backgrounded { startPresence() }
        } else {
            // Cancel restores a battle snapshot before its cable/consent channel closes.
            // Interrupted-battle recovery stays available even with the feature off.
            cooperativeDoubles.suspend(); nativeBattle.cancel(resume: !backgrounded)
            if nativeBattle.blocksAutoSave {
                interactions.stop(message: "Recovery snapshot kept. Reopen this game to restore it.")
            } else {
                if interactions.phase != .ended { interactions.cancel() }
                interactions.stop()
            }
            sharedWorld.stop()
            livePresence.setEnabled(false); livePresence.stop(); livePresence.connectionCheck.stop()
            // Ordinary Agora/local video does not own a Nakama gameplay lane.
            if authenticatedMode && transport is BoundNakamaSharingTransport { disconnectMultiplayer() }
        }
    }

    deinit {
        // Do not rely on isolated-deinit backdeployment: the iOS 26.3 Simulator
        // runtime aborted inside that trampoline during SwiftUI teardown with Xcode 27.
        // Captures retain only resources, never this owner. Deallocation may occur
        // off-main; all actor-owned cancellation/RTC cleanup is explicitly enqueued.
        featureObservers.forEach(NotificationCenter.default.removeObserver)
        tokenTask?.cancel()
        let tokenDeadline = tokenDeadline, receiverDisplayLink = receiverDisplayLink, debugAdmissionDeadline = debugAdmissionDeadline
        let recoveryDeadline = recoveryDeadline, foregroundReconnectRetry = foregroundReconnectRetry
        let sharing = sharing, transport = transport
        BoundMainActorDisposal.enqueue {
            tokenDeadline?.cancel(); debugAdmissionDeadline?.cancel()
            receiverDisplayLink?.cancel()
            recoveryDeadline?.cancel()
            foregroundReconnectRetry?.cancel()
            sharing.stop()
            transport.stop()
        }
    }

    /// Entering the UI-owned authenticated flow permanently leaves temporary
    /// mode for this owner. Sign-out cannot silently restore a retained RTC token.
    func configureAuthenticatedRoom(_ room: String?, disconnectReason: BoundConnectionFeed.DisconnectReason = .sessionChanged,
                                    identity: @escaping () -> AppCloudSession?) {
        automaticMultiplayerConnection = false; startedForMultiplayer = false
        stopLane(reason: disconnectReason)
        authenticatedMode = true; configuration = nil
        roomProvider = { room }; authenticatedSession = identity
        status = room == nil ? "Add a friend to share" : "Game sharing ready"
    }

    func start() {
        BoundMainActorDisposal.drainPending()
        startedForMultiplayer = false
        guard !active else { return }
        clearForegroundReconnectIntent()
        beginStart()
    }

    /// The ROM selects an authenticated friend; this connection never sends a
    /// Jiggle and keeps retrying while that selection remains current.
    func setAutomaticMultiplayerConnection(_ requested: Bool) {
        let enabled = requested && BoundMultiplayerFeatures.isEnabled && authenticatedMode
        automaticMultiplayerConnection = enabled
        guard enabled else {
            if startedForMultiplayer {
                startedForMultiplayer = false
                disconnectMultiplayer()
            }
            return
        }
        guard let room = roomProvider(), let identity = authenticatedSession?() else { return }
        foregroundReconnectIntent = ForegroundReconnectIntent(room: room, owner: identity.owner)
        guard !backgrounded, !active, foregroundReconnectRetry == nil else { return }
        startedForMultiplayer = true
        beginStart()
    }

    /// Pause only the realtime gameplay lane. Keep run ownership, consent,
    /// durable saves and native interrupted-activity recovery for reconnection.
    func disconnectMultiplayer() {
        automaticMultiplayerConnection = false; startedForMultiplayer = false
        connectionFeed.disconnect(.manual)
        if let room = authRoom ?? foregroundReconnectIntent?.room,
           let owner = tokenOwner ?? foregroundReconnectIntent?.owner {
            pausedMultiplayerScope = ForegroundReconnectIntent(room: room, owner: owner)
        }
        stop(clearReconnectIntent: false)
        clearForegroundReconnectIntent()
        connectionFailed = false
    }

    @discardableResult
    func sendMultiplayerPacket(_ data: Data) -> Bool {
        guard !mediaOnly, BoundMultiplayerFeatures.isEnabled, data.starts(with: Data("BRM1".utf8)), data.count <= 1024,
              active, joined, !reconnecting, !backgrounded else { return false }
        return transport.sendInteraction(data)
    }

    private func beginStart() {
        guard !active, !backgrounded else { return }
        peerConnected = false; connectionFailed = false
        if authenticatedMode {
            guard let room = roomProvider(), let identity = authenticatedSession?() else {
                connectionFailed = true; status = "Sign in to share"; return
            }
            generation = UUID(); active = true; status = "Authorizing sharing"
            connectionFeed.beginConnection()
            authRoom = room; tokenOwner = identity.owner; tokenRenewals = 0
            // An explicit Share is also a persistent connection request. A
            // transient authorization/socket failure must not terminate a native
            // activity merely because the ROM did not start the connection.
            foregroundReconnectIntent = ForegroundReconnectIntent(room: room, owner: identity.owner)
            requestToken(initial: true)
            return
        }
        startTransport()
    }

    private func startTransport() {
        guard !backgrounded, let configuration else { return }
        connectionFeed.beginConnection()
        soulLink.setConnection(owner: tokenOwner?.uuidString ?? (authenticatedMode ? nil : String(configuration.uid)), room: authRoom ?? configuration.channel)
        generation = UUID()
        let run = generation
        receivedFrames = 0; publishedFrames = 0; remoteVisible = false; peerConnected = false
        sourceFramesAccepted = 0; receiverCadence = FriendSharingReceiveCadence(); sourceFrameNumber = 0; sourceButtons = 0; publicationToken = nil
        lastDisplayTick = nil; largestDisplayGap = 0
        reconnecting = false; recoveryAttempts = 0; recoveryCompletions = 0; recoveryTimeouts = 0
        captureClock = FriendSharingCaptureClock()
        active = true; status = "Connecting"
        if let nakama = transport as? BoundNakamaSharingTransport { nakama.setVideoRequired(!startedForMultiplayer) }
        videoPublishing = transport.videoPublishing
        transport.setPresenceReceiver { [weak self] data in
            guard BoundMultiplayerFeatures.isEnabled, let self, !self.mediaOnly, self.generation == run, self.active, self.joined, !self.reconnecting else { return }
            self.livePresence.receive(data)
        }
        transport.setRetainedPresenceReceiver { [weak self] data, age in
            guard BoundMultiplayerFeatures.isEnabled, let self, !self.mediaOnly, self.generation == run, self.active else { return }
            self.livePresence.restorePresentation(data, age: age)
        }
        transport.setInteractionReceiver { [weak self] data in
            guard BoundMultiplayerFeatures.isEnabled, let self, !self.mediaOnly, self.generation == run, self.active, self.joined, !self.reconnecting else { return }
            if let data {
                if !self.interactions.connected,
                   BoundBattleControlPacket.decode(data) != nil || BoundCooperativePacket(data: data) != nil {
                    // Native activities do not publish overworld positions. A
                    // valid control from the authenticated peer can restore the
                    // lane; each activity still verifies its own request UUID.
                    self.startInteractions()
                }
                if data.starts(with: BoundWorldPacket.prefix) { self.sharedWorld.receive(data) }
                else if BoundSoulPacket.recognizes(data) { self.soulLink.receive(data) }
                else if data.starts(with: BoundCooperativePacket.prefix) { self.cooperativeDoubles.receive(data) }
                else if data.starts(with: BoundBattleControlPacket.prefix) { self.nativeBattle.receive(data) }
                else if data.starts(with: Data("BRM1".utf8)) { self.multiplayerPacketReceiver?(data) }
                else { self.interactions.receive(data) }
            }
            else {
                self.sharedWorld.peerGone(); self.soulLink.peerGone()
                self.cooperativeDoubles.transportInterrupted(); self.nativeBattle.suspendTransport()
                self.interactions.suspend()
            }
        }
        transport.start(configuration: configuration, remoteView: remoteView) { [weak self] event in
            guard let self, self.generation == run, self.active else { return }
            switch event {
            case .joined:
                self.connectionFailed = false
                self.foregroundReconnectAttempts = 0
                self.joined = true
                self.connectionFeed.connected()
                self.startPresence()
                self.status = "Waiting for friend"
                self.beginReceiving(run: run)
            case .remoteJoined:
                guard self.joined, !self.reconnecting, !self.backgrounded else { return }
                self.peerConnected = true
                self.connectionFeed.friendJoined()
                self.startInteractions()
            case .remoteFrame:
                self.receivedFrames += 1
                // Freshness is established by the decoded-frame clock below.
            case .remoteGone:
                self.peerConnected = false
                self.connectionFeed.friendUnavailable()
                self.invalidateRemoteVideo()
                self.sharedWorld.peerGone(); self.soulLink.peerGone()
                self.cooperativeDoubles.transportInterrupted(); self.nativeBattle.suspendTransport()
                self.interactions.suspend()
                self.livePresence.peerGone()
                self.remoteVisible = false
                self.receivedFrames = 0
                self.status = "Waiting for friend"
            case .reconnecting:
                self.invalidateRemoteVideo()
                self.sharedWorld.peerGone(); self.soulLink.peerGone()
                self.beginRecovery(run: run)
            case .rejoined:
                guard self.reconnecting else { return }
                self.recoveryID = nil
                self.recoveryDeadline?.cancel(); self.recoveryDeadline = nil
                self.connectionFailed = false
                self.reconnecting = false; self.joined = true; self.recoveryCompletions += 1
                self.connectionFeed.connected()
                self.foregroundReconnectAttempts = 0
                self.startPresence()
                self.status = "Waiting for fresh friend video"
                self.beginReceiving(run: run)
            case .tokenNeeded:
                if self.authenticatedMode { self.requestToken(initial: false) }
                else { self.stopLane(reason: .unavailable); self.status = "Sharing unavailable · Retry" }
            case .connection: break
            case .failed:
                if self.debugRealtimeScope != nil { self.handleDebugRealtimeFailure(run:run,revision:self.debugRealtimeRevision) }
                else { self.handleForegroundReconnectFailure(run: run, status: "Sharing unavailable · Retrying") }
            }
            self.writeEvidence()
        }
        writeEvidence()
    }

    /// Called synchronously by PlaybackSession only after displaying this same
    /// detached GameFrame. SharingSession owns the sole pending outgoing frame;
    /// the source callback creates no queue and no Task per emulator frame.
    func receivePlaybackFrame(_ frame: GameFrame?) {
        mediaSession?.receivePlaybackFrame(frame)
        guard let frame else {
            publicationToken = nil
            sourceFrameNumber = 0; sourceButtons = 0
            sharing.stop()
            return
        }
        guard active, joined, !backgrounded, videoPublishing else { return }
        do {
            let token: SharingSessionToken
            if let current = publicationToken { token = current }
            else { token = try sharing.start(); publicationToken = token }
            sequence += 1
            let detached = try SharingFrame(copying: frame.rgba, sequence: sequence,
                                            capturedAt: captureClock.capture(at: scheduler.now))
            try sharing.submit(detached, for: token)
            guard active, joined, !reconnecting, publicationToken == token else { return }
            sourceFrameNumber = frame.number
            sourceButtons = frame.buttons
            sourceFramesAccepted += 1
            if case .failed = sharing.state {
                handleForegroundReconnectFailure(run: generation, status: "Sharing unavailable · Retrying")
            }
        } catch {
            handleForegroundReconnectFailure(run: generation, status: "Sharing unavailable · Retrying")
        }
    }

    private func requestToken(initial: Bool) {
        if transport is BoundNakamaSharingTransport, BoundMultiplayerFeatures.isEnabled || debugRealtimeScope != nil {
            requestNakamaToken(initial: initial)
            return
        }
        guard tokenTask == nil, active, let room = authRoom, let owner = tokenOwner,
              let identity = authenticatedSession?(), identity.owner == owner else {
            if tokenTask == nil { stopLane(reason: .sessionChanged); status = "Sign in to share" }
            return
        }
        let run = generation
        let fetcher = tokenFetcher
        tokenTask = Task { [weak self] in
            do {
                let lease = try await fetcher(room, identity)
                try Task.checkCancellation()
                guard let self, self.generation == run, self.active else { return }
                guard lease.valid(room: room, owner: owner), self.authenticatedSession?()?.owner == owner else {
                    self.tokenTask = nil; self.stopLane(reason: .sessionChanged); self.status = "Sign in to share"; return
                }
                self.tokenTask = nil
                if initial {
                    self.configuration = lease.configuration
                    self.startTransport()
                } else {
                    guard let previous = self.configuration, previous.appID == lease.appID, previous.channel == lease.channel,
                          previous.uid == lease.uid, previous.remoteUID == lease.remoteUID,
                          self.transport.renewToken(lease.token) else { throw FriendSharingTokenError.unavailable }
                    self.configuration = lease.configuration
                    self.tokenRenewals += 1
                }
                guard self.active else { return }
                self.tokenExpiry = lease.expiresAt
                let renewalRun = self.generation
                self.tokenDeadline?.cancel()
                let renewalLead = min(60, (lease.expiresAt - lease.issuedAt) / 2)
                self.tokenDeadline = self.scheduler.schedule(at: self.scheduler.now + max(1, lease.expiresAt - Date().timeIntervalSince1970 - renewalLead)) { [weak self] in
                    guard let self, self.generation == renewalRun, self.active else { return }
                    self.requestToken(initial: false)
                }
            } catch {
                guard let self, self.generation == run, self.active else { return }
                self.tokenTask = nil
                self.handleForegroundReconnectFailure(run: run, status: "Sharing authorization unavailable · Retrying")
            }
        }
    }

    private func requestNakamaToken(initial: Bool) {
        guard tokenTask == nil, active, let room = authRoom, let owner = tokenOwner,
              let identity = authenticatedSession?(), identity.owner == owner,
              let nakama = transport as? BoundNakamaSharingTransport else { return }
        guard debugRealtimeScope == nil || debugRealtimeProvider != nil else { return }
        let run = generation, scope = debugRealtimeScope, revision = debugRealtimeRevision
        let fetcher = debugRealtimeProvider ?? nakamaFetcher
        tokenTask = Task { [weak self] in
            do {
                let lease = try await fetcher(room, identity)
                try Task.checkCancellation()
                guard let self, self.generation == run, self.active,
                      self.debugRealtimeRevision == revision, self.debugRealtimeScope == scope else { return }
                guard let roomID = UUID(uuidString: room),
                      (scope == nil ? lease.isValid(room: roomID, owner: owner) : lease.ownerID == owner && lease.roomID != roomID && lease.isValid()),
                      self.authenticatedSession?()?.isSameSession(as: identity) == true else { throw FriendSharingTokenError.unavailable }
                guard self.reconnectPeerOwner == nil || self.reconnectPeerOwner == lease.peerOwnerID else {
                    if scope == nil {
                        self.tokenTask = nil; self.stopLane(reason: .sessionChanged)
                        self.status = "Friend changed · Reopen multiplayer"; return
                    }
                    throw FriendSharingTokenError.unavailable
                }
                self.reconnectPeerOwner = lease.peerOwnerID
                self.tokenTask = nil; self.debugRealtimeAttempts = 0
                if initial {
                    nakama.configureGameplay(lease, debug: scope != nil)
                    // The display/continuation identity stays the logical friend
                    // room. The socket uses only the server-issued match ID.
                    let localRole: UInt = lease.members.sorted { $0.uuidString < $1.uuidString }.first == owner ? 1 : 2
                    self.configuration = .init(appID: String(repeating: "0", count: 32),
                        channel: "nakama_" + roomID.uuidString.lowercased(), uid: localRole,
                        remoteUID: localRole == 1 ? 2 : 1, token: "nakama")
                    if !nakama.startConfiguredGameplay(rejoining: self.reconnecting) { self.startTransport() }
                } else {
                    guard nakama.renewGameplay(lease, debug: scope != nil) else { throw FriendSharingTokenError.unavailable }
                    self.tokenRenewals += 1
                }
                guard self.active else { return }
                self.tokenExpiry = lease.expiresAt
                let renewalRun = self.generation
                self.tokenDeadline?.cancel()
                let delay = scope == nil ? max(1, min(40, lease.expiresAt - Date().timeIntervalSince1970 - 30))
                    : max(1, min(10, lease.expiresAt - Date().timeIntervalSince1970 - 5))
                self.tokenDeadline = self.scheduler.schedule(at: self.scheduler.now + delay) { [weak self] in
                    guard let self, self.generation == renewalRun, self.active, self.debugRealtimeRevision == revision else { return }
                    self.requestToken(initial: false)
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == run, self.active, self.debugRealtimeRevision == revision else { return }
                self.tokenTask = nil
                if scope != nil {
                    self.handleDebugRealtimeFailure(run:run,revision:revision)
                } else { self.handleForegroundReconnectFailure(run: run, status: "Multiplayer unavailable · Retrying") }
            }
        }
    }

    private func handleDebugRealtimeFailure(run:UUID,revision:UUID) {
        guard generation==run,debugRealtimeRevision==revision,debugRealtimeScope != nil,active,
              let nakama=transport as? BoundNakamaSharingTransport else { return }
        connectionFailed = true
        nakama.suspendGameplay(); joined=false;peerConnected=false;reconnecting=true
        sharedWorld.peerGone();soulLink.peerGone();interactions.suspend()
        nativeBattle.suspendTransport();cooperativeDoubles.transportInterrupted()
        livePresence.stop(keepPresentation:true);tokenExpiry=nil
        status="DEBUG connection unavailable · Retrying"
        debugRealtimeAttempts+=1;tokenDeadline?.cancel()
        guard debugRealtimeProvider != nil else { return }
        tokenDeadline=scheduler.schedule(at:scheduler.now+BoundSDKRetryDelay.seconds(attempt:debugRealtimeAttempts)) { [weak self] in
            guard let self,self.generation==run,self.active,self.debugRealtimeRevision==revision,self.debugRealtimeProvider != nil else { return }
            self.requestNakamaToken(initial:true)
        }
    }

    private func beginRecovery(run: UUID) {
        invalidateRemoteVideo()
        guard !reconnecting else { return } // Repeated SDK events never extend the deadline.
        connectionFeed.recovering()
        sharedWorld.peerGone()
        reconnecting = true; joined = false; peerConnected = false; recoveryAttempts += 1
        cooperativeDoubles.transportInterrupted(); nativeBattle.suspendTransport()
        interactions.suspend(); livePresence.stop(keepPresentation: true)
        receivePlaybackFrame(nil)
        remoteVisible = false; receivedFrames = 0
        status = "Reconnecting…"
        let id = UUID(); recoveryID = id
        recoveryDeadline = scheduler.schedule(at: scheduler.now + 30) { [weak self] in
            guard let self, self.active, self.generation == run, self.recoveryID == id, self.reconnecting else { return }
            self.recoveryTimeouts += 1
            self.transport.recordRecoveryTimeout()
            self.handleForegroundReconnectFailure(run: run, status: "Connection lost · Retrying")
        }
    }

    private func beginReceiving(run: UUID) {
        guard receiverDisplayLink == nil else { return }
        // Receiving remains live while local playback is paused. Publication is
        // driven solely by displayed emulator frames, never this display callback.
        receiverDisplayLink = FriendSharingDisplayLink { [weak self] timestamp in
            guard let self, self.generation == run, self.active else { return }
            #if DEBUG
            if let last = self.lastDisplayTick {
                self.largestDisplayGap = max(self.largestDisplayGap, timestamp - last)
            }
            self.lastDisplayTick = timestamp
            #endif
            if self.authenticatedMode && (self.authenticatedSession?()?.owner != self.tokenOwner || self.roomProvider() != self.authRoom) {
                self.stopLane(reason: .sessionChanged); self.status = "Sign in to share"; return
            }
            if self.authenticatedMode, !(self.debugRealtimeScope != nil && self.tokenExpiry == nil), (self.tokenExpiry ?? 0) <= Date().timeIntervalSince1970 {
                if self.debugRealtimeScope != nil { self.handleDebugRealtimeFailure(run:run,revision:self.debugRealtimeRevision) }
                else { self.handleForegroundReconnectFailure(run: run, status: "Restoring connection · Retrying") }
                return
            }
            self.sharedWorld.tick(enabled: !self.mediaOnly && BoundMultiplayerFeatures.isEnabled && self.livePresence.enabled && self.active, connected: self.joined && !self.reconnecting && !self.backgrounded)
            self.transport.pollPresence()
            self.livePresence.tick()
            // An interaction stream can recover without another roster event.
            // Resume only with fresh authenticated positions, never a retained
            // sprite or a timer alone.
            if self.joined, !self.reconnecting, !self.backgrounded,
               !self.interactions.connected, self.interactions.context?() != nil {
                self.startInteractions()
            }
            self.transport.pollInteractions()
            self.interactions.tick()
            // Keep receiving/publishing while Notes, Types or a hidden PiP is
            // selected. Consume the bounded latest-frame mailbox only when visible.
            if self.remotePresentationEnabled { self.transport.presentLatestFrame() }
            let cadence = self.receiverCadence.tick(at: timestamp)
            let received = self.transport.receivedFrames
            self.updateVideoFreshness(received: received)
            if cadence.statistics {
                if self.publishedFrames != self.transport.publishedFrames { self.publishedFrames = self.transport.publishedFrames }
                if self.receivedFrames != received { self.receivedFrames = received }
            }
            if cadence.evidence {
                self.logFrameTiming()
                self.writeEvidence()
            }
        }
    }

    func stop(reason: BoundConnectionFeed.DisconnectReason = .stopped) {
        mediaSession?.stop(reason: reason)
        stopLane(reason: reason)
    }

    private func stopLane(reason: BoundConnectionFeed.DisconnectReason = .stopped) {
        connectionFeed.disconnect(reason)
        connectionFailed = reason == .unavailable
        stop(clearReconnectIntent: true)
    }

    private func startPresence() {
        guard !mediaOnly, BoundMultiplayerFeatures.isEnabled else { return }
        livePresence.setEnabled(true)
        livePresence.start { [weak self] data in
            guard let self, self.active, self.joined, !self.reconnecting, !self.backgrounded else { return false }
            return self.transport.sendPresence(data)
        }
        startInteractions()
    }

    private func startInteractions() {
        guard gameplayTransportAvailable else { return }
        interactions.start { [weak self] data in
            guard let self, self.active, self.joined, !self.reconnecting, !self.backgrounded else { return false }
            return self.transport.sendInteraction(data)
        }
        nativeBattle.resumeTransport()
        cooperativeDoubles.transportResumed()
    }

    private var gameplayTransportAvailable: Bool {
        !mediaOnly && BoundMultiplayerFeatures.isEnabled && active && joined && !reconnecting && !backgrounded
    }

    private func presenceConnectionSample() -> BoundPresenceConnectionSample {
        var sample = BoundPresenceConnectionSample()
        sample.authenticated = authenticatedMode
        sample.authorizationReady = authenticatedMode && configuration != nil
        sample.active = active; sample.joined = joined; sample.reconnecting = reconnecting
        sample.tokenRenewals = tokenRenewals; sample.reconnectCompletions = recoveryCompletions
        sample.videoAcceptedSends = transport.publishedFrames; sample.videoReceivedFrames = transport.receivedFrames
        sample.transport = transport.presenceConnectionCheck
        sample.reader = livePresence.connectionReaderCheck(at: ProcessInfo.processInfo.systemUptime)
        return sample
    }

    private func stop(clearReconnectIntent: Bool) {
        invalidateRemoteVideo()
        BoundMainActorDisposal.drainPending()
        foregroundReconnectRetry?.cancel(); foregroundReconnectRetry = nil
        if clearReconnectIntent { pausedMultiplayerScope = nil; foregroundReconnectIntent = nil; foregroundReconnectAttempts = 0; reconnectPeerOwner = nil }
        if clearReconnectIntent { sharedWorld.stop() } else { sharedWorld.peerGone() }
        soulLink.peerGone()
        if clearReconnectIntent {
            cooperativeDoubles.suspend(); nativeBattle.cancel(resume: !backgrounded)
        } else {
            cooperativeDoubles.transportInterrupted(); nativeBattle.suspendTransport()
        }
        if clearReconnectIntent { interactions.stop() } else { interactions.suspend() }
        transport.setInteractionReceiver(nil)
        livePresence.stop(keepPresentation: !clearReconnectIntent); transport.setPresenceReceiver(nil); transport.setRetainedPresenceReceiver(nil)
        generation = UUID()
        tokenTask?.cancel(); tokenTask = nil
        tokenDeadline?.cancel(); tokenDeadline = nil
        tokenOwner = nil; authRoom = nil; tokenExpiry = nil
        if authenticatedMode { configuration = nil }
        receiverDisplayLink?.cancel(); receiverDisplayLink = nil
        recoveryID = nil
        recoveryDeadline?.cancel(); recoveryDeadline = nil
        reconnecting = false
        sharing.stop()
        publicationToken = nil
        sourceFrameNumber = 0; sourceButtons = 0
        transport.stop()
        active = false; joined = false; peerConnected = false; videoPublishing = false; remoteVisible = false; receivedFrames = 0
        status = !isConfigured ? "Friend screen" : "Game sharing stopped"
        writeEvidence()
    }

    func background() {
        mediaSession?.background()
        connectionFeed.backgrounded(appInBackground: applicationIsBackgrounded())
        if authenticatedMode && active,
           let room = authRoom, let owner = tokenOwner {
            foregroundReconnectIntent = ForegroundReconnectIntent(room: room, owner: owner)
            foregroundReconnectAttempts = 0
        } else if !hasValidForegroundReconnectIntent {
            clearForegroundReconnectIntent()
        }
        backgrounded = true
        sharing.enterBackground()
        stop(clearReconnectIntent: false)
    }

    func foreground() {
        mediaSession?.foreground()
        let returnedFromBackground = backgrounded
        backgrounded = false; sharing.enterForeground()
        guard returnedFromBackground else { return }
        guard foregroundReconnectIntent != nil else { return }
        guard hasValidForegroundReconnectIntent else { stopLane(reason: .sessionChanged); status = "Sign in to share"; return }
        connectionFeed.foregrounded()
        attemptForegroundReconnect()
    }

    private var hasValidForegroundReconnectIntent: Bool {
        guard authenticatedMode,
              let intent = foregroundReconnectIntent,
              roomProvider() == intent.room,
              authenticatedSession?()?.owner == intent.owner else { return false }
        return true
    }

    private func clearForegroundReconnectIntent() {
        foregroundReconnectIntent = nil
        foregroundReconnectAttempts = 0
        foregroundReconnectRetry?.cancel(); foregroundReconnectRetry = nil
    }

    private func attemptForegroundReconnect() {
        guard !backgrounded, !active, let intent = foregroundReconnectIntent,
              hasValidForegroundReconnectIntent,
              let identity = authenticatedSession?(), identity.owner == intent.owner else {
            if !hasValidForegroundReconnectIntent { stopLane(reason: .sessionChanged); status = "Sign in to share" }
            return
        }
        foregroundReconnectRetry?.cancel(); foregroundReconnectRetry = nil
        connectionFeed.beginConnection(resuming: true)
        generation = UUID(); active = true; peerConnected = false; status = "Restoring sharing"
        authRoom = intent.room; tokenOwner = intent.owner; tokenRenewals = 0
        requestToken(initial: true)
    }

    private func handleForegroundReconnectFailure(run: UUID, status failureStatus: String) {
        guard generation == run, active else { return }
        connectionFailed = true
        guard foregroundReconnectIntent != nil, !backgrounded, hasValidForegroundReconnectIntent else {
            stopLane(reason: .unavailable); status = failureStatus.replacingOccurrences(of: " · Retrying", with: " · Retry"); writeEvidence(); return
        }
        connectionFeed.recovering()
        sharedWorld.peerGone(); soulLink.peerGone()
        cooperativeDoubles.transportInterrupted(); nativeBattle.suspendTransport()
        interactions.suspend(); livePresence.stop(keepPresentation: true)
        transport.setInteractionReceiver(nil); transport.setPresenceReceiver(nil)
        invalidateRemoteVideo()
        generation = UUID()
        tokenTask?.cancel(); tokenTask = nil
        tokenDeadline?.cancel(); tokenDeadline = nil
        tokenOwner = nil; authRoom = nil; tokenExpiry = nil
        configuration = nil
        receiverDisplayLink?.cancel(); receiverDisplayLink = nil
        recoveryID = nil; recoveryDeadline?.cancel(); recoveryDeadline = nil
        reconnecting = false; sharing.stop(); publicationToken = nil
        sourceFrameNumber = 0; sourceButtons = 0; transport.stop()
        active = false; joined = false; peerConnected = false; videoPublishing = false; remoteVisible = false; receivedFrames = 0
        status = failureStatus
        scheduleForegroundReconnectRetry()
        writeEvidence()
    }

    private func scheduleForegroundReconnectRetry() {
        guard !backgrounded, foregroundReconnectIntent != nil, hasValidForegroundReconnectIntent,
              foregroundReconnectRetry == nil else { return }
        foregroundReconnectAttempts += 1
        let delay = BoundSDKRetryDelay.seconds(attempt: foregroundReconnectAttempts)
        let retryGeneration = generation
        foregroundReconnectRetry = scheduler.schedule(at: scheduler.now + delay) { [weak self] in
            guard let self, self.generation == retryGeneration,
                  self.foregroundReconnectIntent != nil, !self.backgrounded else { return }
            self.foregroundReconnectRetry = nil
            guard self.hasValidForegroundReconnectIntent else { self.stopLane(reason: .sessionChanged); self.status = "Sign in to share"; return }
            self.attemptForegroundReconnect()
        }
    }

    private func logFrameTiming() {
        #if DEBUG
        let now = CACurrentMediaTime()
        let times = transport.frameTiming
        func age(_ time: TimeInterval?) -> Int {
            guard let time else { return -1 }
            return Int(max(0, (now - time) * 1000))
        }
        let receiveAge = age(times?.received)
        let conversionAge = age(times?.converted)
        let presentationAge = age(times?.presented)
        let publicationAge = age(times?.published)
        let gap = Int(largestDisplayGap * 1000)
        largestDisplayGap = 0
        let counts = transport.diagnostics
        func count(_ key: String) -> Int { counts[key] as? Int ?? 0 }
        let pause: String
        if gap > 250 { pause = "main_thread_stalled" }
        else if publicationToken != nil && publicationAge >= 500 { pause = "sender_stalled" }
        else if receiveAge >= 500 { pause = "receive_stalled" }
        else if receiveAge >= 0 && receiveAge < 500 && conversionAge >= 500 { pause = "conversion_pressure" }
        else if conversionAge >= 0 && conversionAge < 500 && presentationAge >= 500 { pause = "presentation_stalled" }
        else { pause = "unknown" }
        diagnosticOutput.submit(log: "FRIEND_FEED_DIAG pause=\(pause) pub=\(transport.publishedFrames) recv=\(transport.receivedFrames) conv=\(count("convertedFrames")) pres=\(count("presentedFrames")) replaced=\(count("replacedPendingFrames")) busy=\(count("conversionBusyDrops")) stale=\(count("staleConversionDrops")) ageMs(pub/recv/conv/pres)=\(publicationAge)/\(receiveAge)/\(conversionAge)/\(presentationAge) maxDisplayGapMs=\(gap) sdk(peer/expected/first/encoded/fps/kbps/remoteStats/recvKbps/decodedFps/state/reason)=\(count("sdkPeerJoins"))/\(count("sdkExpectedPeerJoins"))/\(count("sdkFirstPublished"))/\(count("sdkEncodedFrames"))/\(count("sdkSentFPS"))/\(count("sdkSentKbps"))/\(count("sdkRemoteStats"))/\(count("sdkRecvKbps"))/\(count("sdkDecodedFPS"))/\(count("sdkRemoteState"))/\(count("sdkRemoteReason")) joined=\(joined) reconnecting=\(reconnecting)")
        #endif
    }

    private func writeEvidence() {
        #if DEBUG && targetEnvironment(simulator)
        guard authenticatedMode || (configuration != nil && ProcessInfo.processInfo.arguments.contains("--friend-sharing-test")) else { return }
        let value: [String: Any] = ["authenticatedMode": authenticatedMode, "tokenRenewals": tokenRenewals, "active": active, "joined": joined, "remoteVisible": remoteVisible,
                                    "reconnecting": reconnecting, "recoveryAttempts": recoveryAttempts,
                                    "recoveryCompletions": recoveryCompletions, "recoveryTimeouts": recoveryTimeouts,
                                    "receivedFrames": receivedFrames, "publishedFrames": publishedFrames,
                                    "sourceFrameNumber": sourceFrameNumber, "sourceFramesAccepted": sourceFramesAccepted, "sourceButtons": sourceButtons,
                                    "publicationPaused": publicationToken == nil,
                                    "uid": configuration.map { $0.uid as Any } ?? NSNull(),
                                    "remoteUID": configuration.map { $0.remoteUID as Any } ?? NSNull(), "status": status,
                                    "renderDiagnostics": transport.diagnostics]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            diagnosticOutput.submit(file: (data, FriendSharingConfiguration.directory.appendingPathComponent("status.json")))
        }
        #endif
    }
}
