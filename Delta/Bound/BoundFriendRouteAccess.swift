import Foundation

/// Immutable, read-only native navigation evidence. None of these values grant
/// gameplay authority or execute a script. Unknown scripts are not traversable.
struct BoundFriendRouteAccess: Equatable, Sendable {
    typealias Map = BoundPlayerMapConnections.Map
    typealias Point = BoundPlayerState.Point
    struct Object: Equatable, Sendable {
        let localID: Int
        let map: Map
        let tile: Point
        let previous: Point
        let elevation: Int
    }
    let currentMap: Map
    let flags: [UInt8]
    let expandedFlags: [UInt8]
    let variables: [UInt8]
    let expandedVariables: [UInt8]
    let specialVariables: [UInt8]
    let specialFlags: [UInt8]
    let gridWidth: Int
    let gridHeight: Int
    let grid: [UInt16]
    let templates: [UInt8]
    let objects: [Object]
    var wonderCardFlagID: Int? = nil

    static func capture(memory: BoundGBAMemorySnapshot, save: Int, currentMap: Map,
                        rom: (Int, Int) -> [UInt8]?) -> Self? {
        guard let flags = memory.bytes(at: save + 0xEE0, count: 0x120),
              let expandedFlags = memory.bytes(at: 0x0203B174, count: 0x200),
              let variables = memory.bytes(at: save + 0x1000, count: 0x200),
              let expandedVariables = memory.bytes(at: 0x0203B374, count: 0x400),
              let specialVariablePointers = rom(0x0806E754, 21 * 4),
              let specialFlags = memory.bytes(at: 0x020370E0, count: 1),
              let templates = memory.bytes(at: save + 0x8E0, count: 64 * 24),
              let rawObjects = memory.bytes(at: 0x02036E38, count: 16 * 36),
              let virtualMap = memory.bytes(at: 0x03005040, count: 12),
              let header = mapHeader(currentMap, rom: rom), let layout = rom(word(header), 24) else { return nil }
        // Native special IDs use a ROM pointer table, not contiguous RAM order:
        // VAR_RESULT, FACING and ITEM_ID notably point elsewhere.
        var specialVariables: [UInt8] = []
        for index in 0..<21 {
            guard let value = memory.bytes(at: word(specialVariablePointers, index * 4), count: 2) else { return nil }
            specialVariables.append(contentsOf: value)
        }
        let width = word(virtualMap), height = word(virtualMap, 4)
        guard width == word(layout) + 15, height == word(layout, 4) + 14,
              width > 15, height > 14, width * height <= 0x2800,
              let bytes = memory.bytes(at: word(virtualMap, 8), count: width * height * 2) else { return nil }
        let grid = stride(from: 0, to: bytes.count, by: 2).map { UInt16(half(bytes, $0)) }
        let objects = stride(from: 0, to: rawObjects.count, by: 36).compactMap { offset -> Object? in
            // Invisible/offscreen native objects still collide. The player does
            // not block their own flood field, nor destabilize its cache key.
            guard rawObjects[offset] & 1 != 0, rawObjects[offset + 2] & 1 == 0 else { return nil }
            return Object(localID: Int(rawObjects[offset + 8]),
                map: .init(group: Int(rawObjects[offset + 10]), number: Int(rawObjects[offset + 9])),
                tile: .init(x: signed(rawObjects, offset + 16) - 7, y: signed(rawObjects, offset + 18) - 7),
                previous: .init(x: signed(rawObjects, offset + 20) - 7, y: signed(rawObjects, offset + 22) - 7),
                elevation: Int(rawObjects[offset + 11] & 15))
        }
        return .init(currentMap: currentMap, flags: flags, expandedFlags: expandedFlags, variables: variables,
            expandedVariables: expandedVariables, specialVariables: specialVariables, specialFlags: specialFlags,
            gridWidth: width, gridHeight: height, grid: grid, templates: templates, objects: objects,
            wonderCardFlagID: memory.bytes(at: save + 0x32E4, count: 2).map { half($0) })
    }

    /// Changes to native progression, temporary scene state, or native grid are
    /// separate from moving-NPC occupancy and invalidate routing immediately.
    func hasSameProgression(as other: Self) -> Bool {
        currentMap == other.currentMap && flags == other.flags && expandedFlags == other.expandedFlags &&
        variables == other.variables && expandedVariables == other.expandedVariables &&
        specialVariables == other.specialVariables && specialFlags == other.specialFlags &&
        gridWidth == other.gridWidth && gridHeight == other.gridHeight && grid == other.grid && templates == other.templates &&
        wonderCardFlagID == other.wonderCardFlagID
    }

