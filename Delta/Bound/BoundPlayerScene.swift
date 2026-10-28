import Foundation

/// All coordinates are native GBA pixels (240 x 160). World points are feet at
/// tile origin + (8, 16); camera translation is local and is never replayed.
struct BoundPlayerScene: Equatable, Sendable {
    let worldFoot: BoundPlayerState.Point
    let camera: BoundPlayerState.Point
    let appearance: BoundPlayerSprite
    let background: BoundPlayerBackground
    let objects: [BoundPlayerSceneObject]
    var follower: BoundPlayerFollower? = nil
    var mapInstance: UInt64? = nil
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
    private var friendRoutes: BoundFriendRouteGraph?

    /// Call while loading the ROM profile on its utility task, never per frame.
    func prepareFriendRoutes(rom: (Int, Int) -> [UInt8]?) {
        let graph = BoundFriendRouteGraph(rom: rom)
        lock.lock(); defer { lock.unlock() }
        friendRoutes = graph
    }

    /// The caller schedules this immutable-snapshot search on its utility task.
    /// Release the scene cache lock before map parsing or flood filling, so an
    /// arrow query never holds up emulation/compositor asset reads.
    func friendRouteTarget(viewer: BoundPlayerState, friendGroup: Int, friendNumber: Int,
                           friendInstance: UInt64?, friendX: Double, friendY: Double,
                           rom: (Int, Int) -> [UInt8]?) -> BoundPlayerState.Point? {
        lock.lock(); let prepared = friendRoutes; lock.unlock()
        guard let graph = prepared else { return nil }
        typealias Map = BoundPlayerMapConnections.Map
        struct FloodKey: Hashable { let map: Map; let x: Int; let y: Int; let elevation: Int }
        var maps: [Map: BoundFriendRouteAccess.MapAccess] = [:]
        var absent = Set<Map>()
        var floods: [FloodKey: Set<Int>] = [:]
        var retainedTiles = 0
        func reachable(_ map: Map, _ entry: BoundPlayerState.Point, _ elevation: Int) -> (BoundFriendRouteAccess.MapAccess, Set<Int>)? {
            guard let access = viewer.routeAccess, !absent.contains(map) else { return nil }
            if maps[map] == nil {
                guard let value = access.map(map, rom: rom) else { absent.insert(map); return nil }
                if maps.count >= 64 { maps.removeAll() }
                maps[map] = value
            }
            guard let value = maps[map] else { return nil }
            let key = FloodKey(map: map, x: entry.x, y: entry.y, elevation: elevation)
            if let cached = floods[key] { return (value, cached) }
            let tiles = value.reachable(from: entry, elevation: elevation)
            if floods.count >= 32 || retainedTiles + tiles.count > 500_000 {
                floods.removeAll(); retainedTiles = 0
            }
            if tiles.count <= 500_000 { floods[key] = tiles; retainedTiles += tiles.count }
            return (value, tiles)
        }
        let resolved = graph.target(viewer: viewer, friendGroup: friendGroup, friendNumber: friendNumber,
            friendInstance: friendInstance, friendX: friendX, friendY: friendY,
            canArrive: { map, entry, elevation in
                guard let (value, tiles) = reachable(map, entry, elevation) else { return false }
                let tile = BoundPlayerState.Point(x: Int(floor((friendX - 8) / 16)), y: Int(floor((friendY - 16) / 16)))
                return value.canReachTarget(tile, reachable: tiles)
            }, canTraverse: { map, entry, edge in
                guard let (value, tiles) = reachable(map, entry, edge.sourceElevation) else { return false }
                return value.canReachTarget(edge.waypoint(from: entry), reachable: tiles, doorway: edge.direction == 0)
            })
        if let resolved { return resolved }
        // Remote entry scripts may depend on native effects that cannot be
        // projected from this map. Give directions to a reachable local exit;
        // recompute from actual terrain after crossing it. This is advisory UI,
        // never movement permission or a promise that every later door is open.
        return graph.target(viewer: viewer, friendGroup: friendGroup, friendNumber: friendNumber,
            friendInstance: friendInstance, friendX: friendX, friendY: friendY,
            canTraverse: { map, entry, edge in
                guard map == .init(group: viewer.mapGroup, number: viewer.mapNumber) else { return true }
                guard let (value, tiles) = reachable(map, entry, edge.sourceElevation) else { return false }
                return value.canReachTarget(edge.waypoint(from: entry), reachable: tiles, doorway: edge.direction == 0)
            })
    }

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

/// Read-only navigation over the verified cartridge's native map headers.
/// A portal is a hint, never permission to enter a map or bypass a story gate.
struct BoundFriendRouteGraph: Sendable {
    typealias Map = BoundPlayerMapConnections.Map
    struct Edge: Sendable {
        var destination: Map
        let tile: BoundPlayerState.Point
        var sourceWarpID: Int = -1
        var arrivalWarpID: Int = -1
        var arrivalTile: BoundPlayerState.Point? = nil
        var dynamicExit: Bool = false
        var setsDynamicReturn: Bool = false
        var sourceElevation: Int = 0
        var arrivalElevation: Int = 0
        var connectionOffset: Int = 0
        // Cardinal exits track the player's position along the shared seam.
        var direction: Int = 0
        var lower: Int = 0
        var upper: Int = 0
        func waypoint(from tile: BoundPlayerState.Point) -> BoundPlayerState.Point {
            switch direction {
            case 1, 2: return .init(x: min(upper, max(lower, tile.x)), y: self.tile.y)
            case 3, 4: return .init(x: self.tile.x, y: min(upper, max(lower, tile.y)))
            default: return self.tile
            }
        }
    }
    struct Node: Sendable {
        let instance: UInt64
        let width: Int
        let height: Int
        var edges: [Edge]
        var warpTiles: [Int: BoundPlayerState.Point] = [:]
        var warpElevations: [Int: Int] = [:]
    }
    private struct Warp {
        let tile: BoundPlayerState.Point
        let destination: Map
        let index: Int
        let slot: Int
        let elevation: Int
    }
    let nodes: [Map: Node]
    private let reverse: [Map: [Map]]

