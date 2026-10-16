import Foundation

struct BoundRRDexCatalog: Decodable, Sendable {
    let schemaVersion: Int
    let gameVersion: String
    let difficulty: String
    let sourceURL: URL
    let sourceRevision: String
    let sourceSHA256: String
    let species: [BoundRRDexSpecies]
    let types: [BoundRRDexType]
    let abilities: [BoundRRDexAbility]
    let moves: [BoundRRDexMove]
    let normalAbilities: [Int]
    let normalMoves: [Int]

    static let bundled: Self? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "RadicalRedDex-v4.1", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }()

    static func decode(_ data: Data) throws -> Self {
        let c = try JSONDecoder().decode(Self.self, from: data)
        let ids = Set(c.species.map(\.id)), moveIDs = Set(c.moves.map(\.id)), typeIDs = Set(c.types.map(\.id))
        guard c.schemaVersion == 1, c.gameVersion == "4.1", c.difficulty == "Normal", !c.species.isEmpty,
              ids.count == c.species.count, !c.normalAbilities.isEmpty, !c.normalMoves.isEmpty,
              c.species.allSatisfy({ p in
                  !p.name.isEmpty && p.stats.count == 6 && p.stats.allSatisfy { $0 >= 0 }
                    && !p.types.isEmpty && p.types.allSatisfy(typeIDs.contains)
                    && p.abilities.allSatisfy { $0.count == 2 }
                    && p.learnset.allSatisfy { moveIDs.contains($0.moveID) }
                    && p.evolutions.allSatisfy { ids.contains($0.targetID) }
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return c
    }

    func pokemon(id: Int) -> BoundRRDexSpecies? { species.first { $0.id == id } }
    func type(id: Int) -> BoundRRDexType? { types.first { $0.id == id } }
    func move(id: Int) -> BoundRRDexMove? { moves.first { $0.id == id } }
    /// The upstream dex uses case-insensitive substring suggestions. Folding punctuation
    /// also allows convenient searches such as "mr mime" and "nidoran female".
    func suggestions(_ query: String) -> [BoundRRDexSpecies] {
        let text = Self.searchKey(query)
        guard !text.isEmpty else { return [] }
        return species.filter { Self.searchKey($0.name).contains(text) }
    }
    private static func searchKey(_ text: String) -> String {
        text.replacingOccurrences(of: "♀", with: "female").replacingOccurrences(of: "♂", with: "male")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }
    func abilityNames(for pokemon: BoundRRDexSpecies, save: BoundRRDexSave?) -> [String] {
        // Upstream stores Hidden, Primary, Secondary, and displays Primary first.
        [1, 2, 0].compactMap { slot in
            guard pokemon.abilities.indices.contains(slot) else { return nil }
            let pair = pokemon.abilities[slot]
            guard pair[0] != 0 else { return nil }
            let id = save?.randomAbilities == true ? randomizedAbility(pair[0], speciesID: pokemon.id, trainerID: save!.trainerID) : pair[0]
            guard let ability = abilities.first(where: { $0.id == id }) else { return nil }
            let variant = save?.randomAbilities == true ? 0 : pair[1]
            guard ability.names.indices.contains(variant) else { return nil }
            return ability.names[variant] + (slot == 0 ? " (Hidden)" : "")
        }
    }
    func randomizedAbility(_ original: Int, speciesID: Int, trainerID: UInt32) -> Int {
        guard original != 0 else { return 0 }
        let seed = max(1, trainerID), count = normalAbilities.count
        let secret = Int((seed >> 16) & 0xffff) % 255
        var index = (Int(seed & 0xffff) % count + speciesID + original) & 0xffff
        if index > count { index = (index - count + 2) & 0xffff }
        return normalAbilities[(index ^ secret) % count]
    }
    func randomizedMove(_ original: Int, speciesID: Int, trainerID: UInt32) -> Int {
        guard original != 0, original != 0xa5 else { return original }
        let product = UInt64(max(1, trainerID)) &* UInt64(speciesID) &* UInt64(original)
        return normalMoves[Int(product & 0xffffffff) % normalMoves.count]
    }
    func learnedMove(_ entry: BoundRRDexSpecies.LearnedMove, pokemon: BoundRRDexSpecies, save: BoundRRDexSave?) -> BoundRRDexMove? {
        // Exactly as upstream: randomization affects level-up and pre-evolution
        // moves; TM/HM, tutor, egg and event entries keep their original moves.
        let random = save?.randomLearnset == true && ["Level up", "Pre-evolution"].contains(entry.method)
        return move(id: random ? randomizedMove(entry.moveID, speciesID: pokemon.id, trainerID: save!.trainerID) : entry.moveID)
    }
    struct EvolutionLink: Identifiable, Sendable {
        let from: BoundRRDexSpecies
        let to: BoundRRDexSpecies
        let method: String
        var id: String { "\(from.id)-\(to.id)-\(method)" }
    }
    func evolutionLine(for pokemon: BoundRRDexSpecies) -> [EvolutionLink] {
        var result: [EvolutionLink] = [], visited = Set<Int>()
        func visit(_ p: BoundRRDexSpecies) {
            guard visited.insert(p.id).inserted else { return }
            for edge in p.evolutions {
                guard let next = self.pokemon(id: edge.targetID) else { continue }
                result.append(EvolutionLink(from: p, to: next, method: edge.method)); visit(next)
            }
        }
        visit(self.pokemon(id: pokemon.ancestorID) ?? pokemon)
        return result
    }
    struct Matchup: Identifiable, Sendable {
        let type: BoundRRDexType
        let multiplier: Double
        var id: Int { type.id }
        var label: String { multiplier.formatted(.number.precision(.fractionLength(0...2))) + "×" }
    }
    func defensiveMatchups(for pokemon: BoundRRDexSpecies) -> [Matchup] {
        types.map { attack in
            let multiplier = Set(pokemon.types).reduce(1.0) { value, defense in
                guard attack.matchup.indices.contains(defense) else { return value }
                switch attack.matchup[defense] { case 20: return value * 2; case 5: return value * 0.5; case 1: return 0; default: return value }
            }
            return Matchup(type: attack, multiplier: multiplier)
        }
    }
}

struct BoundRRDexSpecies: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let dexNumber: Int
    let ancestorID: Int
    let types: [Int]
    let stats: [Int] // HP, Atk, Def, SpA, SpD, Spe
    let abilities: [[Int]]
    let sprite: String // Upstream's form-specific PNG, base64 encoded.
    let evolutions: [Evolution]
    let learnset: [LearnedMove]
    struct Evolution: Decodable, Sendable { let targetID: Int; let method: String }
    struct LearnedMove: Decodable, Sendable { let moveID: Int; let method: String; let level: Int? }
}
struct BoundRRDexType: Decodable, Identifiable, Sendable {
    let id: Int; let name: String; let color: String; let matchup: [Int]
    enum CodingKeys: String, CodingKey { case id = "ID", name, color, matchup }
}
struct BoundRRDexAbility: Decodable, Identifiable, Sendable {
    let id: Int; let names: [String]
    enum CodingKeys: String, CodingKey { case id = "ID", names }
}
struct BoundRRDexMove: Decodable, Identifiable, Sendable {
    let id: Int; let name: String; let power: Int; let accuracy: Int; let pp: Int; let type: Int; let split: Int
    enum CodingKeys: String, CodingKey { case id = "ID", name, power, accuracy, pp, type, split }
    var category: String { ["Physical", "Special", "Status"].indices.contains(split) ? ["Physical", "Special", "Status"][split] : "—" }
}

