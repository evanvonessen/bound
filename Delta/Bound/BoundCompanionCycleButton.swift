import UIKit
import DeltaCore

/// Companion UI only: this button never enters Delta's emulator input mapping.
@MainActor
final class BoundCompanionCycleButton: UIButton {
    var cycle: (() -> Void)?
    /// Tests can replace the output without touching device feedback or emulator inputs.
    var buttonFeedback: (() -> Void)?
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
    private var visualSize = CGSize(width: 17, height: 17)
    private var landscape = false
    private var minimal = false
    private var boundPortrait = false
    private var selectArtwork: UIImage?
    private var content: BoundPiPContent = .friend
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "bound.panel-cycle"
        accessibilityLabel = "Bound companion panel"
        accessibilityHint = "Cycles Friend, Notes, and Types"
        addTarget(self, action: #selector(advance), for: .touchUpInside)
        addTarget(self, action: #selector(pressVisual), for: [.touchDown, .touchDragEnter])
        addTarget(self, action: #selector(releaseVisual), for: [.touchCancel, .touchUpOutside, .touchDragExit])
        backgroundColor = .clear
        isExclusiveTouch = false
        feedbackGenerator.prepare()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isHighlighted: Bool { didSet { setNeedsDisplay() } }
    @objc private func pressVisual() {
        guard isEnabled, isUserInteractionEnabled, !isHidden else { return }
        isHighlighted = true
    }
    @objc private func releaseVisual() { isHighlighted = false }
    @objc private func advance() {
        isHighlighted = false
        guard isEnabled, isUserInteractionEnabled, !isHidden else { return }
        if BoundAppearancePreferences().effectiveScreenLayout == .bound && Settings.isButtonHapticFeedbackEnabled {
            if let buttonFeedback { buttonFeedback() }
            else {
                // Same intensity and capability fallback as Delta's native ButtonsInputView.
                switch UIDevice.current.feedbackSupportLevel {
                case .feedbackGenerator: feedbackGenerator.impactOccurred()
                case .basic, .unsupported: UIDevice.current.vibrate()
                }
            }
        }
        cycle?()
    }
    var artworkFrame: CGRect {
        CGRect(x: bounds.midX-visualSize.width/2, y: bounds.midY-visualSize.height/2,
               width: visualSize.width, height: visualSize.height)
    }
    /// Native Select/Start assets press inward by two points, immediately on
    /// contact and immediately reset on release. No spring or delayed animation.
    var materialFrame: CGRect {
        let inner = artworkFrame.insetBy(dx: 1.2, dy: 1.2)
        return isHighlighted ? inner.insetBy(dx: 2, dy: 2) : inner
    }
    func configure(menuFrame: CGRect, controllerFrame: CGRect, landscape: Bool, minimal: Bool,
                   content: BoundPiPContent, canvas: CGRect, occupied: [CGRect], rightShoulderFrame: CGRect? = nil, menuHitSize: CGSize? = nil, boundPortrait: Bool = false, selectArtwork: UIImage? = nil, rightControlGutter: CGRect? = nil, menuHitFrame: CGRect? = nil) {
        self.boundPortrait = boundPortrait; self.selectArtwork = selectArtwork
        self.landscape = landscape; self.minimal = minimal; self.content = content
        let fixedPair = landscape && rightControlGutter != nil && abs(menuFrame.width-44) < 0.5 && abs(menuFrame.height-44) < 0.5
        visualSize = fixedPair ? CGSize(width: 44, height: 44)
            : minimal ? CGSize(width: max(48, menuFrame.width), height: max(44, menuFrame.height)) : menuFrame.size
        if landscape, let gutter = rightControlGutter {
            visualSize.width = min(visualSize.width, gutter.width)
            visualSize.height = min(visualSize.height, gutter.height)
        }
        let requestedWidth = max(44, max(visualSize.width, menuHitSize?.width ?? 0))
        let hitSize = fixedPair ? CGSize(width: 44, height: 44)
            : CGSize(width: rightControlGutter.map { min(requestedWidth, $0.width) } ?? requestedWidth,
                     height: max(44, max(visualSize.height, menuHitSize?.height ?? 0)))
        let preferred: CGPoint
        if fixedPair {
            preferred = CGPoint(x: menuFrame.midX, y: menuFrame.maxY + 8 + hitSize.height/2)
        } else if let gutter = rightControlGutter, landscape {
            preferred = CGPoint(x: gutter.maxX - hitSize.width/2,
                                y: (menuHitFrame?.maxY ?? menuFrame.maxY) + 8 + hitSize.height/2)
        } else if !landscape {
            preferred = CGPoint(x: controllerFrame.minX + controllerFrame.maxX - menuFrame.midX, y: menuFrame.midY)
        } else if let right = rightShoulderFrame {
            preferred = CGPoint(x: right.midX, y: right.maxY + hitSize.height / 2 + 10)
        } else {
            preferred = CGPoint(x: controllerFrame.minX + controllerFrame.maxX - menuFrame.midX, y: menuFrame.midY)
        }
        guard let available = Self.clearFrame(preferred: preferred, size: hitSize, canvas: rightControlGutter ?? canvas, occupied: occupied) else {
            // A pathological custom layout can fill the entire viewport. Do not
            // put a companion hit target over native game inputs in that case.
            isHidden = true; isUserInteractionEnabled = false; frame = .zero
            return
        }
        isHidden = false; isUserInteractionEnabled = true; frame = available
        accessibilityValue = content.rawValue.capitalized
        setNeedsDisplay()
    }
    /// Nearest collision-free center among viewport and native-hit-region edges.
    /// The ordinary mirrored/adjacent placement exits immediately without a search.
    static func clearFrame(preferred: CGPoint, size: CGSize, canvas: CGRect, occupied: [CGRect]) -> CGRect? {
        guard size.width > 0, size.height > 0, canvas.width >= size.width, canvas.height >= size.height else { return nil }
        let halfW = size.width / 2, halfH = size.height / 2
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, canvas.minX + halfW), canvas.maxX - halfW),
                    y: min(max(point.y, canvas.minY + halfH), canvas.maxY - halfH))
        }
        func frame(_ point: CGPoint) -> CGRect {
            CGRect(x: point.x - halfW, y: point.y - halfH, width: size.width, height: size.height)
        }
        func clear(_ rect: CGRect) -> Bool {
            canvas.contains(rect) && !occupied.contains { $0.intersects(rect) }
        }
        let initial = clamp(preferred), first = frame(initial)
        if clear(first) { return first }
        var xs = [initial.x, canvas.minX + halfW, canvas.maxX - halfW]
        var ys = [initial.y, canvas.minY + halfH, canvas.maxY - halfH]
        for obstacle in occupied where !obstacle.isNull && !obstacle.isEmpty {
            xs += [obstacle.minX - halfW - 2, obstacle.maxX + halfW + 2]
            ys += [obstacle.minY - halfH - 2, obstacle.maxY + halfH + 2]
        }
        let candidates = xs.flatMap { x in ys.map { y in clamp(CGPoint(x: x, y: y)) } }.sorted {
            let ax = $0.x - initial.x, ay = $0.y - initial.y
            let bx = $1.x - initial.x, by = $1.y - initial.y
            let a = ax * ax + ay * ay
            let b = bx * bx + by * by
            if a == b { return $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
            return a < b
        }
        for candidate in candidates { let rect = frame(candidate); if clear(rect) { return rect } }
        return nil
    }
    override func draw(_ rect: CGRect) {
        let box = artworkFrame
        if boundPortrait && !landscape && !minimal, let selectArtwork {
            // Native composite artwork supplies Select's black bezel/shadow,
            // while its individual asset supplies the gray material and bevel.
            let context = UIGraphicsGetCurrentContext()
            context?.saveGState()
            context?.setShadow(offset: CGSize(width: 0, height: 1), blur: 1.5, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            UIColor.black.withAlphaComponent(0.9).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: min(box.width, box.height)/2).fill()
            context?.restoreGState()
            selectArtwork.draw(in: materialFrame)
            drawMark(in: materialFrame, ink: .darkGray, etched: true)
            return
        }
        let fill: UIColor = minimal ? .secondarySystemBackground : landscape ? .deltaPurple : .black
        let ink: UIColor = minimal ? .label : .white
        let shape = UIBezierPath(roundedRect: box, cornerRadius: min(box.width, box.height)/2)
        fill.setFill(); shape.fill()
        if landscape || minimal { UIColor.white.withAlphaComponent(minimal ? 0.25 : 0.85).setStroke(); shape.lineWidth = 1.5; shape.stroke() }
        drawMark(in: box, ink: ink, etched: boundPortrait && !landscape)
    }
    private func drawMark(in box: CGRect, ink: UIColor, etched: Bool) {
        guard let mark = UIImage(named: "DeltaBoundMark") else { return }
        let side = min(box.width, box.height) * 0.72
        let target = CGRect(x: box.midX-side/2, y: box.midY-side/2, width: side, height: side)
        if etched {
            mark.withTintColor(.white.withAlphaComponent(0.5), renderingMode: .alwaysOriginal)
                .draw(in: target.offsetBy(dx: 0, dy: 0.5))
        }
        mark.withTintColor(ink, renderingMode: .alwaysOriginal).draw(in: target)
    }
}

/// Describes the real Menu hit region; ordinary taps still reach Delta's native touch view.
@MainActor
final class BoundNativeMenuAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}
