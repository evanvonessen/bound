import Foundation

/// All coordinates are native GBA pixels (240 x 160). World points are feet at
/// tile origin + (8, 16); camera translation is local and is never replayed.
struct BoundPlayerScene: Equatable, Sendable {
    let worldFoot: BoundPlayerState.Point
    let camera: BoundPlayerState.Point
    let appearance: BoundPlayerSprite
    let background: BoundPlayerBackground
    let objects: [BoundPlayerSceneObject]
}

struct BoundPlayerSprite: Hashable, Sendable {
    let width: Int
    let height: Int
    let tiles: Data
    let palette: Data
    let flipX: Bool
    let flipY: Bool
    let priority: Int
    // ROM-only frame reference for presence. Tile graphics stay on this device.
    var romAddress: Int? = nil

    func colorIndex(x: Int, y: Int) -> Int {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        let x = flipX ? width - 1 - x : x, y = flipY ? height - 1 - y : y
        let offset = ((y / 8) * (width / 8) + x / 8) * 32 + (y % 8) * 4 + (x % 8) / 2
        return Int((tiles[offset] >> ((x & 1) * 4)) & 15)
    }
}

struct BoundPlayerSceneObject: Equatable, Sendable {
    let origin: BoundPlayerState.Point
    let footY: Int
    let appearance: BoundPlayerSprite
}

struct BoundPlayerBackground: Equatable, Sendable {
    struct Layer: Equatable, Sendable {
        let priority: Int
        let scrollX: Int
        let scrollY: Int
        let map: Data
        var masksWholeTiles = false
    }
    let tiles: Data
    let layers: [Layer]

    func covers(x: Int, y: Int, priority: Int) -> Bool {
        for layer in layers where layer.priority < priority {
            let px = (x + layer.scrollX) & 255, py = (y + layer.scrollY) & 255
            let offset = ((py / 8) * 32 + px / 8) * 2
            let entry = Int(layer.map[offset]) | Int(layer.map[offset + 1]) << 8
            // ClearWindowTilemap leaves palette/flip attributes on transparent
            // tile 0 (e.g. 0xE000/0xF000). Only an occupied tile masks a window;
            // treating those attributes as graphics hides the field beneath it.
            if layer.masksWholeTiles { if entry & 1023 != 0 { return true }; continue }
            let tx = entry & 0x400 != 0 ? 7 - (px & 7) : px & 7
            let ty = entry & 0x800 != 0 ? 7 - (py & 7) : py & 7
            let index = (entry & 1023) * 32 + ty * 4 + tx / 2
            if index < tiles.count, (tiles[index] >> ((tx & 1) * 4)) & 15 != 0 { return true }
        }
        return false
    }
}

/// Small bounded ROM-only cache. No native-core state is retained here.
final class BoundPlayerSceneAssets: @unchecked Sendable {
    private let lock = NSLock()
    private var maps: [Int: Data] = [:]
    private var connections: [BoundPlayerMapConnections.Map: BoundPlayerMapConnections.Projection] = [:]

    func mapOffset(fromGroup: Int, number: Int, toGroup: Int, number targetNumber: Int,
                   rom: (Int, Int) -> [UInt8]?) -> BoundPlayerState.Point? {
        let source = BoundPlayerMapConnections.Map(group: fromGroup, number: number)
        let target = BoundPlayerMapConnections.Map(group: toGroup, number: targetNumber)
        if source == target { return .init(x: 0, y: 0) }
        lock.lock(); defer { lock.unlock() }
        if connections[source] == nil {
            if connections.count >= 16 { connections.removeAll() }
            connections[source] = BoundPlayerMapConnections.projection(from: source, rom: rom)
        }
        if let offset = connections[source]?.offsets[target] { return offset }
        if connections[source]?.ambiguous.contains(target) == true { return nil }
        // Some native seams declare only one cardinal direction. Their geometry
        // still locates the previous map when the viewer crosses that seam.
        if connections[target] == nil {
            if connections.count >= 16 { connections.removeAll() }
            connections[target] = BoundPlayerMapConnections.projection(from: target, rom: rom)
        }
        guard let reverse = connections[target]?.offsets[source] else { return nil }
        return .init(x: -reverse.x, y: -reverse.y)
    }

