import Foundation
import CryptoKit
import Combine
import SwiftUI
import DeltaCore
import UIKit

/// Stable across evolutions, nicknames, party ordering, boxes and hatching.
struct BoundSoulIdentity: Codable, Hashable, Comparable, Sendable {
    let personality: UInt32
    let trainer: UInt32
    static func < (a: Self, b: Self) -> Bool {
        a.personality == b.personality ? a.trainer < b.trainer : a.personality < b.personality
    }
    var bytes: Data {
        var result = Data()
        for word in [personality, trainer] { for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: word >> shift)) } }
        return result
    }
    static func read(_ data: Data, at offset: Int) -> Self? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        func word(_ n: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[n + $1]) << ($1 * 8) } }
        return .init(personality: word(offset), trainer: word(offset + 4))
    }
}

struct BoundSoulMon: Equatable, Sendable {
    let identity: BoundSoulIdentity
    let species: Int
    let name: String
    let area: Int
    let eggOrigin: Bool
    let isEgg: Bool
    let hp: Int?
    var level: Int? = nil
    var maxHP: Int? = nil
    var inParty = false
    static func text(_ data: Data) -> String {
        data.prefix(while: { $0 != 255 }).map { b -> String in
            switch b {
            case 0: return " "
            case 161...170: return String(b - 161)
            case 187...212: return String(UnicodeScalar(Int(b - 187) + 65)!)
            case 213...238: return String(UnicodeScalar(Int(b - 213) + 97)!)
            case 173: return "."
            case 174: return "-"
            default: return "?"
            }
        }.joined()
    }
    static func areaNames(rom: Data) -> [Int: String] {
        guard rom.count == 0x2000000 else { return [:] }
        var names: [Int: String] = [:]
        for index in 0..<109 {
            let offset = 0x3F1CAC + index * 4
            let pointer = (0..<4).reduce(0) { $0 | Int(rom[offset + $1]) << ($1 * 8) } - 0x08000000
            guard pointer >= 0, pointer < rom.count - 32 else { continue }
            names[index + 0x58] = text(rom.subdata(in: pointer..<pointer + 32))
        }
        return names
    }
    static func decode(_ data: Data, stride: Int) -> [Self] {
        guard [58, 100].contains(stride), data.count % stride == 0 else { return [] }
        return Swift.stride(from: 0, to: data.count, by: stride).compactMap { offset in
            func half(_ n: Int) -> Int { Int(data[offset + n]) | Int(data[offset + n + 1]) << 8 }
            let species = half(stride == 100 ? 32 : 28)
            guard data[offset + 19] & 2 != 0, (1...4095).contains(species), let identity = BoundSoulIdentity.read(data, at: offset) else { return nil }
            let misc = stride == 100 ? 68 : 50
            let isEgg = data[offset + 19] & 4 != 0 || data[offset + misc + 7] & 0x40 != 0
            // Native hatch preserves metLevel=0 while changing the displayed met
            // location; egg identity remains the original ordinal in the journal.
            let eggOrigin = isEgg || (half(misc + 2) & 127) == 0 || data[offset + misc + 1] == 253
            let name = text(data.subdata(in: (offset + 8)..<(offset + 18)))
            return .init(identity: identity, species: species, name: name.isEmpty ? "Pokémon" : name,
                         area: Int(data[offset + misc + 1]), eggOrigin: eggOrigin, isEgg: isEgg, hp: stride == 100 && half(88) > 0 ? half(86) : nil,
                         level: stride == 100 && (1...100).contains(Int(data[offset + 84])) ? Int(data[offset + 84]) : nil,
                         maxHP: stride == 100 && half(88) > 0 ? half(88) : nil, inParty: stride == 100)
        }
    }
}

enum BoundSoulWipeout {
    /// A lost pair is not a game over while another usable party member lives.
    /// Eggs and boxed Pokémon cannot keep the current party in a battle.
    static func occurred(party: [BoundSoulMon], ledger: BoundSoulLedger, friendly: Bool = false) -> Bool {
        guard !friendly, ledger.valid, !ledger.offering, !ledger.ended, !ledger.dead.isEmpty else { return false }
        let members = party.filter { $0.inParty && !$0.isEgg }
        guard !members.isEmpty, members.contains(where: { mon in
            ledger.records.contains { $0.eligible && $0.identities.contains(mon.identity) }
        }) else { return false }
        return members.allSatisfy { ledger.denied.contains($0.identity) || $0.hp == 0 }
    }
}

struct BoundSoulRecord: Codable, Equatable, Sendable {
    let identity: BoundSoulIdentity
    let slot: String
    var name: String
    var eligible: Bool
    var aliases: Set<BoundSoulIdentity> = []
    var pendingHatch = false
    var identities: Set<BoundSoulIdentity> { aliases.union([identity]) }
}

struct BoundSoulDeath: Codable, Equatable, Identifiable, Sendable {
    let slot: String
    let recordedAt: Date?
    var localName: String?
    var partnerName: String?
    var announced: Bool
    var localCaught: Bool?
    var partnerCaught: Bool?
    var id: String { slot }
    var localLabel: String { localName ?? (localCaught == true ? "Your Pokémon" : "No catch yet") }
    var partnerLabel: String { partnerName ?? (partnerCaught == false ? "No catch yet" : "Partner’s Pokémon") }
    var names: String { localLabel + " ↔ " + partnerLabel }
}

struct BoundSoulLedger: Codable, Equatable, Sendable {
    static let version = 1
    var version = Self.version
    let run: UUID
    let binding: String
    var records: [BoundSoulRecord] = []
    var dead: Set<String> = []
    var nextEgg = 1
    var offering = false
    var ended = false
    // Optional fields preserve journals written before paired encounter tracking.
    var partnerAcquisitions: Set<String>?
    var partnerNames: [String: String]?
    var memorials: [BoundSoulDeath]?
    // An authenticated own-origin catch may outlive an older native snapshot.
    // Preserve the spent slot without assigning it a fabricated mon identity.
    var consumedSlots: Set<String>?
    var partnerSlots: Set<String> { partnerAcquisitions ?? [] }
    var acquired: Set<String> { Set(records.filter(\.eligible).map(\.slot)).union(consumedSlots ?? []) }
    var acquisitionBits: Data { Self.bits(acquired) }
    static func validSlot(_ slot: String) -> Bool {
        let parts = slot.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[1]), String(n) == parts[1] else { return false }
        return parts[0] == "area" ? (0...255).contains(n) : parts[0] == "egg" && (1...2048).contains(n)
    }
    var valid: Bool {
        version == Self.version && binding.count == 64 && records.count <= 2048 && dead.count <= 2304
        && (1...2049).contains(nextEgg) && Set(records.flatMap(\.identities)).count == records.reduce(0, { $0 + $1.identities.count })
        && records.reduce(0, { $0 + $1.identities.count }) <= 2048
        && records.allSatisfy { Self.validSlot($0.slot) && $0.name.count <= 20 }
        && dead.allSatisfy(Self.validSlot)
        && (consumedSlots ?? []).count <= 2304 && (consumedSlots ?? []).allSatisfy(Self.validSlot)
        && partnerSlots.count <= 2304 && partnerSlots.allSatisfy(Self.validSlot)
        && (partnerNames ?? [:]).allSatisfy { partnerSlots.contains($0.key) && $0.value.count <= 20 }
        && (memorials ?? []).count <= 2304
        && Set((memorials ?? []).map(\.slot)).count == (memorials ?? []).count
        && (memorials ?? []).allSatisfy { dead.contains($0.slot) && ($0.recordedAt?.timeIntervalSince1970.isFinite ?? true) && ($0.localName?.count ?? 0) <= 20 && ($0.partnerName?.count ?? 0) <= 20 }
        && Set(records.filter(\.eligible).map(\.slot)).count == records.filter(\.eligible).count
    }
    var lossBits: Data { Self.bits(dead) }
    static func bits(_ slots: Set<String>) -> Data {
        var bits = Data(repeating: 0, count: 288)
        for key in slots {
            let parts = key.split(separator: ":")
            guard let value = Int(parts[1]) else { continue }
            let bit = parts[0] == "area" ? value : 256 + value - 1
            bits[bit / 8] |= 1 << (bit % 8)
        }
        return bits
    }
    static func losses(_ bits: Data) -> Set<String> {
        guard bits.count == 288 else { return [] }
        return Set((0..<2304).filter { bits[$0 / 8] & (1 << ($0 % 8)) != 0 }
            .map { $0 < 256 ? "area:\($0)" : "egg:\($0 - 255)" })
    }
    var denied: Set<BoundSoulIdentity> {
        Set(records.filter { !$0.eligible || dead.contains($0.slot) }.flatMap(\.identities))
    }
    /// These facts come only from the durable ledger. Names are presentation,
    /// so a nickname change cannot mutate an event already in the outbox.
    var sharedEvents: [BoundSoulSharedEvent] {
        acquired.sorted().map { .init(run: run, kind: .acquired, slot: $0) }
        + dead.sorted().map { .init(run: run, kind: .death, slot: $0) }
        + (ended ? [.init(run: run, kind: .ended, slot: nil)] : [])
    }
    /// Restoring a player's older save restores its native world, never its
    /// permission to reuse an encounter or revive a permanently lost pair.
    static func mergeForIndependentRestore(current: Data, incoming: Data) throws -> Data {
        guard current.count <= 2_097_152, incoming.count <= 2_097_152 else { throw Error.corrupt }
        var value = try JSONDecoder().decode(Self.self, from: current)
        let older = try JSONDecoder().decode(Self.self, from: incoming)
        guard value.valid, older.valid, value.run == older.run, value.binding == older.binding else { throw Error.corrupt }
        for record in older.records {
            let matches = value.records.indices.filter { !value.records[$0].identities.isDisjoint(with: record.identities) }
            guard matches.count <= 1 else { throw Error.corrupt }
            if let index = matches.first {
                guard value.records[index].slot == record.slot else { throw Error.corrupt }
                value.records[index].aliases.formUnion(record.identities.subtracting([value.records[index].identity]))
                value.records[index].eligible = value.records[index].eligible && record.eligible
                value.records[index].pendingHatch = value.records[index].pendingHatch && record.pendingHatch
            } else {
                var additional = record
                // Divergent older saves cannot introduce another eligible catch
                // for a slot already consumed by this player's durable history.
                if value.acquired.contains(additional.slot) { additional.eligible = false }
                value.records.append(additional)
            }
        }
        let priorDeaths = value.dead
        value.dead.formUnion(older.dead)
        if value.consumedSlots != nil || older.consumedSlots != nil {
            value.consumedSlots = (value.consumedSlots ?? []).union(older.consumedSlots ?? [])
        }
        value.nextEgg = max(value.nextEgg, older.nextEgg)
        value.offering = value.offering && older.offering
        value.ended = value.ended || older.ended
        if value.partnerAcquisitions != nil || older.partnerAcquisitions != nil {
            value.partnerAcquisitions = value.partnerSlots.union(older.partnerSlots)
        }
        value.partnerNames = (older.partnerNames ?? [:]).merging(value.partnerNames ?? [:]) { _, latest in latest }
        var memorials = value.memorials ?? []
        for memorial in older.memorials ?? [] {
            if let index = memorials.firstIndex(where: { $0.slot == memorial.slot }) {
                memorials[index].announced = memorials[index].announced || memorial.announced
                memorials[index].localName = memorials[index].localName ?? memorial.localName
                memorials[index].partnerName = memorials[index].partnerName ?? memorial.partnerName
                if memorial.localCaught == true { memorials[index].localCaught = true }
                if memorial.partnerCaught == true { memorials[index].partnerCaught = true }
            } else { memorials.append(memorial) }
        }
        value.memorials = memorials
        value.recordDeaths(previous: priorDeaths)
        guard value.valid else { throw Error.corrupt }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    /// Existing journal losses are quiet history; only newly committed losses queue a moment.
    mutating func recordDeaths(previous: Set<String>, at date: Date = Date()) {
        guard !dead.isEmpty else { return }
        var entries = memorials ?? []
        let local = Dictionary(uniqueKeysWithValues: records.filter(\.eligible).map { ($0.slot, $0.name) })
        var indices = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.slot, $0.offset) })
        for slot in dead.sorted() {
            if let index = indices[slot] {
                // A delayed rotating name or a later catch can fill a missing name,
                // but renaming/evolving never rewrites a known memorial name.
                if acquired.contains(slot) { entries[index].localCaught = true }
                if partnerSlots.contains(slot) { entries[index].partnerCaught = true }
                else if entries[index].partnerCaught == nil, partnerAcquisitions != nil { entries[index].partnerCaught = false }
                if entries[index].localName == nil { entries[index].localName = local[slot] }
                if entries[index].partnerName == nil { entries[index].partnerName = partnerNames?[slot] }
            } else {
                let historical = previous.contains(slot)
                indices[slot] = entries.count
                entries.append(.init(slot: slot, recordedAt: historical ? nil : date,
                                     localName: local[slot], partnerName: partnerNames?[slot], announced: historical,
                                     localCaught: acquired.contains(slot), partnerCaught: partnerAcquisitions == nil ? nil : partnerSlots.contains(slot)))
            }
        }
        memorials = entries
    }
    mutating func observe(_ mons: [BoundSoulMon], registering: Bool, fainted: Set<BoundSoulIdentity>,at date:Date=Date()) throws {
        let previousDeaths = dead
        for mon in mons {
            if let index = records.firstIndex(where: { $0.identities.contains(mon.identity) }) {
                records[index].name = mon.name
                if !mon.isEgg { records[index].pendingHatch = false }
            } else if !mon.isEgg,
                      let index = records.firstIndex(where: { $0.pendingHatch && $0.identity.personality == mon.identity.personality }),
                      records.filter({ $0.pendingHatch && $0.identity.personality == mon.identity.personality }).count == 1 {
                // Native hatching can replace an egg's OT with this trainer.
                // Preserve the egg ordinal and retain both identity aliases.
                records[index].aliases.insert(mon.identity)
                records[index].pendingHatch = false; records[index].name = mon.name
            } else if registering {
                guard records.count < 2048, nextEgg <= 2048 else { throw Error.capacity }
                let slot: String
                if mon.eggOrigin { slot = "egg:\(nextEgg)"; nextEgg += 1 }
                else { slot = "area:\(mon.area)" }
                let eligible = !acquired.contains(slot)
                records.append(.init(identity: mon.identity, slot: slot, name: mon.name, eligible: eligible, pendingHatch: mon.isEgg))
            }
        }
        for record in records where record.eligible {
            if (!record.pendingHatch && !fainted.isDisjoint(with: record.identities)) || mons.contains(where: { record.identities.contains($0.identity) && !$0.isEgg && $0.hp == 0 }) {
                dead.insert(record.slot)
            }
        }
        recordDeaths(previous: previousDeaths,at:date)
        guard valid else { throw Error.capacity }
    }
    enum Error: Swift.Error { case capacity, corrupt }
}

