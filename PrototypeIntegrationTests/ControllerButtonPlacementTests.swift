import XCTest
import CoreGraphics
@testable import Delta

@MainActor
final class ControllerButtonPlacementTests: XCTestCase {
    private func makeModel() throws -> (BoundLandscapeArrangementModel, UserDefaults, String) {
        let namespace = "ControllerButtonPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        return (BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace), defaults, namespace)
    }

    private func arrangeLayout(_ model: BoundLandscapeArrangementModel) {
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let menu = CGRect(x: 900, y: 20, width: 80, height: 70)
        let bound = CGRect(x: 900, y: 500, width: 80, height: 70)
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

    func testDragSnapsButtonCenterToOtherButtonsOnBothAxes() {
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 240)
        let start = CGRect(x: 0, y: 0, width: 44, height: 44)
        let target = CGRect(x: 138, y: 98, width: 44, height: 44)
        var drag = BoundControllerButtonDrag(startFrame: start, targets: [target])

        let result = drag.update(translation: CGSize(width: 136, height: 96), canvas: canvas)

        XCTAssertEqual(result.frame.midX, target.midX, accuracy: 0.001)
        XCTAssertEqual(result.frame.midY, target.midY, accuracy: 0.001)
        XCTAssertEqual(result.snappedX, target.midX)
        XCTAssertEqual(result.snappedY, target.midY)
        XCTAssertTrue(result.didSnap)
    }

    func testSoftSnapReleasesWithoutJumpAndDoesNotRetetherDuringGesture() {
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 240)
        let start = CGRect(x: 0, y: 0, width: 44, height: 44)
        let target = CGRect(x: 78, y: 178, width: 44, height: 44)
        var drag = BoundControllerButtonDrag(startFrame: start, targets: [target])

        let aligned = drag.update(translation: CGSize(width: 72, height: 0), canvas: canvas)
        XCTAssertEqual(aligned.frame.midX, target.midX, accuracy: 0.001)
        XCTAssertNil(aligned.snappedY)
        XCTAssertTrue(aligned.didSnap)

        let released = drag.update(translation: CGSize(width: 84, height: 0), canvas: canvas)
        XCTAssertNil(released.snappedX)
        XCTAssertEqual(released.frame.midX, target.midX, accuracy: 0.001,
                       "The snap should release at the current finger position without moving the button.")

        let movedAway = drag.update(translation: CGSize(width: 86, height: 0), canvas: canvas)
        XCTAssertEqual(movedAway.frame.midX, target.midX + 2, accuracy: 0.001)
        XCTAssertNil(movedAway.snappedX)

