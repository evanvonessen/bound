import XCTest
import UIKit
import SwiftUI
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
        let priorMode = defaults.object(forKey: BoundControllerModePreferences.key)
        let priorNavigation = defaults.object(forKey: BoundControllerNavigationPreferences.key)
        defer {
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
        let modeSelectionPath = IndexPath(row: 5, section: 1)
        let navigationPath = IndexPath(row: 6, section: 1)

        XCTAssertEqual(settings.tableView(tableView, numberOfRowsInSection: 1), 7)
        for indexPath in [modeEnabledPath, modeSelectionPath, navigationPath] {
            XCTAssertEqual(settings.tableView(tableView, heightForRowAt: indexPath), UITableView.automaticDimension)
            XCTAssertNotNil(settings.tableView(tableView, cellForRowAt: indexPath))
        }

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
