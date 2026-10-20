import XCTest
import CoreGraphics
@testable import Delta

private struct LegacyControllerButtonPlacementPayload: Encodable {
    let friend: CGPoint
}

@MainActor
final class ControllerButtonPlacementTests: XCTestCase {
    private func makeModel() throws -> (BoundLandscapeArrangementModel, UserDefaults, String) {
        let namespace = "ControllerButtonPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        return (BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace), defaults, namespace)
    }

    private func arrangeLayout(_ model: BoundLandscapeArrangementModel) {
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let menu = CGRect(x: 900, y: 20, width: 44, height: 44)
        let bound = CGRect(x: 900, y: 500, width: 44, height: 44)
        let defaults: [BoundPiPContent: CGRect] = [
            .friend: CGRect(x: 650, y: 80, width: 240, height: 160),
            .bosses: CGRect(x: 390, y: 130, width: 260, height: 360),
            .dex: CGRect(x: 380, y: 115, width: 300, height: 360),
            .types: CGRect(x: 390, y: 130, width: 260, height: 360),
            .notes: CGRect(x: 390, y: 130, width: 260, height: 360)
        ]
        model.updateLayout(canvas: canvas, occupied: [menu, bound], menuFrame: menu,
                           boundFrame: bound, defaults: defaults, keyboardHeight: 0)
    }