/// Journal payloads are monotonic slot facts, independent of arrival order,
/// transport sessions and the time either player reaches an area.
struct BoundSoulSharedEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case acquired, death, ended }
    var version = 1
    let run: UUID
    let kind: Kind
    let slot: String?
    var id: String { "soul:\(run.uuidString):\(kind.rawValue):\(slot ?? "run")" }
    var valid: Bool { version == 1 && (kind == .ended ? slot == nil : slot.map(BoundSoulLedger.validSlot) == true) }
    var payload: Data? {
        guard valid else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

struct BoundSoulRow: Codable, Equatable, Sendable {
    let slot: String
    let name: String
    let dead: Bool
    var valid: Bool { BoundSoulLedger.validSlot(slot) && name.count <= 20 && name.utf8.count <= 80 }
}
/// BSL2 carries both complete bitmaps in every heartbeat within the gameplay packet limit.
/// Names rotate independently; they never determine whether a catch is occupied.
struct BoundSoulPacket: Sendable {
    static let prefix = Data([0x42, 0x53, 0x4C, 0x32])
    static let legacyPrefix = Data([0x42, 0x53, 0x4C, 0x31])
    static func recognizes(_ data: Data) -> Bool { data.starts(with: prefix) || data.starts(with: legacyPrefix) || data.starts(with: BoundSoulTeamPacket.prefix) }
    enum Kind: String, CaseIterable { case offer, accept, confirm, decline, state, end }
    let version: Int
    let run: UUID
    let kind: Kind
    var rows: [BoundSoulRow] = []
    var losses = Data(repeating: 0, count: 288)
    var acquired = Data(repeating: 0, count: 288)
    var sender = UUID()
    var receiver: UUID? = nil
    func encoded() -> Data? {
        guard version == 2, losses.count == 288, acquired.count == 288, rows.count <= 8,
              rows.allSatisfy(\.valid), Set(rows.map(\.slot)).count == rows.count,
              let kindIndex = Kind.allCases.firstIndex(of: kind) else { return nil }
        var data = Self.prefix
        data.append(2); data.append(UInt8(kindIndex))
        func appendUUID(_ value: UUID) { var bytes = value.uuid; withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) } }
        appendUUID(run); appendUUID(sender)
        data.append(receiver == nil ? 0 : 1)
        appendUUID(receiver ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
        data.append(losses); data.append(acquired); data.append(UInt8(rows.count))
        for row in rows {
            let parts = row.slot.split(separator: ":"), n = Int(parts[1])!
            let index = parts[0] == "area" ? n : n + 255
            let name = Data(row.name.utf8)
            guard name.count <= 80 else { return nil }
            data.append(UInt8(truncatingIfNeeded: index)); data.append(UInt8(index >> 8))
            data.append(row.dead ? 1 : 0); data.append(UInt8(name.count)); data.append(name)
        }
        return data.count <= 1024 ? data : nil
    }
    static func decode(_ data: Data) -> Self? {
        guard data.count <= 1024, data.count >= 632, data.starts(with: prefix), data[4] == 2,
              Int(data[5]) < Kind.allCases.count, data[38] <= 1 else { return nil }
        func uuid(at offset: Int) -> UUID {
            let b = Array(data[offset..<offset+16])
            return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        }
        let count = Int(data[631]); guard count <= 8 else { return nil }
        var offset = 632, rows: [BoundSoulRow] = []
        for _ in 0..<count {
            guard offset + 4 <= data.count else { return nil }
            let index = Int(data[offset]) | Int(data[offset+1]) << 8
            let dead = data[offset+2], length = Int(data[offset+3]); offset += 4
            guard index < 2304, dead <= 1, length <= 80, offset + length <= data.count,
                  let name = String(data: data[offset..<offset+length], encoding: .utf8), name.count <= 20 else { return nil }
            rows.append(.init(slot: index < 256 ? "area:\(index)" : "egg:\(index - 255)", name: name, dead: dead == 1))
            offset += length
        }
        guard offset == data.count, Set(rows.map(\.slot)).count == rows.count else { return nil }
        return .init(version: 2, run: uuid(at: 6), kind: Kind.allCases[Int(data[5])], rows: rows,
                     losses: data.subdata(in: 55..<343), acquired: data.subdata(in: 343..<631),
                     sender: uuid(at: 22), receiver: data[38] == 1 ? uuid(at: 39) : nil)
    }
}

struct BoundSoulTeamMember: Equatable, Sendable {
    var slot: String?
    var name: String
    var species: Int
    var level: Int?
    var hp: Int?
    var maxHP: Int?
    var isEgg = false
    var barred = false
    var valid: Bool {
        (slot == nil || BoundSoulLedger.validSlot(slot!)) && !name.isEmpty && name.count <= 20 && name.utf8.count <= 80
        && (0...4095).contains(species) && (level == nil || (1...100).contains(level!))
        && ((hp == nil && maxHP == nil) || (hp != nil && maxHP != nil && (1...65535).contains(maxHP!) && (0...maxHP!).contains(hp!)))
    }
}
struct BoundSoulTeam: Equatable, Sendable {
    var party: [BoundSoulTeamMember]
    var boxed = Data(repeating: 0, count: 288)
    var fieldReady = true
    var valid: Bool {
        party.count <= 6 && party.allSatisfy(\.valid) && boxed.count == 288
        && Set(party.compactMap(\.slot)).count == party.compactMap(\.slot).count
        && Set(party.compactMap(\.slot)).isDisjoint(with: BoundSoulLedger.losses(boxed))
    }
    static func capture(mons: [BoundSoulMon], ledger: BoundSoulLedger) -> Self? {
        let records = Dictionary(uniqueKeysWithValues: ledger.records.flatMap { record in record.identities.map { ($0, record) } })
        let denied = ledger.denied
        var usedSlots: Set<String> = []
        let party = mons.filter(\.inParty).map { mon -> BoundSoulTeamMember in
            let record = records[mon.identity]
            let slot = record.flatMap { $0.eligible && usedSlots.insert($0.slot).inserted ? $0.slot : nil }
            return .init(slot: slot, name: mon.name,
                         species: mon.isEgg ? 0 : mon.species, level: mon.isEgg ? nil : mon.level,
                         hp: mon.isEgg ? nil : mon.hp, maxHP: mon.isEgg ? nil : mon.maxHP,
                         isEgg: mon.isEgg, barred: denied.contains(mon.identity))
        }
        let boxes = Set(mons.filter { !$0.inParty }.compactMap { mon -> String? in
            guard let record = records[mon.identity], record.eligible else { return nil }; return record.slot
        })
        let result = Self(party: party, boxed: BoundSoulLedger.bits(boxes))
        return result.valid ? result : nil
    }
}
/// Optional presentation channel. BSL2 remains the authority for acquired/dead slots.
struct BoundSoulTeamPacket: Sendable {
    static let prefix = Data("BST1".utf8)
    let run: UUID
    let sender: UUID
    let receiver: UUID
    let sequence: UInt64
    let team: BoundSoulTeam
    func encoded() -> Data? {
        guard team.valid, sequence > 0 else { return nil }
        var data = Self.prefix; data.append(1)
        for uuid in [run, sender, receiver] { var bytes = uuid.uuid; withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) } }
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8(truncatingIfNeeded: sequence >> shift)) }
        data.append(team.fieldReady ? 1 : 0); data.append(UInt8(team.party.count)); data.append(team.boxed)
        func half(_ value: Int) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
        for member in team.party {
            let parts = member.slot?.split(separator: ":")
            let slot = parts.map { Int($0[1])! + ($0[0] == "egg" ? 255 : 0) } ?? 65535
            half(slot); half(member.species); data.append(UInt8(member.level ?? 0))
            half(member.hp ?? 0); half(member.maxHP ?? 0)
            data.append((member.isEgg ? 1 : 0) | (member.barred ? 2 : 0))
            let name = Data(member.name.utf8); data.append(UInt8(name.count)); data.append(name)
        }
        return data.count <= 1024 ? data : nil
    }
    static func decode(_ data: Data) -> Self? {
        guard (351...1024).contains(data.count), data.starts(with: prefix), data[4] == 1, data[61] <= 1, data[62] <= 6 else { return nil }
        func uuid(_ n: Int) -> UUID { let b = Array(data[n..<n+16]); return UUID(uuid:(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15])) }
        func half(_ n: Int) -> Int { Int(data[n]) | Int(data[n+1]) << 8 }
        let sequence = (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[53+$1]) << ($1*8) }
        var offset = 351, party: [BoundSoulTeamMember] = []
        for _ in 0..<Int(data[62]) {
            guard offset + 11 <= data.count else { return nil }
            let slot = half(offset), species = half(offset+2), level = Int(data[offset+4])
            let hp = half(offset+5), maxHP = half(offset+7), flags = data[offset+9], length = Int(data[offset+10]); offset += 11
            guard (slot < 2304 || slot == 65535), flags <= 3, length <= 80, offset + length <= data.count,
                  let name = String(data: data[offset..<offset+length], encoding: .utf8) else { return nil }
            party.append(.init(slot: slot == 65535 ? nil : slot < 256 ? "area:\(slot)" : "egg:\(slot-255)", name: name, species: species,
                               level: level == 0 ? nil : level, hp: maxHP == 0 && hp == 0 ? nil : hp, maxHP: maxHP == 0 ? nil : maxHP,
                               isEgg: flags & 1 != 0, barred: flags & 2 != 0))
            offset += length
        }
        let team = BoundSoulTeam(party: party, boxed: data.subdata(in: 63..<351), fieldReady: data[61] == 1)
        guard offset == data.count, sequence > 0, team.valid else { return nil }
        return .init(run: uuid(5), sender: uuid(21), receiver: uuid(37), sequence: sequence, team: team)
    }
}

