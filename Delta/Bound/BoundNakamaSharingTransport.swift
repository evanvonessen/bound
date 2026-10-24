import Foundation
import UIKit

/// Gameplay uses Nakama. The existing RTC engine is opened only for requested
/// video and never carries a gameplay packet through this transport.
@MainActor
final class BoundNakamaSharingTransport: FriendSharingTransport {
    private let media: any FriendSharingTransport
    private let client: BoundNakamaClient
    private var battleInbox = BoundNakamaBattleInbox()
    private var gameplay: BoundNakamaConfiguration?
    private var event: (@MainActor (FriendSharingEvent) -> Void)?
    private var remoteView: UIView?
    private var spectatorView: UIView?
    private var mediaConfiguration: FriendSharingConfiguration?
    private var generation = UUID()
    private var connected = false
    private var videoRequested = false
    private var videoStarted = false
    private var videoConnected = false
    private var videoTask: Task<Void, Never>?
    private var videoDeadline: Task<Void, Never>?
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

    init(media: (any FriendSharingTransport)? = nil, client: BoundNakamaClient = BoundNakamaClient()) {
        self.media = media ?? AgoraSharingTransport()
        self.client = client
    }

    func configureGameplay(_ configuration: BoundNakamaConfiguration) {
        gameplay = configuration
        Task { await BoundNakamaRunService.shared.configure(configuration) }
    }

    func renewGameplay(_ configuration: BoundNakamaConfiguration) -> Bool {
        guard let previous = gameplay, connected,
              configuration.roomID == previous.roomID, configuration.ownerID == previous.ownerID,
              configuration.nakamaUserID == previous.nakamaUserID,
              configuration.peerOwnerID == previous.peerOwnerID,
              configuration.members == previous.members, configuration.matchID == previous.matchID,
              configuration.endpoint == previous.endpoint,
              client.renewTicket(configuration.joinTicket, expiresAt: configuration.expiresAt) else { return false }
        gameplay = configuration
        Task { await BoundNakamaRunService.shared.configure(configuration) }
        return true
    }

    func setVideoRequired(_ value: Bool) {
        videoRequested = value
        if value { ensureVideo() }
        else if spectatorView == nil { stopVideo() }
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
        generation = UUID(); client.stop(); battleInbox.close(); battleInbox = BoundNakamaBattleInbox()
        connected = false; pendingPresence = nil; pendingRetainedPresence = nil; pendingInteractions.removeAll(); pendingInteractionBytes = 0
        stopVideo()
        self.event = event; self.remoteView = remoteView; mediaConfiguration = configuration
        let run = generation
        acceptedSends = 0; receivedMessages = 0; peerOnline = false
        if let gameplay {
            let inbox = battleInbox, expectedOwner = gameplay.peerOwnerID
            do {
                try client.start(configuration: gameplay) { [weak self] value in
                    if case .message(let opcode, let data, let sender) = value, opcode == 3 {
                        if sender == expectedOwner { inbox.receive(data) }
                        return
                    }
                    if case .failed = value { inbox.fail() }
                    DispatchQueue.main.async { [weak self] in self?.receive(value, run: run) }
                }
            } catch { event(.failed(.init(.joinRejected))) }
        } else {
            // Ordinary friend video remains available with multiplayer disabled.
            videoRequested = true
        }
        ensureVideo()
    }

