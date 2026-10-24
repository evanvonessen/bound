import Foundation
import UIKit
import SwiftUI

struct BoundRecordedPlayerPose: Equatable, Sendable {
    let mapGroup: Int
    let mapNumber: Int
    let elevation: Int
    let x: Double
    let y: Double
    let appearance: BoundPlayerSprite
}

struct BoundRecordedPlayerSample: Equatable, Sendable {
    let frame: UInt64
    let pose: BoundRecordedPlayerPose?
}

/// Presentation decisions use the actual camera and sprite bounds, never a
/// distance cutoff or the result of foreground occlusion. An occluded sprite
/// is still onscreen and must not acquire a misleading offscreen arrow.
enum BoundPlayerViewport {
    static let size = CGSize(width: 240, height: 160)
    static let bounds = CGRect(origin: .zero, size: size)

    static func origin(pose: BoundRecordedPlayerPose, scene: BoundPlayerScene) -> BoundPlayerState.Point {
        .init(x: Int(pose.x.rounded()) + scene.camera.x - pose.appearance.width / 2,
              y: Int(pose.y.rounded()) + scene.camera.y - pose.appearance.height)
    }

    static func indicator(pose: BoundRecordedPlayerPose, scene: BoundPlayerScene) -> BoundOffscreenPlayerIndicator? {
        let origin = origin(pose: pose, scene: scene)
        let sprite = CGRect(x: origin.x, y: origin.y, width: pose.appearance.width, height: pose.appearance.height)
        guard bounds.intersection(sprite).isEmpty else { return nil }
        let target = CGPoint(x: pose.x + Double(scene.camera.x), y: pose.y + Double(scene.camera.y))
        let distance = hypot(pose.x - Double(scene.worldFoot.x), pose.y - Double(scene.worldFoot.y)) / 16
        return .init(target: target, distanceInTiles: max(1, Int(distance.rounded())))
    }
}

struct BoundOffscreenPlayerIndicator: Equatable {
    let target: CGPoint
    let distanceInTiles: Int

    /// Intersect the camera-center-to-player ray with the label's safe inset.
    /// Label dimensions are included so its entire surface stays in the game.
    func center(labelSize: CGSize) -> CGPoint {
        let viewport = BoundPlayerViewport.bounds
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        let dx = target.x - center.x, dy = target.y - center.y
        let halfWidth = max(0, viewport.width / 2 - labelSize.width / 2 - 4)
        let halfHeight = max(0, viewport.height / 2 - labelSize.height / 2 - 4)
        let horizontal = dx == 0 ? CGFloat.infinity : halfWidth / abs(dx)
        let vertical = dy == 0 ? CGFloat.infinity : halfHeight / abs(dy)
        let scale = min(horizontal, vertical)
        guard scale.isFinite else { return center }
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    var angle: CGFloat {
        atan2(target.y - BoundPlayerViewport.bounds.midY, target.x - BoundPlayerViewport.bounds.midX)
    }
}

/// A bounded, memory-only recording of native pixel positions. Samples retain
/// no camera position: playback always uses the viewer's current camera.
struct BoundRecordedPlayerTrack {
    static let maximumFrames: UInt64 = 1800
    private(set) var samples: [BoundRecordedPlayerSample] = []

    mutating func append(frame: UInt64, pose: BoundRecordedPlayerPose?) {
        guard frame <= Self.maximumFrames, samples.count < 1801,
              samples.last.map({ frame > $0.frame }) ?? true else { return }
        samples.append(.init(frame: frame, pose: pose))
    }
    var isPlayable: Bool { samples.compactMap(\.pose).count >= 2 }
    var end: UInt64 { samples.last?.frame ?? 0 }

