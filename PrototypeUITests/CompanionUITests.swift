import XCTest
import UIKit
import ObjectiveC

private func selectCompanion(_ name: String, in app: XCUIApplication) {
    let cycle = app.buttons["bound.panel-cycle"]
    XCTAssertTrue(cycle.waitForExistence(timeout: 15))
    resumeNativePause(in: app)
    for _ in 0..<3 {
        if cycle.value as? String == name { return }
        cycle.tap()
        XCTAssertFalse(app.buttons["Bound Settings"].exists, "Cycling panels must not open Delta's pause menu")
    }
    XCTAssertEqual(cycle.value as? String, name)
}

private func openNativePause(in app: XCUIApplication) {
    if app.buttons["Bound Settings"].exists { return }
    let menu = app.descendants(matching: .any).matching(identifier: "bound.native-menu").firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    menu.tap()
    XCTAssertTrue(app.buttons["Bound Settings"].waitForExistence(timeout: 5))
}

private func openBoundSettings(in app: XCUIApplication) {
    openNativePause(in: app)
    app.buttons["Bound Settings"].tap()
}

private func resumeNativePause(in app: XCUIApplication) {
    let resume = app.buttons["Resume"].firstMatch
    if resume.exists && resume.isHittable { resume.tap() }
}

private func closeBoundSheet(in app: XCUIApplication) {
    app.buttons["Done"].firstMatch.tap()
    resumeNativePause(in: app)
}

/// Actual DEBUG Simulator hit rectangles, read from the gameplay owner after native layout.
/// This is observation only: real gestures still select every corner and size.
private func actualPiPHitObstacles(in game: XCUIElement) throws -> [CGRect] {
    let value = try XCTUnwrap(game.value as? String)
    let prefix = "pip-hit-obstacles="
    XCTAssertTrue(value.hasPrefix(prefix))
    let rectangles = try value.dropFirst(prefix.count).split(separator: "|").map { field -> CGRect in
        let components = field.split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(components.count, 4)
        guard components.count == 4 else { throw NSError(domain: "Malformed hit obstacle", code: 1) }
        return CGRect(x: components[0], y: components[1], width: components[2], height: components[3])
    }
    XCTAssertGreaterThanOrEqual(rectangles.count, 8, "Observe native inputs and the full companion hit target")
    return rectangles
}

