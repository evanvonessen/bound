import Foundation
import UIKit
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import AgoraRtcKit

/// Preserve strict ordering after the transport's millisecond conversion, including
/// tied capture readings and immediate source restarts. Paired Simulators encoded
/// only the first frame when this started at zero. Keep a stream-relative epoch.
struct AgoraSharingTimestamp {
    private var previous: CMTime?

    mutating func next(capturedAt: TimeInterval) -> CMTime {
        var time = CMTime(seconds: capturedAt + 1, preferredTimescale: 1000)
        if let previous, CMTimeCompare(time, previous) <= 0 {
            time = CMTimeAdd(previous, CMTime(value: 1, timescale: 1000))
        }
        previous = time
        return time
    }
}

enum FriendSharingEvent: Equatable, Sendable {
    case joined, remoteFrame, remoteGone, reconnecting, rejoined, tokenNeeded
    case connection(state: Int, reason: Int)
    case failed(FriendSharingFailure)
}

// SDK callbacks copy decoded pixels into one bounded latest-frame mailbox,
// without a per-frame Task. The display-synchronized receiver consumes it on main;
// engine/UI ownership stays on main and publication uses displayed game frames.
final class AgoraSharingCallbacks: NSObject, AgoraRtcEngineDelegate, AgoraVideoFrameDelegate, @unchecked Sendable {
    let remoteUID: UInt
    let event: @Sendable (FriendSharingEvent, UInt?) -> Void
    private let lock = NSLock()
    private var count = 0
    private var acceptsFrames = true
    private var suspended = false
    private var frameGeneration: UInt64 = 0
    private var converting = false
    private var convertedFrames = 0
    private var replacedFrames = 0
    private var busyDrops = 0
    private var staleDrops = 0
    private var sdkEvidence: [String: Int] = [:]
    private var lastReceivedAt: TimeInterval?
    private var lastConvertedAt: TimeInterval?
    private var latestPresence: Data?
    private var presencePackets = 0
    private var interactions: [Data] = []
    private var interactionFailed = false
    private var interactionFailureReported = false
    private var battleChannel: AgoraBattleChannel?
    func setBattleChannel(_ channel: AgoraBattleChannel?) { lock.lock(); battleChannel=channel; lock.unlock() }
    func rtcEngine(_ engine: AgoraRtcEngineKit, receiveRdtMessageFromUid uid: UInt, type: AgoraRdtStreamType, data: Data) {
        guard uid == remoteUID, (type == .data || type == .cmd), data.count <= 131072 else { return }
        lock.lock(); let channel=battleChannel; lock.unlock(); channel?.receive(data)
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurRdtMessageStateFromUid uid: UInt, state: AgoraRdtState) {
        guard uid == remoteUID else { return }
        NSLog("Bound battle RDT state: %ld",state.rawValue)
        if state == .broken || state == .pending {
            lock.lock(); let channel=battleChannel; lock.unlock(); channel?.failed()
        }
    }
    func takeInteractions() -> (messages: [Data], failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = interactions; interactions.removeAll(keepingCapacity: true)
        let failed = interactionFailed && !interactionFailureReported
        if failed { interactionFailureReported = true }
        return (result, failed)
    }
    func receiveInteraction(_ data: Data, uid: UInt) {
        guard uid == remoteUID, (data.starts(with: BoundFriendInteractionPacket.prefix) || data.starts(with: BoundBattleControlPacket.prefix) || BoundSoulPacket.recognizes(data) || data.starts(with: BoundWorldPacket.prefix)),
              data.count <= BoundFriendInteractionPacket.maximumBytes else { return }
        lock.lock(); defer { lock.unlock() }
        guard acceptsFrames, !suspended, !interactionFailed else { return }
        guard interactions.count < 64 else {
            interactions.removeAll(keepingCapacity: true); interactionFailed = true; return
        }
        interactions.append(data.withUnsafeBytes { Data($0) })
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurStreamMessageErrorFromUid uid: UInt,
                   streamId: Int, error: Int, missed: Int, cached: Int) {
        guard uid == remoteUID else { return }
        lock.lock(); interactionFailed = true; interactions.removeAll(keepingCapacity: true); lock.unlock()
    }
    func suspendFrames() { lock.lock(); suspended = true; frameGeneration &+= 1; count = 0; latestPixels = nil; latestPresence = nil; interactions.removeAll(keepingCapacity: true); interactionFailed = false; interactionFailureReported = false; pixelEvidence = [:]; lock.unlock() }
    func resumeFrames() { lock.lock(); suspended = false; frameGeneration &+= 1; count = 0; latestPixels = nil; pixelEvidence = [:]; lock.unlock() }
    private var pixelEvidence: [String: Int] = [:]
    private var firstRendered = false
    private var latestPixels: Data?
    func takeLatestPixels() -> Data? {
        lock.lock(); defer { lock.unlock() }
        let result = latestPixels; latestPixels = nil; return result
    }
    func takeLatestPresence() -> Data? {
        lock.lock(); defer { lock.unlock() }
        let data = latestPresence; latestPresence = nil; return data
    }
    func receivePresence(_ data: Data, uid: UInt) {
        guard uid == remoteUID, !data.isEmpty, data.count <= BoundPresencePacket.maximumBytes else { return }
        lock.lock(); defer { lock.unlock() }
        guard acceptsFrames, !suspended else { return }
        latestPresence = data.withUnsafeBytes { Data($0) }; presencePackets += 1
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, receiveStreamMessageFromUid uid: UInt, streamId: Int, data: Data) {
        if (data.starts(with: BoundFriendInteractionPacket.prefix) || data.starts(with: BoundBattleControlPacket.prefix) || BoundSoulPacket.recognizes(data) || data.starts(with: BoundWorldPacket.prefix)) { receiveInteraction(data, uid: uid) }
        else { receivePresence(data, uid: uid) }
    }
    var diagnostics: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        var result = pixelEvidence
        result["firstRemoteRendered"] = firstRendered ? 1 : 0
        result["presencePackets"] = presencePackets
        result["convertedFrames"] = convertedFrames
        result["replacedPendingFrames"] = replacedFrames
        result["conversionBusyDrops"] = busyDrops
        result["staleConversionDrops"] = staleDrops
        for (key, value) in sdkEvidence { result[key] = value }
        return result
    }
    var frameTimes: (received: TimeInterval?, converted: TimeInterval?) {
        lock.lock(); defer { lock.unlock() }
        return (lastReceivedAt, lastConvertedAt)
    }
    init(remoteUID: UInt, event: @escaping @Sendable (FriendSharingEvent, UInt?) -> Void) {
        self.remoteUID = remoteUID; self.event = event
    }
    var receivedFrames: Int { lock.lock(); defer { lock.unlock() }; return count }
    func resetFrames(enabled: Bool) { lock.lock(); count = 0; frameGeneration &+= 1; acceptsFrames = enabled; convertedFrames = 0; replacedFrames = 0; busyDrops = 0; staleDrops = 0; lastReceivedAt = nil; lastConvertedAt = nil; pixelEvidence = [:]; firstRendered = false; latestPixels = nil; latestPresence = nil; interactions.removeAll(keepingCapacity: true); interactionFailed = false; interactionFailureReported = false; lock.unlock() }
    func onRenderVideoFrame(_ videoFrame: AgoraOutputVideoFrame, uid: UInt, channelId: String) -> Bool {
        guard uid == remoteUID else { return false }
        let convert = { () -> Data? in
            guard videoFrame.type == 1, let y = videoFrame.yBuffer,
                  let u = videoFrame.uBuffer, let v = videoFrame.vBuffer else { return nil }
            return FriendSharingPixels.rgbaFromI420(width: Int(videoFrame.width), height: Int(videoFrame.height),
                yStride: Int(videoFrame.yStride), uStride: Int(videoFrame.uStride), vStride: Int(videoFrame.vStride),
                y: y, u: u, v: v)
        }
        #if DEBUG
        receiveFrame(convert: convert, evidence: { Self.sample(videoFrame) })
        #else
        receiveFrame(convert: convert)
        #endif
        return true
    }

    // Synchronous callback work owns borrowed SDK planes until conversion ends.
    // One conversion can run at a time; contention drops rather than queues work.
    // Lifecycle methods and main-thread consumption never wait for pixel loops.
    func receiveFrame(convert: () -> Data?, evidence: () -> [String: Int] = { [:] }) {
        lock.lock()
        guard acceptsFrames && !suspended else { lock.unlock(); return }
        count += 1
        lastReceivedAt = CACurrentMediaTime()
        guard !converting else { busyDrops += 1; lock.unlock(); return }
        converting = true
        let generation = frameGeneration
        #if DEBUG
        let sample = count == 1 || count % 12 == 0
        #endif
        lock.unlock()

        let pixels = convert()
        #if DEBUG
        let sampled = sample ? evidence() : nil
        #endif

        lock.lock(); defer { lock.unlock() }
        converting = false
        guard generation == frameGeneration, acceptsFrames, !suspended else { staleDrops += 1; return }
        if let pixels {
            if latestPixels != nil { replacedFrames += 1 }
            latestPixels = pixels; convertedFrames += 1; lastConvertedAt = CACurrentMediaTime()
        }
        #if DEBUG
        if let sampled { pixelEvidence = sampled }
        #endif
    }
    // A small aggregate is sampled while the SDK owns the callback buffer. No
    // pixels, pointers, channel identifiers, or SDK text escape this callback.
    #if DEBUG
    private static func sample(_ frame: AgoraOutputVideoFrame) -> [String: Int] {
        var result = ["decodedWidth": Int(frame.width), "decodedHeight": Int(frame.height),
                      "decodedType": frame.type, "sampleCount": 0]
        var values: [Int] = []
        func samplePlane(_ base: UnsafeRawPointer, width: Int, height: Int, stride: Int, bgra: Bool) {
            guard width > 0, height > 0, width <= 4096, height <= 4096,
                  stride >= width * (bgra ? 4 : 1) else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<8 {
                for x in 0..<8 {
                    let offset = (y * height / 8) * stride + (x * width / 8) * (bgra ? 4 : 1)
                    let value = bgra ? (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3 : Int(bytes[offset])
                    values.append(value)
                }
            }
        }
        if let buffer = frame.pixelBuffer,
           CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess {
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            result["decodedCVFormat"] = Int(CVPixelBufferGetPixelFormatType(buffer))
            if CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) > 0,
               let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                samplePlane(base, width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                            height: CVPixelBufferGetHeightOfPlane(buffer, 0),
                            stride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), bgra: false)
            } else if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                      let base = CVPixelBufferGetBaseAddress(buffer) {
                samplePlane(base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                            stride: CVPixelBufferGetBytesPerRow(buffer), bgra: true)
            }
        } else if frame.type == 1, let base = frame.yBuffer {
            samplePlane(base, width: Int(frame.width), height: Int(frame.height), stride: Int(frame.yStride), bgra: false)
        }
        result["sampleCount"] = values.count
        if !values.isEmpty {
            result["sampleMin"] = values.min()!
            result["sampleMax"] = values.max()!
            result["sampleMean"] = values.reduce(0, +) / values.count
            result["sampleBrightCount"] = values.filter { $0 > 40 }.count
        }
        return result
    }
    #endif
    func rtcEngine(_ engine: AgoraRtcEngineKit, firstRemoteVideoFrameOfUid uid: UInt, size: CGSize, elapsed: Int) {
        guard uid == remoteUID else { return }
        lock.lock(); firstRendered = true; lock.unlock()
    }
    func getObservedFramePosition() -> AgoraVideoFramePosition { .preRenderer }
    // Pinned SDK header AgoraVideoFormatI420 = 1 (planar I420, not CVPixelI420).
    func getVideoFormatPreference() -> AgoraVideoFormat { AgoraVideoFormat(rawValue: 1)! }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        event(.joined, nil)
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        #if DEBUG
        lock.lock()
        sdkEvidence["sdkPeerJoins", default: 0] += 1
        if uid == remoteUID { sdkEvidence["sdkExpectedPeerJoins", default: 0] += 1 }
        lock.unlock()
        #endif
        if uid == remoteUID { resetFrames(enabled: true); event(.remoteFrame, uid) }
    }
    #if DEBUG
    func rtcEngine(_ engine: AgoraRtcEngineKit, firstLocalVideoFramePublishedWithElapsed elapsed: Int,
                   sourceType: AgoraVideoSourceType) {
        lock.lock(); sdkEvidence["sdkFirstPublished"] = 1; lock.unlock()
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, localVideoStats stats: AgoraRtcLocalVideoStats,
                   sourceType: AgoraVideoSourceType) {
        lock.lock()
        sdkEvidence["sdkEncodedFrames"] = stats.encodedFrameCount
        sdkEvidence["sdkSentFPS"] = Int(stats.sentFrameRate)
        sdkEvidence["sdkSentKbps"] = Int(stats.sentBitrate)
        lock.unlock()
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, remoteVideoStats stats: AgoraRtcRemoteVideoStats) {
        guard stats.uid == remoteUID else { return }
        lock.lock()
        sdkEvidence["sdkRemoteStats", default: 0] += 1
        sdkEvidence["sdkRecvKbps"] = Int(stats.receivedBitrate)
        sdkEvidence["sdkDecodedFPS"] = stats.decoderOutputFrameRate
        lock.unlock()
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, remoteVideoStateChangedOfUid uid: UInt,
                   state: AgoraVideoRemoteState, reason: AgoraVideoRemoteReason, elapsed: Int) {
        guard uid == remoteUID else { return }
        lock.lock()
        sdkEvidence["sdkRemoteState"] = Int(state.rawValue)
        sdkEvidence["sdkRemoteReason"] = Int(reason.rawValue)
        lock.unlock()
    }
    #endif
    func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
        if uid == remoteUID { resetFrames(enabled: false); event(.remoteGone, uid) }
    }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) { event(.failed(.init(.sdkError, code: Int(errorCode.rawValue))), nil) }
    func rtcEngineConnectionDidLost(_ engine: AgoraRtcEngineKit) { connectionLost() }
    func rtcEngine(_ engine: AgoraRtcEngineKit, connectionChangedTo state: AgoraConnectionState, reason: AgoraConnectionChangedReason) {
        connectionChanged(state: state, reason: reason)
    }
    // These SDK-typed translation seams also let unit tests exercise the exact
    // callback classification without constructing a live RTC engine.
    func connectionChanged(state: AgoraConnectionState, reason: AgoraConnectionChangedReason) {
        event(.connection(state: Int(state.rawValue), reason: Int(reason.rawValue)), nil)
        if state == .reconnecting { suspendFrames(); event(.reconnecting, nil) }
        if state == .failed { suspendFrames(); event(.failed(.init(.connectionFailed, code: Int(reason.rawValue))), nil) }
    }
    func connectionLost() { suspendFrames(); event(.reconnecting, nil) }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didRejoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        event(.rejoined, nil)
    }
    func rtcEngineRequestToken(_ engine: AgoraRtcEngineKit) { event(.tokenNeeded, nil) }
    func rtcEngine(_ engine: AgoraRtcEngineKit, tokenPrivilegeWillExpire token: String) { event(.tokenNeeded, nil) }
}

