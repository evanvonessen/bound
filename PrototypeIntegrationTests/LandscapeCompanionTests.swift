import XCTest
import UIKit
import SwiftUI
@testable import Delta

@MainActor
final class LandscapeCompanionTests: XCTestCase {
    private func makeModel() throws -> (BoundLandscapeCompanionModel, UserDefaults, String) {
        let suite = "BoundLandscapeCompanionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = BoundLandscapePreferences(defaults: defaults, namespace: suite)
        return (BoundLandscapeCompanionModel(preferences: preferences), defaults, suite)
    }

    func testConnectionsIsSelectableWithoutOverwritingSavedReferenceChoices() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(model.referenceContents.contains(.connections))
        model.preferences.referenceContents = [.bosses, .types]
        model.preferences.referenceContent = .types
        model.reload()
        XCTAssertEqual(model.referenceContents, [.bosses, .types])
        XCTAssertEqual(model.referenceContent, .types)
        model.preferences.referenceContents = [.bosses, .types, .connections]
        model.reload()
        model.setHistoryAvailable(true)
        model.selectReference(.connections)
        let restored = BoundLandscapeCompanionModel(preferences: BoundLandscapePreferences(defaults: defaults, namespace: suite))
        restored.setHistoryAvailable(true)
        XCTAssertEqual(restored.referenceContents, [.bosses, .types, .connections])
        XCTAssertEqual(restored.referenceContent, .connections)
    }

    func testLockedFriendOverlayYieldsTouchToUnderlyingControllerButton() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.setActive(true)
        let canvas = CGRect(x: 0, y: 0, width: 900, height: 500)
        model.updateLayout(canvas: canvas, occupied: [], leftShoulder: nil, keyboardHeight: 0)
        let friendRect = model.layout.friend
        let targetRect = CGRect(x: friendRect.midX - 20, y: friendRect.midY - 20, width: 40, height: 40)

        let container = UIView(frame: canvas)
        let controllerButton = UIButton(type: .custom)
        controllerButton.frame = targetRect
        container.addSubview(controllerButton)
        let overlay = BoundOverlayView(frame: canvas)
        overlay.yieldsTouch = { !model.receivesTouch(at: $0) }
        let lockedFriendSurface = UIView(frame: friendRect)
        overlay.addSubview(lockedFriendSurface)
        container.addSubview(overlay)

        XCTAssertFalse(model.editing)
        XCTAssertFalse(model.receivesTouch(at: CGPoint(x: targetRect.midX, y: targetRect.midY)),
                       "The locked friend surface must not claim a controller touch.")
        XCTAssertTrue(model.receivesTouch(at: CGPoint(x: model.layout.friendButton.midX, y: model.layout.friendButton.midY)))
        XCTAssertTrue(model.receivesTouch(at: CGPoint(x: model.layout.viewsButton.midX, y: model.layout.viewsButton.midY)))
        XCTAssertTrue(try XCTUnwrap(container.hitTest(CGPoint(x: targetRect.midX, y: targetRect.midY), with: nil)) === controllerButton,
                      "UIKit must continue hit testing the controller after the full-screen overlay yields.")
    }

    func testInteractiveReferenceAndButtonsAreCapturedButStayClearOfControls() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.setActive(true)
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let controls = [CGRect(x: 70, y: 80, width: 90, height: 90),
                        CGRect(x: 850, y: 400, width: 120, height: 120)]
        model.updateLayout(canvas: canvas, occupied: controls, leftShoulder: CGRect(x: 80, y: 30, width: 40, height: 40), keyboardHeight: 0)
        model.cycleViews()
        model.reload()

        XCTAssertTrue(model.referenceVisible)
        XCTAssertFalse(model.layout.reference.isEmpty)
        for control in controls {
            XCTAssertFalse(model.layout.reference.intersects(control), "Interactive reference content must not cover controller hit areas.")
            XCTAssertFalse(model.layout.friendButton.intersects(control))
            XCTAssertFalse(model.layout.viewsButton.intersects(control))
        }
        XCTAssertTrue(model.receivesTouch(at: CGPoint(x: model.layout.reference.midX, y: model.layout.reference.midY)))
        XCTAssertTrue(model.receivesTouch(at: CGPoint(x: model.layout.friendButton.midX, y: model.layout.friendButton.midY)))
        XCTAssertTrue(model.receivesTouch(at: CGPoint(x: model.layout.viewsButton.midX, y: model.layout.viewsButton.midY)))
        XCTAssertFalse(model.receivesTouch(at: CGPoint(x: model.layout.friend.midX, y: model.layout.friend.midY)),
                       "The locked video remains touch-through even while the other view is visible.")
        model.moveReference(CGSize(width: 800, height: 500), ended: true)
        for control in controls {
            XCTAssertFalse(model.layout.reference.intersects(control), "Dragging must preserve controller clearance.")
        }
        XCTAssertEqual(model.preferences.referenceCenter,
                       BoundLandscapeGeometry.normalizedCenter(frame: model.layout.reference, canvas: model.layout.canvas))
    }

    func testFriendArrangementCancelSaveAndRotationKeepPreferencesIndependent() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = model.preferences
        XCTAssertEqual(preferences.option, .option7)
        preferences.option = .option2
        model.setActive(true)
        model.updateLayout(canvas: CGRect(x: 0, y: 0, width: 900, height: 500), occupied: [], leftShoulder: nil, keyboardHeight: 0)
        preferences.friendVisible = false
        preferences.referenceVisible = false
        preferences.referenceContents = [.notes, .types, .bosses]
        model.reload()

        let original = preferences.friendPlacement
        model.beginArrangement = { true }
        model.arrangeFriend()
        XCTAssertTrue(model.editing)
        model.setSize(0.48)
        model.setOpacity(0.6)
        model.nudgeFriend(dx: -24, dy: 18)
        model.updateLayout(canvas: model.layout.canvas, occupied: [], leftShoulder: nil, keyboardHeight: 0)
        model.finishArrangement(save: false)
        XCTAssertEqual(preferences.friendPlacement, original, "Cancel discards all draft placement and appearance changes.")
        XCTAssertFalse(preferences.friendVisible, "Opening the editor must not persist its temporary forced visibility.")

        model.arrangeFriend()
        model.setSize(0.4)
        model.nudgeFriend(dx: -32, dy: 24)
        model.updateLayout(canvas: model.layout.canvas, occupied: [], leftShoulder: nil, keyboardHeight: 0)
        model.finishArrangement(save: true)
        XCTAssertTrue(preferences.friendVisible)
        XCTAssertEqual(preferences.friendPlacement.widthFraction, 0.4, accuracy: 0.001)

        let savedPlacement = preferences.friendPlacement
        model.arrangeFriend()
        model.setSize(0.55)
        model.updateLayout(canvas: model.layout.canvas, occupied: [], leftShoulder: nil, keyboardHeight: 0)
        model.setActive(false)
        XCTAssertFalse(model.editing)
        XCTAssertEqual(preferences.friendPlacement, savedPlacement, "Leaving landscape while arranging discards the unsaved draft.")

        model.setActive(true)
        model.toggleFriend()
        XCTAssertFalse(preferences.friendVisible)
        model.cycleViews()
        XCTAssertTrue(preferences.referenceVisible)
        XCTAssertEqual(preferences.referenceContents, [.notes, .types, .bosses])
        XCTAssertFalse(preferences.friendVisible, "Showing Views must not implicitly show or select Friend.")
        model.hideReference()
        XCTAssertFalse(preferences.referenceVisible)
        XCTAssertFalse(preferences.friendVisible, "Hiding Views must not change Friend visibility.")

        let restarted = BoundLandscapeCompanionModel(preferences: BoundLandscapePreferences(defaults: defaults, namespace: suite))
        XCTAssertEqual(restarted.preferences.option, .option2)
        XCTAssertEqual(restarted.preferences.friendPlacement, savedPlacement)
        XCTAssertEqual(restarted.preferences.referenceContents, [.notes, .types, .bosses])
        XCTAssertFalse(restarted.preferences.referenceVisible)
    }
}
