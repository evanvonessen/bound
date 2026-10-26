import Foundation

/// The existing reliable interaction envelope. Authentication, kind admission,
/// event meaning, and lifecycle transitions belong to callers of the codec.
struct BoundSDKReliableEnvelope: Equatable, Sendable {
    let kind: UInt8
    let owner: UUID
    let epoch: UUID
    let receiver: UUID?
    let sequence: UInt64
    let body: Data

    func encoded() -> Data? {
        typealias Layout = BoundSDKProtocol.ReliableEnvelope
        guard sequence > 0, body.count <= Layout.maxBodySize else { return nil }
        var data = Data(repeating: 0, count: Layout.headerSize)
        data.replaceSubrange(0..<4, with: Layout.prefix)
        data[Layout.versionOffset] = Layout.version; data[Layout.kindOffset] = kind
        BoundSDKBytes.put(owner, into: &data, at: Layout.ownerOffset)
        BoundSDKBytes.put(epoch, into: &data, at: Layout.epochOffset)
        BoundSDKBytes.put(receiver, into: &data, at: Layout.receiverOffset)
        for i in 0..<8 { data[Layout.sequenceOffset + i] = UInt8(truncatingIfNeeded: sequence >> (i * 8)) }
        data.append(body)
        return data
    }

    static func decode(_ data: Data) -> Self? {
        typealias Layout = BoundSDKProtocol.ReliableEnvelope
        guard (Layout.headerSize...Layout.maxByteSize).contains(data.count), data.starts(with: Layout.prefix),
              data[Layout.versionOffset] == Layout.version,
              data[Layout.reservedOffset..<Layout.reservedOffset + Layout.reservedSize].allSatisfy({ $0 == 0 }) else { return nil }
        let owner = BoundSDKBytes.uuid(data, Layout.ownerOffset), epoch = BoundSDKBytes.uuid(data, Layout.epochOffset)
        let receiver = BoundSDKBytes.uuid(data, Layout.receiverOffset)
        let sequence = (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[Layout.sequenceOffset + $1]) << ($1 * 8) }
        guard owner != BoundSDKBytes.zero, epoch != BoundSDKBytes.zero, sequence > 0 else { return nil }
        return .init(kind: data[Layout.kindOffset], owner: owner, epoch: epoch,
                     receiver: receiver == BoundSDKBytes.zero ? nil : receiver,
                     sequence: sequence, body: data.subdata(in: Layout.headerSize..<data.count))
    }
}

/// The compatibility-tagged world envelope transports an opaque game payload.
/// The game-family state validator continues to own map and checkpoint meaning.
struct BoundSDKWorldEnvelope: Equatable, Sendable {
    let sender: UUID
    let receiver: UUID?
    let sequence: UInt64
    let body: Data

    func encoded(compatibility: Data) -> Data? {
        typealias Layout = BoundSDKProtocol.WorldEnvelope
        guard sequence > 0 else { return nil }
        var data = Data(Layout.prefix) + compatibility
        var senderBytes = sender.uuid, receiverBytes = (receiver ?? BoundSDKBytes.zero).uuid
        withUnsafeBytes(of: &senderBytes) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &receiverBytes) { data.append(contentsOf: $0) }
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8(truncatingIfNeeded: sequence >> shift)) }
        data.append(body)
        return data.count <= Layout.transportByteLimit ? data : nil
    }

    static func decode(_ data: Data, compatibility: Data) -> Self? {
        typealias Layout = BoundSDKProtocol.WorldEnvelope
        guard (Layout.minByteSize...Layout.maxByteSize).contains(data.count), data.starts(with: Layout.prefix),
              data.subdata(in: Layout.compatibilityOffset..<Layout.compatibilityOffset + Layout.compatibilitySize) == compatibility else { return nil }
        let sender = BoundSDKBytes.uuid(data, Layout.senderOffset), receiver = BoundSDKBytes.uuid(data, Layout.receiverOffset)
        let sequence = (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[Layout.sequenceOffset + $1]) << ($1 * 8) }
        guard sender != BoundSDKBytes.zero, sequence > 0,
              data.count == Layout.bouldersOffset + Int(data[Layout.boulderCountOffset]) * Layout.boulderStride else { return nil }
        return .init(sender: sender, receiver: receiver == BoundSDKBytes.zero ? nil : receiver,
                     sequence: sequence, body: data.subdata(in: Layout.headerSize..<data.count))
    }
}
