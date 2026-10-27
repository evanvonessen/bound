import Foundation
import UIKit

/// Gameplay uses Nakama. The existing RTC engine is opened only for requested
/// video and never carries a gameplay packet through this transport.
@MainActor
final class BoundNakamaSharingTransport: FriendSharingTransport {
    private let media: any FriendSharingTransport
    private let client: any BoundSDKRoomTransport<BoundNakamaConfiguration>
    private var battleInbox = BoundNakamaBattleInbox()
    private var gameplay: BoundNakamaConfiguration?
    private var event: (@MainActor (FriendSharingEvent) -> Void)?
    private var remoteView: UIView?
    private var mediaConfiguration: FriendSharingConfiguration?
    private var generation = BoundSDKGeneration()
    private var gameplayGeneration = BoundSDKGeneration()
    private var gameplayIsDebug = false
    private var gameplayFenced = false
    private var gameplayRejoining = false
    private var connected = false
    private var videoRequested = false
    private var videoStarted = false
    private var videoConnected = false
    private var videoTask: Task<Void, Never>?
    private var videoDeadline: Task<Void, Never>?
    private var videoRetry: Task<Void, Never>?
    private var videoRecoveryDeadline: Task<Void, Never>?
    private var videoGeneration = BoundSDKGeneration()
    private var videoRetryAttempts = 0
    private var presenceReceiver: (@MainActor (Data) -> Void)?
    private var retainedPresenceReceiver: (@MainActor (Data, TimeInterval) -> Void)?
    private var interactionReceiver: (@MainActor (Data?) -> Void)?
    private var pendingPresence: Data?
    private var pendingRetainedPresence: (data: Data, age: TimeInterval, received: TimeInterval)?
    private var pendingInteractions: [Data] = []
    private var pendingInteractionBytes = 0
    private var acceptedSends = 0
    private var receivedMessages = 0
    private var peerOnline = false
    var videoStateChanged: (() -> Void)?
    var videoAuthorization: (@MainActor () async throws -> FriendSharingTokenLease)?

    init(media: (any FriendSharingTransport)? = nil, client: any BoundSDKRoomTransport<BoundNakamaConfiguration> = BoundNakamaClient()) {
        self.media = media ?? AgoraSharingTransport()
        self.client = client
    }

    func configureGameplay(_ configuration: BoundNakamaConfiguration, debug: Bool = false) {
        gameplay = configuration; gameplayIsDebug = debug; gameplayFenced = false
        if !debug { Task { await BoundNakamaRunService.shared.configure(configuration) } }
    }

    func renewGameplay(_ configuration: BoundNakamaConfiguration, debug: Bool = false) -> Bool {
        guard gameplayIsDebug == debug, let previous = gameplay, connected,
              configuration.roomID == previous.roomID, configuration.ownerID == previous.ownerID,
              configuration.nakamaUserID == previous.nakamaUserID,
              configuration.peerOwnerID == previous.peerOwnerID,
              configuration.members == previous.members, configuration.matchID == previous.matchID,
              configuration.endpoint == previous.endpoint,
              client.renewTicket(configuration.joinTicket, expiresAt: configuration.expiresAt) else { return false }
        gameplay = configuration
        if !debug { Task { await BoundNakamaRunService.shared.configure(configuration) } }
        return true
    }

    func setVideoRequired(_ value: Bool) {
        videoRequested = value
        if value { ensureVideo() }
        else { stopVideo() }
    }

    var videoPublishing: Bool { videoStarted && videoConnected }
    var publishedFrames: Int { media.publishedFrames }
    var receivedFrames: Int { media.receivedFrames }
    var frameTiming: FriendSharingFrameTiming? { videoStarted ? media.frameTiming : nil }
    var diagnostics: [String: Any] {
        ["gameplayTransport": "nakama", "gameplayConnected": connected,
         "videoActive": videoStarted, "acceptedGameplaySends": acceptedSends,
         "receivedGameplayMessages": receivedMessages]
    }
    var presenceConnectionCheck: BoundPresenceTransportCheck {
        .init(kind: .nakama, streamCreated: connected, acceptedSends: acceptedSends, receivedMessages: receivedMessages)
    }

    func start(configuration: FriendSharingConfiguration, remoteView: UIView,
               event: @escaping @MainActor (FriendSharingEvent) -> Void) {
        generation.invalidate(); client.stop(); battleInbox.close(); battleInbox = BoundNakamaBattleInbox()
        connected = false; pendingPresence = nil; pendingRetainedPresence = nil; pendingInteractions.removeAll(); pendingInteractionBytes = 0
        stopVideo()
        self.event = event; self.remoteView = remoteView; mediaConfiguration = configuration
        acceptedSends = 0; receivedMessages = 0; peerOnline = false
        if gameplay != nil { _ = startConfiguredGameplay() }
        else if !gameplayFenced {
            // Ordinary friend video remains available with multiplayer disabled.
            videoRequested = true
        }
        ensureVideo()
    }