    init(rom: (Int, Int) -> [UInt8]?) {
        var nodes: [Map: Node] = [:], warps: [Map: [Warp]] = [:], connections: [Map: [UInt8]] = [:]
        // Bound contiguous tables at the next group's pointer (or the group
        // table itself). Relocated extended tables stop at their first invalid
        // header. Never let one group's index alias the next group's maps.
        let tableAddress = 0x083526A8
        let tableStarts = (0..<43).compactMap { group in
            rom(tableAddress + group * 4, 4).map { BoundSceneBytes.word($0) }
        } + [tableAddress]
        for group in 0..<43 {
            guard let groupPointer = rom(0x083526A8 + group * 4, 4) else { continue }
            let base = BoundSceneBytes.word(groupPointer)
            guard (0x08000000..<0x0A000000).contains(base), base & 3 == 0 else { continue }
            let end = tableStarts.filter { $0 > base }.min() ?? base + 256 * 4
            let count = min(256, (end - base) / 4)
            for number in 0..<count {
                guard let pointer = rom(base + number * 4, 4) else { break }
                let address = BoundSceneBytes.word(pointer)
                guard address & 3 == 0, (0x08000000..<0x0A000000).contains(address),
                      let header = rom(address, 28) else { break }
                let layoutAddress = BoundSceneBytes.word(header)
                guard let layout = rom(layoutAddress, 24) else { break }
                let width = BoundSceneBytes.word(layout), height = BoundSceneBytes.word(layout, 4)
                guard (1...1024).contains(width), (1...1024).contains(height),
                      let events = rom(BoundSceneBytes.word(header, 4), 20) else { break }
                let rows: [UInt8]
                if events[1] == 0 { rows = [] }
                else if let bytes = rom(BoundSceneBytes.word(events, 8), Int(events[1]) * 8) { rows = bytes }
                else { break }
                let map = Map(group: group, number: number)
                nodes[map] = .init(instance: UInt64(address) << 32 | UInt64(layoutAddress), width: width, height: height, edges: [])
                warps[map] = stride(from: 0, to: rows.count, by: 8).compactMap { index in
                    let x = BoundSceneBytes.signed(rows, index), y = BoundSceneBytes.signed(rows, index + 2)
                    guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
                    return Warp(tile: .init(x: x, y: y), destination: .init(group: Int(rows[index + 7]), number: Int(rows[index + 6])), index: Int(rows[index + 5]), slot: index / 8, elevation: Int(rows[index + 4]))
                }
                let connectionAddress = BoundSceneBytes.word(header, 12)
                if connectionAddress != 0, let table = rom(connectionAddress, 8) {
                    let count = BoundSceneBytes.word(table)
                    if (0...16).contains(count) { connections[map] = rom(BoundSceneBytes.word(table, 4), count * 12) }
                }
            }
        }
        for (map, values) in warps {
            nodes[map]?.warpTiles = Dictionary(uniqueKeysWithValues: values.map { ($0.slot, $0.tile) })
            nodes[map]?.warpElevations = Dictionary(uniqueKeysWithValues: values.map { ($0.slot, $0.elevation) })
            for warp in values {
                if warp.destination.number == 127 {
                    nodes[map]?.edges.append(.init(destination: warp.destination, tile: warp.tile,
                        sourceWarpID: warp.slot, dynamicExit: true, sourceElevation: warp.elevation))
                } else if let arrival = warps[warp.destination]?.first(where: { $0.slot == warp.index }) {
                    nodes[map]?.edges.append(.init(destination: warp.destination, tile: warp.tile,
                        sourceWarpID: warp.slot, arrivalWarpID: warp.index, arrivalTile: arrival.tile,
                        setsDynamicReturn: arrival.destination.number == 127,
                        sourceElevation: warp.elevation, arrivalElevation: arrival.elevation))
                }
            }
        }
        for (map, rows) in connections {
            guard let node = nodes[map] else { continue }
            for index in stride(from: 0, to: rows.count, by: 12) {
                let direction = BoundSceneBytes.word(rows, index)
                let offset = Int(Int32(bitPattern: UInt32(BoundSceneBytes.word(rows, index + 4))))
                let destination = Map(group: Int(rows[index + 8]), number: Int(rows[index + 9]))
                guard let target = nodes[destination], (-1024...1024).contains(offset) else { continue }
                let extent = direction <= 2 ? node.width : node.height
                let otherExtent = direction <= 2 ? target.width : target.height
                let lower = max(0, offset), upper = min(extent - 1, offset + otherExtent - 1)
                guard (1...4).contains(direction), lower <= upper else { continue }
                let tile: BoundPlayerState.Point
                switch direction {
                case 1: tile = .init(x: 0, y: node.height)
                case 2: tile = .init(x: 0, y: -1)
                case 3: tile = .init(x: -1, y: 0)
                default: tile = .init(x: node.width, y: 0)
                }
                nodes[map]?.edges.append(.init(destination: destination, tile: tile, connectionOffset: offset, direction: direction, lower: lower, upper: upper))
            }
        }
        self.nodes = nodes
        var reverse: [Map: [Map]] = [:]
        for (source, node) in nodes { for edge in node.edges where !edge.dynamicExit { reverse[edge.destination, default: []].append(source) } }
        self.reverse = reverse
    }

