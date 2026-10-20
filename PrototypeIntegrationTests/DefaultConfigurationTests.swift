import XCTest
import Foundation
import UIKit
@testable import Delta

@MainActor
final class DefaultConfigurationTests: XCTestCase {
    private var priorRegistrationDomain: [String: Any]?

    override func setUp() {
        super.setUp()
        priorRegistrationDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.registrationDomain)
    }

    override func tearDown() {
        if let priorRegistrationDomain {
            UserDefaults.standard.setVolatileDomain(priorRegistrationDomain, forName: UserDefaults.registrationDomain)
        }
        priorRegistrationDomain = nil
        super.tearDown()
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "DefaultConfigurationTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testFreshInstallRegistersTheExportedInterfaceAndIndependentLandscapeLayouts() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        Settings.registerPreferenceDefaults(in: defaults)

        for (key, expected) in BoundDefaultConfiguration.preferences {
            XCTAssertEqual(defaults.object(forKey: key) as? NSObject, expected as? NSObject,
                           "Fresh-install registration should expose the bundled value for \(key).")
        }

        XCTAssertEqual(defaults.integer(forKey: BoundUIVersionPreferences.key), BoundUIVersion.option2.rawValue)
        XCTAssertEqual(defaults.integer(forKey: "bound.landscape.v1.option"), BoundLandscapeOption.option7.rawValue)
        XCTAssertFalse(defaults.bool(forKey: BoundControllerModePreferences.key))

        let off = try XCTUnwrap(defaults.data(forKey: "bound.landscape.option7.placement.friend"))
        let offPlacement = try JSONDecoder().decode(BoundLandscapeViewPlacement.self, from: off)
        XCTAssertEqual(offPlacement.center.x, 0.200139470013947, accuracy: 0.000_000_001)
        XCTAssertEqual(offPlacement.center.y, 0.21878787878787892, accuracy: 0.000_000_001)
        XCTAssertEqual(offPlacement.opacity, 0.6726851851851849, accuracy: 0.000_000_001)

        let on = try XCTUnwrap(defaults.data(forKey: "bound.landscape.controller-unified.option7.placement.friend"))
        let onPlacement = try JSONDecoder().decode(BoundLandscapeViewPlacement.self, from: on)
        XCTAssertEqual(onPlacement.center.x, 0.8361227336122735, accuracy: 0.000_000_001)
        XCTAssertEqual(onPlacement.center.y, 0.23015151515151527, accuracy: 0.000_000_001)
        XCTAssertEqual(onPlacement.opacity, 0.6791666666666667, accuracy: 0.000_000_001)
        XCTAssertNotEqual(off, on, "Controller Mode on and off must retain the separately exported layouts.")

        XCTAssertTrue(defaults.bool(forKey: "bound.landscape.option7.initialized"))
        XCTAssertTrue(defaults.bool(forKey: "bound.landscape.controller-unified.option7.initialized"))
        XCTAssertTrue(defaults.bool(forKey: "bound.landscape.controller-unified.initialized"))
        XCTAssertFalse(defaults.bool(forKey: "bound.landscape.option7.friend-visible"))
        XCTAssertTrue(defaults.bool(forKey: "bound.landscape.controller-unified.option7.friend-visible"))
        XCTAssertTrue(defaults.bool(forKey: BoundControllerNavigationPreferences.key))
        XCTAssertEqual(defaults.string(forKey: "bound.delta.pip.v1.corner"), "topRight")
        XCTAssertEqual(defaults.integer(forKey: "bound.delta.pip.v2.button-type"), 4)
        XCTAssertEqual(defaults.integer(forKey: "bound.delta.pip.v1.dex.layout"), 12)
        XCTAssertEqual(defaults.integer(forKey: "bound.delta.pip.v1.bosses.layout"), 12)
        XCTAssertEqual(defaults.stringArray(forKey: "bound.delta.pip.v1.button.option4.1.views"), ["friend"])
        XCTAssertEqual(defaults.stringArray(forKey: "bound.delta.pip.v1.button.option4.2.views"), ["types", "bosses", "dex"])
    }

    func testRegistrationDoesNotMaskSavedLegacyOrCurrentLandscapeLayouts() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyButtonData = Data("legacy-button-layout".utf8)
        let savedOffLayout = Data("saved-off-layout".utf8)
        let savedOnLayout = Data("saved-on-layout".utf8)
        defaults.set(legacyButtonData, forKey: "bound.landscape.controller-mode.buttons.v1")
        defaults.set(savedOffLayout, forKey: "bound.landscape.option7.placement.friend")
        defaults.set(savedOnLayout, forKey: "bound.landscape.controller-unified.option7.placement.friend")
        defaults.set(4, forKey: "bound.landscape.v1.option")
        defaults.set("bottomLeft", forKey: "bound.delta.pip.v1.corner")
        defaults.set(3, forKey: "bound.delta.pip.v1.button-type")

        let registered = BoundDefaultConfiguration.registrationPreferences(in: defaults)
        Settings.registerPreferenceDefaults(in: defaults)

        XCTAssertFalse(registered.keys.contains { $0.hasPrefix("bound.landscape.") },
                       "Existing explicit or legacy placements must be allowed to migrate without registered initialized markers masking them.")
        XCTAssertEqual(defaults.data(forKey: "bound.landscape.controller-mode.buttons.v1"), legacyButtonData)
        XCTAssertEqual(defaults.data(forKey: "bound.landscape.option7.placement.friend"), savedOffLayout)
        XCTAssertEqual(defaults.data(forKey: "bound.landscape.controller-unified.option7.placement.friend"), savedOnLayout)
        XCTAssertEqual(defaults.integer(forKey: "bound.landscape.v1.option"), 4)
        XCTAssertNil(defaults.object(forKey: BoundDefaultConfiguration.profileKey),
                     "Existing arrangements keep the legacy registration path until settings reset.")
        XCTAssertFalse(defaults.bool(forKey: "bound.landscape.controller-unified.initialized"),
                       "A new registered marker must not suppress the existing layout migration.")
        XCTAssertFalse(registered.keys.contains("bound.delta.pip.v1.friend.corner"),
                       "A registered per-view corner must not supersede an existing shared corner during migration.")
        XCTAssertFalse(registered.keys.contains("bound.delta.pip.v2.button-type"),
                       "A registered new button type must not supersede a saved legacy button type.")
        XCTAssertEqual(defaults.string(forKey: "bound.delta.pip.v1.corner"), "bottomLeft")
        XCTAssertEqual(defaults.integer(forKey: "bound.delta.pip.v1.button-type"), 3)
        XCTAssertNil(defaults.object(forKey: "bound.delta.pip.v2.button-type"),
                     "The legacy button type remains authoritative until its migration is allowed to run.")
    }

    func testFreshRegistrationIncludesBundleLandscapeDefaultsAndProfileMarker() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let registered = BoundDefaultConfiguration.registrationPreferences(in: defaults)
        Settings.registerPreferenceDefaults(in: defaults)
        let expectedOff = try XCTUnwrap(BoundDefaultConfiguration.preferences["bound.landscape.option7.placement.friend"] as? Data)
        let expectedOn = try XCTUnwrap(BoundDefaultConfiguration.preferences["bound.landscape.controller-unified.option7.placement.friend"] as? Data)
        XCTAssertEqual(registered["bound.landscape.option7.placement.friend"] as? Data, expectedOff)
        XCTAssertEqual(registered["bound.landscape.controller-unified.option7.placement.friend"] as? Data, expectedOn)
        XCTAssertTrue(defaults.bool(forKey: BoundDefaultConfiguration.profileKey))
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?.count, 1,
                       "Only the profile marker is persisted; preference values stay in the registration domain.")

        // The marker prevents migrations written by a fresh app session from
        // disabling the new profile on the following launch.
        defaults.set(Data("migrated-layout".utf8), forKey: "bound.landscape.controller-mode.option7.placement.friend")
        let nextLaunch = BoundDefaultConfiguration.registrationPreferences(in: defaults)
        XCTAssertEqual(nextLaunch["bound.landscape.option7.placement.friend"] as? Data, expectedOff)
        XCTAssertEqual(nextLaunch["bound.landscape.controller-unified.option7.placement.friend"] as? Data, expectedOn)
    }

    func testLandscapeModelLoadsRegisteredExportedLayoutsForBothControllerModes() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        Settings.registerPreferenceDefaults(in: defaults)

        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let gameBase = CGRect(x: 100, y: 100, width: 800, height: 400)
        let menuFrame = CGRect(x: 900, y: 20, width: 44, height: 44)
        let boundFrame = CGRect(x: 900, y: 520, width: 44, height: 44)
        let baseFrames: [BoundPiPContent: CGRect] = [
            .friend: CGRect(x: 650, y: 80, width: 240, height: 160),
            .dex: CGRect(x: 380, y: 115, width: 300, height: 360),
            .bosses: CGRect(x: 390, y: 130, width: 260, height: 360),
            .types: CGRect(x: 390, y: 130, width: 260, height: 360),
            .notes: CGRect(x: 390, y: 130, width: 260, height: 360)
        ]
        var gameFrames: [Bool: CGRect] = [:]
        var friendPlacements: [Bool: BoundLandscapeViewPlacement] = [:]

        for controllerModeEnabled in [false, true] {
            let model = BoundLandscapeArrangementModel(defaults: defaults)
            model.useOption(.option7, controllerModeEnabled: controllerModeEnabled)
            model.setContents([.dex, .bosses, .types])
            model.setActive(true)
            model.updateLayout(canvas: canvas, occupied: [menuFrame, boundFrame], menuFrame: menuFrame,
                               boundFrame: boundFrame, defaults: baseFrames, keyboardHeight: 0,
                               screenBounds: canvas)

            let prefix = controllerModeEnabled ? "bound.landscape.controller-unified" : "bound.landscape"
            let modePlacement = model.placement(for: .friend)
            let expectedFriendData = try XCTUnwrap(defaults.data(forKey: prefix + ".option7.placement.friend"))
            let expectedFriend = try JSONDecoder().decode(BoundLandscapeViewPlacement.self, from: expectedFriendData)
            XCTAssertEqual(modePlacement, expectedFriend,
                           "The model should load the exported Friend placement for Controller Mode \(controllerModeEnabled).")
            friendPlacements[controllerModeEnabled] = modePlacement

            let expectedReferenceData = try XCTUnwrap(defaults.data(forKey: prefix + ".option7.placement.reference"))
            let expectedReference = try JSONDecoder().decode(BoundLandscapeViewPlacement.self, from: expectedReferenceData)
            XCTAssertEqual(model.placement(for: .dex), expectedReference,
                           "Option 7 should use its exported shared reference placement in Controller Mode \(controllerModeEnabled).")
            XCTAssertFalse(model.referenceVisible)
            XCTAssertEqual(model.friendVisible, controllerModeEnabled)

            let gameKey = controllerModeEnabled
                ? "bound.landscape.controller-unified.game-screen.v1"
                : "bound.landscape.game-screen.v1"
            let gameData = try XCTUnwrap(defaults.data(forKey: gameKey))
            let expectedGamePlacement = try JSONDecoder().decode(BoundControllerGamePlacement.self, from: gameData)
            let frame = model.configuredGameFrame(baseFrame: gameBase, canvas: canvas)
            XCTAssertEqual(frame, expectedGamePlacement.frame(baseFrame: gameBase, canvas: canvas))
            gameFrames[controllerModeEnabled] = frame

            for button in BoundControllerButton.allCases {
                XCTAssertTrue(model.isButtonVisible(button), "The exported layout keeps \(button) visible in both modes.")
            }
            let buttonKey = controllerModeEnabled
                ? "bound.landscape.controller-unified.buttons.v1"
                : "bound.landscape.buttons.v1"
            let buttonData = try XCTUnwrap(defaults.data(forKey: buttonKey))
            let buttonPlacement = try JSONDecoder().decode(BoundControllerButtonPlacement.self, from: buttonData)
            XCTAssertEqual(buttonPlacement.visibleButtons, Set(BoundControllerButton.allCases))
            for button in BoundControllerButton.allCases {
                let actual = model.buttonFrame(button)
                let expectedFrame = buttonPlacement.frame(for: button,
                    defaultFrame: CGRect(origin: .zero, size: actual.size), canvas: canvas)
                XCTAssertEqual(actual, expectedFrame,
                               "The model should position \(button) from the exported mode-specific placement.")
            }

            model.setActive(false)
        }

        XCTAssertEqual(try XCTUnwrap(gameFrames[false]).origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(gameFrames[true]).origin.x, 0, accuracy: 0.001)
        XCTAssertNotEqual(friendPlacements[false], friendPlacements[true],
                          "Controller Mode on and off retain their separately exported Friend geometry.")
        XCTAssertTrue(defaults.persistentDomain(forName: suite)?.keys.contains {
            $0.hasPrefix("bound.landscape.option7.") || $0.hasPrefix("bound.landscape.controller-unified.option7.")
        } == false, "Opening the bundled layouts should not persist or overwrite their registered defaults.")
    }

    func testExportAfterRegistrationPreservesEveryBundledPreferenceValue() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        Settings.registerPreferenceDefaults(in: defaults)

        let persistentBefore = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        let snapshot = try BoundConfigurationExport.snapshot(defaults: defaults, mappings: [],
                                                             date: Date(timeIntervalSince1970: 1_729_000_000),
                                                             domainName: suite)
        XCTAssertEqual(snapshot["storedPreferenceKeys"] as? [String], [],
                       "Bundled defaults must not be reported as saved user overrides.")
        let groups = try XCTUnwrap(snapshot["preferences"] as? [String: [String: Any]])
        var exported: [String: Any] = [:]
        for values in groups.values {
            for (key, value) in values {
                XCTAssertNil(exported.updateValue(value, forKey: key), "Preference \(key) should have exactly one export section.")
            }
        }

        XCTAssertEqual(BoundDefaultConfiguration.preferences.count, 87)
        for (key, expected) in BoundDefaultConfiguration.preferences {
            let portable = try XCTUnwrap(exported[key], "The configuration export should include \(key).")
            let decoded = try decodePortableValue(portable)
            XCTAssertTrue((expected as? NSObject)?.isEqual(decoded as? NSObject) == true,
                          "Export should round-trip the bundled value for \(key).")
        }
        let persistentAfter = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        XCTAssertEqual(persistentAfter as NSDictionary, persistentBefore as NSDictionary,
                       "Snapshotting must not rewrite the profile marker or save registered defaults as overrides.")
    }

    private func decodePortableValue(_ value: Any) throws -> Any {
        if let wrapper = value as? [String: Any], wrapper["storageType"] as? String == "data" {
            let encoded = try XCTUnwrap(wrapper["base64"] as? String)
            return try XCTUnwrap(Data(base64Encoded: encoded))
        }
        if let array = value as? [Any] {
            return try array.map(decodePortableValue)
        }
        if let dictionary = value as? [String: Any] {
            return try dictionary.mapValues(decodePortableValue)
        }
        return value
    }
}