    func testDistanceSnappingOffKeepsFreeMovementWithoutAlignmentSnap() {
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 240)
        let start = CGRect(x: 0, y: 0, width: 44, height: 44)
        var drag = BoundControllerButtonDrag(startFrame: start, gridCenter: CGPoint(x: canvas.midX, y: canvas.midY))
        let result = drag.update(translation: CGSize(width: 136, height: 96), canvas: canvas)
        XCTAssertEqual(result.frame.midX, 158, accuracy: 0.001)
        XCTAssertEqual(result.frame.midY, 118, accuracy: 0.001)
        XCTAssertNil(result.snappedX)
        XCTAssertNil(result.snappedY)
        XCTAssertFalse(result.didSnap)
    }

    func testDistanceGridIsCenteredAndSymmetricOnBothAxes() {
        let spacing: CGFloat = 18
        XCTAssertEqual(BoundControllerButtonGrid.quantize(100, centeredAt: 160, spacing: spacing,
                                                           minimum: 22, maximum: 298), 106)
        XCTAssertEqual(BoundControllerButtonGrid.quantize(220, centeredAt: 160, spacing: spacing,
                                                           minimum: 22, maximum: 298), 214)
        XCTAssertEqual(160 - 106, 214 - 160, accuracy: 0.001)
        XCTAssertEqual(BoundControllerButtonGrid.quantize(40, centeredAt: 120, spacing: spacing,
                                                           minimum: 22, maximum: 218), 48)
    }

    func testDistanceGridKeepsButtonCentersOnLatticeAtScreenEdges() {
        let canvas = CGRect(x: 0, y: 18, width: 320, height: 222) // Safe canvas is offset from screen center.
        let screenCenter = CGPoint(x: 160, y: 120)
        let start = CGRect(x: 0, y: 0, width: 44, height: 44)
        var drag = BoundControllerButtonDrag(startFrame: start,
                                             distanceSnapping: true, spacing: 18,
                                             gridCenter: screenCenter)
        let result = drag.update(translation: CGSize(width: -300, height: -300), canvas: canvas)
        XCTAssertEqual(result.frame.midX, 34, accuracy: 0.001)
        XCTAssertEqual(result.frame.midY, 48, accuracy: 0.001)
        XCTAssertEqual(((result.frame.midX - 160) / 18).rounded(), (result.frame.midX - 160) / 18, accuracy: 0.001)
        XCTAssertEqual(((result.frame.midY - 120) / 18).rounded(), (result.frame.midY - 120) / 18, accuracy: 0.001)
    }

    func testGridHapticOnlyFiresWhenMovingBetweenCellsAndOnRecrossing() {
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 240)
        var drag = BoundControllerButtonDrag(startFrame: CGRect(x: 0, y: 0, width: 44, height: 44),
                                             distanceSnapping: true, spacing: 18,
                                             gridCenter: CGPoint(x: 160, y: 120))
        XCTAssertTrue(drag.update(translation: CGSize(width: 1, height: 0), canvas: canvas).didSnap)
        XCTAssertFalse(drag.update(translation: CGSize(width: 3, height: 0), canvas: canvas).didSnap)
        XCTAssertTrue(drag.update(translation: CGSize(width: 22, height: 0), canvas: canvas).didSnap)
        XCTAssertTrue(drag.update(translation: CGSize(width: 3, height: 0), canvas: canvas).didSnap)
    }

    func testGridSpacingPreferenceClampsAndUsesFiniteDefault() {
        XCTAssertEqual(BoundControllerButtonGridPreferences.normalized(.nan), 18)
        XCTAssertEqual(BoundControllerButtonGridPreferences.normalized(.infinity), 18)
        XCTAssertEqual(BoundControllerButtonGridPreferences.normalized(1), 6)
        XCTAssertEqual(BoundControllerButtonGridPreferences.normalized(100), 48)
    }

    func testPlacementPersistsNormalizedPositionsAndClampsFramesToCanvas() throws {
        let canvas = CGRect(x: 10, y: 20, width: 300, height: 200)
        var placement = BoundControllerButtonPlacement()
        placement.set(frame: CGRect(x: -50, y: 300, width: 44, height: 44), for: .friend, canvas: canvas)

        let encoded = try JSONEncoder().encode(placement)
        let decoded = try JSONDecoder().decode(BoundControllerButtonPlacement.self, from: encoded)
        let frame = decoded.frame(for: .friend, defaultFrame: CGRect(x: 30, y: 40, width: 44, height: 44), canvas: canvas)

        XCTAssertEqual(frame.minX, canvas.minX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, canvas.maxY, accuracy: 0.001)
        XCTAssertEqual(decoded.positions[.friend]?.x, 0)
        XCTAssertEqual(decoded.positions[.friend]?.y, 1)
    }

    func testInvalidStoredPositionsAreIgnoredAndOutOfRangeValuesAreNormalized() throws {
        let valid = BoundControllerButtonPlacement(positions: [
            .friend: CGPoint(x: 0.1, y: 0.5),
            .multiview: CGPoint(x: 0.2, y: 0.25),
            .menu: CGPoint(x: 0.5, y: 0.75)
        ])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        func replacingX(_ position: Any?, with value: Any) -> Any? {
            if var coordinates = position as? [String: Any] {
                coordinates["x"] = value
                return coordinates
            }
            if let coordinates = position as? [Any], coordinates.count == 2 {
                return [value, coordinates[1]]
            }
            return position
        }
        object["friend"] = replacingX(object["friend"], with: "invalid")
        object["multiview"] = replacingX(object["multiview"], with: 2)
        let data = try JSONSerialization.data(withJSONObject: object)
        let placement = try JSONDecoder().decode(BoundControllerButtonPlacement.self, from: data)

        XCTAssertNil(placement.positions[.friend])
        XCTAssertEqual(placement.positions[.multiview], CGPoint(x: 1, y: 0.25))
        XCTAssertEqual(placement.positions[.menu], CGPoint(x: 0.5, y: 0.75))

        let canvas = CGRect(x: 0, y: 0, width: 300, height: 200)
        let fallback = CGRect(x: 80, y: 70, width: 44, height: 44)
        XCTAssertEqual(placement.frame(for: .friend, defaultFrame: fallback, canvas: canvas), fallback)
    }

    func testVisibilityDefaultsToMenuAndMenuCannotBeRemoved() throws {
        var placement = BoundControllerButtonPlacement(positions: [.friend: CGPoint(x: 0.2, y: 0.3)])
        XCTAssertTrue(placement.isVisible(.menu))
        XCTAssertFalse(placement.isVisible(.friend))
        XCTAssertFalse(placement.isVisible(.multiview))

        placement.setVisible(true, for: .friend)
        placement.setVisible(false, for: .menu)
        XCTAssertTrue(placement.isVisible(.friend))
        XCTAssertTrue(placement.isVisible(.menu))

        let encoded = try JSONEncoder().encode(placement)
        let decoded = try JSONDecoder().decode(BoundControllerButtonPlacement.self, from: encoded)
        XCTAssertTrue(decoded.isVisible(.friend))
        XCTAssertTrue(decoded.isVisible(.menu))
        XCTAssertFalse(decoded.isVisible(.multiview))
    }

    func testLegacyPositionOnlyPayloadDefaultsToMenuVisible() throws {
        let legacy = try JSONEncoder().encode(LegacyControllerButtonPlacementPayload(
            friend: CGPoint(x: 0.25, y: 0.5)))
        let placement = try JSONDecoder().decode(BoundControllerButtonPlacement.self, from: legacy)
        XCTAssertTrue(placement.isVisible(.menu))
        XCTAssertFalse(placement.isVisible(.friend))
        XCTAssertEqual(placement.positions[.friend], CGPoint(x: 0.25, y: 0.5))
    }

    func testGamePlacementClampsAndKeepsFullSizeAndCenterDefaults() throws {
        let canvas = CGRect(x: 10, y: 20, width: 1000, height: 600)
        let base = CGRect(x: 110, y: 70, width: 800, height: 500)
        let full = BoundControllerGamePlacement().frame(baseFrame: base, canvas: canvas)
        XCTAssertEqual(full, base)

        let left = BoundControllerGamePlacement(scale: 0.5, horizontalPosition: 0)
            .frame(baseFrame: base, canvas: canvas)
        let right = BoundControllerGamePlacement(scale: 0.5, horizontalPosition: 1)
            .frame(baseFrame: base, canvas: canvas)
        XCTAssertEqual(left.minX, canvas.minX, accuracy: 0.001)
        XCTAssertEqual(right.maxX, canvas.maxX, accuracy: 0.001)
        XCTAssertEqual(left.width / right.width, 1, accuracy: 0.001)
        XCTAssertEqual(left.height / right.height, 1, accuracy: 0.001)

        let roundTrip = try JSONDecoder().decode(BoundControllerGamePlacement.self,
                                                from: JSONEncoder().encode(BoundControllerGamePlacement(scale: 3, horizontalPosition: -1)))
        XCTAssertEqual(roundTrip.scale, 1)
        XCTAssertEqual(roundTrip.horizontalPosition, 0)
        let small = BoundControllerGamePlacement(scale: 0.1, horizontalPosition: 0.5)
        XCTAssertEqual(small.scale, 0.45)
    }

    func testUnifiedPlacementSavesReloadsCancelsAndResets() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setDistanceSnappingEnabled(false)
        let key = namespace + ".controller-unified.buttons.v1"
        model.useOption(.option7, controllerModeEnabled: true, controllerModeLayout: .mode1)
        model.setActive(true)
        arrangeLayout(model)
        XCTAssertTrue(model.movableControllerButtons)
        model.configuredGameFrame(baseFrame: CGRect(x: 100, y: 100, width: 800, height: 450),
                                  canvas: CGRect(x: 0, y: 0, width: 1000, height: 600))

        var alignmentHaptics = 0
        model.buttonDidAlign = { alignmentHaptics += 1 }
        XCTAssertFalse(model.isButtonVisible(.friend))
        model.arrange()
        model.moveGameScreen(translation: CGSize(width: 50, height: 0), ended: true)
        XCTAssertEqual(model.gameCentered, false)
        model.resizeGameScreen(translation: CGSize(width: -400, height: -225), ended: true)
        XCTAssertLessThan(model.gameFrame.width, 800)
        let gameFrameBeforeSave = model.gameFrame
        model.advanceArrangement()
        XCTAssertEqual(model.editingPhase, .viewsAndButtons)
        model.removeControllerButton(.menu)
        XCTAssertTrue(model.isButtonVisible(.menu), "Menu must remain visible and cannot be trashed.")
        model.restoreControllerButton(.friend)
        XCTAssertTrue(model.isButtonVisible(.friend))
        alignmentHaptics = 0
        let menuFrame = model.buttonFrame(.menu)
        let friendStart = model.buttonFrame(.friend)
        let alignTranslation = CGSize(width: menuFrame.midX - friendStart.midX,
                                      height: menuFrame.midY - friendStart.midY)
        model.moveControllerButton(.friend, translation: alignTranslation, ended: false)
        model.moveControllerButton(.friend, translation: CGSize(width: alignTranslation.width + 2,
                                                                 height: alignTranslation.height), ended: false)
        XCTAssertEqual(alignmentHaptics, 0, "Free movement must not soft-snap to nearby controls.")
        model.moveControllerButton(.friend, translation: alignTranslation, ended: true)
        model.advanceArrangement()
        XCTAssertNotNil(defaults.data(forKey: key))
        XCTAssertNotNil(defaults.data(forKey: namespace + ".controller-unified.game-screen.v1"))
        let savedFrame = model.buttonFrame(.friend)
        XCTAssertEqual(savedFrame.midX, menuFrame.midX, accuracy: 0.001)
        XCTAssertEqual(savedFrame.midY, menuFrame.midY, accuracy: 0.001)

        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option7, controllerModeEnabled: true, controllerModeLayout: .mode1)
        restored.setActive(true)
        arrangeLayout(restored)
        XCTAssertEqual(restored.buttonFrame(.friend), savedFrame)
        XCTAssertTrue(restored.isButtonVisible(.friend), "Restored button visibility must persist.")
        restored.configuredGameFrame(baseFrame: CGRect(x: 100, y: 100, width: 800, height: 450),
                                     canvas: CGRect(x: 0, y: 0, width: 1000, height: 600))
        XCTAssertEqual(restored.gameFrame, gameFrameBeforeSave)

        restored.arrange()
        restored.configuredGameFrame(baseFrame: CGRect(x: 100, y: 100, width: 800, height: 450),
                                     canvas: CGRect(x: 0, y: 0, width: 1000, height: 600))
        restored.moveGameScreen(translation: CGSize(width: -100, height: 0), ended: true)
        restored.advanceArrangement()
        restored.moveControllerButton(.friend, translation: CGSize(width: 100, height: 70), ended: true)
        restored.finish(save: false)
        arrangeLayout(restored)
        XCTAssertEqual(restored.buttonFrame(.friend), savedFrame, "Cancel must discard draft button positions.")
        XCTAssertEqual(restored.gameFrame, gameFrameBeforeSave, "Cancel must discard game placement changes.")

        defaults.removeObject(forKey: key)
        restored.reload(option: .option7, controllerModeEnabled: true, controllerModeLayout: .mode1)
        restored.setActive(true)
        arrangeLayout(restored)
        XCTAssertEqual(restored.buttonFrame(.friend), friendStart,
                       "Reload after clearing the placement key must restore the default position.")
        XCTAssertFalse(restored.isButtonVisible(.friend))
        XCTAssertTrue(restored.isButtonVisible(.menu))
    }

    func testControllerButtonPlacementsStaySeparateAndNeverApplyInPortrait() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        let moved = BoundControllerButtonPlacement(positions: [.menu: CGPoint(x: 0.1, y: 0.9)],
                                                   visibleButtons: [.menu, .friend])
        let data = try JSONEncoder().encode(moved)
        defaults.set(data, forKey: namespace + ".controller-unified.buttons.v1")
        let original = CGRect(x: 900, y: 20, width: 44, height: 44)
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)
        model.useOption(.option7, controllerModeEnabled: false)
        model.setActive(true)
        arrangeLayout(model)
        XCTAssertTrue(model.movableControllerButtons)
        XCTAssertEqual(Set(model.visibleControllerButtons), Set(BoundControllerButton.allCases))
        XCTAssertFalse(model.hasButtonPlacement(.menu), "Controller Mode On positions must not leak into Off.")
        XCTAssertEqual(model.controllerButtonFrame(.menu, defaultFrame: original, canvas: canvas), original)
        model.useOption(.option7, controllerModeEnabled: true)
        model.setActive(false) // Portrait must not apply saved landscape button geometry.
        XCTAssertFalse(model.movableControllerButtons)
        XCTAssertEqual(model.controllerButtonFrame(.menu, defaultFrame: original, canvas: canvas), original)
        model.setActive(true)
        arrangeLayout(model)
        XCTAssertTrue(model.movableControllerButtons)
        XCTAssertTrue(model.isButtonVisible(.friend))
        XCTAssertNotEqual(model.controllerButtonFrame(.menu, defaultFrame: original, canvas: canvas), original)
    }

    func testArrangementGridTogglePersistsWithoutMovingButtonsUntilDragged() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setDistanceSnappingEnabled(false)
        model.useOption(.option7, controllerModeEnabled: true)
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.advanceArrangement()
        model.restoreControllerButton(.friend)
        model.restoreControllerButton(.multiview)
        let before = model.buttonFrame(.friend)

        model.setDistanceSnappingEnabled(true)
        XCTAssertTrue(model.distanceSnappingEnabled)
        XCTAssertTrue(defaults.bool(forKey: BoundControllerButtonGridPreferences.enabledKey))
        XCTAssertEqual(model.buttonFrame(.friend), before,
                       "Enabling the grid must not silently reposition saved buttons.")

        let target = CGPoint(x: 700, y: 300)
        let translation = CGSize(width: target.x - before.midX, height: target.y - before.midY)
        model.moveControllerButton(.friend, translation: translation, ended: true)
        let moved = model.buttonFrame(.friend)
        XCTAssertEqual((moved.midX - 500).truncatingRemainder(dividingBy: 18), 0, accuracy: 0.001)
        XCTAssertEqual((moved.midY - 300).truncatingRemainder(dividingBy: 18), 0, accuracy: 0.001)

        model.setDistanceSnappingEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: BoundControllerButtonGridPreferences.enabledKey))
    }

    func testLandscapeButtonsUseDefaultGridInBothModesAndSaveIndependently() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        var modeFrames: [Bool: [BoundControllerButton: CGRect]] = [:]
        for enabled in [false, true] {
            model.useOption(.option7, controllerModeEnabled: enabled)
            model.setActive(true)
            arrangeLayout(model)
            model.arrange()
            model.advanceArrangement()
            XCTAssertTrue(model.distanceSnappingEnabled)
            XCTAssertEqual(model.buttonGridSpacing, 18)
            for (index, button) in BoundControllerButton.allCases.enumerated() {
                model.restoreControllerButton(button)
                let before = model.buttonFrame(button)
                let target = CGPoint(x: 250 + CGFloat(index) * 150, y: enabled ? 160 : 250)
                model.moveControllerButton(button, translation: CGSize(width: target.x - before.midX,
                    height: target.y - before.midY), ended: true)
                let frame = model.buttonFrame(button)
                for offset in [frame.midX - 500, frame.midY - 300] {
                    XCTAssertEqual(offset / 18, (offset / 18).rounded(), accuracy: 0.001)
                }
            }
            modeFrames[enabled] = Dictionary(uniqueKeysWithValues: BoundControllerButton.allCases.map { ($0, model.buttonFrame($0)) })
            model.finish(save: true)
        }
        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        for enabled in [false, true] {
            restored.useOption(.option7, controllerModeEnabled: enabled)
            restored.setActive(true)
            arrangeLayout(restored)
            for button in BoundControllerButton.allCases {
                XCTAssertEqual(restored.buttonFrame(button), modeFrames[enabled]?[button])
            }
        }
        restored.useOption(.option7, controllerModeEnabled: false)
        arrangeLayout(restored)
        restored.arrange()
        restored.advanceArrangement()
        restored.removeControllerButton(.friend)
        restored.removeControllerButton(.menu)
        XCTAssertFalse(restored.isButtonVisible(.friend))
        XCTAssertTrue(restored.isButtonVisible(.menu))
        restored.finish(save: true)
        restored.reload(option: .option7, controllerModeEnabled: false)
        XCTAssertFalse(restored.isButtonVisible(.friend))
        restored.useOption(.option7, controllerModeEnabled: true)
        XCTAssertTrue(restored.isButtonVisible(.friend))
        restored.setActive(false)
        XCTAssertFalse(restored.movableControllerButtons)
        XCTAssertFalse(restored.hasButtonPlacement(.menu))
    }

    func testTrashRemovalPreservesButtonPlacementAndCannotRemoveMenu() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.useOption(.option7, controllerModeEnabled: true)
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.advanceArrangement()
        model.restoreControllerButton(.friend)
        let original = model.buttonFrame(.friend)
        let trash = model.buttonTrashFrame

        model.moveControllerButton(.friend,
            translation: CGSize(width: trash.midX - original.midX, height: trash.midY - original.midY), ended: true)
        XCTAssertFalse(model.isButtonVisible(.friend))
        XCTAssertEqual(model.buttonFrame(.friend), original, "Removing a button preserves its last screen position.")

        model.removeControllerButton(.menu)
        XCTAssertTrue(model.isButtonVisible(.menu), "Menu cannot be removed.")
        model.advanceArrangement()

        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option7, controllerModeEnabled: true)
        restored.setActive(true)
        arrangeLayout(restored)
        XCTAssertFalse(restored.isButtonVisible(.friend))
        XCTAssertTrue(restored.isButtonVisible(.menu))
        XCTAssertEqual(restored.buttonFrame(.friend), original)
    }
}
