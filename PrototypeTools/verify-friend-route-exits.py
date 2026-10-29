#!/usr/bin/env python3
"""Exercise production friend routing on exact-ROM native map snapshots.

Use qa-python and an explicit BOUND_GAME_SOURCE. Disposable fixture preparation
only registers a native task calling SetWarpDestination/WarpIntoMap/LoadMap.
The cartridge then loads terrain, map scripts and objects under pinned mGBA.
Native checkpoint pairs use captured positions and collision; optional sweeps
explicitly probe hypothetical positions on captured reachable native terrain.
The pairs JSON contains romSHA256, fixtures (name/group/number/state/sha256),
and pairs (name/from/to). Each pair runs forward and reverse independently.
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
    for name in ('rom', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--state', type=Path)
    parser.add_argument('--fixtures-report', type=Path, help='Reuse hash-verified native snapshots; run only pure route checks')
    parser.add_argument('--pairs-report', type=Path, help='Additional exact-ROM native snapshots and checkpoint pairs; every pair is checked in both directions')
    parser.add_argument('--sweep-destinations', action='store_true', help='Probe both directions from every reachable tile in the native fixtures; reports discrepancies without pretending these probes are gameplay')
    parser.add_argument('--source-ref', help='Optional existing Git revision for a read-only before/after comparison')
    args = parser.parse_args()
    game = Path(os.environ['BOUND_GAME_SOURCE']).resolve(strict=True)
    sys.path.insert(0, str(game / 'tools'))
    from qa_python import ensure_qa_python
    ensure_qa_python()
    from game_elimination_storage_native import Machine

    args.rom = args.rom.resolve(strict=True)
    if not args.state and not args.fixtures_report:
        parser.error('Supply --state or --fixtures-report')
    if args.state:
        args.state = args.state.resolve(strict=True)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    image = args.rom.read_bytes()
    assert len(image) == 0x2000000
    rom_hash = digest(args.rom)
    if args.fixtures_report:
        reused = json.loads(args.fixtures_report.read_text())
        assert reused['romSHA256'] == rom_hash
        state_hash = reused['seedSHA256']
        fixtures = reused['fixtures']
        for fixture in fixtures:
            raw = Path(fixture['state']).read_bytes()
            assert hashlib.sha256(raw).hexdigest() == fixture['sha256']
            assert len(raw) == 0x61000 and struct.unpack_from('<I', raw, 8)[0] == zlib.crc32(image)
    else:
        seed = args.state.read_bytes()
        assert len(seed) == 0x61000 and struct.unpack_from('<I', seed, 8)[0] == zlib.crc32(image)
        state_hash, fixtures = digest(args.state), []
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
    if args.fixtures_report:
        locations, endpoints = [], []
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

    # Check both phones after each actual native endpoint transition. Historical
    # fixtures remain immutable; their resulting walk states are hash-checked
    # like every newly supplied checkpoint. Keeping the two observations
    # separate is essential: independently progressed viewers can disagree.
    pairs = []
    fixture_names = {fixture['name'] for fixture in fixtures}
    for fixture in list(fixtures):
        walked = Path(fixture['state']).parent / 'walk' / 'final.state'
        if not walked.exists():
            continue
        raw = walked.read_bytes()
        assert len(raw) == 0x61000 and struct.unpack_from('<I', raw, 8)[0] == zlib.crc32(image)
        save = struct.unpack_from('<I', raw, 0x19000 + 0x5008)[0] - 0x02000000 + 0x21000
        group, number = struct.unpack_from('<BB', raw, save + 4)
        name = fixture['name'] + '-after-transition'
        if name not in fixture_names:
            fixtures.append(dict(name=name, group=group, number=number, state=str(walked), sha256=digest(walked)))
            fixture_names.add(name)
        pairs.append(dict(name=name, **{'from': 'pallet', 'to': name}))
    if args.pairs_report:
        additional = json.loads(args.pairs_report.read_text())
        assert additional['romSHA256'] == rom_hash
        names = {fixture['name'] for fixture in fixtures}
        for fixture in additional['fixtures']:
            assert fixture['name'] not in names, 'Duplicate fixture name: ' + fixture['name']
            raw = Path(fixture['state']).read_bytes()
            assert hashlib.sha256(raw).hexdigest() == fixture['sha256']
            assert len(raw) == 0x61000 and struct.unpack_from('<I', raw, 8)[0] == zlib.crc32(image)
            fixtures.append(fixture)
            names.add(fixture['name'])
        for pair in additional['pairs']:
            assert pair['from'] in names and pair['to'] in names
            pairs.append(pair)

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
    source += '\nlet pairJSON = ' + json.dumps(json.dumps(pairs)) + '\n'
    source += SWIFT
    source = source.replace('REPORT_PATH', json.dumps(str(args.output / 'native-route-exits.json')))
    source = source.replace('ROM_HASH', json.dumps(rom_hash)).replace('STATE_HASH', json.dumps(state_hash))
    source = source.replace('SOURCE_REF', json.dumps(args.source_ref or 'working-tree'))
    source = source.replace('CURRENT_CHECKS', '' if args.source_ref else CURRENT_CHECKS)
    source = source.replace('DESTINATION_SWEEP', DESTINATION_SWEEP if args.sweep_destinations else '')
    swift = args.output / 'main.swift'
    swift.write_text(source)
    binary = args.output / 'friend-route-exits'
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(args.output / 'modules'), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    assert digest(args.rom) == rom_hash, 'Original ROM changed'
    if not args.fixtures_report:
        assert digest(args.state) == state_hash, 'Original state changed'
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
    let avatar = memory.bytes(at: 0x02037078, count: 8)!
    let object = memory.bytes(at: 0x02036E38 + Int(avatar[5]) * 36, count: 36)!
    let warp = memory.bytes(at: save + 0x14, count: 8)!
    let warpID = Int(Int8(bitPattern: warp[2]))
    let dynamicWarp: BoundPlayerState.DynamicWarp? = warp[0] < 43 && warp[1] < 127 && warpID >= -1
        ? .init(mapGroup: Int(warp[0]), mapNumber: Int(warp[1]), warpID: warpID,
                x: Int(Int16(bitPattern: UInt16(h(warp, 4)))), y: Int(Int16(bitPattern: UInt16(h(warp, 6))))) : nil
    viewers[row["name"] as! String] = .init(mapGroup: map.group, mapNumber: map.number, tile: tile,
        previousTile: tile, facing: "North", elevation: Int(object[11] & 15), graphicsID: Int(object[5]), runningState: Int(avatar[2]),
        tileTransitionState: Int(avatar[3]), mapInstance: graph.nodes[map]!.instance, dynamicWarp: dynamicWarp, routeAccess: access)
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
require("Unprojectable parcel cutscene still permits approach to the verified Mart door", route("viridian-before-parcel", "mart") == Point(x: 36 * 16 + 8, y: 19 * 16 + 16))
for (x, y) in [(168, 176), (184, 176), (184, 192)] {
    let viewer = viewers["pallet"]!
    let result = assets.friendRouteTarget(viewer: viewer, friendGroup: viewer.mapGroup, friendNumber: viewer.mapNumber,
        friendInstance: viewer.mapInstance, friendX: Double(x), friendY: Double(y), rom: read)
    require("Same map preserves exact friend position \(x),\(y)", result == Point(x: x, y: y))
}
CURRENT_CHECKS
let pairs = try JSONSerialization.jsonObject(with: Data(pairJSON.utf8)) as! [[String: Any]]
var pairReport: [[String: Any]] = []
for pair in pairs {
    let name = pair["name"] as! String, first = pair["from"] as! String, second = pair["to"] as! String
    for (from, to, direction) in [(first, second, "forward"), (second, first, "reverse")] {
        unknownRouteOpcodes.removeAll()
        let viewer = viewers[from]!, friend = viewers[to]!, start = Date(), result = route(from, to)
        let map = Map(group: viewer.mapGroup, number: viewer.mapNumber)
        let sameMap = viewer.mapGroup == friend.mapGroup && viewer.mapNumber == friend.mapNumber
        let local = viewer.routeAccess!.map(map, rom: read)!
        let target = result.map { Point(x: ($0.x - 8) / 16, y: ($0.y - 16) / 16) }
        let matching = target.map { tile in graph.nodes[map]!.edges.filter { $0.waypoint(from: tile) == tile } } ?? []
        let valid = target.map { tile in
            sameMap ? tile == friend.tile : local.canReachTarget(tile,
                reachable: local.reachable(from: viewer.tile, elevation: viewer.elevation),
                doorway: matching.contains { $0.direction == 0 }) && !matching.isEmpty
        } ?? false
        let expected = pair[direction + "Available"] as? Bool ?? true
        require("\(name) \(direction): \(from) to \(to) has the expected route availability", (result != nil) == expected)
        if expected { require("\(name) \(direction) points to the friend or a reachable native exit", valid) }
        if let expectedTarget = pair[direction + "Target"] as? [Int] {
            require("\(name) \(direction) selects the expected exit", target == Point(x: expectedTarget[0], y: expectedTarget[1]))
        }
        let entry: [String: Any] = ["checkpoint": name, "direction": direction, "from": from, "to": to,
            "sourceMap": [viewer.mapGroup, viewer.mapNumber], "sourceTile": [viewer.tile.x, viewer.tile.y],
            "destinationMap": [friend.mapGroup, friend.mapNumber], "destinationTile": [friend.tile.x, friend.tile.y],
            "available": result != nil, "expectedAvailable": expected, "target": target.map { [$0.x, $0.y] } ?? [],
            "nativeReachable": valid, "seconds": Date().timeIntervalSince(start),
            "unsupportedOpcodes": unknownRouteOpcodes.sorted()]
        pairReport.append(entry)
        print("PAIR", entry)
    }
}
var sweepReport: [[String: Any]] = []
DESTINATION_SWEEP
let passed = checks.allSatisfy { $0["passed"] as! Bool }
let result: [String: Any] = ["passed": passed, "romSHA256": ROM_HASH, "seedSHA256": STATE_HASH,
    "sourceRef": SOURCE_REF, "routes": report, "pairRoutes": pairReport, "destinationSweep": sweepReport, "checks": checks, "fixtures": rows,
    "provenance": "Exact cartridge native LoadMap fixtures; explicit native VarSet fixture stages4050/4057; production Swift route code and immutable captured grids. No live transport or physical-device validation."]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: REPORT_PATH))
print("CHECKS", checks.count, "passed", checks.filter { $0["passed"] as! Bool }.count)
if SOURCE_REF == "working-tree" && !passed { exit(1) }
'''

DESTINATION_SWEEP = r'''
// These are pure route-policy probes over native reachable terrain. They do
// not edit the fixture state or assert that gameplay visited every coordinate.
let stationary = viewers["pallet"]!
for name in ["route1", "viridian", "downstairs", "upstairs", "mart"] {
    let original = viewers[name]!, map = Map(group: original.mapGroup, number: original.mapNumber)
    let local = original.routeAccess!.map(map, rom: read)!
    let tiles = local.reachable(from: original.tile, elevation: original.elevation).sorted()
    var forwardMissing: [[Int]] = [], reverseMissing: [[Int]] = [], asymmetric: [[Int]] = []
    for index in tiles {
        let tile = Point(x: index % local.width, y: index / local.width)
        let moved = BoundPlayerState(mapGroup: original.mapGroup, mapNumber: original.mapNumber, tile: tile,
            previousTile: tile, facing: original.facing, elevation: original.elevation, graphicsID: original.graphicsID,
            runningState: 0, tileTransitionState: 0, mapInstance: original.mapInstance,
            dynamicWarp: original.dynamicWarp, routeAccess: original.routeAccess)
        func query(_ source: BoundPlayerState, _ friend: BoundPlayerState) -> Bool {
            assets.friendRouteTarget(viewer: source, friendGroup: friend.mapGroup, friendNumber: friend.mapNumber,
                friendInstance: friend.mapInstance, friendX: Double(friend.tile.x * 16 + 8),
                friendY: Double(friend.tile.y * 16 + 16), rom: read) != nil
        }
        let forward = query(stationary, moved), reverse = query(moved, stationary), position = [tile.x, tile.y]
        if !forward { forwardMissing.append(position) }
        if !reverse { reverseMissing.append(position) }
        if forward != reverse { asymmetric.append(position) }
    }
    let row: [String: Any] = ["fixture": name, "testedTiles": tiles.count, "directedQueries": tiles.count * 2,
        "forwardUnavailable": forwardMissing, "reverseUnavailable": reverseMissing, "asymmetric": asymmetric,
        "method": "Pure hypothetical tile probes on the unmodified captured native reachable terrain; no native movement claim"]
    sweepReport.append(row)
    print("SWEEP", row)
}
'''

CURRENT_CHECKS = r'''
// The center's exact-ROM entry scripts include unsupported native specials
// and its first-visit cutscene. The friend is known, so guide to its threshold.
let center = Map(group: 5, number: 4)
for (name, x, y) in [("pallet",12,-1),("route1",13,-1),("viridian",26,26)] {
    let viewer = viewers[name]!
    require("\(name) cannot project center entry scripts", viewer.routeAccess!.map(center, rom: read) == nil)
    let target = assets.friendRouteTarget(viewer: viewer, friendGroup: center.group, friendNumber: center.number,
        friendInstance: graph.nodes[center]!.instance, friendX: 8 * 16 + 8, friendY: 6 * 16 + 16, rom: read)
    require("\(name) tracks friend in center without entering Route 1 first", target == Point(x:x * 16 + 8,y:y * 16 + 16))
}
let blocked = viewers["pallet-before-oak"]!
require("Unknown center does not bypass Oak gate", assets.friendRouteTarget(viewer:blocked,friendGroup:center.group,
    friendNumber:center.number,friendInstance:graph.nodes[center]!.instance,friendX:136,friendY:112,rom:read) == nil)
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
// The native snapshot has already moved these wandering NPCs off their ROM
// template origins. Each tile is reachable in the actual destination map;
// stale projected NPC origins must not erase the stationary player's arrow.
// These policy probes complement the separately recorded native journey.
for (name, x, y) in [("route1", 6, 28), ("viridian", 16, 22), ("mart", 6, 2)] {
    let original = viewers[name]!, map = Map(group: original.mapGroup, number: original.mapNumber)
    let local = original.routeAccess!.map(map, rom: read)!, tile = Point(x: x, y: y)
    require("\(name) wandering NPC origin is reachable in captured native terrain",
        local.reachable(from: original.tile, elevation: original.elevation).contains(y * local.width + x))
    let probe = name + "-vacated-npc-origin"
    viewers[probe] = .init(mapGroup: original.mapGroup, mapNumber: original.mapNumber, tile: tile,
        previousTile: tile, facing: original.facing, elevation: original.elevation, graphicsID: original.graphicsID,
        runningState: 0, tileTransitionState: 0, mapInstance: original.mapInstance,
        dynamicWarp: original.dynamicWarp, routeAccess: original.routeAccess)
    require("Pallet routes toward \(name) friend on vacated wandering NPC origin", route("pallet", probe) != nil)
    require("\(name) friend on vacated wandering NPC origin routes back to Pallet", route(probe, "pallet") != nil)
}
'''


if __name__ == '__main__':
    main()
