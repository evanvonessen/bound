import Foundation

/// Optional presentation only. The acquired/dead ledger is always authority;
/// receiving this metadata can neither enroll a Pokémon nor change a loss.
struct BoundSoulLinkPresentation: Codable, Equatable, Sendable {
    var species: Int
    var personality: UInt32
    var name: String
    var area: Int
    var ordinal: Int
    var isEgg = false
    var trainerID:UInt32?
    var valid: Bool {
        (0...4095).contains(species) && (0...255).contains(area) && (1...2048).contains(ordinal)
        && !name.isEmpty && name.count <= 20 && name.utf8.count <= 80
    }
}

/// BLP1 cosmetic chunks are scoped to the existing run and fresh challenges.
/// Session code must also reject stale sequences and changed slot ordinals.
struct BoundSoulLinksPacket: Sendable {
    struct Row: Equatable, Sendable {
        var slot: String
        var presentation: BoundSoulLinkPresentation
        var valid: Bool { BoundSoulLedger.validSlot(slot) && presentation.valid }
    }
    static let prefix = Data("BLP1".utf8)
    static let currentPrefix = Data("BLP2".utf8)
    let run: UUID
    let sender: UUID
    let receiver: UUID
    let sequence: UInt64
    let offset: Int
    let total: Int
    var rows: [Row]
    static func recognizes(_ data: Data) -> Bool { data.starts(with: prefix) || data.starts(with:currentPrefix) }
    private var valid: Bool {
        sequence > 0 && (0...2048).contains(total) && offset >= 0 && rows.count <= 8
        && (total == 0 ? offset == 0 && rows.isEmpty : !rows.isEmpty && offset < total && offset + rows.count <= total)
        && rows.allSatisfy(\.valid) && Set(rows.map(\.slot)).count == rows.count
        && zip(rows, rows.dropFirst()).allSatisfy { $0.presentation.ordinal < $1.presentation.ordinal }
    }
    func encoded(legacy:Bool=false) -> Data? {
        guard valid else { return nil }
        var data = Data(repeating: 0, count: 72)
        data.replaceSubrange(0..<4, with: legacy ? Self.prefix:Self.currentPrefix); data[4] = legacy ? 1:2; data[5] = UInt8(rows.count)
        func put(_ value: UInt64, at offset: Int, size: Int) {
            for n in 0..<size { data[offset+n] = UInt8(truncatingIfNeeded: value >> (8*n)) }
        }
        put(UInt64(total), at: 6, size: 2); put(UInt64(offset), at: 8, size: 2); put(sequence, at: 12, size: 8)
        for (offset, value) in [(20, run), (36, sender), (52, receiver)] {
            var bytes = value.uuid
            withUnsafeBytes(of: &bytes) { data.replaceSubrange(offset..<offset+16, with: $0) }
        }
        for row in rows {
            guard let index = BoundSoulLedger.wireIndex(row.slot) else { return nil }
            let p = row.presentation, name = Data(p.name.utf8)
            for value in [index, p.ordinal, p.species] {
                data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(value >> 8))
            }
            data.append(UInt8(p.area)); data.append((p.isEgg ? 1:0) | (!legacy && p.trainerID != nil ? 2:0))
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: p.personality >> shift)) }
            if !legacy { for shift in stride(from:0,to:32,by:8) { data.append(UInt8(truncatingIfNeeded:(p.trainerID ?? 0)>>shift)) } }
            data.append(UInt8(name.count)); data.append(name)
        }
        return data.count <= 1024 ? data : nil
    }
    static func decode(_ input: Data) -> Self? {
        guard (72...1024).contains(input.count), recognizes(input) else { return nil }
        let data = Data(input)
        let modern=data.starts(with:currentPrefix)
        guard data[4] == (modern ? 2:1), data[5] <= 8, data[10] == 0, data[11] == 0,
              data[68..<72].allSatisfy({ $0 == 0 }) else { return nil }
        func number(at offset: Int, size: Int) -> UInt64 {
            (0..<size).reduce(0) { $0 | UInt64(data[offset+$1]) << (8*$1) }
        }
        func uuid(at offset: Int) -> UUID {
            let b = Array(data[offset..<offset+16])
            return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        }
        var position = 72, rows: [Row] = []
        for _ in 0..<Int(data[5]) {
            let header=modern ? 17:13
            guard position + header <= data.count else { return nil }
            let index = Int(number(at: position, size: 2)), ordinal = Int(number(at: position+2, size: 2))
            let species = Int(number(at: position+4, size: 2)), area = Int(data[position+6])
            let flags = data[position+7], personality = UInt32(number(at: position+8, size: 4))
            let trainer=modern ? UInt32(number(at:position+12,size:4)):0
            let length = Int(data[position+header-1]); position += header
            guard let slot = BoundSoulLedger.wireSlot(index), flags <= (modern ? 3:1), (flags&2 != 0 || trainer==0), length <= 80,
                  position + length <= data.count,
                  let name = String(data: data[position..<position+length], encoding: .utf8) else { return nil }
            rows.append(.init(slot: slot, presentation: .init(species: species, personality: personality, name: name,
                                                           area: area, ordinal: ordinal, isEgg: flags&1 != 0,trainerID:modern && flags&2 != 0 ? trainer:nil)))
            position += length
        }
        guard position == data.count else { return nil }
        let value = Self(run: uuid(at: 20), sender: uuid(at: 36), receiver: uuid(at: 52),
                         sequence: number(at: 12, size: 8), offset: Int(number(at: 8, size: 2)),
                         total: Int(number(at: 6, size: 2)), rows: rows)
        return value.valid ? value : nil
    }
}

