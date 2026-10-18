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
    private let speciesByID: [Int: BoundRRDexSpecies]
    private let typesByID: [Int: BoundRRDexType]
    private let movesByID: [Int: BoundRRDexMove]
    private let abilitiesByID: [Int: BoundRRDexAbility]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, gameVersion, difficulty, sourceURL, sourceRevision, sourceSHA256
        case species, types, abilities, moves, normalAbilities, normalMoves
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        gameVersion = try values.decode(String.self, forKey: .gameVersion)
        difficulty = try values.decode(String.self, forKey: .difficulty)
        sourceURL = try values.decode(URL.self, forKey: .sourceURL)
        sourceRevision = try values.decode(String.self, forKey: .sourceRevision)
        sourceSHA256 = try values.decode(String.self, forKey: .sourceSHA256)
        species = try values.decode([BoundRRDexSpecies].self, forKey: .species)
        types = try values.decode([BoundRRDexType].self, forKey: .types)
        abilities = try values.decode([BoundRRDexAbility].self, forKey: .abilities)
        moves = try values.decode([BoundRRDexMove].self, forKey: .moves)
        normalAbilities = try values.decode([Int].self, forKey: .normalAbilities)
        normalMoves = try values.decode([Int].self, forKey: .normalMoves)
        // Preserve the previous first-match behavior if a future catalog has duplicate IDs.
        speciesByID = Dictionary(species.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        typesByID = Dictionary(types.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        movesByID = Dictionary(moves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        abilitiesByID = Dictionary(abilities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

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
              c.abilities.allSatisfy({ !$0.names.isEmpty && $0.names.count == $0.descriptions.count }),
              c.species.allSatisfy({ p in
                  !p.name.isEmpty && p.stats.count == 6 && p.stats.allSatisfy { $0 >= 0 }
                    && !p.types.isEmpty && p.types.allSatisfy(typeIDs.contains)
                    && p.abilities.allSatisfy { $0.count == 2 }
                    && p.learnset.allSatisfy { moveIDs.contains($0.moveID) }
                    && p.evolutions.allSatisfy { ids.contains($0.targetID) }
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return c
    }

    func pokemon(id: Int) -> BoundRRDexSpecies? { speciesByID[id] }
    func type(id: Int) -> BoundRRDexType? { typesByID[id] }
    func move(id: Int) -> BoundRRDexMove? { movesByID[id] }
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
        abilityDetails(for: pokemon, save: save).map { $0.name + ($0.isHidden ? " (Hidden)" : "") }
    }
    func abilityDetails(for pokemon: BoundRRDexSpecies, save: BoundRRDexSave?) -> [AbilityDetail] {
        // Upstream stores Hidden, Primary, Secondary, and displays Primary first.
        [1, 2, 0].compactMap { slot in
            guard pokemon.abilities.indices.contains(slot) else { return nil }
            let pair = pokemon.abilities[slot]
            guard pair[0] != 0 else { return nil }
            let id = save?.randomAbilities == true ? randomizedAbility(pair[0], speciesID: pokemon.id, trainerID: save!.trainerID) : pair[0]
            guard let ability = abilitiesByID[id] else { return nil }
            let variant = save?.randomAbilities == true ? 0 : pair[1]
            guard ability.names.indices.contains(variant), ability.descriptions.indices.contains(variant) else { return nil }
            return AbilityDetail(name: ability.names[variant], description: ability.descriptions[variant], isHidden: slot == 0)
        }
    }
    struct AbilityDetail: Identifiable, Sendable {
        let name: String
        let description: String
        let isHidden: Bool
        var id: String { name + (isHidden ? ".hidden" : ".standard") }
    }
    static func statColorHex(for value: Int) -> String {
        switch value {
        case ..<30: "#CC0000"
        case ..<60: "#ce4d00"
        case ..<90: "#ffe100"
        case ..<120: "#0d8d00"
        case ..<150: "#25d65e"
        default: "#15c9c7"
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
    /// Learnset categories present for this species, in the order used by the compact Dex UI.
    func learnsetMethods(for pokemon: BoundRRDexSpecies) -> [String] {
        let order = ["Level up", "TM/HM", "Tutor", "Egg", "Pre-evolution", "Event"]
        let present = Set(pokemon.learnset.map(\.method))
        return order.filter(present.contains) + present.subtracting(order).sorted()
    }
    /// Compact learnset rows. Browsing one method retains its source entries; searching
    /// spans every method and folds resolved duplicate moves into a single result.
    func learnsetRows(for pokemon: BoundRRDexSpecies, save: BoundRRDexSave?, method: String?, query: String) -> [BoundRRDexLearnsetRow] {
        let isBrowsing = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let search = Self.searchKey(query)
        if isBrowsing {
            guard let method else { return [] }
            return pokemon.learnset.enumerated().compactMap { index, entry in
                guard entry.method == method, let move = learnedMove(entry, pokemon: pokemon, save: save) else { return nil }
                return BoundRRDexLearnsetRow(id: "entry-\(index)", move: move, sources: [entry])
            }.sorted { lhs, rhs in
                if method == "Level up", lhs.level != rhs.level {
                    return (lhs.level ?? Int.max) < (rhs.level ?? Int.max)
                }
                let nameOrder = lhs.move.name.localizedCaseInsensitiveCompare(rhs.move.name)
                return nameOrder == .orderedSame ? lhs.id < rhs.id : nameOrder == .orderedAscending
            }
        }
        guard !search.isEmpty else { return [] }

        var grouped: [Int: (move: BoundRRDexMove, sources: [BoundRRDexSpecies.LearnedMove])] = [:]
        for entry in pokemon.learnset {
            guard let move = learnedMove(entry, pokemon: pokemon, save: save), Self.searchKey(move.name).contains(search) else { continue }
            var group = grouped[move.id] ?? (move, [])
            if !group.sources.contains(where: { $0.method == entry.method && $0.level == entry.level }) {
                group.sources.append(entry)
            }
            grouped[move.id] = group
        }
        return grouped.values.map { group in
            BoundRRDexLearnsetRow(id: "move-\(group.move.id)", move: group.move, sources: group.sources)
        }.sorted {
            let nameOrder = $0.move.name.localizedCaseInsensitiveCompare($1.move.name)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
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

struct BoundRRDexLearnsetRow: Identifiable, Sendable {
    let id: String
    let move: BoundRRDexMove
    let sources: [BoundRRDexSpecies.LearnedMove]
    var level: Int? {
        let levels = Set(sources.filter { $0.method == "Level up" }.compactMap(\.level))
        return levels.count == 1 ? levels.first : nil
    }
    var sourceSummary: String {
        let labels = sources.map { entry -> String in
            if entry.method == "Level up", let level = entry.level { return level == 0 ? "Evolution" : "Level \(level)" }
            if entry.method == "Pre-evolution", let level = entry.level { return "Pre-evolution · Level \(level)" }
            return entry.method
        }
        var seen = Set<String>()
        return labels.filter { seen.insert($0).inserted }.joined(separator: " · ")
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
    let id: Int; let names: [String]; let descriptions: [String]
    enum CodingKeys: String, CodingKey { case id = "ID", names, descriptions }
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
    enum ImportError: LocalizedError, Equatable {
        case cannotPause, currentGameUnavailable, format, incomplete, difficulty
        var errorDescription: String? {
            switch self {
            case .cannotPause: return "Bound could not pause the active game to read its save. It will retry when the game saves again or when you reopen the Dex."
            case .currentGameUnavailable: return "The active GBA game's battery save could not be read. Bound will retry when it becomes available."
            case .format: return "The current game's battery save is not a supported Radical Red 4.1 save."
            case .incomplete: return "This run does not have a complete Radical Red battery save yet. Save once in-game and Bound will detect it automatically."
            case .difficulty: return "This panel supports Normal difficulty. This save has Hardcore or Restricted mode enabled."
            }
        }
    }
    static func shouldDiscardCachedConfiguration(after error: Error) -> Bool {
        guard let error = error as? ImportError else { return false }
        switch error {
        case .format, .incomplete, .difficulty: return true
        case .cannotPause, .currentGameUnavailable: return false
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
        return try readCompletedSave(at: saveURL)
    }

    /// Called after the core has finished writing its battery save. Unlike a live
    /// export, reading this file does not need to pause or resume emulation.
    static func readCompletedSave(at saveURL: URL) throws -> BoundRRDexSave {
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

/// One cache per emulator session. Only the trainer ID and randomizer flags are
/// retained; completed saves replace the cache only when those settings change.
/// The lock never spans a core call, since pausing can invoke the save handler.
final class BoundRRDexSaveCache: @unchecked Sendable {
    private typealias Outcome = Result<BoundRRDexSave, BoundRRDexSave.ImportError>
    private let lock = NSLock()
    private var cached: Outcome?
    private var needsLiveSave = false
    private var revision: UInt64 = 0

    func invalidate(restoredState: Bool) {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        cached = nil
        needsLiveSave = restoredState
    }

    func value(completedSave: () throws -> BoundRRDexSave,
               restoredSave: () throws -> BoundRRDexSave) throws -> BoundRRDexSave {
        lock.lock()
        if let cached { lock.unlock(); return try cached.get() }
        let version = revision
        let useLiveSave = needsLiveSave
        lock.unlock()
        let outcome = Self.read(useLiveSave ? restoredSave : completedSave)
        lock.lock()
        defer { lock.unlock() }
        guard version == revision else {
            // A completed save or state load overtook this read.
            guard let cached else { throw BoundRRDexSave.ImportError.currentGameUnavailable }
            return try cached.get()
        }
        if case .failure(.currentGameUnavailable) = outcome { return try outcome.get() }
        if case .failure(.cannotPause) = outcome { return try outcome.get() }
        cached = outcome
        needsLiveSave = false
        return try outcome.get()
    }

    /// The callback runs after the disk write, before the emulation thread can
    /// start another write. Snapshot and parse that small file here, with no
    /// additional pause/export cycle. Unchanged saves produce no UI event.
    @discardableResult
    func completedSave(read: () throws -> BoundRRDexSave) -> Bool {
        lock.lock()
        revision &+= 1
        let version = revision
        lock.unlock()
        let outcome = Self.read(read)
        lock.lock(); defer { lock.unlock() }
        guard version == revision else { return false }
        // A transient disk error is retried at the next entry/save, and must not
        // turn a restored-state invalidation into permission to read stale disk.
        if case .failure(.currentGameUnavailable) = outcome { return false }
        let changed = cached != outcome
        cached = outcome
        needsLiveSave = false
        return changed
    }

    private static func read(_ read: () throws -> BoundRRDexSave) -> Outcome {
        do { return .success(try read()) }
        catch { return .failure(error as? BoundRRDexSave.ImportError ?? .currentGameUnavailable) }
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
        guard read(gameID: gameID) != choice else { return }
        defaults.set(data, forKey: key)
    }

    /// Refreshes only the parsed randomizer configuration for this ROM. The
    /// selected species and prior configuration remain intact if capture fails.
    /// The closure normally returns the session's cached completed-save settings;
    /// a state load can require a separate live read. Raw bytes are never stored.
    @discardableResult
    func refreshCurrentSave(gameID: String, capture: () throws -> BoundRRDexSave) throws -> Choice {
        guard key(gameID) != nil else { throw BoundRRDexSave.ImportError.currentGameUnavailable }
        var choice = read(gameID: gameID)
        let save: BoundRRDexSave
        do {
            save = try capture()
        } catch {
            if BoundRRDexSave.shouldDiscardCachedConfiguration(after: error) {
                choice.save = nil
                write(choice, gameID: gameID)
            }
            throw error
        }
        choice.save = save
        write(choice, gameID: gameID)
        return choice
    }
}

/// Event bridge for automatic, event-driven refreshes while the RR Dex is open.
/// The event contains only the ROM identifier; it never carries save bytes.
enum BoundRRDexSaveRefreshEvent {
    static let notificationName = Notification.Name("BoundRRDexCurrentSaveDidChange")
    static let gameIDKey = "gameID"
    private final class SuppressionRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var activeGameIDs: [String: Int] = [:]

        func begin(_ gameID: String) {
            lock.lock(); defer { lock.unlock() }
            activeGameIDs[gameID, default: 0] += 1
        }
        func end(_ gameID: String) {
            lock.lock(); defer { lock.unlock() }
            let remaining = (activeGameIDs[gameID] ?? 1) - 1
            if remaining == 0 { activeGameIDs.removeValue(forKey: gameID) }
            else { activeGameIDs[gameID] = remaining }
        }
        func contains(_ gameID: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return (activeGameIDs[gameID] ?? 0) > 0
        }
    }
    private static let suppressionRegistry = SuppressionRegistry()

    static func isSuppressed(gameID: String) -> Bool { suppressionRegistry.contains(gameID) }

    /// Core pause writes invoke EmulatorCore.saveHandler inline. Suppressing the
    /// current ROM around the pause/export prevents that save from recursively
    /// scheduling another automatic refresh.
    static func suppressWhileCapturing<T>(gameID: String, _ capture: () throws -> T) rethrows -> T {
        suppressionRegistry.begin(gameID)
        defer { suppressionRegistry.end(gameID) }
        return try capture()
    }

    static func post(gameID: String) {
        guard !gameID.isEmpty else { return }
        guard !suppressionRegistry.contains(gameID) else { return }
        NotificationCenter.default.post(name: notificationName, object: nil, userInfo: [gameIDKey: gameID])
    }
}
