#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit
import CoreVideo
import CryptoKit
import DeltaCore

@MainActor
private final class BoundLocalPairPending: SharingCancellation {
    let id = UUID()
    var cancelled = false
    var task: Task<Void, Never>?
    func cancel() { cancelled = true; task?.cancel() }
}

/// Explicit opt-in loopback fixture. Shipping builds never compile this transport.
/// Uses native detached gameplay pixels and the production CV conversion/mailbox/presenter.
@MainActor
final class BoundLocalPairedTransport: FriendSharingTransport {
    private final class WeakInstance {
        weak var value: BoundLocalPairedTransport?
        init(_ value: BoundLocalPairedTransport) { self.value = value }
    }
    private static var instances: [WeakInstance] = []
    private let fixtureInstance = UUID().uuidString
    private weak var diagnosticTrace: EmulatorFrameTrace?
    static func qaSetTrace(_ trace: EmulatorFrameTrace?) {
        for item in instances { item.value?.diagnosticTrace = trace }
    }
    static func qaInstanceDiagnostics() -> [[String:Any]] {
        instances = instances.filter { $0.value != nil }
        return instances.compactMap { item in
            guard let value=item.value else { return nil }
            return ["id":value.fixtureInstance,"peer":value.peer,"namespace":value.presenceNamespace ?? "",
                    "running":value.running,"online":value.online,"sentPresence":value.sentPresence,
                    "receivedPresence":value.receivedPresence,"sentInteractions":value.sentInteractions,
                    "receivedInteractions":value.receivedInteractions]
        }
    }
    let peer: String
    let port: Int
    private let presenceNamespace: String?
    private let presenceOnly: Bool
    private var presenceReceiver: (@MainActor (Data) -> Void)?
    private var presencePolling: Task<Void, Never>?
    private var presenceSending: Task<Void, Never>?
    private var outgoingPresence: Data?, incomingPresence: Data?
    private var presenceSequence = 0, receivedPresence = 0, sentPresence = 0
    private var presencePeerOnline = false
    private var interactionReceiver: (@MainActor (Data?) -> Void)?
    private var interactionPolling: Task<Void, Never>?, interactionSending: Task<Void, Never>?
    private var incomingInteractions: [Data] = [], outgoingInteractions: [Data] = []
    private var interactionSequence = 0, sentInteractions = 0, receivedInteractions = 0
    private static let interactionCapacity = 64
    var videoPublishing: Bool { !presenceOnly }
    var presenceConnectionCheck: BoundPresenceTransportCheck {
        .init(kind: .fixture, streamCreated: running && presenceNamespace != nil,
              acceptedSends: sentPresence, receivedMessages: receivedPresence)
    }
    private let outgoing = AgoraOutgoingPixels()
    private let callbacks = AgoraSharingCallbacks(remoteUID: 2) { _, _ in }
    private let presenter = FriendSharingCanvasPresenter()
    private let session: URLSession
    private var host: UIView?
    private var event: (@MainActor (FriendSharingEvent) -> Void)?
    private var generation = UUID()
    private var producerRun = UUID().uuidString
    private var running = false
    private var online = false
    private var announcedJoined = false
    private var epoch = 0
    private var remoteRun = ""
    private var lastReceivedSequence: UInt64 = 0
    private var pendingEvidence: (sequence: UInt64, hash: String, peer: String)?
    private var pollTask: Task<Void, Never>?
    private var outgoingPending: BoundLocalPairPending?
    private var reportTask: Task<Void, Never>?
    private var nextReportTime = 0.0
    private var reportRequired = false
    private var reportSequence: UInt64 = 0
    private(set) var publishedFrames = 0
    var receivedFrames: Int { callbacks.receivedFrames }
    private var presentedFrames = 0
    private var lastPresentedSeq: UInt64 = 0
    private var lastPresentedHash = ""
    private var lastRemotePeer = ""
    private var staleDrops = 0
    private var canceledCallbacks = 0
    var diagnostics: [String: Any] { ["publishedFrames": publishedFrames, "presentedFrames": presentedFrames, "staleDrops": staleDrops, "canceledCallbacks": canceledCallbacks, "decodedImageVisible": presenter.isVisible, "sentInteractions":sentInteractions, "receivedInteractions":receivedInteractions] }
    init(peer: String, port: Int, presenceNamespace: String? = nil, presenceOnly: Bool = false) {
        self.peer = peer; self.port = port
        self.presenceNamespace = presenceNamespace.flatMap { UUID(uuidString: $0)?.uuidString }
        self.presenceOnly = presenceOnly
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1; config.timeoutIntervalForResource = 2
        config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config)
        Self.instances = Self.instances.filter { $0.value != nil }
        Self.instances.append(WeakInstance(self))
        if Self.instances.count>64 { Self.instances.removeFirst(Self.instances.count-64) }
    }
    private func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)" + path)! }
    func start(configuration: FriendSharingConfiguration, remoteView: UIView, event: @escaping @MainActor (FriendSharingEvent) -> Void) {
        stop(); generation = UUID(); producerRun = UUID().uuidString
        host = remoteView; self.event = event; running = true; online = false; announcedJoined = false
        remoteRun = ""; lastReceivedSequence = 0; pendingEvidence = nil
        callbacks.resetFrames(enabled: true); callbacks.resumeFrames()
        if !presenceOnly { beginPolling() }
        beginPresencePolling()
        beginInteractionPolling()
    }
    func stop() {
        generation = UUID(); running = false; online = false
        outgoingPending?.cancel(); pollTask?.cancel(); reportTask?.cancel()
        presencePolling?.cancel(); presencePolling = nil; presenceSending?.cancel(); presenceSending = nil
        outgoingPresence = nil; incomingPresence = nil; presenceSequence = 0; presencePeerOnline = false
        interactionPolling?.cancel(); interactionPolling = nil; interactionSending?.cancel(); interactionSending = nil
        incomingInteractions.removeAll(); outgoingInteractions.removeAll(); interactionSequence = 0
        event = nil; host = nil; pendingEvidence = nil
        callbacks.resetFrames(enabled: false); presenter.clear(); report(force: true)
    }
    private func changeEpoch(_ newer: Int) {
        guard newer > epoch else { return }
        epoch = newer; outgoingPending?.cancel()
        outgoingPresence = nil; incomingPresence = nil; presenceSequence = 0; presencePeerOnline = false
        incomingInteractions.removeAll(); outgoingInteractions.removeAll(); interactionSequence = 0
        interactionReceiver?(nil)
        remoteRun = ""; lastReceivedSequence = 0; pendingEvidence = nil
        callbacks.resetFrames(enabled: running); presenter.clear()
        lastPresentedSeq = 0; lastPresentedHash = ""; lastRemotePeer = ""
    }
    private func setOnline(_ value: Bool) {
        guard running else { return }
        if value {
            if !announcedJoined { announcedJoined = true; online = true; event?(.joined) }
            else if !online { online = true; callbacks.resumeFrames(); event?(.rejoined) }
        } else if online {
            online = false; callbacks.suspendFrames(); presenter.clear(); pendingEvidence = nil
            outgoingPending?.cancel(); event?(.reconnecting)
        }
    }
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        let pending = BoundLocalPairPending()
        guard running, online, outgoingPending == nil else { completion(.success(())); return pending }
        outgoingPending = pending
        let run = generation, relayEpoch = epoch, producer = producerRun
        pending.task = Task { [self, pending] in
            defer {
                if outgoingPending?.id == pending.id { outgoingPending = nil }
                pending.task = nil
                completion(.success(())) // Cancellation also releases the real SharingSession slot.
            }
            var prepared: AgoraOutgoingPixels.Prepared? = await outgoing.prepare(frame)
            defer { prepared = nil }
            guard !pending.cancelled, run == generation, relayEpoch == epoch, online,
                  let buffer = prepared?.buffer else { canceledCallbacks += 1; return }
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
            var pixels = Data(count: SharingFrame.byteCount)
            if let source = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                pixels.withUnsafeMutableBytes { raw in
                    let destination = raw.bindMemory(to: UInt8.self).baseAddress!
                    for y in 0..<160 { for x in 0..<240 {
                        let i = y*stride+x*4, o = (y*240+x)*4
                        destination[o] = source[i+2]; destination[o+1] = source[i+1]
                        destination[o+2] = source[i]; destination[o+3] = source[i+3]
                    } }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly); prepared = nil
            var request = URLRequest(url: url("/frame/" + peer)); request.httpMethod = "PUT"; request.httpBody = pixels
            request.setValue(String(frame.sequence), forHTTPHeaderField: "X-Sequence")
            request.setValue(producer, forHTTPHeaderField: "X-Run")
            request.setValue(String(relayEpoch), forHTTPHeaderField: "X-Epoch")
            do {
                let (_, response) = try await session.data(for: request)
                guard !pending.cancelled, run == generation, relayEpoch == epoch else { canceledCallbacks += 1; return }
                if let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) { publishedFrames += 1 }
                else { setOnline(false) }
            } catch { if pending.cancelled || run != generation { canceledCallbacks += 1 } else { setOnline(false) } }
            report()
        }
        return pending
    }
    func setPresenceReceiver(_ receiver: (@MainActor (Data) -> Void)?) { presenceReceiver = receiver }
    func pollPresence() {
        guard let bytes = incomingPresence else { return }
        incomingPresence = nil
        if diagnosticTrace != nil, let packet=BoundPresencePacket.decode(bytes) {
            diagnosticTrace?.record("transport.presence.delivered",value:packet.pose == nil ? 0:1,detail:packet.sequence)
            diagnosticTrace?.record("transport.presence.deliveredCollision",value:packet.pose?.collisionTiles == nil ? 0:1,detail:packet.sequence)
        }
        presenceReceiver?(bytes)
    }
    func sendPresence(_ data: Data) -> Bool {
        guard running, online, presenceNamespace != nil, let packet=BoundPresencePacket.decode(data) else { return false }
        diagnosticTrace?.record("transport.presence.send",value:packet.pose == nil ? 0:1,detail:packet.sequence)
        diagnosticTrace?.record("transport.presence.sendCollision",value:packet.pose?.collisionTiles == nil ? 0:1,detail:packet.sequence)
        outgoingPresence = data; sentPresence += 1
        drainPresence()
        return true
    }
    private func drainPresence() {
        guard presenceSending == nil, let namespace = presenceNamespace else { return }
        let run = generation
        presenceSending = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == run { self.presenceSending = nil } }
            while self.running, self.generation == run, !Task.isCancelled, let bytes = self.outgoingPresence {
                self.outgoingPresence = nil
                var request = URLRequest(url: self.url("/presence/\(namespace)/\(self.peer)"))
                request.httpMethod = "PUT"; request.httpBody = bytes
                request.setValue(String(self.epoch), forHTTPHeaderField: "X-Epoch")
                request.setValue(self.fixtureInstance, forHTTPHeaderField: "X-Producer")
                do {
                    let (_, raw) = try await self.session.data(for: request)
                    guard self.generation == run, !Task.isCancelled else { return }
                    if (raw as? HTTPURLResponse)?.statusCode != 200 { self.setOnline(false); return }
                } catch {
                    if self.generation == run, !Task.isCancelled { self.setOnline(false) }
                    return
                }
            }
        }
    }
    private func beginPresencePolling() {
        guard presencePolling == nil, let namespace = presenceNamespace else { return }
        let run = generation
        presencePolling = Task { [weak self] in
            guard let self else { return }
            while self.running, self.generation == run, !Task.isCancelled {
                do {
                    let (bytes, raw) = try await self.session.data(from: self.url("/presence/\(namespace)/\(self.peer)?after=\(self.presenceSequence)"))
                    guard self.generation == run, !Task.isCancelled, let response = raw as? HTTPURLResponse else { return }
                    let epoch = Int(response.value(forHTTPHeaderField: "X-Epoch") ?? "") ?? -1
                    guard epoch >= self.epoch else { continue }
                    self.changeEpoch(epoch)
                    if response.statusCode == 404 { self.setOnline(true) }
                    else if response.statusCode == 200,
                            response.value(forHTTPHeaderField: "X-Peer") == (self.peer == "A" ? "B" : "A"),
                            let sequence = Int(response.value(forHTTPHeaderField: "X-Presence-Sequence") ?? ""),
                            sequence > self.presenceSequence, let packet=BoundPresencePacket.decode(bytes) {
                        self.setOnline(true); self.presenceSequence = sequence
                        self.incomingPresence = bytes; self.receivedPresence += 1
                        self.diagnosticTrace?.record("transport.presence.arrived",value:packet.pose == nil ? 0:1,detail:packet.sequence)
                        self.diagnosticTrace?.record("transport.presence.arrivedCollision",value:packet.pose?.collisionTiles == nil ? 0:1,detail:packet.sequence)
                        self.diagnosticTrace?.record("transport.presence.age",value:ProcessInfo.processInfo.systemUptime-packet.time,detail:packet.sequence)
                        if !self.presencePeerOnline { self.presencePeerOnline = true; self.event?(.remoteJoined) }
                    } else { self.setOnline(false) }
                } catch { if self.generation == run, !Task.isCancelled { self.setOnline(false) } }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
    func setInteractionReceiver(_ receiver: (@MainActor (Data?) -> Void)?) { interactionReceiver = receiver }
    func pollInteractions() {
        let pending = incomingInteractions
        incomingInteractions.removeAll(keepingCapacity: true)
        for data in pending {
            if diagnosticTrace != nil, let packet=BoundMovementPacket.decode(data) {
                diagnosticTrace?.record("transport.movement.received.\(packet.kind.rawValue)",detail:packet.sequence)
            }
            interactionReceiver?(data)
        }
    }
    func sendInteraction(_ data: Data) -> Bool {
        // Match the production control-lane limits/prefixes. The receiving
        // shipping session still validates each packet and its owner/channel.
        guard running, online, presenceNamespace != nil, !data.isEmpty, data.count <= 1024,
              data.starts(with: BoundFriendInteractionPacket.prefix) || data.starts(with: BoundBattleControlPacket.prefix)
                || data.starts(with: BoundMovementPacket.prefix) || data.starts(with: BoundFollowerInteractionPacket.prefix)
                || BoundSoulPacket.recognizes(data) || data.starts(with: BoundWorldPacket.prefix)
                || data.starts(with: Data("BRM1".utf8)) || data.starts(with: BoundCooperativePacket.prefix),
              outgoingInteractions.count < Self.interactionCapacity else { return false }
        outgoingInteractions.append(data); sentInteractions += 1
        if diagnosticTrace != nil, let packet=BoundMovementPacket.decode(data) {
            diagnosticTrace?.record("transport.movement.send.\(packet.kind.rawValue)",detail:packet.sequence)
        }
        drainInteractions(); return true
    }
    private func drainInteractions() {
        guard interactionSending == nil, let namespace = presenceNamespace else { return }
        let run = generation
        interactionSending = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == run { self.interactionSending = nil } }
            while self.running, self.generation == run, !Task.isCancelled, !self.outgoingInteractions.isEmpty {
                let bytes = self.outgoingInteractions.removeFirst(), epoch = self.epoch
                var request = URLRequest(url:self.url("/interaction/\(namespace)/\(self.peer)"))
                request.httpMethod = "PUT"; request.httpBody = bytes
                request.setValue(String(epoch),forHTTPHeaderField:"X-Epoch")
                do {
                    let (_, raw) = try await self.session.data(for:request)
                    guard self.generation == run, !Task.isCancelled else { return }
                    guard self.epoch == epoch else { continue }
                    guard (raw as? HTTPURLResponse)?.statusCode == 200 else {
                        self.outgoingInteractions.removeAll(); self.interactionReceiver?(nil); self.setOnline(false); return
                    }
                } catch {
                    if self.generation == run, !Task.isCancelled {
                        self.outgoingInteractions.removeAll(); self.interactionReceiver?(nil); self.setOnline(false)
                    }
                    return
                }
            }
        }
    }
    private func beginInteractionPolling() {
        guard interactionPolling == nil, let namespace = presenceNamespace else { return }
        let run = generation
        interactionPolling = Task { [weak self] in
            guard let self else { return }
            while self.running, self.generation == run, !Task.isCancelled {
                if self.incomingInteractions.count < Self.interactionCapacity {
                    let requestedEpoch = self.epoch
                    do {
                        let (bytes, raw) = try await self.session.data(from:self.url("/interaction/\(namespace)/\(self.peer)?after=\(self.interactionSequence)"))
                        guard self.generation == run, !Task.isCancelled, let response = raw as? HTTPURLResponse else { return }
                        let epoch = Int(response.value(forHTTPHeaderField:"X-Epoch") ?? "") ?? -1
                        if epoch >= self.epoch {
                            self.changeEpoch(epoch)
                            // An epoch change also clears this request's cursor.
                            // Refetch before admitting a new-epoch message.
                            if epoch == requestedEpoch, response.statusCode == 200,
                               response.value(forHTTPHeaderField:"X-Peer") == (self.peer == "A" ? "B":"A"),
                               let sequence = Int(response.value(forHTTPHeaderField:"X-Interaction-Sequence") ?? ""),
                               sequence > self.interactionSequence, !bytes.isEmpty, bytes.count <= 1024 {
                                self.interactionSequence = sequence; self.incomingInteractions.append(bytes); self.receivedInteractions += 1
                            } else if response.statusCode != 404 && !(response.statusCode == 200 && epoch != requestedEpoch) {
                                self.incomingInteractions.removeAll(); self.interactionReceiver?(nil); self.setOnline(false)
                            }
                        }
                    } catch {
                        if self.generation == run, !Task.isCancelled { self.incomingInteractions.removeAll(); self.interactionReceiver?(nil); self.setOnline(false) }
                    }
                }
                try? await Task.sleep(for:.milliseconds(16))
            }
        }
    }
    private func pollingURL() -> URL {
        var components = URLComponents(url: url("/frame/" + peer), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "after", value: String(lastReceivedSequence)),
                                URLQueryItem(name: "run", value: remoteRun)]
        return components.url!
    }
    private func beginPolling() {
        guard running, pollTask == nil else { return }
        let run = generation
        pollTask = Task { [self] in
            defer { pollTask = nil; if running, generation != run { beginPolling() } }
            while running, generation == run, !Task.isCancelled {
                do {
                    let (data, raw) = try await session.data(from: pollingURL())
                    guard running, generation == run, !Task.isCancelled else { canceledCallbacks += 1; return }
                    guard let response = raw as? HTTPURLResponse else { continue }
                    let packetEpoch = Int(response.value(forHTTPHeaderField: "X-Epoch") ?? "") ?? epoch
                    if packetEpoch < epoch { staleDrops += 1 }
                    else {
                        changeEpoch(packetEpoch)
                        if response.statusCode == 503 { setOnline(false) }
                        else if response.statusCode == 404 { setOnline(true) }
                        else if response.statusCode == 200 {
                            setOnline(true)
                            let sequence = UInt64(response.value(forHTTPHeaderField: "X-Sequence") ?? "") ?? 0
                            let producer = response.value(forHTTPHeaderField: "X-Run") ?? ""
                            let sender = response.value(forHTTPHeaderField: "X-Peer") ?? ""
                            let hash = response.value(forHTTPHeaderField: "X-Hash") ?? ""
                            if sender == peer || producer.isEmpty || sequence == 0 || data.count != SharingFrame.byteCount || (producer == remoteRun && sequence <= lastReceivedSequence) { staleDrops += 1 }
                            else {
                                let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                                if !hash.isEmpty && actualHash != hash { staleDrops += 1 }
                                else {
                                    remoteRun = producer; lastReceivedSequence = sequence
                                    callbacks.receiveFrame(convert: { data })
                                    pendingEvidence = (sequence, actualHash, sender)
                                    event?(.remoteFrame)
                                }
                            }
                        } else { setOnline(false) }
                    }
                    report()
                } catch { if generation == run, running, !Task.isCancelled { setOnline(false); report() } }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }
    func clearPresentation() { presenter.clear() }
    func presentLatestFrame() {
        guard running, online, let host, let pixels = callbacks.takeLatestPixels(), let evidence = pendingEvidence,
              presenter.present(pixels, in: host) else { return }
        pendingEvidence = nil; presentedFrames += 1
        lastPresentedSeq = evidence.sequence; lastPresentedHash = evidence.hash; lastRemotePeer = evidence.peer
        report()
    }
    private func report(force: Bool = false) {
        if force { reportRequired = true }
        let now = ProcessInfo.processInfo.systemUptime
        guard (running || reportRequired), reportTask == nil, (reportRequired || now >= nextReportTime) else { return }
        reportRequired = false; nextReportTime = now + 0.2
        let run = generation
        reportSequence &+= 1
        let metadata: [String: Any] = ["peer": peer, "epoch": epoch, "reportSequence": reportSequence, "run": producerRun, "generation": generation.uuidString, "published": publishedFrames, "presentedCounts": presentedFrames,
            "publishedCounts": publishedFrames, "lastPresentedSeq": lastPresentedSeq, "lastPresentedHash": lastPresentedHash,
            "lastRemotePeer": lastRemotePeer, "staleDrops": staleDrops, "canceledCallbacks": canceledCallbacks, "visible": presenter.isVisible]
        guard let data = try? JSONSerialization.data(withJSONObject: metadata) else { return }
        reportTask = Task { [self] in
            defer { reportTask = nil; if reportRequired { report(force: true) } }
            var request = URLRequest(url: url("/report/" + peer)); request.httpMethod = "POST"; request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            _ = try? await session.data(for: request)
            if generation != run { canceledCallbacks += 1 }
        }
    }
}
#endif