    func distances(to target: Map) -> [Map: Int] {
        guard nodes[target] != nil else { return [:] }
        var result = [target: 0], queue = [target], cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]; cursor += 1
            for predecessor in reverse[current] ?? [] where result[predecessor] == nil {
                result[predecessor] = result[current]! + 1; queue.append(predecessor)
            }
        }
        return result
    }

    /// Searches actual arrival regions, carrying the ROM's dynamic return warp
    /// through doors and stairs exactly as native SetupWarp does. No static
    /// reverse edge is guessed for shared rooms or elevators.
    func target(viewer: BoundPlayerState, friendGroup: Int, friendNumber: Int, friendInstance: UInt64?,
                friendX: Double, friendY: Double, distances: [Map: Int] = [:],
                canArrive: (Map, BoundPlayerState.Point, Int) -> Bool = { _, _, _ in true },
                canTraverse: (Map, BoundPlayerState.Point, Edge) -> Bool = { _, _, _ in true }) -> BoundPlayerState.Point? {
        let source = Map(group: viewer.mapGroup, number: viewer.mapNumber), destination = Map(group: friendGroup, number: friendNumber)
        guard let node = nodes[source], node.instance == viewer.mapInstance,
              let target = nodes[destination], target.instance == friendInstance,
              friendX.isFinite, friendY.isFinite,
              (-104...Double(target.width * 16 + 40)).contains(friendX),
              (-96...Double(target.height * 16 + 48)).contains(friendY) else { return nil }
        if source == destination {
            return .init(x: Int(friendX.rounded()), y: Int(friendY.rounded()))
        }
        let initial = RouteState(map: source, x: viewer.tile.x, y: viewer.tile.y, elevation: viewer.elevation,
            returnWarp: normalized(viewer.dynamicWarp))
        var visited: Set<RouteState> = [initial]
        var queue: [(RouteState, BoundPlayerState.Point?)] = [(initial, nil)], cursor = 0
        while cursor < queue.count, queue.count <= 8192 {
            if Task.isCancelled { return nil }
            let (state, first) = queue[cursor]; cursor += 1
            guard let current = nodes[state.map] else { continue }
            // A connected border often contains trees/walls except for a small
            // gap. Test the full native overlap instead of aiming blindly at
            // the coordinate nearest the local player.
            let candidates = current.edges.flatMap { edge -> [Edge] in
                guard edge.direction != 0 else { return [edge] }
                return (edge.lower...edge.upper).map { coordinate in
                    var candidate = edge; candidate.lower = coordinate; candidate.upper = coordinate
                    return candidate
                }
            }
            let ordered = candidates.sorted { a, b in
                let pa = a.waypoint(from: state.entry), pb = b.waypoint(from: state.entry)
                let da = abs(pa.x - state.x) + abs(pa.y - state.y), db = abs(pb.x - state.x) + abs(pb.y - state.y)
                if da != db { return da < db }
                if pa.y != pb.y { return pa.y < pb.y }
                if pa.x != pb.x { return pa.x < pb.x }
                if a.destination.group != b.destination.group { return a.destination.group < b.destination.group }
                return a.destination.number < b.destination.number
            }
            for original in ordered {
                var edge = original
                let portal = edge.waypoint(from: state.entry)
                var returnWarp = state.returnWarp
                let arrival: BoundPlayerState.Point
                if edge.dynamicExit {
                    guard let saved = state.returnWarp,
                          let resolved = resolve(saved) else { continue }
                    edge.destination = resolved.map; arrival = resolved.tile
                    edge.arrivalWarpID = saved.warpID; edge.arrivalTile = arrival
                    edge.arrivalElevation = resolved.elevation
                } else if edge.direction != 0 {
                    guard let next = nodes[edge.destination] else { continue }
                    switch edge.direction {
                    case 1: arrival = .init(x: portal.x - edge.connectionOffset, y: 0)
                    case 2: arrival = .init(x: portal.x - edge.connectionOffset, y: next.height - 1)
                    case 3: arrival = .init(x: next.width - 1, y: portal.y - edge.connectionOffset)
                    default: arrival = .init(x: 0, y: portal.y - edge.connectionOffset)
                    }
                    edge.arrivalTile = arrival; edge.arrivalElevation = state.elevation
                } else {
                    guard let tile = edge.arrivalTile else { continue }; arrival = tile
                    if edge.setsDynamicReturn {
                        returnWarp = .init(mapGroup: state.map.group, mapNumber: state.map.number,
                            warpID: edge.sourceWarpID, x: 0, y: 0)
                    }
                }
                edge.sourceElevation = state.elevation
                guard let next = nodes[edge.destination],
                      (0..<next.width).contains(arrival.x), (0..<next.height).contains(arrival.y),
                      canTraverse(state.map, state.entry, edge) else { continue }
                let initialPortal = first ?? portal
                if edge.destination == destination && canArrive(edge.destination, arrival, edge.arrivalElevation) {
                    return .init(x: initialPortal.x * 16 + 8, y: initialPortal.y * 16 + 16)
                }
                let following = RouteState(map: edge.destination, x: arrival.x, y: arrival.y,
                    elevation: edge.arrivalElevation, returnWarp: normalized(returnWarp))
                if visited.insert(following).inserted { queue.append((following, initialPortal)) }
            }
        }
        return nil
    }

    private struct RouteState: Hashable {
        let map: Map
        let x: Int
        let y: Int
        let elevation: Int
        let returnWarp: BoundPlayerState.DynamicWarp?
        var entry: BoundPlayerState.Point { .init(x: x, y: y) }
    }
    private func normalized(_ warp: BoundPlayerState.DynamicWarp?) -> BoundPlayerState.DynamicWarp? {
        guard let warp, resolve(warp) != nil else { return nil }
        if warp.warpID >= 0 {
            return .init(mapGroup: warp.mapGroup, mapNumber: warp.mapNumber, warpID: warp.warpID, x: 0, y: 0)
        }
        return warp
    }
    private func resolve(_ warp: BoundPlayerState.DynamicWarp) -> (map: Map, tile: BoundPlayerState.Point, elevation: Int)? {
        let map = Map(group: warp.mapGroup, number: warp.mapNumber)
        guard let node = nodes[map] else { return nil }
        if warp.warpID >= 0 {
            guard let tile = node.warpTiles[warp.warpID] else { return nil }
            return (map, tile, node.warpElevations[warp.warpID] ?? 0)
        }
        guard warp.warpID == -1, (0..<node.width).contains(warp.x), (0..<node.height).contains(warp.y) else { return nil }
        return (map, .init(x: warp.x, y: warp.y), 0)
    }

}