struct BoundSoulEncounter: Identifiable, Equatable {
    enum State: String { case available = "Available", localOnly = "Waiting for partner", partnerOnly = "Waiting for you", linked = "Linked", lost = "Fainted", syncing = "Syncing partner" }
    let slot: String
    let localName: String?
    let partnerName: String?
    let state: State
    var id: String { slot }
    var occupied: Bool { localName != nil || partnerName != nil || state == .lost }
    static func rows(ledger: BoundSoulLedger, areas: Set<Int>) -> [Self] {
        let local = Dictionary(uniqueKeysWithValues: ledger.records.filter(\.eligible).map { ($0.slot, $0.name) })
        let slots = Set(areas.map { "area:\($0)" }).union(ledger.acquired).union(ledger.partnerSlots).union(ledger.dead)
        return slots.sorted().map { slot in
            let mine = local[slot] ?? (ledger.acquired.contains(slot) ? "Pokémon" : nil), theirs = ledger.partnerSlots.contains(slot) ? (ledger.partnerNames?[slot] ?? "Pokémon") : nil
            let state: State = ledger.dead.contains(slot) ? .lost : ledger.partnerAcquisitions == nil ? .syncing : mine != nil && theirs != nil ? .linked : mine != nil ? .localOnly : theirs != nil ? .partnerOnly : .available
            return .init(slot: slot, localName: mine, partnerName: theirs, state: state)
        }
    }
}

/// The frame owner commits catch/death changes before allowing another frame.
/// Only main updates peer tombstones; neither networking callbacks nor SwiftUI accesses live RAM.
final class BoundSoulProbe: @unchecked Sendable {
    struct Snapshot: Sendable {
        var ready=false
        var mons:[BoundSoulMon]=[]
        var team:BoundSoulTeam?
        var teamCapturedAt:TimeInterval?
        var ledger:BoundSoulLedger?
        var error:String?
        var activeDenied=false
        var partyWipedOut=false
    }
    private struct Observation: Equatable, Sendable {
        let generation:UUID,frame:Int
        let date=Date(),uptime=ProcessInfo.processInfo.systemUptime
        let ready:Bool,battle:Bool,overflow:Bool,cooperative:Bool
        let party:Data,boxes:Data,faints:Data,battleFaints:Data,nativeRing:Data
        let outcome:Int,flags:UInt32
        func sameContents(as other:Self)->Bool {
            generation==other.generation && ready==other.ready && battle==other.battle && overflow==other.overflow
                && cooperative==other.cooperative && party==other.party && boxes==other.boxes && faints==other.faints
                && battleFaints==other.battleFaints && nativeRing==other.nativeRing && outcome==other.outcome && flags==other.flags
        }
    }
    private struct FileAction: Sendable {
        let id=UUID(),source:URL?,destination:URL,data:Data?
    }
    private struct Candidate: Sendable {
        let generation:UUID,url:URL?,gameID:String,ledger:BoundSoulLedger?,timeline:Data
        let snapshot:Snapshot,ring:Data?,policy:Data,actions:[FileAction],writeLedger:Bool,writeTimeline:Bool,observation:Observation?
    }
    private struct Owner {
        var generation=UUID(),coreID:ObjectIdentifier?
        var gameURL:URL?
        var preview=false,verified=false,nativeAllowed=true,installed=false,blocked=false,criticalGate=false
        var friendly:ObjectIdentifier?,cooperative:ObjectIdentifier?
        var frame=0,nativeGeneration:UInt=0
        var lastPolicy=Data(),lastInput:Observation?
        var replacementVerification:Bool?
        var callbacks:UInt64=0,blockedCallbacks:UInt64=0,criticalCallbacks:UInt64=0
    }
    let timeline=BoundRunTimeline()
    private let lock=NSLock()
    private var owner=Owner(),published=Snapshot(),receipt:Candidate?
    private weak var core:EmulatorCore?
    // Everything below belongs to the compute queue. Only immutable candidates
    // cross to persistence; frame callbacks never take this model's lock.
    private var generation=UUID(),url:URL?,gameID=""
    private var ledger:BoundSoulLedger? { didSet { deniedPolicy=nil } }
    private var deniedPolicy:Data?,snapshot=Snapshot(),reachedField=false
    private var lastBoxes=Data(),cachedBoxes:[BoundSoulMon]=[],ring:Data?
    private var actions:[FileAction]=[],needsCandidate=false
    private var stagedTimeline=Data(),durableTimeline=Data(),durableLedger:BoundSoulLedger?
    private var observation:Observation?
#if DEBUG
    private var persistenceInterceptor:(() throws->Void)?
    func qaSetPersistenceInterceptor(_ value:(() throws->Void)?) { lock.lock();persistenceInterceptor=value;lock.unlock() }
#endif
    private lazy var pipeline=BoundSDKObservationPipeline<Observation,Candidate>(
        reduce:{ [weak self] in try self?.reduce($0) },candidate:{ [weak self] in try self?.candidate() },
        write:{ [weak self] value in
            if let self { try self.writeCandidate(value) } else { try Self.write(value) }
        },committed:{ [weak self] in self?.committed($0) },
        failed:{ [weak self] _ in self?.requestPause("Soul Link couldn’t save its rules. Retry while the game is paused.") },
        backpressure:{ [weak self] in self?.requestPause("Soul Link is catching up. Retry while the game is paused.") })