final class CompanionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func openGame(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // Legacy layout regression cases explicitly opt into Bound; the native
        // layout case removes this helper-only marker and exercises persistence.
        app.launchArguments = arguments.filter { $0 != "--bound-ui-native-layout" }
        if !arguments.contains("--bound-ui-native-layout") {
            app.launchArguments.append("--bound-ui-screen-layout-bound")
        }
        #if DEBUG
        app.launchArguments.append("--bound-ui-no-animations")
        #endif
        app.launch()
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 2) { close.tap() }
        let cell = app.collectionViews.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        cell.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        return app
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // Short Form drags avoid jumping past a lazily materialized row in landscape.
    private func scrollToSetting(_ target: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        for _ in 0..<40 {
            if target.exists && target.isHittable { return }
            let scrollDown = target.exists && target.frame.midY < form.frame.midY
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollDown ? 0.35 : 0.80))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollDown ? 0.65 : 0.50))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(target.isHittable)
    }

    private func waitForFrame(_ element: XCUIElement, _ predicate: @escaping (CGRect) -> Bool) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && predicate(element.frame)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed)
    }

    func testPortraitStockStripAndWordmarkAcrossLayoutsAndThemes() throws {
        let app = openGame(arguments: ["--bound-ui-native-layout", "--bound-ui-reset-layout", "--bound-ui-friend-fixture"])
        let game = element("bound.game-screen", in: app)
        let left = element("bound.native-l", in: app), right = element("bound.native-r", in: app)
        let cycle = app.buttons["bound.panel-cycle"]
        var measurements: [[String: Any]] = []
        for layout in ["Classic", "Bound"] {
            for theme in ["Classic", "Minimal"] {
                XCUIDevice.shared.orientation = .portrait
                openBoundSettings(in: app)
                let arrangement = element("bound.screen-layout", in: app)
                XCTAssertTrue(arrangement.waitForExistence(timeout: 5)); arrangement.tap()
                app.buttons[layout].firstMatch.tap()
                let appearance = element("bound.theme", in: app)
                scrollToSetting(appearance, in: app); appearance.tap()
                app.buttons[theme].firstMatch.tap()
                closeBoundSheet(in: app)
                selectCompanion("Friend", in: app)
                waitForFrame(game) { app.frame.height > app.frame.width && $0.width > $0.height }
                XCTAssertTrue(left.waitForExistence(timeout: 5)); XCTAssertTrue(right.waitForExistence(timeout: 5))
                let scale = app.frame.width / 320
                let mappingHeight: CGFloat = app.frame.height <= 667 ? 240 : 274
                let controllerTop = app.frame.maxY - mappingHeight * scale
                for (control, x) in [(left, CGFloat(0)), (right, CGFloat(212))] {
                    XCTAssertEqual(control.frame.minX, app.frame.minX + x * scale, accuracy: 1)
                    XCTAssertEqual(control.frame.minY, controllerTop + 2 * scale, accuracy: 1)
                    XCTAssertEqual(control.frame.width, 108 * scale, accuracy: 1)
                    XCTAssertEqual(control.frame.height, 30 * scale, accuracy: 1)
                    XCTAssertFalse(control.frame.intersects(game.frame), "Gameplay cannot cover the original shoulder strip")
                }
                if layout == "Bound" {
                    XCTAssertEqual(game.frame.width, app.frame.width, accuracy: 1)
                    XCTAssertEqual(game.frame.maxY, controllerTop, accuracy: 1)
                    XCTAssertEqual(game.frame.width / game.frame.height, 1.5, accuracy: 0.01)
                    let friend = element("bound.friend-screen", in: app)
                    XCTAssertLessThanOrEqual(friend.frame.maxY + 7, game.frame.minY)
                }
                func values(_ frame: CGRect) -> [Double] { [frame.minX, frame.minY, frame.width, frame.height].map(Double.init) }
                measurements.append(["layout": layout, "theme": theme, "screen": values(app.frame),
                    "game": values(game.frame), "left": values(left.frame), "right": values(right.frame),
                    "controllerTop": controllerTop, "cycle": values(cycle.frame)])
                screenshot("Portrait-strip-\(layout)-\(theme)")
                let leftBefore = left.frame, rightBefore = right.frame, cycleBefore = cycle.frame
                selectCompanion("Notes", in: app)
                selectCompanion("Friend", in: app)
                XCTAssertEqual(left.frame, leftBefore); XCTAssertEqual(right.frame, rightBefore)
                XCTAssertEqual(cycle.frame, cycleBefore)
                XCUIDevice.shared.orientation = .landscapeLeft
                waitForFrame(game) { app.frame.width > app.frame.height && $0.width > $0.height }
                if layout == "Bound" { XCTAssertEqual(game.frame.height, app.frame.height, accuracy: 1) }
                screenshot("Portrait-check-landscape-\(layout)-\(theme)")
                XCUIDevice.shared.orientation = .portrait
                waitForFrame(left) { abs($0.minY-leftBefore.minY) < 1 && abs($0.height-leftBefore.height) < 1 }
                XCTAssertEqual(right.frame.minY, rightBefore.minY, accuracy: 1)
                XCTAssertEqual(cycle.frame.minY, cycleBefore.minY, accuracy: 1)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "portrait-stock-geometry"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testAllLandscapePanelsMoveResizeRestoreAndKeepChromeStable() throws {
        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture"])
        XCUIDevice.shared.orientation = .landscapeLeft
        let game = element("bound.game-screen", in: app)
        let panel = element("bound.companion-container", in: app)
        let menu = element("bound.native-menu", in: app)
        let cycle = app.buttons["bound.panel-cycle"]
        waitForFrame(game) { _ in app.frame.width > app.frame.height }
        let menuFrame = menu.frame, cycleFrame = cycle.frame
        XCTAssertEqual(menuFrame.width, 44, accuracy: 1)
        XCTAssertEqual(menuFrame.height, 44, accuracy: 1)
        XCTAssertEqual(cycleFrame.width, 44, accuracy: 1)
        XCTAssertEqual(cycleFrame.height, 44, accuracy: 1)
        for name in ["Friend", "Notes", "Types"] {
            selectCompanion(name, in: app)
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            let initial = panel.frame
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: game.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25)))
            waitForFrame(panel) { $0.midX < game.frame.midX }
            XCTAssertFalse(app.keyboards.firstMatch.exists, "Arranging Notes must not open the keyboard")
            panel.pinch(withScale: 0.75, velocity: -1)
            waitForFrame(panel) { $0.width < initial.width - 10 }
            let smallWidth = panel.frame.width
            panel.pinch(withScale: 1.5, velocity: 1)
            waitForFrame(panel) { $0.width > smallWidth + 5 }
            let resized = panel.frame
            cycle.tap(); cycle.tap(); cycle.tap()
            XCTAssertEqual(cycle.value as? String, name)
            XCTAssertEqual(panel.frame.width, resized.width, accuracy: 2)
            XCTAssertEqual(panel.frame.minX, resized.minX, accuracy: 2)
            XCTAssertEqual(menu.frame, menuFrame)
            XCTAssertEqual(cycle.frame, cycleFrame)
            screenshot("Landscape-" + name + "-resized")
            // Deliberate edge swipe hides; the same B button restores this panel.
            panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: game.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.25)))
            XCTAssertFalse(panel.isHittable)
            cycle.tap()
            XCTAssertEqual(cycle.value as? String, name)
            XCTAssertTrue(panel.isHittable)
            XCTAssertEqual(panel.frame.width, resized.width, accuracy: 2)
        }
        openNativePause(in: app)
        XCTAssertTrue(app.buttons["Bound Settings"].exists)
        resumeNativePause(in: app)
        XCUIDevice.shared.orientation = .landscapeRight
        waitForFrame(menu) { abs($0.width - 44) < 0.5 }
        XCTAssertFalse(menu.frame.intersects(game.frame))
        XCTAssertFalse(cycle.frame.intersects(game.frame))
        screenshot("Landscape-right-matched-controls")
        selectCompanion("Notes", in: app)
        element("bound.notes-preview", in: app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCUIDevice.shared.orientation = .portrait
        selectCompanion("Notes", in: app)
        let editor = element("bound.notes-editor", in: app)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    func testNativeMenuFriendLoginAndSettingsReturnToPause() throws {
        let app = openGame()
        let cycle = app.buttons["bound.panel-cycle"]
        for name in ["Notes", "Types", "Friend"] {
            selectCompanion(name, in: app)
            XCTAssertEqual(cycle.value as? String, name)
            XCTAssertFalse(app.buttons["Bound Settings"].exists)
        }
        openNativePause(in: app)
        XCTAssertTrue(app.buttons["Connect"].exists)
        XCTAssertFalse(app.buttons["Hold Buttons"].exists)
        XCTAssertFalse(app.buttons["Screenshot"].exists)
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Sign in"].isEnabled)
        screenshot("Bound-friend-login-over-native-pause")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Bound Settings"].waitForExistence(timeout: 5))
        app.buttons["Bound Settings"].tap()
        XCTAssertTrue(element("bound.screen-layout", in: app).waitForExistence(timeout: 5))
        screenshot("Bound-settings-over-native-pause")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Bound Settings"].waitForExistence(timeout: 5))
        resumeNativePause(in: app)
        XCTAssertFalse(app.buttons["Bound Settings"].exists)
        XCTAssertTrue(cycle.isHittable)
    }

    func testOfflineFriendPixelsFitBothLayouts() throws {
        let app = openGame(arguments: ["--bound-ui-friend-fixture"])
        selectCompanion("Friend", in: app)
        let friend = element("bound.friend-screen", in: app)
        let game = element("bound.game-screen", in: app)
        XCTAssertTrue(friend.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Connect a friend"].exists)
        XCTAssertEqual(friend.frame.width / friend.frame.height, 1.5, accuracy: 0.015)
        XCTAssertEqual(game.frame.width / game.frame.height, 1.5, accuracy: 0.015)
        XCTAssertEqual(game.frame.width, app.frame.width, accuracy: 2)
        screenshot("Bound-portrait-offline-friend-pixels")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(game) { $0.height > app.frame.height * 0.8 }
        XCTAssertEqual(friend.frame.width / friend.frame.height, 1.5, accuracy: 0.015)
        screenshot("Bound-landscape-offline-friend-pixels")
    }

    func testDualScreenPortraitAndLandscapePictureInPicture() throws {
        let app = openGame()
        selectCompanion("Friend", in: app)
        let friend = element("bound.friend-screen", in: app)
        let game = element("bound.game-screen", in: app)
        XCTAssertTrue(friend.waitForExistence(timeout: 5))
        XCTAssertTrue(game.waitForExistence(timeout: 5))
        waitForFrame(friend) { $0.width > 100 && $0.maxY <= game.frame.minY + 2 }
        XCTAssertTrue(app.staticTexts["Connect a friend"].exists)
        screenshot("Bound-portrait-dual-screen-no-friend")

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(game) { $0.width > $0.height && $0.height > app.frame.height * 0.8 }
        XCTAssertGreaterThanOrEqual(friend.frame.minX, app.frame.minX)
        XCTAssertGreaterThanOrEqual(friend.frame.minY, app.frame.minY)
        XCTAssertLessThanOrEqual(friend.frame.maxX, app.frame.maxX + 1)
        XCTAssertLessThanOrEqual(friend.frame.maxY, app.frame.maxY + 1)
        XCTAssertLessThan(friend.frame.width, game.frame.width * 0.65)
        screenshot("Bound-landscape-full-height-game-and-pip")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(friend.waitForExistence(timeout: 5))
        XCTAssertTrue(game.exists)
        XCUIDevice.shared.orientation = .portrait
        waitForFrame(friend) { $0.maxY <= game.frame.minY + 2 }
        screenshot("Bound-portrait-after-rotation-and-foreground")
    }

    func testLandscapePictureInPictureSnapsToAllFourGameCorners() throws {
        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture"])
        selectCompanion("Friend", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let game = element("bound.game-screen", in: app)
        let friend = element("bound.friend-screen", in: app)
        waitForFrame(game) { app.frame.width > app.frame.height && $0.height > app.frame.height * 0.8 }
        for (name, x, y, left, top) in [
            ("top-left", 0.22, 0.22, true, true),
            ("top-right", 0.78, 0.22, false, true),
            ("bottom-right", 0.78, 0.78, false, false),
            ("bottom-left", 0.22, 0.78, true, false)
        ] {
            // Start on the PiP; gameplay and native controls do not move it.
            // End well inside the real viewport so this cannot invoke edge-hide.
            friend.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.15, thenDragTo: game.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)))
            waitForFrame(friend) { frame in
                (left ? frame.midX < game.frame.midX : frame.midX > game.frame.midX) &&
                (top ? frame.midY < game.frame.midY : frame.midY > game.frame.midY)
            }
            for identifier in ["bound.native-menu", "bound.panel-cycle", "bound.native-l", "bound.native-r"] {
                let fixed = element(identifier, in: app)
                XCTAssertTrue(fixed.exists)
                XCTAssertFalse(friend.frame.intersects(fixed.frame), "PiP must clear fixed control: " + identifier)
            }
            for obstacle in try actualPiPHitObstacles(in: game) {
                XCTAssertFalse(friend.frame.insetBy(dx: 0.02, dy: 0.02).intersects(obstacle),
                               "Friend PiP must clear actual extended native hit regions")
            }
            XCTAssertTrue(game.frame.insetBy(dx: -1, dy: -1).contains(friend.frame))
            XCTAssertFalse(app.buttons["Bound Settings"].exists)
            screenshot("Bound-landscape-pip-" + name)
        }
        let saved = friend.frame
        app.terminate()
        _ = openGame(arguments: ["--bound-ui-friend-fixture"])
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(friend) { abs($0.minX - saved.minX) < 3 && abs($0.maxY - saved.maxY) < 3 }
    }

    func testPictureInPictureGesturesAndTransparencyPersist() throws {
        let app = openGame(arguments: ["--bound-ui-reset-layout"])
        selectCompanion("Friend", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let friend = element("bound.friend-screen", in: app)
        waitForFrame(friend) { $0.width > 100 && app.frame.width > app.frame.height }
        let initial = friend.frame
        let destination = app.coordinate(withNormalizedOffset: CGVector(dx: initial.midX > app.frame.midX ? 0.30 : 0.70, dy: 0.35))
        friend.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: destination)
        waitForFrame(friend) { abs($0.midX - initial.midX) > 30 || abs($0.midY - initial.midY) > 30 }
        screenshot("Bound-landscape-pip-moved")
        let game = element("bound.game-screen", in: app)
        friend.pinch(withScale: 0.5, velocity: -1)
        let movedWidth = friend.frame.width
        friend.pinch(withScale: 1.5, velocity: 1)
        waitForFrame(friend) { $0.width > movedWidth + 5 }
        screenshot("Bound-landscape-pip-resized")
        openBoundSettings(in: app)
        let transparency = app.sliders["bound.friend-transparency"]
        scrollToSetting(transparency, in: app)
        XCTAssertTrue(transparency.waitForExistence(timeout: 5))
        transparency.adjust(toNormalizedSliderPosition: 0.45)
        let savedValue = transparency.value as? String
        XCTAssertNotNil(savedValue)
        screenshot("Bound-friend-transparency-setting")
        closeBoundSheet(in: app)
        let savedFrame = friend.frame
        app.terminate()
        _ = openGame()
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(friend) { app.frame.width > app.frame.height && abs($0.width - savedFrame.width) < 3 }
        XCTAssertEqual(friend.frame.midX, savedFrame.midX, accuracy: 3)
        XCTAssertEqual(friend.frame.midY, savedFrame.midY, accuracy: 3)
        openBoundSettings(in: app)
        scrollToSetting(transparency, in: app)
        XCTAssertTrue(transparency.waitForExistence(timeout: 5))
        XCTAssertEqual(transparency.value as? String, savedValue)
        // Restore visibility without resetting saved movement or scale.
        transparency.adjust(toNormalizedSliderPosition: 0)
        closeBoundSheet(in: app)
        XCUIDevice.shared.orientation = .portrait
        screenshot("Bound-portrait-after-pip-customization")
    }

    func testControlPlacementSaveResetAndOrientationIsolation() throws {
        let app = openGame()
        func openPlacement() {
            openBoundSettings(in: app)
            let placement = app.buttons["bound.button-placement"]
            XCTAssertTrue(placement.waitForExistence(timeout: 5))
            if !placement.isHittable { app.swipeUp() }
            placement.tap()
            XCTAssertTrue(app.otherElements["controls.editor.preview"].waitForExistence(timeout: 5))
        }
        func tapEditorButton(_ identifier: String) {
            let button = app.buttons[identifier]
            for _ in 0..<5 where !button.isHittable { app.swipeUp() }
            XCTAssertTrue(button.isHittable)
            button.tap()
        }
        openPlacement()
        tapEditorButton("controls.editor.reset-all")
        app.buttons["Save"].tap()
        resumeNativePause(in: app)
        openPlacement()
        let size = app.sliders["controls.editor.size"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Size: 100%"].exists)
        size.adjust(toNormalizedSliderPosition: 0.8)
        let customSize = size.value as? String
        tapEditorButton("controls.editor.nudge.→")
        screenshot("Bound-portrait-custom-control-placement")
        app.buttons["Save"].tap()
        resumeNativePause(in: app)
        let game = element("bound.game-screen", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(game.frame.height, 100)
        XCTAssertEqual(game.frame.width / game.frame.height, 1.5, accuracy: 0.015)
        screenshot("Bound-portrait-gameplay-with-custom-controls")
        app.terminate()
        _ = openGame()
        openPlacement()
        XCTAssertEqual(size.value as? String, customSize)
        app.buttons["Cancel"].tap()
        resumeNativePause(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        openPlacement()
        XCTAssertTrue(app.staticTexts["Size: 100%"].exists)
        screenshot("Bound-landscape-default-control-placement")
        app.buttons["Cancel"].tap()
        resumeNativePause(in: app)
        XCUIDevice.shared.orientation = .portrait
        openPlacement()
        tapEditorButton("controls.editor.reset-all")
        app.buttons["Save"].tap()
        resumeNativePause(in: app)
        openPlacement()
        XCTAssertTrue(app.staticTexts["Size: 100%"].exists)
        app.buttons["Cancel"].tap()
        resumeNativePause(in: app)
    }

    func testThemeAndHapticPreferencesPersistAndReset() throws {
        let app = openGame(arguments: ["--bound-ui-friend-fixture"])
        selectCompanion("Friend", in: app)
        let friend = element("bound.friend-screen", in: app)
        let game = element("bound.game-screen", in: app)
        func settings() {
            openBoundSettings(in: app)
            XCTAssertTrue(element("bound.theme", in: app).waitForExistence(timeout: 5))
        }
        func scrollTo(_ target: XCUIElement) {
            for _ in 0..<12 where !target.exists || !target.isHittable { app.collectionViews.firstMatch.swipeUp() }
            XCTAssertTrue(target.isHittable)
        }
        func resetAppearance() {
            let reset = app.buttons["bound.reset-appearance"]
            scrollTo(reset)
            reset.tap()
            let theme = element("bound.theme", in: app)
            for _ in 0..<12 where !theme.exists || !theme.isHittable { app.collectionViews.firstMatch.swipeDown() }
            XCTAssertTrue(theme.isHittable)
        }
        settings()
        resetAppearance()
        let buttonHaptics = app.switches["bound.button-haptics"]
        let stickHaptics = app.switches["bound.stick-haptics"]
        XCTAssertEqual(buttonHaptics.value as? String, "1")
        XCTAssertEqual(stickHaptics.value as? String, "1")
        closeBoundSheet(in: app)
        screenshot("Bound-Delta-default-theme-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(game) { $0.height > app.frame.height * 0.8 }
        screenshot("Bound-Delta-default-theme-landscape")
        XCUIDevice.shared.orientation = .portrait
        settings()
        element("bound.theme", in: app).tap()
        let minimal = app.buttons["Minimal"].firstMatch
        XCTAssertTrue(minimal.waitForExistence(timeout: 5))
        minimal.tap()
        scrollTo(buttonHaptics)
        buttonHaptics.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        scrollTo(stickHaptics)
        stickHaptics.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(buttonHaptics.value as? String, "0")
        XCTAssertEqual(stickHaptics.value as? String, "0")
        screenshot("Bound-Minimal-theme-haptic-settings")
        closeBoundSheet(in: app)
        waitForFrame(friend) { $0.maxY <= game.frame.minY + 2 }
        XCTAssertEqual(game.frame.width / game.frame.height, 1.5, accuracy: 0.015)
        screenshot("Bound-Minimal-theme-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(game) { $0.height > app.frame.height * 0.8 }
        XCTAssertEqual(friend.frame.width / friend.frame.height, 1.5, accuracy: 0.015)
        screenshot("Bound-Minimal-theme-landscape")
        selectCompanion("Types", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "bound.type-chart").firstMatch.waitForExistence(timeout: 5))
        selectCompanion("Notes", in: app)
        XCTAssertTrue(app.textViews["bound.notes-editor"].waitForExistence(timeout: 5))
        selectCompanion("Friend", in: app)
        XCUIDevice.shared.press(.home)
        app.activate()
        app.terminate()
        _ = openGame(arguments: ["--bound-ui-friend-fixture"])
        XCUIDevice.shared.orientation = .portrait
        waitForFrame(game) { $0.width < app.frame.height && app.frame.height > app.frame.width }
        settings()
        XCTAssertEqual(buttonHaptics.value as? String, "0")
        XCTAssertEqual(stickHaptics.value as? String, "0")
        let persistedTheme = element("bound.theme", in: app)
        XCTAssertTrue(persistedTheme.label.contains("Minimal") || (persistedTheme.value as? String)?.contains("Minimal") == true)
        resetAppearance()
        XCTAssertEqual(buttonHaptics.value as? String, "1")
        XCTAssertEqual(stickHaptics.value as? String, "1")
        screenshot("Bound-reset-appearance-settings")
        closeBoundSheet(in: app)
    }

    func testNativeAndBoundScreenLayoutChoicePersistsAndReportsBackend() throws {
        let nativeArguments = ["--bound-ui-native-layout", "--bound-ui-friend-fixture"]
        let app = openGame(arguments: nativeArguments + ["--bound-ui-reset-screen-layout"])
        let game = element("bound.game-screen", in: app)
        let friend = element("bound.friend-screen", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 5))
        func settings() {
            openBoundSettings(in: app)
            XCTAssertTrue(element("bound.screen-layout", in: app).waitForExistence(timeout: 5))
        }
        func scrollTo(_ target: XCUIElement) {
            for _ in 0..<12 where !target.exists || !target.isHittable { app.collectionViews.firstMatch.swipeUp() }
            XCTAssertTrue(target.isHittable)
        }
        func assertSelection(_ expected: String) {
            let picker = element("bound.screen-layout", in: app)
            XCTAssertTrue(picker.label.contains(expected) || (picker.value as? String)?.contains(expected) == true)
        }
        func chooseLayout(_ name: String) {
            element("bound.screen-layout", in: app).tap()
            let choice = app.buttons[name].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
            assertSelection(name)
            closeBoundSheet(in: app)
        }
        func matches(_ frame: CGRect, _ expected: CGRect) -> Bool {
            abs(frame.minX - expected.minX) < 3 && abs(frame.minY - expected.minY) < 3 &&
            abs(frame.width - expected.width) < 3 && abs(frame.height - expected.height) < 3
        }
        settings()
        assertSelection("Bound")
        chooseLayout("Classic")
        waitForFrame(game) { $0.width > 100 && $0.height > 100 && app.frame.height > app.frame.width }
        let nativePortrait = game.frame
        let menu = element("bound.native-menu", in: app)
        let nativeMenuPortrait = menu.frame
        XCTAssertGreaterThan(nativeMenuPortrait.width, 0)
        XCTAssertGreaterThan(nativeMenuPortrait.height, 0)
        XCTAssertLessThan(nativeMenuPortrait.width, app.frame.width * 0.25, "Menu AX must expose the real input, not a full-screen container")
        XCTAssertLessThan(nativeMenuPortrait.height, app.frame.height * 0.25)
        screenshot("Bound-native-Delta-layout-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(game) { app.frame.width > app.frame.height && $0.width > $0.height }
        let nativeLandscape = game.frame
        let nativeMenuLandscape = menu.frame
        XCTAssertGreaterThan(nativeMenuLandscape.width, 0)
        XCTAssertGreaterThan(nativeMenuLandscape.height, 0)
        XCTAssertLessThan(nativeMenuLandscape.width, app.frame.width * 0.25)
        XCTAssertLessThan(nativeMenuLandscape.height, app.frame.height * 0.25, "Menu AX must expose the real input, not a full-screen container")
        screenshot("Bound-native-Delta-layout-landscape")
        XCUIDevice.shared.orientation = .portrait
        waitForFrame(game) { matches($0, nativePortrait) }
        settings()
        chooseLayout("Bound")
        waitForFrame(game) { !matches($0, nativePortrait) && friend.frame.maxY <= $0.minY + 2 }
        let boundPortrait = game.frame
        XCTAssertEqual(game.frame.width, app.frame.width, accuracy: 2)
        XCTAssertTrue(matches(menu.frame, nativeMenuPortrait), "Bound must preserve Delta's native Menu input frame")
        screenshot("Bound-selected-dual-screen-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(game) { app.frame.width > app.frame.height && $0.height > app.frame.height * 0.8 }
        XCTAssertGreaterThanOrEqual(menu.frame.minX, game.frame.maxX)
        XCTAssertFalse(menu.frame.intersects(game.frame))
        screenshot("Bound-selected-full-height-landscape")
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        _ = openGame(arguments: nativeArguments)
        waitForFrame(game) { matches($0, boundPortrait) }
        settings()
        assertSelection("Bound")
        // Appearance reset must leave the independent screen arrangement alone.
        let resetAppearance = app.buttons["bound.reset-appearance"]
        scrollTo(resetAppearance)
        resetAppearance.tap()
        let picker = element("bound.screen-layout", in: app)
        for _ in 0..<12 where !picker.exists || !picker.isHittable { app.collectionViews.firstMatch.swipeDown() }
        assertSelection("Bound")
        func assertBackend(_ identifier: String, contains value: String) {
            let row = element(identifier, in: app)
            scrollTo(row)
            let content = row.label + " " + ((row.value as? String) ?? "") + " " + row.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
            XCTAssertTrue(content.contains(value), "Backend row \(identifier) must contain \(value), got \(content)")
        }
        assertBackend("bound.emulation-package", contains: "GBADeltaCore")
        assertBackend("bound.emulation-package-build", contains: "869c34aeca9d")
        assertBackend("bound.emulation-engine", contains: "VBA-M")
        assertBackend("bound.emulation-engine-build", contains: "453fa0decf17")
        screenshot("Bound-active-GBA-backend-details")
        for _ in 0..<12 where !picker.exists || !picker.isHittable { app.collectionViews.firstMatch.swipeDown() }
        chooseLayout("Classic")
        waitForFrame(game) { matches($0, nativePortrait) }
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(game) { matches($0, nativeLandscape) }
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        _ = openGame(arguments: nativeArguments)
        waitForFrame(game) { matches($0, nativePortrait) }
        settings()
        assertSelection("Classic")
        chooseLayout("Bound")
        waitForFrame(game) { matches($0, boundPortrait) }
        settings()
        let reset = app.buttons["bound.reset-screen-layout"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        assertSelection("Bound")
        chooseLayout("Classic")
        waitForFrame(game) { matches($0, nativePortrait) }
        screenshot("Bound-reset-native-Delta-layout-portrait")
        // Native Delta's screen geometry must survive companion gestures and
        // keyboard editing; only the overlay is allowed to move or resize.
        friend.pinch(withScale: 0.5, velocity: -1)
        let compactFriendWidth = friend.frame.width
        friend.pinch(withScale: 1.5, velocity: 1)
        waitForFrame(friend) { $0.width > compactFriendWidth + 5 }
        XCTAssertTrue(matches(game.frame, nativePortrait))
        screenshot("Bound-native-portrait-pip-resized")
        selectCompanion("Notes", in: app)
        let editor = app.textViews["bound.notes-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" Native layout QA note")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(matches(game.frame, nativePortrait))
        screenshot("Bound-native-portrait-notes-keyboard")
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        resumeNativePause(in: app)
        let keyboardDismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.keyboards.firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardDismissed], timeout: 5), .completed)
        XCTAssertTrue(matches(game.frame, nativePortrait))
        selectCompanion("Types", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "bound.type-chart").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(matches(game.frame, nativePortrait))
        screenshot("Bound-native-portrait-type-chart")
        selectCompanion("Friend", in: app)
        XCTAssertTrue(friend.waitForExistence(timeout: 5))
        XCTAssertTrue(matches(game.frame, nativePortrait))
    }

    func testPortraitTypeChartContentGesturesAndLandscapePanelGestures() throws {
        let app = openGame(arguments: ["--bound-ui-friend-fixture"])
        selectCompanion("Friend", in: app)
        let game = element("bound.game-screen", in: app)
        let portraitGame = game.frame
        let friendFrame = element("bound.friend-screen", in: app).frame
        selectCompanion("Types", in: app)
        let chart = app.descendants(matching: .any).matching(identifier: "bound.type-chart").firstMatch
        let image = app.images["bound.type-chart-image"]
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        func metrics() -> [String: Double] {
            let text = (chart.value as? String) ?? ""
            return Dictionary(uniqueKeysWithValues: text.split(separator: ";").compactMap { field in
                let parts = field.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let number = Double(parts[1]) else { return nil }
                return (String(parts[0]).trimmingCharacters(in: .whitespaces), number)
            })
        }
        let initial = metrics()
        let zoom = try XCTUnwrap(initial["zoom"])
        XCTAssertEqual(try XCTUnwrap(initial["imageHeight"]), try XCTUnwrap(initial["fitViewportHeight"]), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(initial["fitViewportHeight"]),
                       try (XCTUnwrap(initial["viewportHeight"]) - XCTUnwrap(initial["topInset"])), accuracy: 1)
        XCTAssertEqual(zoom, try XCTUnwrap(initial["initial"]), accuracy: 0.001)
        let portraitPanelFrame = chart.frame
        XCTAssertLessThanOrEqual(portraitPanelFrame.minY, 1)
        XCTAssertGreaterThan(portraitPanelFrame.height, friendFrame.height)
        XCTAssertEqual(portraitPanelFrame.maxY, portraitGame.minY, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(initial["imageY"]), friendFrame.minY, accuracy: 2,
                       "The initial chart header clears the safe area without shortening the viewport")
        XCTAssertLessThanOrEqual(try (XCTUnwrap(initial["imageY"]) + XCTUnwrap(initial["imageHeight"])),
                                 try XCTUnwrap(initial["viewportHeight"]) + 1,
                                 "Both chart extremes must be visible before any pan or zoom")
        XCTAssertEqual(game.frame, portraitGame)
        XCTAssertEqual(game.frame.width, app.frame.width, accuracy: 2)
        screenshot("Bound-portrait-type-chart-height-fit")
        let minimum = try XCTUnwrap(initial["minimum"])
        chart.pinch(withScale: 0.1, velocity: -1)
        let settledAtMinimum = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let current = metrics()["zoom"] else { return false }
            return abs(current - minimum) < 0.001
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settledAtMinimum], timeout: 8), .completed,
                       "Releasing a pinch below full-image fit must spring back to the minimum")
        let fitted = metrics()
        let fittedX = try XCTUnwrap(fitted["imageX"])
        let fittedY = try XCTUnwrap(fitted["imageY"])
        XCTAssertGreaterThanOrEqual(fittedX, -1)
        XCTAssertGreaterThanOrEqual(fittedY, -1)
        XCTAssertLessThanOrEqual(fittedX + (try XCTUnwrap(fitted["imageWidth"])),
                                 try XCTUnwrap(fitted["viewportWidth"]) + 1)
        XCTAssertLessThanOrEqual(fittedY + (try XCTUnwrap(fitted["imageHeight"])),
                                 try XCTUnwrap(fitted["viewportHeight"]) + 1)
        XCTAssertEqual(chart.frame, portraitPanelFrame)
        XCTAssertEqual(game.frame, portraitGame)
        chart.swipeUp()
        XCTAssertEqual(try XCTUnwrap(metrics()["imageY"]), fittedY, accuracy: 1)
        chart.swipeDown()
        XCTAssertEqual(try XCTUnwrap(metrics()["imageY"]), fittedY, accuracy: 1)
        screenshot("Bound-portrait-type-chart-full-image-minimum-after-elastic-pinch")
        chart.pinch(withScale: CGFloat(zoom * 2 / minimum), velocity: 1)
        let zoomed = metrics()
        XCTAssertGreaterThan(try XCTUnwrap(zoomed["zoom"]), zoom * 1.2)
        XCTAssertEqual(chart.frame.width, portraitPanelFrame.width, accuracy: 2)
        XCTAssertEqual(chart.frame.height, portraitPanelFrame.height, accuracy: 2)
        // At 2x this tall chart can still fit horizontally; its overflowing
        // vertical content must pan without moving the companion panel.
        let yBefore = try XCTUnwrap(zoomed["imageY"])
        chart.swipeUp()
        XCTAssertNotEqual(try XCTUnwrap(metrics()["imageY"]), yBefore)
        screenshot("Bound-portrait-type-chart-content-zoomed-and-panned")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(game) { app.frame.width > app.frame.height && $0.height > app.frame.height * 0.8 }
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        XCTAssertFalse(app.scrollViews.matching(identifier: "bound.type-chart").firstMatch.exists,
                       "Landscape fits the complete image and has no inner content scroller")
        let landscapeGame = game.frame
        chart.pinch(withScale: 0.5, velocity: -1)
        let smallPanelWidth = chart.frame.width
        screenshot("Bound-landscape-full-chart-minimum-PiP")
        chart.pinch(withScale: 1.2, velocity: 1)
        waitForFrame(chart) { $0.width > smallPanelWidth + 5 }
        screenshot("Bound-landscape-type-chart-whole-panel-resized")
        chart.pinch(withScale: 4, velocity: 1)
        screenshot("Bound-landscape-full-chart-maximum-PiP")
        let panelBeforeDrag = chart.frame
        let oppositeCorner = CGVector(dx: panelBeforeDrag.midX < game.frame.midX ? 0.78 : 0.22,
                                      dy: panelBeforeDrag.midY < game.frame.midY ? 0.78 : 0.22)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: game.coordinate(withNormalizedOffset: oppositeCorner))
        waitForFrame(chart) { abs($0.minX - panelBeforeDrag.minX) > 5 || abs($0.minY - panelBeforeDrag.minY) > 5 }
        XCTAssertEqual(chart.frame.width, panelBeforeDrag.width, accuracy: 2)
        XCTAssertEqual(chart.frame.height, panelBeforeDrag.height, accuracy: 2)
        XCTAssertEqual(game.frame, landscapeGame)
        XCTAssertFalse(app.buttons["Bound Settings"].exists)
        screenshot("Bound-landscape-full-chart-whole-PiP-dragged")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        let rotated = metrics()
        XCTAssertEqual(try XCTUnwrap(rotated["zoom"]), try XCTUnwrap(rotated["initial"]), accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(rotated["imageHeight"]), try XCTUnwrap(rotated["fitViewportHeight"]), accuracy: 1)
        app.terminate()
        _ = openGame(arguments: ["--bound-ui-friend-fixture"])
        selectCompanion("Types", in: app)
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        let relaunched = metrics()
        XCTAssertEqual(try XCTUnwrap(relaunched["zoom"]), try XCTUnwrap(relaunched["initial"]), accuracy: 0.001)
        screenshot("Bound-portrait-type-chart-reset-after-relaunch")
    }

    func testLandscapeTypeChartClearsFixedControlsAtEveryCornerAndScale() throws {
        let app = openGame(arguments: ["--bound-ui-native-layout", "--bound-ui-friend-fixture", "--bound-ui-reset-layout"])
        let game = element("bound.game-screen", in: app)
        let chart = element("bound.type-chart", in: app)
        let corners: [(String, Bool, Bool)] = [
            ("top-left", true, true),
            ("top-right", false, true),
            ("bottom-right", false, false),
            ("bottom-left", true, false)
        ]
        for layout in ["Classic", "Bound"] {
            XCUIDevice.shared.orientation = .portrait
            openBoundSettings(in: app)
            let arrangement = element("bound.screen-layout", in: app)
            XCTAssertTrue(arrangement.waitForExistence(timeout: 5))
            arrangement.tap()
            app.buttons[layout].firstMatch.tap()
            closeBoundSheet(in: app)
            selectCompanion("Types", in: app)
            for (orientationName, orientation) in [("left", UIDeviceOrientation.landscapeLeft), ("right", .landscapeRight)] {
                XCUIDevice.shared.orientation = orientation
                waitForFrame(game) { app.frame.width > app.frame.height && $0.width > $0.height }
                XCTAssertTrue(chart.waitForExistence(timeout: 5))
                let originalGame = game.frame
                var minimumWidth: CGFloat?
                for (scaleName, scale, velocity) in [("minimum", CGFloat(0.1), CGFloat(-1)), ("maximum", CGFloat(8), CGFloat(1))] {
                    // The collision-free chart itself guarantees both initial pinch
                    // contacts are clear of native controls in either orientation.
                    chart.pinch(withScale: scale, velocity: velocity)
                    if scaleName == "minimum" { minimumWidth = chart.frame.width }
                    else { XCTAssertGreaterThan(chart.frame.width, try XCTUnwrap(minimumWidth) + 5) }
                    var observedCornerCenters: [CGPoint] = []
                    for (cornerName, left, top) in corners {
                        // Start on the actual PiP, never on a native input.
                        // Targets stay inside the viewport; obstacle avoidance may offset the
                        // final frame from its ideal8pt edge without changing the chosen corner.
                        // Aim near the desired corner without crossing the hide
                        // edge; release chooses the nearest clear corner.
                        let target = game.coordinate(withNormalizedOffset: CGVector(dx: left ? 0 : 1, dy: top ? 0 : 1))
                            .withOffset(CGVector(dx: left ? 30 : -30, dy: top ? 30 : -30))
                        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                            .press(forDuration: 0.15, thenDragTo: target)
                        let observedObstacles = try actualPiPHitObstacles(in: game)
                        print("BOUND_CHART_PLACEMENT", layout, orientationName, scaleName, cornerName,
                              "game", game.frame, "chart", chart.frame, "obstacles", observedObstacles)
                        waitForFrame(chart) { frame in
                            let horizontal = left ? frame.midX < game.frame.midX : frame.midX > game.frame.midX
                            if scaleName == "maximum" {
                                // The largest square clears the lower Start/
                                // Select hit strip retained in either arrangement. Its saved
                                // bottom corner can therefore remain above the
                                // viewport midpoint; require the actual clear edge.
                                if top { return horizontal && abs(frame.minY - (game.frame.minY + 8)) < 1 }
                                let lowerHits = observedObstacles.filter {
                                    $0.minY > game.frame.midY && $0.minX < frame.maxX && $0.maxX > frame.minX
                                }
                                let bottom = min(game.frame.maxY - 8, lowerHits.map { $0.minY - 2 }.min() ?? game.frame.maxY - 8)
                                return horizontal && abs(frame.maxY - bottom) < 1
                            }
                            return horizontal && (top ? frame.midY < game.frame.midY : frame.midY > game.frame.midY)
                        }
                        XCTAssertEqual(chart.frame.width / chart.frame.height, 1, accuracy: 0.005,
                                       "The500×500 source chart uses an aspect-correct square container without sidebars")
                        let center = CGPoint(x: chart.frame.midX, y: chart.frame.midY)
                        for previous in observedCornerCenters {
                            XCTAssertGreaterThan(hypot(center.x - previous.x, center.y - previous.y), 5,
                                                 "All four selected chart corners must remain distinct")
                        }
                        observedCornerCenters.append(center)
                        XCTAssertTrue(game.frame.insetBy(dx: -1, dy: -1).contains(chart.frame),
                                      "The entire fitted chart viewport remains in gameplay")
                        for identifier in ["bound.native-menu", "bound.panel-cycle", "bound.native-l", "bound.native-r"] {
                            let fixed = element(identifier, in: app)
                            XCTAssertTrue(fixed.exists)
                            XCTAssertGreaterThan(fixed.frame.width, 0)
                            XCTAssertLessThan(fixed.frame.width, app.frame.width * 0.5)
                            XCTAssertFalse(chart.frame.intersects(fixed.frame),
                                           "Chart must clear fixed control: " + identifier)
                        }
                        for obstacle in try actualPiPHitObstacles(in: game) {
                            XCTAssertFalse(chart.frame.insetBy(dx: 0.02, dy: 0.02).intersects(obstacle),
                                           "Chart must clear every actual extended native/cycle hit region")
                        }
                        XCTAssertEqual(game.frame, originalGame)
                        XCTAssertFalse(app.buttons["Bound Settings"].exists)
                        screenshot("Bound-chart-clearance-\(layout)-\(orientationName)-\(scaleName)-\(cornerName)")
                    }
                }
            }
        }
    }

    func testLandscapeMenuAndCycleSitBelowTheirNativeShoulders() throws {
        let app = openGame(arguments: ["--bound-ui-native-layout", "--bound-ui-friend-fixture"])
        let game = element("bound.game-screen", in: app)
        for layout in ["Classic", "Bound"] {
            for theme in ["Classic", "Minimal"] {
                XCUIDevice.shared.orientation = .portrait
                openBoundSettings(in: app)
                let arrangement = element("bound.screen-layout", in: app)
                XCTAssertTrue(arrangement.waitForExistence(timeout: 5))
                arrangement.tap()
                app.buttons[layout].firstMatch.tap()
                let appearance = element("bound.theme", in: app)
                scrollToSetting(appearance, in: app)
                appearance.tap()
                app.buttons[theme].firstMatch.tap()
                closeBoundSheet(in: app)
                for (name, orientation) in [("left", UIDeviceOrientation.landscapeLeft), ("right", .landscapeRight)] {
                    XCUIDevice.shared.orientation = orientation
                    waitForFrame(game) { app.frame.width > app.frame.height && $0.width > $0.height }
                    let left = element("bound.native-l", in: app)
                    let right = element("bound.native-r", in: app)
                    let menu = element("bound.native-menu", in: app)
                    let cycle = app.buttons["bound.panel-cycle"]
                    XCTAssertTrue(left.waitForExistence(timeout: 5))
                    XCTAssertTrue(right.waitForExistence(timeout: 5))
                    for input in [left, right, menu, cycle] {
                        XCTAssertGreaterThan(input.frame.width, 0)
                        XCTAssertGreaterThan(input.frame.height, 0)
                        XCTAssertLessThan(input.frame.width, app.frame.width * 0.5,
                                          "AX must describe actual controls rather than a screen container")
                    }
                    if layout == "Bound" {
                        XCTAssertGreaterThanOrEqual(menu.frame.minX, game.frame.maxX - 1)
                        XCTAssertGreaterThanOrEqual(cycle.frame.minX, game.frame.maxX - 1)
                        XCTAssertGreaterThanOrEqual(menu.frame.minY, right.frame.maxY)
                        XCTAssertGreaterThanOrEqual(cycle.frame.minY, menu.frame.maxY)
                        XCTAssertGreaterThanOrEqual(cycle.frame.width, 43.99)
                        XCTAssertGreaterThanOrEqual(cycle.frame.height, 43.99)
                        let obstacles = try actualPiPHitObstacles(in: game)
                        // Identify Menu's observed full hit region by containment of
                        // its real AX artwork; do not infer hit bounds from artwork size.
                        let menuHits = obstacles.filter { $0.contains(menu.frame.insetBy(dx: 0.02, dy: 0.02)) }
                        XCTAssertEqual(menuHits.count, 1, "Menu artwork belongs to exactly one actual hit region")
                        let menuHit = try XCTUnwrap(menuHits.first)
                        XCTAssertGreaterThanOrEqual(menuHit.width, 43.99)
                        XCTAssertGreaterThanOrEqual(menuHit.height, 43.99)
                        XCTAssertGreaterThanOrEqual(menuHit.minX, game.frame.maxX - 1)
                        XCTAssertFalse(menuHit.insetBy(dx: 0.02, dy: 0.02).intersects(game.frame))
                        XCTAssertFalse(cycle.frame.insetBy(dx: 0.02, dy: 0.02).intersects(game.frame))
                        XCTAssertGreaterThanOrEqual(cycle.frame.minY - menuHit.maxY, 7.9,
                                                    "The actual Menu and cycle hit regions keep their8pt gap")
                        for obstacle in obstacles where !obstacle.contains(cycle.frame.insetBy(dx: 0.02, dy: 0.02)) {
                            XCTAssertFalse(cycle.frame.insetBy(dx: 0.02, dy: 0.02).intersects(obstacle))
                        }
                    } else {
                        XCTAssertLessThan(menu.frame.midX, app.frame.midX)
                        XCTAssertGreaterThan(cycle.frame.midX, app.frame.midX)
                        XCTAssertGreaterThanOrEqual(menu.frame.minY, left.frame.maxY)
                        XCTAssertGreaterThanOrEqual(cycle.frame.minY, right.frame.maxY)
                        XCTAssertLessThan(abs(menu.frame.midX - left.frame.midX), left.frame.width)
                        XCTAssertLessThan(abs(cycle.frame.midX - right.frame.midX), right.frame.width)
                    }
                    XCTAssertFalse(menu.frame.intersects(cycle.frame))
                    selectCompanion("Notes", in: app)
                    XCTAssertFalse(app.buttons["Bound Settings"].exists)
                    screenshot("Bound-shoulders-\(layout)-\(theme)-\(name)")
                }
            }
        }
    }

    func testControllerModeKeepsMenuAndCompanionAcrossRotationAndRelaunch() throws {
        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture"])
        let game = element("bound.game-screen", in: app)
        let menu = element("bound.native-menu", in: app)
        let shoulder = element("bound.native-r", in: app)
        let cycle = app.buttons["bound.panel-cycle"]
        XCTAssertTrue(shoulder.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(game) { app.frame.width > app.frame.height && $0.height > app.frame.height * 0.8 }
        let originalGame = game.frame
        openNativePause(in: app)
        let mode = app.buttons["bound.controller-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(mode.label, "Controller Mode")
        XCTAssertEqual(mode.value as? String, "Off")
        XCTAssertTrue(app.frame.contains(mode.frame))
        for label in ["Save State", "Load State", "Cheat Codes", "Fast Forward", "Connect", "Bound Settings"] {
            XCTAssertTrue(app.buttons[label].exists)
        }
        screenshot("Bound-seven-tile-pause-menu")
        mode.tap()
        resumeNativePause(in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(cycle.exists)
        XCTAssertFalse(shoulder.exists)
        XCTAssertEqual(game.frame, originalGame)
        XCTAssertFalse(menu.frame.intersects(game.frame))
        XCTAssertFalse(cycle.frame.intersects(game.frame))
        screenshot("Bound-controller-mode-landscape")
        cycle.tap()
        XCTAssertEqual(cycle.value as? String, "Notes")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(shoulder.waitForExistence(timeout: 5), "Portrait retains native controls")
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertFalse(shoulder.exists)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertFalse(shoulder.exists)
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        _ = openGame()
        XCTAssertTrue(shoulder.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertFalse(shoulder.exists)
        openNativePause(in: app)
        XCTAssertEqual(mode.value as? String, "On")
        mode.tap()
        resumeNativePause(in: app)
        XCTAssertTrue(shoulder.waitForExistence(timeout: 5))
        XCTAssertTrue(cycle.exists)
        XCTAssertEqual(game.frame, originalGame)
    }

    func testBoundNotesPlaceholderAndEditing() throws {
        let app = openGame()
        selectCompanion("Notes", in: app)
        let editor = app.textViews["bound.notes-editor"]
        let placeholder = app.staticTexts["bound.notes-placeholder"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        // Preserve the fixture's existing note while checking the empty state.
        let previous = editor.value as? String ?? ""
        editor.tap()
        func clearNote() {
            let count = (editor.value as? String ?? "").count
            // Existing QA notes may span multiple screens; move the caret to the
            // final visible line rather than assuming a center tap means End.
            for _ in 0..<3 { editor.swipeUp() }
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
            editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
            XCTAssertEqual(editor.value as? String, "", "Fixture note must be fully deleted")
        }
        if !previous.isEmpty { clearNote() }
        XCTAssertFalse(placeholder.exists, "Deleting while focused must not restore the placeholder")
        app.buttons["Done"].firstMatch.tap()
        screenshot("Bound-empty-notes-placeholder")
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
        XCTAssertEqual(placeholder.label, "Tap to add notes")
        XCTAssertEqual(editor.value as? String, "")
        // Tap directly through the placeholder, before entering any characters.
        placeholder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(placeholder.exists)
        editor.typeText("Bound placeholder note")
        XCTAssertFalse(placeholder.exists)
        screenshot("Bound-pixel-notes-keyboard-and-Done")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(editor.value as? String, "Bound placeholder note")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(placeholder.exists)
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        _ = openGame()
        selectCompanion("Notes", in: app)
        XCTAssertEqual(editor.value as? String, "Bound placeholder note")
        XCTAssertFalse(placeholder.exists)
        editor.tap()
        clearNote()
        XCTAssertFalse(placeholder.exists)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        for theme in ["Classic", "Minimal"] {
            openBoundSettings(in: app)
            element("bound.theme", in: app).tap()
            app.buttons[theme].firstMatch.tap()
            closeBoundSheet(in: app)
            XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
            screenshot("Bound-pixel-notes-placeholder-" + theme)
        }
        if !previous.isEmpty {
            editor.tap(); editor.typeText(previous)
            app.buttons["Done"].firstMatch.tap()
        }
    }

    func testPanelsAndNotesPersist() throws {
        let app = openGame()
        selectCompanion("Notes", in: app)
        let editor = app.textViews["bound.notes-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("QA companion note")
        XCTAssertFalse(app.staticTexts["Saved on this device"].exists)
        screenshot("Bound-portrait-notes-keyboard")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Saved on this device"].exists)
        screenshot("Bound-landscape-notes-keyboard")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" after foreground")
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertFalse(app.staticTexts["Saved on this device"].exists)
        resumeNativePause(in: app)
        selectCompanion("Types", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "bound.type-chart").firstMatch.waitForExistence(timeout: 5))
        screenshot("Bound-landscape-type-chart")
        selectCompanion("Friend", in: app)
        openNativePause(in: app)
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.secureTextFields["Password"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Sign in"].isEnabled)
        closeBoundSheet(in: app)
        selectCompanion("Notes", in: app)
        XCTAssertTrue((editor.value as? String)?.contains("QA companion note") == true)
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        _ = openGame()
        selectCompanion("Notes", in: app)
        XCTAssertTrue((editor.value as? String)?.contains("QA companion note") == true)
        screenshot("Bound-portrait-notes-restored")
    }
}

/// Requires the original generated fixture in Documents/PickerImportQA.
/// Staging is documented in PrototypeTools/verify.sh; no personal ROM is read.
final class FileImportUITests: XCTestCase {
    func testActualFilesPickerCancelRetryAndImport() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        #if DEBUG
        app.launchArguments.append("--bound-ui-no-animations")
        #endif
        app.launch()
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 2) { close.tap() }
        app.buttons["Add"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 20))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10))
        app.buttons["Add"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 20))
        let local = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label == %@", "On My iPhone", "On My iPad")).firstMatch
        if !local.exists, app.buttons["Browse"].firstMatch.exists {
            app.buttons["Browse"].firstMatch.tap()
        }
        XCTAssertTrue(local.waitForExistence(timeout: 15)); local.tap()
        let bound = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Delta Bound", "Bound"))
        XCTAssertTrue(bound.firstMatch.waitForExistence(timeout: 15))
        let folder = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "PickerImportQA")).firstMatch
        // Prototype and release identities can both be installed with the Bound
        // display name. Open the provider containing our staged test cartridge.
        for index in 0..<bound.count {
            bound.element(boundBy: index).tap()
            if folder.waitForExistence(timeout: 3) { break }
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(folder.waitForExistence(timeout: 15)); folder.tap()
        let file = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "BoundPickerDiagnostic")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        XCTAssertTrue(file.isEnabled)
        file.tap()
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 20))
        // Game cells expose their title as a child StaticText, not a cell label.
        let search = app.searchFields["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("BoundPickerDiagnostic")
        let imported = app.collectionViews.cells.containing(.staticText, identifier: "BoundPickerDiagnostic").firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 20))
        imported.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
    }
}

