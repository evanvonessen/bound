import Foundation
import CoreGraphics

enum BoundControllerButton: String, CaseIterable, Codable, Sendable {
    case friend
    case multiview
    case menu
}

/// Normalized button centers, stored relative to the available controller canvas.
/// A missing or invalid entry falls back to the button's current default frame.
struct BoundControllerButtonPlacement: Codable, Equatable, Sendable {
    private(set) var positions: [BoundControllerButton: CGPoint]
    private(set) var visibleButtons: Set<BoundControllerButton>

    init(positions: [BoundControllerButton: CGPoint] = [:],
         visibleButtons: Set<BoundControllerButton> = [.menu]) {
        self.positions = positions.filter { $0.value.x.isFinite && $0.value.y.isFinite }
            .mapValues { CGPoint(x: Self.unit($0.x), y: Self.unit($0.y)) }
        self.visibleButtons = visibleButtons.union([.menu])
    }

    func isVisible(_ button: BoundControllerButton) -> Bool {
        visibleButtons.contains(button) || button == .menu
    }

    mutating func setVisible(_ visible: Bool, for button: BoundControllerButton) {
        guard button != .menu else { return }
        if visible {
            visibleButtons.insert(button)
        } else {
            visibleButtons.remove(button)
        }
    }

    func frame(for button: BoundControllerButton, defaultFrame: CGRect, canvas: CGRect) -> CGRect {
        guard canvas.isUsable, defaultFrame.isUsable else { return defaultFrame }
        guard let position = positions[button] else { return Self.clamped(defaultFrame, in: canvas) }
        let center = CGPoint(x: canvas.minX + defaultFrame.width / 2
                                + position.x * max(0, canvas.width - defaultFrame.width),
                             y: canvas.minY + defaultFrame.height / 2
                                + position.y * max(0, canvas.height - defaultFrame.height))
        return Self.clamped(CGRect(x: center.x - defaultFrame.width / 2,
                                   y: center.y - defaultFrame.height / 2,
                                   width: defaultFrame.width, height: defaultFrame.height), in: canvas)
    }

    mutating func set(frame: CGRect, for button: BoundControllerButton, canvas: CGRect) {
        guard canvas.isUsable, frame.isUsable else { return }
        let safeFrame = Self.clamped(frame, in: canvas)
        positions[button] = CGPoint(
            x: Self.unit((safeFrame.midX - canvas.minX - safeFrame.width / 2)
                            / max(1, canvas.width - safeFrame.width)),
            y: Self.unit((safeFrame.midY - canvas.minY - safeFrame.height / 2)
                            / max(1, canvas.height - safeFrame.height))
        )
    }

    private enum CodingKeys: String, CodingKey {
        case friend, multiview, menu, visibleButtons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var decoded: [BoundControllerButton: CGPoint] = [:]
        for button in BoundControllerButton.allCases {
            guard let value = try? container.decode(CGPoint.self, forKey: CodingKeys(rawValue: button.rawValue)!),
                  value.x.isFinite, value.y.isFinite else { continue }
            decoded[button] = CGPoint(x: Self.unit(value.x), y: Self.unit(value.y))
        }
        positions = decoded
        // Older placement payloads have no visibility field. The unified editor
        // starts with just the non-removable Menu button visible.
        let stored = (try? container.decode([BoundControllerButton].self, forKey: .visibleButtons)) ?? [.menu]
        visibleButtons = Set(stored).union([.menu])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        for button in BoundControllerButton.allCases {
            if let value = positions[button] {
                try container.encode(value, forKey: CodingKeys(rawValue: button.rawValue)!)
            }
        }
        try container.encode(BoundControllerButton.allCases.filter(isVisible), forKey: .visibleButtons)
    }