/// Pixel pools and conversion have one background owner. A prepared buffer is
/// immutable when returned; only SDK submission remains on its existing owner.
final class AgoraOutgoingPixels: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Bound outgoing pixels", qos: .userInitiated)
    private var pool: CVPixelBufferPool?
    struct Prepared: @unchecked Sendable {
        let buffer: CVPixelBuffer?
        let failure: FriendSharingFailure?
        let creation: CVReturn
    }
    func prepare(_ frame: SharingFrame) async -> Prepared {
        await withCheckedContinuation { reply in
            queue.async { [self] in
                var creation = kCVReturnSuccess
                if pool == nil {
                    creation = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                        [kCVPixelBufferWidthKey: 240, kCVPixelBufferHeightKey: 160,
                         kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                         kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool)
                }
                guard let pool else {
                    reply.resume(returning: Prepared(buffer: nil,
                        failure: .init(.pixelPoolMissing, code: Int(creation)), creation: creation)); return
                }
                var failure: FriendSharingFailure?
                let buffer = FriendSharingPixels.bgraBuffer(frame, pool: pool, failure: { failure = $0 })
                reply.resume(returning: Prepared(buffer: buffer, failure: failure, creation: creation))
            }
        }
    }
}
@MainActor
private final class AgoraPendingSend: SharingCancellation {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

@MainActor
private final class AgoraCompletedSend: SharingCancellation { func cancel() {} }

/// Shared retained presentation boundary, also exercised by offline integration tests.
@MainActor
final class FriendSharingCanvasPresenter {
    private var imageView: UIImageView?
    var isVisible: Bool { imageView?.image != nil }
    @discardableResult func present(_ data: Data, in host: UIView) -> Bool {
        guard data.count == SharingFrame.byteCount,
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: 240, height: 160, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 240 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return false }
        if imageView == nil {
            let view = UIImageView(frame: host.bounds)
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.contentMode = .scaleAspectFit; view.backgroundColor = .black
            host.addSubview(view); imageView = view
        }
        imageView?.image = UIImage(cgImage: image)
        return true
    }
    func clear() { imageView?.image = nil; imageView?.removeFromSuperview(); imageView = nil }
}

