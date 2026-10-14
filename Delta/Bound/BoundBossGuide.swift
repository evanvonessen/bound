import Foundation

struct BoundBossCatalog: Decodable, Sendable {
    let schemaVersion: Int
    let gameVersion: String
    let difficulty: String
    let sourceTitle: String
    let sourceURL: URL
    let sourceModifiedTime: String?
    let sourceSHA256: String
    let categories: [String]
    let categoryCounts: [String: Int]
    let levelCaps: [LevelCap]
    let trainerOrder: [TrainerOrderEntry]
    let teams: [BoundBossTeam]

    struct LevelCap: Decodable, Sendable { let stage: String; let level: Int }
    struct TrainerOrderEntry: Decodable, Sendable {
        let name: String
        let location: String
        let levelCap: Int?
        let teamID: String
        let note: String?
    }

    static let bundled: BoundBossCatalog? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "RadicalRedDefaultBosses-v4.1", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }()

    static func decode(_ data: Data) throws -> Self {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1, catalog.gameVersion == "4.1", catalog.difficulty == "Default",
              !catalog.teams.isEmpty, Set(catalog.teams.map(\.id)).count == catalog.teams.count,
              catalog.categoryCounts.values.reduce(0, +) == catalog.teams.count,
              catalog.categories.allSatisfy({ category in
                  catalog.teams.filter { $0.category == category }.count == catalog.categoryCounts[category]
              }), catalog.teams.allSatisfy({ !$0.pokemon.isEmpty && $0.pokemon.allSatisfy {
                  !$0.species.isEmpty && !$0.level.isEmpty && $0.moves.count == 4 && $0.stats.count == 6
              } }), catalog.trainerOrder.allSatisfy({ entry in catalog.teams.contains { $0.id == entry.teamID } })
        else { throw CocoaError(.fileReadCorruptFile) }
        return catalog
    }

    var defaultTeam: BoundBossTeam { teams.first { $0.id == "kanto-leaders-4" } ?? teams[0] }
    func team(id: String) -> BoundBossTeam? { teams.first { $0.id == id } }
    func teams(matching query: String, category: String? = nil) -> [BoundBossTeam] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return teams.filter { team in
            guard category == nil || team.category == category else { return false }
            let text = ([team.name, team.location, team.variant, team.category, team.sourceLabel] + team.pokemon.map(\.species))
                .joined(separator: " ").lowercased()
            return words.allSatisfy(text.contains)
        }.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.sourceRow < $1.sourceRow
        }
    }
}

struct BoundBossTeam: Decodable, Identifiable, Sendable {
    let id: String
    let category: String
    let name: String
    let location: String
    let sourceLabel: String
    let sourceRow: Int
    let variant: String
    let notes: [String]
    let levelCap: Int?
    let order: Int
    let pokemon: [BoundBossPokemon]
    var subtitle: String { [location, variant].filter { !$0.isEmpty }.joined(separator: " · ") }
}

struct BoundBossPokemon: Decodable, Sendable {
    let species: String
    let level: String
    let nature: String
    let ability: String
    let item: String
    let moves: [String]
    let stats: [Stat]
    let speed: [Speed]
    struct Stat: Decodable, Sendable { let name: String; let base: Int?; let ev: Int }
    struct Speed: Decodable, Sendable { let label: String; let value: String }
    var levelLabel: String { Double(level) == nil ? level : "Lv. " + level }
}

struct BoundBossGuideSelection: Codable, Equatable, Sendable {
    var teamID: String
    var pokemonIndex: Int
    func resolved(in catalog: BoundBossCatalog) -> Self {
        let team = catalog.team(id: teamID) ?? catalog.defaultTeam
        return Self(teamID: team.id, pokemonIndex: min(max(0, pokemonIndex), team.pokemon.count - 1))
    }
}

/// Device-local reference choices, isolated per ROM; no saves or account data are read.
final class BoundBossGuidePreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(gameID: String) -> String? {
        guard !gameID.isEmpty, gameID.utf8.count <= 128,
              gameID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return "bound.boss-guide.selection.v1." + gameID
    }
    func read(gameID: String, catalog: BoundBossCatalog) -> BoundBossGuideSelection {
        if let key = key(gameID: gameID), let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(BoundBossGuideSelection.self, from: data) {
            return saved.resolved(in: catalog)
        }
        return BoundBossGuideSelection(teamID: catalog.defaultTeam.id, pokemonIndex: 0)
    }
    func write(_ selection: BoundBossGuideSelection, gameID: String, catalog: BoundBossCatalog) {
        guard let key = key(gameID: gameID),
              let data = try? JSONEncoder().encode(selection.resolved(in: catalog)) else { return }
        defaults.set(data, forKey: key)
    }
}
