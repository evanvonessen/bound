import XCTest
import UIKit
import SwiftUI
import DeltaCore
@testable import Delta

@MainActor
final class CompanionCycleButtonTests: XCTestCase {
    func testUIVersionAndViewOrderPersistWithoutChangingOptionOneOrBaseline() throws {
        let suite = "BoundUIVersion." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let version = BoundUIVersionPreferences(defaults: defaults)
        let preferences = BoundPiPPreferences(defaults: defaults)
        XCTAssertEqual(version.version, .option1)
        let original = BoundPiPContent.cycleOrder(experimentalFeaturesEnabled: true)
        preferences.setContentOrder([.dex, .bosses, .dex])
        XCTAssertEqual(preferences.orderedContents, [.dex, .bosses, .friend, .notes, .types])
        XCTAssertEqual(preferences.enabledContents(experimentalFeaturesEnabled: true), original)
        version.version = .option2
        XCTAssertEqual(version.effectiveVersion, .option1)
        BoundExperimentalFeaturesPreferences(defaults: defaults).isEnabled = true
        XCTAssertEqual(version.effectiveVersion, .option2)
        preferences.setEnabled(false, for: .bosses)
        let restarted = BoundPiPPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(restarted.uiVersion, .option2)
        XCTAssertEqual(restarted.enabledContents(experimentalFeaturesEnabled: true, uiVersion: restarted.uiVersion), [.dex, .friend, .notes, .types])
        XCTAssertEqual(restarted.enabledContents(experimentalFeaturesEnabled: false, uiVersion: .option2), [.friend, .notes, .types])
        BoundExperimentalFeaturesPreferences(defaults: defaults).isEnabled = false
        XCTAssertEqual(version.effectiveVersion, .option1)
        XCTAssertEqual(version.version, .option2)
        defaults.set(99, forKey: BoundUIVersionPreferences.key)
        XCTAssertEqual(version.version, .option1)
        defaults.set(["unknown", "notes", "notes"], forKey: "bound.delta.pip.v1.view-order")
        XCTAssertEqual(restarted.orderedContents, [.notes, .friend, .types, .bosses, .dex])
    }
    func testUIVersionSwitchingAndReorderingPreserveVisiblePanelAndGateShortcuts() throws {
        let suite = "BoundUIVersionState." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let version = BoundUIVersionPreferences(defaults: defaults)
        let preferences = BoundPiPPreferences(defaults: defaults)
        let state = BoundCompanionState(preferences: preferences, experimentalFeaturesEnabled: true)
        state.selected = 3
        XCTAssertEqual(state.content, .bosses)
        state.selectPanel(.dex)
        XCTAssertEqual(state.content, .bosses, "Option 1 does not expose the direct-selection action")
        version.version = .option2
        state.updateUIVersion()
        state.setContentOrder([.dex, .bosses, .friend, .types, .notes])
        XCTAssertEqual(state.content, .bosses)
        XCTAssertEqual(state.selected, 1)
        state.hidden = true
        state.selectPanel(.dex)
        XCTAssertEqual(state.content, .dex)
        XCTAssertFalse(state.hidden)
        state.setContentEnabled(false, for: .notes)
        state.selectPanel(.notes)
        XCTAssertEqual(state.content, .dex, "Disabled views cannot be selected through a stale menu")
        version.version = .option1
        state.updateUIVersion()
        XCTAssertEqual(state.content, .dex)
        XCTAssertEqual(state.availableContents, [.friend, .types, .bosses, .dex])
        state.updateExperimentalFeatures(false)
        XCTAssertEqual(state.availableContents, [.friend, .notes, .types])
        state.selectPanel(.dex)
        state.setContentOrder([.types, .friend])
        XCTAssertEqual(state.content, .friend)
        XCTAssertEqual(preferences.orderedContents, [.dex, .bosses, .friend, .types, .notes])
    }