    /// Drops only the gameplay lane. Existing ordinary media and native recovery
    /// ownership survive DEBUG admission loss and generation replacement.
    func suspendGameplay(fenced: Bool = true) {
        gameplayGeneration.invalidate(); client.stop(); battleInbox.close()
        battleInbox = BoundNakamaBattleInbox(); gameplay = nil; gameplayFenced = fenced
        connected = false; peerOnline = false; pendingPresence = nil; pendingRetainedPresence = nil
        pendingInteractions.removeAll(); pendingInteractionBytes = 0
    }

    @discardableResult func startConfiguredGameplay(rejoining: Bool = false) -> Bool {
        guard let gameplay, event != nil, remoteView != nil else { return false }
        gameplayGeneration.invalidate(); client.stop(); battleInbox.close(); battleInbox = BoundNakamaBattleInbox()
        let run = gameplayGeneration.token, inbox = battleInbox, expectedOwner = gameplay.peerOwnerID
        gameplayRejoining = rejoining; connected = false; peerOnline = false
        do {
            try client.start(configuration: gameplay) { [weak self] value in
                if case .message(let opcode, let data, let sender) = value, opcode == 3 {
                    if sender == expectedOwner { inbox.receive(data) }; return
                }
                if case .failed = value { inbox.fail() }
                DispatchQueue.main.async { [weak self] in self?.receive(value, run: run) }
            }
            return true
        } catch { event?(.failed(.init(.joinRejected))); return true }
    }

    private func receive(_ value: BoundSDKRoomEvent, run: BoundSDKGeneration.Token) {
        guard gameplayGeneration.admits(run), let gameplay, event != nil else { return }
        switch value {
        case .joined:
            connected = true; event?(gameplayRejoining ? .rejoined : .joined); gameplayRejoining = false
            if peerOnline { event?(.remoteJoined) }
            ensureVideo()
        case .roster(let members):
            let online = members.contains { $0.ownerID == gameplay.peerOwnerID && $0.online }
            if online != peerOnline {
                peerOnline = online
                if !online { pendingPresence = nil }
                if connected { event?(online ? .remoteJoined : .remoteGone) }
            }
        case .message(let opcode, let data, let sender):
            guard connected, sender == gameplay.peerOwnerID else { return }
            receivedMessages += 1
            if opcode == 1 { pendingPresence = data }
            else if opcode == 2 {
                guard pendingInteractions.count < 128, pendingInteractionBytes + data.count <= 131_072 else {
                    client.stop(); connected = false; peerOnline = false; battleInbox.fail()
                    event?(.failed(.init(.connectionLost))); return
                }
                pendingInteractions.append(data); pendingInteractionBytes += data.count
            }
        case .retainedPresence(let data, let owner, let age):
            guard owner == gameplay.peerOwnerID else { return }
            pendingRetainedPresence = (data, age, ProcessInfo.processInfo.systemUptime)
        case .failed:
            connected = false; peerOnline = false; pendingPresence = nil; pendingInteractions.removeAll(); pendingInteractionBytes = 0
            event?(.failed(.init(.connectionLost)))
        }
    }

    func setPresenceReceiver(_ receiver: (@MainActor (Data) -> Void)?) { presenceReceiver = receiver }
    func setRetainedPresenceReceiver(_ receiver: (@MainActor (Data, TimeInterval) -> Void)?) { retainedPresenceReceiver = receiver }
    func setInteractionReceiver(_ receiver: (@MainActor (Data?) -> Void)?) { interactionReceiver = receiver }
    func pollPresence() {
        if connected, let pending = pendingRetainedPresence {
            pendingRetainedPresence = nil
            retainedPresenceReceiver?(pending.data, pending.age + max(0, ProcessInfo.processInfo.systemUptime - pending.received))
        }
        guard let data = pendingPresence else { return }
        pendingPresence = nil; presenceReceiver?(data)
    }
    func pollInteractions() {
        let messages = pendingInteractions
        pendingInteractions.removeAll(keepingCapacity: true); pendingInteractionBytes = 0
        for data in messages { interactionReceiver?(data) }
    }
    func sendPresence(_ data: Data) -> Bool {
        guard connected, let gameplay, data.count <= BoundPresencePacket.maximumBytes,
              client.sendPresence(data, targetOwnerID: gameplay.peerOwnerID) else { return false }
        acceptedSends += 1; return true
    }
    func sendInteraction(_ data: Data) -> Bool {
        guard connected, let gameplay, data.count <= 1024,
              data.starts(with: BoundFriendInteractionPacket.prefix) || data.starts(with: BoundBattleControlPacket.prefix)
                || BoundSoulPacket.recognizes(data) || data.starts(with: BoundWorldPacket.prefix)
                || data.starts(with: Data("BRM1".utf8)) || data.starts(with: BoundCooperativePacket.prefix),
              client.sendInteraction(data, targetOwnerID: gameplay.peerOwnerID) else { return false }
        acceptedSends += 1; return true
    }
    func makeBattleChannel(receiver: @escaping @Sendable (Data) -> Void,
                           failed: @escaping @Sendable () -> Void) -> (any BoundBattleChannel)? {
        guard connected, let gameplay else { return nil }
        let id = battleInbox.install(receiver: receiver, failed: failed)
        return BoundNakamaRoutedBattleChannel(client: client, peer: gameplay.peerOwnerID, inbox: battleInbox, id: id)
    }