    func pose(at frame: UInt64) -> BoundRecordedPlayerPose? {
        guard let first = samples.first, frame >= first.frame, frame <= end else { return nil }
        var lower = 0, upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].frame <= frame { lower = middle + 1 } else { upper = middle }
        }
        let index = lower - 1, sample = samples[index]
        guard let a = sample.pose else { return nil }
        if sample.frame == frame || index + 1 == samples.count { return a }
        let next = samples[index + 1]
        guard let b = next.pose, next.frame - sample.frame <= 8,
              a.mapGroup == b.mapGroup, a.mapNumber == b.mapNumber, a.elevation == b.elevation else { return nil }
        guard abs(a.x - b.x) + abs(a.y - b.y) <= 32 else { return a }
        let fraction = Double(frame - sample.frame) / Double(next.frame - sample.frame)
        return .init(mapGroup: a.mapGroup, mapNumber: a.mapNumber, elevation: a.elevation,
                     x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction, appearance: a.appearance)
    }
}

@MainActor
final class BoundRecordedPlayerSession: ObservableObject {
    enum Mode { case idle, recording, playing }
    @Published private(set) var mode = Mode.idle
    @Published private(set) var message = "Record a walk, then replay it as a second player."
    @Published private(set) var hasRecording = false
    @Published private(set) var available = true
    private(set) var track = BoundRecordedPlayerTrack()
    private(set) var pose: BoundRecordedPlayerPose?
    private var lastFrame: UInt64?
    private var cursor: UInt64 = 0
    private var breakPending = false
    var demandChanged: (() -> Void)?
    var needsReader: Bool { BoundMultiplayerFeatures.isEnabled && mode != .idle }

    func record() {
        guard BoundMultiplayerFeatures.isEnabled, available else { return }
        track = .init(); hasRecording = false; pose = nil; cursor = 0; lastFrame = nil; breakPending = false
        mode = .recording; message = "Resume and walk. Opening the pause menu finishes the recording."
        demandChanged?()
    }
    func finishRecording() {
        guard mode == .recording else { return }
        hasRecording = track.isPlayable; mode = .idle; lastFrame = nil
        message = hasRecording ? "Recorded \(String(format: "%.1f", Double(track.end) / 60)) seconds. Ready to replay."
            : "No walking frames recorded. Resume in the overworld and try again."
        demandChanged?()
    }
    func play() {
        if mode == .recording { finishRecording() }
        guard BoundMultiplayerFeatures.isEnabled, available, hasRecording else { return }
        cursor = 0; lastFrame = nil; pose = nil; mode = .playing
        message = "Resume to play the recorded player."
        demandChanged?()
    }
    func stop() {
        mode = .idle; pose = nil; lastFrame = nil
        message = hasRecording ? "Recording ready to replay." : "Record a walk, then replay it as a second player."
        demandChanged?()
    }
    func clear() {
        track = .init(); hasRecording = false; available = true; stop()
    }
    func unavailable(_ detail: String) {
        stop(); available = false; message = detail
    }
    func suspend() {
        pose = nil; lastFrame = nil; breakPending = true
        if mode == .recording, !track.samples.isEmpty { finishRecording() }
    }

    func consume(_ reading: BoundPlayerStateReading) {
        guard needsReader else { pose = nil; return }
        guard reading.status == .live, let player = reading.player, let scene = player.scene else {
            pose = nil; lastFrame = nil; breakPending = true
            if mode == .playing { message = "Replay hidden while the walking scene is unavailable." }
            return
        }
        let delta = lastFrame.flatMap { reading.frame > $0 ? reading.frame - $0 : nil } ?? 1
        lastFrame = reading.frame
        if mode == .recording {
            if !track.samples.isEmpty { cursor += delta }
            if breakPending, !track.samples.isEmpty {
                track.append(frame: cursor, pose: nil); cursor += 1
            }
            breakPending = false
            track.append(frame: cursor, pose: .init(mapGroup: player.mapGroup, mapNumber: player.mapNumber,
                elevation: player.elevation, x: Double(scene.worldFoot.x), y: Double(scene.worldFoot.y), appearance: scene.appearance))
            if cursor % 15 == 0 { message = "Recording \(String(format: "%.1f", Double(cursor) / 60)) / 30 seconds…" }
            if cursor >= BoundRecordedPlayerTrack.maximumFrames { finishRecording() }
        } else {
            let frame = cursor
            cursor += delta
            if frame > track.end { stop(); return }
            let next = track.pose(at: frame)
            pose = next.flatMap {
                $0.mapGroup == player.mapGroup && $0.mapNumber == player.mapNumber && $0.elevation == player.elevation ? $0 : nil
            }
            message = pose == nil ? "Recorded player is on another map, level, or a recording gap." : "Playing recorded player."
        }
    }
}

