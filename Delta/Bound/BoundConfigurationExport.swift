import CoreData
import DeltaCore
import DeltaFeatures
import SwiftUI

enum BoundDeveloperFeatures {
    static let key = "bound.developer-features.enabled.v1"
}

struct BoundConfigurationDocument {
    let data: Data
}

struct BoundConfigurationFile: Identifiable {
    let url: URL
    var id: URL { url }
    func removeTemporaryFile() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct BoundConfigurationFilePicker: UIViewControllerRepresentable {
    let file: BoundConfigurationFile
    var finished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(file: file, finished: finished) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}
    static func dismantleUIViewController(_ picker: UIDocumentPickerViewController, coordinator: Coordinator) {
        coordinator.file.removeTemporaryFile()
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let file: BoundConfigurationFile
        let finished: () -> Void
        init(file: BoundConfigurationFile, finished: @escaping () -> Void) {
            self.file = file
            self.finished = finished
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished() }
    }
}

/// Portable settings only: never export the defaults domain or the database wholesale.
@MainActor
enum BoundConfigurationExport {
    struct Binding: Codable, Sendable {
        let identifier: String
        let type: String
        let isContinuous: Bool
    }

    struct ControllerMapping: Codable, Sendable {
        let playerIndex: Int
        let gameType: String
        let controllerType: String
        let bindings: [String: Binding]
    }

    static var defaultFilename: String {
        "Bound-Config-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    static func file() async throws -> BoundConfigurationFile {
        let document = try await document()
        return try temporaryFile(data: document.data)
    }