    private func ensureVideo() {
        guard event != nil, videoRequested, !videoStarted, videoTask == nil, videoRetry == nil,
              let remoteView else { return }
        let run = generation.token, attempt = BoundSDKGeneration.Token(); videoGeneration.replace(with: attempt)
        if gameplay == nil, !gameplayFenced, let mediaConfiguration {
            // The ordinary video session owns its existing lease/renewal loop.
            beginVideo(mediaConfiguration, view: remoteView, run: run)
            return
        }
        if let videoAuthorization {
            videoTask = Task { [weak self] in
                do {
                    let lease = try await videoAuthorization()
                    try Task.checkCancellation()
                    guard let self, self.generation.admits(run), self.videoGeneration.admits(attempt), self.event != nil,
                          self.videoRequested else { return }
                    self.videoTask = nil; self.beginVideo(lease.configuration, view: remoteView, run: run)
                    self.scheduleVideoRenewal(lease, run: run)
                } catch {
                    guard !Task.isCancelled, let self, self.generation.admits(run), self.videoGeneration.admits(attempt) else { return }
                    self.videoTask = nil
                    if self.gameplay == nil, !self.gameplayFenced { self.event?(.failed(.init(.tokenRequired))) }
                    else { self.scheduleVideoRetry() }
                }
            }
        } else if let mediaConfiguration { beginVideo(mediaConfiguration, view: remoteView, run: run) }
    }

    private func beginVideo(_ configuration: FriendSharingConfiguration, view: UIView, run: BoundSDKGeneration.Token) {
        let attempt = BoundSDKGeneration.Token(); videoGeneration.replace(with: attempt)
        mediaConfiguration = configuration; videoStarted = true; videoStateChanged?()
        scheduleVideoRecoveryDeadline(run: run, attempt: attempt)
        media.start(configuration: configuration, remoteView: view) { [weak self] value in
            guard let self, self.generation.admits(run), self.videoGeneration.admits(attempt), self.videoStarted else { return }
            switch value {
            case .joined, .rejoined:
                self.videoConnected = true; self.videoRetryAttempts = 0
                self.videoRecoveryDeadline?.cancel(); self.videoRecoveryDeadline = nil
                self.videoStateChanged?()
            case .failed, .reconnecting: self.videoConnected = false; self.videoStateChanged?()
            default: break
            }
            if self.gameplay == nil, !self.gameplayFenced { self.event?(value) }
            else {
                switch value {
                case .remoteFrame: self.event?(value)
                case .tokenNeeded: break // Independently renewed below.
                case .failed: self.retryVideoAfterFailure()
                case .reconnecting:
                    self.scheduleVideoRecoveryDeadline(run: run, attempt: attempt)
                    self.videoStateChanged?()
                case .remoteGone:
                    // A media outage cannot tear down a healthy gameplay room.
                    self.videoStateChanged?()
                default: break
                }
            }
        }
    }

    private func scheduleVideoRenewal(_ lease: FriendSharingTokenLease, run: BoundSDKGeneration.Token) {
        guard videoStarted else { return }
        let attempt = videoGeneration.token
        videoDeadline?.cancel()
        videoDeadline = Task { [weak self] in
            let delay = max(1, lease.expiresAt - Date().timeIntervalSince1970 - 30)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation.admits(run), self.videoGeneration.admits(attempt), self.videoStarted,
                  let authorize = self.videoAuthorization else { return }
            do {
                let next = try await authorize()
                guard !Task.isCancelled, self.generation.admits(run), self.videoGeneration.admits(attempt), self.videoStarted else { return }
                guard let previous = self.mediaConfiguration, previous.channel == next.channel,
                      previous.uid == next.uid, previous.remoteUID == next.remoteUID,
                      self.media.renewToken(next.token) else { self.retryVideoAfterFailure(); return }
                self.mediaConfiguration = next.configuration; self.scheduleVideoRenewal(next, run: run)
            } catch {
                guard !Task.isCancelled, self.generation.admits(run), self.videoGeneration.admits(attempt) else { return }
                self.retryVideoAfterFailure()
            }
        }
    }

