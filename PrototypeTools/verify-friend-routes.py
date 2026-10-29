#!/usr/bin/env python3
"""Compile and execute cartridge navigation code against bounded native tables."""
import argparse
from pathlib import Path
import subprocess
import json

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--rom', type=Path)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
scene = (root / 'Delta/Bound/BoundPlayerScene.swift').read_text()
state = (root / 'Delta/Bound/BoundPlayerState.swift').read_text()
source = 'import Foundation\nstruct BoundPlayerScene: Equatable, Sendable {}\nstruct BoundFriendRouteAccess: Equatable, Sendable {}\n'
source += state[state.index('struct BoundPlayerState:'):state.index('struct BoundPlayerStateReading:')]
source += scene[scene.index('struct BoundFriendRouteGraph:'):scene.index('enum BoundPlayerSceneDecoder {')]
source += r'''
var storage = [Int: UInt8]()
func put(_ address: Int, _ value: Int, count: Int = 4) {
    for byte in 0..<count { storage[address + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
}
func fill(_ address: Int, _ size: Int) { for byte in 0..<size { storage[address + byte] = 0 } }
func read(_ address: Int, _ count: Int) -> [UInt8]? {
    guard count >= 0, count <= 4096 else { return nil }
    var result = [UInt8]()
    for byte in 0..<count { guard let value = storage[address + byte] else { return nil }; result.append(value) }
    return result
}
let table = 0x08001000
put(0x083526A8, table)
for map in 0..<5 {
    let header = 0x08002000 + map * 256, layout = header + 32, events = header + 64
    put(table + map * 4, header); fill(header, 28); fill(layout, 24); fill(events, 20)
    put(header, layout); put(header + 4, events); put(layout, 10); put(layout + 4, 10)
}
func warps(_ map: Int, _ portals: [(Int, Int, Int, Int)]) {
    let events = 0x08002000 + map * 256 + 64, rows = events + 32
    put(events + 1, portals.count, count: 1); put(events + 8, rows)
    for (slot, portal) in portals.enumerated() {
        let row = rows + slot * 8; fill(row, 8)
        put(row, portal.0, count: 2); put(row + 2, portal.1, count: 2)
        put(row + 5, portal.3, count: 1); put(row + 6, portal.2, count: 1)
    }
}
warps(0, [(5, 5, 1, 0)])
warps(1, [(1, 9, 127, 0), (8, 1, 2, 0)])
warps(2, [(2, 8, 1, 1)])
// Map 3 is isolated; map 4 is attached through a cardinal seam.
let c = 0x08004000
put(0x08002000 + 12, c); put(c, 1); put(c + 4, c + 8)
put(c + 8, 4); put(c + 12, 0); put(c + 16, 0, count: 1); put(c + 17, 4, count: 1); fill(c + 18, 2)
let graph = BoundFriendRouteGraph(rom: read)
assert(graph.nodes.count == 5)
func instance(_ map: Int) -> UInt64 { UInt64(0x08002000 + map * 256) << 32 | UInt64(0x08002000 + map * 256 + 32) }
func player(_ map: Int, x: Int = 4, y: Int = 5, key: UInt64? = nil) -> BoundPlayerState {
    .init(mapGroup: 0, mapNumber: map, tile: .init(x: x, y: y), previousTile: .init(x: x, y: y),
        facing: "North", elevation: 0, graphicsID: 0, runningState: 0, tileTransitionState: 0, mapInstance: key ?? instance(map), dynamicWarp: .init(mapGroup: 0, mapNumber: 0, warpID: 0, x: 0, y: 0))
}
func target(_ viewer: BoundPlayerState, _ friend: Int, x: Double = 80, y: Double = 80, key: UInt64? = nil) -> BoundPlayerState.Point? {
    graph.target(viewer: viewer, friendGroup: 0, friendNumber: friend, friendInstance: key ?? instance(friend),
        friendX: x, friendY: y, distances: graph.distances(to: .init(group: 0, number: friend)))
}
assert(target(player(0), 2) == .init(x: 88, y: 96), "Outside guidance selects building entrance")
assert(target(player(1), 2) == .init(x: 136, y: 32), "Next floor selects native staircase")
assert(target(player(2), 0) == .init(x: 40, y: 144), "Multiroom return selects next doorway")
assert(target(player(1), 0) == .init(x: 24, y: 160), "Unique dynamic return selects building exit")
assert(target(player(0), 0, x: 31, y: 42) == .init(x: 31, y: 42), "Same map points directly at friend")
assert(target(player(0), 0, x: 46, y: 42) == .init(x: 46, y: 42), "Friend movement refreshes direction")
assert(target(player(0, y: 7), 4) == .init(x: 168, y: 128), "Cardinal exit follows local movement")
let narrowGap = graph.target(viewer: player(0, y: 7), friendGroup: 0, friendNumber: 4, friendInstance: instance(4),
    friendX: 80, friendY: 80, canTraverse: { _, from, edge in edge.direction == 0 || edge.waypoint(from: from).y == 2 })
assert(narrowGap == .init(x: 168, y: 48), "Cardinal guidance finds the actual opening instead of the nearest wall")
assert(target(player(0), 3) == nil, "Disconnected map has no invented direction")
assert(target(player(0), 0, key: 1) == nil, "Different native map instance cannot provide direct coordinates")
assert(target(player(0, key: 1), 1) == nil, "Stale viewer instance is rejected")
assert(target(player(0), 0, x: .infinity) == nil)
// Two outdoor maps sharing a return room cannot resolve its dynamic exit.
warps(4, [(3, 3, 1, 0)])
let ambiguous = BoundFriendRouteGraph(rom: read)
assert(ambiguous.nodes[.init(group: 0, number: 1)]!.edges.contains { $0.dynamicExit })
var inside = player(1)
inside.dynamicWarp = .init(mapGroup: 0, mapNumber: 4, warpID: 0, x: -1, y: -1)
let friend4 = ambiguous.target(viewer: inside, friendGroup: 0, friendNumber: 4, friendInstance: instance(4), friendX: 48, friendY: 64)
assert(friend4 == .init(x: 24, y: 160), "Shared room exit resolves the actual saved return, not incoming-map guesses")
inside.dynamicWarp = .init(mapGroup: 0, mapNumber: 3, warpID: -1, x: 4, y: 5)
assert(ambiguous.target(viewer: inside, friendGroup: 0, friendNumber: 3, friendInstance: instance(3), friendX: 48, friendY: 64) == .init(x: 24, y: 160), "Coordinate dynamic return is supported")
inside.dynamicWarp = .init(mapGroup: 0, mapNumber: 3, warpID: 100, x: 4, y: 5)
assert(ambiguous.target(viewer: inside, friendGroup: 0, friendNumber: 3, friendInstance: instance(3), friendX: 48, friendY: 64) == nil, "Invalid warp ID is not replaced with guessed coordinates")
// Reaching a map through a different doorway may reach a different wall region.
warps(0, [(5, 5, 1, 0), (9, 9, 1, 1)])
let regions = BoundFriendRouteGraph(rom: read)
let regionalTarget = regions.target(viewer: player(0), friendGroup: 0, friendNumber: 2, friendInstance: instance(2), friendX: 80, friendY: 80, canTraverse: { map, from, edge in
    map.number != 1 || edge.destination.number != 2 || from.x == 8
})
assert(regionalTarget == .init(x: 152, y: 160), "Search retains separate native arrival regions")
let arrivalTarget = regions.target(viewer: player(0), friendGroup: 0, friendNumber: 1, friendInstance: instance(1),
    friendX: 136, friendY: 32, canArrive: { _, entry, _ in entry.x == 8 })
assert(arrivalTarget == .init(x: 152, y: 160), "Destination map must also arrive in the friend's reachable region")
assert(regions.target(viewer: player(0), friendGroup: 0, friendNumber: 1, friendInstance: instance(1),
    friendX: 136, friendY: 32, canArrive: { _, _, _ in false }) == nil, "No map-only success through a wall")
assert(regions.target(viewer: player(0), friendGroup: 0, friendNumber: 2, friendInstance: instance(2), friendX: 80, friendY: 80, canTraverse: { _,_,_ in false }) == nil, "Closed story/path gates withhold every inaccessible route")
warps(0, [(5, 5, 1, 0)])
warps(4, [(3, 3, 1, 1)])
let detourGraph = BoundFriendRouteGraph(rom: read)
let detour = detourGraph.target(viewer: player(0), friendGroup: 0, friendNumber: 2, friendInstance: instance(2),
    friendX: 80, friendY: 80, canTraverse: { map, entry, edge in
        map.number != 1 || edge.destination.number != 2 || entry.x == 8
    })
assert(detour == .init(x: 168, y: 96), "A locked shorter branch does not hide an accessible longer route")
let fastest = detourGraph.target(viewer: player(0), friendGroup: 0, friendNumber: 2, friendInstance: instance(2),
    friendX: 80, friendY: 80, arrivalCost: { _, _, _ in 0 }, traversalCost: { map, _, edge in
        map.number == 0 && edge.direction == 0 ? 100 : 1
    })
assert(fastest == .init(x: 168, y: 96), "A shorter walking route wins even when it crosses more map transitions")
let nearFriend = regions.target(viewer: player(0), friendGroup: 0, friendNumber: 1, friendInstance: instance(1),
    friendX: 136, friendY: 32, arrivalCost: { _, entry, _ in abs(entry.x - 8) + abs(entry.y - 1) },
    traversalCost: { _, entry, edge in let p = edge.waypoint(from: entry); return abs(p.x - entry.x) + abs(p.y - entry.y) })
assert(nearFriend == .init(x: 152, y: 160), "Destination walking distance beats the nearest first doorway")
let movedFriend = regions.target(viewer: player(0), friendGroup: 0, friendNumber: 1, friendInstance: instance(1),
    friendX: 24, friendY: 160, arrivalCost: { _, entry, _ in abs(entry.x - 1) + abs(entry.y - 9) },
    traversalCost: { _, entry, edge in let p = edge.waypoint(from: entry); return abs(p.x - entry.x) + abs(p.y - entry.y) })
assert(movedFriend == .init(x: 88, y: 96), "Friend movement changes the fastest doorway within the same destination map")
// Unsupported destination scripts must not erase a proven approach to its
// threshold. Unknown intermediate rooms and blocked source exits stay closed.
let threshold = graph.target(viewer: player(0), friendGroup: 0, friendNumber: 2, friendInstance: instance(2),
    friendX: 80, friendY: 80, destinationApproachCost: { _, _, _ in 1 },
    warpArrival: { map, tile in map.number == 2 ? nil : tile })
assert(threshold == .init(x: 88, y: 96), "A known path reaches the threshold of an unprojectable destination")
assert(graph.target(viewer: player(0), friendGroup: 0, friendNumber: 2, friendInstance: instance(2),
    friendX: 80, friendY: 80, destinationApproachCost: { _, _, _ in nil }) == nil,
    "A blocked target threshold cannot be reached by the approach fallback")
assert(graph.target(viewer: player(0), friendGroup: 0, friendNumber: 2, friendInstance: instance(2),
    friendX: 80, friendY: 80, destinationApproachCost: { _, _, _ in 1 },
    warpArrival: { map, tile in map.number == 1 ? nil : tile }) == nil,
    "Unknown intermediate rooms are never traversed for a destination approach")
assert(graph.target(viewer: player(0), friendGroup: 0, friendNumber: 2, friendInstance: 1,
    friendX: 80, friendY: 80, destinationApproachCost: { _, _, _ in 1 }) == nil,
    "Destination approach still rejects stale friend map identity")
print("PASS: native entrances, exits, stairs, multiple rooms, movement, map identity, disconnected/ambiguous routes, destination thresholds")

'''
if a.rom:
    source += '\nlet actualROM = try Data(contentsOf: URL(fileURLWithPath: ' + json.dumps(str(a.rom.resolve())) + '))\n'
    source += r'''
func actualRead(_ at: Int, _ count: Int) -> [UInt8]? {
    let start = at - 0x08000000
    guard start >= 0, count >= 0, start <= actualROM.count, count <= actualROM.count - start else { return nil }
    return Array(actualROM[start..<start + count])
}
let start = Date()
let actual = BoundFriendRouteGraph(rom: actualRead)
let count = actual.nodes.values.reduce(0) { $0 + $1.edges.count }
assert(actual.nodes.count == 437 && count == 1530, "Pinned cartridge topology changed")
func nativeViewer(_ map: BoundPlayerMapConnections.Map) -> BoundPlayerState {
    .init(mapGroup: map.group, mapNumber: map.number, tile: .init(x: 4, y: 5), previousTile: .init(x: 4, y: 5),
        facing: "North", elevation: 0, graphicsID: 0, runningState: 0, tileTransitionState: 0, mapInstance: actual.nodes[map]!.instance)
}
let pallet = BoundPlayerMapConnections.Map(group: 3, number: 0)
let downstairs = BoundPlayerMapConnections.Map(group: 4, number: 0)
let upstairs = BoundPlayerMapConnections.Map(group: 4, number: 1)
func nativeTarget(_ from: BoundPlayerMapConnections.Map, _ to: BoundPlayerMapConnections.Map) -> BoundPlayerState.Point? {
    actual.target(viewer: nativeViewer(from), friendGroup: to.group, friendNumber: to.number,
        friendInstance: actual.nodes[to]!.instance, friendX: 80, friendY: 80, distances: actual.distances(to: to))
}
assert(nativeTarget(pallet, upstairs) == .init(x: 6 * 16 + 8, y: 7 * 16 + 16), "Actual Pallet house entrance")
assert(nativeTarget(downstairs, upstairs) == .init(x: 10 * 16 + 8, y: 2 * 16 + 16), "Actual upstairs staircase")
assert(nativeTarget(upstairs, pallet) == .init(x: 10 * 16 + 8, y: 2 * 16 + 16), "Actual return via downstairs")
let exit = nativeTarget(downstairs, pallet)
assert(exit == .init(x: 4 * 16 + 8, y: 8 * 16 + 16), "Actual nearest house exit")
// Celadon's shared elevator has several fixed incoming floors. The saved
// native dynamic warp, rather than those incoming edges, determines its exit.
let elevator = BoundPlayerMapConnections.Map(group: 10, number: 6)
for floorNumber in [0, 2] {
    let floor = BoundPlayerMapConnections.Map(group: 10, number: floorNumber)
    guard let incoming = actual.nodes[floor]?.edges.first(where: { $0.destination == elevator }) else { fatalError("Missing pinned elevator portal") }
    var local = nativeViewer(elevator)
    local.dynamicWarp = .init(mapGroup: floor.group, mapNumber: floor.number, warpID: incoming.sourceWarpID, x: -1, y: -1)
    var observedDynamicDestination: BoundPlayerMapConnections.Map?
    let hint = actual.target(viewer: local, friendGroup: floor.group, friendNumber: floor.number,
        friendInstance: actual.nodes[floor]!.instance, friendX: 80, friendY: 80, canTraverse: { _, _, edge in
            if edge.dynamicExit { observedDynamicDestination = edge.destination }
            return true
        })
    assert(hint != nil && observedDynamicDestination == floor, "Actual elevator resolves the selected native return floor")
}
print("PASS: actual verified-ROM table extraction", actual.nodes.count, "maps", count, "portals; seconds", Date().timeIntervalSince(start))
'''
a.output.mkdir(parents=True, exist_ok=True)
main = a.output / 'main.swift'
main.write_text(source)
subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(a.output / 'modules'), str(main), '-o', str(a.output / 'friend-route-tests')], check=True)
subprocess.run([str(a.output / 'friend-route-tests')], check=True)