    private static func unit(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

    private static func clamped(_ frame: CGRect, in canvas: CGRect) -> CGRect {
        let width = min(frame.width, canvas.width)
        let height = min(frame.height, canvas.height)
        let minX = canvas.minX + width / 2
        let maxX = canvas.maxX - width / 2
        let minY = canvas.minY + height / 2
        let maxY = canvas.maxY - height / 2
        let x = min(maxX, max(minX, frame.midX))
        let y = min(maxY, max(minY, frame.midY))
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }
}

/// User-adjustable game frame. Horizontal position is normalized across the
/// free space left after scaling; scale 1 keeps the supplied maximum frame.
struct BoundControllerGamePlacement: Codable, Equatable, Sendable {
    private(set) var scale: CGFloat
    private(set) var horizontalPosition: CGFloat

    init(scale: CGFloat = 1, horizontalPosition: CGFloat = 0.5) {
        self.scale = Self.normalizedScale(scale)
        self.horizontalPosition = Self.unit(horizontalPosition)
    }

    mutating func set(scale: CGFloat? = nil, horizontalPosition: CGFloat? = nil) {
        if let scale { self.scale = Self.normalizedScale(scale) }
        if let horizontalPosition { self.horizontalPosition = Self.unit(horizontalPosition) }
    }

    func frame(baseFrame: CGRect, canvas: CGRect) -> CGRect {
        guard baseFrame.isUsable, canvas.isUsable else { return baseFrame }
        let width = min(baseFrame.width * scale, canvas.width)
        let height = min(baseFrame.height * scale, canvas.height)
        let travel = max(0, canvas.width - width)
        let x = canvas.minX + travel * horizontalPosition
        let y = min(canvas.maxY - height, max(canvas.minY, baseFrame.midY - height / 2))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private enum CodingKeys: String, CodingKey { case scale, horizontalPosition }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scale = Self.normalizedScale((try? container.decode(CGFloat.self, forKey: .scale)) ?? 1)
        horizontalPosition = Self.unit((try? container.decode(CGFloat.self, forKey: .horizontalPosition)) ?? 0.5)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scale, forKey: .scale)
        try container.encode(horizontalPosition, forKey: .horizontalPosition)
    }

    private static func unit(_ value: CGFloat) -> CGFloat { min(1, max(0, value.isFinite ? value : 0.5)) }
    private static func normalizedScale(_ value: CGFloat) -> CGFloat {
        min(1, max(0.45, value.isFinite ? value : 1))
    }
}

struct BoundControllerButtonDrag {
    struct Result: Equatable {
        let frame: CGRect
        let snappedX: CGFloat?
        let snappedY: CGFloat?
        let didSnap: Bool
        let hint: String?
    }

    private struct SnapTarget {
        let coordinate: CGFloat
        let hint: String
    }

    private struct AxisSnap {
        var target: CGFloat?
        var hint: String?
        var entryTranslation: CGFloat = 0
        var previousRawCenter: CGFloat?
        var disabledTargets = Set<CGFloat>()
        var rebaseOffset: CGFloat = 0
    }

    private let startFrame: CGRect
    private let xTargets: [SnapTarget]
    private let yTargets: [SnapTarget]
    private var xSnap = AxisSnap()
    private var ySnap = AxisSnap()

    private let entryDistance: CGFloat = 6
    private let releaseTravel: CGFloat = 10

    init(startFrame: CGRect, targets: [CGRect]) {
        self.startFrame = startFrame
        self.xTargets = targets.map { SnapTarget(coordinate: $0.midX, hint: "Aligned") }
        self.yTargets = targets.map { SnapTarget(coordinate: $0.midY, hint: "Aligned") }
    }