    init() {
        timeline.stageWrites(execute:{ [weak self] body in
            guard let self else { return }
            self.pipeline.perform(body)
            do { try self.pipeline.flush() }
            catch { self.requestPause("Run history couldn’t be saved. Retry while the game is paused.") }
        },
                             isExecuting:{ [weak self] in self?.pipeline.isComputing == true })
    }
    private func policyBytes(for value:BoundSoulLedger)->Data {
        if let deniedPolicy { return deniedPolicy }
        let bytes=value.denied.sorted().reduce(into:Data()) { $0.append($1.bytes) }
        deniedPolicy=bytes;return bytes
    }
    private func candidate() throws->Candidate? {
        if let ledger { timeline.observeSoul(ledger) }
        let bytes=try timeline.pendingBytes()
        // External timeline reductions share the compute queue too.
        guard needsCandidate || stagedTimeline != bytes else { return nil }
        needsCandidate=false;stagedTimeline=bytes
        return .init(generation:generation,url:url,gameID:gameID,ledger:ledger,timeline:bytes,
                     snapshot:snapshot,ring:ring,policy:ledger.map { policyBytes(for:$0) } ?? Data(),actions:actions,
                     writeLedger:ledger != durableLedger,writeTimeline:bytes != durableTimeline,observation:observation)
    }
    private static func write(_ value:Candidate) throws {
        for action in value.actions {
            try BoundServerMemoryFiles.directory(action.destination.deletingLastPathComponent(),gameID:value.gameID)
            if let source=action.source {
                if BoundServerMemoryFiles.exists(source,gameID:value.gameID) {
                    try BoundServerMemoryFiles.move(source,to:action.destination,gameID:value.gameID)
                } else if !BoundServerMemoryFiles.exists(action.destination,gameID:value.gameID) { throw BoundSoulLedger.Error.corrupt }
            } else if let data=action.data,!BoundServerMemoryFiles.exists(action.destination,gameID:value.gameID) {
                try BoundServerMemoryFiles.write(data,to:action.destination,gameID:value.gameID)
            }
        }
        guard let url=value.url,value.writeLedger || value.writeTimeline else { return }
        try BoundServerMemoryFiles.directory(url.deletingLastPathComponent(),gameID:value.gameID)
        if value.writeTimeline {
            try BoundServerMemoryFiles.write(value.timeline,to:url.deletingPathExtension().appendingPathExtension("timeline.json"),gameID:value.gameID)
        }
        if value.writeLedger,let ledger=value.ledger {
            guard ledger.valid else { throw BoundSoulLedger.Error.corrupt }
            try BoundServerMemoryFiles.write(JSONEncoder().encode(ledger),to:url,gameID:value.gameID)
        }
    }
    private func writeCandidate(_ value:Candidate) throws {
#if DEBUG
        lock.lock();let interceptor=persistenceInterceptor;lock.unlock()
        if value.writeLedger || value.writeTimeline || !value.actions.isEmpty { try interceptor?() }
#endif
        try Self.write(value)
    }
    private func committed(_ value:Candidate) {
        guard value.generation==generation else { return }
        let changedTimeline=durableTimeline != value.timeline
        durableLedger=value.ledger;durableTimeline=value.timeline
        if changedTimeline { timeline.confirm(value.timeline) }
        let completed=Set(value.actions.map(\.id));actions.removeAll { completed.contains($0.id) }
        lock.lock();defer { lock.unlock() }
        guard owner.generation==value.generation else { return }
        let error=owner.blocked ? published.error:value.snapshot.error
        receipt=value;published=value.snapshot;published.ledger=value.ledger;published.error=error
    }
    private func requestPause(_ message:String) {
        lock.lock();owner.blocked=true;published.error=message
        let token=owner.generation,epoch=owner.nativeGeneration,core=self.core;lock.unlock()
        _=BoundVBABattleBridge.setSoulFrameBlocked(true,owner:token.uuidString,generation:epoch)
        Task { @MainActor [weak self,weak core] in
            guard let self,let core else { return }
            self.lock.lock();let current=self.owner.generation==token && self.owner.coreID==ObjectIdentifier(core) && self.owner.blocked;self.lock.unlock()
            if current,core.state == .running { _=core.pause() }
        }
    }
    private func durableMutation(_ body:() throws->Void) throws {
        try pipeline.perform(body)
        do { try pipeline.flush() }
        catch { requestPause("Soul Link couldn’t save its rules. Retry while the game is paused.");throw error }
    }
    @discardableResult func configure(core:EmulatorCore?,url:URL?,gameID:String="")->Bool {
        // Game may be a main-queue Core Data object. Resolve its immutable
        // cartridge location at the owner boundary, never under the probe lock
        // or from a completed-frame callback that the main queue can await.
        let gameURL=core?.game.fileURL
        do { try pipeline.flush() }
        catch { requestPause("Soul Link still has unsaved rules. Retry before changing games.");return false }
        let next=UUID()
        lock.lock()
        if owner.blocked,let previous=self.core,previous.state != .paused && previous.state != .stopped {
            lock.unlock();requestPause("Pause the current game before changing Soul Link ownership.");return false
        }
        _=BoundVBABattleBridge.setSoulFrameBlocked(false,owner:owner.generation.uuidString,generation:owner.nativeGeneration)
        let oldID=owner.coreID,friendly=owner.friendly,cooperative=owner.cooperative
        owner=Owner();owner.generation=next;owner.coreID=core.map(ObjectIdentifier.init);owner.gameURL=gameURL
        if oldID==owner.coreID { owner.friendly=friendly;owner.cooperative=cooperative }
        self.core=core;published=Snapshot();receipt=nil;lock.unlock()
        pipeline.perform {
            generation=next;self.url=url;self.gameID=gameID;ledger=nil;snapshot=Snapshot();reachedField=false
            lastBoxes=Data();cachedBoxes=[];ring=nil;observation=nil;actions=[];needsCandidate=false
            timeline.configure(url:url.map { $0.deletingPathExtension().appendingPathExtension("timeline.json") },gameID:gameID)
            if let url,BoundServerMemoryFiles.exists(url,gameID:gameID) {
                do {
                    let data=try BoundServerMemoryFiles.read(url,gameID:gameID)
                    guard data.count<=2_097_152 else { throw BoundSoulLedger.Error.corrupt }
                    var value=try JSONDecoder().decode(BoundSoulLedger.self,from:data)
                    guard value.valid else { throw BoundSoulLedger.Error.corrupt }
                    value.recordDeaths(previous:value.dead);ledger=value;snapshot.ledger=value
                } catch { snapshot.error="Soul Link record couldn’t be read. Your run is paused." }
            }
            durableLedger=ledger;durableTimeline=(try? timeline.pendingBytes()) ?? Data();stagedTimeline=durableTimeline
            lock.lock();published=snapshot;lock.unlock()
        }
        return true
    }
    func reloadContinuationMemory(for core:EmulatorCore) throws {
        lock.lock();let valid=owner.coreID==ObjectIdentifier(core),verified=owner.verified;lock.unlock()
        guard valid,core.state == .paused else { throw BoundSoulLedger.Error.corrupt }
        try pipeline.flush()
        let context=pipeline.inspect { (url,gameID) }
        guard configure(core:core,url:context.0,gameID:context.1) else { throw BoundSoulLedger.Error.corrupt };setVerified(verified)
        if read().error != nil { throw BoundSoulLedger.Error.corrupt }
    }
    func setPreviewEnabled(_ value:Bool) { lock.lock();owner.preview=value;lock.unlock() }
    func setVerified(_ value:Bool) { lock.lock();owner.verified=value;lock.unlock() }
    func setNativeObservationAllowed(_ value:Bool) { lock.lock();owner.nativeAllowed=value;lock.unlock() }
    private func claimNativeFrameOwnerUnlocked()->UInt {
        guard let gameURL=owner.gameURL else { return 0 }
        return BoundVBABattleBridge.claimSoulFrameOwner(owner.generation.uuidString,gameURL:gameURL)
    }
    func setFriendlyBattleActive(_ active:Bool,for core:EmulatorCore) {
        lock.lock();defer { lock.unlock() };let id=ObjectIdentifier(core)
        if active { owner.friendly=id } else if owner.friendly==id { owner.friendly=nil }
    }
    func setCooperativeBattleActive(_ active:Bool,for core:EmulatorCore) {
        lock.lock();defer { lock.unlock() };let id=ObjectIdentifier(core)
        if active { owner.cooperative=id } else if owner.cooperative==id { owner.cooperative=nil }
    }
    @discardableResult func observeCooperativeParty(_ party:Data,fainted:Set<BoundSoulIdentity>,for core:EmulatorCore)->Bool {
        captureCooperative(party,fainted:fainted,core:core,force:false).durable
    }
    private func captureCooperative(_ party:Data,fainted:Set<BoundSoulIdentity>,core:EmulatorCore,force:Bool)->(accepted:Bool,durable:Bool) {
        lock.lock();defer { lock.unlock() }
        guard owner.cooperative==ObjectIdentifier(core),party.count==600,force || !owner.blocked else { return (false,false) }
        if published.ledger?.ended != false { return (true,true) }
        if owner.nativeGeneration==0 {
            owner.nativeGeneration=claimNativeFrameOwnerUnlocked()
            guard owner.nativeGeneration != 0 else {
                lock.unlock();requestPause("Soul Link frame ownership is unavailable. Keep the game paused.");lock.lock();return (false,false)
            }
        }
        owner.frame+=1
        let native=BoundVBABattleBridge.soulLinkSnapshot()
        let input=Observation(generation:owner.generation,frame:owner.frame,ready:false,battle:true,overflow:native["overflow"] as? Bool==true,
            cooperative:true,party:party,boxes:Data(),faints:fainted.sorted().reduce(into:Data()) { $0.append($1.bytes) },
            battleFaints:Data(),nativeRing:native["faints"] as? Data ?? Data(),outcome:0,flags:0)
        let saved=receipt?.observation
        let durable=saved?.generation==input.generation && saved?.cooperative==true && saved?.party==party && saved?.faints==input.faints
        if durable,!owner.blocked,let ring=receipt?.ring { _=BoundVBABattleBridge.acknowledgeSoulLinkFaints(matching:ring) }
        if owner.criticalGate,durable,saved?.sameContents(as:input)==true {
            owner.criticalGate=false
            _=BoundVBABattleBridge.setSoulFrameBlocked(false,owner:owner.generation.uuidString,generation:owner.nativeGeneration)
        }
        if force { owner.lastInput=nil }
        return (submitUnlocked(input),durable)
    }
    private func archive(_ value:BoundSoulLedger,folder:String) throws {
        guard let url else { return }
        actions.append(.init(source:nil,destination:url.deletingLastPathComponent().appendingPathComponent(folder)
            .appendingPathComponent(value.run.uuidString+".json"),data:try JSONEncoder().encode(value)))
    }
    func start(run:UUID,binding:String,offering:Bool=false) throws {
        try durableMutation {
            guard snapshot.ready,(ledger==nil || ledger?.ended==true),snapshot.mons.count==1,let starter=snapshot.mons.first,
                  !starter.eggOrigin,(starter.hp ?? 0)>0 else { throw BoundSoulLedger.Error.corrupt }
            var value=BoundSoulLedger(run:run,binding:binding);value.offering=offering
            try value.observe(snapshot.mons,registering:true,fainted:[])
            if let old=ledger,old.ended { try archive(old,folder:"Finished Runs") }
            try persist(value)
        }
    }
    func startPreparedRun(run:UUID,binding:String) throws {
        try durableMutation {
            if let ledger,ledger.run==run,ledger.binding==binding,!ledger.ended { return }
            guard ledger==nil || ledger?.ended==true else { throw BoundSoulLedger.Error.corrupt }
            if let old=ledger { try archive(old,folder:"Finished Runs") }
            try persist(.init(run:run,binding:binding))
        }
    }
    func endRun() throws { try durableMutation {
        guard var value=ledger else { return };value.ended=true;value.offering=false;try persist(value)
    } }
    func markAccepted() throws { try durableMutation {
        guard var value=ledger,value.offering else { return };value.offering=false;try persist(value)
    } }
    func cancelOffer() throws { try durableMutation {
        guard let value=ledger,value.offering,let url else { return }
        actions.append(.init(source:url,destination:url.deletingLastPathComponent().appendingPathComponent("Cancelled Invitations")
            .appendingPathComponent(value.run.uuidString+".json"),data:nil))
        ledger=nil;snapshot.ledger=nil;needsCandidate=true
    } }
    private func persist(_ value:BoundSoulLedger) throws {
        guard url != nil,value.valid,snapshot.error==nil else { throw BoundSoulLedger.Error.corrupt }
        ledger=value;snapshot.ledger=value;needsCandidate=true
    }
    func merge(run:UUID,rows:[BoundSoulRow],losses:Data,acquired:Data?=nil) throws { try durableMutation {
        guard var value=ledger,value.run==run else { return }
        guard losses.count==288,rows.allSatisfy(\.valid),acquired==nil || acquired?.count==288 else { throw BoundSoulLedger.Error.corrupt }
        let previous=value
        if let acquired {
            value.partnerAcquisitions=value.partnerSlots.union(BoundSoulLedger.losses(acquired))
            var names=value.partnerNames ?? [:]
            for row in rows where value.partnerSlots.contains(row.slot) && !row.name.isEmpty { names[row.slot]=row.name }
            value.partnerNames=names
        }
        value.dead.formUnion(BoundSoulLedger.losses(losses));value.dead.formUnion(rows.filter(\.dead).map(\.slot))
        value.recordDeaths(previous:previous.dead)
        if value != previous { try persist(value) }
    } }
    func sharedEvents()->[BoundSoulSharedEvent] { read().ledger?.sharedEvents ?? [] }
    func receiveSharedEvent(_ payload:Data,localOrigin:Bool=false) throws { try durableMutation {
        guard payload.count<=1024,let event=try? JSONDecoder().decode(BoundSoulSharedEvent.self,from:payload),event.valid,
              var value=ledger,value.run==event.run else { throw BoundSoulLedger.Error.corrupt }
        let previous=value
        switch event.kind {
        case .acquired:
            if let slot=event.slot {
                if localOrigin {
                    value.consumedSlots=(value.consumedSlots ?? []).union([slot])
                    if slot.hasPrefix("egg:"),let ordinal=Int(slot.dropFirst(4)) { value.nextEgg=max(value.nextEgg,ordinal+1) }
                } else { value.partnerAcquisitions=value.partnerSlots.union([slot]) }
            }
        case .death:if let slot=event.slot { value.dead.insert(slot) }
        case .ended:value.ended=true;value.offering=false
        }
        value.recordDeaths(previous:previous.dead)
        if value != previous { try persist(value) }
    } }
    static func mayApplyNativePolicy(ready:Bool,battle:Bool)->Bool { ready && !battle }
    func acknowledgeDeath(run:UUID,slot:String) throws { try durableMutation {
        guard var value=ledger,value.run==run,let index=value.memorials?.firstIndex(where:{$0.slot==slot}),
              value.memorials?[index].announced==false else { return }
        value.memorials?[index].announced=true;try persist(value)
    } }
    func read()->Snapshot { lock.lock();defer { lock.unlock() };return published }
    func observationMetrics()->[String:UInt64] {
        var result=pipeline.metrics()
        lock.lock();result["callbacks"]=owner.callbacks;result["blockedCallbacks"]=owner.blockedCallbacks
        result["criticalCallbacks"]=owner.criticalCallbacks;lock.unlock();return result
    }

