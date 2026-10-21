import SwiftUI
import UIKit

/// Portrait keeps its existing height fit. The Mac sidebar opts into a centered viewport fit.
struct BoundTypeChartView: UIViewRepresentable {
    var topInset: CGFloat = 0
    var constrainsPan: Bool = false
    var fitsViewport: Bool = false
    func makeUIView(context: Context) -> BoundPortraitChartScrollView { BoundPortraitChartScrollView() }
    func updateUIView(_ uiView: BoundPortraitChartScrollView, context: Context) {
        uiView.topInset = topInset
        uiView.constrainsPan = constrainsPan
        uiView.fitsViewport = fitsViewport
    }
}

final class BoundPortraitChartScrollView: UIScrollView, UIScrollViewDelegate {
    private let chart = UIImageView(image: UIImage(named: "PokemonTypeChart"))
    var topInset: CGFloat = 0 { didSet { if oldValue != topInset { setNeedsLayout() } } }
    var constrainsPan = false {
        didSet {
            guard oldValue != constrainsPan else { return }
            bounces = !constrainsPan
            previousViewport = .zero
            setNeedsLayout()
        }
    }
    var fitsViewport = false {
        didSet {
            guard oldValue != fitsViewport else { return }
            previousViewport = .zero
            setNeedsLayout()
        }
    }
    private var adjustingPanBounds = false
    private var updatingChartLayout = false
    private var previousTopInset: CGFloat = -1
    private var previousViewport = CGSize.zero
    private var initialScale: CGFloat = 1
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .black
        accessibilityIdentifier = "bound.type-chart"
        accessibilityLabel = "Pokémon type effectiveness chart"
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        contentInsetAdjustmentBehavior = .never
        chart.contentMode = .scaleToFill // Bounds preserve the original image aspect ratio.
        chart.accessibilityIdentifier = "bound.type-chart-image"
        chart.accessibilityLabel = chart.image == nil ? "Type chart unavailable" : "Pokémon type effectiveness chart"
        chart.isAccessibilityElement = true
        chart.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Zoom in", target: self, selector: #selector(accessibleZoomIn)),
            UIAccessibilityCustomAction(name: "Zoom out", target: self, selector: #selector(accessibleZoomOut)),
            UIAccessibilityCustomAction(name: "Reset chart zoom", target: self, selector: #selector(accessibleReset))
        ]
        addSubview(chart)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard (bounds.size != previousViewport || topInset != previousTopInset), let image = chart.image,
              let geometry = BoundTypeChartGeometry(image: image.size, viewport: CGSize(width: bounds.width, height: max(1, bounds.height - min(max(0, topInset), bounds.height)))) else { return }
        let oldViewport = previousViewport
        previousViewport = bounds.size
        previousTopInset = topInset
        if fitsViewport {
            layoutFittingChart(image: image, geometry: geometry, oldViewport: oldViewport)
            return
        }
        // Layout/rotation and a newly created chart always start at the same height fit.
        minimumZoomScale = min(geometry.minimumScale, 1)
        maximumZoomScale = max(geometry.maximumScale, 1)
        setZoomScale(1, animated: false)
        chart.bounds = CGRect(origin: .zero, size: image.size)
        chart.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        initialScale = geometry.initialScale
        minimumZoomScale = geometry.minimumScale
        maximumZoomScale = geometry.maximumScale
        resetZoom()
    }
    private func layoutFittingChart(image: UIImage, geometry: BoundTypeChartGeometry, oldViewport: CGSize) {
        // Preserve the magnification and chart location while a sidebar divider
        // moves. A chart at its initial fit continues fitting the new viewport.
        let relativeZoom = zoomScale / max(initialScale, 0.0001)
        let preservesFocus = oldViewport.width > 0 && oldViewport.height > 0 && relativeZoom > 1.001
        let focus = CGPoint(x: min(1, max(0, (contentOffset.x + oldViewport.width / 2 - chart.frame.minX) / max(chart.frame.width, 1))),
                            y: min(1, max(0, (contentOffset.y + oldViewport.height / 2 - chart.frame.minY) / max(chart.frame.height, 1))))
        updatingChartLayout = true
        minimumZoomScale = min(geometry.minimumScale, 1)
        maximumZoomScale = max(geometry.minimumScale * 8, 1)
        setZoomScale(1, animated: false)
        chart.bounds = CGRect(origin: .zero, size: image.size)
        chart.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        initialScale = geometry.minimumScale
        minimumZoomScale = initialScale
        maximumZoomScale = initialScale * 8
        setZoomScale(preservesFocus ? min(maximumZoomScale, initialScale * relativeZoom) : initialScale, animated: false)
        centerSmallContent()
        let offset = preservesFocus
            ? CGPoint(x: chart.frame.minX + focus.x * chart.frame.width - bounds.width / 2,
                      y: chart.frame.minY + focus.y * chart.frame.height - bounds.height / 2)
            : CGPoint(x: -contentInset.left, y: -contentInset.top)
        setContentOffset(offset, animated: false)
        updatingChartLayout = false
        clampPanOffset()
        updateProbe()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { chart }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !updatingChartLayout else { return }
        centerSmallContent()
        clampPanOffset()
        updateProbe()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { clampPanOffset(); updateProbe() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        centerSmallContent()
        clampPanOffset()
        updateProbe()
    }
    private func clampPanOffset() {
        // Elastic pinch is independent of pan overscroll. Let UIKit complete its
        // below-minimum zoom animation before enforcing the final pan bounds.
        guard constrainsPan, !adjustingPanBounds, !updatingChartLayout, !isZooming, !isZoomBouncing else { return }
        let minimum = CGPoint(x: -contentInset.left, y: -contentInset.top)
        let maximum = CGPoint(x: max(minimum.x, contentSize.width - bounds.width + contentInset.right),
                              y: max(minimum.y, contentSize.height - bounds.height + contentInset.bottom))
        let clamped = CGPoint(x: min(maximum.x, max(minimum.x, contentOffset.x)),
                              y: min(maximum.y, max(minimum.y, contentOffset.y)))
        guard clamped != contentOffset else { return }
        adjustingPanBounds = true
        setContentOffset(clamped, animated: false)
        adjustingPanBounds = false
    }
    private func centerSmallContent() {
        let padding = BoundTypeChartGeometry.centeredInsets(content: contentSize, viewport: bounds.size)
        if fitsViewport {
            contentInset = UIEdgeInsets(top: padding.vertical, left: padding.horizontal,
                                        bottom: padding.vertical, right: padding.horizontal)
        } else if constrainsPan {
            // A fitting image stays bottom-aligned above gameplay. Once an axis
            // overflows, only image content can move through that viewport.
            adjustingPanBounds = true
            contentInset = UIEdgeInsets(top: max(0, bounds.height - contentSize.height),
                                        left: padding.horizontal, bottom: 0, right: padding.horizontal)
            adjustingPanBounds = false
        } else {
            contentInset = UIEdgeInsets(top: max(padding.vertical, topInset), left: padding.horizontal,
                                        bottom: padding.vertical, right: padding.horizontal)
        }
    }
    private func resetZoom() {
        setZoomScale(initialScale, animated: false)
        centerSmallContent()
        setContentOffset(CGPoint(x: max(-contentInset.left, (contentSize.width - bounds.width)/2),
                                 y: -contentInset.top), animated: false)
        updateProbe()
    }
    private func updateProbe() {
        #if DEBUG
        let frame = chart.frame.offsetBy(dx: -contentOffset.x, dy: -contentOffset.y)
        let value = String(format: "zoom=%.4f; initial=%.4f; imageX=%.2f; imageY=%.2f; imageWidth=%.2f; imageHeight=%.2f; viewportWidth=%.2f; viewportHeight=%.2f; topInset=%.2f; fitViewportHeight=%.2f; minimum=%.4f", Double(zoomScale), Double(initialScale), Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height), Double(bounds.width), Double(bounds.height), Double(topInset), Double(max(1, bounds.height - min(max(0, topInset), bounds.height))), Double(minimumZoomScale))
        #else
        let value = String(format: "Zoom %.0f percent", Double(zoomScale / max(initialScale, 0.0001)) * 100)
        #endif
        accessibilityValue = value
        chart.accessibilityValue = value
    }
    @objc private func accessibleZoomIn() -> Bool { setZoomScale(min(maximumZoomScale, zoomScale * 1.5), animated: false); return true }
    @objc private func accessibleZoomOut() -> Bool { setZoomScale(max(minimumZoomScale, zoomScale / 1.5), animated: false); return true }
    @objc private func accessibleReset() -> Bool { resetZoom(); return true }
}
