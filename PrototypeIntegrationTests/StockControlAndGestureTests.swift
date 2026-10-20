import XCTest
import UIKit
import AVFoundation
import CoreData
import GameController
import DeltaCore
@testable import Delta
@testable import class Delta.Game
@testable import class Delta.GameViewController

private struct RendererFixtureGame: GameProtocol {
    let fileURL: URL
    let type: GameType
}

@MainActor
final class StockControlAndGestureTests: XCTestCase {
    func testStoppedSaveStatePreviewCannotRestartAfterHandoff() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rom = directory.appendingPathComponent("preview.gba")
        try FileManager.default.copyItem(at: fixture, to: rom)
        let preview = PreviewGameViewController()
        preview.game = RendererFixtureGame(fileURL: rom, type: .gba)
        preview.loadViewIfNeeded()
        let core = try XCTUnwrap(preview.emulatorCore)
        defer { core.stop(); preview.game = nil }

        let stopped = expectation(description: "Preview relinquished the shared emulator")
        preview.stopPreview { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)

        // UIKit may finish presenting a context-menu preview after its action
        // has requested shutdown. Its inherited startup path must stay inert.
        XCTAssertFalse(preview.startEmulation(), "A dismissed preview must never reacquire gameplay's bridge")
        XCTAssertEqual(core.state, .stopped)
    }

    func testSaveStatePreviewUsesGameplayRendererOptions() throws {
        let gameplayController = GameViewController()
        let previewController = PreviewGameViewController()

        func options(for game: GameProtocol) -> ([EmulatorCore.Option: Any], [EmulatorCore.Option: Any]) {
            let gameplayOptions = gameplayController.gameViewController(gameplayController, optionsFor: game)
            let previewOptions = previewController.gameViewController(previewController, optionsFor: game)
            return (gameplayOptions, previewOptions)
        }

        // Use a private, unsaved context: Game's computed settings need a context,
        // but these fixtures must never enter DatabaseManager's library.
        let modelURL = try XCTUnwrap(Bundle(for: DatabaseManager.self).url(forResource: "Delta", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        let entity = try XCTUnwrap(model.entitiesByName["Game"])
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        defer { context.reset() }

        func makeGame(type: GameType, settings: [Game.Setting: Any] = [:]) -> Game {
            let game = Game(entity: entity, insertInto: context)
            game.type = type
            game.filename = "renderer-options-fixture.rom"
            game.identifier = UUID().uuidString
            game.name = "Renderer Options Fixture"
            game.settings = settings
            return game
        }

        let previousMetalPreference = ExperimentalFeatures.shared.metal.isEnabled
        defer { ExperimentalFeatures.shared.metal.isEnabled = previousMetalPreference }

        let gba = RendererFixtureGame(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("renderer-fixture.gba"), type: .gba)
        ExperimentalFeatures.shared.metal.isEnabled = false
        var (gameplayOptions, previewOptions) = options(for: gba)
        XCTAssertEqual(gameplayOptions[.metal] as? Bool, true)
        XCTAssertEqual(previewOptions[.metal] as? Bool, true, "GBA previews must use the same Metal path as gameplay")
        XCTAssertEqual(previewOptions[.metal] as? Bool, gameplayOptions[.metal] as? Bool)

        let otherGame = makeGame(type: .gbc)
        for enabled in [false, true] {
            ExperimentalFeatures.shared.metal.isEnabled = enabled
            (gameplayOptions, previewOptions) = options(for: otherGame)
            XCTAssertEqual(gameplayOptions[.metal] as? Bool, enabled)
            XCTAssertEqual(previewOptions[.metal] as? Bool, enabled)
        }

        let n64 = makeGame(type: .n64, settings: [.openGLES2: true])
        (gameplayOptions, previewOptions) = options(for: n64)
        XCTAssertEqual(gameplayOptions[.openGLES2] as? Bool, true)
        XCTAssertEqual(previewOptions[.openGLES2] as? Bool, true)
        XCTAssertNil(gameplayOptions[.metal])
        XCTAssertNil(previewOptions[.metal])
    }

    func testPreviewCommitAndLateDismissalPreserveGameplayCore() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rom = directory.appendingPathComponent("handoff.gba")
        try FileManager.default.copyItem(at: fixture, to: rom)
        let game = RendererFixtureGame(fileURL: rom, type: .gba)
        let gameplay = try XCTUnwrap(EmulatorCore(game: game, options: [.metal: true]))
        defer { gameplay.stop() }
        XCTAssertTrue(gameplay.start())
        XCTAssertTrue(gameplay.pause())
        let selected = gameplay.saveSaveState(to: directory.appendingPathComponent("selected.svs"))
        gameplay.stop()

        for iteration in 0..<3 {
            let preview = PreviewGameViewController()
            preview.game = game
            preview.previewSaveState = selected
            preview.loadViewIfNeeded()
            let previewCore = try XCTUnwrap(preview.emulatorCore)
            var stopNotifications = 0
            preview.onPreviewStopped = { stopNotifications += 1 }
            var runningTransitions = 0
            let prepared = keyValueObservingExpectation(for: previewCore, keyPath: #keyPath(EmulatorCore.state)) { _, change in
                guard (change[NSKeyValueChangeKey.newKey] as? NSNumber)?.intValue == EmulatorCore.State.running.rawValue else { return false }
                runningTransitions += 1
                return runningTransitions == 2 // Initial start, then resume after loading the selected state.
            }
            XCTAssertTrue(preview.startEmulation())
            wait(for: [prepared], timeout: 5)
            let committed = preview.stopPreview(savingTo: directory.appendingPathComponent("commit-\(iteration).svs"))
            XCTAssertNotNil(committed, "A prepared live preview must commit its current snapshot")
            XCTAssertEqual(previewCore.state, .stopped)
            XCTAssertEqual(stopNotifications, 1)

            XCTAssertTrue(gameplay.start())
            XCTAssertTrue(gameplay.pause())
            // Load the committed preview after gameplay owns the bridge, then
            // deliver late UIKit callbacks from the old preview controller.
            try gameplay.load(committed ?? selected)
            preview.beginAppearanceTransition(true, animated: false)
            preview.endAppearanceTransition()
            XCTAssertFalse(preview.startEmulation())
            preview.beginAppearanceTransition(false, animated: false)
            preview.endAppearanceTransition()
            preview.stopPreview()
            XCTAssertEqual(stopNotifications, 1, "Repeated UIKit cleanup must be idempotent")
            XCTAssertEqual(gameplay.state, .paused)
            let after = gameplay.saveSaveState(to: directory.appendingPathComponent("after-\(iteration).svs"))
            XCTAssertGreaterThan(try Data(contentsOf: after.fileURL).count, 0)
            try gameplay.load(after)
            XCTAssertTrue(gameplay.resume())
            XCTAssertTrue(gameplay.pause())
            gameplay.stop()
        }
    }

    func testLandscapeControllerTogglesUseNativeMappingTransformerAndActualReceiverPipeline() throws {
        let domain = "BoundControllerActionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.buttonType = .option1
        for content in BoundPiPContent.allCases {
            preferences.setEnabled([.friend, .notes, .types].contains(content), for: content)
        }
        let controller = BoundVirtualMappingController()
        var mapping = DeltaCore.GameControllerInputMapping(gameControllerInputType: controller.inputType)
        mapping.set(StandardGameControllerInput.menu, forControllerInput: MFiGameController.Input.leftShoulder)
        mapping.set(ActionInput.cycleBoundPanels, forControllerInput: MFiGameController.Input.rightShoulder)
        mapping.set(ActionInput.toggleBoundFriend, forControllerInput: MFiGameController.Input.x)
        mapping.set(ActionInput.toggleBoundMultiview, forControllerInput: MFiGameController.Input.y)
        mapping.set(StandardGameControllerInput.b, forControllerInput: MFiGameController.Input.b)
        let transformer = GameControllerInputMappingTransformer()
        let bytes = try XCTUnwrap(transformer.transformedValue(mapping) as? Data)
        let restored = try XCTUnwrap(transformer.reverseTransformedValue(bytes) as? DeltaCore.GameControllerInputMapping)
        XCTAssertEqual(StandardGameControllerInput(input: try XCTUnwrap(restored.input(forControllerInput: MFiGameController.Input.leftShoulder))), .menu)
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(restored.input(forControllerInput: MFiGameController.Input.rightShoulder))), .cycleBoundPanels)
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(restored.input(forControllerInput: MFiGameController.Input.x))), .toggleBoundFriend)
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(restored.input(forControllerInput: MFiGameController.Input.y))), .toggleBoundMultiview)
        XCTAssertEqual(StandardGameControllerInput(input: try XCTUnwrap(restored.input(forControllerInput: MFiGameController.Input.b))), .b)
        XCTAssertTrue(ControlsEditorView.actionInputs.contains(AnyInput(ActionInput.cycleBoundPanels)))
        XCTAssertEqual(AnyInput(ActionInput.cycleBoundPanels).localizedDisplayName, "Cycle Friend/Notes/Types")
        XCTAssertTrue(ControlsEditorView.actionInputs.contains(AnyInput(ActionInput.toggleBoundFriend)))
        XCTAssertEqual(AnyInput(ActionInput.toggleBoundFriend).localizedDisplayName, "Toggle Friend")
        XCTAssertTrue(ControlsEditorView.actionInputs.contains(AnyInput(ActionInput.toggleBoundMultiview)))
        XCTAssertEqual(AnyInput(ActionInput.toggleBoundMultiview).localizedDisplayName, "Toggle Multiview")
        let state = BoundCompanionState(preferences: preferences)
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

        // Each action is independently mapped and routed through the actual
        // GameController receiver callback. Simultaneous holds must not collide.
        controller.activate(MFiGameController.Input.x)
        controller.activate(MFiGameController.Input.y)
        controller.activate(MFiGameController.Input.x, value: 0.9)
        controller.activate(MFiGameController.Input.y, value: 0.9)
        XCTAssertEqual(receiver.friendToggleActivations, 1)
        XCTAssertEqual(receiver.multiviewToggleActivations, 1)
        controller.deactivate(MFiGameController.Input.x)
        controller.deactivate(MFiGameController.Input.y)
        XCTAssertEqual(receiver.friendToggleActivations, 1)
        XCTAssertEqual(receiver.multiviewToggleActivations, 1)

        // Releasing one mapped action re-arms that action alone.
        controller.activate(MFiGameController.Input.x)
        controller.activate(MFiGameController.Input.y)
        receiver.router.release(controller: controller, action: .toggleBoundFriend)
        controller.activate(MFiGameController.Input.x)
        controller.activate(MFiGameController.Input.y)
        XCTAssertEqual(receiver.friendToggleActivations, 3)
        XCTAssertEqual(receiver.multiviewToggleActivations, 2)
        controller.deactivate(MFiGameController.Input.x)
        controller.deactivate(MFiGameController.Input.y)

        // A hold that starts while blocked stays consumed until release.
        receiver.eligible = false
        controller.activate(MFiGameController.Input.x)
        XCTAssertEqual(receiver.friendToggleActivations, 3)
        receiver.eligible = true
        controller.activate(MFiGameController.Input.x)
        XCTAssertEqual(receiver.friendToggleActivations, 3)
        controller.deactivate(MFiGameController.Input.x)
        controller.activate(MFiGameController.Input.x)
        XCTAssertEqual(receiver.friendToggleActivations, 4)
        controller.deactivate(MFiGameController.Input.x)

        // The disconnect reset clears every action hold for this controller.
        controller.activate(MFiGameController.Input.x)
        controller.activate(MFiGameController.Input.y)
        receiver.router.release(controller: controller)
        controller.activate(MFiGameController.Input.x)
        controller.activate(MFiGameController.Input.y)
        XCTAssertEqual(receiver.friendToggleActivations, 6)
        XCTAssertEqual(receiver.multiviewToggleActivations, 4)
        controller.deactivate(MFiGameController.Input.x)
        controller.deactivate(MFiGameController.Input.y)

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
        XCTAssertEqual(preferences.layout, .mode1)
        preferences.isEnabled = true
        XCTAssertTrue(BoundControllerModePreferences(defaults: defaults).isEnabled)
        XCTAssertEqual(BoundControllerModePreferences(defaults: defaults).layout, .mode1)
        for enabled in [false, true] { for layout in BoundScreenLayout.allCases { for landscape in [false, true] {
            XCTAssertEqual(BoundControllerModePreferences.hidesTouchControls(enabled: enabled, layout: layout, landscape: landscape), enabled && layout == .bound && landscape)
        } } }
        preferences.isEnabled = false
        XCTAssertFalse(BoundControllerModePreferences(defaults: defaults).isEnabled,
                       "A saved Controller Mode off choice remains off after recreating preferences.")
        XCTAssertEqual(preferences.layout, .mode1)
    }

    func testBoundTouchControlsRemainAssignedOffAndInPortraitWithExternalPlayerCollision() throws {
        // updateControllers clears local player 0 when a wireless controller
        // is also assigned to player 0. Bound still needs its visible virtual
        // receiver, using that external player's input route.
        for modeEnabled in [false, true] {
            for landscape in [false, true] {
                let modeOnly = BoundControllerModePreferences.hidesTouchControls(
                    enabled: modeEnabled, layout: .bound, landscape: landscape)
                let assignment = BoundControllerViewAssignment.resolve(
                    localPlayerIndex: nil, externalPlayerIndex: 0, menuOnly: modeOnly)
                XCTAssertTrue(assignment.isVisible)
                XCTAssertEqual(assignment.playerIndex, 0)
            }
        }

        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let landscapeTraits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .landscape)
        let portraitTraits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .portrait)
        let stock = BoundStockControllerSkin(base: base, canvasSize: CGSize(width: 844, height: 390))
        let gameplayInputs: Set<String> = ["a", "b", "l", "r"]

        let offLandscape = try XCTUnwrap(stock.items(for: landscapeTraits))
        XCTAssertTrue(gameplayInputs.isSubset(of: Set(offLandscape.flatMap { $0.inputs.allInputs.map(\.stringValue) })))

        let modeSkin = BoundControllerModeSkin(base: stock)
        let modeLandscape = try XCTUnwrap(modeSkin.items(for: landscapeTraits))
        XCTAssertEqual(modeLandscape.count, 1)
        XCTAssertEqual(modeLandscape.first?.inputs.allInputs.map(\.stringValue), ["menu"])

        let modePortrait = try XCTUnwrap(modeSkin.items(for: portraitTraits))
        XCTAssertTrue(gameplayInputs.isSubset(of: Set(modePortrait.flatMap { $0.inputs.allInputs.map(\.stringValue) })))
    }

    @available(iOS 17.0, *)
    func testBoundControllerViewStaysVisibleWithConnectedVirtualPadAcrossModesAndReset() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
        let gameDirectory = DatabaseManager.gamesDirectoryURL
        try FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        let filename = "controller-visibility-\(UUID().uuidString).gba"
        let gameURL = gameDirectory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: fixture, to: gameURL)
        defer { try? FileManager.default.removeItem(at: gameURL) }

        let modelURL = try XCTUnwrap(Bundle(for: DatabaseManager.self).url(forResource: "Delta", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        let entity = try XCTUnwrap(model.entitiesByName["Game"])
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        defer { context.reset() }
        let game = Game(entity: entity, insertInto: context)
        game.type = .gba
        game.filename = filename
        game.identifier = UUID().uuidString
        game.name = "Controller Visibility Fixture"

        let appearance = BoundAppearancePreferences()
        let oldScreenLayout = appearance.screenLayout
        let oldTheme = appearance.theme
        let modePreferences = BoundControllerModePreferences()
        let oldModeEnabled = modePreferences.isEnabled
        let oldModeLayout = modePreferences.layout
        let oldLocalPlayerIndex = Settings.localControllerPlayerIndex
        let navigationPreferences = BoundControllerNavigationPreferences()
        let oldNavigationEnabled = navigationPreferences.isEnabled
        let landscapePreferences = BoundLandscapePreferences()
        let oldLandscapeOption = landscapePreferences.option
        let manager = ExternalGameControllerManager.shared
        let oldAutomaticAssignment = manager.automaticallyAssignsPlayerIndexes
        let oldControllers = manager.connectedControllers.map { ($0, $0.playerIndex) }

        let configuration = GCVirtualController.Configuration()
        configuration.elements = [GCInputButtonA, GCInputButtonB, GCInputLeftShoulder,
                                  GCInputRightShoulder, GCInputDirectionPad]
        configuration.isHidden = true
        let virtualController = GCVirtualController(configuration: configuration)
        // Install teardown before connecting: connect() may partially succeed
        // even when it later reports an error and the test skips.
        defer { virtualController.disconnect() }
        do {
            try await virtualController.connect()
        } catch {
            throw XCTSkip("The simulator did not provide a virtual game controller: \(error.localizedDescription)")
        }
        let physicalController = try XCTUnwrap(virtualController.controller)

        var window: UIWindow?
        let gameController = BoundControllerMenuProbe()
        let selectors = (NSSelectorFromString("mfiGameControllerDidConnect:"),
                         NSSelectorFromString("mfiGameControllerDidDisconnect:"))
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        defer {
            if manager.connectedControllers.contains(where: { ($0 as? MFiGameController)?.controller === physicalController }) {
                manager.perform(selectors.1, with: Notification(name: .GCControllerDidDisconnect, object: physicalController))
            }
            manager.automaticallyAssignsPlayerIndexes = oldAutomaticAssignment
            oldControllers.forEach { $0.0.playerIndex = $0.1 }
            Settings.localControllerPlayerIndex = oldLocalPlayerIndex
            modePreferences.isEnabled = oldModeEnabled
            modePreferences.layout = oldModeLayout
            navigationPreferences.isEnabled = oldNavigationEnabled
            landscapePreferences.option = oldLandscapeOption
            appearance.screenLayout = oldScreenLayout
            appearance.theme = oldTheme
            gameController.emulatorCore?.stop()
            gameController.game = nil
            window?.rootViewController = nil
            window?.isHidden = true
            previousKeyWindow?.makeKey()
        }

        manager.automaticallyAssignsPlayerIndexes = false
        manager.connectedControllers.forEach { $0.playerIndex = nil }
        if !manager.connectedControllers.contains(where: { ($0 as? MFiGameController)?.controller === physicalController }) {
            XCTAssertTrue(manager.responds(to: selectors.0), "The real MFi connection entry point must be available to the test")
            manager.perform(selectors.0, with: Notification(name: .GCControllerDidConnect, object: physicalController))
        }
        let external = try XCTUnwrap(manager.connectedControllers.first { ($0 as? MFiGameController)?.controller === physicalController })
        external.playerIndex = 0

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            throw XCTSkip("The integration test host has no active window scene")
        }
        let testWindow = UIWindow(windowScene: scene)
        window = testWindow
        testWindow.rootViewController = gameController
        testWindow.makeKeyAndVisible()
        gameController.game = game
        appearance.screenLayout = .bound
        modePreferences.isEnabled = false

        let landscapeTraits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .landscape)
        let portraitTraits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .portrait)
        let gameplayInputs: Set<String> = ["a", "b", "l", "r"]
        let refreshSelector = NSSelectorFromString("updateControllers")
        XCTAssertTrue(gameController.responds(to: refreshSelector))

        func setViewport(_ size: CGSize, traits: DeltaCore.ControllerSkin.Traits) {
            gameController.view.bounds = CGRect(origin: .zero, size: size)
            gameController.view.frame = CGRect(origin: .zero, size: size)
            gameController.controllerView.overrideControllerSkinTraits = traits
            gameController.view.setNeedsLayout()
            gameController.view.layoutIfNeeded()
            gameController.perform(refreshSelector)
        }
        func visibleInputs(_ traits: DeltaCore.ControllerSkin.Traits) -> Set<String> {
            Set((gameController.controllerView.controllerSkin?.items(for: traits) ?? [])
                .flatMap { $0.inputs.allInputs.map(\.stringValue) })
        }
        func assertTouchControls(_ traits: DeltaCore.ControllerSkin.Traits, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(gameController.controllerView.isHidden, file: file, line: line)
            XCTAssertEqual(gameController.controllerView.playerIndex, 0, file: file, line: line)
            XCTAssertTrue(gameplayInputs.isSubset(of: visibleInputs(traits)), "GBA A/B/L/R must remain visible", file: file, line: line)
        }

        // This reproduces local player 0 being cleared when a connected pad
        // owns player 0. Each saved layout must remain inert while mode is off.
        for layout in BoundControllerModeLayout.allCases {
            Settings.localControllerPlayerIndex = 0
            modePreferences.isEnabled = false
            modePreferences.layout = layout
            setViewport(CGSize(width: 844, height: 390), traits: landscapeTraits)
            XCTAssertNil(Settings.localControllerPlayerIndex, "The test must exercise the external-player collision")
            assertTouchControls(landscapeTraits)
        }

        // Reset's real settings notification must leave the receiver present.
        modePreferences.isEnabled = false
        modePreferences.layout = .mode1
        NotificationCenter.default.post(name: Settings.didChangeNotification, object: nil,
            userInfo: [Settings.NotificationUserInfoKey.name: Settings.Name.resetToDefaults])
        setViewport(CGSize(width: 844, height: 390), traits: landscapeTraits)
        assertTouchControls(landscapeTraits)

        // Even an enabled Mode 3 cannot remove portrait GBA buttons.
        modePreferences.isEnabled = true
        modePreferences.layout = .mode3
        setViewport(CGSize(width: 390, height: 844), traits: portraitTraits)
        assertTouchControls(portraitTraits)

        // With the mode truly active in landscape, the same assigned receiver
        // remains visible and exposes its actual Menu item only.
        setViewport(CGSize(width: 844, height: 390), traits: landscapeTraits)
        XCTAssertFalse(gameController.controllerView.isHidden)
        XCTAssertEqual(gameController.controllerView.playerIndex, 0)
        XCTAssertEqual(visibleInputs(landscapeTraits), ["menu"])

        // Drive mapped actions through the same live receiver used by a pad.
        landscapePreferences.option = .option7
        navigationPreferences.isEnabled = true
        setViewport(CGSize(width: 844, height: 390), traits: landscapeTraits)
        let core = try XCTUnwrap(gameController.emulatorCore)
        if core.state == .stopped { core.start() }
        if core.state == .paused { core.resume() }
        XCTAssertEqual(core.state, .running)
        var events: [Notification] = []
        let observation = NotificationCenter.default.addObserver(forName: BoundControllerNavigationEvent.notificationName,
                                                                 object: nil, queue: .main) { events.append($0) }
        defer { NotificationCenter.default.removeObserver(observation) }
        func press(_ action: ActionInput) {
            var mapping = DeltaCore.GameControllerInputMapping(gameControllerInputType: external.inputType)
            mapping.set(action, forControllerInput: MFiGameController.Input.a)
            external.addReceiver(gameController, inputMapping: mapping)
            external.activate(MFiGameController.Input.a)
            external.deactivate(MFiGameController.Input.a)
        }
        press(.boundShowDex)
        press(.boundNextItem)
        XCTAssertEqual(events.count, 1, "The connected pad must reach the visible Dex through GameViewController")
        XCTAssertEqual(BoundControllerNavigationEvent.command(from: try XCTUnwrap(events.last), gameID: game.identifier, content: .dex), .nextItem)
        navigationPreferences.isEnabled = false
        press(.boundNextItem)
        XCTAssertEqual(events.count, 1, "Opting out disables navigation without removing mappings")
        navigationPreferences.isEnabled = true
        modePreferences.isEnabled = false
        setViewport(CGSize(width: 844, height: 390), traits: landscapeTraits)
        press(.boundNextItem)
        XCTAssertEqual(events.count, 1, "Controller Mode off ignores mapped view actions")
        modePreferences.isEnabled = true
        setViewport(CGSize(width: 390, height: 844), traits: portraitTraits)
        press(.boundNextItem)
        XCTAssertEqual(events.count, 1, "Portrait ignores landscape controller navigation")
        setViewport(CGSize(width: 844, height: 390), traits: landscapeTraits)
        press(.boundShowBosses)
        press(.boundNextItem)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(BoundControllerNavigationEvent.command(from: try XCTUnwrap(events.last), gameID: game.identifier, content: .bosses), .nextItem)
        try await Task.sleep(nanoseconds: 150_000_000)
        press(.boundSelect)
        for _ in 0..<30 where core.state != .paused { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(core.state, .paused, "The existing companion presentation flow pauses gameplay")
        // Let the actual UIKit presentation finish before sending Back from the pad.
        try await Task.sleep(nanoseconds: 500_000_000)
        press(.boundBack)
        for _ in 0..<30 where core.state != .running { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(core.state, .running, "Controller Back must remain available while a reference sheet pauses the core")
        let countBeforeHiding = events.count
        XCTAssertEqual(countBeforeHiding, 4)
        press(.boundHideMultiview)
        press(.boundNextItem)
        XCTAssertEqual(events.count, countBeforeHiding, "Hidden reference views cannot be navigated")

        // Hiding or switching an open selector must finish its dismissal before
        // removing the reference, so the existing pause is returned to gameplay.
        for action in [ActionInput.boundHideMultiview, .toggleBoundMultiview, .boundShowDex] {
            press(.boundShowBosses)
            try await Task.sleep(nanoseconds: 150_000_000)
            press(.boundSelect)
            for _ in 0..<30 where core.state != .paused { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertEqual(core.state, .paused)
            try await Task.sleep(nanoseconds: 500_000_000)
            press(action)
            if action == .boundHideMultiview {
                try await Task.sleep(nanoseconds: 50_000_000)
                NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
                try await Task.sleep(nanoseconds: 50_000_000)
                NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            }
            for _ in 0..<30 where core.state != .running { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertEqual(core.state, .running, "\(action) must dismiss the selector and resume gameplay")
            try await Task.sleep(nanoseconds: 150_000_000)
            let countAfterTransition = events.count
            press(.boundNextItem)
            if action == .boundShowDex {
                XCTAssertEqual(events.count, countAfterTransition + 1)
                XCTAssertEqual(BoundControllerNavigationEvent.command(from: try XCTUnwrap(events.last), gameID: game.identifier, content: .dex), .nextItem)
            } else {
                XCTAssertEqual(events.count, countAfterTransition, "The completed action must hide the multiview")
            }
        }

        var stickMapping = DeltaCore.GameControllerInputMapping(gameControllerInputType: external.inputType)
        stickMapping.set(ActionInput.boundScrollDown, forControllerInput: MFiGameController.Input.leftThumbstickDown)
        stickMapping.set(ActionInput.boundScrollDown, forControllerInput: MFiGameController.Input.rightThumbstickDown)
        stickMapping.set(ActionInput.none, forControllerInput: MFiGameController.Input.a)
        external.addReceiver(gameController, inputMapping: BoundControllerInputMapping(base: stickMapping))
        let beforeStickInput = events.count
        external.activate(MFiGameController.Input.leftThumbstickDown, value: 0.9)
        external.deactivate(MFiGameController.Input.leftThumbstickDown)
        external.activate(MFiGameController.Input.a)
        external.deactivate(MFiGameController.Input.a)
        external.activate(MFiGameController.Input.rightThumbstickDown, value: 0.1)
        XCTAssertEqual(events.count, beforeStickInput, "Left stick, None bindings, and stick drift must not navigate companion views")
        external.activate(MFiGameController.Input.rightThumbstickDown, value: 0.9)
        external.deactivate(MFiGameController.Input.rightThumbstickDown)
        XCTAssertEqual(events.count, beforeStickInput + 1, "The right stick must still reach the active companion")

        var menuMapping = DeltaCore.GameControllerInputMapping(gameControllerInputType: external.inputType)
        menuMapping.set(StandardGameControllerInput.menu, forControllerInput: MFiGameController.Input.share)
        external.addReceiver(gameController, inputMapping: BoundControllerInputMapping(base: menuMapping))
        external.activate(MFiGameController.Input.share)
        external.deactivate(MFiGameController.Input.share)
        XCTAssertTrue(gameController.didRequestPauseMenu, "A button bound to Menu must request Bound's pause menu")
    }

    func testViewNavigationMappingsRoundTripAndRequireOptInInBothEditors() throws {
        let preferences = BoundControllerNavigationPreferences()
        let original = preferences.isEnabled
        defer { preferences.isEnabled = original }
        preferences.isEnabled = false
        for action in ActionInput.viewNavigationActions {
            XCTAssertFalse(ActionInput.configurableActions.contains(action))
            XCTAssertFalse(ControlsEditorView.actionInputs.contains(AnyInput(action)))
        }
        preferences.isEnabled = true
        let transformer = GameControllerInputMappingTransformer()
        for action in ActionInput.viewNavigationActions {
            var mapping = DeltaCore.GameControllerInputMapping(gameControllerInputType: .mfi)
            mapping.set(action, forControllerInput: MFiGameController.Input.x)
            let encoded = try XCTUnwrap(transformer.transformedValue(mapping) as? Data)
            let decoded = try XCTUnwrap(transformer.reverseTransformedValue(encoded) as? DeltaCore.GameControllerInputMapping)
            XCTAssertEqual(ActionInput(input: try XCTUnwrap(decoded.input(forControllerInput: MFiGameController.Input.x))), action)
            XCTAssertTrue(ActionInput.configurableActions.contains(action))
            XCTAssertTrue(ControlsEditorView.actionInputs.contains(AnyInput(action)))
            XCTAssertFalse(action.localizedDisplayName.isEmpty)
            XCTAssertNotEqual(action.sfSymbolName, "questionmark.circle")
        }
    }

    func testControllerModeLayoutPersistsAndLegacyEnabledPreferenceDefaultsToModeOne() throws {
        let name = "ControllerModeLayoutTests."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(true, forKey: BoundControllerModePreferences.key)
        let upgradedPreferences = BoundControllerModePreferences(defaults: defaults)
        XCTAssertTrue(upgradedPreferences.isEnabled)
        XCTAssertEqual(upgradedPreferences.layout, .mode1)

        upgradedPreferences.layout = .mode2
        XCTAssertEqual(BoundControllerModePreferences(defaults: defaults).layout, .mode2)
        upgradedPreferences.isEnabled = false
        XCTAssertEqual(BoundControllerModePreferences(defaults: defaults).layout, .mode2,
                       "Turning Controller Mode off should retain the selected layout.")
        upgradedPreferences.isEnabled = true
        XCTAssertEqual(BoundControllerModePreferences(defaults: defaults).layout, .mode2)
    }

    func testControllerModeTwoMatchesStandardGameSizeAndKeepsControlsAccessible() throws {
        let cases: [(CGRect, UIEdgeInsets, CGSize)] = [
            (CGRect(x: 0, y: 0, width: 852, height: 393), UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 34), CGSize(width: 240, height: 160)),
            (CGRect(x: 0, y: 0, width: 852, height: 393), UIEdgeInsets(top: 0, left: 34, bottom: 21, right: 59), CGSize(width: 240, height: 160)),
            (CGRect(x: 0, y: 0, width: 667, height: 375), .zero, CGSize(width: 240, height: 160)),
            (CGRect(x: 0, y: 0, width: 1194, height: 834), UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0), CGSize(width: 240, height: 160)),
            (CGRect(x: 0, y: 0, width: 852, height: 393), UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 34), CGSize(width: 8, height: 1))
        ]

        for (bounds, safeArea, gameAspect) in cases {
            let geometry = try XCTUnwrap(BoundControllerModeTwoGeometry(bounds: bounds, safeArea: safeArea, gameAspect: gameAspect))
            let safe = bounds.inset(by: safeArea)
            let standardBounds = CGRect(x: safe.minX, y: bounds.minY, width: safe.width, height: bounds.height)
            let standardGame = AVMakeRect(aspectRatio: gameAspect, insideRect: standardBounds)
            XCTAssertEqual(geometry.game.width, standardGame.width, accuracy: 0.001)
            XCTAssertEqual(geometry.game.height, standardGame.height, accuracy: 0.001,
                           "Mode 2 must preserve the game size from Modes 1 and 3, even without a left gutter.")
            XCTAssertEqual(geometry.game.midY, standardGame.midY, accuracy: 0.001)
            XCTAssertEqual(geometry.game.maxX, safe.maxX, accuracy: 0.5)
            XCTAssertEqual(geometry.game.width / geometry.game.height, gameAspect.width / gameAspect.height, accuracy: 0.01)
            XCTAssertEqual(geometry.friend.width / geometry.friend.height, 1.5, accuracy: 0.01)
            XCTAssertEqual(geometry.menu.size, CGSize(width: 44, height: 44))
            XCTAssertEqual(geometry.views.size, CGSize(width: 44, height: 44))
            XCTAssertEqual(geometry.friendButton.size, CGSize(width: 44, height: 44))
            XCTAssertTrue(safe.contains(geometry.friend))
            XCTAssertTrue(safe.contains(geometry.menu))
            XCTAssertTrue(safe.contains(geometry.views))
            XCTAssertTrue(safe.contains(geometry.friendButton))
            XCTAssertGreaterThanOrEqual(geometry.game.minX, safe.minX - 0.5)
            XCTAssertLessThanOrEqual(geometry.game.maxX, safe.maxX + 0.5)
            XCTAssertGreaterThanOrEqual(geometry.game.minY, bounds.minY - 0.5)
            XCTAssertLessThanOrEqual(geometry.game.maxY, bounds.maxY + 0.5)
            if geometry.game.minX - safe.minX >= 112 {
                XCTAssertFalse(geometry.friend.intersects(geometry.game))
                XCTAssertFalse(geometry.menu.intersects(geometry.game))
                XCTAssertFalse(geometry.views.intersects(geometry.game))
                XCTAssertFalse(geometry.friendButton.intersects(geometry.game))
            }
            XCTAssertFalse(geometry.menu.intersects(geometry.views))
            XCTAssertFalse(geometry.friend.intersects(geometry.menu))
            XCTAssertFalse(geometry.views.intersects(geometry.friendButton))
            XCTAssertEqual(geometry.friend.minX, safe.minX, accuracy: 0.5)
            XCTAssertEqual(geometry.friend.minY, safe.minY, accuracy: 0.5)
            if bounds.width == 852, gameAspect == CGSize(width: 240, height: 160) {
                XCTAssertEqual(geometry.game.height, bounds.height, accuracy: 0.5,
                               "When the left strip fits, keep the current full-height gameplay presentation.")
            }
        }
    }

    func testControllerModeTwoGeometryRejectsPortraitAndInvalidInputs() {
        XCTAssertNil(BoundControllerModeTwoGeometry(bounds: CGRect(x: 0, y: 0, width: 390, height: 844), safeArea: .zero, gameAspect: CGSize(width: 3, height: 2)))
        XCTAssertNil(BoundControllerModeTwoGeometry(bounds: CGRect(x: 0, y: 0, width: 844, height: 390), safeArea: .zero, gameAspect: .zero))
        XCTAssertNil(BoundControllerModeTwoGeometry(bounds: .zero, safeArea: .zero, gameAspect: CGSize(width: 3, height: 2)))
    }

    func testControllerModeThreeMenuUsesBottomLeftSafeEdgeAndNativeHitTarget() throws {
        let cases: [(CGRect, UIEdgeInsets)] = [
            (CGRect(x: 0, y: 0, width: 852, height: 393), UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 34)),
            (CGRect(x: 0, y: 0, width: 852, height: 393), UIEdgeInsets(top: 0, left: 34, bottom: 21, right: 59)),
            (CGRect(x: 0, y: 0, width: 1194, height: 834), UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
            (CGRect(x: 12, y: 8, width: 667, height: 375), .zero)
        ]
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .landscape)
        for (bounds, insets) in cases {
            let geometry = try XCTUnwrap(BoundControllerModeThreeGeometry(bounds: bounds, safeArea: insets))
            let safe = bounds.inset(by: insets)
            XCTAssertEqual(geometry.menu.minX, safe.minX)
            XCTAssertEqual(geometry.menu.maxY, safe.maxY)
            XCTAssertEqual(geometry.menu.size, CGSize(width: 44, height: 44))
            XCTAssertTrue(safe.contains(geometry.menu))
            let normalized = geometry.menu.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                .applying(.init(scaleX: 1 / bounds.width, y: 1 / bounds.height))
            let skin = BoundControllerModeSkin(base: base, menuFrame: normalized)
            let items = try XCTUnwrap(skin.items(for: traits))
            XCTAssertEqual(items.count, 1)
            let menu = try XCTUnwrap(items.first)
            XCTAssertTrue(menu.inputs.allInputs.contains { $0.stringValue == "menu" })
            XCTAssertEqual(menu.frame, normalized)
            XCTAssertEqual(menu.extendedFrame, normalized)
        }
        XCTAssertNil(BoundControllerModeThreeGeometry(bounds: CGRect(x: 0, y: 0, width: 393, height: 852), safeArea: .zero))
        XCTAssertNil(BoundControllerModeThreeGeometry(bounds: .zero, safeArea: .zero))
    }

    func testControllerModeTwoMovesOnlyNativeMenuAndUsesNormalizedFortyFourPointFrame() throws {
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .landscape)
        let size = CGSize(width: 844, height: 390)
        let stock = BoundStockControllerSkin(base: base, canvasSize: size,
            boundLandscapeGutter: CGRect(x: 738.5, y: 0, width: 105.5, height: 369))
        let originalItems = try XCTUnwrap(stock.items(for: traits))
        let originalMenu = try XCTUnwrap(originalItems.first { $0.inputs.allInputs.contains { $0.stringValue == "menu" } })
        let customFrame = CGRect(x: 0.08, y: 0.78, width: 44 / size.width, height: 44 / size.height)
        let mode1 = BoundControllerModeSkin(base: stock)
        let mode2 = BoundControllerModeSkin(base: stock, menuFrame: customFrame)
        let mode1Items = try XCTUnwrap(mode1.items(for: traits))
        let mode2Items = try XCTUnwrap(mode2.items(for: traits))
        let mode1Menu = try XCTUnwrap(mode1Items.first)
        let mode2Menu = try XCTUnwrap(mode2Items.first)

        XCTAssertEqual(mode1Items.map(\.id), [originalMenu.id])
        XCTAssertEqual(mode1Menu.frame, originalMenu.frame)
        XCTAssertEqual(mode2Items.map(\.id), [originalMenu.id])
        XCTAssertEqual(mode2Menu.frame, customFrame)
        XCTAssertEqual(mode2Menu.frame.width * size.width, 44, accuracy: 0.01)
        XCTAssertEqual(mode2Menu.frame.height * size.height, 44, accuracy: 0.01)
        XCTAssertEqual(mode2Menu.inputs.allInputs.map(\.stringValue), originalMenu.inputs.allInputs.map(\.stringValue))
        XCTAssertEqual(mode2Menu.extendedFrame, customFrame)
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
        preferences.buttonType = .option1
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
private final class BoundControllerMenuProbe: GameViewController {
    var didRequestPauseMenu = false

