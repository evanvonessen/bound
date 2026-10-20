import UIKit
import CoreText
import DeltaCore

/// App-owned artwork/stock placement policy. Upstream skin files and native inputs stay intact.
final class BoundStockControllerSkin: ControllerSkinProtocol {
    let base: ControllerSkinProtocol
    let canvasSize: CGSize
    let contentInsets: UIEdgeInsets
    /// Bound landscape only, expressed in the native controller's pixel coordinates.
    let boundLandscapeGutter: CGRect?
    init(base: ControllerSkinProtocol, canvasSize: CGSize, contentInsets: UIEdgeInsets = .zero, boundLandscapeGutter: CGRect? = nil) {
        self.base = base; self.canvasSize = canvasSize; self.contentInsets = contentInsets
        self.boundLandscapeGutter = boundLandscapeGutter
    }
    private var stock: Bool { ["gba", "gbc", "nes", "snes", "n64", "genesis", "ds"].contains { base.identifier == "com.delta." + $0 + ".standard" } }
    var name: String { base.name }
    var identifier: String { base.identifier + ".bound-stock.v4." + String(describing: canvasSize) + String(describing: contentInsets) + String(describing: boundLandscapeGutter) }
    var gameType: GameType { base.gameType }
    var isDebugModeEnabled: Bool { base.isDebugModeEnabled }
    func supports(_ traits: DeltaCore.ControllerSkin.Traits) -> Bool { base.supports(traits) }
    func supportedTraits(for traits: DeltaCore.ControllerSkin.Traits) -> DeltaCore.ControllerSkin.Traits? { base.supportedTraits(for: traits) }
    func items(for traits: DeltaCore.ControllerSkin.Traits) -> [DeltaCore.ControllerSkin.Item]? {
        // Relocation clears the old artwork. Opaque Split View casings must
        // retain their native Menu instead of exposing a hole in the skin.
        guard let original = base.items(for: traits), stock, traits.orientation == .landscape,
              base.isTranslucent(for: traits) == true,
              ["com.delta.gba.standard", "com.delta.snes.standard", "com.delta.n64.standard"].contains(base.identifier),
              let left = original.first(where: { Self.hasInput("l", $0) }), canvasSize.height > 0, canvasSize.width > 0 else { return base.items(for: traits) }
        return original.map { item in
            guard Self.hasInput("menu", item) else { return item }
            var result = item
            if let gutter = boundLandscapeGutter,
               let right = original.first(where: { Self.hasInput("r", $0) }) {
                let toPixels = CGAffineTransform(scaleX: canvasSize.width, y: canvasSize.height)
                // Reserve Menu and the companion button together. Both remain
                // 44pt targets in the same slots when Controller Mode hides inputs.
                let slot = gutter.width >= 48 ? gutter.insetBy(dx: 2, dy: 0) : gutter
                let pairSize = CGSize(width: 44, height: 96)
                let obstacles = original.filter { !Self.hasInput("menu", $0) }.map { $0.extendedFrame.applying(toPixels) }
                let belowShoulder = right.extendedFrame.applying(toPixels).maxY + 10 + pairSize.height/2
                if let pair = Self.gutterFrame(preferredY: belowShoulder, size: pairSize, gutter: slot, occupied: obstacles) {
                    let frame = CGRect(x: pair.minX, y: pair.minY, width: 44, height: 44)
                    let normalized = CGAffineTransform(scaleX: 1/canvasSize.width, y: 1/canvasSize.height)
                    result.frame = frame.applying(normalized)
                    result.extendedFrame = result.frame
                    return result
                }
                // Unsupported/no-space layouts retain the usable native Menu.
            }
            let topMargin = item.frame.minY - item.extendedFrame.minY
            let target = CGPoint(x: left.frame.midX, y: left.extendedFrame.maxY + topMargin + 10 / canvasSize.height)
            let dx = target.x - item.frame.midX, dy = target.y - item.frame.minY
            result.frame = item.frame.offsetBy(dx: dx, dy: dy)
            result.extendedFrame = item.extendedFrame.offsetBy(dx: dx, dy: dy)
            // Clamp the complete native touch target, not just its visible artwork.
            // This moves the stock default inward around landscape notches while
            // retaining its native size and the shoulder-to-menu vertical gap.
            let safe = CGRect(origin: .zero, size: canvasSize).inset(by: contentInsets)
                .applying(.init(scaleX: 1 / canvasSize.width, y: 1 / canvasSize.height))
            let hit = result.extendedFrame
            let shiftX = safe.width >= hit.width ? min(max(hit.minX, safe.minX), safe.maxX-hit.width)-hit.minX : safe.midX-hit.midX
            let shiftY = safe.height >= hit.height ? min(max(hit.minY, safe.minY), safe.maxY-hit.height)-hit.minY : safe.midY-hit.midY
            result.frame = result.frame.offsetBy(dx: shiftX, dy: shiftY)
            result.extendedFrame = result.extendedFrame.offsetBy(dx: shiftX, dy: shiftY)
            return result
        }
    }
    /// Keep the gutter's outer edge and select the nearest clear vertical slot.
    static func gutterFrame(preferredY: CGFloat, size: CGSize, gutter: CGRect, occupied: [CGRect]) -> CGRect? {
        guard gutter.minX.isFinite, gutter.minY.isFinite, gutter.width.isFinite, gutter.height.isFinite,
              size.width.isFinite, size.height.isFinite, preferredY.isFinite,
              size.width >= 44, size.height >= 44, gutter.width >= size.width, gutter.height >= size.height else { return nil }
        let half = size.height/2
        func clampedY(_ y: CGFloat) -> CGFloat { min(max(y, gutter.minY+half), gutter.maxY-half) }
        let initial = clampedY(preferredY)
        var candidates = [initial, gutter.minY+half, gutter.maxY-half]
        for rect in occupied where !rect.isNull && !rect.isEmpty {
            candidates += [rect.minY-half-2, rect.maxY+half+2]
        }
        candidates = candidates.map(clampedY).sorted { abs($0-initial) < abs($1-initial) }
        for y in candidates {
            let frame = CGRect(x: gutter.maxX-size.width, y: y-half, width: size.width, height: size.height)
            if !occupied.contains(where: { frame.intersects($0) }) { return frame }
        }
        return nil
    }
    private static func hasInput(_ name: String, _ item: DeltaCore.ControllerSkin.Item) -> Bool { item.inputs.allInputs.contains { $0.stringValue == name } }
    private func artwork(_ image: UIImage?, traits: DeltaCore.ControllerSkin.Traits) -> UIImage? {
        guard stock, let image else { return image }
        let sourceItems = base.items(for: traits) ?? [], targetItems = items(for: traits) ?? []
        let size = image.size
        func scaled(_ normalized: CGRect) -> CGRect { normalized.applying(.init(scaleX: size.width, y: size.height)) }
        return UIGraphicsImageRenderer(size: size).image { context in
            image.draw(at: .zero)
            if traits.orientation == .landscape,
               let menu = sourceItems.first(where: { Self.hasInput("menu", $0) }),
               let moved = targetItems.first(where: { $0.id == menu.id }), moved.frame != menu.frame {
                let old = scaled(menu.frame), destination = scaled(moved.frame)
                context.cgContext.saveGState(); context.cgContext.setBlendMode(.clear)
                context.cgContext.fill(old.insetBy(dx: -2, dy: -2)); context.cgContext.restoreGState()
                if boundLandscapeGutter != nil, abs(moved.frame.width*canvasSize.width - 44) < 0.1,
                   abs(moved.frame.height*canvasSize.height - 44) < 0.1 {
                    drawMenu(in: destination)
                } else {
                    context.cgContext.saveGState(); context.cgContext.clip(to: destination)
                    let sx = destination.width/old.width, sy = destination.height/old.height
                    image.draw(in: CGRect(x: destination.minX-old.minX*sx, y: destination.minY-old.minY*sy,
                        width: size.width*sx, height: size.height*sy))
                    context.cgContext.restoreGState()
                }
            }
            if traits.orientation == .portrait && traits.device == .iphone {
                let core = base.identifier.replacingOccurrences(of: "com.delta.", with: "").replacingOccurrences(of: ".standard", with: "")
                let edge = traits.displayType == .edgeToEdge
                // The centered stock wordmarks sit on transparent pixels above the
                // casing edge. Clear only their ink region; sampling lower casing
                // pixels here used to paint a raised purple block between L/R.
                if let rect = portraitWordmarkFrame(size: size, traits: traits) {
                    context.cgContext.saveGState()
                    context.cgContext.clip(to: rect)
                    if core == "nes" {
                        // NES prints on the casing: sample the same horizontal band.
                        image.draw(at: CGPoint(x: -70 * size.width / 320, y: 0))
                    } else {
                        context.cgContext.setBlendMode(.clear)
                        context.cgContext.fill(rect)
                    }
                    context.cgContext.restoreGState()
                    drawPortraitWordmark(in: context.cgContext, size: size, traits: traits)
                }
                let bottom: CGRect?
                switch core {
                case "gba": bottom = CGRect(x: 0.89, y: edge ? 0.77 : 0.85, width: 0.09, height: edge ? 0.115 : 0.13)
                case "gbc", "snes": bottom = CGRect(x: 0.89, y: edge ? 0.77 : 0.87, width: 0.09, height: edge ? 0.10 : 0.11)
                case "n64": bottom = CGRect(x: 0.89, y: edge ? 0.82 : 0.91, width: 0.09, height: edge ? 0.075 : 0.07)
                case "genesis": bottom = CGRect(x: 0.88, y: edge ? 0.77 : 0.83, width: 0.10, height: edge ? 0.115 : 0.125)
                case "ds": bottom = CGRect(x: edge ? 0.71 : 0.73, y: edge ? 0.805 : 0.82, width: edge ? 0.08 : 0.09, height: edge ? 0.035 : 0.05)
                default: bottom = nil
                }
                if let bottom {
                    let rect = scaled(bottom)
                    context.cgContext.saveGState(); context.cgContext.clip(to: rect)
                    image.draw(at: CGPoint(x: rect.width + 5, y: 0))
                    context.cgContext.restoreGState()
                    // GBA's interactive companion mark occupies the removed logo spot.
                    // Other console motifs use the composite branding in their own slot.
                    if core != "gba", let mark = UIImage(named: "DeltaBoundMark") {
                        let side = min(rect.width, rect.height)
                        mark.draw(in: CGRect(x: rect.midX-side/2, y: rect.midY-side/2, width: side, height: side))
                    }
                }
            }
            for patch in supplementalBrandingPatches(size: size, traits: traits) {
                // Copy an adjacent unprinted piece of the same casing. Copy mode
                // also replaces ink on transparent bezels without leaving a ghost.
                let sx = patch.frame.width / patch.sample.width
                let sy = patch.frame.height / patch.sample.height
                context.cgContext.saveGState()
                context.cgContext.clip(to: patch.frame)
                image.draw(in: CGRect(x: patch.frame.minX - patch.sample.minX * sx,
                                      y: patch.frame.minY - patch.sample.minY * sy,
                                      width: size.width * sx, height: size.height * sy),
                           blendMode: .copy, alpha: 1)
                context.cgContext.restoreGState()
                if patch.compact {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.boldSystemFont(ofSize: patch.frame.height * 0.8),
                        .foregroundColor: patch.color]
                    let label = "B" as NSString
                    let ink = label.size(withAttributes: attributes)
                    label.draw(at: CGPoint(x: patch.frame.midX - ink.width/2,
                                           y: patch.frame.midY - ink.height/2), withAttributes: attributes)
                } else {
                    drawWordmark(in: context.cgContext, frame: patch.frame.insetBy(dx: 3, dy: patch.frame.height * 0.16), color: patch.color)
                }
            }
        }
    }
    struct BrandingPatch {
        let frame: CGRect
        let sample: CGRect
        var compact = false
        var color = UIColor.white
    }
    /// Measured against the pinned stock artwork. This covers iPad's separate
    /// casing assets (including Split View), plus GBC/DS landscape on iPhone.
    /// It never edits a native item, touch region, game screen, or custom skin.
    func supplementalBrandingPatches(size: CGSize, traits: DeltaCore.ControllerSkin.Traits) -> [BrandingPatch] {
        guard stock else { return [] }
        let tablet = traits.device == .ipad
        let landscape = traits.orientation == .landscape
        let split = traits.displayType == .splitView
        let core = base.identifier
        if core == "com.delta.ds.standard", tablet || landscape {
            let controls = base.items(for: traits) ?? []
            guard let a = controls.first(where: { Self.hasInput("a", $0) }),
                  let b = controls.first(where: { Self.hasInput("b", $0) }),
                  let x = controls.first(where: { Self.hasInput("x", $0) }),
                  let y = controls.first(where: { Self.hasInput("y", $0) }) else { return [] }
            let scale = CGAffineTransform(scaleX: size.width, y: size.height)
            let gap = CGRect(x: y.frame.maxX, y: x.frame.maxY,
                             width: a.frame.minX - y.frame.maxX,
                             height: b.frame.minY - x.frame.maxY).applying(scale)
            let frame = gap.insetBy(dx: gap.width * 0.08, dy: gap.height * 0.08)
            let left = y.frame.applying(scale)
            let sample = tablet
                ? CGRect(x: left.minX, y: left.maxY + gap.height/2, width: frame.width, height: frame.height)
                : CGRect(x: left.minX - gap.width * 0.6, y: frame.minY, width: gap.width * 0.15, height: frame.height)
            return [BrandingPatch(frame: frame, sample: sample, compact: true,
                                  color: UIColor(red: 0.58, green: 0.31, blue: 0.38, alpha: 1))]
        }
        if core == "com.delta.gbc.standard", landscape, !split {
            let scale = size.height / (tablet ? 1024 : 375)
            let frame = CGRect(x: size.width/2 - (tablet ? 76 : 44) * scale,
                               y: (tablet ? 716 : 275) * scale,
                               width: (tablet ? 152 : 88) * scale, height: (tablet ? 42 : 23) * scale)
            let symbol = CGRect(x: size.width - (tablet ? 77 : 47) * scale,
                                y: (tablet ? 944 : 332) * scale,
                                width: (tablet ? 57 : 32) * scale, height: (tablet ? 54 : 31) * scale)
            // Stay within the black bezel at every row; farther sideways its
            // curved lower edge would copy a purple stripe beneath the label.
            let bezel = CGRect(x: frame.maxX + 2 * scale, y: frame.minY, width: 2 * scale, height: frame.height)
            return [BrandingPatch(frame: frame, sample: bezel),
                    BrandingPatch(frame: symbol, sample: symbol.offsetBy(dx: -symbol.width - 5 * scale, dy: 0), compact: true)]
        }
        guard tablet, !landscape || split else { return [] }
        if core == "com.delta.nes.standard" {
            let scale = size.height / 355
            let frame = CGRect(x: size.width - 200 * scale, y: 83 * scale, width: 116 * scale, height: 29 * scale)
            return [BrandingPatch(frame: frame,
                                  sample: CGRect(x: frame.minX - 85 * scale, y: frame.minY, width: 70 * scale, height: frame.height),
                                  color: UIColor(red: 0.8, green: 0, blue: 0, alpha: 1))]
        }
        let scale = size.height / 429
        let frame: CGRect
        switch core {
        case "com.delta.gba.standard", "com.delta.gbc.standard", "com.delta.snes.standard":
            frame = CGRect(x: size.width/2 - 112 * scale, y: 75 * scale, width: 224 * scale, height: 51 * scale)
        case "com.delta.genesis.standard":
            frame = CGRect(x: size.width/2 - 100 * scale, y: 190 * scale, width: 200 * scale, height: 50 * scale)
        default: return [] // N64's iPad casing has no Delta mark.
        }
        return [BrandingPatch(frame: frame,
                              sample: CGRect(x: frame.minX - 72 * scale, y: frame.minY, width: 60 * scale, height: frame.height),
                              color: core == "com.delta.snes.standard" ? .darkGray : .white)]
    }
    /// Measured in the official 320-point-wide portrait PDFs, not gameplay space.
    /// Keep the original top strip and all native item/hit rectangles unchanged.
    func portraitWordmarkFrame(size: CGSize, traits: DeltaCore.ControllerSkin.Traits) -> CGRect? {
        guard stock, traits.device == .iphone, traits.orientation == .portrait else { return nil }
        let rect: CGRect
        switch base.identifier {
        case "com.delta.gba.standard", "com.delta.snes.standard", "com.delta.n64.standard":
            rect = CGRect(x: 130, y: 0, width: 60, height: 12)
        case "com.delta.gbc.standard":
            rect = CGRect(x: 130, y: 10, width: 60, height: 12)
        case "com.delta.nes.standard":
            rect = CGRect(x: 14, y: traits.displayType == .edgeToEdge ? 13 : 8, width: 60, height: 12)
        default: return nil
        }
        let scale = size.width / 320
        return rect.applying(.init(scaleX: scale, y: scale))
    }
    // Cache the native font outlines. Both normal and pressed composites use
    // the same crisp uppercase wordmark without adding an interactive view.
    private static let portraitWordmark: CGPath = {
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 14, nil)
        let characters = Array("BOUND".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let path = CGMutablePath()
        var x: CGFloat = 0
        for (index, glyph) in glyphs.enumerated() {
            if let outline = CTFontCreatePathForGlyph(font, glyph, nil) {
                path.addPath(outline, transform: .init(translationX: x, y: 0))
            }
            x += advances[index].width + 0.8
        }
        return path
    }()
    func drawPortraitWordmark(in context: CGContext, size: CGSize,
                              traits: DeltaCore.ControllerSkin.Traits, color: UIColor? = nil) {
        guard let frame = portraitWordmarkFrame(size: size, traits: traits) else { return }
        drawWordmark(in: context, frame: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 10 * size.width / 320),
                     color: color ?? (base.identifier == "com.delta.nes.standard" ? .black : .white))
    }
    private func drawWordmark(in context: CGContext, frame: CGRect, color: UIColor) {
        let path = Self.portraitWordmark
        let ink = path.boundingBoxOfPath
        let scale = min(frame.width / ink.width, frame.height / ink.height)
        context.saveGState()
        context.translateBy(x: frame.midX - ink.width * scale / 2, y: frame.minY + ink.height * scale)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -ink.minX, y: -ink.minY)
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }
    private func drawMenu(in frame: CGRect) {
        let box = frame.insetBy(dx: 1, dy: 1)
        let path = UIBezierPath(roundedRect: box, cornerRadius: box.height/2)
        UIColor.deltaPurple.setFill(); path.fill()
        UIColor.white.withAlphaComponent(0.85).setStroke(); path.lineWidth = 1.5; path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: box.height * 0.25, weight: .semibold), .foregroundColor: UIColor.white]
        let label = "MENU" as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: box.midX-size.width/2, y: box.midY-size.height/2), withAttributes: attributes)
    }
    func image(for traits: DeltaCore.ControllerSkin.Traits, preferredSize: DeltaCore.ControllerSkin.Size) -> UIImage? { artwork(base.image(for: traits, preferredSize: preferredSize), traits: traits) }
    func pressedImage(for traits: DeltaCore.ControllerSkin.Traits, preferredSize: DeltaCore.ControllerSkin.Size) -> UIImage? { artwork(base.pressedImage(for: traits, preferredSize: preferredSize), traits: traits) }
    func image(for item: DeltaCore.ControllerSkin.Item, traits: DeltaCore.ControllerSkin.Traits, preferredSize: DeltaCore.ControllerSkin.Size) -> (UIImage, CGSize)? { base.image(for: item, traits: traits, preferredSize: preferredSize) }
    func isTranslucent(for traits: DeltaCore.ControllerSkin.Traits) -> Bool? { base.isTranslucent(for: traits) }
    func gameScreenFrame(for traits: DeltaCore.ControllerSkin.Traits) -> CGRect? { base.gameScreenFrame(for: traits) }
    func screens(for traits: DeltaCore.ControllerSkin.Traits) -> [DeltaCore.ControllerSkin.Screen]? { base.screens(for: traits) }
    func aspectRatio(for traits: DeltaCore.ControllerSkin.Traits) -> CGSize? { base.aspectRatio(for: traits) }
    func contentSize(for traits: DeltaCore.ControllerSkin.Traits) -> CGSize? { base.contentSize(for: traits) }
    func menuInsets(for traits: DeltaCore.ControllerSkin.Traits) -> UIEdgeInsets? { base.menuInsets(for: traits) }
}

