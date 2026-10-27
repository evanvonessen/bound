#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit
import CoreVideo
import CryptoKit

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
    let peer: String
    let port: Int
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
    var diagnostics: [String: Any] { ["publishedFrames": publishedFrames, "presentedFrames": presentedFrames, "staleDrops": staleDrops, "canceledCallbacks": canceledCallbacks, "decodedImageVisible": presenter.isVisible] }
    init(peer: String, port: Int) {
        self.peer = peer; self.port = port
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1; config.timeoutIntervalForResource = 2
        config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config)
    }
    private func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)" + path)! }
    func start(configuration: FriendSharingConfiguration, remoteView: UIView, event: @escaping @MainActor (FriendSharingEvent) -> Void) {
        stop(); generation = UUID(); producerRun = UUID().uuidString
        host = remoteView; self.event = event; running = true; online = false; announcedJoined = false
        remoteRun = ""; lastReceivedSequence = 0; pendingEvidence = nil
        callbacks.resetFrames(enabled: true); callbacks.resumeFrames(); beginPolling()
    }
    func stop() {
        generation = UUID(); running = false; online = false
        outgoingPending?.cancel(); pollTask?.cancel(); reportTask?.cancel()
        event = nil; host = nil; pendingEvidence = nil
        callbacks.resetFrames(enabled: false); presenter.clear(); report(force: true)
    }
    private func changeEpoch(_ newer: Int) {
        guard newer > epoch else { return }
        epoch = newer; outgoingPending?.cancel()
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
