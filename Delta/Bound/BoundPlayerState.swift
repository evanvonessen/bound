import Foundation
import CryptoKit

/// The ROM owns these addresses. VBA-M supplies the RAM; no save-state format
/// or alternate emulator is involved in Bound's player-state reader.
struct BoundPlayerState: Equatable, Sendable {
    struct Point: Equatable, Sendable { let x: Int; let y: Int }
    struct DynamicWarp: Equatable, Hashable, Sendable {
        let mapGroup: Int
        let mapNumber: Int
        let warpID: Int
        let x: Int
        let y: Int
    }
    let mapGroup: Int
    let mapNumber: Int
    let tile: Point
    let previousTile: Point
    let facing: String
    let elevation: Int
    let graphicsID: Int
    let runningState: Int
    let tileTransitionState: Int
    var scene: BoundPlayerScene? = nil
    // A native step can update the object before CameraMove updates the save.
    // This anchor only locates the rendered camera; collision uses native tiles.
    var cameraTile: Point? = nil
    var mapInstance: UInt64? = nil
    var dynamicWarp: DynamicWarp? = nil
    var routeAccess: BoundFriendRouteAccess? = nil
}

struct BoundPlayerStateReading: Equatable, Sendable {
    enum Status: String, Sendable {
        case disabled, checkingROM, unsupportedROM, unavailable, waiting, live, paused, stopped
        case battle, outsideOverworld, transition, invalidMemory
        var title: String {
            switch self {
            case .disabled: return "Off"
            case .checkingROM: return "Checking ROM"
            case .unsupportedROM: return "Unsupported ROM"
            case .unavailable: return "Unavailable"
            case .waiting: return "Waiting"
            case .live: return "Live"
            case .paused: return "Paused"
            case .stopped: return "Stopped"
            case .battle: return "Battle"
            case .outsideOverworld: return "Menu / loading"
            case .transition: return "Transition"
            case .invalidMemory: return "Invalid state"
            }
        }
    }
    let frame: UInt64
    let status: Status
    let detail: String
    let player: BoundPlayerState?

    static func inactive(_ status: Status, _ detail: String, frame: UInt64 = 0) -> Self {
        Self(frame: frame, status: status, detail: detail, player: nil)
    }
}

final class BoundPlayerROMProfile: Sendable {
    static let supportedSHA256 = BoundWorldContract.romSHA256
    enum ProfileError: Error { case unsupportedROM }
    let adapter: MultiRedAdapter
    var gameProfile: BoundGameProfile { adapter.profile }
    private let rom: Data
    let sceneAssets = BoundPlayerSceneAssets()

    init(rom: Data) throws {
        adapter = try MultiRedAdapter(rom: rom)
        // This profile is constructed from an owned file mapping, not core RAM.
        self.rom = rom
    }

    func bytes(at address: Int, count: Int) -> [UInt8]? {
        let offset = address - 0x08000000
        guard count >= 0, offset >= 0, offset <= rom.count, count <= rom.count - offset else { return nil }
        return Array(rom[offset..<offset + count])
    }
}

struct BoundGBAMemorySnapshot: Sendable {
    let workRAM: [UInt8]
    let internalRAM: [UInt8]
    var paletteRAM: [UInt8]? = nil
    var followerObservation: BoundNativeFollowerObservation? = nil
    var presentationObservation: BoundNativePresentationObservation? = nil

    init?(copyingWorkRAM work: Data, internalRAM internalData: Data) {
        guard work.count == 0x40000, internalData.count == 0x8000 else { return nil }
        // Data(value) can retain NSData's bytesNoCopy view. Array(rawBuffer)
        // explicitly owns the bytes before VBA-M advances its next frame.
        workRAM = work.withUnsafeBytes { Array($0) }
        internalRAM = internalData.withUnsafeBytes { Array($0) }
    }

    /// Called synchronously on the emulation owner, after a completed frame.
    static func capture(readMemory: (Int, Int) -> Data?) -> Self? {
        // GBADeltaCore's achievement address space: IWRAM first, then EWRAM.
        guard let work = readMemory(0x8000, 0x40000),
              let internalData = readMemory(0, 0x8000) else { return nil }
        guard var snapshot = Self(copyingWorkRAM: work, internalRAM: internalData) else { return nil }
        if let palette = readMemory(0x48000, 0x400), palette.count == 0x400 {
            snapshot.paletteRAM = palette.withUnsafeBytes { Array($0) }
        }
        return snapshot
    }