@MainActor
final class AgoraSharingTransport: FriendSharingTransport {
    static func encoderConfiguration() -> AgoraVideoEncoderConfiguration {
        AgoraVideoEncoderConfiguration(size: CGSize(width: 240, height: 160),
            frameRate: FriendSharingCadence.framesPerSecond, bitrate: AgoraVideoBitrateStandard,
            orientationMode: .fixedLandscape, mirrorMode: .disabled)
    }
    private var engine: AgoraRtcEngineKit?
    private var callbacks: AgoraSharingCallbacks?
    private var generation = UUID()
    private weak var remoteView: UIView?
    private var remoteUID: UInt = 0
    private var joined = false
    private var recovering = false
    private var recoveryCount = 0
    private var recoverySuccessCount = 0
    private var sdkRejoinCallbacks = 0
    private var lastRecoveryReason: Int?
    private var eventHandler: (@MainActor (FriendSharingEvent) -> Void)?
    private let outgoingPixels = AgoraOutgoingPixels()
    private var setupResult: Int?
    private var poolCreationResult: CVReturn = kCVReturnSuccess
    private var lastFailure: [String: Any] = [:]
    private var lastConnectionState: Int?
    private var lastConnectionReason: Int?
    private var joinResult: Int?
    private var lastPushAccepted: Bool?
    private var attemptedFrames = 0
    private var timestamps = AgoraSharingTimestamp()
    private var lastAttemptedSequence: UInt64 = 0
    private let presenter = FriendSharingCanvasPresenter()
    private var presentedFrames = 0
    private var lastPresentedAt: TimeInterval?
    private var lastPublishedAt: TimeInterval?
    private var presenceReceiver: (@MainActor (Data) -> Void)?
    private var presenceStream: Int?
    private var interactionStream: Int?
    private var interactionReceiver: (@MainActor (Data?) -> Void)?
    private var battleChannel: AgoraBattleChannel?
    private var sentPresence = 0
    private var presenceCreateResult: Int?
    private var presenceSendResult: Int?
    private let metalAvailable = MTLCreateSystemDefaultDevice() != nil