    func tiles(layout: Int, rom: (Int, Int) -> [UInt8]?) -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let cached = maps[layout] { return cached }
        guard let header = rom(layout, 24) else { return nil }
        var result = Data(repeating: 0, count: 1024 * 32)
        for (pointerOffset, destination, capacity) in [(16, 0, 640 * 32), (20, 640 * 32, 384 * 32)] {
            guard let set = rom(BoundSceneBytes.word(header, pointerOffset), 8) else { return nil }
            let address = BoundSceneBytes.word(set, 4)
            let bytes: [UInt8]
            if set[0] == 1 {
                guard let decoded = Self.decompress(address: address, rom: rom), decoded.count <= capacity else { return nil }
                bytes = decoded
            } else {
                guard set[0] == 0, let raw = rom(address, capacity) else { return nil }
                bytes = raw
            }
            result.replaceSubrange(destination..<destination + bytes.count, with: bytes)
        }
        if maps.count >= 8 { maps.removeAll() }
        maps[layout] = result
        return result
    }

    /// GBA LZ77, with bounded source and output, including overlapping copies.
    static func decompress(address: Int, rom: (Int, Int) -> [UInt8]?) -> [UInt8]? {
        guard let header = rom(address, 4), header[0] == 0x10 else { return nil }
        let size = Int(header[1]) | Int(header[2]) << 8 | Int(header[3]) << 16
        guard size > 0, size <= 0x8000 else { return nil }
        var output: [UInt8] = [], cursor = address + 4
        output.reserveCapacity(size)
        while output.count < size {
            guard cursor - address < 0x10000, let flags = rom(cursor, 1)?.first else { return nil }
            cursor += 1
            for bit in (0...7).reversed() where output.count < size {
                if flags & (1 << bit) == 0 {
                    guard let byte = rom(cursor, 1)?.first else { return nil }
                    output.append(byte); cursor += 1
                } else {
                    guard let pair = rom(cursor, 2) else { return nil }
                    cursor += 2
                    let count = Int(pair[0] >> 4) + 3, distance = ((Int(pair[0]) & 15) << 8 | Int(pair[1])) + 1
                    guard distance <= output.count else { return nil }
                    for _ in 0..<min(count, size - output.count) { output.append(output[output.count - distance]) }
                }
            }
        }
        return output
    }
}

/// Native cardinal connections define where adjoining maps are drawn. These
/// are viewer-relative translations, not a fabricated global coordinate grid:
/// some cartridge loops have inconsistent offsets, so nearer connections win
/// and equally short conflicting paths are withheld. Doors/dive/warps never
/// connect unrelated rooms for presentation or interaction authority.
enum BoundPlayerMapConnections {
    struct Map: Hashable { let group: Int; let number: Int }
    struct Projection { let offsets: [Map: BoundPlayerState.Point]; let ambiguous: Set<Map> }
    private struct Header { let width: Int; let height: Int; let edges: [(Int, Int, Map)] }

    private static func header(_ map: Map, rom: (Int, Int) -> [UInt8]?) -> Header? {
        guard (0..<43).contains(map.group), (0...255).contains(map.number),
              let group = rom(0x083526A8 + map.group * 4, 4),
              let pointer = rom(BoundSceneBytes.word(group) + map.number * 4, 4),
              let header = rom(BoundSceneBytes.word(pointer), 28),
              let layout = rom(BoundSceneBytes.word(header), 8) else { return nil }
        let width = BoundSceneBytes.word(layout), height = BoundSceneBytes.word(layout, 4)
        guard (1...1024).contains(width), (1...1024).contains(height) else { return nil }
        let address = BoundSceneBytes.word(header, 12)
        if address == 0 { return .init(width: width, height: height, edges: []) }
        guard let connections = rom(address, 8), (0...16).contains(BoundSceneBytes.word(connections)),
              let rows = rom(BoundSceneBytes.word(connections, 4), BoundSceneBytes.word(connections) * 12) else { return nil }
        var edges: [(Int, Int, Map)] = []
        for index in stride(from: 0, to: rows.count, by: 12) {
            let direction = BoundSceneBytes.word(rows, index)
            let offset = Int(Int32(bitPattern: UInt32(BoundSceneBytes.word(rows, index + 4))))
            guard (1...4).contains(direction), (-1024...1024).contains(offset) else { continue }
            edges.append((direction, offset, .init(group: Int(rows[index + 8]), number: Int(rows[index + 9]))))
        }
        return .init(width: width, height: height, edges: edges)
    }