    func flag(_ id: Int, on map: Map) -> Bool? {
        if id == 0 { return false }
        // Temporary flags/variables are reset and then set by map scripts. Their
        // current-map values cannot be transplanted into another room.
        if map != currentMap && id < 0x20 { return nil }
        if (1..<0x900).contains(id) { return flags[id / 8] & (1 << (id & 7)) != 0 }
        if (0x900..<0x1900).contains(id) { return expandedFlags[(id - 0x900) / 8] & (1 << (id & 7)) != 0 }
        if (0x4000..<0x4008).contains(id), map == currentMap { return specialFlags[0] & (1 << (id & 7)) != 0 }
        return nil
    }

    func variable(_ id: Int, on map: Map) -> Int? {
        if id < 0x4000 { return id }
        if (0x4000..<0x4010).contains(id), map != currentMap { return nil }
        if (0x4000..<0x4100).contains(id) { return Self.half(variables, (id - 0x4000) * 2) }
        if (0x5000..<0x5200).contains(id) { return Self.half(expandedVariables, (id - 0x5000) * 2) }
        if (0x8000...0x8014).contains(id), map == currentMap, (id - 0x8000) * 2 + 2 <= specialVariables.count { return Self.half(specialVariables, (id - 0x8000) * 2) }
        return nil
    }

    struct MapAccess: Sendable {
        let width: Int
        let height: Int
        let cells: [UInt16]
        let behaviors: [UInt8]
        let objects: [Object]
        let blockedScripts: Set<Int>
        let warps: Set<Int>
        var borderCells: [Int: UInt16] = [:]

        func reachable(from start: Point, elevation: Int = 0) -> Set<Int> {
            guard (0..<width).contains(start.x), (0..<height).contains(start.y) else { return [] }
            let count = width * height, initial = start.y * width + start.x
            let initialCellLevel = Int(cells[initial] >> 12)
            let initialLevel = elevation == 0 && initialCellLevel != 15 ? initialCellLevel : max(0, min(15, elevation))
            var visited: Set<Int> = [initialLevel * count + initial]
            var result: Set<Int> = [initial], queue = [(initial, initialLevel)], cursor = 0
            let moves = [(0, 1, 1), (0, -1, 2), (-1, 0, 3), (1, 0, 4)]
            while cursor < queue.count, queue.count <= count * 16 {
                if cursor & 255 == 0, Task.isCancelled { return [] }
                let (index, level) = queue[cursor]; cursor += 1
                if index != initial, warps.contains(index) { continue }
                for (dx, dy, direction) in moves {
                    let x = index % width + dx, y = index / width + dy
                    guard (0..<width).contains(x), (0..<height).contains(y) else { continue }
                    let next = y * width + x, cell = cells[next], behavior = Int(behaviors[next])
                    guard cell != 0x3FF, cell & 0xC00 == 0, !blockedScripts.contains(next),
                          !Self.blocks(behavior: Int(behaviors[index]), toward: direction),
                          !Self.blocks(behavior: behavior, toward: Self.opposite(direction)),
                          // Currents, spin tiles, ice and ledges have native
                          // forced movement. Never model them as ordinary floor.
                          ![0x10,0x11,0x12,0x13,0x15,0x19,0x1A,0x1B,0x23,0x26,0x27].contains(behavior),
                          !(0x38...0x58).contains(behavior) else { continue }
                    let destinationLevel = Int(cell >> 12)
                    guard level == 0 || destinationLevel == 0 || destinationLevel == 15 || destinationLevel == level else { continue }
                    let nextLevel = destinationLevel == 0 || destinationLevel == 15 ? level : destinationLevel
                    guard !objects.contains(where: { object in
                        (object.elevation == 0 || nextLevel == 0 || object.elevation == nextLevel) &&
                        ((object.tile.x == x && object.tile.y == y) || (object.previous.x == x && object.previous.y == y))
                    }) else { continue }
                    result.insert(next)
                    if visited.insert(nextLevel * count + next).inserted { queue.append((next, nextLevel)) }
                }
            }
            return result
        }