    private func retryVideoAfterFailure() {
        stopVideo(resetRetry: false)
        scheduleVideoRetry()
    }
    private func scheduleVideoRetry() {
        guard gameplay != nil, connected, event != nil, videoRequested, videoRetry == nil else { return }
        videoRetryAttempts += 1
        let delay = BoundSDKRetryDelay.seconds(attempt: videoRetryAttempts)
        let run = generation.token, attempt = videoGeneration.token
        videoRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation.admits(run), self.videoGeneration.admits(attempt) else { return }
            self.videoRetry = nil
            guard self.connected else { return }
            self.ensureVideo()
        }
    }
    private func scheduleVideoRecoveryDeadline(run: BoundSDKGeneration.Token, attempt: BoundSDKGeneration.Token) {
        guard gameplay != nil, videoRecoveryDeadline == nil else { return }
        videoRecoveryDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.generation.admits(run), self.videoGeneration.admits(attempt),
                  self.videoStarted, !self.videoConnected else { return }
            self.videoRecoveryDeadline = nil
            self.retryVideoAfterFailure()
        }
    }
    private func stopVideo(resetRetry: Bool = true) {
        videoGeneration.invalidate()
        videoRetry?.cancel(); videoRetry = nil; videoRecoveryDeadline?.cancel(); videoRecoveryDeadline = nil
        if resetRetry { videoRetryAttempts = 0 }
        videoTask?.cancel(); videoTask = nil; videoDeadline?.cancel(); videoDeadline = nil
        media.stop(); videoStarted = false; videoConnected = false; videoStateChanged?()
    }
    func clearPresentation() { media.clearPresentation() }
    func presentLatestFrame() { if videoStarted { media.presentLatestFrame() } }
    func renewToken(_ token: String) -> Bool { media.renewToken(token) }
    func recordRecoveryTimeout() { media.recordRecoveryTimeout() }
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        guard videoPublishing else { completion(.success(())); return BoundNakamaCompletedFrame() }
        let gameplayOnlyFailure = gameplay != nil
        return media.send(frame) { result in completion(gameplayOnlyFailure ? .success(()) : result) }
    }
    func stop() {
        generation.invalidate(); gameplayGeneration.invalidate(); event = nil; connected = false; client.stop(); battleInbox.close()
        stopVideo(); gameplay = nil; gameplayFenced = false; gameplayIsDebug = false; mediaConfiguration = nil; remoteView = nil
        pendingPresence = nil; pendingRetainedPresence = nil; pendingInteractions.removeAll(); pendingInteractionBytes = 0; peerOnline = false
    }
}

@MainActor private final class BoundNakamaCompletedFrame: SharingCancellation { func cancel() {} }

private final class BoundNakamaBattleInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var id = UUID()
    private var receiver: (@Sendable (Data) -> Void)?
    private var failure: (@Sendable () -> Void)?
    func install(receiver: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable () -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        id = UUID(); self.receiver = receiver; failure = failed; return id
    }
    func receive(_ data: Data) { lock.lock(); let deliver = receiver; lock.unlock(); deliver?(data) }
    func fail() { lock.lock(); let failed = failure; receiver = nil; failure = nil; lock.unlock(); failed?() }
    func send(_ data: Data, through channel: BoundNakamaBattleChannel, expected: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // A retained activity gets a replacement channel after rejoining. Its
        // previous sender must never enqueue into the replacement socket, nor
        // into a later activity sharing the same authenticated client.
        guard id == expected, receiver != nil else { return false }
        return channel.send(data)
    }
    func close(_ expected: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard expected == nil || id == expected else { return }
        id = UUID(); receiver = nil; failure = nil
    }
}

private final class BoundNakamaRoutedBattleChannel: BoundBattleChannel, @unchecked Sendable {
    private let channel: BoundNakamaBattleChannel
    private let inbox: BoundNakamaBattleInbox
    private let id: UUID
    init(client: any BoundSDKRoomTransport<BoundNakamaConfiguration>, peer: UUID, inbox: BoundNakamaBattleInbox, id: UUID) {
        channel = BoundNakamaBattleChannel(client: client, targetOwnerID: peer); self.inbox = inbox; self.id = id
    }
    func send(_ data: Data) -> Bool { inbox.send(data, through: channel, expected: id) }
    func close() { channel.close(); inbox.close(id) }
    deinit { close() }
}
