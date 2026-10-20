import XCTest
import UIKit
import DeltaCore
@testable import Delta

@MainActor
final class SettingsResetTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "SettingsResetTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testPreferenceResetRestoresFreshDefaultsAndPreservesUserData() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        for key in Settings.defaultPreferences.keys {
            defaults.set("customized", forKey: key)
        }
        defaults.set(["custom shortcut"], forKey: "gameShortcutIdentifiers")
        defaults.set("custom-server.example", forKey: "preferredWFCServer")
        defaults.set("custom-server.example", forKey: "customWFCServer")
        defaults.set("custom-palette", forKey: "preferredGBColorPalette")
        defaults.set("custom-skin", forKey: "gba-landscape-standard-controller")

        BoundUIVersionPreferences(defaults: defaults).version = .option1
        BoundExperimentalSettingsPreferences(defaults: defaults).enabled = true
        let appearance = BoundAppearancePreferences(defaults: defaults)
        appearance.screenLayout = .delta
        appearance.theme = .minimal
        let controllerMode = BoundControllerModePreferences(defaults: defaults)
        controllerMode.isEnabled = true
        controllerMode.layout = .mode3
        let controllerNavigation = BoundControllerNavigationPreferences(defaults: defaults)
        controllerNavigation.isEnabled = true
        defaults.set(Data([1, 2, 3]), forKey: "bound.landscape.controller-mode.buttons.v1")
        defaults.set(Data([4, 5, 6]), forKey: "bound.landscape.controller-mode2.buttons.v1")
        defaults.set(Data([7, 8, 9]), forKey: "bound.landscape.controller-mode3.buttons.v1")
        defaults.set(Data([10, 11, 12]), forKey: "bound.landscape.controller-unified.buttons.v1")
        defaults.set(Data([13, 14, 15]), forKey: "bound.landscape.controller-unified.game-screen.v1")
        let companion = BoundCompanionButtonPreferences(defaults: defaults)
        companion.buttonType = .option3
        let pip = BoundPiPPreferences(defaults: defaults)
        pip.setEnabled(false, for: .dex)
        pip.setScale(1.3, for: .bosses)
        pip.setAssignedContents([.bosses], for: 0, buttonType: .option3)
        defaults.set(3, forKey: BoundReferenceLayoutPreferences.bossKey)
        defaults.set(4, forKey: BoundReferenceLayoutPreferences.dexKey)
        BoundLandscapePreferences(defaults: defaults).option = .option3
        BoundControlPlacementStore(defaults: defaults).save(
            BoundControlLayout(positions: ["button": BoundControlPlacement(x: 0.3, y: 0.4, scale: 1.2)]),
            skin: "test-skin", landscape: true)
        defaults.set("custom", forKey: "respectSilentMode")
        defaults.set("custom", forKey: "mixWithOtherAudio")
        defaults.set("custom", forKey: "pauseOtherAudio")
        defaults.set("custom", forKey: "pauseWhileInactive")
        defaults.set("custom", forKey: "supportsExternalDisplays")

        BoundFastForwardPreferences(defaults: defaults).setEnabled(true, for: "ROM123")

        let protectedValues: [String: Any] = [
            "com.evanvonessen.bound.friend-account.signed-out.https://qevnxhngdtlyihhmvnjv.supabase.co": true,
            "syncingService": "boundCloud",
            "previousGameCollectionIdentifier": "collection-fixture",
            "bound.boss-guide.selection.v1.ROM123": Data([1, 2, 3]),
            "bound.rrdex.choice.v1.ROM123": Data([4, 5, 6]),
            "bound.notes.v1.ROM123": "keep my notes",
            "future.user.data": Data([7, 8, 9])
        ]
        for (key, value) in protectedValues { defaults.set(value, forKey: key) }

        Settings.resetPreferenceValues(in: defaults)

        for (key, value) in Settings.defaultPreferences {
            XCTAssertTrue((defaults.object(forKey: key) as? NSObject)?.isEqual(value) == true,
                          "\(key) should return to its registered fresh-install value.")
        }
        XCTAssertEqual(BoundUIVersionPreferences(defaults: defaults).version, .option2)
        XCTAssertFalse(BoundExperimentalSettingsPreferences(defaults: defaults).enabled)
        XCTAssertEqual(appearance.effectiveScreenLayout, .bound)
        XCTAssertEqual(appearance.effectiveTheme, .delta)
        XCTAssertFalse(BoundFastForwardPreferences(defaults: defaults).isEnabled(for: "ROM123"))
        XCTAssertFalse(controllerMode.isEnabled)
        XCTAssertEqual(controllerMode.layout, .mode1)
        XCTAssertFalse(controllerNavigation.isEnabled)
        XCTAssertNil(defaults.object(forKey: "bound.landscape.controller-mode.buttons.v1"))
        XCTAssertNil(defaults.object(forKey: "bound.landscape.controller-mode2.buttons.v1"))
        XCTAssertNil(defaults.object(forKey: "bound.landscape.controller-mode3.buttons.v1"))
        XCTAssertNil(defaults.object(forKey: "bound.landscape.controller-unified.buttons.v1"))
        XCTAssertNil(defaults.object(forKey: "bound.landscape.controller-unified.game-screen.v1"))
        XCTAssertEqual(companion.buttonType, .option4)
        XCTAssertTrue(pip.isEnabled(.dex))
        XCTAssertEqual(BoundLandscapePreferences(defaults: defaults).option, .option7)
        XCTAssertEqual(BoundControlPlacementStore(defaults: defaults).read(skin: "test-skin", landscape: true), .init())
        XCTAssertNil(defaults.object(forKey: "preferredWFCServer"))
        XCTAssertNil(defaults.object(forKey: "customWFCServer"))
        XCTAssertNil(defaults.object(forKey: "preferredGBColorPalette"))
        XCTAssertNil(defaults.object(forKey: "gba-landscape-standard-controller"))

        for (key, expected) in protectedValues {
            XCTAssertEqual(defaults.object(forKey: key) as? NSObject, expected as? NSObject,
                           "Reset must preserve \(key).")
        }
    }

    func testControllerModeTileTogglesOnAndOffAndPreservesLegacyLayoutForMigration() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(BoundControllerModeLayout.mode3.rawValue, forKey: BoundControllerModePreferences.layoutKey)
        let preferences = BoundControllerModePreferences(defaults: defaults)

        XCTAssertFalse(preferences.isEnabled)
        XCTAssertEqual(preferences.displayName, "OFF")
        XCTAssertEqual(preferences.layout, .mode1, "The unified runtime exposes only its single mode.")
        XCTAssertEqual(defaults.integer(forKey: BoundControllerModePreferences.layoutKey), 3,
                       "The original selected mode remains available to the one-time arrangement migration.")
        preferences.cycle()
        XCTAssertTrue(preferences.isEnabled)
        XCTAssertEqual(preferences.displayName, "ON")
        XCTAssertEqual(defaults.integer(forKey: BoundControllerModePreferences.layoutKey), 3)
        preferences.cycle()
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertEqual(preferences.displayName, "OFF")
        XCTAssertEqual(defaults.integer(forKey: BoundControllerModePreferences.layoutKey), 3)
    }

    func testControllerViewNavigationDefaultsOff() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(BoundControllerNavigationPreferences(defaults: defaults).isEnabled)
    }

    func testResetReloadsCachedOption7Arrangement() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        BoundLandscapePreferences(defaults: defaults).option = .option7
        let model = BoundLandscapeArrangementModel(defaults: defaults)
        model.setContents([.dex, .bosses, .types])
        model.setActive(true)
        model.useOption(.option7)

        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let menu = CGRect(x: 900, y: 20, width: 80, height: 70)
        let bound = CGRect(x: 900, y: 500, width: 80, height: 70)
        let frames: [BoundPiPContent: CGRect] = [
            .friend: CGRect(x: 650, y: 80, width: 240, height: 160),
            .dex: CGRect(x: 380, y: 115, width: 300, height: 360),
            .bosses: CGRect(x: 390, y: 130, width: 260, height: 360),
            .types: CGRect(x: 390, y: 130, width: 260, height: 360),
            .notes: CGRect(x: 390, y: 130, width: 260, height: 360)
        ]
        model.updateLayout(canvas: canvas, occupied: [menu, bound], menuFrame: menu,
                           boundFrame: bound, defaults: frames, keyboardHeight: 0)
        let freshReferenceFrame = model.layout.reference
        model.toggleFriend()
        model.toggleReference()
        model.arrange()
        model.select(.bosses)
        model.move(content: .bosses, translation: CGSize(width: -120, height: 55), ended: true)
        model.finish(save: true)
        XCTAssertEqual(model.friendVisible, false)
        XCTAssertEqual(model.referenceVisible, false)
        XCTAssertEqual(model.referenceContent, .bosses)
        XCTAssertNotEqual(model.layout.reference, freshReferenceFrame)

        Settings.resetPreferenceValues(in: defaults)
        model.reload(option: .option7, controllerModeEnabled: false)
        model.setActive(true)
        model.updateLayout(canvas: canvas, occupied: [menu, bound], menuFrame: menu,
                           boundFrame: bound, defaults: frames, keyboardHeight: 0)

        XCTAssertEqual(model.option, .option7)
        XCTAssertTrue(model.friendVisible)
        XCTAssertTrue(model.referenceVisible)
        XCTAssertEqual(model.referenceContent, .dex)
        XCTAssertEqual(model.layout.reference, freshReferenceFrame,
                       "Reset should discard cached Option 7 placement and restore its fresh geometry.")

        model.useOption(.option6, controllerModeEnabled: true, controllerModeLayout: .mode2)
        model.updateLayout(canvas: canvas, occupied: [menu, bound], menuFrame: menu,
                           boundFrame: bound, defaults: frames, keyboardHeight: 0)
        Settings.resetPreferenceValues(in: defaults)
        model.reload(option: .option7, controllerModeEnabled: false)
        model.updateLayout(canvas: canvas, occupied: [menu, bound], menuFrame: menu,
                           boundFrame: bound, defaults: frames, keyboardHeight: 0)
        XCTAssertFalse(model.controllerModeEnabled)
        XCTAssertEqual(model.controllerModeLayout, .mode1)
        XCTAssertEqual(model.option, .option7)
        XCTAssertEqual(model.layout.reference, freshReferenceFrame,
                       "Reset must also leave the previous Controller Mode arrangement behind.")
    }
}
