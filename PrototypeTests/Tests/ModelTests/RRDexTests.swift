import Foundation
import XCTest
@testable import Models

final class RRDexTests: XCTestCase {
    func testFullCatalogAndRadicalRedSpecificForms() throws {
        let c = try XCTUnwrap(BoundRRDexCatalog.bundled)
        XCTAssertEqual(c.species.count, 1343)
        XCTAssertEqual(c.moves.count, 1003)
        XCTAssertEqual(c.types.count, 18)
        XCTAssertEqual(c.sourceSHA256, "04c9dc94b6a7e3d33f5dcb5e804487466e7a249f4d340cf19853d70f37596df9")
        let bulbasaur = try XCTUnwrap(c.pokemon(id: 1))
        XCTAssertEqual(bulbasaur.stats, [45, 49, 49, 65, 65, 45])
        XCTAssertEqual(c.abilityNames(for: bulbasaur, save: nil), ["Overgrow", "Chlorophyll (Hidden)"])
        XCTAssertEqual(Array(try XCTUnwrap(Data(base64Encoded: bulbasaur.sprite)).prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertTrue(c.suggestions("Sevii").count > 10)
        XCTAssertEqual(c.pokemon(id: 154)?.types.compactMap { c.type(id: $0)?.name }, ["Grass", "Fairy"])
        for p in c.species {
            XCTAssertNotNil(Data(base64Encoded: p.sprite), p.name)
            XCTAssertFalse(c.abilityNames(for: p, save: nil).isEmpty, p.name)
            XCTAssertEqual(p.stats.count, 6)
        }
    }
    func testLiveSuggestionsEvolutionMethodsAndTypeOnlyMatchups() throws {
        let c = try XCTUnwrap(BoundRRDexCatalog.bundled)
        XCTAssertTrue(c.suggestions("").isEmpty)
        XCTAssertTrue(c.suggestions("   ").isEmpty)
        XCTAssertEqual(c.suggestions("bu").first?.name, "Bulbasaur")
        XCTAssertTrue(c.suggestions("bulb").count < c.suggestions("bu").count)
        XCTAssertEqual(c.suggestions("BuLbAsAuR").map(\.id), [1])
        XCTAssertTrue(c.suggestions("mr mime").contains { $0.name.contains("Mr.") })
        XCTAssertTrue(c.suggestions("no-such-pokemon").isEmpty)
        let b = try XCTUnwrap(c.pokemon(id: 1))
        let line = c.evolutionLine(for: b)
        XCTAssertEqual(line.first?.to.name, "Ivysaur")
        XCTAssertEqual(line.first?.method, "Level 16")
        XCTAssertTrue(line.contains { $0.to.name == "Venusaur" && $0.method == "Level 36" })
        let pikachu = try XCTUnwrap(c.species.first { $0.name == "Pikachu" })
        XCTAssertTrue(c.evolutionLine(for: pikachu).contains { $0.method == "ThunderStone" })
        let charizard = try XCTUnwrap(c.species.first { $0.name == "Charizard" })
        XCTAssertEqual(c.defensiveMatchups(for: charizard).first { $0.type.name == "Rock" }?.multiplier, 4)
        XCTAssertEqual(c.defensiveMatchups(for: charizard).first { $0.type.name == "Ground" }?.multiplier, 0)
        XCTAssertEqual(c.defensiveMatchups(for: b).first { $0.type.name == "Grass" }?.multiplier, 0.25)
    }
    func testRandomizerMatchesIndependentUpstreamJavaScriptVectors() throws {
        let c = try XCTUnwrap(BoundRRDexCatalog.bundled)
        // Generated directly by the live site's tryRandomizeAbility/Move functions.
        let vectors: [(UInt32, [Int])] = [(0, [39, 71, 37, 357, 676]), (123456789, [7, 224, 357, 262, 554]), (.max, [216, 249, 417, 97, 600])]
        for (seed, expected) in vectors {
            XCTAssertEqual([c.randomizedAbility(34, speciesID: 1, trainerID: seed), c.randomizedAbility(65, speciesID: 1, trainerID: seed), c.randomizedMove(33, speciesID: 1, trainerID: seed), c.randomizedMove(345, speciesID: 1, trainerID: seed), c.randomizedMove(85, speciesID: 150, trainerID: seed)], expected)
        }
        XCTAssertEqual(c.randomizedMove(0xa5, speciesID: 1, trainerID: 123), 0xa5)
        XCTAssertEqual(c.randomizedAbility(0, speciesID: 1, trainerID: 123), 0)
        let b = try XCTUnwrap(c.pokemon(id: 1)), save = BoundRRDexSave(trainerID: 123456789, randomAbilities: true, randomLearnset: true)
        XCTAssertEqual(c.abilityNames(for: b, save: save), ["Friend Guard", "Limber (Hidden)"])
        let level = try XCTUnwrap(b.learnset.first { $0.method == "Level up" })
        XCTAssertEqual(c.learnedMove(level, pokemon: b, save: save)?.id, 357)
        for method in ["TM/HM", "Tutor", "Egg"] {
            let entry = try XCTUnwrap(b.learnset.first { $0.method == method })
            XCTAssertEqual(c.learnedMove(entry, pokemon: b, save: save)?.id, entry.moveID)
        }
    }
    func testLearnsetMethodsAndCompactCategoryRows() throws {
        let catalog = try XCTUnwrap(BoundRRDexCatalog.bundled)
        let bulbasaur = try XCTUnwrap(catalog.pokemon(id: 1))
        XCTAssertEqual(catalog.learnsetMethods(for: bulbasaur), ["Level up", "TM/HM", "Tutor", "Egg"])
        XCTAssertTrue(catalog.learnsetRows(for: bulbasaur, save: nil, method: nil, query: "").isEmpty)
        XCTAssertTrue(catalog.learnsetRows(for: bulbasaur, save: nil, method: "Level up", query: "!!!").isEmpty,
                      "A nonempty query that normalizes to no search terms must not become browse mode")
        XCTAssertTrue(catalog.learnsetRows(for: bulbasaur, save: nil, method: "Level up", query: "   ").map(\.id)
            .allSatisfy { $0.hasPrefix("entry-") })

        let levelEntries = bulbasaur.learnset.filter { $0.method == "Level up" }
        let levelRows = catalog.learnsetRows(for: bulbasaur, save: nil, method: "Level up", query: "")
        XCTAssertEqual(levelRows.count, levelEntries.count)
        XCTAssertEqual(Set(levelRows.map(\.id)).count, levelRows.count)
        XCTAssertEqual(levelRows.map(\.level), levelRows.map(\.level).sorted { ($0 ?? Int.max) < ($1 ?? Int.max) })
        XCTAssertEqual(levelRows.first?.level, levelEntries.compactMap(\.level).min())
        XCTAssertEqual(levelRows.map(\.id), catalog.learnsetRows(for: bulbasaur, save: nil, method: "Level up", query: "").map(\.id),
                       "Equal-level rows must retain deterministic ordering")

        let venusaur = try XCTUnwrap(catalog.pokemon(id: 3))
        let evolution = try XCTUnwrap(catalog.learnsetRows(for: venusaur, save: nil, method: "Level up", query: "").first { $0.level == 0 })
        XCTAssertEqual(evolution.sourceSummary, "Evolution")

        let tmRows = catalog.learnsetRows(for: bulbasaur, save: nil, method: "TM/HM", query: "")
        XCTAssertEqual(tmRows.count, bulbasaur.learnset.filter { $0.method == "TM/HM" }.count)
        XCTAssertEqual(tmRows.map { $0.move.name }, tmRows.map { $0.move.name }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }
    func testLearnsetSearchCombinesSourcesAcrossMethodsAndResolvesRandomizedMoves() throws {
        let catalog = try XCTUnwrap(BoundRRDexCatalog.bundled)
        let bulbasaur = try XCTUnwrap(catalog.pokemon(id: 1))
        let magicalLeaf = catalog.learnsetRows(for: bulbasaur, save: nil, method: "Egg", query: " magical leaf ")
        XCTAssertEqual(magicalLeaf.count, 1)
        XCTAssertEqual(magicalLeaf[0].sources.map(\.method), ["Level up", "Egg"])
        XCTAssertEqual(magicalLeaf[0].level, 9, "A grouped result retains its single distinct level-up level")
        XCTAssertEqual(magicalLeaf[0].sourceSummary, "Level 9 · Egg")
        let preEvolutionRow = BoundRRDexLearnsetRow(
            id: "fixture",
            move: magicalLeaf[0].move,
            sources: [
                .init(moveID: magicalLeaf[0].move.id, method: "Pre-evolution", level: 12),
                .init(moveID: magicalLeaf[0].move.id, method: "Level up", level: 9),
                .init(moveID: magicalLeaf[0].move.id, method: "TM/HM", level: nil),
                .init(moveID: magicalLeaf[0].move.id, method: "TM/HM", level: nil)
            ]
        )
        XCTAssertEqual(preEvolutionRow.sourceSummary, "Pre-evolution · Level 12 · Level 9 · TM/HM")
        XCTAssertEqual(preEvolutionRow.level, 9)

        let randomSave = BoundRRDexSave(trainerID: 123456789, randomAbilities: false, randomLearnset: true)
        let originalLevelEntry = try XCTUnwrap(bulbasaur.learnset.first { $0.method == "Level up" })
        let randomizedMove = try XCTUnwrap(catalog.learnedMove(originalLevelEntry, pokemon: bulbasaur, save: randomSave))
        let randomizedRows = catalog.learnsetRows(for: bulbasaur, save: randomSave, method: "Egg", query: randomizedMove.name)
        XCTAssertTrue(randomizedRows.contains { row in
            row.id == "move-\(randomizedMove.id)" && row.sources.contains { $0.method == "Level up" }
        }, "Search must resolve randomizer moves and search across methods regardless of selected category")
        XCTAssertEqual(randomizedRows.map(\.move.name), randomizedRows.map(\.move.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }
    func testSaveImportUsesLatestCompleteRotatedSlotAndRejectsWrongFormats() throws {
        var data = Self.saveFixture()
        XCTAssertEqual(try BoundRRDexSave.parse(data), BoundRRDexSave(trainerID: 123456789, randomAbilities: true, randomLearnset: true))
        // A torn newer slot must fall back to the coherent previous slot.
        data[0xe000 + 0xff8] = 0
        XCTAssertEqual(try BoundRRDexSave.parse(data).trainerID, 42)
        XCTAssertThrowsError(try BoundRRDexSave.parse(Data(repeating: 0, count: 0x20000)))
        XCTAssertThrowsError(try BoundRRDexSave.parse(Data(repeating: 0, count: 123)))
        var hardcore = Self.saveFixture()
        // Sector 4 is physical sector 7 in the rotated second slot.
        hardcore[0xe000 + 7 * 0x1000 + 0xdb2] = 0x10
        XCTAssertThrowsError(try BoundRRDexSave.parse(hardcore)) { XCTAssertEqual(($0 as? BoundRRDexSave.ImportError), .difficulty) }
        var restricted = Self.saveFixture()
        restricted[0xe000 + 7 * 0x1000 + 0xdc3] = 0x40
        XCTAssertThrowsError(try BoundRRDexSave.parse(restricted))
    }
    func testCurrentSaveCaptureUsesFreshExportAndCleansUpOnSuccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalURL = directory.appendingPathComponent("game.sav")
        let originalData = Self.saveFixture(trainerID: 42)
        try originalData.write(to: originalURL)
        let freshData = Self.saveFixture(trainerID: 987654321)
        var exportedURL: URL?

        let captured = try BoundRRDexCurrentSaveImport.capture(temporaryDirectory: directory) { url in
            exportedURL = url
            XCTAssertNotEqual(url, originalURL)
            XCTAssertEqual(url.lastPathComponent, "current-game.sav")
            try freshData.write(to: url)
        }

        XCTAssertEqual(captured, BoundRRDexSave(trainerID: 987654321, randomAbilities: true, randomLearnset: true))
        XCTAssertEqual(try Data(contentsOf: originalURL), originalData, "Capturing a current save must not modify the game's battery save")
        let exportDirectory = try XCTUnwrap(exportedURL).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportDirectory.path), "Temporary export files must be removed after parsing")
    }

    func testCurrentSaveCaptureCleansUpPartialExportAndPreservesPreferencesOnFailure() throws {
        let suite = "RRDexCurrentSaveTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundRRDexPreferences(defaults: defaults)
        let previous = BoundRRDexPreferences.Choice(speciesID: 6, save: try BoundRRDexSave.parse(Self.saveFixture(trainerID: 42)))
        preferences.write(previous, gameID: "ROM_A")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("game.sav")
        let originalData = Data("original battery save".utf8)
        try originalData.write(to: originalURL)
        var exportedURL: URL?

        XCTAssertThrowsError(try BoundRRDexCurrentSaveImport.capture(temporaryDirectory: directory) { url in
            exportedURL = url
            try Data("partial export".utf8).write(to: url)
            throw NSError(domain: "RRDexSaveExporterFixture", code: 1)
        }) { error in
            XCTAssertEqual(error as? BoundRRDexSave.ImportError, .currentGameUnavailable)
        }

        let exportDirectory = try XCTUnwrap(exportedURL).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportDirectory.path), "Partial temporary exports must be removed after exporter failure")
        XCTAssertEqual(try Data(contentsOf: originalURL), originalData)
        XCTAssertEqual(preferences.read(gameID: "ROM_A"), previous, "A failed import must leave the caller's previous choice unchanged")
    }