    /// Adds the canvas center, reflected peer positions, and extrapolated or
    /// midpoint positions that evenly space the dragged button with two peers.
    init(startFrame: CGRect, targets: [CGRect], canvas: CGRect,
         button: BoundControllerButton, otherButtons: [BoundControllerButton: CGRect]) {
        self.startFrame = startFrame
        let peers = BoundControllerButton.allCases.filter { $0 != button && otherButtons[$0] != nil }
        let peerFrames = peers.compactMap { otherButtons[$0] }
        var xs = peerFrames.map { SnapTarget(coordinate: $0.midX, hint: "Aligned") }
        var ys = peerFrames.map { SnapTarget(coordinate: $0.midY, hint: "Aligned") }
        if canvas.isUsable {
            xs.append(SnapTarget(coordinate: canvas.midX, hint: "Centered"))
            ys.append(SnapTarget(coordinate: canvas.midY, hint: "Centered"))
            let peerCenters = peerFrames.map(\.midX)
            let peerCentersY = peerFrames.map(\.midY)
            xs.append(contentsOf: peerCenters.map {
                SnapTarget(coordinate: 2 * canvas.midX - $0, hint: "Mirrored")
            })
            ys.append(contentsOf: peerCentersY.map {
                SnapTarget(coordinate: 2 * canvas.midY - $0, hint: "Mirrored")
            })
            let peersShareRow = (peerCentersY.max() ?? 0) - (peerCentersY.min() ?? 0) <= entryDistance
            let peersShareColumn = (peerCenters.max() ?? 0) - (peerCenters.min() ?? 0) <= entryDistance
            if peerCenters.count >= 2 && peersShareRow {
                for first in 0..<(peerCenters.count - 1) {
                    for second in (first + 1)..<peerCenters.count {
                        let a = peerCenters[first]
                        let b = peerCenters[second]
                        xs.append(SnapTarget(coordinate: (a + b) / 2, hint: "Even spacing"))
                        xs.append(SnapTarget(coordinate: 2 * b - a, hint: "Even spacing"))
                        xs.append(SnapTarget(coordinate: 2 * a - b, hint: "Even spacing"))
                    }
                }
            }
            if peerCentersY.count >= 2 && peersShareColumn {
                for first in 0..<(peerCentersY.count - 1) {
                    for second in (first + 1)..<peerCentersY.count {
                        let top = peerCentersY[first]
                        let bottom = peerCentersY[second]
                        ys.append(SnapTarget(coordinate: (top + bottom) / 2, hint: "Even spacing"))
                        ys.append(SnapTarget(coordinate: 2 * bottom - top, hint: "Even spacing"))
                        ys.append(SnapTarget(coordinate: 2 * top - bottom, hint: "Even spacing"))
                    }
                }
            }
        }
        self.xTargets = Self.uniqueTargets(xs)
        self.yTargets = Self.uniqueTargets(ys)
    }

    init(startFrame: CGRect, targets: [CGRect], canvas: CGRect,
         button: BoundControllerButton, otherButtons: [BoundControllerButton]) {
        self.init(startFrame: startFrame, targets: targets, canvas: canvas, button: button,
                  otherButtons: Dictionary(uniqueKeysWithValues: zip(otherButtons, targets)))
    }

    private static func uniqueTargets(_ targets: [SnapTarget]) -> [SnapTarget] {
        var result: [SnapTarget] = []
        let priority = ["Aligned": 0, "Centered": 1, "Mirrored": 2, "Even spacing": 3]
        for target in targets where target.coordinate.isFinite {
            if let index = result.firstIndex(where: { abs($0.coordinate - target.coordinate) < 0.001 }) {
                if (priority[target.hint] ?? 0) > (priority[result[index].hint] ?? 0) {
                    result[index] = target
                }
            } else {
                result.append(target)
            }
        }
        return result.sorted { $0.coordinate < $1.coordinate }
    }

