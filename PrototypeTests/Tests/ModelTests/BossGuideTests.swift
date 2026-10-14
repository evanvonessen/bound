import Foundation
import XCTest
@testable import Models

final class BossGuideTests: XCTestCase {
    func testBundledCatalogCoversEveryBossSectionAndPokemon() throws {
        let catalog = try XCTUnwrap(BoundBossCatalog.bundled)
        XCTAssertEqual(catalog.gameVersion, "4.1")
        XCTAssertEqual(catalog.difficulty, "Default")
        XCTAssertEqual(catalog.categories.count, 9)
        XCTAssertEqual(catalog.teams.count, 167)
        XCTAssertEqual(catalog.teams.reduce(0) { $0 + $1.pokemon.count }, 792)
        XCTAssertEqual(catalog.levelCaps.count, 18)
        XCTAssertEqual(catalog.trainerOrder.count, 97)
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
        defaults.set(false, forKey: BoundExperimentalFeaturesPreferences.enabledKey)
        XCTAssertEqual(store.read(gameID: "ROM_A", catalog: catalog), choice, "Turning experiments off must preserve the guide choice")
    }

    func testExperimentGateKeepsTheBuild13CycleAndAddsReferencePanels() {
        XCTAssertEqual(BoundPiPContent.cycleOrder(experimentalFeaturesEnabled: false), [.friend, .notes, .types])
        XCTAssertEqual(BoundPiPContent.cycleOrder(experimentalFeaturesEnabled: true), [.friend, .notes, .types, .bosses, .dex])
    }
}