        func canReachTarget(_ target: Point, reachable: Set<Int>, doorway: Bool = false) -> Bool {
            if (0..<width).contains(target.x), (0..<height).contains(target.y) {
                let index = target.y * width + target.x
                if reachable.contains(index) { return true }
                // Native door entry is attempted northward before ordinary
                // collision. No generic adjacent-wall exception is permitted.
                guard doorway, behaviors[index] == 0x69, !blockedScripts.contains(index),
                      !objects.contains(where: { $0.tile == target || $0.previous == target }), target.y + 1 < height else { return false }
                return reachable.contains((target.y + 1) * width + target.x)
            }
            guard (target.x == -1 || target.x == width) && (0..<height).contains(target.y) ||
                  (target.y == -1 || target.y == height) && (0..<width).contains(target.x) else { return false }
            let x = min(width - 1, max(0, target.x)), y = min(height - 1, max(0, target.y))
            guard reachable.contains(y * width + x) else { return false }
            if let cell = borderCells[target.y * (width + 2) + target.x] { return cell != 0x3FF && cell & 0xC00 == 0 }
            return true
        }

        private static func opposite(_ direction: Int) -> Int { direction == 1 ? 2 : direction == 2 ? 1 : direction == 3 ? 4 : 3 }
        private static func blocks(behavior: Int, toward direction: Int) -> Bool {
            switch direction {
            case 1: return [0x33,0x36,0x37].contains(behavior)
            case 2: return [0x32,0x34,0x35].contains(behavior)
            case 3: return [0x31,0x35,0x37].contains(behavior)
            default: return [0x30,0x34,0x36].contains(behavior)
            }
        }
    }

