import XCTest
import ObjectiveC

final class MacWorkspaceUITests: XCTestCase {
    private var originalQuiescenceImplementations: [(Method, IMP)] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Use the same Xcode 27 idle-notification workaround as the companion
        // tests; every transition below still waits for its actual UI controls.
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originalQuiescenceImplementations.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
    }

    override func tearDownWithError() throws {
        for (method, original) in originalQuiescenceImplementations {
            imp_removeBlock(method_setImplementation(method, original))
        }
        originalQuiescenceImplementations.removeAll()
    }

    func testForcedMacWorkspaceKeepsFriendVideoWhileChangingCompanionTabs() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchDiagnosticGame(arguments: [
            "--bound-ui-mac-workspace",
            "--bound-ui-friend-fixture",
            "--bound-ui-no-animations",
            // Launch arguments live in UserDefaults' higher-priority argument
            // domain, so this exercises Layout 12 without changing the device's
            // saved UI version or reference selections.
            "-bound.ui.version.v1", "2",
            "-bound.delta.pip.v1.dex.layout", "12",
            "-bound.delta.pip.v1.bosses.layout", "12"
        ])

        let workspace = element("bound.mac-workspace", in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 20))
        let friendVideo = element("bound.friend-screen", in: app)
        XCTAssertTrue(friendVideo.waitForExistence(timeout: 10))
        XCTAssertTrue(friendVideo.frame.width > 80 && friendVideo.frame.height > 50,
                      "The persistent friend-video region must have usable space.")
        let initialVideoFrame = friendVideo.frame
        let gameViewport = element("bound.game-screen", in: app)
        XCTAssertTrue(gameViewport.waitForExistence(timeout: 5))
        assertGameplayContinues(gameViewport, context: "initial Mac workspace")

        let tabs: [(String, String, String)] = [
            ("bound.mac-dex", "bound.rrdex", "bound.rrdex-search-open"),
            ("bound.mac-bosses", "bound.boss-guide", "bound.boss-picker"),
            ("bound.mac-notes", "bound.notes-editor", "bound.notes-editor"),
            ("bound.mac-types", "bound.type-chart", "bound.type-chart-image")
        ]
        var visibleMiddleContent = "bound.rrdex"
        for (tabID, contentID, controlID) in tabs {
            let tab = app.buttons[tabID]
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "Missing workspace tab \(tabID)")
            XCTAssertTrue(tab.isHittable, "Workspace tab \(tabID) must be usable")
            tab.tap()

            XCTAssertTrue(element(contentID, in: app).waitForExistence(timeout: 10),
                          "Selecting \(tabID) must show its existing companion content")
            XCTAssertTrue(element(controlID, in: app).waitForExistence(timeout: 10),
                          "Selecting \(tabID) must retain its existing controls")
            if tabID == "bound.mac-dex" || tabID == "bound.mac-bosses" {
                visibleMiddleContent = contentID
            }
            XCTAssertTrue(element(visibleMiddleContent, in: app).exists,
                          "Notes and Types must leave the independent middle reference visible")
            XCTAssertTrue(friendVideo.exists, "Changing companion content must not remove friend video")
            XCTAssertEqual(friendVideo.frame.minX, initialVideoFrame.minX, accuracy: 1)
            XCTAssertEqual(friendVideo.frame.minY, initialVideoFrame.minY, accuracy: 1)
            XCTAssertEqual(friendVideo.frame.width, initialVideoFrame.width, accuracy: 1)
            XCTAssertEqual(friendVideo.frame.height, initialVideoFrame.height, accuracy: 1)
            attachScreenshot(named: "Mac-workspace-\(tabID)", from: app)
        }

        // Layout 12 reference content should remain mounted while another
        // workspace tab is active, preserving its selected category and scroll.
        app.buttons["bound.mac-dex"].tap()
        XCTAssertTrue(element("bound.rrdex", in: app).waitForExistence(timeout: 10))
        app.buttons["bound.rrdex-search-open"].tap()
        let dexSearch = app.textFields["bound.rrdex-search"]
        XCTAssertTrue(dexSearch.waitForExistence(timeout: 5))
        // Opening search already focuses the field. An extra tap can hit the
        // Simulator's software keyboard while its landscape layout settles.
        dexSearch.typeText("bulbasaur")
        let bulbasaur = app.buttons["bound.rrdex-suggestion-1"]
        XCTAssertTrue(bulbasaur.waitForExistence(timeout: 10))
        // Return selects the first suggestion and dismisses the software
        // keyboard, which covers the lower inspector in the iPad harness.
        dexSearch.typeText("\n")
        let selectedPokemon = app.staticTexts["bound.rrdex-pokemon"]
        XCTAssertTrue(selectedPokemon.waitForExistence(timeout: 5))
        XCTAssertEqual(selectedPokemon.label, "Bulbasaur")

        let dexDetails = app.scrollViews["bound.rrdex-layout12-details"]
        let learnset = element("bound.rrdex-layout12-learnset", in: app)
        XCTAssertTrue(dexDetails.waitForExistence(timeout: 5))
        XCTAssertTrue(learnset.waitForExistence(timeout: 5))
        // Learnset is a passive accessibility container. Scroll to the actual
        // method button, just as the iPhone Layout 12 regression does.
        let levelUp = app.buttons["bound.rrdex-layout12-learnset-method-Level up"]
        XCTAssertTrue(levelUp.waitForExistence(timeout: 5))
        for _ in 0..<14 {
            if !levelUp.frame.isEmpty && dexDetails.frame.contains(levelUp.frame) { break }
            let below = levelUp.frame.midY > dexDetails.frame.midY
            dexDetails.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.8 : 0.4))
                .press(forDuration: 0.1,
                       thenDragTo: dexDetails.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.4 : 0.8)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            // Quiescence is disabled, so let the scroll geometry settle.
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Xcode 27 can report these nested-host buttons as nonhittable even
        // when a normal tap works. Verify visible bounds and the tap's result.
        XCTAssertFalse(levelUp.frame.isEmpty)
        XCTAssertTrue(dexDetails.frame.contains(levelUp.frame), "The entire Level Up button must be inside the details viewport.")
        XCTAssertTrue(app.frame.contains(levelUp.frame), "The Level Up button must be onscreen.")
        levelUp.tap()
        let levelUpSelected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: levelUp)
        XCTAssertEqual(XCTWaiter.wait(for: [levelUpSelected], timeout: 5), .completed)
        let dexList = app.scrollViews["bound.rrdex-layout12-learnset-list"]
        XCTAssertTrue(dexList.waitForExistence(timeout: 5))
        let dexMoves = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "bound.rrdex-layout12-learnset-move-entry-")
        )
        XCTAssertTrue(dexMoves.firstMatch.waitForExistence(timeout: 5))
        let initialDexMove = try XCTUnwrap(dexMoves.allElementsBoundByIndex.first { move in
            !move.frame.isEmpty && dexList.frame.insetBy(dx: 0, dy: 1).contains(move.frame)
        }, "A Level Up move should be visible before scrolling the learnset.")
        let initialDexMoveID = initialDexMove.identifier
        let initialDexMoveY = initialDexMove.frame.minY
        dexList.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
            .press(forDuration: 0.1,
                   thenDragTo: dexList.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        Thread.sleep(forTimeInterval: 0.5)
        let scrolledDexMove = element(initialDexMoveID, in: app)
        XCTAssertTrue(!scrolledDexMove.exists || scrolledDexMove.frame.minY < initialDexMoveY - 5,
                      "The learnset must actually scroll before its position is tested across tab changes.")
        let rememberedDexMove = try XCTUnwrap(dexMoves.allElementsBoundByIndex.first { move in
            !move.frame.isEmpty && dexList.frame.insetBy(dx: 0, dy: 1).contains(move.frame)
        }, "A Level up move should be visible after scrolling the learnset.")
        let rememberedDexMoveID = rememberedDexMove.identifier
        let rememberedDexMoveFrame = rememberedDexMove.frame

        for bottomTab in ["bound.mac-notes", "bound.mac-types"] {
            app.buttons[bottomTab].tap()
            XCTAssertTrue(dexList.exists, "Changing the bottom box must leave the Dex learnset mounted.")
            XCTAssertEqual(levelUp.value as? String, "Selected",
                           "Changing the bottom box must preserve the selected learnset category.")
            XCTAssertEqual(element(rememberedDexMoveID, in: app).frame.minY, rememberedDexMoveFrame.minY, accuracy: 1,
                           "Changing the bottom box must preserve the middle Dex scroll position.")
        }

        app.buttons["bound.mac-bosses"].tap()
        XCTAssertTrue(element("bound.boss-guide", in: app).waitForExistence(timeout: 10))
        app.buttons["bound.mac-notes"].tap()
        XCTAssertTrue(element("bound.notes-editor", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("bound.boss-guide", in: app).exists)
        app.buttons["bound.mac-dex"].tap()
        XCTAssertTrue(dexList.waitForExistence(timeout: 10), "Returning to Dex should reopen the learnset.")
        XCTAssertEqual(levelUp.value as? String, "Selected", "The Level up category should remain selected.")
        let restoredDexMove = element(rememberedDexMoveID, in: app)
        XCTAssertTrue(restoredDexMove.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredDexMove.frame.minY, rememberedDexMoveFrame.minY, accuracy: 1,
                       "Returning to Dex after switching through Boss and Notes should restore learnset scroll.")

        XCTAssertTrue(gameViewport.exists)
        XCTAssertGreaterThan(gameViewport.frame.width, 100, "The live gameplay viewport must remain visible")
        XCTAssertGreaterThan(gameViewport.frame.height, 100, "The live gameplay viewport must remain visible")

        openWorkspaceActions(in: app)
        let friends = app.buttons["bound.mac-friends"].firstMatch
        XCTAssertTrue(friends.waitForExistence(timeout: 5), "Friends must remain reachable")
        friends.tap()
        XCTAssertTrue(app.navigationBars["Friends"].waitForExistence(timeout: 5))
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 5), "Closing Friends must return to the workspace")
        assertGameplayContinues(gameViewport, context: "after Friends closes")

        openWorkspaceActions(in: app)
        let settings = app.buttons["bound.mac-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings must remain reachable")
        settings.tap()
        let settingsClose = app.buttons["bound.settings-close"]
        XCTAssertTrue(settingsClose.waitForExistence(timeout: 5))
        settingsClose.tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 5), "Closing Settings must return to the workspace")
        assertGameplayContinues(gameViewport, context: "after Settings closes")

        openWorkspaceActions(in: app)
        let menu = app.buttons["bound.mac-menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Game menu must remain reachable")
        menu.tap()
        let resume = app.buttons["Resume"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "Game menu should offer Resume")
        resume.tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 5), "Resuming must return to the workspace")
        assertGameplayContinues(gameViewport, context: "after Menu Resume")
        app.terminate()
    }

    func testMacSidebarResizesCollapsesAndFitsIndependentTypeChart() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchDiagnosticGame(arguments: [
            "--bound-ui-mac-workspace",
            "--bound-ui-friend-fixture",
            "--bound-ui-no-animations"
        ])
        let workspace = element("bound.mac-workspace", in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 20))
        let friend = element("bound.friend-screen", in: app)
        let middle = element("bound.mac-mid", in: app)
        let bottom = element("bound.mac-bottom", in: app)
        let game = element("bound.game-screen", in: app)
        XCTAssertTrue(friend.waitForExistence(timeout: 10))
        XCTAssertTrue(middle.waitForExistence(timeout: 5))
        XCTAssertTrue(bottom.waitForExistence(timeout: 5))
        XCTAssertTrue(game.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["bound.mac-friends-connect"].exists,
                      "The friend connection control must remain available below the video.")

        app.buttons["bound.mac-types"].tap()
        let chart = element("bound.type-chart-image", in: app)
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        XCTAssertTrue(element("bound.rrdex", in: app).exists,
                      "The Types box must coexist with the middle Dex.")
        assertContained(chart, in: bottom, context: "before sidebar resizing")

        let initialFriendWidth = friend.frame.width
        let initialGameWidth = game.frame.width
        let sidebarResize = element("bound.mac-sidebar-resize", in: app)
        XCTAssertTrue(sidebarResize.waitForExistence(timeout: 5))
        let sideStart = sidebarResize.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        sideStart.press(forDuration: 0.1, thenDragTo: sideStart.withOffset(CGVector(dx: -70, dy: 0)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        let wider = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            friend.frame.width > initialFriendWidth + 20 && game.frame.width < initialGameWidth - 20
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wider], timeout: 5), .completed,
                       "Dragging the sidebar edge left must expand its content and give gameplay the remaining width.")
        assertContained(chart, in: bottom, context: "after sidebar resizing")

        let divider = element("bound.mac-top-mid-resize", in: app)
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        let initialFriendHeight = friend.frame.height
        let initialMiddleY = middle.frame.minY
        let dividerStart = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        dividerStart.press(forDuration: 0.1, thenDragTo: dividerStart.withOffset(CGVector(dx: 0, dy: 50)),
                           withVelocity: .slow, thenHoldForDuration: 0.2)
        let taller = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            friend.frame.height > initialFriendHeight + 10 && middle.frame.minY > initialMiddleY + 10
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [taller], timeout: 5), .completed,
                       "Dragging the top/mid divider must redistribute their vertical space.")
        XCTAssertTrue(element("bound.rrdex", in: app).exists)
        assertContained(chart, in: bottom, context: "after top/mid resizing")

        let expandedFriendFrame = friend.frame
        let sidebarGameWidth = game.frame.width
        let toggle = app.buttons["bound.mac-sidebar-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            game.frame.width > sidebarGameWidth + 100 && toggle.value as? String == "Collapsed"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed,
                       "Collapsing the sidebar must return its space to gameplay.")
        // Retained accessibility containers may remain in XCTest snapshots;
        // their actual controls must be hidden and unable to receive input.
        XCTAssertFalse(app.buttons["bound.mac-dex"].isHittable)
        XCTAssertFalse(app.buttons["bound.mac-types"].isHittable)
        XCTAssertTrue(toggle.exists, "The sidebar must be reopenable from the top-right icon.")
        assertGameplayContinues(game, context: "with sidebar collapsed")
        attachScreenshot(named: "Mac-workspace-collapsed-sidebar", from: app)

        toggle.tap()
        XCTAssertTrue(middle.waitForExistence(timeout: 5))
        XCTAssertTrue(friend.waitForExistence(timeout: 5))
        XCTAssertTrue(chart.waitForExistence(timeout: 5), "Reopening must preserve the bottom Types selection.")
        XCTAssertEqual(friend.frame.width, expandedFriendFrame.width, accuracy: 1)
        XCTAssertEqual(friend.frame.height, expandedFriendFrame.height, accuracy: 1)
        XCTAssertTrue(element("bound.rrdex", in: app).exists)
        assertContained(chart, in: bottom, context: "after reopening the sidebar")
        attachScreenshot(named: "Mac-workspace-resized-sidebar", from: app)
        app.terminate()
    }

    func testOrdinaryIOSLaunchKeepsExistingCompanionAndHidesMacWorkspace() throws {
        guard !ProcessInfo.processInfo.isiOSAppOnMac else {
            throw XCTSkip("This case verifies the unforced iOS path; run it on an iPhone or iPad Simulator.")
        }
        let app = launchDiagnosticGame(arguments: [
            "--bound-ui-friend-fixture",
            "--bound-ui-reset-layout",
            "--bound-ui-no-animations"
        ])
        XCTAssertFalse(element("bound.mac-workspace", in: app).exists)

        let friendControl = app.buttons["bound.panel-cycle.1"]
        XCTAssertTrue(friendControl.waitForExistence(timeout: 15), "The current iOS Friend control should remain available")
        XCTAssertEqual(friendControl.value as? String, "Friend")
        XCTAssertTrue(app.buttons["bound.panel-cycle.2"].exists, "The current iOS Multiview control should remain available")
        XCTAssertTrue(element("bound.friend-screen", in: app).exists)
        XCTAssertFalse(app.buttons["bound.mac-dex"].exists)
        app.terminate()
    }

    func testMacWorkspaceSettingsExposeSharedControllerOptionsAndBindings() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchDiagnosticGame(arguments: [
            "--bound-ui-mac-workspace",
            "--bound-ui-no-animations"
        ])

        let workspace = element("bound.mac-workspace", in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 20))
        openWorkspaceActions(in: app)
        let settings = app.buttons["bound.mac-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Mac workspace Settings must be reachable")
        settings.tap()

        XCTAssertTrue(element("bound.settings-root", in: app).waitForExistence(timeout: 10))
        let controlsEntry = app.buttons["bound.settings-controls"]
        XCTAssertTrue(controlsEntry.waitForExistence(timeout: 5))
        controlsEntry.tap()

        XCTAssertTrue(app.switches["bound.controller-mode-enabled"].waitForExistence(timeout: 5),
                      "The shared Controls screen must expose Controller Mode")
        XCTAssertTrue(app.switches["bound.controller-multiview"].waitForExistence(timeout: 5),
                      "The shared Controls screen must expose controller Multiview control")

        let controllers = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Controllers")).firstMatch
        XCTAssertTrue(controllers.waitForExistence(timeout: 5), "Controls must retain its controller bindings entry")
        controllers.tap()
        XCTAssertTrue(app.navigationBars["Controllers"].waitForExistence(timeout: 5))
        let playerOne = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Player 1")).firstMatch
        XCTAssertTrue(playerOne.waitForExistence(timeout: 5), "Controller bindings must offer Player 1")
        playerOne.tap()
        XCTAssertTrue(app.navigationBars["Player 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This Device"].waitForExistence(timeout: 5),
                      "Player 1 bindings must show the built-in touch controller without requiring external hardware")
        app.terminate()
    }

    private func launchDiagnosticGame(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        if arguments.contains("--bound-ui-mac-workspace") {
            XCUIDevice.shared.orientation = .landscapeRight
        }
        app.launchArguments = arguments
        app.launch()

        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 2) { close.tap() }

        let search = app.searchFields["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "Wait for the diagnostic ROM library")
        search.tap()
        search.typeText("BoundRRDexDiagnostic")
        search.typeText("\n")
        let game = app.collectionViews.cells.containing(.staticText, identifier: "BoundRRDexDiagnostic").firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 20), "The offline diagnostic ROM must be installed by the UI-test fixture setup")
        game.tap()
        return app
    }

    private func openWorkspaceActions(in app: XCUIApplication) {
        let actions = app.buttons["bound.mac-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5), "Workspace actions must remain reachable.")
        actions.tap()
    }

    private func assertContained(_ child: XCUIElement, in container: XCUIElement, context: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(child.frame.isEmpty, "Content must have visible size \(context)", file: file, line: line)
        XCTAssertTrue(container.frame.insetBy(dx: -1, dy: -1).contains(child.frame),
                      "Content must fit its own box \(context): \(child.frame) in \(container.frame)",
                      file: file, line: line)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachScreenshot(named name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertGameplayContinues(_ game: XCUIElement, context: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard let initial = gameplayPixels(game) else {
            XCTFail("Could not capture gameplay pixels \(context)", file: file, line: line)
            return
        }
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.2)
            if let next = gameplayPixels(game), next != initial { return }
        }
        XCTFail("Gameplay pixels stayed unchanged \(context)", file: file, line: line)
    }

    private func gameplayPixels(_ game: XCUIElement) -> Data? {
        guard let image = game.screenshot().image.cgImage,
              let pixelData = image.dataProvider?.data else { return nil }
        return pixelData as Data
    }
}