    @discardableResult private func submitUnlocked(_ input:Observation)->Bool {
        if let previous=owner.lastInput,input.sameContents(as:previous),input.frame%15 != 0 { return true }
        let prior=owner.lastInput
        let critical=published.ledger?.ended==false && (
            (input.ready && (prior?.party != input.party || prior?.boxes != input.boxes))
            || (!input.faints.isEmpty && prior?.faints != input.faints)
            || (!input.battleFaints.isEmpty && prior?.battleFaints != input.battleFaints))
        if critical {
            owner.criticalGate=true
            _=BoundVBABattleBridge.setSoulFrameBlocked(true,owner:owner.generation.uuidString,generation:owner.nativeGeneration)
        }
        // submit may synchronously close admission, so never hold publication
        // lock across it. There is one native producer; checkpoints pause it.
        owner.lastInput=input;lock.unlock();let accepted=pipeline.submit(input);lock.lock()
        if !accepted { owner.lastInput=nil }
        return accepted
    }
    func receive(_ core:EmulatorCore) { _=receive(core,force:false) }
    private func receive(_ core:EmulatorCore,force:Bool)->Bool {
        lock.lock();defer { lock.unlock() }
        guard owner.coreID==ObjectIdentifier(core),owner.verified,owner.nativeAllowed,
              core.deltaCore.identifier=="com.rileytestut.GBADeltaCore" else { return true }
        owner.callbacks &+= 1
        if owner.criticalGate,!owner.blocked,let receipt,receipt.generation==owner.generation,
           receipt.ledger?.ended != false {
            // Ending a run is a durable candidate too. Its receipt retires the
            // critical-fact fence before the inactive fast path closes hooks.
            owner.criticalGate=false
            _=BoundVBABattleBridge.setSoulFrameBlocked(false,owner:owner.generation.uuidString,generation:owner.nativeGeneration)
        }
        if owner.installed,published.ledger?.ended != false {
            BoundVBABattleBridge.closeSoulLink();owner.installed=false;owner.lastPolicy=Data()
        }
        guard owner.friendly != ObjectIdentifier(core),owner.cooperative != ObjectIdentifier(core) else { return true }
        if owner.blocked && !force { owner.blockedCallbacks &+= 1;return true }
        if owner.criticalGate { owner.criticalCallbacks &+= 1 }
        let active=published.ledger?.ended==false
        guard owner.preview || owner.installed || active else { return true }
        owner.frame+=1
        if !force,!active,owner.frame%30 != 1 { return true }
        if owner.nativeGeneration==0 {
            owner.nativeGeneration=claimNativeFrameOwnerUnlocked()
            guard owner.nativeGeneration != 0 else {
                lock.unlock();requestPause("Soul Link frame ownership is unavailable. Keep the game paused.");lock.lock();return false
            }
        }
        if active,!owner.installed {
            owner.installed=BoundVBABattleBridge.installSoulLink()
            guard owner.installed else {
                lock.unlock();requestPause("Soul Link requires the supported Radical Red game. Keep the game paused.");lock.lock();return false
            }
        }
        applyReceiptUnlocked()
        let native=BoundVBABattleBridge.soulLinkSnapshot()
        let input=Observation(generation:owner.generation,frame:owner.frame,ready:native["ready"] as? Bool==true,
            battle:native["battle"] as? Bool==true,overflow:native["overflow"] as? Bool==true,cooperative:false,
            party:native["party"] as? Data ?? Data(),boxes:native["boxes"] as? Data ?? Data(),
            faints:native["faints"] as? Data ?? Data(),battleFaints:native["battleFaints"] as? Data ?? Data(),
            nativeRing:native["faints"] as? Data ?? Data(),
            outcome:native["outcome"] as? Int ?? 0,flags:native["battleFlags"] as? UInt32 ?? 0)
        if force { owner.lastInput=nil }
        return submitUnlocked(input)
    }
    private func reduce(_ input:Observation) throws {
        guard input.generation==generation else { return }
        observation=input
        guard !input.overflow else { throw BoundSoulLedger.Error.capacity }
        let party=BoundSoulMon.decode(input.party,stride:100)
        var fainted:Set<BoundSoulIdentity>=[]
        for data in [input.faints,input.battleFaints] {
            guard data.count%8==0 else { throw BoundSoulLedger.Error.corrupt }
            for offset in stride(from:0,to:data.count,by:8) { if let id=BoundSoulIdentity.read(data,at:offset) { fainted.insert(id) } }
        }
        if input.cooperative {
            guard var value=ledger,!value.ended else { return }
            try value.observe(party,registering:false,fainted:fainted,at:input.date)
            if value != ledger { try persist(value) }
            snapshot.partyWipedOut=snapshot.partyWipedOut || BoundSoulWipeout.occurred(party:party,ledger:value)
            ring=input.nativeRing;needsCandidate=true;return
        }
        reachedField=reachedField || input.ready
        let boxesChanged=input.ready && input.boxes != lastBoxes
        if boxesChanged { lastBoxes=input.boxes;cachedBoxes=BoundSoulMon.decode(input.boxes,stride:58) }
        let mons=party+cachedBoxes
        timeline.observe(mons:mons,ready:input.ready,battle:input.battle,outcome:input.outcome,flags:input.flags,at:input.date)
        snapshot.ready=input.ready;if input.ready { snapshot.mons=mons }
        if reachedField,var value=ledger,!value.ended {
            let previous=value
            try value.observe(input.ready && boxesChanged ? mons:party,registering:input.ready,fainted:fainted,at:input.date)
            if value != previous { try persist(value) }
            snapshot.partyWipedOut=snapshot.partyWipedOut || BoundSoulWipeout.occurred(party:party,ledger:value)
            if input.ready && (snapshot.team==nil || input.frame%15==0 || boxesChanged || value != previous) {
                snapshot.team=BoundSoulTeam.capture(mons:snapshot.mons,ledger:value)
                snapshot.teamCapturedAt=input.uptime
            }
            ring=input.faints
        }
        needsCandidate=true
    }
    private func applyReceiptUnlocked() {
        guard let value=receipt,value.generation==owner.generation,!owner.blocked else { return }
        guard owner.installed,value.ledger?.ended==false else { return }
        if owner.criticalGate {
            guard let latest=owner.lastInput,value.observation?.sameContents(as:latest)==true else { return }
        }
        let current=BoundVBABattleBridge.soulLinkSnapshot()
        if let ring=value.ring { _=BoundVBABattleBridge.acknowledgeSoulLinkFaints(matching:ring) }
        if Self.mayApplyNativePolicy(ready:current["ready"] as? Bool==true,battle:current["battle"] as? Bool==true) {
            if value.policy != owner.lastPolicy {
                guard BoundVBABattleBridge.setSoulLinkDenied(value.policy) else {
                    lock.unlock();requestPause("Soul Link native rules couldn’t be applied. Keep the game paused.");lock.lock();return
                }
                owner.lastPolicy=value.policy
            }
            BoundVBABattleBridge.enforceSoulLink()
        }
        if owner.criticalGate {
            owner.criticalGate=false
            _=BoundVBABattleBridge.setSoulFrameBlocked(false,owner:owner.generation.uuidString,generation:owner.nativeGeneration)
        }
    }
    func prepareCheckpoint(core:EmulatorCore,timeout:TimeInterval=5) throws {
        guard core.state == .paused else { throw BoundSoulLedger.Error.corrupt }
        lock.lock();let id=owner.coreID,inactive=published.ledger==nil && !owner.installed,token=owner.generation
        let verify=published.ledger?.ended==false && !owner.verified,allowed=owner.nativeAllowed,gameURL=owner.gameURL;lock.unlock()
        if id==nil && inactive { return }
        guard id==ObjectIdentifier(core) else { throw BoundSoulLedger.Error.corrupt }
        if verify {
            // The paused capture boundary admits the exact owned file rather
            // than waiting for an unrelated asynchronous verifier callback.
            guard allowed,let gameURL,core.deltaCore.identifier=="com.rileytestut.GBADeltaCore",
                  (try? BoundPlayerROMProfile(rom:Data(contentsOf:gameURL,options:.mappedIfSafe))) != nil else { throw BoundSoulLedger.Error.corrupt }
            lock.lock();guard owner.generation==token else { lock.unlock();throw BoundSoulLedger.Error.corrupt }
            owner.verified=true;lock.unlock()
        }
        guard allowed || inactive else { throw BoundSoulLedger.Error.corrupt }
        let start=ProcessInfo.processInfo.systemUptime
        do {
            try pipeline.flush(timeout:timeout)
            lock.lock();let cooperative=owner.cooperative==ObjectIdentifier(core);lock.unlock()
            if cooperative {
                guard let value=BoundCooperativeSnapshot(BoundVBABattleBridge.cooperativeSnapshot()) else { throw BoundSoulLedger.Error.corrupt }
                var fainted:Set<BoundSoulIdentity>=[]
                for index in 0..<6 where value.faintedMask & (1 << index) != 0 {
                    if let identity=BoundSoulIdentity.read(value.party,at:index*100) { fainted.insert(identity) }
                }
                guard captureCooperative(value.owned,fainted:fainted,core:core,force:true).accepted else { throw BoundSoulLedger.Error.corrupt }
            } else {
                guard receive(core,force:true) else { throw BoundSDKObservationPipeline<Observation,Candidate>.Failure.rejected }
            }
            try pipeline.flush(timeout:max(0,timeout-(ProcessInfo.processInfo.systemUptime-start)))
            guard pipeline.inspect({ snapshot.error })==nil else { throw BoundSoulLedger.Error.corrupt }
        }
        catch { requestPause("Soul Link couldn’t finish saving its rules. Retry while paused.");throw error }
        lock.lock();defer { lock.unlock() }
        guard owner.generation==token,owner.coreID==ObjectIdentifier(core),core.state == .paused else { throw BoundSoulLedger.Error.corrupt }
        owner.blocked=false;published.error=nil
        if owner.friendly != ObjectIdentifier(core),owner.cooperative != ObjectIdentifier(core) { applyReceiptUnlocked() }
        guard !owner.blocked else { throw BoundSoulLedger.Error.corrupt }
        owner.criticalGate=false
        _=BoundVBABattleBridge.setSoulFrameBlocked(false,owner:token.uuidString,generation:owner.nativeGeneration)
    }
    func drainBeforeMemoryReplacement(core:EmulatorCore?,timeout:TimeInterval=5) throws {
        guard core==nil || core?.state == .paused || core?.state == .stopped else { throw BoundSoulLedger.Error.corrupt }
        lock.lock();let identity=owner.coreID;lock.unlock()
        if let identity { guard core.map(ObjectIdentifier.init)==identity else { throw BoundSoulLedger.Error.corrupt } }
        do {
            try pipeline.flush(timeout:timeout)
            guard pipeline.inspect({ snapshot.error })==nil else { throw BoundSoulLedger.Error.corrupt }
        }
        catch { requestPause("Soul Link still has unsaved rules. Retry before replacing this run.");throw error }
    }
    func retryPendingPersistence(core:EmulatorCore,timeout:TimeInterval=5) throws { try prepareCheckpoint(core:core,timeout:timeout) }
    func prepareForNativeMemoryReplacement(core:EmulatorCore) throws {
        try drainBeforeMemoryReplacement(core:core)
        lock.lock();defer { lock.unlock() }
        guard owner.coreID==ObjectIdentifier(core) else { return }
        // start() can deliver callbacks before pause() completes. Retain the
        // worker's permanent facts while suppressing observations of that boot.
        _=BoundVBABattleBridge.setSoulFrameBlocked(false,owner:owner.generation.uuidString,generation:owner.nativeGeneration)
        owner.criticalGate=false
        if owner.replacementVerification==nil { owner.replacementVerification=owner.verified }
        owner.verified=false;owner.installed=false;owner.nativeGeneration=0
        owner.lastInput=nil;owner.lastPolicy=Data();receipt=nil
    }
    func refreshAfterNativeMemoryReplacement(core:EmulatorCore) throws {
        guard core.state == .paused else { throw BoundSoulLedger.Error.corrupt }
        try drainBeforeMemoryReplacement(core:core)
        lock.lock();let matches=owner.coreID==ObjectIdentifier(core),active=published.ledger?.ended==false
        let allowed=owner.nativeAllowed,token=owner.generation,gameURL=owner.gameURL;lock.unlock()
        guard matches else { return }
        if active {
            guard allowed,let gameURL,core.deltaCore.identifier=="com.rileytestut.GBADeltaCore",
                  (try? BoundPlayerROMProfile(rom:Data(contentsOf:gameURL,options:.mappedIfSafe))) != nil else {
                requestPause("Soul Link couldn’t restore its native rules. Keep the game paused.");throw BoundSoulLedger.Error.corrupt
            }
        }
        lock.lock();defer { lock.unlock() }
        guard owner.generation==token else { throw BoundSoulLedger.Error.corrupt }
        owner.installed=false;owner.lastPolicy=Data();owner.lastInput=nil;receipt=nil
        owner.nativeGeneration=0;owner.verified=active || owner.replacementVerification==true
        owner.replacementVerification=nil
        if active {
            owner.nativeGeneration=claimNativeFrameOwnerUnlocked()
            guard owner.nativeGeneration != 0 else {
                lock.unlock();requestPause("Soul Link frame ownership is unavailable. Keep the game paused.");lock.lock();throw BoundSoulLedger.Error.corrupt
            }
            if owner.friendly != ObjectIdentifier(core),owner.cooperative != ObjectIdentifier(core),let value=published.ledger {
                let policy=value.denied.sorted().reduce(into:Data()) { $0.append($1.bytes) }
                guard BoundVBABattleBridge.installSoulLink(),BoundVBABattleBridge.setSoulLinkDenied(policy) else {
                    lock.unlock();requestPause("Soul Link couldn’t restore its native rules. Keep the game paused.");lock.lock();throw BoundSoulLedger.Error.corrupt
                }
                owner.installed=true;owner.lastPolicy=policy;BoundVBABattleBridge.enforceSoulLink()
            }
        } else { BoundVBABattleBridge.closeSoulLink() }
        owner.blocked=false;owner.criticalGate=false;published.error=nil
        _=BoundVBABattleBridge.setSoulFrameBlocked(false,owner:token.uuidString,generation:owner.nativeGeneration)
    }
    func prepareRestoredState(_ core:EmulatorCore) throws {
        guard core.state == .paused else { throw BoundSoulLedger.Error.corrupt }
        try pipeline.flush()
        lock.lock();defer { lock.unlock() }
        guard owner.coreID==ObjectIdentifier(core),core.deltaCore.identifier=="com.rileytestut.GBADeltaCore",
              owner.friendly != ObjectIdentifier(core),owner.cooperative != ObjectIdentifier(core),
              let value=published.ledger,value.valid,published.error==nil else { throw BoundSoulLedger.Error.corrupt }
        if value.ended {
            BoundVBABattleBridge.closeSoulLink();owner.installed=false;owner.lastPolicy=Data();owner.criticalGate=false
            _=BoundVBABattleBridge.setSoulFrameBlocked(false,owner:owner.generation.uuidString,generation:owner.nativeGeneration)
            return
        }
        guard BoundVBABattleBridge.installSoulLink() else { throw BoundSoulLedger.Error.corrupt }
        let policy=value.denied.sorted().reduce(into:Data()) { $0.append($1.bytes) }
        guard BoundVBABattleBridge.setSoulLinkDenied(policy) else { throw BoundSoulLedger.Error.corrupt }
        owner.installed=true;owner.lastPolicy=policy;owner.verified=true
        owner.nativeGeneration=claimNativeFrameOwnerUnlocked()
        guard owner.nativeGeneration != 0 else { throw BoundSoulLedger.Error.corrupt }
        BoundVBABattleBridge.enforceSoulLink()
    }
}


