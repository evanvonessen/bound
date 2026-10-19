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

    func testOptionFiveCopiesOptionThreeAndPersistsIndependentlyAcrossRecreation() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses])
        model.setActive(true)
        arrangeLayout(model)

        model.arrange()
        model.select(.dex)
        model.move(content: .dex, translation: CGSize(width: -70, height: 30), ended: true)
        model.setOpacity(0.38, for: .dex)
        model.finish(save: true)
        let optionThreeDex = model.placement(for: .dex)
        let optionThreeFriend = model.placement(for: .friend)

        model.useOption(.option4)
        arrangeLayout(model)
        model.arrange()
        model.select(.dex)
        model.move(content: .dex, translation: CGSize(width: 90, height: -35), ended: true)
        model.setOpacity(0.82, for: .dex)
        model.finish(save: true)
        let optionFourDex = model.placement(for: .dex)
        XCTAssertNotEqual(optionFourDex, optionThreeDex)

        model.useOption(.option5)
        XCTAssertEqual(model.placement(for: .dex), optionThreeDex,
                       "Option 5's first-use snapshot comes from Option 3, not the currently selected Option 4.")
        XCTAssertEqual(model.placement(for: .friend), optionThreeFriend)
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(.dex)
        model.setOpacity(0.61, for: .dex)
        model.finish(save: true)
        let optionFiveDex = model.placement(for: .dex)
        XCTAssertNotEqual(optionFiveDex, optionThreeDex)

        model.useOption(.option3)
        XCTAssertEqual(model.placement(for: .dex), optionThreeDex)
        model.useOption(.option4)
        XCTAssertEqual(model.placement(for: .dex), optionFourDex)
        model.useOption(.option5)
        XCTAssertEqual(model.placement(for: .dex), optionFiveDex)

        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option5)
        XCTAssertEqual(restored.placement(for: .dex), optionFiveDex)
        restored.useOption(.option3)
        XCTAssertEqual(restored.placement(for: .dex), optionThreeDex)
        restored.useOption(.option4)
        XCTAssertEqual(restored.placement(for: .dex), optionFourDex)
    }

    func testOptionSixSharesOptionThreeNotesPlacementAcrossPagesAndRecreation() throws {
        try assertOptionSixSnapshot(source: .notes, expectedInitialPage: .dex)
    }

    func testOptionSixSharesOptionThreeDexPlacementAcrossPagesAndRecreation() throws {
        try assertOptionSixSnapshot(source: .dex, expectedInitialPage: .dex)
    }

    private func assertOptionSixSnapshot(source: BoundPiPContent,
                                         expectedInitialPage: BoundPiPContent) throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.notes, .dex, .bosses, .types])
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(source)
        model.move(content: source, translation: CGSize(width: -55, height: 25), ended: true)
        model.resize(content: source, translation: CGSize(width: 24, height: 12), axis: .scale, ended: true)
        model.setOpacity(0.43, for: source)
        model.finish(save: true)
        let optionThreeSource = model.placement(for: source)

        model.useOption(.option6)
        XCTAssertTrue(model.multiview)
        XCTAssertEqual(model.contents, [.dex, .bosses, .types])
        XCTAssertEqual(model.referenceContent, expectedInitialPage)
        for page in model.contents { XCTAssertEqual(model.placement(for: page), optionThreeSource) }

        model.setActive(true)
        arrangeLayout(model)
        let initialSize = model.layout.reference.size
        model.select(.bosses)
        XCTAssertEqual(model.layout.reference.size, initialSize)
        model.select(.types)
        XCTAssertEqual(model.layout.reference.size, initialSize)
        model.arrange()
        model.move(content: .types, translation: CGSize(width: 35, height: -18), ended: true)
        model.resize(content: .types, translation: CGSize(width: 18, height: 9), axis: .scale, ended: true)
        model.setOpacity(0.71, for: .types)
        let shared = model.placement(for: .types)
        for page in model.contents { XCTAssertEqual(model.placement(for: page), shared) }
        model.finish(save: true)

        model.useOption(.option3)
        XCTAssertEqual(model.placement(for: source), optionThreeSource,
                       "Option 6 edits must not change the Option 3 snapshot.")
        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option6)
        XCTAssertEqual(restored.referenceContent, .types,
                       "Option 6 must persist its selected page independently.")
        for page in restored.contents {
            XCTAssertEqual(restored.placement(for: page), shared)
            XCTAssertEqual(restored.opacity(for: page), 0.71, accuracy: 0.0001)
        }
    }

    func testOptionSixKeepsFixedPagesWhenGloballyDisabledAndPlacesToggleOnBound() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([])
        model.useOption(.option6)
        XCTAssertEqual(model.contents, [.dex, .bosses, .types])
        XCTAssertTrue(model.multiview)

        model.setActive(true)
        arrangeLayout(model)
        XCTAssertEqual(model.layout.viewsButton.midX, 940, accuracy: 0.001)
        XCTAssertEqual(model.layout.viewsButton.midY, 535, accuracy: 0.001)
        XCTAssertEqual(model.layout.friendButton.midX, 60, accuracy: 0.001,
                       "The Friend toggle remains mirrored from Menu.")
        model.useOption(.option3)
        XCTAssertEqual(model.contents, [], "The configured content list returns outside Option 6.")
    }

    func testOptionSevenCopiesCustomizedOptionSixAndPersistsIndependently() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses, .types, .notes])
        model.useOption(.option6)
        XCTAssertTrue(model.multiview)
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(.bosses)
        model.move(content: .bosses, translation: CGSize(width: -30, height: 18), ended: true)
        model.setOpacity(0.46, for: .bosses)
        model.select(.friend)
        model.move(content: .friend, translation: CGSize(width: 24, height: -14), ended: true)
        model.toggleFriend()
        model.toggleReference()
        model.finish(save: true)
        let optionSixReference = model.placement(for: .dex)
        let optionSixFriend = model.placement(for: .friend)

        model.useOption(.option7)
        XCTAssertTrue(model.multiview)
        XCTAssertTrue(model.tabbedMultiview)
        XCTAssertEqual(model.contents, [.dex, .bosses, .types])
        XCTAssertEqual(model.referenceContent, .bosses)
        XCTAssertEqual(model.placement(for: .types), optionSixReference)
        XCTAssertEqual(model.placement(for: .friend), optionSixFriend)
        XCTAssertFalse(model.friendVisible)
        XCTAssertFalse(model.referenceVisible)

        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(.types)
        model.setOpacity(0.73, for: .types)
        let optionSevenReference = model.placement(for: .types)
        model.finish(save: true)
        model.useOption(.option6)
        XCTAssertEqual(model.referenceContent, .bosses)
        XCTAssertEqual(model.placement(for: .dex), optionSixReference)
        XCTAssertEqual(model.opacity(for: .dex), 0.46, accuracy: 0.0001)

        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option7)
        XCTAssertEqual(restored.referenceContent, .types)
        XCTAssertEqual(restored.placement(for: .bosses), optionSevenReference)
        XCTAssertEqual(restored.opacity(for: .bosses), 0.73, accuracy: 0.0001)
        XCTAssertEqual(restored.placement(for: .friend), optionSixFriend)
        XCTAssertFalse(restored.friendVisible)
        XCTAssertFalse(restored.referenceVisible)
    }

    func testOptionSevenUninitializedOptionSixUsesOptionThreeBaselineAndEnforcesHeaderHeight() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex])
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(.dex)
        model.resize(content: .dex, translation: CGSize(width: -1000, height: -1000), axis: .scale, ended: true)
        model.finish(save: true)
        let tinyOptionThree = model.placement(for: .dex)
        model.useOption(.option7)
        model.setContents([])

        XCTAssertFalse(defaults.bool(forKey: namespace + ".option6.initialized"),
                        "Creating Option 7 must not initialize or rewrite Option 6.")
        XCTAssertTrue(model.tabbedMultiview)
        XCTAssertEqual(model.contents, [.dex, .bosses, .types],
                       "Fixed Option 7 tabs remain available when global content selection is empty.")
        XCTAssertEqual(model.placement(for: .dex), tinyOptionThree)

        model.setActive(true)
        arrangeLayout(model)
        XCTAssertGreaterThanOrEqual(model.layout.reference.height, 154,
                                    "The fixed tab header needs 44 points above a 110-point body.")
        XCTAssertEqual(model.layout.viewsButton.midX, 940, accuracy: 0.001)
        XCTAssertEqual(model.layout.viewsButton.midY, 535, accuracy: 0.001)
        XCTAssertEqual(model.layout.friendButton.midX, 60, accuracy: 0.001)

        let shortCanvas = CGRect(x: 0, y: 0, width: 1000, height: 200)
        let menu = CGRect(x: 900, y: 20, width: 80, height: 40)
        let bound = CGRect(x: 900, y: 150, width: 80, height: 40)
        let bases: [BoundPiPContent: CGRect] = [
            .friend: CGRect(x: 650, y: 35, width: 240, height: 160),
            .dex: CGRect(x: 380, y: 30, width: 300, height: 130),
            .bosses: CGRect(x: 390, y: 30, width: 260, height: 130),
            .types: CGRect(x: 390, y: 30, width: 260, height: 130),
            .notes: CGRect(x: 390, y: 30, width: 260, height: 130)
        ]
        model.updateLayout(canvas: shortCanvas, occupied: [menu, bound], menuFrame: menu,
                           boundFrame: bound, defaults: bases, keyboardHeight: 50)
        XCTAssertFalse(model.layout.reference.isEmpty,
                       "A keyboard-reduced landscape canvas should keep the multiview visible.")
        XCTAssertLessThanOrEqual(model.layout.reference.height, model.layout.canvas.height)
    }

    func testOptionSevenCopiesOptionSixAutoLayoutWithoutArrangement() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses, .types])
        model.useOption(.option6)
        model.setActive(true)
        arrangeLayout(model)
        let optionSixReference = model.placement(for: .dex)
        let optionSixFriend = model.placement(for: .friend)

        model.useOption(.option7)
        XCTAssertEqual(model.placement(for: .dex), optionSixReference)
        XCTAssertEqual(model.placement(for: .friend), optionSixFriend,
                       "Option 7 should preserve Option 6's live auto-layout for Friend.")
    }

    func testOptionFiveCornerPlacementKeepsSizeAndOpacityAndRespectsReferenceControls() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex])
        model.useOption(.option5)
        model.setActive(true)
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let menu = CGRect(x: 900, y: 20, width: 80, height: 70)
        let bound = CGRect(x: 900, y: 500, width: 80, height: 70)
        let obstacle = CGRect(x: 445, y: 220, width: 110, height: 120)
        let bases: [BoundPiPContent: CGRect] = [
            .friend: CGRect(x: 650, y: 80, width: 240, height: 160),
            .dex: CGRect(x: 380, y: 115, width: 300, height: 360),
            .bosses: CGRect(x: 390, y: 130, width: 260, height: 360),
            .types: CGRect(x: 390, y: 130, width: 260, height: 360),
            .notes: CGRect(x: 390, y: 130, width: 260, height: 360)
        ]
        model.updateLayout(canvas: canvas, occupied: [obstacle, menu, bound], menuFrame: menu,
                           boundFrame: bound, defaults: bases, keyboardHeight: 0)
        model.arrange()
        model.select(.dex)
        model.resize(content: .dex, translation: CGSize(width: 35, height: -10), axis: .scale, ended: true)
        model.setOpacity(0.47, for: .dex)
        let referenceSize = model.layout.reference.size
        let referenceOpacity = model.opacity(for: .dex)
        for corner in BoundLandscapeArrangementModel.Corner.allCases {
            model.placeSelectedView(at: corner)
            let frame = model.layout.reference
            XCTAssertFalse(frame.isEmpty, "\(corner.title) should resolve to a visible reference position.")
            XCTAssertFalse(frame.intersects(obstacle), "Reference must avoid the play-area obstacle at \(corner.title).")
            XCTAssertFalse(frame.intersects(menu), "Reference must remain clear of the MENU hit region.")
            XCTAssertFalse(frame.intersects(bound), "Reference must remain clear of the BOUND hit region.")
            XCTAssertEqual(frame.size.width, referenceSize.width, accuracy: 1)
            XCTAssertEqual(frame.size.height, referenceSize.height, accuracy: 1)
            XCTAssertEqual(model.opacity(for: .dex), referenceOpacity, accuracy: 0.0001)
        }

        model.select(.friend)
        model.setOpacity(0.29, for: .friend)
        let friendSize = model.layout.friend.size
        model.placeSelectedView(at: .topRight)
        XCTAssertTrue(model.layout.friend.intersects(menu),
                      "Friend corner shortcuts may use the touch-through MENU area.")
        XCTAssertEqual(model.layout.friend.size.width, friendSize.width, accuracy: 1)
        XCTAssertEqual(model.layout.friend.size.height, friendSize.height, accuracy: 1)
        XCTAssertEqual(model.opacity(for: .friend), 0.29, accuracy: 0.0001)
    }

    func testOptionFiveCornerPlacementDraftCancelAndDonePersistence() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex])
        model.useOption(.option5)
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(.dex)
        let original = model.placement(for: .dex)
        model.placeSelectedView(at: .topLeft)
        let draft = model.placement(for: .dex)
        XCTAssertNotEqual(draft.center, original.center)
        model.finish(save: false)
        XCTAssertEqual(model.placement(for: .dex), original, "Cancel discards a corner shortcut draft.")

        model.arrange()
        model.select(.dex)
        model.placeSelectedView(at: .bottomRight)
        let saved = model.placement(for: .dex)
        model.finish(save: true)
        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option5)
        XCTAssertEqual(restored.placement(for: .dex), saved, "Done persists the selected corner position.")
    }

    func testOptionFiveToolbarAnchorWaitsForManipulationEndAndShortcutsAreOptionScoped() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex])
        model.useOption(.option5)
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(.dex)
        let anchorBeforeDrag = model.editorAtTop
        model.move(content: .dex, translation: CGSize(width: 0, height: 180), ended: false)
        XCTAssertEqual(model.editorAtTop, anchorBeforeDrag,
                       "The toolbar remains steady while the panel is moving under a finger.")
        model.move(content: .dex, translation: CGSize(width: 0, height: 180), ended: true)
        XCTAssertTrue(model.editorAtTop, "After the move ends, the toolbar moves opposite the panel's lower-half position.")

        model.finish(save: false)
        model.useOption(.option3)
        arrangeLayout(model)
        model.arrange()
        XCTAssertFalse(model.placementShortcuts)
        XCTAssertFalse(model.focusedHandles)
        let optionThreePlacement = model.placement(for: .dex)
        model.placeSelectedView(at: .topLeft)
        XCTAssertEqual(model.placement(for: .dex), optionThreePlacement)
        model.finish(save: false)

        model.useOption(.option4)
        arrangeLayout(model)
        model.arrange()
        XCTAssertFalse(model.placementShortcuts)
        XCTAssertTrue(model.focusedHandles)
        let optionFourPlacement = model.placement(for: .dex)
        model.placeSelectedView(at: .topLeft)
        XCTAssertEqual(model.placement(for: .dex), optionFourPlacement)
        let optionFourAnchor = model.editorAtTop
        model.move(content: .dex, translation: CGSize(width: 0, height: 180), ended: true)
        XCTAssertEqual(model.editorAtTop, optionFourAnchor,
                       "Automatic toolbar repositioning is specific to Option 5.")
        model.finish(save: false)
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