final class ReleaseSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        // Xcode 27 can miss animation-idle notifications from the native pause
        // menu indefinitely. This opt-in affects only XCTest's runner, never
        // the app: assertions below wait for actual elements and orientation.
        guard ProcessInfo.processInfo.environment["BOUND_UI_EXPLICIT_WAITS"] == "1" else { return }
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            method_setImplementation(method, imp_implementationWithBlock(skip))
        }
    }

    func testReleaseScreenshotsWithOriginalDiagnosticCartridge() throws {
        #if DEBUG
        throw XCTSkip("Capture the shipping Release interface.")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        let search = app.searchFields["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.tap(); search.typeText("BoundPickerDiagnostic")
        let game = app.collectionViews.cells.containing(.staticText, identifier: "BoundPickerDiagnostic").firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 10)); game.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        openBoundSettings(in: app)
        let layout = app.descendants(matching: .any).matching(identifier: "bound.screen-layout").firstMatch
        XCTAssertTrue(layout.waitForExistence(timeout: 5)); layout.tap()
        app.buttons["Bound"].firstMatch.tap()
        closeBoundSheet(in: app)
        selectCompanion("Notes", in: app)
        XCTAssertTrue(app.textViews["bound.notes-editor"].waitForExistence(timeout: 10))
        func capture(_ name: String) {
            // Let the shipping animation finish; the runner's notification
            // workaround above does not disable or accelerate app animations.
            Thread.sleep(forTimeInterval: 1)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("Release-01-portrait-notes")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["bound.panel-cycle"].isHittable)
        capture("Release-02-landscape-notes")
        openNativePause(in: app)
        XCTAssertTrue(app.buttons["Bound Settings"].isHittable)
        resumeNativePause(in: app)
        XCUIDevice.shared.orientation = .portrait
        openBoundSettings(in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        capture("Release-03-settings")
        #endif
    }

    func testReleaseLibrarySettingsAndPlaybackHaveNoDevelopmentUI() throws {
        #if DEBUG
        throw XCTSkip("Run this smoke case with -configuration Release.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        #if DEBUG
        app.launchArguments.append("--bound-ui-no-animations")
        #endif
        app.launch()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Close"].exists, "No upstream release-note onboarding")
        app.buttons["Settings"].tap()
        XCTAssertFalse(app.staticTexts["Experimental Features"].exists)
        XCTAssertFalse(app.staticTexts["Delta Sync"].exists)
        XCTAssertFalse(app.staticTexts["Patreon"].exists)
        let close = app.buttons["Close"].firstMatch
        let done = app.buttons["Done"].firstMatch
        if close.waitForExistence(timeout: 5) { close.tap() }
        else { XCTAssertTrue(done.waitForExistence(timeout: 10)); done.tap() }
        // A generated game is imported by the fixture setup, never a personal ROM.
        let cell = app.collectionViews.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20)); cell.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        openBoundSettings(in: app)
        let about = app.staticTexts["About Bound 2"].firstMatch
        for _ in 0..<6 {
            if about.exists && about.isHittable { break }
            let form = app.collectionViews.firstMatch
            XCTAssertTrue(form.exists)
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.80))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Build entry"].exists)
        XCTAssertFalse(app.staticTexts["Engine source"].exists)
        XCTAssertFalse(app.staticTexts["Package identifier"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "private testing prototype")).firstMatch.exists)
        let source = app.buttons["bound.source-and-licenses-link"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "bound.source-version").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "bound.source-repository").firstMatch.exists)
        let license = app.buttons["bound.license-agpl"].firstMatch
        XCTAssertTrue(license.waitForExistence(timeout: 10)); license.tap()
        XCTAssertTrue(app.staticTexts["bound.license-content"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        closeBoundSheet(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["bound.panel-cycle"].exists)
        selectCompanion("Notes", in: app)
        XCTAssertTrue(app.textViews["bound.notes-editor"].waitForExistence(timeout: 10))
        selectCompanion("Types", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "bound.type-chart").firstMatch.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .portrait
        #endif
    }
}