    func testUIVersionTwoMenuKeepsTapCycleAndOnlyEnabledChoices() throws {
        let button = BoundCompanionCycleButton()
        var cycles = 0
        button.cycle = { cycles += 1 }
        button.configureViewMenu(contents: [.bosses, .friend], selected: .bosses, enabled: true)
        let menu = try XCTUnwrap(button.menu)
        let actions = menu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.map(\.title), ["Bosses", "Friend"])
        XCTAssertEqual(actions.map(\.state), [.on, .off])
        XCTAssertFalse(button.showsMenuAsPrimaryAction)
        button.sendActions(for: .touchDown)
        XCTAssertEqual(cycles, 1, "The tap activates as soon as the finger touches the button.")
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(cycles, 1, "Adding a long-press menu must preserve normal tap cycling")
        button.configureViewMenu(contents: [.friend, .notes, .types], selected: .friend, enabled: false)
        XCTAssertNil(button.menu)
        button.configureViewMenu(contents: [], selected: .friend, enabled: true)
        XCTAssertNil(button.menu)
    }

    func testDexAutomaticallyRefreshesMatchingSaveEventsOnMain() throws {
        let preferences = BoundExperimentalFeaturesPreferences()
        let wasEnabled = preferences.isEnabled
        let savedLayout = UserDefaults.standard.object(forKey: BoundReferenceLayoutPreferences.dexKey)
        let gameID = "RRDEX_AUTO_QA_" + UUID().uuidString
        let dexPreferences = BoundRRDexPreferences()
        defer {
            preferences.isEnabled = wasEnabled
            if let savedLayout { UserDefaults.standard.set(savedLayout, forKey: BoundReferenceLayoutPreferences.dexKey) }
            else { UserDefaults.standard.removeObject(forKey: BoundReferenceLayoutPreferences.dexKey) }
            UserDefaults.standard.removeObject(forKey: "bound.rrdex.choice.v1." + gameID)
        }
        preferences.isEnabled = true
        UserDefaults.standard.set(7, forKey: BoundReferenceLayoutPreferences.dexKey)
        var captureCount = 0
        var save = BoundRRDexSave(trainerID: 1, randomAbilities: false, randomLearnset: false)
        var expectedCapture: XCTestExpectation? = expectation(description: "Read current save on entry")
        let firstCapture = try XCTUnwrap(expectedCapture)
        let host = UIHostingController(rootView: BoundRRDexView(gameID: gameID, presentationChanged: { _ in }, currentSave: {
            XCTAssertTrue(Thread.isMainThread, "Emulator save callbacks must reach SwiftUI on main")
            captureCount += 1
            expectedCapture?.fulfill(); expectedCapture = nil
            return save
        }))
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.rootViewController)
        parent.addChild(host); parent.view.addSubview(host.view); host.didMove(toParent: parent)
        host.view.frame = CGRect(x: 0, y: 60, width: 393, height: 263)
        defer { host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent() }
        host.view.layoutIfNeeded()
        wait(for: [firstCapture], timeout: 5)
        XCTAssertEqual(dexPreferences.read(gameID: gameID).save, save)
        save = BoundRRDexSave(trainerID: 42, randomAbilities: true, randomLearnset: true)
        expectedCapture = expectation(description: "Refresh current save after worker callback")
        let refreshed = try XCTUnwrap(expectedCapture)
        DispatchQueue.global().async { BoundRRDexSaveRefreshEvent.post(gameID: gameID) }
        wait(for: [refreshed], timeout: 5)
        XCTAssertEqual(dexPreferences.read(gameID: gameID).save, save)
        XCTAssertEqual(captureCount, 2)
        let unrelated = expectation(description: "Other ROMs must not trigger a capture")
        unrelated.isInverted = true
        expectedCapture = unrelated
        BoundRRDexSaveRefreshEvent.post(gameID: "UNRELATED_ROM")
        wait(for: [unrelated], timeout: 0.2)
        XCTAssertEqual(captureCount, 2)
    }

    func testDexCardRendersAtPortraitAndLandscapePanelSizes() throws {
        let preferences = BoundExperimentalFeaturesPreferences()
        let wasEnabled = preferences.isEnabled
        preferences.isEnabled = true
        let savedLayout = UserDefaults.standard.object(forKey: BoundReferenceLayoutPreferences.dexKey)
        defer {
            preferences.isEnabled = wasEnabled
            if let savedLayout { UserDefaults.standard.set(savedLayout, forKey: BoundReferenceLayoutPreferences.dexKey) }
            else { UserDefaults.standard.removeObject(forKey: BoundReferenceLayoutPreferences.dexKey) }
        }
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.rootViewController)
        for layout in BoundReferenceLayout.allCases {
            UserDefaults.standard.set(layout.rawValue, forKey: BoundReferenceLayoutPreferences.dexKey)
            var sizes = [("island-portrait", CGSize(width: 393, height: 263)), ("portrait", CGSize(width: 390, height: 195)), ("compact-portrait", CGSize(width: 375, height: 100)), ("landscape", CGSize(width: 330, height: 275))]
            if layout.rawValue >= 6 { sizes.append(("narrow-portrait", CGSize(width: 320, height: 195))) }
            for (name, size) in sizes {
                let host = UIHostingController(rootView: BoundRRDexView(gameID: "RRDEX_RENDER_QA", floating: name == "landscape", portraitTopInset: name == "island-portrait" ? 59 : 0, presentationChanged: { _ in }))
                if layout.rawValue >= 8 { host.overrideUserInterfaceStyle = .light }
                host.safeAreaRegions = []
                parent.addChild(host); parent.view.addSubview(host.view); host.didMove(toParent: parent)
                host.view.frame = CGRect(origin: CGPoint(x: 0, y: 60), size: size)
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                host.view.layoutIfNeeded()
                func searchField(_ view: UIView) -> UITextField? {
                    if let field = view as? UITextField { return field }
                    return view.subviews.lazy.compactMap(searchField).first
                }
                if layout.rawValue < 4 {
                    let search = try XCTUnwrap(searchField(host.view))
                    XCTAssertGreaterThan(search.bounds.width, 150)
                    XCTAssertEqual(search.autocapitalizationType, .none)
                }
                let renderer = UIGraphicsImageRenderer(size: size)
                let snapshot = renderer.image { _ in host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) }
                XCTAssertGreaterThan(try XCTUnwrap(snapshot.pngData()).count, 5000)
                let attachment = XCTAttachment(image: snapshot)
                attachment.name = "RRDex-hosted-layout-\(layout.rawValue)-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
                if layout == .layout10 || layout == .layout11 || layout == .layout12, name == "island-portrait" {
                    try captureInlineMatchupScroll(in: host.view, size: size, layout: layout, name: "light")
                }
                if layout.rawValue >= 8 {
                    host.overrideUserInterfaceStyle = .dark
                    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    let darkSnapshot = renderer.image { _ in host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) }
                    let darkAttachment = XCTAttachment(image: darkSnapshot)
                    darkAttachment.name = "RRDex-hosted-layout-\(layout.rawValue)-\(name)-dark"; darkAttachment.lifetime = .keepAlways; add(darkAttachment)
                    if layout == .layout10 || layout == .layout11 || layout == .layout12, name == "island-portrait" {
                        try captureInlineMatchupScroll(in: host.view, size: size, layout: layout, name: "dark")
                    }
                }
                if name == "compact-portrait" { try checkCompactCardScrolls(in: host.view, size: size, name: "RRDex") }
                host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
            }
        }
    }
    func testBossCardRendersAtPortraitAndLandscapePanelSizes() throws {
        let preferences = BoundExperimentalFeaturesPreferences()
        let wasEnabled = preferences.isEnabled
        preferences.isEnabled = true
        let savedLayout = UserDefaults.standard.object(forKey: BoundReferenceLayoutPreferences.bossKey)
        defer {
            preferences.isEnabled = wasEnabled
            if let savedLayout { UserDefaults.standard.set(savedLayout, forKey: BoundReferenceLayoutPreferences.bossKey) }
            else { UserDefaults.standard.removeObject(forKey: BoundReferenceLayoutPreferences.bossKey) }
        }
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.rootViewController)
        var selectionKeys: [String] = []
        defer { selectionKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        for layout in BoundReferenceLayout.bossLayouts {
            UserDefaults.standard.set(layout.rawValue, forKey: BoundReferenceLayoutPreferences.bossKey)
            var sizes = [("island-portrait", CGSize(width: 393, height: 263)), ("portrait", CGSize(width: 390, height: 195)), ("compact-portrait", CGSize(width: 375, height: 100)), ("landscape", CGSize(width: 330, height: 275))]
            if layout.rawValue >= 6 { sizes.append(("narrow-portrait", CGSize(width: 320, height: 195))) }
            for (name, size) in sizes {
                let gameID = "BOSS_RENDER_QA_\(layout.rawValue)_\(name)"
                if layout.rawValue >= 7, name == "narrow-portrait",
                   let selection = try? JSONEncoder().encode(BoundBossGuideSelection(teamID: "johto-leaders-56", pokemonIndex: 0)) {
                    let key = "bound.boss-guide.selection.v1." + gameID
                    selectionKeys.append(key)
                    UserDefaults.standard.set(selection, forKey: key)
                }
                let host = UIHostingController(rootView: BoundBossGuideView(gameID: gameID, floating: name == "landscape", portraitTopInset: name == "island-portrait" ? 59 : 0, presentationChanged: { _ in }))
                if layout.rawValue >= 8 { host.overrideUserInterfaceStyle = .light }
                host.safeAreaRegions = []
                parent.addChild(host); parent.view.addSubview(host.view); host.didMove(toParent: parent)
                host.view.frame = CGRect(origin: CGPoint(x: 0, y: 60), size: size)
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                host.view.layoutIfNeeded()
                let renderer = UIGraphicsImageRenderer(size: size)
                let snapshot = renderer.image { _ in host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) }
                XCTAssertEqual(snapshot.size, size)
                XCTAssertGreaterThan(try XCTUnwrap(snapshot.pngData()).count, 5000)
                let attachment = XCTAttachment(image: snapshot)
                attachment.name = "Boss-guide-hosted-layout-\(layout.rawValue)-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
                if layout == .layout12, name == "island-portrait" {
                    try captureBossMatchupScroll(in: host.view, size: size, layout: layout, name: "light")
                }
                if layout.rawValue >= 8 {
                    host.overrideUserInterfaceStyle = .dark
                    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    let darkSnapshot = renderer.image { _ in host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true) }
                    let darkAttachment = XCTAttachment(image: darkSnapshot)
                    darkAttachment.name = "Boss-guide-hosted-layout-\(layout.rawValue)-\(name)-dark"; darkAttachment.lifetime = .keepAlways; add(darkAttachment)
                    if layout == .layout12, name == "island-portrait" {
                        try captureBossMatchupScroll(in: host.view, size: size, layout: layout, name: "dark")
                    }
                }
                if name == "compact-portrait" { try checkCompactCardScrolls(in: host.view, size: size, name: "Boss-guide") }
                if layout.rawValue >= 7, name == "narrow-portrait" {
                    let team = try XCTUnwrap(BoundBossCatalog.bundled?.team(id: "johto-leaders-56"))
                    XCTAssertEqual(team.pokemon.count, 6, "The narrow layout fixture should use a full six-member team.")
                    XCTAssertNil(team.levelCap, "Post-Surge Bugsy must retain its source data without an invented cap.")
                    try checkCompactCardScrolls(in: host.view, size: size, name: "Boss-guide-layout\(layout.rawValue)-narrow")
                }
                host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
            }
        }
    }

    func testBossLayout7ReferenceDataIncludesConditionalSpeedAndLevelContext() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        let falkner = try XCTUnwrap(catalog.team(id: "johto-leaders-4"))
        XCTAssertEqual(falkner.name, "Falkner")
        XCTAssertEqual(falkner.levelCap, 15)
        let flittle = try XCTUnwrap(falkner.pokemon.first { $0.species == "Flittle" })
        XCTAssertEqual(flittle.speed.map(\.label), ["SPEED STAT:", "1 S. BOOST:"])
        XCTAssertEqual(flittle.speed.map(\.value), ["30", "45"])

        let preSurgeBugsy = try XCTUnwrap(catalog.team(id: "johto-leaders-31"))
        XCTAssertEqual(preSurgeBugsy.name, "Bugsy")
        XCTAssertEqual(preSurgeBugsy.levelCap, 27)
        XCTAssertEqual(preSurgeBugsy.speedContext, "IF YOU'RE LEVEL 27")
        XCTAssertEqual(preSurgeBugsy.pokemon.first?.level, "Highest Lv -2")
        let postSurgeBugsy = try XCTUnwrap(catalog.team(id: "johto-leaders-56"))
        XCTAssertEqual(postSurgeBugsy.name, "Bugsy")
        XCTAssertNil(postSurgeBugsy.levelCap)
        XCTAssertEqual(postSurgeBugsy.speedContext, "IF YOU'RE LEVEL 44")
        XCTAssertEqual(postSurgeBugsy.pokemon.count, 6)
        XCTAssertEqual(postSurgeBugsy.pokemon.first?.level, "Highest Lv -2")
    }

    private func checkCompactCardScrolls(in view: UIView, size: CGSize, name: String) throws {
        func scrollingContent(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 1 { return scroll }
            return view.subviews.lazy.compactMap { scrollingContent(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollingContent(in: view), "A short portrait panel must scroll instead of shrinking or clipping its content")
        let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        view.layoutIfNeeded()
        XCTAssertGreaterThan(scroll.contentOffset.y, 0)
        let snapshot = UIGraphicsImageRenderer(size: size).image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = "\(name)-hosted-compact-portrait-footer"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func captureInlineMatchupScroll(in view: UIView, size: CGSize, layout: BoundReferenceLayout, name: String) throws {
        func scrollingContent(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 1 { return scroll }
            return view.subviews.lazy.compactMap { scrollingContent(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollingContent(in: view), "The inline learnset needs a scroll view.")
        let originalOffset = scroll.contentOffset
        defer { scroll.setContentOffset(originalOffset, animated: false) }
        let targetOffset = min(250, max(0, scroll.contentSize.height - scroll.bounds.height))
        scroll.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        view.layoutIfNeeded()
        let snapshot = UIGraphicsImageRenderer(size: size).image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = "RRDex-layout\(layout.rawValue)-matchups-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func captureBossMatchupScroll(in view: UIView, size: CGSize, layout: BoundReferenceLayout, name: String) throws {
        func scrollingContent(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 1 { return scroll }
            return view.subviews.lazy.compactMap { scrollingContent(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollingContent(in: view), "The Boss View matchup summary needs a scroll view.")
        let originalOffset = scroll.contentOffset
        defer { scroll.setContentOffset(originalOffset, animated: false) }
        let targetOffset = min(250, max(0, scroll.contentSize.height - scroll.bounds.height))
        scroll.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        view.layoutIfNeeded()
        let snapshot = UIGraphicsImageRenderer(size: size).image { _ in
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = "Boss-guide-layout\(layout.rawValue)-matchups-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDexSearchDisablesCorrectionCapitalizationSpellingAndSmartEdits() {
        let field = BoundRRDexSearchField.makeTextField()
        XCTAssertEqual(field.autocapitalizationType, .none)
        XCTAssertEqual(field.autocorrectionType, .no)
        XCTAssertEqual(field.spellCheckingType, .no)
        XCTAssertEqual(field.smartQuotesType, .no)
        XCTAssertEqual(field.smartDashesType, .no)
        XCTAssertEqual(field.smartInsertDeleteType, .no)
        XCTAssertEqual(field.inlinePredictionType, .no)
    }

    func testSplitButtonAssignmentsDefaultIndependentlyAndPersistEmptySets() throws {
        let suite = "BoundSplitButtonAssignments." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)

        XCTAssertEqual(preferences.assignedContents(for: 0), [.friend])
        XCTAssertEqual(preferences.assignedContents(for: 1), [.bosses])
        XCTAssertEqual(preferences.assignedContents(for: 2), [.types])

        preferences.setAssignedContents([.dex, .friend, .notes], for: 0)
        preferences.setAssignedContents([], for: 1)
        preferences.setAssignedContents([.types, .bosses], for: 2)

        let relaunched = BoundPiPPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(relaunched.assignedContents(for: 0), [.friend, .notes, .dex])
        XCTAssertEqual(relaunched.assignedContents(for: 1), [])
        XCTAssertEqual(relaunched.assignedContents(for: 2), [.types, .bosses])
    }
    func testRemovedButtonOptionFourMigratesToSplitButtonOptionThree() throws {
        let suite = "BoundButtonTypeMigration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(4, forKey: BoundCompanionButtonPreferences.key)

        XCTAssertEqual(BoundCompanionButtonPreferences(defaults: defaults).buttonType, .option3)
    }

    func testCompanionButtonTypePersistsAndExperimentalGateKeepsOriginalEffectiveStyle() throws {
        let suite = "BoundCompanionButtonType." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = BoundCompanionButtonPreferences(defaults: defaults)
        XCTAssertEqual(preferences.buttonType, .option1, "Existing installs keep the original round button by default.")
        XCTAssertEqual(preferences.effectiveButtonType, .option1)

        preferences.buttonType = .option3
        XCTAssertEqual(preferences.buttonType, .option3)
        XCTAssertEqual(BoundCompanionButtonPreferences(defaults: defaults).buttonType, .option3,
                       "A newly created preferences object reads the saved choice.")
        XCTAssertEqual(preferences.effectiveButtonType, .option1,
                       "Experimental button styles remain inactive while experiments are off.")

        BoundExperimentalFeaturesPreferences(defaults: defaults).isEnabled = true
        XCTAssertEqual(preferences.effectiveButtonType, .option3)
        BoundExperimentalFeaturesPreferences(defaults: defaults).isEnabled = false
        XCTAssertEqual(preferences.buttonType, .option3, "Gating does not erase the user's saved preference.")
        XCTAssertEqual(preferences.effectiveButtonType, .option1)

        defaults.set(99, forKey: BoundCompanionButtonPreferences.key)
        XCTAssertEqual(preferences.buttonType, .option1, "Unknown stored values safely fall back to Option 1.")
    }

    func testBossLayout10NatureEffectsCoverBundledNaturesAndFallbacks() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        let natures = Set(catalog.teams.flatMap { $0.pokemon.map(\.nature) })
        XCTAssertTrue(natures.contains("Random"), "The source includes an unknown/random nature that must not get invented modifiers.")
        for nature in natures where nature.caseInsensitiveCompare("Random") != .orderedSame {
            XCTAssertTrue(BoundBossNatureDescription.label(for: nature).hasPrefix("Nature · \(nature) · "))
            XCTAssertFalse(BoundBossNatureDescription.label(for: nature).contains("unavailable"), nature)
        }
        XCTAssertEqual(BoundBossNatureDescription.label(for: "Adamant"), "Nature · Adamant · +10% Attack, −10% Sp. Atk")
        XCTAssertEqual(BoundBossNatureDescription.label(for: "Jolly"), "Nature · Jolly · +10% Speed, −10% Sp. Atk")
        XCTAssertEqual(BoundBossNatureDescription.label(for: "Modest"), "Nature · Modest · +10% Sp. Atk, −10% Attack")
        XCTAssertEqual(BoundBossNatureDescription.label(for: "Hardy"), "Nature · Hardy · no stat changes")
        XCTAssertEqual(BoundBossNatureDescription.label(for: "  adamant  "), "Nature · adamant · +10% Attack, −10% Sp. Atk")
        XCTAssertEqual(BoundBossNatureDescription.label(for: "Random"), "Nature · Random · nature effects unavailable")
        XCTAssertEqual(BoundBossNatureDescription.label(for: "Unlisted"), "Nature · Unlisted · nature effects unavailable")
        XCTAssertEqual(BoundBossNatureDescription.label(for: ""), "Nature · Unknown · nature effects unavailable")
    }
    func testExperimentalBossCycleFallsBackImmediatelyWhenDisabled() throws {
        let suite = "BoundBaselineCycle." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = BoundCompanionState(preferences: BoundPiPPreferences(defaults: defaults), experimentalFeaturesEnabled: false)
        for expected in [BoundPiPContent.notes, .types, .friend, .notes, .types, .friend] {
            state.advancePanel()
            XCTAssertEqual(state.content, expected)
        }
        state.updateExperimentalFeatures(true)
        for expected in [BoundPiPContent.notes, .types, .bosses, .dex] {
            state.advancePanel()
            XCTAssertEqual(state.content, expected)
        }
        state.hidden = true
        state.updateExperimentalFeatures(false)
        XCTAssertEqual(state.content, .friend)
        XCTAssertEqual(state.selected, 0)
        XCTAssertFalse(state.hidden)
        XCTAssertEqual(state.availableContents, [.friend, .notes, .types])
        state.selected = 3
        XCTAssertEqual(state.content, .friend, "A stale experimental selection must not expose the guide")
    }
    func testEnabledViewsPreserveSelectionAndHandleNoneAcrossRestartAndExperimentalGate() throws {
        let suite = "BoundCompanionCycle." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        let state = BoundCompanionState(preferences: preferences, experimentalFeaturesEnabled: true)
        state.selected = 3
        XCTAssertEqual(state.content, .bosses)
        var selectionChanges = 0
        state.selectionChanged = { selectionChanges += 1 }
        state.setContentEnabled(false, for: .notes)
        state.setContentEnabled(false, for: .types)
        state.setContentEnabled(false, for: .dex)
        XCTAssertEqual(state.content, .bosses, "Removing earlier entries must preserve the visible view")
        XCTAssertEqual(state.availableContents, [.friend, .bosses])
        XCTAssertEqual(selectionChanges, 0)
        for expected in [BoundPiPContent.friend, .bosses, .friend, .bosses] {
            state.advancePanel()
            XCTAssertEqual(state.content, expected)
        }
        state.setContentEnabled(false, for: .bosses)
        XCTAssertEqual(state.content, .friend)
        XCTAssertEqual(selectionChanges, 1, "Removing the visible view cancels its active interactions")
        state.setContentEnabled(false, for: .friend)
        XCTAssertTrue(state.availableContents.isEmpty)
        state.advancePanel() // All off must never divide by zero or expose Friend.
        state.landscape = true
        XCTAssertFalse(BoundCompanionCoordinator(state: state).allowsOpacityGesture)

        let restarted = BoundCompanionState(preferences: BoundPiPPreferences(defaults: defaults), experimentalFeaturesEnabled: true)
        XCTAssertTrue(restarted.availableContents.isEmpty)
        restarted.updateExperimentalFeatures(false)
        XCTAssertEqual(restarted.availableContents, [.friend, .notes, .types])
        restarted.setContentEnabled(true, for: .bosses)
        XCTAssertFalse(preferences.isEnabled(.bosses), "The experimental settings action is gated too")
        restarted.updateExperimentalFeatures(true)
        XCTAssertTrue(restarted.availableContents.isEmpty)
        restarted.setContentEnabled(true, for: .bosses)
        XCTAssertEqual(restarted.content, .bosses)
        restarted.advancePanel()
        XCTAssertEqual(restarted.content, .bosses, "One enabled view stays selected")
    }
    func testAssignedButtonsCycleIndependentlyRestoreWhenHiddenAndRespectExperimentGate() throws {
        let suite = "BoundAssignedButtons." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.buttonType = .option3
        XCTAssertEqual(preferences.assignedContents(for: 0), [.friend])
        XCTAssertEqual(preferences.assignedContents(for: 1), [.bosses])
        XCTAssertEqual(preferences.assignedContents(for: 2), [.types])

        let state = BoundCompanionState(preferences: preferences, experimentalFeaturesEnabled: true)
        XCTAssertTrue(state.usesAssignedButtons)
        state.setAssigned(true, content: .notes, for: 0)
        state.setAssigned(true, content: .dex, for: 1)
        XCTAssertEqual(preferences.assignedContents(for: 0), [.friend, .notes])
        XCTAssertEqual(preferences.assignedContents(for: 1), [.bosses, .dex])
        state.advanceButton(0)
        XCTAssertEqual(state.content, .notes)
        state.advanceButton(1)
        XCTAssertEqual(state.content, .bosses)
        state.advanceButton(0)
        XCTAssertEqual(state.content, .friend)

        state.hidden = true
        state.advanceButton(1)
        XCTAssertEqual(state.content, .bosses, "A button press restores the view assigned to that button.")
        XCTAssertFalse(state.hidden)

        state.updateExperimentalFeatures(false)
        XCTAssertFalse(state.usesAssignedButtons)
        let gatedContent = state.content
        state.advanceButton(1)
        XCTAssertEqual(state.content, gatedContent, "Assigned-button actions stay gated when experiments are off.")
        state.setAssigned(true, content: .types, for: 1)
        XCTAssertEqual(preferences.assignedContents(for: 1), [.bosses, .dex],
                       "The settings action cannot change assignments while experiments are off.")

        state.updateExperimentalFeatures(true)
        XCTAssertTrue(state.usesAssignedButtons)
        state.hidden = true
        state.advanceButton(1)
        XCTAssertEqual(state.content, .bosses)
        XCTAssertFalse(state.hidden)
    }

    func testPortraitMirrorKeepsDefaultAndAvoidsMovedInput() throws {
        let canvas = CGRect(x: 0, y: 0, width: 390, height: 800)
        let menu = CGRect(x: 20, y: 740, width: 20, height: 20)
        let button = BoundCompanionCycleButton()
        button.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                         content: .friend, canvas: canvas, occupied: [menu])
        XCTAssertEqual(button.frame.midX, 360, accuracy: 0.001)
        XCTAssertEqual(button.frame.midY, 750, accuracy: 0.001)
        let movedA = button.frame.insetBy(dx: -4, dy: -4)
        button.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                         content: .notes, canvas: canvas, occupied: [menu, movedA])
        XCTAssertFalse(button.isHidden); XCTAssertTrue(canvas.contains(button.frame))
        XCTAssertFalse(button.frame.intersects(menu)); XCTAssertFalse(button.frame.intersects(movedA))
        XCTAssertEqual(button.accessibilityValue, "Notes")
    }
    func testLandscapeChecksCollisionAfterEdgeClamping() throws {
        let canvas = CGRect(x: 50, y: 0, width: 700, height: 350)
        let menu = CGRect(x: 680, y: 8, width: 60, height: 30)
        let blocked = CGRect(x: 610, y: 0, width: 140, height: 70)
        let button = BoundCompanionCycleButton()
        button.configure(menuFrame: menu, controllerFrame: canvas, landscape: true, minimal: false,
                         content: .types, canvas: canvas, occupied: [blocked])
        XCTAssertFalse(button.isHidden); XCTAssertTrue(canvas.contains(button.frame))
        XCTAssertFalse(button.frame.intersects(blocked)); XCTAssertEqual(button.accessibilityValue, "Types")
    }
    func testPortraitButtonTypesKeepNativeGBAInputsClearAtCommonWidths() throws {
        let oldLayout = BoundAppearancePreferences().screenLayout
        let oldFeedback = Settings.isButtonHapticFeedbackEnabled
        defer {
            BoundAppearancePreferences().screenLayout = oldLayout
            Settings.isButtonHapticFeedbackEnabled = oldFeedback
        }
        BoundAppearancePreferences().screenLayout = .bound
        Settings.isButtonHapticFeedbackEnabled = true
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let cases: [(CGSize, UIEdgeInsets)] = [
            (CGSize(width: 320, height: 568), UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)),
            (CGSize(width: 390, height: 844), UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)),
            (CGSize(width: 402, height: 874), UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
            (CGSize(width: 430, height: 932), UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
        ]
        let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .edgeToEdge, orientation: .portrait)
        for (screen, insets) in cases {
            let aspect = try XCTUnwrap(base.aspectRatio(for: traits))
            let size = CGSize(width: screen.width, height: screen.width * aspect.height / aspect.width)
            let controller = CGRect(x: 0, y: screen.height - size.height, width: size.width, height: size.height)
            let stock = BoundStockControllerSkin(base: base, canvasSize: size)
            let items = try XCTUnwrap(stock.items(for: traits))
            let menu = try XCTUnwrap(items.first { $0.inputs.allInputs.contains { $0.stringValue == "menu" } })
            let select = try XCTUnwrap(items.first { $0.inputs.allInputs.contains { $0.stringValue == "select" } })
            let selectArtwork = try XCTUnwrap(stock.image(for: select, traits: traits, preferredSize: .large)?.0)
            let scale = CGAffineTransform(scaleX: size.width, y: size.height)
            let menuFrame = menu.frame.applying(scale).offsetBy(dx: controller.minX, dy: controller.minY)
            let menuHitSize = menu.extendedFrame.applying(scale).size
            let occupied = items.map { $0.extendedFrame.applying(scale).offsetBy(dx: controller.minX, dy: controller.minY) }
            let canvas = CGRect(origin: .zero, size: screen).inset(by: insets)
            var silhouettes: Set<String> = []
            for type in BoundCompanionButtonType.allCases {
                let button = BoundCompanionCycleButton()
                button.configure(menuFrame: menuFrame, controllerFrame: controller, landscape: false,
                    minimal: false, content: .friend, canvas: canvas, occupied: occupied,
                    menuHitSize: menuHitSize, boundPortrait: true, selectArtwork: selectArtwork,
                    buttonType: type)
                if type == .option3 {
                    button.configureSegments(contents: [[.friend], [.bosses], [.types]], selected: .friend)
                    button.layoutIfNeeded()
                }
                XCTAssertFalse(button.isHidden, "\(type.title) has a clear placement at width \(Int(screen.width)).")
                XCTAssertTrue(canvas.contains(button.frame))
                XCTAssertGreaterThanOrEqual(button.frame.width, 44)
                XCTAssertGreaterThanOrEqual(button.frame.height, 44)
                XCTAssertGreaterThan(button.frame.midX, screen.width * 0.75,
                                     "The button stays in the lower-right area shown in the reference.")
                XCTAssertGreaterThanOrEqual(button.frame.maxY, menuFrame.maxY)
                XCTAssertFalse(occupied.contains { $0.intersects(button.frame) },
                               "\(type.title) cannot cover a native GBA input at width \(Int(screen.width)).")
                let splitMarker = type == .option3 ? "/split3" : ""
                silhouettes.insert(String(format: "%.1f×%.1f", button.artworkFrame.width, button.artworkFrame.height) + splitMarker)

                var feedback = 0, cycles = 0, segmentActivations = 0
                button.buttonFeedback = { feedback += 1 }
                button.cycle = { cycles += 1 }
                button.activateSegment = { _ in segmentActivations += 1 }
                let actionButton = type == .option3 ? try XCTUnwrap(button.segmentButtons.first) : button
                actionButton.buttonFeedback = { feedback += 1 }
                actionButton.sendActions(for: .touchDown)
                XCTAssertEqual(feedback, 1)
                XCTAssertEqual(cycles, type == .option3 ? 0 : 1)
                XCTAssertEqual(segmentActivations, type == .option3 ? 1 : 0,
                    "A \(type.title) press activates on first contact.")
                actionButton.sendActions(for: .touchCancel)
                XCTAssertEqual(feedback, 1)
                XCTAssertEqual(cycles, type == .option3 ? 0 : 1)
                XCTAssertEqual(segmentActivations, type == .option3 ? 1 : 0,
                    "Cancelling \(type.title) never advances a companion view.")
                actionButton.sendActions(for: .touchDown)
                actionButton.sendActions(for: .touchUpInside)
                XCTAssertEqual(feedback, 2)
                XCTAssertEqual(cycles, type == .option3 ? 0 : 2)
                XCTAssertEqual(segmentActivations, type == .option3 ? 2 : 0,
                    "A completed \(type.title) tap retains one feedback and cycle action.")
            }
            XCTAssertEqual(silhouettes.count, BoundCompanionButtonType.allCases.count,
                           "All available styles render distinct shapes at width \(Int(screen.width)).")
        }
    }

    func testNoClearSpaceDoesNotStealNativeInputsAndRecoversAfterReset() {
        let canvas = CGRect(x: 0, y: 0, width: 200, height: 100)
        let button = BoundCompanionCycleButton()
        let menu = CGRect(x: 10, y: 10, width: 20, height: 20)
        button.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                         content: .friend, canvas: canvas, occupied: [canvas])
        XCTAssertTrue(button.isHidden); XCTAssertFalse(button.isUserInteractionEnabled); XCTAssertEqual(button.frame, .zero)
        button.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                         content: .friend, canvas: canvas, occupied: [menu])
        XCTAssertFalse(button.isHidden); XCTAssertTrue(button.isUserInteractionEnabled)
    }
    func testBoundCycleUsesOneNativeFeedbackAndOneCyclePerCompletedTap() {
        let oldLayout = BoundAppearancePreferences().screenLayout
        let oldFeedback = Settings.isButtonHapticFeedbackEnabled
        defer { BoundAppearancePreferences().screenLayout = oldLayout; Settings.isButtonHapticFeedbackEnabled = oldFeedback }
        for landscape in [false, true] {
            let button = BoundCompanionCycleButton()
            let canvas = CGRect(x: 0, y: 0, width: 844, height: 390)
            button.configure(menuFrame: CGRect(x: 20, y: 40, width: 73, height: 26), controllerFrame: canvas,
                landscape: landscape, minimal: false, content: .friend, canvas: canvas, occupied: [])
            var feedback = 0, cycles = 0
            button.buttonFeedback = { feedback += 1 }
            button.cycle = { cycles += 1 }
            BoundAppearancePreferences().screenLayout = .bound
            Settings.isButtonHapticFeedbackEnabled = true
            button.sendActions(for: .touchDown)
            XCTAssertEqual(feedback, 1)
            XCTAssertEqual(cycles, 1)
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(feedback, 1)
            XCTAssertEqual(cycles, 1)
            button.sendActions(for: .touchCancel)
            button.sendActions(for: .touchUpOutside)
            XCTAssertEqual(feedback, 1)
            XCTAssertEqual(cycles, 1)
            Settings.isButtonHapticFeedbackEnabled = false
            button.sendActions(for: .touchDown)
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(feedback, 1)
            XCTAssertEqual(cycles, 2)
            BoundAppearancePreferences().screenLayout = .delta
            // Build 13's simplified presentation retains the saved choice but
            // still uses Bound, including its existing native button feedback.
            XCTAssertEqual(BoundAppearancePreferences().effectiveScreenLayout, .bound)
            Settings.isButtonHapticFeedbackEnabled = true
            button.sendActions(for: .touchDown)
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(feedback, 2)
            XCTAssertEqual(cycles, 3)
            BoundAppearancePreferences().screenLayout = .bound
            button.isEnabled = false
            button.sendActions(for: .touchDown)
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(feedback, 2)
            XCTAssertEqual(cycles, 3)
        }
    }

    func testBoundPortraitMaterialPressMatchesNativeDepthAndCancelNeverCycles() {
        let originalLayout = BoundAppearancePreferences().screenLayout
        let originalFeedback = Settings.isButtonHapticFeedbackEnabled
        defer { BoundAppearancePreferences().screenLayout = originalLayout; Settings.isButtonHapticFeedbackEnabled = originalFeedback }
        BoundAppearancePreferences().screenLayout = .bound
        Settings.isButtonHapticFeedbackEnabled = true
        let material = UIGraphicsImageRenderer(size: CGSize(width: 17, height: 17)).image { _ in
            UIColor.lightGray.setFill(); UIBezierPath(rect: CGRect(x: 0, y: 0, width: 17, height: 17)).fill()
        }
        let button = BoundCompanionCycleButton()
        button.configure(menuFrame: CGRect(x: 20, y: 200, width: 17, height: 17),
            controllerFrame: CGRect(x: 0, y: 0, width: 390, height: 300), landscape: false,
            minimal: false, content: .friend, canvas: CGRect(x: 0, y: 0, width: 390, height: 300), occupied: [], boundPortrait: true, selectArtwork: material)
        var cycles = 0, feedback = 0
        button.cycle = { cycles += 1 }; button.buttonFeedback = { feedback += 1 }
        let hit = button.frame, normal = button.materialFrame
        button.sendActions(for: .touchDown)
        XCTAssertTrue(button.isHighlighted)
        XCTAssertEqual(button.materialFrame.width, normal.width-4, accuracy: 0.001)
        XCTAssertEqual(button.materialFrame.height, normal.height-4, accuracy: 0.001)
        XCTAssertEqual(button.frame, hit)
        XCTAssertEqual(feedback, 1); XCTAssertEqual(cycles, 1)
        button.sendActions(for: .touchCancel)
        XCTAssertFalse(button.isHighlighted); XCTAssertEqual(button.materialFrame, normal)
        XCTAssertEqual(feedback, 1); XCTAssertEqual(cycles, 1)
        button.sendActions(for: .touchDown); button.sendActions(for: .touchUpInside)
        XCTAssertFalse(button.isHighlighted); XCTAssertEqual(button.materialFrame, normal)
        XCTAssertEqual(feedback, 2); XCTAssertEqual(cycles, 2)
    }

    func testSplitOptionThreeUsesOptionTwoFootprintAndActivatesIndependentSegmentsOnTouchDown() {
        let canvas = CGRect(x: 0, y: 0, width: 390, height: 844)
        let menu = CGRect(x: 10, y: 700, width: 20, height: 20)
        let option2 = BoundCompanionCycleButton()
        option2.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                          content: .friend, canvas: canvas, occupied: [menu], boundPortrait: true,
                          buttonType: .option2)
        let option3 = BoundCompanionCycleButton()
        option3.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                          content: .friend, canvas: canvas, occupied: [menu], boundPortrait: true,
                          buttonType: .option3)
        XCTAssertEqual(option3.frame, option2.frame)
        option3.configureSegments(contents: [[.friend], [.bosses, .dex], [.types]], selected: .friend)
        option3.layoutIfNeeded()
        XCTAssertFalse(option3.isAccessibilityElement)
        XCTAssertEqual(option3.segmentButtons.count, 3)
        XCTAssertEqual(option3.segmentButtons.map(\.accessibilityIdentifier), [
            "bound.panel-cycle.1", "bound.panel-cycle.2", "bound.panel-cycle.3"
        ])
        XCTAssertEqual(option3.accessibilityElements?.count, 3,
                       "A split host explicitly exposes its three child buttons to accessibility.")
        XCTAssertEqual(option3.segmentButtons[0].frame.minY, 0, accuracy: 0.001)
        XCTAssertEqual(option3.segmentButtons[0].frame.height, option3.bounds.height / 3, accuracy: 0.001)
        XCTAssertEqual(option3.segmentButtons[1].frame.minY, option3.segmentButtons[0].frame.maxY, accuracy: 0.001)
        XCTAssertEqual(option3.segmentButtons[2].frame.maxY, option3.bounds.maxY, accuracy: 0.001)
        for segment in option3.segmentButtons {
            XCTAssertTrue(option3.hitTest(segment.center, with: nil) === segment,
                          "The host routes touches to each child button.")
        }
        var activated: [Int] = []
        option3.activateSegment = { activated.append($0) }
        for index in option3.segmentButtons.indices {
            let segment = option3.segmentButtons[index]
            segment.sendActions(for: .touchDown)
            XCTAssertEqual(activated, Array(0...index), "Segment \(index + 1) acts on touch-down.")
            segment.sendActions(for: .touchUpInside)
            XCTAssertEqual(activated, Array(0...index), "Release does not activate a segment twice.")
        }
    }

    func testSegmentConfigurationLeavesOtherStylesAndFailedGeometryIntact() {
        let canvas = CGRect(x: 0, y: 0, width: 390, height: 844)
        let menu = CGRect(x: 10, y: 700, width: 20, height: 20)
        for type in [BoundCompanionButtonType.option1, .option2] {
            let button = BoundCompanionCycleButton()
            button.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                             content: .friend, canvas: canvas, occupied: [menu], boundPortrait: true,
                             buttonType: type)
            button.configureSegments(contents: [[.friend], [.bosses], [.types]], selected: .friend)
            XCTAssertTrue(button.segmentButtons.isEmpty)
            XCTAssertTrue(button.isAccessibilityElement)
            XCTAssertTrue(button.isUserInteractionEnabled)
        }

        let unavailable = CGRect(x: 0, y: 0, width: 200, height: 100)
        let button = BoundCompanionCycleButton()
        button.configure(menuFrame: CGRect(x: 10, y: 10, width: 20, height: 20),
                         controllerFrame: unavailable, landscape: false, minimal: false,
                         content: .friend, canvas: unavailable, occupied: [unavailable], boundPortrait: true,
                         buttonType: .option3)
        button.configureSegments(contents: [[.friend], [.bosses], [.types]], selected: .friend)
        XCTAssertTrue(button.isHidden)
        XCTAssertFalse(button.isUserInteractionEnabled)
        XCTAssertEqual(button.frame, .zero)
    }

    func testMinimalCompanionArtworkFitsNarrowRightGutters() {
        for width: CGFloat in [44, 45, 47, 52.25, 106] {
            let gutter = CGRect(x: 500, y: 0, width: width, height: 200)
            let button = BoundCompanionCycleButton()
            button.configure(menuFrame: CGRect(x: 500, y: 10, width: min(48, width), height: 20),
                controllerFrame: CGRect(x: 0, y: 0, width: 700, height: 390), landscape: true,
                minimal: true, content: .types, canvas: CGRect(x: 0, y: 0, width: 700, height: 390),
                occupied: [], menuHitSize: CGSize(width: 106, height: 56), rightControlGutter: gutter)
            XCTAssertFalse(button.isHidden)
            XCTAssertTrue(gutter.contains(button.frame))
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertTrue(button.bounds.contains(button.artworkFrame))
            XCTAssertLessThanOrEqual(button.artworkFrame.width, width)
        }
    }

    func testBoundNotesDisablesCorrectionAndSpellingAndHonorsDisabledState() {
        for enabled in [true, false] {
            let host = UIHostingController(rootView: BoundNotesTextView(text: .constant("Existing note"), editing: .constant(false)).disabled(!enabled))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            func find(_ view: UIView) -> UITextView? {
                if let text = view as? UITextView { return text }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            guard let editor = find(host.view) else { XCTFail("Missing real Notes UITextView"); continue }
            XCTAssertEqual(editor.autocorrectionType, .no)
            XCTAssertEqual(editor.spellCheckingType, .no)
            XCTAssertEqual(editor.text, "Existing note")
            XCTAssertEqual(editor.isEditable, enabled)
            XCTAssertEqual(editor.isSelectable, enabled)
            XCTAssertEqual(editor.isUserInteractionEnabled, enabled)
            XCTAssertTrue(editor.adjustsFontForContentSizeCategory)
            window.isHidden = true
        }
    }

    func testUIVersion2ReferencePreviewsAreReadOnlyAndRenderSelectedLayouts() throws {
        let featurePreferences = BoundExperimentalFeaturesPreferences()
        let oldFeatures = featurePreferences.isEnabled
        let oldVersion = UserDefaults.standard.object(forKey: BoundUIVersionPreferences.key)
        let oldDexLayout = UserDefaults.standard.object(forKey: BoundReferenceLayoutPreferences.dexKey)
        let oldBossLayout = UserDefaults.standard.object(forKey: BoundReferenceLayoutPreferences.bossKey)
        let gameID = "BOUND_UIV2_PREVIEW_" + UUID().uuidString
        let dexPreferences = BoundRRDexPreferences()
        let dexChoice = BoundRRDexPreferences.Choice(speciesID: 25, save: nil)
        dexPreferences.write(dexChoice, gameID: gameID)
        let bossPreferences = BoundBossGuidePreferences()
        let bossCatalog = try XCTUnwrap(BoundBossCatalog.bundled)
        let bossSelection = BoundBossGuideSelection(teamID: bossCatalog.defaultTeam.id, pokemonIndex: 0)
        bossPreferences.write(bossSelection, gameID: gameID, catalog: bossCatalog)
        defer {
            featurePreferences.isEnabled = oldFeatures
            if let oldVersion { UserDefaults.standard.set(oldVersion, forKey: BoundUIVersionPreferences.key) }
            else { UserDefaults.standard.removeObject(forKey: BoundUIVersionPreferences.key) }
            if let oldDexLayout { UserDefaults.standard.set(oldDexLayout, forKey: BoundReferenceLayoutPreferences.dexKey) }
            else { UserDefaults.standard.removeObject(forKey: BoundReferenceLayoutPreferences.dexKey) }
            if let oldBossLayout { UserDefaults.standard.set(oldBossLayout, forKey: BoundReferenceLayoutPreferences.bossKey) }
            else { UserDefaults.standard.removeObject(forKey: BoundReferenceLayoutPreferences.bossKey) }
            UserDefaults.standard.removeObject(forKey: "bound.rrdex.choice.v1." + gameID)
            UserDefaults.standard.removeObject(forKey: "bound.boss-guide.selection.v1." + gameID)
        }
        featurePreferences.isEnabled = true
        UserDefaults.standard.set(BoundUIVersion.option2.rawValue, forKey: BoundUIVersionPreferences.key)
        UserDefaults.standard.set(BoundReferenceLayout.layout1.rawValue, forKey: BoundReferenceLayoutPreferences.dexKey)
        UserDefaults.standard.set(BoundReferenceLayout.layout1.rawValue, forKey: BoundReferenceLayoutPreferences.bossKey)
        let parent = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first?.rootViewController)

        var saveReads = 0
        let dexHost = UIHostingController(rootView: BoundRRDexView(gameID: gameID, previewLayout: .layout12,
            presentationChanged: { _ in }, currentSave: {
                saveReads += 1
                throw BoundRRDexSave.ImportError.currentGameUnavailable
            }))
        parent.addChild(dexHost); parent.view.addSubview(dexHost.view); dexHost.didMove(toParent: parent)
        dexHost.view.frame = CGRect(x: 0, y: 60, width: 393, height: 263)
        dexHost.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let dexImage = UIGraphicsImageRenderer(size: CGSize(width: 393, height: 263)).image { _ in
            dexHost.view.drawHierarchy(in: CGRect(x: 0, y: 0, width: 393, height: 263), afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(try XCTUnwrap(dexImage.pngData()).count, 5_000)
        let dexAttachment = XCTAttachment(image: dexImage)
        dexAttachment.name = "UI-Version-2-RRDex-preview"; dexAttachment.lifetime = .keepAlways; add(dexAttachment)
        XCTAssertEqual(saveReads, 0, "Layout previews must not inspect or refresh the active ROM save")
        XCTAssertEqual(dexPreferences.read(gameID: gameID), dexChoice)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: BoundReferenceLayoutPreferences.dexKey), BoundReferenceLayout.layout1.rawValue,
                       "Preview overrides must not persist layout selection")
        dexHost.willMove(toParent: nil); dexHost.view.removeFromSuperview(); dexHost.removeFromParent()

        let bossHost = UIHostingController(rootView: BoundBossGuideView(gameID: gameID, portraitTopInset: 59,
            previewLayout: .layout12, presentationChanged: { _ in }))
        bossHost.safeAreaRegions = []
        parent.addChild(bossHost); parent.view.addSubview(bossHost.view); bossHost.didMove(toParent: parent)
        for layout in [BoundReferenceLayout.layout1, .layout6, .layout12] {
            for height in [CGFloat(263), CGFloat(100)] {
                let size = CGSize(width: 393, height: height)
                bossHost.rootView = BoundBossGuideView(gameID: gameID, portraitTopInset: height > 100 ? 59 : 0,
                    previewLayout: layout, presentationChanged: { _ in })
                bossHost.view.frame = CGRect(x: 0, y: 60, width: size.width, height: size.height)
                bossHost.view.setNeedsLayout(); bossHost.view.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                let bossImage = UIGraphicsImageRenderer(size: size).image { _ in
                    bossHost.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
                }
                XCTAssertGreaterThan(try XCTUnwrap(bossImage.pngData()).count, 5_000)
                let bossAttachment = XCTAttachment(image: bossImage)
                bossAttachment.name = "UI-Version-2-Boss-layout-\(layout.rawValue)-height-\(Int(height))"
                bossAttachment.lifetime = .keepAlways; add(bossAttachment)
                if height == 100 {
                    try checkCompactCardScrolls(in: bossHost.view, size: size, name: "Boss-v2-layout-\(layout.rawValue)")
                }
            }
        }
        XCTAssertEqual(bossPreferences.read(gameID: gameID, catalog: bossCatalog), bossSelection)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: BoundReferenceLayoutPreferences.bossKey), BoundReferenceLayout.layout1.rawValue,
                       "Boss preview must not overwrite the saved layout")
        bossHost.willMove(toParent: nil); bossHost.view.removeFromSuperview(); bossHost.removeFromParent()
    }

}