@MainActor
final class BoundSoulSession: ObservableObject {
    let probe: BoundSoulProbe
    func reloadContinuationMemory(for core: EmulatorCore) throws {
        try probe.reloadContinuationMemory(for: core)
        ledger = probe.read().ledger; localTeam = nil; localTeamCurrent = false
    }
    @Published private(set) var status = "Receive your starter, then connect to your partner."
    @Published private(set) var ledger: BoundSoulLedger?
    @Published private(set) var localTeam: BoundSoulTeam?
    @Published private(set) var partnerTeam: BoundSoulTeam?
    @Published private(set) var localTeamCurrent = false
    @Published private(set) var partnerTeamCurrent = false
    private var lastTeamSent: TimeInterval = -.infinity
    private var teamSequence: UInt64 = 0
    private var peerTeamSequence: UInt64 = 0
    private var peerTeamAt: TimeInterval?
    @Published private(set) var deathMoment: BoundSoulDeath?
    private var deathMomentStarted: TimeInterval?
    var canPresentDeathMoment: (() -> Bool)?
    var graveyard: [BoundSoulDeath] {
        (ledger?.memorials ?? []).sorted {
            if $0.recordedAt != $1.recordedAt { return ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
            return $0.slot < $1.slot
        }
    }
    @Published private(set) var incoming: UUID?
    @Published private(set) var offered: UUID?
    var encounters: [BoundSoulEncounter] {
        guard let ledger else { return [] }
        return BoundSoulEncounter.rows(ledger: ledger, areas: Set(areaNames.keys))
            .sorted { BoundSoulControls.title($0.slot, names: areaNames).localizedStandardCompare(BoundSoulControls.title($1.slot, names: areaNames)) == .orderedAscending }
    }
    @Published private(set) var canStart = false
    @Published private(set) var areaNames: [Int: String] = [:]
    private let clock: () -> TimeInterval
    private let teamSnapshot: () -> BoundSoulProbe.Snapshot
    private weak var core: EmulatorCore?
    private var gameID = ""
    private var supported = false
    private var binding: String?
    private var connection: String?
    private var incompatiblePeer = false
    private var confirmed = false
    private var epoch = UUID()
    private var peerEpoch: UUID?
    private var proposedEpoch: UUID?
    private var proposalAt: TimeInterval = 0
    private var retiredEpochs: [UUID] = []
    private var retiredInvitations: [UUID] = []
    private var lastPeer: TimeInterval = 0
    private var sent: TimeInterval = 0
    private var cursor = 0
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    var bannerChanged: ((String?) -> Void)?
    var send: ((Data) -> Bool)?
    var connected: (() -> Bool)?
    var nativeActivity: (() -> Bool)?
    /// ROM-driven runs surface local integrity errors in their native UI.
    var cartridgeManagesPause = false
    private(set) var recoveryError: String?
    func retryRecovery() {
        if probe.read().error==nil { recoveryError=nil;return }
        guard let core,core.state == .paused else { return }
        do {
            try probe.retryPendingPersistence(core:core)
            ledger=probe.read().ledger;recoveryError=nil;status="Rules saved. Resume when ready."
        } catch { recoveryError=probe.read().error ?? "Soul Link couldn’t save its rules. Keep the game paused.";status=recoveryError! }
    }
    private func haltForRecovery() {
        recoveryError = status
        if !cartridgeManagesPause { _ = core?.pause() }
    }
    var active: Bool { ledger != nil && ledger?.ended == false }
    var paired: Bool { confirmed && clock() - lastPeer < 3 }
    func permitsNativeActivity(_ activity: BoundFriendInteractionPacket.Activity) -> Bool {
        activity == .battle || !active
    }
    var permitsIndependentStateLoading: Bool { !active && probe.read().error == nil }
    static func hasProtectedRun(gameID: String) -> Bool {
        let url = directory.appendingPathComponent(hash(gameID) + ".json")
        guard BoundServerMemoryFiles.exists(url, gameID: gameID) else { return false }
        guard let bytes = try? BoundServerMemoryFiles.read(url, gameID: gameID), bytes.count <= 2_097_152,
              let ledger = try? JSONDecoder().decode(BoundSoulLedger.self, from: bytes), ledger.valid else { return true }
        return !ledger.ended
    }
    func startPreparedRun(run: UUID) throws {
        guard let binding else { throw BoundSoulLedger.Error.corrupt }
        try probe.startPreparedRun(run: run, binding: binding)
        ledger = probe.read().ledger
    }
    init(probe: BoundSoulProbe = BoundSoulProbe(), clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, areaNames: [Int: String] = [:], teamSnapshot: (() -> BoundSoulProbe.Snapshot)? = nil) {
        self.teamSnapshot = teamSnapshot ?? { probe.read() }
        self.areaNames = areaNames; self.clock = clock; self.probe = probe; self.ledger = probe.read().ledger
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    deinit {
        let timer = timer
        BoundMainActorDisposal.enqueue { timer?.invalidate() }
        loadTask?.cancel()
    }
    func bind(core: EmulatorCore?, gameID: String) {
        guard self.core !== core || self.gameID != gameID else { return }
        let url = core.map { _ in Self.directory.appendingPathComponent(Self.hash(gameID) + ".json") }
        guard probe.configure(core:core,url:url,gameID:gameID) else {
            recoveryError=probe.read().error;status=recoveryError ?? "Soul Link still has unsaved rules."
            return
        }
        deathMoment = nil; deathMomentStarted = nil; recoveryError = nil
        peerGone(); localTeam = nil; localTeamCurrent = false
        self.core = core; self.gameID = gameID; supported = false
        confirmed = false; lastPeer = 0; offered = nil; incoming = nil; cursor = 0
        ledger = probe.read().ledger
        loadTask?.cancel()
        guard let core, core.deltaCore.identifier == "com.rileytestut.GBADeltaCore" else { return }
        let id = ObjectIdentifier(core), file = core.game.fileURL
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (Bool, [Int: String]) in
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                      (try? BoundPlayerROMProfile(rom: data)) != nil else { return (false, [:]) }
                return (true, BoundSoulMon.areaNames(rom: data))
            }.value
            guard !Task.isCancelled, let self, self.core.map(ObjectIdentifier.init) == id else { return }
            self.supported = result.0; self.areaNames = result.1; self.probe.setVerified(result.0)
        }
    }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soul Link", isDirectory: true)
    }
    static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    func setConnection(owner: String?, room: String?) {
        let value = owner.flatMap { owner in room.map { Self.hash(owner + ":" + $0) } }
        if value != connection { peerGone(); offered = nil; incoming = nil; retiredInvitations = []; connection = value }
        binding = value
    }
    private func retireInvitation(_ run: UUID) {
        if !retiredInvitations.contains(run) { retiredInvitations.append(run) }
        retiredInvitations = Array(retiredInvitations.suffix(32))
    }
    #if DEBUG && targetEnvironment(simulator)
    func qaPermitIncomingInvitation() { canStart = true }
    #endif
    private func transmit(_ kind: BoundSoulPacket.Kind, run: UUID, rows: [BoundSoulRow] = []) {
        if let data = BoundSoulPacket(version: 2, run: run, kind: kind, rows: rows,
                                      losses: ledger?.lossBits ?? Data(repeating: 0, count: 288),
                                      acquired: ledger?.acquisitionBits ?? Data(repeating: 0, count: 288),
                                      sender: epoch, receiver: proposedEpoch ?? peerEpoch).encoded() { _ = send?(data) }
    }
    func invite() {
        guard canStart else { return }
        guard let binding else { return }
        let run = UUID()
        do {
            try probe.start(run: run, binding: binding, offering: true)
            ledger = probe.read().ledger; offered = run
            transmit(.offer, run: run); status = "Waiting for your partner to accept Soul Link."
        } catch { status = "Couldn’t save the Soul Link invitation." }
    }
    func accept() {
        guard canStart, let incoming, let binding else { return }
        do {
            try probe.start(run: incoming, binding: binding); ledger = probe.read().ledger
            transmit(.accept, run: incoming); self.incoming = nil; confirmed = false
        } catch { status = "Start a new game and receive only your starter first." }
    }
    func decline() {
        if let incoming { retireInvitation(incoming); transmit(.decline, run: incoming) }
        incoming = nil
    }
    func receive(_ data: Data) {
        guard BoundMultiplayerFeatures.isEnabled, connected?() == true, let binding else { return }
        if data.starts(with: BoundSoulTeamPacket.prefix) {
            guard let packet = BoundSoulTeamPacket.decode(data), let ledger, !ledger.ended,
                  ledger.run == packet.run, ledger.binding == binding, paired,
                  packet.receiver == epoch, packet.sender == peerEpoch, packet.sequence > peerTeamSequence else { return }
            partnerTeam = packet.team; peerTeamSequence = packet.sequence; peerTeamAt = clock()
            partnerTeamCurrent = packet.team.fieldReady
            return
        }
        if data.starts(with: BoundSoulPacket.legacyPrefix) || (data.starts(with: BoundSoulPacket.prefix) && data.count > 4 && data[4] != 2) {
            incompatiblePeer = true; confirmed = false; canStart = false
            status = "Partner update required for Soul Link sync."; return
        }
        guard let packet = BoundSoulPacket.decode(data) else { return }
        if retiredInvitations.contains(packet.run) {
            if packet.kind == .offer { transmit(.decline, run: packet.run) }
            return
        }
        if ledger?.run == packet.run, ledger?.ended == true, packet.kind != .end { return }
        guard !retiredEpochs.contains(packet.sender) else { return }
        let fresh = packet.receiver == epoch
        if fresh {
            if let old = peerEpoch, old != packet.sender {
                retiredEpochs.append(old); if retiredEpochs.count > 16 { retiredEpochs.removeFirst() }
            }
            if peerEpoch != packet.sender { partnerTeam = nil; peerTeamAt = nil; peerTeamSequence = 0; partnerTeamCurrent = false }
            peerEpoch = packet.sender; proposedEpoch = nil
        } else if proposedEpoch == nil {
            proposedEpoch = packet.sender; proposalAt = clock()
        }
        // Tombstones are monotonic and safe even before the challenge completes.
        // An old alive packet can never mark a reconnected partner ready.
        if ledger?.run == packet.run, ledger?.binding == binding, packet.kind == .state {
            do { try probe.merge(run: packet.run, rows: packet.rows, losses: packet.losses, acquired: packet.acquired); ledger = probe.read().ledger }
            catch { status = "Couldn’t preserve your partner’s Soul Link record."; haltForRecovery(); return }
        }
        if !fresh && ![.offer, .end, .decline].contains(packet.kind) { return }
        switch packet.kind {
        case .end:
            guard let ledger, ledger.run == packet.run, ledger.binding == binding else { return }
            if !ledger.ended { endRun() }
            confirmed = true; lastPeer = clock()
        case .offer:
            if let ledger, ledger.run == packet.run, ledger.binding == binding { transmit(.accept, run: ledger.run) }
            else if incoming == packet.run { break }
            else if canStart, offered == nil, incoming == nil { incoming = packet.run }
            else { transmit(.decline, run: packet.run) }
        case .accept:
            if let ledger, ledger.run == packet.run, ledger.binding == binding {
                do { try probe.markAccepted(); self.ledger = probe.read().ledger }
                catch { status = "Couldn’t save Soul Link acceptance."; haltForRecovery(); return }
                offered = nil; transmit(.confirm, run: ledger.run); confirmed = true; lastPeer = clock()
            }
            else if offered == packet.run, canStart {
                do {
                    try probe.start(run: packet.run, binding: binding); ledger = probe.read().ledger
                    offered = nil; confirmed = true; lastPeer = clock()
                    transmit(.confirm, run: packet.run)
                } catch { status = "Couldn’t start Soul Link. Keep only your starter." }
            }
        case .confirm, .state:
            guard let ledger, ledger.run == packet.run, ledger.binding == binding else { return }
            do {
                try probe.merge(run: packet.run, rows: packet.rows, losses: packet.losses, acquired: packet.acquired)
                try probe.markAccepted(); offered = nil
                self.ledger = probe.read().ledger
                confirmed = true; lastPeer = clock()
            } catch { status = "Couldn’t preserve your partner’s Soul Link record."; haltForRecovery() }
        case .decline:
            if incoming == packet.run { retireInvitation(packet.run); incoming = nil }
            if ledger?.run == packet.run, ledger?.offering == true { cancelInvitation() }
        }
    }
    func endRun() {
        let wasRunning = core?.state == .running
        if let core, core.state == .running, !core.pause() { status = "Couldn’t pause this run safely."; return }
        do {
            try probe.endRun(); ledger = probe.read().ledger
            if let ledger { transmit(.end, run: ledger.run) }
            status = "Soul Link ended. Your run record is kept."; offered = nil; incoming = nil
            if wasRunning { core?.resume() }
        } catch { status = "Couldn’t save the end of this run." }
    }
    func cancelInvitation() {
        let wasRunning = core?.state == .running
        if wasRunning, core?.pause() != true { status = "Couldn’t pause this run safely."; return }
        do {
            let cancelled = ledger?.offering == true ? ledger?.run : nil
            try probe.cancelOffer(); ledger = probe.read().ledger; offered = nil; status = "Soul Link invitation cancelled."
            if let cancelled { retireInvitation(cancelled); transmit(.decline, run: cancelled) }
            if wasRunning { core?.resume() }
        }
        catch { status = "Couldn’t cancel the Soul Link invitation." }
    }
    func peerGone() {
        partnerTeam = nil; peerTeamAt = nil; peerTeamSequence = 0; partnerTeamCurrent = false
        teamSequence = 0; lastTeamSent = -.infinity
        incompatiblePeer = false; confirmed = false; lastPeer = 0; epoch = UUID(); peerEpoch = nil
        proposedEpoch = nil; retiredEpochs = []
    }
    private func updateTeams(at now: TimeInterval) {
        let snapshot = teamSnapshot()
        if localTeam != snapshot.team { localTeam = snapshot.team }
        localTeamCurrent = active && BoundMultiplayerFeatures.isEnabled && snapshot.error == nil && (core == nil || core?.state == .running) && snapshot.ready && snapshot.teamCapturedAt.map { now - $0 >= 0 && now - $0 < 3 } == true
        partnerTeamCurrent = active && BoundMultiplayerFeatures.isEnabled && paired && peerTeamAt.map { now - $0 >= 0 && now - $0 < 3 } == true && partnerTeam?.fieldReady == true
        guard active, ledger?.offering == false, snapshot.error == nil, BoundMultiplayerFeatures.isEnabled, connected?() == true,
              ledger?.binding == binding, paired, let peerEpoch, let run = ledger?.run,
              var team = localTeam, now - lastTeamSent >= 1, teamSequence < UInt64.max else { return }
        team.fieldReady = localTeamCurrent
        teamSequence += 1; lastTeamSent = now
        if let data = BoundSoulTeamPacket(run: run, sender: epoch, receiver: peerEpoch, sequence: teamSequence, team: team).encoded() { _ = send?(data) }
    }
    func teamLocation(slot: String, partner: Bool) -> String {
        guard let ledger else { return "Syncing" }
        if ledger.dead.contains(slot) { return "Fainted" }
        let caught = partner ? ledger.partnerSlots.contains(slot) : ledger.acquired.contains(slot)
        guard caught else { return partner && ledger.partnerAcquisitions == nil ? "Syncing" : "Waiting for catch" }
        guard let team = partner ? partnerTeam : localTeam else { return "Syncing" }
        let prefix = (partner ? partnerTeamCurrent : localTeamCurrent) ? "" : "Last seen: "
        if team.party.contains(where: { $0.slot == slot }) { return prefix + "In party" }
        if BoundSoulLedger.losses(team.boxed).contains(slot) { return prefix + "Boxed" }
        return prefix + "Off team"
    }
    func dismissDeathMoment() {
        guard let moment = deathMoment, let ledger else { return }
        do {
            try probe.acknowledgeDeath(run: ledger.run, slot: moment.slot)
            self.ledger = probe.read().ledger; deathMoment = nil; deathMomentStarted = nil
        } catch { status = "Couldn’t preserve this Soul Link moment."; haltForRecovery() }
    }
    private func updateDeathMoment(at now: TimeInterval) {
        guard BoundMultiplayerFeatures.isEnabled, active, ledger?.offering == false,
              probe.read().error == nil, canPresentDeathMoment?() == true else {
            if deathMoment != nil { deathMoment = nil; deathMomentStarted = nil }
            return
        }
        if deathMoment != nil, let began = deathMomentStarted, now - began >= 7 { dismissDeathMoment() }
        guard probe.read().error == nil else { return }
        let pending = (ledger?.memorials ?? []).filter { !$0.announced }
        let next = pending.first
        if next?.slot != deathMoment?.slot { deathMoment = next; deathMomentStarted = next == nil ? nil : now }
        else if deathMoment != next { deathMoment = next }
    }
    func tick(at time: TimeInterval? = nil) {
        let now = time ?? clock()
        if proposedEpoch != nil, now - proposalAt > 1 { peerGone() }
        probe.setPreviewEnabled(BoundMultiplayerFeatures.isEnabled)
        defer { updateTeams(at: now); updateDeathMoment(at: now); bannerChanged?(!cartridgeManagesPause && (probe.read().error != nil || recoveryError != nil) ? status : nil) }
        let snapshot = probe.read(); if snapshot.ledger != ledger { ledger = snapshot.ledger }
        if let ledger { probe.timeline.observeSoul(ledger) }
        canStart = BoundMultiplayerFeatures.isEnabled && supported && snapshot.ready && snapshot.mons.count == 1
            && !snapshot.mons.contains(where: { $0.eggOrigin || ($0.hp ?? 0) <= 0 })
            && (ledger == nil || ledger?.ended == true) && binding != nil && connected?() == true && nativeActivity?() != true
        if incompatiblePeer {
            canStart = false
            status = "Partner update required for Soul Link sync."
        }
        if let error = snapshot.error { status = error; haltForRecovery(); return }
        // An invitation belongs to this account/room until explicitly answered.
        // Packet silence and challenge renewal do not revoke the user's prompt.
        guard let ledger else {
            if offered == nil && incoming == nil {
                status = canStart ? "Ready to start Soul Link." : "Start a new game, receive only your starter, and connect to your partner."
            }
            if let offered, now - sent > 1 { sent = now; transmit(.offer, run: offered) }
            return
        }
        let transportReady = !incompatiblePeer && BoundMultiplayerFeatures.isEnabled && connected?() == true && binding == ledger.binding
        if ledger.ended { status = "Soul Link ended. Your run record is kept." }
        else if !transportReady || !confirmed || now - lastPeer > 3 {
            status = incompatiblePeer ? "Soul Link active · Partner update required" : "Soul Link active · Sync pending"
        } else { status = "Soul Link active" }
        guard transportReady, now - sent >= 0.25 else { return }
        sent = now
        if ledger.ended { transmit(.end, run: ledger.run); return }
        if ledger.offering { transmit(.offer, run: ledger.run); return }
        let records = ledger.records.filter(\.eligible)
        let slots = Set(records.map(\.slot)).union(ledger.dead).sorted()
        let rows = slots.map { key in BoundSoulRow(slot: key, name: records.first(where: { $0.slot == key })?.name ?? "", dead: ledger.dead.contains(key)) }
        let chunk: [BoundSoulRow]
        if rows.isEmpty { chunk = [] }
        else {
            cursor = cursor % rows.count; chunk = Array(rows[cursor..<min(cursor + 3, rows.count)]); cursor = (cursor + chunk.count) % rows.count
        }
        transmit(.state, run: ledger.run, rows: chunk)
    }
}

