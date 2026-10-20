import Foundation
import UIKit
import DeltaCore
import DeltaFeatures

extension Settings.Name {
    static let resetToDefaults: Settings.Name = "resetToDefaults"
}

extension Settings {
    static let didResetNotification = Notification.Name("BoundSettingsDidReset")

    /// Only preference-owned keys belong here. Account, sync, onboarding, ROM
    /// metadata, notes, and save-derived reference data share the defaults store.
    @MainActor
    static func resetPreferenceValues(in defaults: UserDefaults = .standard) {
        var keys = Set(defaultPreferences.keys)
        keys.formUnion([
            "gameShortcutIdentifiers", "preferredWFCServer", "customWFCServer", "preferredGBColorPalette",
            "gameScreenOffsetPortrait", "gameScreenOffsetLandscape",
            "preferredSaveStatesSorting", "prefersDescendingSaveStatesSorting",
            BoundUIVersionPreferences.key, BoundExperimentalSettingsPreferences.key, BoundDeveloperFeatures.key,
            BoundAppearancePreferences.screenLayoutKey, BoundAppearancePreferences.themeKey,
            BoundControllerModePreferences.key, BoundControllerModePreferences.layoutKey,
            BoundControllerNavigationPreferences.key, BoundControllerMultiviewPreferences.key,
            BoundCompanionButtonPreferences.key, BoundCompanionButtonPreferences.legacyKey,
            BoundReferenceLayoutPreferences.bossKey, BoundReferenceLayoutPreferences.dexKey,
            "bound.delta.pip.v1.corner", "bound.delta.pip.v1.view-order"
        ])
        for content in BoundPiPContent.allCases {
            for suffix in ["enabled", "corner", "scale", "opacity"] {
                keys.insert("bound.delta.pip.v1.\(content.rawValue).\(suffix)")
            }
        }
        for button in 1...3 { keys.insert("bound.delta.pip.v1.button.\(button).views") }
        for button in 1...2 { keys.insert("bound.delta.pip.v1.button.option4.\(button).views") }
        for (system, name) in [(System.nes, "nes"), (.snes, "snes"), (.gbc, "gbc"), (.gba, "gba"),
                               (.n64, "n64"), (.ds, "ds"), (.genesis, "genesis")] {
            keys.insert(preferredCoreSettingsKey(for: system.gameType))
            for orientation in ["portrait", "landscape"] {
                for display in ["standard", "splitview"] {
                    for device in ["", "-tv"] {
                        for controller in ["", "-externalcontroller"] {
                            keys.insert("\(name)-\(orientation)-\(display)\(device)\(controller)-controller")
                        }
                    }
                }
            }
        }
        // These feature containers hold settings, including speed and display
        // options. Credentials and account sessions are stored separately.
        for feature in Settings.features.allFeatures + ExperimentalFeatures.shared.allFeatures {
            keys.insert(feature.settingsKey.rawValue)
            // Lu also tracks the active ROM/save and onboarding in hidden options.
            let options = feature.allOptions.filter { feature.key != "Lu" || $0.name != nil }
            keys.formUnion(options.map { $0.settingsKey.rawValue })
        }
        let layoutPrefixes = ["bound.fast-forward.enabled.v1.", "bound.controls.v1.", "bound.landscape.v1.",
            "bound.landscape.option3.", "bound.landscape.option4.", "bound.landscape.option5.",
            "bound.landscape.option6.", "bound.landscape.option7.",
            // Match every controller-mode placement namespace, including new
            // modes added after this reset implementation was introduced.
            "bound.landscape.controller-mode", "bound.landscape.controller-unified.", "bound.landscape.game-screen.v1"]
        keys.formUnion(defaults.dictionaryRepresentation().keys.filter { key in
            layoutPrefixes.contains { key.hasPrefix($0) }
        })
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.register(defaults: defaultPreferences)
    }

    @MainActor
    static func resetToDefaults() async throws {
        let context = DatabaseManager.shared.newBackgroundContext()
        try await context.perform {
            try resetDatabasePreferences(in: context)
            try context.save()
        }
        resetPreferenceValues()
        UIApplication.shared.shortcutItems = nil
        // Refresh cached models even when the chosen layout hasn't changed.
        NotificationCenter.default.post(name: didResetNotification, object: nil)
        localControllerPlayerIndex = 0
        for name in [BoundAppearancePreferences.didChangeNotification, BoundUIVersionPreferences.didChangeNotification,
                     BoundCompanionButtonPreferences.didChangeNotification, BoundPiPPreferences.didChangeNotification,
                     BoundLandscapePreferences.didChangeNotification] {
            NotificationCenter.default.post(name: name, object: nil)
        }
        for name: Settings.Name in [.resetToDefaults, .respectSilentMode, .mixWithOtherAudio, .pauseOtherAudio,
                                   .pauseWhileInactive, .supportsExternalDisplays, .dsAirPlayTopScreenOnly] {
            NotificationCenter.default.post(name: didChangeNotification, object: nil,
                userInfo: [NotificationUserInfoKey.name: name])
        }
    }
}
