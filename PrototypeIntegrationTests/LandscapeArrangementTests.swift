import XCTest
import UIKit
@testable import Delta

@MainActor
final class LandscapeArrangementTests: XCTestCase {
    private func makeModel() throws -> (BoundLandscapeArrangementModel, UserDefaults, String) {
        let namespace = "LandscapeArrangementTests.\(UUID().uuidString)"
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

    func testOptionThreeKeepsEarlierOptionsAndDiscardsDraftWhenLeavingLandscape() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        let preferences = BoundLandscapePreferences(defaults: defaults)
        XCTAssertEqual(preferences.option, .option1)
        preferences.option = .option2
        preferences.friendPlacement = BoundLandscapeFriendPlacement(center: CGPoint(x: 0.2, y: 0.7), widthFraction: 0.3, opacity: 0.6)
        let optionTwoPlacement = preferences.friendPlacement
        preferences.option = .option3
        XCTAssertEqual(BoundLandscapePreferences(defaults: defaults).option, .option3)
        model.setContents([.bosses, .dex])
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(.dex)
        model.setOpacity(0.2, for: .friend)
        model.move(content: .friend, translation: CGSize(width: -100, height: 50), ended: true)
        let beforeDone = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        XCTAssertEqual(beforeDone.referenceContent, .bosses)
        XCTAssertEqual(beforeDone.opacity(for: .friend), 1)
        var resumed: Bool?
        model.endArrangement = { resumed = $0 }
        model.setActive(false)
        XCTAssertFalse(model.editing)
        XCTAssertEqual(resumed, false)
        XCTAssertEqual(model.referenceContent, .bosses)
        XCTAssertEqual(model.opacity(for: .friend), 1)
        XCTAssertEqual(preferences.friendPlacement, optionTwoPlacement)
    }

