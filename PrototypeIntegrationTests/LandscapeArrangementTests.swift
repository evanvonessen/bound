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

    private func arrangeLayout(_ model: BoundLandscapeArrangementModel, screenBounds: CGRect? = nil) {
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
                           boundFrame: bound, defaults: defaults, keyboardHeight: 0,
                           screenBounds: screenBounds)
    }

    private func saveReferenceArrangement(_ model: BoundLandscapeArrangementModel,
                                          content: BoundPiPContent,
                                          translation: CGSize,
                                          resize: CGSize,
                                          opacity: Double) {
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(content)
        model.move(content: content, translation: translation, ended: true)
        model.resize(content: content, translation: resize, axis: .scale, ended: true)
        model.setOpacity(opacity, for: content)
        model.finish(save: true)
    }

    func testControllerModeMigrationCopiesOptionsThreeThroughSevenOnce() throws {
        let namespace = "LandscapeArrangementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }

        let options: [BoundLandscapeOption] = [.option3, .option4, .option5, .option6, .option7]
        var expected: [BoundLandscapeOption: BoundLandscapeViewPlacement] = [:]
        for (index, option) in options.enumerated() {
            let placement = BoundLandscapeViewPlacement(
                center: CGPoint(x: 0.16 + Double(index) * 0.13, y: 0.22 + Double(index) * 0.11),
                widthFraction: 0.24 + Double(index) * 0.07,
                heightFraction: 0.31 + Double(index) * 0.08,
                opacity: 0.35 + Double(index) * 0.1)
            expected[option] = placement
            let prefix = namespace + ".option\(option.rawValue)."
            let referenceContent: BoundPiPContent = [.dex, .bosses, .types][index % 3]
            defaults.set(index.isMultiple(of: 2), forKey: prefix + "friend-visible")
            defaults.set(!index.isMultiple(of: 2), forKey: prefix + "reference-visible")
            defaults.set(referenceContent.rawValue, forKey: prefix + "reference-content")
            defaults.set(try JSONEncoder().encode(placement),
                         forKey: prefix + (option == .option6 || option == .option7
                                          ? "placement.reference" : "placement.\(referenceContent.rawValue)"))
            defaults.set(try JSONEncoder().encode(BoundLandscapeViewPlacement(
                center: CGPoint(x: 0.8, y: 0.7), widthFraction: 0.2, heightFraction: 0.18, opacity: 0.9)),
                         forKey: prefix + "placement.friend")
            if option != .option3 {
                defaults.set(true, forKey: prefix + "initialized")
            }
        }

        let model = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        XCTAssertTrue(defaults.bool(forKey: namespace + ".controller-mode.initialized"))
        for (index, option) in options.enumerated() {
            model.useOption(option, controllerModeEnabled: true)
            XCTAssertTrue(model.controllerModeEnabled)
            let content = model.referenceContent
            XCTAssertEqual(content, [.dex, .bosses, .types][index % 3])
            XCTAssertEqual(model.placement(for: content), try XCTUnwrap(expected[option]))
            XCTAssertEqual(model.friendVisible, index.isMultiple(of: 2))
            XCTAssertEqual(model.referenceVisible, !index.isMultiple(of: 2))
        }
        XCTAssertTrue(defaults.bool(forKey: namespace + ".controller-mode.initialized"),
                      "The controller-mode namespace is migrated once on model creation.")

        model.useOption(.option5, controllerModeEnabled: true)
        saveReferenceArrangement(model, content: .types, translation: CGSize(width: -42, height: 28),
                                 resize: CGSize(width: 24, height: 18), opacity: 0.73)
        let controllerPlacement = model.placement(for: .types)
        XCTAssertNotEqual(controllerPlacement, expected[.option5])

        model.useOption(.option5, controllerModeEnabled: false)
        XCTAssertFalse(model.controllerModeEnabled)
        XCTAssertEqual(model.placement(for: .types), expected[.option5],
                       "Editing Controller Mode on must leave the original Option 5 arrangement intact.")
        model.useOption(.option5, controllerModeEnabled: true)
        XCTAssertEqual(model.placement(for: .types), controllerPlacement,
                       "Switching back must reload the saved Controller Mode on arrangement.")

        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option5, controllerModeEnabled: true)
        XCTAssertEqual(restored.placement(for: .types), controllerPlacement,
                       "A later model initialization must not copy the old arrangement over the migrated state.")
        XCTAssertEqual(restored.referenceContent, .types)
        XCTAssertTrue(restored.friendVisible)
        XCTAssertFalse(restored.referenceVisible)
    }

    func testControllerModeVariantsSnapshotAndPersistWithinTheirOwnNamespace() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses, .types])
        model.useOption(.option3, controllerModeEnabled: false)
        saveReferenceArrangement(model, content: .dex, translation: CGSize(width: 74, height: -38),
                                 resize: CGSize(width: -25, height: 19), opacity: 0.86)
        let controllerModeOffOptionThree = model.placement(for: .dex)

        // makeModel initialized the one-time migration before this later off-mode save.
        // Entering Controller Mode now must load its own pre-edit fallback, not reuse
        // the recently changed off-mode placement from memory.
        model.useOption(.option3, controllerModeEnabled: true)
        let initialControllerOptionThree = model.placement(for: .dex)
        XCTAssertNotEqual(initialControllerOptionThree, controllerModeOffOptionThree)
        saveReferenceArrangement(model, content: .dex, translation: CGSize(width: -68, height: 34),
                                 resize: CGSize(width: 28, height: 14), opacity: 0.44)
        let controllerOptionThree = model.placement(for: .dex)

        model.useOption(.option4, controllerModeEnabled: true)
        XCTAssertEqual(model.placement(for: .dex), controllerOptionThree)
        saveReferenceArrangement(model, content: .dex, translation: CGSize(width: 82, height: -26),
                                 resize: CGSize(width: -20, height: 10), opacity: 0.82)
        let controllerOptionFour = model.placement(for: .dex)
        XCTAssertNotEqual(controllerOptionFour, controllerOptionThree)

        model.useOption(.option5, controllerModeEnabled: true)
        XCTAssertEqual(model.placement(for: .dex), controllerOptionThree,
                       "Option 5 takes its initial snapshot from Controller Mode Option 3.")
        saveReferenceArrangement(model, content: .dex, translation: CGSize(width: 35, height: 48),
                                 resize: CGSize(width: 16, height: -12), opacity: 0.61)
        let controllerOptionFive = model.placement(for: .dex)

        model.useOption(.option6, controllerModeEnabled: true)
        XCTAssertEqual(model.placement(for: .types), controllerOptionThree,
                       "Option 6 starts from Controller Mode Option 3's reference arrangement.")
        saveReferenceArrangement(model, content: .types, translation: CGSize(width: -24, height: 19),
                                 resize: CGSize(width: 20, height: 13), opacity: 0.69)
        let controllerOptionSix = model.placement(for: .dex)

        model.useOption(.option7, controllerModeEnabled: true)
        XCTAssertEqual(model.placement(for: .bosses), controllerOptionSix,
                       "Option 7 starts from Controller Mode Option 6.")
        saveReferenceArrangement(model, content: .bosses, translation: CGSize(width: 51, height: -21),
                                 resize: CGSize(width: -15, height: 17), opacity: 0.77)
        let controllerOptionSeven = model.placement(for: .types)

        for (option, expected) in [
            (BoundLandscapeOption.option3, controllerOptionThree),
            (.option4, controllerOptionFour), (.option5, controllerOptionFive),
            (.option6, controllerOptionSix), (.option7, controllerOptionSeven)
        ] {
            model.useOption(option, controllerModeEnabled: true)
            XCTAssertEqual(model.placement(for: .dex), expected,
                           "Controller Mode Option \(option.rawValue) should retain its own saved state.")
        }

        model.useOption(.option3, controllerModeEnabled: false)
        XCTAssertEqual(model.placement(for: .dex), controllerModeOffOptionThree,
                       "Controller Mode on snapshots must not replace Controller Mode off state.")
        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        for (option, expected) in [
            (BoundLandscapeOption.option3, controllerOptionThree),
            (.option4, controllerOptionFour), (.option5, controllerOptionFive),
            (.option6, controllerOptionSix), (.option7, controllerOptionSeven)
        ] {
            restored.useOption(option, controllerModeEnabled: true)
            XCTAssertEqual(restored.placement(for: .dex), expected)
        }
    }

    func testSwitchingControllerModeCancelsDraftAndReloadsTheSameOption() throws {
        let namespace = "LandscapeArrangementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        let migratedPlacement = BoundLandscapeViewPlacement(
            center: CGPoint(x: 0.31, y: 0.42), widthFraction: 0.39, heightFraction: 0.63, opacity: 0.67)
        defaults.set(try JSONEncoder().encode(migratedPlacement),
                     forKey: namespace + ".option3.placement.dex")
        let model = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        model.setContents([.dex, .bosses])
        model.useOption(.option3, controllerModeEnabled: false)
        model.setActive(true)
        arrangeLayout(model)
        model.arrange()
        model.select(.dex)
        model.setOpacity(0.58, for: .dex)
        model.finish(save: true)
        let savedOff = model.placement(for: .dex)
        XCTAssertNotEqual(savedOff, migratedPlacement)

        var resumeValues: [Bool] = []
        model.endArrangement = { resumeValues.append($0) }
        model.arrange()
        model.setOpacity(0.12, for: .dex)
        model.useOption(.option3, controllerModeEnabled: true)
        XCTAssertFalse(model.editing)
        XCTAssertEqual(resumeValues, [false], "Changing mode must cancel the active draft without resuming gameplay.")
        XCTAssertEqual(model.placement(for: .dex), migratedPlacement,
                       "Controller Mode on retains the value copied once during initialization.")

        model.arrange()
        model.setOpacity(0.91, for: .dex)
        model.useOption(.option3, controllerModeEnabled: false)
        XCTAssertFalse(model.editing)
        XCTAssertEqual(resumeValues, [false, false])
        XCTAssertEqual(model.placement(for: .dex), savedOff,
                       "Returning to Controller Mode off discards the unsaved on draft.")
    }

    func testOptionThreeKeepsEarlierOptionsAndDiscardsDraftWhenLeavingLandscape() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        let preferences = BoundLandscapePreferences(defaults: defaults)
        XCTAssertEqual(preferences.option, .option7)
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

    func testLegacyMultiviewPlacementsDecodeWithFrontLayerDefaults() throws {
        let namespace = "LandscapeArrangementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        let prefix = namespace + ".option6."
        defaults.set(true, forKey: prefix + "initialized")
        defaults.set("dex", forKey: prefix + "reference-content")
        defaults.set(try JSONEncoder().encode(BoundLandscapeViewPlacement(
            center: CGPoint(x: 0.42, y: 0.36), widthFraction: 0.31,
            heightFraction: 0.52, opacity: 0.7)), forKey: prefix + "placement.reference")
        defaults.set(try JSONEncoder().encode(BoundLandscapeViewPlacement(
            center: CGPoint(x: 0.77, y: 0.29), widthFraction: 0.25,
            heightFraction: 0.17, opacity: 0.9)), forKey: prefix + "placement.friend")

        let model = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        model.useOption(.option6)
        XCTAssertTrue(model.aboveButtons(for: .friend))
        XCTAssertTrue(model.aboveButtons(for: .dex))
        XCTAssertTrue(model.aboveButtons(for: .bosses))
        XCTAssertTrue(model.aboveButtons(for: .types))
        XCTAssertEqual(model.placement(for: .dex).opacity, 0.7, accuracy: 0.0001)
    }

    func testMultiviewLayerChoiceIsDraftedSharedAndNamespaced() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses, .types])
        model.setActive(true)
        model.useOption(.option6)
        arrangeLayout(model)

        model.setAboveButtons(false, for: .friend)
        XCTAssertTrue(model.aboveButtons(for: .friend), "Layer changes require an active arrangement edit.")
        model.arrange()
        model.setAboveButtons(false, for: .friend)
        XCTAssertTrue(model.aboveButtons(for: .dex), "Friend and Multiview have independent layer state.")
        model.setAboveButtons(false, for: .dex)
        XCTAssertFalse(model.aboveButtons(for: .friend))
        for page in [BoundPiPContent.dex, .bosses, .types] {
            XCTAssertFalse(model.aboveButtons(for: page), "Multiview layer state is shared across its pages.")
        }
        model.finish(save: false)
        XCTAssertTrue(model.aboveButtons(for: .friend))
        XCTAssertTrue(model.aboveButtons(for: .dex), "Cancel restores saved layer state.")

        model.arrange()
        model.setAboveButtons(false, for: .friend)
        model.setAboveButtons(false, for: .dex)
        model.finish(save: true)
        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option6)
        XCTAssertFalse(restored.aboveButtons(for: .friend))
        for page in [BoundPiPContent.dex, .bosses, .types] {
            XCTAssertFalse(restored.aboveButtons(for: page))
        }

        restored.useOption(.option7)
        restored.setActive(true)
        arrangeLayout(restored)
        restored.arrange()
        restored.setAboveButtons(true, for: .friend)
        restored.setAboveButtons(true, for: .types)
        restored.finish(save: true)
        restored.useOption(.option6)
        XCTAssertFalse(restored.aboveButtons(for: .friend), "Options 6 and 7 keep separate saved layer choices.")
        XCTAssertFalse(restored.aboveButtons(for: .dex))

        restored.useOption(.option6, controllerModeEnabled: true)
        XCTAssertTrue(restored.aboveButtons(for: .friend),
                      "Controller Mode Option 6 is initialized from its own Option 3 snapshot when it did not exist at the one-time migration.")
        restored.setActive(true)
        arrangeLayout(restored)
        restored.arrange()
        restored.setAboveButtons(true, for: .friend)
        restored.setAboveButtons(true, for: .dex)
        restored.finish(save: true)
        restored.useOption(.option6, controllerModeEnabled: false)
        XCTAssertFalse(restored.aboveButtons(for: .friend))
        restored.useOption(.option6, controllerModeEnabled: true)
        XCTAssertTrue(restored.aboveButtons(for: .friend))
    }

    func testMultiviewFriendCanReachPhysicalScreenEdgesAndReferenceStaysSafe() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses, .types])
        model.setActive(true)
        model.useOption(.option6)

        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let safe = CGRect(x: 24, y: 12, width: 952, height: 576)
        let menu = CGRect(x: 900, y: 18, width: 76, height: 68)
        let bound = CGRect(x: 900, y: 514, width: 76, height: 68)
        let obstacle = CGRect(x: 426, y: 214, width: 150, height: 110)
        let bases: [BoundPiPContent: CGRect] = [
            .friend: CGRect(x: 650, y: 90, width: 240, height: 160),
            .dex: CGRect(x: 350, y: 112, width: 300, height: 360),
            .bosses: CGRect(x: 370, y: 120, width: 260, height: 360),
            .types: CGRect(x: 370, y: 120, width: 260, height: 360)
        ]
        model.updateLayout(canvas: safe, occupied: [obstacle, menu, bound], menuFrame: menu,
                           boundFrame: bound, defaults: bases, keyboardHeight: 0, screenBounds: screen)
        XCTAssertEqual(model.layout.friendCanvas, screen)
        XCTAssertEqual(model.layout.canvas.minX, safe.minX + 4, accuracy: 0.001)
        model.arrange()

        model.move(content: .friend, translation: CGSize(width: -10_000, height: -10_000), ended: true)
        XCTAssertEqual(model.layout.friend.minX, screen.minX, accuracy: 0.001)
        XCTAssertEqual(model.layout.friend.minY, screen.minY, accuracy: 0.001)
        model.move(content: .friend, translation: CGSize(width: 10_000, height: 0), ended: true)
        XCTAssertEqual(model.layout.friend.maxX, screen.maxX, accuracy: 0.001)
        XCTAssertEqual(model.layout.friend.minY, screen.minY, accuracy: 0.001)
        model.move(content: .friend, translation: CGSize(width: 0, height: 10_000), ended: true)
        XCTAssertEqual(model.layout.friend.maxX, screen.maxX, accuracy: 0.001)
        XCTAssertEqual(model.layout.friend.maxY, screen.maxY, accuracy: 0.001)
        model.move(content: .friend, translation: CGSize(width: -10_000, height: 0), ended: true)
        XCTAssertEqual(model.layout.friend.minX, screen.minX, accuracy: 0.001)
        XCTAssertEqual(model.layout.friend.maxY, screen.maxY, accuracy: 0.001)

        XCTAssertGreaterThanOrEqual(model.layout.reference.minX, model.layout.canvas.minX)
        XCTAssertGreaterThanOrEqual(model.layout.reference.minY, model.layout.canvas.minY)
        XCTAssertLessThanOrEqual(model.layout.reference.maxX, model.layout.canvas.maxX)
        XCTAssertLessThanOrEqual(model.layout.reference.maxY, model.layout.canvas.maxY)
        XCTAssertFalse(model.layout.reference.intersects(obstacle))
        XCTAssertFalse(model.layout.reference.intersects(menu))
        XCTAssertFalse(model.layout.reference.intersects(bound))
    }

    func testFriendCanvasMigrationPreservesPhysicalFrameAndCopiesBasisToOptionSeven() throws {
        let namespace = "LandscapeArrangementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        let option6 = namespace + ".option6."
        defaults.set(true, forKey: option6 + "initialized")
        defaults.set("dex", forKey: option6 + "reference-content")
        defaults.set(try JSONEncoder().encode(BoundLandscapeViewPlacement(
            center: CGPoint(x: 0.37, y: 0.62), widthFraction: 0.26,
            heightFraction: 0.20, opacity: 0.6)), forKey: option6 + "placement.friend")
        defaults.set(try JSONEncoder().encode(BoundLandscapeViewPlacement()), forKey: option6 + "placement.reference")

        let safe = CGRect(x: 24, y: 12, width: 952, height: 576)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let model = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        model.useOption(.option6)
        model.updateLayout(canvas: safe, occupied: [], menuFrame: .zero, boundFrame: .zero,
                           defaults: [.friend: CGRect(x: 650, y: 90, width: 240, height: 160),
                                      .dex: CGRect(x: 350, y: 112, width: 300, height: 360)],
                           keyboardHeight: 0, screenBounds: screen)

        let oldCanvas = safe.insetBy(dx: 4, dy: 4)
        let oldWidth = oldCanvas.width * 0.26
        let oldHeight = oldCanvas.height * 0.20
        let width = min(oldWidth, oldHeight * 1.5)
        let height = width / 1.5
        let oldCenter = CGPoint(x: oldCanvas.minX + oldCanvas.width * 0.37,
                                y: oldCanvas.minY + oldCanvas.height * 0.62)
        let expected = CGRect(x: oldCenter.x - width / 2, y: oldCenter.y - height / 2,
                              width: width, height: height)
        XCTAssertEqual(model.layout.friend.minX, expected.minX, accuracy: 0.01)
        XCTAssertEqual(model.layout.friend.minY, expected.minY, accuracy: 0.01)
        XCTAssertEqual(model.layout.friend.width, expected.width, accuracy: 0.01)
        XCTAssertEqual(model.layout.friend.height, expected.height, accuracy: 0.01)

        model.useOption(.option7)
        model.updateLayout(canvas: safe, occupied: [], menuFrame: .zero, boundFrame: .zero,
                           defaults: [.friend: CGRect(x: 650, y: 90, width: 240, height: 160),
                                      .dex: CGRect(x: 350, y: 112, width: 300, height: 360)],
                           keyboardHeight: 0, screenBounds: screen)
        XCTAssertEqual(model.layout.friend, expected,
                       "Option 7 copies the screen-canvas basis and does not migrate it a second time.")

        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option7)
        restored.updateLayout(canvas: safe, occupied: [], menuFrame: .zero, boundFrame: .zero,
                              defaults: [.friend: CGRect(x: 650, y: 90, width: 240, height: 160),
                                         .dex: CGRect(x: 350, y: 112, width: 300, height: 360)],
                              keyboardHeight: 0, screenBounds: screen)
        XCTAssertEqual(restored.layout.friend, expected,
                       "A later launch preserves the migrated physical frame.")
    }

    func testExplicitMultiviewLayerAllowsReferenceToStayOverButtons() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses, .types])
        model.setActive(true)
        model.useOption(.option6)
        arrangeLayout(model)
        let menu = model.layout.doneButton
        XCTAssertFalse(model.layout.reference.intersects(menu), "The default solver keeps the reference clear of controls.")

        model.arrange()
        model.setAboveButtons(false, for: .dex)
        let safe = model.layout.canvas
        let delta = CGSize(width: menu.midX - model.layout.reference.midX,
                           height: menu.midY - model.layout.reference.midY)
        model.move(content: .dex, translation: delta, ended: true)
        XCTAssertTrue(model.layout.reference.intersects(menu),
                      "After choosing a layer, the panel may overlap the requested button area.")
        model.finish(save: true)

        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.useOption(.option6)
        restored.setActive(true)
        arrangeLayout(restored)
        restored.arrange()
        XCTAssertTrue(restored.layout.reference.intersects(menu), "Explicit overlap survives a later layout pass.")
        XCTAssertFalse(restored.aboveButtons(for: .dex))
        XCTAssertGreaterThanOrEqual(restored.layout.reference.minX, safe.minX)
        XCTAssertLessThanOrEqual(restored.layout.reference.maxX, safe.maxX + 0.001)
    }

    func testControllerModeTwoUsesIndependentNamespaceAndSuppliedSideRailFrames() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses, .types])
        model.setActive(true)

        model.useOption(.option6, controllerModeEnabled: true, controllerModeLayout: .mode1)
        arrangeLayout(model)
        model.arrange()
        model.move(content: .friend, translation: CGSize(width: -340, height: 70), ended: true)
        model.finish(save: true)
        let modeOneFriend = model.placement(for: .friend)

        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let safe = CGRect(x: 20, y: 12, width: 960, height: 576)
        let menu = CGRect(x: 900, y: 20, width: 80, height: 70)
        let bound = CGRect(x: 900, y: 500, width: 80, height: 70)
        let friendDefault = CGRect(x: 42, y: 82, width: 230, height: 154)
        let referenceDefault = CGRect(x: 600, y: 110, width: 300, height: 360)
        let friendButton = CGRect(x: 82, y: 430, width: 48, height: 48)
        let viewsButton = CGRect(x: 142, y: 430, width: 48, height: 48)

        model.useOption(.option6, controllerModeEnabled: true, controllerModeLayout: .mode2)
        XCTAssertEqual(model.controllerModeLayout, .mode2)
        XCTAssertNotEqual(model.placement(for: .friend), modeOneFriend,
                          "Mode 2 must not inherit a saved Mode 1 Friend position.")
        model.updateLayout(canvas: safe, occupied: [], menuFrame: menu, boundFrame: bound,
                           defaults: [.friend: friendDefault, .dex: referenceDefault,
                                      .bosses: referenceDefault, .types: referenceDefault],
                           keyboardHeight: 0, screenBounds: screen,
                           friendButtonFrame: friendButton, viewsButtonFrame: viewsButton)
        XCTAssertEqual(model.layout.friend.midX, friendDefault.midX, accuracy: 0.1,
                       "Mode 2 should honor the supplied Friend position in the left side rail.")
        XCTAssertEqual(model.layout.friendButton, friendButton)
        XCTAssertEqual(model.layout.viewsButton, viewsButton)
        XCTAssertGreaterThan(model.layout.reference.midX, model.layout.friend.midX,
                             "Mode 2 should place the game companion to the right of Friend.")

        model.useOption(.option6, controllerModeEnabled: false, controllerModeLayout: .mode2)
        XCTAssertEqual(model.controllerModeLayout, .mode1,
                       "A remembered Mode 2 preference has no effect while Controller Mode is off.")
        XCTAssertEqual(model.placement(for: .friend), BoundLandscapeViewPlacement(
            center: CGPoint(x: 0.75, y: 0.3), widthFraction: 0.28, heightFraction: 0.187, opacity: 1),
                        "Controller Mode off keeps its existing independent defaults.")

        let modeTwoFriendKey = namespace + ".controller-mode2.option6.placement.friend"
        XCTAssertNil(defaults.data(forKey: modeTwoFriendKey),
                     "Mode 2 should not persist the Mode 1 Friend placement under its own namespace.")
        XCTAssertNotNil(defaults.data(forKey: namespace + ".controller-mode.option6.placement.friend"))
    }

    func testControllerModeTwoDefaultFriendTracksSafeColumnRotationUntilManuallyMoved() throws {
        let (model, defaults, namespace) = try makeModel()
        defer { defaults.removePersistentDomain(forName: namespace) }
        model.setContents([.dex, .bosses, .types])
        model.setActive(true)
        model.useOption(.option6, controllerModeEnabled: true, controllerModeLayout: .mode2)

        let bounds = CGRect(x: 0, y: 0, width: 852, height: 393)
        let gameAspect = CGSize(width: 3, height: 2)
        func update(insets: UIEdgeInsets, model: BoundLandscapeArrangementModel) throws -> BoundControllerModeTwoGeometry {
            let geometry = try XCTUnwrap(BoundControllerModeTwoGeometry(bounds: bounds, safeArea: insets,
                                                                        gameAspect: gameAspect))
            let canvas = bounds.inset(by: insets)
            let reference = CGRect(x: geometry.game.minX + geometry.game.width * 0.58,
                                   y: geometry.game.minY + geometry.game.height * 0.15,
                                   width: geometry.game.width * 0.36,
                                   height: geometry.game.height * 0.68)
            model.updateLayout(canvas: canvas, occupied: [], menuFrame: geometry.menu,
                               boundFrame: geometry.views,
                               defaults: [.friend: geometry.friend, .dex: reference,
                                          .bosses: reference, .types: reference],
                               keyboardHeight: 0, screenBounds: bounds,
                               friendButtonFrame: geometry.friendButton, viewsButtonFrame: geometry.views)
            return geometry
        }

        let leftInsetGeometry = try update(insets: UIEdgeInsets(top: 0, left: 59, bottom: 0, right: 0), model: model)
        XCTAssertLessThanOrEqual(model.layout.friend.maxX, leftInsetGeometry.game.minX,
                                 "The fresh Friend default fits the left rail beside gameplay.")
        model.arrange()
        model.select(.friend) // Selecting without dragging must retain the automatic placement.
        model.setOpacity(0.72, for: .friend)
        model.setAboveButtons(false, for: .dex)
        model.finish(save: true)

        let rightInsetGeometry = try update(insets: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 59), model: model)
        XCTAssertLessThanOrEqual(model.layout.friend.maxX, rightInsetGeometry.game.minX,
                                 "An untouched saved default recomputes when the safe left column changes sides.")

        model.useOption(.option7, controllerModeEnabled: true, controllerModeLayout: .mode2)
        try update(insets: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 59), model: model)
        XCTAssertLessThanOrEqual(model.layout.friend.maxX, rightInsetGeometry.game.minX,
                                 "Option 7 inherits the automatic Friend placement behavior from Option 6.")

        let restored = BoundLandscapeArrangementModel(defaults: defaults, namespace: namespace)
        restored.setContents([.dex, .bosses, .types])
        restored.setActive(true)
        restored.useOption(.option7, controllerModeEnabled: true, controllerModeLayout: .mode2)
        try update(insets: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 59), model: restored)
        XCTAssertLessThanOrEqual(restored.layout.friend.maxX, rightInsetGeometry.game.minX,
                                 "The automatic placement marker survives relaunch.")

        restored.arrange()
        restored.select(.friend)
        restored.move(content: .friend, translation: CGSize(width: 24, height: 8), ended: true)
        restored.finish(save: true)
        let manuallyMoved = restored.layout.friend
        try update(insets: UIEdgeInsets(top: 0, left: 59, bottom: 0, right: 0), model: restored)
        XCTAssertEqual(restored.layout.friend, manuallyMoved,
                       "An explicit Friend move remains at its full-screen position after rotation.")
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