    func map(_ map: Map, rom: (Int, Int) -> [UInt8]?) -> MapAccess? {
        guard !Task.isCancelled else { return nil }
        guard let header = Self.mapHeader(map, rom: rom), let layout = rom(Self.word(header), 24),
              let events = rom(Self.word(header, 4), 20) else { return nil }
        let width = Self.word(layout), height = Self.word(layout, 4)
        guard (1...1024).contains(width), (1...1024).contains(height), width * height <= 0x2800,
              let rawCells = rom(Self.word(layout, 12), width * height * 2),
              let primary = rom(Self.word(layout, 16), 24), let secondary = rom(Self.word(layout, 20), 24) else { return nil }
        var cells = stride(from: 0, to: rawCells.count, by: 2).map { UInt16(Self.half(rawCells, $0)) }
        if map == currentMap {
            guard gridWidth == width + 15, gridHeight == height + 14 else { return nil }
            for y in 0..<height { for x in 0..<width { cells[y * width + x] = grid[(y + 7) * gridWidth + x + 7] } }
        }
        var projection = ScriptProjection()
        if map != currentMap {
            for id in 0x4000..<0x4010 { projection.variables[id] = 0 }
            for id in 1..<0x20 { projection.flags[id] = false }
            for id in [0x803,0x804,0x805,0x807,0x842] { projection.flags[id] = false }
            // Map entry runs transition, native InitMap/on-load, warp table,
            // resume, then the frame table. Unknown native effects cannot be
            // used as evidence that a remote room's static grid is open.
            let table = Self.word(header, 8)
            if table != 0 {
                var scripts: [Int: Int] = [:], ended = false
                for index in 0..<32 {
                    guard let tag = rom(table + index * 5, 1)?.first else { return nil }
                    if tag == 0 { ended = true; break }
                    guard let pointer = rom(table + index * 5 + 1, 4), scripts[Int(tag)] == nil else { return nil }
                    scripts[Int(tag)] = Self.word(pointer)
                }
                guard ended else { return nil }
                for tag in [3,1,4,5,2] {
                    guard !Task.isCancelled else { return nil }
                    guard var script = scripts[tag] else { continue }
                    if tag == 2 || tag == 4 {
                        var selected: Int?, terminated = false
                        for index in 0..<64 {
                            guard let first = rom(script + index * 8, 2) else { return nil }
                            if Self.half(first) == 0 { terminated = true; break }
                            guard let row = rom(script + index * 8, 8),
                                  let a = projectedVariable(Self.half(row), on: map, projection: projection),
                                  let b = projectedVariable(Self.half(row, 2), on: map, projection: projection) else { return nil }
                            if a == b { selected = Self.word(row, 4); terminated = true; break }
                        }
                        guard terminated else { return nil }
                        guard let selected else { continue }; script = selected
                    }
                    guard evaluateScript(script, on: map, projecting: true, projection: &projection, rom: rom) else { return nil }
                }
            }
            for (index, value) in projection.tiles {
                let x = index & 0xFFFF, y = index >> 16
                guard x < width, y < height else { return nil }
                cells[y * width + x] = (cells[y * width + x] & 0xF000) | value
            }
        }
        var behaviorCache: [Int: UInt8] = [:], behaviors: [UInt8] = []
        for cell in cells {
            let metatile = Int(cell & 0x3FF)
            if let cached = behaviorCache[metatile] { behaviors.append(cached); continue }
            let tileset = metatile < 640 ? primary : secondary, index = metatile < 640 ? metatile : metatile - 640
            guard let attribute = rom(Self.word(tileset, 20) + index * 4, 4) else { return nil }
            let behavior = attribute[0] // native MapGridGetMetatileBehaviorAt returns u8
            behaviorCache[metatile] = behavior; behaviors.append(behavior)
        }
        let templateCount = Int(events[0])
        guard templateCount <= 64 else { return nil }
        let templateRows: [UInt8]
        if map == currentMap { templateRows = Array(templates.prefix(templateCount * 24)) }
        else if templateCount == 0 { templateRows = [] }
        else if let rows = rom(Self.word(events, 4), templateCount * 24) { templateRows = rows }
        else { return nil }
        var blockers = map == currentMap ? objects : []
        for offset in stride(from: 0, to: templateRows.count, by: 24) {
            let row = Array(templateRows[offset..<offset + 24]), localID = Int(row[0])
            if map == currentMap && objects.contains(where: { $0.localID == localID && $0.map == map }) { continue }
            if projection.hiddenObjects.contains(localID) { continue }
            if !projection.shownObjects.contains(localID), projectedFlag(Self.half(row, 22), on: map, projection: projection) == true { continue }
            let tile = projection.objectPositions[localID] ?? Point(x: Self.signed(row, 4), y: Self.signed(row, 6))
            guard (0..<width).contains(tile.x), (0..<height).contains(tile.y) else { continue }
            blockers.append(.init(localID: localID, map: map, tile: tile, previous: tile, elevation: Int(row[8] & 15)))
        }
        var blockedScripts: Set<Int> = []
        let coordCount = Int(events[2])
        if coordCount > 0 {
            guard let rows = rom(Self.word(events, 12), coordCount * 16) else { return nil }
            for offset in stride(from: 0, to: rows.count, by: 16) {
                let x = Self.half(rows, offset), y = Self.half(rows, offset + 2), script = Self.word(rows, offset + 12)
                guard x < width, y < height, script != 0 else { continue }
                let trigger = Self.half(rows, offset + 6), value = Self.half(rows, offset + 8) & 255
                if trigger != 0, let actual = projectedVariable(trigger, on: map, projection: projection), actual != value { continue }
                var coordinateProjection = projection
                if !evaluateScript(script, on: map, projecting: false, projection: &coordinateProjection, rom: rom) { blockedScripts.insert(y * width + x) }
            }
        }
        var warps: Set<Int> = []
        if events[1] > 0 {
            guard let rows = rom(Self.word(events, 8), Int(events[1]) * 8) else { return nil }
            for offset in stride(from: 0, to: rows.count, by: 8) {
                let x = Self.signed(rows, offset), y = Self.signed(rows, offset + 2)
                if (0..<width).contains(x), (0..<height).contains(y) { warps.insert(y * width + x) }
            }
        }
        var result = MapAccess(width: width, height: height, cells: cells, behaviors: behaviors,
            objects: blockers, blockedScripts: blockedScripts, warps: warps)
        if map == currentMap {
            for y in -1...height { for x in -1...width where x == -1 || x == width || y == -1 || y == height {
                result.borderCells[y * (width + 2) + x] = grid[(y + 7) * gridWidth + x + 7]
            } }
        }
        return result
    }

    /// The interpreter recognizes only verified native branch/predicate and
    /// presentation commands. It never calls native code or mutates RAM/save.
    /// Movement, battles, specials, arbitrary memory reads and unknown handlers
    /// are deliberately unknown rather than guessed to be an unlocked route.
    func scriptAllowsPassage(_ address: Int, on map: Map, rom: (Int, Int) -> [UInt8]?) -> Bool {
        var projection = ScriptProjection()
        return evaluateScript(address, on: map, projecting: false, projection: &projection, rom: rom)
    }

