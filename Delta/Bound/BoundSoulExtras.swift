import Foundation

/// Complete monotonic gift/static facts supplement the area/egg packet without
/// sharing their ordinal namespace. Authentication and fresh challenge matching
/// remain the session owner's responsibility before any facts are merged.
struct BoundSoulExtrasPacket: Sendable {
    static let prefix = Data([0x42, 0x53, 0x45, 0x31]) // BSE1
    let category: String
    let run: UUID
    let sender: UUID
    let receiver: UUID
    let acquired: Data
    let losses: Data
    let boxed: Data
    var rows: [BoundSoulRow] = []

    static func recognizes(_ data: Data) -> Bool { data.starts(with: prefix) }

    private static func categoryByte(_ category: String) -> UInt8? {
        switch category {
        case "gift": return 0
        case "static": return 1
        default: return nil
        }
    }
    private static func ordinal(_ slot: String, category: String) -> Int? {
        let parts = slot.split(separator: ":", omittingEmptySubsequences: false)
        guard categoryByte(category) != nil, parts.count == 2, parts[0] == category,
              let value = Int(parts[1]), (1...2048).contains(value), String(value) == parts[1] else { return nil }
        return value
    }
    static func bits(_ slots: Set<String>, category: String) -> Data {
        var data = Data(repeating: 0, count: 256)
        for slot in slots {
            guard let ordinal = ordinal(slot, category: category) else { continue }
            let bit = ordinal - 1
            data[bit / 8] |= 1 << (bit % 8)
        }
        return data
    }
    static func slots(_ bits: Data, category: String) -> Set<String> {
        guard bits.count == 256, categoryByte(category) != nil else { return [] }
        let bytes = Data(bits)
        return Set((0..<2048).filter { bytes[$0 / 8] & (1 << ($0 % 8)) != 0 }
            .map { "\(category):\($0 + 1)" })
    }

    func encoded() -> Data? {
        guard let categoryByte = Self.categoryByte(category), acquired.count == 256,
              losses.count == 256, boxed.count == 256, rows.count <= 2,
              Set(rows.map(\.slot)).count == rows.count else { return nil }
        var data = Self.prefix
        data.append(categoryByte)
        for value in [run, sender, receiver] {
            var bytes = value.uuid
            withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
        }
        data.append(acquired); data.append(losses); data.append(boxed)
        data.append(UInt8(rows.count))
        for row in rows {
            guard let ordinal = Self.ordinal(row.slot, category: category), row.name.count <= 20 else { return nil }
            let name = Data(row.name.utf8)
            guard name.count <= 80 else { return nil }
            data.append(UInt8(truncatingIfNeeded: ordinal)); data.append(UInt8(ordinal >> 8))
            data.append(row.dead ? 1 : 0); data.append(UInt8(name.count)); data.append(name)
        }
        return data.count <= 990 ? data : nil
    }

    static func decode(_ input: Data) -> Self? {
        guard (822...990).contains(input.count), recognizes(input) else { return nil }
        let data = Data(input)
        guard data[4] <= 1, data[821] <= 2 else { return nil }
        let category = data[4] == 0 ? "gift" : "static"
        func uuid(at offset: Int) -> UUID {
            let b = Array(data[offset..<offset + 16])
            return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        }
        var offset = 822, rows: [BoundSoulRow] = []
        for _ in 0..<Int(data[821]) {
            guard offset + 4 <= data.count else { return nil }
            let ordinal = Int(data[offset]) | Int(data[offset + 1]) << 8
            let dead = data[offset + 2], length = Int(data[offset + 3])
            offset += 4
            guard (1...2048).contains(ordinal), dead <= 1, length <= 80, offset + length <= data.count,
                  let name = String(data: data[offset..<offset + length], encoding: .utf8), name.count <= 20 else { return nil }
            rows.append(.init(slot: "\(category):\(ordinal)", name: name, dead: dead == 1))
            offset += length
        }
        guard offset == data.count, Set(rows.map(\.slot)).count == rows.count else { return nil }
        return .init(category: category, run: uuid(at: 5), sender: uuid(at: 21), receiver: uuid(at: 37),
                     acquired: data.subdata(in: 53..<309), losses: data.subdata(in: 309..<565),
                     boxed: data.subdata(in: 565..<821), rows: rows)
    }
}

/// Readiness expires independently for each complete gift/static baseline.
/// A primary heartbeat cannot renew supplemental facts that have gone silent.
struct BoundSoulExtrasReadiness: Sendable {
    private var received: [String: TimeInterval] = [:]

    mutating func mark(category: String, at time: TimeInterval) {
        guard ["gift", "static"].contains(category), time.isFinite else { return }
        received[category] = time
    }
    mutating func reset() { received.removeAll() }
    func ready(at time: TimeInterval) -> Bool {
        guard time.isFinite else { return false }
        return ["gift", "static"].allSatisfy { category in
            guard let received = received[category] else { return false }
            let age = time - received
            return age >= 0 && age < 3
        }
    }
}