/// Native cardinal connections define where adjoining maps are drawn. These
/// are viewer-relative translations, not a fabricated global coordinate grid:
/// some cartridge loops have inconsistent offsets, so nearer connections win
/// and equally short conflicting paths are withheld. Doors/dive/warps never
/// connect unrelated rooms for presentation or interaction authority.
enum BoundPlayerMapConnections {
    struct Map: Hashable, Sendable { let group: Int; let number: Int }
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
    /// directly connected map whose destination or previous tile translates
    /// exactly onto the saved camera (which can itself still be one step late).
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
            let destinationMatches = tile.x + delta.x == camera.x && tile.y + delta.y == camera.y
            let previousMatches = previous.x + delta.x == camera.x && previous.y + delta.y == camera.y
            if (destinationMatches || previousMatches), !candidates.contains(delta) {
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
        guard [8, 16, 32, 64].contains(width), [8, 16, 32, 64].contains(height),
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
              let palette = memory.bytes(at: 0x05000200 + (BoundSceneBytes.half(raw, 4) >> 12) * 32, count: 32)
                ?? memory.bytes(at: 0x020375F8 + 512 + (BoundSceneBytes.half(raw, 4) >> 12) * 32, count: 32) else { return nil }
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
        let followerBinding:BoundNativeFollowerBinding?
        if let observation=memory.followerObservation {
            followerBinding=observation.cache.read(memory:memory,player:player,scope:observation.scope)
        } else { followerBinding=BoundNativeFollowerBinding.read(memory:memory,player:player) }
        var follower: BoundPlayerFollower?
        for slot in 0..<16 {
            guard let object = memory.bytes(at: 0x02036E38 + slot * 36, count: 36), object[0] & 1 != 0,
                  BoundSceneBytes.word(object) & (1 << 13) == 0, object[4] < 64,
                  let raw = memory.bytes(at: 0x0202063C + Int(object[4]) * 68, count: 68),
                  let appearance = sprite(raw, memory: memory, rom: rom) else { continue }
            let x = BoundSceneBytes.wrap(BoundSceneBytes.signed(raw, 0x20) + BoundSceneBytes.signed(raw, 0x24) + offset.x)
            let y = BoundSceneBytes.wrap(BoundSceneBytes.signed(raw, 0x22) + BoundSceneBytes.signed(raw, 0x26) + offset.y)
            objects.append(.init(origin: .init(x: x - appearance.width / 2, y: y - appearance.height / 2),
                                 footY: y + appearance.height / 2, appearance: appearance))
            if let binding=followerBinding,binding.objectID==slot {
                follower = .init(identity:binding.identity,species:binding.species,objectID:slot,generation:binding.generation,
                    current:binding.current,previous:binding.previous,
                    worldFoot:.init(x:x-camera.x,y:y+appearance.height/2-camera.y),
                    elevation:binding.elevation,facing:binding.facing,appearance:appearance)
            }
        }
        return .init(worldFoot: foot, camera: camera, appearance: appearance,
                     background: .init(tiles: tiles, layers: layers), objects: objects,
                     follower:follower,mapInstance:player.mapInstance)
    }
}