    private(set) var publishedFrames = 0
    var receivedFrames: Int { callbacks?.receivedFrames ?? 0 }
    var frameTiming: FriendSharingFrameTiming? {
        let times = callbacks?.frameTimes
        return FriendSharingFrameTiming(received: times?.received, converted: times?.converted,
                                        presented: lastPresentedAt, published: lastPublishedAt)
    }
    var presenceConnectionCheck: BoundPresenceTransportCheck {
        .init(kind: .agora, streamCreated: presenceStream != nil, createResult: presenceCreateResult,
              sendResult: presenceSendResult, acceptedSends: sentPresence,
              receivedMessages: callbacks?.diagnostics["presencePackets"] ?? 0)
    }

    var diagnostics: [String: Any] {
        var result: [String: Any] = callbacks?.diagnostics ?? [:]
        result["publicationFailure"] = lastFailure
        result["sentPresencePackets"] = sentPresence
        result["recovering"] = recovering
        result["reconnectCount"] = recoveryCount
        result["reconnectSuccessCount"] = recoverySuccessCount
        result["sdkRejoinCallbacks"] = sdkRejoinCallbacks
        if let lastRecoveryReason { result["lastRecoveryReason"] = lastRecoveryReason }
        result["pixelPoolCreationResult"] = Int(poolCreationResult)
        result["attemptedFrames"] = attemptedFrames
        result["lastAttemptedSequence"] = lastAttemptedSequence
        if let lastConnectionState { result["connectionState"] = lastConnectionState }
        if let lastConnectionReason { result["connectionReason"] = lastConnectionReason }
        if let joinResult { result["joinReturn"] = joinResult }
        if let lastPushAccepted { result["lastPushAccepted"] = lastPushAccepted }
        result["metalDeviceAvailable"] = metalAvailable
        result["presentedFrames"] = presentedFrames
        result["decodedImageVisible"] = presenter.isVisible
        if let setupResult { result["setupRemoteVideoResult"] = setupResult }
        func dimensions(_ rect: CGRect) -> [Double] {
            [Double(rect.origin.x), Double(rect.origin.y), Double(rect.width), Double(rect.height)]
        }
        if let view = remoteView {
            result["hostFrame"] = dimensions(view.frame)
            result["hostBounds"] = dimensions(view.bounds)
            result["hostAlpha"] = Double(view.alpha)
            result["hostHidden"] = view.isHidden
            result["hostInWindow"] = view.window != nil
            result["hostLayerBounds"] = dimensions(view.layer.bounds)
            func layerEvidence(_ layer: CALayer, depth: Int) -> [String: Any] {
                var entry: [String: Any] = ["class": String(describing: type(of: layer)),
                    "bounds": dimensions(layer.bounds), "opacity": Double(layer.opacity),
                    "hidden": layer.isHidden, "contentsScale": Double(layer.contentsScale)]
                if let metal = layer as? CAMetalLayer {
                    entry["drawableSize"] = [Double(metal.drawableSize.width), Double(metal.drawableSize.height)]
                    entry["deviceAvailable"] = metal.device != nil
                    entry["pixelFormat"] = metal.pixelFormat.rawValue
                }
                if depth < 4 { entry["children"] = (layer.sublayers ?? []).prefix(8).map { layerEvidence($0, depth: depth + 1) } }
                return entry
            }
            result["rendererLayers"] = layerEvidence(view.layer, depth: 0)
            var ancestors: [[String: Any]] = []
            var parent = view.superview
            while let current = parent, ancestors.count < 8 {
                ancestors.append(["class": String(describing: type(of: current)), "alpha": Double(current.alpha),
                    "hidden": current.isHidden, "bounds": dimensions(current.bounds), "layerOpacity": Double(current.layer.opacity)])
                parent = current.superview
            }
            result["hostAncestors"] = ancestors
            result["hostChildren"] = view.subviews.prefix(8).map { child in
                ["frame": dimensions(child.frame), "bounds": dimensions(child.bounds),
                 "alpha": Double(child.alpha), "hidden": child.isHidden,
                 "layerBounds": dimensions(child.layer.bounds),
                 "childFrames": child.subviews.prefix(8).map { dimensions($0.frame) }] as [String: Any]
            }
        }
        return result
    }