/// Only randomizer configuration is retained. Raw saves never enter the dex store.
struct BoundRRDexSave: Codable, Equatable, Sendable {
    let trainerID: UInt32
    let randomAbilities: Bool
    let randomLearnset: Bool
    var summary: String {
        let flags = [randomAbilities ? "Random abilities" : nil, randomLearnset ? "Random learnset" : nil].compactMap { $0 }
        return flags.isEmpty ? "Standard abilities and moves" : flags.joined(separator: " · ")
    }
    enum ImportError: LocalizedError {
        case cannotPause, currentGameUnavailable, format, incomplete, difficulty
        var errorDescription: String? {
            switch self {
            case .cannotPause: return "The current game cannot be paused for import. Finish the multiplayer session and try again."
            case .currentGameUnavailable: return "A current-game battery save is unavailable. Start an active GBA game with Radical Red 4.1 and try again."
            case .format: return "The current game's battery save is not a supported Radical Red 4.1 save."
            case .incomplete: return "This run has no complete Radical Red battery save yet. Save once in-game, then tap Import save again."
            case .difficulty: return "This panel supports Normal difficulty. This save has Hardcore or Restricted mode enabled."
            }
        }
    }
    static func parse(_ data: Data) throws -> Self {
        guard [0x1c000, 0x20000].contains(data.count) else { throw ImportError.format }
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
        var complete: [(UInt32, [Int: Int])] = []
        // Two rotating slots, fourteen sectors each. Do not mix sectors from
        // different writes (the upstream site's parser does not enforce this).
        for base in [0, 0xe000] {
            var sectors: [Int: Int] = [:], index: UInt32?
            for offset in stride(from: base, to: base + 0xe000, by: 0x1000) {
                guard u32(offset + 0xff8) == 0x08012025 else { continue }
                let id = u16(offset + 0xff4), savedIndex = u32(offset + 0xffc)
                guard (0..<14).contains(id), sectors[id] == nil else { continue }
                if let index, index != savedIndex { continue }
                index = savedIndex; sectors[id] = offset
            }
            if sectors.count == 14, let index { complete.append((index, sectors)) }
        }
        guard let chosen = complete.reduce(nil as (UInt32, [Int: Int])?, { latest, slot in
            guard let latest else { return slot }
            return Int32(bitPattern: slot.0 &- latest.0) > 0 ? slot : latest
        }), let trainer = chosen.1[0], let flags = chosen.1[4] else { throw ImportError.incomplete }
        guard bytes[flags + 0xdb2] & 0x10 == 0, bytes[flags + 0xdc3] & 0x40 == 0 else { throw ImportError.difficulty }
        let random = bytes[trainer + 0xf2c]
        return Self(trainerID: u32(trainer + 0xa), randomAbilities: random & 4 != 0, randomLearnset: random & 2 != 0)
    }
}