/// Isolated user preference; OFF until explicitly enabled, retained across launches.
final class BoundControllerModePreferences {
    static let key = "bound.controller-mode.v1.enabled"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        set {
            defaults.set(newValue, forKey: Self.key)
            NotificationCenter.default.post(name: BoundAppearancePreferences.didChangeNotification, object: nil)
        }
    }
    static func hidesTouchControls(enabled: Bool, layout: BoundScreenLayout, landscape: Bool) -> Bool {
        enabled && layout == .bound && landscape
    }
}

/// Leaves Delta's screens and external-controller pipeline intact. Only the
/// touchscreen skin's gameplay controls disappear; its real Menu remains.
final class BoundControllerModeSkin: ControllerSkinProtocol {
    let base: ControllerSkinProtocol
    init(base: ControllerSkinProtocol) { self.base = base }
    var name: String { base.name }
    var identifier: String { base.identifier + ".bound-controller-mode" }
    var gameType: GameType { base.gameType }
    var isDebugModeEnabled: Bool { base.isDebugModeEnabled }
    private func isMenu(_ item: DeltaCore.ControllerSkin.Item) -> Bool { item.inputs.allInputs.contains { $0.stringValue == "menu" } }
    func items(for traits: DeltaCore.ControllerSkin.Traits) -> [DeltaCore.ControllerSkin.Item]? {
        guard traits.orientation == .landscape else { return base.items(for: traits) }
        return base.items(for: traits)?.filter(isMenu)
    }
    private func artwork(_ image: UIImage?, traits: DeltaCore.ControllerSkin.Traits) -> UIImage? {
        guard traits.orientation == .landscape, let image else { return image }
        return UIGraphicsImageRenderer(size: image.size).image { context in
            for item in items(for: traits) ?? [] {
                context.cgContext.saveGState()
                context.cgContext.clip(to: item.extendedFrame.applying(.init(scaleX: image.size.width, y: image.size.height)))
                image.draw(at: .zero)
                context.cgContext.restoreGState()
            }
        }
    }
    @MainActor static func cancelTouchInputs(in controller: ControllerView,
                                            preservingExternalInputsFrom controllers: [GameController] = [],
                                            emulatorCore: EmulatorCore? = nil) {
        let releasedPlayer = controller.playerIndex
        controller.cancelTouchInputs()
        // Thumbstick/touchscreen/sustained virtual inputs are separate from the
        // button touch map. Release only this virtual controller's own state.
        for input in Array(controller.sustainedInputs.keys) { controller.unsustain(input) }
        for input in Array(controller.activatedInputs.keys) { controller.deactivate(input) }
        guard let core = emulatorCore, let releasedPlayer,
              core.gameViews.isEmpty || core.gameViews.contains(where: { $0.window?.windowScene?.hasKeyboardFocus == true }) else { return }
        // Delta releases bridge bits per controller rather than aggregating
        // players. Restore same-player external holds after virtual releases.
        // Use the bridge directly: routing sustained inputs through didActivate
        // would deliberately pulse them off for two frames. Never replay actions.
        for external in controllers where external !== controller && external.playerIndex == releasedPlayer {
            var held = external.sustainedInputs
            for (input, value) in external.activatedInputs { held[input] = value }
            for (physical, value) in held {
                guard let mapped = external.mappedInput(for: physical, receiver: core) else { continue }
                let gameInput: Input
                if let standard = StandardGameControllerInput(input: mapped) {
                    guard let resolved = standard.input(for: core.game.type) else { continue }
                    gameInput = resolved
                } else { gameInput = mapped }
                guard gameInput.type == .game(core.game.type), let index = gameInput.intValue else { continue }
                // Match EmulatorCore's discrete threshold and analog saturation.
                var adjustedValue = value
                if !gameInput.isContinuous && value < 0.33 {
                    let sustained = external.sustainedInputs.first { input, _ in
                        guard let mapped = external.mappedInput(for: input, receiver: core) else { return false }
                        return (StandardGameControllerInput(input: mapped)?.input(for: core.game.type) ?? mapped) == gameInput
                    }
                    guard let sustained, sustained.value >= 0.33 else { continue }
                    adjustedValue = sustained.value
                } else if !gameInput.isContinuous && mapped.isContinuous && value > (1.0 - 0.33) {
                    adjustedValue = 1
                }
                core.deltaCore.emulatorBridge.activateInput(index, value: adjustedValue, playerIndex: releasedPlayer)
            }
        }
    }
    func supports(_ traits: DeltaCore.ControllerSkin.Traits) -> Bool { base.supports(traits) }
    func supportedTraits(for traits: DeltaCore.ControllerSkin.Traits) -> DeltaCore.ControllerSkin.Traits? { base.supportedTraits(for: traits) }
    func image(for traits: DeltaCore.ControllerSkin.Traits, preferredSize: DeltaCore.ControllerSkin.Size) -> UIImage? { artwork(base.image(for: traits, preferredSize: preferredSize), traits: traits) }
    func pressedImage(for traits: DeltaCore.ControllerSkin.Traits, preferredSize: DeltaCore.ControllerSkin.Size) -> UIImage? { artwork(base.pressedImage(for: traits, preferredSize: preferredSize), traits: traits) }
    func image(for item: DeltaCore.ControllerSkin.Item, traits: DeltaCore.ControllerSkin.Traits, preferredSize: DeltaCore.ControllerSkin.Size) -> (UIImage, CGSize)? {
        guard traits.orientation != .landscape || isMenu(item) else { return nil }
        return base.image(for: item, traits: traits, preferredSize: preferredSize)
    }
    func isTranslucent(for traits: DeltaCore.ControllerSkin.Traits) -> Bool? { base.isTranslucent(for: traits) }
    func gameScreenFrame(for traits: DeltaCore.ControllerSkin.Traits) -> CGRect? { base.gameScreenFrame(for: traits) }
    func screens(for traits: DeltaCore.ControllerSkin.Traits) -> [DeltaCore.ControllerSkin.Screen]? { base.screens(for: traits) }
    func aspectRatio(for traits: DeltaCore.ControllerSkin.Traits) -> CGSize? { base.aspectRatio(for: traits) }
    func contentSize(for traits: DeltaCore.ControllerSkin.Traits) -> CGSize? { base.contentSize(for: traits) }
    func menuInsets(for traits: DeltaCore.ControllerSkin.Traits) -> UIEdgeInsets? { base.menuInsets(for: traits) }
}