enum BoundSoulLinks {
    struct Row: Equatable, Sendable {
        var slot: String
        var label: String
        var own: BoundSoulLinkPresentation?
        var partner: BoundSoulLinkPresentation?
        var ownCaught: Bool
        var partnerCaught: Bool
        var dead: Bool
        var partnerNameFallback: String?
    }
    /// Records are append-only acquisition history. Numeric map IDs, nickname
    /// edits, evolution, hatch aliases and packet arrival never reorder them.
    static func localPresentations(ledger: BoundSoulLedger) -> [BoundSoulLinksPacket.Row] {
        guard ledger.valid else { return [] }
        return ledger.records.enumerated().compactMap { index, record in
            guard record.eligible else { return nil }
            let area = record.area ?? (record.slot.hasPrefix("area:") ? Int(record.slot.dropFirst(5)) : nil) ?? 0
            let identity=record.currentIdentity ?? record.identity
            let value = BoundSoulLinkPresentation(species: record.pendingHatch ? 0 : record.species ?? 0, personality: identity.personality,
                name: record.name.isEmpty ? "Pokémon" : record.name, area: area, ordinal: index+1, isEgg: record.pendingHatch,trainerID:identity.trainer)
            return value.valid ? .init(slot: record.slot, presentation: value) : nil
        }
    }
    static func orderedRows(ledger: BoundSoulLedger, areaNames: [Int: String]) -> [Row]? {
        guard ledger.valid, ledger.acquired.count <= 2048, ledger.partnerSlots.count <= 2048 else { return nil }
        let acquired = ledger.acquired, partnerSlots = ledger.partnerSlots, union = acquired.union(partnerSlots).union(ledger.dead)
        guard union.count <= 4096 else { return nil }
        let local = localPresentations(ledger: ledger)
        let own = Dictionary(uniqueKeysWithValues: local.map { ($0.slot, $0.presentation) })
        let peer = (ledger.partnerLinks ?? [:]).filter { partnerSlots.contains($0.key) && $0.value.valid }
        var order = local.map(\.slot)
        let known = Set(order)
        // Older authenticated history may retain a spent slot but no identity
        // or acquisition order. Keep it visible without inventing an ordinal.
        order += union.subtracting(known).sorted { a, b in
            if acquired.contains(a) != acquired.contains(b) { return acquired.contains(a) }
            let left = peer[a]?.ordinal ?? Int.max, right = peer[b]?.ordinal ?? Int.max
            return left == right ? (BoundSoulLedger.wireIndex(a) ?? Int.max) < (BoundSoulLedger.wireIndex(b) ?? Int.max) : left < right
        }
        return order.map { slot in
            .init(slot: slot, label: label(slot, areaNames: areaNames, area: (own[slot]?.area ?? 0) > 0 ? own[slot]?.area : peer[slot]?.area), own: own[slot], partner: peer[slot],
                  ownCaught: acquired.contains(slot), partnerCaught: partnerSlots.contains(slot), dead: ledger.dead.contains(slot),
                  partnerNameFallback: ledger.partnerNames?[slot])
        }
    }
    private static func label(_ slot: String, areaNames: [Int: String], area: Int?) -> String {
        let parts = slot.split(separator: ":"), n = Int(parts[1])!
        if parts[0] == "area" { return n == 0 ? "Celadon City - Prize" : areaNames[n] ?? "Area \(n)" }
        let category = (parts[0] == "egg" ? "Egg " : parts[0] == "gift" ? "Gift " : "Static ") + String(n)
        guard let area, area > 0 else { return category }
        return category + " - " + (areaNames[area] ?? "Area \(area)")
    }
    static func page(ledger: BoundSoulLedger?, areaNames: [Int: String], offset: Int, sequence: UInt32, connected: Bool) -> Data? {
        let rows: [Row]
        if let ledger { guard let value = orderedRows(ledger: ledger, areaNames: areaNames) else { return nil }; rows = value }
        else { rows = [] }
        return encodePage(rows: rows, offset: offset, sequence: sequence, connected: connected)
    }
    /// BLN1 is an immutable two-row viewport in the exact game's 1024-byte port.
    /// It contains no commands and cannot modify catches, identities or saves.
    static func encodePage(rows: [Row], offset: Int, sequence: UInt32, connected: Bool) -> Data? {
        guard sequence > 0, sequence & 1 == 0, offset >= 0, offset <= Int(UInt32.max), rows.count <= 4096,
              rows.allSatisfy({ BoundSoulLedger.validSlot($0.slot) }), Set(rows.map(\.slot)).count == rows.count else { return nil }
        let start = offset
        // Echo a stale request exactly with no rows. The game can then clamp
        // its next request against total without accepting a mismatched page.
        let visible = start >= rows.count ? [] : Array(rows.dropFirst(start).prefix(2))
        var data = Data(repeating: 0, count: 1024)
        func put(_ value: UInt32, at offset: Int, size: Int = 4) {
            for n in 0..<size { data[offset+n] = UInt8(truncatingIfNeeded: value >> (8*n)) }
        }
        put(0x314E4C42, at: 0); put(1, at: 4, size: 2)
        put(sequence, at: 8); put(UInt32(rows.count), at: 12); put(UInt32(start), at: 16)
        put(UInt32(visible.count), at: 20); put(connected ? 1 : 0, at: 24)
        for (index, row) in visible.enumerated() {
            guard let slot = BoundSoulLedger.wireIndex(row.slot) else { return nil }
            let own = row.ownCaught ? row.own : nil, peer = row.partnerCaught ? row.partner : nil
            guard own?.valid != false, peer?.valid != false else { return nil }
            let flags: UInt32 = (row.dead ? 1:0) | (row.ownCaught ? 0:2) | (row.partnerCaught ? 0:4)
                | (own?.isEgg == true ? 8:0) | (peer?.isEgg == true ? 16:0)
            let base = 32 + index*64
            put(UInt32(slot), at: base, size: 2); put(flags, at: base+2, size: 2)
            data.replaceSubrange(base+4..<base+28, with: nativeText(row.label, size: 24))
            put(UInt32(own?.species ?? 0), at: base+28, size: 2); put(UInt32(peer?.species ?? 0), at: base+30, size: 2)
            put(own?.personality ?? 0, at: base+32); put(peer?.personality ?? 0, at: base+36)
            data.replaceSubrange(base+40..<base+51, with: nativeText(own?.name ?? (row.ownCaught ? "Pokémon" : "--"), size: 11))
            data.replaceSubrange(base+51..<base+62, with: nativeText(peer?.name ?? (row.partnerCaught ? row.partnerNameFallback ?? "Pokémon" : "--"), size: 11))
        }
        return data
    }
    private static let glyphs: [Character: UInt8] = [
        " ":0x00,"À":0x01,"Á":0x02,"Â":0x03,"Ç":0x04,"È":0x05,"É":0x06,"Ê":0x07,"Ë":0x08,
        "Ì":0x09,"Î":0x0B,"Ï":0x0C,"Ò":0x0D,"Ó":0x0E,"Ô":0x0F,"Œ":0x10,"Ù":0x11,"Ú":0x12,
        "Û":0x13,"Ñ":0x14,"ß":0x15,"à":0x16,"á":0x17,"ç":0x19,"è":0x1A,"é":0x1B,"ê":0x1C,
        "ë":0x1D,"ì":0x1E,"î":0x20,"ï":0x21,"ò":0x22,"ó":0x23,"ô":0x24,"œ":0x25,"ù":0x26,
        "ú":0x27,"û":0x28,"ñ":0x29,"º":0x2A,"ª":0x2B,"&":0x2D,"+":0x2E,"=":0x35,";":0x36,
        "¿":0x51,"¡":0x52,"<":0x85,">":0x86,"↑":0x79,"↓":0x7A,"←":0x7B,"→":0x7C,"Í":0x5A,"%":0x5B,"(":0x5C,")":0x5D,"â":0x68,"í":0x6F,
        "!":0xAB,"?":0xAC,".":0xAD,"-":0xAE,"·":0xAF,"…":0xB0,"“":0xB1,"”":0xB2,"‘":0xB3,
        "’":0xB4,"'":0xB4,"♂":0xB5,"♀":0xB6,"$":0xB7,",":0xB8,"×":0xB9,"/":0xBA,":":0xF0,
        "Ä":0xF1,"Ö":0xF2,"Ü":0xF3,"ä":0xF4,"ö":0xF5,"ü":0xF6
    ]
    private static let characters: [UInt8: String] = {
        var result: [UInt8: String] = [:]
        for (character, byte) in glyphs { result[byte] = String(character) }
        // The font uses one glyph for both straight and curly apostrophes.
        result[0xB4] = "'"
        return result
    }()
    static func decodeNativeText(_ data: Data) -> String {
        return data.prefix(while: { $0 != 255 }).map { byte in
            switch byte {
            case 0xBB...0xD4: return String(UnicodeScalar(Int(byte-0xBB)+65)!)
            case 0xD5...0xEE: return String(UnicodeScalar(Int(byte-0xD5)+97)!)
            case 0xA1...0xAA: return String(byte-0xA1)
            default: return characters[byte] ?? "?"
            }
        }.joined()
    }
    static func nativeText(_ text: String, size: Int) -> Data {
        guard (1...256).contains(size) else { return Data() }
        var data = Data(repeating: 255, count: size)
        for (index, character) in text.prefix(size-1).enumerated() {
            if let byte = glyphs[character] { data[index] = byte }
            else if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 {
                switch scalar.value {
                case 65...90: data[index] = UInt8(scalar.value-65+0xBB)
                case 97...122: data[index] = UInt8(scalar.value-97+0xD5)
                case 48...57: data[index] = UInt8(scalar.value-48+0xA1)
                default: data[index] = 0xAC
                }
            } else { data[index] = 0xAC }
        }
        return data
    }
}