struct BoundSoulControls: View {
    @ObservedObject var session: BoundSoulSession
    @State private var confirming = false
    @State private var ending = false
    var body: some View {
        if BoundMultiplayerFeatures.isEnabled {
            Section("Soul Link") {
                Text(session.status).font(.caption).accessibilityIdentifier("bound.soul-link.status")
                if session.recoveryError != nil || session.probe.read().error != nil {
                    Button("Retry") { session.retryRecovery() }.accessibilityIdentifier("bound.soul-link.retry")
                }
                if session.ledger == nil || session.ledger?.ended == true {
                    if session.incoming != nil {
                        Button("Accept Soul Link") { confirming = true }.disabled(!session.canStart)
                        Button("Decline", role: .cancel) { session.decline() }
                    } else {
                        Button(session.offered == nil ? "Start Soul Link" : "Invitation sent") { confirming = true }
                            .disabled(!session.canStart || session.offered != nil)
                            .accessibilityIdentifier("bound.soul-link.start")
                    }
                }
                if let ledger = session.ledger {
                    if ledger.offering { Button("Cancel invitation", role: .cancel) { session.cancelInvitation() } }
                    else if !ledger.ended { Button("End Soul Link run", role: .destructive) { ending = true } }
                    NavigationLink {
                        BoundSoulTeamDashboard(session: session)
                    } label: { Label("Shared team", systemImage: "person.2.fill") }
                    .accessibilityIdentifier("bound.soul-link.team")
                    NavigationLink {
                        BoundSoulEncountersView(session: session)
                    } label: {
                        LabeledContent("Paired encounters", value: "\(session.encounters.filter { $0.state == .linked }.count) linked")
                    }
                    .accessibilityIdentifier("bound.soul-link.encounters")
                    NavigationLink {
                        BoundSoulGraveyardView(session: session)
                    } label: {
                        LabeledContent("Graveyard", value: "\(session.graveyard.count) lost")
                    }
                    .accessibilityIdentifier("bound.soul-link.graveyard")
                }
            }
            .confirmationDialog("End this Soul Link run?", isPresented: $ending, titleVisibility: .visible) {
                Button("End run", role: .destructive) { session.endRun() }
            } message: {
                Text("This ends the challenge for both players. Your Pokémon and the run record are kept. Your partner receives the result when you reconnect.")
            }
            .confirmationDialog("Start Soul Link with this friend?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Start Soul Link") { if session.incoming != nil { session.accept() } else { session.invite() } }
            } message: {
                Text("Start after receiving only your starter. One catch per named area, including raids. Eggs pair as Egg 1, Egg 2. Fainting permanently disables both linked Pokémon, except in friendly battles. Offline losses apply when received. Trades are unavailable during the run.")
            }
        }
    }
    static func title(_ slot: String, names: [Int: String] = [:]) -> String {
        let parts = slot.split(separator: ":")
        if parts.first == "area", let value = Int(parts.last ?? ""), let name = names[value] { return name }
        return (parts.first == "egg" ? "Egg " : "Area ") + String(parts.last ?? "")
    }
}
struct BoundSoulEncountersView: View {
    @ObservedObject var session: BoundSoulSession
    @State private var search = ""
    var body: some View {
        List {
            if !session.paired { Section { Text(session.status).font(.caption) } }
            let rows = session.encounters.filter { search.isEmpty || BoundSoulControls.title($0.slot, names: session.areaNames).localizedCaseInsensitiveContains(search) || ($0.localName ?? "").localizedCaseInsensitiveContains(search) || ($0.partnerName ?? "").localizedCaseInsensitiveContains(search) }
            Section("Encounters") { ForEach(rows.filter(\.occupied)) { row in encounter(row) } }
            Section("Available Areas") { ForEach(rows.filter { !$0.occupied }) { row in encounter(row) } }
        }
        .navigationTitle("Paired Encounters")
        .searchable(text: $search, prompt: "Area or Pokémon")
        .accessibilityIdentifier("bound.soul-link.encounter-list")
    }
    private func encounter(_ row: BoundSoulEncounter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(BoundSoulControls.title(row.slot, names: session.areaNames)).font(.headline)
                Spacer()
                Text(row.state.rawValue).font(.caption).foregroundStyle(row.state == .lost ? Color.red : Color.secondary)
            }
            Text("You: " + (row.localName ?? (row.state == .lost ? "Unavailable" : "Catch available"))).font(.subheadline)
            Text("Partner: " + (row.partnerName ?? (row.state == .lost ? "Unavailable" : row.state == .syncing ? "Syncing" : "Catch available"))).font(.subheadline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bound.soul-link.encounter." + row.slot)
    }
}