        let crossedAgain = drag.update(translation: CGSize(width: 150, height: 0), canvas: canvas)
        XCTAssertNil(crossedAgain.snappedX, "A released alignment must stay disengaged until the next drag.")
        XCTAssertGreaterThan(crossedAgain.frame.midX, target.midX + 50)
    }

    func testReleasingSnapSuppressesEveryButtonAtSameAlignmentCoordinate() {
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 240)
        let start = CGRect(x: 0, y: 0, width: 44, height: 44)
        let sharedAlignment = CGRect(x: 78, y: 178, width: 44, height: 44)
        var drag = BoundControllerButtonDrag(startFrame: start, targets: [sharedAlignment, sharedAlignment])

        let aligned = drag.update(translation: CGSize(width: 72, height: 0), canvas: canvas)
        XCTAssertEqual(aligned.snappedX, sharedAlignment.midX)
        let released = drag.update(translation: CGSize(width: 84, height: 0), canvas: canvas)
        XCTAssertNil(released.snappedX)
        XCTAssertEqual(released.frame.midX, sharedAlignment.midX, accuracy: 0.001)

        let continued = drag.update(translation: CGSize(width: 86, height: 0), canvas: canvas)
        XCTAssertNil(continued.snappedX, "An identical target from another button must not reattach the snap.")
        XCTAssertEqual(continued.frame.midX, sharedAlignment.midX + 2, accuracy: 0.001)
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

    func testModeOneButtonPlacementSavesReloadsCancelsAndResets() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        let key = namespace + ".controller-mode.buttons.v1"
        model.useOption(.option7, controllerModeEnabled: true, controllerModeLayout: .mode1)
        model.setActive(true)
        arrangeLayout(model)
        XCTAssertTrue(model.movableControllerButtons)

        var alignmentHaptics = 0
        model.buttonDidAlign = { alignmentHaptics += 1 }
        let menuFrame = model.buttonFrame(.menu)
        let friendStart = model.buttonFrame(.friend)
        model.arrange()
        let alignTranslation = CGSize(width: menuFrame.midX - friendStart.midX - 5,
                                      height: menuFrame.midY - friendStart.midY)
        model.moveControllerButton(.friend, translation: alignTranslation, ended: false)
        model.moveControllerButton(.friend, translation: CGSize(width: alignTranslation.width + 2,
                                                                 height: alignTranslation.height), ended: false)
        XCTAssertEqual(alignmentHaptics, 1, "Holding an acquired snap should emit one alignment haptic.")
        model.moveControllerButton(.friend, translation: alignTranslation, ended: true)
        model.finish(save: true)
        XCTAssertNotNil(defaults.data(forKey: key))
        let savedFrame = model.buttonFrame(.friend)
        XCTAssertEqual(savedFrame.midX, menuFrame.midX, accuracy: 0.001)
        XCTAssertEqual(savedFrame.midY, menuFrame.midY, accuracy: 0.001)

        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option7, controllerModeEnabled: true, controllerModeLayout: .mode1)
        restored.setActive(true)
        arrangeLayout(restored)
        XCTAssertEqual(restored.buttonFrame(.friend), savedFrame)

        restored.arrange()
        restored.moveControllerButton(.friend, translation: CGSize(width: 100, height: 70), ended: true)
        restored.finish(save: false)
        arrangeLayout(restored)
        XCTAssertEqual(restored.buttonFrame(.friend), savedFrame, "Cancel must discard draft button positions.")

        defaults.removeObject(forKey: key)
        restored.reload(option: .option7, controllerModeEnabled: true, controllerModeLayout: .mode1)
        restored.setActive(true)
        arrangeLayout(restored)
        XCTAssertEqual(restored.buttonFrame(.friend), friendStart,
                       "Reload after clearing the placement key must restore the default position.")
    }

    func testOffPortraitAndModeThreeIgnoreMovedButtons() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        let moved = BoundControllerButtonPlacement(positions: [.menu: CGPoint(x: 0.1, y: 0.9)])
        let data = try JSONEncoder().encode(moved)
        for suffix in ["controller-mode", "controller-mode2", "controller-mode3"] {
            defaults.set(data, forKey: namespace + "." + suffix + ".buttons.v1")
        }
        let original = CGRect(x: 900, y: 20, width: 44, height: 44)
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)
        for mode in BoundControllerModeLayout.allCases {
            model.useOption(.option7, controllerModeEnabled: false, controllerModeLayout: mode)
            model.setActive(true)
            arrangeLayout(model)
            XCTAssertFalse(model.movableControllerButtons)
            XCTAssertEqual(model.controllerButtonFrame(.menu, defaultFrame: original, canvas: canvas), original)
            model.useOption(.option7, controllerModeEnabled: true, controllerModeLayout: mode)
            model.setActive(false) // Portrait has no active landscape arrangement.
            XCTAssertFalse(model.movableControllerButtons)
            XCTAssertEqual(model.controllerButtonFrame(.menu, defaultFrame: original, canvas: canvas), original)
        }
        model.useOption(.option7, controllerModeEnabled: true, controllerModeLayout: .mode3)
        model.setActive(true)
        arrangeLayout(model)
        XCTAssertFalse(model.movableControllerButtons)
        XCTAssertEqual(model.controllerButtonFrame(.menu, defaultFrame: original, canvas: canvas), original)
        model.arrange()
        model.moveControllerButton(.menu, translation: CGSize(width: -200, height: 100), ended: true)
        model.finish(save: true)
        XCTAssertEqual(defaults.data(forKey: namespace + ".controller-mode3.buttons.v1"), data)
    }

    func testModesOneAndTwoKeepIndependentButtonPositions() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        var frames: [BoundControllerModeLayout: CGRect] = [:]
        for mode in [BoundControllerModeLayout.mode1, .mode2] {
            model.useOption(.option7, controllerModeEnabled: true, controllerModeLayout: mode)
            model.setActive(true)
            arrangeLayout(model)
            XCTAssertTrue(model.movableControllerButtons)
            let original = model.buttonFrame(.menu)
            model.arrange()
            model.moveControllerButton(.menu, translation: CGSize(width: mode == .mode1 ? -120 : -240, height: 90), ended: true)
            model.finish(save: true)
            arrangeLayout(model)
            frames[mode] = model.buttonFrame(.menu)
            XCTAssertNotEqual(frames[mode], original)
        }
        XCTAssertNotEqual(frames[.mode1], frames[.mode2])
        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.setActive(true)
        for mode in [BoundControllerModeLayout.mode1, .mode2] {
            restored.useOption(.option7, controllerModeEnabled: true, controllerModeLayout: mode)
            arrangeLayout(restored)
            XCTAssertEqual(restored.buttonFrame(.menu), frames[mode])
        }
    }
}
