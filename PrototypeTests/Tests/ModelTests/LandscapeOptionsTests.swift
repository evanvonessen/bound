import Foundation
import CoreGraphics
import XCTest
@testable import Models

final class LandscapeOptionsTests: XCTestCase {
    @MainActor
    func testLandscapeOptionsDefaultToOptionSevenAndPersistSeparately() throws {
        let suite = "BoundLandscapeOptions." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = BoundLandscapePreferences(defaults: defaults)
        XCTAssertEqual(preferences.option, .option7)
        XCTAssertEqual(BoundLandscapeOption.option1.title, "Option 1")
        XCTAssertEqual(preferences.referenceContents, [.notes, .types, .bosses, .dex])
        XCTAssertEqual(preferences.referenceContent, .notes)
        XCTAssertTrue(preferences.friendVisible)
        XCTAssertFalse(preferences.referenceVisible)
        XCTAssertEqual(preferences.friendPlacement, BoundLandscapeFriendPlacement())
        XCTAssertEqual(preferences.referenceCenter, CGPoint(x: 0.5, y: 0.3))
        XCTAssertEqual(preferences.referenceScale, 1)

        preferences.option = .option2
        preferences.friendVisible = false
        preferences.referenceVisible = true
        preferences.referenceContents = [.dex, .notes, .friend, .dex, .types]
        preferences.referenceContent = .types
        preferences.referenceCenter = CGPoint(x: 0.2, y: 0.8)
        preferences.referenceScale = 1.2
        preferences.friendPlacement = BoundLandscapeFriendPlacement(center: CGPoint(x: 0.91, y: 0.62),
                                                                      widthFraction: 0.4, opacity: 0.65)

        let restarted = BoundLandscapePreferences(defaults: defaults)
        XCTAssertEqual(restarted.option, .option2)
        XCTAssertFalse(restarted.friendVisible)
        XCTAssertTrue(restarted.referenceVisible)
        XCTAssertEqual(restarted.referenceContents, [.dex, .notes, .types])
        XCTAssertEqual(restarted.referenceContent, .types)
        XCTAssertEqual(restarted.referenceCenter, CGPoint(x: 0.2, y: 0.8))
        XCTAssertEqual(restarted.referenceScale, 1.2)
        XCTAssertEqual(restarted.friendPlacement, preferences.friendPlacement)
    }

    @MainActor
    func testLandscapePreferencesSanitizeInvalidSavedValuesAndAllowEmptyViews() throws {
        let suite = "BoundLandscapeInvalid." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(99, forKey: "bound.landscape.v1.option")
        defaults.set(["friend", "dex", "dex", "invalid", "types"], forKey: "bound.landscape.v1.reference-contents")
        defaults.set("friend", forKey: "bound.landscape.v1.reference-content")
        let prefs = BoundLandscapePreferences(defaults: defaults)
        XCTAssertEqual(prefs.option, .option1)
        XCTAssertEqual(prefs.referenceContents, [.dex, .types])
        XCTAssertEqual(prefs.referenceContent, .dex)

        prefs.referenceContents = []
        prefs.referenceContent = .bosses
        XCTAssertTrue(prefs.referenceContents.isEmpty)
        XCTAssertEqual(prefs.referenceContent, .notes)
        XCTAssertEqual(prefs.friendPlacement, BoundLandscapeFriendPlacement())

        prefs.friendPlacement = BoundLandscapeFriendPlacement(center: CGPoint(x: .infinity, y: -.infinity),
                                                                widthFraction: .nan, opacity: .infinity)
        XCTAssertEqual(prefs.friendPlacement, BoundLandscapeFriendPlacement())
        prefs.referenceCenter = CGPoint(x: -0.5, y: 1.5)
        XCTAssertEqual(prefs.referenceCenter, CGPoint(x: 0, y: 1))
        prefs.referenceCenter = CGPoint(x: .nan, y: -.infinity)
        XCTAssertEqual(prefs.referenceCenter, CGPoint(x: 0.5, y: 0.5))
        prefs.referenceScale = .infinity
        XCTAssertEqual(prefs.referenceScale, 1)
        prefs.referenceScale = 4
        XCTAssertEqual(prefs.referenceScale, 1.3)
        prefs.referenceScale = 0
        XCTAssertEqual(prefs.referenceScale, 0.8)
    }