    func bytes(at address: Int, count: Int) -> [UInt8]? {
        let bank: [UInt8], offset: Int
        if address >= 0x05000000, let paletteRAM { bank = paletteRAM; offset = address - 0x05000000 }
        else if address >= 0x03000000 { bank = internalRAM; offset = address - 0x03000000 }
        else { bank = workRAM; offset = address - 0x02000000 }
        guard count >= 0, offset >= 0, offset <= bank.count, count <= bank.count - offset else { return nil }
        return Array(bank[offset..<offset + count])
    }
}

enum BoundPlayerStateDecoder {
    private static func word(_ bytes: [UInt8], _ offset: Int = 0) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }
    private static func half(_ bytes: [UInt8], _ offset: Int = 0) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }
    private static func coordinate(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(Int16(bitPattern: UInt16(half(bytes, offset))))
    }

    static func read(profile: BoundPlayerROMProfile, memory: BoundGBAMemorySnapshot, frame: UInt64,
                     includeScene: Bool = false, presentationOnly: Bool = false) -> BoundPlayerStateReading {
        let reading = decode(memory: memory, frame: frame, romBytes: profile.bytes, presentationOnly: presentationOnly)
        guard includeScene, var player = reading.player else {
            memory.presentationObservation?.cache.reset()
            return reading
        }
        if let pointer = memory.bytes(at: 0x03005008, count: 4) {
            player.routeAccess = BoundFriendRouteAccess.capture(memory: memory, save: word(pointer),
                currentMap: .init(group: player.mapGroup, number: player.mapNumber), rom: profile.bytes)
        }
        player.scene = BoundPlayerSceneDecoder.read(player: player, memory: memory, profile: profile)
        return .init(frame: frame, status: reading.status, detail: reading.detail, player: player)
    }

    /// Pure decoder seam for small metadata fixtures. Production admission always
    /// constructs the exact-hash profile above before this decoder can run.
    static func decode(memory: BoundGBAMemorySnapshot, frame: UInt64,
                       romBytes: (Int, Int) -> [UInt8]?, presentationOnly: Bool = false) -> BoundPlayerStateReading {
        func invalid(_ detail: String) -> BoundPlayerStateReading { .inactive(.invalidMemory, detail, frame: frame) }
        guard let main = memory.bytes(at: 0x030030F0, count: 8),
              let battle = memory.bytes(at: 0x03003529, count: 1),
              let fade = memory.bytes(at: 0x02037AB8, count: 8) else { return invalid("Incomplete RAM capture") }
        if battle[0] & 2 != 0 { return .inactive(.battle, "Overworld position withheld", frame: frame) }
        guard word(main) == 0x08056535, word(main, 4) == 0x080565B5 else {
            return .inactive(.outsideOverworld, "Waiting for the overworld", frame: frame)
        }
        if fade[7] & 0x80 != 0 || ((half(fade, 4) >> 6) & 31) >= 16 {
            return .inactive(.transition, "Screen fade or fully obscured field", frame: frame)
        }
        guard let pointerBytes = memory.bytes(at: 0x03005008, count: 4) else { return invalid("Save pointer missing") }
        let pointer = word(pointerBytes)
        guard pointer & 3 == 0, pointer >= 0x02000000, pointer <= 0x02040000 - 12,
              let save = memory.bytes(at: pointer, count: 12),
              let header = memory.bytes(at: 0x02036DFC, count: 28),
              let avatar = memory.bytes(at: 0x02037078, count: 8),
              let objects = memory.bytes(at: 0x02036E38, count: 16 * 36) else { return invalid("Invalid RAM pointers") }
        let group = Int(save[4]), number = Int(save[5])
        guard group < 43,
              let groupPointer = romBytes(0x083526A8 + group * 4, 4),
              let headerPointer = romBytes(word(groupPointer) + number * 4, 4),
              romBytes(word(headerPointer), 28) == header,
              let layout = romBytes(word(header), 8) else { return invalid("Map identity disagreement") }
        let width = word(layout), height = word(layout, 4)
        guard (1...1024).contains(width), (1...1024).contains(height) else { return invalid("Invalid map dimensions") }
        let spriteID = Int(avatar[4]), objectID = Int(avatar[5])
        guard objectID < 16, spriteID < 64 else { return invalid("Invalid player slot") }
        let object = Array(objects[objectID * 36..<(objectID + 1) * 36])
        let flags = word(object)
        guard flags & 0x10001 == 0x10001, object[8] == 0xFF,
              (0..<16).filter({ word(objects, $0 * 36) & 0x10001 == 0x10001 }) == [objectID],
              // Connected-map scrolling keeps the player ObjectEvent alive.
              // Its map bytes identify where that object was spawned, while
              // the save location and verified live header own its current map.
              // Native UpdateObjectEventCoordsForCameraUpdate rebases all three
              // coordinate pairs without changing those spawn-map bytes.
              Int(object[4]) == spriteID,
              let sprite = memory.bytes(at: 0x0202063C + spriteID * 68, count: 68),
              half(sprite, 0x2E) == objectID, sprite[0x3E] & 1 != 0 else { return invalid("Player object / sprite disagreement") }
        if flags & (1 << 13) != 0 || sprite[0x3E] & 4 != 0 {
            return .inactive(.transition, "Player is hidden", frame: frame)
        }
        var tile = BoundPlayerState.Point(x: coordinate(object, 0x10) - 7, y: coordinate(object, 0x12) - 7)
        var previous = BoundPlayerState.Point(x: coordinate(object, 0x14) - 7, y: coordinate(object, 0x16) - 7)
        let cameraTile = BoundPlayerState.Point(x: coordinate(save, 0), y: coordinate(save, 2))
        var rebasedAtBoundary = false
        if presentationOnly, tile != cameraTile, avatar[2] == 2, avatar[3] == 2,
           let delta = BoundPlayerMapConnections.pendingBoundaryOffset(in: .init(group: group, number: number),
               tile: tile, previous: previous, camera: cameraTile, rom: romBytes) {
            tile = .init(x: tile.x + delta.x, y: tile.y + delta.y)
            previous = .init(x: previous.x + delta.x, y: previous.y + delta.y)
            rebasedAtBoundary = true
        }
        // Native UpdateObjectEvents commits the next step before CameraMove.
        // A completed emulator frame may interrupt that valid in-map phase.
        // Read its fresh object coordinates without treating it as a reader
        // failure (which would revoke both peers' movement channel). Authority
        // never borrows a connected-map rebase or an out-of-map endpoint.
        let pendingCameraStep = previous == cameraTile
            && abs(tile.x - cameraTile.x) + abs(tile.y - cameraTile.y) == 1
            && avatar[2] == 2 && avatar[3] == 2
            && (presentationOnly || ((0..<width).contains(tile.x) && (0..<height).contains(tile.y)
                && (0..<width).contains(previous.x) && (0..<height).contains(previous.y)))
        guard (tile == cameraTile || pendingCameraStep),
              (-7..<width + 7).contains(tile.x), (-7..<height + 7).contains(tile.y),
              avatar[2] <= 2, avatar[3] <= 2 else { return invalid("Coordinate or movement disagreement") }
        let directions = [1: "South", 2: "North", 3: "West", 4: "East"]
        guard let facing = directions[Int(object[0x18] & 15)], directions[Int(object[0x18] >> 4)] != nil else {
            return invalid("Invalid facing direction")
        }
        let dynamicWarp = memory.bytes(at: pointer + 0x14, count: 8).flatMap { bytes -> BoundPlayerState.DynamicWarp? in
            let group = Int(bytes[0]), number = Int(bytes[1]), warp = Int(Int8(bitPattern: bytes[2]))
            guard group < 43, number < 127, warp >= -1 else { return nil }
            return .init(mapGroup: group, mapNumber: number, warpID: warp,
                         x: coordinate(bytes, 4), y: coordinate(bytes, 6))
        }
        return BoundPlayerStateReading(frame: frame, status: .live, detail: "RR 4.1 · local reader",
            player: BoundPlayerState(mapGroup: group, mapNumber: number, tile: tile, previousTile: previous,
                facing: facing, elevation: Int(object[11] & 15), graphicsID: Int(object[5]),
                runningState: Int(avatar[2]), tileTransitionState: Int(avatar[3]),
                // Boundary camera residuals already belong to the new map's
                // destination tile, even while the saved tile is still behind.
                cameraTile: pendingCameraStep && !rebasedAtBoundary ? cameraTile : nil,
                mapInstance: UInt64(word(headerPointer))<<32 | UInt64(word(header)), dynamicWarp: dynamicWarp))
    }
}

struct BoundPlayerPresenceTracker {
    private var previous: BoundPlayerStateReading?
    mutating func update(_ reading: BoundPlayerStateReading) -> BoundPlayerStateReading {
        defer { previous = reading }
        guard let player = reading.player else { return reading }
        guard let last = previous, let lastPlayer = last.player,
              reading.frame > 0, last.frame == reading.frame - 1,
              player.mapGroup == lastPlayer.mapGroup, player.mapNumber == lastPlayer.mapNumber else {
            return .inactive(.waiting, "Confirming consecutive overworld frames", frame: reading.frame)
        }
        return reading
    }
}
