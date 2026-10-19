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

    init(positions: [BoundControllerButton: CGPoint] = [:]) {
        self.positions = positions.filter { $0.value.x.isFinite && $0.value.y.isFinite }
            .mapValues { CGPoint(x: Self.unit($0.x), y: Self.unit($0.y)) }
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
        case friend, multiview, menu
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        for button in BoundControllerButton.allCases {
            if let value = positions[button] {
                try container.encode(value, forKey: CodingKeys(rawValue: button.rawValue)!)
            }
        }
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

struct BoundControllerButtonDrag {
    struct Result: Equatable {
        let frame: CGRect
        let snappedX: CGFloat?
        let snappedY: CGFloat?
        let didSnap: Bool
    }

    private struct AxisSnap {
        var target: CGFloat?
        var targetIndex: Int?
        var entryTranslation: CGFloat = 0
        var disabledTargets = Set<CGFloat>()
        var rebaseOffset: CGFloat = 0
    }

    private let startFrame: CGRect
    private let targets: [CGRect]
    private var xSnap = AxisSnap()
    private var ySnap = AxisSnap()

    private let entryDistance: CGFloat = 6
    private let releaseTravel: CGFloat = 10

    init(startFrame: CGRect, targets: [CGRect]) {
        self.startFrame = startFrame
        self.targets = targets
    }

    mutating func update(translation: CGSize, canvas: CGRect) -> Result {
        guard canvas.isUsable, startFrame.isUsable else {
            return Result(frame: startFrame, snappedX: nil, snappedY: nil, didSnap: false)
        }

        let rawX = startFrame.midX + translation.width + xSnap.rebaseOffset
        let rawY = startFrame.midY + translation.height + ySnap.rebaseOffset
        let enteredX = update(axis: &xSnap, startCenter: startFrame.midX,
                              rawCenter: rawX, translation: translation.width,
                              targets: targets.map(\.midX), lower: canvas.minX + startFrame.width / 2,
                              upper: canvas.maxX - startFrame.width / 2)
        let enteredY = update(axis: &ySnap, startCenter: startFrame.midY,
                              rawCenter: rawY, translation: translation.height,
                              targets: targets.map(\.midY), lower: canvas.minY + startFrame.height / 2,
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
        return Result(frame: frame, snappedX: xSnap.target, snappedY: ySnap.target,
                      didSnap: enteredX || enteredY)
    }

    private func update(axis: inout AxisSnap, startCenter: CGFloat,
                        rawCenter: CGFloat, translation: CGFloat,
                        targets: [CGFloat], lower: CGFloat, upper: CGFloat) -> Bool {
        if let target = axis.target {
            if abs(translation - axis.entryTranslation) >= releaseTravel {
                axis.target = nil
                axis.targetIndex = nil
                axis.disabledTargets.insert(target)
                // Rebase the free drag at the snapped position so releasing the soft snap is smooth.
                axis.rebaseOffset = target - startCenter - translation
                return false
            }
            return false
        }

        guard upper >= lower else { return false }
        let candidate = targets.enumerated()
            .filter { !axis.disabledTargets.contains($0.element) && $0.element >= lower && $0.element <= upper }
            .map { ($0.offset, $0.element, abs($0.element - rawCenter)) }
            .filter { $0.2 <= entryDistance }
            .min { $0.2 < $1.2 }
        guard let candidate else { return false }
        axis.target = candidate.1
        axis.targetIndex = candidate.0
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