    func testFriendCanUseExactNormalizedPlacementAcrossControlAreas() {
        let canvas = CGRect(x: 20, y: 30, width: 900, height: 420)
        let placement = BoundLandscapeFriendPlacement(center: CGPoint(x: 0.82, y: 0.68),
                                                       widthFraction: 0.3, opacity: 0.9)
        let frame = BoundLandscapeGeometry.friendFrame(canvas: canvas, placement: placement)
        XCTAssertEqual(frame.width, 270, accuracy: 0.001)
        XCTAssertEqual(frame.height, 180, accuracy: 0.001)
        XCTAssertEqual(BoundLandscapeGeometry.normalizedCenter(frame: frame, canvas: canvas).x, 0.82, accuracy: 0.001)
        XCTAssertEqual(BoundLandscapeGeometry.normalizedCenter(frame: frame, canvas: canvas).y, 0.68, accuracy: 0.001)

        let button = CGRect(x: 730, y: 290, width: 100, height: 90)
        XCTAssertTrue(frame.intersects(button), "Friend overlay is allowed to cover controls when locked.")
    }

    func testFriendPreservesAspectRatioWhenLandscapeCanvasIsShort() {
        let canvas = CGRect(x: 0, y: 0, width: 900, height: 120)
        let placement = BoundLandscapeFriendPlacement(center: CGPoint(x: 0.5, y: 0.5),
                                                       widthFraction: 0.3, opacity: 0.9)
        let frame = BoundLandscapeGeometry.friendFrame(canvas: canvas, placement: placement)
        XCTAssertEqual(frame.width, 180, accuracy: 0.001)
        XCTAssertEqual(frame.height, 120, accuracy: 0.001)
        XCTAssertEqual(frame.width / frame.height, 1.5, accuracy: 0.001)
        XCTAssertTrue(canvas.contains(frame))
    }

    func testReferenceViewFindsClearPlacementAroundControlsAndSafeCanvas() throws {
        // The canvas starts after a left safe-area inset and ends before the right inset.
        let canvas = CGRect(x: 50, y: 12, width: 820, height: 396)
        let controls = [CGRect(x: 48, y: 280, width: 170, height: 130),
                        CGRect(x: 700, y: 280, width: 175, height: 130),
                        CGRect(x: 435, y: 12, width: 130, height: 60)]
        let frame = try XCTUnwrap(BoundLandscapeGeometry.referenceFrame(
            canvas: canvas, preferredCenter: CGPoint(x: 0.85, y: 0.85),
            preferredSize: CGSize(width: 340, height: 230), occupied: controls,
            minimumSize: CGSize(width: 220, height: 150)))

        XCTAssertTrue(canvas.contains(frame))
        for control in controls { XCTAssertFalse(frame.intersects(control)) }
        XCTAssertGreaterThanOrEqual(frame.width, 220)
        XCTAssertGreaterThanOrEqual(frame.height, 150)
        XCTAssertEqual(frame.width / frame.height, 340 / 230, accuracy: 0.001)
    }

    func testReferencePlacementReturnsNilWhenMinimumCannotFit() {
        let canvas = CGRect(x: 100, y: 20, width: 180, height: 120)
        XCTAssertNil(BoundLandscapeGeometry.referenceFrame(
            canvas: canvas, preferredCenter: CGPoint(x: 0.5, y: 0.5),
            preferredSize: CGSize(width: 340, height: 230), occupied: [],
            minimumSize: CGSize(width: 220, height: 150)))

        let covered = CGRect(x: 0, y: 0, width: 500, height: 300)
        XCTAssertNil(BoundLandscapeGeometry.referenceFrame(
            canvas: covered, preferredCenter: CGPoint(x: 0.5, y: 0.5),
            preferredSize: CGSize(width: 340, height: 230), occupied: [covered],
            minimumSize: CGSize(width: 220, height: 150)))
    }

    func testReferencePanelMayTouchControlBoundsWithoutCoveringThem() throws {
        // These are actual control hit-area bounds in a safe landscape canvas.
        let canvas = CGRect(x: 24, y: 8, width: 872, height: 404)
        let menu = CGRect(x: 796, y: 308, width: 84, height: 84)
        let frame = try XCTUnwrap(BoundLandscapeGeometry.referenceFrame(
            canvas: canvas, preferredCenter: CGPoint(x: (menu.minX - 100 - canvas.minX) / canvas.width,
                                                      y: (menu.midY - canvas.minY) / canvas.height),
            preferredSize: CGSize(width: 200, height: 100), occupied: [menu],
            minimumSize: CGSize(width: 180, height: 90)))

        XCTAssertEqual(frame.maxX, menu.minX, accuracy: 0.001)
        XCTAssertEqual(min(frame.maxX, menu.maxX) - max(frame.minX, menu.minX), 0, accuracy: 0.001)
        XCTAssertGreaterThan(min(frame.maxY, menu.maxY) - max(frame.minY, menu.minY), 0)
        XCTAssertTrue(canvas.contains(frame))
    }
}
