#!/usr/bin/env python3
"""Exercise production Swift occupancy ports with exact-ROM native button input.

Two persistent Swift sessions observe two independent native mGBA states. Trainer
positions come from those states; follower cases identify the same declared peer
position as a follower and move its trainer away. No native coordinate, terrain,
save, collision routine, or cartridge instruction is changed. Outputs are private
test artifacts, never ordinary app/simulator/server data.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
GAME = Path(os.environ['BOUND_GAME_SOURCE']).resolve()
sys.path.insert(0, str(GAME / 'tools'))
from integrated_game import verify_image
from verify_integrated_gameplay import memory
from game_presence_field import tile, word

SWIFT = r'''
struct BoundPlayerState { struct Point { let x:Int,y:Int } }
final class EmulatorCore {}
enum BoundVBABattleBridge {
    static func setWorldMovementHost(_ d:Data) {}
    static func worldMovementSnapshot()->Data { Data() }
    static func worldMovementPublicationInProgress()->Bool { false }
    static func worldMovementTimeline()->UInt64 { 0 }
    static func requestWorldMovementRevocation() {}
}
struct Command:Decodable { let states:[String],output:String,mode:String,reset:Bool }
MainActor.assumeIsolated {
    let previous = UserDefaults.standard.object(forKey:BoundLetPassButton.key)
    UserDefaults.standard.set(false,forKey:BoundLetPassButton.key)
    defer { UserDefaults.standard.set(previous,forKey:BoundLetPassButton.key) }
    let ids = [UUID(uuidString:"00000000-0000-0000-0000-000000000001")!, UUID(uuidString:"00000000-0000-0000-0000-000000000002")!]
    var sessions:[BoundWorldMovementSession] = []
    var queue:[(Int,Data)] = []
    var clock = 0.0
    func actor(_ s:BoundMovementSnapshot,kind:Int=0)->BoundMovementActor {
        .init(current:s.current,previous:s.previous,elevation:s.elevation,kind:kind,identity:kind==0 ? 0:123456)
    }
    while let line=readLine() {
        let command=try! JSONDecoder().decode(Command.self,from:Data(line.utf8))
        if command.reset || sessions.isEmpty {
            sessions=[BoundWorldMovementSession(),BoundWorldMovementSession()];queue=[]
            for i in 0..<2 { sessions[i].send = { queue.append((1-i,$0));return true } }
        }
        let snapshots=command.states.map { path in
            let data=try! Data(contentsOf:URL(fileURLWithPath:path))
            return BoundMovementSnapshot(data.subdata(in:0x23000..<0x23100))!
        }
        for _ in 0..<20 {
            clock += 0.05
            for i in 0..<2 {
                let s=snapshots[i],peer=snapshots[1-i]
                let far=BoundMovementActor(current:.init(x:1000,y:1000),previous:.init(x:1000,y:1000),elevation:s.elevation,kind:0,identity:0)
                let peers = command.mode=="none" ? [far] : command.mode=="follower" ? [far,actor(peer,kind:1)] : [actor(peer)]
                let c=BoundWorldMovementSession.Context(local:ids[i],peer:ids[1-i],instance:s.instance,
                    group:s.group,number:s.number,elevation:s.elevation,own:[actor(s)],other:peers)
                sessions[i].probe.record(s)
                sessions[i].update(c,native:s,at:clock)
                precondition(!BoundLetPassButton.isShown)
            }
            while !queue.isEmpty { let (i,data)=queue.removeFirst();sessions[i].receive(data,at:clock) }
            if sessions.allSatisfy({ !$0.reconnecting && $0.probe.hostInput() != nil }) { break }
        }
        for i in 0..<2 {
            guard let data=sessions[i].probe.hostInput() else {
                fatalError("Missing host input role \(i), reconnecting \(sessions[i].reconnecting), flags \(snapshots[i].flags), generation \(snapshots[i].generation), epoch \(sessions[i].probe.epoch())")
            }
            precondition(BoundMovementSnapshot.word(data,12)==1,"Proximity negotiation must stay disabled")
            try! data.write(to:URL(fileURLWithPath:command.output+"/host-\(i).bin"))
        }
        print("READY");fflush(stdout)
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('rom', 'manifest', 'state-a', 'state-b', 'output'):
        parser.add_argument('--' + key, type=Path, required=True)
    parser.add_argument('--debug-state-a', type=Path)
    parser.add_argument('--debug-state-b', type=Path)
    args = parser.parse_args()
    if bool(args.debug_state_a) != bool(args.debug_state_b):
        parser.error('Supply both debug spawn states')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    rom = args.rom.read_bytes()
    release = json.loads(args.manifest.read_text())
    verify_image(rom, release)
    seeds = [args.state_a.resolve(), args.state_b.resolve()]
    debug = [args.debug_state_a.resolve(), args.debug_state_b.resolve()] if args.debug_state_a else []
    for state in seeds + debug:
        raw = state.read_bytes()
        assert len(raw) == 0x61000 and int.from_bytes(raw[8:12], 'little') == zlib.crc32(rom)
    assert all(tile(memory(s)) == (6, 6) for s in seeds), 'Requires native bedroom spawn states'
    model = (ROOT / 'Delta/Bound/BoundWorldMovement.swift').read_text()
    pref = (ROOT / 'Delta/Bound/BoundAppearancePreferences.swift').read_text()
    pref = pref[pref.index('enum BoundLetPassButton {'):pref.index('/// Retired customization-visibility')]
    source = args.output / 'main.swift'
    source.write_text(model.replace('import DeltaCore', '') + pref + SWIFT)
    executable = args.output / 'host'
    with (args.output / 'compile.log').open('w') as log:
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(args.output / 'modules'), str(source), '-o', str(executable)], check=True, stdout=log, stderr=subprocess.STDOUT)
    checks, traces = [], []
    serial = 0
    host_log = (args.output / 'host.log').open('w')
    host = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=host_log, text=True)

    def ports(states, label, mode='trainer', reset=False):
        nonlocal serial
        serial += 1
        out = args.output / f'{serial:03d}-{label}'
        out.mkdir()
        host.stdin.write(json.dumps(dict(states=list(map(str, states)), output=str(out), mode=mode, reset=reset)) + '\n')
        host.stdin.flush()
        assert host.stdout.readline().strip() == 'READY', 'Swift source host failed; see host.log'
        return out, [(out / f'host-{i}.bin').read_bytes() for i in range(2)]

    def drive(state, data, output, key=None, frames=35, sample=False):
        output.mkdir(parents=True, exist_ok=False)
        command = [str(GAME / 'tools/qa-python'), str(GAME / 'tools/map_emulator.py'), '--rom', str(args.rom.resolve()), '--state-in', str(state), '--output', str(output), '--frames', str(frames), '--rtc-ms', '1735689600000', '--state-out', f'{frames}:{output}/final.state']
        if key:
            command += ['--input', f'1:{frames}:{key}']
        if sample:
            for frame in range(1, frames):
                command += ['--state-out', f'{frame}:{output}/{frame}.state']
        assert len(data) == 1024 and not any(data[192:]) and not any(rom[0x1FC92C0:0x1FC9600])
        for offset in range(0, 192, 4):
            command += ['--host-port', f'0:{0x09FC9200 + offset:#x}:{int.from_bytes(data[offset:offset + 4], "little")}:4']
        for frame in range(6, frames, 6):
            command += ['--host-port', f'{frame}:0x09FC9208:{1000 + frame * 2}:4']
        with (output / 'run.log').open('w') as log:
            subprocess.run(command, cwd=GAME, check=True, stdout=log, stderr=subprocess.STDOUT)
        report = json.loads((output / 'run-report.json').read_text())
        assert not report['requested_memory_writes']
        return output / 'final.state'

    def first_movement(out, start):
        return next(((f, out / f'{f}.state') for f in range(1, 35) if tile(memory(out / f'{f}.state')) != start), None)

    def movement_completion(out, start):
        for frame in range(1, 35):
            state = out / f'{frame}.state'
            data = state.read_bytes()
            if tile(memory(state)) != start and data[0x23024:0x23028] == data[0x23028:0x2302C]:
                return frame
        raise AssertionError('Native animation did not finish within 34 frames')

    directions = {'LEFT': (-1, 0), 'RIGHT': (1, 0), 'UP': (0, -1), 'DOWN': (0, 1)}
    opposite = {'LEFT': 'RIGHT', 'RIGHT': 'LEFT', 'UP': 'DOWN', 'DOWN': 'UP'}

    def step(states, keys, label, mode='trainer', reset=False, blocked=False, compare=True, running=False):
        out, inputs = ports(states, label, mode, reset)
        result = list(states)
        for i, key in enumerate(keys):
            if key is None:
                continue
            start = tile(memory(states[i]))
            press = out / f'player-{i}-press'
            input_keys = 'B,' + key if running else key
            final = drive(states[i], inputs[i], press, input_keys, sample=True)
            moved = first_movement(press, start)
            if blocked:
                assert moved is None and tile(memory(final)) == start, (label, i, 'entered solid occupied tile')
                assert any(word(memory(press / f'{f}.state'), 0x02002014) & 32 for f in range(1, 35)), (label, 'missing native peer block')
                result[i] = final
                traces.append(dict(case=label, player=i, blocked=True, origin=start, runningRequested=running))
                continue
            assert moved is not None, (label, i, 'trapped', start, key)
            frame, first = moved
            completion = movement_completion(press, start)
            assert frame <= 20, (label, i, 'movement delayed', frame)
            assert all(not word(memory(press / f'{f}.state'), 0x02002014) & (32 | 64) for f in range(1, frame + 1)), (label, i, 'unexpected peer/proximity block')
            baseline_frame = None
            if compare:
                baseline = out / f'player-{i}-baseline'
                drive(states[i], bytes(1024), baseline, input_keys, sample=True)
                baseline_result = first_movement(baseline, start)
                assert baseline_result is not None
                baseline_frame = baseline_result[0]
                assert frame <= baseline_frame + 1, (label, i, 'added input latency', frame, baseline_frame)
                assert completion <= movement_completion(baseline, start) + 1, (label, i, 'delayed native animation')
            settled = drive(first, inputs[i], out / f'player-{i}-release', frames=45)
            expected = tuple(x + d for x, d in zip(start, directions[key]))
            assert tile(memory(settled)) == expected, (label, i, start, key, tile(memory(settled)), expected)
            settled_data = settled.read_bytes()
            assert settled_data[0x23024:0x23028] == settled_data[0x23028:0x2302C], (label, 'native previous tile did not settle')
            result[i] = settled
            walk_frame = walk_completion = None
            if running and 'beside-pass' in label:
                walk = out / f'player-{i}-walking-comparison'
                drive(states[i], bytes(1024), walk, key, sample=True)
                walk_frame = first_movement(walk, start)[0]
                walk_completion = movement_completion(walk, start)
            traces.append(dict(case=label, player=i, blocked=False, origin=start, target=expected,
                               firstMovementFrame=frame, baselineFrame=baseline_frame,
                               runningRequested=running, walkingComparisonFrame=walk_frame,
                               movementCompletionFrame=completion, walkingCompletionFrame=walk_completion,
                               nativeAvatarFlagsAtStart=first.read_bytes()[0x58078],
                               nativeSettledPreviousEqualsCurrent=True))
        checks.append(label)
        print(label, [tile(memory(s)) for s in result], flush=True)
        return result

    try:
        # The native bedroom chair north of spawn remains terrain-authoritative.
        _, inputs = ports(seeds, 'native-chair', reset=True)
        for i in range(2):
            final = drive(seeds[i], inputs[i], args.output / f'chair-{i}', 'UP', frames=60)
            assert tile(memory(final)) == (6, 6)
        checks.append('native-chair-remains-solid-for-both-players')

        for first, second in [('LEFT', 'RIGHT'), ('RIGHT', 'LEFT')]:
            step(seeds, [first, second], 'spawn-apart-' + first, reset=True)
        center = step(seeds, ['LEFT', 'LEFT'], 'overlap-same-direction-left-first', reset=True)
        carpet = list(center)
        center = step(center, ['LEFT', 'LEFT'], 'overlap-same-direction-left-again')
        floor_edge = list(center)
        assert all(tile(memory(s)) == (4, 6) for s in center)
        for direction in directions:
            states = step(center, [direction, direction], 'overlap-together-' + direction, reset=True)
            step(states, [opposite[direction], opposite[direction]], 'overlap-together-return-' + direction)
        for first, second in [('UP', 'DOWN'), ('DOWN', 'UP')]:
            step(center, [first, second], 'overlap-apart-' + first, reset=True)

        # Distinct frames of an existing overlap must not trap the slower role.
        for direction in directions:
            out, inputs = ports(center, 'stagger-start-' + direction, reset=True)
            pressed = out / 'leader-press'
            drive(center[0], inputs[0], pressed, direction, sample=True)
            moved = first_movement(pressed, tile(memory(center[0])))
            assert moved
            in_flight = [moved[1], center[1]]
            # An in-flight native sample can be between seqlock publications;
            # choose the first completed sample at/after native displacement.
            for frame in range(moved[0], 35):
                candidate = pressed / f'{frame}.state'
                data = candidate.read_bytes()
                seq = int.from_bytes(data[0x23008:0x2300C], 'little')
                if seq and not seq & 1:
                    in_flight[0] = candidate
                    break
            step(in_flight, [None, direction], 'overlap-stagger-follower-' + direction)

        # Each kind is exercised from both client roles, in all cardinal
        # directions. A native follower pose is represented by the kind-1 port;
        # this tests collision policy, not native follower selection/rendering.
        for running in (False, True):
            speed = 'run' if running else 'walk'
            for kind in ('trainer', 'follower'):
                for role in (0, 1):
                    for direction in directions:
                        label = f'{speed}-{kind}-{role}-{direction}'
                        keys = [None, None]
                        keys[role] = opposite[direction]
                        separated = step(center, keys, label + '-separate', mode=kind, reset=True, running=running)
                        keys[role] = direction
                        step(separated, keys, label + '-solid-entry', mode=kind, blocked=True, running=running)
                        # Travel across the neighboring row/column from either
                        # side without entering the peer's actual occupied tile.
                        side = 'UP' if direction in ('LEFT', 'RIGHT') else 'LEFT'
                        keys[role] = side
                        beside = step(separated, keys, label + '-beside-approach', mode=kind, running=running)
                        keys[role] = direction
                        beside = step(beside, keys, label + '-beside-pass', mode=kind, running=running)
                        step(beside, keys, label + '-beside-exit', mode=kind, running=running)
            for direction in directions:
                together = step(center, [direction, direction], speed + '-overlap-together-' + direction, reset=True, running=running)
                step(together, [opposite[direction], opposite[direction]], speed + '-overlap-return-' + direction, running=running)

        # Native elevation zero is the ground wildcard, not a separate floor.
        # Real bedroom carpet/floor edges exercise both directions of 0 <-> 3.
        for kind in ('trainer', 'follower'):
            for role in (0, 1):
                for origin, away, toward in [(carpet, 'LEFT', 'RIGHT'), (floor_edge, 'RIGHT', 'LEFT')]:
                    label = f'elevation-{kind}-{role}-{away}'
                    keys = [None, None]
                    keys[role] = away
                    separated = step(origin, keys, label + '-separate', mode=kind, reset=True)
                    keys[role] = toward
                    step(separated, keys, label + '-solid-entry', mode=kind, blocked=True)

        if debug:
            assert tile(memory(debug[0])) == tile(memory(debug[1]))
            for first, second in [('LEFT', 'RIGHT'), ('RIGHT', 'LEFT')]:
                step(debug, [first, second], 'debug-spawn-apart-' + first, reset=True)
            together = step(debug, ['LEFT', 'LEFT'], 'debug-spawn-together', reset=True)
            step(together, ['LEFT', 'LEFT'], 'debug-spawn-together-again')
        result = dict(passed=True, letPassHidden=True, letPassRequests=0, checks=checks, nativeSteps=traces,
                      romSHA256=hashlib.sha256(rom).hexdigest(), appMovementSHA256=hashlib.sha256(model.encode()).hexdigest(),
                      stateSHA256=[hashlib.sha256(s.read_bytes()).hexdigest() for s in seeds + debug], contract=release['contract'],
                      runnerProvenance=json.loads((GAME / '.tools/build/map_emulator/provenance.json').read_text()),
                      limits='Two exact-ROM mGBA instances with production Swift sessions/probe and native DPad input. Follower occupancy is a synthetic kind-1 peer pose. Deterministic local transport; no physical-device, Delta/VBA-M gameplay, WAN, or native follower rendering claim.')
        result['nativeRunningObserved'] = any(t.get('walkingCompletionFrame') and t['movementCompletionFrame'] < t['walkingCompletionFrame'] and t['nativeAvatarFlagsAtStart'] & 128 for t in traces)
        (args.output / 'acceptance.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(dict(passed=True, checks=len(checks), nativeSteps=len(traces))))
    finally:
        host.stdin.close()
        host.wait(timeout=10)
        host_log.close()


if __name__ == '__main__':
    main()