    private struct ScriptProjection {
        var variables: [Int: Int] = [:]
        var flags: [Int: Bool] = [:]
        var tiles: [Int: UInt16] = [:]
        var hiddenObjects: Set<Int> = []
        var shownObjects: Set<Int> = []
        var objectPositions: [Int: Point] = [:]
    }
    private func projectedVariable(_ id: Int, on map: Map, projection: ScriptProjection) -> Int? {
        projection.variables[id] ?? variable(id, on: map)
    }
    private func projectedFlag(_ id: Int, on map: Map, projection: ScriptProjection) -> Bool? {
        id == 0 ? false : projection.flags[id] ?? flag(id, on: map)
    }
    private func evaluateScript(_ address: Int, on map: Map, projecting: Bool,
                                projection: inout ScriptProjection, rom: (Int, Int) -> [UInt8]?) -> Bool {
        let handlers = [0x02:0x08069ED9,0x03:0x08069FC9,0x04:0x08069FD5,0x05:0x08069FB1,
            0x06:0x08069FED,0x07:0x0806A029,0x21:0x0806A521,0x22:0x0806A551,0x2B:0x0806A855,
            0x69:0x0806B6DD,0x6A:0x0806B705,0x6B:0x0806B75D,0x6C:0x0806B795,
            0x66:0x0806B879,0x68:0x0806B88D,
            0x16:0x0806A391,0x17:0x0806A585,0x18:0x0806A5AD,0x19:0x0806A3B5,0x1A:0x0806A3E1,
            0x29:0x0806A82D,0x2A:0x0806A841,0x53:0x0806B359,0x55:0x0806B3B1,
            0x57:0x0806B409,0x63:0x0806B471,0xA2:0x0806C555,
            0x0F:0x0806A2B5,0x2F:0x0806B069,0x33:0x0806B0E1,0x37:0x0806B17D,
            0x5B:0x0806B5F5,0x7F:0x0806BD15,0x84:0x0806BED5,0x9F:0x0806C4D5,
            0xA3:0x0806AA19,0xA4:0x0806A9FD,0xA5:0x0806AA25,0xC7:0x0806B7ED,0xD0:0x0806A8C1,
            0x26:0x08069F3D]
        var pc = address, stack: [Int] = [], comparison: Int?
        for _ in 0..<256 {
            guard !Task.isCancelled else { return false }
            guard let opcode = rom(pc, 1)?.first, let expected = handlers[Int(opcode)],
                  let handler = rom(0x0815F9B4 + Int(opcode) * 4, 4), Self.word(handler) == expected else { return false }
            pc += 1
            switch opcode {
            case 0x02: return true
            case 0x03:
                guard let next = stack.popLast() else { return true }; pc = next
            case 0x04,0x05:
                guard let pointer = rom(pc, 4), stack.count < 16 else { return false }
                if opcode == 0x04 { stack.append(pc + 4) }; pc = Self.word(pointer)
            case 0x06,0x07:
                guard let args = rom(pc, 5), let comparison, args[0] < 6 else { return false }
                let conditions = [[0],[1],[2],[0,1],[1,2],[0,2]]
                if conditions[Int(args[0])].contains(comparison) {
                    guard stack.count < 16 else { return false }
                    if opcode == 0x07 { stack.append(pc + 5) }; pc = Self.word(args, 1)
                } else { pc += 5 }
            case 0x21,0x22:
                guard let args = rom(pc, 4), let a = projectedVariable(Self.half(args), on: map, projection: projection),
                      let b = opcode == 0x21 ? Self.half(args, 2) : projectedVariable(Self.half(args, 2), on: map, projection: projection) else { return false }
                comparison = a < b ? 0 : a == b ? 1 : 2; pc += 4
            case 0x2B:
                guard let args = rom(pc, 2), let value = projectedFlag(Self.half(args), on: map, projection: projection) else { return false }
                comparison = value ? 1 : 0; pc += 2
            case 0x26:
                guard projecting, let args = rom(pc, 4), Self.half(args, 2) == 0x180,
                      wonderCardFlagID == 0, let special = rom(0x0815FD60 + 0x180 * 4, 4),
                      Self.word(special) == 0x08143FC9 else { return false }
                // Exact native ValidateSavedWonderCard returns false when the
                // saved card flag ID is zero, for either CRC outcome. This is
                // a read-only proven native case, not a generic special stub.
                let id = Self.half(args)
                guard (0x4000..<0x4100).contains(id) || (0x5000..<0x5200).contains(id) || (0x8000...0x8014).contains(id) else { return false }
                projection.variables[id] = 0; pc += 4
            case 0x16,0x17,0x18,0x19,0x1A:
                guard let args = rom(pc, 4) else { return false }
                let id = Self.half(args), operand = Self.half(args, 2)
                guard (0x4000..<0x4100).contains(id) || (0x5000..<0x5200).contains(id) || (0x8000...0x8014).contains(id) else { return false }
                var value: Int
                if opcode == 0x16 { value = operand }
                else if opcode == 0x17 || opcode == 0x18 {
                    guard let existing = projectedVariable(id, on: map, projection: projection) else { return false }
                    value = (existing + (opcode == 0x17 ? operand : -operand)) & 0xFFFF
                } else {
                    guard let resolved = projectedVariable(operand, on: map, projection: projection) else { return false }; value = resolved
                }
                projection.variables[id] = value; pc += 4
            case 0x29,0x2A,0xD0:
                guard let args = rom(pc, 2), Self.half(args) < 0x1900 else { return false }
                projection.flags[Self.half(args)] = opcode != 0x2A; pc += 2
            case 0x53,0x55:
                guard projecting, let args = rom(pc, 2), let id = projectedVariable(Self.half(args), on: map, projection: projection), id != 0xFF else { return false }
                if opcode == 0x53 { projection.hiddenObjects.insert(id); projection.shownObjects.remove(id) }
                else { projection.shownObjects.insert(id); projection.hiddenObjects.remove(id) }
                pc += 2
            case 0x57,0x63:
                guard projecting, let args = rom(pc, 6), let id = projectedVariable(Self.half(args), on: map, projection: projection), id != 0xFF,
                      let x = projectedVariable(Self.half(args, 2), on: map, projection: projection),
                      let y = projectedVariable(Self.half(args, 4), on: map, projection: projection) else { return false }
                projection.objectPositions[id] = .init(x: x, y: y); pc += 6
            case 0xA2:
                guard projecting, let args = rom(pc, 8),
                      let x = projectedVariable(Self.half(args), on: map, projection: projection),
                      let y = projectedVariable(Self.half(args, 2), on: map, projection: projection),
                      let metatile = projectedVariable(Self.half(args, 4), on: map, projection: projection),
                      let collision = projectedVariable(Self.half(args, 6), on: map, projection: projection), x < 1024, y < 1024 else { return false }
                projection.tiles[y << 16 | x] = UInt16(metatile & 0xFFF | (collision == 0 ? 0 : 0xC00)); pc += 8
            case 0xC7:
                guard let color = rom(pc, 1)?.first else { return false }
                if let previous = projectedVariable(0x8012, on: map, projection: projection) { projection.variables[0x8013] = previous }
                else { projection.variables.removeValue(forKey: 0x8013) }
                projection.variables[0x8012] = Int(color); pc += 1
            case 0x0F,0x2F,0x33,0x37,0x5B,0x7F,0x84,0x9F,0xA4:
                // Audited effects: script-local word, audio, facing, string
                // buffers, respawn and saved weather. None changes geometry or
                // the variable/flag predicates supported by this interpreter.
                // Commands that consume script-local data remain unsupported.
                let lengths: [UInt8: Int] = [0x0F:5,0x2F:2,0x33:3,0x37:1,0x5B:3,0x7F:3,0x84:3,0x9F:2,0xA4:2]
                guard let length = lengths[opcode], rom(pc, length) != nil else { return false }; pc += length
            default: break
            }
        }
        return false
    }

    private static func mapHeader(_ map: Map, rom: (Int, Int) -> [UInt8]?) -> [UInt8]? {
        guard (0..<43).contains(map.group), (0..<256).contains(map.number),
              let group = rom(0x083526A8 + map.group * 4, 4), let pointer = rom(word(group) + map.number * 4, 4) else { return nil }
        return rom(word(pointer), 28)
    }
    private static func half(_ data: [UInt8], _ offset: Int = 0) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
    private static func signed(_ data: [UInt8], _ offset: Int = 0) -> Int { Int(Int16(bitPattern: UInt16(half(data, offset)))) }
    private static func word(_ data: [UInt8], _ offset: Int = 0) -> Int { half(data, offset) | half(data, offset + 2) << 16 }
}
