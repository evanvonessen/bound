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
    var publishedFrames: Int { get }
    var receivedFrames: Int { get }
    var diagnostics: [String: Any] { get }
    var frameTiming: FriendSharingFrameTiming? { get }
    func start(configuration: FriendSharingConfiguration, remoteView: UIView,
               event: @escaping @MainActor (FriendSharingEvent) -> Void)
    func stop()
    func presentLatestFrame()
    func renewToken(_ token: String) -> Bool
    func recordRecoveryTimeout()
}

extension FriendSharingTransport {
    var diagnostics: [String: Any] { [:] }
    var frameTiming: FriendSharingFrameTiming? { nil }
    func presentLatestFrame() {}
    func renewToken(_ token: String) -> Bool { false }
    func recordRecoveryTimeout() {}
}

@MainActor
final class FriendSharingSession: ObservableObject {
    private let diagnosticOutput = FriendSharingDiagnosticOutput()
    @Published private(set) var status = "Friend screen"
    @Published private(set) var active = false
    @Published private(set) var joined = false
    @Published private(set) var reconnecting = false
    // Numeric counters feed diagnostics, not the production companion UI.
    private(set) var receivedFrames = 0
    private(set) var publishedFrames = 0
    @Published private(set) var remoteVisible = false
    private(set) var configuration: FriendSharingConfiguration?
    private(set) var authenticatedMode: Bool
    private var roomProvider: () -> String?
    private let tokenFetcher: @MainActor (String, AppCloudSession) async throws -> FriendSharingTokenLease
    var isConfigured: Bool { authenticatedMode || configuration != nil }
    var authenticatedSession: (() -> AppCloudSession?)?
    private var tokenTask: Task<Void, Never>?
    private var tokenDeadline: (any SharingCancellation)?
    private var tokenOwner: UUID?
    private var authRoom: String?
    private var tokenExpiry: TimeInterval?
    private var tokenRenewals = 0
    let remoteView = UIView()
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
    func setRemotePresentationEnabled(_ enabled: Bool) { remotePresentationEnabled = enabled }
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

    init(configuration: FriendSharingConfiguration? = .load(), transport: (any FriendSharingTransport)? = nil,
         scheduler: (any SharingScheduler)? = nil,
         authenticatedMode: Bool = FriendSharingConfiguration.authenticationRequested,
         roomProvider: @escaping () -> String? = { FriendSharingTokens.room() },
         tokenFetcher: @escaping @MainActor (String, AppCloudSession) async throws -> FriendSharingTokenLease = { try await FriendSharingTokens.fetch(room: $0, session: $1) }) {
        self.authenticatedMode = authenticatedMode
        self.roomProvider = roomProvider; self.tokenFetcher = tokenFetcher
        self.configuration = authenticatedMode ? nil : configuration
        let transport = transport ?? AgoraSharingTransport()
        self.transport = transport
        let scheduler = scheduler ?? FriendSharingScheduler()
        self.scheduler = scheduler
        self.sharing = try! SharingSession(transport: transport, scheduler: scheduler,
                                          minimumPublicationInterval: FriendSharingCadence.interval)
        remoteView.backgroundColor = .black
        if isConfigured { status = "Game sharing ready" }
    }

    deinit {
        // Do not rely on isolated-deinit backdeployment: the iOS 26.3 Simulator
        // runtime aborted inside that trampoline during SwiftUI teardown with Xcode 27.
        // Captures retain only resources, never this owner. Deallocation may occur
        // off-main; all actor-owned cancellation/RTC cleanup is explicitly enqueued.
        tokenTask?.cancel()
        let tokenDeadline = tokenDeadline, receiverDisplayLink = receiverDisplayLink
        let recoveryDeadline = recoveryDeadline, sharing = sharing, transport = transport
        BoundMainActorDisposal.enqueue {
            tokenDeadline?.cancel()
            receiverDisplayLink?.cancel()
            recoveryDeadline?.cancel()
            sharing.stop()
            transport.stop()
        }
    }

    /// Entering the UI-owned authenticated flow permanently leaves temporary
    /// mode for this owner. Sign-out cannot silently restore a retained RTC token.
    func configureAuthenticatedRoom(_ room: String?, identity: @escaping () -> AppCloudSession?) {
        stop()
        authenticatedMode = true; configuration = nil
        roomProvider = { room }; authenticatedSession = identity
        status = room == nil ? "Add a friend to share" : "Game sharing ready"
    }

    func start() {
        BoundMainActorDisposal.drainPending()
        guard !active, !backgrounded else { return }
        if authenticatedMode {
            guard let room = roomProvider(), let identity = authenticatedSession?() else {
                status = "Sign in to share"; return
            }
            generation = UUID(); active = true; status = "Authorizing sharing"
            authRoom = room; tokenOwner = identity.owner; tokenRenewals = 0
            requestToken(initial: true)
            return
        }
        startTransport()
    }