struct BoundRecordedPlayerControls: View {
    @ObservedObject var session: BoundRecordedPlayerSession
    var body: some View {
        Section("Recorded Player") {
            Text(session.message).font(.footnote).foregroundStyle(.secondary)
            if session.mode == .recording {
                Button("Finish recording") { session.finishRecording() }
                    .accessibilityIdentifier("bound.recorded-player-finish")
            } else {
                Button("Record movement") { session.record() }
                    .disabled(!session.available).accessibilityIdentifier("bound.recorded-player-record")
            }
            if session.mode == .playing {
                Button("Stop replay") { session.stop() }.accessibilityIdentifier("bound.recorded-player-stop")
            } else {
                Button("Replay recorded player") { session.play() }
                    .disabled(!session.hasRecording || !session.available).accessibilityIdentifier("bound.recorded-player-play")
            }
            Button("Clear recording", role: .destructive) { session.clear() }
                .disabled(!session.hasRecording && session.mode == .idle).accessibilityIdentifier("bound.recorded-player-clear")
        }
    }
}

/// The native framebuffer remains untouched. Foreground BG pixels and nearer
/// object pixels cut holes in the overlay instead of being painted over.
enum BoundRecordedPlayerRasterizer {
    static func rgba(pose: BoundRecordedPlayerPose, scene: BoundPlayerScene) -> (Data, BoundPlayerState.Point) {
        let sprite = pose.appearance
        let origin = BoundPlayerViewport.origin(pose: pose, scene: scene)
        let footY = origin.y + sprite.height
        var rgba = Data(repeating: 0, count: sprite.width * sprite.height * 4)
        for y in 0..<sprite.height {
            for x in 0..<sprite.width {
                let index = sprite.colorIndex(x: x, y: y), sx = origin.x + x, sy = origin.y + y
                guard index != 0, (0..<240).contains(sx), (0..<160).contains(sy),
                      !scene.background.covers(x: sx, y: sy, priority: sprite.priority) else { continue }
                let covered = scene.objects.contains { object in
                    let other = object.appearance
                    guard other.priority < sprite.priority || (other.priority == sprite.priority && object.footY >= footY) else { return false }
                    return other.colorIndex(x: sx - object.origin.x, y: sy - object.origin.y) != 0
                }
                guard !covered else { continue }
                let color = Int(sprite.palette[index * 2]) | Int(sprite.palette[index * 2 + 1]) << 8
                let offset = (y * sprite.width + x) * 4
                rgba[offset] = UInt8((color & 31) * 255 / 31)
                rgba[offset + 1] = UInt8(((color >> 5) & 31) * 255 / 31)
                rgba[offset + 2] = UInt8(((color >> 10) & 31) * 255 / 31)
                rgba[offset + 3] = 255
            }
        }
        return (rgba, origin)
    }
}