    private func receive(_ value: BoundNakamaClient.Event, run: UUID) {
        guard generation == run, let gameplay, event != nil else { return }
        switch value {
        case .joined:
            connected = true; event?(.joined)
            if peerOnline { event?(.remoteJoined) }
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
        guard event != nil, (videoRequested || spectatorView != nil), !videoStarted, videoTask == nil,
              let remoteView else { return }
        let run = generation
        if gameplay == nil, let mediaConfiguration {
            // The ordinary video session owns its existing lease/renewal loop.
            beginVideo(mediaConfiguration, view: remoteView, run: run)
            return
        }
        if let videoAuthorization {
            videoTask = Task { [weak self] in
                do {
                    let lease = try await videoAuthorization()
                    try Task.checkCancellation()
                    guard let self, self.generation == run, self.event != nil,
                          self.videoRequested || self.spectatorView != nil else { return }
                    self.videoTask = nil; self.beginVideo(lease.configuration, view: remoteView, run: run)
                    self.scheduleVideoRenewal(lease, run: run)
                } catch {
                    guard let self, self.generation == run else { return }
                    self.videoTask = nil
                    if self.gameplay == nil { self.event?(.failed(.init(.tokenRequired))) }
                }
            }
        } else if let mediaConfiguration { beginVideo(mediaConfiguration, view: remoteView, run: run) }
    }

    private func beginVideo(_ configuration: FriendSharingConfiguration, view: UIView, run: UUID) {
        mediaConfiguration = configuration; videoStarted = true; videoStateChanged?()
        media.start(configuration: configuration, remoteView: view) { [weak self] value in
            guard let self, self.generation == run, self.videoStarted else { return }
            switch value {
            case .joined, .rejoined: self.videoConnected = true; self.videoStateChanged?()
            case .failed, .reconnecting: self.videoConnected = false; self.videoStateChanged?()
            default: break
            }
            if self.gameplay == nil { self.event?(value) }
            else {
                switch value {
                case .remoteFrame: self.event?(value)
                case .tokenNeeded: break // Independently renewed below.
                case .failed, .reconnecting, .remoteGone:
                    // A media outage cannot tear down a healthy gameplay room.
                    self.videoStateChanged?()
                default: break
                }
            }
        }
        media.setSpectatorView(spectatorView)
    }

    private func scheduleVideoRenewal(_ lease: FriendSharingTokenLease, run: UUID) {
        videoDeadline?.cancel()
        videoDeadline = Task { [weak self] in
            let delay = max(1, lease.expiresAt - Date().timeIntervalSince1970 - 30)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation == run, self.videoStarted,
                  let authorize = self.videoAuthorization else { return }
            do {
                let next = try await authorize()
                guard !Task.isCancelled, self.generation == run, self.videoStarted else { return }
                guard let previous = self.mediaConfiguration, previous.channel == next.channel,
                      previous.uid == next.uid, previous.remoteUID == next.remoteUID,
                      self.media.renewToken(next.token) else { self.stopVideo(); return }
                self.mediaConfiguration = next.configuration; self.scheduleVideoRenewal(next, run: run)
            } catch { self.stopVideo() }
        }
    }

    private func stopVideo() {
        videoTask?.cancel(); videoTask = nil; videoDeadline?.cancel(); videoDeadline = nil
        media.stop(); videoStarted = false; videoConnected = false; videoStateChanged?()
    }
    func setSpectatorView(_ view: UIView?) {
        spectatorView = view; media.setSpectatorView(view)
        if view != nil { ensureVideo() } else if !videoRequested { stopVideo() }
    }
    func presentLatestFrame() { if videoStarted { media.presentLatestFrame() } }
    func renewToken(_ token: String) -> Bool { media.renewToken(token) }
    func recordRecoveryTimeout() { media.recordRecoveryTimeout() }
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        guard videoPublishing else { completion(.success(())); return BoundNakamaCompletedFrame() }
        let gameplayOnlyFailure = gameplay != nil
        return media.send(frame) { result in completion(gameplayOnlyFailure ? .success(()) : result) }
    }
    func stop() {
        generation = UUID(); event = nil; connected = false; client.stop(); battleInbox.close()
        stopVideo(); gameplay = nil; mediaConfiguration = nil; remoteView = nil; spectatorView = nil
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
    init(client: BoundNakamaClient, peer: UUID, inbox: BoundNakamaBattleInbox, id: UUID) {
        channel = BoundNakamaBattleChannel(client: client, targetOwnerID: peer); self.inbox = inbox; self.id = id
    }
    func send(_ data: Data) -> Bool { channel.send(data) }
    func close() { channel.close(); inbox.close(id) }
    deinit { close() }
}
