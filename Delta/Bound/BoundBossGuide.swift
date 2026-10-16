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
    func encounters(matching query: String, category: String? = nil) -> [BoundBossEncounter] {
        let matches = Set(teams(matching: query, category: category).map(\.id))
        var encounters: [BoundBossEncounter] = []
        var indices: [String: Int] = [:]
        for team in teams(matching: "", category: category) {
            // Source labels distinguish repeated fights, including Route 22 #1/#2.
            let key = team.category + "|" + team.sourceLabel
            if let index = indices[key] { encounters[index].teams.append(team) }
            else {
                indices[key] = encounters.count
                encounters.append(BoundBossEncounter(teams: [team]))
            }
        }
        return encounters.filter { $0.teams.contains { matches.contains($0.id) } }
    }
}

struct BoundBossEncounter: Identifiable, Sendable {
    var teams: [BoundBossTeam]
    var id: String { teams[0].id }
    var primary: BoundBossTeam { teams[0] }
    func optionTitle(for team: BoundBossTeam) -> String {
        if !team.variant.isEmpty { return team.variant }
        return "Team \((teams.firstIndex { $0.id == team.id } ?? 0) + 1)"
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
    var battleConditionBadges: [String] {
        var badges: [String] = []
        for note in notes {
            let value = note.uppercased()
            if value.contains("DOUBLES"), !badges.contains("Doubles") { badges.append("Doubles") }
            for (source, label) in [("PERMANENT SUN", "Permanent sun"), ("PERMANENT RAIN", "Permanent rain"),
                                    ("PERMANENT SAND", "Permanent sand"), ("PERMANENT HAIL", "Permanent hail"),
                                    ("PERMANENT SNOW", "Permanent snow")] {
                if value.contains(source), !badges.contains(label) { badges.append(label) }
            }
            if value.contains("PARTNER"), !badges.contains("Partner battle") { badges.append("Partner battle") }
            if value.contains("BACK TO BACK"), !badges.contains("Back-to-back") { badges.append("Back-to-back") }
        }
        return badges
    }
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

/// Joins the published Default boss sheet to the bundled, Normal-difficulty RR Dex.
/// It deliberately does not accept a save, so opponent choices cannot be randomized.
struct BoundBossReference: Sendable {
    struct Move: Sendable {
        let name: String
        let type: BoundRRDexType?
        let categoryLabel: String
    }
    struct Detail: Sendable {
        let species: BoundRRDexSpecies?
        let types: [BoundRRDexType]
        let abilityDescription: String?
        let itemDescription: String?
        let moves: [Move]
    }

    private let dex: BoundRRDexCatalog
    private let data: BoundBossReferenceData
    private let speciesByKey: [String: BoundRRDexSpecies]
    private let movesByKey: [String: BoundRRDexMove]

    static let bundled: Self? = {
        guard let dex = BoundRRDexCatalog.bundled,
              let data = BoundBossReferenceData.bundled else { return nil }
        return Self(dex: dex, data: data)
    }()

    init(dex: BoundRRDexCatalog, data: BoundBossReferenceData) {
        self.dex = dex
        self.data = data
        speciesByKey = Dictionary(dex.species.map { (Self.key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        movesByKey = Dictionary(dex.moves.map { (Self.key($0.name), $0) }, uniquingKeysWith: { first, _ in first })
    }

    func detail(for pokemon: BoundBossPokemon, teamID: String? = nil, pokemonIndex: Int? = nil) -> Detail {
        let species = species(for: pokemon.species)
        let types = species?.types.compactMap(dex.type(id:)) ?? []
        let moveDetails = pokemon.moves.enumerated().map { entry -> Move in
            let moveIndex = entry.offset
            let name = entry.element
            guard name != "-" else { return Move(name: name, type: nil, categoryLabel: "—") }
            let sheetTypeName: String? = {
                guard let teamID, let pokemonIndex else { return nil }
                return data.bossMoveTypeOverrides?["\(teamID)|\(pokemonIndex)|\(moveIndex)"]
            }()
            let sheetType = sheetTypeName.flatMap { typeName in dex.types.first { Self.key($0.name) == Self.key(typeName) } }
            if let move = move(for: name) {
                return Move(name: name, type: sheetType ?? dex.type(id: move.type), categoryLabel: Self.categoryLabel(for: move))
            }
            if let override = data.moveOverrides[Self.key(name)], let type = dex.types.first(where: { Self.key($0.name) == Self.key(override.type) }) {
                return Move(name: name, type: sheetType ?? type, categoryLabel: override.categoryLabel)
            }
            return Move(name: name, type: nil, categoryLabel: "—")
        }
        return Detail(
            species: species,
            types: types,
            abilityDescription: abilityDescription(for: pokemon.ability),
            itemDescription: itemDescription(for: pokemon.item),
            moves: moveDetails
        )
    }

    func typeIconData(for type: BoundRRDexType) -> Data? {
        guard let encoded = data.typeIcons[type.name]?.pngBase64 else { return nil }
        return Data(base64Encoded: encoded)
    }
    func trainerIconData(for team: BoundBossTeam) -> [Data] {
        (data.trainerIconsByTeam?[team.id] ?? []).compactMap { key in
            data.trainerIcons?[key].flatMap { Data(base64Encoded: $0.pngBase64) }
        }
    }

    private func species(for bossName: String) -> BoundRRDexSpecies? {
        let name = Self.speciesAliases[bossName] ?? bossName
        if let direct = speciesByKey[Self.key(name)] { return direct }
        return nil
    }

    private func move(for bossName: String) -> BoundRRDexMove? {
        let name = Self.moveAliases[bossName] ?? bossName
        return movesByKey[Self.key(name)]
    }

    private func abilityDescription(for name: String) -> String? {
        let abilities = name.components(separatedBy: .newlines).flatMap { rawLine -> [String] in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let variants = line.hasPrefix("or ") ? [String(line.dropFirst(3))] : line.components(separatedBy: " or ")
            return variants.map {
                $0.replacingOccurrences(of: "(Both)", with: "").replacingOccurrences(of: "(Mega)", with: "").trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
        let descriptions = abilities.map { ability -> (String, String)? in
            guard let description = data.abilityDescriptions[Self.key(Self.abilityAliases[ability] ?? ability)] else { return nil }
            return (ability, description)
        }
        guard !descriptions.isEmpty, descriptions.allSatisfy({ $0 != nil }) else { return nil }
        let resolved = descriptions.compactMap { $0 }
        if resolved.count == 1 { return resolved[0].1 }
        return resolved.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    private func itemDescription(for name: String) -> String? {
        guard name != "No Item" else { return data.noItemDescription }
        let resolved = Self.itemAliases[name] ?? name
        return data.itemDescriptions[Self.key(resolved)]
    }

    private static func categoryLabel(for move: BoundRRDexMove) -> String {
        switch move.split {
        case 0: "PhysA."
        case 1: "SpA."
        case 2: "Status"
        default: "—"
        }
    }

    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static let speciesAliases: [String: String] = [
        "Aegislash": "Aegislash-Shield", "Arcanine-H": "Arcanine-Hisui", "Articuno-G": "Articuno-Galar",
        "Avalugg-H": "Avalugg-Hisui", "Braviary-H": "Braviary-Hisui", "Calyrex-I": "Calyrex-Ice",
        "Centiskorch-MegaS": "Centiskorch-Sevii-Mega", "Clawitzer-S": "Clawitzer-Sevii", "Darmanitan-G": "Darmanitan-Galar",
        "Darmanitan-GZ": "Darmanitan-Galar-Zen", "Decidueye-H": "Decidueye-Hisui", "Deoxys-A": "Deoxys-Attack",
        "Dodrio-S": "Dodrio-Sevii", "Dugtrio-A": "Dugtrio-Alola", "Electrode-H": "Electrode-Hisui",
        "Enamorus-I": "Enamorus", "Enamorus-T": "Enamorus-Therian", "Exeggutor-A": "Exeggutor-Alola",
        "Genesect-Douse": "Genesect", "Giratina-O": "Giratina-Origin", "Goodra-H": "Goodra-Hisui",
        "Hoopa-U": "Hoopa-Unbound", "Indeedee-M": "Indeedee", "Kyogre-P": "Kyogre-Primal",
        "Kyurem-B": "Kyurem-Black", "Kyurem-W": "Kyurem-White", "Landorus-I": "Landorus", "Landorus-T": "Landorus-Therian",
        "Lycanroc-D": "Lycanroc-Dusk", "Magearna-O": "Magearna", "Mantine-S": "Mantine-Sevii", "Milotic-S": "Milotic-Sevii",
        "Necrozma-DM": "Necrozma-Dusk-Mane", "Ninetales-A": "Ninetales-Alola", "Ogerpon-C": "Ogerpon-Cornerstone",
        "Ogerpon-H": "Ogerpon-Hearthflame", "Ogerpon-W": "Ogerpon-Wellspring", "Palkia-O": "Palkia-Origin",
        "Persian-A": "Persian-Alola", "Rotom-W": "Rotom-Wash", "Shaymin-S": "Shaymin-Sky",
        "Slowbro-G": "Slowbro-Galar", "Ursaluna-BM": "Ursaluna-Bloodmoon", "Ursaring-S": "Ursaring-Sevii",
        "Urshifu-R": "Urshifu-Rapid-Strike", "Urshifu-S": "Urshifu", "Voltorb-H": "Voltorb-Hisui",
        "Weezing-G": "Weezing-Galar", "Wishiwashi-S-Sch": "Wishiwashi-Sevii-School", "Wishiwashi-Sch": "Wishiwashi-School",
        "Wormadam-Sa": "Wormadam-Sandy", "Zacian-C": "Zacian-Crowned", "Zapdos-G": "Zapdos-Galar", "Zebstrika-S": "Zebstrika-Sevii",
        "Zoroark-H": "Zoroark-Hisui", "Geodude-A": "Geodude-Alola", "Lilligant-H": "Lilligant-Hisui",
        "Marowak-A": "Marowak-Alola", "Moltres-G": "Moltres-Galar", "Qwilfish-H": "Qwilfish-Hisui",
        "Samurott-H": "Samurott-Hisui", "Sandslash-A": "Sandslash-Alola", "Sneasel-H": "Sneasel-Hisui"
    ]

    private static let moveAliases: [String: String] = [
        "Behemo. Blade": "Behemoth Blade", "Cease. Edge": "Ceaseless Edge", "Clang. Scales": "Clanging Scales",
        "Clang. Soul": "Clangorous Soul", "Dazz. Gleam": "Dazzling Gleam", "Disarm. Voice": "Disarming Voice",
        "Double I. Bash": "Double Iron Bash", "Dragon Hamm.": "Dragon Hammer", "Draining Kiss": "Drain Kiss",
        "Dyna. Cannon": "Dynamax Cannon", "Dynam. Punch": "Dynamic Punch", "Expand. Force": "Expanding Force",
        "First Impress.": "First Impression", "Giga. Hammer": "Gigaton Hammer", "HP Dark": "Hidden Power Dark",
        "HP Dragon": "Hidden Power Dragon", "HP Fighting": "Hidden Power Fighting", "HP Fire": "Hidden Power Fire",
        "HP Grass": "Hidden Power Grass", "HP Ice": "Hidden Power Ice", "HP Rock": "Hidden Power Rock",
        "Headlon. Rush": "Headlong Rush", "High Horsep.": "High Horsepower", "High J. Kick": "High Jump Kick",
        "Hypersp. Fury": "Hyperspace Fury", "Matcha Got.": "Matcha Gotcha", "Parab. Charge": "Parabolic Charge",
        "Popula. Bomb": "Population Bomb", "Pow-Up Punch": "Power-Up Punch", "Scorch. Sands": "Scorching Sands",
        "Steam Erupt.": "Steam Eruption", "Stom. Tantrum": "Stomping Tantrum", "Supercell Slam": "Supercell Slam",
        "Surg. Strikes": "Surging Strikes", "Water Shurik.": "Water Shuriken"
    ]

    private static let abilityAliases: [String: String] = ["Comotose": "Comatose", "Swords of Ruin": "Sword of Ruin"]
    private static let itemAliases: [String: String] = [
        "Corner. Mask": "Cornerstone Mask", "Hearth. Mask": "Hearthflame Mask", "Well. Mask": "Wellspring Mask",
        "HeavyD. Boots": "Heavy-Duty Boots", "Terrain Exten.": "Terrain Extender", "Terrain Extend.": "Terrain Extender",
        "Weakness Pol.": "Weakness Policy", "Abomasnite": "Abomasite", "Blastoisinite": "Blastoisnite", "Houndoominite": "Houndoomnite",
        "Kangaskhanite": "Kangaskanite", "Rusted Sword": "Rusty Sword"
    ]
}

struct BoundBossReferenceData: Decodable, Sendable {
    struct TypeIcon: Decodable, Sendable { let pngBase64: String; let sha256: String }
    struct TrainerIcon: Decodable, Sendable { let pngBase64: String; let sha256: String; let sourceURL: URL }
    let schemaVersion: Int
    let typeIconSource: String
    let typeIconRevision: String
    let typeIconLicense: String
    let typeIconLicenseText: String
    let descriptionsSource: String
    let descriptionsRevision: String
    let descriptionsLicense: String
    let typeIcons: [String: TypeIcon]
    let abilityDescriptions: [String: String]
    let itemDescriptions: [String: String]
    let moveOverrides: [String: MoveOverride]
    let noItemDescription: String
    let bossMoveTypeOverrides: [String: String]?
    let bossMoveTypeOverrideCells: [String: String]?
    let trainerIconSource: String?
    let trainerIconAttribution: String?
    let trainerIcons: [String: TrainerIcon]?
    let trainerIconsByTeam: [String: [String]]?

    struct MoveOverride: Decodable, Sendable {
        let type: String
        let categoryLabel: String
        let sourceCell: String?
    }

    static let bundled: Self? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "BoundBossReference-v1", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.schemaVersion == 1 else { return nil }
        return value
    }()
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
