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
              a.mapGroup == b.mapGroup, a.mapNumber == b.mapNumber, a.elevation == b.elevation,
              abs(a.x - b.x) + abs(a.y - b.y) <= 32 else { return nil }
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
        Section("Recorded player") {
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
        let origin = BoundPlayerState.Point(x: Int(pose.x.rounded()) + scene.camera.x - sprite.width / 2,
                                           y: Int(pose.y.rounded()) + scene.camera.y - sprite.height)
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
    private var origin = BoundPlayerState.Point(x: 0, y: 0)
    private var nativeSize = CGSize.zero
    private(set) var visiblePixels = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; clipsToBounds = true
        accessibilityIdentifier = "bound.recorded-player"
        imageView.layer.magnificationFilter = .nearest; imageView.layer.minificationFilter = .nearest
        addSubview(imageView); isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func show(pose: BoundRecordedPlayerPose?, scene: BoundPlayerScene?) {
        guard let pose, let scene else { isHidden = true; imageView.image = nil; visiblePixels = 0; return }
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
    }
}