    deinit {
        // Keep SDK/UI disposal on main without an isolated-deinit runtime trampoline.
        // Normal stop() remains synchronous; this fallback also covers off-main release.
        let engine = engine, callbacks = callbacks, remoteView = remoteView
        let presenter = presenter, remoteUID = remoteUID
        BoundMainActorDisposal.enqueue {
            callbacks?.resetFrames(enabled: false)
            guard let engine else { return }
            engine.setVideoFrameDelegate(nil)
            presenter.clear()
            let canvas = AgoraRtcVideoCanvas(); canvas.uid = remoteUID
            engine.setupRemoteVideo(canvas)
            remoteView?.subviews.forEach { $0.removeFromSuperview() }
            remoteView?.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            engine.muteLocalVideoStream(true)
            engine.leaveChannel(nil)
            engine.delegate = nil
            AgoraRtcEngineKit.destroy()
        }
    }

    func start(configuration: FriendSharingConfiguration, remoteView: UIView,
               event: @escaping @MainActor (FriendSharingEvent) -> Void) {
        BoundMainActorDisposal.drainPending()
        stop()
        sentPresence = 0
        presenceCreateResult = nil; presenceSendResult = nil
        lastFailure = [:]; lastConnectionState = nil; lastConnectionReason = nil
        joinResult = nil; lastPushAccepted = nil; attemptedFrames = 0; lastAttemptedSequence = 0
        recoveryCount = 0; recoverySuccessCount = 0; sdkRejoinCallbacks = 0; lastRecoveryReason = nil
        eventHandler = event
        let run = UUID(); generation = run
        self.remoteView = remoteView; remoteUID = configuration.remoteUID
        let proxy = AgoraSharingCallbacks(remoteUID: configuration.remoteUID) { [weak self] value, uid in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == run, self.engine != nil else { return }
                switch value {
                case .joined:
                    if self.recovering { self.completeRecovery() }
                    else { self.joined = true; event(.joined) }
                case .remoteFrame:
                    // Presence only binds the canvas. Receipt is measured separately
                    // by the actual pre-render frame observer, never this join event.
                    if uid == self.remoteUID, !self.recovering {
                        self.engine?.muteRemoteVideoStream(self.remoteUID, mute: false)
                        self.bindRemote()
                    }
                case .remoteGone: self.clearRemote(); if !self.recovering { event(.remoteGone) }
                case .connection(let state, let reason):
                    self.lastConnectionState = state; self.lastConnectionReason = reason
                    if state == Int(AgoraConnectionState.reconnecting.rawValue) { self.lastRecoveryReason = reason }
                    if state == Int(AgoraConnectionState.connected.rawValue) { self.completeRecovery() }
                case .reconnecting: self.suspendForRecovery()
                case .rejoined:
                    self.sdkRejoinCallbacks += 1
                    self.completeRecovery()
                case .tokenNeeded: event(.tokenNeeded)
                case .failed(let failure):
                    self.recordFailure(failure)
                    event(.failed(failure))
                }
            }
        }
        callbacks = proxy
        let config = AgoraRtcEngineConfig()
        config.appId = configuration.appID
        config.channelProfile = .communication
        let logs = AgoraLogConfig(); logs.level = .none; config.logConfig = logs
        let kit = AgoraRtcEngineKit.sharedEngine(with: config, delegate: proxy)
        engine = kit
        // The pinned 4.6.4 SDK leaves its RDT engine disabled by default.
        // Enable the client tunnel before joining; this changes no cloud setup.
        let rdtResult = kit.setParameters("{\"rtc.rdt_enable\":true,\"rtc.rdt_auto_connect\":true}")
        NSLog("Bound battle RDT setup: %d", rdtResult)
        kit.disableAudio()
        kit.setExternalVideoSource(true, useTexture: true, sourceType: .videoFrame)
        kit.enableVideo()
        kit.setVideoFrameDelegate(proxy)
        kit.setVideoEncoderConfiguration(Self.encoderConfiguration())
        let options = AgoraRtcChannelMediaOptions()
        options.publishCameraTrack = false
        options.publishMicrophoneTrack = false
        options.publishCustomVideoTrack = true
        options.customVideoTrackId = 0
        options.autoSubscribeAudio = false
        options.autoSubscribeVideo = true
        options.enableAudioRecordingOrPlayout = false
        options.clientRoleType = .broadcaster
        let result = kit.joinChannel(byToken: configuration.token, channelId: configuration.channel,
                                     uid: configuration.uid, mediaOptions: options)
        joinResult = Int(result)
        if result != 0 {
            let failure = FriendSharingFailure(.joinRejected, code: Int(result))
            recordFailure(failure); event(.failed(failure))
        }
    }

    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        // Finish adapter-owned buffer lifetime before reporting completion, which
        // can synchronously reenter SharingSession. The SDK's internal pipeline
        // owns any references it retains after synchronous push acceptance.
        attemptedFrames += 1; lastAttemptedSequence = frame.sequence
        // The SDK can change state before its delegate reaches the main queue.
        // Suspend that race rather than interpreting a transient push rejection as
        // a terminal error. Completion releases this dropped frame synchronously.
        if engine?.getConnectionState() == .reconnecting {
            suspendForRecovery(); completion(.success(())); return AgoraCompletedSend()
        }
        guard joined else {
            recordFailure(.init(.inactive)); completion(.failure(.transport("Video submission unavailable")))
            return AgoraCompletedSend()
        }
        let pending = AgoraPendingSend(), requestedGeneration = generation
        Task { [self] in
            var prepared: AgoraOutgoingPixels.Prepared? = await outgoingPixels.prepare(frame)
            guard !pending.cancelled, generation == requestedGeneration else {
                prepared = nil; completion(.success(())); return
            }
            // Delegate delivery may lag SDK reconnect state while conversion runs.
            if engine?.getConnectionState() == .reconnecting { suspendForRecovery() }
            guard !recovering else { prepared = nil; completion(.success(())); return }
            poolCreationResult = prepared!.creation
            if let failure = prepared!.failure { recordFailure(failure) }
            let accepted = prepared!.buffer.map { push(frame, buffer: $0) } ?? false
            prepared = nil // Release adapter buffer ownership before reentrant completion.
            if !accepted, recovering { completion(.success(())); return }
            if accepted { publishedFrames += 1; lastPublishedAt = CACurrentMediaTime() }
            completion(accepted ? .success(()) : .failure(.transport("Video submission unavailable")))
        }
        return pending
    }

    private func push(_ frame: SharingFrame, buffer: CVPixelBuffer) -> Bool {
        // Never mutate/reuse a submitted buffer. Conversion's pool bounds any
        // SDK-retained buffers; no native owner or UI thread allocates these pixels.
        guard joined else { recordFailure(.init(.inactive)); return false }
        guard let engine else { recordFailure(.init(.engineUnavailable)); return false }
        let video = AgoraVideoFrame()
        video.format = AgoraVideoFormat.cvPixelBGRA.rawValue
        video.textureBuf = buffer
        video.time = timestamps.next(capturedAt: frame.capturedAt)
        let accepted = withExtendedLifetime(buffer) { engine.pushExternalVideoFrame(video, videoTrackId: 0) }
        lastPushAccepted = accepted
        if !accepted {
            if engine.getConnectionState() == .reconnecting { suspendForRecovery() }
            else { recordFailure(.init(.pushRejected)) }
        }
        return accepted
    }

    private func suspendForRecovery() {
        guard engine != nil, !recovering else { return }
        recovering = true; joined = false; recoveryCount += 1
        lastRecoveryReason = lastConnectionState == Int(AgoraConnectionState.reconnecting.rawValue) ? lastConnectionReason : nil
        callbacks?.suspendFrames()
        clearRemote()
        eventHandler?(.reconnecting)
    }

    private func completeRecovery() {
        // Delegate delivery crosses onto main. A queued old success must not
        // reopen publication after send() observes a newer SDK interruption.
        guard let engine, recovering, engine.getConnectionState() == .connected else { return }
        recovering = false; joined = true; recoverySuccessCount += 1
        callbacks?.resumeFrames()
        engine.muteRemoteVideoStream(remoteUID, mute: false)
        bindRemote()
        eventHandler?(.rejoined)
    }

    func recordRecoveryTimeout() { recordFailure(.init(.reconnectionTimeout)) }

    private func recordFailure(_ failure: FriendSharingFailure) {
        // Keep the FIRST cause through cleanup, including the counters at failure.
        // Intentional stop/destroy callbacks cannot replace this generation's cause.
        guard lastFailure.isEmpty else { return }
        lastFailure = ["category": failure.kind.rawValue, "publishedFrames": publishedFrames,
                       "receivedFrames": receivedFrames, "attemptedFrames": attemptedFrames,
                       "sequence": lastAttemptedSequence]
        if let code = failure.code { lastFailure["code"] = code }
        if let lastConnectionState { lastFailure["connectionState"] = lastConnectionState }
        if let lastConnectionReason { lastFailure["connectionReason"] = lastConnectionReason }
        if let lastPushAccepted { lastFailure["lastPushAccepted"] = lastPushAccepted }
    }

    func presentLatestFrame() {
        guard joined, let data = callbacks?.takeLatestPixels(), let remoteView,
              presenter.present(data, in: remoteView) else { return }
        presentedFrames += 1
        lastPresentedAt = CACurrentMediaTime()
    }

    private func bindRemote() {
        let canvas = AgoraRtcVideoCanvas()
        canvas.uid = remoteUID; canvas.view = remoteView; canvas.renderMode = .fit
        setupResult = engine.map { Int($0.setupRemoteVideo(canvas)) }
    }
    private func clearRemote() {
        presenter.clear()
        presentedFrames = 0
        lastPresentedAt = nil
        let canvas = AgoraRtcVideoCanvas(); canvas.uid = remoteUID
        engine?.setupRemoteVideo(canvas)
        remoteView?.subviews.forEach { $0.removeFromSuperview() }
        remoteView?.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }
    func setPresenceReceiver(_ receiver: (@MainActor (Data) -> Void)?) { presenceReceiver = receiver }
    func pollPresence() {
        guard joined, !recovering, let data = callbacks?.takeLatestPresence() else { return }
        presenceReceiver?(data)
    }
    func makeBattleChannel(receiver: @escaping @Sendable (Data) -> Void, failed: @escaping @Sendable () -> Void) -> (any BoundBattleChannel)? {
        guard joined, !recovering, let engine, remoteUID != 0 else { return nil }
        battleChannel?.close()
        let channel = AgoraBattleChannel(engine: engine, uid: remoteUID, receiver: receiver, failure: failed)
        battleChannel = channel; callbacks?.setBattleChannel(channel)
        return channel
    }
    func setInteractionReceiver(_ receiver: (@MainActor (Data?) -> Void)?) { interactionReceiver = receiver }
    func pollInteractions() {
        guard joined, !recovering, let pending = callbacks?.takeInteractions() else { return }
        if pending.failed { interactionReceiver?(nil); return }
        for data in pending.messages { interactionReceiver?(data) }
    }
    func sendInteraction(_ data: Data) -> Bool {
        guard joined, !recovering, (data.starts(with: BoundFriendInteractionPacket.prefix) || data.starts(with: BoundBattleControlPacket.prefix) || BoundSoulPacket.recognizes(data) || data.starts(with: BoundWorldPacket.prefix)),
              data.count <= BoundFriendInteractionPacket.maximumBytes,
              let engine, engine.getConnectionState() == .connected else { return false }
        if interactionStream == nil {
            var stream = 0
            guard engine.createDataStream(&stream, reliable: true, ordered: true) == 0 else { return false }
            interactionStream = stream
        }
        guard let interactionStream else { return false }
        return engine.sendStreamMessage(interactionStream, data: data) == 0
    }
    func sendPresence(_ data: Data) -> Bool {
        guard joined, !recovering, !data.isEmpty, data.count <= BoundPresencePacket.maximumBytes,
              let engine, engine.getConnectionState() == .connected else { return false }
        if presenceStream == nil {
            var stream = 0
            let config = AgoraDataStreamConfig(); config.ordered = false; config.syncWithAudio = false
            let result = engine.createDataStream(&stream, config: config)
            presenceCreateResult = Int(result)
            guard result == 0 else { return false }
            presenceStream = stream
        }
        guard let presenceStream else { return false }
        let result = engine.sendStreamMessage(presenceStream, data: data)
        presenceSendResult = Int(result)
        guard result == 0 else { return false }
        sentPresence += 1; return true
    }
    func renewToken(_ token: String) -> Bool { engine?.renewToken(token) == 0 }

    func stop() {
        battleChannel?.close(); battleChannel = nil; callbacks?.setBattleChannel(nil)
        presenceStream = nil; interactionStream = nil
        BoundMainActorDisposal.drainPending()
        generation = UUID(); joined = false; recovering = false; eventHandler = nil; setupResult = nil
        callbacks?.resetFrames(enabled: false)
        if let engine {
            engine.setVideoFrameDelegate(nil)
            clearRemote()
            engine.muteLocalVideoStream(true)
            engine.leaveChannel(nil)
            engine.delegate = nil
            AgoraRtcEngineKit.destroy()
        }
        engine = nil; callbacks = nil; remoteView = nil; publishedFrames = 0
        lastPublishedAt = nil; lastPresentedAt = nil
        timestamps = AgoraSharingTimestamp()
    }
}