    static func temporaryFile(data: Data) throws -> BoundConfigurationFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Bound-Config-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = BoundConfigurationFile(url: directory.appendingPathComponent(defaultFilename).appendingPathExtension("json"))
        do { try data.write(to: file.url, options: .atomic) }
        catch { file.removeTemporaryFile(); throw error }
        return file
    }

    static func document() async throws -> BoundConfigurationDocument {
        let context = DatabaseManager.shared.newBackgroundContext()
        let mappings = try await context.perform { try controllerMappings(in: context) }
        var snapshot = try snapshot(defaults: .standard, mappings: mappings)
        let screen = UIScreen.main
        snapshot["device"] = [
            "model": UIDevice.current.model,
            "systemVersion": UIDevice.current.systemVersion,
            "screenWidthPoints": screen.bounds.width,
            "screenHeightPoints": screen.bounds.height,
            "screenScale": screen.scale
        ]
        // Include stock mappings too, so an absent custom mapping can be understood
        // without requiring the same physical controller to be connected later.
        snapshot["connectedControllerDefaults"] = ExternalGameControllerManager.shared.connectedControllers.map { controller in
            ["controllerType": controller.inputType.rawValue,
             "playerIndex": controller.playerIndex.map { $0 as Any } ?? NSNull(),
             "bindings": (try? json(bindings(in: BoundMultiviewDefaultMapping.mapping(for: controller)))) ?? [:]] as [String: Any]
        }
        return BoundConfigurationDocument(data: try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
    }

    nonisolated static func controllerMappings(in context: NSManagedObjectContext) throws -> [ControllerMapping] {
        try context.fetch(GameControllerInputMapping.fetchRequest()).filter { !$0.isDeleted }.map { record in
            guard let mapping = record.deltaCoreInputMapping as? DeltaCore.GameControllerInputMapping else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return ControllerMapping(playerIndex: Int(record.playerIndex), gameType: record.gameType.rawValue,
                                     controllerType: record.gameControllerInputType.rawValue, bindings: bindings(in: mapping))
        }.sorted {
            ($0.playerIndex, $0.gameType, $0.controllerType) < ($1.playerIndex, $1.gameType, $1.controllerType)
        }
    }

    nonisolated private static func bindings(in mapping: DeltaCore.GameControllerInputMapping?) -> [String: Binding] {
        guard let mapping else { return [:] }
        return Dictionary(uniqueKeysWithValues: mapping.supportedControllerInputs.compactMap { input in
            guard let action = mapping.input(forControllerInput: input) else { return nil }
            return (input.stringValue, Binding(identifier: action.stringValue, type: action.type.rawValue,
                                               isContinuous: action.isContinuous))
        })
    }

    static func snapshot(defaults: UserDefaults, mappings: [ControllerMapping], date: Date = Date()) throws -> [String: Any] {
        let all = defaults.dictionaryRepresentation()
        let keys = preferenceKeys(in: all)
        let saved = all.filter { keys.contains($0.key) }
        let effective = try effectivePreferences(defaults: defaults).merging(saved) { _, saved in saved }
        let sections = [
            "settings": effective.filter { !$0.key.hasPrefix("bound.landscape.") && !$0.key.hasPrefix("bound.controls.v1.") },
            "touchControlLayouts": effective.filter { $0.key.hasPrefix("bound.controls.v1.") },
            "landscapeCommon": effective.filter { $0.key.hasPrefix("bound.landscape.v1.") },
            "controllerModeOff": effective.filter { $0.key.hasPrefix("bound.landscape.option") || $0.key == "bound.landscape.game-screen.v1" || $0.key == "bound.landscape.buttons.v1" },
            "controllerModeOn": effective.filter { $0.key.hasPrefix("bound.landscape.controller-unified.") },
            "legacyControllerLayouts": effective.filter { $0.key.hasPrefix("bound.landscape.controller-mode") }
        ]
        return [
            "format": "bound-configuration",
            "schemaVersion": 1,
            "exportedAt": ISO8601DateFormatter().string(from: date),
            "app": ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                    "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown"],
            "preferences": try sections.mapValues { try $0.mapValues(portableValue) },
            "storedPreferenceKeys": saved.keys.sorted(),
            "controllerMappings": try json(mappings),
            "effectiveInterface": [
                "uiVersion": BoundUIVersionPreferences(defaults: defaults).effectiveVersion.rawValue,
                "screenLayout": BoundAppearancePreferences(defaults: defaults).effectiveScreenLayout.rawValue,
                "theme": BoundAppearancePreferences(defaults: defaults).effectiveTheme.rawValue,
                "controllerModeEnabled": BoundControllerModePreferences(defaults: defaults).isEnabled,
                "landscapeOption": BoundLandscapePreferences(defaults: defaults).option.rawValue
            ],
            "interpretation": [
                "purpose": "Snapshot for preparing future app defaults; exporting does not change current defaults.",
                "dataValues": "Data retains exact base64 bytes and decoded JSON where available.",
                "missingLayoutKeys": "Use the bundled defaults from this app version and build.",
                "controllerMappings": "Complete saved maps, including disconnected controllers. Player indices are zero-based; missing inputs are unbound. None and Overlay remain distinct actions.",
                "coordinates": "Placements retain their original normalized coordinates, sizes, opacity, layering and canvas flags.",
                "buttonGrid": "Only Menu, Friend and Multiview button centers use the optional grid. Spacing is in screen points and the grid origin is the full screen center. Saved placements include free or snapped positions separately for Controller Mode on and off.",
                "excluded": "Accounts, credentials, ROMs, saves, notes, per-ROM progress and developer-tool state."
            ]
        ]
    }

    private static func preferenceKeys(in values: [String: Any]) -> Set<String> {
        var keys = Set(Settings.defaultPreferences.keys)
        keys.formUnion([
            BoundUIVersionPreferences.key, BoundAppearancePreferences.screenLayoutKey, BoundAppearancePreferences.themeKey,
            BoundControllerModePreferences.key, BoundControllerModePreferences.layoutKey, BoundControllerNavigationPreferences.key, BoundControllerMultiviewPreferences.key,
            BoundControllerButtonGridPreferences.enabledKey, BoundControllerButtonGridPreferences.spacingKey,
            "gameScreenOffsetPortrait", "gameScreenOffsetLandscape", "preferredGBColorPalette",
            "preferredSaveStatesSorting", "prefersDescendingSaveStatesSorting"
        ])
        // Feature wrappers may hold game history or service state. Only these
        // known presentation/control features belong in a defaults template.
        let portableFeatures: Set<String> = ["airPlaySkins", "showStatusBar", "toastNotifications", "skinDebugging",
                                             "reverseScreens", "showTouches", "metal", "screenshotsAlbum"]
        let features = Settings.features.allFeatures + ExperimentalFeatures.shared.allFeatures.filter { portableFeatures.contains($0.key) }
        for feature in features {
            keys.insert(feature.settingsKey.rawValue)
            keys.formUnion(feature.allOptions.map { $0.settingsKey.rawValue })
        }
        for (system, name) in [(System.nes, "nes"), (.snes, "snes"), (.gbc, "gbc"), (.gba, "gba"), (.n64, "n64"), (.ds, "ds"), (.genesis, "genesis")] {
            keys.insert(Settings.preferredCoreSettingsKey(for: system.gameType))
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
        let prefixes = ["bound.delta.pip.v1.", "bound.delta.pip.v2.", "bound.controls.v1.", "bound.landscape.v1.",
                        "bound.landscape.option3.", "bound.landscape.option4.", "bound.landscape.option5.",
                        "bound.landscape.option6.", "bound.landscape.option7.", "bound.landscape.controller-mode.",
                        "bound.landscape.controller-mode2.", "bound.landscape.controller-mode3.", "bound.landscape.controller-unified."]
        keys.formUnion(["bound.landscape.game-screen.v1", "bound.landscape.buttons.v1"])
        keys.formUnion(values.keys.filter { key in prefixes.contains { key.hasPrefix($0) } })
        return keys
    }

    /// Materialize implicit defaults as well as explicit settings. Do not call
    /// migration-backed getters that write to the user's preferences during export.
    private static func effectivePreferences(defaults: UserDefaults) throws -> [String: Any] {
        var values = Settings.defaultPreferences
        values[BoundUIVersionPreferences.key] = BoundUIVersionPreferences(defaults: defaults).version.rawValue
        values[BoundAppearancePreferences.screenLayoutKey] = BoundAppearancePreferences(defaults: defaults).screenLayout.rawValue
        values[BoundAppearancePreferences.themeKey] = BoundAppearancePreferences(defaults: defaults).theme.rawValue
        values[BoundControllerModePreferences.key] = BoundControllerModePreferences(defaults: defaults).isEnabled
        values[BoundControllerNavigationPreferences.key] = BoundControllerNavigationPreferences(defaults: defaults).isEnabled
        values[BoundControllerMultiviewPreferences.key] = BoundControllerMultiviewPreferences(defaults: defaults).isEnabled
        values[BoundControllerButtonGridPreferences.enabledKey] = BoundControllerButtonGridPreferences.isEnabled(in: defaults)
        values[BoundControllerButtonGridPreferences.spacingKey] = Double(BoundControllerButtonGridPreferences.spacing(in: defaults))
        values[BoundCompanionButtonPreferences.key] = BoundCompanionButtonPreferences(defaults: defaults).buttonType.rawValue
        values[BoundReferenceLayoutPreferences.bossKey] = 12
        values[BoundReferenceLayoutPreferences.dexKey] = 12
        let pip = BoundPiPPreferences(defaults: defaults)
        values["bound.delta.pip.v1.corner"] = pip.corner.rawValue
        values["bound.delta.pip.v1.view-order"] = pip.orderedContents.map(\.rawValue)
        for content in BoundPiPContent.allCases {
            let prefix = "bound.delta.pip.v1." + content.rawValue
            values[prefix + ".enabled"] = pip.isEnabled(content)
            values[prefix + ".scale"] = pip.scale(for: content)
            values[prefix + ".opacity"] = pip.opacity(for: content)
            values[prefix + ".corner"] = defaults.string(forKey: prefix + ".corner") ?? pip.corner.rawValue
        }
        for type in [BoundCompanionButtonType.option3, .option4] {
            for button in 0..<type.splitButtonCount {
                let suffix = type == .option3 ? "button.\(button + 1).views" : "button.option4.\(button + 1).views"
                values["bound.delta.pip.v1." + suffix] = pip.assignedContents(for: button, buttonType: type).map(\.rawValue)
            }
        }
        let landscape = BoundLandscapePreferences(defaults: defaults)
        values["bound.landscape.v1.option"] = landscape.option.rawValue
        values["bound.landscape.v1.reference-contents"] = landscape.referenceContents.map(\.rawValue)
        values["bound.landscape.v1.reference-content"] = landscape.referenceContent.rawValue
        values["bound.landscape.v1.friend-visible"] = landscape.friendVisible
        values["bound.landscape.v1.reference-visible"] = landscape.referenceVisible
        values["bound.landscape.v1.reference-scale"] = landscape.referenceScale
        values["bound.landscape.v1.friend-placement"] = try JSONEncoder().encode(landscape.friendPlacement)
        for namespace in ["bound.landscape", "bound.landscape.controller-unified"] {
            values[namespace + ".game-screen.v1"] = try JSONEncoder().encode(BoundControllerGamePlacement())
            let visibleButtons: Set<BoundControllerButton> = namespace == "bound.landscape" ? Set(BoundControllerButton.allCases) : [.menu]
            values[namespace + ".buttons.v1"] = try JSONEncoder().encode(BoundControllerButtonPlacement(visibleButtons: visibleButtons))
        }
        return values
    }

    private static func portableValue(_ value: Any) throws -> Any {
        if let data = value as? Data {
            var encoded: [String: Any] = ["storageType": "data", "base64": data.base64EncodedString()]
            if let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                encoded["decodedJSON"] = decoded
            }
            return encoded
        }
        if let date = value as? Date { return ["storageType": "date", "iso8601": ISO8601DateFormatter().string(from: date)] }
        if let array = value as? [Any] { return try array.map(portableValue) }
        if let dictionary = value as? [String: Any] { return try dictionary.mapValues(portableValue) }
        if value is String || value is NSNumber || value is NSNull { return value }
        throw CocoaError(.fileWriteInapplicableStringEncoding)
    }

    private static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
}
