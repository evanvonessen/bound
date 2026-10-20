import XCTest
import UIKit
import AVFoundation
import DeltaCore
@testable import Delta

@MainActor
final class StockControlAndGestureTests: XCTestCase {
    func testBoundControllerActionUsesNativeMappingTransformerAndActualReceiverPipeline() throws {
        let controller = BoundVirtualMappingController()
        var mapping = DeltaCore.GameControllerInputMapping(gameControllerInputType: controller.inputType)
        mapping.set(StandardGameControllerInput.menu, forControllerInput: MFiGameController.Input.leftShoulder)
        mapping.set(ActionInput.cycleBoundPanels, forControllerInput: MFiGameController.Input.rightShoulder)
        mapping.set(StandardGameControllerInput.b, forControllerInput: MFiGameController.Input.b)
        let transformer = GameControllerInputMappingTransformer()
        let bytes = try XCTUnwrap(transformer.transformedValue(mapping) as? Data)
        let restored = try XCTUnwrap(transformer.reverseTransformedValue(bytes) as? DeltaCore.GameControllerInputMapping)
        XCTAssertEqual(StandardGameControllerInput(input: try XCTUnwrap(restored.input(forControllerInput: MFiGameController.Input.leftShoulder))), .menu)
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(restored.input(forControllerInput: MFiGameController.Input.rightShoulder))), .cycleBoundPanels)
        XCTAssertEqual(StandardGameControllerInput(input: try XCTUnwrap(restored.input(forControllerInput: MFiGameController.Input.b))), .b)
        XCTAssertTrue(ControlsEditorView.actionInputs.contains(AnyInput(ActionInput.cycleBoundPanels)))
        XCTAssertEqual(AnyInput(ActionInput.cycleBoundPanels).localizedDisplayName, "Cycle Friend/Notes/Types")
        let state = BoundCompanionState()
        let coordinator = BoundCompanionCoordinator(state: state)
        let receiver = BoundVirtualMappingReceiver(coordinator: coordinator)
        controller.addReceiver(receiver, inputMapping: restored)
        defer { controller.removeReceiver(receiver) }
        controller.activate(MFiGameController.Input.leftShoulder)
        controller.deactivate(MFiGameController.Input.leftShoulder)
        XCTAssertEqual(receiver.menuActivations, 1)
        controller.activate(MFiGameController.Input.b)
        controller.deactivate(MFiGameController.Input.b)
        XCTAssertEqual(receiver.gameBActivations, 1)
        XCTAssertEqual(state.selected, 0, "Game B remains a game input")
        for selected in [1, 2, 0] {
            controller.activate(MFiGameController.Input.rightShoulder)
            controller.activate(MFiGameController.Input.rightShoulder, value: 0.9)
            XCTAssertEqual(state.selected, selected, "One action per physical hold")
            controller.deactivate(MFiGameController.Input.rightShoulder)
        }
        receiver.eligible = false
        controller.activate(MFiGameController.Input.rightShoulder)
        XCTAssertEqual(state.selected, 0)
        receiver.eligible = true
        controller.activate(MFiGameController.Input.rightShoulder)
        XCTAssertEqual(state.selected, 0, "A hold begun while blocked cannot become a fresh action")
        controller.deactivate(MFiGameController.Input.rightShoulder)
        controller.activate(MFiGameController.Input.rightShoulder)
        XCTAssertEqual(state.selected, 1)
        receiver.router.release(controller: controller) // Same reset used by real disconnect notification.
        controller.activate(MFiGameController.Input.rightShoulder)
        XCTAssertEqual(state.selected, 2)
        controller.deactivate(MFiGameController.Input.rightShoulder)
        XCTAssertEqual(receiver.gameBActivations, 1)
    }
    func testLandscapeStockMenuMovesBelowLeftShoulderWithoutChangingNativeInputOrSize() throws {
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .landscape)
        let old = try XCTUnwrap(base.items(for: traits))
        let skin = BoundStockControllerSkin(base: base, canvasSize: CGSize(width: 844, height: 390))
        let items = try XCTUnwrap(skin.items(for: traits))
        let menu = try XCTUnwrap(items.first { $0.inputs.allInputs.contains { $0.stringValue == "menu" } })
        let nativeMenu = try XCTUnwrap(old.first { $0.id == menu.id })
        let left = try XCTUnwrap(items.first { $0.inputs.allInputs.contains { $0.stringValue == "l" } })
        XCTAssertEqual(menu.frame.size, nativeMenu.frame.size)
        XCTAssertEqual(menu.extendedFrame.size, nativeMenu.extendedFrame.size)
        XCTAssertEqual(menu.frame.midX, left.frame.midX, accuracy: 0.001)
        XCTAssertEqual((menu.extendedFrame.minY-left.extendedFrame.maxY)*390, 10, accuracy: 0.001)
        for item in items where item.id != menu.id { XCTAssertEqual(item.frame, old.first { $0.id == item.id }?.frame) }
        let custom = BoundPlacedControllerSkin(base: skin, layout: .init(positions: [menu.id: .init(x: 0.5, y: 0.8, scale: 1)]), canvasSize: CGSize(width: 844, height: 390))
        XCTAssertEqual(custom.items(for: traits)?.first { $0.id == menu.id }?.frame.midX, 0.5)
        XCTAssertEqual(custom.items(for: traits)?.first { $0.id == menu.id }?.frame.midY, 0.8)
    }
    func testStockMenuCompleteTouchTargetStaysInsideLandscapeSafeArea() throws {
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .landscape)
        let size = CGSize(width: 844, height: 390)
        let original = try XCTUnwrap(base.items(for: traits))
        for inset in [UIEdgeInsets(top: 0, left: 47, bottom: 21, right: 0), UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 47)] {
            let skin = BoundStockControllerSkin(base: base, canvasSize: size, contentInsets: inset)
            let items = try XCTUnwrap(skin.items(for: traits))
            let menu = try XCTUnwrap(items.first { $0.inputs.allInputs.contains { $0.stringValue == "menu" } })
            let old = try XCTUnwrap(original.first { $0.id == menu.id })
            let hit = menu.extendedFrame.applying(.init(scaleX: size.width, y: size.height))
            XCTAssertGreaterThanOrEqual(hit.minX, inset.left-0.001)
            XCTAssertLessThanOrEqual(hit.maxX, size.width-inset.right+0.001)
            XCTAssertEqual(menu.frame.size, old.frame.size)
            XCTAssertEqual(menu.extendedFrame.size, old.extendedFrame.size)
            for item in items where item.id != menu.id { XCTAssertEqual(item.frame, original.first { $0.id == item.id }?.frame) }
        }
    }
    func testBoundLandscapeStockMenuUsesSafeRightGutterWithoutChangingGameplayOrOtherInputs() throws {
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let phones: [(CGSize, DeltaCore.ControllerSkin.DisplayType)] = [
            (CGSize(width: 667, height: 375), .standard),
            (CGSize(width: 812, height: 375), .edgeToEdge),
            (CGSize(width: 844, height: 390), .edgeToEdge),
            (CGSize(width: 896, height: 414), .edgeToEdge)
        ]
        for (size, display) in phones {
            let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: display, orientation: .landscape)
            let original = try XCTUnwrap(base.items(for: traits))
            let source = AVMakeRect(aspectRatio: try XCTUnwrap(base.aspectRatio(for: traits)), insideRect: CGRect(origin: .zero, size: size))
            let variants: [UIEdgeInsets] = display == .standard ? [.zero] : [
                UIEdgeInsets(top: 0, left: 47, bottom: 21, right: 0),
                UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 47)
            ]
            for insets in variants {
                let horizontal = CGRect(x: insets.left, y: 0, width: size.width-insets.left-insets.right, height: size.height)
                let game = AVMakeRect(aspectRatio: CGSize(width: 3, height: 2), insideRect: horizontal)
                XCTAssertEqual(game.height, size.height, accuracy: 0.001)
                XCTAssertEqual(game.width/game.height, 1.5, accuracy: 0.001)
                let safe = CGRect(origin: .zero, size: size).inset(by: insets)
                let gutter = CGRect(x: game.maxX, y: safe.minY, width: safe.maxX-game.maxX, height: safe.height)
                let localGutter = gutter.offsetBy(dx: -source.minX, dy: -source.minY).intersection(CGRect(origin: .zero, size: source.size))
                let skin = BoundStockControllerSkin(base: base, canvasSize: source.size, contentInsets: insets, boundLandscapeGutter: localGutter)
                let items = try XCTUnwrap(skin.items(for: traits))
                let menu = try XCTUnwrap(items.first { $0.inputs.allInputs.contains { $0.stringValue == "menu" } })
                let transform = CGAffineTransform(scaleX: source.width, y: source.height)
                let art = menu.frame.applying(transform).offsetBy(dx: source.minX, dy: source.minY)
                let hit = menu.extendedFrame.applying(transform).offsetBy(dx: source.minX, dy: source.minY)
                XCTAssertFalse(art.intersects(game))
                XCTAssertFalse(hit.intersects(game))
                XCTAssertGreaterThanOrEqual(hit.width, 44-0.001)
                XCTAssertGreaterThanOrEqual(hit.height, 44-0.001)
                XCTAssertGreaterThanOrEqual(hit.minX, gutter.minX-0.001)
                XCTAssertLessThanOrEqual(hit.maxX, gutter.maxX+0.001)
                XCTAssertEqual(art.width, 44, accuracy: 0.001)
                XCTAssertEqual(art.height, 44, accuracy: 0.001)
                XCTAssertEqual(hit.size, art.size)
                for item in items where item.id != menu.id {
                    XCTAssertEqual(item.frame, original.first { $0.id == item.id }?.frame)
                    XCTAssertEqual(item.extendedFrame, original.first { $0.id == item.id }?.extendedFrame)
                    XCTAssertFalse(hit.intersects(item.extendedFrame.applying(transform).offsetBy(dx: source.minX, dy: source.minY)))
                }
                for minimal in [false, true] {
                    let themed: ControllerSkinProtocol = minimal
                        ? BoundMinimalControllerSkin(base: skin, canvasSize: source.size, traits: UITraitCollection(userInterfaceStyle: .light)) : skin
                    let actualItems = try XCTUnwrap(themed.items(for: traits))
                    let actualMenu = try XCTUnwrap(actualItems.first { $0.id == menu.id })
                    let actualMenuArt = actualMenu.frame.applying(transform).offsetBy(dx: source.minX, dy: source.minY)
                    let actualMenuHit = actualMenu.extendedFrame.applying(transform).offsetBy(dx: source.minX, dy: source.minY)
                    let actualHits = actualItems.map { $0.extendedFrame.applying(transform).offsetBy(dx: source.minX, dy: source.minY) }
                    let cycle = BoundCompanionCycleButton(frame: .zero)
                    cycle.configure(menuFrame: actualMenuArt, controllerFrame: source, landscape: true,
                        minimal: minimal, content: .friend, canvas: safe, occupied: actualHits,
                        menuHitSize: actualMenuHit.size, rightControlGutter: gutter, menuHitFrame: actualMenuHit)
                    XCTAssertFalse(cycle.isHidden)
                    XCTAssertGreaterThanOrEqual(cycle.frame.width, 44-0.001)
                    XCTAssertGreaterThanOrEqual(cycle.frame.height, 44-0.001)
                    XCTAssertFalse(cycle.frame.intersects(game))
                    XCTAssertGreaterThanOrEqual(cycle.frame.minX, gutter.minX-0.001)
                    XCTAssertLessThanOrEqual(cycle.frame.maxX, gutter.maxX+0.001)
                    for target in actualHits { XCTAssertFalse(cycle.frame.intersects(target)) }
                }
                // Empty/reset customization retains the new Bound default.
                let reset = BoundPlacedControllerSkin(base: skin, layout: .init(), canvasSize: size, sourceFrame: source)
                let resetMenu = try XCTUnwrap(reset.items(for: traits)?.first { $0.id == menu.id })
                XCTAssertEqual(resetMenu.frame.minX*size.width, art.minX, accuracy: 0.001)
            }
        }
    }

    func testBoundGutterPolicyDoesNotMovePortraitItemsAndRejectsImpossibleTargets() throws {
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .portrait)
        let original = try XCTUnwrap(base.items(for: traits))
        let skin = BoundStockControllerSkin(base: base, canvasSize: CGSize(width: 390, height: 334),
            boundLandscapeGutter: CGRect(x: 290, y: 0, width: 100, height: 334))
        let items = try XCTUnwrap(skin.items(for: traits))
        for item in items {
            XCTAssertEqual(item.frame, original.first { $0.id == item.id }?.frame)
            XCTAssertEqual(item.extendedFrame, original.first { $0.id == item.id }?.extendedFrame)
        }
        XCTAssertNil(BoundStockControllerSkin.gutterFrame(preferredY: 90, size: CGSize(width: 44, height: 44), gutter: CGRect(x: 100, y: 0, width: 30, height: 200), occupied: []))
        XCTAssertNil(BoundStockControllerSkin.gutterFrame(preferredY: 90, size: CGSize(width: 44, height: 44), gutter: CGRect(x: 100, y: 0, width: 80, height: 200), occupied: [CGRect(x: 100, y: 0, width: 80, height: 200)]))
    }

    func testControllerModePreferenceDefaultsOffPersistsAndScopesOnlyBoundLandscape() throws {
        let name = "ControllerModeTests."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = BoundControllerModePreferences(defaults: defaults)
        XCTAssertFalse(preferences.isEnabled)
        preferences.isEnabled = true
        XCTAssertTrue(BoundControllerModePreferences(defaults: defaults).isEnabled)
        for enabled in [false, true] { for layout in BoundScreenLayout.allCases { for landscape in [false, true] {
            XCTAssertEqual(BoundControllerModePreferences.hidesTouchControls(enabled: enabled, layout: layout, landscape: landscape), enabled && layout == .bound && landscape)
        } } }
        preferences.isEnabled = false
        XCTAssertFalse(BoundControllerModePreferences(defaults: defaults).isEnabled)
    }

    func testControllerModeRetainsActualMenuAndRestoresNativeTreeAfterRotationAndOff() throws {
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let landscape = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .landscape)
        let portrait = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .portrait)
        let stock = BoundStockControllerSkin(base: base, canvasSize: CGSize(width: 844, height: 390),
            boundLandscapeGutter: CGRect(x: 738.5, y: 0, width: 105.5, height: 369))
        let original = try XCTUnwrap(stock.items(for: landscape))
        let mode = BoundControllerModeSkin(base: stock)
        let menu = try XCTUnwrap(original.first { $0.inputs.allInputs.contains { $0.stringValue == "menu" } })
        let controller = ControllerView(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        controller.usesControlOnlyHitTesting = true
        for _ in 0..<3 {
            controller.overrideControllerSkinTraits = landscape; controller.controllerSkin = mode
            let remaining = try XCTUnwrap(mode.items(for: landscape))
            XCTAssertEqual(remaining.map(\.id), [menu.id])
            XCTAssertEqual(remaining.first?.frame, menu.frame)
            XCTAssertEqual(remaining.first?.extendedFrame, menu.extendedFrame)
            XCTAssertEqual(controller.controlHitFrames.count, 1)
            XCTAssertEqual(mode.aspectRatio(for: landscape), stock.aspectRatio(for: landscape))
            XCTAssertEqual(mode.screens(for: landscape)?.first?.outputFrame, stock.screens(for: landscape)?.first?.outputFrame)
            let a = try XCTUnwrap(original.first { $0.inputs.allInputs.contains { $0.stringValue == "a" } })
            XCTAssertNil(controller.hitTest(CGPoint(x: a.frame.midX*844, y: a.frame.midY*390), with: nil))
            controller.overrideControllerSkinTraits = portrait; controller.controllerSkin = mode
            XCTAssertEqual(controller.controlHitFrames.count, stock.items(for: portrait)?.count)
            BoundControllerModeSkin.cancelTouchInputs(in: controller)
            controller.overrideControllerSkinTraits = landscape; controller.controllerSkin = stock
            XCTAssertEqual(controller.controlHitFrames.count, original.count)
        }
    }

    func testControllerModeReleasesOnlyVirtualControllerHeldAndSustainedInputs() throws {
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .landscape)
        let input = try XCTUnwrap(base.items(for: traits)?.first { $0.inputs.allInputs.contains { $0.stringValue == "a" } }?.inputs.allInputs.first)
        let touch = ControllerView(), separateController = ControllerView()
        touch.activate(input); touch.sustain(input)
        separateController.activate(input)
        XCTAssertFalse(touch.activatedInputs.isEmpty); XCTAssertFalse(touch.sustainedInputs.isEmpty)
        BoundControllerModeSkin.cancelTouchInputs(in: touch)
        XCTAssertTrue(touch.activatedInputs.isEmpty); XCTAssertTrue(touch.sustainedInputs.isEmpty)
        XCTAssertFalse(separateController.activatedInputs.isEmpty)
        separateController.deactivate(input)
    }

    func testControllerModeArtworkClearsLeftControlsAndKeepsMenuPixels() throws {
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .landscape)
        let stock = BoundStockControllerSkin(base: base, canvasSize: CGSize(width: 844, height: 390),
            boundLandscapeGutter: CGRect(x: 738.5, y: 0, width: 105.5, height: 369))
        let mode = BoundControllerModeSkin(base: stock)
        let image = try XCTUnwrap(mode.image(for: traits, preferredSize: .small)?.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width*image.height*4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width*4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))); return true
        }
        XCTAssertTrue(drawn)
        XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 })
        let leftWidth = image.width/2
        XCTAssertTrue((0..<image.height).allSatisfy { y in
            (0..<leftWidth).allSatisfy { x in bytes[(y*image.width+x)*4+3] == 0 }
        })
    }

    func testSevenItemGridCentersIncompleteFinalRow() {
        if #available(iOS 26, *) {
            XCTAssertEqual(ContainerRelativeGrid.incompleteRowOffset(columns: 3, count: 1, itemWidth: 145, spacing: 15), 160)
            XCTAssertEqual(ContainerRelativeGrid.incompleteRowOffset(columns: 4, count: 3, itemWidth: 145, spacing: 15), 80)
            XCTAssertEqual(ContainerRelativeGrid.incompleteRowOffset(columns: 3, count: 3, itemWidth: 145, spacing: 15), 0)
        }
    }

    func testShortRecognizedGesturesCommitTheirFinalValidSample() throws {
        let suite = "BoundShortGestures." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        let state = BoundCompanionState(preferences: preferences)
        state.landscape = true
        let coordinator = BoundCompanionCoordinator(state: state)
        coordinator.resize(.began, scale: 1.08)
        coordinator.resize(.ended, scale: 1.08)
        XCTAssertEqual(preferences.scale(for: .friend), 1.08, accuracy: 0.001)
        coordinator.fade(.began, dy: 20)
        coordinator.fade(.ended, dy: 20)
        XCTAssertLessThan(preferences.opacity(for: .friend), 1)
        let saved = preferences.opacity(for: .friend)
        coordinator.fade(.began, dy: 40)
        coordinator.fade(.cancelled, dy: 40)
        XCTAssertEqual(preferences.opacity(for: .friend), saved)
        state.selected = 2
        coordinator.fade(.began, dy: 60)
        coordinator.fade(.ended, dy: 60)
        XCTAssertEqual(preferences.opacity(for: .types), 1)
    }

    func testFingerCountChangesCannotCommitUnwantedMovementResizeOrOpacity() {
        for required in [1, 2, 3] {
            var gate = BoundPiPTouchCountGate()
            XCTAssertEqual(gate.update(phase: .began, touches: required, required: required), .deliver)
            XCTAssertEqual(gate.update(phase: .changed, touches: required+1, required: required), .cancel)
            XCTAssertEqual(gate.update(phase: .changed, touches: required, required: required), .ignore)
            XCTAssertEqual(gate.update(phase: .ended, touches: 0, required: required), .ignore)
            XCTAssertEqual(gate.update(phase: .began, touches: required, required: required), .deliver)
            XCTAssertEqual(gate.update(phase: .ended, touches: 0, required: required), .deliver)
        }
    }
    func testStaggeredFingerReleaseCommitsButAddingFingersStillCancels() {
        for required in [1, 2] {
            var gate = BoundPiPTouchCountGate()
            XCTAssertEqual(gate.update(phase: .began, touches: required, required: required), .deliver)
            XCTAssertEqual(gate.update(phase: .changed, touches: required, required: required), .deliver)
            XCTAssertEqual(gate.update(phase: .changed, touches: required - 1, required: required, releasing: true), .ignore)
            XCTAssertEqual(gate.update(phase: .ended, touches: 0, required: required, releasing: true), .deliver)
            XCTAssertEqual(gate.update(phase: .began, touches: required, required: required), .deliver)
            XCTAssertEqual(gate.update(phase: .changed, touches: required + 1, required: required), .cancel)
            XCTAssertEqual(gate.update(phase: .ended, touches: 0, required: required, releasing: true), .ignore)
        }
    }

    func testLandscapePiPReservesAllStockAndCompanionHitRegions() throws {
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .landscape)
        let canvas = CGRect(x: 0, y: 0, width: 844, height: 390)
        for insets in [UIEdgeInsets(top: 0, left: 47, bottom: 21, right: 0), UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 47)] {
            let skin = BoundStockControllerSkin(base: base, canvasSize: canvas.size, contentInsets: insets)
            let items = try XCTUnwrap(skin.items(for: traits))
            let transform = CGAffineTransform(scaleX: canvas.width, y: canvas.height)
            let occupied = items.map { $0.extendedFrame.applying(transform) }
            let menu = try XCTUnwrap(items.first { $0.inputs.allInputs.contains { $0.stringValue == "menu" } })
            let right = try XCTUnwrap(items.first { $0.inputs.allInputs.contains { $0.stringValue == "r" } })
            let game = CGRect(x: 129.5, y: 0, width: 585, height: 390)
            for minimal in [false, true] {
                let cycle = BoundCompanionCycleButton(frame: .zero)
                cycle.configure(menuFrame: menu.frame.applying(transform), controllerFrame: canvas,
                    landscape: true, minimal: minimal, content: .types, canvas: canvas.inset(by: insets),
                    occupied: occupied, rightShoulderFrame: right.extendedFrame.applying(transform),
                    menuHitSize: menu.extendedFrame.applying(transform).size)
                XCTAssertFalse(cycle.isHidden)
                for scale: CGFloat in [0.65, 1.4] {
                    let layout = BoundPiPLayout(viewport: game, baseSize: CGSize(width: 210.6, height: 140.4), scale: scale,
                                              occupied: occupied + [cycle.frame])
                    XCTAssertGreaterThan(layout.size.width, 100)
                    XCTAssertEqual(layout.size.width/layout.size.height, 1.5, accuracy: 0.001)
                    for corner in BoundPiPCorner.allCases {
                        let center = layout.center(corner)
                        let panel = CGRect(x: center.x-layout.size.width/2, y: center.y-layout.size.height/2,
                                           width: layout.size.width, height: layout.size.height)
                        XCTAssertTrue(game.contains(panel))
                        for target in occupied + [cycle.frame] { XCTAssertFalse(panel.intersects(target)) }
                    }
                }
            }
        }
    }

}

private final class BoundVirtualMappingController: NSObject, GameController {
    let name = "Bound virtual mapping test"
    var playerIndex: Int? = 0
    let inputType = GameControllerInputType.mfi
    var defaultInputMapping: GameControllerInputMappingProtocol? { nil }
}

@MainActor
private final class BoundVirtualMappingReceiver: GameControllerReceiver {
    let router = BoundPanelActionRouter()
    let coordinator: BoundCompanionCoordinator
    var eligible = true
    var menuActivations = 0
    var gameBActivations = 0
    init(coordinator: BoundCompanionCoordinator) { self.coordinator = coordinator }
    func gameController(_ gameController: GameController, didActivate input: Input, value: Double) {
        if ActionInput(input: input) == .cycleBoundPanels {
            router.activate(controller: gameController, eligible: eligible) { coordinator.cyclePanels() }
        } else if StandardGameControllerInput(input: input) == .menu { menuActivations += 1 }
        else if StandardGameControllerInput(input: input) == .b { gameBActivations += 1 }
    }
    func gameController(_ gameController: GameController, didDeactivate input: Input) {
        if ActionInput(input: input) == .cycleBoundPanels { router.release(controller: gameController) }
    }
}
