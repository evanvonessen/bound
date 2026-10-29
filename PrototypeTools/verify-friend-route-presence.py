#!/usr/bin/env python3
"""Check both arrows from real published poses decoded from exact-ROM states.

Run through qa-python with explicit BOUND_GAME_SOURCE. No emulator state is
changed. The actual state/scene/presence/route implementations are compiled;
only native-I/O adapters requiring an app profile are omitted. Hidden or menu
samples are reported separately rather than counted as published arrow tests.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import zlib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rom', type=Path, required=True)
    parser.add_argument('--pairs-report', type=Path, required=True)
    parser.add_argument('--transition-states', type=Path, action='append', default=[],
                        help='Also inspect every frame-*.state in this directory')
    parser.add_argument('--stationary', default='stationary-p1')
    parser.add_argument('--require-published', nargs='+', default=[],
                        help='Checkpoints that must decode to published poses, in addition to the stationary player')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-ref', help='Existing Git revision for before/after evidence')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    args.rom = args.rom.resolve(strict=True)
    image = args.rom.read_bytes()
    rom_hash = hashlib.sha256(image).hexdigest()
    manifest = json.loads(args.pairs_report.read_text())
    assert manifest['romSHA256'] == rom_hash
    fixtures, pairs = list(manifest['fixtures']), list(manifest['pairs'])
    known = {str(Path(row['state']).resolve()) for row in fixtures}
    assert args.stationary in {row['name'] for row in fixtures}
    for directory in args.transition_states:
        paths = sorted(directory.glob('frame-*.state'))
        assert paths, 'No transition states in ' + str(directory)
        for path in paths:
            if str(path.resolve()) in known:
                continue
            raw = path.read_bytes()
            save = struct.unpack_from('<I', raw, 0x19000 + 0x5008)[0] - 0x02000000 + 0x21000
            group, number = struct.unpack_from('<BB', raw, save + 4)
            name = directory.name + '-' + path.stem
            fixtures.append(dict(name=name, group=group, number=number, state=str(path.resolve()),
                                 sha256=hashlib.sha256(raw).hexdigest()))
            pairs.append({'name': name, 'from': args.stationary, 'to': name})
            known.add(str(path.resolve()))
    for fixture in fixtures:
        raw = Path(fixture['state']).read_bytes()
        assert hashlib.sha256(raw).hexdigest() == fixture['sha256']
        assert len(raw) == 0x61000 and struct.unpack_from('<I', raw, 8)[0] == zlib.crc32(image)

    source_hashes = {}

    def read(path):
        source = subprocess.check_output(['git', 'show', args.source_ref + ':' + path], cwd=root, text=True) \
            if args.source_ref else (root / path).read_text()
        source_hashes[path] = hashlib.sha256(source.encode()).hexdigest()
        return source

    def cut(source, start, end):
        return source[source.index(start):source.index(end)]

    state = read('Delta/Bound/BoundPlayerState.swift')
    declarations = cut(state, 'struct BoundPlayerState:', 'final class BoundPlayerROMProfile')
    declarations += cut(state, 'struct BoundGBAMemorySnapshot:', 'enum BoundPlayerStateDecoder')
    scene = read('Delta/Bound/BoundPlayerScene.swift')
    declarations += cut(scene, 'struct BoundPlayerScene:', '/// Small bounded ROM-only cache')
    declarations += read('Delta/Bound/BoundFriendRouteAccess.swift')
    adapter = scene[scene.index('/// Small bounded ROM-only cache'):]
    start = adapter.index('    static func read(player: BoundPlayerState, memory: BoundGBAMemorySnapshot, profile:')
    end = adapter.index('    static func read(player: BoundPlayerState, memory: BoundGBAMemorySnapshot,\n', start + 1)
    declarations += adapter[:start] + adapter[end:]
    decoder = cut(state, 'enum BoundPlayerStateDecoder {', 'struct BoundPlayerPresenceTracker')
    start = decoder.index('    static func read(profile:')
    end = decoder.index('    /// Pure decoder seam', start)
    declarations += decoder[:start] + decoder[end:]
    declarations += cut(read('Delta/Bound/BoundAppearancePreferences.swift'), 'enum BoundMultiplayerFeatures {', '/// Retired customization-visibility')
    declarations += cut(read('Delta/Bound/BoundBattleLosses.swift'), '/// Presentation history', '/// Each device always')
    declarations += cut(read('Delta/Bound/BoundSoulLink.swift'), 'struct BoundSoulIdentity:', '/// The frame owner commits')
    declarations += read('Delta/Bound/BoundSoulExtras.swift') + read('Delta/Bound/BoundSoulLinks.swift')
    follower = read('Delta/Bound/BoundPresenceFollower.swift')
    declarations += follower[:follower.index('    func rendered(profile:')] + '}\n'
    pose = cut(read('Delta/Bound/BoundLivePresence.swift'), 'struct BoundPresencePose:', '/// Main-actor, bounded receive buffer')
    declarations += pose[:pose.index('    func rendered(profile:')] + '}\n' + pose[pose.index('struct BoundPresenceCollision:'):]
    declarations += cut(read('Delta/Bound/BoundFriendInteraction.swift'), 'struct BoundFriendWorldPosition:', '/// A separate namespace')
    declarations += cut(read('Delta/Bound/BoundRecordedPlayer.swift'), 'struct BoundRecordedPlayerPose:', '/// A bounded, memory-only recording')
    source = 'import Foundation\nimport CryptoKit\nimport SwiftUI\n' + declarations
    source += '\nlet fixtureJSON = ' + json.dumps(json.dumps(fixtures)) + '\n'
    source += '\nlet pairJSON = ' + json.dumps(json.dumps(pairs)) + '\n'
    source += '\nlet sourceHashesJSON = ' + json.dumps(json.dumps(source_hashes)) + '\n'
    required = sorted(set(args.require_published + manifest.get('requiredPublished', []) + [args.stationary]))
    assert set(required).issubset({row['name'] for row in fixtures}), 'Missing required checkpoint'
    source += '\nlet requiredPublished: [String] = ' + json.dumps(required) + '\n'
    source += SWIFT.replace('ROM_PATH', json.dumps(str(args.rom))).replace('REPORT_PATH', json.dumps(str(args.output / 'presence-routes.json'))).replace('SOURCE_REF', json.dumps(args.source_ref or 'working-tree'))
    swift = args.output / 'main.swift'
    swift.write_text(source)
    binary = args.output / 'friend-route-presence'
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(args.output / 'modules'), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    assert hashlib.sha256(args.rom.read_bytes()).hexdigest() == rom_hash
    assert all(hashlib.sha256(Path(row['state']).read_bytes()).hexdigest() == row['sha256'] for row in fixtures)


SWIFT = r'''
let rom = try Data(contentsOf: URL(fileURLWithPath: ROM_PATH))
func read(_ address: Int, _ count: Int) -> [UInt8]? {
    let offset = address - 0x08000000
    guard offset >= 0, count >= 0, offset <= rom.count, count <= rom.count - offset else { return nil }
    return Array(rom[offset..<offset + count])
}
let assets = BoundPlayerSceneAssets()
assets.prepareFriendRoutes(rom: read)
let graph = BoundFriendRouteGraph(rom: read)
let fixtures = try JSONSerialization.jsonObject(with: Data(fixtureJSON.utf8)) as! [[String: Any]]
let pairs = try JSONSerialization.jsonObject(with: Data(pairJSON.utf8)) as! [[String: Any]]
var players: [String: BoundPlayerState] = [:], poses: [String: BoundPresencePose] = [:]
var observations: [[String: Any]] = [], routes: [[String: Any]] = []
for fixture in fixtures {
    let name = fixture["name"] as! String, path = fixture["state"] as! String
    let raw = try Data(contentsOf: URL(fileURLWithPath: path))
    let memory = BoundGBAMemorySnapshot(copyingWorkRAM: raw.subdata(in: 0x21000..<0x61000), internalRAM: raw.subdata(in: 0x19000..<0x21000))!
    let observed = BoundPlayerStateDecoder.decode(memory: memory, frame: 1, romBytes: read)
    var row: [String: Any] = ["name": name, "state": path, "sha256": fixture["sha256"]!, "status": observed.status.rawValue, "detail": observed.detail, "publishable": false]
    if var player = observed.player {
        let pointer = memory.bytes(at: 0x03005008, count: 4)!
        let save = pointer.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        player.routeAccess = BoundFriendRouteAccess.capture(memory: memory, save: save,
            currentMap: .init(group: player.mapGroup, number: player.mapNumber), rom: read)
        player.scene = BoundPlayerSceneDecoder.read(player: player, memory: memory, rom: read, assets: assets)
        let reading = BoundPlayerStateReading(frame: 1, status: observed.status, detail: observed.detail, player: player)
        row["tile"] = [player.tile.x, player.tile.y]
        row["map"] = [player.mapGroup, player.mapNumber]
        if let pose = BoundPresencePose(reading: reading) {
            players[name] = player; poses[name] = pose
            row["publishable"] = true
            row["foot"] = [pose.x, pose.y]
            row["routeTile"] = [Int(floor((pose.x - 8) / 16)), Int(floor((pose.y - 16) / 16))]
        }
    }
    observations.append(row)
}
for pair in pairs {
    let name = pair["name"] as! String, first = pair["from"] as! String, second = pair["to"] as! String
    for (from, to, direction) in [(first, second, "forward"), (second, first, "reverse")] {
        var row: [String: Any] = ["checkpoint": name, "direction": direction, "from": from, "to": to, "tested": false]
        if let viewer = players[from], poses[from] != nil, let friend = poses[to] {
            let target = assets.friendRouteTarget(viewer: viewer, friendGroup: friend.mapGroup, friendNumber: friend.mapNumber,
                friendInstance: friend.mapInstance, friendX: friend.x, friendY: friend.y, rom: read)
            row["tested"] = true; row["available"] = target != nil
            row["sourceTile"] = [viewer.tile.x, viewer.tile.y]
            row["destinationFoot"] = [friend.x, friend.y]
            row["destinationTile"] = [Int(floor((friend.x - 8) / 16)), Int(floor((friend.y - 16) / 16))]
            row["target"] = target.map { [($0.x - 8) / 16, ($0.y - 16) / 16] } ?? []
            let sourceMap = BoundPlayerMapConnections.Map(group: viewer.mapGroup, number: viewer.mapNumber)
            let destinationMap = BoundPlayerMapConnections.Map(group: friend.mapGroup, number: friend.mapNumber)
            let targetTile = target.map { BoundPlayerState.Point(x: ($0.x - 8) / 16, y: ($0.y - 16) / 16) }
            var usable = false, correctDirection = false
            if sourceMap == destinationMap {
                usable = target == .init(x: Int(friend.x), y: Int(friend.y)); correctDirection = usable
            } else if let tile = targetTile, let access = viewer.routeAccess?.map(sourceMap, rom: read) {
                let exits = graph.nodes[sourceMap]!.edges.filter { $0.waypoint(from: tile) == tile }
                let distances = access.walkingDistances(from: viewer.tile, elevation: viewer.elevation)
                usable = exits.contains { edge in
                    edge.direction == 0
                        ? access.warpDistance(to: tile, distances: distances, elevation: viewer.elevation, eventElevation: edge.warpElevation) != nil
                        : access.walkingDistance(to: tile, distances: distances) != nil
                }
                // Independently known first transitions for the Pallet/Route1/
                // Viridian/Center journey. Other supplied pairs still require
                // a real, reachable native portal.
                let pallet = BoundPlayerMapConnections.Map(group: 3, number: 0)
                let route1 = BoundPlayerMapConnections.Map(group: 3, number: 19)
                let city = BoundPlayerMapConnections.Map(group: 3, number: 1)
                let center = BoundPlayerMapConnections.Map(group: 5, number: 4)
                let expected: BoundPlayerMapConnections.Map?
                if sourceMap == pallet && [route1, city, center].contains(destinationMap) { expected = route1 }
                else if sourceMap == route1 && destinationMap == pallet { expected = pallet }
                else if sourceMap == city && destinationMap == pallet { expected = route1 }
                else if sourceMap == center && destinationMap == pallet { expected = city }
                else { expected = nil }
                correctDirection = expected.map { wanted in exits.contains { $0.destination == wanted } } ?? !exits.isEmpty
                if sourceMap == pallet && viewer.tile == .init(x: 10, y: 10) && expected == route1 {
                    correctDirection = correctDirection && tile == .init(x: 12, y: -1)
                }
                if sourceMap == center && expected == city { correctDirection = correctDirection && tile == .init(x: 7, y: 8) }
                if let expectedTarget = pair[direction + "Target"] as? [Int] {
                    correctDirection = correctDirection && tile == .init(x: expectedTarget[0], y: expectedTarget[1])
                }
            }
            row["usableTarget"] = usable; row["correctFirstTransition"] = correctDirection
            row["passed"] = target != nil && usable && correctDirection
            if target == nil { print("FAIL", name, direction, "published pose has no route") }
            else if !usable || !correctDirection { print("FAIL", name, direction, "route does not select a usable correct exit") }
        } else { row["skipReason"] = "One or both native snapshots do not publish a presence pose" }
        routes.append(row)
    }
}
let missingPublished = requiredPublished.filter { poses[$0] == nil }
for name in missingPublished { print("FAIL", name, "required checkpoint did not publish a pose") }
let tested = routes.filter { $0["tested"] as! Bool }, failures = tested.filter { !($0["passed"] as! Bool) }
let passed = !tested.isEmpty && failures.isEmpty && missingPublished.isEmpty
let result: [String: Any] = ["passed": passed, "sourceRef": SOURCE_REF,
    "romSHA256": SHA256.hash(data: rom).map { String(format: "%02x", $0) }.joined(),
    "sourceSHA256": try JSONSerialization.jsonObject(with: Data(sourceHashesJSON.utf8)),
    "observations": observations, "routes": routes, "directedQueries": tested.count, "failedQueries": failures.count,
    "requiredPublished": requiredPublished, "missingPublished": missingPublished,
    "provenance": "Exact native snapshots through production state decoder, scene decoder, BoundPresencePose and friend route code. Hidden/menu snapshots excluded from arrow counts. No live transport or physical-device claim."]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: REPORT_PATH))
print("Published-pose arrow checks", tested.count, "passed", tested.count - failures.count, "skipped", routes.count - tested.count)
if SOURCE_REF == "working-tree" && !passed { exit(1) }
'''


if __name__ == '__main__':
    main()
