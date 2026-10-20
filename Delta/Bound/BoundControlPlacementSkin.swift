import UIKit
import DeltaCore

/// Keeps Delta's native inputs and artwork. The same transformed item drives drawing and hit testing.
final class BoundPlacedControllerSkin: ControllerSkinProtocol {
    let base: ControllerSkinProtocol
    let layout: BoundControlLayout
    let canvasSize: CGSize
    /// Original native controller rectangle inside the full customization canvas.
    let sourceFrame: CGRect
    let identifier: String
    init(base: ControllerSkinProtocol, layout: BoundControlLayout, canvasSize: CGSize, sourceFrame: CGRect? = nil) {
        self.base = base; self.layout = layout; self.canvasSize = canvasSize
        self.sourceFrame = sourceFrame ?? CGRect(origin: .zero, size: canvasSize)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let encoded = (try? encoder.encode(layout))?.base64EncodedString() ?? "default"
        self.identifier = base.identifier + ".bound-placement." + encoded + "." + String(describing: canvasSize) + "." + String(describing: self.sourceFrame)
    }
    var name: String { base.name }
    var gameType: GameType { base.gameType }
    var isDebugModeEnabled: Bool { base.isDebugModeEnabled }
    func supports(_ traits: DeltaCore.ControllerSkin.Traits) -> Bool { base.supports(traits) }
    func supportedTraits(for traits: DeltaCore.ControllerSkin.Traits) -> DeltaCore.ControllerSkin.Traits? { base.supportedTraits(for: traits) }
    func items(for traits: DeltaCore.ControllerSkin.Traits) -> [DeltaCore.ControllerSkin.Item]? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return base.items(for: traits) }
        if layout.positions.isEmpty && sourceFrame == CGRect(origin: .zero, size: canvasSize) { return base.items(for: traits) }
        return base.items(for: traits)?.map { item in
            guard item.kind == .button || item.kind == .dPad else { return item }
            var result = item
            let source = item.frame.applying(.init(scaleX: sourceFrame.width, y: sourceFrame.height)).offsetBy(dx: sourceFrame.minX, dy: sourceFrame.minY)
            let destination = layout.frame(id: item.id, base: source, canvas: canvasSize, directional: item.kind == .dPad)
            result.frame = destination.applying(.init(scaleX: 1 / canvasSize.width, y: 1 / canvasSize.height))
            // Scale extended touch margins by the exact artwork transformation.
            let sx = result.frame.width / max(item.frame.width, 0.0001), sy = result.frame.height / max(item.frame.height, 0.0001)
            result.extendedFrame = CGRect(x: result.frame.minX - (item.frame.minX - item.extendedFrame.minX) * sx,
                y: result.frame.minY - (item.frame.minY - item.extendedFrame.minY) * sy,
                width: item.extendedFrame.width * sx, height: item.extendedFrame.height * sy)
            return result
        }
    }
    private func composite(_ source: UIImage?, traits: DeltaCore.ControllerSkin.Traits, size: DeltaCore.ControllerSkin.Size) -> UIImage? {
        guard let source, let original = base.items(for: traits), let moved = items(for: traits) else { return source }
        if layout.positions.isEmpty && sourceFrame == CGRect(origin: .zero, size: canvasSize) { return source }
        guard canvasSize.width > 0, canvasSize.height > 0 else { return source }
        // Render a transparent full viewport; native PDF controls are drawn separately
        // by ControllerView. Flat artwork gets the identical item-frame transform.
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { context in
            for (old, new) in zip(original, moved) where old.kind == .button || old.kind == .dPad {
                guard base.image(for: old, traits: traits, preferredSize: size) == nil else { continue }
                let destination = new.frame.applying(.init(scaleX: canvasSize.width, y: canvasSize.height))
                context.cgContext.saveGState(); context.cgContext.clip(to: destination)
                let sx = destination.width / max(old.frame.width * source.size.width, 0.0001)
                let sy = destination.height / max(old.frame.height * source.size.height, 0.0001)
                source.draw(in: CGRect(x: destination.minX - old.frame.minX * source.size.width * sx,
                    y: destination.minY - old.frame.minY * source.size.height * sy,
                    width: source.size.width * sx, height: source.size.height * sy))
                context.cgContext.restoreGState()
            }
        }
    }
    func image(for traits: DeltaCore.ControllerSkin.Traits, preferredSize: DeltaCore.ControllerSkin.Size) -> UIImage? {
        composite(base.image(for: traits, preferredSize: preferredSize), traits: traits, size: preferredSize)
    }
    func pressedImage(for traits: DeltaCore.ControllerSkin.Traits, preferredSize: DeltaCore.ControllerSkin.Size) -> UIImage? {
        composite(base.pressedImage(for: traits, preferredSize: preferredSize), traits: traits, size: preferredSize)
    }
    func image(for item: DeltaCore.ControllerSkin.Item, traits: DeltaCore.ControllerSkin.Traits, preferredSize: DeltaCore.ControllerSkin.Size) -> (UIImage, CGSize)? {
        guard let original = base.items(for: traits)?.first(where: { $0.id == item.id }), let (image, size) = base.image(for: original, traits: traits, preferredSize: preferredSize) else { return nil }
        return (image, CGSize(width: size.width * item.frame.width / max(original.frame.width, 0.0001), height: size.height * item.frame.height / max(original.frame.height, 0.0001)))
    }
    func isTranslucent(for traits: DeltaCore.ControllerSkin.Traits) -> Bool? { base.isTranslucent(for: traits) }
    func gameScreenFrame(for traits: DeltaCore.ControllerSkin.Traits) -> CGRect? { base.gameScreenFrame(for: traits) }
    func screens(for traits: DeltaCore.ControllerSkin.Traits) -> [DeltaCore.ControllerSkin.Screen]? { base.screens(for: traits) }
    func aspectRatio(for traits: DeltaCore.ControllerSkin.Traits) -> CGSize? { base.aspectRatio(for: traits) }
    func contentSize(for traits: DeltaCore.ControllerSkin.Traits) -> CGSize? { base.contentSize(for: traits) }
    func menuInsets(for traits: DeltaCore.ControllerSkin.Traits) -> UIEdgeInsets? { base.menuInsets(for: traits) }
}