struct BoundSoulTeamDashboard: View {
    @ObservedObject var session: BoundSoulSession
    @State private var dex: BoundRRDexCatalog?
    var body: some View {
        List {
            Section {
                Text(session.status).font(.caption)
                HStack {
                    teamColumn(title: "You", team: session.localTeam, current: session.localTeamCurrent)
                    Divider()
                    teamColumn(title: "Partner", team: session.partnerTeam, current: session.partnerTeamCurrent)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            Section("Linked Pairs") {
                ForEach(session.encounters.filter(\.occupied)) { pair in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(BoundSoulControls.title(pair.slot, names: session.areaNames)).font(.headline)
                            Spacer()
                            Text(pair.state.rawValue).font(.caption).foregroundStyle(pair.state == .lost ? Color.red : Color.secondary)
                        }
                        HStack(alignment: .top) {
                            pairSide(name: pair.localName, location: session.teamLocation(slot: pair.slot, partner: false))
                            Image(systemName: pair.state == .lost ? "heart.slash.fill" : "link").foregroundStyle(.secondary)
                            pairSide(name: pair.partnerName, location: session.teamLocation(slot: pair.slot, partner: true))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("bound.soul-link.team-pair." + pair.slot)
                }
                NavigationLink("Paired encounters") { BoundSoulEncountersView(session: session) }
                NavigationLink("Graveyard") { BoundSoulGraveyardView(session: session) }
            }
        }
        .navigationTitle("Shared Team")
        .accessibilityIdentifier("bound.soul-link.team-dashboard")
        .task { dex = await Task.detached(priority: .utility) { BoundRRDexCatalog.bundled }.value }
    }
    private func pairSide(name: String?, location: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name ?? "No catch yet").font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Text(location).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func teamColumn(title: String, team: BoundSoulTeam?, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(current ? "Live" : team == nil ? "Waiting for team" : "Last seen").font(.caption).foregroundStyle(.secondary)
            if let team {
                ForEach(Array(team.party.enumerated()), id: \.offset) { _, member in
                    let lost = member.barred || member.slot.map { session.ledger?.dead.contains($0) == true } == true
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .top, spacing: 4) {
                            if !member.isEgg, let sprite = dex?.pokemon(id: member.species)?.sprite, let bytes = Data(base64Encoded: sprite), let image = UIImage(data: bytes) {
                                Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 32, height: 32).accessibilityHidden(true)
                            }
                            Text(member.name).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        }
                        if member.isEgg { Text("Egg").font(.caption) }
                        else {
                            if let level = member.level { Text("Lv. \(level)").font(.caption).foregroundStyle(.secondary) }
                            if let hp = member.hp, let maxHP = member.maxHP {
                                Text("\(lost ? 0 : hp)/\(maxHP) HP").font(.caption).monospacedDigit()
                                ProgressView(value: Double(lost ? 0 : hp), total: Double(maxHP)).tint(lost ? .red : .green)
                            }
                        }
                        if lost { Text("Unusable").font(.caption).foregroundStyle(.red) }
                        else if member.slot == nil { Text("Unlinked").font(.caption).foregroundStyle(.secondary) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("bound.soul-link.team-member." + title + "." + member.name)
                }
                if team.party.isEmpty { Text("No party Pokémon").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct BoundSoulGraveyardView: View {
    @ObservedObject var session: BoundSoulSession
    var body: some View {
        List {
            if session.graveyard.isEmpty {
                ContentUnavailableView("No lost pairs", systemImage: "heart.fill")
            }
            ForEach(session.graveyard) { loss in
                VStack(alignment: .leading, spacing: 6) {
                    Label(BoundSoulControls.title(loss.slot, names: session.areaNames), systemImage: "heart.slash.fill")
                        .font(.headline).foregroundStyle(.red)
                    Text("You: " + loss.localLabel)
                    Text("Partner: " + loss.partnerLabel)
                    if let date = loss.recordedAt { Text(date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("bound.soul-link.memorial." + loss.slot)
            }
        }
        .navigationTitle("Graveyard")
        .accessibilityIdentifier("bound.soul-link.graveyard-list")
    }
}

/// A quiet, dismissible in-game card; it does not pause the core or intercept controls.
struct BoundSoulDeathNotice: View {
    @ObservedObject var session: BoundSoulSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if let loss = session.deathMoment {
                VStack(spacing: 8) {
                    HStack(alignment: .top) {
                        Image(systemName: "heart.slash.fill").font(.title2).foregroundStyle(.red)
                        Spacer()
                        Button { session.dismissDeathMoment() } label: {
                            Image(systemName: "xmark").padding(10).contentShape(Rectangle())
                        }
                        .accessibilityLabel("Dismiss death announcement")
                        .accessibilityIdentifier("bound.soul-link.death-dismiss")
                    }
                    Text("SOUL LINK BROKEN").font(.headline).tracking(2)
                    Text(loss.names).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(BoundSoulControls.title(loss.slot, names: session.areaNames)).font(.subheadline)
                    Text("Together, remembered.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .environment(\.colorScheme, .dark)
                .foregroundStyle(.white)
                .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).stroke(.red.opacity(0.7), lineWidth: 1) }
                .shadow(color: .red.opacity(0.2), radius: 14)
                .accessibilityIdentifier("bound.soul-link.death-moment")
                .id(loss.slot)
                .onAppear {
                    UIAccessibility.post(notification: .announcement, argument: "Soul Link broken. " + loss.names + ". " + BoundSoulControls.title(loss.slot, names: session.areaNames))
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: session.deathMoment?.slot)
    }
}

@MainActor
final class BoundSoulBanner: UILabel {
    init() {
        super.init(frame: .zero)
        numberOfLines = 0; textAlignment = .center
        font = .preferredFont(forTextStyle: .caption1)
        backgroundColor = .secondarySystemBackground; textColor = .label
        layer.cornerRadius = 8; clipsToBounds = true; isHidden = true
        accessibilityIdentifier = "bound.soul-link.paused"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func show(_ message: String?) {
        guard text != message || isHidden != (message == nil) else { return }
        text = message; isHidden = message == nil
        if message != nil { superview?.bringSubviewToFront(self) }
    }
}

struct BoundRunEvent: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable { case catchPokemon, death, trade, victory }
    let id: String
    let date: Date
    let kind: Kind
    let title: String
    let detail: String
    var symbol: String {
        switch kind {
        case .catchPokemon: return "circle.inset.filled"
        case .death: return "heart.slash"
        case .trade: return "arrow.left.arrow.right"
        case .victory: return "trophy"
        }
    }
}

/// Append-only per-game history. The frame owner and UI share this locked store;
/// persistence succeeds before new history becomes visible. It never writes saves.
final class BoundRunTimeline: @unchecked Sendable {
    struct Journal: Codable {
        var version = 1
        var events: [BoundRunEvent] = []
        var known: Set<BoundSoulIdentity> = []
        var initialized = false
    }
    private let lock = NSRecursiveLock()
    private var journal = Journal()
    private var url: URL?
    private var gameID = ""
    private var error: String?
    private var inBattle = false
    private var battleID: UUID?
    private var battleFlags: UInt32 = 0
    private var execute: (((() -> Void)) -> Void)?
    private var isExecuting: (() -> Bool)?
    private var durableJournal: Journal?
    private var pendingEncoded:Data?
    func stageWrites(execute: @escaping ((() -> Void) -> Void), isExecuting: @escaping () -> Bool) {
        self.execute=execute;self.isExecuting=isExecuting
    }
    func pendingBytes() throws -> Data {
        lock.lock();defer { lock.unlock() }
        if let pendingEncoded { return pendingEncoded }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let bytes=try encoder.encode(journal);pendingEncoded=bytes;return bytes
    }
    func confirm(_ bytes:Data) {
        lock.lock();defer { lock.unlock() }
        durableJournal=try? JSONDecoder().decode(Journal.self,from:bytes)
    }
    func configure(url: URL?, gameID: String = "") {
        if let execute,isExecuting?() == false { execute { self.configure(url:url,gameID:gameID) };return }
        lock.lock(); defer { lock.unlock() }
        self.url = url; self.gameID = gameID; journal = Journal();durableJournal=journal;pendingEncoded=nil; error = nil; inBattle = false; battleID = nil
        guard let url, BoundServerMemoryFiles.exists(url, gameID: gameID) else { return }
        do {
            let bytes = try BoundServerMemoryFiles.read(url, gameID: gameID)
            guard bytes.count <= 8_388_608 else { throw BoundSoulLedger.Error.capacity }
            let value = try JSONDecoder().decode(Journal.self, from: bytes)
            guard value.version == 1, value.events.count <= 20000, value.known.count <= 20000,
                  Set(value.events.map(\.id)).count == value.events.count,
                  value.events.allSatisfy({ $0.id.count <= 180 && $0.title.count <= 100 && $0.detail.count <= 200 && $0.date.timeIntervalSince1970.isFinite }) else { throw BoundSoulLedger.Error.corrupt }
            journal = value;durableJournal=value
        } catch { self.error = "Run history couldn’t be read." }
    }
    func read() -> (events: [BoundRunEvent], error: String?) {
        lock.lock(); defer { lock.unlock() }; return ((execute == nil ? journal:durableJournal ?? Journal()).events, error)
    }
    private func save(_ value: Journal) throws {
        guard let url, value.events.count <= 20000, value.known.count <= 20000 else { throw BoundSoulLedger.Error.capacity }
        if execute == nil {
            try BoundServerMemoryFiles.directory(url.deletingLastPathComponent(), gameID: gameID)
            try BoundServerMemoryFiles.write(JSONEncoder().encode(value), to: url, gameID: gameID)
        } else { _=try JSONEncoder().encode(value) }
        journal = value
        pendingEncoded=nil
    }
    func append(id: String, kind: BoundRunEvent.Kind, title: String, detail: String = "", at date: Date = Date()) {
        if let execute,isExecuting?() == false { execute { self.append(id:id,kind:kind,title:title,detail:detail,at:date) };return }
        lock.lock(); defer { lock.unlock() }
        guard error == nil, url != nil, !journal.events.contains(where: { $0.id == id }) else { return }
        var value = journal
        value.events.append(.init(id: id, date: date, kind: kind, title: title, detail: detail))
        do { try save(value) } catch { self.error = "Run history couldn’t be saved." }
    }
    func observe(mons: [BoundSoulMon], ready: Bool, battle: Bool, outcome: Int, flags: UInt32, at date: Date = Date()) {
        if let execute,isExecuting?() == false { execute { self.observe(mons:mons,ready:ready,battle:battle,outcome:outcome,flags:flags,at:date) };return }
        lock.lock(); defer { lock.unlock() }
        guard error == nil, url != nil else { return }
        // Ignore link/scripted demonstrations; never claim a victory from a
        // loaded outcome byte without observing a battle in this session.
        if battle && !inBattle { battleID = UUID(); battleFlags = flags }
        if battle { battleFlags |= flags }
        if !battle && inBattle, let id = battleID, outcome == 1, battleFlags & 0x10222 == 0 {
            append(id: "victory:" + id.uuidString, kind: .victory,
                   title: battleFlags & 8 != 0 ? "Trainer battle won" : "Wild battle won", at: date)
        }
        inBattle = battle
        guard ready else { return }
        var value = journal
        for mon in mons where !value.known.contains(mon.identity) {
            if value.initialized {
                value.events.append(.init(id: "catch:\(mon.identity.personality):\(mon.identity.trainer)", date: date,
                    kind: .catchPokemon, title: mon.isEgg ? "Egg received" : "Acquired \(mon.name)", detail: "Area \(mon.area)"))
            }
            value.known.insert(mon.identity)
        }
        value.initialized = true
        if value.known != journal.known || value.initialized != journal.initialized {
            do { try save(value) } catch { self.error = "Run history couldn’t be saved." }
        }
    }
    func observeSoul(_ ledger: BoundSoulLedger) {
        if let execute,isExecuting?() == false { execute { self.observeSoul(ledger) };return }
        for death in ledger.memorials ?? [] {
            // Undated migrated losses are historical, not fabricated new events.
            guard let date = death.recordedAt else { continue }
            append(id: "death:\(ledger.run.uuidString):\(death.slot)", kind: .death,
                   title: "Linked pair lost", detail: death.names, at: date)
        }
    }
}

struct BoundRunTimelineView: View {
    let timeline: BoundRunTimeline
    @State private var events: [BoundRunEvent] = []
    @State private var error: String?
    @State private var filter: BoundRunEvent.Kind?
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private func load() { let snapshot = timeline.read(); events = snapshot.events; error = snapshot.error }
    var body: some View {
        List {
            Picker("Show", selection: $filter) {
                Text("All events").tag(BoundRunEvent.Kind?.none)
                Text("Catches").tag(Optional(BoundRunEvent.Kind.catchPokemon))
                Text("Deaths").tag(Optional(BoundRunEvent.Kind.death))
                Text("Trades").tag(Optional(BoundRunEvent.Kind.trade))
                Text("Victories").tag(Optional(BoundRunEvent.Kind.victory))
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            let visible = events.reversed().filter { filter == nil || $0.kind == filter }.sorted { $0.date > $1.date }
            if visible.isEmpty { Text("No events yet").foregroundStyle(.secondary) }
            ForEach(visible) { event in
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title)
                        if !event.detail.isEmpty { Text(event.detail).font(.caption).foregroundStyle(.secondary) }
                        Text(event.date, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: event.symbol) }
            }
        }
        .navigationTitle("Run Timeline")
        .accessibilityIdentifier("bound.run-timeline")
        .onAppear { load() }
        .onReceive(refresh) { _ in load() }
    }
}

struct BoundRunTimelineControls: View {
    let timeline: BoundRunTimeline
    var body: some View {
        Section {
            NavigationLink {
                BoundRunTimelineView(timeline: timeline)
            } label: {
                Label("Run timeline", systemImage: "clock.arrow.circlepath")
            }
        }
    }
}
