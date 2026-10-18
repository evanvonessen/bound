import XCTest

final class MacWorkspaceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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
        for (tabID, contentID, controlID) in tabs {
            let tab = app.buttons[tabID]
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "Missing workspace tab \(tabID)")
            XCTAssertTrue(tab.isHittable, "Workspace tab \(tabID) must be usable")
            tab.tap()

            XCTAssertTrue(element(contentID, in: app).waitForExistence(timeout: 10),
                          "Selecting \(tabID) must show its existing companion content")
            XCTAssertTrue(element(controlID, in: app).waitForExistence(timeout: 10),
                          "Selecting \(tabID) must retain its existing controls")
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
        for _ in 0..<14 {
            if learnset.isHittable && dexDetails.frame.contains(learnset.frame) { break }
            let below = !learnset.exists || learnset.frame.midY > dexDetails.frame.midY
            dexDetails.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.8 : 0.4))
                .press(forDuration: 0.1,
                       thenDragTo: dexDetails.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.4 : 0.8)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(learnset.isHittable, "The Layout 12 learnset control must be reachable in the workspace.")
        let levelUp = app.buttons["bound.rrdex-layout12-learnset-method-Level up"]
        XCTAssertTrue(levelUp.waitForExistence(timeout: 5))
        levelUp.tap()
        XCTAssertEqual(levelUp.value as? String, "Selected")
        let dexList = app.scrollViews["bound.rrdex-layout12-learnset-list"]
        XCTAssertTrue(dexList.waitForExistence(timeout: 5))
        let dexMoves = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "bound.rrdex-layout12-learnset-move-")
        )
        dexList.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
            .press(forDuration: 0.1,
                   thenDragTo: dexList.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        let rememberedDexMove = try XCTUnwrap(dexMoves.allElementsBoundByIndex.first { move in
            dexList.frame.insetBy(dx: 0, dy: 1).contains(move.frame)
        }, "A Level up move should be visible after scrolling the learnset.")
        let rememberedDexMoveID = rememberedDexMove.identifier
        let rememberedDexMoveFrame = rememberedDexMove.frame

        app.buttons["bound.mac-bosses"].tap()
        XCTAssertTrue(element("bound.boss-guide", in: app).waitForExistence(timeout: 10))
        app.buttons["bound.mac-notes"].tap()
        XCTAssertTrue(element("bound.notes-editor", in: app).waitForExistence(timeout: 10))
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

        let friends = app.buttons["bound.mac-friends"].firstMatch
        XCTAssertTrue(friends.waitForExistence(timeout: 5), "Friends must remain reachable")
        friends.tap()
        XCTAssertTrue(app.navigationBars["Friends"].waitForExistence(timeout: 5))
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 5), "Closing Friends must return to the workspace")
        assertGameplayContinues(gameViewport, context: "after Friends closes")

        let settings = app.buttons["bound.mac-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings must remain reachable")
        settings.tap()
        let settingsClose = app.buttons["bound.settings-close"]
        XCTAssertTrue(settingsClose.waitForExistence(timeout: 5))
        settingsClose.tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 5), "Closing Settings must return to the workspace")
        assertGameplayContinues(gameViewport, context: "after Settings closes")

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

        let cycle = app.buttons["bound.panel-cycle"]
        XCTAssertTrue(cycle.waitForExistence(timeout: 15), "The existing iOS companion control should remain available")
        XCTAssertEqual(cycle.value as? String, "Friend")
        XCTAssertTrue(element("bound.friend-screen", in: app).exists)
        XCTAssertFalse(app.buttons["bound.mac-dex"].exists)
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
