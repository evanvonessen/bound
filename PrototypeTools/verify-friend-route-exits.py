#!/usr/bin/env python3
"""Exercise production friend routing on exact-ROM native map snapshots.

Use qa-python and an explicit BOUND_GAME_SOURCE. Disposable fixture preparation
only registers a native task calling SetWarpDestination/WarpIntoMap/LoadMap.
The cartridge then loads terrain, map scripts and objects under pinned mGBA.
No gameplay endpoint, collision result, player position or terrain is stubbed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import zlib


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('rom', 'state', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--source-ref', help='Optional existing Git revision for a read-only before/after comparison')
    args = parser.parse_args()
    game = Path(os.environ['BOUND_GAME_SOURCE']).resolve(strict=True)
    sys.path.insert(0, str(game / 'tools'))
    from qa_python import ensure_qa_python
    ensure_qa_python()
    from game_elimination_storage_native import Machine

    args.rom = args.rom.resolve(strict=True)
    args.state = args.state.resolve(strict=True)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    image, seed = args.rom.read_bytes(), args.state.read_bytes()
    assert len(image) == 0x2000000 and len(seed) == 0x61000
    assert struct.unpack_from('<I', seed, 8)[0] == zlib.crc32(image), 'Fixture must match exact cartridge'
    rom_hash, state_hash = digest(args.rom), digest(args.state)
    # Native map IDs and ordinary open floor, avoiding script/warp tiles.
    locations = [('pallet', 3, 0, 10, 10), ('viridian', 3, 1, 20, 26),
                 ('route1', 3, 19, 13, 32), ('downstairs', 4, 0, 4, 6),
                 ('upstairs', 4, 1, 5, 5), ('mart', 5, 3, 4, 6), ('pallet-before-oak', 3, 0, 10, 10),
                 ('viridian-before-parcel', 3, 1, 20, 26)]
    endpoints = [('pallet-north', 3, 0, 12, 0, 'UP', 3, 19),
                 ('route1-south', 3, 19, 12, 39, 'DOWN', 3, 0),
                 ('route1-north', 3, 19, 13, 0, 'UP', 3, 1),
                 ('viridian-south', 3, 1, 25, 39, 'DOWN', 3, 19),
                 ('house-enter', 3, 0, 6, 8, 'UP', 4, 0),
                 ('house-exit', 4, 0, 4, 8, 'DOWN', 3, 0),
                 ('stairs-up', 4, 0, 10, 2, 'RIGHT', 4, 1),
                 ('stairs-down', 4, 1, 10, 2, 'LEFT', 4, 0),
                 ('mart-enter', 3, 1, 36, 20, 'UP', 5, 3),
                 ('mart-exit', 5, 3, 4, 7, 'DOWN', 3, 1),
                 ('dormant-pallet-warp', 3, 0, 7, 10, 'UP', 3, 0)]
    locations += [endpoint[:5] for endpoint in endpoints]
    fixtures = []
    for name, group, number, x, y in locations:
        output = args.output / name
        output.mkdir(exist_ok=True)
        prepared = output / 'native-task.state'
        final = output / 'final.state'
        metadata = output / 'fixture-inputs.json'
        oak_stage = 0 if name == 'pallet-before-oak' else 1
        parcel_stage = 0 if name == 'viridian-before-parcel' else 1
        expected = dict(romSHA256=rom_hash, stateSHA256=state_hash, group=group, number=number, x=x, y=y,
                        nativeVarSet={'0x4050': oak_stage, '0x4057': parcel_stage})
        if not final.exists() or not metadata.exists() or json.loads(metadata.read_text()) != expected:
            source, layout = output / 'task.c', output / 'task.ld'
            source.write_text('void Prepare(unsigned id){'
                f'((void(*)(unsigned,unsigned,int,int,int))0x0805538D)({group},{number},-1,{x},{y});'
                '((void(*)(void))0x08055379)();'
                '((void(*)(void*))0x08000545)((void*)0x0805671D);'
                '((void(*)(unsigned))0x08077509)(id);}')
            layout.write_text('SECTIONS { .text 0x03004C00 : { *(.text*) *(.rodata*) } '
                              '/DISCARD/ : { *(.comment) *(.ARM.attributes) *(.ARM.exidx*) } }')
            prefix = '/opt/devkitpro/devkitARM/bin/arm-none-eabi-'
            subprocess.run([prefix + 'gcc', '-mcpu=arm7tdmi', '-mthumb', '-Os', '-ffreestanding', '-fno-builtin',
                            '-nostdlib', '-Wl,-T,' + str(layout), str(source), '-o', str(output / 'task.elf')], check=True)
            subprocess.run([prefix + 'objcopy', '-O', 'binary', str(output / 'task.elf'), str(output / 'task.bin')], check=True)
            code = (output / 'task.bin').read_bytes()
            assert len(code) <= 256
            native = Machine(image, seed)
            # Explicit synthetic progression fixture: the original native VarSet
            # chooses the completed introductory Oak gate branch. This is not a
            # claim that the task played the story or modified any user save.
            assert native.call(0x0806E585, 0x4050, oak_stage) == 1
            assert native.call(0x0806E585, 0x4057, parcel_stage) == 1
            native.u.mem_write(0x03004C00, code)
            native.call(0x0807741D, 0x03004C01, 0)
            state = bytearray(seed)
            state[0x19000:0x21000] = native.bytes(0x03000000, 0x8000)
            state[0x21000:] = native.bytes(0x02000000, 0x40000)
            prepared.write_bytes(state)
            command = [sys.executable, str(game / 'tools/map_emulator.py'), '--rom', str(args.rom),
                       '--state-in', str(prepared), '--output', str(output), '--frames', '600',
                       '--rtc-ms', '1735689600000', '--state-out', '600:' + str(final), '--screenshot-at', '600']
            subprocess.run(command, cwd=game, check=True, stdout=subprocess.DEVNULL)
            metadata.write_text(json.dumps(expected, indent=2) + '\n')
        fixtures.append(dict(name=name, group=group, number=number, state=str(final), sha256=digest(final)))
        print('Native fixture', name, flush=True)

    transitions = []
    for name, _, _, _, _, button, target_group, target_number in endpoints:
        output = args.output / name / 'walk'
        output.mkdir(exist_ok=True)
        final = output / 'final.state'
        command = [sys.executable, str(game / 'tools/map_emulator.py'), '--rom', str(args.rom),
                   '--state-in', str(args.output / name / 'final.state'), '--output', str(output),
                   '--frames', '650', '--rtc-ms', '1735689600000', '--state-out', '650:' + str(final),
                   '--input', '361:365:' + button, '--input', '391:395:' + button, '--screenshot-at', '650']
        # Let native introduction text finish through ordinary cancel presses.
        # This runs the actual scripts; it does not clear their lock in RAM.
        for frame in range(1, 332, 30):
            command += ['--input', f'{frame}:{frame + 4}:B']
        subprocess.run(command, cwd=game, check=True, stdout=subprocess.DEVNULL)
        raw = final.read_bytes()
        save = struct.unpack_from('<I', raw, 0x19000 + 0x5008)[0] - 0x02000000 + 0x21000
        x, y, group, number = struct.unpack_from('<HHBB', raw, save)
        passed = (group, number) == (target_group, target_number)
        if name == 'dormant-pallet-warp':
            passed = passed and (x, y) == (7, 9)
        transitions.append(dict(name=name, passed=passed, finalMap=[group, number], finalTile=[x, y],
                                expectedMap=[target_group, target_number], nativeInputs=[button, button]))
        print('Native transition', transitions[-1], flush=True)
    (args.output / 'native-transitions.json').write_text(json.dumps(transitions, indent=2) + '\n')

    root = Path(__file__).resolve().parents[1]
    def owning_source(path):
        if args.source_ref:
            return subprocess.check_output(['git', 'show', args.source_ref + ':' + path], cwd=root, text=True)
        return (root / path).read_text()
    scene = owning_source('Delta/Bound/BoundPlayerScene.swift')
    state = owning_source('Delta/Bound/BoundPlayerState.swift')
    access = owning_source('Delta/Bound/BoundFriendRouteAccess.swift')
    guard = '''guard let opcode = rom(pc, 1)?.first, let expected = handlers[Int(opcode)],
                  let handler = rom(0x0815F9B4 + Int(opcode) * 4, 4), Self.word(handler) == expected else { return false }'''
    instrumented = '''guard let opcode = rom(pc, 1)?.first else { return false }
            guard let expected = handlers[Int(opcode)],
                  let handler = rom(0x0815F9B4 + Int(opcode) * 4, 4), Self.word(handler) == expected else {
                unknownRouteOpcodes.insert(String(format: "0x%08X:0x%02X", pc, opcode)); return false
            }'''
    assert guard in access
    access = access.replace(guard, instrumented)
    source = '''import Foundation
var unknownRouteOpcodes = Set<String>()
struct BoundPlayerScene: Equatable, Sendable {}
struct BoundGBAMemorySnapshot {
    let state: [UInt8]
    func bytes(at address: Int, count: Int) -> [UInt8]? {
        let offset: Int
        if address >= 0x02000000 && address + count <= 0x02040000 { offset = address - 0x02000000 + 0x21000 }
        else if address >= 0x03000000 && address + count <= 0x03008000 { offset = address - 0x03000000 + 0x19000 }
        else { return nil }
        return Array(state[offset..<offset + count])
    }
}
'''
    source += state[state.index('struct BoundPlayerState:'):state.index('struct BoundPlayerStateReading:')]
    source += access
    source += scene[scene.index('final class BoundPlayerSceneAssets:'):scene.index('enum BoundPlayerSceneDecoder {')]
    source += '\nlet rom = Array(try Data(contentsOf: URL(fileURLWithPath: ' + json.dumps(str(args.rom)) + ')))\n'
    source += '\nlet fixtureJSON = ' + json.dumps(json.dumps(fixtures)) + '\n'
    source += SWIFT
    source = source.replace('REPORT_PATH', json.dumps(str(args.output / 'native-route-exits.json')))
    source = source.replace('ROM_HASH', json.dumps(rom_hash)).replace('STATE_HASH', json.dumps(state_hash))
    source = source.replace('SOURCE_REF', json.dumps(args.source_ref or 'working-tree'))
    source = source.replace('CURRENT_CHECKS', '' if args.source_ref else CURRENT_CHECKS)
    swift = args.output / 'main.swift'
    swift.write_text(source)
    binary = args.output / 'friend-route-exits'
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(args.output / 'modules'), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    assert digest(args.rom) == rom_hash and digest(args.state) == state_hash, 'Original inputs changed'
    assert all(row['passed'] for row in transitions), 'Native endpoint transition failed'


SWIFT = r'''
typealias Map = BoundPlayerMapConnections.Map
typealias Point = BoundPlayerState.Point
func read(_ address: Int, _ count: Int) -> [UInt8]? {
    let start = address - 0x08000000
    guard start >= 0, count >= 0, start <= rom.count, count <= rom.count - start else { return nil }
    return Array(rom[start..<start + count])
}
func h(_ bytes: [UInt8], _ at: Int = 0) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
func w(_ bytes: [UInt8], _ at: Int = 0) -> Int { h(bytes, at) | h(bytes, at + 2) << 16 }
let graph = BoundFriendRouteGraph(rom: read)
let assets = BoundPlayerSceneAssets()
assets.prepareFriendRoutes(rom: read)
let rows = try JSONSerialization.jsonObject(with: Data(fixtureJSON.utf8)) as! [[String: Any]]
var viewers: [String: BoundPlayerState] = [:], report: [[String: Any]] = [], checks: [[String: Any]] = []
func require(_ label: String, _ passed: Bool) {
    checks.append(["check": label, "passed": passed])
    if !passed { print("FAIL", label) }
}
for row in rows {
    let memory = BoundGBAMemorySnapshot(state: Array(try Data(contentsOf: URL(fileURLWithPath: row["state"] as! String))))
    let save = w(memory.bytes(at: 0x03005008, count: 4)!), saved = memory.bytes(at: save, count: 12)!
    let map = Map(group: Int(saved[4]), number: Int(saved[5]))
    precondition(map.group == row["group"] as! Int && map.number == row["number"] as! Int, "Native map load did not finish")
    let access = BoundFriendRouteAccess.capture(memory: memory, save: save, currentMap: map, rom: read)!
    let tile = Point(x: h(saved), y: h(saved, 2))
    viewers[row["name"] as! String] = .init(mapGroup: map.group, mapNumber: map.number, tile: tile,
        previousTile: tile, facing: "North", elevation: 0, graphicsID: 0, runningState: 0,
        tileTransitionState: 0, mapInstance: graph.nodes[map]!.instance, routeAccess: access)
    let local = access.map(map, rom: read)!
    print("CAPTURE", row["name"]!, map, tile, "grid", local.width, local.height, "blockedScripts", local.blockedScripts)
}
func route(_ from: String, _ to: String) -> Point? {
    let viewer = viewers[from]!, friend = viewers[to]!
    return assets.friendRouteTarget(viewer: viewer, friendGroup: friend.mapGroup, friendNumber: friend.mapNumber,
        friendInstance: friend.mapInstance, friendX: Double(friend.tile.x * 16 + 8), friendY: Double(friend.tile.y * 16 + 16), rom: read)
}
for (from, to, expectedX, expectedY) in [("pallet", "viridian", 12, -1), ("viridian", "pallet", 22, 40),
                   ("pallet", "route1", 12, -1), ("route1", "pallet", 13, 40),
                   ("route1", "viridian", 13, -1), ("viridian", "route1", 22, 40),
                   ("pallet", "upstairs", 6, 7), ("upstairs", "pallet", 10, 2),
                   ("downstairs", "upstairs", 10, 2), ("upstairs", "downstairs", 10, 2),
                   ("viridian", "mart", 36, 19), ("mart", "viridian", 4, 7)] {
    unknownRouteOpcodes.removeAll()
    let start = Date(), result = route(from, to), elapsed = Date().timeIntervalSince(start)
    let viewer = viewers[from]!, access = viewer.routeAccess!
    let map = Map(group: viewer.mapGroup, number: viewer.mapNumber), local = access.map(map, rom: read)!
    let target = result.map { Point(x: ($0.x - 8) / 16, y: ($0.y - 16) / 16) }
    let matching = target.map { tile in graph.nodes[map]!.edges.filter { $0.waypoint(from: tile) == tile } } ?? []
    let valid = target.map { local.canReachTarget($0, reachable: local.reachable(from: viewer.tile), doorway: matching.contains { $0.direction == 0 }) } ?? false
    require("\(from) to \(to) uses exact native exit", target == Point(x: expectedX, y: expectedY))
    require("\(from) to \(to) exit is reachable on captured native terrain", valid && !matching.isEmpty)
    let resultRow: [String: Any] = ["from": from, "to": to, "target": target.map { [$0.x, $0.y] } ?? [],
        "nativeReachable": valid, "exitDestinations": matching.map { [$0.destination.group, $0.destination.number] },
        "seconds": elapsed, "unsupportedOpcodes": unknownRouteOpcodes.sorted()]
    report.append(resultRow)
    print("ROUTE", resultRow)
}
require("Oak's actual introductory gate withholds the inaccessible route", route("pallet-before-oak", "viridian") == nil)
require("Unprojectable parcel cutscene withholds route through the unverified room", route("viridian-before-parcel", "mart") == nil)
for (x, y) in [(168, 176), (184, 176), (184, 192)] {
    let viewer = viewers["pallet"]!
    let result = assets.friendRouteTarget(viewer: viewer, friendGroup: viewer.mapGroup, friendNumber: viewer.mapNumber,
        friendInstance: viewer.mapInstance, friendX: Double(x), friendY: Double(y), rom: read)
    require("Same map preserves exact friend position \(x),\(y)", result == Point(x: x, y: y))
}
CURRENT_CHECKS
let passed = checks.allSatisfy { $0["passed"] as! Bool }
let result: [String: Any] = ["passed": passed, "romSHA256": ROM_HASH, "seedSHA256": STATE_HASH,
    "sourceRef": SOURCE_REF, "routes": report, "checks": checks, "fixtures": rows,
    "provenance": "Exact cartridge native LoadMap fixtures; explicit native VarSet fixture stages4050/4057; production Swift route code and immutable captured grids. No live transport or physical-device validation."]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: REPORT_PATH))
if SOURCE_REF == "working-tree" { precondition(passed, "Native route regression failed; inspect report") }
print("CHECKS", checks.count, "passed", checks.filter { $0["passed"] as! Bool }.count)
'''

CURRENT_CHECKS = r'''
// Enumerate every valid opening through the two exact native seams. This
// independent exhaustive combination check does not use the graph's Dijkstra
// search or its first-portal selection, and includes the friend's final walk.
func checkShortest(_ from: String, _ to: String, through sequence: [Map]) {
    let viewer = viewers[from]!, friend = viewers[to]!, access = viewer.routeAccess!
    var best = Int.max, optimal = Set<String>()
    func visit(_ index: Int, _ entry: Point, _ cost: Int, _ first: Point?) {
        let map = sequence[index]
        guard let terrain = access.map(map, rom: read) else { return }
        let distances = terrain.walkingDistances(from: entry)
        if index == sequence.count - 1 {
            guard let last = terrain.walkingDistance(to: friend.tile, distances: distances), let first else { return }
            let total = cost + last, key = "\(first.x),\(first.y)"
            if total < best { best = total; optimal = [key] }
            else if total == best { optimal.insert(key) }
            return
        }
        let next = sequence[index + 1]
        guard let other = access.map(next, rom: read),
              let edge = graph.nodes[map]!.edges.first(where: { $0.destination == next && $0.direction != 0 }) else { return }
        for coordinate in edge.lower...edge.upper {
            let portal = Point(x: coordinate, y: edge.tile.y)
            let arrival = Point(x: coordinate - edge.connectionOffset, y: edge.direction == 2 ? other.height - 1 : 0)
            guard let steps = terrain.walkingDistance(to: portal, distances: distances),
                  other.canEnter(arrival, elevation: 0, direction: edge.direction) else { continue }
            visit(index + 1, arrival, cost + steps, first ?? portal)
        }
    }
    visit(0, viewer.tile, 0, nil)
    let result = route(from, to)
    let key = result.map { "\(($0.x - 8) / 16),\(($0.y - 16) / 16)" }
    require("\(from) to \(to) matches shortest native walking path", key.map { optimal.contains($0) } ?? false)
    print("SHORTEST", from, to, "walkingTiles", best, "optimalExits", optimal.sorted(), "actual", key as Any)
}
let pallet = Map(group: 3, number: 0), route1 = Map(group: 3, number: 19), viridian = Map(group: 3, number: 1)
checkShortest("pallet", "viridian", through: [pallet, route1, viridian])
checkShortest("viridian", "pallet", through: [viridian, route1, pallet])
checkShortest("pallet-north", "viridian", through: [pallet, route1, viridian])
checkShortest("pallet", "viridian-south", through: [pallet, route1, viridian])
checkShortest("route1-south", "viridian", through: [route1, viridian])
checkShortest("route1-north", "pallet", through: [route1, pallet])
'''


if __name__ == '__main__':
    main()
