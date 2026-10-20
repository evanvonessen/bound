import XCTest
import UIKit
import SwiftUI
import GameController
import DeltaCore
@testable import Delta

@MainActor
final class ControllerNavigationTests: XCTestCase {
    private var previousKeyWindow: UIWindow?
    private var testWindow: UIWindow?

    override func tearDown() {
        testWindow?.isHidden = true
        previousKeyWindow?.makeKey()
        testWindow = nil
        previousKeyWindow = nil
        super.tearDown()
    }

    func testAutomaticMultiviewDefaultsCaptureAndOptOut() throws {
        let name = "MultiviewPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preference = BoundControllerMultiviewPreferences(defaults: defaults)
        XCTAssertFalse(preference.isEnabled)
        preference.isEnabled = true
        let export = try BoundConfigurationExport.snapshot(defaults: defaults, mappings: [])
        let sections = try XCTUnwrap(export["preferences"] as? [String: [String: Any]])
        XCTAssertEqual(sections["settings"]?[BoundControllerMultiviewPreferences.key] as? Bool, true)
        Settings.resetPreferenceValues(in: defaults)
        XCTAssertFalse(preference.isEnabled)

        let controller = MFiGameController(controller: GCController.withExtendedGamepad())
        let stock = BoundMultiviewDefaultMapping.mapping(for: controller, enabled: false)
        let automatic = BoundMultiviewDefaultMapping.mapping(for: controller, enabled: true)
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(automatic.input(forControllerInput: MFiGameController.Input.leftTrigger))), .boundPreviousView)
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(automatic.input(forControllerInput: MFiGameController.Input.rightTrigger))), .boundNextView)
        for input in [MFiGameController.Input.leftShoulder, .rightShoulder] {
            XCTAssertEqual(automatic.input(forControllerInput: input).map(AnyInput.init), stock.input(forControllerInput: input).map(AnyInput.init))
        }
        let captured = BoundControllerInputMapping(base: stock, multiviewActive: true, multiviewDefaults: automatic)
        let regular = BoundControllerInputMapping(base: stock, multiviewDefaults: automatic)
        let expected: [(MFiGameController.Input, ActionInput)] = [(.up, .boundFocusUp), (.down, .boundFocusDown),
            (.left, .boundFocusLeft), (.right, .boundFocusRight), (.a, .boundSelect), (.b, .boundBack),
            (.rightThumbstickDown, .boundScrollDown), (.rightThumbstickUp, .boundScrollUp)]
        for (input, action) in expected {
            XCTAssertEqual(ActionInput(input: try XCTUnwrap(captured.input(forControllerInput: input))), action)
            XCTAssertEqual(regular.input(forControllerInput: input).map(AnyInput.init), stock.input(forControllerInput: input).map(AnyInput.init))
        }
        for trigger in [MFiGameController.Input.leftTrigger, .rightTrigger] {
            XCTAssertEqual(regular.input(forControllerInput: trigger).map(AnyInput.init), stock.input(forControllerInput: trigger).map(AnyInput.init),
                           "Hidden Multiview returns default triggers to gameplay too")
        }
        XCTAssertNil(captured.input(forControllerInput: MFiGameController.Input.leftThumbstickDown))
        XCTAssertNil(captured.input(forControllerInput: MFiGameController.Input.rightShoulder))
        var custom = stock
        custom.set(ActionInput.none, forControllerInput: MFiGameController.Input.a)
        custom.set(ActionInput.toggleBoundMultiview, forControllerInput: MFiGameController.Input.b)
        custom.set(StandardGameControllerInput.menu, forControllerInput: MFiGameController.Input.x)
        custom.set(ActionInput.boundShowTypes, forControllerInput: MFiGameController.Input.leftTrigger)
        let customCapture = BoundControllerInputMapping(base: custom, multiviewActive: true)
        XCTAssertNil(customCapture.input(forControllerInput: MFiGameController.Input.a))
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(customCapture.input(forControllerInput: MFiGameController.Input.b))), .toggleBoundMultiview)
        XCTAssertEqual(StandardGameControllerInput(input: try XCTUnwrap(customCapture.input(forControllerInput: MFiGameController.Input.x))), .menu)
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(customCapture.input(forControllerInput: MFiGameController.Input.leftTrigger))), .boundShowTypes)
    }

    func testAutomaticMultiviewHeldNavigationStopsOnReleaseAndEligibilityLoss() async throws {
        let controller = MFiGameController(controller: GCController.withExtendedGamepad())
        let repeater = BoundMultiviewInputRepeater()
        var count = 0
        repeater.begin(controller: controller, action: .boundScrollDown) { count += 1; return true }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertGreaterThan(count, 0)
        repeater.end(controller: controller, action: .boundScrollDown)
        let released = count
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(count, released)
        var eligible = true
        repeater.begin(controller: controller, action: .boundFocusDown) {
            guard eligible else { return false }
            count += 1
            return true
        }
        eligible = false
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(count, released)
        repeater.endAll()
    }

    func testNavigationEventsRequireMatchingGameContentAndCommand() {
        let notification = Notification(
            name: BoundControllerNavigationEvent.notificationName,
            object: nil,
            userInfo: [
                BoundControllerNavigationEvent.gameIDKey: "game-a",
                BoundControllerNavigationEvent.contentKey: BoundPiPContent.dex.rawValue,
                BoundControllerNavigationEvent.commandKey: BoundControllerNavigationCommand.nextItem.rawValue
            ]
        )

        XCTAssertEqual(BoundControllerNavigationEvent.command(from: notification, gameID: "game-a", content: .dex), .nextItem)
        XCTAssertNil(BoundControllerNavigationEvent.command(from: notification, gameID: "game-b", content: .dex))
        XCTAssertNil(BoundControllerNavigationEvent.command(from: notification, gameID: "game-a", content: .bosses))
        let invalidCommand = Notification(name: notification.name, object: nil, userInfo: [
            BoundControllerNavigationEvent.gameIDKey: "game-a",
            BoundControllerNavigationEvent.contentKey: BoundPiPContent.dex.rawValue,
            BoundControllerNavigationEvent.commandKey: "execute-arbitrary-action"
        ])
        XCTAssertNil(BoundControllerNavigationEvent.command(from: invalidCommand, gameID: "game-a", content: .dex))
    }

    func testHideMultiviewRequestIsScopedToVisibleGameContentAndAvailability() {
        let notification = Notification(name: BoundControllerNavigationEvent.hideMultiviewNotificationName,
                                        object: nil, userInfo: [
                                            BoundControllerNavigationEvent.gameIDKey: "game-a",
                                            BoundControllerNavigationEvent.contentKey: BoundPiPContent.dex.rawValue
                                        ])
        XCTAssertTrue(BoundControllerNavigationEvent.hideMultiviewRequestMatches(
            notification, gameID: "game-a", content: .dex, available: true))
        XCTAssertFalse(BoundControllerNavigationEvent.hideMultiviewRequestMatches(
            notification, gameID: "game-b", content: .dex, available: true))
        XCTAssertFalse(BoundControllerNavigationEvent.hideMultiviewRequestMatches(
            notification, gameID: "game-a", content: .bosses, available: true))
        XCTAssertFalse(BoundControllerNavigationEvent.hideMultiviewRequestMatches(
            notification, gameID: "game-a", content: .dex, available: false))
    }

    func testControllerBindingLabelsShowEffectiveDefaultsAndExplicitOverrides() {
        XCTAssertEqual(ControllerBindingDisplayLabel.value(selected: nil, defaultInput: AnyInput(ActionInput.boundBack)),
                       ActionInput.boundBack.localizedDisplayName)
        XCTAssertEqual(ControllerBindingDisplayLabel.value(selected: AnyInput(ActionInput.none), defaultInput: AnyInput(ActionInput.boundBack)),
                       ActionInput.none.localizedDisplayName)
        XCTAssertEqual(ControllerBindingDisplayLabel.value(selected: AnyInput(ActionInput.boundSelect), defaultInput: AnyInput(ActionInput.boundBack)),
                       ActionInput.boundSelect.localizedDisplayName)
        XCTAssertEqual(ControllerBindingDisplayLabel.value(
            selected: nil,
            defaultInput: nil,
            unassignedLabel: "System Capture"
        ), "System Capture", "An unassigned physical Share button keeps its system capture behavior.")
        XCTAssertEqual(ControllerBindingDisplayLabel.value(
            selected: AnyInput(ActionInput.none),
            defaultInput: nil,
            unassignedLabel: "System Capture"
        ), ActionInput.none.localizedDisplayName, "An explicit None mapping disables the system capture action.")
    }

    func testMFiShareAndThumbstickClickInputsHaveExpectedDefaultMappings() throws {
        XCTAssertEqual(MFiGameController.Input(rawValue: "share"), .share)
        XCTAssertEqual(MFiGameController.Input(rawValue: "leftThumbstickButton"), .leftThumbstickButton)
        XCTAssertEqual(MFiGameController.Input(rawValue: "rightThumbstickButton"), .rightThumbstickButton)

        let controller = GCController.withExtendedGamepad()
        let adapter = MFiGameController(controller: controller)
        let mapping = try XCTUnwrap(adapter.defaultInputMapping as? DeltaCore.GameControllerInputMapping)
        XCTAssertEqual(StandardGameControllerInput(input: try XCTUnwrap(mapping.input(forControllerInput: MFiGameController.Input.leftThumbstickButton))), .l3)
        XCTAssertEqual(StandardGameControllerInput(input: try XCTUnwrap(mapping.input(forControllerInput: MFiGameController.Input.rightThumbstickButton))), .r3)
        XCTAssertNil(mapping.input(forControllerInput: MFiGameController.Input.share), "Share must remain available for an explicit user binding.")
        XCTAssertFalse(mapping.supportedControllerInputs.contains { MFiGameController.Input(input: $0) == .share })
    }

    func testSnapshotThumbstickClicksReachReceiverAsDistinctMFiInputs() async throws {
        let controller = GCController.withExtendedGamepad()
        let adapter = MFiGameController(controller: controller)
        let receiver = ControllerNavigationInputCapture()
        adapter.addReceiver(receiver, inputMapping: nil)
        defer { adapter.removeReceiver(receiver) }

        let profile = controller.physicalInputProfile
        let leftClick = try XCTUnwrap(profile.buttons[GCInputLeftThumbstickButton])
        let rightClick = try XCTUnwrap(profile.buttons[GCInputRightThumbstickButton])

        leftClick.setValue(1)
        rightClick.setValue(1)
        let activated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in receiver.activated.count == 2 }, object: nil)
        await fulfillment(of: [activated], timeout: 2)
        XCTAssertEqual(receiver.activated.map(\.stringValue), ["leftThumbstickButton", "rightThumbstickButton"])
        leftClick.setValue(0)
        rightClick.setValue(0)
        let deactivated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in receiver.deactivated.count == 2 }, object: nil)
        await fulfillment(of: [deactivated], timeout: 2)
        XCTAssertEqual(receiver.deactivated.map(\.stringValue), ["leftThumbstickButton", "rightThumbstickButton"])
    }

    func testNoneAndOverlaySentinelsRoundTripThroughInputSerialization() throws {
        for action in [ActionInput.none, .systemOverlay] {
            let encoded = try JSONEncoder().encode(AnyInput(action))
            let decoded = try JSONDecoder().decode(AnyInput.self, from: encoded)
            XCTAssertEqual(ActionInput(input: decoded), action)
        }
    }

    func testMultiviewTabBindingsRemainAvailableWhenDetailedNavigationIsOff() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: BoundControllerNavigationPreferences.key)
        defer {
            if let previousValue { defaults.set(previousValue, forKey: BoundControllerNavigationPreferences.key) }
            else { defaults.removeObject(forKey: BoundControllerNavigationPreferences.key) }
        }

        BoundControllerNavigationPreferences().isEnabled = false
        let actions = ActionInput.configurableActions
        XCTAssertTrue(actions.contains(.boundPreviousView))
        XCTAssertTrue(actions.contains(.boundNextView))
        XCTAssertFalse(actions.contains(.boundScrollUp))
        XCTAssertTrue(ActionInput.boundPreviousView.isMultiviewTabAction)
        XCTAssertTrue(ActionInput.boundNextView.isMultiviewTabAction)
    }

    func testMultiviewTabCyclingWrapsAtBothEnds() {
        XCTAssertEqual(BoundMultiviewTabCycling.index(current: 2, direction: 1, count: 3), 0)
        XCTAssertEqual(BoundMultiviewTabCycling.index(current: 0, direction: -1, count: 3), 2)
        XCTAssertEqual(BoundMultiviewTabCycling.index(current: 0, direction: 1, count: 1), 0)
        XCTAssertNil(BoundMultiviewTabCycling.index(current: 0, direction: 1, count: 0))
    }

    func testPreviousAndNextTabBindingsActivateSeparatelyOncePerHold() {
        let controller = MFiGameController(controller: GCController.withExtendedGamepad())
        let router = BoundPanelActionRouter()
        var previousActivations = 0
        var nextActivations = 0

        router.activate(controller: controller, action: .boundPreviousView, eligible: true) { previousActivations += 1 }
        router.activate(controller: controller, action: .boundPreviousView, eligible: true) { previousActivations += 1 }
        router.activate(controller: controller, action: .boundNextView, eligible: true) { nextActivations += 1 }
        XCTAssertEqual(previousActivations, 1)
        XCTAssertEqual(nextActivations, 1)

        router.release(controller: controller)
        router.activate(controller: controller, action: .boundNextView, eligible: true) { nextActivations += 1 }
        XCTAssertEqual(nextActivations, 2)
    }

    func testControllerInputMappingDropsNoneAndOverlayAndFiltersOnlyLeftStickCompanionActions() throws {
        var base = DeltaCore.GameControllerInputMapping(gameControllerInputType: .mfi)
        base.set(ActionInput.none, forControllerInput: MFiGameController.Input.a)
        base.set(ActionInput.systemOverlay, forControllerInput: MFiGameController.Input.b)
        base.set(ActionInput.boundScrollDown, forControllerInput: MFiGameController.Input.leftThumbstickDown)
        base.set(ActionInput.boundScrollDown, forControllerInput: MFiGameController.Input.rightThumbstickDown)
        base.set(ActionInput.boundNextItem, forControllerInput: MFiGameController.Input.leftThumbstickButton)
        base.set(ActionInput.boundNextItem, forControllerInput: MFiGameController.Input.rightThumbstickButton)

        let mapping = BoundControllerInputMapping(base: base)
        XCTAssertNil(mapping.input(forControllerInput: MFiGameController.Input.a))
        XCTAssertNil(mapping.input(forControllerInput: MFiGameController.Input.b))
        XCTAssertNil(mapping.input(forControllerInput: MFiGameController.Input.leftThumbstickDown))
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(mapping.input(forControllerInput: MFiGameController.Input.rightThumbstickDown))), .boundScrollDown)
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(mapping.input(forControllerInput: MFiGameController.Input.leftThumbstickButton))), .boundNextItem)
        XCTAssertEqual(ActionInput(input: try XCTUnwrap(mapping.input(forControllerInput: MFiGameController.Input.rightThumbstickButton))), .boundNextItem)
    }

    func testControllerSystemGesturePolicyUsesOnlyAssignedOverlayAndCaptureOverridesIt() {
        XCTAssertEqual(BoundControllerSystemGestures.preferredState(for: ActionInput.quickSave), .disabled)
        XCTAssertEqual(BoundControllerSystemGestures.preferredState(for: ActionInput.none), .disabled)
        XCTAssertEqual(BoundControllerSystemGestures.preferredState(for: ActionInput.systemOverlay), .enabled)
        XCTAssertEqual(BoundControllerSystemGestures.preferredState(for: nil), .enabled)
        XCTAssertEqual(BoundControllerSystemGestures.preferredState(for: ActionInput.quickSave, capturing: true), .disabled)
        XCTAssertEqual(BoundControllerSystemGestures.preferredState(for: nil, capturing: true), .disabled)
    }

    func testControllerInputHostScopesEventSuppressionAndPreservesProposedSize() throws {
        let root = BoundControllerInputHost {
            Color.clear
                .frame(width: 180, height: 100)
                .accessibilityIdentifier("bound.controller-input-host.content")
        }
        .frame(width: 180, height: 100)
        let hostingController = UIHostingController(rootView: root)
        let window = makeWindow(rootViewController: hostingController)
        hostingController.view.frame = window.bounds
        window.layoutIfNeeded()

        let eventController = try XCTUnwrap(descendantViewControllers(of: hostingController).compactMap { $0 as? GCEventViewController }.first)
        XCTAssertFalse(eventController.controllerUserInteractionEnabled)
        XCTAssertEqual(eventController.view.bounds.width, 180, accuracy: 0.5)
        XCTAssertEqual(eventController.view.bounds.height, 100, accuracy: 0.5)
        let childHostingController = try XCTUnwrap(eventController.children.first as? UIHostingController<AnyView>)
        XCTAssertEqual(childHostingController.view.bounds.width, 180, accuracy: 0.5)
        XCTAssertEqual(childHostingController.view.bounds.height, 100, accuracy: 0.5)
    }

    func testVerticalAndHorizontalScrollingUseViewportStepsAndClampAtEdges() throws {
        let window = try makeWindow()
        let vertical = makeScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                     contentSize: CGSize(width: 100, height: 500))
        let horizontal = makeScrollView(frame: CGRect(x: 120, y: 0, width: 100, height: 100),
                                       contentSize: CGSize(width: 500, height: 100))
        window.rootViewController?.view.addSubview(vertical)
        window.rootViewController?.view.addSubview(horizontal)
        window.layoutIfNeeded()

        XCTAssertTrue(BoundControllerNavigationScrollTarget.scroll(.scrollDown, in: vertical, active: true, animated: false))
        XCTAssertEqual(vertical.contentOffset.y, 65, accuracy: 0.1)
        vertical.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        XCTAssertFalse(BoundControllerNavigationScrollTarget.scroll(.scrollDown, in: vertical, active: true, animated: false))
        XCTAssertEqual(vertical.contentOffset.y, 400, accuracy: 0.1)
        XCTAssertTrue(BoundControllerNavigationScrollTarget.scroll(.scrollUp, in: vertical, active: true, animated: false))
        XCTAssertEqual(vertical.contentOffset.y, 335, accuracy: 0.1)

        XCTAssertTrue(BoundControllerNavigationScrollTarget.scroll(.scrollRight, in: horizontal, active: true, animated: false))
        XCTAssertEqual(horizontal.contentOffset.x, 65, accuracy: 0.1)
        horizontal.setContentOffset(CGPoint(x: 400, y: 0), animated: false)
        XCTAssertFalse(BoundControllerNavigationScrollTarget.scroll(.scrollRight, in: horizontal, active: true, animated: false))
        XCTAssertEqual(horizontal.contentOffset.x, 400, accuracy: 0.1)
        XCTAssertTrue(BoundControllerNavigationScrollTarget.scroll(.scrollLeft, in: horizontal, active: true, animated: false))
        XCTAssertEqual(horizontal.contentOffset.x, 335, accuracy: 0.1)
    }

    func testInactiveContentIgnoresScrollCommand() throws {
        let window = try makeWindow()
        let scrollView = makeScrollView(frame: window.bounds, contentSize: CGSize(width: 100, height: 500))
        window.rootViewController?.view.addSubview(scrollView)
        window.layoutIfNeeded()

        XCTAssertFalse(BoundControllerNavigationScrollTarget.scroll(.scrollDown, in: scrollView, active: false, animated: false))
        XCTAssertEqual(scrollView.contentOffset, .zero)
    }

    func testSwiftUIMarkerRoutesOnlyToItsVisibleSiblingScrollViewport() async throws {
        let fixture = ControllerNavigationScrollFixture(gameID: "hosted-game")
        let hosting = UIHostingController(rootView: fixture)
        let window = makeWindow(rootViewController: hosting)
        hosting.view.frame = window.bounds
        window.layoutIfNeeded()

        let scrollViews = allScrollViews(in: hosting.view).filter { $0.contentSize.height > $0.bounds.height + 1 }
        let visibleScrollViews = scrollViews.filter(isVisible)
        XCTAssertGreaterThanOrEqual(visibleScrollViews.count, 2)
        let ordered = visibleScrollViews.sorted {
            $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
        }
        let target = try XCTUnwrap(ordered.first)
        let sibling = try XCTUnwrap(ordered.dropFirst().first)
        let initiallyHidden = scrollViews.first(where: { !isVisible($0) })

        BoundControllerNavigationEvent.post(command: .scrollDown, gameID: "hosted-game", content: .dex)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in target.contentOffset.y > 0 }, object: nil)
        await fulfillment(of: [moved], timeout: 2)

        XCTAssertGreaterThan(target.contentOffset.y, 0)
        XCTAssertEqual(sibling.contentOffset.y, 0, accuracy: 0.1)
        if let initiallyHidden { XCTAssertEqual(initiallyHidden.contentOffset.y, 0, accuracy: 0.1) }
    }

    func testLegacySettingsControllerRendersAndUpdatesControllerPreferences() throws {
        let defaults = UserDefaults.standard
        let priorMultiview = defaults.object(forKey: BoundControllerMultiviewPreferences.key)
        let priorMode = defaults.object(forKey: BoundControllerModePreferences.key)
        let priorNavigation = defaults.object(forKey: BoundControllerNavigationPreferences.key)
        defer {
            if let priorMultiview { defaults.set(priorMultiview, forKey: BoundControllerMultiviewPreferences.key) }
            else { defaults.removeObject(forKey: BoundControllerMultiviewPreferences.key) }
            if let priorMode { defaults.set(priorMode, forKey: BoundControllerModePreferences.key) }
            else { defaults.removeObject(forKey: BoundControllerModePreferences.key) }
            if let priorNavigation { defaults.set(priorNavigation, forKey: BoundControllerNavigationPreferences.key) }
            else { defaults.removeObject(forKey: BoundControllerNavigationPreferences.key) }
        }

        let storyboard = UIStoryboard(name: "Settings", bundle: Bundle(for: SettingsViewController.self))
        let navigation = try XCTUnwrap(storyboard.instantiateInitialViewController() as? UINavigationController)
        let settings = try XCTUnwrap(navigation.viewControllers.first as? SettingsViewController)
        settings.loadViewIfNeeded()
        let tableView = settings.tableView!
        let modeEnabledPath = IndexPath(row: 4, section: 1)
        let navigationPath = IndexPath(row: 5, section: 1)

        XCTAssertEqual(settings.tableView(tableView, numberOfRowsInSection: 1), 8)
        for indexPath in [modeEnabledPath, navigationPath, IndexPath(row: 6, section: 1), IndexPath(row: 7, section: 1)] {
            XCTAssertEqual(settings.tableView(tableView, heightForRowAt: indexPath), UITableView.automaticDimension)
            XCTAssertNotNil(settings.tableView(tableView, cellForRowAt: indexPath))
        }

        let gridCell = try XCTUnwrap(settings.tableView(tableView, cellForRowAt: IndexPath(row: 7, section: 1)))
        XCTAssertTrue(gridCell.contentConfiguration is UIHostingConfiguration<BoundButtonGridSpacingSetting, EmptyView>,
                      "The eighth Controls row must host the Button Grid Spacing slider.")

        let modeCell = try XCTUnwrap(settings.tableView(tableView, cellForRowAt: modeEnabledPath))
        let modeSwitch = try XCTUnwrap(modeCell.accessoryView as? UISwitch)
        let oldMode = BoundControllerModePreferences().isEnabled
        modeSwitch.isOn = !oldMode
        modeSwitch.sendActions(for: .valueChanged)
        XCTAssertEqual(BoundControllerModePreferences().isEnabled, !oldMode)

        let navigationCell = try XCTUnwrap(settings.tableView(tableView, cellForRowAt: navigationPath))
        let navigationSwitch = try XCTUnwrap(navigationCell.accessoryView as? UISwitch)
        let oldNavigation = BoundControllerNavigationPreferences().isEnabled
        navigationSwitch.isOn = !oldNavigation
        navigationSwitch.sendActions(for: .valueChanged)
        XCTAssertEqual(BoundControllerNavigationPreferences().isEnabled, !oldNavigation)

        let multiviewCell = settings.tableView(tableView, cellForRowAt: IndexPath(row: 6, section: 1))
        XCTAssertEqual(multiviewCell.textLabel?.text, "Allow Controller to Control Multiview")
        let multiviewSwitch = try XCTUnwrap(multiviewCell.accessoryView as? UISwitch)
        let oldMultiview = BoundControllerMultiviewPreferences().isEnabled
        multiviewSwitch.isOn = !oldMultiview
        multiviewSwitch.sendActions(for: .valueChanged)
        XCTAssertEqual(BoundControllerMultiviewPreferences().isEnabled, !oldMultiview)
    }

    private func makeWindow() throws -> UIWindow {
        makeWindow(rootViewController: UIViewController())
    }

    private func makeWindow(rootViewController: UIViewController) -> UIWindow {
        previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        rootViewController.view.frame = window.bounds
        rootViewController.view.layoutIfNeeded()
        testWindow = window
        return window
    }

    private func allScrollViews(in root: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        var stack = root.subviews
        while let view = stack.popLast() {
            if let scrollView = view as? UIScrollView { result.append(scrollView) }
            stack.append(contentsOf: view.subviews)
        }
        return result
    }

    private func descendantViewControllers(of root: UIViewController) -> [UIViewController] {
        var result: [UIViewController] = []
        var stack = root.children
        while let controller = stack.popLast() {
            result.append(controller)
            stack.append(contentsOf: controller.children)
        }
        return result
    }

    private func isVisible(_ view: UIView) -> Bool {
        guard !view.isHidden, view.alpha > 0.01, view.window != nil else { return false }
        var ancestor = view.superview
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0.01 { return false }
            ancestor = current.superview
        }
        return true
    }

    private func makeScrollView(frame: CGRect, contentSize: CGSize) -> UIScrollView {
        let scrollView = UIScrollView(frame: frame)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentSize = contentSize
        return scrollView
    }
}

private struct ControllerNavigationScrollFixture: View {
    let gameID: String
    var body: some View {
        VStack(spacing: 8) {
            ScrollView { Color.clear.frame(height: 900) }
                .frame(width: 220, height: 70)
                .boundControllerScroll(gameID: gameID, content: .dex, active: true)
            ScrollView { Color.clear.frame(height: 900) }
                .frame(width: 220, height: 70)
            ScrollView { Color.clear.frame(height: 900) }
                .frame(width: 220, height: 70)
                .opacity(0)
        }
        .frame(width: 260, height: 226)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private final class ControllerNavigationInputCapture: GameControllerReceiver {
    var activated = [Input]()
    var deactivated = [Input]()

    func gameController(_ gameController: DeltaCore.GameController, didActivate input: Input, value: Double) {
        activated.append(input)
    }

    func gameController(_ gameController: DeltaCore.GameController, didDeactivate input: Input) {
        deactivated.append(input)
    }
}
