import Foundation
import CoreGraphics

enum BoundControllerButton: String, CaseIterable, Codable, Sendable {
    case friend
    case multiview
    case menu
}

/// Distance grid used by the compact landscape controls. The value is in
/// points: 18 pt is approximately 3 mm on a typical iPhone display.
enum BoundControllerButtonGridPreferences {
    static let enabledKey = "bound.controller-button-grid.enabled"
    static let spacingKey = "bound.controller-button-grid.spacing"
    static let defaultEnabled = true
    static let defaultSpacing: CGFloat = 18
    static let minimumSpacing: CGFloat = 6
    static let maximumSpacing: CGFloat = 48

    /// Unset installs use the grid. An explicit saved false remains an opt-out.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: enabledKey) as? Bool) ?? defaultEnabled
    }

    static func spacing(in defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.object(forKey: spacingKey) as? NSNumber
        return normalized(stored.map { CGFloat($0.doubleValue) } ?? defaultSpacing)
    }

    static func setSpacing(_ spacing: CGFloat, in defaults: UserDefaults = .standard) {
        defaults.set(Double(normalized(spacing)), forKey: spacingKey)
    }

    static func normalized(_ spacing: CGFloat) -> CGFloat {
        min(maximumSpacing, max(minimumSpacing, spacing.isFinite ? spacing : defaultSpacing))
    }
}

enum BoundControllerButtonGrid {
    static func quantize(_ coordinate: CGFloat, centeredAt center: CGFloat, spacing: CGFloat,
                         minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let step = BoundControllerButtonGridPreferences.normalized(spacing)
        let first = center + ceil((minimum - center) / step) * step
        let last = center + floor((maximum - center) / step) * step
        guard first <= last else { return min(maximum, max(minimum, coordinate)) }
        let nearest = center + ((coordinate - center) / step).rounded() * step
        return min(last, max(first, nearest))
    }
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

    private let startFrame: CGRect
    private let distanceSnapping: Bool
    private let spacing: CGFloat
    private let gridCenter: CGPoint
    private var lastGridCenter: CGPoint?

    init(startFrame: CGRect, distanceSnapping: Bool = false,
         spacing: CGFloat = BoundControllerButtonGridPreferences.defaultSpacing,
         gridCenter: CGPoint) {
        self.startFrame = startFrame
        self.distanceSnapping = distanceSnapping
        self.spacing = BoundControllerButtonGridPreferences.normalized(spacing)
        self.gridCenter = gridCenter
    }

    mutating func update(translation: CGSize, canvas: CGRect) -> Result {
        guard canvas.isUsable, startFrame.isUsable else {
            return Result(frame: startFrame, snappedX: nil, snappedY: nil, didSnap: false, hint: nil)
        }

        let rawX = startFrame.midX + translation.width
        let rawY = startFrame.midY + translation.height
        let lowerX = canvas.minX + startFrame.width / 2
        let upperX = canvas.maxX - startFrame.width / 2
        let lowerY = canvas.minY + startFrame.height / 2
        let upperY = canvas.maxY - startFrame.height / 2
        let centerX: CGFloat
        let centerY: CGFloat
        if distanceSnapping {
            centerX = BoundControllerButtonGrid.quantize(rawX, centeredAt: gridCenter.x, spacing: spacing,
                                                          minimum: lowerX, maximum: upperX)
            centerY = BoundControllerButtonGrid.quantize(rawY, centeredAt: gridCenter.y, spacing: spacing,
                                                          minimum: lowerY, maximum: upperY)
        } else {
            centerX = min(upperX, max(lowerX, rawX))
            centerY = min(upperY, max(lowerY, rawY))
        }
        let frame = CGRect(x: centerX - startFrame.width / 2,
                           y: centerY - startFrame.height / 2,
                           width: startFrame.width, height: startFrame.height)
        let previousGridCenter = lastGridCenter ?? CGPoint(x: startFrame.midX, y: startFrame.midY)
        let didSnap = distanceSnapping
            && (abs(centerX - previousGridCenter.x) > 0.001 || abs(centerY - previousGridCenter.y) > 0.001)
        if distanceSnapping { lastGridCenter = CGPoint(x: centerX, y: centerY) }
        return Result(frame: frame, snappedX: distanceSnapping ? centerX : nil,
                      snappedY: distanceSnapping ? centerY : nil,
                      didSnap: didSnap, hint: distanceSnapping ? "Grid" : nil)
    }
}

private extension CGRect {
    var isUsable: Bool {
        !isNull && !isInfinite && origin.x.isFinite && origin.y.isFinite
            && width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
