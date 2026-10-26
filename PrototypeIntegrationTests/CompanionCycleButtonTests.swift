import XCTest
import UIKit
import SwiftUI
import Combine
import DeltaCore
@testable import Delta

@MainActor
final class CompanionCycleButtonTests: XCTestCase {
    private func renderedButtonStrip(_ button: BoundCompanionCycleButton) -> UIImage {
        button.setNeedsLayout()
        button.layoutIfNeeded()
        button.setNeedsDisplay()
        return UIGraphicsImageRenderer(size: button.bounds.size).image { context in
            button.layer.render(in: context.cgContext)
        }
    }

    private func renderedPixels(_ image: UIImage) -> Data? {
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data else { return nil }
        return data as Data
    }

    func testReferenceCatalogStoreSharesConcurrentLoadAndPublishesOnce() async {
        let loadCounter = LockedCounter()
        let loaderThreads = LockedValues<Bool>()
        let completionRecorder = LockedValues<Bool>()
        let store = BoundReferenceCatalogStore {
            loadCounter.increment()
            loaderThreads.append(Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.05)
            return .init(dex: nil, bosses: nil, reference: nil)
        }
        let subscription = store.$hasFinishedLoading.dropFirst().sink { completionRecorder.append($0) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await store.loadIfNeeded() } }
        }
        await store.loadIfNeeded()
        XCTAssertEqual(loadCounter.value, 1)
        XCTAssertEqual(loaderThreads.values, [false], "Catalog decoding must run outside the main thread.")
        XCTAssertEqual(completionRecorder.values, [true], "Overlapping callers should publish the shared result only once.")
        XCTAssertTrue(store.hasFinishedLoading)
        withExtendedLifetime(subscription) {}
    }

    func testDecodedReferenceImageIsReusedFromBoundedCache() throws {
        let source = try XCTUnwrap(UIImage(systemName: "star.fill")?.pngData()?.base64EncodedString())
        let key = "cache-test-\(UUID().uuidString)"
        let cache = BoundRRImageCache.shared
        let first = try XCTUnwrap(cache.image(key: key, base64: source))
        let reused = try XCTUnwrap(cache.image(key: key, base64: "invalid-base64"))
        XCTAssertTrue(first === reused, "A cached image should be returned without decoding its source again.")
        XCTAssertNotNil(reused.cgImage, "The cached display image should have its bitmap ready.")
    }

    func testUIVersionAndViewOrderPersistWithOptionTwoDefault() throws {
        let suite = "BoundUIVersion." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let version = BoundUIVersionPreferences(defaults: defaults)
        let preferences = BoundPiPPreferences(defaults: defaults)
        XCTAssertEqual(version.version, .option2)
        let original = BoundPiPContent.cycleOrder
        preferences.setContentOrder([.dex, .bosses, .dex])
        XCTAssertEqual(preferences.orderedContents, [.dex, .bosses, .friend, .notes, .types, .connections, .debug])
        XCTAssertEqual(preferences.enabledContents(uiVersion: .option1), original)
        version.version = .option2
        XCTAssertEqual(version.effectiveVersion, .option2)
        preferences.setEnabled(false, for: .bosses)
        let restarted = BoundPiPPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(restarted.uiVersion, .option2)
        XCTAssertEqual(restarted.enabledContents(uiVersion: restarted.uiVersion), [.dex, .friend, .notes, .types, .connections, .debug])
        XCTAssertEqual(restarted.enabledContents(uiVersion: .option1), [.friend, .notes, .types, .dex, .connections, .debug])
        XCTAssertEqual(version.effectiveVersion, .option2)
        XCTAssertEqual(version.version, .option2)
        defaults.set(99, forKey: BoundUIVersionPreferences.key)
        XCTAssertEqual(version.version, .option2)
        defaults.set(["unknown", "notes", "notes"], forKey: "bound.delta.pip.v1.view-order")
        XCTAssertEqual(restarted.orderedContents, [.notes, .friend, .types, .bosses, .dex, .connections, .debug])
    }

    func testConnectionsAppendsToExistingChoicesWithoutResettingAssignmentsOrEnablingMultiplayer() throws {
        let suite = "BoundConnectionsPreferences." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let order = ["dex", "friend", "types", "notes", "bosses"]
        defaults.set(order, forKey: "bound.delta.pip.v1.view-order")
        defaults.set(["friend", "notes"], forKey: "bound.delta.pip.v1.button.option4.1.views")
        defaults.set([], forKey: "bound.delta.pip.v1.button.option4.2.views")
        defaults.set(false, forKey: BoundMultiplayerFeatures.key)
        let preferences = BoundPiPPreferences(defaults: defaults)
        XCTAssertEqual(preferences.orderedContents.map(\.rawValue), order + ["connections", "debug"])
        XCTAssertEqual(defaults.stringArray(forKey: "bound.delta.pip.v1.view-order"), order)
        XCTAssertTrue(preferences.isEnabled(.connections))
        XCTAssertEqual(preferences.assignedContents(for: 0, buttonType: .option4), [.friend, .notes])
        XCTAssertEqual(preferences.assignedContents(for: 1, buttonType: .option4), [])

        preferences.setAssignedContents([.connections], for: 1, buttonType: .option4)
        let state = BoundCompanionState(preferences: preferences)
        state.advanceButton(1)
        XCTAssertEqual(state.content, .connections)
        XCTAssertEqual(state.content.title, "Connections")
        XCTAssertEqual(preferences.assignedContents(for: 0, buttonType: .option4), [.friend, .notes])
        XCTAssertEqual(BoundPiPPreferences(defaults: defaults).assignedContents(for: 1, buttonType: .option4), [.connections])
        XCTAssertFalse(defaults.bool(forKey: BoundMultiplayerFeatures.key))
    }
    func testUIVersionSwitchingAndReorderingPreserveVisiblePanel() throws {
        let suite = "BoundUIVersionState." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let version = BoundUIVersionPreferences(defaults: defaults)
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.buttonType = .option1
        let state = BoundCompanionState(preferences: preferences)
        state.selected = 3
        XCTAssertEqual(state.content, .bosses)
        version.version = .option2
        state.updateUIVersion()
        state.setContentOrder([.dex, .bosses, .friend, .types, .notes])
        XCTAssertEqual(state.content, .bosses)
        XCTAssertEqual(state.selected, 1)
        for _ in 0..<5 { state.advancePanel() }
        XCTAssertEqual(state.content, .dex, "Views remain reachable through ordinary cycling in either UI version")
        state.hidden = true
        state.advancePanel()
        XCTAssertEqual(state.content, .dex)
        XCTAssertFalse(state.hidden)
        state.setContentEnabled(false, for: .dex)
        XCTAssertEqual(state.content, .bosses, "Disabling the selected view restores the first enabled view")
        state.setContentEnabled(false, for: .notes)
        XCTAssertEqual(state.content, .bosses, "Disabling another view preserves the current selection")
        version.version = .option1
        state.updateUIVersion()
        XCTAssertEqual(state.content, .bosses)
        XCTAssertEqual(state.availableContents, [.friend, .types, .bosses, .connections])
        state.advancePanel()
        XCTAssertEqual(state.content, .connections)
        state.advancePanel()
        XCTAssertEqual(state.content, .friend)
        state.setContentOrder([.types, .friend])
        XCTAssertEqual(state.content, .friend, "Changing cycle order preserves the selected panel")
        XCTAssertEqual(preferences.orderedContents, [.dex, .bosses, .friend, .types, .notes, .connections, .debug])
    }

    func testSplitButtonsRememberTheirOwnViewWhenAssignmentsOverlap() throws {
        let suite = "BoundSplitButtonMemory." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.buttonType = .option3
        preferences.setAssignedContents([.friend, .dex], for: 0, buttonType: .option3)
        preferences.setAssignedContents([.friend, .bosses], for: 1, buttonType: .option3)
        preferences.setAssignedContents([.types], for: 2, buttonType: .option3)
        let state = BoundCompanionState(preferences: preferences)

        XCTAssertEqual(state.displayedButtonContents, [.friend, .friend, .types])
        state.advanceButton(0)
        XCTAssertEqual(state.content, .dex)
        XCTAssertEqual(state.displayedButtonContents, [.dex, .friend, .types],
                       "Selecting Dex on Button 1 must leave shared Friend on inactive Button 2.")

        state.advanceButton(1)
        XCTAssertEqual(state.content, .friend, "The first tap on an inactive button restores its remembered view.")
        XCTAssertEqual(state.displayedButtonContents, [.dex, .friend, .types],
                       "Selecting a view shared by two assignments must update only the active button.")

        state.hidden = true
        state.advanceButton(0)
        XCTAssertEqual(state.content, .dex, "A hidden panel restores the pressed button's remembered view.")
        XCTAssertFalse(state.hidden)
        XCTAssertEqual(state.displayedButtonContents, [.dex, .friend, .types])
    }

    func testSplitButtonMemoryIsIndependentByStyleAndSanitizedWhenAssignmentChanges() throws {
        let suite = "BoundSplitButtonStyleMemory." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.buttonType = .option3
        preferences.setAssignedContents([.friend, .dex], for: 0, buttonType: .option3)
        preferences.setAssignedContents([.bosses], for: 1, buttonType: .option3)
        preferences.setAssignedContents([.types], for: 2, buttonType: .option3)
        let state = BoundCompanionState(preferences: preferences)
        state.advanceButton(0)
        XCTAssertEqual(state.content, .dex)
        XCTAssertEqual(state.displayedButtonContents.first!, .dex)

        preferences.setAssignedContents([.notes, .types], for: 0, buttonType: .option4)
        preferences.setAssignedContents([.friend], for: 1, buttonType: .option4)
        state.setButtonType(.option4)
        XCTAssertEqual(state.displayedButtonContents, [.notes, .friend],
                       "Button 4 starts with its own assignments and does not inherit Button 3's selection.")
        state.advanceButton(0) // Restore Button 4's remembered Notes view.
        XCTAssertEqual(state.content, .notes)
        state.advanceButton(0)
        XCTAssertEqual(state.content, .types)
        XCTAssertEqual(state.displayedButtonContents, [.types, .friend])

        state.setButtonType(.option3)
        XCTAssertEqual(state.displayedButtonContents.first!, .dex,
                       "Returning to Button 3 preserves its independent last selected view.")
        preferences.setAssignedContents([.friend], for: 0, buttonType: .option3)
        state.settings.refresh()
        XCTAssertEqual(state.displayedButtonContents.first, .friend,
                       "Removing the remembered view falls back to the first remaining assignment.")
        preferences.setAssignedContents([], for: 0, buttonType: .option3)
        state.settings.refresh()
        XCTAssertNil(state.displayedButtonContents.first!, "An empty assignment has no displayed view.")
    }

    func testReturningToButtonStylePreservesItsRememberedViewAcrossOverlappingAssignments() throws {
        let suite = "BoundSplitButtonStyleOverlap." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.buttonType = .option3
        preferences.setAssignedContents([.friend, .dex], for: 0, buttonType: .option3)
        preferences.setAssignedContents([.friend], for: 1, buttonType: .option3)
        preferences.setAssignedContents([.types], for: 2, buttonType: .option3)
        preferences.setAssignedContents([.friend, .notes], for: 0, buttonType: .option4)
        preferences.setAssignedContents([.bosses], for: 1, buttonType: .option4)
        let state = BoundCompanionState(preferences: preferences)

        state.advanceButton(0)
        XCTAssertEqual(state.content, .dex)
        XCTAssertEqual(state.displayedButtonContents[0], .dex)

        state.setButtonType(.option4)
        XCTAssertEqual(state.content, .friend, "A first-use style keeps the current view when it is assigned.")
        state.advanceButton(1)
        XCTAssertEqual(state.content, .bosses)
        state.advanceButton(0)
        XCTAssertEqual(state.content, .friend, "The inactive Button 4 control restores its own Friend view.")

        state.setButtonType(.option3)
        XCTAssertEqual(state.content, .dex,
                       "Returning to Button 3 restores its active button's view even though Friend overlaps.")
        XCTAssertEqual(state.displayedButtonContents[0], .dex,
                       "Showing shared Friend in Button 4 must not overwrite Button 3's Dex icon.")
    }

    func testInactiveOverlappingSplitButtonKeepsItsRenderedIcon() throws {
        let suite = "BoundSplitButtonRendererMemory." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.buttonType = .option3
        preferences.setAssignedContents([.friend, .dex], for: 0, buttonType: .option3)
        preferences.setAssignedContents([.friend, .bosses], for: 1, buttonType: .option3)
        preferences.setAssignedContents([.types], for: 2, buttonType: .option3)
        let state = BoundCompanionState(preferences: preferences)
        let canvas = CGRect(x: 0, y: 0, width: 390, height: 844)
        let menuFrame = CGRect(x: 10, y: 700, width: 20, height: 20)
        let button = BoundCompanionCycleButton()
        button.configure(menuFrame: menuFrame, controllerFrame: canvas, landscape: false, minimal: false,
                         content: state.content, canvas: canvas, occupied: [menuFrame], boundPortrait: true,
                         buttonType: .option3)

        func renderFirstSegment() throws -> Data {
            let assignments = (0..<state.buttonType.splitButtonCount).map {
                preferences.assignedContents(for: $0, buttonType: state.buttonType)
            }
            button.configureSegments(contents: assignments, displayedContents: state.displayedButtonContents)
            let image = renderedButtonStrip(button)
            let frame = button.segmentButtons[0].frame
            let scale = image.scale
            let cropRect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                                  width: frame.width * scale, height: frame.height * scale).integral
            return try XCTUnwrap(UIImage(cgImage: try XCTUnwrap(image.cgImage?.cropping(to: cropRect))).pngData())
        }

        state.advanceButton(0)
        let selectedDexImage = try renderFirstSegment()
        XCTAssertEqual(button.segmentButtons[0].accessibilityValue as? String, "RR Dex")

        state.advanceButton(1)
        XCTAssertEqual(state.content, .friend)
        let retainedDexImage = try renderFirstSegment()
        XCTAssertEqual(button.segmentButtons[0].accessibilityValue as? String, "RR Dex",
                       "The inactive button continues to identify its remembered view.")
        XCTAssertEqual(retainedDexImage, selectedDexImage,
                       "The inactive button's rendered icon remains unchanged when another button selects a shared view.")
    }

    func testPersistentSettingsModelUpdatesActiveSessionAndPreservesSelection() async throws {
        let suite = "BoundSettingsLive." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        BoundUIVersionPreferences(defaults: defaults).version = .option1
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.buttonType = .option1
        let model = BoundCompanionSettingsModel(preferences: preferences)
        let state = BoundCompanionState(preferences: preferences)
        let versionChanged = expectation(description: "An active session observes the UI version")
        versionChanged.assertForOverFulfill = false
        let orderChanged = expectation(description: "An active session observes the new view order")
        let disabled = expectation(description: "The active session observes a disabled view")
        let cancellable = model.$configuration.dropFirst().sink { configuration in
            if configuration.uiVersion == .option2 { versionChanged.fulfill() }
            if configuration.availableContents == [.dex, .bosses, .friend, .types, .notes, .connections] { orderChanged.fulfill() }
            if !configuration.availableContents.contains(.dex) { disabled.fulfill() }
        }

        state.advancePanel()
        XCTAssertEqual(state.content, .notes, "The panel advances through the ordinary button action")
        BoundUIVersionPreferences(defaults: defaults).version = .option2
        await fulfillment(of: [versionChanged], timeout: 2)
        model.setContentOrder([.dex, .bosses, .friend, .types, .notes])
        await fulfillment(of: [orderChanged], timeout: 2)
        XCTAssertEqual(state.uiVersion, .option2)
        XCTAssertEqual(state.content, .notes, "A settings edit should preserve the active session's selected view")
        state.advancePanel()
        XCTAssertEqual(state.content, .connections)
        state.advancePanel()
        XCTAssertEqual(state.content, .dex)
        state.advancePanel()
        XCTAssertEqual(state.content, .bosses)
        model.setContentEnabled(false, for: .dex)
        await fulfillment(of: [disabled], timeout: 2)
        XCTAssertEqual(state.content, .bosses)
        XCTAssertFalse(state.availableContents.contains(.dex))
        withExtendedLifetime(cancellable) {}
    }

    func testSharedSettingsPresentationRunsCleanupOnceAcrossDismissalCallbacks() throws {
        let syncs = LockedCounter()
        let closes = LockedCounter()
        let host = BoundSettingsHostingController(syncOnClose: { syncs.increment() }, closed: { closes.increment() })
        host.finishPresentation()
        let parent = UIViewController()
        let presentation = UIPresentationController(presentedViewController: host, presenting: parent)
        host.presentationControllerDidDismiss(presentation)
        host.finishPresentation()
        XCTAssertEqual(syncs.value, 1, "Done and interactive-dismissal callbacks must not sync more than once")
        XCTAssertEqual(closes.value, 1, "Done and interactive-dismissal callbacks must not close more than once")
    }

    func testCompanionButtonsActivateOnTouchAndAccessibilityWithoutMenus() {
        let canvas = CGRect(x: 0, y: 0, width: 390, height: 844)
        let menuFrame = CGRect(x: 10, y: 700, width: 20, height: 20)
        let button = BoundCompanionCycleButton()
        button.configure(menuFrame: menuFrame, controllerFrame: canvas, landscape: false, minimal: false,
                         content: .friend, canvas: canvas, occupied: [menuFrame], boundPortrait: true,
                         buttonType: .option2)
        var cycles = 0
        button.cycle = { cycles += 1 }
        XCTAssertNil(button.menu, "Companion cycle buttons no longer expose a hold menu.")
        button.sendActions(for: .touchDown)
        XCTAssertEqual(cycles, 1, "A normal press activates immediately on touch-down.")
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(cycles, 1, "Release must not activate the button a second time.")
        XCTAssertTrue(button.accessibilityActivate())
        XCTAssertEqual(cycles, 2, "Accessibility activation keeps the ordinary cycle action.")

        let split = BoundCompanionCycleButton()
        split.configure(menuFrame: menuFrame, controllerFrame: canvas, landscape: false, minimal: false,
                        content: .friend, canvas: canvas, occupied: [menuFrame], boundPortrait: true,
                        buttonType: .option3)
        split.configureSegments(contents: [[.friend], [.bosses, .dex], [.types]],
                                displayedContents: [.friend, .bosses, .types])
        var activated: [Int] = []
        split.activateSegment = { activated.append($0) }
        XCTAssertNil(split.menu, "The split button host must not expose a hold menu.")
        for (index, segment) in split.segmentButtons.enumerated() {
            XCTAssertNil(segment.menu, "Split button \(index + 1) must not expose a hold menu.")
            segment.sendActions(for: .touchDown)
            XCTAssertEqual(activated, Array(0...index), "Split button \(index + 1) activates on touch-down.")
            segment.sendActions(for: .touchUpInside)
            XCTAssertEqual(activated, Array(0...index), "Release must not activate split button \(index + 1) twice.")
        }
    }

    func testDexAutomaticallyRefreshesMatchingSaveEventsOnMain() throws {
        let savedLayout = UserDefaults.standard.object(forKey: BoundReferenceLayoutPreferences.dexKey)
        let gameID = "RRDEX_AUTO_QA_" + UUID().uuidString
        let dexPreferences = BoundRRDexPreferences()
        defer {
            if let savedLayout { UserDefaults.standard.set(savedLayout, forKey: BoundReferenceLayoutPreferences.dexKey) }
            else { UserDefaults.standard.removeObject(forKey: BoundReferenceLayoutPreferences.dexKey) }
            UserDefaults.standard.removeObject(forKey: "bound.rrdex.choice.v1." + gameID)
        }
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

    func testRetainedReferencePanelRefreshesDexOnlyWhenActiveAndResetsForNewROM() throws {
        let suite = "BoundRetainedReference." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gameIDs = ["RETAINED_DEX_" + UUID().uuidString, "RETAINED_DEX_" + UUID().uuidString]
        defer { gameIDs.forEach { UserDefaults.standard.removeObject(forKey: "bound.rrdex.choice.v1." + $0) } }

        let preferences = BoundPiPPreferences(defaults: defaults)
        let state = BoundCompanionState(preferences: preferences)
        let sharing = FriendSharingSession(configuration: nil, authenticatedMode: true)
        var captures = 0
        var capturedGameIDs: [String] = []
        var currentGameID = gameIDs[0]
        var expectedCapture: XCTestExpectation?
        var save = BoundRRDexSave(trainerID: 1, randomAbilities: false, randomLearnset: false)

        func makePanel(gameID: String) -> BoundCompanionPanel {
            BoundCompanionPanel(sharing: sharing, state: state, gameID: gameID, editingChanged: { _ in },
                                currentSave: { requestedGameID in
                XCTAssertTrue(Thread.isMainThread)
                // Match importCurrentRRDexSave's active-ROM guard: SwiftUI can
                // finish an old subtree's appearance while replacing its root.
                guard requestedGameID == currentGameID else {
                    throw BoundRRDexSave.ImportError.currentGameUnavailable
                }
                captures += 1
                capturedGameIDs.append(requestedGameID)
                expectedCapture?.fulfill()
                expectedCapture = nil
                return save
            })
        }

        let host = UIHostingController(rootView: makePanel(gameID: gameIDs[0]))
        // Give this appearance-sensitive fixture its own root lifecycle. The
        // app's existing root can still be finishing another host's transition.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 60, width: 393, height: 263)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
            sharing.stop()
        }

        func settle() {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            host.view.layoutIfNeeded()
        }
        func show(_ content: BoundPiPContent) throws {
            state.selected = try XCTUnwrap(state.availableContents.firstIndex(of: content))
            settle()
        }

        settle()
        XCTAssertEqual(captures, 0, "A lazily unvisited Dex panel must not read the current game save.")
        try show(.bosses)
        XCTAssertEqual(captures, 0, "Opening Bosses must not initialize or capture the Dex save.")

        let firstActivation = expectation(description: "First Dex visit reads the current game save")
        expectedCapture = firstActivation
        try show(.dex)
        wait(for: [firstActivation], timeout: 10)
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(capturedGameIDs, [gameIDs[0]])

        try show(.friend)
        save = BoundRRDexSave(trainerID: 42, randomAbilities: true, randomLearnset: true)
        let hiddenRefresh = expectation(description: "Hidden Dex ignores save refresh")
        hiddenRefresh.isInverted = true
        expectedCapture = hiddenRefresh
        BoundRRDexSaveRefreshEvent.post(gameID: gameIDs[0])
        wait(for: [hiddenRefresh], timeout: 0.3)
        XCTAssertEqual(captures, 1, "A retained but inactive Dex must not capture on save events.")

        let reactivation = expectation(description: "Reopening Dex catches up to the latest save")
        expectedCapture = reactivation
        try show(.dex)
        wait(for: [reactivation], timeout: 5)
        XCTAssertEqual(captures, 2)
        XCTAssertEqual(BoundRRDexPreferences().read(gameID: gameIDs[0]).save, save)

        let newROM = expectation(description: "A new ROM gets a fresh Dex view and save refresh")
        expectedCapture = newROM
        let oldROMSave = save
        save = BoundRRDexSave(trainerID: 99, randomAbilities: false, randomLearnset: true)
        currentGameID = gameIDs[1]
        host.rootView = makePanel(gameID: gameIDs[1])
        settle()
        wait(for: [newROM], timeout: 5)
        XCTAssertEqual(captures, 3)
        XCTAssertEqual(capturedGameIDs, [gameIDs[0], gameIDs[0], gameIDs[1]],
                       "The retained Dex subtree resets its ROM-scoped identity when the game changes.")
        XCTAssertEqual(BoundRRDexPreferences().read(gameID: gameIDs[0]).save, oldROMSave,
                       "A stale appearance callback must not import the new ROM's save into the old ROM.")
        XCTAssertEqual(BoundRRDexPreferences().read(gameID: gameIDs[1]).save, save)
    }

    func testDexCardRendersAtPortraitAndLandscapePanelSizes() throws {
        let savedLayout = UserDefaults.standard.object(forKey: BoundReferenceLayoutPreferences.dexKey)
        defer {
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
        let savedLayout = UserDefaults.standard.object(forKey: BoundReferenceLayoutPreferences.bossKey)
        defer {
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
        preferences.buttonType = .option3

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

        XCTAssertEqual(preferences.assignedContents(for: 0, buttonType: .option4), [.friend])
        XCTAssertEqual(preferences.assignedContents(for: 1, buttonType: .option4), [.types, .bosses, .dex])
        preferences.setAssignedContents([.dex, .notes], for: 0, buttonType: .option4)
        preferences.setAssignedContents([], for: 1, buttonType: .option4)
        XCTAssertEqual(relaunched.assignedContents(for: 0, buttonType: .option4), [.notes, .dex])
        XCTAssertEqual(relaunched.assignedContents(for: 1, buttonType: .option4), [])
        XCTAssertEqual(relaunched.assignedContents(for: 0, buttonType: .option3), [.friend, .notes, .dex],
                       "Option 4 assignments remain separate from the existing three-button layout.")
    }
    func testLegacyButtonOptionFourMigratesToSplitButtonThreeAndNewOptionFourPersists() throws {
        let suite = "BoundButtonTypeMigration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Registration is shared across UserDefaults suites. A legacy launch
        // excludes the new key before registering its profile defaults.
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        var legacyRegistration = registered
        legacyRegistration.removeValue(forKey: BoundCompanionButtonPreferences.key)
        UserDefaults.standard.setVolatileDomain(legacyRegistration, forName: UserDefaults.registrationDomain)
        defer { UserDefaults.standard.setVolatileDomain(registered, forName: UserDefaults.registrationDomain) }
        defaults.set(4, forKey: BoundCompanionButtonPreferences.legacyKey)

        XCTAssertEqual(BoundCompanionButtonPreferences(defaults: defaults).buttonType, .option3)
        let preferences = BoundCompanionButtonPreferences(defaults: defaults)
        preferences.buttonType = .option4
        XCTAssertEqual(preferences.buttonType, .option4)
        XCTAssertEqual(defaults.integer(forKey: BoundCompanionButtonPreferences.key), 4)
        XCTAssertEqual(BoundCompanionButtonPreferences(defaults: defaults).buttonType, .option4,
                       "The new settings key distinguishes Option 4 from a legacy raw 4.")
    }

    func testCompanionButtonTypePersistsAsTheEffectiveStyle() throws {
        let suite = "BoundCompanionButtonType." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = BoundCompanionButtonPreferences(defaults: defaults)
        XCTAssertEqual(preferences.buttonType, .option4, "New installs use the two-button default.")
        XCTAssertEqual(preferences.effectiveButtonType, .option4)

        preferences.buttonType = .option3
        XCTAssertEqual(preferences.buttonType, .option3)
        XCTAssertEqual(BoundCompanionButtonPreferences(defaults: defaults).buttonType, .option3,
                       "A newly created preferences object reads the saved choice.")
        XCTAssertEqual(preferences.effectiveButtonType, .option3)
        XCTAssertEqual(preferences.buttonType, .option3, "The user's saved selection remains intact.")
        XCTAssertEqual(preferences.effectiveButtonType, .option3)

        defaults.set(99, forKey: BoundCompanionButtonPreferences.key)
        XCTAssertEqual(preferences.buttonType, .option1, "Unknown stored values safely fall back to Option 1.")
    }

    func testDebugGameAddsConnectionsAndDebugWithoutSavingAssignments() throws {
        let suite = "BoundDebugFeed." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        let state = BoundCompanionState(preferences: preferences)
        let original = state.configuration
        let stored = defaults.persistentDomain(forName: suite) ?? [:]
        state.settings.setDebugGame(true)
        XCTAssertEqual(state.availableContents, [.friend, .types, .bosses, .connections, .debug, .dex])
        XCTAssertEqual(state.configuration.assignments, [[.friend], [.types, .bosses, .connections, .dex, .debug]])
        for _ in 0..<3 { state.advanceButton(1) }
        XCTAssertEqual(state.content, .connections, "The normal iPhone companion button must reach the live feed")
        state.advanceButton(1); state.advanceButton(1)
        XCTAssertEqual(state.content, .debug)
        state.settings.setDebugGame(false)
        XCTAssertEqual(state.configuration, original)
        XCTAssertEqual((defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary, stored as NSDictionary)
    }

    func testDeveloperFeaturesAddsFourthFeedForBothSplitButtonStyles() throws {
        let suite = "BoundDeveloperFeed." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        let settings = BoundCompanionSettingsModel(preferences: preferences)
        defaults.set(true, forKey: BoundDeveloperFeatures.key)
        for style in [BoundCompanionButtonType.option3, .option4] {
            settings.setButtonType(style)
            XCTAssertEqual(settings.availableContents[3], .connections)
            XCTAssertTrue(settings.configuration.assignments.last!.contains(.connections))
            XCTAssertTrue(settings.configuration.debugAvailable)
            XCTAssertTrue(settings.configuration.assignments.last!.contains(.debug))
            XCTAssertFalse(preferences.assignedContents(for: style.splitButtonCount - 1).contains(.connections))
        }
        defaults.set(false, forKey: BoundDeveloperFeatures.key)
        settings.refresh()
        XCTAssertEqual(settings.availableContents, [.friend, .types, .bosses, .dex])
    }

    func testDebugConnectionsRemainSelectedThroughUnavailableReadingsAndDisconnectedFeed() throws {
        let suite = "BoundOfflineDebugFeed." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        let state = BoundCompanionState(preferences: preferences)
        let feed = BoundConnectionFeed()
        let stored = defaults.persistentDomain(forName: suite) ?? [:]
        state.settings.setDebugGame(true)
        for _ in 0..<3 { state.advanceButton(1) }
        XCTAssertEqual(state.content, .connections)
        let configuration = state.configuration
        let transitions: [() -> Void] = [
            {}, // No connection has been established.
            { feed.beginConnection() },
            { feed.connected() },
            { feed.recovering() },
            { feed.disconnect(.manual) }
        ]
        for transition in transitions {
            transition()
            state.settings.setDebugGame(nil)
            state.settings.refresh()
            XCTAssertEqual(state.configuration, configuration)
            XCTAssertEqual(state.content, .connections, "A dropped connection cannot hide its own diagnostic screen")
        }
        XCTAssertEqual(feed.entries.first?.kind, .manuallyDisconnected)
        XCTAssertTrue(feed.entries.contains { $0.kind == .connectionLost })
        XCTAssertEqual((defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary, stored as NSDictionary)
        state.settings.setDebugGame(false)
        XCTAssertFalse(state.availableContents.contains(.connections), "A confirmed Debug setting change still applies")
    }

    func testDebugFeedPreservesCustomOrderAssignmentsAndSelectedView() throws {
        let suite = "BoundCustomDebugFeed." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.setContentOrder([.dex, .notes, .friend, .types, .bosses, .connections])
        preferences.setAssignedContents([.friend, .notes, .dex], for: 0)
        preferences.setAssignedContents([], for: 1)
        let state = BoundCompanionState(preferences: preferences)
        state.selected = 1
        let selected = state.content, original = state.configuration
        state.settings.setDebugGame(true)
        XCTAssertEqual(state.availableContents, [.dex, .notes, .friend, .connections, .debug])
        XCTAssertEqual(state.content, selected)
        XCTAssertEqual(preferences.assignedContents(for: 1), [])
        state.settings.setDebugGame(false)
        XCTAssertEqual(state.configuration, original)
        XCTAssertEqual(state.content, selected)
    }

    func testDebugAvailabilityPreservesAssignmentsAndClearsUnavailableMacFocus() throws {
        let suite = "BoundDebugAvailability." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.setAssignedContents([.debug], for: 0)
        preferences.setAssignedContents([.types, .dex], for: 1)
        let saved = defaults.persistentDomain(forName: suite) ?? [:]
        let state = BoundCompanionState(preferences: preferences)
        XCTAssertFalse(state.availableContents.contains(.debug))
        state.settings.setDebugGame(true)
        XCTAssertEqual(state.configuration.assignments[0], [.debug])
        state.macReference = .debug; state.macControllerFocused = true
        XCTAssertEqual(state.macBottomReference, .debug)
        state.settings.setDebugGame(false)
        XCTAssertEqual(state.macReference, .connections)
        XCTAssertEqual(state.macBottomReference, .connections)
        XCTAssertFalse(state.macControllerFocused)
        XCTAssertEqual(preferences.assignedContents(for: 0), [.debug])
        XCTAssertEqual((defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary, saved as NSDictionary)
        state.settings.setDebugGame(true)
        XCTAssertEqual(state.configuration.assignments[0], [.debug])
    }

    func testDebugIsFifthMultiviewTabAndUnavailableSelectionIsRestoredWithoutPreferenceLoss() throws {
        let suite = "BoundDebugMultiview." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BoundLandscapeArrangementModel(defaults: defaults)
        model.useOption(.option7)
        model.setContents([.dex, .bosses, .types, .connections, .debug])
        XCTAssertEqual(model.contents, [.dex, .bosses, .types, .connections, .debug])
        model.select(.debug)
        let saved = defaults.persistentDomain(forName: suite) ?? [:]
        model.setContents([.dex, .bosses, .types, .connections])
        XCTAssertEqual(model.referenceContent, .dex)
        XCTAssertEqual((defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary, saved as NSDictionary)
        model.setContents([.dex, .bosses, .types, .connections, .debug])
        XCTAssertEqual(model.referenceContent, .debug)
        model.cycleReference()
        XCTAssertEqual(model.referenceContent, .dex)
    }

    func testFreshInstallUsesRequestedPresetWithoutWritingUntilEdited() throws {
        let suite = "BoundFreshPreset." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = BoundPiPPreferences(defaults: defaults)
        let settings = BoundCompanionSettingsModel(preferences: preferences)
        XCTAssertEqual(settings.configuration.uiVersion, .option2)
        XCTAssertEqual(settings.configuration.buttonType, .option4)
        XCTAssertEqual(settings.configuration.assignments, [[.friend], [.types, .bosses, .dex]])
        XCTAssertEqual(settings.configuration.availableContents, [.friend, .types, .bosses, .dex])

        let landscape = BoundLandscapePreferences(defaults: defaults)
        XCTAssertEqual(landscape.option, .option7)
        let controller = BoundControllerModePreferences(defaults: defaults)
        XCTAssertFalse(controller.isEnabled, "Controller Mode is off on a fresh install.")
        XCTAssertEqual(controller.layout, .mode1)

        for key in [BoundUIVersionPreferences.key,
                    "bound.landscape.v1.option",
                    BoundCompanionButtonPreferences.key,
                    BoundCompanionButtonPreferences.legacyKey,
                    "bound.delta.pip.v1.button.option4.1.views",
                    "bound.delta.pip.v1.button.option4.2.views",
                    BoundReferenceLayoutPreferences.dexKey,
                    BoundReferenceLayoutPreferences.bossKey,
                    BoundControllerModePreferences.key,
                    BoundControllerModePreferences.layoutKey] {
            XCTAssertNil(defaults.persistentDomain(forName: suite)?[key], "Reading the fresh preset must not write \(key).")
        }

        settings.setButtonType(.option3)
        XCTAssertEqual(defaults.integer(forKey: BoundCompanionButtonPreferences.key), BoundCompanionButtonType.option3.rawValue)

        let upgradedSuite = "BoundUpgradedPreset." + UUID().uuidString
        let upgradedDefaults = try XCTUnwrap(UserDefaults(suiteName: upgradedSuite))
        defer { upgradedDefaults.removePersistentDomain(forName: upgradedSuite) }
        upgradedDefaults.set(BoundUIVersion.option1.rawValue, forKey: BoundUIVersionPreferences.key)
        upgradedDefaults.set(BoundLandscapeOption.option3.rawValue, forKey: "bound.landscape.v1.option")
        upgradedDefaults.set(BoundCompanionButtonType.option4.rawValue, forKey: BoundCompanionButtonPreferences.key)
        upgradedDefaults.set(["friend", "notes"], forKey: "bound.delta.pip.v1.button.option4.1.views")
        upgradedDefaults.set(["bosses"], forKey: "bound.delta.pip.v1.button.option4.2.views")
        upgradedDefaults.set(BoundReferenceLayout.layout4.rawValue, forKey: BoundReferenceLayoutPreferences.dexKey)
        upgradedDefaults.set(BoundReferenceLayout.layout9.rawValue, forKey: BoundReferenceLayoutPreferences.bossKey)
        upgradedDefaults.set(false, forKey: BoundControllerModePreferences.key)
        upgradedDefaults.set(BoundControllerModeLayout.mode2.rawValue, forKey: BoundControllerModePreferences.layoutKey)

        XCTAssertEqual(BoundUIVersionPreferences(defaults: upgradedDefaults).version, .option1)
        XCTAssertEqual(BoundLandscapePreferences(defaults: upgradedDefaults).option, .option3)
        let upgradedButtons = BoundPiPPreferences(defaults: upgradedDefaults)
        XCTAssertEqual(upgradedButtons.buttonType, .option4)
        XCTAssertEqual(upgradedButtons.assignedContents(for: 0), [.friend, .notes])
        XCTAssertEqual(upgradedButtons.assignedContents(for: 1), [.bosses])
        XCTAssertEqual(upgradedDefaults.integer(forKey: BoundReferenceLayoutPreferences.dexKey), BoundReferenceLayout.layout4.rawValue)
        XCTAssertEqual(upgradedDefaults.integer(forKey: BoundReferenceLayoutPreferences.bossKey), BoundReferenceLayout.layout9.rawValue)
        let upgradedController = BoundControllerModePreferences(defaults: upgradedDefaults)
        XCTAssertFalse(upgradedController.isEnabled)
        XCTAssertEqual(upgradedController.layout, .mode1, "Controller Mode now has one effective layout.")
        XCTAssertEqual(upgradedDefaults.integer(forKey: BoundControllerModePreferences.layoutKey), BoundControllerModeLayout.mode2.rawValue,
                       "Reading the unified layout must retain the legacy value for arrangement migration.")
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
    func testPermanentBossCycleIncludesReferenceViewsAndAllOffIsSafe() throws {
        let suite = "BoundBaselineCycle." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.buttonType = .option1
        let state = BoundCompanionState(preferences: preferences)
        for expected in [BoundPiPContent.notes, .types, .bosses, .dex, .connections, .friend] {
            state.advancePanel()
            XCTAssertEqual(state.content, expected)
        }
        state.hidden = true
        state.advancePanel()
        XCTAssertEqual(state.content, .friend)
        XCTAssertFalse(state.hidden)
        XCTAssertEqual(state.availableContents, [.friend, .notes, .types, .bosses, .dex, .connections])
        state.setContentEnabled(false, for: .friend)
        state.setContentEnabled(false, for: .notes)
        state.setContentEnabled(false, for: .types)
        state.setContentEnabled(false, for: .bosses)
        state.setContentEnabled(false, for: .dex)
        state.setContentEnabled(false, for: .connections)
        XCTAssertTrue(state.availableContents.isEmpty)
        state.advancePanel()
        XCTAssertEqual(state.content, .friend)
    }
    func testEnabledViewsPreserveSelectionAndHandleNoneAcrossRestart() throws {
        let suite = "BoundCompanionCycle." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.buttonType = .option1
        let state = BoundCompanionState(preferences: preferences)
        state.selected = 3
        XCTAssertEqual(state.content, .bosses)
        var selectionChanges = 0
        state.selectionChanged = { selectionChanges += 1 }
        state.setContentEnabled(false, for: .notes)
        state.setContentEnabled(false, for: .types)
        state.setContentEnabled(false, for: .dex)
        state.setContentEnabled(false, for: .connections)
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

        let restarted = BoundCompanionState(preferences: BoundPiPPreferences(defaults: defaults))
        XCTAssertTrue(restarted.availableContents.isEmpty)
        restarted.setContentEnabled(true, for: .bosses)
        XCTAssertEqual(restarted.content, .bosses)
        restarted.advancePanel()
        XCTAssertEqual(restarted.content, .bosses, "One enabled view stays selected")
    }
    func testAssignedButtonsCycleIndependentlyAndRestoreWhenHidden() throws {
        let suite = "BoundAssignedButtons." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        preferences.buttonType = .option3
        XCTAssertEqual(preferences.assignedContents(for: 0), [.friend])
        XCTAssertEqual(preferences.assignedContents(for: 1), [.bosses])
        XCTAssertEqual(preferences.assignedContents(for: 2), [.types])

        let state = BoundCompanionState(preferences: preferences)
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
        XCTAssertEqual(state.content, .notes, "Switching back to Button 1 restores its remembered Notes view.")

        state.hidden = true
        state.advanceButton(1)
        XCTAssertEqual(state.content, .bosses, "A button press restores the view assigned to that button.")
        XCTAssertFalse(state.hidden)

        state.setAssigned(true, content: .types, for: 1)
        XCTAssertEqual(preferences.assignedContents(for: 1), [.types, .bosses, .dex],
                       "Assignments follow the shared cycle order regardless of insertion order.")
        XCTAssertTrue(state.usesAssignedButtons)
        state.hidden = true
        state.advanceButton(1)
        XCTAssertEqual(state.content, .bosses, "A hidden panel restores Button 2's remembered Bosses view.")
        XCTAssertFalse(state.hidden)

        let option4Preferences = BoundPiPPreferences(defaults: defaults)
        option4Preferences.buttonType = .option4
        option4Preferences.setAssignedContents([.friend], for: 0, buttonType: .option4)
        option4Preferences.setAssignedContents([.bosses], for: 1, buttonType: .option4)
        XCTAssertEqual(option4Preferences.assignedContents(for: 0), [.friend])
        XCTAssertEqual(option4Preferences.assignedContents(for: 1), [.bosses])
        let option4State = BoundCompanionState(preferences: option4Preferences)
        XCTAssertTrue(option4State.usesAssignedButtons)
        option4State.setAssigned(true, content: .notes, for: 0)
        option4State.setAssigned(true, content: .dex, for: 1)
        XCTAssertEqual(option4Preferences.assignedContents(for: 0), [.friend, .notes])
        XCTAssertEqual(option4Preferences.assignedContents(for: 1), [.bosses, .dex])
        option4State.advanceButton(0)
        XCTAssertEqual(option4State.content, .notes)
        option4State.advanceButton(1)
        XCTAssertEqual(option4State.content, .bosses)
        option4State.hidden = true
        option4State.advanceButton(1)
        XCTAssertEqual(option4State.content, .bosses, "An Option 4 button restores its first selected view when hidden.")
        XCTAssertFalse(option4State.hidden)
        option4State.setAssigned(false, content: .bosses, for: 1)
        option4State.setAssigned(false, content: .dex, for: 1)
        let remainingContent = option4State.content
        option4State.hidden = true
        option4State.advanceButton(1)
        XCTAssertTrue(option4State.hidden, "An unassigned Option 4 button remains inactive.")
        XCTAssertEqual(option4State.content, remainingContent)
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
                if type.splitButtonCount > 0 {
                    button.configureSegments(contents: [[.friend], [.bosses], [.types]],
                                             displayedContents: [.friend, .bosses, .types])
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
                let splitMarker = type.splitButtonCount > 0 ? "/split\(type.splitButtonCount)" : ""
                silhouettes.insert(String(format: "%.1f×%.1f", button.artworkFrame.width, button.artworkFrame.height) + splitMarker)

                var feedback = 0, cycles = 0, segmentActivations = 0
                button.buttonFeedback = { feedback += 1 }
                button.cycle = { cycles += 1 }
                button.activateSegment = { _ in segmentActivations += 1 }
                let isSplit = type.splitButtonCount > 0
                XCTAssertEqual(button.segmentButtons.count, type.splitButtonCount)
                let actionButton = isSplit ? try XCTUnwrap(button.segmentButtons.first) : button
                actionButton.buttonFeedback = { feedback += 1 }
                actionButton.sendActions(for: .touchDown)
                XCTAssertEqual(feedback, 1)
                XCTAssertEqual(cycles, isSplit ? 0 : 1)
                XCTAssertEqual(segmentActivations, isSplit ? 1 : 0,
                    "A \(type.title) press activates on first contact.")
                actionButton.sendActions(for: .touchCancel)
                XCTAssertEqual(feedback, 1)
                XCTAssertEqual(cycles, isSplit ? 0 : 1)
                XCTAssertEqual(segmentActivations, isSplit ? 1 : 0,
                    "Cancelling \(type.title) never advances a companion view.")
                actionButton.sendActions(for: .touchDown)
                actionButton.sendActions(for: .touchUpInside)
                XCTAssertEqual(feedback, 2)
                XCTAssertEqual(cycles, isSplit ? 0 : 2)
                XCTAssertEqual(segmentActivations, isSplit ? 2 : 0,
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

    func testBoundPortraitButtonPressKeepsArtworkStableAndPreservesHapticCycleSemantics() {
        let originalLayout = BoundAppearancePreferences().screenLayout
        let originalFeedback = Settings.isButtonHapticFeedbackEnabled
        defer { BoundAppearancePreferences().screenLayout = originalLayout; Settings.isButtonHapticFeedbackEnabled = originalFeedback }
        BoundAppearancePreferences().screenLayout = .bound
        Settings.isButtonHapticFeedbackEnabled = true
        let material = UIGraphicsImageRenderer(size: CGSize(width: 17, height: 17)).image { _ in
            UIColor.lightGray.setFill(); UIBezierPath(rect: CGRect(x: 0, y: 0, width: 17, height: 17)).fill()
        }
        let canvas = CGRect(x: 0, y: 0, width: 390, height: 300)
        let menu = CGRect(x: 20, y: 200, width: 17, height: 17)
        var cycles = 0, feedback = 0

        for type in BoundCompanionButtonType.allCases {
            let button = BoundCompanionCycleButton()
            button.configure(menuFrame: menu, controllerFrame: canvas, landscape: false,
                minimal: false, content: .friend, canvas: canvas, occupied: [], boundPortrait: true,
                selectArtwork: material, buttonType: type)
            button.cycle = { cycles += 1 }; button.buttonFeedback = { feedback += 1 }

            let cyclesBefore = cycles
            let feedbackBefore = feedback
            let hit = button.frame
            let normalMaterial = button.materialFrame
            let normalPixels = renderedPixels(renderedButtonStrip(button))
            XCTAssertNotNil(normalPixels, "\(type.title) should render to a pixel buffer.")

            button.sendActions(for: .touchDown)
            XCTAssertTrue(button.isHighlighted, "Touch state remains available for \(type.title).")
            XCTAssertEqual(button.frame, hit)
            XCTAssertEqual(button.materialFrame, normalMaterial)
            XCTAssertEqual(renderedPixels(renderedButtonStrip(button)), normalPixels,
                           "\(type.title) artwork must not change while pressed.")
            XCTAssertEqual(feedback, feedbackBefore + 1)
            XCTAssertEqual(cycles, cyclesBefore + 1)

            button.sendActions(for: .touchCancel)
            XCTAssertFalse(button.isHighlighted)
            XCTAssertEqual(button.materialFrame, normalMaterial)
            XCTAssertEqual(renderedPixels(renderedButtonStrip(button)), normalPixels,
                           "\(type.title) artwork must remain stable after release.")
            XCTAssertEqual(feedback, feedbackBefore + 1, "Cancel must not emit extra feedback.")
            XCTAssertEqual(cycles, cyclesBefore + 1, "Cancel must not perform an extra cycle.")

            button.sendActions(for: .touchDown)
            button.sendActions(for: .touchUpInside)
            XCTAssertFalse(button.isHighlighted)
            XCTAssertEqual(feedback, feedbackBefore + 2)
            XCTAssertEqual(cycles, cyclesBefore + 2,
                           "A second completed tap performs exactly one cycle and feedback event.")
        }
    }

    func testSplitOptionsUseOptionTwoFootprintAndActivateIndependentSegmentsOnTouchDown() {
        let canvas = CGRect(x: 0, y: 0, width: 390, height: 844)
        let menu = CGRect(x: 10, y: 700, width: 20, height: 20)
        let option2 = BoundCompanionCycleButton()
        option2.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                          content: .friend, canvas: canvas, occupied: [menu], boundPortrait: true,
                          buttonType: .option2)
        for type in [BoundCompanionButtonType.option3, .option4] {
            let split = BoundCompanionCycleButton()
            split.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                            content: .friend, canvas: canvas, occupied: [menu], boundPortrait: true,
                            buttonType: type)
            XCTAssertEqual(split.frame, option2.frame)
            split.configureSegments(contents: [[.friend], [.bosses, .dex], [.types]],
                                    displayedContents: [.friend, .bosses, .types])
            split.layoutIfNeeded()
            let count = type.splitButtonCount
            XCTAssertFalse(split.isAccessibilityElement)
            XCTAssertEqual(split.segmentButtons.count, count)
            XCTAssertEqual(split.segmentButtons.map(\.accessibilityIdentifier), (1...count).map {
                "bound.panel-cycle.\($0)"
            })
            XCTAssertEqual(split.accessibilityElements?.count, count,
                           "\(type.title) exposes each child button to accessibility.")
            let rowHeight = split.bounds.height / CGFloat(count)
            for index in split.segmentButtons.indices {
                let segment = split.segmentButtons[index]
                XCTAssertEqual(segment.frame.minY, CGFloat(index) * rowHeight, accuracy: 0.001)
                XCTAssertEqual(segment.frame.height, rowHeight, accuracy: 0.001)
                XCTAssertTrue(split.hitTest(segment.center, with: nil) === segment,
                              "The host routes touches to each child button.")
            }
            XCTAssertEqual(split.segmentButtons.last?.frame.maxY ?? 0, split.bounds.maxY, accuracy: 0.001)
            var activated: [Int] = []
            split.activateSegment = { activated.append($0) }
            for index in split.segmentButtons.indices {
                let segment = split.segmentButtons[index]
                segment.sendActions(for: .touchDown)
                XCTAssertEqual(activated, Array(0...index), "\(type.title) segment \(index + 1) acts on touch-down.")
                segment.sendActions(for: .touchUpInside)
                XCTAssertEqual(activated, Array(0...index), "Release does not activate a segment twice.")
            }
        }
    }

    func testSplitButtonIconsFollowEachButtonsDisplayedView() throws {
        let canvas = CGRect(x: 0, y: 0, width: 390, height: 844)
        let menu = CGRect(x: 10, y: 700, width: 20, height: 20)
        for type in [BoundCompanionButtonType.option3, .option4] {
            let button = BoundCompanionCycleButton()
            button.configure(menuFrame: menu, controllerFrame: canvas, landscape: false, minimal: false,
                             content: .friend, canvas: canvas, occupied: [menu], boundPortrait: true,
                             buttonType: type)
            let assignments: [[BoundPiPContent]] = [[.friend, .notes], [.bosses, .dex], [.types]]
            button.configureSegments(contents: assignments, displayedContents: [.friend, .bosses, .types])
            XCTAssertEqual(button.segmentButtons[0].accessibilityValue as? String, "Friend")
            XCTAssertEqual(button.segmentButtons[1].accessibilityValue as? String, "Bosses")
            let friendImage = renderedButtonStrip(button)
            let friendAttachment = XCTAttachment(image: friendImage)
            friendAttachment.name = "Bound-Option-\(type.rawValue)-strip-Friend"
            friendAttachment.lifetime = .keepAlways
            add(friendAttachment)

            button.configureSegments(contents: assignments, displayedContents: [.notes, .bosses, .types])
            XCTAssertEqual(button.segmentButtons[0].accessibilityValue as? String, "Notes",
                           "\(type.title)'s first icon follows its currently displayed assigned view.")
            XCTAssertEqual(button.segmentButtons[1].accessibilityValue as? String, "Bosses",
                           "An inactive segment keeps its own displayed view.")
            let notesImage = renderedButtonStrip(button)
            XCTAssertNotEqual(try XCTUnwrap(friendImage.pngData()), try XCTUnwrap(notesImage.pngData()),
                              "The rendered icon must change when the selected assigned view changes.")
            let notesAttachment = XCTAttachment(image: notesImage)
            notesAttachment.name = "Bound-Option-\(type.rawValue)-strip-Notes"
            notesAttachment.lifetime = .keepAlways
            add(notesAttachment)
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
            button.configureSegments(contents: [[.friend], [.bosses], [.types]],
                                     displayedContents: [.friend, .bosses, .types])
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
        button.configureSegments(contents: [[.friend], [.bosses], [.types]],
                                 displayedContents: [.friend, .bosses, .types])
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
            if let oldVersion { UserDefaults.standard.set(oldVersion, forKey: BoundUIVersionPreferences.key) }
            else { UserDefaults.standard.removeObject(forKey: BoundUIVersionPreferences.key) }
            if let oldDexLayout { UserDefaults.standard.set(oldDexLayout, forKey: BoundReferenceLayoutPreferences.dexKey) }
            else { UserDefaults.standard.removeObject(forKey: BoundReferenceLayoutPreferences.dexKey) }
            if let oldBossLayout { UserDefaults.standard.set(oldBossLayout, forKey: BoundReferenceLayoutPreferences.bossKey) }
            else { UserDefaults.standard.removeObject(forKey: BoundReferenceLayoutPreferences.bossKey) }
            UserDefaults.standard.removeObject(forKey: "bound.rrdex.choice.v1." + gameID)
            UserDefaults.standard.removeObject(forKey: "bound.boss-guide.selection.v1." + gameID)
        }
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
        for layout in [BoundReferenceLayout.layout1, .layout2, .layout3, .layout4, .layout5, .layout6, .layout12] {
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func increment() { lock.lock(); defer { lock.unlock() }; stored += 1 }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: Value) { lock.lock(); defer { lock.unlock() }; stored.append(value) }
}