    func testOptionFourCopiesOptionThreeOnceThenPersistsIndependently() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses])
        model.setActive(true)
        arrangeLayout(model)
        model.toggleFriend()
        model.toggleReference()
        model.arrange()
        model.select(.friend)
        model.setOpacity(0.42, for: .friend)
        model.move(content: .friend, translation: CGSize(width: -80, height: 45), ended: true)
        model.select(.dex)
        model.setOpacity(0.63, for: .dex)
        model.move(content: .dex, translation: CGSize(width: -65, height: 35), ended: true)
        model.finish(save: true)

        let optionThreeFriend = model.placement(for: .friend)
        let optionThreeDex = model.placement(for: .dex)
        let optionThreeBosses = model.placement(for: .bosses)
        XCTAssertFalse(model.friendVisible)
        XCTAssertFalse(model.referenceVisible)
        XCTAssertEqual(model.referenceContent, .dex)

        model.useOption(.option4)
        XCTAssertEqual(model.option, .option4)
        XCTAssertFalse(model.friendVisible)
        XCTAssertFalse(model.referenceVisible)
        XCTAssertEqual(model.referenceContent, .dex)
        XCTAssertEqual(model.placement(for: .friend), optionThreeFriend)
        XCTAssertEqual(model.placement(for: .dex), optionThreeDex)
        XCTAssertEqual(model.placement(for: .bosses), optionThreeBosses)

        model.toggleFriend()
        model.toggleReference()
        model.arrange()
        model.select(.friend)
        model.setOpacity(0.81, for: .friend)
        model.select(.bosses)
        model.setOpacity(0.27, for: .bosses)
        model.finish(save: true)
        let optionFourFriend = model.placement(for: .friend)
        let optionFourBosses = model.placement(for: .bosses)

        model.useOption(.option3)
        XCTAssertFalse(model.friendVisible)
        XCTAssertFalse(model.referenceVisible)
        XCTAssertEqual(model.placement(for: .friend), optionThreeFriend)
        XCTAssertEqual(model.placement(for: .dex), optionThreeDex)
        XCTAssertEqual(model.placement(for: .bosses), optionThreeBosses)

        model.useOption(.option4)
        XCTAssertTrue(model.friendVisible)
        XCTAssertTrue(model.referenceVisible)
        XCTAssertEqual(model.placement(for: .friend), optionFourFriend)
        XCTAssertEqual(model.placement(for: .bosses), optionFourBosses)

        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option4)
        XCTAssertTrue(restored.friendVisible)
        XCTAssertTrue(restored.referenceVisible)
        XCTAssertEqual(restored.referenceContent, .bosses)
        XCTAssertEqual(restored.placement(for: .friend), optionFourFriend)
        XCTAssertEqual(restored.placement(for: .bosses), optionFourBosses)
        restored.useOption(.option3)
        XCTAssertFalse(restored.friendVisible)
        XCTAssertFalse(restored.referenceVisible)
        XCTAssertEqual(restored.placement(for: .friend), optionThreeFriend)
        XCTAssertEqual(restored.placement(for: .dex), optionThreeDex)
    }

    func testOptionFourResetSelectedViewIsDraftableAndAffectsOnlySelection() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses])
        model.useOption(.option4)
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()

        model.select(.dex)
        let dexDefault = model.placement(for: .dex)
        model.move(content: .dex, translation: CGSize(width: -100, height: 50), ended: true)
        model.setOpacity(0.35, for: .dex)
        model.finish(save: true)
        let savedDex = model.placement(for: .dex)
        let savedBosses = model.placement(for: .bosses)
        XCTAssertNotEqual(savedDex, dexDefault)

        model.arrange()
        model.select(.dex)
        model.resetSelectedView()
        XCTAssertEqual(model.placement(for: .dex), dexDefault)
        XCTAssertEqual(model.placement(for: .bosses), savedBosses)
        model.finish(save: false)
        XCTAssertEqual(model.placement(for: .dex), savedDex, "Cancel restores the saved placement and opacity.")

        model.arrange()
        model.select(.dex)
        model.resetSelectedView()
        model.finish(save: true)
        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option4)
        XCTAssertEqual(restored.placement(for: .dex), dexDefault)
        XCTAssertEqual(restored.placement(for: .bosses), savedBosses)
    }

    func testSwitchingOptionsDuringArrangementDiscardsDraftWithoutResuming() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses])
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(.dex)
        model.setOpacity(0.6, for: .dex)
        model.finish(save: true)
        let savedOptionThreeDex = model.placement(for: .dex)

        var resumeValues: [Bool] = []
        model.endArrangement = { resumeValues.append($0) }
        model.arrange()
        model.setOpacity(0.1, for: .dex)
        model.useOption(.option4)
        XCTAssertFalse(model.editing)
        XCTAssertEqual(resumeValues, [false], "Switching variants must cancel without resuming gameplay.")
        XCTAssertEqual(model.placement(for: .dex), savedOptionThreeDex)

        model.arrange()
        model.setOpacity(0.9, for: .dex)
        model.useOption(.option3)
        XCTAssertFalse(model.editing)
        XCTAssertEqual(resumeValues, [false, false])
        XCTAssertEqual(model.placement(for: .dex), savedOptionThreeDex)

        model.useOption(.option4)
        XCTAssertEqual(model.placement(for: .dex), savedOptionThreeDex)
    }

    func testOptionThreeStateIsIndependentAndViewContentNeverContainsFriend() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.friend, .dex, .bosses, .dex])
        XCTAssertEqual(model.contents, [.dex, .bosses])
        XCTAssertTrue(model.friendVisible)
        XCTAssertTrue(model.referenceVisible)
        XCTAssertEqual(model.selected, .dex)
        XCTAssertNil(defaults.object(forKey: "bound.landscape.v1.option"))
        XCTAssertNil(defaults.object(forKey: "bound.landscape.option3.option"))
        model.cycleReference()
        XCTAssertEqual(model.selected, .bosses)
        XCTAssertTrue(model.friendVisible, "Cycling the other views never toggles Friend.")
        model.toggleFriend()
        XCTAssertFalse(model.friendVisible)
        XCTAssertTrue(model.referenceVisible)
    }

    func testArrangeCancelAndSavePersistEachViewSeparately() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.bosses, .dex])
        model.setActive(true)
        arrangeLayout(model)
        model.beginArrangement = { true }
        model.arrange()
        XCTAssertTrue(model.editing)
        let originalDex = model.placement(for: .dex)
        model.move(content: .dex, translation: CGSize(width: -160, height: 90), ended: true)
        model.resize(content: .dex, translation: CGSize(width: 80, height: 20), axis: .scale, ended: true)
        model.setOpacity(0.4, for: .dex)
        model.select(.bosses)
        model.move(content: .bosses, translation: CGSize(width: 110, height: -40), ended: true)
        model.setOpacity(0.7, for: .bosses)
        model.finish(save: false)
        XCTAssertEqual(model.placement(for: .dex), originalDex)
        XCTAssertEqual(model.opacity(for: .bosses), 1)

        model.arrange()
        model.move(content: .dex, translation: CGSize(width: -160, height: 90), ended: true)
        model.resize(content: .dex, translation: CGSize(width: 80, height: 20), axis: .scale, ended: true)
        model.setOpacity(0.4, for: .dex)
        model.select(.bosses)
        model.move(content: .bosses, translation: CGSize(width: 110, height: -40), ended: true)
        model.setOpacity(0.7, for: .bosses)
        model.finish(save: true)

        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        XCTAssertEqual(restored.placement(for: .dex).opacity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(restored.placement(for: .bosses).opacity, 0.7, accuracy: 0.0001)
        XCTAssertNotEqual(restored.placement(for: .dex).center, restored.placement(for: .bosses).center)
        XCTAssertEqual(restored.selected, .bosses)
        XCTAssertEqual(restored.referenceContent, .bosses)
    }

    func testViewPlacementAvoidsControlsAndLockedFriendPassesTouchesThrough() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setActive(true)
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let menu = CGRect(x: 900, y: 15, width: 85, height: 72)
        let bound = CGRect(x: 900, y: 510, width: 85, height: 72)
        let obstacle = CGRect(x: 460, y: 225, width: 180, height: 130)
        let bases: [BoundPiPContent: CGRect] = [
            .friend: CGRect(x: 650, y: 90, width: 230, height: 153),
            .bosses: CGRect(x: 360, y: 120, width: 260, height: 360),
            .dex: CGRect(x: 350, y: 120, width: 300, height: 360),
            .types: CGRect(x: 360, y: 120, width: 260, height: 360),
            .notes: CGRect(x: 360, y: 120, width: 260, height: 360)
        ]
        model.updateLayout(canvas: canvas, occupied: [obstacle, menu, bound], menuFrame: menu,
                           boundFrame: bound, defaults: bases, keyboardHeight: 0)

        XCTAssertEqual(model.layout.friendButton.midY, menu.midY, accuracy: 1)
        XCTAssertEqual(model.layout.viewsButton.midY, bound.midY, accuracy: 1)
        XCTAssertLessThan(model.layout.friendButton.midX, canvas.midX)
        XCTAssertLessThan(model.layout.viewsButton.midX, canvas.midX)
        XCTAssertFalse(model.layout.reference.intersects(obstacle))
        XCTAssertFalse(model.layout.reference.intersects(menu))
        XCTAssertFalse(model.layout.reference.intersects(bound))
        XCTAssertTrue(model.receivesTouch(at: CGPoint(x: model.layout.reference.midX, y: model.layout.reference.midY)))
        XCTAssertFalse(model.receivesTouch(at: CGPoint(x: model.layout.friend.midX, y: model.layout.friend.midY)))
        XCTAssertTrue(model.receivesTouch(at: CGPoint(x: model.layout.friendButton.midX, y: model.layout.friendButton.midY)))

        model.arrange()
        XCTAssertFalse(model.receivesTouch(at: CGPoint(x: bound.midX, y: bound.midY)), "BOUND remains tappable while arranging.")
        XCTAssertTrue(model.receivesTouch(at: CGPoint(x: menu.midX, y: menu.midY)), "The temporary DONE target receives MENU touches.")
        XCTAssertTrue(model.layout.opacityZone.contains(CGPoint(x: canvas.midX, y: canvas.midY)))
    }

    func testThreeFingerFadeChangesOnlySelectedViewAndKeepsZeroRecoverable() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses])
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(.dex)
        model.fade(phase: .began, dy: 0)
        model.fade(phase: .changed, dy: 240)
        model.fade(phase: .ended, dy: 240)
        XCTAssertEqual(model.opacity(for: .dex), 0, accuracy: 0.0001)
        XCTAssertEqual(model.opacity(for: .bosses), 1, accuracy: 0.0001)
        model.setOpacity(0.55, for: .dex)
        XCTAssertEqual(model.opacity(for: .dex), 0.55, accuracy: 0.0001)
        model.finish(save: true)
        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        XCTAssertEqual(restored.opacity(for: .dex), 0.55, accuracy: 0.0001)
        XCTAssertEqual(restored.opacity(for: .bosses), 1, accuracy: 0.0001)
    }

    func testFriendCanBeSelectedForOpacityWithoutChangingReferenceCycle() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses])
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(.friend)
        XCTAssertEqual(model.selected, .friend)
        XCTAssertEqual(model.referenceContent, .dex)
        model.setOpacity(0.3, for: .friend)
        XCTAssertEqual(model.opacity(for: .friend), 0.3, accuracy: 0.0001)
        model.cycleReference()
        XCTAssertEqual(model.selected, .bosses)
        XCTAssertEqual(model.referenceContent, .bosses)
        XCTAssertTrue(model.friendVisible)
    }

    func testReferenceWidthAndHeightCanBeAdjustedIndependently() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex])
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        let initial = model.layout.reference
        model.resize(content: .dex, translation: CGSize(width: 30, height: 0), axis: .width, ended: true)
        let wider = model.layout.reference
        XCTAssertGreaterThan(wider.width, initial.width)
        XCTAssertEqual(wider.height, initial.height, accuracy: 0.01)
        model.resize(content: .dex, translation: CGSize(width: 0, height: 25), axis: .height, ended: true)
        XCTAssertEqual(model.layout.reference.width, wider.width, accuracy: 0.01)
        XCTAssertGreaterThan(model.layout.reference.height, wider.height)
    }

    func testScaleResizePreservesAspectAndUnchangedContentsDoNotRelayout() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setActive(true)
        arrangeLayout(model)
        model.beginArrangement = { true }
        model.arrange()
        let start = model.placement(for: .dex)
        model.resize(content: .dex, translation: CGSize(width: 80, height: 20), axis: .scale, ended: true)
        let scaled = model.placement(for: .dex)
        let canvas = model.layout.canvas
        XCTAssertEqual((scaled.widthFraction * canvas.width) / (scaled.heightFraction * canvas.height),
                       (start.widthFraction * canvas.width) / (start.heightFraction * canvas.height), accuracy: 0.0001)

        var layoutRequests = 0
        model.needsLayout = { layoutRequests += 1 }
        let configured = model.contents
        model.setContents(configured)
        XCTAssertEqual(layoutRequests, 0)
        model.finish(save: false)

        model.setContents([])
        XCTAssertTrue(model.receivesTouch(at: CGPoint(x: model.layout.friendButton.midX, y: model.layout.friendButton.midY)))
        XCTAssertFalse(model.receivesTouch(at: CGPoint(x: model.layout.canvas.midX, y: model.layout.canvas.midY)))
        model.arrange()
        XCTAssertEqual(model.selected, .friend)
    }
}