    static func offsets(from source: Map, rom: (Int, Int) -> [UInt8]?) -> [Map: BoundPlayerState.Point] {
        projection(from: source, rom: rom).offsets
    }
    /// During native seam scrolling the save/header can switch one frame
    /// before ObjectEvents are rebased. Accept only a one-tile exit from a
    /// directly connected map that translates exactly onto the saved camera.
    static func pendingBoundaryOffset(in current: Map, tile: BoundPlayerState.Point,
                                      previous: BoundPlayerState.Point, camera: BoundPlayerState.Point,
                                      rom: (Int, Int) -> [UInt8]?) -> BoundPlayerState.Point? {
        guard abs(tile.x - previous.x) + abs(tile.y - previous.y) == 1,
              let currentHeader = header(current, rom: rom) else { return nil }
        var candidates = [BoundPlayerState.Point]()
        for (direction, offset, neighbor) in currentHeader.edges {
            guard let old = header(neighbor, rom: rom),
                  (0..<old.width).contains(previous.x), (0..<old.height).contains(previous.y),
                  !(0..<old.width).contains(tile.x) || !(0..<old.height).contains(tile.y) else { continue }
            let delta: BoundPlayerState.Point
            switch direction {
            case 1: delta = .init(x: offset, y: currentHeader.height)
            case 2: delta = .init(x: offset, y: -old.height)
            case 3: delta = .init(x: -old.width, y: offset)
            default: delta = .init(x: currentHeader.width, y: offset)
            }
            if tile.x + delta.x == camera.x, tile.y + delta.y == camera.y, !candidates.contains(delta) {
                candidates.append(delta)
            }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    static func projection(from source: Map, rom: (Int, Int) -> [UInt8]?) -> Projection {
        var offsets: [Map: BoundPlayerState.Point] = [source: .init(x: 0, y: 0)]
        var depths = [source: 0], queue = [source], cursor = 0, ambiguous = Set<Map>()
        while cursor < queue.count, queue.count <= 512 {
            let current = queue[cursor]; cursor += 1
            guard !ambiguous.contains(current), let origin = offsets[current], let depth = depths[current],
                  let currentHeader = header(current, rom: rom) else { continue }
            for (direction, offset, target) in currentHeader.edges {
                guard let targetHeader = header(target, rom: rom) else { continue }
                let delta: BoundPlayerState.Point
                switch direction {
                case 1: delta = .init(x: offset, y: currentHeader.height)
                case 2: delta = .init(x: offset, y: -targetHeader.height)
                case 3: delta = .init(x: -targetHeader.width, y: offset)
                default: delta = .init(x: currentHeader.width, y: offset)
                }
                let value = BoundPlayerState.Point(x: origin.x + delta.x, y: origin.y + delta.y)
                if let existing = offsets[target] {
                    if depths[target] == depth + 1, existing != value { ambiguous.insert(target) }
                } else {
                    guard queue.count < 512 else { continue }
                    offsets[target] = value; depths[target] = depth + 1; queue.append(target)
                }
            }
        }
        for key in ambiguous { offsets.removeValue(forKey: key) }
        return .init(offsets: offsets, ambiguous: ambiguous)
    }
}

enum BoundSceneBytes {
    static func word(_ b: [UInt8], _ i: Int = 0) -> Int { half(b, i) | half(b, i + 2) << 16 }
    static func half(_ b: [UInt8], _ i: Int = 0) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    static func signed(_ b: [UInt8], _ i: Int = 0) -> Int { Int(Int16(bitPattern: UInt16(half(b, i)))) }
    static func wrap(_ value: Int) -> Int { Int(Int16(truncatingIfNeeded: value)) }
}

enum BoundPlayerSceneDecoder {
    private static func sprite(_ raw: [UInt8], memory: BoundGBAMemorySnapshot,
                               rom: (Int, Int) -> [UInt8]?) -> BoundPlayerSprite? {
        let width = -Int(Int8(bitPattern: raw[0x28])) * 2, height = -Int(Int8(bitPattern: raw[0x29])) * 2
        guard [16, 32].contains(width), [16, 32].contains(height),
              BoundSceneBytes.half(raw) & 0x2F00 == 0, raw[0x3F] & 0x40 == 0,
              raw[0x3E] & 5 == 1, raw[0x2B] < 64,
              let animPointer = rom(BoundSceneBytes.word(raw, 8) + Int(raw[0x2A]) * 4, 4) else { return nil }
        let anim = BoundSceneBytes.word(animPointer)
        // At ANIM_END the visible frame is the preceding frame command.
        var imageIndex: Int?
        for index in stride(from: Int(raw[0x2B]), through: 0, by: -1) {
            guard let command = rom(anim + index * 4, 4) else { return nil }
            if BoundSceneBytes.signed(command) >= 0 { imageIndex = BoundSceneBytes.half(command); break }
        }
        guard let imageIndex, imageIndex < 64,
              let image = rom(BoundSceneBytes.word(raw, 12) + imageIndex * 8, 8),
              BoundSceneBytes.half(image, 4) == width * height / 2,
              let tiles = rom(BoundSceneBytes.word(image), width * height / 2),
              let palette = memory.bytes(at: 0x020375F8 + 512 + (BoundSceneBytes.half(raw, 4) >> 12) * 32, count: 32) else { return nil }
        return .init(width: width, height: height, tiles: Data(tiles), palette: Data(palette),
                     flipX: raw[3] & 0x10 != 0, flipY: raw[3] & 0x20 != 0,
                     priority: (BoundSceneBytes.half(raw, 4) >> 10) & 3,
                     romAddress: BoundSceneBytes.word(image))
    }

    static func camera(save: BoundPlayerState.Point, residual: BoundPlayerState.Point,
                       total: BoundPlayerState.Point, offset: BoundPlayerState.Point) -> BoundPlayerState.Point {
        func axis(_ tile: Int, _ remainder: Int, _ total: Int, _ offset: Int) -> Int {
            (7 - tile) * 16 - remainder + (remainder > 0 ? 16 : remainder < 0 ? -16 : 0)
                + BoundSceneBytes.wrap(offset - total)
        }
        return .init(x: axis(save.x, residual.x, total.x, offset.x), y: axis(save.y, residual.y, total.y, offset.y))
    }

    static func read(player: BoundPlayerState, memory: BoundGBAMemorySnapshot, profile: BoundPlayerROMProfile) -> BoundPlayerScene? {
        read(player: player, memory: memory, rom: profile.bytes, assets: profile.sceneAssets)
    }

    static func read(player: BoundPlayerState, memory: BoundGBAMemorySnapshot,
                     rom: (Int, Int) -> [UInt8]?, assets: BoundPlayerSceneAssets) -> BoundPlayerScene? {
        // Script/control locks stop movement, not the visible field or its sprites.
        guard let avatar = memory.bytes(at: 0x02037078, count: 8), avatar[0] & 0x1E == 0,
              let raw = memory.bytes(at: 0x0202063C + Int(avatar[4]) * 68, count: 68),
              let appearance = sprite(raw, memory: memory, rom: rom), appearance.width == 16, appearance.height == 32,
              BoundSceneBytes.signed(raw, 0x24) == 0, BoundSceneBytes.signed(raw, 0x26) == 0,
              let offsetBytes = memory.bytes(at: 0x02021BC8, count: 4), raw[0x3E] & 2 != 0,
              let cameraBytes = memory.bytes(at: 0x03005060, count: 16),
              let header = memory.bytes(at: 0x02036DFC, count: 4),
              let tiles = assets.tiles(layout: BoundSceneBytes.word(header), rom: rom),
              let regs = memory.bytes(at: 0x03000000, count: 0x40) else { return nil }
        let residual = BoundPlayerState.Point(x: Int(Int32(bitPattern: UInt32(BoundSceneBytes.word(cameraBytes)))),
                                             y: Int(Int32(bitPattern: UInt32(BoundSceneBytes.word(cameraBytes, 4)))))
        guard abs(residual.x) < 16, abs(residual.y) < 16 else { return nil }
        let offset = BoundPlayerState.Point(x: BoundSceneBytes.signed(offsetBytes), y: BoundSceneBytes.signed(offsetBytes, 2))
        let camera = camera(save: player.cameraTile ?? player.tile, residual: residual,
                            total: .init(x: BoundSceneBytes.signed(cameraBytes, 12), y: BoundSceneBytes.signed(cameraBytes, 8)), offset: offset)
        let foot = BoundPlayerState.Point(x: BoundSceneBytes.wrap(BoundSceneBytes.signed(raw, 0x20) + offset.x) - camera.x,
                                         y: BoundSceneBytes.wrap(BoundSceneBytes.signed(raw, 0x22) + offset.y) + 16 - camera.y)
        guard (min(player.tile.x, player.previousTile.x) * 16 + 8...max(player.tile.x, player.previousTile.x) * 16 + 8).contains(foot.x),
              (min(player.tile.y, player.previousTile.y) * 16 + 16...max(player.tile.y, player.previousTile.y) * 16 + 16).contains(foot.y) else { return nil }
        var layers: [BoundPlayerBackground.Layer] = []
        for bg in 1...2 {
            if BoundSceneBytes.half(regs) & (1 << (8 + bg)) == 0 { continue }
            let control = BoundSceneBytes.half(regs, 8 + bg * 2)
            guard control & 0xC08C == 0,
                  // Buffer2 is BG1 (foreground), Buffer1 is BG2 (middle).
                  let pointer = memory.bytes(at: bg == 1 ? 0x03005018 : 0x03005014, count: 4),
                  let map = memory.bytes(at: BoundSceneBytes.word(pointer), count: 2048) else { return nil }
            layers.append(.init(priority: control & 3, scrollX: BoundSceneBytes.half(regs, 0x10 + bg * 4),
                                scrollY: BoundSceneBytes.half(regs, 0x12 + bg * 4), map: Data(map)))
        }
        // GetBgTilemapBuffer(0) reads this native BG configuration pointer.
        // UI windows use RAM-generated tiles rather than the map tileset.
        if BoundSceneBytes.half(regs) & 0x100 != 0 {
            let control = BoundSceneBytes.half(regs, 8)
            guard control & 0xC080 == 0,
                  let pointer = memory.bytes(at: 0x030008EC, count: 4),
                  let map = memory.bytes(at: BoundSceneBytes.word(pointer), count: 2048) else { return nil }
            layers.append(.init(priority: control & 3, scrollX: BoundSceneBytes.half(regs, 0x10),
                                scrollY: BoundSceneBytes.half(regs, 0x12), map: Data(map), masksWholeTiles: true))
        }
        var objects: [BoundPlayerSceneObject] = []
        for slot in 0..<16 {
            guard let object = memory.bytes(at: 0x02036E38 + slot * 36, count: 36), object[0] & 1 != 0,
                  BoundSceneBytes.word(object) & (1 << 13) == 0, object[4] < 64,
                  let raw = memory.bytes(at: 0x0202063C + Int(object[4]) * 68, count: 68),
                  let appearance = sprite(raw, memory: memory, rom: rom) else { continue }
            let x = BoundSceneBytes.wrap(BoundSceneBytes.signed(raw, 0x20) + BoundSceneBytes.signed(raw, 0x24) + offset.x)
            let y = BoundSceneBytes.wrap(BoundSceneBytes.signed(raw, 0x22) + BoundSceneBytes.signed(raw, 0x26) + offset.y)
            objects.append(.init(origin: .init(x: x - appearance.width / 2, y: y - appearance.height / 2),
                                 footY: y + appearance.height / 2, appearance: appearance))
        }
        return .init(worldFoot: foot, camera: camera, appearance: appearance,
                     background: .init(tiles: tiles, layers: layers), objects: objects)
    }
}
