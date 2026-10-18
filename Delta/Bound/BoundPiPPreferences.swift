import Foundation
import CoreGraphics

// Original Bound's PiP interaction policy; storage is isolated from its account preferences.
enum BoundPiPCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}
enum BoundPiPContent: String, CaseIterable, Sendable {
    case friend, types, notes, bosses, dex
    var title: String { self == .dex ? "RR Dex" : rawValue.capitalized }
    static let cycleOrder: [Self] = [.friend, .notes, .types, .bosses, .dex]
}
enum BoundPiPHiddenSide: String, Sendable { case left, right }

enum BoundUIVersion: Int, CaseIterable, Sendable {
    case option1 = 1, option2 = 2
    var title: String { "Option \(rawValue)" }
}

final class BoundUIVersionPreferences {
    static let key = "bound.ui.version.v1"
    static let didChangeNotification = Notification.Name("BoundUIVersionDidChange")
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var version: BoundUIVersion {
        get { BoundUIVersion(rawValue: defaults.integer(forKey: Self.key)) ?? .option1 }
        set {
            guard version != newValue else { return }
            defaults.set(newValue.rawValue, forKey: Self.key)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    var effectiveVersion: BoundUIVersion {
        version
    }
}

enum BoundReferenceLayout: Int, CaseIterable, Sendable {
    case layout1 = 1, layout2 = 2, layout3 = 3, layout4 = 4, layout5 = 5, layout6 = 6, layout7 = 7, layout8 = 8, layout9 = 9, layout10 = 10, layout11 = 11, layout12 = 12
    static var bossLayouts: [Self] { allCases }
    var title: String { "Layout \(rawValue)" }
    var descriptiveName: String {
        switch self {
        case .layout1: "Original"
        case .layout2: "Quick reference"
        case .layout3: "Full portrait"
        case .layout4: "Expandable details"
        case .layout5: "At a glance"
        case .layout6: "Priority stats"
        case .layout7: "Detailed classic"
        case .layout8: "Island controls"
        case .layout9: "Inline learnset"
        case .layout10: "Compact matchups"
        case .layout11: "Trainer navigation"
        case .layout12: "Expanded reference"
        }
    }
    func descriptiveName(isBoss: Bool) -> String {
        if isBoss {
            return switch self {
            case .layout5: "Moves or stats"
            case .layout6: "Moves and stats"
            case .layout7: "Speed reference"
            case .layout9: "Team focus"
            case .layout12: "Expanded team"
            default: descriptiveName
            }
        }
        return self == .layout11 ? "Collapsible learnset" : descriptiveName
    }
    var summary: String {
        switch self {
        case .layout1: "The original reference view."
        case .layout2: "More reference details and quick shortcuts."
        case .layout3: "Uses the full portrait space around the Dynamic Island."
        case .layout4: "Larger controls with expandable secondary details."
        case .layout5: "More information at a glance, with quick access to details."
        case .layout6: "Keeps key stats in view and makes secondary details easier to reach."
        case .layout7: "The original reference view with colored stats, more detail, and compact shortcuts."
        case .layout8: "More room for details, with Island controls and larger reference shortcuts."
        case .layout9: "Layout 8's design; RR Dex adds an inline, searchable learnset."
        case .layout10: "Layout 9 with compact matchup summaries and nature effects."
        case .layout11: "Layout 10 with a larger Boss View trainer icon and an inset trainer picker."
        case .layout12: "Layout 11 with full-color matchups, wider boss team icons, and shorter move labels."
        }
    }
}

enum BoundReferenceLayoutPreferences {
    // Separate, device-local choices; keeping the existing layout is the default.
    static let bossKey = "bound.delta.pip.v1.bosses.layout"
    static let dexKey = "bound.delta.pip.v1.dex.layout"
}

enum BoundCompanionButtonType: Int, CaseIterable, Sendable {
    case option1 = 1, option2 = 2, option3 = 3
    var title: String { "Option \(rawValue)" }
    var summary: String {
        switch self {
        case .option1: "The original round button and placement."
        case .option2: "A tall rounded rectangle."
        case .option3: "Three separate buttons in the tall button's space."
        }
    }
}

final class BoundCompanionButtonPreferences {
    static let key = "bound.delta.pip.v1.button-type"
    static let didChangeNotification = Notification.Name("BoundCompanionButtonDidChange")
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var buttonType: BoundCompanionButtonType {
        get {
            let saved = defaults.integer(forKey: Self.key)
            return saved == 4 ? .option3 : BoundCompanionButtonType(rawValue: saved) ?? .option1
        }
        set {
            guard buttonType != newValue else { return }
            defaults.set(newValue.rawValue, forKey: Self.key)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    var effectiveButtonType: BoundCompanionButtonType {
        buttonType
    }
}

@MainActor
final class BoundPiPPreferences {
    static let didChangeNotification = Notification.Name("BoundPiPPreferencesDidChange")
    private let defaults: UserDefaults
    private let namespace: String
    init(defaults: UserDefaults = .standard, namespace: String = "bound.delta.pip.v1") {
        self.defaults = defaults; self.namespace = namespace
    }
    private func key(_ suffix: String) -> String { namespace + "." + suffix }
    func isEnabled(_ content: BoundPiPContent) -> Bool {
        defaults.object(forKey: key(content.rawValue + ".enabled")) as? Bool ?? true
    }
    func setEnabled(_ enabled: Bool, for content: BoundPiPContent) {
        guard isEnabled(content) != enabled else { return }
        defaults.set(enabled, forKey: key(content.rawValue + ".enabled"))
        notifyChange()
    }
    var uiVersion: BoundUIVersion { BoundUIVersionPreferences(defaults: defaults).version }
    var buttonType: BoundCompanionButtonType {
        get { BoundCompanionButtonPreferences(defaults: defaults).buttonType }
        set { BoundCompanionButtonPreferences(defaults: defaults).buttonType = newValue }
    }
    /// Each segment keeps its own choices, including an intentionally empty set.
    func assignedContents(for button: Int) -> [BoundPiPContent] {
        guard (0..<3).contains(button) else { return [] }
        let fallback: [[BoundPiPContent]] = [[.friend], [.bosses], [.types]]
        guard let saved = defaults.stringArray(forKey: key("button.\(button + 1).views")) else { return fallback[button] }
        let selected = Set(saved.compactMap(BoundPiPContent.init(rawValue:)))
        return orderedContents.filter { selected.contains($0) }
    }
    func setAssignedContents(_ contents: [BoundPiPContent], for button: Int) {
        guard (0..<3).contains(button) else { return }
        let selected = Set(contents)
        let normalized = orderedContents.filter { selected.contains($0) }.map(\.rawValue)
        let preferenceKey = key("button.\(button + 1).views")
        guard defaults.stringArray(forKey: preferenceKey) != normalized else { return }
        defaults.set(normalized, forKey: preferenceKey)
        notifyChange()
    }
    var orderedContents: [BoundPiPContent] {
        let saved = defaults.stringArray(forKey: key("view-order")) ?? []
        return Self.normalizedOrder(saved.compactMap(BoundPiPContent.init(rawValue:)))
    }
    private static func normalizedOrder(_ contents: [BoundPiPContent]) -> [BoundPiPContent] {
        var result: [BoundPiPContent] = []
        for content in contents + BoundPiPContent.cycleOrder where !result.contains(content) {
            result.append(content)
        }
        return result
    }
    func setContentOrder(_ contents: [BoundPiPContent]) {
        let normalized = Self.normalizedOrder(contents).map(\.rawValue)
        let preferenceKey = key("view-order")
        guard defaults.stringArray(forKey: preferenceKey) != normalized else { return }
        defaults.set(normalized, forKey: preferenceKey)
        notifyChange()
    }
    func enabledContents(uiVersion: BoundUIVersion = .option1) -> [BoundPiPContent] {
        let contents = uiVersion == .option2 ? orderedContents : BoundPiPContent.cycleOrder
        return contents.filter { isEnabled($0) }
    }
    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
    var corner: BoundPiPCorner {
        get { BoundPiPCorner(rawValue: defaults.string(forKey: key("corner")) ?? "") ?? .topRight }
        set {
            guard corner != newValue else { return }
            defaults.set(newValue.rawValue, forKey: key("corner"))
            notifyChange()
        }
    }
    func corner(for content: BoundPiPContent) -> BoundPiPCorner {
        let name = key(content.rawValue + ".corner")
        if let value = defaults.string(forKey: name), let saved = BoundPiPCorner(rawValue: value) { return saved }
        let inherited = corner
        defaults.set(inherited.rawValue, forKey: name)
        return inherited
    }
    func setCorner(_ value: BoundPiPCorner, for content: BoundPiPContent) {
        let preferenceKey = key(content.rawValue + ".corner")
        guard defaults.string(forKey: preferenceKey) != value.rawValue else { return }
        defaults.set(value.rawValue, forKey: preferenceKey)
        notifyChange()
    }
    func scale(for content: BoundPiPContent) -> Double {
        validNumber(key(content.rawValue + ".scale"), range: 0.65...1.4)
    }
    func opacity(for content: BoundPiPContent) -> Double {
        content == .types ? 1 : validNumber(key(content.rawValue + ".opacity"), range: 0...1)
    }
    private func validNumber(_ name: String, range: ClosedRange<Double>) -> Double {
        guard let value = defaults.object(forKey: name) as? NSNumber,
              value.doubleValue.isFinite, range.contains(value.doubleValue) else { return 1 }
        return value.doubleValue
    }
    func setScale(_ value: Double, for content: BoundPiPContent) {
        guard value.isFinite else { return }
        let normalized = min(1.4, max(0.65, value))
        guard scale(for: content) != normalized else { return }
        defaults.set(normalized, forKey: key(content.rawValue + ".scale"))
        notifyChange()
    }
    func setOpacity(_ value: Double, for content: BoundPiPContent) {
        guard content != .types, value.isFinite else { return }
        let normalized = min(1, max(0, value))
        guard opacity(for: content) != normalized else { return }
        defaults.set(normalized, forKey: key(content.rawValue + ".opacity"))
        notifyChange()
    }
    func transparency(for content: BoundPiPContent) -> Double { 1 - opacity(for: content) }
    func setTransparency(_ value: Double, for content: BoundPiPContent) { setOpacity(1 - value, for: content) }
    static func opacity(start: Double, verticalTranslation: CGFloat, panelHeight: CGFloat) -> Double {
        guard start.isFinite, verticalTranslation.isFinite, panelHeight.isFinite else { return 1 }
        return min(1, max(0, start - Double(verticalTranslation / max(1, panelHeight))))
    }
}

struct BoundPiPLayout {
    let viewport: CGRect
    let size: CGSize
    private let occupied: [CGRect]
    private let padding: CGFloat = 8
    init(viewport: CGRect, baseSize: CGSize, scale: CGFloat, occupied: [CGRect] = []) {
        self.viewport = viewport
        let canvas = viewport.insetBy(dx: 8, dy: 8)
        self.occupied = occupied.filter { !$0.isNull && !$0.isEmpty }
            .map { $0.insetBy(dx: -2, dy: -2) }.filter { $0.intersects(canvas) }
        guard canvas.width > 0, canvas.height > 0, baseSize.width > 0, baseSize.height > 0,
              baseSize.width.isFinite, baseSize.height.isFinite, scale.isFinite, scale > 0 else {
            size = .zero; return
        }
        let factor = min(scale, canvas.width / baseSize.width, canvas.height / baseSize.height)
        let requested = CGSize(width: baseSize.width * factor, height: baseSize.height * factor)
        if Self.clearCenter(preferred: CGPoint(x: canvas.midX, y: canvas.midY), size: requested,
                            canvas: canvas, occupied: self.occupied) != nil {
            size = requested; return
        }
        // Preserve aspect ratio while bounding the maximum to an available region.
        // A fully covered custom layout has no placement; the caller hides its PiP.
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<12 {
            let mid = (low + high) / 2
            let candidate = CGSize(width: requested.width * mid, height: requested.height * mid)
            if Self.clearCenter(preferred: CGPoint(x: canvas.midX, y: canvas.midY), size: candidate,
                                canvas: canvas, occupied: self.occupied) != nil { low = mid }
            else { high = mid }
        }
        size = low > 0 ? CGSize(width: requested.width * low, height: requested.height * low) : .zero
    }
    private func preferredCenter(_ corner: BoundPiPCorner) -> CGPoint {
        let left = viewport.minX + padding + size.width / 2
        let right = viewport.maxX - padding - size.width / 2
        let top = viewport.minY + padding + size.height / 2
        let bottom = viewport.maxY - padding - size.height / 2
        return CGPoint(x: corner == .topLeft || corner == .bottomLeft ? left : right,
                       y: corner == .topLeft || corner == .topRight ? top : bottom)
    }
    func center(_ corner: BoundPiPCorner) -> CGPoint {
        Self.clearCenter(preferred: preferredCenter(corner), size: size,
                         canvas: viewport.insetBy(dx: padding, dy: padding), occupied: occupied)
            ?? CGPoint(x: viewport.midX, y: viewport.midY)
    }
    func clampedCenter(from corner: BoundPiPCorner, translation: CGSize) -> CGPoint {
        let origin = center(corner)
        return Self.clearCenter(preferred: CGPoint(x: origin.x + translation.width, y: origin.y + translation.height),
                                size: size, canvas: viewport.insetBy(dx: padding, dy: padding), occupied: occupied)
            ?? origin
    }
    /// Rectangle edges define every feasible region; choose the closest clear placement.
    private static func clearCenter(preferred: CGPoint, size: CGSize, canvas: CGRect, occupied: [CGRect]) -> CGPoint? {
        guard size.width > 0, size.height > 0, canvas.width >= size.width, canvas.height >= size.height else { return nil }
        let halfW = size.width / 2, halfH = size.height / 2
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, canvas.minX + halfW), canvas.maxX - halfW),
                    y: min(max(p.y, canvas.minY + halfH), canvas.maxY - halfH))
        }
        func clear(_ p: CGPoint) -> Bool {
            let rect = CGRect(x: p.x - halfW, y: p.y - halfH, width: size.width, height: size.height)
            return !occupied.contains { obstacle in
                let intersection = rect.intersection(obstacle)
                return !intersection.isNull && intersection.width > 0.001 && intersection.height > 0.001
            }
        }
        let initial = clamp(preferred)
        if clear(initial) { return initial }
        var xs = [initial.x, canvas.minX + halfW, canvas.maxX - halfW]
        var ys = [initial.y, canvas.minY + halfH, canvas.maxY - halfH]
        for obstacle in occupied {
            xs += [obstacle.minX - halfW, obstacle.maxX + halfW]
            ys += [obstacle.minY - halfH, obstacle.maxY + halfH]
        }
        var closest: CGPoint?, distance = CGFloat.infinity
        for x in xs { for y in ys {
            let point = clamp(CGPoint(x: x, y: y))
            let dx = point.x - initial.x, dy = point.y - initial.y, d = dx * dx + dy * dy
            if d < distance && clear(point) { closest = point; distance = d }
        } }
        return closest
    }
    /// During a drag, preserve direct finger-to-panel movement instead of jumping
    /// between collision-free regions as the pointer crosses a native control.
    func dragCenter(from corner: BoundPiPCorner, translation: CGSize) -> CGPoint {
        let origin = center(corner)
        return CGPoint(x: min(max(origin.x + translation.width, viewport.minX + padding + size.width/2), viewport.maxX - padding - size.width/2),
                       y: min(max(origin.y + translation.height, viewport.minY + padding + size.height/2), viewport.maxY - padding - size.height/2))
    }
    func destination(from corner: BoundPiPCorner, translation: CGSize) -> BoundPiPCorner {
        let origin = center(corner)
        let end = CGPoint(x: origin.x + translation.width, y: origin.y + translation.height)
        func distance(_ candidate: BoundPiPCorner) -> CGFloat {
            let target = center(candidate)
            return pow(target.x-end.x, 2) + pow(target.y-end.y, 2)
        }
        // Small drags stay put; a cross-screen drag selects the nearest actual
        // destination, including its native-control clearance.
        return BoundPiPCorner.allCases.reduce(corner) { distance($1) < distance($0) ? $1 : $0 }
    }
    func hiddenSide(from corner: BoundPiPCorner, translation: CGSize, endX: CGFloat? = nil) -> BoundPiPHiddenSide? {
        guard abs(translation.width) > 50 else { return nil }
        if let endX {
            if endX <= viewport.minX + 20 && translation.width < 0 { return .left }
            if endX >= viewport.maxX - 20 && translation.width > 0 { return .right }
        } else {
            let rawX = center(corner).x + translation.width
            if rawX <= viewport.minX + 12 && translation.width < 0 { return .left }
            if rawX >= viewport.maxX - 12 && translation.width > 0 { return .right }
        }
        return nil
    }
}