enum BoundRRDexCurrentSaveImport {
    private static let maximumFileSize = 0x20000

    static func capture(temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                        export: (URL) throws -> Void) throws -> BoundRRDexSave {
        let directory = temporaryDirectory.appendingPathComponent("bound-rrdex-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try export(directory.appendingPathComponent("current-game.sav"))
        } catch {
            throw BoundRRDexSave.ImportError.currentGameUnavailable
        }

        let saveURL = directory.appendingPathComponent("current-game.sav")
        let fileSize: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: saveURL.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw BoundRRDexSave.ImportError.currentGameUnavailable
            }
            fileSize = size.intValue
        } catch let error as BoundRRDexSave.ImportError {
            throw error
        } catch {
            throw BoundRRDexSave.ImportError.currentGameUnavailable
        }
        guard fileSize <= maximumFileSize else { throw BoundRRDexSave.ImportError.format }

        let data: Data
        do {
            data = try Data(contentsOf: saveURL, options: [.mappedIfSafe])
        } catch {
            throw BoundRRDexSave.ImportError.currentGameUnavailable
        }
        guard data.count <= maximumFileSize else { throw BoundRRDexSave.ImportError.format }
        return try BoundRRDexSave.parse(data)
    }
}

final class BoundRRDexPreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    struct Choice: Codable, Equatable {
        var speciesID: Int = 1
        var save: BoundRRDexSave?
    }
    private func key(_ gameID: String) -> String? {
        guard !gameID.isEmpty, gameID.utf8.count <= 128,
              gameID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return "bound.rrdex.choice.v1." + gameID
    }
    func read(gameID: String) -> Choice {
        guard let key = key(gameID), let data = defaults.data(forKey: key), let choice = try? JSONDecoder().decode(Choice.self, from: data) else { return Choice() }
        return choice
    }
    func write(_ choice: Choice, gameID: String) {
        guard let key = key(gameID), let data = try? JSONEncoder().encode(choice) else { return }
        defaults.set(data, forKey: key)
    }
}