@MainActor
final class BoundRecordedPlayerOverlay: UIView {
    private let imageView = UIImageView()
    private let indicatorView = UIView()
    private let indicatorArrow = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let indicatorLabel = UILabel()
    private let indicatorDistanceLabel = UILabel()
    private var origin = BoundPlayerState.Point(x: 0, y: 0)
    private var nativeSize = CGSize.zero
    private(set) var visiblePixels = 0
    private(set) var offscreenIndicator: BoundOffscreenPlayerIndicator?
    private(set) var offscreenText: String?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; clipsToBounds = true
        accessibilityIdentifier = "bound.recorded-player"
        imageView.layer.magnificationFilter = .nearest; imageView.layer.minificationFilter = .nearest
        indicatorView.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        indicatorView.isUserInteractionEnabled = false
        indicatorView.isAccessibilityElement = true
        indicatorView.accessibilityIdentifier = "bound.offscreen-player"
        indicatorArrow.tintColor = .white
        indicatorArrow.contentMode = .scaleAspectFit
        indicatorLabel.textColor = .white
        indicatorLabel.lineBreakMode = .byTruncatingTail
        indicatorDistanceLabel.textColor = .white
        indicatorView.addSubview(indicatorArrow); indicatorView.addSubview(indicatorLabel); indicatorView.addSubview(indicatorDistanceLabel)
        addSubview(imageView); addSubview(indicatorView); isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func show(pose: BoundRecordedPlayerPose?, scene: BoundPlayerScene?, offscreenName: String? = nil) {
        offscreenIndicator = nil; offscreenText = nil; indicatorView.isHidden = true
        guard let pose, let scene else { isHidden = true; imageView.image = nil; visiblePixels = 0; return }
        if let offscreenName, let indicator = BoundPlayerViewport.indicator(pose: pose, scene: scene) {
            offscreenIndicator = indicator
            let name = String(offscreenName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            offscreenText = "\(name.isEmpty ? "Friend" : name) · \(indicator.distanceInTiles) tiles"
            indicatorLabel.text = name.isEmpty ? "Friend" : name
            indicatorDistanceLabel.text = "· \(indicator.distanceInTiles) tiles"
            indicatorView.accessibilityLabel = offscreenText
            indicatorView.isHidden = false; imageView.image = nil; visiblePixels = 0; isHidden = false
            accessibilityValue = "offscreen-player map=\(pose.mapGroup):\(pose.mapNumber) distance=\(indicator.distanceInTiles)"
            setNeedsLayout()
            return
        }
        let (rgba, origin) = BoundRecordedPlayerRasterizer.rgba(pose: pose, scene: scene)
        let sprite = pose.appearance
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: sprite.width, height: sprite.height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: sprite.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { isHidden = true; return }
        self.origin = origin; nativeSize = CGSize(width: sprite.width, height: sprite.height)
        visiblePixels = stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] != 0 }.count
        imageView.image = UIImage(cgImage: image); isHidden = visiblePixels == 0
        accessibilityValue = "recorded-player map=\(pose.mapGroup):\(pose.mapNumber) pixels=\(origin.x),\(origin.y)"
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = CGRect(x: CGFloat(origin.x) * bounds.width / 240, y: CGFloat(origin.y) * bounds.height / 160,
                                 width: nativeSize.width * bounds.width / 240, height: nativeSize.height * bounds.height / 160)
        guard let indicator = offscreenIndicator, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / 240, bounds.height / 160)
        indicatorLabel.font = .systemFont(ofSize: 8 * scale, weight: .medium)
        indicatorDistanceLabel.font = indicatorLabel.font
        let textWidth = min(64 * scale, indicatorLabel.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: 14 * scale)).width)
        let distanceWidth = indicatorDistanceLabel.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: 14 * scale)).width
        let size = CGSize(width: textWidth + distanceWidth + 24 * scale, height: 14 * scale)
        let center = indicator.center(labelSize: CGSize(width: size.width / scale, height: size.height / scale))
        indicatorView.frame = CGRect(x: center.x * bounds.width / 240 - size.width / 2,
                                     y: center.y * bounds.height / 160 - size.height / 2,
                                     width: size.width, height: size.height)
        indicatorView.layer.cornerRadius = 4 * scale
        indicatorArrow.bounds = CGRect(x: 0, y: 0, width: 8 * scale, height: 8 * scale)
        indicatorArrow.center = CGPoint(x: 8 * scale, y: 7 * scale)
        indicatorArrow.transform = CGAffineTransform(rotationAngle: indicator.angle)
        indicatorLabel.frame = CGRect(x: 15 * scale, y: 0, width: textWidth, height: size.height)
        indicatorDistanceLabel.frame = CGRect(x: textWidth + 19 * scale, y: 0, width: distanceWidth, height: size.height)
    }
}
