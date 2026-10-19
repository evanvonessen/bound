import Foundation
import CoreGraphics

enum BoundLandscapeOption: Int, CaseIterable, Sendable {
    case option1 = 1
    case option2 = 2
    case option3 = 3
    case option4 = 4
    case option5 = 5
    case option6 = 6
    case option7 = 7

    var supportsArrangement: Bool { self == .option3 || self == .option4 || self == .option5 || self == .option6 || self == .option7 }

    var title: String { "Option \(rawValue)" }
}

/// Position and appearance of the landscape friend video, stored as a single value.
struct BoundLandscapeFriendPlacement: Codable, Equatable, Sendable {
    var center: CGPoint
    var widthFraction: CGFloat
    var opacity: CGFloat

    init(center: CGPoint = CGPoint(x: 0.75, y: 0.3), widthFraction: CGFloat = 0.28, opacity: CGFloat = 0.85) {
        self.center = CGPoint(x: Self.normalized(center.x, fallback: 0.75),
                              y: Self.normalized(center.y, fallback: 0.3))
        self.widthFraction = Self.clamp(widthFraction, to: 0.15...0.6, fallback: 0.28)
        self.opacity = Self.clamp(opacity, to: 0.35...1, fallback: 0.85)
    }

    private static func normalized(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(1, max(0, value))
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

@MainActor
final class BoundLandscapePreferences {
    static let didChangeNotification = Notification.Name("BoundLandscapePreferencesDidChange")

    private let defaults: UserDefaults
    private let namespace: String

    init(defaults: UserDefaults = .standard, namespace: String = "bound.landscape.v1") {
        self.defaults = defaults
        self.namespace = namespace
    }

    private func key(_ suffix: String) -> String { namespace + "." + suffix }

    var option: BoundLandscapeOption {
        get {
            guard let raw = defaults.object(forKey: key("option")) as? Int else { return .option7 }
            return BoundLandscapeOption(rawValue: raw) ?? .option1
        }
        set {
            guard option != newValue else { return }
            defaults.set(newValue.rawValue, forKey: key("option"))
            notifyChange()
        }
    }

    /// Defaults to every reference panel in its established cycle order. Friend is
    /// controlled independently and is never part of this selection.
    var referenceContents: [BoundPiPContent] {
        get {
            guard let saved = defaults.stringArray(forKey: key("reference-contents")) else {
                return BoundPiPContent.cycleOrder.filter { $0 != .friend }
            }
            var seen = Set<BoundPiPContent>()
            return saved.compactMap { raw in
                guard let content = BoundPiPContent(rawValue: raw), content != .friend,
                      seen.insert(content).inserted else { return nil }
                return content
            }
        }
        set {
            var seen = Set<BoundPiPContent>()
            let normalized = newValue.filter { $0 != .friend && seen.insert($0).inserted }.map(\.rawValue)
            let preferenceKey = key("reference-contents")
            guard defaults.stringArray(forKey: preferenceKey) != normalized else { return }
            defaults.set(normalized, forKey: preferenceKey)
            notifyChange()
        }
    }

    /// The active reference view always resolves to a selectable non-friend view.
    var referenceContent: BoundPiPContent {
        get {
            if let raw = defaults.string(forKey: key("reference-content")),
               let saved = BoundPiPContent(rawValue: raw), saved != .friend,
               referenceContents.contains(saved) { return saved }
            return referenceContents.first ?? .notes
        }
        set {
            guard newValue != .friend, referenceContents.contains(newValue),
                  referenceContent != newValue else { return }
            defaults.set(newValue.rawValue, forKey: key("reference-content"))
            notifyChange()
        }
    }

    var friendVisible: Bool {
        get { defaults.object(forKey: key("friend-visible")) as? Bool ?? true }
        set { setBoolean(newValue, suffix: "friend-visible") }
    }

    var referenceVisible: Bool {
        get { defaults.object(forKey: key("reference-visible")) as? Bool ?? false }
        set { setBoolean(newValue, suffix: "reference-visible") }
    }

    /// Relative size multiplier for the interactive landscape reference panel.
    var referenceScale: CGFloat {
        get {
            let saved = defaults.object(forKey: key("reference-scale")) as? Double ?? 1
            return Self.clamp(CGFloat(saved), to: 0.8...1.3, fallback: 1)
        }
        set {
            let normalized = Self.clamp(newValue, to: 0.8...1.3, fallback: 1)
            let preferenceKey = key("reference-scale")
            guard abs(referenceScale - normalized) > 0.0001 else { return }
            defaults.set(Double(normalized), forKey: preferenceKey)
            notifyChange()
        }
    }

    var friendPlacement: BoundLandscapeFriendPlacement {
        get {
            guard let data = defaults.data(forKey: key("friend-placement")),
                  let decoded = try? JSONDecoder().decode(BoundLandscapeFriendPlacement.self, from: data) else {
                return BoundLandscapeFriendPlacement()
            }
            return BoundLandscapeFriendPlacement(center: decoded.center,
                                                 widthFraction: decoded.widthFraction,
                                                 opacity: decoded.opacity)
        }
        set {
            let normalized = BoundLandscapeFriendPlacement(center: newValue.center,
                                                            widthFraction: newValue.widthFraction,
                                                            opacity: newValue.opacity)
            guard normalized != friendPlacement,
                  let data = try? JSONEncoder().encode(normalized) else { return }
            defaults.set(data, forKey: key("friend-placement"))
            notifyChange()
        }
    }

    /// Normalized center for the interactive reference panel.
    var referenceCenter: CGPoint {
        get {
            let point = decodePoint(key("reference-center")) ?? CGPoint(x: 0.5, y: 0.3)
            return CGPoint(x: Self.normalized(point.x, fallback: 0.5),
                           y: Self.normalized(point.y, fallback: 0.3))
        }
        set {
            let normalized = CGPoint(x: Self.normalized(newValue.x, fallback: 0.5),
                                     y: Self.normalized(newValue.y, fallback: 0.5))
            guard normalized != referenceCenter,
                  let data = try? JSONEncoder().encode(PointValue(point: normalized)) else { return }
            defaults.set(data, forKey: key("reference-center"))
            notifyChange()
        }
    }

    private struct PointValue: Codable { var point: CGPoint }

    private func decodePoint(_ preferenceKey: String) -> CGPoint? {
        guard let data = defaults.data(forKey: preferenceKey),
              let value = try? JSONDecoder().decode(PointValue.self, from: data) else { return nil }
        return value.point
    }

    private static func normalized(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(1, max(0, value))
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private func setBoolean(_ value: Bool, suffix: String) {
        let preferenceKey = key(suffix)
        guard (defaults.object(forKey: preferenceKey) as? Bool ?? (suffix == "friend-visible")) != value else { return }
        defaults.set(value, forKey: preferenceKey)
        notifyChange()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

/// Landscape placement rules: friend video can cover game controls when locked;
/// interactive views and companion buttons use `referenceFrame` and remain clear.
enum BoundLandscapeGeometry {
    static func friendFrame(canvas: CGRect, placement: BoundLandscapeFriendPlacement) -> CGRect {
        guard valid(canvas), placement.widthFraction.isFinite else { return .zero }
        let aspect: CGFloat = 1.5
        let width = min(canvas.width, canvas.height * aspect,
                        max(0, canvas.width * placement.widthFraction))
        guard width > 0, canvas.height > 0 else { return .zero }
        let height = width / aspect
        let center = CGPoint(x: canvas.minX + normalized(placement.center.x) * canvas.width,
                             y: canvas.minY + normalized(placement.center.y) * canvas.height)
        let x = min(max(center.x - width / 2, canvas.minX), canvas.maxX - width)
        let y = min(max(center.y - height / 2, canvas.minY), canvas.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func normalizedCenter(frame: CGRect, canvas: CGRect) -> CGPoint {
        guard valid(canvas), finite(frame.midX), finite(frame.midY) else { return CGPoint(x: 0.75, y: 0.3) }
        return CGPoint(x: normalized((frame.midX - canvas.minX) / canvas.width),
                       y: normalized((frame.midY - canvas.minY) / canvas.height))
    }

    /// Finds the closest placement to the normalized preferred center without
    /// intersecting any occupied controller/button rectangles. It shrinks a view
    /// only as far as `minimumSize`, preserving its requested aspect ratio.
    static func referenceFrame(canvas: CGRect, preferredCenter: CGPoint, preferredSize: CGSize,
                               occupied: [CGRect], minimumSize: CGSize) -> CGRect? {
        guard valid(canvas), finite(preferredSize.width), finite(preferredSize.height),
              finite(minimumSize.width), finite(minimumSize.height),
              preferredSize.width > 0, preferredSize.height > 0,
              minimumSize.width > 0, minimumSize.height > 0 else { return nil }
        let obstacles = occupied.filter(valid)
        let center = CGPoint(x: canvas.minX + normalized(preferredCenter.x) * canvas.width,
                             y: canvas.minY + normalized(preferredCenter.y) * canvas.height)
        let maxScale = min(1, canvas.width / preferredSize.width, canvas.height / preferredSize.height)
        guard maxScale > 0 else { return nil }
        let minScale = max(minimumSize.width / preferredSize.width,
                           minimumSize.height / preferredSize.height)
        guard maxScale + 0.0001 >= minScale else { return nil }

        func frame(scale: CGFloat) -> CGRect? {
            let size = CGSize(width: preferredSize.width * scale, height: preferredSize.height * scale)
            guard size.width + 0.0001 >= minimumSize.width,
                  size.height + 0.0001 >= minimumSize.height,
                  let clearCenter = closestClearCenter(preferred: center, size: size, canvas: canvas,
                                                       occupied: obstacles) else { return nil }
            return CGRect(x: clearCenter.x - size.width / 2, y: clearCenter.y - size.height / 2,
                          width: size.width, height: size.height)
        }
        if let exact = frame(scale: maxScale) { return exact }
        // Search downward; keep the largest usable size, stopping at the minimum.
        var low = minScale, high = maxScale
        guard frame(scale: low) != nil else { return nil }
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if frame(scale: mid) != nil { low = mid } else { high = mid }
        }
        return frame(scale: low)
    }

    private static func closestClearCenter(preferred: CGPoint, size: CGSize, canvas: CGRect,
                                           occupied: [CGRect]) -> CGPoint? {
        guard size.width <= canvas.width, size.height <= canvas.height else { return nil }
        let halfW = size.width / 2, halfH = size.height / 2
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, canvas.minX + halfW), canvas.maxX - halfW),
                    y: min(max(p.y, canvas.minY + halfH), canvas.maxY - halfH))
        }
        func clear(_ point: CGPoint) -> Bool {
            let rect = CGRect(x: point.x - halfW, y: point.y - halfH, width: size.width, height: size.height)
            // A shared edge has no covered area, so an edge-aligned panel is clear.
            return !occupied.contains {
                min(rect.maxX, $0.maxX) > max(rect.minX, $0.minX) &&
                    min(rect.maxY, $0.maxY) > max(rect.minY, $0.minY)
            }
        }
        let origin = clamp(preferred)
        if clear(origin) { return origin }
        var xs = [origin.x, canvas.minX + halfW, canvas.maxX - halfW]
        var ys = [origin.y, canvas.minY + halfH, canvas.maxY - halfH]
        for obstacle in occupied {
            xs += [obstacle.minX - halfW, obstacle.maxX + halfW]
            ys += [obstacle.minY - halfH, obstacle.maxY + halfH]
        }
        var best: CGPoint?
        var bestDistance = CGFloat.infinity
        for x in xs { for y in ys {
            let point = clamp(CGPoint(x: x, y: y))
            let dx = point.x - origin.x, dy = point.y - origin.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance && clear(point) {
                best = point
                bestDistance = distance
            }
        } }
        return best
    }

    private static func normalized(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }

    private static func finite(_ value: CGFloat) -> Bool { value.isFinite }
    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && finite(rect.minX) && finite(rect.minY) &&
            finite(rect.width) && finite(rect.height) && rect.width > 0 && rect.height > 0
    }
}
