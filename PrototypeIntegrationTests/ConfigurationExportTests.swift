import XCTest
import CoreData
import DeltaCore
@testable import Delta

@MainActor
final class ConfigurationExportTests: XCTestCase {
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
        let suite = "ConfigurationExportTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func inMemoryContext() throws -> NSManagedObjectContext {
        let modelURL = try XCTUnwrap(Bundle(for: DatabaseManager.self).url(forResource: "Delta", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    func testSnapshotIncludesBothControllerModeArrangementsAndPortableLayoutsWithoutMutatingDefaults() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: BoundControllerModePreferences.key)
        defaults.set(0.43, forKey: "translucentControllerSkinOpacity")
        defaults.set(true, forKey: BoundControllerButtonGridPreferences.enabledKey)
        defaults.set(24, forKey: BoundControllerButtonGridPreferences.spacingKey)
        defaults.set(true, forKey: Settings.Name.respectSilentMode.rawValue)
        defaults.set(true, forKey: Settings.Name.mixWithOtherAudio.rawValue)
        defaults.set(true, forKey: Settings.Name.pauseOtherAudio.rawValue)
        defaults.set(7, forKey: "bound.landscape.v1.option")
        defaults.set(Data("{\"positions\":{\"a\":{\"x\":0.2,\"y\":0.8,\"scale\":1.1}}}".utf8),
                     forKey: "bound.controls.v1.test-skin.landscape")
        defaults.set(Data("{\"positions\":{\"b\":{\"x\":0.7,\"y\":0.4,\"scale\":0.9}}}".utf8),
                     forKey: "bound.controls.v1.test-skin.portrait")

        let offPrefix = "bound.landscape.option7."
        defaults.set(true, forKey: offPrefix + "friend-visible")
        defaults.set(Data("{\"center\":{\"x\":0.72,\"y\":0.31},\"widthFraction\":0.3,\"heightFraction\":0.4,\"opacity\":0.62,\"aboveButtons\":false}".utf8),
                     forKey: offPrefix + "placement.friend")
        defaults.set(Data("{\"center\":{\"x\":0.28,\"y\":0.55},\"widthFraction\":0.44,\"heightFraction\":0.65,\"opacity\":0.77}".utf8),
                     forKey: offPrefix + "placement.reference")
        defaults.set("types", forKey: offPrefix + "reference-content")
        defaults.set(Data("{\"scale\":0.84,\"horizontalPosition\":0.71}".utf8),
                     forKey: "bound.landscape.game-screen.v1")
        defaults.set(Data("{\"menu\":{\"x\":0.9,\"y\":0.8},\"visibleButtons\":[\"menu\",\"friend\"]}".utf8),
                     forKey: "bound.landscape.buttons.v1")

        let onPrefix = "bound.landscape.controller-unified.option7."
        defaults.set(false, forKey: onPrefix + "friend-visible")
        defaults.set(Data("{\"center\":{\"x\":0.13,\"y\":0.26},\"widthFraction\":0.36,\"heightFraction\":0.51,\"opacity\":0.49,\"allowsButtonOverlap\":true}".utf8),
                     forKey: onPrefix + "placement.friend")
        defaults.set(Data("{\"center\":{\"x\":0.81,\"y\":0.48},\"widthFraction\":0.38,\"heightFraction\":0.58,\"opacity\":0.91}".utf8),
                     forKey: onPrefix + "placement.reference")
        defaults.set("bosses", forKey: onPrefix + "reference-content")
        defaults.set(Data("{\"scale\":0.73,\"horizontalPosition\":0.88}".utf8),
                     forKey: "bound.landscape.controller-unified.game-screen.v1")
        defaults.set(Data("{\"menu\":{\"x\":0.1,\"y\":0.9},\"visibleButtons\":[\"menu\",\"multiview\"]}".utf8),
                     forKey: "bound.landscape.controller-unified.buttons.v1")

        let protectedValues: [String: Any] = [
            "com.evanvonessen.bound.friend-account.signed-out.fixture": true,
            "bound.notes.v1.fixture-rom": "private notes",
            "bound.rrdex.choice.v1.fixture-rom": Data([1, 2, 3]),
            "bound.fast-forward.enabled.v1.fixture-rom": true,
            "rom.fixture.identifier": "fixture-rom",
            "bound.rom-updates.folder-bookmark.v1": Data("private-rom-folder-bookmark".utf8),
            "bound.rom-updates.folder-name.v1": "Private ROM Folder",
            "bound.rom-updates.enabled.v1": true,
            "bound.rom-updates.enrollment-game.v1": "private-enrollment-game",
            (Bundle.main.bundleIdentifier ?? "Bound") + ".github.signed-out": true,
            BoundDeveloperFeatures.legacyDebuggingKey: true,
            BoundDeveloperFeatures.key: true
        ]
        for (key, value) in protectedValues { defaults.set(value, forKey: key) }
        let before = defaults.dictionaryRepresentation()

        let exportedAt = Date(timeIntervalSince1970: 1_729_000_000)
        let snapshot = try BoundConfigurationExport.snapshot(defaults: defaults, mappings: [], date: exportedAt,
                                                             domainName: suite)
        let storedKeys = try XCTUnwrap(snapshot["storedPreferenceKeys"] as? [String])
        XCTAssertTrue(storedKeys.contains("translucentControllerSkinOpacity"))
        XCTAssertFalse(storedKeys.contains(BoundUIVersionPreferences.key))
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let preferences = try XCTUnwrap(roundTrip["preferences"] as? [String: [String: Any]])

        XCTAssertEqual(roundTrip["format"] as? String, "bound-configuration")
        XCTAssertEqual(roundTrip["schemaVersion"] as? Int, 1)
        XCTAssertEqual(roundTrip["exportedAt"] as? String, ISO8601DateFormatter().string(from: exportedAt))
        XCTAssertEqual((roundTrip["effectiveInterface"] as? [String: Any])?["controllerModeEnabled"] as? Bool, true)
        XCTAssertEqual(preferences["settings"]?["translucentControllerSkinOpacity"] as? Double, 0.43)
        XCTAssertEqual(preferences["settings"]?[BoundControllerButtonGridPreferences.enabledKey] as? Bool, true)
        XCTAssertEqual(preferences["settings"]?[BoundControllerButtonGridPreferences.spacingKey] as? Double, 18)
        for key in [Settings.Name.respectSilentMode, .mixWithOtherAudio, .pauseOtherAudio] {
            XCTAssertEqual(preferences["settings"]?[key.rawValue] as? Bool, true)
        }

        let off = try XCTUnwrap(preferences["controllerModeOff"])
        let offPlacement = try XCTUnwrap(off[offPrefix + "placement.reference"] as? [String: Any])
        XCTAssertEqual(try decodedData(offPlacement), Data("{\"center\":{\"x\":0.28,\"y\":0.55},\"widthFraction\":0.44,\"heightFraction\":0.65,\"opacity\":0.77}".utf8))
        XCTAssertNotNil(off["bound.landscape.game-screen.v1"])
        XCTAssertNotNil(off["bound.landscape.buttons.v1"])
        let offButtons = try XCTUnwrap(off["bound.landscape.buttons.v1"] as? [String: Any])
        XCTAssertEqual(try decodedData(offButtons), defaults.data(forKey: "bound.landscape.buttons.v1"))

        let on = try XCTUnwrap(preferences["controllerModeOn"])
        XCTAssertEqual(on[onPrefix + "friend-visible"] as? Bool, false)
        let onPlacement = try XCTUnwrap(on[onPrefix + "placement.friend"] as? [String: Any])
        XCTAssertEqual(try decodedData(onPlacement), Data("{\"center\":{\"x\":0.13,\"y\":0.26},\"widthFraction\":0.36,\"heightFraction\":0.51,\"opacity\":0.49,\"allowsButtonOverlap\":true}".utf8))
        XCTAssertNotNil(on["bound.landscape.controller-unified.game-screen.v1"])
        XCTAssertNotNil(on["bound.landscape.controller-unified.buttons.v1"])
        let onButtons = try XCTUnwrap(on["bound.landscape.controller-unified.buttons.v1"] as? [String: Any])
        XCTAssertEqual(try decodedData(onButtons), defaults.data(forKey: "bound.landscape.controller-unified.buttons.v1"))

        let touch = try XCTUnwrap(preferences["touchControlLayouts"])
        XCTAssertNotNil(touch["bound.controls.v1.test-skin.landscape"])
        XCTAssertNotNil(touch["bound.controls.v1.test-skin.portrait"])
        XCTAssertEqual((preferences["landscapeCommon"]?["bound.landscape.v1.option"] as? Int), 7)
        XCTAssertTrue(preferences["landscapeCommon"]?.keys.contains("bound.landscape.v1.friend-placement") == true)

        let jsonText = String(decoding: data, as: UTF8.self)
        for (key, _) in protectedValues {
            XCTAssertFalse(jsonText.contains(key), "The configuration file must exclude \(key).")
        }
        XCTAssertFalse(jsonText.contains("private notes"))
        XCTAssertFalse(jsonText.contains("fixture-rom"))
        XCTAssertFalse(jsonText.contains("Private ROM Folder"))
        XCTAssertFalse(jsonText.contains("private-enrollment-game"))
        XCTAssertFalse(jsonText.contains(Data("private-rom-folder-bookmark".utf8).base64EncodedString()))
        XCTAssertEqual(defaults.dictionaryRepresentation().count, before.count, "Export must not add, remove, or migrate preferences.")
        for (key, value) in before {
            XCTAssertEqual(defaults.object(forKey: key) as? NSObject, value as? NSObject,
                           "Export must preserve the existing value for \(key).")
        }
    }

