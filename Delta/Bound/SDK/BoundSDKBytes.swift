import Foundation

/// Byte primitives shared by SDK codecs. Callers validate frame sizes before reading.
enum BoundSDKBytes {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static func word(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
    static func put(_ value: UInt32, into data: inout Data, at offset: Int) {
        for n in 0..<4 { data[offset + n] = UInt8(truncatingIfNeeded: value >> (n * 8)) }
    }
    static func uuid(_ data: Data, _ offset: Int) -> UUID {
        let b = Array(data[offset..<offset + 16])
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }
    static func put(_ uuid: UUID?, into data: inout Data, at offset: Int) {
        var bytes = (uuid ?? zero).uuid
        withUnsafeBytes(of: &bytes) { data.replaceSubrange(offset..<offset + 16, with: $0) }
    }
    static func text(_ string: String, into data: inout Data, at offset: Int, size: Int) {
        let clean = string.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let bytes = clean.unicodeScalars.map { scalar -> UInt8 in
            if scalar.value == 10 { return 10 }
            return (32...126).contains(scalar.value) ? UInt8(scalar.value) : 63
        }.prefix(size - 1)
        data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }
}

