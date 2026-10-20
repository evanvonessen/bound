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

    func testSoftSnapReleasesWithoutJumpAndCanRetetherAfterMovingAway() {
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

        let movedFarAway = drag.update(translation: CGSize(width: 100, height: 0), canvas: canvas)
        XCTAssertNil(movedFarAway.snappedX)
        let crossedAgain = drag.update(translation: CGSize(width: 78, height: 0), canvas: canvas)
        XCTAssertEqual(crossedAgain.snappedX, target.midX,
                       "After moving away, the same alignment should snap again during this drag.")
        XCTAssertTrue(crossedAgain.didSnap)
    }

    func testReleasedSharedAlignmentCanSnapAgainAfterMovingAway() {
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 240)
        let start = CGRect(x: 0, y: 0, width: 44, height: 44)
        let sharedAlignment = CGRect(x: 78, y: 178, width: 44, height: 44)
        var drag = BoundControllerButtonDrag(startFrame: start, targets: [sharedAlignment, sharedAlignment])

        let aligned = drag.update(translation: CGSize(width: 72, height: 0), canvas: canvas)
        XCTAssertEqual(aligned.snappedX, sharedAlignment.midX)
        let released = drag.update(translation: CGSize(width: 84, height: 0), canvas: canvas)
        XCTAssertNil(released.snappedX)
        XCTAssertEqual(released.frame.midX, sharedAlignment.midX, accuracy: 0.001)

        let movedAway = drag.update(translation: CGSize(width: 110, height: 0), canvas: canvas)
        XCTAssertNil(movedAway.snappedX, "The release target must not catch again at the segment's starting edge.")
        XCTAssertEqual(movedAway.frame.midX, sharedAlignment.midX + 26, accuracy: 0.001)
        let continued = drag.update(translation: CGSize(width: 78, height: 0), canvas: canvas)
        XCTAssertEqual(continued.snappedX, sharedAlignment.midX,
                       "A coordinate shared by peers must become eligible again after moving away.")
        XCTAssertTrue(continued.didSnap)
    }

    func testSnapCatchesFastGuideCrossingBetweenGestureSamples() {
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 240)
        let start = CGRect(x: 0, y: 0, width: 44, height: 44)
        let target = CGRect(x: 78, y: 178, width: 44, height: 44)
        var drag = BoundControllerButtonDrag(startFrame: start, targets: [target])

        _ = drag.update(translation: CGSize(width: 68, height: 0), canvas: canvas) // center 90
        let crossed = drag.update(translation: CGSize(width: 108, height: 0), canvas: canvas) // center 130
        XCTAssertEqual(crossed.snappedX, target.midX)
        XCTAssertEqual(crossed.frame.midX, target.midX, accuracy: 0.001)
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

    func testSnapTargetsIncludeCenterMirrorAndEqualSpacingCandidates() {
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 200)
        let first = CGRect(x: 50, y: 50, width: 40, height: 40) // center 70
        let second = CGRect(x: 150, y: 50, width: 40, height: 40) // center 170
        let start = CGRect(x: 300, y: 50, width: 40, height: 40)

        var centerDrag = BoundControllerButtonDrag(startFrame: start, targets: [first, second],
                                                   canvas: canvas, button: .menu,
                                                   otherButtons: [.friend: first, .multiview: second])
        let center = centerDrag.update(translation: CGSize(width: -120, height: 0), canvas: canvas)
        XCTAssertEqual(center.snappedX, canvas.midX)
        XCTAssertEqual(center.hint, "Centered")

        var mirrorDrag = BoundControllerButtonDrag(startFrame: start, targets: [first],
                                                   canvas: canvas, button: .menu,
                                                   otherButtons: [.friend: first])
        let mirror = mirrorDrag.update(translation: CGSize(width: 10, height: 0), canvas: canvas)
        XCTAssertEqual(mirror.snappedX, 330, "A peer at x=70 mirrors to x=330 across center x=200.")
        XCTAssertEqual(mirror.hint, "Mirrored")

        let verticalStart = CGRect(x: 300, y: 100, width: 40, height: 40) // center y=120
        var verticalMirrorDrag = BoundControllerButtonDrag(startFrame: verticalStart, targets: [first],
                                                           canvas: canvas, button: .menu,
                                                           otherButtons: [.friend: first])
        let verticalMirror = verticalMirrorDrag.update(translation: CGSize(width: 0, height: 10), canvas: canvas)
        XCTAssertEqual(verticalMirror.snappedY, 130, "A peer at y=70 mirrors to y=130 across center y=100.")
        XCTAssertEqual(verticalMirror.hint, "Mirrored")

        var spacingDrag = BoundControllerButtonDrag(startFrame: start, targets: [first, second],
                                                    canvas: canvas, button: .menu,
                                                    otherButtons: [.friend: first, .multiview: second])
        let spaced = spacingDrag.update(translation: CGSize(width: -50, height: 0), canvas: canvas)
        XCTAssertEqual(spaced.snappedX, 270,
                       "The x=270 target continues the 70, 170 spacing interval.")
        XCTAssertEqual(spaced.hint, "Even spacing")

        let verticalCanvas = CGRect(x: 0, y: 0, width: 400, height: 400)
        let upper = CGRect(x: 50, y: 50, width: 40, height: 40) // center y=70
        let lower = CGRect(x: 50, y: 150, width: 40, height: 40) // center y=170, same column
        let verticalSpacingStart = CGRect(x: 300, y: 280, width: 40, height: 40) // center y=300
        var verticalSpacingDrag = BoundControllerButtonDrag(startFrame: verticalSpacingStart,
            targets: [upper, lower], canvas: verticalCanvas, button: .menu,
            otherButtons: [.friend: upper, .multiview: lower])
        let verticalSpaced = verticalSpacingDrag.update(translation: CGSize(width: 0, height: -30), canvas: verticalCanvas)
        XCTAssertEqual(verticalSpaced.snappedY, 270)
        XCTAssertEqual(verticalSpaced.hint, "Even spacing")
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
        let alignTranslation = CGSize(width: menuFrame.midX - friendStart.midX - 5,
                                      height: menuFrame.midY - friendStart.midY)
        model.moveControllerButton(.friend, translation: alignTranslation, ended: false)
        model.moveControllerButton(.friend, translation: CGSize(width: alignTranslation.width + 2,
                                                                 height: alignTranslation.height), ended: false)
        XCTAssertEqual(alignmentHaptics, 1, "Holding an acquired snap should emit one alignment haptic.")
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

    func testUnifiedButtonPlacementOnlyAppliesWhenControllerModeAndLandscapeAreActive() throws {
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
        XCTAssertFalse(model.movableControllerButtons)
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

    func testButtonSpreadSupportsThreeWayRowsColumnsAndTwoButtonSymmetry() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.useOption(.option7, controllerModeEnabled: true)
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.advanceArrangement()
        model.restoreControllerButton(.friend)
        model.restoreControllerButton(.multiview)

        let canvas = model.layout.canvas
        model.spreadVertically = false
        model.setButtonSpread(0.5)
        var frames = model.visibleControllerButtons.map { model.buttonFrame($0) }.sorted { $0.midX < $1.midX }
        XCTAssertEqual(frames.count, 3)
        let firstGap = frames[1].midX - frames[0].midX
        let secondGap = frames[2].midX - frames[1].midX
        XCTAssertEqual(firstGap, secondGap, accuracy: 0.01)
        XCTAssertEqual(frames.map(\.midX).reduce(0, +) / 3, canvas.midX, accuracy: 0.01)
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $0.1.minX - $0.0.maxX >= -0.01 },
                      "Spread keeps the button frames at least non-overlapping.")

        model.spreadVertically = true
        model.setButtonSpread(0.4)
        frames = model.visibleControllerButtons.map { model.buttonFrame($0) }.sorted { $0.midY < $1.midY }
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[1].midY - frames[0].midY,
                       frames[2].midY - frames[1].midY, accuracy: 0.01)
        XCTAssertEqual(frames.map(\.midY).reduce(0, +) / 3, canvas.midY, accuracy: 0.01)

        model.spreadVertically = false
        model.removeControllerButton(.multiview)
        model.setButtonSpread(0.6)
        let pair = [model.buttonFrame(.friend), model.buttonFrame(.menu)]
        XCTAssertEqual(abs(pair[0].midX - canvas.midX), abs(pair[1].midX - canvas.midX), accuracy: 0.01,
                       "Two buttons remain mirrored around the canvas center.")
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