    mutating func update(translation: CGSize, canvas: CGRect) -> Result {
        guard canvas.isUsable, startFrame.isUsable else {
            return Result(frame: startFrame, snappedX: nil, snappedY: nil, didSnap: false, hint: nil)
        }

        let rawX = startFrame.midX + translation.width + xSnap.rebaseOffset
        let rawY = startFrame.midY + translation.height + ySnap.rebaseOffset
        let enteredX = update(axis: &xSnap, startCenter: startFrame.midX,
                              rawCenter: rawX, translation: translation.width,
                              targets: xTargets, lower: canvas.minX + startFrame.width / 2,
                              upper: canvas.maxX - startFrame.width / 2)
        let enteredY = update(axis: &ySnap, startCenter: startFrame.midY,
                              rawCenter: rawY, translation: translation.height,
                              targets: yTargets, lower: canvas.minY + startFrame.height / 2,
                              upper: canvas.maxY - startFrame.height / 2)

        let freeX = startFrame.midX + translation.width + xSnap.rebaseOffset
        let freeY = startFrame.midY + translation.height + ySnap.rebaseOffset
        let centerX = min(canvas.maxX - startFrame.width / 2,
                          max(canvas.minX + startFrame.width / 2, xSnap.target ?? freeX))
        let centerY = min(canvas.maxY - startFrame.height / 2,
                          max(canvas.minY + startFrame.height / 2, ySnap.target ?? freeY))
        let frame = CGRect(x: centerX - startFrame.width / 2,
                           y: centerY - startFrame.height / 2,
                           width: startFrame.width, height: startFrame.height)
        let hints = [xSnap.hint, ySnap.hint].compactMap { $0 }
        let hintPriority = ["Aligned": 0, "Centered": 1, "Mirrored": 2, "Even spacing": 3]
        let hint = hints.max { (hintPriority[$0] ?? 0) < (hintPriority[$1] ?? 0) }
        return Result(frame: frame, snappedX: xSnap.target, snappedY: ySnap.target,
                      didSnap: enteredX || enteredY, hint: hint)
    }

    private func update(axis: inout AxisSnap, startCenter: CGFloat,
                        rawCenter: CGFloat, translation: CGFloat,
                        targets: [SnapTarget], lower: CGFloat, upper: CGFloat) -> Bool {
        let previousRawCenter = axis.previousRawCenter
        axis.previousRawCenter = rawCenter
        if let target = axis.target {
            if abs(translation - axis.entryTranslation) >= releaseTravel {
                axis.target = nil
                axis.hint = nil
                // Rebase at the snapped position so releasing the soft snap is smooth.
                axis.rebaseOffset = target - startCenter - translation
                axis.previousRawCenter = target
                axis.disabledTargets.insert(target)
                return false
            }
            return false
        }

        // A released target becomes available again as soon as the button has
        // moved clearly away. This allows users to cross that guide again in
        // the same drag without the old one-shot snap suppression.
        axis.disabledTargets = axis.disabledTargets.filter { abs(rawCenter - $0) <= releaseTravel }

        guard upper >= lower else { return false }
        let eligible = targets.filter {
            !axis.disabledTargets.contains($0.coordinate) && $0.coordinate >= lower && $0.coordinate <= upper
        }
        let near = eligible.map { ($0, abs($0.coordinate - rawCenter)) }
            .filter { $0.1 <= entryDistance }
        // Gesture updates can jump across a guide between samples. Catch any
        // crossing segment; among several guides, the closest to the endpoint
        // wins so the button follows the direction of travel.
        let crossed = eligible.filter { target in
            guard let previousRawCenter else { return false }
            if rawCenter > previousRawCenter {
                return target.coordinate > previousRawCenter && target.coordinate <= rawCenter
            }
            if rawCenter < previousRawCenter {
                return target.coordinate < previousRawCenter && target.coordinate >= rawCenter
            }
            return false
        }.map { ($0, abs($0.coordinate - rawCenter)) }
        let candidate = (near.isEmpty ? crossed : near).min { $0.1 < $1.1 }
        guard let candidate else { return false }
        axis.target = candidate.0.coordinate
        axis.hint = candidate.0.hint
        axis.entryTranslation = translation
        return true
    }
}

private extension CGRect {
    var isUsable: Bool {
        !isNull && !isInfinite && origin.x.isFinite && origin.y.isFinite
            && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
