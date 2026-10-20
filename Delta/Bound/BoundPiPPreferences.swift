import Foundation
import CoreGraphics

// Original Bound's PiP interaction policy; storage is isolated from its account preferences.
enum BoundPiPCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}
enum BoundPiPContent: String, CaseIterable, Sendable { case friend, types, notes }
enum BoundPiPHiddenSide: String, Sendable { case left, right }

@MainActor
final class BoundPiPPreferences {
    private let defaults: UserDefaults
    private let namespace: String
    init(defaults: UserDefaults = .standard, namespace: String = "bound.delta.pip.v1") {
        self.defaults = defaults; self.namespace = namespace
    }
    private func key(_ suffix: String) -> String { namespace + "." + suffix }
    var corner: BoundPiPCorner {
        get { BoundPiPCorner(rawValue: defaults.string(forKey: key("corner")) ?? "") ?? .topRight }
        set { defaults.set(newValue.rawValue, forKey: key("corner")) }
    }
    func corner(for content: BoundPiPContent) -> BoundPiPCorner {
        let name = key(content.rawValue + ".corner")
        if let value = defaults.string(forKey: name), let saved = BoundPiPCorner(rawValue: value) { return saved }
        let inherited = corner
        defaults.set(inherited.rawValue, forKey: name)
        return inherited
    }
    func setCorner(_ value: BoundPiPCorner, for content: BoundPiPContent) {
        defaults.set(value.rawValue, forKey: key(content.rawValue + ".corner"))
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
        defaults.set(min(1.4, max(0.65, value)), forKey: key(content.rawValue + ".scale"))
    }
    func setOpacity(_ value: Double, for content: BoundPiPContent) {
        guard content != .types, value.isFinite else { return }
        defaults.set(min(1, max(0, value)), forKey: key(content.rawValue + ".opacity"))
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
