import Foundation

/// Versioned data frames shared with a cartridge. Game command interpretation
/// and native identity conversion remain in the adapter calling these codecs.
struct BoundSDKUIRequestFrame: Equatable, Sendable {
    let sequence: UInt32
    let command: UInt32
    let friendIndex: UInt32
    let argument: UInt32
    let identifier: UUID
    let settings: Data
    let flags: UInt32
    let frame: UInt32
    let requestID: UInt32
    let debugSetup: Bool
    let setupError: UInt32

    static func decode(_ data: Data) -> Self? {
        typealias Layout = BoundSDKProtocol.UIRequest
        guard data.count == Layout.byteSize, data.prefix(8) == Data(Layout.prefix) else { return nil }
        let sequence = BoundSDKBytes.word(data, Layout.sequenceOffset)
        guard sequence > 0, sequence & 1 == 0 else { return nil }
        return .init(sequence: sequence, command: BoundSDKBytes.word(data, Layout.commandOffset),
                     friendIndex: BoundSDKBytes.word(data, Layout.friendIndexOffset),
                     argument: BoundSDKBytes.word(data, Layout.argumentOffset),
                     identifier: BoundSDKBytes.uuid(data, Layout.identifierOffset),
                     settings: data.subdata(in: Layout.settingsOffset..<Layout.settingsOffset + Layout.settingsSize),
                     flags: BoundSDKBytes.word(data, Layout.flagsOffset),
                     frame: BoundSDKBytes.word(data, Layout.frameOffset),
                     requestID: BoundSDKBytes.word(data, Layout.requestIDOffset),
                     debugSetup: BoundSDKBytes.word(data, Layout.debugSetupOffset) == 1,
                     setupError: BoundSDKBytes.word(data, Layout.setupErrorOffset))
    }
}

struct BoundSDKUIHostFrame: Sendable {
    struct Entry: Sendable { var identifier: UUID; var name: String; var status: UInt32 }
    struct PeerLocation: Sendable {
        var group: Int; var number: Int; var elevation: Int
        var x: Int; var y: Int; var previousX: Int; var previousY: Int
    }
    struct PlayerIdentity: Sendable { var name: Data; var gender: UInt8; var debugPlayer: UInt8 }
    var flags: UInt32
    var acknowledgedRequest: UInt32
    var status: UInt32
    var run: UUID?
    var localSeed: UInt32
    var partnerSeed: UInt32
    var settings: Data
    var partnerName: String
    var message: String
    var entries: [Entry]
    var peerLocation: PeerLocation?
    var playerIdentity: PlayerIdentity?
    var page: UInt32

    func encoded(sequence: UInt32) -> Data {
        typealias Layout = BoundSDKProtocol.UIHost
        var data = Data(repeating: 0, count: Layout.byteSize)
        data.replaceSubrange(0..<8, with: Layout.prefix)
        BoundSDKBytes.put(sequence, into: &data, at: Layout.sequenceOffset)
        BoundSDKBytes.put(flags, into: &data, at: Layout.flagsOffset)
        BoundSDKBytes.put(acknowledgedRequest, into: &data, at: Layout.acknowledgedRequestOffset)
        BoundSDKBytes.put(status, into: &data, at: Layout.statusOffset)
        BoundSDKBytes.put(UInt32(min(entries.count, Layout.friendCapacity)), into: &data, at: Layout.friendCountOffset)
        BoundSDKBytes.put(run, into: &data, at: Layout.runOffset)
        BoundSDKBytes.put(localSeed, into: &data, at: Layout.localSeedOffset)
        BoundSDKBytes.put(partnerSeed, into: &data, at: Layout.partnerSeedOffset)
        if settings.count == Layout.settingsSize { data.replaceSubrange(Layout.settingsOffset..<Layout.settingsOffset + Layout.settingsSize, with: settings) }
        BoundSDKBytes.text(partnerName, into: &data, at: Layout.partnerNameOffset, size: Layout.partnerNameSize)
        BoundSDKBytes.text(message, into: &data, at: Layout.messageOffset, size: Layout.messageSize)
        BoundSDKBytes.put(UInt32(Layout.leaseFrames), into: &data, at: Layout.leaseOffset)
        BoundSDKBytes.put(page, into: &data, at: Layout.pageOffset)
        for (index, entry) in entries.prefix(Layout.friendCapacity).enumerated() {
            let offset = Layout.friendsOffset + index * Layout.friendStride
            BoundSDKBytes.put(entry.identifier, into: &data, at: offset)
            BoundSDKBytes.text(entry.name, into: &data, at: offset + Layout.friendNameOffset, size: Layout.friendNameSize)
            BoundSDKBytes.put(entry.status, into: &data, at: offset + Layout.friendStatusOffset)
        }
        if let peerLocation {
            let offset = Layout.peerPresenceOffset
            BoundSDKBytes.put(1, into: &data, at: offset)
            data[Layout.peerGroupOffset] = UInt8(peerLocation.group); data[Layout.peerNumberOffset] = UInt8(peerLocation.number)
            data[Layout.peerElevationOffset] = UInt8(peerLocation.elevation)
            for (position, value) in [(Layout.peerXOffset, peerLocation.x), (Layout.peerYOffset, peerLocation.y),
                                      (Layout.peerPreviousXOffset, peerLocation.previousX), (Layout.peerPreviousYOffset, peerLocation.previousY)] {
                let bits = UInt16(bitPattern: Int16(value))
                data[position] = UInt8(truncatingIfNeeded: bits)
                data[position + 1] = UInt8(bits >> 8)
            }
        }
        if let playerIdentity {
            let offset = Layout.playerNameOffset
            data.replaceSubrange(offset..<offset + Layout.playerNameSize, with: playerIdentity.name)
            data[Layout.playerGenderOffset] = playerIdentity.gender; data[Layout.playerPresentOffset] = 1
            data[Layout.debugPlayerOffset] = playerIdentity.debugPlayer
        }
        return data
    }
}
