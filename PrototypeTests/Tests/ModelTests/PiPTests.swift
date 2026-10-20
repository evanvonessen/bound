import Foundation
import CoreGraphics
import XCTest
@testable import Models
final class PiPTests: XCTestCase {
    @MainActor func testLegacyCornerMigratesPerPanelAndTypesIgnoresLegacyTransparency() throws {
        let suite = "BoundPiPIndependent." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("bottomLeft", forKey: "bound.delta.pip.v1.corner")
        defaults.set(0.2, forKey: "bound.delta.pip.v1.types.opacity")
        let preferences = BoundPiPPreferences(defaults: defaults)
        for content in BoundPiPContent.allCases { XCTAssertEqual(preferences.corner(for: content), .bottomLeft) }
        preferences.setCorner(.topLeft, for: .friend)
        preferences.setCorner(.bottomRight, for: .notes)
        preferences.setCorner(.topRight, for: .types)
        preferences.setOpacity(0.3, for: .friend)
        preferences.setOpacity(0.6, for: .notes)
        preferences.setOpacity(0, for: .types)
        let relaunched = BoundPiPPreferences(defaults: defaults)
        XCTAssertEqual(relaunched.corner(for: .friend), .topLeft)
        XCTAssertEqual(relaunched.corner(for: .notes), .bottomRight)
        XCTAssertEqual(relaunched.corner(for: .types), .topRight)
        XCTAssertEqual(relaunched.opacity(for: .friend), 0.3)
        XCTAssertEqual(relaunched.opacity(for: .notes), 0.6)
        XCTAssertEqual(relaunched.opacity(for: .types), 1)
        XCTAssertEqual(relaunched.transparency(for: .types), 0)
    }
    @MainActor func testPreferencesPersistIndependentContentAndSharedCorner() throws {
        let suite = "BoundPiPTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BoundPiPPreferences(defaults: defaults)
        XCTAssertEqual(model.corner, .topRight)
        for content in BoundPiPContent.allCases {
            XCTAssertEqual(model.scale(for: content), 1)
            XCTAssertEqual(model.opacity(for: content), 1)
        }
        model.corner = .bottomLeft
        model.setScale(0.7, for: .friend); model.setScale(1.25, for: .types)
        model.setTransparency(0.75, for: .notes)
        let restarted = BoundPiPPreferences(defaults: defaults)
        XCTAssertEqual(restarted.corner, .bottomLeft)
        XCTAssertEqual(restarted.scale(for: .friend), 0.7)
        XCTAssertEqual(restarted.scale(for: .types), 1.25)
        XCTAssertEqual(restarted.scale(for: .notes), 1)
        XCTAssertEqual(restarted.opacity(for: .notes), 0.25)
        XCTAssertEqual(restarted.opacity(for: .friend), 1)
        restarted.setScale(.nan, for: .friend)
        XCTAssertEqual(restarted.scale(for: .friend), 0.7)
        restarted.setScale(20, for: .types)
        XCTAssertEqual(restarted.scale(for: .types), 1.4)
    }
    @MainActor func testVerticalOpacityMappingMatchesOriginalBound() {
        XCTAssertEqual(BoundPiPPreferences.opacity(start: 1, verticalTranslation: 50, panelHeight: 100), 0.5)
        XCTAssertEqual(BoundPiPPreferences.opacity(start: 0.5, verticalTranslation: -50, panelHeight: 100), 1)
        XCTAssertEqual(BoundPiPPreferences.opacity(start: 0.5, verticalTranslation: 500, panelHeight: 100), 0)
    }
    func testCornersClampAndDirectionalSnap() {
        let viewport = CGRect(x: 100, y: 20, width: 600, height: 400)
        let layout = BoundPiPLayout(viewport: viewport, baseSize: CGSize(width: 216, height: 144), scale: 1.4)
        for corner in BoundPiPCorner.allCases {
            let center = layout.center(corner)
            let frame = CGRect(x: center.x - layout.size.width/2, y: center.y - layout.size.height/2,
                               width: layout.size.width, height: layout.size.height)
            XCTAssertTrue(viewport.contains(frame))
            let clamp = layout.clampedCenter(from: corner, translation: CGSize(width: 9999, height: -9999))
            XCTAssertEqual(clamp.x, viewport.maxX - 8 - layout.size.width/2)
            XCTAssertEqual(clamp.y, viewport.minY + 8 + layout.size.height/2)
        }
        XCTAssertEqual(layout.destination(from: .topRight, translation: CGSize(width: -71, height: 56)), .topRight)
        XCTAssertEqual(layout.destination(from: .topRight, translation: CGSize(width: -300, height: 200)), .bottomLeft)
        XCTAssertEqual(layout.destination(from: .topRight, translation: CGSize(width: -70, height: 55)), .topRight)
        XCTAssertEqual(layout.hiddenSide(from: .topRight, translation: CGSize(width: 51, height: 0), endX: 681), .right)
        XCTAssertNil(layout.hiddenSide(from: .topRight, translation: CGSize(width: 50, height: 0), endX: 700))
        XCTAssertEqual(layout.hiddenSide(from: .bottomLeft, translation: CGSize(width: -400, height: 0)), .left)
    }
    func testPiPAvoidsControlsAtEveryCornerAndDuringDragging() {
        let viewport = CGRect(x: 100, y: 0, width: 600, height: 400)
        let occupied = [CGRect(x: 95, y: 30, width: 100, height: 40),
                        CGRect(x: 100, y: 85, width: 55, height: 50),
                        CGRect(x: 630, y: 30, width: 100, height: 40),
                        CGRect(x: 645, y: 85, width: 55, height: 50),
                        CGRect(x: 90, y: 230, width: 110, height: 140),
                        CGRect(x: 610, y: 230, width: 110, height: 140)]
        for scale: CGFloat in [0.65, 1.4, 99] {
            let layout = BoundPiPLayout(viewport: viewport, baseSize: CGSize(width: 216, height: 144), scale: scale, occupied: occupied)
            XCTAssertGreaterThan(layout.size.width, 0)
            XCTAssertEqual(layout.size.width / layout.size.height, 1.5, accuracy: 0.0001)
            for corner in BoundPiPCorner.allCases {
                for translation in [CGSize.zero, CGSize(width: 9999, height: -9999), CGSize(width: -90, height: 50)] {
                    let center = layout.clampedCenter(from: corner, translation: translation)
                    let frame = CGRect(x: center.x - layout.size.width/2, y: center.y - layout.size.height/2,
                                       width: layout.size.width, height: layout.size.height)
                    XCTAssertTrue(viewport.insetBy(dx: 7.99, dy: 7.99).contains(frame))
                    for obstacle in occupied { XCTAssertFalse(frame.intersects(obstacle)) }
                }
            }
        }
    }
    func testDraggingAcrossAnInputDoesNotTeleportBeforeRelease() {
        let layout = BoundPiPLayout(viewport: CGRect(x: 100, y: 0, width: 600, height: 400),
            baseSize: CGSize(width: 216, height: 144), scale: 1,
            occupied: [CGRect(x: 600, y: 240, width: 100, height: 150)])
        let start = layout.center(.topRight)
        for dy: CGFloat in [25, 50, 75, 100] {
            let dragged = layout.dragCenter(from: .topRight, translation: CGSize(width: -30, height: dy))
            XCTAssertEqual(dragged.x, start.x - 30, accuracy: 0.001)
            XCTAssertEqual(dragged.y, start.y + dy, accuracy: 0.001)
        }
        // A short diagonal adjustment does not leap across both axes.
        XCTAssertEqual(layout.destination(from: .topRight, translation: CGSize(width: -80, height: 60)), .topRight)
    }

    func testPiPBoundsOversizedRequestAndReportsCompletelyCoveredViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 60)
        let layout = BoundPiPLayout(viewport: viewport, baseSize: CGSize(width: 216, height: 144), scale: 1.4)
        XCTAssertLessThanOrEqual(layout.size.width, 84)
        XCTAssertLessThanOrEqual(layout.size.height, 44)
        XCTAssertEqual(layout.size.width/layout.size.height, 1.5, accuracy: 0.0001)
        let covered = BoundPiPLayout(viewport: viewport, baseSize: CGSize(width: 216, height: 144), scale: 1.4,
                                    occupied: [viewport])
        XCTAssertEqual(covered.size, .zero)
    }

}
