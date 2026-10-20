import XCTest
import UIKit
import SwiftUI
@testable import Delta

@MainActor
final class MultiviewDexNavigationTests: XCTestCase {
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
    private func settle<Content: View>(_ mounted: MountedHost<Content>, timeout: TimeInterval = 3,
                                      until condition: () -> Bool = { true }) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(40))
            if condition() { return true }
        } while Date() < deadline
        return condition()
    }

    func testDexFocusPathPickerLearnsetWrapAndScopedScrolling() async throws {
        await BoundReferenceCatalogStore.shared.loadIfNeeded()
        let catalog = try XCTUnwrap(BoundReferenceCatalogStore.shared.dex)
        let pokemon = try XCTUnwrap(catalog.species.first { candidate in
            let availableMethods = catalog.learnsetMethods(for: candidate)
            guard let lastMethod = availableMethods.last, availableMethods.count > 1 else { return false }
            return catalog.learnsetRows(for: candidate, save: nil, method: lastMethod, query: "").count >= 8
        })
        let gameID = "MULTIVIEW_DEX_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let defaults = UserDefaults.standard
        let oldEnabled = defaults.object(forKey: BoundControllerMultiviewPreferences.key)
        let oldLayout = defaults.object(forKey: BoundReferenceLayoutPreferences.dexKey)
        let choiceKey = "bound.rrdex.choice.v1." + gameID
        defaults.set(true, forKey: BoundControllerMultiviewPreferences.key)
        defaults.set(12, forKey: BoundReferenceLayoutPreferences.dexKey)
        BoundRRDexPreferences().write(.init(speciesID: pokemon.id, save: nil), gameID: gameID)
        defer {
            if let oldEnabled { defaults.set(oldEnabled, forKey: BoundControllerMultiviewPreferences.key) }
            else { defaults.removeObject(forKey: BoundControllerMultiviewPreferences.key) }
            if let oldLayout { defaults.set(oldLayout, forKey: BoundReferenceLayoutPreferences.dexKey) }
            else { defaults.removeObject(forKey: BoundReferenceLayoutPreferences.dexKey) }
            defaults.removeObject(forKey: choiceKey)
        }

        let mounted = try await mount(BoundRRDexView(gameID: gameID, floating: true, inlineSearch: true,
                                                       presentationChanged: { _ in })
            .frame(width: 360, height: 260))
        defer { unmount(mounted) }
        let host = mounted.host
        let marker = try await waitForNavigationMarker(mounted)
        let mainDetails = try XCTUnwrap(BoundControllerNavigationScrollCoordinator.resolveScrollView(
            for: marker, command: .scrollDown))
        XCTAssertGreaterThan(mainDetails.contentSize.height, mainDetails.bounds.height)
        BoundControllerNavigationEvent.post(command: .scrollDown, gameID: gameID, content: .dex)
        let mainScrolled = await settle(mounted, until: { mainDetails.contentOffset.y > 24 })
        XCTAssertTrue(mainScrolled, "The right stick scroll command should move the visible main Dex card.")

        // The first focus stop is the Pokémon search icon. A opens the existing picker.
        let speciesScrollBeforeFocus = mainDetails.contentOffset.y
        BoundControllerNavigationEvent.post(command: .clearFocus, gameID: gameID, content: .dex)
        BoundControllerNavigationEvent.post(command: .focusDown, gameID: gameID, content: .dex)
        let speciesSearchVisible = await settle(mounted, until: {
            mainDetails.contentOffset.y < speciesScrollBeforeFocus - 8
        })
        XCTAssertTrue(speciesSearchVisible, "Focusing species search should scroll the Pokémon heading back into view.")
        attachAccessibilityScreenshot(of: host.view, named: "Dex species search focused")
        BoundControllerNavigationEvent.post(command: .select, gameID: gameID, content: .dex)
        let pickerOpened = await settle(mounted, until: { host.presentedViewController != nil })
        XCTAssertTrue(pickerOpened)
        BoundControllerNavigationEvent.post(command: .back, gameID: gameID, content: .dex)
        let pickerCancelled = await settle(mounted, until: { host.presentedViewController == nil })
        XCTAssertTrue(pickerCancelled, "B should cancel the species picker without committing a selection.")
        XCTAssertEqual(BoundRRDexPreferences().read(gameID: gameID).speciesID, pokemon.id)

        // A second picker run moves down through candidates and A commits that choice.
        BoundControllerNavigationEvent.post(command: .clearFocus, gameID: gameID, content: .dex)
        BoundControllerNavigationEvent.post(command: .focusDown, gameID: gameID, content: .dex)
        BoundControllerNavigationEvent.post(command: .select, gameID: gameID, content: .dex)
        _ = await settle(mounted, until: { host.presentedViewController != nil })
        BoundControllerNavigationEvent.post(command: .focusDown, gameID: gameID, content: .dex)
        BoundControllerNavigationEvent.post(command: .select, gameID: gameID, content: .dex)
        let selectedCandidate = await settle(mounted, timeout: 5, until: {
            host.presentedViewController == nil && BoundRRDexPreferences().read(gameID: gameID).speciesID != pokemon.id
        })
        XCTAssertTrue(selectedCandidate, "D-pad down followed by A should commit the highlighted Pokémon.")

        // Starting over, the second focus stop opens the learnset search view.
        BoundControllerNavigationEvent.post(command: .previousItem, gameID: gameID, content: .dex)
        let restoredSpecies = await settle(mounted, until: {
            BoundRRDexPreferences().read(gameID: gameID).speciesID == pokemon.id
        })
        XCTAssertTrue(restoredSpecies)
        var mainScrollAfterSearch = try XCTUnwrap(BoundControllerNavigationScrollCoordinator.resolveScrollView(
            for: marker, command: .scrollDown))
        let moveSearchOffsetBeforeFocus = mainScrollAfterSearch.contentOffset.y
        BoundControllerNavigationEvent.post(command: .clearFocus, gameID: gameID, content: .dex)
        BoundControllerNavigationEvent.post(command: .focusDown, gameID: gameID, content: .dex)
        BoundControllerNavigationEvent.post(command: .focusDown, gameID: gameID, content: .dex)
        let moveSearchVisible = await settle(mounted, until: {
            mainScrollAfterSearch.contentOffset.y > moveSearchOffsetBeforeFocus + 8
        })
        XCTAssertTrue(moveSearchVisible, "Focusing learnset search should scroll the learnset section into view.")
        attachAccessibilityScreenshot(of: host.view, named: "Dex learnset search focused")
        BoundControllerNavigationEvent.post(command: .select, gameID: gameID, content: .dex)
        let searchOpened = await settle(mounted, until: {
            findView(identifier: "bound.rrdex-layout12-learnset-search", in: host.view) != nil
        })
        XCTAssertTrue(searchOpened, "The second focus stop should open the expanded learnset search.")
        BoundControllerNavigationEvent.post(command: .back, gameID: gameID, content: .dex)
        let returnedToMain = await settle(mounted, until: {
            guard let scroll = BoundControllerNavigationScrollCoordinator.resolveScrollView(for: marker, command: .scrollDown),
                  scroll !== mainDetails else { return false }
            mainScrollAfterSearch = scroll
            return true
        })
        XCTAssertTrue(returnedToMain, "B should return from the expanded learnset to the main Dex card.")

        // After returning, down enters the first method. Left and right wrap across the method row.
        BoundControllerNavigationEvent.post(command: .focusDown, gameID: gameID, content: .dex)
        let methodFocused = await settle(mounted, until: {
            mainScrollAfterSearch.contentOffset.y > 0
        })
        XCTAssertTrue(methodFocused, "D-pad down should keep the learnset method tabs in the visible section.")
        attachAccessibilityScreenshot(of: host.view, named: "Dex first method focused")
        BoundControllerNavigationEvent.post(command: .focusLeft, gameID: gameID, content: .dex)
        BoundControllerNavigationEvent.post(command: .focusRight, gameID: gameID, content: .dex)
        BoundControllerNavigationEvent.post(command: .focusLeft, gameID: gameID, content: .dex)
        _ = await settle(mounted)
        attachAccessibilityScreenshot(of: host.view, named: "Dex wrapped to last learnset method")
        BoundControllerNavigationEvent.post(command: .select, gameID: gameID, content: .dex)
        var expandedScroll: UIScrollView?
        let lastMethodOpened = await settle(mounted, until: {
            guard let scroll = BoundControllerNavigationScrollCoordinator.resolveScrollView(for: marker, command: .scrollDown),
                  scroll !== mainScrollAfterSearch else { return false }
            expandedScroll = scroll
            return true
        })
        XCTAssertTrue(lastMethodOpened, "A should open the currently highlighted learn method.")
        _ = await settle(mounted)
        attachAccessibilityScreenshot(of: host.view, named: "Dex last learnset method selected")

        // The same right-stick event now targets the expanded learnset list instead of main details.
        let expandedList = try XCTUnwrap(expandedScroll)
        XCTAssertFalse(expandedList === mainScrollAfterSearch,
                       "The visible expanded learnset should supply the active scroll target.")
        XCTAssertGreaterThan(expandedList.contentSize.height, expandedList.bounds.height)
        BoundControllerNavigationEvent.post(command: .scrollDown, gameID: gameID, content: .dex)
        let expandedScrolled = await settle(mounted, until: { expandedList.contentOffset.y > 0 })
        XCTAssertTrue(expandedScrolled, "Right-stick scroll should follow the visible expanded learnset.")

        // Clear focus restores the legacy A action (the species chooser) without retaining a highlight.
        BoundControllerNavigationEvent.post(command: .back, gameID: gameID, content: .dex)
        _ = await settle(mounted, until: {
            guard let scroll = BoundControllerNavigationScrollCoordinator.resolveScrollView(for: marker, command: .scrollDown),
                  scroll !== expandedList else { return false }
            mainScrollAfterSearch = scroll
            return true
        })
        BoundControllerNavigationEvent.post(command: .clearFocus, gameID: gameID, content: .dex)
        BoundControllerNavigationEvent.post(command: .select, gameID: gameID, content: .dex)
        let legacyPickerOpened = await settle(mounted, until: { host.presentedViewController != nil })
        XCTAssertTrue(legacyPickerOpened, "clearFocus should leave the established A behavior available.")
    }

    private func waitForNavigationMarker<Content: View>(
        _ mounted: MountedHost<Content>, timeout: TimeInterval = 3
    ) async throws -> BoundControllerNavigationMarkerView {
        let ready = await settle(mounted, timeout: timeout, until: {
            findNavigationMarker(in: mounted.host.view) != nil
        })
        XCTAssertTrue(ready, "The hosted Dex view should attach its controller navigation marker.")
        return try XCTUnwrap(findNavigationMarker(in: mounted.host.view))
    }

    private func findNavigationMarker(in view: UIView) -> BoundControllerNavigationMarkerView? {
        if let marker = view as? BoundControllerNavigationMarkerView { return marker }
        for child in view.subviews {
            if let marker = findNavigationMarker(in: child) { return marker }
        }
        return nil
    }

    private func findView(identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews {
            if let result = findView(identifier: identifier, in: child) { return result }
        }
        return nil
    }

    private func attachAccessibilityScreenshot(of view: UIView, named name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image(actions: { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        })
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
