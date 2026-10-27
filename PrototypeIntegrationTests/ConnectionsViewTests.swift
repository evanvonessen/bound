import XCTest
import UIKit
import SwiftUI
@testable import Delta

@MainActor
final class ConnectionsViewTests: XCTestCase {
    func testHistoryTabsRenderIndependentGatesAndPreserveTimeline() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let feed = BoundConnectionFeed(); feed.username = "evanator3000"
        feed.beginConnection(); feed.connected(); feed.friendJoined(); feed.disconnect(.manual)
        let timeline = BoundRunTimeline()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryQA-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("timeline.json")
        timeline.configure(url: url)
        timeline.append(id: "old-event", kind: .victory, title: "Trainer battle won")
        for index in 0..<30 { timeline.append(id: "retained-\(index)", kind: .victory, title: "Trainer battle \(index + 1) won") }
        let original = try Data(contentsOf: url)
        let gameID = "History-" + UUID().uuidString
        func view(_ debug: Bool, _ developer: Bool) -> BoundHistoryView {
            BoundHistoryView(feed: feed, timeline: timeline, connectionsAllowed: debug,
                             timelineAllowed: developer, gameID: gameID)
        }
        let host = UIHostingController(rootView: view(false, true))
        host.safeAreaRegions = []; host.overrideUserInterfaceStyle = .dark
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 263)
        await settle(host.view); try capture(host.view, name: "history-initial-timeline")
        host.rootView = view(true, true)
        await settle(host.view); try capture(host.view, name: "history-both-retains-timeline")
        BoundControllerNavigationEvent.post(command: .focusLeft, gameID: gameID, content: .connections)
        await settle(host.view); try capture(host.view, name: "history-both-connections")
        BoundControllerNavigationEvent.post(command: .focusRight, gameID: gameID, content: .connections)
        await settle(host.view)
        let timelineScroll = try XCTUnwrap(scrollViews(in: host.view).first { $0.contentSize.height > $0.bounds.height + 1 })
        let offset = timelineScroll.contentOffset.y
        BoundControllerNavigationEvent.post(command: .scrollDown, gameID: gameID, content: .connections)
        for _ in 0..<20 where timelineScroll.contentOffset.y <= offset + 16 { await settle(host.view) }
        XCTAssertGreaterThan(timelineScroll.contentOffset.y, offset + 16, "History controller scrolling reaches the existing timeline")
        try capture(host.view, name: "history-both-timeline")
        host.rootView = view(true, false)
        await settle(host.view); try capture(host.view, name: "history-debug-only-fallback")
        host.rootView = view(false, true)
        await settle(host.view); try capture(host.view, name: "history-developer-only-fallback")
        host.rootView = view(false, false)
        await settle(host.view); try capture(host.view, name: "history-neither")
        XCTAssertEqual(try Data(contentsOf: url), original, "Visibility never rewrites the existing journal")
        let reopened = BoundRunTimeline(); reopened.configure(url: url)
        XCTAssertEqual(reopened.read().events.map(\.id), ["old-event"] + (0..<30).map { "retained-\($0)" })
        XCTAssertEqual(BoundHistoryTab.selection(.timeline, allowed: [.connections]), .connections)
        XCTAssertEqual(BoundHistoryTab.selection(.connections, allowed: [.timeline]), .timeline)
        XCTAssertNil(BoundHistoryTab.selection(.connections, allowed: []))
    }

    func testCompactPortraitShowsLiveRowsAndScrollsHistory() async throws {
        try await verify(size: CGSize(width: 393, height: 263), name: "portrait")
    }

    func testLandscapeShowsLiveRowsAndScrollsHistory() async throws {
        try await verify(size: CGSize(width: 360, height: 220), name: "landscape")
    }

    func testMacSidebarShowsLiveRowsAndScrollsHistory() async throws {
        try await verify(size: CGSize(width: 400, height: 600), name: "mac-sidebar")
    }

    private func verify(size: CGSize, name: String) async throws {
        for _ in 0..<100 where UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), owner = UIViewController()
        var date = Date(timeIntervalSince1970: 1_792_869_300)
        let feed = BoundConnectionFeed(now: { date })
        let gameID = "CONNECTIONS_QA_" + UUID().uuidString
        let host = UIHostingController(rootView: BoundConnectionsView(feed: feed, gameID: gameID))
        host.overrideUserInterfaceStyle = .dark
        host.safeAreaRegions = []
        window.rootViewController = owner; window.makeKeyAndVisible()
        owner.addChild(host); owner.view.addSubview(host.view); host.didMove(toParent: owner)
        host.view.frame = CGRect(origin: CGPoint(x: 0, y: 80), size: size)
        host.view.backgroundColor = .secondarySystemBackground
        defer {
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        await settle(host.view)
        try capture(host.view, name: name + "-empty")

        // Update the same observable owner while the page remains mounted.
        // Repeated transitions provide enough real rows to exercise a short
        // multiview viewport and lazy history outside the initial screen.
        let kinds = BoundConnectionFeed.Kind.allCases
        for index in 0..<48 {
            date = date.addingTimeInterval(17)
            feed.record(kinds[index % kinds.count])
        }
        await settle(host.view)
        let scroll = try XCTUnwrap(scrollViews(in: host.view).first(where: { $0.contentSize.height > $0.bounds.height + 1 }),
            "The event history must scroll inside the allocated multiview page")
        XCTAssertGreaterThan(scroll.bounds.height, 80)
        XCTAssertLessThanOrEqual(scroll.bounds.height, size.height + 1)
        XCTAssertLessThanOrEqual(scroll.bounds.width, size.width + 1)
        XCTAssertLessThan(scroll.contentSize.height, CGFloat(feed.entries.count) * 60 + 60,
            "Timestamped status rows should stay compact")
        try capture(host.view, name: name + "-latest")

        let originalOffset = scroll.contentOffset.y
        BoundControllerNavigationEvent.post(command: .scrollDown, gameID: gameID, content: .dex)
        await settle(host.view)
        XCTAssertEqual(scroll.contentOffset.y, originalOffset, accuracy: 0.5,
            "Another page's controller commands must not move Connections")
        BoundControllerNavigationEvent.post(command: .scrollDown, gameID: gameID, content: .connections)
        for _ in 0..<20 where scroll.contentOffset.y <= originalOffset + 16 {
            await settle(host.view)
        }
        XCTAssertGreaterThan(scroll.contentOffset.y, originalOffset + 16,
            "The visible Connections page must respond to its controller scroll command")

        let bottom = max(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        await settle(host.view)
        // Lazy stacks refine estimated row positions as older entries appear.
        for _ in 0..<5 {
            let target = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            if abs(scroll.contentOffset.y - target) <= 2 { break }
            scroll.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            await settle(host.view)
        }
        XCTAssertGreaterThan(scroll.contentOffset.y, 0)
        XCTAssertEqual(scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom,
            scroll.contentSize.height, accuracy: 2, "The oldest retained event must be reachable")
        try capture(host.view, name: name + "-oldest")

        feed.clear()
        await settle(host.view)
        XCTAssertFalse(scrollViews(in: host.view).contains(where: { $0.contentSize.height > $0.bounds.height + 1 }),
            "The mounted page must return to its empty state without stale scroll content")
    }

    private func settle(_ view: UIView) async {
        for _ in 0..<5 {
            view.setNeedsLayout(); view.layoutIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func capture(_ view: UIView, name: String) throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 2_000)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Connections-" + name; attachment.lifetime = .keepAlways; add(attachment)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ConnectionsVisualQA")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
