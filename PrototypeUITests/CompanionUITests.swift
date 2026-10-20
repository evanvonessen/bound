import XCTest
import UIKit
import ObjectiveC

private func selectCompanion(_ name: String, in app: XCUIApplication) {
    let cycle = app.buttons["bound.panel-cycle"]
    XCTAssertTrue(cycle.waitForExistence(timeout: 15))
    resumeNativePause(in: app)
    // The default portrait layout splits Friend and reference views into
    // separate controls; the parent button no longer cycles every view.
    let segments = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bound.panel-cycle.")).allElementsBoundByIndex
    if !segments.isEmpty {
        for segment in segments where segment.isEnabled {
            segment.tap()
            for _ in 0..<5 {
                if segment.value as? String == name { return }
                segment.tap()
            }
        }
        XCTFail("No companion button contains \(name)")
        return
    }
    for _ in 0..<5 {
        if cycle.value as? String == name { return }
        cycle.tap()
        XCTAssertFalse(app.buttons["Settings"].exists, "Cycling panels must not open the pause menu")
    }
    XCTAssertEqual(cycle.value as? String, name)
}

private func openNativePause(in app: XCUIApplication) {
    if app.buttons["Settings"].exists { return }
    let menu = app.descendants(matching: .any).matching(identifier: "bound.native-menu").firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    menu.tap()
    XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
}

private func openBoundSettings(in app: XCUIApplication) {
    openNativePause(in: app)
    app.buttons["Settings"].tap()
    XCTAssertTrue(app.buttons["bound.settings-controls"].waitForExistence(timeout: 5))
    app.buttons["bound.settings-controls"].tap()
    XCTAssertTrue(app.switches["bound.controller-mode-enabled"].waitForExistence(timeout: 5))
}

private func resumeNativePause(in app: XCUIApplication) {
    let resume = app.buttons["Resume"].firstMatch
    if resume.exists && resume.isHittable { resume.tap() }
}

private func closeBoundSheet(in app: XCUIApplication) {
    let close = app.buttons["bound.settings-close"]
    if close.exists { close.tap() } else { app.buttons["Done"].firstMatch.tap() }
    resumeNativePause(in: app)
}

private func swipeDownSettings(in app: XCUIApplication) {
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.90))
    start.press(forDuration: 0.1, thenDragTo: end)
    XCTAssertTrue(app.buttons["bound.settings-close"].waitForNonExistence(timeout: 10),
                  "The settings sheet must dismiss after the downward swipe.")
    XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5),
                  "A downward sheet swipe should return to the paused game's menu.")
}

private func gamePixelSample(_ game: XCUIElement, in app: XCUIApplication) -> Data? {
    guard let screenshot = XCUIScreen.main.screenshot().image.cgImage else { return nil }
    // Use the target app's measured bounds: the UI-test runner's UIScreen can
    // have a different coordinate space from the application under test.
    let appFrame = app.frame
    guard appFrame.width > 0, appFrame.height > 0 else { return nil }
    let frame = game.frame.intersection(appFrame)
    let x = (frame.minX - appFrame.minX) / appFrame.width
    let y = (frame.minY - appFrame.minY) / appFrame.height
    let normalizedWidth = frame.width / appFrame.width, normalizedHeight = frame.height / appFrame.height
    let screenshotWidth = CGFloat(screenshot.width), screenshotHeight = CGFloat(screenshot.height)
    let sample: CGRect
    if appFrame.width > appFrame.height && screenshot.width < screenshot.height {
        // XCTest can keep screenshot pixels in the display's portrait orientation
        // while accessibility frames have already rotated into landscape.
        if XCUIDevice.shared.orientation == .landscapeRight {
            sample = CGRect(x: y * screenshotWidth, y: (1 - x - normalizedWidth) * screenshotHeight,
                            width: normalizedHeight * screenshotWidth, height: normalizedWidth * screenshotHeight)
        } else {
            sample = CGRect(x: (1 - y - normalizedHeight) * screenshotWidth, y: x * screenshotHeight,
                            width: normalizedHeight * screenshotWidth, height: normalizedWidth * screenshotHeight)
        }
    } else {
        sample = CGRect(x: x * screenshotWidth, y: y * screenshotHeight,
                        width: normalizedWidth * screenshotWidth, height: normalizedHeight * screenshotHeight)
    }
    let pixels = sample.integral.intersection(CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height))
    guard pixels.width > 0, pixels.height > 0,
          let crop = screenshot.cropping(to: pixels) else { return nil }
    let width = crop.width, height = crop.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
        guard let base = storage.baseAddress,
              let context = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return rendered ? Data(rgba) : nil
}

private func settingsPixelLuminance(x normalizedX: CGFloat, in app: XCUIApplication) -> CGFloat? {
    guard let screenshot = XCUIScreen.main.screenshot().image.cgImage else { return nil }
    let appFrame = app.frame
    guard appFrame.width > appFrame.height, appFrame.width > 0, appFrame.height > 0 else { return nil }
    let width = CGFloat(screenshot.width), height = CGFloat(screenshot.height)
    let sampleWidth: CGFloat = 0.008, sampleHeight: CGFloat = 0.012
    let sample: CGRect
    if screenshot.width < screenshot.height {
        let rect = CGRect(x: normalizedX - sampleWidth / 2, y: 0.5 - sampleHeight / 2,
                          width: sampleWidth, height: sampleHeight)
        if XCUIDevice.shared.orientation == .landscapeRight {
            sample = CGRect(x: rect.minY * width, y: (1 - rect.maxX) * height,
                            width: rect.height * width, height: rect.width * height)
        } else {
            sample = CGRect(x: (1 - rect.maxY) * width, y: rect.minX * height,
                            width: rect.height * width, height: rect.width * height)
        }
    } else {
        sample = CGRect(x: (normalizedX - sampleWidth / 2) * width,
                        y: (0.5 - sampleHeight / 2) * height,
                        width: sampleWidth * width, height: sampleHeight * height)
    }
    let pixels = sample.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard pixels.width > 0, pixels.height > 0, let crop = screenshot.cropping(to: pixels) else { return nil }
    let pixelWidth = crop.width, pixelHeight = crop.height
    var rgba = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
    let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
        guard let base = storage.baseAddress,
              let context = CGContext(data: base, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return true
    }
    guard rendered else { return nil }
    var luminance: Double = 0
    for index in stride(from: 0, to: rgba.count, by: 4) {
        let red = Double(rgba[index]) * 0.2126
        let green = Double(rgba[index + 1]) * 0.7152
        let blue = Double(rgba[index + 2]) * 0.0722
        luminance += red + green + blue
    }
    return CGFloat(luminance / Double(pixelWidth * pixelHeight))
}

