import Foundation
import XCTest
@testable import Models

final class BossGuideTests: XCTestCase {
    func testBattleConditionBadgesPreserveMultipleConditionsPerNote() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        XCTAssertEqual(catalog.team(id: "kanto-leaders-97")?.battleConditionBadges, ["Doubles"])
        XCTAssertEqual(catalog.team(id: "team-rocket-169")?.battleConditionBadges, ["Doubles", "Partner battle"])
        XCTAssertEqual(catalog.team(id: "mini-bosses-340")?.battleConditionBadges, ["Back-to-back", "Permanent snow"])
        XCTAssertEqual(catalog.team(id: "mini-bosses-441")?.battleConditionBadges, ["Doubles", "Permanent sun"])
    }

    func testEncounterGroupsPreserveEveryTeamAndSeparateRepeatedFights() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        let encounters = catalog.encounters(matching: "")
        XCTAssertEqual(encounters.flatMap(\.teams).map(\.id).sorted(), catalog.teams.map(\.id).sorted())
        XCTAssertEqual(Set(encounters.map(\.id)).count, encounters.count)
        let route22 = catalog.encounters(matching: "Rival Route 22", category: "Rivals")
        XCTAssertEqual(route22.count, 2, "Early and late Route 22 fights remain separate encounters")
        XCTAssertTrue(route22.allSatisfy { $0.teams.count == 3 })
        XCTAssertTrue(route22.allSatisfy { Set($0.teams.map(\.sourceLabel)).count == 1 })
        let starterSearch = catalog.encounters(matching: "If Rival Has Squirtle", category: "Rivals")
        XCTAssertEqual(starterSearch.count, 4)
        XCTAssertTrue(starterSearch.allSatisfy { $0.teams.count == 3 }, "Search keeps each matching encounter's alternatives available")
        let jasmine = try XCTUnwrap(catalog.encounters(matching: "Jasmine", category: "Johto Leaders").first)
        XCTAssertEqual(jasmine.teams.map { jasmine.optionTitle(for: $0) }, ["Team One", "Team Two", "Team Three"])
        let lorelei = try XCTUnwrap(catalog.encounters(matching: "Lorelei", category: "Indigo League").first)
        XCTAssertEqual(lorelei.teams.map { lorelei.optionTitle(for: $0) }, ["Rain Team", "Snow Team"])
        let champion = try XCTUnwrap(catalog.encounters(matching: "Rival Champion", category: "Indigo League").first)
        XCTAssertEqual(champion.teams.map { champion.optionTitle(for: $0) }, ["Team 1", "Team 2", "Team 3"])
    }

    func testAdjacentTrainerFollowsPublishedEarlyPlaythroughOrder() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        let sequence = [
            "rivals-6", "rivals-77", "mini-bosses-4", "mini-bosses-27",
            "johto-leaders-4", "kanto-leaders-4", "mini-bosses-51", "team-rocket-4",
            "rivals-102"
        ]

        for (index, teamID) in sequence.enumerated() where index + 1 < sequence.count {
            XCTAssertEqual(catalog.adjacentTrainer(to: teamID, offset: 1)?.id, sequence[index + 1],
                           "Unexpected next trainer after \(teamID)")
        }
        for (index, teamID) in sequence.enumerated() where index > 0 {
            XCTAssertEqual(catalog.adjacentTrainer(to: teamID, offset: -1)?.id, sequence[index - 1],
                           "Unexpected previous trainer before \(teamID)")
        }
    }

    func testAdjacentTrainerMapsConditionalVariantsAndCorrectedRoute13Rows() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)

        XCTAssertEqual(catalog.adjacentTrainer(to: "rivals-54", offset: 1)?.id, "rivals-77",
                       "Route 22 starter variants navigate from their shared encounter")
        XCTAssertEqual(catalog.adjacentTrainer(to: "rivals-150", offset: 1)?.id, "mini-bosses-75",
                       "Cerulean Rival variants navigate from their shared encounter")
        XCTAssertEqual(catalog.adjacentTrainer(to: "johto-leaders-199", offset: 1)?.id, "mini-bosses-790",
                       "Unlisted Jasmine variants navigate from the listed Jasmine encounter")

        XCTAssertEqual(catalog.adjacentTrainer(to: "mini-bosses-391", offset: 1)?.id, "mini-bosses-416",
                       "The independently listed Picnicker Alma fight follows Susie")
        XCTAssertEqual(catalog.adjacentTrainer(to: "mini-bosses-416", offset: 1)?.id, "mini-bosses-441")
        XCTAssertEqual(catalog.adjacentTrainer(to: "mini-bosses-441", offset: -1)?.id, "mini-bosses-416")
        XCTAssertEqual(catalog.adjacentTrainer(to: "mini-bosses-515", offset: 1)?.id, "optional-bosses-99",
                       "Robert's repeated location-row link is not a separate fight")
    }

    func testAdjacentTrainerHasNoWraparoundAndRejectsUnlistedEncounters() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        let first = try XCTUnwrap(catalog.trainerOrder.first?.teamID)
        let last = try XCTUnwrap(catalog.trainerOrder.last?.teamID)

        XCTAssertNil(catalog.adjacentTrainer(to: first, offset: -1))
        XCTAssertNil(catalog.adjacentTrainer(to: last, offset: 1))
        XCTAssertNil(catalog.adjacentTrainer(to: "postgame-6", offset: 1),
                     "Postgame teams have no published linear position")
        XCTAssertNil(catalog.adjacentTrainer(to: "unknown-team", offset: 1))
        XCTAssertNil(catalog.adjacentTrainer(to: first, offset: 0))
        XCTAssertNil(catalog.adjacentTrainer(to: first, offset: Int.max))
    }

    func testTrainerIconsCoverAllBossTeamsOffline() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        let data = try XCTUnwrap(BoundBossReferenceData.bundled)
        let icons = try XCTUnwrap(data.trainerIcons)
        let mappings = try XCTUnwrap(data.trainerIconsByTeam)
        let reference = try XCTUnwrap(BoundBossReference.bundled)
        XCTAssertEqual(Set(mappings.keys), Set(catalog.teams.map(\.id)))
        XCTAssertFalse(icons.isEmpty)
        for team in catalog.teams {
            let keys = try XCTUnwrap(mappings[team.id])
            XCTAssertFalse(keys.isEmpty)
            XCTAssertEqual(reference.trainerIconData(for: team).count, keys.count)
            for key in keys {
                let icon = try XCTUnwrap(icons[key])
                XCTAssertTrue(Data(base64Encoded: icon.pngBase64)?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)
                XCTAssertEqual(icon.sourceURL.host, "play.pokemonshowdown.com")
                XCTAssertEqual(icon.sha256.count, 64)
            }
        }
        XCTAssertEqual(mappings[catalog.defaultTeam.id], ["brock-gen3"])
        XCTAssertEqual(mappings["team-rocket-169"], ["ariana", "archer"])
    }
    func testBundledCatalogCoversEveryBossSectionAndPokemon() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        XCTAssertEqual(catalog.gameVersion, "4.1")
        XCTAssertEqual(catalog.difficulty, "Default")
        XCTAssertEqual(catalog.categories.count, 9)
        XCTAssertEqual(catalog.teams.count, 167)
        XCTAssertEqual(catalog.teams.reduce(0) { $0 + $1.pokemon.count }, 792)
        XCTAssertEqual(catalog.levelCaps.count, 18)
        XCTAssertEqual(catalog.trainerOrder.count, 96)
        XCTAssertEqual(Set(catalog.trainerOrder.map(\.teamID)).count, catalog.trainerOrder.count)
        XCTAssertEqual(catalog.categoryCounts["Postgame"], 51)
        XCTAssertEqual(catalog.categoryCounts["Mini Bosses"], 42)
        XCTAssertEqual(Set(catalog.teams.map(\.id)).count, catalog.teams.count)
        for team in catalog.teams {
            for pokemon in team.pokemon {
                XCTAssertEqual(pokemon.moves.count, 4)
                XCTAssertEqual(pokemon.stats.map(\.name), ["HP", "ATK", "DEF", "SPA", "SPD", "SPE"])
            }
        }
    }

    func testSourceExamplesPreserveMovesScalingLevelsAndVariants() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        let brock = catalog.defaultTeam
        XCTAssertEqual(brock.name, "Brock")
        XCTAssertEqual(brock.levelCap, 15)
        XCTAssertEqual(brock.location, "Pewter City")
        XCTAssertEqual(brock.pokemon.count, 4)
        XCTAssertEqual(brock.pokemon[0].species, "Geodude-A")
        XCTAssertEqual(brock.pokemon[0].ability, "Sturdy")
        XCTAssertEqual(brock.pokemon[0].item, "Custap Berry")
        XCTAssertEqual(brock.pokemon[0].moves, ["Bulldoze", "Rock Tomb", "Spark", "Self-Destruct"])
        XCTAssertEqual(brock.pokemon[2].moves.last, "-")
        XCTAssertEqual(catalog.team(id: "johto-leaders-31")?.pokemon[0].level, "Highest Lv -2")
        XCTAssertEqual(catalog.teams(matching: "Lorelei", category: "Indigo League").count, 2)
        XCTAssertEqual(catalog.teams.filter { $0.category == "Rivals" && $0.name == "Rival" }.count, 12)
        XCTAssertTrue(catalog.teams(matching: "Soupercell").contains { $0.pokemon[0].level == "250" })
        XCTAssertFalse(catalog.teams(matching: "Ketchup").isEmpty)
        XCTAssertFalse(catalog.teams(matching: "Kyogre-P").isEmpty)
        XCTAssertTrue(catalog.teams(matching: "Cerulean Misty").contains { $0.id == "kanto-leaders-27" })
    }

    func testConditionalSpeedContextIsPreservedFromSource() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        XCTAssertEqual(catalog.team(id: "johto-leaders-31")?.speedContext, "IF YOU'RE LEVEL 27")
        XCTAssertEqual(catalog.team(id: "johto-leaders-56")?.speedContext, "IF YOU'RE LEVEL 44")
        XCTAssertNil(catalog.team(id: "kanto-leaders-4")?.speedContext)
        XCTAssertEqual(catalog.team(id: "johto-leaders-31")?.pokemon[0].speed.first?.label, "SPEED STAT:")
    }

    func testBossBaseStatColorsMatchSpreadsheetBarPalette() {
        func color(_ base: Int?) -> String? {
            BoundBossPokemon.Stat(name: "HP", base: base, ev: 0).colorHex
        }
        XCTAssertEqual(color(20), "#F34444")
        XCTAssertEqual(color(29), "#F34444")
        XCTAssertEqual(color(30), "#FF7F0F")
        XCTAssertEqual(color(59), "#FF7F0F")
        XCTAssertEqual(color(60), "#FFDD57")
        XCTAssertEqual(color(89), "#FFDD57")
        XCTAssertEqual(color(90), "#A0E515")
        XCTAssertEqual(color(119), "#A0E515")
        XCTAssertEqual(color(120), "#23CD5E")
        XCTAssertEqual(color(149), "#23CD5E")
        XCTAssertEqual(color(150), "#00C2B8")
        XCTAssertNil(color(nil))
    }

    func testSelectionsPersistPerROMAndInvalidSavedIndicesRecover() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        let suite = "BoundBossGuideTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoundBossGuidePreferences(defaults: defaults)
        let choice = BoundBossGuideSelection(teamID: "kanto-leaders-27", pokemonIndex: 2)
        store.write(choice, gameID: "ROM_A", catalog: catalog)
        XCTAssertEqual(BoundBossGuidePreferences(defaults: defaults).read(gameID: "ROM_A", catalog: catalog), choice)
        XCTAssertEqual(store.read(gameID: "ROM_B", catalog: catalog).teamID, catalog.defaultTeam.id)
        let invalid = BoundBossGuideSelection(teamID: "old-or-missing-team", pokemonIndex: -7)
        XCTAssertEqual(invalid.resolved(in: catalog), BoundBossGuideSelection(teamID: catalog.defaultTeam.id, pokemonIndex: 0))
        let tooHigh = BoundBossGuideSelection(teamID: choice.teamID, pokemonIndex: 999)
        XCTAssertEqual(tooHigh.resolved(in: catalog).pokemonIndex, 3)
        defaults.set(false, forKey: BoundLegacyPreferences.experimentalFeaturesKey)
        XCTAssertEqual(store.read(gameID: "ROM_A", catalog: catalog), choice, "Turning experiments off must preserve the guide choice")
    }

    func testPermanentCompanionCycleIncludesReferencePanels() {
        XCTAssertEqual(BoundPiPContent.cycleOrder, [.friend, .notes, .types, .bosses, .dex])
        XCTAssertEqual(BoundPiPContent.cycleOrder, [.friend, .notes, .types, .bosses, .dex])
    }

    func testBossReferenceResolvesEveryDefaultSpeciesMoveAndDescriptionOffline() throws {
        let bosses = try XCTUnwrap(BoundBossCatalog.bundled)
        let reference = try XCTUnwrap(BoundBossReference.bundled)
        let dex = try XCTUnwrap(BoundRRDexCatalog.bundled)
        var speciesCount = 0
        var describedAbilities = Set<String>()
        var describedItems = Set<String>()

        for team in bosses.teams {
            for (pokemonIndex, pokemon) in team.pokemon.enumerated() {
                let detail = reference.detail(for: pokemon, teamID: team.id, pokemonIndex: pokemonIndex)
                XCTAssertNotNil(detail.species, "Unresolved boss species: \(pokemon.species)")
                XCTAssertFalse(detail.types.isEmpty, "No types for boss species: \(pokemon.species)")
                XCTAssertEqual(detail.moves.count, 4)
                speciesCount += 1
                if detail.abilityDescription != nil { describedAbilities.insert(pokemon.ability) }
                if detail.itemDescription != nil { describedItems.insert(pokemon.item) }
                for move in detail.moves where move.name != "-" {
                    XCTAssertNotNil(move.type, "Missing type for \(move.name) on \(pokemon.species)")
                    XCTAssertTrue(["PhysA.", "SpA.", "Status"].contains(move.categoryLabel), "Missing category for \(move.name)")
                }
                XCTAssertNotNil(detail.abilityDescription, "Missing ability description for \(pokemon.ability)")
                XCTAssertNotNil(detail.itemDescription, "Missing item description for \(pokemon.item)")
            }
        }

        XCTAssertEqual(speciesCount, 792)
        XCTAssertEqual(describedAbilities.count, Set(bosses.teams.flatMap { $0.pokemon.map(\.ability) }).count)
        XCTAssertEqual(describedItems.count, Set(bosses.teams.flatMap { $0.pokemon.map(\.item) }).count)

        let geodude = try XCTUnwrap(reference.detail(for: bosses.defaultTeam.pokemon[0]).species)
        XCTAssertEqual(geodude.name, "Geodude-Alola")
        XCTAssertEqual(geodude.types.compactMap(dex.type(id:)).map(\.name), ["Rock", "Electric"])
        let sturdy = try XCTUnwrap(reference.detail(for: bosses.defaultTeam.pokemon[0]).abilityDescription)
        XCTAssertTrue(sturdy.contains("at full HP"))
        XCTAssertFalse(sturdy.hasPrefix("Sturdy:"))
    }

    func testBossReferenceTypeIconsAndSheetMoveOverridesAreBundled() throws {
        let reference = try XCTUnwrap(BoundBossReference.bundled)
        let dex = try XCTUnwrap(BoundRRDexCatalog.bundled)
        XCTAssertEqual(dex.types.count, 18)
        XCTAssertTrue(dex.types.allSatisfy { reference.typeIconData(for: $0)?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true })

        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        let overrides = ["HP Grass", "HP Ice", "HP Fire", "Disarm. Voice", "HP Fighting", "HP Rock", "Supercell Slam", "HP Dark", "HP Dragon"]
        let known = Set(catalog.teams.flatMap { $0.pokemon.flatMap(\.moves) })
        XCTAssertTrue(overrides.allSatisfy(known.contains))
        XCTAssertNotNil(BoundBossReferenceData.bundled?.typeIconLicenseText)
    }

    func testBossMoveTypeOverridesMatchAllSourceCellsAndApplyByContext() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        let reference = try XCTUnwrap(BoundBossReference.bundled)
        let source = try XCTUnwrap(BoundBossReferenceData.bundled)
        let overrides = try XCTUnwrap(source.bossMoveTypeOverrides)
        let cells = try XCTUnwrap(source.bossMoveTypeOverrideCells)
        XCTAssertEqual(overrides.count, 53)
        XCTAssertEqual(Set(overrides.keys), Set(cells.keys))

        for (key, expectedType) in overrides {
            let parts = key.split(separator: "|")
            XCTAssertEqual(parts.count, 3, "Malformed context key: \(key)")
            guard parts.count == 3,
                  let team = catalog.team(id: String(parts[0])),
                  let pokemonIndex = Int(parts[1]), team.pokemon.indices.contains(pokemonIndex),
                  let moveIndex = Int(parts[2]), team.pokemon[pokemonIndex].moves.indices.contains(moveIndex) else {
                XCTFail("Unknown boss move context: \(key)")
                continue
            }
            XCTAssertFalse(cells[key, default: ""].isEmpty, "Missing spreadsheet cell for \(key)")
            let detail = reference.detail(for: team.pokemon[pokemonIndex], teamID: team.id, pokemonIndex: pokemonIndex)
            XCTAssertEqual(detail.moves[moveIndex].type?.name, expectedType, "Wrong type at \(cells[key] ?? key)")
        }

        func sheetType(teamID: String, pokemonIndex: Int, moveIndex: Int) throws -> String? {
            let team = try XCTUnwrap(catalog.team(id: teamID))
            let detail = reference.detail(for: team.pokemon[pokemonIndex], teamID: teamID, pokemonIndex: pokemonIndex)
            return detail.moves[moveIndex].type?.name
        }
        XCTAssertEqual(try sheetType(teamID: "mini-bosses-366", pokemonIndex: 3, moveIndex: 2), "Fire")
        XCTAssertEqual(try sheetType(teamID: "mini-bosses-289", pokemonIndex: 1, moveIndex: 2), "Ice")
        XCTAssertEqual(try sheetType(teamID: "postgame-1149", pokemonIndex: 2, moveIndex: 0), "Water")
    }
}