    override func performSegue(withIdentifier identifier: String, sender: Any?) {
        if identifier == "pause" { didRequestPauseMenu = true }
        else { super.performSegue(withIdentifier: identifier, sender: sender) }
    }
}

@MainActor
private final class BoundVirtualMappingReceiver: GameControllerReceiver {
    let router = BoundPanelActionRouter()
    let coordinator: BoundCompanionCoordinator
    var eligible = true
    var menuActivations = 0
    var gameBActivations = 0
    var friendToggleActivations = 0
    var multiviewToggleActivations = 0
    init(coordinator: BoundCompanionCoordinator) { self.coordinator = coordinator }
    func gameController(_ gameController: GameController, didActivate input: Input, value: Double) {
        if let action = ActionInput(input: input) {
            router.activate(controller: gameController, action: action, eligible: eligible) {
                switch action {
                case .cycleBoundPanels: coordinator.cyclePanels()
                case .toggleBoundFriend: friendToggleActivations += 1
                case .toggleBoundMultiview: multiviewToggleActivations += 1
                default: break
                }
            }
        } else if StandardGameControllerInput(input: input) == .menu { menuActivations += 1 }
        else if StandardGameControllerInput(input: input) == .b { gameBActivations += 1 }
    }
    func gameController(_ gameController: GameController, didDeactivate input: Input) {
        if let action = ActionInput(input: input) { router.release(controller: gameController, action: action) }
    }
}