    private func startTransport() {
        guard !backgrounded, let configuration else { return }
        generation = UUID()
        let run = generation
        receivedFrames = 0; publishedFrames = 0; remoteVisible = false
        sourceFramesAccepted = 0; receiverCadence = FriendSharingReceiveCadence(); sourceFrameNumber = 0; sourceButtons = 0; publicationToken = nil
        lastDisplayTick = nil; largestDisplayGap = 0
        reconnecting = false; recoveryAttempts = 0; recoveryCompletions = 0; recoveryTimeouts = 0
        captureClock = FriendSharingCaptureClock()
        active = true; status = "Connecting"
        transport.start(configuration: configuration, remoteView: remoteView) { [weak self] event in
            guard let self, self.generation == run, self.active else { return }
            switch event {
            case .joined:
                self.joined = true
                self.status = "Waiting for friend"
                self.beginReceiving(run: run)
            case .remoteFrame:
                self.receivedFrames += 1
                self.remoteVisible = true
                self.status = "Receiving game video"
            case .remoteGone:
                self.remoteVisible = false
                self.receivedFrames = 0
                self.status = "Waiting for friend"
            case .reconnecting:
                self.beginRecovery(run: run)
            case .rejoined:
                guard self.reconnecting else { return }
                self.recoveryID = nil
                self.recoveryDeadline?.cancel(); self.recoveryDeadline = nil
                self.reconnecting = false; self.joined = true; self.recoveryCompletions += 1
                self.status = "Waiting for fresh friend video"
                self.beginReceiving(run: run)
            case .tokenNeeded:
                if self.authenticatedMode { self.requestToken(initial: false) }
                else { self.stop(); self.status = "Sharing unavailable · Retry" }
            case .connection: break
            case .failed:
                self.stop()
                self.status = "Sharing unavailable · Retry"
            }
            self.writeEvidence()
        }
        writeEvidence()
    }

    /// Called synchronously by PlaybackSession only after displaying this same
    /// detached GameFrame. SharingSession owns the sole pending outgoing frame;
    /// the source callback creates no queue and no Task per emulator frame.
    func receivePlaybackFrame(_ frame: GameFrame?) {
        guard let frame else {
            publicationToken = nil
            sourceFrameNumber = 0; sourceButtons = 0
            sharing.stop()
            return
        }
        guard active, joined, !backgrounded else { return }
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
                stop(); status = "Sharing unavailable · Retry"; writeEvidence()
            }
        } catch {
            stop(); status = "Sharing unavailable · Retry"; writeEvidence()
        }
    }

    private func requestToken(initial: Bool) {
        guard tokenTask == nil, active, let room = authRoom, let owner = tokenOwner,
              let identity = authenticatedSession?(), identity.owner == owner else {
            if tokenTask == nil { stop(); status = "Sign in to share" }
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
                    self.tokenTask = nil; self.stop(); self.status = "Sign in to share"; return
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
                self.tokenTask = nil; self.stop(); self.status = "Sharing authorization unavailable"
            }
        }
    }

    private func beginRecovery(run: UUID) {
        guard !reconnecting else { return } // Repeated SDK events never extend the deadline.
        reconnecting = true; joined = false; recoveryAttempts += 1
        receivePlaybackFrame(nil)
        remoteVisible = false; receivedFrames = 0
        status = "Reconnecting…"
        let id = UUID(); recoveryID = id
        recoveryDeadline = scheduler.schedule(at: scheduler.now + 30) { [weak self] in
            guard let self, self.active, self.generation == run, self.recoveryID == id, self.reconnecting else { return }
            self.recoveryTimeouts += 1
            self.transport.recordRecoveryTimeout()
            self.stop()
            self.status = "Connection lost · Retry"
            self.writeEvidence()
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
            if self.authenticatedMode && (self.authenticatedSession?()?.owner != self.tokenOwner || (self.tokenExpiry ?? 0) <= Date().timeIntervalSince1970) {
                self.stop(); self.status = "Sign in to share"; return
            }
            // Keep receiving/publishing while Notes, Types or a hidden PiP is
            // selected. Consume the bounded latest-frame mailbox only when visible.
            if self.remotePresentationEnabled { self.transport.presentLatestFrame() }
            let cadence = self.receiverCadence.tick(at: timestamp)
            let received = self.transport.receivedFrames
            let visible = received > 0
            if self.remoteVisible != visible { self.remoteVisible = visible }
            if visible && self.status != "Receiving game video" { self.status = "Receiving game video" }
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

    func stop() {
        BoundMainActorDisposal.drainPending()
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
        active = false; joined = false; remoteVisible = false; receivedFrames = 0
        status = !isConfigured ? "Friend screen" : "Game sharing stopped"
        writeEvidence()
    }

    func background() {
        backgrounded = true
        sharing.enterBackground()
        stop()
    }

    func foreground() { backgrounded = false; sharing.enterForeground() }

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