private func assertGamePixelsAnimate(_ game: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    guard let initial = gamePixelSample(game, in: app) else {
        XCTFail("Could not capture the game view pixels", file: file, line: line)
        return
    }
    for _ in 0..<12 {
        Thread.sleep(forTimeInterval: 0.25)
        if let next = gamePixelSample(game, in: app), next != initial { return }
    }
    XCTFail("The game view pixels stayed unchanged for three seconds", file: file, line: line)
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

    private func assertPermanentFeatureBaseline(in app: XCUIApplication) {
        XCTAssertFalse(app.switches["bound.enable-experimental-features"].exists,
                       "Bound companion views are available without an opt-in switch.")
    }

    func testFastForwardToggleSurvivesAppTermination() throws {
        // Xcode 27 can miss the native menu's animation-idle notification.
        // Skip that runner-only wait; every transition below checks real UI.
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originalImplementations: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            let replacement = imp_implementationWithBlock(skip)
            originalImplementations.append((method, method_setImplementation(method, replacement)))
        }
        defer {
            for (method, original) in originalImplementations {
                let replacement = method_setImplementation(method, original)
                imp_removeBlock(replacement)
            }
        }
        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        defer {
            app.terminate()
            app.launch()
            assertPermanentFeatureBaseline(in: app)
            app.terminate()
        }

        func openGameAndPause() {
            let game = app.collectionViews.cells.firstMatch
            XCTAssertTrue(game.waitForExistence(timeout: 20)); game.tap()
            XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
            openNativePause(in: app)
        }
        openGameAndPause()
        let fastForward = app.buttons["Fast Forward"]
        XCTAssertTrue(fastForward.waitForExistence(timeout: 5))
        if fastForward.isSelected { fastForward.tap() }
        fastForward.tap()
        XCTAssertTrue(fastForward.isSelected)

        app.terminate()
        app.launch()
        openGameAndPause()
        XCTAssertTrue(fastForward.isSelected, "The enabled toggle must restore after the app process terminates")
        fastForward.tap()
        XCTAssertFalse(fastForward.isSelected)

        app.terminate()
        app.launch()
        openGameAndPause()
        XCTAssertFalse(fastForward.isSelected, "Turning fast forward off must also survive app termination")
    }

    func testSaveStateRenameUnlockedWithPreviewsAndNameSorting() throws {
        try checkSaveStateRename(previewsEnabled: true, initiallyLocked: false)
    }

    func testSaveStateRenameLockedWithPreviewsAndNameSorting() throws {
        try checkSaveStateRename(previewsEnabled: true, initiallyLocked: true)
    }

    func testSaveStateRenameUnlockedWithoutPreviewsAndNameSorting() throws {
        try checkSaveStateRename(previewsEnabled: false, initiallyLocked: false)
    }

    func testSaveStateRenameLockedWithoutPreviewsAndNameSorting() throws {
        try checkSaveStateRename(previewsEnabled: false, initiallyLocked: true)
    }

    private func checkSaveStateRename(previewsEnabled: Bool, initiallyLocked: Bool) throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originalImplementations: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originalImplementations.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            for (method, original) in originalImplementations {
                imp_removeBlock(method_setImplementation(method, original))
            }
        }

        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations", "-isPreviewsEnabled", previewsEnabled ? "YES" : "NO",
                               "-preferredSaveStatesSorting", "name", "-prefersDescendingSaveStatesSorting", "NO"]
        defer { app.terminate() }
        let suffix = UUID().uuidString.prefix(8)
        let testNamePrefix = "ZZZ Rename QA " + suffix + " "
        let middleName = testNamePrefix + "Middle"
        let newName = testNamePrefix + "Zulu"
        let finalName = testNamePrefix + "Alpha"
        func openStates(_ mode: String = "Save State") {
            app.launch()
            let game = app.collectionViews.cells.containing(.staticText, identifier: "BoundPickerDiagnostic").firstMatch
            XCTAssertTrue(game.waitForExistence(timeout: 20)); game.tap()
            XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
            openNativePause(in: app)
            app.buttons[mode].tap()
            XCTAssertTrue(app.navigationBars[mode].waitForExistence(timeout: 10))
        }
        openStates()
        let states = app.collectionViews["bound.save-states"]
        let cells = states.cells
        let rename = app.buttons["Rename"].firstMatch
        let alert = app.alerts["Rename Save State"]
        let field = alert.textFields.firstMatch
        var stateIDsByName = [String: String]()
        func currentStateSnapshots() -> [XCUIElementSnapshot] {
            // Use one immutable accessibility snapshot. Resolving a list of
            // live cell queries while scrolling can hit recycled cells.
            guard let snapshot = try? states.snapshot() else { return [] }
            func snapshots(in snapshot: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
                if snapshot.elementType == .cell, snapshot.identifier.hasPrefix("bound.save-state.") {
                    return [snapshot]
                }
                return snapshot.children.flatMap { snapshots(in: $0) }
            }
            return snapshots(in: snapshot)
        }
        func currentOrderedStateIDs() -> [String] {
            currentStateSnapshots().map(\.identifier)
        }
        func currentStateIDs() -> Set<String> {
            Set(currentOrderedStateIDs())
        }
        func scrollStates(up: Bool) {
            let top = states.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let bottom = states.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            // End the drag stationary so deceleration cannot recycle a row
            // between revealing it and tapping it with quiescence disabled.
            (up ? bottom : top).press(forDuration: 0.05, thenDragTo: up ? top : bottom,
                                     withVelocity: .fast, thenHoldForDuration: 0.2)
        }
        func allStateIDs() -> [String] {
            var previousIDs: Set<String>?
            for _ in 0..<24 {
                let ids = currentStateIDs()
                if ids == previousIDs { break }
                previousIDs = ids
                scrollStates(up: false)
            }
            var result = [String]()
            previousIDs = nil
            for _ in 0..<24 {
                let ids = currentOrderedStateIDs()
                for id in ids where !result.contains(id) { result.append(id) }
                if Set(ids) == previousIDs { break }
                previousIDs = Set(ids)
                scrollStates(up: true)
            }
            return result
        }
        func reveal(_ state: XCUIElement) -> Bool {
            for scrollUp in [true, false] {
                var previousIDs: Set<String>?
                var unchangedScrolls = 0
                for _ in 0..<24 {
                    if state.exists && state.isHittable { return true }
                    // Offscreen collection cells may not have a snapshot at all;
                    // reading their frame fails XCTest before we can scroll.
                    let ids = currentStateIDs()
                    unchangedScrolls = ids == previousIDs ? unchangedScrolls + 1 : 0
                    if unchangedScrolls == 2 { break }
                    previousIDs = ids
                    scrollStates(up: scrollUp)
                }
            }
            return state.exists && state.isHittable
        }
        func waitForStableState(_ state: XCUIElement, id: String) {
            var priorFrame: CGRect?
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let frame = currentStateSnapshots().first(where: { $0.identifier == id })?.frame else {
                    priorFrame = nil
                    return false
                }
                defer { priorFrame = frame }
                return frame == priorFrame && state.exists && state.isHittable
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
        }
        func pressState(_ state: XCUIElement, id: String) {
            waitForStableState(state, id: id)
            state.press(forDuration: 1)
        }
        func addAndRename(to name: String) {
            let previousIDs = Set(allStateIDs())
            app.navigationBars["Save State"].buttons["Add"].tap()
            let addedIDs = Set(allStateIDs()).subtracting(previousIDs)
            XCTAssertEqual(addedIDs.count, 1, "Identify the newly saved state across the entire collection")
            guard let createdID = addedIDs.first else {
                XCTFail("Creating a save state must add a unique collection item")
                return
            }
            let createdState = cells[createdID]
            XCTAssertTrue(reveal(createdState), "The new save state must be reachable after name sorting")
            pressState(createdState, id: createdID)
            XCTAssertTrue(rename.waitForExistence(timeout: 10)); rename.tap()
            XCTAssertTrue(alert.waitForExistence(timeout: 10))
            XCTAssertTrue((field.value as? String ?? "").isEmpty || field.value as? String == "Name", "Only rename the new unnamed fixture state")
            field.tap(); field.typeText(name)
            alert.buttons["Rename"].tap()
            stateIDsByName[name] = createdID
            let renamedCell = cells[createdID]
            XCTAssertTrue(reveal(renamedCell), "The renamed cell must be reachable after its sort position changes")
            XCTAssertTrue(renamedCell.staticTexts[name].waitForExistence(timeout: 10))
        }
        func performStateAction(named stateName: String, actionTitle: String) {
            guard let id = stateIDsByName[stateName] else {
                XCTFail("No stable collection ID recorded for save state \(stateName)")
                return
            }
            let state = cells[id]
            XCTAssertTrue(reveal(state), "Expected save state \(stateName) to be available for \(actionTitle)")
            pressState(state, id: id)
            let action = app.buttons[actionTitle].firstMatch
            XCTAssertTrue(action.waitForExistence(timeout: 10), "Expected \(actionTitle) for save state \(stateName)")
            action.tap()
        }
        func cancelRename(of stateName: String) {
            guard let id = stateIDsByName[stateName] else {
                XCTFail("No stable collection ID recorded for save state \(stateName)")
                return
            }
            let state = cells[id]
            XCTAssertTrue(reveal(state))
            pressState(state, id: id)
            XCTAssertTrue(rename.waitForExistence(timeout: 10)); rename.tap()
            XCTAssertTrue(alert.waitForExistence(timeout: 10))
            alert.buttons["Cancel"].tap()
            XCTAssertTrue(app.staticTexts[stateName].waitForExistence(timeout: 10), "Cancelling must preserve the saved name")
        }
        func renameState(from oldName: String, to newName: String) {
            guard let id = stateIDsByName[oldName] else {
                XCTFail("No stable collection ID recorded for save state \(oldName)")
                return
            }
            let state = cells[id]
            XCTAssertTrue(reveal(state), "Expected save state \(oldName) to be available for renaming")
            pressState(state, id: id)
            XCTAssertTrue(rename.waitForExistence(timeout: 10)); rename.tap()
            XCTAssertTrue(alert.waitForExistence(timeout: 10))
            // UIAlertController focuses this field with the cursor at its end.
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count))
            field.typeText(newName)
            alert.buttons["Rename"].tap()
            stateIDsByName.removeValue(forKey: oldName)
            stateIDsByName[newName] = id
            let renamedCell = cells[id]
            XCTAssertTrue(reveal(renamedCell), "The renamed cell must be reachable after its sort position changes")
            XCTAssertTrue(renamedCell.staticTexts[newName].waitForExistence(timeout: 10))
        }
        addAndRename(to: String(middleName))
        addAndRename(to: String(newName))
        if initiallyLocked {
            performStateAction(named: String(middleName), actionTitle: "Lock")
            performStateAction(named: String(newName), actionTitle: "Lock")
        }

        cancelRename(of: String(newName))
        renameState(from: String(newName), to: String(finalName))
        let namesAfterSortedRename = allStateIDs()
        let renamedID = try XCTUnwrap(stateIDsByName[String(finalName)])
        let middleID = try XCTUnwrap(stateIDsByName[String(middleName)])
        XCTAssertLessThan(try XCTUnwrap(namesAfterSortedRename.firstIndex(of: renamedID)),
                          try XCTUnwrap(namesAfterSortedRename.firstIndex(of: middleID)),
                          "Renaming Zulu to Alpha must move the state before Middle in its section")

        if initiallyLocked {
            performStateAction(named: String(finalName), actionTitle: "Unlock")
            let unlockedName = testNamePrefix + "Bravo"
            renameState(from: String(finalName), to: unlockedName)
        } else {
            let lockedName = testNamePrefix + "Bravo"
            performStateAction(named: String(finalName), actionTitle: "Lock")
            renameState(from: String(finalName), to: lockedName)
        }

        let persistedName = testNamePrefix + "Bravo"
        let persistedState = cells[try XCTUnwrap(stateIDsByName[persistedName])]
        XCTAssertTrue(reveal(persistedState))

        // Renaming and section moves must leave the collection usable for another save.
        let previousIDs = Set(allStateIDs())
        app.navigationBars["Save State"].buttons["Add"].tap()
        XCTAssertEqual(Set(allStateIDs()).subtracting(previousIDs).count, 1)

        XCTAssertEqual(app.state, .runningForeground)
        app.terminate()
        openStates("Load State")
        let persistedID = try XCTUnwrap(stateIDsByName[persistedName])
        let renamedState = cells[persistedID]
        XCTAssertTrue(reveal(renamedState), "Renaming and lock state must survive app termination")
        pressState(renamedState, id: persistedID)
        let expectedLockAction = initiallyLocked ? "Lock" : "Unlock"
        XCTAssertTrue(app.buttons[expectedLockAction].waitForExistence(timeout: 10), "The final lock state must persist across app termination")
        app.buttons[expectedLockAction].tap()
        XCTAssertTrue(app.buttons[expectedLockAction].waitForNonExistence(timeout: 5))
        let stateAfterLockToggle = cells[persistedID]
        XCTAssertTrue(reveal(stateAfterLockToggle))
        waitForStableState(stateAfterLockToggle, id: persistedID)
        stateAfterLockToggle.tap()
        XCTAssertTrue(app.navigationBars["Load State"].waitForNonExistence(timeout: 10))
        let gameScreen = element("bound.game-screen", in: app)
        XCTAssertTrue(gameScreen.waitForExistence(timeout: 10))
        assertGamePixelsAnimate(gameScreen, in: app)

        for _ in 0..<2 {
            openNativePause(in: app)
            app.buttons["Load State"].tap()
            XCTAssertTrue(app.navigationBars["Load State"].waitForExistence(timeout: 10))
            let repeatedLoadState = cells[persistedID]
            XCTAssertTrue(reveal(repeatedLoadState), "The renamed state must remain loadable during active gameplay")
            waitForStableState(repeatedLoadState, id: persistedID)
            repeatedLoadState.tap()
            XCTAssertTrue(app.navigationBars["Load State"].waitForNonExistence(timeout: 10))
            XCTAssertTrue(gameScreen.waitForExistence(timeout: 10))
            assertGamePixelsAnimate(gameScreen, in: app)
        }
    }

    private func openRRDexPlayback(in app: XCUIApplication) {
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        let gameCell = app.collectionViews.cells.firstMatch
        XCTAssertTrue(gameCell.waitForExistence(timeout: 20)); gameCell.tap()
        selectCompanion("Dex", in: app)
        XCTAssertTrue(element("bound.rrdex", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("bound.game-screen", in: app).exists)
    }

    private func clearLibrarySearch(in app: XCUIApplication) {
        let search = app.searchFields["Search"].firstMatch
        if search.exists, let value = search.value as? String, !value.isEmpty, value != search.placeholderValue {
            search.tap()
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            search.typeText("\n")
        }
    }

    private func libraryGame(named name: String, in app: XCUIApplication) -> XCUIElement {
        clearLibrarySearch(in: app)
        let search = app.searchFields["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText(name); search.typeText("\n")
        return app.collectionViews.cells.containing(.staticText, identifier: name).firstMatch
    }

    private func chooseRRDexDocument(_ filename: String, in app: XCUIApplication) {
        let browse = app.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 3) { browse.tap() }
        let localFiles = app.staticTexts["On My iPhone"].firstMatch
        if localFiles.waitForExistence(timeout: 3) { localFiles.tap() }
        let fileView = app.collectionViews["File View"]
        let folder = fileView.cells["Bound, Container"]
        if folder.waitForExistence(timeout: 3) { folder.tap() }
        let base = (filename as NSString).deletingPathExtension
        let file = fileView.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", base)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "Find QA document \(filename) in the Bound app's Files container")
        file.tap()
        let open = app.buttons["Open"].firstMatch
        if open.exists { open.tap() }
        XCTAssertTrue(file.waitForNonExistence(timeout: 10), "Wait for the document picker to finish closing after choosing \(filename)")
    }

    func testImportRRDexCurrentGameFixture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations"]
        app.launch()
        let title = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        if title.waitForExistence(timeout: 5) { return }

        // Close the native search presentation before looking for Library Add.
        let closeSearch = app.buttons["close"].firstMatch
        if closeSearch.exists { closeSearch.tap() }
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 5))
        app.buttons["Add"].tap()
        chooseRRDexDocument("BoundRRDexDiagnostic.gba", in: app)
        let imported = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(imported.waitForExistence(timeout: 20), "The staged current-save fixture ROM must be available in the library")
    }

    func testRRDexLayout7SearchDescriptionsAndAutomaticSaveRefresh() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound",
                               "-bound.delta.pip.v1.dex.layout", "7"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        defer {
            app.terminate(); app.launch()
            assertPermanentFeatureBaseline(in: app)
            app.terminate()
        }
        func openDex() {
            let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
            XCTAssertTrue(game.waitForExistence(timeout: 20))
            game.tap()
            XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
            selectCompanion("Dex", in: app)
            XCTAssertTrue(element("bound.rrdex", in: app).waitForExistence(timeout: 10))
            XCTAssertEqual(element("bound.rrdex", in: app).value as? String, "Layout 7")
            XCTAssertFalse(app.buttons["bound.rrdex-info"].exists,
                           "Dex version details are plain text, not an Information button.")
            XCTAssertTrue(app.staticTexts["bound.rrdex-reference-rom"].exists)
            XCTAssertTrue(app.staticTexts["bound.rrdex-reference-difficulty"].exists)
        }
        func assertAutomaticSave() {
            XCTAssertFalse(app.buttons["bound.rrdex-import"].exists, "Layout 7 has no manual save control")
            XCTAssertFalse(app.alerts["Save could not be imported"].exists)
            XCTAssertFalse(app.links["Radical Red Pokédex · JwowSquared"].exists)
        }
        openDex()
        let gameScreen = element("bound.game-screen", in: app)
        XCTAssertTrue(gameScreen.waitForExistence(timeout: 10))
        assertAutomaticSave()
        assertGamePixelsAnimate(gameScreen, in: app)
        XCTAssertFalse(app.textFields["bound.rrdex-search"].exists)
        let searchButton = app.buttons["bound.rrdex-search-open"]
        XCTAssertTrue(searchButton.isHittable)
        XCTAssertGreaterThan(searchButton.frame.minX, app.frame.midX + 78)
        XCTAssertFalse(app.buttons["bound.rrdex-info"].exists)
        searchButton.tap()
        let search = app.textFields["bound.rrdex-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("bulbasaur")
        app.buttons["bound.rrdex-suggestion-1"].tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Bulbasaur")
        let ability0 = app.staticTexts["bound.rrdex-ability-description-0"]
        let ability1 = app.staticTexts["bound.rrdex-ability-description-1"]
        XCTAssertTrue(ability0.label.contains("Friend Guard"))
        XCTAssertTrue(ability1.label.contains("Limber"))
        XCTAssertGreaterThan(ability1.frame.minY, ability0.frame.minY, "Each ability occupies its own line")
        XCTAssertTrue(ability1.label.contains("Hidden"))
        screenshot("RRDex-layout-7-auto-save-abilities")
        let details = element("bound.rrdex-details", in: app)
        func reveal(_ button: XCUIElement) {
            for _ in 0..<6 {
                if button.isHittable && details.frame.contains(button.frame) { return }
                details.swipeUp()
            }
            XCTAssertTrue(button.isHittable)
        }
        let learnset = app.buttons["bound.rrdex-learnset"]
        reveal(learnset)
        let evolution = element("bound.rrdex-evolution", in: app)
        XCTAssertGreaterThan(learnset.frame.minX, evolution.frame.minX)
        screenshot("RRDex-layout-7-evolution-shortcuts")
        learnset.tap()
        XCTAssertTrue(element("bound.rrdex-moves", in: app).waitForExistence(timeout: 10))
        app.buttons["bound.rrdex-close-detail"].tap()
        XCTAssertTrue(app.buttons["bound.rrdex-close-detail"].waitForNonExistence(timeout: 5))
        let weaknesses = app.buttons["bound.rrdex-weaknesses"]
        reveal(weaknesses); weaknesses.tap()
        XCTAssertTrue(element("bound.rrdex-matchups", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Based on typing. Abilities, items, and battle effects can change damage."].exists)
        app.buttons["bound.rrdex-close-detail"].tap()
        XCTAssertTrue(app.buttons["bound.rrdex-close-detail"].waitForNonExistence(timeout: 5))
        assertGamePixelsAnimate(gameScreen, in: app)
        XCTAssertFalse(app.collectionViews["File View"].exists)
        app.terminate(); app.launch(); openDex()
        assertAutomaticSave()
        XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Bulbasaur")
        assertGamePixelsAnimate(element("bound.game-screen", in: app), in: app)
    }

    func testRRDexReferenceTextAtEndOfScrollableContentPortraitAndLandscape() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            XCUIDevice.shared.orientation = .portrait
            for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) }
        }

        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-reset-layout", "--bound-ui-friend-fixture",
                               "--bound-ui-screen-layout-bound", "--bound-ui-no-animations",
                               "-bound.delta.pip.v1.dex.layout", "12"]
        app.launch()
        let diagnostic = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 20))
        diagnostic.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        let game = element("bound.game-screen", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 10))
        selectCompanion("Dex", in: app)
        let dex = element("bound.rrdex", in: app)
        func assertReferenceText(_ screenshotName: String) {
            XCTAssertTrue(dex.waitForExistence(timeout: 10))
            XCTAssertEqual(dex.value as? String, "Layout 12")
            XCTAssertFalse(app.buttons["bound.rrdex-info"].exists,
                           "Dex version details must not expose an information action.")
            let details = app.scrollViews["bound.rrdex-layout12-details"]
            let footer = element("bound.rrdex-reference-footer", in: app)
            let rom = app.staticTexts["bound.rrdex-reference-rom"]
            let difficulty = app.staticTexts["bound.rrdex-reference-difficulty"]
            XCTAssertTrue(details.waitForExistence(timeout: 10))
            XCTAssertTrue(footer.exists)
            XCTAssertEqual(rom.label, "Radical Red Version 4.1")
            XCTAssertEqual(difficulty.label, "Normal Difficulty")
            XCTAssertFalse(app.buttons["bound.rrdex-close-detail"].exists,
                           "The reference text does not present a detail sheet.")

            let pokemonName = app.staticTexts["bound.rrdex-pokemon"]
            for _ in 0..<10 {
                if details.frame.contains(pokemonName.frame) { break }
                details.swipeDown()
            }
            let initiallyVisibleY = footer.frame.minY
            XCTAssertGreaterThan(footer.frame.minY, details.frame.maxY,
                                 "The reference text starts below the visible Dex content.")
            for _ in 0..<12 {
                if details.frame.insetBy(dx: 0, dy: -1).contains(footer.frame) { break }
                details.swipeUp()
            }
            XCTAssertTrue(details.frame.insetBy(dx: 0, dy: -1).contains(footer.frame),
                           "The reference text should be at the end of the Dex details scroller.")
            XCTAssertGreaterThan(initiallyVisibleY, footer.frame.minY + 8,
                                 "Scrolling to the content tail should move the reference text with the Dex content.")
            let tailY = footer.frame.minY
            XCTAssertEqual(rom.frame.midX, details.frame.midX, accuracy: 2)
            XCTAssertEqual(difficulty.frame.midX, details.frame.midX, accuracy: 2)
            XCTAssertGreaterThan(difficulty.frame.minY, rom.frame.maxY)
            screenshot(screenshotName)
            footer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertFalse(app.buttons["bound.rrdex-close-detail"].exists,
                           "Tapping the reference text must not open a menu or sheet.")
            details.swipeDown()
            XCTAssertGreaterThan(footer.frame.minY, tailY + 8,
                                 "Scrolling away from the tail should move the reference text out of view.")
        }

        assertReferenceText("RRDex-Reference-Text-Portrait")
        let search = app.buttons["bound.rrdex-search-open"]
        XCTAssertTrue(search.isHittable)
        XCTAssertEqual(search.frame.midX, app.frame.midX + 102, accuracy: 4)
        XCTAssertLessThan(search.frame.midY, 70)
        XCTAssertEqual(search.frame.width, 44, accuracy: 1)
        XCTAssertEqual(search.frame.height, 44, accuracy: 1)
        assertGamePixelsAnimate(game, in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        assertReferenceText("RRDex-Reference-Text-Landscape-Left")
        assertGamePixelsAnimate(game, in: app)

        XCUIDevice.shared.orientation = .landscapeRight
        assertReferenceText("RRDex-Reference-Text-Landscape-Right")
        assertGamePixelsAnimate(game, in: app)
    }

    private func swipeDownDetail(named title: String, in app: XCUIApplication) {
        let navigationBar = app.navigationBars[title].firstMatch
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 10))
        let dragStart = navigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
    }

    func testUnifiedSettingsHomeFromLibraryAndPauseMenu() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }
        let app = XCUIApplication()
        #if DEBUG
        app.launchArguments.append("--bound-ui-no-animations")
        #endif
        app.launch()

        func assertSharedSettingsHome() {
            XCTAssertTrue(element("bound.settings-root", in: app).waitForExistence(timeout: 10))
            for identifier in ["bound.settings-controls", "bound.settings-audio",
                               "bound.settings-account", "bound.settings-about"] {
                XCTAssertTrue(element(identifier, in: app).exists, "Shared settings home must contain \(identifier).")
            }
            XCTAssertFalse(element("bound.settings-interface", in: app).exists)
            XCTAssertFalse(element("bound.settings-general", in: app).exists)
            XCTAssertFalse(app.switches["bound.experimental-settings"].exists)
            XCTAssertFalse(app.switches["bound.enable-experimental-features"].exists)
        }
        func closeSettings() {
            let close = app.buttons["bound.settings-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
        }

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        assertSharedSettingsHome()
        screenshot("Unified-Settings-Home")
        element("bound.settings-controls", in: app).tap()
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["bound.context-menu-previews"].exists)
        XCTAssertTrue(element("bound.pause-menu-button-placement", in: app).exists)
        XCTAssertTrue(app.switches["bound.controller-mode-enabled"].exists)
        XCTAssertFalse(app.switches["bound.experimental-settings"].exists)
        XCTAssertFalse(element("bound.ui-version", in: app).exists)
        screenshot("Unified-Settings-Controls")
        closeSettings()

        let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 20)); game.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        openNativePause(in: app)
        app.buttons["Settings"].tap()
        assertSharedSettingsHome()
        element("bound.settings-controls", in: app).tap()
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["bound.context-menu-previews"].exists)
        XCTAssertTrue(element("bound.pause-menu-button-placement", in: app).exists)
        XCTAssertTrue(app.switches["bound.controller-mode-enabled"].exists)
        XCTAssertFalse(app.switches["bound.experimental-settings"].exists)
        swipeDownSettings(in: app)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5),
                      "Swiping shared Settings away returns to the paused game's menu.")
        XCTAssertTrue(app.buttons["Resume"].exists)
        app.buttons["Settings"].tap()
        assertSharedSettingsHome()
        element("bound.settings-controls", in: app).tap()
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 5))
        closeSettings()
        XCTAssertTrue(app.buttons["Settings"].exists)
        app.buttons["Resume"].tap()
        let gameScreen = element("bound.game-screen", in: app)
        XCTAssertTrue(gameScreen.waitForExistence(timeout: 5))
        assertGamePixelsAnimate(gameScreen, in: app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(gameScreen.waitForExistence(timeout: 5))
        assertGamePixelsAnimate(gameScreen, in: app)

        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10),
                      "Returning from gameplay to Library should expose the same Settings entry point.")
        XCTAssertTrue(app.searchFields["Search"].exists,
                      "A fresh launch after gameplay returns to the Library.")
        app.buttons["Settings"].tap()
        assertSharedSettingsHome()
        closeSettings()
    }

    func testGeneralSettingsMoveIntoControlsAndAboutKeepsConciseSources() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations", "-bound.experimental-settings.enabled.v1", "YES"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        XCTAssertTrue(element("bound.settings-controls", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("bound.settings-interface", in: app).exists)
        XCTAssertFalse(element("bound.settings-general", in: app).exists)
        XCTAssertFalse(app.switches["bound.experimental-settings"].exists)
        XCTAssertFalse(app.switches["bound.enable-experimental-features"].exists)
        element("bound.settings-controls", in: app).tap()
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 5))

        let previews = app.switches["bound.context-menu-previews"]
        scrollToSetting(previews, in: app)
        XCTAssertTrue(previews.isHittable, "Context Menu Previews must be available in Controls")
        let originalPreviewValue = previews.value as? String
        previews.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertNotEqual(previews.value as? String, originalPreviewValue)
        let placement = element("bound.pause-menu-button-placement", in: app)
        scrollToSetting(placement, in: app)
        XCTAssertTrue(placement.isHittable)
        let controllerEnabled = app.switches["bound.controller-mode-enabled"]
        XCTAssertTrue(controllerEnabled.exists)
        XCTAssertEqual(app.switches.matching(identifier: "bound.controller-mode-enabled").count, 1)
        XCTAssertFalse(element("bound.controller-mode-layout", in: app).exists,
                        "Controller Mode has no layout selector.")
        XCTAssertFalse(app.switches["bound.experimental-settings"].exists)
        XCTAssertFalse(element("bound.ui-version", in: app).exists)
        screenshot("Controls-Moved-General-Settings")
        app.navigationBars["Controls"].buttons.firstMatch.tap()
        element("bound.settings-controls", in: app).tap()
        scrollToSetting(previews, in: app)
        XCTAssertNotEqual(previews.value as? String, originalPreviewValue, "The moved control must persist through navigation")
        previews.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(previews.value as? String, originalPreviewValue)
        app.navigationBars["Controls"].buttons.firstMatch.tap()
        element("bound.settings-about", in: app).tap()
        let sources = element("bound.source-and-licenses-link", in: app)
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        XCTAssertEqual(sources.label, "Sources & Licenses")
        XCTAssertTrue(element("bound.rules-and-contact-link", in: app).exists)
        XCTAssertFalse(app.staticTexts["Experimental"].exists)
        screenshot("About-Organized")
        sources.tap()
        XCTAssertTrue(app.navigationBars["Sources & Licenses"].waitForExistence(timeout: 5))
        XCTAssertEqual(element("bound.source-repository", in: app).label, "Source")
        XCTAssertEqual(element("bound.source-radical-red-pokedex", in: app).label, "Pokédex")
        XCTAssertEqual(element("bound.source-radical-red-docs", in: app).label, "Trainer Data")
        XCTAssertFalse(element("bound.source-availability", in: app).exists)
        screenshot("Sources-Concise-Labels")
        let license = element("bound.license-agpl", in: app)
        scrollToSetting(license, in: app)
        license.tap()
        XCTAssertTrue(app.staticTexts["bound.license-content"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["bound.license-content"].label.contains("GNU AFFERO GENERAL PUBLIC LICENSE"))
    }

    func testResetSettingsToDefaultFromLibraryAndGameSettings() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }

        let app = XCUIApplication()
        #if DEBUG
        app.launchArguments.append("--bound-ui-no-animations")
        #endif
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        XCTAssertTrue(element("bound.settings-root", in: app).waitForExistence(timeout: 10))

        let reset = app.buttons["bound.settings-reset-defaults"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertEqual(reset.label, "Reset Settings to Default")

        XCTAssertFalse(element("bound.settings-interface", in: app).exists)
        element("bound.settings-controls", in: app).tap()
        let previews = app.switches["bound.context-menu-previews"]
        XCTAssertTrue(previews.waitForExistence(timeout: 5))
        if previews.value as? String == "1" {
            previews.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let modeEnabled = app.switches["bound.controller-mode-enabled"]
        XCTAssertEqual(app.switches.matching(identifier: "bound.controller-mode-enabled").count, 1)
        XCTAssertFalse(element("bound.controller-mode-layout", in: app).exists)
        scrollToSetting(modeEnabled, in: app)
        if modeEnabled.value as? String != "1" {
            modeEnabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(modeEnabled.value as? String, "1")
        app.navigationBars["Controls"].buttons.firstMatch.tap()

        element("bound.settings-audio", in: app).tap()
        let mixAudio = app.switches["Mix with Other Audio"]
        XCTAssertTrue(mixAudio.waitForExistence(timeout: 5))
        if mixAudio.value as? String != "1" {
            mixAudio.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(mixAudio.value as? String, "1")
        app.navigationBars["Audio"].buttons.firstMatch.tap()

        XCTAssertTrue(reset.isHittable)
        reset.tap()
        XCTAssertTrue(element("bound.settings-root", in: app).exists,
                      "Reset should leave the user on the shared Settings home.")
        XCTAssertTrue(reset.exists)

        element("bound.settings-controls", in: app).tap()
        XCTAssertFalse(app.switches["bound.experimental-settings"].exists)
        XCTAssertFalse(element("bound.ui-version", in: app).exists)
        XCTAssertEqual(app.switches["bound.context-menu-previews"].value as? String, "1")
        XCTAssertEqual(app.switches["bound.controller-mode-enabled"].value as? String, "0")
        XCTAssertFalse(element("bound.controller-mode-layout", in: app).exists,
                        "Reset leaves the single Controller Mode toggle off.")
        app.navigationBars["Controls"].buttons.firstMatch.tap()
        element("bound.settings-audio", in: app).tap()
        XCTAssertEqual(mixAudio.value as? String, "0")
        XCTAssertEqual(app.switches["Respect Silent Mode"].value as? String, "0")
        app.navigationBars["Audio"].buttons.firstMatch.tap()
        app.buttons["bound.settings-close"].tap()

        let diagnostic = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 10),
                      "Resetting preferences must leave the imported ROM in the library.")
        diagnostic.tap()
        XCTAssertTrue(element("bound.native-menu", in: app).waitForExistence(timeout: 15))
        openNativePause(in: app)
        app.buttons["Settings"].tap()
        XCTAssertTrue(element("bound.settings-root", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["bound.settings-reset-defaults"].exists,
                      "The reset action should also be available from in-game Settings.")
        app.buttons["bound.settings-reset-defaults"].tap()
        XCTAssertTrue(app.buttons["bound.settings-controls"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["bound.settings-interface"].exists)
        XCTAssertFalse(app.alerts["Unable to Reset Settings"].exists)
        app.buttons["bound.settings-close"].tap()
    }

    func testDeveloperFeaturesExportAllConfigAndReset() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }

        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations"]
        app.launch()
        defer { app.terminate() }

        func openSettings() {
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
            app.buttons["Settings"].tap()
            XCTAssertTrue(element("bound.settings-root", in: app).waitForExistence(timeout: 10))
        }

        openSettings()
        let reset = app.buttons["bound.settings-reset-defaults"]
        let developerFeatures = app.switches["bound.settings-developer-features"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertTrue(developerFeatures.waitForExistence(timeout: 5))
        XCTAssertLessThan(reset.frame.midY, developerFeatures.frame.midY,
                          "Developer Features sits below Reset Settings to Default.")

        if developerFeatures.value as? String == "1" {
            developerFeatures.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(developerFeatures.value as? String, "0")
        XCTAssertFalse(app.buttons["bound.settings-export-all-config"].exists,
                       "Export All Config is hidden while Developer Features is off.")

        developerFeatures.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(developerFeatures.value as? String, "1")
        let export = app.buttons["bound.settings-export-all-config"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertLessThan(developerFeatures.frame.midY, export.frame.midY,
                          "Export All Config appears immediately below the switch.")

        app.terminate()
        app.launch()
        openSettings()
        let persistedDeveloperFeatures = app.switches["bound.settings-developer-features"]
        XCTAssertTrue(persistedDeveloperFeatures.waitForExistence(timeout: 5))
        XCTAssertEqual(persistedDeveloperFeatures.value as? String, "1",
                       "The developer-features choice persists across app launches.")
        let persistedExport = app.buttons["bound.settings-export-all-config"]
        XCTAssertTrue(persistedExport.waitForExistence(timeout: 5))
        persistedExport.tap()

        let pickerNavigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let saveExport = app.buttons["DOCPicker.actionButton"]
        func cancelPicker() {
            // Files is a dismissible sheet on current iOS. Its accessibility
            // Cancel proxy can overlap More, so exercise the visible sheet gesture.
            let origin = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: pickerNavigation.frame.midX, dy: pickerNavigation.frame.minY - 6))
            let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            origin.press(forDuration: 0.1, thenDragTo: destination)
        }
        XCTAssertTrue(saveExport.waitForExistence(timeout: 15),
                      "Export opens the system Save to Files picker.")
        screenshot("Configuration-Export-Files-Picker")
        cancelPicker()
        XCTAssertTrue(element("bound.settings-root", in: app).waitForExistence(timeout: 10),
                      "Cancel returns to Settings.")
        XCTAssertFalse(app.alerts["Unable to Export Configuration"].exists)
        XCTAssertTrue(saveExport.waitForNonExistence(timeout: 10),
                      "Wait for the file picker to dismiss before retrying export.")
        let exportEnabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                                      object: persistedExport)
        XCTAssertEqual(XCTWaiter.wait(for: [exportEnabled], timeout: 5), .completed,
                       "Cancel re-enables Export All Config.")
        persistedExport.tap()
        XCTAssertTrue(saveExport.waitForExistence(timeout: 10),
                      "Export can be opened again after canceling the first picker.")
        cancelPicker()
        XCTAssertTrue(saveExport.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.alerts["Unable to Export Configuration"].exists)

        persistedExport.tap()
        XCTAssertTrue(saveExport.waitForExistence(timeout: 10),
                      "The system file picker exposes its Save action.")
        screenshot("Configuration-Export-Before-Save")
        saveExport.tap()
        XCTAssertTrue(saveExport.waitForNonExistence(timeout: 10),
                      "Saving the JSON export dismisses the file picker.")
        XCTAssertTrue(element("bound.settings-root", in: app).waitForExistence(timeout: 10),
                      "Saving returns to Settings.")
        let exportEnabledAfterSave = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                                               object: persistedExport)
        XCTAssertEqual(XCTWaiter.wait(for: [exportEnabledAfterSave], timeout: 5), .completed,
                       "Export is available again after the save completes.")
        XCTAssertFalse(app.alerts["Unable to Export Configuration"].exists)

        let resetAfterExport = app.buttons["bound.settings-reset-defaults"]
        XCTAssertTrue(resetAfterExport.waitForExistence(timeout: 5))
        resetAfterExport.tap()
        let resetDeveloperFeatures = app.switches["bound.settings-developer-features"]
        XCTAssertTrue(resetDeveloperFeatures.waitForExistence(timeout: 5))
        XCTAssertEqual(resetDeveloperFeatures.value as? String, "0",
                       "Reset Settings to Default disables Developer Features.")
        XCTAssertFalse(app.buttons["bound.settings-export-all-config"].exists,
                       "Reset Settings to Default hides Export All Config.")
        XCTAssertFalse(app.alerts["Unable to Reset Settings"].exists)
    }

    func testUnifiedSettingsPreferencesPersistAcrossEntryPointsRelaunchAndRotation() throws {
        throw XCTSkip("This test only covers removed Interface customization controls.")
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait }
        #if DEBUG
        app.launchArguments.append("--bound-ui-no-animations")
        #endif
        app.launch()
        func openInterfaceFromLibrary() {
            app.buttons["Settings"].tap()
            app.buttons["bound.settings-interface"].tap()
            XCTAssertTrue(element("bound.ui-version", in: app).waitForExistence(timeout: 5))
        }
        func openInterfaceFromPause() {
            openNativePause(in: app)
            app.buttons["Settings"].tap()
            XCTAssertTrue(app.buttons["bound.settings-interface"].waitForExistence(timeout: 5))
            app.buttons["bound.settings-interface"].tap()
            XCTAssertTrue(element("bound.ui-version", in: app).waitForExistence(timeout: 5))
        }
        func closeSettingsAndResume() {
            app.buttons["bound.settings-close"].tap()
            resumeNativePause(in: app)
        }
        let names = ["friend", "notes", "types", "bosses", "dex"]
        func viewToggle(_ name: String) -> XCUIElement { app.switches["bound.companion-enabled.\(name)"] }

        openInterfaceFromLibrary()
        let buttonType = app.segmentedControls["bound.companion-button-type"]
        buttonType.buttons["1"].tap()
        let version = element("bound.ui-version", in: app)
        version.tap()
        app.buttons["Option 2"].tap()
        for name in names {
            let toggle = viewToggle(name)
            scrollToSetting(toggle, in: app)
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            if toggle.value as? String != "0" {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            XCTAssertEqual(toggle.value as? String, "0")
        }
        app.buttons["bound.settings-close"].tap()

        let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 20)); game.tap()
        let cycle = app.buttons["bound.panel-cycle"]
        XCTAssertTrue(cycle.waitForExistence(timeout: 15))
        XCTAssertEqual(cycle.value as? String, "No views enabled")
        openInterfaceFromPause()
        XCTAssertEqual(version.label, "UI Version, Option 2")
        for name in names {
            scrollToSetting(viewToggle(name), in: app)
            XCTAssertEqual(viewToggle(name).value as? String, "0")
        }
        scrollToSetting(viewToggle("friend"), in: app)
        viewToggle("friend").coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        closeSettingsAndResume()
        XCTAssertEqual(cycle.value as? String, "Friend")

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(element("bound.game-screen", in: app)) { _ in app.frame.width > app.frame.height }
        openInterfaceFromPause()
        XCTAssertEqual(version.label, "UI Version, Option 2")
        closeSettingsAndResume()
        XCUIDevice.shared.orientation = .portrait

        app.terminate(); app.launch()
        openInterfaceFromLibrary()
        XCTAssertEqual(version.label, "UI Version, Option 2")
        for name in names {
            scrollToSetting(viewToggle(name), in: app)
            XCTAssertEqual(viewToggle(name).value as? String, name == "friend" ? "1" : "0",
                           "In-game settings must remain visible in Library after relaunch")
        }
        app.buttons["bound.settings-close"].tap()
        let relaunchedGame = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(relaunchedGame.waitForExistence(timeout: 20)); relaunchedGame.tap()
        XCTAssertTrue(cycle.waitForExistence(timeout: 15))
        XCTAssertEqual(cycle.value as? String, "Friend")
        openInterfaceFromPause()
        XCTAssertEqual(version.label, "UI Version, Option 2")
        for name in names {
            scrollToSetting(viewToggle(name), in: app)
            XCTAssertEqual(viewToggle(name).value as? String, name == "friend" ? "1" : "0")
            if name != "friend" {
                viewToggle(name).coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        scrollToSetting(version, in: app)
        version.tap()
        app.buttons["Option 1"].tap()
        closeSettingsAndResume()
        for expected in ["Notes", "Types", "Bosses", "Dex", "Friend"] {
            cycle.tap()
            XCTAssertEqual(cycle.value as? String, expected)
        }
        app.terminate()
    }

    func testUnifiedSettingsCategoriesAndBottomContentPortrait() throws {
        try checkUnifiedSettingsCategoriesAndBottomContent(orientation: .portrait)
    }

    func testUnifiedSettingsCategoriesAndBottomContentLandscape() throws {
        try checkUnifiedSettingsCategoriesAndBottomContent(orientation: .landscapeLeft)
    }

    func testSettingsLandscapeKeepsFullWidthBackgroundAndNavigationVisible() throws {
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        #if DEBUG
        app.launchArguments.append("--bound-ui-no-animations")
        #endif
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        XCTAssertTrue(element("bound.settings-root", in: app).waitForExistence(timeout: 10))

        func assertLandscapeEdges(_ page: String) {
            screenshot("Settings-edges-\(page)-\(XCUIDevice.shared.orientation.rawValue)")
            let leftEdge = settingsPixelLuminance(x: 0.015, in: app)
            let leftContent = settingsPixelLuminance(x: 0.08, in: app)
            let rightEdge = settingsPixelLuminance(x: 0.985, in: app)
            let rightContent = settingsPixelLuminance(x: 0.92, in: app)
            XCTAssertNotNil(leftEdge, "Could not sample the left edge on \(page).")
            XCTAssertNotNil(leftContent)
            XCTAssertNotNil(rightEdge, "Could not sample the right edge on \(page).")
            XCTAssertNotNil(rightContent)
            if let leftEdge, let leftContent {
                XCTAssertLessThan(abs(leftEdge - leftContent), 6,
                                  "The left landscape edge should continue the settings background on \(page).")
            }
            if let rightEdge, let rightContent {
                XCTAssertLessThan(abs(rightEdge - rightContent), 6,
                                  "The right landscape edge should continue the settings background on \(page).")
            }
        }

        func checkBackButton(_ title: String) {
            let back = app.navigationBars[title].buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "\(title) should show its navigation back button.")
            XCTAssertTrue(back.isHittable, "\(title)'s back button should remain tappable in landscape.")
            assertLandscapeEdges(title)
        }

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(app.buttons["bound.settings-close"]) { _ in app.frame.width > app.frame.height }
        assertLandscapeEdges("Settings")
        assertSettingsCloseAtTop(in: app, navigationTitle: "Settings")

        element("bound.settings-audio", in: app).tap()
        XCTAssertTrue(app.navigationBars["Audio"].waitForExistence(timeout: 5))
        checkBackButton("Audio")
        assertSettingsCloseAtTop(in: app, navigationTitle: "Audio")
        app.navigationBars["Audio"].buttons.firstMatch.tap()

        let about = element("bound.settings-about", in: app)
        assertSettingsContentVisible(about, in: app, name: "Settings-edges-About-link")
        about.tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        checkBackButton("About")
        assertSettingsCloseAtTop(in: app, navigationTitle: "About")
        XCUIDevice.shared.orientation = .landscapeRight
        waitForFrame(app.navigationBars["About"]) { _ in app.frame.width > app.frame.height }
        checkBackButton("About")
        assertSettingsCloseAtTop(in: app, navigationTitle: "About")
        app.navigationBars["About"].buttons.firstMatch.tap()

        let audio = element("bound.settings-audio", in: app)
        assertSettingsContentVisible(audio, in: app, name: "Settings-edges-Audio-link", searchTowardTop: true)
        audio.tap()
        XCTAssertTrue(app.navigationBars["Audio"].waitForExistence(timeout: 5))
        checkBackButton("Audio")
    }

    private func checkUnifiedSettingsCategoriesAndBottomContent(orientation: UIDeviceOrientation) throws {
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        #if DEBUG
        app.launchArguments.append("--bound-ui-no-animations")
        #endif
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))

        func back(from title: String) {
            let backButton = app.navigationBars[title].buttons.firstMatch
            XCTAssertTrue(backButton.waitForExistence(timeout: 5))
            backButton.tap()
        }

        func checkBottomScreens(orientation: UIDeviceOrientation, label: String) {
            XCUIDevice.shared.orientation = orientation
            waitForFrame(app.buttons["Settings"]) { _ in
                orientation.isLandscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width
            }

            app.buttons["Settings"].tap()
            assertSettingsCloseAtTop(in: app, navigationTitle: "Settings")
            let audioLink = element("bound.settings-audio", in: app)
            XCTAssertTrue(audioLink.waitForExistence(timeout: 5))
            audioLink.tap()
            XCTAssertTrue(app.navigationBars["Audio"].waitForExistence(timeout: 5),
                          "Audio should open directly from the Settings home.")
            assertSettingsCloseAtTop(in: app, navigationTitle: "Audio")
            let pauseOtherAudio = app.switches["Pause Other Audio"]
            assertSettingsContentVisible(pauseOtherAudio, in: app, name: "\(label)-Audio-last-row")
            back(from: "Audio")

            let aboutLink = element("bound.settings-about", in: app)
            assertSettingsContentVisible(aboutLink, in: app, name: "\(label)-Home-About")
            aboutLink.tap()
            XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
            assertSettingsCloseAtTop(in: app, navigationTitle: "About")
            let gbaCore = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Game Boy Advance")).firstMatch
            assertSettingsContentVisible(gbaCore, in: app, name: "\(label)-About-GBA-core")
            gbaCore.tap()
            XCTAssertTrue(app.navigationBars["Game Boy Advance"].waitForExistence(timeout: 5),
                          "About should link directly to the Game Boy Advance core information.")
            screenshot("\(label)-About-GBA-Core-Info")
            back(from: "Game Boy Advance")

            let rulesLink = element("bound.rules-and-contact-link", in: app)
            assertSettingsContentVisible(rulesLink, in: app, name: "\(label)-About-Rules-and-Contact")

            let sourceLink = element("bound.source-and-licenses-link", in: app)
            assertSettingsContentVisible(sourceLink, in: app, name: "\(label)-About-source-link", searchTowardTop: true)
            sourceLink.tap()
            let lastNotice = element("bound.license-notesFont", in: app)
            assertSettingsContentVisible(lastNotice, in: app, name: "\(label)-Source-last-notice")
            let softwareLicenses = app.buttons["Software Licenses"]
            assertSettingsContentVisible(softwareLicenses, in: app, name: "\(label)-Software-Licenses-link", searchTowardTop: true)
            softwareLicenses.tap()
            let licenseText = app.textViews["bound.software-licenses-text"]
            XCTAssertTrue(licenseText.waitForExistence(timeout: 10))
            let lastLicenseLine = licenseText.textViews["Delta uses OpenVGDB to provide automatic artwork for imported games."]
            assertSettingsContentVisible(lastLicenseLine, in: app, name: "\(label)-UIKit-Software-Licenses-bottom")
            assertSettingsCloseAtTop(in: app)
            app.buttons["bound.settings-close"].tap()
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
            app.buttons["Settings"].tap()
            let controlsLink = element("bound.settings-controls", in: app)
            XCTAssertTrue(controlsLink.waitForExistence(timeout: 5))
            assertSettingsContentVisible(controlsLink, in: app, name: "\(label)-Home-Controls")
            controlsLink.tap()
            XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 5))
            assertSettingsCloseAtTop(in: app, navigationTitle: "Controls")
            XCTAssertTrue(app.switches["bound.controller-mode-enabled"].exists)
            XCTAssertFalse(app.switches["bound.experimental-settings"].exists)
            let previews = app.switches["bound.context-menu-previews"]
            assertSettingsContentVisible(previews, in: app, name: "\(label)-Controls-Context-Menu-Previews")
            let pausePlacement = element("bound.pause-menu-button-placement", in: app)
            assertSettingsContentVisible(pausePlacement, in: app, name: "\(label)-Controls-Pause-Menu-Placement")
        }

        checkBottomScreens(orientation: orientation, label: orientation.isLandscape ? "Landscape" : "Portrait")
        app.buttons["bound.settings-close"].tap()
    }

    func testBossGuidePortraitSelectionPersistsWithPermanentAvailability() throws {
        let app = XCUIApplication()
        #if DEBUG
        app.launchArguments.append("--bound-ui-no-animations")
        #endif
        app.launch()
        func playAndCycle(to expected: String) {
            let cell = app.collectionViews.cells.firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 20))
            cell.tap()
            let cycle = app.buttons["bound.panel-cycle"]
            XCTAssertTrue(cycle.waitForExistence(timeout: 20))
            XCTAssertEqual(cycle.value as? String, "Friend")
            cycle.tap(); XCTAssertEqual(cycle.value as? String, "Notes")
            cycle.tap(); XCTAssertEqual(cycle.value as? String, "Types")
            cycle.tap(); XCTAssertEqual(cycle.value as? String, expected)
        }
        assertPermanentFeatureBaseline(in: app)
        playAndCycle(to: "Bosses")
        let guide = element("bound.boss-guide", in: app)
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        let species = app.staticTexts["bound.boss-pokemon"]
        // Exercise a known team without erasing a prior run's persisted choice.
        app.buttons["bound.boss-picker"].tap()
        let initialSearch = app.searchFields.firstMatch
        XCTAssertTrue(initialSearch.waitForExistence(timeout: 10))
        initialSearch.tap(); initialSearch.typeText("Brock")
        let brock = app.buttons["bound.boss-select-kanto-leaders-4"]
        XCTAssertTrue(brock.waitForExistence(timeout: 10)); brock.tap()
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        XCTAssertEqual(species.label, "Geodude-A")
        XCTAssertTrue(app.staticTexts["Bulldoze"].exists)
        XCTAssertTrue(app.staticTexts["Self-Destruct"].exists)
        XCTAssertEqual(app.staticTexts["bound.boss-cap"].label, "Cap 15")
        app.buttons["bound.boss-next"].tap()
        XCTAssertEqual(species.label, "Varoom")
        app.buttons["bound.boss-previous"].tap()
        XCTAssertEqual(species.label, "Geodude-A")
        screenshot("Boss-guide-portrait-Brock")

        app.buttons["bound.boss-picker"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Cerulean Misty")
        let misty = app.buttons["bound.boss-select-kanto-leaders-27"]
        XCTAssertTrue(misty.waitForExistence(timeout: 10)); misty.tap()
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        XCTAssertEqual(species.label, "Frogadier")
        app.buttons["bound.boss-next"].tap()
        XCTAssertEqual(species.label, "Floatzel")
        app.buttons["bound.boss-full-team"].tap()
        XCTAssertTrue(element("bound.boss-full-team-list", in: app).waitForExistence(timeout: 10))
        screenshot("Boss-guide-full-team-Misty")
        app.buttons["bound.boss-close-full-team"].tap()

        XCTAssertTrue(guide.exists)
        XCTAssertEqual(app.buttons["bound.panel-cycle"].value as? String, "Bosses")
        XCTAssertEqual(species.label, "Floatzel")
        app.buttons["bound.panel-cycle"].tap()
        XCTAssertEqual(app.buttons["bound.panel-cycle"].value as? String, "Dex")
        app.buttons["bound.panel-cycle"].tap()
        XCTAssertEqual(app.buttons["bound.panel-cycle"].value as? String, "Friend")
        app.buttons["bound.panel-cycle"].tap()
        app.buttons["bound.panel-cycle"].tap()
        app.buttons["bound.panel-cycle"].tap()
        XCTAssertEqual(app.buttons["bound.panel-cycle"].value as? String, "Bosses")
        XCTAssertEqual(species.label, "Floatzel")

        app.terminate(); XCUIDevice.shared.orientation = .portrait; app.launch()
        assertPermanentFeatureBaseline(in: app)
        playAndCycle(to: "Bosses")
        XCTAssertEqual(species.label, "Floatzel", "The selected boss team and member persist across relaunch")
        openBoundSettings(in: app)
        XCTAssertTrue(app.switches["bound.companion-enabled.bosses"].exists)
        closeBoundSheet(in: app)
    }

    func testBossFullTeamDismissalResumesGamePixels() throws {
        let app = XCUIApplication()
        app.launch()


        // Leave the shared simulator in the baseline app state after this test.
        defer {
            app.terminate()
            app.launch()
            assertPermanentFeatureBaseline(in: app)
        }

        assertPermanentFeatureBaseline(in: app)
        let cell = app.collectionViews.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        cell.tap()
        let cycle = app.buttons["bound.panel-cycle"]
        XCTAssertTrue(cycle.waitForExistence(timeout: 15))
        for expected in ["Notes", "Types", "Bosses"] {
            cycle.tap()
            XCTAssertEqual(cycle.value as? String, expected)
        }
        XCTAssertTrue(element("bound.boss-guide", in: app).waitForExistence(timeout: 10))
        let game = element("bound.game-screen", in: app)
        XCTAssertTrue(game.exists)
        assertGamePixelsAnimate(game, in: app)

        // The boss picker shares the same emulator pause/resume lifecycle.
        app.buttons["bound.boss-picker"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Brock")
        let brock = app.buttons["bound.boss-select-kanto-leaders-4"]
        XCTAssertTrue(brock.waitForExistence(timeout: 10)); brock.tap()
        XCTAssertTrue(element("bound.boss-guide", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(search.waitForNonExistence(timeout: 10), "Wait for the boss picker sheet to finish dismissing")
        assertGamePixelsAnimate(game, in: app)

        XCTAssertEqual(app.staticTexts["bound.boss-pokemon"].label, "Geodude-A")
        let picture = element("bound.boss-picture", in: app)
        XCTAssertTrue(picture.exists)
        XCTAssertTrue(picture.label.contains("Geodude-A"))
        let types = element("bound.boss-types", in: app)
        XCTAssertEqual(types.value as? String, "Rock, Electric")
        XCTAssertEqual(app.staticTexts["bound.boss-move-0"].label, "Bulldoze")
        XCTAssertEqual(element("bound.boss-move-type-0", in: app).label, "Ground")
        XCTAssertEqual(app.staticTexts["bound.boss-move-category-0"].label, "PhysA.")
        XCTAssertTrue(app.buttons["bound.boss-picker"].isHittable)
        screenshot("Boss-guide-portrait-reference-details")

        let details = element("bound.boss-details", in: app)
        XCTAssertTrue(details.exists)
        details.swipeUp()
        let abilityDescription = app.staticTexts["bound.boss-ability-description"]
        let itemDescription = app.staticTexts["bound.boss-item-description"]
        XCTAssertTrue(abilityDescription.waitForExistence(timeout: 10))
        XCTAssertTrue(itemDescription.waitForExistence(timeout: 10))
        XCTAssertTrue(abilityDescription.isHittable)
        XCTAssertTrue(itemDescription.isHittable)
        XCTAssertTrue(abilityDescription.label.contains("at full HP"))
        XCTAssertTrue(itemDescription.label.contains("move first just once in a pinch."))
        XCTAssertTrue(app.buttons["bound.boss-picker"].isHittable, "Boss selector stays pinned while details scroll")
        XCTAssertTrue(app.buttons["bound.boss-full-team"].isHittable, "Boss navigation footer stays pinned while details scroll")
        screenshot("Boss-guide-portrait-ability-item-details")

        for pass in 1...2 {
            app.buttons["bound.boss-full-team"].tap()
            XCTAssertTrue(element("bound.boss-full-team-list", in: app).waitForExistence(timeout: 10))
            app.buttons["bound.boss-close-full-team"].tap()
            XCTAssertTrue(element("bound.boss-guide", in: app).waitForExistence(timeout: 10))
            XCTAssertTrue(element("bound.boss-full-team-list", in: app).waitForNonExistence(timeout: 10), "Wait for Full team to finish dismissing")
            XCTAssertEqual(cycle.value as? String, "Bosses")
            assertGamePixelsAnimate(game, in: app)
            screenshot("Boss-full-team-dismissal-resumes-game-\(pass)")
        }

        app.buttons["bound.boss-full-team"].tap()
        let team = element("bound.boss-full-team-list", in: app)
        XCTAssertTrue(team.waitForExistence(timeout: 10))
        let navigationBar = app.navigationBars.firstMatch
        XCTAssertTrue(navigationBar.exists)
        let dragStart = navigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
        XCTAssertTrue(team.waitForNonExistence(timeout: 10), "A downward sheet swipe should dismiss Full team")
        XCTAssertTrue(element("bound.boss-guide", in: app).waitForExistence(timeout: 10))
        assertGamePixelsAnimate(game, in: app)
        screenshot("Boss-full-team-swipe-dismissal-resumes-game")
    }

    func testBossAndDexPresentationsDoNotMoveCompanionPanel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound", "--bound-ui-reset-layout"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
            app.launch()
            assertPermanentFeatureBaseline(in: app)
            app.terminate()
        }

        let gameCell = libraryGame(named: "BoundPickerDiagnostic", in: app)
        XCTAssertTrue(gameCell.waitForExistence(timeout: 20)); gameCell.tap()
        let cycle = app.buttons["bound.panel-cycle"]
        XCTAssertTrue(cycle.waitForExistence(timeout: 15))
        let game = element("bound.game-screen", in: app)
        let panel = element("bound.companion-container", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 10))

        func assertFrame(_ actual: CGRect, matches expected: CGRect, label: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 2, "\(label) x position", file: file, line: line)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 2, "\(label) y position", file: file, line: line)
            XCTAssertEqual(actual.width, expected.width, accuracy: 2, "\(label) width", file: file, line: line)
            XCTAssertEqual(actual.height, expected.height, accuracy: 2, "\(label) height", file: file, line: line)
        }

        func verifyPresentation(_ label: String, presented: XCUIElement, open: () -> Void, dismiss: () -> Void) {
            XCTAssertTrue(panel.waitForExistence(timeout: 5), "Companion container should exist before \(label)")
            let originalFrame = panel.frame
            open()
            XCTAssertTrue(presented.waitForExistence(timeout: 10), "\(label) should appear")
            XCTAssertTrue(panel.exists, "Companion container should remain measurable while \(label) is presented")
            assertFrame(panel.frame, matches: originalFrame, label: label + " presented")
            dismiss()
            XCTAssertTrue(presented.waitForNonExistence(timeout: 10), "\(label) should dismiss")
            waitForFrame(panel) { frame in
                abs(frame.minX - originalFrame.minX) < 2 && abs(frame.minY - originalFrame.minY) < 2
                    && abs(frame.width - originalFrame.width) < 2 && abs(frame.height - originalFrame.height) < 2
            }
            assertFrame(panel.frame, matches: originalFrame, label: label + " dismissed")
            XCTContext.runActivity(named: "Playback after " + label) { _ in
                assertGamePixelsAnimate(game, in: app)
            }
        }

        func runPortraitAndFloatingLandscapeCases() {
            selectCompanion("Bosses", in: app)
            verifyPresentation("Boss picker", presented: app.searchFields.firstMatch, open: {
                app.buttons["bound.boss-picker"].tap()
            }, dismiss: {
                app.buttons["Done"].firstMatch.tap()
            })
            verifyPresentation("Boss full team", presented: element("bound.boss-full-team-list", in: app), open: {
                app.buttons["bound.boss-full-team"].tap()
            }, dismiss: {
                app.buttons["bound.boss-close-full-team"].tap()
            })

            selectCompanion("Dex", in: app)
            verifyPresentation("Dex weaknesses", presented: element("bound.rrdex-matchups", in: app), open: {
                app.buttons["bound.rrdex-weaknesses"].tap()
            }, dismiss: {
                app.buttons["bound.rrdex-close-detail"].tap()
            })
            verifyPresentation("Dex learnset", presented: element("bound.rrdex-moves", in: app), open: {
                app.buttons["bound.rrdex-learnset"].tap()
            }, dismiss: {
                app.buttons["bound.rrdex-close-detail"].tap()
            })
            verifyPresentation("Current-save import error", presented: app.alerts["Save could not be imported"], open: {
                app.buttons["bound.rrdex-import"].tap()
            }, dismiss: {
                app.alerts["Save could not be imported"].buttons["OK"].tap()
            })
        }

        runPortraitAndFloatingLandscapeCases()
        assertGamePixelsAnimate(game, in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(game) { app.frame.width > app.frame.height && $0.width > $0.height }
        assertGamePixelsAnimate(game, in: app)
        runPortraitAndFloatingLandscapeCases()
        assertGamePixelsAnimate(game, in: app)
    }

    func testRRDexWeaknessesDismissalResumesGamePixels() throws {
        let app = XCUIApplication()
        defer {
            app.terminate()
            app.launch()
            assertPermanentFeatureBaseline(in: app)
        }
        openRRDexPlayback(in: app)
        let game = element("bound.game-screen", in: app)
        assertGamePixelsAnimate(game, in: app)

        let search = app.textFields["bound.rrdex-search"]
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10), "Done should dismiss the search keyboard")
        assertGamePixelsAnimate(game, in: app)

        search.tap(); search.typeText("char")
        XCTAssertEqual(search.value as? String, "char")
        let charizard = app.buttons["bound.rrdex-suggestion-6"]
        XCTAssertTrue(charizard.waitForExistence(timeout: 10)); charizard.tap()
        XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Charizard")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10), "Suggestion selection should dismiss the search keyboard")
        assertGamePixelsAnimate(game, in: app)

        search.tap(); search.typeText("bu")
        app.buttons["bound.rrdex-clear-search"].tap()

        app.buttons["bound.rrdex-weaknesses"].tap()
        let matchups = element("bound.rrdex-matchups", in: app)
        XCTAssertTrue(matchups.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["4×"].exists)
        app.buttons["bound.rrdex-close-detail"].tap()
        XCTAssertTrue(matchups.waitForNonExistence(timeout: 10), "Wait for the weaknesses sheet to finish dismissing")
        XCTAssertTrue(element("bound.rrdex", in: app).waitForExistence(timeout: 10))
        assertGamePixelsAnimate(game, in: app)
        screenshot("RRDex-weaknesses-dismissal-resumes-game")

        app.buttons["bound.rrdex-weaknesses"].tap()
        XCTAssertTrue(matchups.waitForExistence(timeout: 10))
        swipeDownDetail(named: "Type matchups", in: app)
        XCTAssertTrue(matchups.waitForNonExistence(timeout: 10), "A downward swipe should dismiss the weaknesses sheet")
        assertGamePixelsAnimate(game, in: app)

        app.buttons["bound.rrdex-learnset"].tap()
        let moves = element("bound.rrdex-moves", in: app)
        XCTAssertTrue(moves.waitForExistence(timeout: 10))
        app.buttons["bound.rrdex-close-detail"].tap()
        XCTAssertTrue(moves.waitForNonExistence(timeout: 10), "Wait for the learnset sheet to finish dismissing")
        assertGamePixelsAnimate(game, in: app)

        app.buttons["bound.rrdex-learnset"].tap()
        XCTAssertTrue(moves.waitForExistence(timeout: 10))
        swipeDownDetail(named: "Learnset", in: app)
        XCTAssertTrue(moves.waitForNonExistence(timeout: 10), "A downward swipe should dismiss the learnset sheet")
        assertGamePixelsAnimate(game, in: app)

    }

    func testRRDexCurrentSaveImportErrorResumesGamePixels() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        defer {
            app.terminate()
            app.launch()
            assertPermanentFeatureBaseline(in: app)
        }

        let gameCell = libraryGame(named: "BoundPickerDiagnostic", in: app)
        XCTAssertTrue(gameCell.waitForExistence(timeout: 20)); gameCell.tap()
        selectCompanion("Dex", in: app)
        XCTAssertTrue(element("bound.rrdex", in: app).waitForExistence(timeout: 10))
        let game = element("bound.game-screen", in: app)
        assertGamePixelsAnimate(game, in: app)

        let importButton = app.buttons["bound.rrdex-import"]
        let previousImportLabel = importButton.label
        let search = app.textFields["bound.rrdex-search"]
        search.tap(); search.typeText("char")
        XCTAssertTrue(app.buttons["bound.rrdex-suggestion-6"].waitForExistence(timeout: 10))
        app.buttons["bound.rrdex-suggestion-6"].tap()
        XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Charizard")
        search.tap(); search.typeText("bulb")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        importButton.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10), "Import should dismiss search before exporting the current game save")
        let errorAlert = app.alerts["Save could not be imported"]
        XCTAssertTrue(errorAlert.waitForExistence(timeout: 10), "The original diagnostic ROM does not contain a valid Radical Red save")
        XCTAssertFalse(app.buttons["Cancel"].exists, "Current-save import must not open the Files picker")
        XCTAssertFalse(app.collectionViews["File View"].exists, "Current-save import must not open the Files browser")
        errorAlert.buttons["OK"].tap()
        XCTAssertTrue(errorAlert.waitForNonExistence(timeout: 10), "Wait for the current-save error to finish dismissing")
        let clearSearch = app.buttons["bound.rrdex-clear-search"]
        if clearSearch.exists { clearSearch.tap() }
        XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Charizard", "A failed import must preserve the current dex selection")
        XCTAssertEqual(importButton.label, previousImportLabel, "A failed import must preserve the previously loaded save configuration")
        assertGamePixelsAnimate(game, in: app)
    }

    func testRRDexSearchDetailsSaveImportPersistenceAndPermanentAvailability() throws {
        let app = XCUIApplication()
        app.launch()
        func play() {
            let cell = libraryGame(named: "BoundRRDexDiagnostic", in: app)
            XCTAssertTrue(cell.waitForExistence(timeout: 20)); cell.tap()
            XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 20))
        }
        func assertImportedAbilities() {
            let abilities = element("bound.rrdex-abilities", in: app)
            let value = abilities.value as? String ?? ""
            XCTAssertTrue(value.contains("Limber"))
            XCTAssertTrue(value.contains("Friend Guard"))
        }
        assertPermanentFeatureBaseline(in: app); play(); selectCompanion("Dex", in: app)
        XCTAssertTrue(element("bound.rrdex", in: app).waitForExistence(timeout: 10))
        let game = element("bound.game-screen", in: app)
        let search = app.textFields["bound.rrdex-search"]
        search.tap(); search.typeText("bu")
        XCTAssertEqual(search.value as? String, "bu")
        XCTAssertTrue(app.buttons["bound.rrdex-suggestion-1"].waitForExistence(timeout: 10))
        search.typeText("lb")
        XCTAssertEqual(search.value as? String, "bulb")
        app.buttons["bound.rrdex-suggestion-1"].tap()
        XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Bulbasaur")
        XCTAssertTrue(element("bound.rrdex-picture", in: app).exists)
        XCTAssertTrue(element("bound.rrdex-stats", in: app).exists)
        let level = app.staticTexts["Level 16"]
        XCTAssertTrue(level.exists)
        screenshot("RRDex-portrait-Bulbasaur")
        search.tap(); search.typeText("char")
        XCTAssertEqual(search.value as? String, "char")
        let charizard = app.buttons["bound.rrdex-suggestion-6"]
        XCTAssertTrue(charizard.waitForExistence(timeout: 10)); charizard.tap()
        XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Charizard")
        app.buttons["bound.rrdex-weaknesses"].tap()
        XCTAssertTrue(element("bound.rrdex-matchups", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["4×"].exists)
        screenshot("RRDex-Charizard-matchups")
        app.buttons["bound.rrdex-close-detail"].tap()
        app.buttons["bound.rrdex-learnset"].tap()
        XCTAssertTrue(element("bound.rrdex-moves", in: app).waitForExistence(timeout: 10))
        let moveSearch = app.searchFields.firstMatch
        XCTAssertTrue(moveSearch.waitForExistence(timeout: 10)); moveSearch.tap(); moveSearch.typeText("flamethrower")
        XCTAssertTrue(app.staticTexts["Flamethrower"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(moveSearch.value as? String, "flamethrower")
        screenshot("RRDex-Charizard-learnset")
        // iOS hides the navigation toolbar during an active native search.
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["bound.rrdex-close-detail"].waitForExistence(timeout: 5))
        app.buttons["bound.rrdex-close-detail"].tap()
        // This dedicated fixture starts with a synthetic valid Radical Red battery save.
        // Import should export the current native game save directly, without Files.
        let importButton = app.buttons["bound.rrdex-import"]
        importButton.tap()
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        XCTAssertTrue(importButton.label.contains("Save loaded"))
        XCTAssertFalse(app.buttons["Cancel"].exists, "Importing the current save must not open the Files picker")
        XCTAssertFalse(app.collectionViews["File View"].exists, "Importing the current save must not open the Files browser")
        assertGamePixelsAnimate(game, in: app)
        search.tap(); search.typeText("bulbasaur")
        app.buttons["bound.rrdex-suggestion-1"].tap()
        assertImportedAbilities()
        screenshot("RRDex-imported-randomizer")
        // Re-import refreshes the current native save and keeps the randomizer settings.
        importButton.tap()
        XCTAssertTrue(importButton.label.contains("Save loaded"))
        assertGamePixelsAnimate(game, in: app)
        search.tap(); search.typeText("bulbasaur")
        app.buttons["bound.rrdex-suggestion-1"].tap()
        assertImportedAbilities()
        search.tap(); search.typeText("charizard")
        app.buttons["bound.rrdex-suggestion-6"].tap()
        XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Charizard")
        app.buttons["bound.panel-cycle"].tap()
        XCTAssertEqual(app.buttons["bound.panel-cycle"].value as? String, "Friend")
        selectCompanion("Dex", in: app)
        XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Charizard")
        XCTAssertTrue(app.buttons["bound.rrdex-import"].label.contains("Save loaded"))
        app.terminate(); XCUIDevice.shared.orientation = .portrait; app.launch(); play()
        selectCompanion("Dex", in: app)
        XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Charizard")
        XCTAssertTrue(app.buttons["bound.rrdex-import"].label.contains("Save loaded"))
        search.tap(); search.typeText("bulbasaur")
        app.buttons["bound.rrdex-suggestion-1"].tap()
        assertImportedAbilities()
        app.terminate(); app.launch(); assertPermanentFeatureBaseline(in: app); play()
        for name in ["Notes", "Types", "Bosses", "Dex", "Friend"] {
            app.buttons["bound.panel-cycle"].tap()
            XCTAssertEqual(app.buttons["bound.panel-cycle"].value as? String, name)
            XCTAssertEqual(element("bound.rrdex", in: app).exists, name == "Dex")
        }
        openBoundSettings(in: app)
        XCTAssertTrue(app.switches["bound.companion-enabled.dex"].exists)
        closeBoundSheet(in: app)
    }

    func testRRDexLandscapeWhenRuntimeSupportsRotation() throws {
        let app = XCUIApplication()
        app.launch(); assertPermanentFeatureBaseline(in: app)
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate(); app.launch(); assertPermanentFeatureBaseline(in: app)
        }
        let cell = app.collectionViews.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20)); cell.tap()
        selectCompanion("Dex", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        guard XCTWaiter.wait(for: [rotated], timeout: 8) == .completed else {
            throw XCTSkip("Runtime kept its display in portrait after the orientation request; landscape panel rendering is covered by hosted tests.")
        }
        XCTAssertTrue(element("bound.rrdex", in: app).exists)
        XCTAssertTrue(app.buttons["bound.rrdex-weaknesses"].isHittable)
        XCTAssertTrue(app.buttons["bound.rrdex-learnset"].isHittable)
        screenshot("RRDex-landscape")
        app.buttons["bound.panel-cycle"].tap()
        XCTAssertEqual(app.buttons["bound.panel-cycle"].value as? String, "Friend")
    }

    func testBossPickerUsesTrainerIconsAndCollapsibleVariants() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        defer {
            app.terminate(); app.launch()
            assertPermanentFeatureBaseline(in: app)
            app.terminate()
        }
        let cell = app.collectionViews.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20)); cell.tap()
        selectCompanion("Bosses", in: app)
        app.buttons["bound.boss-picker"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        func find(_ text: String) {
            search.tap()
            if let value = search.value as? String, value != search.placeholderValue {
                search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            }
            search.typeText(text)
        }
        func toggleOptions(_ id: String) {
            let group = element("bound.boss-options-\(id)", in: app)
            XCTAssertTrue(group.waitForExistence(timeout: 5))
            group.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 32)).tap()
        }
        find("Brock")
        XCTAssertTrue(app.buttons["bound.boss-select-kanto-leaders-4"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("bound.boss-trainer-icon-kanto-leaders-4", in: app).exists)
        screenshot("Choose-boss-black-background-white-text-trainer-icons")

        find("Lorelei")
        let rain = app.buttons["bound.boss-select-indigo-league-8"]
        let snow = app.buttons["bound.boss-select-indigo-league-35"]
        XCTAssertTrue(rain.waitForExistence(timeout: 5))
        XCTAssertTrue(snow.exists)
        toggleOptions("indigo-league-8")
        XCTAssertTrue(rain.waitForNonExistence(timeout: 5))
        XCTAssertFalse(snow.exists)
        toggleOptions("indigo-league-8")
        XCTAssertTrue(rain.waitForExistence(timeout: 5))
        XCTAssertTrue(snow.exists)
        screenshot("Choose-boss-collapsible-weather-teams")

        find("Rival Route 22")
        let starterOptions = ["rivals-6", "rivals-30", "rivals-54"]
        for id in starterOptions { XCTAssertTrue(app.buttons["bound.boss-select-\(id)"].waitForExistence(timeout: 5)) }
        XCTAssertTrue(app.staticTexts["If Rival Has Squirtle"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["If Rival Has Charmander"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["If Rival Has Bulbasaur"].firstMatch.exists)
        screenshot("Choose-boss-collapsible-starter-choices")
        app.buttons["bound.boss-select-rivals-30"].tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 10))
        XCTAssertTrue(element("bound.boss-guide", in: app).exists)
        assertGamePixelsAnimate(element("bound.game-screen", in: app), in: app)
        app.buttons["bound.boss-picker"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["bound.boss-select-rivals-30"].waitForExistence(timeout: 5),
                      "The selected encounter should open with its variants available")
        app.buttons["Done"].firstMatch.tap()
    }

    func testCompanionViewSwitchesPersistAndFilterCycle() throws {
        throw XCTSkip("This test only covers removed Interface view-selection controls.")
        // Native pause-menu animation idle notifications can be lost on Xcode 27.
        // Observe the real controls and transitions explicitly throughout this test.
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originalImplementations: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originalImplementations.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            for (method, original) in originalImplementations {
                imp_removeBlock(method_setImplementation(method, original))
            }
        }
        let app = XCUIApplication()
        let arguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launchArguments = arguments + ["--bound-ui-reset-layout"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        func openFirstGame() {
            let cell = app.collectionViews.cells.firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 20)); cell.tap()
            XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        }
        defer {
            app.terminate()
            app.launchArguments = arguments + ["--bound-ui-reset-layout"]
            app.launch()
            assertPermanentFeatureBaseline(in: app)
            openFirstGame() // Reset only the dedicated QA simulator's test preferences.
            app.terminate()
        }
        openFirstGame()
        app.launchArguments = arguments // Relaunch must retain the saved view switches.
        let contents = ["friend", "notes", "types", "bosses", "dex"]
        func toggle(_ content: String) -> XCUIElement { app.switches["bound.companion-enabled.\(content)"] }
        func setView(_ content: String, enabled: Bool) {
            let control = toggle(content)
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            if (control.value as? String == "1") != enabled {
                control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            XCTAssertEqual(control.value as? String, enabled ? "1" : "0")
        }
        openBoundSettings(in: app)
        for content in contents {
            XCTAssertTrue(toggle(content).waitForExistence(timeout: 5))
            XCTAssertEqual(toggle(content).value as? String, "1", "Every view starts enabled")
        }
        for content in ["notes", "types", "dex"] { setView(content, enabled: false) }
        screenshot("Companion-views-Friend-and-Bosses-enabled")
        closeBoundSheet(in: app)
        let cycle = app.buttons["bound.panel-cycle"]
        for expected in ["Bosses", "Friend", "Bosses", "Friend"] {
            cycle.tap(); XCTAssertEqual(cycle.value as? String, expected)
        }

        app.terminate(); app.launch(); openFirstGame()
        openBoundSettings(in: app)
        for content in contents {
            XCTAssertEqual(toggle(content).value as? String, ["friend", "bosses"].contains(content) ? "1" : "0")
        }
        setView("friend", enabled: false)
        closeBoundSheet(in: app)
        XCTAssertEqual(cycle.value as? String, "Bosses", "Disabling the visible view selects an enabled view")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForFrame(element("bound.game-screen", in: app)) { app.frame.width > app.frame.height && $0.width > $0.height }
        cycle.tap(); XCTAssertEqual(cycle.value as? String, "Bosses")
        XCUIDevice.shared.orientation = .portrait
        waitForFrame(element("bound.game-screen", in: app)) { app.frame.height > app.frame.width && $0.width > $0.height }

        openBoundSettings(in: app)
        setView("bosses", enabled: false)
        closeBoundSheet(in: app)
        XCTAssertEqual(cycle.value as? String, "No views enabled")
        for identifier in ["bound.friend-screen", "bound.boss-guide", "bound.rrdex", "bound.type-chart", "bound.notes-editor", "bound.notes-preview"] {
            XCTAssertFalse(element(identifier, in: app).exists, "Disabled views must leave the view hierarchy")
        }
        cycle.tap(); XCTAssertEqual(cycle.value as? String, "No views enabled")
        assertGamePixelsAnimate(element("bound.game-screen", in: app), in: app)
        openBoundSettings(in: app)
        setView("friend", enabled: true)
        setView("bosses", enabled: true)
        closeBoundSheet(in: app)
        XCTAssertEqual(cycle.value as? String, "Friend")

        app.terminate(); app.launch()
        assertPermanentFeatureBaseline(in: app)
        openFirstGame()
        for expected in ["Notes", "Types", "Friend"] {
            cycle.tap(); XCTAssertEqual(cycle.value as? String, expected)
        }
        openBoundSettings(in: app)
        for content in contents {
            XCTAssertTrue(toggle(content).exists, "Availability controls remain present after relaunch")
            XCTAssertEqual(toggle(content).value as? String, ["friend", "bosses"].contains(content) ? "1" : "0")
        }
        for content in contents { setView(content, enabled: true) }
        closeBoundSheet(in: app)
    }

    func testEnhancedReferenceLayoutsKeepActionsUsableAndGameGeometryStable() throws {
        try checkReferenceLayouts([2, 3])
    }

    func testLayout4KeepsReferenceActionsUsableAndGameGeometryStable() throws {
        try checkReferenceLayouts([4])
    }

    func testLayout5KeepsReferenceDetailsVisibleAndActionsUsable() throws {
        try checkReferenceLayouts([5])
    }

    func testLayout6KeepsMovesStatsAndEvolutionWithinReach() throws {
        try checkReferenceLayouts([6])
    }

    func testLayout7ShowsConditionalSpeedAndTappableTeamStrip() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }

        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        func playDiagnosticGame() {
            let cell = libraryGame(named: "BoundRRDexDiagnostic", in: app)
            XCTAssertTrue(cell.waitForExistence(timeout: 20)); cell.tap()
            XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        }
        defer {
            app.terminate(); XCUIDevice.shared.orientation = .portrait
            app.launch(); assertPermanentFeatureBaseline(in: app); playDiagnosticGame(); app.terminate()
        }
        playDiagnosticGame()
        openBoundSettings(in: app)
        let layout = app.segmentedControls["bound.boss-layout"]
        scrollToSetting(layout, in: app)
        layout.buttons["7"].tap()
        closeBoundSheet(in: app)
        selectCompanion("Bosses", in: app)

        func chooseBoss(_ id: String, search: String) {
            app.buttons["bound.boss-picker"].tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(search)
            let row = app.buttons["bound.boss-select-\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        }
        let guide = element("bound.boss-guide", in: app)
        XCTAssertEqual(guide.value as? String, "Layout 7")
        chooseBoss("johto-leaders-4", search: "Falkner")
        XCTAssertTrue(app.buttons["bound.boss-picker"].label.contains("Falkner"))
        XCTAssertEqual(app.staticTexts["bound.boss-cap"].label, "Cap 15")

        let firstIcon = app.buttons["bound.boss-team-member-0"]
        let flittleIcon = app.buttons["bound.boss-team-member-2"]
        XCTAssertTrue(firstIcon.isHittable); XCTAssertTrue(flittleIcon.isHittable)
        let pokemonName = app.staticTexts["bound.boss-pokemon"]
        let pokemonLevel = app.staticTexts["bound.boss-pokemon-level"]
        XCTAssertEqual(pokemonName.label, "Rufflet")
        XCTAssertEqual(pokemonLevel.label, "Lv. 12")
        XCTAssertLessThan(firstIcon.frame.midY, guide.frame.midY, "Team sprites should sit in the selected Pokémon row near the top of the card.")

        flittleIcon.tap()
        XCTAssertEqual(pokemonName.label, "Flittle")
        XCTAssertEqual(pokemonLevel.label, "Lv. 14")
        let baseSpeed = element("bound.boss-speed-0", in: app)
        let boostedSpeed = element("bound.boss-speed-1", in: app)
        XCTAssertTrue(baseSpeed.waitForExistence(timeout: 5))
        XCTAssertEqual(baseSpeed.label, "SPEED STAT:")
        XCTAssertEqual(baseSpeed.value as? String, "30")
        XCTAssertEqual(boostedSpeed.label, "1 S. BOOST:")
        XCTAssertEqual(boostedSpeed.value as? String, "45")
        let speed = element("bound.boss-speed", in: app)
        let stats = element("bound.boss-stats", in: app)
        XCTAssertGreaterThanOrEqual(speed.frame.minY, stats.frame.minY)
        screenshot("Boss-Layout7-Flittle-Speed")
        XCTAssertFalse(app.buttons["bound.boss-next"].exists, "Layout 7 navigates through the team strip, without bottom arrows.")
        XCTAssertFalse(app.buttons["bound.boss-previous"].exists, "Layout 7 navigates through the team strip, without bottom arrows.")
        XCTAssertFalse(element("bound.boss-page", in: app).exists, "Layout 7 omits the page counter.")

        let fullTeam = app.buttons["bound.boss-full-team"]
        XCTAssertTrue(fullTeam.isHittable)
        XCTAssertLessThan(fullTeam.frame.midY, 70, "Full team should stay beside the Dynamic Island at the top of the screen.")
        XCTAssertGreaterThan(fullTeam.frame.midX, app.frame.midX, "Full team should sit to the right of the Dynamic Island.")
        fullTeam.tap()
        let fullTeamSheet = element("bound.boss-full-team-list", in: app)
        XCTAssertTrue(fullTeamSheet.waitForExistence(timeout: 5))
        app.buttons["bound.boss-close-full-team"].tap()
        XCTAssertTrue(fullTeamSheet.waitForNonExistence(timeout: 5))
        assertGamePixelsAnimate(element("bound.game-screen", in: app), in: app)

        chooseBoss("johto-leaders-31", search: "Bugsy Pre Lt. Surge")
        XCTAssertEqual(app.staticTexts["bound.boss-cap"].label, "Cap 27")
        XCTAssertEqual(pokemonLevel.label, "Highest Lv -2")
        let preSurgeContext = element("bound.boss-speed-context", in: app)
        let preSurgeContextLabel = preSurgeContext.label
        XCTAssertEqual(preSurgeContextLabel, "IF YOU'RE LEVEL 27")
        chooseBoss("johto-leaders-56", search: "Bugsy Post Lt. Surge")
        XCTAssertFalse(app.staticTexts["bound.boss-cap"].exists)
        XCTAssertEqual(pokemonLevel.label, "Highest Lv -2")
        let postSurgeContext = element("bound.boss-speed-context", in: app)
        XCTAssertEqual(postSurgeContext.label, "IF YOU'RE LEVEL 44")
        XCTAssertNotEqual(preSurgeContextLabel, postSurgeContext.label,
                          "Speed examples should explain the current team's conditional level context.")
        let bugsyTeamIcons = (0..<6).map { app.buttons["bound.boss-team-member-\($0)"] }
        bugsyTeamIcons.forEach { XCTAssertTrue($0.isHittable, "All six members should be reachable from the team strip.") }
        screenshot("Boss-Layout7-Bugsy-Six-Member-Team")
        bugsyTeamIcons[5].tap()
        XCTAssertEqual(pokemonName.label, "Vikavolt")
        XCTAssertEqual(pokemonLevel.label, "Highest Lv -2")
    }

    func testLayout8IslandControlsBossNatureAndDexInformation() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }

        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        func playDiagnosticGame() {
            let cell = libraryGame(named: "BoundRRDexDiagnostic", in: app)
            XCTAssertTrue(cell.waitForExistence(timeout: 20)); cell.tap()
            XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        }
        defer {
            app.terminate(); XCUIDevice.shared.orientation = .portrait
            app.launch(); assertPermanentFeatureBaseline(in: app); playDiagnosticGame(); app.terminate()
        }
        playDiagnosticGame()
        openBoundSettings(in: app)
        let bossLayout = app.segmentedControls["bound.boss-layout"]
        scrollToSetting(bossLayout, in: app); bossLayout.buttons["8"].tap()
        let dexLayout = app.segmentedControls["bound.rrdex-layout"]
        scrollToSetting(dexLayout, in: app); dexLayout.buttons["8"].tap()
        var originalEnabledStates: [String: Bool] = [:]
        for content in ["bosses", "dex"] {
            let toggle = app.switches["bound.companion-enabled.\(content)"]
            scrollToSetting(toggle, in: app)
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            originalEnabledStates[content] = toggle.value as? String == "1"
            if toggle.value as? String != "1" {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        closeBoundSheet(in: app)

        selectCompanion("Bosses", in: app)
        func chooseBoss(_ id: String, search: String) {
            app.buttons["bound.boss-picker"].tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(search)
            let row = app.buttons["bound.boss-select-\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        }
        chooseBoss("johto-leaders-4", search: "Falkner")
        let bossPicker = app.buttons["bound.boss-picker"]
        let fullTeam = app.buttons["bound.boss-full-team"]
        XCTAssertTrue(bossPicker.isHittable); XCTAssertTrue(fullTeam.isHittable)
        XCTAssertLessThan(bossPicker.frame.midY, 70)
        XCTAssertLessThan(fullTeam.frame.midY, 70)
        XCTAssertLessThan(bossPicker.frame.midX, app.frame.midX)
        XCTAssertGreaterThan(fullTeam.frame.midX, app.frame.midX)
        XCTAssertGreaterThanOrEqual(fullTeam.frame.minX - bossPicker.frame.maxX, 160,
                                    "Keep the Dynamic Island clear between the two 44-point actions.")
        XCTAssertGreaterThanOrEqual(bossPicker.frame.height, 44)
        XCTAssertGreaterThanOrEqual(fullTeam.frame.height, 44)
        let cap = element("bound.boss-cap", in: app)
        let speedRow = element("bound.boss-speed-row", in: app)
        XCTAssertEqual(cap.label, "Cap 15")
        XCTAssertTrue(speedRow.frame.insetBy(dx: 0, dy: -2).intersects(cap.frame),
                      "The level cap should sit with the speed examples, not in the removed header.")
        app.buttons["bound.boss-team-member-2"].tap()
        XCTAssertEqual(app.staticTexts["bound.boss-pokemon"].label, "Flittle",
                       "Layout 8 keeps the team strip interactive beside the selected Pokémon.")
        app.buttons["bound.boss-team-member-0"].tap()
        let nature = app.staticTexts["bound.boss-nature"]
        XCTAssertTrue(nature.waitForExistence(timeout: 5))
        XCTAssertEqual(nature.label, "Nature · Jolly")
        let details = element("bound.boss-details", in: app)
        for _ in 0..<3 where !nature.isHittable { details.swipeUp() }
        let moves = element("bound.boss-move-0", in: app)
        let ability = element("bound.boss-ability-description", in: app)
        XCTAssertLessThan(moves.frame.midY, nature.frame.midY)
        XCTAssertLessThan(nature.frame.midY, ability.frame.midY,
                          "Nature should appear after moves and before the ability description.")
        screenshot("Boss-Layout8-Nature-and-Speed-Cap")

        fullTeam.tap()
        let fullTeamSheet = element("bound.boss-full-team-list", in: app)
        XCTAssertTrue(fullTeamSheet.waitForExistence(timeout: 5))
        app.buttons["bound.boss-close-full-team"].tap()
        XCTAssertTrue(fullTeamSheet.waitForNonExistence(timeout: 5))
        assertGamePixelsAnimate(element("bound.game-screen", in: app), in: app)

        selectCompanion("Dex", in: app)
        let search = app.buttons["bound.rrdex-search-open"]
        XCTAssertFalse(app.buttons["bound.rrdex-info"].exists)
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(app.staticTexts["bound.rrdex-reference-rom"].exists)
        XCTAssertTrue(app.staticTexts["bound.rrdex-reference-difficulty"].exists)
        XCTAssertLessThan(search.frame.midY, 70)
        XCTAssertEqual(search.frame.midX, app.frame.midX + 102, accuracy: 4)
        XCTAssertGreaterThanOrEqual(search.frame.width, 44); XCTAssertGreaterThanOrEqual(search.frame.height, 44)
        search.tap()
        XCTAssertTrue(app.textFields["bound.rrdex-search"].waitForExistence(timeout: 5))
        search.tap()

        let dexDetails = app.scrollViews["bound.rrdex-layout8-details"]
        for _ in 0..<3 where !app.buttons["bound.rrdex-layout8-weaknesses"].isHittable { dexDetails.swipeUp() }
        let evolutionTitle = app.staticTexts["EVOLUTION"].firstMatch
        let bst = element("bound.rrdex-layout8-bst", in: app)
        let learnset = app.buttons["bound.rrdex-layout8-learnset"]
        let weaknesses = app.buttons["bound.rrdex-layout8-weaknesses"]
        XCTAssertTrue(evolutionTitle.exists); XCTAssertTrue(bst.exists)
        XCTAssertTrue(learnset.isHittable); XCTAssertTrue(weaknesses.isHittable)
        XCTAssertGreaterThan(learnset.frame.midX, evolutionTitle.frame.midX,
                             "Learnset and weaknesses should sit to the right of the evolution chain.")
        XCTAssertLessThan(bst.frame.midY, learnset.frame.midY)
        XCTAssertLessThan(learnset.frame.midY, weaknesses.frame.midY)
        XCTAssertGreaterThanOrEqual(learnset.frame.height, 44)
        XCTAssertGreaterThanOrEqual(weaknesses.frame.height, 44)
        XCTAssertEqual(bst.frame.maxX, learnset.frame.maxX, accuracy: 3,
                       "BST and both actions should share the right-hand column.")
        screenshot("RRDex-Layout8-Evolution-BST-Actions")
        weaknesses.tap()
        XCTAssertTrue(element("bound.rrdex-matchups", in: app).waitForExistence(timeout: 10))
        app.buttons["bound.rrdex-close-detail"].tap()
        learnset.tap()
        XCTAssertTrue(element("bound.rrdex-moves", in: app).waitForExistence(timeout: 10))
        app.buttons["bound.rrdex-close-detail"].tap()
        assertGamePixelsAnimate(element("bound.game-screen", in: app), in: app)
        openBoundSettings(in: app)
        for (content, wasEnabled) in originalEnabledStates {
            let toggle = app.switches["bound.companion-enabled.\(content)"]
            scrollToSetting(toggle, in: app)
            if (toggle.value as? String == "1") != wasEnabled {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        closeBoundSheet(in: app)
    }

    func testLayout10InlineMatchupsAndNatureEffects() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }

        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 20)); game.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))

        openBoundSettings(in: app)
        let bossLayout = app.segmentedControls["bound.boss-layout"]
        scrollToSetting(bossLayout, in: app); bossLayout.buttons["10"].tap()
        let dexLayout = app.segmentedControls["bound.rrdex-layout"]
        scrollToSetting(dexLayout, in: app); dexLayout.buttons["10"].tap()
        var originalEnabledStates: [String: Bool] = [:]
        for content in ["bosses", "dex"] {
            let toggle = app.switches["bound.companion-enabled.\(content)"]
            scrollToSetting(toggle, in: app)
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            originalEnabledStates[content] = toggle.value as? String == "1"
            if toggle.value as? String != "1" {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        closeBoundSheet(in: app)
        defer {
            app.terminate(); app.launch()
            assertPermanentFeatureBaseline(in: app)
            app.terminate()
        }

        selectCompanion("Bosses", in: app)
        XCTAssertEqual(element("bound.boss-guide", in: app).value as? String, "Layout 10")
        XCTAssertFalse(app.buttons["bound.boss-full-team"].exists)
        app.buttons["bound.boss-picker"].tap()
        let bossSearch = app.searchFields.firstMatch
        XCTAssertTrue(bossSearch.waitForExistence(timeout: 5)); bossSearch.tap(); bossSearch.typeText("Falkner")
        let falkner = app.buttons["bound.boss-select-johto-leaders-4"]
        XCTAssertTrue(falkner.waitForExistence(timeout: 5)); falkner.tap()
        XCTAssertTrue(bossSearch.waitForNonExistence(timeout: 5))
        let bossNature = element("bound.boss-nature", in: app)
        XCTAssertTrue(bossNature.waitForExistence(timeout: 5))
        XCTAssertEqual(bossNature.label, "Nature · Jolly · +10% Speed, −10% Sp. Atk")
        let bossMatchups = element("bound.boss-layout10-matchups", in: app)
        XCTAssertTrue(bossMatchups.waitForExistence(timeout: 5))
        let bossAbility = element("bound.boss-ability-description", in: app)
        let bossItem = element("bound.boss-item-description", in: app)
        XCTAssertTrue(bossAbility.exists); XCTAssertTrue(bossItem.exists)
        XCTAssertLessThan(bossAbility.frame.minY, bossItem.frame.minY)
        XCTAssertLessThan(bossItem.frame.minY, bossMatchups.frame.minY,
                          "Boss matchups follow the selected Pokémon's Ability and Item.")
        XCTAssertFalse(app.staticTexts["Neutral:"].exists, "Neutral matchups are implicit and are not listed.")
        let bossDetails = app.scrollViews["bound.boss-details"]
        for _ in 0..<10 where !bossMatchups.isHittable || !bossDetails.frame.contains(bossMatchups.frame) {
            let below = bossMatchups.frame.midY > bossDetails.frame.midY
            bossDetails.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.8 : 0.4))
                .press(forDuration: 0.1, thenDragTo: bossDetails.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.4 : 0.8)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 0.5)
        }
        screenshot("Boss-Layout10-Matchups")

        selectCompanion("Dex", in: app)
        XCTAssertEqual(element("bound.rrdex", in: app).value as? String, "Layout 10")
        app.buttons["bound.rrdex-search-open"].tap()
        let speciesSearch = app.textFields["bound.rrdex-search"]
        XCTAssertTrue(speciesSearch.waitForExistence(timeout: 5)); speciesSearch.tap(); speciesSearch.typeText("bulbasaur")
        let bulbasaur = app.buttons["bound.rrdex-suggestion-1"]
        XCTAssertTrue(bulbasaur.waitForExistence(timeout: 5)); bulbasaur.tap()
        let details = app.scrollViews["bound.rrdex-layout10-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["bound.rrdex-layout10-weaknesses"].exists)
        let matchups = element("bound.rrdex-layout10-matchups", in: app)
        XCTAssertTrue(matchups.waitForExistence(timeout: 5))
        let weaknesses = element("bound.rrdex-layout10-matchups-weaknesses", in: app)
        let resistances = element("bound.rrdex-layout10-matchups-resistances", in: app)
        let immunities = element("bound.rrdex-layout10-matchups-immunities", in: app)
        for _ in 0..<10 where !weaknesses.isHittable || !details.frame.contains(weaknesses.frame) {
            let below = weaknesses.frame.midY > details.frame.midY
            details.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.8 : 0.4))
                .press(forDuration: 0.1, thenDragTo: details.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.4 : 0.8)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(weaknesses.isHittable); XCTAssertTrue(resistances.exists)
        XCTAssertTrue(app.staticTexts["Weaknesses:"].exists)
        XCTAssertTrue(app.staticTexts["Resistances:"].exists)
        XCTAssertTrue(element("bound.rrdex-layout10-matchups-weaknesses-type-10", in: app).label.contains("Fire"))
        XCTAssertTrue(element("bound.rrdex-layout10-matchups-weaknesses-type-14", in: app).label.contains("Psychic"))
        XCTAssertTrue(element("bound.rrdex-layout10-matchups-resistances-type-1", in: app).label.contains("Fighting"))
        XCTAssertTrue(element("bound.rrdex-layout10-matchups-resistances-type-23", in: app).label.contains("Fairy"))
        XCTAssertFalse(immunities.exists, "Empty matchup categories are omitted entirely.")
        XCTAssertFalse(app.staticTexts["Neutral:"].exists)
        XCTAssertTrue(element("bound.rrdex-layout10-evolution", in: app).exists)
        let learnset = element("bound.rrdex-layout10-learnset", in: app)
        XCTAssertTrue(learnset.exists)
        XCTAssertLessThan(element("bound.rrdex-layout10-evolution", in: app).frame.minY, matchups.frame.minY)
        XCTAssertLessThan(matchups.frame.maxY, learnset.frame.minY,
                          "The compact matchup summary sits between Evolution and the inline Learnset.")
        screenshot("RRDex-Layout10-Matchups")

        openBoundSettings(in: app)
        for (content, wasEnabled) in originalEnabledStates {
            let toggle = app.switches["bound.companion-enabled.\(content)"]
            scrollToSetting(toggle, in: app)
            if (toggle.value as? String == "1") != wasEnabled {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        closeBoundSheet(in: app)
    }

    func testLayout11BossHeaderNavigatesChronologicalTrainers() throws {
        // Keep UI events deterministic while the game surface continues animating.
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }

        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 20)); game.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        openBoundSettings(in: app)
        let bossLayout = app.segmentedControls["bound.boss-layout"]
        scrollToSetting(bossLayout, in: app)
        bossLayout.buttons["11"].tap()
        let bossEnabled = app.switches["bound.companion-enabled.bosses"]
        scrollToSetting(bossEnabled, in: app)
        if bossEnabled.value as? String != "1" {
            bossEnabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        closeBoundSheet(in: app)
        defer {
            app.terminate(); app.launch()
            assertPermanentFeatureBaseline(in: app)
            app.terminate()
        }

        selectCompanion("Bosses", in: app)
        let picker = app.buttons["bound.boss-picker"]
        func chooseBoss(id: String, search: String) {
            picker.tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(search)
            let row = app.buttons["bound.boss-select-\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        }
        chooseBoss(id: "johto-leaders-4", search: "Falkner")
        XCTAssertEqual(element("bound.boss-guide", in: app).value as? String, "Layout 11")

        let previous = app.buttons["bound.boss-previous-trainer"]
        let next = app.buttons["bound.boss-next-trainer"]
        XCTAssertTrue(previous.isHittable); XCTAssertTrue(next.isHittable)
        for arrow in [previous, next] {
            XCTAssertGreaterThanOrEqual(arrow.frame.width, 44)
            XCTAssertGreaterThanOrEqual(arrow.frame.height, 44)
        }
        XCTAssertGreaterThan(previous.frame.minX, app.frame.midX,
                             "Trainer navigation belongs on the right side of the Dynamic Island.")
        XCTAssertGreaterThan(next.frame.minX, app.frame.midX)
        XCTAssertLessThan(previous.frame.midY, 80); XCTAssertLessThan(next.frame.midY, 80)
        XCTAssertLessThanOrEqual(abs(previous.frame.midY - next.frame.midY), 2,
                                 "Previous and next controls share the top header row.")
        XCTAssertTrue(picker.label.contains("Falkner"))

        let pokemon = app.staticTexts["bound.boss-pokemon"]
        let secondMember = app.buttons["bound.boss-team-member-2"]
        XCTAssertTrue(secondMember.isHittable)
        secondMember.tap()
        XCTAssertEqual(pokemon.label, "Flittle")

        // The published order places Ace Nelle immediately before Falkner,
        // then Brock immediately after. Each trainer change selects member 0.
        previous.tap()
        XCTAssertTrue(picker.label.contains("Nelle"))
        XCTAssertEqual(pokemon.label, "Charcadet")
        next.tap()
        XCTAssertTrue(picker.label.contains("Falkner"))
        XCTAssertEqual(pokemon.label, "Rufflet")
        next.tap()
        XCTAssertTrue(picker.label.contains("Brock"))
        XCTAssertEqual(pokemon.label, "Geodude-A")
        previous.tap()
        XCTAssertTrue(picker.label.contains("Falkner"))
        XCTAssertEqual(pokemon.label, "Rufflet")

        // Walk back to the first published trainer and verify the left arrow
        // disables at the endpoint instead of wrapping around.
        for (trainer, species) in [("Nelle", "Charcadet"), ("Anne", "Stufful"), ("Brendan", "Corphish"), ("Rival", "Starly")] {
            previous.tap()
            XCTAssertTrue(picker.label.contains(trainer), "Expected the previous published trainer: \(trainer)")
            XCTAssertEqual(pokemon.label, species, "Changing trainers resets the selected Pokémon to slot 0.")
        }
        XCTAssertFalse(previous.isEnabled, "The first published trainer has no previous encounter.")
        XCTAssertTrue(next.isEnabled)
        next.tap()
        XCTAssertTrue(picker.label.contains("Brendan"))
        XCTAssertEqual(pokemon.label, "Corphish")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Layout 11 trainer navigation beside Dynamic Island"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLayout11LearnsetAccordionAndSearch() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }

        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 20)); game.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        defer {
            app.terminate(); app.launch()
            assertPermanentFeatureBaseline(in: app)
            app.terminate()
        }

        openBoundSettings(in: app)
        let layout = app.segmentedControls["bound.rrdex-layout"]
        scrollToSetting(layout, in: app); layout.buttons["11"].tap()
        let enabled = app.switches["bound.companion-enabled.dex"]
        scrollToSetting(enabled, in: app)
        let wasEnabled = enabled.value as? String == "1"
        if !wasEnabled { enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        closeBoundSheet(in: app)
        selectCompanion("Dex", in: app)
        app.buttons["bound.rrdex-search-open"].tap()
        let speciesSearch = app.textFields["bound.rrdex-search"]
        XCTAssertTrue(speciesSearch.waitForExistence(timeout: 5))
        speciesSearch.tap(); speciesSearch.typeText("bulbasaur")
        let bulbasaur = app.buttons["bound.rrdex-suggestion-1"]
        XCTAssertTrue(bulbasaur.waitForExistence(timeout: 5)); bulbasaur.tap()

        let details = app.scrollViews["bound.rrdex-layout11-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        func reveal(_ target: XCUIElement, downward: Bool = true) {
            for _ in 0..<14 {
                if target.isHittable && details.frame.contains(target.frame) { break }
                let below = target.exists ? target.frame.midY > details.frame.midY : downward
                details.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.8 : 0.4))
                    .press(forDuration: 0.1, thenDragTo: details.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.4 : 0.8)),
                           withVelocity: .slow, thenHoldForDuration: 0.2)
                Thread.sleep(forTimeInterval: 0.5)
            }
            XCTAssertTrue(target.isHittable)
            XCTAssertTrue(details.frame.contains(target.frame))
        }
        let levelUp = app.buttons["bound.rrdex-layout11-learnset-method-Level up"]
        let machines = app.buttons["bound.rrdex-layout11-learnset-method-TM/HM"]
        let tutor = app.buttons["bound.rrdex-layout11-learnset-method-Tutor"]
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "bound.rrdex-layout11-learnset-move-"))
        reveal(tutor)
        for header in [levelUp, machines, tutor] { XCTAssertEqual(header.value as? String, "Collapsed") }
        XCTAssertFalse(rows.firstMatch.exists)
        screenshot("RRDex-Layout11-Learnset-Collapsed")

        // Work upward through the headers so switching does not require scrolling
        // through an entire expanded move list to reach the following section.
        tutor.tap()
        XCTAssertEqual(tutor.value as? String, "Expanded")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        reveal(machines, downward: false); machines.tap()
        XCTAssertEqual(machines.value as? String, "Expanded")
        // The following headers are virtualized while a long section is open.
        // Close the active section before checking the old section's state.
        reveal(machines, downward: false); machines.tap()
        reveal(tutor)
        XCTAssertEqual(tutor.value as? String, "Collapsed")
        reveal(machines, downward: false); machines.tap()
        reveal(levelUp, downward: false); levelUp.tap()
        XCTAssertEqual(levelUp.value as? String, "Expanded")
        screenshot("RRDex-Layout11-Level-Up-Expanded")
        reveal(levelUp, downward: false); levelUp.tap()
        XCTAssertEqual(levelUp.value as? String, "Collapsed")
        reveal(machines)
        XCTAssertEqual(machines.value as? String, "Collapsed")
        reveal(tutor)
        XCTAssertEqual(tutor.value as? String, "Collapsed")
        XCTAssertFalse(rows.firstMatch.exists)

        let searchToggle = app.buttons["bound.rrdex-layout11-learnset-search-toggle"]
        reveal(searchToggle, downward: false); searchToggle.tap()
        let search = app.textFields["bound.rrdex-layout11-learnset-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("solar")
        XCTAssertTrue(tutor.waitForExistence(timeout: 5))
        XCTAssertEqual(tutor.value as? String, "Collapsed")
        reveal(tutor); tutor.tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(rows.firstMatch.label.localizedCaseInsensitiveContains("solar"))
        screenshot("RRDex-Layout11-Filtered-Moves")

        // A species change starts a fresh, fully collapsed accordion.
        app.buttons["bound.rrdex-search-open"].tap()
        XCTAssertTrue(speciesSearch.waitForExistence(timeout: 5))
        speciesSearch.tap(); speciesSearch.typeText("charmander")
        let charmander = app.buttons["bound.rrdex-suggestion-4"]
        XCTAssertTrue(charmander.waitForExistence(timeout: 5)); charmander.tap()
        reveal(levelUp)
        XCTAssertEqual(levelUp.value as? String, "Collapsed")
        XCTAssertFalse(rows.firstMatch.exists)

        if !wasEnabled {
            openBoundSettings(in: app)
            scrollToSetting(enabled, in: app)
            enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            closeBoundSheet(in: app)
        }
    }

    func testDefaultPresetAndExperimentalCustomizationVisibility() throws {
        throw XCTSkip("This test only covers the removed experimental customization UI.")
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            XCUIDevice.shared.orientation = .portrait
            for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) }
        }
        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-reset-layout"]
        app.launch()
        // The existing layout-reset fixture runs when gameplay is installed.
        // Relaunch afterward so Library settings read genuinely unset choices.
        let resetGame = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(resetGame.waitForExistence(timeout: 15)); resetGame.tap()
        XCTAssertTrue(element("bound.native-menu", in: app).waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["--bound-ui-no-animations"]
        app.launch()
        func openInterface() {
            XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
            app.buttons["Settings"].tap()
            XCTAssertTrue(app.buttons["bound.settings-interface"].waitForExistence(timeout: 5))
            app.buttons["bound.settings-interface"].tap()
        }
        func reveal(_ target: XCUIElement, towardTop: Bool = false) {
            for _ in 0..<24 {
                let navigation = app.navigationBars["Interface & Companion"]
                if target.exists && target.isHittable && target.frame.minY >= navigation.frame.maxY &&
                    target.frame.maxY <= app.frame.maxY - 8 { return }
                dragSettingsContent(towardTop: towardTop, in: app)
            }
            XCTAssertTrue(target.isHittable)
        }
        let experimental = app.switches["bound.experimental-settings"]
        func setExperimental(_ enabled: Bool) {
            reveal(experimental, towardTop: true)
            if experimental.value as? String != (enabled ? "1" : "0") {
                experimental.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            XCTAssertEqual(experimental.value as? String, enabled ? "1" : "0")
        }
        let version = element("bound.ui-version", in: app)
        func assertCustomizationHidden() {
            for identifier in ["bound.ui-version", "bound.landscape-options",
                               "bound.companion-button-type", "bound.button-1-view.friend",
                               "bound.button-2-view.types", "bound.rrdex-layout", "bound.boss-layout"] {
                XCTAssertFalse(element(identifier, in: app).exists, "Hidden customization: \(identifier)")
            }
            let controllerMode = element("bound.controller-mode-layout", in: app)
            XCTAssertTrue(controllerMode.exists, "Controller Mode is a normal Interface setting.")
            XCTAssertTrue(controllerMode.label.contains("Off")
                          || (controllerMode.value as? String)?.contains("Off") == true)
        }
        openInterface()
        XCTAssertTrue(experimental.waitForExistence(timeout: 5))
        XCTAssertEqual(experimental.value as? String, "0")
        assertCustomizationHidden()
        screenshot("Default-interface-customization-hidden")
        setExperimental(true)
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertTrue(version.label.contains("Option 2"))
        XCTAssertTrue(element("bound.landscape-options", in: app).label.contains("Option 7"))
        XCTAssertTrue(element("bound.controller-mode-layout", in: app).label.contains("Off"))
        let buttonType = app.segmentedControls["bound.companion-button-type"]
        reveal(buttonType)
        XCTAssertTrue(buttonType.buttons["4"].isSelected)
        for button in [1, 2] {
            for content in ["friend", "notes", "types", "bosses", "dex"] {
                let toggle = app.switches["bound.button-\(button)-view.\(content)"]
                reveal(toggle)
                let enabled = button == 1 ? content == "friend" : ["types", "bosses", "dex"].contains(content)
                XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0", "Default assignment for button \(button): \(content)")
            }
        }
        for identifier in ["bound.rrdex-layout", "bound.boss-layout"] {
            let layout = element(identifier, in: app)
            reveal(layout)
            XCTAssertTrue(layout.label.contains("Layout 12"))
        }
        reveal(version, towardTop: true)
        version.tap(); app.buttons["Option 1"].firstMatch.tap()
        XCTAssertTrue(version.label.contains("Option 1"))
        setExperimental(false)
        assertCustomizationHidden()
        app.buttons["bound.settings-close"].tap()
        app.terminate()
        app.launchArguments = ["--bound-ui-no-animations"]
        app.launch()
        openInterface()
        XCTAssertEqual(experimental.value as? String, "0")
        assertCustomizationHidden()
        setExperimental(true)
        XCTAssertTrue(version.label.contains("Option 1"), "Hiding customization preserves the selected UI version across launch.")
        version.tap(); app.buttons["Option 2"].firstMatch.tap()
        setExperimental(false)
        app.buttons["bound.settings-close"].tap()
        let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 15)); game.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle.1"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["bound.panel-cycle.1"].value as? String, "Friend")
        XCTAssertEqual(app.buttons["bound.panel-cycle.2"].value as? String, "Types")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(element("bound.landscape7-tabs", in: app).waitForExistence(timeout: 10))
        for content in ["dex", "bosses", "types"] {
            XCTAssertTrue(app.buttons["bound.landscape7-tab-" + content].exists)
        }
        XCTAssertTrue(element("bound.native-l", in: app).exists, "Controller Mode is off by default.")
        screenshot("Default-landscape-seven-with-touch-controls")
        app.terminate()
    }

    func testControllerModeCyclesAndNavigationCanBeEnabledFromMainSettings() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            XCUIDevice.shared.orientation = .portrait
            for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) }
        }
        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture",
                                       "--bound-ui-no-animations", "--bound-ui-screen-layout-bound"])
        openNativePause(in: app)
        let tile = app.buttons["bound.controller-mode"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertEqual(tile.label, "OFF")
        for state in ["ON", "OFF", "ON"] {
            tile.tap()
            let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", state), object: tile)
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        }
        app.buttons["Settings"].tap()
        let controls = app.buttons["bound.settings-controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5)); controls.tap()
        let enabled = app.switches["bound.controller-mode-enabled"]
        let navigation = app.switches["bound.controller-view-navigation"]
        let multiview = app.switches["bound.controller-multiview"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertFalse(element("bound.controller-mode-layout", in: app).exists,
                        "Controller Mode is a single on/off setting.")
        XCTAssertEqual(enabled.value as? String, "1")
        XCTAssertEqual(navigation.value as? String, "0")
        XCTAssertTrue(multiview.waitForExistence(timeout: 5))
        XCTAssertEqual(multiview.label, "Allow Controller to Control Multiview")
        XCTAssertEqual(multiview.value as? String, "0")
        multiview.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(multiview.value as? String, "1")
        screenshot("Controls-Allow-Multiview-Portrait")
        navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(navigation.value as? String, "1")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(enabled.value as? String, "0")
        closeBoundSheet(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(element("bound.native-r", in: app).waitForExistence(timeout: 8))
        openNativePause(in: app)
        XCTAssertEqual(tile.label, "OFF")
        app.buttons["Settings"].tap()
        XCTAssertTrue(controls.waitForExistence(timeout: 5)); controls.tap()
        XCTAssertEqual(navigation.value as? String, "1", "Navigation preference remains independent of mode enablement")
        XCTAssertEqual(multiview.value as? String, "1", "Automatic Multiview preference persists independently of Controller Mode")
        screenshot("Controls-Allow-Controller-to-Control-Multiview")
        multiview.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(multiview.value as? String, "0")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        closeBoundSheet(in: app)
        XCTAssertTrue(element("bound.native-r", in: app).waitForNonExistence(timeout: 5))
        app.terminate()
    }

    func testGBAGamepadEditorHidesAndRestoresSharedTopSettingsDone() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-controller-fixture"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        let controls = app.buttons["bound.settings-controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5)); controls.tap()
        let controllers = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Controllers")).firstMatch
        XCTAssertTrue(controllers.waitForExistence(timeout: 5)); controllers.tap()
        XCTAssertTrue(app.navigationBars["Controllers"].waitForExistence(timeout: 5))
        assertSettingsCloseAtTop(in: app, navigationTitle: "Controllers")

        let player = app.staticTexts["Player 2"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 5)); player.tap()
        let connectedController = app.buttons["ExtendedGamepad"]
        XCTAssertTrue(connectedController.waitForExistence(timeout: 10), "The app-local controller fixture should appear in Player 2.")
        connectedController.tap()
        let gba = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Game Boy Advance")).firstMatch
        XCTAssertTrue(gba.waitForExistence(timeout: 5), "The connected controller exposes its GBA mapping editor.")
        gba.tap()
        XCTAssertTrue(app.navigationBars["Game Boy Advance"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["bound.settings-close"].exists,
                       "GBA mapping uses its Save and navigation Back controls without a redundant shared Done.")
        XCTAssertFalse(element("bound.settings-footer", in: app).exists)
        let bindingRows = [(input: "a", action: "A"),
                           (input: "b", action: "B"),
                           (input: "leftTrigger", action: "Select"),
                           (input: "rightTrigger", action: "Start"),
                           (input: "share", action: "System Capture")]
        for (input, expectedAction) in bindingRows {
            let row = app.buttons.matching(identifier: "bound.controller-mapping.\(input)").firstMatch
            scrollToSetting(row, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "The \(input) controller binding row should be visible.")
            XCTAssertEqual(row.value as? String, expectedAction,
                           "The \(input) row should expose its effective default action.")
        }
        XCTAssertTrue(app.buttons["Save"].exists)
        screenshot("GBA-Controller-Mapping-Without-Shared-Done")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["bound.settings-close"].waitForExistence(timeout: 5),
                      "Back restores the shared top-bar Done after leaving GBA mapping.")
        assertSettingsCloseAtTop(in: app)
    }

    func testLandscapeArrangeViewsUsesTheDefaultGridWithControllerModeOff() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            XCUIDevice.shared.orientation = .portrait
            for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) }
        }

        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture",
                                       "--bound-ui-no-animations", "--bound-ui-screen-layout-bound"])
        defer { app.terminate() }

        openBoundSettings(in: app)
        let controllerMode = app.switches["bound.controller-mode-enabled"]
        XCTAssertEqual(controllerMode.value as? String, "0", "Controller Mode starts Off in the reset fixture.")
        let settingsSpacing = app.sliders["bound.button-grid-spacing"]
        scrollToSetting(settingsSpacing, in: app)
        XCTAssertTrue(settingsSpacing.waitForExistence(timeout: 5))
        settingsSpacing.adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(settingsSpacing.value as? String, "48 points")
        closeBoundSheet(in: app)

        XCTAssertTrue(element("bound.native-r", in: app).waitForExistence(timeout: 5),
                      "Landscape arrangement settings do not disable portrait touch controls.")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(element("bound.landscape7-tabs", in: app).waitForExistence(timeout: 10))
        openNativePause(in: app)
        let arrange = app.buttons["bound.menu-arrange-views"]
        XCTAssertTrue(arrange.waitForExistence(timeout: 5)); arrange.tap()

        let next = app.buttons["bound.landscape7-next"]
        if next.waitForExistence(timeout: 8) { next.tap() }
        let done = app.buttons["bound.landscape7-done"]
        let snapping = app.buttons["bound.arrange-buttons.distance-snapping"]
        let spacing = app.sliders["bound.arrange-buttons.grid-spacing"]
        XCTAssertTrue(done.waitForExistence(timeout: 8), "Arrange Views exposes the common button placement phase while Controller Mode is Off.")
        XCTAssertTrue(snapping.waitForExistence(timeout: 5))
        XCTAssertEqual(snapping.value as? String, "On", "The distance grid is enabled by default in Controller Mode Off.")
        XCTAssertTrue(spacing.waitForExistence(timeout: 5), "Controller Mode Off uses the same visible spacing slider.")
        XCTAssertEqual(spacing.value as? String, "48 points", "The arrange window uses the spacing configured in Controls.")

        let multiview = element("bound.landscape7-move.dex", in: app)
        let menuHandle = element("bound.controller-button-move.menu", in: app)
        XCTAssertTrue(multiview.waitForExistence(timeout: 5))
        XCTAssertTrue(menuHandle.waitForExistence(timeout: 5))
        let panelStart = multiview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        panelStart.press(forDuration: 0.1, thenDragTo: panelStart.withOffset(
            CGVector(dx: menuHandle.frame.midX - multiview.frame.midX,
                     dy: menuHandle.frame.midY - multiview.frame.midY)))
        XCTAssertTrue(multiview.frame.intersects(menuHandle.frame),
                      "Multiview can overlap Menu on the first drag without pressing a layer arrow.")
        XCTAssertTrue(app.buttons["bound.landscape7-layer-front.dex"].isSelected,
                      "Dragging over buttons must preserve the selected layer.")
        screenshot("Landscape-Controller-Off-Multiview-Overlap-Without-Layer-Change")

        let buttonNames = ["menu", "friend", "multiview"]
        let gridSpacing: CGFloat = 48
        var savedFrames: [String: CGRect] = [:]
        for (index, name) in buttonNames.enumerated() {
            let button = element("bound.controller-button-move." + name, in: app)
            XCTAssertTrue(button.waitForExistence(timeout: 5), "The \(name) button can be moved with Controller Mode Off.")
            let start = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let target = app.coordinate(withNormalizedOffset: CGVector(dx: CGFloat(index + 1) * 0.25, dy: 0.72))
            start.press(forDuration: 0.1, thenDragTo: target)
            let moved = element("bound.controller-button-move." + name, in: app)
            savedFrames[name] = moved.frame
            XCTAssertTrue(moved.frame.midY.isFinite)
            for offset in [moved.frame.midX - app.frame.midX, moved.frame.midY - app.frame.midY] {
                XCTAssertEqual(offset / gridSpacing, (offset / gridSpacing).rounded(), accuracy: 0.08,
                               "The \(name) button snaps to the center-aligned grid.")
            }
        }
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))

        // Change the Controller Mode On arrangement, then make sure those edits
        // do not replace the placements saved above with Controller Mode Off.
        openNativePause(in: app)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["bound.settings-controls"].waitForExistence(timeout: 5))
        app.buttons["bound.settings-controls"].tap()
        XCTAssertTrue(controllerMode.waitForExistence(timeout: 5))
        controllerMode.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(controllerMode.value as? String, "1")
        closeBoundSheet(in: app)
        openNativePause(in: app)
        XCTAssertTrue(app.buttons["bound.menu-arrange-views"].waitForExistence(timeout: 5))
        app.buttons["bound.menu-arrange-views"].tap()
        if next.waitForExistence(timeout: 8) { next.tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        XCTAssertEqual(snapping.value as? String, "On")
        let plus = app.buttons["bound.arrange-buttons.plus"]
        for name in ["friend", "multiview"] where !element("bound.controller-button-move." + name, in: app).exists {
            plus.tap()
            let addButton = element("bound.arrange-buttons.add." + name, in: app)
            XCTAssertTrue(addButton.waitForExistence(timeout: 5))
            addButton.tap()
            XCTAssertTrue(element("bound.controller-button-move." + name, in: app).waitForExistence(timeout: 5))
        }
        for (index, name) in buttonNames.enumerated() {
            let button = element("bound.controller-button-move." + name, in: app)
            let start = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let target = app.coordinate(withNormalizedOffset: CGVector(dx: CGFloat(index + 1) * 0.25, dy: 0.38))
            start.press(forDuration: 0.1, thenDragTo: target)
        }
        for name in buttonNames {
            XCTAssertTrue(element("bound.controller-button-move." + name, in: app).exists)
        }
        done.tap()

        openNativePause(in: app)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["bound.settings-controls"].waitForExistence(timeout: 5))
        app.buttons["bound.settings-controls"].tap()
        XCTAssertTrue(controllerMode.waitForExistence(timeout: 5))
        controllerMode.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(controllerMode.value as? String, "0")
        closeBoundSheet(in: app)
        openNativePause(in: app)
        app.buttons["bound.menu-arrange-views"].tap()
        if next.waitForExistence(timeout: 8) { next.tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        XCTAssertEqual(snapping.value as? String, "On")
        for name in buttonNames {
            let button = element("bound.controller-button-move." + name, in: app)
            let savedFrame = try XCTUnwrap(savedFrames[name])
            XCTAssertEqual(button.frame.midX, savedFrame.midX, accuracy: 1,
                           "Controller Mode On keeps a separate layout from the saved Off \(name) placement.")
            XCTAssertEqual(button.frame.midY, savedFrame.midY, accuracy: 1)
        }
        done.tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(element("bound.native-r", in: app).waitForExistence(timeout: 10),
                      "Controller Mode Off leaves portrait touch controls visible after landscape editing.")
    }

    func testControllerModeArrangeViewsUsesTwoPhasesAndRestoresRemovedButtons() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            XCUIDevice.shared.orientation = .portrait
            for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) }
        }

        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture",
                                       "--bound-ui-no-animations", "--bound-ui-screen-layout-bound"])
        openNativePause(in: app)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["bound.settings-controls"].waitForExistence(timeout: 5))
        app.buttons["bound.settings-controls"].tap()
        let enabled = app.switches["bound.controller-mode-enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertFalse(element("bound.controller-mode-layout", in: app).exists)
        XCTAssertFalse(app.switches["bound.experimental-settings"].exists)
        XCTAssertFalse(app.switches["bound.enable-experimental-features"].exists)
        let gridSpacing = app.sliders["bound.button-grid-spacing"]
        scrollToSetting(gridSpacing, in: app)
        XCTAssertTrue(gridSpacing.waitForExistence(timeout: 5))
        XCTAssertEqual(gridSpacing.value as? String, "18 points")
        gridSpacing.adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(gridSpacing.value as? String, "48 points")
        screenshot("Controls-Button-Grid-Spacing")
        if enabled.value as? String != "1" {
            enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(enabled.value as? String, "1")
        closeBoundSheet(in: app)

        XCTAssertTrue(element("bound.native-r", in: app).waitForExistence(timeout: 5),
                      "Controller Mode must not hide portrait touch controls.")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(element("bound.landscape7-tabs", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["bound.landscape7-friend-button"].exists,
                       "The unified Controller Mode starts with only Menu visible.")
        XCTAssertFalse(app.buttons["bound.landscape7-views-button"].exists)

        let menu = element("bound.native-menu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(menu.frame.minX, app.frame.minX + 70)
        XCTAssertGreaterThanOrEqual(menu.frame.maxY, app.frame.maxY - 55)
        menu.tap()
        let arrange = app.buttons["bound.menu-arrange-views"]
        XCTAssertTrue(arrange.waitForExistence(timeout: 5)); arrange.tap()

        let gameMove = element("bound.arrange-game.move", in: app)
        let gameResize = element("bound.arrange-game.resize", in: app)
        let status = element("bound.arrange-game.status", in: app)
        let next = app.buttons["bound.landscape7-next"]
        XCTAssertTrue(gameMove.waitForExistence(timeout: 8), "Arrange Views starts with game-screen placement.")
        XCTAssertTrue(gameResize.exists)
        XCTAssertTrue(status.exists)
        XCTAssertFalse(app.buttons["bound.landscape7-done"].exists,
                       "Done belongs to the second phase.")

        let beforeMove = gameMove.frame
        let moveStart = gameMove.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        moveStart.press(forDuration: 0.1, thenDragTo: moveStart.withOffset(CGVector(dx: 30, dy: 0)))
        XCTAssertNotEqual(gameMove.frame.minX, beforeMove.minX, accuracy: 1,
                           "The first phase moves the game screen horizontally.")
        let beforeResize = gameResize.frame
        let resizeStart = gameResize.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        resizeStart.press(forDuration: 0.1, thenDragTo: resizeStart.withOffset(CGVector(dx: -90, dy: 0)))
        XCTAssertNotEqual(gameResize.frame, beforeResize,
                          "The first phase lets users resize the game screen.")
        XCTAssertTrue(next.waitForExistence(timeout: 5)); next.tap()

        let done = app.buttons["bound.landscape7-done"]
        let plus = app.buttons["bound.arrange-buttons.plus"]
        let trash = element("bound.arrange-buttons.trash", in: app)
        XCTAssertTrue(done.waitForExistence(timeout: 8), "NEXT opens view and button placement.")
        XCTAssertTrue(plus.exists)
        XCTAssertTrue(trash.exists)
        let arrangementSpacing = app.sliders["bound.arrange-buttons.grid-spacing"]
        XCTAssertTrue(arrangementSpacing.waitForExistence(timeout: 5))
        let spacingFrame = arrangementSpacing.frame
        XCTAssertEqual(arrangementSpacing.value as? String, "48 points")
        arrangementSpacing.adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(arrangementSpacing.value as? String, "6 points")
        arrangementSpacing.adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(arrangementSpacing.value as? String, "48 points")
        XCTAssertTrue(element("bound.controller-button-move.menu", in: app).exists,
                       "The Menu button remains present and cannot be removed.")

        func add(_ name: String, byDragging: Bool = false) {
            if element("bound.controller-button-move.\(name)", in: app).exists { return }
            plus.tap()
            XCTAssertEqual(arrangementSpacing.frame, spacingFrame, "The spacing slider stays fixed when the add-button tray opens.")
            let add = element("bound.arrange-buttons.add.\(name)", in: app)
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            if byDragging {
                let start = add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                let target = name == "friend" ? CGVector(dx: 0.82, dy: 0.75) : CGVector(dx: 0.68, dy: 0.55)
                start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: target))
            } else {
                add.tap()
            }
            XCTAssertTrue(element("bound.controller-button-move.\(name)", in: app).waitForExistence(timeout: 5))
        }
        add("friend")
        add("multiview", byDragging: true)

        let friend = element("bound.controller-button-move.friend", in: app)
        let friendStart = friend.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let trashCenter = trash.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        friendStart.press(forDuration: 0.1, thenDragTo: trashCenter)
        XCTAssertTrue(friend.waitForNonExistence(timeout: 5), "Dropping Friend in the trash removes its screen button.")
        add("friend", byDragging: true)
        XCTAssertTrue(element("bound.controller-button-move.multiview", in: app).exists)
        screenshot("Controller-Mode-Unified-Buttons-Restored")
        XCTAssertFalse(app.buttons["bound.arrange-buttons.spread"].exists)
        let snapping = app.buttons["bound.arrange-buttons.distance-snapping"]
        XCTAssertTrue(snapping.waitForExistence(timeout: 5))
        XCTAssertEqual(snapping.value as? String, "On", "The distance grid is enabled by default in Controller Mode On.")
        let buttonIDs = ["friend", "multiview", "menu"]
        for (index, name) in buttonIDs.enumerated() {
            let button = element("bound.controller-button-move." + name, in: app)
            let start = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: CGFloat(index - 1) * 96 + 4, dy: 52))
            start.press(forDuration: 0.1, thenDragTo: target)
        }
        let row = buttonIDs.map { element("bound.controller-button-move." + $0, in: app).frame }.sorted { $0.midX < $1.midX }
        XCTAssertEqual(row[1].midX - row[0].midX, row[2].midX - row[1].midX, accuracy: 2)
        XCTAssertEqual(row[0].midY, row[2].midY, accuracy: 2)
        XCTAssertEqual(row[0].midX + row[2].midX, 2 * app.frame.midX, accuracy: 2)
        for frame in row {
            let x = (frame.midX - app.frame.midX) / 48
            let y = (frame.midY - app.frame.midY) / 48
            XCTAssertEqual(x, x.rounded(), accuracy: 0.04)
            XCTAssertEqual(y, y.rounded(), accuracy: 0.04)
        }
        screenshot("Controller-Mode-Buttons-Centered-Grid")
        snapping.tap()
        XCTAssertEqual(snapping.value as? String, "Off")
        let freeStart = friend.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let freeFrame = friend.frame
        freeStart.press(forDuration: 0.1, thenDragTo: freeStart.withOffset(CGVector(dx: 37, dy: 29)))
        // UIKit's pan threshold can consume part of a synthesized drag. Check
        // that both axes move freely off the lattice; model tests cover exact translation.
        XCTAssertGreaterThan(friend.frame.midX - freeFrame.midX, 15)
        XCTAssertGreaterThan(friend.frame.midY - freeFrame.midY, 10)
        for offset in [friend.frame.midX - app.frame.midX, friend.frame.midY - app.frame.midY] {
            XCTAssertGreaterThan(abs(offset - (offset / 48).rounded() * 48), 6)
        }
        let ontoSlider = friend.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        ontoSlider.press(forDuration: 0.1, thenDragTo: arrangementSpacing.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(friend.frame.intersects(spacingFrame), "Buttons can be placed over the spacing slider.")
        let overlappingFrame = friend.frame
        let awayFromSlider = friend.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        awayFromSlider.press(forDuration: 0.1, thenDragTo: awayFromSlider.withOffset(CGVector(dx: -85, dy: -60)))
        XCTAssertLessThan(friend.frame.midX - overlappingFrame.midX, -50, "A button over the slider must remain draggable.")
        XCTAssertLessThan(friend.frame.midY - overlappingFrame.midY, -30)
        XCTAssertEqual(arrangementSpacing.value as? String, "48 points", "Dragging over the slider must not resize the grid.")
        XCTAssertEqual(arrangementSpacing.frame, spacingFrame)
        let savedFriendFrame = friend.frame
        let beforeToolbar = trash.frame
        let menuHandle = element("bound.controller-button-move.menu", in: app)
        menuHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: trash.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertNotEqual(trash.frame, beforeToolbar, "The toolbar avoids Menu while the slider keeps its fixed anchor.")
        XCTAssertEqual(arrangementSpacing.frame, spacingFrame)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))

        menu.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        arrange.tap()
        XCTAssertTrue(gameMove.waitForExistence(timeout: 8))
        next.tap()
        XCTAssertTrue(element("bound.controller-button-move.friend", in: app).waitForExistence(timeout: 5),
                      "DONE persists the restored Friend button.")
        XCTAssertTrue(element("bound.controller-button-move.multiview", in: app).exists,
                       "DONE persists the Multiview button.")
        XCTAssertEqual(snapping.value as? String, "Off")
        XCTAssertEqual(arrangementSpacing.value as? String, "48 points")
        XCTAssertEqual(friend.frame.midX, savedFriendFrame.midX, accuracy: 1)
        XCTAssertEqual(friend.frame.midY, savedFriendFrame.midY, accuracy: 1)
        done.tap()

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(element("bound.native-r", in: app).waitForExistence(timeout: 10),
                       "Portrait touch controls remain visible while Controller Mode is on.")
        app.terminate()
    }

    func testLibraryAccountSettingsProvidesBoundSignInAndAccountCreation() throws {
        let app = XCUIApplication()
        for version in [1, 2] {
            app.launchArguments = ["--bound-ui-no-animations", "-bound.ui.version.v1", "\(version)"]
            app.launch()

            let settings = app.buttons["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 20))
            settings.tap()
            let accountSettings = app.buttons["bound.settings-account"]
            XCTAssertTrue(accountSettings.waitForExistence(timeout: 10))
            accountSettings.tap()
            XCTAssertTrue(app.navigationBars["Account & Sync"].waitForExistence(timeout: 5))
            assertSettingsCloseAtTop(in: app, navigationTitle: "Account & Sync")

            // This QA check must never sign out a saved account or alter its state.
            if app.descendants(matching: .any).matching(identifier: "bound.account-username").firstMatch.exists ||
                app.buttons["bound.account-sign-out"].exists {
                app.terminate()
                throw XCTSkip("Account & Sync is signed in; keep this check read-only for saved accounts.")
            }

            screenshot("Library-Account-Sign-In-Option-\(version)")
            let email = app.textFields["account.signin.email"]
            let password = app.secureTextFields["account.signin.password"]
            let submit = app.buttons["account.signin.submit"]
            XCTAssertTrue(email.waitForExistence(timeout: 5))
            XCTAssertTrue(password.exists)
            XCTAssertFalse(submit.isEnabled, "Sign in stays disabled until both fields have values.")
            email.tap()
            email.typeText("library-fixture@example.invalid")

            app.buttons["account.signin.create-account"].tap()
            let signupEmail = app.textFields["account.signup.email"]
            XCTAssertTrue(signupEmail.waitForExistence(timeout: 5))
            XCTAssertEqual(signupEmail.value as? String, "library-fixture@example.invalid",
                           "Create Account carries the entered address into the signup form.")
            XCTAssertTrue(app.secureTextFields["account.signup.password"].exists)
            XCTAssertTrue(app.textFields["account.signup.username"].exists)

            app.navigationBars["Create Account"].buttons["Cancel"].tap()
            XCTAssertTrue(email.waitForExistence(timeout: 5), "Cancel returns to the sign-in form.")
            XCTAssertTrue(password.exists)
            XCTAssertFalse(submit.isEnabled)

            password.tap()
            let fixturePassword = "offline-fixture-password"
            password.typeText(fixturePassword)
            XCTAssertTrue(submit.isEnabled)
            // No login is submitted. Clear this fixture before navigating so iOS
            // does not offer to save dummy credentials over the app's controls.
            password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: fixturePassword.count))
            XCTAssertFalse(submit.isEnabled)

            app.navigationBars["Account & Sync"].buttons.firstMatch.tap()
            XCTAssertTrue(accountSettings.waitForExistence(timeout: 5), "Back returns to the Settings list.")
            accountSettings.tap()
            XCTAssertTrue(app.navigationBars["Account & Sync"].waitForExistence(timeout: 5))
            let reopenedSubmit = app.buttons["account.signin.submit"]
            XCTAssertTrue(app.textFields["account.signin.email"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.secureTextFields["account.signin.password"].exists)
            XCTAssertFalse(reopenedSubmit.isEnabled, "Reopening Account & Sync does not restore the password.")

            app.navigationBars["Account & Sync"].buttons.firstMatch.tap()
            XCTAssertTrue(accountSettings.waitForExistence(timeout: 5))
            app.buttons["bound.settings-close"].tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 5), "Done returns from Account & Sync to the game library.")
            app.terminate()
        }
    }

    func testUsernameIsRequiredForSignup() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }
        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 20)); game.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        openNativePause(in: app)
        XCTAssertTrue(app.buttons["Connect"].waitForExistence(timeout: 5), "Use the signed-out diagnostic Simulator; never change a real account")
        app.buttons["Connect"].tap()
        app.buttons["Create Account"].tap()
        let email = app.textFields["account.signup.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        let username = app.textFields["account.signup.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        let submit = app.buttons["account.signup.submit"]
        XCTAssertFalse(submit.isEnabled)
        email.tap(); email.typeText("fixture@example.invalid")
        let password = app.secureTextFields["account.signup.password"]
        password.tap(); password.typeText("offline-fixture-password")
        XCTAssertFalse(submit.isEnabled, "A new account requires a username")
        username.tap(); username.typeText("Fixture River")
        XCTAssertTrue(submit.isEnabled)
        screenshot("Bound-username-signup")
        // No signup, friend request, or real authentication is sent by this UI check.
        app.buttons["Cancel"].tap()
        closeBoundSheet(in: app)
        app.terminate()
    }

    func testBoundButtonTypesPersistAndPreserveGameplay() throws {
        throw XCTSkip("This test only covers the removed companion button type customization UI.")
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }
        let app = XCUIApplication()
        let arguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launchArguments = arguments + ["--bound-ui-reset-layout"]
        app.launch()
        app.launchArguments = arguments
        assertPermanentFeatureBaseline(in: app)
        func play() {
            let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
            XCTAssertTrue(game.waitForExistence(timeout: 20)); game.tap()
            XCTAssertTrue(element("bound.panel-cycle", in: app).waitForExistence(timeout: 15))
        }
        play()
        let picker = app.segmentedControls["bound.companion-button-type"]
        let cycle = element("bound.panel-cycle", in: app)
        let game = element("bound.game-screen", in: app)
        let originalGameFrame = game.frame
        openBoundSettings(in: app)
        let version = element("bound.ui-version", in: app)
        let originalVersion = version.label.contains("Option 2") ? "Option 2" : "Option 1"
        if originalVersion != "Option 2" {
            version.tap(); app.buttons["Option 2"].tap()
        }
        closeBoundSheet(in: app)
        func choose(_ option: Int) {
            openBoundSettings(in: app)
            scrollToSetting(picker, in: app)
            picker.buttons[String(option)].tap()
            XCTAssertTrue(picker.buttons[String(option)].isSelected)
            XCTAssertTrue(picker.buttons["4"].exists)
            if option == 2 { screenshot("Bound-button-type-settings") }
            closeBoundSheet(in: app)
            if option >= 3 { screenshot("Bound-button-option-\(option)-controls") }
            XCTAssertTrue(option >= 3 ? app.buttons["bound.panel-cycle.1"].isHittable : cycle.isHittable)
            XCTAssertEqual(game.frame, originalGameFrame, "Changing the Bound button must preserve gameplay placement.")
        }
        func assertNoHoldMenu(_ button: XCUIElement, afterHold: String, afterTap: String) {
            button.press(forDuration: 0.7)
            XCTAssertEqual(button.value as? String, afterHold,
                           "A hold should activate the assigned companion button once.")
            for menuEntry in ["Friend", "Notes", "Types", "Bosses", "RR Dex"] {
                XCTAssertFalse(app.buttons[menuEntry].exists,
                               "Holding a Bound button must not open the \(menuEntry) view menu entry.")
            }
            button.tap()
            XCTAssertEqual(button.value as? String, afterTap,
                           "The button should still respond to a normal tap after holding.")
        }
        func assertCycleHold() {
            selectCompanion("Friend", in: app)
            cycle.tap()
            let afterOneTap = cycle.value as? String
            cycle.tap()
            let afterTwoTaps = cycle.value as? String
            selectCompanion("Friend", in: app)
            assertNoHoldMenu(cycle, afterHold: afterOneTap ?? "", afterTap: afterTwoTaps ?? "")
        }
        choose(1)
        assertCycleHold()
        let originalButtonFrame = cycle.frame
        var frames: [Int: CGRect] = [1: originalButtonFrame]
        screenshot("Bound-button-option-1")
        for option in 2...4 {
            choose(option)
            if option == 2 { assertCycleHold() }
            frames[option] = cycle.frame
            XCTAssertTrue(app.frame.contains(cycle.frame))
            XCTAssertGreaterThanOrEqual(cycle.frame.width, 44)
            XCTAssertGreaterThan(cycle.frame.height, originalButtonFrame.height * 2)
            XCTAssertGreaterThan(cycle.frame.midX, app.frame.width * 0.75)
            XCTAssertGreaterThanOrEqual(cycle.frame.maxY, originalButtonFrame.maxY)
            XCTAssertFalse(cycle.frame.intersects(game.frame))
            for id in ["bound.native-menu", "bound.native-l", "bound.native-r"] {
                XCTAssertFalse(cycle.frame.intersects(element(id, in: app).frame))
            }
            screenshot("Bound-button-option-\(option)")
        }
        XCTAssertEqual(frames[2], frames[3], "Three separate buttons fit in exactly option 2's footprint.")
        XCTAssertEqual(frames[2], frames[4], "Two separate buttons use the same overall footprint.")
        let top = app.buttons["bound.panel-cycle.1"], bottom = app.buttons["bound.panel-cycle.2"]
        XCTAssertTrue(top.isHittable); XCTAssertTrue(bottom.isHittable)
        XCTAssertFalse(app.buttons["bound.panel-cycle.3"].exists)
        XCTAssertEqual(top.frame.height, bottom.frame.height, accuracy: 0.5)
        XCTAssertEqual(top.frame.maxY, bottom.frame.minY, accuracy: 0.5)
        XCTAssertEqual(top.frame.height + bottom.frame.height, cycle.frame.height, accuracy: 0.5)
        choose(3)
        let segments = (1...3).map { app.buttons["bound.panel-cycle.\($0)"] }
        for segment in segments { XCTAssertTrue(segment.isHittable) }
        XCTAssertLessThanOrEqual(segments[0].frame.maxY, segments[1].frame.minY)
        XCTAssertLessThanOrEqual(segments[1].frame.maxY, segments[2].frame.minY)
        for (index, identifier) in ["bound.friend-screen", "bound.boss-guide", "bound.type-chart"].enumerated() {
            segments[index].tap()
            XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 5))
        }

        openBoundSettings(in: app)
        let topDex = app.switches["bound.button-1-view.dex"]
        let middleTypes = app.switches["bound.button-2-view.types"]
        let bottomNotes = app.switches["bound.button-3-view.notes"]
        scrollToSetting(topDex, in: app)
        let originallyTopDex = topDex.value as? String == "1"
        if !originallyTopDex { topDex.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(topDex.value as? String, "1")
        scrollToSetting(middleTypes, in: app)
        let originallyMiddleTypes = middleTypes.value as? String == "1"
        if !originallyMiddleTypes { middleTypes.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(middleTypes.value as? String, "1")
        scrollToSetting(bottomNotes, in: app)
        let originallyBottomNotes = bottomNotes.value as? String == "1"
        if !originallyBottomNotes { bottomNotes.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(bottomNotes.value as? String, "1")
        closeBoundSheet(in: app)

        // Each split control cycles through two assigned views here, so its
        // accessibility value proves that a hold activates exactly once.
        for (activeIndex, segment) in segments.enumerated() {
            let previousValues = segments.map { $0.value as? String }
            segment.tap(); let afterOneTap = segment.value as? String
            segment.tap(); let afterTwoTaps = segment.value as? String
            XCTAssertNotEqual(afterOneTap, afterTwoTaps, "Each split button cycles between its assigned views.")
            assertNoHoldMenu(segment, afterHold: afterOneTap ?? "", afterTap: afterTwoTaps ?? "")
            for index in segments.indices where index != activeIndex {
                XCTAssertEqual(segments[index].value as? String, previousValues[index],
                               "An inactive button must retain its last selected view icon.")
            }
        }

        // Restore the two assignments added for this hold-menu regression.
        openBoundSettings(in: app)
        scrollToSetting(middleTypes, in: app)
        if (middleTypes.value as? String == "1") != originallyMiddleTypes {
            middleTypes.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        scrollToSetting(bottomNotes, in: app)
        if (bottomNotes.value as? String == "1") != originallyBottomNotes {
            bottomNotes.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        closeBoundSheet(in: app)

        segments[0].tap()
        if segments[0].value as? String != "Friend" { segments[0].tap() }
        XCTAssertTrue(element("bound.friend-screen", in: app).waitForExistence(timeout: 5))
        segments[0].tap()
        XCTAssertTrue(element("bound.rrdex", in: app).waitForExistence(timeout: 5))
        segments[0].tap()
        XCTAssertTrue(element("bound.friend-screen", in: app).waitForExistence(timeout: 5))

        app.terminate(); app.launch(); play()
        XCTAssertEqual(cycle.frame, frames[3], "The selected button survives an app relaunch.")
        openBoundSettings(in: app)
        scrollToSetting(picker, in: app)
        XCTAssertTrue(picker.buttons["3"].isSelected)
        scrollToSetting(topDex, in: app)
        XCTAssertEqual(topDex.value as? String, "1")
        closeBoundSheet(in: app)

        app.terminate(); app.launch(); assertPermanentFeatureBaseline(in: app); play()
        XCTAssertEqual(cycle.frame, frames[3], "The selected button style survives relaunch in the permanent settings baseline.")
        openBoundSettings(in: app)
        scrollToSetting(picker, in: app)
        XCTAssertTrue(picker.buttons["3"].isSelected)
        scrollToSetting(topDex, in: app)
        if (topDex.value as? String == "1") != originallyTopDex {
            topDex.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        scrollToSetting(picker, in: app)
        picker.buttons["4"].tap()
        scrollToSetting(topDex, in: app)
        XCTAssertEqual(topDex.value as? String, "0", "Button 4 keeps independent assignments.")
        topDex.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(topDex.value as? String, "1")
        scrollToSetting(middleTypes, in: app) // Button 2 is Bottom for the two-button style.
        XCTAssertEqual(middleTypes.value as? String, "0")
        middleTypes.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(middleTypes.value as? String, "1")
        screenshot("Bound-button-4-assignments")
        closeBoundSheet(in: app)
        XCTAssertFalse(app.buttons["bound.panel-cycle.3"].exists)
        top.tap()
        XCTAssertEqual(top.value as? String, "RR Dex")
        XCTAssertTrue(element("bound.rrdex", in: app).waitForExistence(timeout: 5))
        screenshot("Bound-button-4-current-dex")
        assertNoHoldMenu(top, afterHold: "Friend", afterTap: "RR Dex")
        bottom.tap()
        XCTAssertEqual(bottom.value as? String, "Bosses", "An inactive button restores its remembered view.")
        XCTAssertEqual(top.value as? String, "RR Dex", "The inactive top button keeps its Dex icon.")
        bottom.tap()
        XCTAssertEqual(bottom.value as? String, "Types")
        XCTAssertTrue(element("bound.type-chart", in: app).waitForExistence(timeout: 5))
        screenshot("Bound-button-4-retained-dex-current-types")
        assertNoHoldMenu(bottom, afterHold: "Bosses", afterTap: "Types")
        top.tap()
        XCTAssertEqual(top.value as? String, "RR Dex")
        XCTAssertTrue(element("bound.rrdex", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(bottom.value as? String, "Types", "The inactive bottom button keeps its Types icon.")
        screenshot("Bound-button-4-current-dex-retained-types")
        top.tap()
        XCTAssertEqual(top.value as? String, "Friend", "Another tap cycles the active button.")
        bottom.tap()
        XCTAssertEqual(bottom.value as? String, "Types")
        XCTAssertTrue(element("bound.type-chart", in: app).waitForExistence(timeout: 5))

        app.terminate(); app.launch(); play()
        XCTAssertFalse(app.buttons["bound.panel-cycle.3"].exists)
        XCTAssertEqual(cycle.frame, frames[4])
        openBoundSettings(in: app)
        XCTAssertTrue(picker.buttons["4"].isSelected)
        scrollToSetting(topDex, in: app)
        XCTAssertEqual(topDex.value as? String, "1")
        scrollToSetting(middleTypes, in: app)
        XCTAssertEqual(middleTypes.value as? String, "1")
        closeBoundSheet(in: app); openBoundSettings(in: app)
        picker.buttons["3"].tap()
        scrollToSetting(topDex, in: app)
        XCTAssertEqual(topDex.value as? String, originallyTopDex ? "1" : "0")
        scrollToSetting(middleTypes, in: app)
        XCTAssertEqual(middleTypes.value as? String, originallyMiddleTypes ? "1" : "0",
                       "Editing Button 4 must preserve Button 3's assignments.")
        closeBoundSheet(in: app); openBoundSettings(in: app)
        picker.buttons["1"].tap()
        if originalVersion == "Option 1" {
            closeBoundSheet(in: app)
            openBoundSettings(in: app)
            let currentVersion = element("bound.ui-version", in: app)
            currentVersion.tap(); app.buttons[originalVersion].tap()
            closeBoundSheet(in: app)
        } else {
            closeBoundSheet(in: app)
        }
        app.terminate()
    }

    func testUIVersionTwoCyclesAndPersistsReferenceLayouts() throws {
        throw XCTSkip("This test only covers removed UI Version and layout customization controls.")
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }
        let app = XCUIApplication()
        let arguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launchArguments = arguments + ["--bound-ui-reset-layout"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        func play() {
            let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
            XCTAssertTrue(game.waitForExistence(timeout: 20)); game.tap()
            XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        }
        defer {
            app.terminate()
            app.launchArguments = arguments + ["--bound-ui-reset-layout"]
            app.launch(); assertPermanentFeatureBaseline(in: app); play(); app.terminate()
        }
        play()
        let gameScreen = element("bound.game-screen", in: app)
        let originalFrame = gameScreen.frame
        openBoundSettings(in: app)
        let version = element("bound.ui-version", in: app)
        scrollToSetting(version, in: app)
        version.tap()
        app.buttons["Option 2"].tap()
        let dex = app.buttons["bound.rrdex-layout"]
        scrollToSetting(dex, in: app); dex.tap()
        let choice = app.buttons["bound.layout-preview.12"]
        scrollToSetting(choice, in: app, fullyVisible: true); choice.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in choice.isSelected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        screenshot("UI-Version2-layout-gallery")
        app.buttons["bound.use-layout"].tap()
        let boss = app.buttons["bound.boss-layout"]
        scrollToSetting(boss, in: app); boss.tap()
        scrollToSetting(choice, in: app, fullyVisible: true); choice.tap()
        app.buttons["bound.use-layout"].tap()
        let reorder = app.buttons["bound.reorder-views"]
        scrollToSetting(reorder, in: app); reorder.tap()
        XCTAssertTrue(app.navigationBars["View order"].waitForExistence(timeout: 5))
        screenshot("UI-Version2-view-order")
        app.navigationBars.buttons.firstMatch.tap()
        closeBoundSheet(in: app)
        XCTAssertEqual(gameScreen.frame, originalFrame)
        let cycle = app.buttons["bound.panel-cycle"]
        selectCompanion("Dex", in: app)
        XCTAssertEqual(cycle.value as? String, "Dex")
        XCTAssertEqual(element("bound.rrdex", in: app).value as? String, "Layout 12")
        screenshot("UI-Version2-dex")
        selectCompanion("Bosses", in: app)
        XCTAssertEqual(cycle.value as? String, "Bosses")
        XCTAssertEqual(element("bound.boss-guide", in: app).value as? String, "Layout 12")
        let teamMember = app.buttons["bound.boss-team-member-1"]
        XCTAssertTrue(teamMember.waitForExistence(timeout: 5))
        XCTAssertTrue(teamMember.isHittable)
        teamMember.tap()
        let memberSelected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in teamMember.isSelected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [memberSelected], timeout: 5), .completed)
        XCTAssertEqual(gameScreen.frame, originalFrame)
        screenshot("UI-Version2-boss")
        app.terminate()
        app.launchArguments = arguments
        app.launch(); play()
        selectCompanion("Dex", in: app)
        XCTAssertEqual(cycle.value as? String, "Dex", "UI Version 2 remains usable after relaunch")
        openBoundSettings(in: app)
        XCTAssertEqual(element("bound.ui-version", in: app).label, "UI Version, Option 2",
                       "UI Version 2 survives relaunch independently of the selected panel.")
        scrollToSetting(version, in: app); version.tap(); app.buttons["Option 1"].tap()
        let originalDex = app.segmentedControls["bound.rrdex-layout"]
        scrollToSetting(originalDex, in: app)
        XCTAssertTrue(originalDex.buttons["12"].isSelected, "Switching UI versions preserves the independent reference layout")
        screenshot("UI-Version1-original-settings")
        closeBoundSheet(in: app)
    }

    func testBossTeamTilesKeepEqualDimensionsAcrossSelection() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }

        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 20)); game.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))

        openBoundSettings(in: app)
        let uiVersion = element("bound.ui-version", in: app)
        let originalVersion = uiVersion.label.contains("Option 2") ? "Option 2" : "Option 1"
        if originalVersion == "Option 2" {
            uiVersion.tap(); app.buttons["Option 1"].tap()
        }
        let bossLayout = app.segmentedControls["bound.boss-layout"]
        scrollToSetting(bossLayout, in: app)
        let originalLayout = bossLayout.buttons.allElementsBoundByIndex.first(where: \.isSelected)?.label ?? "1"
        let bossesEnabled = app.switches["bound.companion-enabled.bosses"]
        scrollToSetting(bossesEnabled, in: app)
        let originallyEnabled = bossesEnabled.value as? String == "1"

        func setVersion(_ title: String) {
            // Reopen at the top rather than tapping an offscreen lazy Form row.
            closeBoundSheet(in: app)
            openBoundSettings(in: app)
            let version = element("bound.ui-version", in: app)
            if !version.label.contains(title) {
                version.tap()
                let option = app.buttons[title]
                XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
            }
            XCTAssertTrue(element("bound.ui-version", in: app).label.contains(title))
        }

        func setBossLayout(_ number: String) {
            let layout = app.segmentedControls["bound.boss-layout"]
            scrollToSetting(layout, in: app)
            if !layout.buttons[number].isSelected { layout.buttons[number].tap() }
            XCTAssertTrue(layout.buttons[number].isSelected)
        }

        func restoreSettings() {
            openBoundSettings(in: app)
            setVersion("Option 1")
            setBossLayout(originalLayout)
            let toggle = app.switches["bound.companion-enabled.bosses"]
            scrollToSetting(toggle, in: app)
            if (toggle.value as? String == "1") != originallyEnabled {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            if originalVersion == "Option 2" { setVersion(originalVersion) }
            closeBoundSheet(in: app)
        }

        defer {
            if app.buttons["bound.panel-cycle"].exists { restoreSettings() }
            app.terminate()
        }

        setVersion("Option 1")
        setBossLayout("12")
        let toggle = app.switches["bound.companion-enabled.bosses"]
        scrollToSetting(toggle, in: app)
        if toggle.value as? String != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        closeBoundSheet(in: app)

        func chooseBoss(_ id: String, search: String) {
            app.buttons["bound.boss-picker"].tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(search)
            let row = app.buttons["bound.boss-select-\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        }

        func verifyTeam(_ id: String, search: String, species: [String], selectionOrder: [Int]) {
            selectCompanion("Bosses", in: app)
            chooseBoss(id, search: search)
            let guide = element("bound.boss-guide", in: app)
            let selectedPokemon = app.staticTexts["bound.boss-pokemon"]
            let members = species.indices.map { app.buttons["bound.boss-team-member-\($0)"] }
            XCTAssertEqual(members.count, species.count)
            members.forEach { XCTAssertTrue($0.exists) }
            XCTAssertEqual(selectedPokemon.label, species[0])

            let strip = element("bound.boss-team-strip", in: app)
            let picture = element("bound.boss-picture", in: app)
            XCTAssertTrue(strip.exists)
            let stripFrame = strip.frame
            XCTAssertEqual(stripFrame.maxX, guide.frame.maxX - 10, accuracy: 1,
                           "The inline team strip must use all remaining width to the guide's trailing inset.")
            XCTAssertGreaterThan(stripFrame.minX, selectedPokemon.frame.maxX,
                                 "The team strip remains beside the selected Pokémon's name.")
            XCTAssertEqual(stripFrame.midY, picture.frame.midY, accuracy: 1,
                           "The selected Pokémon sprite and team strip must share one row.")
            for member in members {
                XCTAssertEqual(member.frame.width, 44, accuracy: 0.5)
                XCTAssertEqual(member.frame.height, 44, accuracy: 0.5)
            }

            func reveal(_ member: XCUIElement) {
                for _ in 0..<8 {
                    let viewport = strip.frame
                    let frame = member.frame
                    if frame.minX >= viewport.minX - 1 && frame.maxX <= viewport.maxX + 1 { break }
                    let movingLeft = frame.maxX > viewport.maxX
                    let start = strip.coordinate(withNormalizedOffset: CGVector(dx: movingLeft ? 0.9 : 0.1, dy: 0.5))
                    let end = strip.coordinate(withNormalizedOffset: CGVector(dx: movingLeft ? 0.1 : 0.9, dy: 0.5))
                    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
                }
                XCTAssertTrue(member.isHittable, "Every fixed-size team tile must be reachable by horizontal scrolling.")
            }
            for index in selectionOrder {
                reveal(members[index])
                let framesBeforeSelection = members.map(\.frame)
                members[index].tap()
                XCTAssertEqual(selectedPokemon.label, species[index])
                XCTAssertTrue(members[index].isSelected)
                XCTAssertEqual(members.filter(\.isSelected).count, 1)
                XCTAssertEqual(strip.frame, stripFrame, "Selecting a different name must not move or resize the inline strip.")
                for (memberIndex, member) in members.enumerated() {
                    let frame = member.frame
                    XCTAssertEqual(frame.width, 44, accuracy: 0.5,
                                   "Selecting \(species[index]) must not resize team tiles.")
                    XCTAssertEqual(frame.height, 44, accuracy: 0.5,
                                   "Selecting \(species[index]) must not resize team tiles.")
                    XCTAssertEqual(frame.minX, framesBeforeSelection[memberIndex].minX, accuracy: 1,
                                   "Selecting a Pokémon must not shift its sibling tiles.")
                }
            }
            screenshot("Boss-tiles-\(search)-\(element("bound.boss-guide", in: app).value ?? "")")
        }

        verifyTeam("johto-leaders-4", search: "Falkner",
                   species: ["Rufflet", "Wattrel", "Flittle"], selectionOrder: [1, 2, 0])
        verifyTeam("kanto-leaders-4", search: "Brock",
                   species: ["Geodude-A", "Varoom", "Onix", "Archen"], selectionOrder: [2, 3, 0])
        verifyTeam("johto-leaders-56", search: "Bugsy Post Lt. Surge",
                   species: ["Kleavor", "Scizor-Mega", "Scyther", "Lokix", "Araquanid", "Vikavolt"],
                   selectionOrder: [3, 1, 5])

        openBoundSettings(in: app)
        setVersion("Option 2")
        let version2Layout = app.buttons["bound.boss-layout"]
        scrollToSetting(version2Layout, in: app)
        XCTAssertTrue(version2Layout.label.contains("Layout 12"),
                       "Changing UI version must retain the selected Boss layout.")
        closeBoundSheet(in: app)
        verifyTeam("johto-leaders-56", search: "Bugsy Post Lt. Surge",
                   species: ["Kleavor", "Scizor-Mega", "Scyther", "Lokix", "Araquanid", "Vikavolt"],
                   selectionOrder: [3, 1, 5])
    }

    func testLayout12BossAndDexInteractions() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }

        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 20)); game.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))

        openBoundSettings(in: app)
        element("bound.ui-version", in: app).tap()
        app.buttons["Option 1"].tap()
        let bossLayout = app.segmentedControls["bound.boss-layout"]
        scrollToSetting(bossLayout, in: app); bossLayout.buttons["12"].tap()
        let dexLayout = app.segmentedControls["bound.rrdex-layout"]
        scrollToSetting(dexLayout, in: app); dexLayout.buttons["12"].tap()
        var originalEnabledStates: [String: Bool] = [:]
        for content in ["bosses", "dex"] {
            let toggle = app.switches["bound.companion-enabled.\(content)"]
            scrollToSetting(toggle, in: app)
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            originalEnabledStates[content] = toggle.value as? String == "1"
            if toggle.value as? String != "1" {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        closeBoundSheet(in: app)
        defer {
            app.terminate(); app.launch()
            assertPermanentFeatureBaseline(in: app)
            app.terminate()
        }

        selectCompanion("Bosses", in: app)
        let bossCard = element("bound.boss-guide", in: app)
        XCTAssertEqual(bossCard.value as? String, "Layout 12")
        let picker = app.buttons["bound.boss-picker"]
        func chooseBoss(id: String, search: String) {
            picker.tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(search)
            let row = app.buttons["bound.boss-select-\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        }
        chooseBoss(id: "johto-leaders-4", search: "Falkner")
        let previousTrainer = app.buttons["bound.boss-previous-trainer"]
        let nextTrainer = app.buttons["bound.boss-next-trainer"]
        XCTAssertTrue(previousTrainer.isHittable); XCTAssertTrue(nextTrainer.isHittable,
                      "Layout 12 keeps the chronological trainer controls from Layout 11.")
        nextTrainer.tap()
        XCTAssertTrue(picker.label.contains("Brock"))
        previousTrainer.tap()
        XCTAssertTrue(picker.label.contains("Falkner"))

        // Compare the team sprite target against Layout 11 for the same encounter.
        let teamIcon = app.buttons["bound.boss-team-member-0"]
        XCTAssertTrue(teamIcon.isHittable)
        let layout12IconFrame = teamIcon.frame
        XCTAssertGreaterThanOrEqual(layout12IconFrame.width, 44)
        XCTAssertGreaterThanOrEqual(layout12IconFrame.height, 44)
        XCTAssertGreaterThanOrEqual(layout12IconFrame.minY, picker.frame.maxY + 2,
                                    "The raised Boss body must stay below the Island actions.")
        XCTAssertLessThanOrEqual(layout12IconFrame.minY, picker.frame.maxY + 8,
                                 "Keep the team row close to the Island actions.")
        screenshot("Boss-Layout12-Tighter-Top-Spacing")
        openBoundSettings(in: app)
        scrollToSetting(bossLayout, in: app); bossLayout.buttons["11"].tap()
        closeBoundSheet(in: app)
        XCTAssertEqual(bossCard.value as? String, "Layout 11")
        let layout11Icon = app.buttons["bound.boss-team-member-0"]
        XCTAssertTrue(layout11Icon.isHittable)
        XCTAssertGreaterThan(layout12IconFrame.width, layout11Icon.frame.width,
                             "Layout 12 gives the team sprites more room than Layout 11.")
        openBoundSettings(in: app)
        scrollToSetting(bossLayout, in: app); bossLayout.buttons["12"].tap()
        closeBoundSheet(in: app)
        XCTAssertEqual(bossCard.value as? String, "Layout 12")

        // The existing row category identifiers expose Layout 12's clearer labels.
        chooseBoss(id: "kanto-leaders-4", search: "Brock")
        XCTAssertEqual(app.staticTexts["bound.boss-move-category-0"].label, "Atk")
        chooseBoss(id: "kanto-leaders-27", search: "Misty")
        XCTAssertEqual(app.staticTexts["bound.boss-move-3"].label, "Grass Knot")
        XCTAssertEqual(app.staticTexts["bound.boss-move-category-3"].label, "SpAtk")

        let bossScroll = app.scrollViews["bound.boss-details"]
        let bossMove = app.staticTexts["bound.boss-move-0"]
        let bossName = app.staticTexts["bound.boss-pokemon"].label
        let bossMoveAtTop = bossMove.frame
        bossScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: bossScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        let bossMoveScrolled = bossMove.frame
        XCTAssertLessThan(bossMoveScrolled.minY, bossMoveAtTop.minY - 5)

        selectCompanion("Dex", in: app)
        XCTAssertFalse(app.buttons["bound.boss-picker"].isHittable,
                       "Retained Boss controls must not receive taps while Dex is active.")
        let dexCard = element("bound.rrdex", in: app)
        XCTAssertEqual(dexCard.value as? String, "Layout 12")
        let search = app.buttons["bound.rrdex-search-open"]
        XCTAssertFalse(app.buttons["bound.rrdex-info"].exists)
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(app.staticTexts["bound.rrdex-reference-rom"].exists)
        XCTAssertTrue(app.staticTexts["bound.rrdex-reference-difficulty"].exists)
        XCTAssertEqual(search.frame.width, 44, accuracy: 1)
        XCTAssertEqual(search.frame.height, 44, accuracy: 1)
        XCTAssertLessThan(search.frame.midY, 70)
        XCTAssertEqual(search.frame.midX, app.frame.midX + 102, accuracy: 4,
                       "The search control keeps its original Dynamic Island clearance and x position.")
        XCTAssertTrue(element("bound.rrdex-reference-footer", in: app).exists)
        screenshot("RRDex-Layout12-Restored-Island-Controls")
        search.tap()
        let speciesSearch = app.textFields["bound.rrdex-search"]
        XCTAssertTrue(speciesSearch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Search Pokémon by name."].exists,
                       "Layout 12 removes the empty-state search instruction.")
        speciesSearch.tap(); speciesSearch.typeText("bulbasaur")
        let bulbasaur = app.buttons["bound.rrdex-suggestion-1"]
        XCTAssertTrue(bulbasaur.waitForExistence(timeout: 5)); bulbasaur.tap()
        XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Bulbasaur")

        let details = app.scrollViews["bound.rrdex-layout12-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        let learnset = element("bound.rrdex-layout12-learnset", in: app)
        XCTAssertTrue(learnset.waitForExistence(timeout: 5))
        func revealLearnsetControl(_ target: XCUIElement) {
            for _ in 0..<14 {
                if target.isHittable && details.frame.contains(target.frame) { break }
                let below = target.exists ? target.frame.midY > details.frame.midY : true
                details.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.8 : 0.4))
                    .press(forDuration: 0.1, thenDragTo: details.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.4 : 0.8)),
                           withVelocity: .slow, thenHoldForDuration: 0.2)
                Thread.sleep(forTimeInterval: 0.5)
            }
            XCTAssertTrue(target.isHittable)
            XCTAssertTrue(details.frame.contains(target.frame))
        }
        let methods = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "bound.rrdex-layout12-learnset-method-")
        )
        let list = app.scrollViews["bound.rrdex-layout12-learnset-list"]
        let categories = ["Level up", "TM/HM", "Tutor", "Egg"]
        let levelUp = app.buttons["bound.rrdex-layout12-learnset-method-Level up"]
        revealLearnsetControl(levelUp)
        for name in categories {
            let category = app.buttons["bound.rrdex-layout12-learnset-method-\(name)"]
            XCTAssertTrue(category.waitForExistence(timeout: 5), "The \(name) category is available in the compact learnset summary.")
        }
        XCTAssertGreaterThanOrEqual(methods.count, categories.count)

        levelUp.tap()
        XCTAssertEqual(levelUp.value as? String, "Selected")
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let compactMoveQuery = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "bound.rrdex-layout12-learnset-move-entry-")
        )
        XCTAssertTrue(compactMoveQuery.firstMatch.waitForExistence(timeout: 5))
        screenshot("RRDex-Layout12-Level-Up-Compact-List")

        let powerHeader = app.staticTexts["Power"]
        let statsHeader = app.staticTexts["Acc / PP"]
        XCTAssertTrue(statsHeader.exists)
        XCTAssertGreaterThan(powerHeader.frame.minX, statsHeader.frame.maxX,
                             "Power remains the rightmost comparison column.")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                       "bound.rrdex-layout12-learnset-move-entry-")).count, 0,
                       "Move rows are static information, not collapsible buttons.")

        // Scrolling the move list leaves the category strip fixed and usable.
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        let rememberedMove = try XCTUnwrap(compactMoveQuery.allElementsBoundByIndex.first { move in
            list.frame.insetBy(dx: 0, dy: 1).contains(move.frame)
        })
        let rememberedMoveID = rememberedMove.identifier
        let rememberedMoveFrame = rememberedMove.frame
        selectCompanion("Bosses", in: app)
        XCTAssertFalse(app.buttons["bound.rrdex-layout12-learnset-back"].isHittable,
                       "Retained Dex controls must not receive taps while Bosses is active.")
        XCTAssertEqual(app.staticTexts["bound.boss-pokemon"].label, bossName)
        XCTAssertEqual(bossMove.frame.minY, bossMoveScrolled.minY, accuracy: 1,
                       "Returning to Boss keeps its prior scroll position.")
        selectCompanion("Dex", in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 5), "Returning to Dex reopens the learnset directly.")
        XCTAssertEqual(levelUp.value as? String, "Selected")
        let restoredMove = element(rememberedMoveID, in: app)
        XCTAssertEqual(restoredMove.frame.minY, rememberedMoveFrame.minY, accuracy: 1,
                       "Returning to the learnset preserves its exact scroll position.")
        screenshot("RRDex-Layout12-Restored-Level-Up-Scroll")
        for name in categories {
            let category = app.buttons["bound.rrdex-layout12-learnset-method-\(name)"]
            XCTAssertTrue(category.isHittable, "The pinned \(name) selector remains reachable after scrolling the move list.")
        }
        XCTAssertTrue(app.buttons["bound.rrdex-layout12-learnset-back"].isHittable)

        // Switch categories directly while the focused list stays open.
        for name in categories.dropFirst() {
            let category = app.buttons["bound.rrdex-layout12-learnset-method-\(name)"]
            category.tap()
            XCTAssertEqual(category.value as? String, "Selected")
            XCTAssertTrue(compactMoveQuery.firstMatch.waitForExistence(timeout: 5),
                          "Selecting \(name) switches the compact list without returning to the summary.")
        }
        levelUp.tap()
        XCTAssertEqual(levelUp.value as? String, "Selected")
        XCTAssertTrue(compactMoveQuery.firstMatch.waitForExistence(timeout: 5))
        let listViewport = list.frame.insetBy(dx: 0, dy: 2)
        let visibleMove = try XCTUnwrap(compactMoveQuery.allElementsBoundByIndex.first { move in
            listViewport.contains(move.frame)
        })
        XCTAssertTrue(visibleMove.label.localizedCaseInsensitiveContains("accuracy"))
        XCTAssertTrue(visibleMove.label.localizedCaseInsensitiveContains("PP"))
        XCTAssertTrue(visibleMove.label.localizedCaseInsensitiveContains("power"))
        let frameBeforeTap = visibleMove.frame
        visibleMove.tap()
        XCTAssertEqual(visibleMove.frame, frameBeforeTap, "Tapping a move must not expand it or resize the row.")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@",
                       "bound.rrdex-layout12-learnset-detail-")).count, 0)
        screenshot("RRDex-Layout12-Inline-Move-Stats")

        // Search crosses method boundaries and merges duplicate move sources into one result.
        app.buttons["bound.rrdex-layout12-learnset-back"].tap()
        revealLearnsetControl(app.buttons["bound.rrdex-layout12-learnset-search-toggle"])
        let searchToggle = app.buttons["bound.rrdex-layout12-learnset-search-toggle"]
        XCTAssertTrue(searchToggle.waitForExistence(timeout: 5)); searchToggle.tap()
        let moveSearch = app.textFields["bound.rrdex-layout12-learnset-search"]
        XCTAssertTrue(moveSearch.waitForExistence(timeout: 5))
        moveSearch.tap(); moveSearch.typeText("Giga Drain")
        moveSearch.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let searchResult = element("bound.rrdex-layout12-learnset-move-move-202", in: app)
        XCTAssertTrue(searchResult.waitForExistence(timeout: 5), "Search finds Giga Drain across learnset categories.")
        let matchingResults = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "bound.rrdex-layout12-learnset-move-move-202")
        )
        XCTAssertEqual(matchingResults.count, 1, "A move learned through multiple methods appears once in search.")
        XCTAssertTrue(searchResult.label.localizedCaseInsensitiveContains("TM/HM"))
        XCTAssertTrue(searchResult.label.localizedCaseInsensitiveContains("Egg"),
                      "The single search result identifies both learning sources.")

        selectCompanion("Bosses", in: app)
        selectCompanion("Dex", in: app)
        XCTAssertTrue(moveSearch.waitForExistence(timeout: 5))
        XCTAssertEqual(moveSearch.value as? String, "Giga Drain", "Move search survives companion switching.")
        XCTAssertTrue(searchResult.exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        app.buttons["bound.rrdex-layout12-learnset-back"].tap()
        XCTAssertTrue(details.waitForExistence(timeout: 5))

        openBoundSettings(in: app)
        for (content, wasEnabled) in originalEnabledStates {
            let toggle = app.switches["bound.companion-enabled.\(content)"]
            scrollToSetting(toggle, in: app)
            if (toggle.value as? String == "1") != wasEnabled {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        closeBoundSheet(in: app)
    }

    func testLayout9InlineLearnsetSearchAndAutomaticRandomizedMoves() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }

        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        let game = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 20))
        game.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))

        openBoundSettings(in: app)
        let bossLayout = app.segmentedControls["bound.boss-layout"]
        scrollToSetting(bossLayout, in: app); bossLayout.buttons["9"].tap()
        let dexLayout = app.segmentedControls["bound.rrdex-layout"]
        scrollToSetting(dexLayout, in: app); dexLayout.buttons["9"].tap()
        var originalEnabledStates: [String: Bool] = [:]
        for content in ["bosses", "dex"] {
            let toggle = app.switches["bound.companion-enabled.\(content)"]
            scrollToSetting(toggle, in: app)
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            originalEnabledStates[content] = toggle.value as? String == "1"
            if toggle.value as? String != "1" {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        closeBoundSheet(in: app)
        app.terminate(); app.launch()
        let relaunchedGame = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(relaunchedGame.waitForExistence(timeout: 20))
        relaunchedGame.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        defer {
            app.terminate(); app.launch()
            assertPermanentFeatureBaseline(in: app)
            app.terminate()
        }

        selectCompanion("Bosses", in: app)
        let bossCard = element("bound.boss-guide", in: app)
        XCTAssertEqual(bossCard.value as? String, "Layout 9")
        app.buttons["bound.boss-picker"].tap()
        let bossSearch = app.searchFields.firstMatch
        XCTAssertTrue(bossSearch.waitForExistence(timeout: 5)); bossSearch.tap(); bossSearch.typeText("Falkner")
        let falkner = app.buttons["bound.boss-select-johto-leaders-4"]
        XCTAssertTrue(falkner.waitForExistence(timeout: 5)); falkner.tap()
        XCTAssertTrue(bossSearch.waitForNonExistence(timeout: 5))
        let bossPicker = app.buttons["bound.boss-picker"]
        XCTAssertFalse(app.buttons["bound.boss-full-team"].exists)
        XCTAssertTrue(bossPicker.isHittable)
        XCTAssertLessThan(bossPicker.frame.midY, 70)
        XCTAssertLessThan(bossPicker.frame.midX, app.frame.midX)
        XCTAssertLessThanOrEqual(bossPicker.frame.maxX, app.frame.midX - 78)
        XCTAssertEqual(app.staticTexts["bound.boss-cap"].label, "Cap 15")

        selectCompanion("Dex", in: app)
        let card = element("bound.rrdex", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertEqual(card.value as? String, "Layout 9")
        XCTAssertFalse(app.buttons["bound.rrdex-info"].exists)
        XCTAssertEqual(app.staticTexts["bound.rrdex-reference-rom"].label, "Radical Red Version 4.1")
        XCTAssertEqual(app.staticTexts["bound.rrdex-reference-difficulty"].label, "Normal Difficulty")
        XCTAssertTrue(element("bound.rrdex-reference-footer", in: app).exists)
        let gameScreen = element("bound.game-screen", in: app)
        XCTAssertTrue(gameScreen.waitForExistence(timeout: 10))
        assertGamePixelsAnimate(gameScreen, in: app)

        // Choose one known species so the move list and search are deterministic.
        app.buttons["bound.rrdex-search-open"].tap()
        let speciesSearch = app.textFields["bound.rrdex-search"]
        XCTAssertTrue(speciesSearch.waitForExistence(timeout: 5))
        speciesSearch.tap(); speciesSearch.typeText("bulbasaur")
        let bulbasaur = app.buttons["bound.rrdex-suggestion-1"]
        XCTAssertTrue(bulbasaur.waitForExistence(timeout: 5)); bulbasaur.tap()
        XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Bulbasaur")

        let details = app.scrollViews["bound.rrdex-layout9-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        let searchToggle = app.buttons["bound.rrdex-layout9-learnset-search-toggle"]
        let learnset = app.descendants(matching: .any)["bound.rrdex-layout9-learnset"]
        XCTAssertFalse(app.buttons["bound.rrdex-layout9-learnset"].exists,
                       "Layout 9 should display moves inline instead of opening a Learnset sheet.")

        func revealLearnset() {
            for _ in 0..<10 where !searchToggle.isHittable || !details.frame.contains(searchToggle.frame) {
                let below = searchToggle.frame.midY > details.frame.midY
                details.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.8 : 0.4))
                    .press(forDuration: 0.1, thenDragTo: details.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.4 : 0.8)),
                           withVelocity: .slow, thenHoldForDuration: 0.2)
                // Let scrolling settle before testing the heading's hit target.
                Thread.sleep(forTimeInterval: 0.6)
            }
            if !searchToggle.isHittable {
                let attachment = XCTAttachment(string: app.debugDescription)
                attachment.name = "Layout9-Learnset-Hierarchy"; attachment.lifetime = .keepAlways; add(attachment)
                screenshot("RRDex-Layout9-Learnset-Reveal-Failure")
            }
            XCTAssertTrue(searchToggle.isHittable)
        }
        revealLearnset()
        XCTAssertTrue(learnset.exists)
        let learnsetHeader = app.staticTexts.matching(NSPredicate(format: "label == %@", "Learnset")).firstMatch
        XCTAssertTrue(learnsetHeader.exists)
        let weaknesses = app.buttons["bound.rrdex-layout9-weaknesses"]
        XCTAssertLessThan(weaknesses.frame.minY, learnsetHeader.frame.minY,
                          "Weaknesses remains in the Evolution section above the inline Learnset.")
        XCTAssertTrue(app.staticTexts["Level-up moves match your imported save. TM/HM, tutor and egg moves keep their standard moves."].exists,
                      "Layout 9 should use the automatically loaded randomized learnset from the diagnostic save.")
        XCTAssertTrue(app.staticTexts["bound.rrdex-layout9-learnset-method-Level up"].exists)
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "bound.rrdex-layout9-learnset-move-"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "Auto-loaded randomized move data should appear in the inline list.")
        screenshot("RRDex-Layout9-Inline-Learnset")

        // Derive the term from a currently rendered randomized row; do not rely on a fixed move pool.
        let firstMoveLabel = rows.firstMatch.label
        let firstMoveName = firstMoveLabel.components(separatedBy: ",").first ?? firstMoveLabel
        let firstSearchTerm = String(firstMoveName.split(separator: " ").first ?? "")
        XCTAssertFalse(firstSearchTerm.isEmpty)

        searchToggle.tap()
        let search = app.textFields["bound.rrdex-layout9-learnset-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText(firstSearchTerm)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "A partial name from the rendered move row should match.")
        XCTAssertTrue(rows.firstMatch.label.localizedCaseInsensitiveContains(firstSearchTerm))
        app.buttons["bound.rrdex-layout9-learnset-clear"].tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "Clearing restores the randomized move rows.")

        search.typeText("zzqvnonexistentmove")
        XCTAssertTrue(app.staticTexts["bound.rrdex-layout9-learnset-empty"].waitForExistence(timeout: 5))
        app.buttons["bound.rrdex-layout9-learnset-clear"].tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        screenshot("RRDex-Layout9-Learnset-Search-Cleared")

        searchToggle.tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), "Closing inline search should hide the field.")
        XCTAssertFalse(app.buttons["bound.rrdex-layout9-learnset-clear"].exists)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "Closing search clears the filter.")

        for _ in 0..<10 where !weaknesses.isHittable || !details.frame.contains(weaknesses.frame) {
            let below = weaknesses.frame.midY > details.frame.midY
            details.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.8 : 0.4))
                .press(forDuration: 0.1, thenDragTo: details.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: below ? 0.4 : 0.8)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 0.6)
        }
        XCTAssertTrue(weaknesses.isHittable, "Weaknesses appears above the inline Learnset section.")
        XCTAssertTrue(details.frame.contains(weaknesses.frame))
        weaknesses.tap()
        XCTAssertTrue(element("bound.rrdex-matchups", in: app).waitForExistence(timeout: 10))
        app.buttons["bound.rrdex-close-detail"].tap()
        XCTAssertTrue(app.buttons["bound.rrdex-close-detail"].waitForNonExistence(timeout: 5))
        assertGamePixelsAnimate(gameScreen, in: app)

        openBoundSettings(in: app)
        for (content, wasEnabled) in originalEnabledStates {
            let toggle = app.switches["bound.companion-enabled.\(content)"]
            scrollToSetting(toggle, in: app)
            if (toggle.value as? String == "1") != wasEnabled {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
        }
        closeBoundSheet(in: app)
    }

    private func checkReferenceLayouts(_ layouts: [Int]) throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }
        let app = XCUIApplication()
        let arguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound", "--bound-ui-reset-layout"]
        app.launchArguments = arguments
        app.launch(); assertPermanentFeatureBaseline(in: app)
        func play() {
            let cell = app.collectionViews.cells.firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 20)); cell.tap()
            XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        }
        defer {
            app.terminate(); XCUIDevice.shared.orientation = .portrait
            app.launch(); assertPermanentFeatureBaseline(in: app); play(); app.terminate()
        }
        play()
        let game = element("bound.game-screen", in: app)
        let originalGame = game.frame
        let safeTop = element("bound.friend-screen", in: app).frame.minY
        func chooseBoss(_ id: String, search: String) {
            app.buttons["bound.boss-picker"].tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(search)
            let row = app.buttons["bound.boss-select-\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        }
        func assertGeometry() {
            XCTAssertEqual(game.frame.minY, originalGame.minY, accuracy: 1)
            XCTAssertEqual(game.frame.height, originalGame.height, accuracy: 1)
            let panel = element("bound.companion-container", in: app)
            XCTAssertEqual(panel.frame.minY, app.frame.minY, accuracy: 1)
            XCTAssertEqual(panel.frame.maxY, game.frame.minY, accuracy: 1)
        }
        func closeDetail() {
            let done = app.buttons["Done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
            XCTAssertTrue(done.waitForNonExistence(timeout: 5))
            assertGamePixelsAnimate(game, in: app)
        }
        func reveal(_ target: XCUIElement, in scroll: XCUIElement) {
            for _ in 0..<8 {
                if target.isHittable && scroll.frame.contains(target.frame) { return }
                scroll.swipeUp()
                // Native-menu idle waits are disabled above; let scroll deceleration
                // finish so the next tap activates the control instead of stopping it.
                Thread.sleep(forTimeInterval: 0.6)
            }
            XCTAssertTrue(target.isHittable, "Secondary details must remain reachable")
        }
        for layout in layouts {
            openBoundSettings(in: app)
            for name in ["boss", "rrdex"] {
                let picker = app.segmentedControls["bound.\(name)-layout"]
                scrollToSetting(picker, in: app)
                picker.buttons[String(layout)].tap()
            }
            closeBoundSheet(in: app)
            selectCompanion("Bosses", in: app)
            chooseBoss("kanto-leaders-4", search: "Brock")
            XCTAssertEqual(element("bound.boss-guide", in: app).value as? String, "Layout \(layout)")
            assertGeometry()
            let member = app.buttons["bound.boss-team-member-1"]
            XCTAssertTrue(member.isHittable); member.tap()
            XCTAssertTrue(member.isSelected)
            XCTAssertEqual(app.staticTexts["bound.boss-page"].label, "2 / 4")
            if layout >= 4 {
                XCTAssertGreaterThanOrEqual(member.frame.height, 43.5)
                app.buttons["bound.boss-next"].tap()
                XCTAssertEqual(app.staticTexts["bound.boss-page"].label, "3 / 4")
                app.buttons["bound.boss-previous"].tap()
                XCTAssertEqual(app.staticTexts["bound.boss-page"].label, "2 / 4")
            }
            for id in ["bound.boss-ability", "bound.boss-item"] {
                if layout >= 4 { XCTAssertGreaterThanOrEqual(app.buttons[id].frame.height, 43.5) }
                XCTAssertTrue(app.buttons[id].isHittable); app.buttons[id].tap(); closeDetail()
            }
            app.buttons["bound.boss-team-member-0"].tap()
            let matchups = app.buttons["bound.boss-weaknesses"]
            XCTAssertTrue(matchups.isHittable)
            if layout >= 3 && safeTop >= 51 {
                XCTAssertLessThanOrEqual(matchups.frame.maxY, safeTop + 1)
                XCTAssertLessThanOrEqual(matchups.frame.maxX, app.frame.midX - 78)
                let fullTeam = app.buttons["bound.boss-full-team"]
                XCTAssertGreaterThanOrEqual(fullTeam.frame.minX, app.frame.midX + 78)
                XCTAssertLessThanOrEqual(fullTeam.frame.maxY, safeTop + 1)
            }
            screenshot("Boss-layout-\(layout)-portrait")
            if layout >= 4 {
                app.buttons["bound.boss-full-team"].tap(); closeDetail()
            }
            matchups.tap()
            XCTAssertTrue(element("bound.rrdex-matchups", in: app).waitForExistence(timeout: 5))
            closeDetail()
            if layout == 4 {
                let stats = app.buttons["bound.boss-layout4-stats-toggle"]
                reveal(stats, in: element("bound.boss-details", in: app))
                XCTAssertEqual(stats.value as? String, "Collapsed")
                stats.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", "Expanded"), object: stats)], timeout: 3), .completed)
                XCTAssertTrue(element("bound.boss-layout4-stats", in: app).exists)
                screenshot("Boss-layout-4-expanded-stats")
            }
            if layout == 5 {
                let toggle = app.buttons["bound.boss-layout5-detail-toggle"]
                XCTAssertTrue(toggle.isHittable)
                XCTAssertGreaterThanOrEqual(toggle.frame.height, 43.5)
                XCTAssertEqual(toggle.value as? String, "Moves")
                toggle.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", "Stats"), object: toggle)], timeout: 3), .completed)
                XCTAssertTrue(element("bound.boss-layout5-stats", in: app).exists)
                app.buttons["bound.boss-next"].tap()
                XCTAssertEqual(toggle.value as? String, "Stats")
                screenshot("Boss-layout-5-stats")
            }
            chooseBoss("kanto-leaders-145", search: "Blaine")
            if layout == 5 {
                XCTAssertEqual(app.buttons["bound.boss-layout5-detail-toggle"].value as? String, "Moves")
            }
            XCTAssertTrue(element("bound.boss-condition-permanent-sun", in: app).exists)
            screenshot("Boss-layout-\(layout)-battle-conditions")
            if layout == 6 {
                let footerTop = app.buttons["bound.boss-next"].frame.minY
                for index in 0..<4 {
                    let move = app.staticTexts["bound.boss-move-\(index)"]
                    XCTAssertTrue(move.exists)
                    XCTAssertLessThanOrEqual(move.frame.maxY, footerTop + 1,
                                            "All four moves must remain visible beside the base stats")
                }
                for stat in ["hp", "atk", "def", "spa", "spd", "spe"] {
                    let cell = element("bound.boss-stat-\(stat)", in: app)
                    XCTAssertTrue(cell.exists)
                    XCTAssertLessThanOrEqual(cell.frame.maxY, footerTop + 1)
                }
                for index in 0..<6 {
                    let member = app.buttons["bound.boss-team-member-\(index)"]
                    XCTAssertTrue(member.isHittable)
                    XCTAssertGreaterThanOrEqual(member.frame.width, 43.5)
                    XCTAssertGreaterThanOrEqual(member.frame.minX, app.buttons["bound.boss-previous"].frame.maxX)
                    XCTAssertLessThanOrEqual(member.frame.maxX, app.buttons["bound.boss-next"].frame.minX)
                }
                app.buttons["bound.boss-team-member-5"].tap()
                XCTAssertEqual(app.staticTexts["bound.boss-page"].label, "6 / 6")
                app.buttons["bound.boss-team-member-0"].tap()
            }
            assertGeometry()

            selectCompanion("Dex", in: app)
            XCTAssertEqual(element("bound.rrdex", in: app).value as? String, "Layout \(layout)")
            if layout >= 4 { app.buttons["bound.rrdex-search-open"].tap() }
            let search = app.textFields["bound.rrdex-search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            XCTAssertTrue(search.isHittable); search.tap(); search.typeText("charizard")
            let suggestion = app.buttons["bound.rrdex-suggestion-6"]
            XCTAssertTrue(suggestion.waitForExistence(timeout: 5)); suggestion.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            assertGeometry()
            screenshot("RRDex-layout-\(layout)-portrait")
            if layout >= 5 {
                let footerTop = app.buttons["bound.rrdex-search-open"].frame.minY
                for stat in ["HP", "Atk", "Def", "SpA", "SpD", "Spe"] {
                    let cell = element("bound.rrdex-layout\(layout)-stat-\(stat)", in: app)
                    XCTAssertTrue(cell.exists)
                    XCTAssertGreaterThan(cell.frame.height, 20)
                    XCTAssertLessThanOrEqual(cell.frame.maxY, footerTop + 1,
                                            "Every base stat must be fully visible without scrolling")
                }
            }
            XCTAssertTrue(app.buttons["bound.rrdex-import"].isHittable)
            XCTAssertFalse(app.buttons["bound.rrdex-info"].exists)
            let ability = app.buttons["bound.rrdex-ability-0"]
            if layout >= 4 { XCTAssertGreaterThanOrEqual(ability.frame.height, 43.5) }
            XCTAssertTrue(ability.isHittable); ability.tap(); closeDetail()
            app.buttons["bound.rrdex-weaknesses"].tap()
            XCTAssertTrue(element("bound.rrdex-matchups", in: app).waitForExistence(timeout: 5)); closeDetail()
            app.buttons["bound.rrdex-learnset"].tap()
            XCTAssertTrue(element("bound.rrdex-moves", in: app).waitForExistence(timeout: 5)); closeDetail()
            if layout == 4 || layout == 5 {
                let details = element("bound.rrdex-layout\(layout)-details", in: app)
                let evolution = element("bound.rrdex-layout\(layout)-evolution", in: app)
                reveal(evolution, in: details)
                XCTAssertEqual(evolution.value as? String, "Collapsed")
                evolution.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", "Expanded"), object: evolution)], timeout: 3), .completed)
                XCTAssertTrue(element("bound.rrdex-evolution", in: app).exists)
                screenshot("RRDex-layout-\(layout)-expanded-evolution")
                // Search opens from the fixed footer even after scrolling down.
                app.buttons["bound.rrdex-search-open"].tap()
                XCTAssertTrue(search.waitForExistence(timeout: 5))
                XCTAssertTrue(search.isHittable)
                app.buttons["Done"].firstMatch.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            }
            if layout == 6 {
                let evolution = app.buttons["bound.rrdex-evolution-open"]
                XCTAssertTrue(evolution.isHittable)
                XCTAssertGreaterThanOrEqual(evolution.frame.height, 43.5)
                evolution.tap()
                let charmeleon = app.buttons.matching(identifier: "bound.rrdex-evolution-select-5").firstMatch
                XCTAssertTrue(charmeleon.waitForExistence(timeout: 5))
                XCTAssertGreaterThanOrEqual(charmeleon.frame.height, 43.5)
                screenshot("RRDex-layout-6-evolution")
                charmeleon.tap()
                XCTAssertTrue(charmeleon.waitForNonExistence(timeout: 5))
                assertGamePixelsAnimate(game, in: app)
                XCTAssertTrue(app.staticTexts["Charmeleon"].exists)
                app.buttons["bound.rrdex-search-open"].tap()
                XCTAssertTrue(search.waitForExistence(timeout: 5)); XCTAssertTrue(search.isHittable)
                app.buttons["Done"].firstMatch.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            }
            assertGeometry()
            if layout >= 3 {
                XCUIDevice.shared.orientation = .landscapeLeft
                waitForFrame(game) { app.frame.width > app.frame.height && $0.width > $0.height }
                if layout >= 4 { XCTAssertTrue(app.buttons["bound.rrdex-search-open"].isHittable) }
                else { XCTAssertTrue(search.isHittable) }
                screenshot("RRDex-layout-\(layout)-landscape")
                selectCompanion("Bosses", in: app)
                XCTAssertTrue(app.buttons["bound.boss-picker"].isHittable)
                screenshot("Boss-layout-\(layout)-landscape")
                XCUIDevice.shared.orientation = .portrait
                waitForFrame(game) { app.frame.height > app.frame.width && abs($0.minY - originalGame.minY) < 2 }
            }
        }
    }

    func testReferenceLayoutChoicesPersistIndependentlyInPermanentBaseline() throws {
        // Avoid Xcode 27's lost native pause-menu idle notifications; wait for real controls.
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer { for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) } }
        let app = XCUIApplication()
        let arguments = ["--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        app.launchArguments = arguments + ["--bound-ui-reset-layout"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        func play() {
            let cell = app.collectionViews.cells.firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 20)); cell.tap()
            XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        }
        defer {
            app.terminate(); app.launchArguments = arguments + ["--bound-ui-reset-layout"]
            app.launch(); assertPermanentFeatureBaseline(in: app); play(); app.terminate()
        }
        play()
        app.launchArguments = arguments
        func picker(_ name: String) -> XCUIElement { app.segmentedControls["bound.\(name)-layout"] }
        func assertChoice(_ name: String, _ number: Int) {
            let control = picker(name)
            scrollToSetting(control, in: app)
            XCTAssertTrue(control.buttons[String(number)].isSelected)
        }
        openBoundSettings(in: app)
        assertChoice("rrdex", 1); assertChoice("boss", 1)
        picker("boss").buttons["6"].tap()
        assertChoice("boss", 6); assertChoice("rrdex", 1)
        picker("rrdex").buttons["3"].tap()
        screenshot("Reference-layout-settings-independent-choices")
        closeBoundSheet(in: app)
        selectCompanion("Bosses", in: app)
        XCTAssertEqual(element("bound.boss-guide", in: app).value as? String, "Layout 6")
        selectCompanion("Dex", in: app)
        XCTAssertEqual(element("bound.rrdex", in: app).value as? String, "Layout 3")

        app.terminate(); app.launch(); play()
        openBoundSettings(in: app)
        assertChoice("boss", 6); assertChoice("rrdex", 3)
        closeBoundSheet(in: app)
        selectCompanion("Bosses", in: app)
        XCTAssertEqual(element("bound.boss-guide", in: app).value as? String, "Layout 6")
        selectCompanion("Dex", in: app)
        XCTAssertEqual(element("bound.rrdex", in: app).value as? String, "Layout 3")

        openBoundSettings(in: app)
        scrollToSetting(picker("boss"), in: app)
        picker("boss").buttons["3"].tap()
        scrollToSetting(picker("rrdex"), in: app)
        picker("rrdex").buttons["6"].tap()
        closeBoundSheet(in: app)
        app.terminate(); app.launch(); assertPermanentFeatureBaseline(in: app); play()
        openBoundSettings(in: app)
        assertChoice("boss", 3); assertChoice("rrdex", 6)
        closeBoundSheet(in: app)
        selectCompanion("Friend", in: app)
        for expected in ["Notes", "Types", "Bosses", "Dex", "Friend"] {
            app.buttons["bound.panel-cycle"].tap()
            XCTAssertEqual(app.buttons["bound.panel-cycle"].value as? String, expected)
        }
        openBoundSettings(in: app)
        scrollToSetting(picker("boss"), in: app)
        picker("boss").buttons["1"].tap()
        scrollToSetting(picker("rrdex"), in: app)
        picker("rrdex").buttons["1"].tap()
        closeBoundSheet(in: app)
    }

    func testPortraitBossAndRRDexCardsUseFullScreenWidthWithoutScalingSprites() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-screen-layout-bound", "--bound-ui-reset-layout", "--bound-ui-friend-fixture", "--bound-ui-no-animations"]
        app.launch()
        assertPermanentFeatureBaseline(in: app)
        defer {
            app.terminate()
            app.launch()
            assertPermanentFeatureBaseline(in: app)
        }

        let gameCell = app.collectionViews.cells.firstMatch
        XCTAssertTrue(gameCell.waitForExistence(timeout: 20))
        gameCell.tap()
        let cycle = app.buttons["bound.panel-cycle"]
        XCTAssertTrue(cycle.waitForExistence(timeout: 15))
        let game = element("bound.game-screen", in: app)
        XCTAssertTrue(game.waitForExistence(timeout: 10))
        let friend = element("bound.friend-screen", in: app)
        XCTAssertTrue(friend.waitForExistence(timeout: 10))
        let screenFrame = app.frame
        XCTAssertGreaterThan(screenFrame.width, 100)
        let safeContentTop = friend.frame.minY
        let panel = element("bound.companion-container", in: app)
        screenshot("Portrait-full-screen-width-reference")

        cycle.tap() // Notes
        cycle.tap() // Types
        cycle.tap() // Bosses
        XCTAssertEqual(cycle.value as? String, "Bosses")
        let bossGuide = element("bound.boss-guide", in: app)
        XCTAssertTrue(bossGuide.waitForExistence(timeout: 10))
        XCTAssertEqual(bossGuide.frame.minX, screenFrame.minX, accuracy: 2)
        XCTAssertEqual(bossGuide.frame.maxX, screenFrame.maxX, accuracy: 2)
        XCTAssertEqual(panel.frame.minY, screenFrame.minY, accuracy: 2)
        XCTAssertEqual(panel.frame.maxY, game.frame.minY, accuracy: 2)
        XCTAssertEqual(bossGuide.frame.minY, safeContentTop, accuracy: 2)
        XCTAssertEqual(bossGuide.frame.maxY, game.frame.minY, accuracy: 2)
        let bossPicker = app.buttons["bound.boss-picker"]
        let bossCap = app.staticTexts["bound.boss-cap"]
        let bossPicture = element("bound.boss-picture", in: app)
        XCTAssertTrue(bossPicker.isHittable)
        XCTAssertGreaterThanOrEqual(bossPicker.frame.minY, safeContentTop)
        XCTAssertTrue(bossCap.exists)
        let referenceHeaderTop = bossCap.frame.minY
        XCTAssertTrue(bossPicture.waitForExistence(timeout: 5))
        XCTAssertEqual(bossPicker.frame.minX, screenFrame.minX + 12, accuracy: 2)
        XCTAssertEqual(bossPicker.frame.maxX, screenFrame.maxX - 12, accuracy: 2)
        XCTAssertGreaterThanOrEqual(bossCap.frame.minX, screenFrame.minX + 10)
        XCTAssertLessThanOrEqual(bossCap.frame.maxX, screenFrame.maxX - 10)
        XCTAssertGreaterThanOrEqual(bossPicker.frame.width, screenFrame.width - 28,
                                    "The boss picker should span the full-screen card inside its 12 pt side padding")
        XCTAssertEqual(bossPicker.frame.midX, screenFrame.midX, accuracy: 2)
        XCTAssertEqual(bossPicture.frame.width, 46, accuracy: 2,
                        "The boss sprite should retain its normal portrait size")
        XCTAssertEqual(bossPicture.frame.height, 46, accuracy: 2,
                        "The boss sprite should retain its normal portrait size")
        XCTAssertLessThanOrEqual(game.frame.minY - app.buttons["bound.boss-next"].frame.maxY, 12,
                                 "The arrow glyph should sit close to gameplay inside its lowered navigation row")
        XCTAssertLessThanOrEqual(game.frame.minY - app.buttons["bound.boss-full-team"].frame.maxY, 14)
        screenshot("Portrait-boss-card-full-width")
        app.buttons["bound.boss-full-team"].tap()
        let fullTeam = element("bound.boss-full-team-list", in: app)
        XCTAssertTrue(fullTeam.waitForExistence(timeout: 10))
        app.buttons["bound.boss-close-full-team"].tap()
        XCTAssertTrue(fullTeam.waitForNonExistence(timeout: 10))
        assertGamePixelsAnimate(game, in: app)

        cycle.tap() // Dex
        XCTAssertEqual(cycle.value as? String, "Dex")
        let dex = element("bound.rrdex", in: app)
        XCTAssertTrue(dex.waitForExistence(timeout: 10))
        XCTAssertEqual(dex.frame.minX, screenFrame.minX, accuracy: 2)
        XCTAssertEqual(dex.frame.maxX, screenFrame.maxX, accuracy: 2)
        XCTAssertEqual(panel.frame.minY, screenFrame.minY, accuracy: 2)
        XCTAssertEqual(panel.frame.maxY, game.frame.minY, accuracy: 2)
        XCTAssertGreaterThanOrEqual(dex.frame.minY, screenFrame.minY)
        XCTAssertLessThanOrEqual(dex.frame.minY, safeContentTop)
        XCTAssertEqual(dex.frame.maxY, game.frame.minY, accuracy: 2)
        let search = app.textFields["bound.rrdex-search"]
        let dexPicture = element("bound.rrdex-picture", in: app)
        XCTAssertTrue(search.exists)
        XCTAssertGreaterThanOrEqual(app.buttons["bound.rrdex-import"].frame.minY, safeContentTop)
        XCTAssertEqual(app.buttons["bound.rrdex-import"].frame.minY, referenceHeaderTop, accuracy: 8,
                       "Closing Full team must preserve the Dynamic Island clearance for the next panel")
        XCTAssertTrue(dexPicture.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(search.frame.width, screenFrame.width - 80,
                                    "The Dex search field should remain full-width at normal text size")
        XCTAssertGreaterThanOrEqual(search.frame.minX, screenFrame.minX + 12)
        XCTAssertEqual(search.frame.maxX, screenFrame.maxX - 21, accuracy: 3,
                        "The search field should end at the standard card and search-row insets")
        XCTAssertEqual(dexPicture.frame.width, 58, accuracy: 2,
                       "The Dex sprite should retain its normal portrait size")
        XCTAssertEqual(dexPicture.frame.height, 58, accuracy: 2,
                       "The Dex sprite should retain its normal portrait size")
        let weaknesses = app.buttons["bound.rrdex-weaknesses"]
        let learnset = app.buttons["bound.rrdex-learnset"]
        for identifier in ["bound.rrdex-import", "bound.rrdex-weaknesses", "bound.rrdex-learnset"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.isHittable, "\(identifier) must remain tappable in the full-width portrait card")
            XCTAssertGreaterThanOrEqual(control.frame.minX, screenFrame.minX + 10)
            XCTAssertLessThanOrEqual(control.frame.maxX, screenFrame.maxX - 10)
        }
        let dexContentWidth = learnset.frame.maxX - weaknesses.frame.minX
        XCTAssertGreaterThanOrEqual(dexContentWidth, screenFrame.width - 28,
                                    "Dex detail buttons should span the full-screen card inside its 12 pt side padding")
        XCTAssertEqual(weaknesses.frame.minX, screenFrame.minX + 12, accuracy: 2)
        XCTAssertEqual(learnset.frame.maxX, screenFrame.maxX - 12, accuracy: 2)
        XCTAssertEqual((learnset.frame.maxX + weaknesses.frame.minX) / 2, screenFrame.midX, accuracy: 2)
        if safeContentTop - screenFrame.minY >= 51 {
            XCTAssertLessThanOrEqual(weaknesses.frame.maxX, screenFrame.midX - 80 + 2)
            XCTAssertGreaterThanOrEqual(learnset.frame.minX, screenFrame.midX + 80 - 2)
            for control in [weaknesses, learnset] {
                XCTAssertGreaterThanOrEqual(control.frame.minY, screenFrame.minY)
                XCTAssertLessThanOrEqual(control.frame.maxY, safeContentTop)
                XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            }
        }
        screenshot("Portrait-rrdex-card-full-width")
        app.buttons["bound.rrdex-weaknesses"].tap()
        let matchups = element("bound.rrdex-matchups", in: app)
        XCTAssertTrue(matchups.waitForExistence(timeout: 10))
        app.buttons["bound.rrdex-close-detail"].tap()
        XCTAssertTrue(matchups.waitForNonExistence(timeout: 10))
        assertGamePixelsAnimate(game, in: app)
        learnset.tap()
        let moves = element("bound.rrdex-moves", in: app)
        XCTAssertTrue(moves.waitForExistence(timeout: 10))
        app.buttons["bound.rrdex-close-detail"].tap()
        XCTAssertTrue(moves.waitForNonExistence(timeout: 10))
        assertGamePixelsAnimate(game, in: app)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func assertSettingsCloseAtTop(in app: XCUIApplication, navigationTitle: String? = nil,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let close = app.buttons["bound.settings-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertFalse(element("bound.settings-footer", in: app).exists,
                        "Settings should not render a bottom Done footer.", file: file, line: line)

        let navigationBar: XCUIElement
        if let navigationTitle {
            navigationBar = app.navigationBars[navigationTitle]
        } else {
            navigationBar = app.navigationBars.allElementsBoundByIndex
                .filter { $0.isHittable }.last ?? app.navigationBars.firstMatch
        }
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(close.isHittable, "Top-bar Done must remain tappable.", file: file, line: line)
        XCTAssertTrue(navigationBar.frame.intersects(close.frame),
                      "Done belongs in the active native navigation bar.", file: file, line: line)
        XCTAssertLessThan(close.frame.midY, app.frame.minY + app.frame.height * 0.20,
                          "Done should remain at the top of the settings window.", file: file, line: line)
    }

    private func assertSettingsContentVisible(_ target: XCUIElement, in app: XCUIApplication, name: String,
                                              searchTowardTop: Bool = false) {
        assertSettingsCloseAtTop(in: app)
        for _ in 0..<30 {
            let navigationBottom = app.navigationBars.allElementsBoundByIndex
                .filter { $0.isHittable }.map { $0.frame.maxY }.max() ?? app.frame.minY
            if target.exists && target.isHittable && target.frame.minY >= navigationBottom &&
                target.frame.maxY <= app.frame.maxY - 8 { break }
            dragSettingsContent(towardTop: target.exists ? target.frame.minY < navigationBottom : searchTowardTop, in: app)
        }
        screenshot(name)
        assertSettingsElementVisible(target, in: app)
    }

    private func dragSettingsContent(towardTop: Bool, in app: XCUIApplication) {
        // Drag the visible content between the native navigation bar and the screen's bottom safe area.
        let frame = app.frame
        let bottom = frame.maxY - 16
        let navigationBottom = app.navigationBars.allElementsBoundByIndex
            .filter { $0.frame.intersects(frame) }.map { $0.frame.maxY }.max() ?? frame.minY
        let top = min(navigationBottom, bottom - 44)
        let startY = top + (bottom - top) * (towardTop ? 0.35 : 0.75)
        let endY = top + (bottom - top) * (towardTop ? 0.75 : 0.35)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: frame.width / 2, dy: startY - frame.minY))
        let end = origin.withOffset(CGVector(dx: frame.width / 2, dy: endY - frame.minY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    private func assertSettingsElementVisible(_ target: XCUIElement, in app: XCUIApplication,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let navigationBottom = app.navigationBars.allElementsBoundByIndex
            .filter { $0.isHittable }.map { $0.frame.maxY }.max() ?? app.frame.minY
        XCTAssertTrue(target.exists, file: file, line: line)
        XCTAssertTrue(target.isHittable, "Settings content must remain hittable below the navigation bar.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(target.frame.minY, navigationBottom - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(target.frame.maxY, app.frame.maxY,
                                 "Settings content must remain inside the app window.", file: file, line: line)
    }

    // Short Form drags avoid jumping past a lazily materialized row in landscape.
    private func scrollToSetting(_ target: XCUIElement, in app: XCUIApplication, fullyVisible: Bool = true) {
        let form = app.collectionViews.firstMatch
        for _ in 0..<40 {
            let bottom = form.frame.maxY - 24
            if target.exists && target.isHittable && (!fullyVisible ||
                target.frame.minY >= form.frame.minY + 8 && target.frame.maxY <= bottom) { return }
            let scrollDown = target.exists && target.frame.midY < form.frame.midY
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollDown ? 0.35 : 0.80))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollDown ? 0.65 : 0.50))
            // Gameplay tests skip quiescence, so finish the scroll without a
            // fling that could consume the next tap on a setting.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
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
        XCTAssertTrue(app.buttons["Settings"].exists)
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
            XCTAssertFalse(app.buttons["Settings"].exists)
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
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        let about = element("bound.settings-about", in: app)
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()
        XCTAssertTrue(app.buttons["bound.source-and-licenses-link"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["Menu Button Gestures"].exists)
        screenshot("Bound-settings-over-native-pause")
        app.buttons["bound.settings-close"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        resumeNativePause(in: app)
        XCTAssertFalse(app.buttons["Settings"].exists)
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
            XCTAssertFalse(app.buttons["Settings"].exists)
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
        XCTAssertFalse(app.buttons["Settings"].exists)
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
                        XCTAssertFalse(app.buttons["Settings"].exists)
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
                    XCTAssertFalse(app.buttons["Settings"].exists)
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
        XCTAssertEqual(mode.label, "OFF")
        XCTAssertEqual(mode.value as? String, "OFF")
        XCTAssertTrue(app.frame.contains(mode.frame))
        for label in ["Save State", "Load State", "Cheat Codes", "Fast Forward", "Connect", "Settings"] {
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
        for _ in 0..<3 { mode.tap() }
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
        XCTAssertTrue(element("bound.ui-version", in: app).exists)
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
        XCTAssertTrue(app.buttons["Settings"].isHittable)
        resumeNativePause(in: app)
        XCUIDevice.shared.orientation = .portrait
        openBoundSettings(in: app)
        XCTAssertTrue(element("bound.ui-version", in: app).waitForExistence(timeout: 10))
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
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(element("bound.settings-root", in: app).waitForExistence(timeout: 10))
        for identifier in ["bound.settings-controls", "bound.settings-audio",
                           "bound.settings-account", "bound.settings-about"] {
            XCTAssertTrue(element(identifier, in: app).exists, "Release settings should include \(identifier).")
        }
        XCTAssertFalse(element("bound.settings-interface", in: app).exists)
        XCTAssertFalse(element("bound.settings-general", in: app).exists)
        XCTAssertFalse(app.switches["bound.experimental-settings"].exists)
        XCTAssertFalse(app.switches["bound.enable-experimental-features"].exists)
        XCTAssertFalse(app.staticTexts["Patreon"].exists)

        element("bound.settings-about", in: app).tap()
        XCTAssertTrue(app.buttons["bound.source-and-licenses-link"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Build entry"].exists)
        XCTAssertFalse(app.staticTexts["Engine Source"].exists)
        XCTAssertFalse(app.staticTexts["Package Identifier"].exists)
        XCTAssertFalse(app.staticTexts["Experimental"].exists)
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
        app.buttons["bound.settings-close"].tap()

        settings.tap()
        element("bound.settings-account", in: app).tap()
        XCTAssertTrue(app.navigationBars["Account & Sync"].waitForExistence(timeout: 5))
        let deltaSync = element("bound.delta-sync-settings", in: app)
        XCTAssertTrue(deltaSync.waitForExistence(timeout: 5))
        deltaSync.tap()
        let dropbox = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Dropbox")).firstMatch
        XCTAssertTrue(dropbox.waitForExistence(timeout: 10), "Release settings retain the configured Dropbox provider entry.")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Google Drive")).firstMatch.exists,
                       "Google Drive is not offered by Bound's sync settings.")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["bound.settings-close"].tap()

        // A generated game is imported by the fixture setup, never a personal ROM.
        let cell = app.collectionViews.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20)); cell.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
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

extension CompanionUITests {
    func testLandscapeMultiviewArrangementLayerControlsAndFriendEdgePlacement() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            XCUIDevice.shared.orientation = .portrait
            for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) }
        }

        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture",
                                       "--bound-ui-no-animations", "--bound-ui-screen-layout-bound",
                                       "-bound.delta.pip.v1.dex.layout", "12"])
        func chooseOption(_ number: Int) {
            openBoundSettings(in: app)
            let options = element("bound.landscape-options", in: app)
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            options.tap()
            app.buttons["Option \(number)"].firstMatch.tap()
            closeBoundSheet(in: app)
        }
        func beginArrangement(_ prefix: String) {
            openNativePause(in: app)
            let arrange = app.buttons["bound.menu-arrange-views"]
            XCTAssertTrue(arrange.waitForExistence(timeout: 5))
            arrange.tap()
            XCTAssertTrue(app.buttons[prefix + "-done"].waitForExistence(timeout: 10))
        }
        func assertLayer(_ prefix: String, _ content: String, front: Bool) {
            let frontButton = app.buttons[prefix + "-layer-front." + content]
            let backButton = app.buttons[prefix + "-layer-back." + content]
            XCTAssertTrue(frontButton.waitForExistence(timeout: 5))
            XCTAssertTrue(backButton.waitForExistence(timeout: 5))
            XCTAssertEqual(frontButton.isSelected, front, "Front arrow should reflect the selected view's layer")
            XCTAssertEqual(backButton.isSelected, !front, "Back arrow should reflect the selected view's layer")
        }
        func move(_ target: XCUIElement, centerX: CGFloat, centerY: CGFloat) {
            let frame = target.frame
            let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: centerX - frame.midX,
                                                              dy: centerY - frame.midY)))
        }
        func verifyOption(_ option: Int) {
            let prefix = "bound.landscape\(option)"
            beginArrangement(prefix)
            let friend = element(prefix + "-move.friend", in: app)
            let multiview = element(prefix + "-move.dex", in: app)
            XCTAssertTrue(friend.waitForExistence(timeout: 5))
            XCTAssertTrue(multiview.waitForExistence(timeout: 5))

            friend.tap()
            XCTAssertTrue(friend.isSelected)
            XCTAssertTrue(app.buttons[prefix + "-layer-front.dex"].waitForNonExistence(timeout: 3),
                          "Layer arrows should only appear for the selected panel")
            app.buttons[prefix + "-layer-front.friend"].tap()
            assertLayer(prefix, "friend", front: true)

            // Friend is not covered by emulator controls, so its panel can reach all four screen edges.
            let screen = app.frame
            move(friend, centerX: screen.minX + friend.frame.width / 2 - 20,
                 centerY: screen.minY + friend.frame.height / 2 - 20)
            XCTAssertEqual(friend.frame.minX, screen.minX, accuracy: 2)
            XCTAssertEqual(friend.frame.minY, screen.minY, accuracy: 2)
            screenshot("Landscape-option\(option)-friend-at-top-left-front")

            app.buttons[prefix + "-layer-back.friend"].tap()
            assertLayer(prefix, "friend", front: false)
            screenshot("Landscape-option\(option)-friend-at-top-left-behind")
            move(friend, centerX: screen.maxX - friend.frame.width / 2 + 20,
                 centerY: screen.maxY - friend.frame.height / 2 + 20)
            XCTAssertEqual(friend.frame.maxX, screen.maxX, accuracy: 2)
            XCTAssertEqual(friend.frame.maxY, screen.maxY, accuracy: 2)
            screenshot("Landscape-option\(option)-friend-at-bottom-right-behind")

            multiview.tap()
            XCTAssertTrue(multiview.isSelected)
            XCTAssertTrue(app.buttons[prefix + "-layer-front.friend"].waitForNonExistence(timeout: 3),
                          "Friend layer arrows should disappear when Multiview is selected")
            app.buttons[prefix + "-layer-front.dex"].tap()
            assertLayer(prefix, "dex", front: true)
            app.buttons[prefix + "-layer-back.dex"].tap()
            assertLayer(prefix, "dex", front: false)
            app.buttons[prefix + "-layer-front.dex"].tap()
            assertLayer(prefix, "dex", front: true)

            // The shared Multiview remains inside its usual safe placement area while its layer
            // controls decide whether it draws over native landscape buttons.
            let menu = app.descendants(matching: .any).matching(identifier: "bound.native-menu").firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            let multiFrame = multiview.frame
            move(multiview, centerX: menu.frame.midX, centerY: menu.frame.midY)
            let menuOverlap = multiview.frame.intersection(menu.frame)
            XCTAssertGreaterThan(menuOverlap.width * menuOverlap.height, 0,
                                 "Multiview should overlap the native Menu button area")
            XCTAssertGreaterThanOrEqual(multiview.frame.minX, screen.minX)
            XCTAssertGreaterThanOrEqual(multiview.frame.minY, screen.minY)
            XCTAssertLessThanOrEqual(multiview.frame.maxX, screen.maxX)
            XCTAssertLessThanOrEqual(multiview.frame.maxY, screen.maxY)
            XCTAssertGreaterThan(multiview.frame.width, 0)
            XCTAssertGreaterThan(multiFrame.width, 0)
            let frontMultiviewFrame = multiview.frame
            screenshot("Landscape-option\(option)-multiview-over-menu-front")
            app.buttons[prefix + "-done"].tap()
            XCTAssertTrue(app.buttons[prefix + "-done"].waitForNonExistence(timeout: 5))

            let viewsToggle = app.buttons[prefix + "-views-button"]
            XCTAssertTrue(viewsToggle.waitForExistence(timeout: 5))
            let toggleOverlap = viewsToggle.frame.intersection(frontMultiviewFrame)
            XCTAssertGreaterThan(toggleOverlap.width * toggleOverlap.height, 0,
                                 "The front Multiview should overlap the companion Views toggle")
            viewsToggle.tap()
            XCTAssertEqual(viewsToggle.label, "Show multiview")
            XCTAssertTrue(element(prefix + "-reference-content", in: app).waitForNonExistence(timeout: 5))
            viewsToggle.tap()
            XCTAssertEqual(viewsToggle.label, "Hide multiview")
            XCTAssertTrue(element(prefix + "-reference-content", in: app).waitForExistence(timeout: 5))

            // Reopening Arrange View must work through native Menu while Multiview is still in front.
            beginArrangement(prefix)
            multiview.tap()
            XCTAssertTrue(multiview.isSelected)
            app.buttons[prefix + "-layer-back.dex"].tap()
            assertLayer(prefix, "dex", front: false)
            screenshot("Landscape-option\(option)-multiview-over-menu-behind")
            app.buttons[prefix + "-done"].tap()
            XCTAssertTrue(app.buttons[prefix + "-done"].waitForNonExistence(timeout: 5))

            // With both panels saved behind the controller, Multiview must still route
            // gestures inside its content while native controls remain on top.
            if option == 7 {
                let docs = app.buttons[prefix + "-tab-bosses"]
                let dex = app.buttons[prefix + "-tab-dex"]
                XCTAssertTrue(docs.waitForExistence(timeout: 5))
                XCTAssertTrue(dex.waitForExistence(timeout: 5))
                docs.tap()
                XCTAssertTrue(docs.isSelected)
                dex.tap()
                XCTAssertTrue(dex.isSelected)
            }
            let referenceContent = element(prefix + "-reference-content", in: app)
            let dexFooter = app.staticTexts["bound.rrdex-reference-rom"]
            XCTAssertTrue(referenceContent.waitForExistence(timeout: 5))
            XCTAssertTrue(dexFooter.waitForExistence(timeout: 5))
            let footerAtTop = dexFooter.frame.minY
            let scrollStart = referenceContent.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.82))
            let scrollEnd = referenceContent.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.30))
            scrollStart.press(forDuration: 0.05, thenDragTo: scrollEnd,
                              withVelocity: .slow, thenHoldForDuration: 0.1)
            let footerMoved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                dexFooter.frame.minY < footerAtTop - 5
            }, object: dexFooter)
            wait(for: [footerMoved], timeout: 5)
            screenshot("Landscape-option\(option)-multiview-background-scroll")

            let restoreStart = referenceContent.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.30))
            let restoreEnd = referenceContent.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.82))
            restoreStart.press(forDuration: 0.05, thenDragTo: restoreEnd,
                               withVelocity: .slow, thenHoldForDuration: 0.1)
            let footerRestored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                abs(dexFooter.frame.minY - footerAtTop) < 10
            }, object: dexFooter)
            wait(for: [footerRestored], timeout: 5)

            viewsToggle.tap()
            XCTAssertEqual(viewsToggle.label, "Show multiview")
            XCTAssertTrue(element(prefix + "-reference-content", in: app).waitForNonExistence(timeout: 5))
            viewsToggle.tap()
            XCTAssertEqual(viewsToggle.label, "Hide multiview")
            XCTAssertTrue(element(prefix + "-reference-content", in: app).waitForExistence(timeout: 5))

            beginArrangement(prefix)
            friend.tap()
            assertLayer(prefix, "friend", front: false)
            multiview.tap()
            assertLayer(prefix, "dex", front: false)
            app.buttons[prefix + "-done"].tap()
            XCTAssertTrue(app.buttons[prefix + "-done"].waitForNonExistence(timeout: 5))
        }

        chooseOption(6)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["bound.landscape6-views-button"].waitForExistence(timeout: 10))
        verifyOption(6)

        chooseOption(7)
        XCTAssertTrue(element("bound.landscape7-tabs", in: app).waitForExistence(timeout: 10))
        verifyOption(7)
    }

    func testLandscapeArrangementGeometryIsIndependentByControllerMode() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            XCUIDevice.shared.orientation = .portrait
            for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) }
        }

        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture",
                                       "--bound-ui-no-animations", "--bound-ui-screen-layout-bound",
                                       "-bound.delta.pip.v1.dex.layout", "12"])
        func assertFrame(_ actual: CGRect, matches expected: CGRect, accuracy: CGFloat = 2) {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy)
            XCTAssertEqual(actual.width, expected.width, accuracy: accuracy)
            XCTAssertEqual(actual.height, expected.height, accuracy: accuracy)
        }
        func chooseOption7() {
            openBoundSettings(in: app)
            let options = element("bound.landscape-options", in: app)
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            options.tap(); app.buttons["Option 7"].firstMatch.tap()
            closeBoundSheet(in: app)
        }
        func setControllerMode(_ enabled: Bool) {
            openNativePause(in: app)
            let mode = app.buttons["bound.controller-mode"]
            XCTAssertTrue(mode.waitForExistence(timeout: 5))
            let expected = enabled ? "On" : "Off"
            for _ in 0..<4 where (mode.value as? String) != expected { mode.tap() }
            XCTAssertEqual(mode.value as? String, expected)
            resumeNativePause(in: app)
        }
        func arrangeDexAndResize(heightDelta: CGFloat) -> CGRect {
            openNativePause(in: app)
            let arrange = app.buttons["bound.menu-arrange-views"]
            XCTAssertTrue(arrange.waitForExistence(timeout: 5)); arrange.tap()
            let prefix = "bound.landscape7"
            let move = element(prefix + "-move.dex", in: app)
            XCTAssertTrue(move.waitForExistence(timeout: 5))
            let before = move.frame
            let handle = element(prefix + "-resize-height.dex", in: app)
            XCTAssertTrue(handle.waitForExistence(timeout: 5))
            if heightDelta != 0 {
                let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(forDuration: 0.05,
                            thenDragTo: start.withOffset(CGVector(dx: 0, dy: heightDelta)))
            }
            let after = move.frame
            if heightDelta != 0 {
                XCTAssertGreaterThan(abs(after.height - before.height), 12,
                                     "Dragging the height handle should change the saved panel geometry.")
            }
            app.buttons[prefix + "-done"].tap()
            return after
        }

        chooseOption7()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(element("bound.landscape7-tabs", in: app).waitForExistence(timeout: 10))
        app.buttons["bound.landscape7-tab-dex"].tap()
        XCTAssertEqual(element("bound.landscape7-reference-content", in: app).value as? String, "RR Dex")
        setControllerMode(false)

        let controllerModeOffFrame = arrangeDexAndResize(heightDelta: -28)
        setControllerMode(true)
        let modeOnInherited = arrangeDexAndResize(heightDelta: 28)
        XCTAssertGreaterThan(abs(modeOnInherited.height - controllerModeOffFrame.height), 24,
                             "Controller Mode on must keep its own edited height.")

        setControllerMode(false)
        let restoredOffFrame = arrangeDexAndResize(heightDelta: 0)
        assertFrame(restoredOffFrame, matches: controllerModeOffFrame)
        setControllerMode(true)
        let restoredOnFrame = arrangeDexAndResize(heightDelta: 0)
        assertFrame(restoredOnFrame, matches: modeOnInherited)

        app.terminate()
        app.launchArguments = app.launchArguments.filter { $0 != "--bound-ui-reset-layout" }
        app.launch()
        let diagnostic = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 20))
        diagnostic.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(element("bound.landscape7-tabs", in: app).waitForExistence(timeout: 15))
        setControllerMode(true)
        openNativePause(in: app)
        let arrange = app.buttons["bound.menu-arrange-views"]
        XCTAssertTrue(arrange.waitForExistence(timeout: 5)); arrange.tap()
        assertFrame(element("bound.landscape7-move.dex", in: app).frame, matches: modeOnInherited)
        app.buttons["bound.landscape7-done"].tap()
    }

    func testLandscapeOption7FixedTabsAndIndependentLayout() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            XCUIDevice.shared.orientation = .portrait
            for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) }
        }
        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture",
                                       "-bound.delta.pip.v1.dex.layout", "12",
                                       "-bound.delta.pip.v1.bosses.layout", "12"])
        let bound = app.buttons["bound.panel-cycle"]
        let portraitButton = bound.frame
        let portraitSelection = bound.value as? String
        func chooseOption(_ number: Int) {
            openBoundSettings(in: app)
            let options = element("bound.landscape-options", in: app)
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            options.tap(); app.buttons["Option \(number)"].firstMatch.tap()
            closeBoundSheet(in: app)
        }
        func beginArrangement(_ prefix: String) {
            openNativePause(in: app)
            let arrange = app.buttons["bound.menu-arrange-views"]
            XCTAssertTrue(arrange.waitForExistence(timeout: 5)); arrange.tap()
            XCTAssertTrue(app.buttons[prefix + "-done"].waitForExistence(timeout: 5))
        }
        func assertFrame(_ actual: CGRect, matches expected: CGRect) {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 2)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 2)
            XCTAssertEqual(actual.width, expected.width, accuracy: 2)
            XCTAssertEqual(actual.height, expected.height, accuracy: 2)
        }

        chooseOption(6)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["bound.landscape6-views-button"].waitForExistence(timeout: 10))
        let toggleFrame = app.buttons["bound.landscape6-views-button"].frame
        beginArrangement("bound.landscape6")
        let originalOption6 = element("bound.landscape6-move.dex", in: app).frame
        let heightHandle = element("bound.landscape6-resize-height.dex", in: app)
        let heightStart = heightHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        heightStart.press(forDuration: 0.05, thenDragTo: heightStart.withOffset(CGVector(dx: 0, dy: -12)))
        let option6Frame = element("bound.landscape6-move.dex", in: app).frame
        XCTAssertLessThan(option6Frame.height, originalOption6.height)
        app.buttons["bound.landscape6-done"].tap()

        chooseOption(7)
        let prefix = "bound.landscape7"
        let reference = element(prefix + "-reference-content", in: app)
        let tabs = element(prefix + "-tabs", in: app)
        let toggle = app.buttons[prefix + "-views-button"]
        let menu = element("bound.native-menu", in: app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        XCTAssertTrue(bound.waitForNonExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Hide multiview")
        assertFrame(toggle.frame, matches: toggleFrame)
        XCTAssertGreaterThan(toggle.frame.midY, menu.frame.midY)
        let tabFrame = tabs.frame
        let bodyFrame = reference.frame
        XCTAssertEqual(tabFrame.height, 44, accuracy: 1)
        XCTAssertEqual(bodyFrame.minY, tabFrame.maxY, accuracy: 1)
        assertFrame(tabFrame.union(bodyFrame), matches: option6Frame)
        for (id, title) in [("dex", "DEX"), ("bosses", "DOCS"), ("types", "TYPES")] {
            let tab = app.buttons[prefix + "-tab-" + id]
            XCTAssertEqual(tab.label, title)
            XCTAssertTrue(tab.isHittable)
            XCTAssertGreaterThanOrEqual(tab.frame.width, 44)
            XCTAssertEqual(tab.frame.height, 44, accuracy: 1)
        }
        func chooseTab(_ id: String, title: String, identifier: String) {
            let tab = app.buttons[prefix + "-tab-" + id]
            tab.tap()
            XCTAssertEqual(reference.value as? String, title)
            XCTAssertTrue(tab.isSelected)
            XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 5))
            assertFrame(tabs.frame, matches: tabFrame)
            assertFrame(reference.frame, matches: bodyFrame)
        }

        chooseTab("dex", title: "RR Dex", identifier: "bound.rrdex")
        reference.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8))
            .press(forDuration: 0.05,
                   thenDragTo: reference.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.8)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertEqual(reference.value as? String, "RR Dex", "Option 7 uses tabs instead of page swipes.")
        screenshot("Landscape-option7-DEX-tabs")
        chooseTab("bosses", title: "Bosses", identifier: "bound.boss-guide")
        let bossDetails = app.scrollViews["bound.boss-details"]
        XCTAssertTrue(bossDetails.waitForExistence(timeout: 5))
        let move = app.staticTexts["bound.boss-move-0"]
        let moveBeforeScroll = move.frame
        bossDetails.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
            .press(forDuration: 0.05,
                   thenDragTo: bossDetails.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertLessThan(move.frame.minY, moveBeforeScroll.minY - 5)
        assertFrame(tabs.frame, matches: tabFrame)
        XCTAssertTrue(app.buttons[prefix + "-tab-bosses"].isSelected)
        screenshot("Landscape-option7-DOCS-fixed-tabs-after-scroll")
        chooseTab("types", title: "Types", identifier: "bound.type-chart")
        screenshot("Landscape-option7-TYPES-tabs")
        toggle.tap()
        XCTAssertTrue(tabs.waitForNonExistence(timeout: 5))
        XCTAssertFalse(reference.exists)
        XCTAssertEqual(toggle.label, "Show multiview")
        XCTAssertTrue(element(prefix + "-friend", in: app).exists)
        toggle.tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[prefix + "-tab-types"].isSelected)
        assertFrame(tabs.frame.union(reference.frame), matches: option6Frame)

        beginArrangement(prefix)
        let widthHandle = element(prefix + "-resize-width.types", in: app)
        let widthStart = widthHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        widthStart.press(forDuration: 0.05, thenDragTo: widthStart.withOffset(CGVector(dx: -20, dy: 0)))
        let option7Frame = element(prefix + "-move.types", in: app).frame
        XCTAssertLessThan(option7Frame.width, option6Frame.width)
        app.buttons[prefix + "-done"].tap()
        chooseOption(6)
        XCTAssertFalse(tabs.exists)
        beginArrangement("bound.landscape6")
        assertFrame(element("bound.landscape6-move.dex", in: app).frame, matches: option6Frame)
        app.buttons["bound.landscape6-done"].tap()
        chooseOption(7)
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[prefix + "-tab-types"].isSelected)
        // Hidden retained reference pages keep their old viewport. Their AX
        // union can exceed the visible frame after resizing another page.
        assertFrame(tabs.frame, matches: CGRect(x: option7Frame.minX, y: option7Frame.minY,
                                               width: option7Frame.width, height: 44))
        beginArrangement(prefix)
        assertFrame(element(prefix + "-move.types", in: app).frame, matches: option7Frame)
        app.buttons[prefix + "-done"].tap()
        assertGamePixelsAnimate(element("bound.game-screen", in: app), in: app)

        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[prefix + "-tab-dex"].isHittable)
        XCTAssertTrue(app.buttons[prefix + "-tab-bosses"].isHittable)
        XCTAssertTrue(app.buttons[prefix + "-tab-types"].isHittable)
        XCTAssertGreaterThan(toggle.frame.midX, app.frame.midX)
        XCTAssertGreaterThan(toggle.frame.midY, menu.frame.midY)
        screenshot("Landscape-option7-opposite-orientation")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(bound.waitForExistence(timeout: 10))
        XCTAssertFalse(tabs.exists)
        XCTAssertFalse(toggle.exists)
        XCTAssertEqual(bound.value as? String, portraitSelection)
        assertFrame(bound.frame, matches: portraitButton)
    }

    func testLandscapeMultiviewArrangementUsesThreeFingerOpacityWithoutEditorBox() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            XCUIDevice.shared.orientation = .portrait
            for (method, original) in originals {
                imp_removeBlock(method_setImplementation(method, original))
            }
        }

        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture",
                                       "--bound-ui-no-animations", "--bound-ui-screen-layout-bound",
                                       "-bound.delta.pip.v1.dex.layout", "12"])
        func chooseOption(_ number: Int) {
            openBoundSettings(in: app)
            let options = element("bound.landscape-options", in: app)
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            options.tap()
            app.buttons["Option \(number)"].firstMatch.tap()
            closeBoundSheet(in: app)
        }
        func beginArrangement(_ prefix: String) {
            openNativePause(in: app)
            let arrange = app.buttons["bound.menu-arrange-views"]
            XCTAssertTrue(arrange.waitForExistence(timeout: 5))
            arrange.tap()
            XCTAssertTrue(app.buttons[prefix + "-done"].waitForExistence(timeout: 10))
        }
        func swipeOpacity(in app: XCUIApplication) throws {
            let screen = app.frame
            // This is the lower canvas area occupied by the old opacity editor.
            // Multiview should now accept the gesture there without drawing a box.
            try BoundUITestGestures.swipe(
                withStart: CGPoint(x: screen.midX, y: screen.height * 0.82),
                deltaY: 40,
                orientation: UIInterfaceOrientation.landscapeRight.rawValue,
                screenSize: screen.size)
        }
        func waitForOpacityChange(on target: XCUIElement, from baseline: String) {
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@", baseline), object: target)
            wait(for: [changed], timeout: 5)
        }
        func verifyOption(_ option: Int) throws {
            let prefix = "bound.landscape\(option)"
            beginArrangement(prefix)

            let editor = element(prefix + "-arrangement", in: app)
            XCTAssertFalse(editor.exists, "Options 6 and 7 must not show the opacity editor box")
            XCTAssertEqual(app.sliders.matching(identifier: prefix + "-opacity").count, 0)
            XCTAssertFalse(element(prefix + "-reset", in: app).exists)
            screenshot("Landscape-option\(option)-multiview-opacity-without-editor")

            let friend = element(prefix + "-move.friend", in: app)
            let multiview = element(prefix + "-move.dex", in: app)
            XCTAssertTrue(friend.waitForExistence(timeout: 5))
            XCTAssertTrue(multiview.waitForExistence(timeout: 5))
            let initialFriendOpacity = try XCTUnwrap(friend.value as? String)
            let initialMultiviewOpacity = try XCTUnwrap(multiview.value as? String)
            XCTAssertTrue(initialFriendOpacity.hasPrefix("Opacity "))
            XCTAssertTrue(initialMultiviewOpacity.hasPrefix("Opacity "))
            let initialFriendPercent = try XCTUnwrap(Int(initialFriendOpacity
                .replacingOccurrences(of: "Opacity ", with: "")
                .replacingOccurrences(of: "%", with: "")))
            let initialMultiviewPercent = try XCTUnwrap(Int(initialMultiviewOpacity
                .replacingOccurrences(of: "Opacity ", with: "")
                .replacingOccurrences(of: "%", with: "")))
            XCTAssertGreaterThan(initialFriendPercent, 0)
            XCTAssertGreaterThan(initialMultiviewPercent, 0)

            friend.tap()
            XCTAssertTrue(friend.isSelected, "Tapping Friend selects it for the opacity gesture")
            XCTAssertFalse(multiview.isSelected)
            try swipeOpacity(in: app)
            waitForOpacityChange(on: friend, from: initialFriendOpacity)
            XCTAssertTrue(friend.isSelected)
            XCTAssertFalse(multiview.isSelected)
            let changedFriendOpacity = try XCTUnwrap(friend.value as? String)
            XCTAssertNotEqual(changedFriendOpacity, initialFriendOpacity)
            XCTAssertEqual(multiview.value as? String, initialMultiviewOpacity,
                           "A Friend swipe must leave Multiview opacity unchanged")

            multiview.tap()
            XCTAssertTrue(multiview.isSelected, "Tapping Multiview selects it for the opacity gesture")
            XCTAssertFalse(friend.isSelected)
            try swipeOpacity(in: app)
            waitForOpacityChange(on: multiview, from: initialMultiviewOpacity)
            XCTAssertTrue(multiview.isSelected)
            XCTAssertFalse(friend.isSelected)
            let changedMultiviewOpacity = try XCTUnwrap(multiview.value as? String)
            XCTAssertNotEqual(changedMultiviewOpacity, initialMultiviewOpacity)
            XCTAssertEqual(friend.value as? String, changedFriendOpacity,
                           "A Multiview swipe must leave Friend opacity unchanged")

            app.buttons[prefix + "-done"].tap()
            XCTAssertTrue(app.buttons[prefix + "-done"].waitForNonExistence(timeout: 5))
            beginArrangement(prefix)
            XCTAssertFalse(editor.exists)
            XCTAssertEqual(friend.value as? String, changedFriendOpacity,
                           "Done saves Friend opacity when Arrange Views is reopened")
            XCTAssertEqual(multiview.value as? String, changedMultiviewOpacity,
                           "Done saves Multiview opacity when Arrange Views is reopened")
            app.buttons[prefix + "-done"].tap()
            XCTAssertTrue(app.buttons[prefix + "-done"].waitForNonExistence(timeout: 5))
        }

        chooseOption(6)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["bound.landscape6-views-button"].waitForExistence(timeout: 10))
        try verifyOption(6)

        chooseOption(7)
        XCTAssertTrue(element("bound.landscape7-tabs", in: app).waitForExistence(timeout: 10))
        try verifyOption(7)
    }

    func testLandscapeOption6MultiviewSwipesToggleAndPortraitRestoration() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            XCUIDevice.shared.orientation = .portrait
            for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) }
        }
        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture",
                                       "-bound.delta.pip.v1.dex.layout", "12",
                                       "-bound.delta.pip.v1.bosses.layout", "12"])
        let bound = app.buttons["bound.panel-cycle"]
        let portraitButton = bound.frame
        let portraitSelection = bound.value as? String
        func chooseOption(_ number: Int) {
            openBoundSettings(in: app)
            let options = element("bound.landscape-options", in: app)
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            options.tap(); app.buttons["Option \(number)"].firstMatch.tap()
            closeBoundSheet(in: app)
        }
        func beginArrangement(_ prefix: String) {
            openNativePause(in: app)
            let arrange = app.buttons["bound.menu-arrange-views"]
            XCTAssertTrue(arrange.waitForExistence(timeout: 5)); arrange.tap()
            XCTAssertTrue(app.buttons[prefix + "-done"].waitForExistence(timeout: 5))
        }
        func assertFrame(_ actual: CGRect, matches expected: CGRect) {
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 2)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 2)
            XCTAssertEqual(actual.width, expected.width, accuracy: 2)
            XCTAssertEqual(actual.height, expected.height, accuracy: 2)
        }

        chooseOption(3)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["bound.landscape3-views-button"].waitForExistence(timeout: 10))
        selectCompanion("RR Dex", in: app)
        let boundSlot = bound.frame
        beginArrangement("bound.landscape3")
        let originalOption3 = element("bound.landscape3-move.dex", in: app).frame
        let heightHandle = element("bound.landscape3-resize-height.dex", in: app)
        let heightStart = heightHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        heightStart.press(forDuration: 0.05, thenDragTo: heightStart.withOffset(CGVector(dx: 0, dy: -24)))
        let option3Frame = element("bound.landscape3-move.dex", in: app).frame
        XCTAssertLessThan(option3Frame.height, originalOption3.height,
                          "Option 6 must copy a customized Option 3 layout.")
        app.buttons["bound.landscape3-done"].tap()

        chooseOption(6)
        let prefix = "bound.landscape6"
        let reference = element(prefix + "-reference-content", in: app)
        let toggle = app.buttons[prefix + "-views-button"]
        let menu = element("bound.native-menu", in: app)
        XCTAssertTrue(reference.waitForExistence(timeout: 10))
        XCTAssertEqual(reference.value as? String, "RR Dex")
        XCTAssertTrue(bound.waitForNonExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Hide multiview")
        XCTAssertEqual(toggle.frame.midX, boundSlot.midX, accuracy: 2)
        XCTAssertEqual(toggle.frame.midY, boundSlot.midY, accuracy: 2)
        XCTAssertGreaterThan(toggle.frame.midX, app.frame.midX)
        XCTAssertGreaterThan(toggle.frame.midY, menu.frame.midY)

        beginArrangement(prefix)
        assertFrame(element(prefix + "-move.dex", in: app).frame, matches: option3Frame)
        app.buttons[prefix + "-done"].tap()
        let sharedFrame = reference.frame
        func swipe(left: Bool, to title: String, identifier: String) {
            let start = reference.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: 0.8))
            let end = reference.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.85, dy: 0.8))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            waitForFrame(reference) { _ in reference.value as? String == title }
            XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 5))
            assertFrame(reference.frame, matches: sharedFrame)
        }
        swipe(left: true, to: "Bosses", identifier: "bound.boss-guide")
        app.buttons["bound.boss-picker"].tap()
        let bossSearch = app.searchFields.firstMatch
        XCTAssertTrue(bossSearch.waitForExistence(timeout: 5))
        bossSearch.tap(); bossSearch.typeText("Brock")
        app.buttons["bound.boss-select-kanto-leaders-4"].tap()
        XCTAssertTrue(bossSearch.waitForNonExistence(timeout: 5))
        let teamStrip = element("bound.boss-team-strip", in: app)
        XCTAssertTrue(teamStrip.waitForExistence(timeout: 5))
        let firstMember = app.buttons["bound.boss-team-member-0"]
        let memberBeforeScroll = firstMember.frame
        teamStrip.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .press(forDuration: 0.05,
                   thenDragTo: teamStrip.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertEqual(reference.value as? String, "Bosses",
                       "Scrolling a horizontal list must not switch multiview pages.")
        XCTAssertLessThan(firstMember.frame.minX, memberBeforeScroll.minX - 5)
        swipe(left: true, to: "Types", identifier: "bound.type-chart")
        swipe(left: false, to: "Bosses", identifier: "bound.boss-guide")
        swipe(left: false, to: "RR Dex", identifier: "bound.rrdex")
        screenshot("Landscape-option6-multiview-visible")
        toggle.tap()
        XCTAssertTrue(reference.waitForNonExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Show multiview")
        XCTAssertEqual(toggle.value as? String, "Hidden")
        XCTAssertTrue(element(prefix + "-friend", in: app).exists)
        screenshot("Landscape-option6-multiview-hidden-book")
        toggle.tap()
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        XCTAssertEqual(reference.value as? String, "RR Dex")
        assertFrame(reference.frame, matches: sharedFrame)

        // Edits belong to the shared Option 6 panel, independently of Option 3.
        beginArrangement(prefix)
        let move = element(prefix + "-move.dex", in: app)
        let handle = element(prefix + "-resize-width.dex", in: app)
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -20, dy: 0)))
        let option6Frame = move.frame
        XCTAssertLessThan(option6Frame.width, option3Frame.width)
        app.buttons[prefix + "-done"].tap()
        chooseOption(3)
        XCTAssertTrue(bound.waitForExistence(timeout: 5))
        beginArrangement("bound.landscape3")
        assertFrame(element("bound.landscape3-move.dex", in: app).frame, matches: option3Frame)
        app.buttons["bound.landscape3-done"].tap()
        chooseOption(6)
        beginArrangement(prefix)
        assertFrame(element(prefix + "-move.dex", in: app).frame, matches: option6Frame)
        app.buttons[prefix + "-done"].tap()
        assertGamePixelsAnimate(element("bound.game-screen", in: app), in: app)

        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(bound.exists)
        XCTAssertGreaterThan(toggle.frame.midX, app.frame.midX)
        XCTAssertGreaterThan(toggle.frame.midY, menu.frame.midY)
        screenshot("Landscape-option6-opposite-orientation")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(bound.waitForExistence(timeout: 10))
        XCTAssertFalse(toggle.exists)
        XCTAssertFalse(reference.exists)
        XCTAssertEqual(bound.value as? String, portraitSelection)
        assertFrame(bound.frame, matches: portraitButton)
    }

    func testLandscapeMultiviewDexSearchSharesPokemonHeaderRow() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originals: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originals.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            XCUIDevice.shared.orientation = .portrait
            for (method, original) in originals { imp_removeBlock(method_setImplementation(method, original)) }
        }

        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-reset-layout", "--bound-ui-friend-fixture",
                              "--bound-ui-screen-layout-bound", "--bound-ui-no-animations",
                              "-bound.delta.pip.v1.dex.layout", "12",
                              "-bound.delta.pip.v1.bosses.layout", "12"]
        app.launch()
        let diagnostic = libraryGame(named: "BoundRRDexDiagnostic", in: app)
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 20))
        diagnostic.tap()
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 15))
        selectCompanion("Dex", in: app)
        let portraitSearch = app.buttons["bound.rrdex-search-open"]
        XCTAssertTrue(portraitSearch.isHittable)
        XCTAssertLessThan(portraitSearch.frame.midY, 70,
                          "Portrait keeps the existing search position near the top safe area.")

        func chooseOption(_ number: Int) {
            openBoundSettings(in: app)
            let options = element("bound.landscape-options", in: app)
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            options.tap(); app.buttons["Option \(number)"].firstMatch.tap()
            closeBoundSheet(in: app)
        }

        func verifyDexHeader(option: Int) {
            let prefix = "bound.landscape\(option)"
            if option == 7 {
                let dexTab = app.buttons[prefix + "-tab-dex"]
                XCTAssertTrue(dexTab.waitForExistence(timeout: 10)); dexTab.tap()
            }
            let content = element(prefix + "-reference-content", in: app)
            XCTAssertTrue(content.waitForExistence(timeout: 10))
            XCTAssertEqual(content.value as? String, "RR Dex")
            let sprite = element("bound.rrdex-picture", in: app)
            let searchButton = app.buttons["bound.rrdex-search-open"]
            XCTAssertTrue(sprite.waitForExistence(timeout: 5))
            XCTAssertTrue(searchButton.isHittable)
            XCTAssertEqual(searchButton.frame.midY, sprite.frame.midY, accuracy: 5,
                           "Landscape Option \(option) places search beside the Pokémon sprite.")
            XCTAssertEqual(searchButton.frame.height, sprite.frame.height * 44 / 58, accuracy: 2,
                           "The 44pt search target scales with the floating Dex card.")

            let contentTop = option == 7 ? element(prefix + "-tabs", in: app).frame.maxY : content.frame.minY
            XCTAssertLessThanOrEqual(sprite.frame.minY, contentTop + 16,
                                     "The Dex body starts immediately under the multiview top edge, without a standalone search bar.")
            XCTAssertFalse(app.textFields["bound.rrdex-search"].exists)
            screenshot("Landscape-option\(option)-Dex-inline-search")

            searchButton.tap()
            let search = app.textFields["bound.rrdex-search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            let done = app.buttons["bound.rrdex-search-open"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            XCTAssertTrue(search.waitForNonExistence(timeout: 5),
                          "The inline Done control closes an empty search and restores details.")
            XCTAssertTrue(app.staticTexts["bound.rrdex-pokemon"].exists)
            searchButton.tap()
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap(); search.typeText("bulbasaur")
            let bulbasaur = app.buttons["bound.rrdex-suggestion-1"]
            XCTAssertTrue(bulbasaur.waitForExistence(timeout: 5))
            bulbasaur.tap()
            XCTAssertTrue(search.waitForNonExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["bound.rrdex-pokemon"].label, "Bulbasaur")
            XCTAssertTrue(app.buttons["bound.rrdex-search-open"].isHittable,
                          "Selecting a result returns to details with inline search available.")
        }

        chooseOption(6)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["bound.landscape6-views-button"].waitForExistence(timeout: 10))
        verifyDexHeader(option: 6)

        chooseOption(3)
        selectCompanion("RR Dex", in: app)
        let option3Search = app.buttons["bound.rrdex-search-open"]
        let option3Details = app.scrollViews["bound.rrdex-layout12-details"]
        XCTAssertTrue(option3Search.isHittable)
        XCTAssertTrue(option3Details.waitForExistence(timeout: 5))
        XCTAssertLessThan(option3Search.frame.maxY, option3Details.frame.minY,
                          "Option 3 keeps the existing separate search header.")

        chooseOption(7)
        XCTAssertTrue(element("bound.landscape7-tabs", in: app).waitForExistence(timeout: 10))
        verifyDexHeader(option: 7)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(portraitSearch.waitForExistence(timeout: 10))
        XCTAssertLessThan(portraitSearch.frame.midY, 70,
                          "Returning to portrait restores its existing search position.")
    }

    func testLandscapeOption3ArrangementGesturesAndIndependentViews() throws {
        try verifyLandscapeArrangement(option: 3)
    }

    func testLandscapeOption4RefinedArrangementAndIndependentViews() throws {
        try verifyLandscapeArrangement(option: 4)
    }

    func testLandscapeOption5CornerPlacementAndIndependentViews() throws {
        try verifyLandscapeArrangement(option: 5)
    }

    func testArrangeViewsPortraitPromptThenLandscapeEntry() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originalImplementations: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originalImplementations.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            for (method, original) in originalImplementations {
                imp_removeBlock(method_setImplementation(method, original))
            }
        }

        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture"])
        let arrange = app.buttons["bound.menu-arrange-views"]

        openNativePause(in: app)
        XCTAssertTrue(arrange.waitForExistence(timeout: 10))
        arrange.tap()
        XCTAssertTrue(app.staticTexts["Rotate your phone"].waitForExistence(timeout: 5))
        screenshot("Portrait-arrange-views-rotate-prompt")
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(arrange.exists, "Dismissing the portrait prompt leaves the game paused in Menu")
        XCTAssertTrue(app.buttons["Settings"].exists)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(arrange.waitForExistence(timeout: 10))
        arrange.tap()
        let done = app.buttons["bound.landscape7-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Option 7 should open Arrange Views in landscape")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10))

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 10))
        openNativePause(in: app)
        XCTAssertTrue(arrange.waitForExistence(timeout: 10), "The tile remains available in portrait after arranging")
    }

    func testLandscapeRRDexHeightResizeFillsContent() throws {
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originalImplementations: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originalImplementations.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            for (method, original) in originalImplementations {
                imp_removeBlock(method_setImplementation(method, original))
            }
        }

        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture",
                                       "-bound.delta.pip.v1.dex.layout", "12"])
        openBoundSettings(in: app)
        let options = element("bound.landscape-options", in: app)
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()
        app.buttons["Option 5"].firstMatch.tap()
        closeBoundSheet(in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        let prefix = "bound.landscape5"
        let arrangeTile = app.buttons["bound.menu-arrange-views"]
        openNativePause(in: app)
        XCTAssertTrue(arrangeTile.waitForExistence(timeout: 10))
        arrangeTile.tap()
        XCTAssertTrue(app.buttons[prefix + "-done"].waitForExistence(timeout: 10))
        app.buttons[prefix + "-choose-view"].tap()
        app.buttons[prefix + "-select.dex"].tap()

        let moveDex = element(prefix + "-move.dex", in: app)
        let widthHandle = element(prefix + "-resize-width.dex", in: app)
        let heightHandle = element(prefix + "-resize-height.dex", in: app)
        XCTAssertTrue(moveDex.waitForExistence(timeout: 5))
        let widthStart = widthHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        widthStart.press(forDuration: 0.1, thenDragTo: widthStart.withOffset(CGVector(dx: -220, dy: 0)))
        let heightStart = heightHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        heightStart.press(forDuration: 0.1, thenDragTo: heightStart.withOffset(CGVector(dx: 0, dy: -180)))
        let minimumHeightHandle = element(prefix + "-resize-height.dex", in: app)
        let minimumHeightStart = minimumHeightHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        minimumHeightStart.press(forDuration: 0.1, thenDragTo: minimumHeightStart.withOffset(CGVector(dx: 0, dy: 40)))
        app.buttons[prefix + "-done"].tap()
        XCTAssertTrue(app.buttons[prefix + "-done"].waitForNonExistence(timeout: 5))
        screenshot("Landscape-option5-rrdex-height-baseline")

        let details = app.scrollViews["bound.rrdex-layout12-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        let minimumDetailsHeight = details.frame.height
        XCTAssertGreaterThan(minimumDetailsHeight, 0)

        openNativePause(in: app)
        XCTAssertTrue(arrangeTile.waitForExistence(timeout: 5))
        arrangeTile.tap()
        XCTAssertTrue(app.buttons[prefix + "-done"].waitForExistence(timeout: 10))
        app.buttons[prefix + "-choose-view"].tap()
        app.buttons[prefix + "-select.dex"].tap()
        let currentHeightHandle = element(prefix + "-resize-height.dex", in: app)
        let beforeGrow = moveDex.frame.size
        let growStart = currentHeightHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        growStart.press(forDuration: 0.1, thenDragTo: growStart.withOffset(CGVector(dx: 0, dy: 60)))
        let outerHeightDelta = moveDex.frame.height - beforeGrow.height
        XCTAssertEqual(moveDex.frame.width, beforeGrow.width, accuracy: 2,
                       "A pure height resize must leave the RR Dex panel width unchanged")
        XCTAssertGreaterThan(outerHeightDelta, 30,
                             "The outer RR Dex panel must grow from its saved minimum height")
        let resizedFrame = moveDex.frame
        app.buttons[prefix + "-done"].tap()
        XCTAssertTrue(app.buttons[prefix + "-done"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(details.frame.height - minimumDetailsHeight, outerHeightDelta, accuracy: 3,
                        "The visible RR Dex details viewport must track the panel's height increase")
        screenshot("Landscape-option5-rrdex-height-resized")

        let bound = app.buttons["bound.panel-cycle"]
        for _ in 0..<5 where bound.value as? String != "Notes" { bound.tap() }
        XCTAssertEqual(bound.value as? String, "Notes")
        for _ in 0..<5 where bound.value as? String != "RR Dex" { bound.tap() }
        XCTAssertEqual(bound.value as? String, "RR Dex")
        // The native drag target measures the panel itself; the accessibility
        // container can include offscreen descendants from the detail scroller.
        openNativePause(in: app)
        XCTAssertTrue(arrangeTile.waitForExistence(timeout: 5))
        arrangeTile.tap()
        XCTAssertTrue(moveDex.waitForExistence(timeout: 5))
        XCTAssertEqual(moveDex.frame, resizedFrame, "The resized RR Dex frame must persist when cycling away and back")
        app.buttons[prefix + "-done"].tap()
    }

    private func verifyLandscapeArrangement(option: Int) throws {
        let prefix = "bound.landscape\(option)"
        // Observe native menu transitions explicitly; the running emulator can
        // otherwise leave Xcode's idle detector waiting after opening Settings.
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originalImplementations: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            originalImplementations.append((method, method_setImplementation(method, imp_implementationWithBlock(skip))))
        }
        defer {
            for (method, original) in originalImplementations {
                imp_removeBlock(method_setImplementation(method, original))
            }
        }

        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture"])
        func selectView(_ name: String) {
            if option == 5 { app.buttons[prefix + "-choose-view"].tap() }
            let choice = app.buttons[prefix + "-select." + name]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
        }
        openBoundSettings(in: app)
        let options = element("bound.landscape-options", in: app)
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.tap()
        app.buttons["Option \(option)"].firstMatch.tap()
        closeBoundSheet(in: app)

        // The tile stays in the native Menu in portrait and updates as the
        // game rotates into landscape, without reopening Settings.
        let arrangeTile = app.buttons["bound.menu-arrange-views"]
        openNativePause(in: app)
        XCTAssertTrue(arrangeTile.waitForExistence(timeout: 10),
                      "Arrange Views should remain available in portrait so it can explain the rotation requirement")
        arrangeTile.tap()
        XCTAssertTrue(app.staticTexts["Rotate your phone"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(arrangeTile.exists, "The portrait prompt should leave the Menu open")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(arrangeTile.waitForExistence(timeout: 10),
                      "The Menu tile should appear as soon as the game enters landscape")
        if option == 5 {
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(arrangeTile.waitForExistence(timeout: 10),
                          "Arrange Views should remain visible when the Menu returns to portrait")
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(arrangeTile.waitForExistence(timeout: 10))
            // Returning from Settings updates this same paused menu, including
            // removing the tile for the two options with no arrangement editor.
            for selectedOption in [1, 2, 5] {
                app.buttons["Settings"].tap()
                XCTAssertTrue(app.buttons["bound.settings-interface"].waitForExistence(timeout: 5))
                XCTAssertFalse(element("bound.settings-arrange-views", in: app).exists)
                app.buttons["bound.settings-interface"].tap()
                XCTAssertTrue(options.waitForExistence(timeout: 5))
                options.tap()
                app.buttons["Option \(selectedOption)"].firstMatch.tap()
                app.buttons["bound.settings-close"].tap()
                XCTAssertTrue(app.buttons["bound.settings-close"].waitForNonExistence(timeout: 5))
                if selectedOption == 5 { XCTAssertTrue(arrangeTile.waitForExistence(timeout: 5)) }
                else {
                    XCTAssertTrue(arrangeTile.waitForNonExistence(timeout: 5),
                                  "Landscape Options 1 and 2 do not support arranging")
                    XCUIDevice.shared.orientation = .portrait
                    XCTAssertTrue(arrangeTile.waitForExistence(timeout: 10),
                                  "The portrait tile remains available regardless of landscape option")
                    XCUIDevice.shared.orientation = .landscapeLeft
                    XCTAssertTrue(arrangeTile.waitForNonExistence(timeout: 10))
                }
            }
        }
        screenshot("Landscape-option\(option)-menu-arrange-tile")
        resumeNativePause(in: app)
        let friendToggle = app.buttons[prefix + "-friend-button"]
        let viewsToggle = app.buttons[prefix + "-views-button"]
        XCTAssertTrue(friendToggle.waitForExistence(timeout: 10))
        XCTAssertTrue(viewsToggle.waitForExistence(timeout: 5))
        let friend = element(prefix + "-friend", in: app)
        let reference = element(prefix + "-reference-content", in: app)
        XCTAssertTrue(friend.waitForExistence(timeout: 5))
        XCTAssertTrue(reference.waitForExistence(timeout: 5))

        // Friend visibility is independent from reference visibility and cycling.
        friendToggle.tap()
        XCTAssertTrue(friend.waitForNonExistence(timeout: 5))
        XCTAssertTrue(reference.exists)
        friendToggle.tap()
        XCTAssertTrue(friend.waitForExistence(timeout: 5))
        if option >= 4 { XCTAssertEqual(viewsToggle.label, "Hide views") }
        viewsToggle.tap()
        if option >= 4 { XCTAssertEqual(viewsToggle.label, "Show views") }
        XCTAssertEqual(viewsToggle.value as? String, "Hidden")
        XCTAssertTrue(reference.waitForNonExistence(timeout: 5))
        XCTAssertTrue(friend.exists)
        viewsToggle.tap()
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        let bound = app.buttons["bound.panel-cycle"]
        bound.tap()
        XCTAssertNotEqual(bound.value as? String, "Friend", "Bound cycles reference views only")
        XCTAssertTrue(friend.exists, "Bound must not toggle the independent Friend panel")
        for _ in 0..<5 where bound.value as? String != "RR Dex" { bound.tap() }
        XCTAssertEqual(bound.value as? String, "RR Dex")
        let menu = element("bound.native-menu", in: app)
        XCTAssertEqual(friendToggle.frame.midY, menu.frame.midY, accuracy: 2)
        XCTAssertEqual(viewsToggle.frame.midY, bound.frame.midY, accuracy: 2)
        for obstacle in try actualPiPHitObstacles(in: element("bound.game-screen", in: app)) {
            let overlap = reference.frame.intersection(obstacle)
            XCTAssertFalse(overlap.width > 1 && overlap.height > 1)
        }
        XCTAssertFalse(friend.frame.intersects(reference.frame), "The default arrangement must show both distinct panels")
        screenshot("Landscape-option\(option)-independent-views")

        // Reopen the native Menu and enter arrangement from its dedicated tile.
        openNativePause(in: app)
        XCTAssertTrue(arrangeTile.waitForExistence(timeout: 5))
        arrangeTile.tap()
        XCTAssertTrue(app.buttons[prefix + "-done"].waitForExistence(timeout: 10),
                      "Starting arrangement should return to gameplay with Menu relabeled Done")
        XCTAssertTrue(element(prefix + "-arrangement", in: app).exists)
        XCTAssertTrue(app.sliders[prefix + "-opacity"].waitForExistence(timeout: 5),
                      "The selected panel should expose an accessible opacity control")

        // A genuine three-finger swipe changes only the selected panel.
        let opacity = app.sliders[prefix + "-opacity"]
        if option >= 4 {
            // Every enabled view is directly selectable; only the selected view
            // has resize handles, keeping the other panel easy to distinguish.
            selectView("bosses")
            XCTAssertTrue(element(prefix + "-move.bosses", in: app).exists)
            XCTAssertTrue(element(prefix + "-resize-width.bosses", in: app).exists)
            XCTAssertFalse(element(prefix + "-resize-scale.friend", in: app).exists)
            opacity.adjust(toNormalizedSliderPosition: 0.30)
            app.buttons[prefix + "-reset"].tap()
            XCTAssertEqual(opacity.value as? String, "100%")
        }
        if option == 5 {
            let toolbar = element(prefix + "-arrangement", in: app)
            selectView("friend")
            let movableFriend = element(prefix + "-move.friend", in: app)
            let friendSize = movableFriend.frame.size
            app.buttons[prefix + "-place.bottomRight"].tap()
            XCTAssertGreaterThan(movableFriend.frame.midY, app.frame.midY)
            XCTAssertLessThan(toolbar.frame.midY, app.frame.midY)
            XCTAssertEqual(movableFriend.frame.width, friendSize.width, accuracy: 1)
            XCTAssertEqual(movableFriend.frame.height, friendSize.height, accuracy: 1)
            app.buttons[prefix + "-place.topLeft"].tap()
            XCTAssertLessThan(movableFriend.frame.midY, app.frame.midY)
            XCTAssertGreaterThan(toolbar.frame.midY, app.frame.midY)
            selectView("dex")
            app.buttons[prefix + "-place.bottomRight"].tap()
            let movableReference = element(prefix + "-move.dex", in: app)
            for obstacle in try actualPiPHitObstacles(in: element("bound.game-screen", in: app)) {
                let overlap = movableReference.frame.intersection(obstacle)
                XCTAssertFalse(overlap.width > 1 && overlap.height > 1)
            }
            screenshot("Landscape-option5-corner-placement")
            app.buttons[prefix + "-place.topRight"].tap()
        }
        selectView("friend")
        if option >= 4 {
            XCTAssertTrue(element(prefix + "-resize-scale.friend", in: app).exists)
            XCTAssertFalse(element(prefix + "-resize-width.bosses", in: app).exists)
        }
        opacity.adjust(toNormalizedSliderPosition: 0.55)
        let friendOpacity = opacity.value as? String
        selectView("dex")
        let originalReferenceOpacity = opacity.value as? String
        let screen = app.frame
        try BoundUITestGestures.swipe(withStart: CGPoint(x: screen.midX, y: screen.height * 0.30), deltaY: 65, orientation: UIInterfaceOrientation.landscapeRight.rawValue, screenSize: screen.size)
        XCTAssertNotEqual(opacity.value as? String, originalReferenceOpacity,
                          "Three fingers in the center should change the selected reference opacity")
        selectView("friend")
        XCTAssertEqual(opacity.value as? String, friendOpacity)
        let moveFriend = element(prefix + "-move.friend", in: app)
        moveFriend.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        selectView("dex")
        let moveDex = element(prefix + "-move.dex", in: app)
        XCTAssertTrue(moveDex.exists)
        let originalSize = moveDex.frame.size
        let width = element(prefix + "-resize-width.dex", in: app)
        let height = element(prefix + "-resize-height.dex", in: app)
        XCTAssertTrue(width.exists); XCTAssertTrue(height.exists)
        let from = width.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: -24, dy: 0)))
        XCTAssertLessThan(moveDex.frame.width, originalSize.width)
        screenshot("Landscape-option\(option)-arrange-views")

        app.buttons[prefix + "-done"].tap()
        XCTAssertTrue(app.buttons[prefix + "-done"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        XCTAssertTrue(friend.frame.contains(CGPoint(x: menu.frame.midX, y: menu.frame.midY)))
        let savedDex = reference.frame
        screenshot("Landscape-option\(option)-locked-friend-over-menu")
        assertGamePixelsAnimate(element("bound.game-screen", in: app), in: app)
        XCTAssertTrue(app.buttons["bound.native-menu"].exists,
                      "Done should restore the native Menu control and lock the views")
        // Locked Friend passes touches through; the native menu still pauses.
        app.buttons["bound.native-menu"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        resumeNativePause(in: app)
        for _ in 0..<5 where bound.value as? String != "Notes" { bound.tap() }
        element("bound.notes-preview", in: app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        for _ in 0..<5 where bound.value as? String != "RR Dex" { bound.tap() }
        XCTAssertEqual(reference.frame, savedDex, "Each reference keeps its own placement")

        // Portrait returns to its existing single-panel control; Arrange Views remains available from Menu.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 10))
        XCTAssertFalse(friendToggle.exists)
        openNativePause(in: app)
        XCTAssertTrue(arrangeTile.waitForExistence(timeout: 10),
                      "Arrange Views should remain available from the Menu in portrait")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["bound.settings-interface"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("bound.settings-arrange-views", in: app).exists)
        closeBoundSheet(in: app)
    }

    func testLandscapeOption2IndependentViewsLockAndPortraitRestoration() throws {
        // The animated game can keep Xcode 27's idle detector waiting after
        // opening the native pause menu. Observe each UI transition explicitly.
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        var originalImplementations: [(Method, IMP)] = []
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let method = try XCTUnwrap(class_getInstanceMethod(process, NSSelectorFromString(name)))
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            let replacement = imp_implementationWithBlock(skip)
            originalImplementations.append((method, method_setImplementation(method, replacement)))
        }
        defer {
            for (method, original) in originalImplementations {
                let replacement = method_setImplementation(method, original)
                imp_removeBlock(replacement)
            }
        }
        let app = openGame(arguments: ["--bound-ui-reset-layout", "--bound-ui-friend-fixture"])
        let originalPortrait = element("bound.companion-container", in: app).frame
        openBoundSettings(in: app)
        let options = element("bound.landscape-options", in: app)
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(options.label.contains("Option 1") || (options.value as? String) == "Option 1")
        options.tap()
        app.buttons["Option 2"].firstMatch.tap()
        closeBoundSheet(in: app)
        XCTAssertFalse(app.buttons["bound.landscape-friend-button"].exists)
        XCTAssertTrue(app.buttons["bound.panel-cycle"].exists)
        XCTAssertEqual(element("bound.companion-container", in: app).frame, originalPortrait)

        XCUIDevice.shared.orientation = .landscapeLeft
        let friendButton = app.buttons["bound.landscape-friend-button"]
        let viewsButton = app.buttons["bound.landscape-views-button"]
        XCTAssertTrue(friendButton.waitForExistence(timeout: 10))
        XCTAssertTrue(viewsButton.exists)
        XCTAssertFalse(app.buttons["bound.panel-cycle"].exists)
        viewsButton.tap()
        XCTAssertEqual(viewsButton.value as? String, "Notes")
        let game = element("bound.game-screen", in: app)
        let reference = element("bound.landscape-reference-content", in: app)
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        for name in ["Notes", "Types", "Bosses", "RR Dex"] {
            XCTAssertEqual(viewsButton.value as? String, name)
            let header = element("bound.landscape-reference-handle", in: app)
            let frame = reference.frame.union(header.frame)
            for obstacle in try actualPiPHitObstacles(in: game) {
                let overlap = frame.intersection(obstacle)
                XCTAssertFalse(overlap.width > 1 && overlap.height > 1, "\(name) overlaps a control: \(frame) / \(obstacle)")
            }
            XCTAssertTrue(element("bound.landscape-friend", in: app).exists)
            viewsButton.tap()
        }
        XCTAssertEqual(viewsButton.value as? String, "Notes")
        element("bound.notes-preview", in: app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        friendButton.tap()
        XCTAssertTrue(element("bound.landscape-friend", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(reference.exists)
        friendButton.tap()
        XCTAssertTrue(element("bound.landscape-friend", in: app).waitForExistence(timeout: 5))
        friendButton.press(forDuration: 1)
        let save = app.buttons["bound.landscape-save-lock"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let menu = element("bound.native-menu", in: app)
        let move = element("bound.landscape-friend-move", in: app)
        move.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        let locked = element("bound.landscape-friend", in: app)
        XCTAssertTrue(locked.frame.contains(CGPoint(x: menu.frame.midX, y: menu.frame.midY)))
        XCTAssertEqual(locked.value as? String, "Locked, touches pass through")
        screenshot("Landscape-option2-locked-friend-over-menu")
        menu.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5), "A native control under locked Friend must receive the tap")
        resumeNativePause(in: app)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 10))
        XCTAssertFalse(friendButton.exists)
        XCTAssertEqual(app.buttons["bound.panel-cycle"].value as? String, "Friend")
        XCTAssertEqual(element("bound.companion-container", in: app).frame, originalPortrait)
        screenshot("Landscape-option2-portrait-unchanged")
        openBoundSettings(in: app)
        element("bound.landscape-options", in: app).tap()
        app.buttons["Option 1"].firstMatch.tap()
        closeBoundSheet(in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["bound.panel-cycle"].waitForExistence(timeout: 10))
        XCTAssertFalse(friendButton.exists)
        XCTAssertFalse(viewsButton.exists)
        screenshot("Landscape-option1-restored")
    }
}