    func testCurrentSaveCaptureRejectsInvalidAndOversizedExportsAndCleansUp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalURL = directory.appendingPathComponent("game.sav")
        let originalData = Data("original battery save".utf8)
        try originalData.write(to: originalURL)

        for (name, output, expectedError) in [
            ("invalid", Data(repeating: 0, count: 0x20000), BoundRRDexSave.ImportError.incomplete),
            ("oversized", Data(repeating: 0, count: 0x20001), BoundRRDexSave.ImportError.format)
        ] {
            var exportedURL: URL?
            XCTAssertThrowsError(try BoundRRDexCurrentSaveImport.capture(temporaryDirectory: directory) { url in
                exportedURL = url
                try output.write(to: url)
            }, name) { error in
                XCTAssertEqual(error as? BoundRRDexSave.ImportError, expectedError, name)
            }
            let exportDirectory = try XCTUnwrap(exportedURL).deletingLastPathComponent()
            XCTAssertFalse(FileManager.default.fileExists(atPath: exportDirectory.path), "\(name) temporary exports must be removed")
            XCTAssertEqual(try Data(contentsOf: originalURL), originalData)
        }
    }

    func testImportedConfigurationPersistsPerROMWithoutStoringRawSave() throws {
        let suite = "RRDexTests." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoundRRDexPreferences(defaults: defaults)
        let save = try BoundRRDexSave.parse(Self.saveFixture())
        let choice = BoundRRDexPreferences.Choice(speciesID: 6, save: save)
        store.write(choice, gameID: "ROM_A")
        XCTAssertEqual(store.read(gameID: "ROM_A"), choice)
        XCTAssertNil(store.read(gameID: "ROM_B").save)
        defaults.set(false, forKey: BoundLegacyPreferences.experimentalFeaturesKey)
        XCTAssertEqual(store.read(gameID: "ROM_A"), choice)
        let retained = try XCTUnwrap(defaults.data(forKey: "bound.rrdex.choice.v1.ROM_A"))
        XCTAssertLessThan(retained.count, 256)
        store.write(.init(speciesID: 6, save: nil), gameID: "ROM_A")
        XCTAssertNil(store.read(gameID: "ROM_A").save)
        XCTAssertEqual(store.read(gameID: "ROM_A").speciesID, 6)
    }

    func testAutomaticRefreshStoresOnlyConfigurationAndHandlesFailuresSafely() throws {
        let suite = "RRDexAutoRefreshTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = BoundRRDexPreferences(defaults: defaults)
        let originalSave = try BoundRRDexSave.parse(Self.saveFixture(trainerID: 42))
        let newSave = try BoundRRDexSave.parse(Self.saveFixture(trainerID: 123456789))
        preferences.write(.init(speciesID: 150, save: originalSave), gameID: "ROM_A")

        var captureCount = 0
        let refreshed = try preferences.refreshCurrentSave(gameID: "ROM_A") {
            captureCount += 1
            return newSave
        }
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(refreshed, .init(speciesID: 150, save: newSave), "Automatic refresh must preserve the selected species.")
        XCTAssertEqual(preferences.read(gameID: "ROM_A"), refreshed)

        XCTAssertThrowsError(try preferences.refreshCurrentSave(gameID: "ROM_A") {
            throw BoundRRDexSave.ImportError.currentGameUnavailable
        })
        XCTAssertEqual(preferences.read(gameID: "ROM_A"), refreshed, "Transient export failures must keep the last good configuration.")

        XCTAssertThrowsError(try preferences.refreshCurrentSave(gameID: "ROM_A") {
            throw BoundRRDexSave.ImportError.difficulty
        })
        XCTAssertEqual(preferences.read(gameID: "ROM_A"), .init(speciesID: 150), "An unsupported active save must clear stale randomizer settings while preserving species selection.")

        var invalidGameCaptureCalled = false
        XCTAssertThrowsError(try preferences.refreshCurrentSave(gameID: "ROM/A") {
            invalidGameCaptureCalled = true
            return newSave
        })
        XCTAssertFalse(invalidGameCaptureCalled, "Invalid game identifiers must not invoke the live-save exporter.")
    }

    func testAutomaticRefreshEventsArePerGameAndSuppressCapturePauseCallbacks() {
        let recorder = NotificationRecorder()
        let observer = NotificationCenter.default.addObserver(forName: BoundRRDexSaveRefreshEvent.notificationName,
                                                               object: nil, queue: nil) { recorder.append($0) }
        defer { NotificationCenter.default.removeObserver(observer) }

        BoundRRDexSaveRefreshEvent.suppressWhileCapturing(gameID: "ROM_A") {
            BoundRRDexSaveRefreshEvent.post(gameID: "ROM_A")
            BoundRRDexSaveRefreshEvent.post(gameID: "ROM_B")
        }
        XCTAssertEqual(recorder.notifications.count, 1)
        XCTAssertEqual(recorder.notifications.first?.userInfo?[BoundRRDexSaveRefreshEvent.gameIDKey] as? String, "ROM_B")

        BoundRRDexSaveRefreshEvent.post(gameID: "ROM_A")
        XCTAssertEqual(recorder.notifications.count, 2)
        XCTAssertEqual(recorder.notifications.last?.userInfo?[BoundRRDexSaveRefreshEvent.gameIDKey] as? String, "ROM_A")
    }

    func testAbilityDescriptionsFollowRandomizedAbilityAndRRDexStatColors() throws {
        let catalog = try XCTUnwrap(BoundRRDexCatalog.bundled)
        let bulbasaur = try XCTUnwrap(catalog.pokemon(id: 1))
        let standard = catalog.abilityDetails(for: bulbasaur, save: nil)
        XCTAssertEqual(standard.map(\.name), ["Overgrow", "Chlorophyll"])
        XCTAssertEqual(standard.map(\.description), [
            "Boosts Grass moves by 50% at 1/3 or less HP.",
            "Doubles Speed in Sun."
        ])
        XCTAssertEqual(standard.map(\.isHidden), [false, true])

        let randomized = catalog.abilityDetails(for: bulbasaur,
                                                save: .init(trainerID: 123456789, randomAbilities: true, randomLearnset: false))
        XCTAssertEqual(randomized.map(\.name), ["Friend Guard", "Limber"])
        XCTAssertEqual(randomized.map(\.description), ["Reduces damage done to allies.", "Prevents paralysis."])

        let boundaries: [(Int, String)] = [
            (29, "#CC0000"), (30, "#ce4d00"), (59, "#ce4d00"), (60, "#ffe100"),
            (89, "#ffe100"), (90, "#0d8d00"), (119, "#0d8d00"), (120, "#25d65e"),
            (149, "#25d65e"), (150, "#15c9c7")
        ]
        for (value, expected) in boundaries {
            XCTAssertEqual(BoundRRDexCatalog.statColorHex(for: value), expected, "Unexpected RR Dex stat color at \(value).")
        }
    }

    private static func saveFixture(trainerID: UInt32 = 123456789) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x20000)
        func put(_ value: UInt32, _ offset: Int, count: Int = 4) {
            for n in 0..<count { bytes[offset + n] = UInt8(truncatingIfNeeded: value >> (n * 8)) }
        }
        for slot in 0..<2 {
            for physical in 0..<14 {
                let sector = (physical + (slot == 1 ? 11 : 0)) % 14, offset = slot * 0xe000 + physical * 0x1000
                put(UInt32(sector), offset + 0xff4, count: 2)
                put(0x08012025, offset + 0xff8); put(UInt32(slot + 10), offset + 0xffc)
                if sector == 0 { put(slot == 1 ? trainerID : 42, offset + 0xa); bytes[offset + 0xf2c] = slot == 1 ? 6 : 0 }
            }
        }
        return Data(bytes)
    }

    private final class NotificationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Notification] = []
        var notifications: [Notification] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        func append(_ notification: Notification) {
            lock.lock(); defer { lock.unlock() }
            stored.append(notification)
        }
    }
}

extension RRDexTests {
    func testIndexedLookupsMatchEveryBundledCatalogEntry() throws {
        let catalog = try XCTUnwrap(BoundRRDexCatalog.bundled)

        for species in catalog.species {
            XCTAssertEqual(catalog.pokemon(id: species.id)?.name, species.name, "Species ID \(species.id)")
        }
        for type in catalog.types {
            XCTAssertEqual(catalog.type(id: type.id)?.name, type.name, "Type ID \(type.id)")
        }
        for move in catalog.moves {
            XCTAssertEqual(catalog.move(id: move.id)?.name, move.name, "Move ID \(move.id)")
        }
        XCTAssertNil(catalog.pokemon(id: Int.min))
        XCTAssertNil(catalog.type(id: Int.min))
        XCTAssertNil(catalog.move(id: Int.min))
    }
}
