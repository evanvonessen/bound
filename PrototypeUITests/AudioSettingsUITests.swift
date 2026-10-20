import XCTest
import ObjectiveC

final class AudioSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testAudioPreferencesSurviveRelaunchAndGameSessions() throws {
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

        let identifiers = [
            "bound.audio.respect-silent-mode",
            "bound.audio.mix-with-other-audio",
            "bound.audio.pause-other-audio"
        ]

        func openAudioFromLibrary() {
            let settings = app.buttons["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 15))
            settings.tap()
            let settingsRoot = app.descendants(matching: .any).matching(identifier: "bound.settings-root").firstMatch
            XCTAssertTrue(settingsRoot.waitForExistence(timeout: 10))
            let audio = app.buttons["bound.settings-audio"]
            XCTAssertTrue(audio.waitForExistence(timeout: 5))
            audio.tap()
            XCTAssertTrue(app.navigationBars["Audio"].waitForExistence(timeout: 5))
            for identifier in identifiers {
                XCTAssertTrue(app.switches[identifier].waitForExistence(timeout: 5), "Missing audio toggle: \(identifier)")
            }
        }

        func closeAudioToLibrarySettings() {
            app.navigationBars["Audio"].buttons.firstMatch.tap()
        }

        func set(_ toggle: XCUIElement, to enabled: Bool) {
            if (toggle.value as? String == "1") != enabled {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
        }

        func currentValues() -> [Bool] {
            identifiers.map { app.switches[$0].value as? String == "1" }
        }

        func assertValues(_ expected: [Bool], _ context: String) {
            XCTAssertEqual(currentValues(), expected, "Audio toggles should persist \(context).")
        }

        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        openAudioFromLibrary()
        let originalValues = currentValues()
        let customizedValues = originalValues.map(!)
        defer {
            if app.state != .notRunning {
                app.terminate()
            }
            app.launch()
            openAudioFromLibrary()
            for (index, identifier) in identifiers.enumerated() {
                set(app.switches[identifier], to: originalValues[index])
            }
            app.terminate()
        }

        for (index, identifier) in identifiers.enumerated() {
            set(app.switches[identifier], to: customizedValues[index])
        }
        closeAudioToLibrarySettings()

        app.terminate()
        app.launch()
        openAudioFromLibrary()
        assertValues(customizedValues, "after terminating and relaunching Bound")
        closeAudioToLibrarySettings()
        app.buttons["bound.settings-close"].tap()

        let game = app.collectionViews.cells.firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 20), "The QA library should contain a playable game.")
        game.tap()
        let menu = app.descendants(matching: .any).matching(identifier: "bound.native-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["bound.settings-root"].waitForExistence(timeout: 10))
        app.buttons["bound.settings-audio"].tap()
        XCTAssertTrue(app.navigationBars["Audio"].waitForExistence(timeout: 5))
        assertValues(customizedValues, "after starting a game")
        closeAudioToLibrarySettings()
        app.buttons["bound.settings-close"].tap()
        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()

        app.terminate()
        app.launch()
        openAudioFromLibrary()
        assertValues(customizedValues, "after returning from gameplay and relaunching")
    }
}
