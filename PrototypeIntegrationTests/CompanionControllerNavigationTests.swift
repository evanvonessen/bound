import XCTest
import UIKit
import SwiftUI
@testable import Delta

@MainActor
final class CompanionControllerNavigationTests: XCTestCase {
    private struct MountedHost<Content: View> {
        let window: UIWindow
        let host: UIHostingController<Content>
        let previousKeyWindow: UIWindow?
    }

    private func mount<Content: View>(_ content: Content) async throws -> MountedHost<Content> {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        let mounted = MountedHost(window: window, host: host, previousKeyWindow: previousKeyWindow)
        _ = await settle(mounted)
        return mounted
    }

    private func unmount<Content: View>(_ mounted: MountedHost<Content>) {
        mounted.host.dismiss(animated: false)
        mounted.window.isHidden = true
        mounted.window.rootViewController = nil
        mounted.previousKeyWindow?.makeKeyAndVisible()
    }

    @discardableResult
    private func settle<Content: View>(
        _ mounted: MountedHost<Content>,
        timeout: TimeInterval = 2,
        until condition: () -> Bool = { true }
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            mounted.host.view.setNeedsLayout()
            mounted.host.view.layoutIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
            if condition() { return true }
        } while Date() < deadline
        return condition()
    }

    private func waitForStableOffset(_ scrollView: UIScrollView, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = scrollView.contentOffset.y
        var stableSamples = 0
        while Date() < deadline && stableSamples < 8 {
            try? await Task.sleep(for: .milliseconds(50))
            let current = scrollView.contentOffset.y
            if abs(current - previous) < 0.02 {
                stableSamples += 1
            } else {
                stableSamples = 0
            }
            previous = current
        }
    }

    func testDexControllerBrowsingSelectionAndBackPersistOnlyConfirmedSpecies() async throws {
        await BoundReferenceCatalogStore.shared.loadIfNeeded()
        let catalog = try XCTUnwrap(BoundReferenceCatalogStore.shared.dex)
        let gameID = "CTRLDEX_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let preferences = BoundRRDexPreferences()
        let original = BoundRRDexPreferences.Choice(speciesID: catalog.species[12].id, save: nil)
        preferences.write(original, gameID: gameID)
        defer { UserDefaults.standard.removeObject(forKey: "bound.rrdex.choice.v1." + gameID) }
        var presentationStates: [Bool] = []
        let mounted = try await mount(BoundRRDexView(gameID: gameID, presentationChanged: { presentationStates.append($0) }))
        defer { unmount(mounted) }
        let host = mounted.host

        BoundControllerNavigationEvent.post(command: .nextItem, gameID: gameID, content: .dex)
        let advanced = await settle(mounted, until: { preferences.read(gameID: gameID).speciesID == catalog.species[13].id })
        XCTAssertTrue(advanced)
        XCTAssertEqual(preferences.read(gameID: gameID).speciesID, catalog.species[13].id)
        BoundControllerNavigationEvent.post(command: .previousItem, gameID: gameID, content: .dex)
        let returned = await settle(mounted, until: { preferences.read(gameID: gameID).speciesID == original.speciesID })
        XCTAssertTrue(returned)
        XCTAssertEqual(preferences.read(gameID: gameID).speciesID, original.speciesID)

        BoundControllerNavigationEvent.post(command: .select, gameID: gameID, content: .dex)
        let opened = await settle(mounted, until: { host.presentedViewController != nil && presentationStates.contains(true) })
        XCTAssertTrue(opened, "The chooser should be presented and enter the existing paused-sheet state.")
        BoundControllerNavigationEvent.post(command: .nextItem, gameID: gameID, content: .dex)
        await settle(mounted)
        BoundControllerNavigationEvent.post(command: .select, gameID: gameID, content: .dex)
        let committedAndClosed = await settle(mounted, timeout: 5, until: {
            preferences.read(gameID: gameID).speciesID == catalog.species[13].id &&
                host.presentedViewController == nil && presentationStates.last == false
        })
        XCTAssertTrue(committedAndClosed, "Select should commit the highlighted species and resume after dismissal.")
        XCTAssertEqual(preferences.read(gameID: gameID).speciesID, catalog.species[13].id)

        BoundControllerNavigationEvent.post(command: .select, gameID: gameID, content: .dex)
        let reopened = await settle(mounted, until: { host.presentedViewController != nil })
        XCTAssertTrue(reopened)
        BoundControllerNavigationEvent.post(command: .back, gameID: gameID, content: .dex)
        let backedOut = await settle(mounted, timeout: 5, until: {
            host.presentedViewController == nil && presentationStates.last == false
        })
        XCTAssertTrue(backedOut, "Back should dismiss the chooser and release its pause.")
        XCTAssertEqual(preferences.read(gameID: gameID).speciesID, catalog.species[13].id,
                       "Back closes the chooser without changing the committed species.")
    }

    func testBossControllerPickerAndTeamMemberNavigation() async throws {
        await BoundReferenceCatalogStore.shared.loadIfNeeded()
        let catalog = try XCTUnwrap(BoundReferenceCatalogStore.shared.bosses)
        let gameID = "CTRLBOSS_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let preferences = BoundBossGuidePreferences()
        let startingTeam = catalog.defaultTeam
        let original = BoundBossGuideSelection(teamID: startingTeam.id, pokemonIndex: 0)
        preferences.write(original, gameID: gameID, catalog: catalog)
        defer { UserDefaults.standard.removeObject(forKey: "bound.boss-guide.selection.v1." + gameID) }
        var presentationStates: [Bool] = []
        let mounted = try await mount(BoundBossGuideView(gameID: gameID, presentationChanged: { presentationStates.append($0) }))
        defer { unmount(mounted) }
        let host = mounted.host

        BoundControllerNavigationEvent.post(command: .nextItem, gameID: gameID, content: .bosses)
        let advanced = await settle(mounted, until: {
            preferences.read(gameID: gameID, catalog: catalog).pokemonIndex == 1
        })
        XCTAssertTrue(advanced)
        XCTAssertEqual(preferences.read(gameID: gameID, catalog: catalog),
                       BoundBossGuideSelection(teamID: startingTeam.id, pokemonIndex: 1))
        BoundControllerNavigationEvent.post(command: .previousItem, gameID: gameID, content: .bosses)
        let returned = await settle(mounted, until: {
            preferences.read(gameID: gameID, catalog: catalog).pokemonIndex == 0
        })
        XCTAssertTrue(returned)
        XCTAssertEqual(preferences.read(gameID: gameID, catalog: catalog), original)

        let candidates = catalog.teams(matching: "")
        let originalIndex = try XCTUnwrap(candidates.firstIndex { $0.id == startingTeam.id })
        let nextTeam = candidates[(originalIndex + 1) % candidates.count]
        BoundControllerNavigationEvent.post(command: .select, gameID: gameID, content: .bosses)
        let opened = await settle(mounted, until: { host.presentedViewController != nil && presentationStates.contains(true) })
        XCTAssertTrue(opened, "The boss picker should be presented and enter the existing paused-sheet state.")
        BoundControllerNavigationEvent.post(command: .nextItem, gameID: gameID, content: .bosses)
        await settle(mounted)
        BoundControllerNavigationEvent.post(command: .select, gameID: gameID, content: .bosses)
        let committedAndClosed = await settle(mounted, timeout: 5, until: {
            preferences.read(gameID: gameID, catalog: catalog) ==
                BoundBossGuideSelection(teamID: nextTeam.id, pokemonIndex: 0) &&
                host.presentedViewController == nil && presentationStates.last == false
        })
        XCTAssertTrue(committedAndClosed, "Select should commit the highlighted team and resume after dismissal.")
        XCTAssertEqual(preferences.read(gameID: gameID, catalog: catalog),
                       BoundBossGuideSelection(teamID: nextTeam.id, pokemonIndex: 0))

        BoundControllerNavigationEvent.post(command: .select, gameID: gameID, content: .bosses)
        let reopened = await settle(mounted, until: { host.presentedViewController != nil })
        XCTAssertTrue(reopened)
        BoundControllerNavigationEvent.post(command: .back, gameID: gameID, content: .bosses)
        let backedOut = await settle(mounted, timeout: 5, until: {
            host.presentedViewController == nil && presentationStates.last == false
        })
        XCTAssertTrue(backedOut, "Back should dismiss the boss picker and release its pause.")
        XCTAssertEqual(preferences.read(gameID: gameID, catalog: catalog).teamID, nextTeam.id,
                       "Back closes the picker without changing the committed team.")
    }

    func testScopedControllerScrollMovesVisibleScrollViewAndIgnoresOtherROMs() async throws {
        let gameID = "CTRLSCROLL_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let root = ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(0..<80, id: \.self) { index in
                    Text("Scrollable controller row \(index)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 44)
                }
            }.padding()
        }
        .frame(width: 360, height: 240)
        .boundControllerScroll(gameID: gameID, content: .dex)
        let mounted = try await mount(root)
        defer { unmount(mounted) }
        let scrollView = try XCTUnwrap(descendantScrollView(in: mounted.host.view))
        XCTAssertGreaterThan(scrollView.contentSize.height, scrollView.bounds.height)
        BoundControllerNavigationEvent.post(command: .scrollDown, gameID: gameID, content: .dex)
        let moved = await settle(mounted, until: { scrollView.contentOffset.y > 0 })
        XCTAssertTrue(moved)
        await waitForStableOffset(scrollView)
        scrollView.layer.removeAllAnimations()
        let oldOffset = scrollView.contentOffset.y
        BoundControllerNavigationEvent.post(command: .scrollDown, gameID: "OTHER_ROM", content: .dex)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(scrollView.contentOffset.y, oldOffset, accuracy: 0.5,
                       "Events for another ROM must not scroll this panel.")
    }

    private func descendantScrollView(in root: UIView) -> UIScrollView? {
        if let scroll = root as? UIScrollView { return scroll }
        for child in root.subviews {
            if let scroll = descendantScrollView(in: child) { return scroll }
        }
        return nil
    }
}