    func testFreshInstallSnapshotMaterializesBundledDefaultsWithoutChangingSuite() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = defaults.dictionaryRepresentation()

        let snapshot = try BoundConfigurationExport.snapshot(defaults: defaults, mappings: [],
                                                             date: Date(timeIntervalSince1970: 1_729_000_000),
                                                             domainName: suite)
        let preferences = try XCTUnwrap(snapshot["preferences"] as? [String: [String: Any]])
        let settings = try XCTUnwrap(preferences["settings"])
        let interface = try XCTUnwrap(snapshot["effectiveInterface"] as? [String: Any])
        let pip = BoundPiPPreferences(defaults: defaults)

        XCTAssertEqual(interface["uiVersion"] as? Int, BoundUIVersion.option2.rawValue)
        XCTAssertEqual(interface["landscapeOption"] as? Int, BoundLandscapeOption.option7.rawValue)
        XCTAssertEqual(interface["controllerModeEnabled"] as? Bool, false)
        XCTAssertEqual(settings["translucentControllerSkinOpacity"] as? Double, 0.7)
        XCTAssertEqual(settings[BoundControllerButtonGridPreferences.enabledKey] as? Bool, true)
        XCTAssertEqual(settings[BoundControllerButtonGridPreferences.spacingKey] as? Double, 18)
        for (group, namespace, visible) in [
            ("controllerModeOff", "bound.landscape", Set(BoundControllerButton.allCases)),
            ("controllerModeOn", "bound.landscape.controller-unified", Set(BoundControllerButton.allCases))
        ] {
            let buttons = try XCTUnwrap(preferences[group]?[namespace + ".buttons.v1"] as? [String: Any])
            let placement = try JSONDecoder().decode(BoundControllerButtonPlacement.self, from: decodedData(buttons))
            XCTAssertEqual(placement.visibleButtons, visible)
        }
        XCTAssertEqual(settings["bound.delta.pip.v1.bosses.layout"] as? Int, 12)
        XCTAssertEqual(settings["bound.delta.pip.v1.dex.layout"] as? Int, 12)
        for content in BoundPiPContent.allCases {
            XCTAssertEqual(settings["bound.delta.pip.v1.\(content.rawValue).opacity"] as? Double,
                           content == .types ? 1 : pip.opacity(for: content))
        }
        XCTAssertNil(defaults.object(forKey: BoundDeveloperFeatures.key), "Developer Features is not part of exported app defaults.")
        XCTAssertEqual(defaults.dictionaryRepresentation().count, before.count,
                       "Reading fresh-install values for the export must not persist defaults into the user suite.")
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
    }

    func testExportUsesPermanentGridAndNavigationDespiteLegacyPreferences() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        func exportedGridValue() throws -> Bool? {
            let snapshot = try BoundConfigurationExport.snapshot(defaults: defaults, mappings: [], domainName: suite)
            let preferences = try XCTUnwrap(snapshot["preferences"] as? [String: [String: Any]])
            let settings = try XCTUnwrap(preferences["settings"])
            return settings[BoundControllerButtonGridPreferences.enabledKey] as? Bool
        }

        XCTAssertEqual(try exportedGridValue(), true)
        defaults.set(false, forKey: BoundControllerButtonGridPreferences.enabledKey)
        defaults.set(48, forKey: BoundControllerButtonGridPreferences.spacingKey)
        defaults.set(false, forKey: BoundControllerNavigationPreferences.key)
        let before = defaults.dictionaryRepresentation()
        XCTAssertEqual(try exportedGridValue(), true)
        XCTAssertTrue(BoundControllerButtonGridPreferences.isEnabled(in: defaults))
        let snapshot = try BoundConfigurationExport.snapshot(defaults: defaults, mappings: [], domainName: suite)
        let settings = try XCTUnwrap((snapshot["preferences"] as? [String: [String: Any]])?["settings"])
        XCTAssertEqual(settings[BoundControllerButtonGridPreferences.spacingKey] as? Double, 18)
        XCTAssertEqual(settings[BoundControllerNavigationPreferences.key] as? Bool, true)
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
    }

    func testControllerMappingsExportAllSavedPlayersAndControllerTypesWithoutDatabaseIdentifiers() throws {
        let context = try inMemoryContext()
        defer { context.reset() }

        try context.performAndWait {
            var firstMap = DeltaCore.GameControllerInputMapping(gameControllerInputType: .mfi)
            firstMap.set(ActionInput.none, forControllerInput: MFiGameController.Input.a)
            firstMap.set(ActionInput.systemOverlay, forControllerInput: MFiGameController.Input.b)
            firstMap.set(StandardGameControllerInput.menu, forControllerInput: MFiGameController.Input.menu)
            firstMap.set(ActionInput.toggleBoundFriend, forControllerInput: MFiGameController.Input.leftThumbstickButton)
            let first = GameControllerInputMapping(inputMapping: firstMap, context: context)
            first.gameType = .gba
            first.gameControllerInputType = .mfi
            first.playerIndex = 0

            var disconnectedMap = DeltaCore.GameControllerInputMapping(gameControllerInputType: .mfi)
            disconnectedMap.set(ActionInput.boundNextView, forControllerInput: MFiGameController.Input.rightThumbstickButton)
            let disconnected = GameControllerInputMapping(inputMapping: disconnectedMap, context: context)
            disconnected.gameType = .gba
            disconnected.gameControllerInputType = .mfi
            disconnected.playerIndex = 2

            var alternateMap = DeltaCore.GameControllerInputMapping(gameControllerInputType: .standard)
            alternateMap.set(ActionInput.toggleBoundMultiview, forControllerInput: StandardGameControllerInput.x)
            let alternate = GameControllerInputMapping(inputMapping: alternateMap, context: context)
            alternate.gameType = .gba
            alternate.gameControllerInputType = .standard
            alternate.playerIndex = 0

            try context.save()
        }

        let mappings = try BoundConfigurationExport.controllerMappings(in: context)
        XCTAssertEqual(mappings.count, 3, "Mappings must include disconnected player and controller-type records.")
        XCTAssertEqual(mappings.map(\.playerIndex), [0, 0, 2])
        XCTAssertTrue(mappings.contains { $0.playerIndex == 2 && $0.controllerType == GameControllerInputType.mfi.rawValue })
        let json = try JSONEncoder().encode(mappings)
        let decoded = try JSONDecoder().decode([BoundConfigurationExport.ControllerMapping].self, from: json)
        XCTAssertEqual(decoded.count, 3)

        let primary = try XCTUnwrap(decoded.first { $0.playerIndex == 0 && $0.controllerType == GameControllerInputType.mfi.rawValue })
        XCTAssertEqual(primary.bindings[MFiGameController.Input.a.stringValue]?.identifier, ActionInput.none.rawValue)
        XCTAssertEqual(primary.bindings[MFiGameController.Input.b.stringValue]?.identifier, ActionInput.systemOverlay.rawValue)
        XCTAssertEqual(primary.bindings[MFiGameController.Input.menu.stringValue]?.identifier, StandardGameControllerInput.menu.stringValue)
        XCTAssertEqual(primary.bindings[MFiGameController.Input.leftThumbstickButton.stringValue]?.identifier, ActionInput.toggleBoundFriend.rawValue)
        let disconnected = try XCTUnwrap(decoded.first { $0.playerIndex == 2 })
        XCTAssertEqual(disconnected.bindings[MFiGameController.Input.rightThumbstickButton.stringValue]?.identifier, ActionInput.boundNextView.rawValue)

        let mappingObjects = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        for object in mappingObjects {
            XCTAssertEqual(Set(object.keys), Set(["playerIndex", "gameType", "controllerType", "bindings"]))
        }
        let jsonText = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(jsonText.contains("deltaCoreInputMapping"))
    }

    func testDeveloperToolsMigrationRunsDuringPreferenceRegistrationAndResetStaysOff() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: BoundDeveloperFeatures.legacyDebuggingKey)
        Settings.registerPreferenceDefaults(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: BoundDeveloperFeatures.key))
        XCTAssertNil(defaults.object(forKey: BoundDeveloperFeatures.legacyDebuggingKey))
        Settings.resetPreferenceValues(in: defaults)
        Settings.registerPreferenceDefaults(in: defaults)
        XCTAssertFalse(defaults.bool(forKey: BoundDeveloperFeatures.key))
    }

    func testPreferenceResetTurnsOffDeveloperFeaturesAndPreservesAccountsAndLibraryData() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: BoundDeveloperFeatures.key)
        XCTAssertFalse(defaults.bool(forKey: BoundDeveloperFeatures.legacyDebuggingKey))
        defaults.set(true, forKey: BoundDeveloperFeatures.legacyDebuggingKey)
        let protected: [String: Any] = [
            "com.evanvonessen.bound.friend-account.signed-out.fixture": true,
            "syncingService": "boundCloud",
            "bound.notes.v1.fixture-rom": "keep",
            "bound.rrdex.choice.v1.fixture-rom": Data([4, 5]),
            "rom.fixture.identifier": "fixture-rom"
        ]
        for (key, value) in protected { defaults.set(value, forKey: key) }

        Settings.resetPreferenceValues(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: BoundDeveloperFeatures.key))
        XCTAssertFalse(defaults.bool(forKey: BoundDeveloperFeatures.legacyDebuggingKey))
        for (key, value) in protected {
            XCTAssertEqual(defaults.object(forKey: key) as? NSObject, value as? NSObject,
                           "Reset must preserve protected user data at \(key).")
        }
    }

    private func decodedData(_ wrapper: [String: Any]) throws -> Data {
        XCTAssertEqual(wrapper["storageType"] as? String, "data")
        return try XCTUnwrap((wrapper["base64"] as? String).flatMap { Data(base64Encoded: $0) })
    }

    func testPreparedExportFileContainsJSONAndCleansOnlyItsOwnTemporaryDirectory() throws {
        let data = Data("{\"format\":\"bound-configuration\",\"schemaVersion\":1}".utf8)
        let first = try BoundConfigurationExport.temporaryFile(data: data)
        let second = try BoundConfigurationExport.temporaryFile(data: data)
        defer { first.removeTemporaryFile(); second.removeTemporaryFile() }
        XCTAssertEqual(first.url.pathExtension, "json")
        XCTAssertTrue(first.url.lastPathComponent.hasPrefix("Bound-Config-"))
        XCTAssertEqual(try Data(contentsOf: first.url), data)
        XCTAssertNotEqual(first.url.deletingLastPathComponent(), second.url.deletingLastPathComponent())
        first.removeTemporaryFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(try Data(contentsOf: second.url), data)
    }
}
