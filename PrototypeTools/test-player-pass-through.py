#!/usr/bin/env python3
"""Run source-produced collision ports against two exact-ROM native mGBA states.

Uses BOUND_GAME_SOURCE's guarded persistent runtime and pinned runner. Native
buttons and declared host ports are the only gameplay inputs. No simulator,
server, cartridge patch, coordinate write, or save conversion is performed.
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
MainActor.assumeIsolated {
    let previous = UserDefaults.standard.object(forKey: BoundLetPassButton.key)
    UserDefaults.standard.set(false, forKey: BoundLetPassButton.key)
    defer { UserDefaults.standard.set(previous, forKey: BoundLetPassButton.key) }
    let ids = [UUID(uuidString:"00000000-0000-0000-0000-000000000001")!, UUID(uuidString:"00000000-0000-0000-0000-000000000002")!]
    let snapshots = (1...2).map { i in
        let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i]))
        return BoundMovementSnapshot(raw.subdata(in: 0x23000..<0x23100))!
    }
    let sessions = [BoundWorldMovementSession(), BoundWorldMovementSession()]
    var queue:[(Int,Data)] = []
    for i in 0..<2 { sessions[i].send = { queue.append((1-i,$0)); return true } }
    func actor(_ s:BoundMovementSnapshot)->BoundMovementActor {
        .init(current:s.current,previous:s.previous,elevation:s.elevation,kind:0,identity:0)
    }
    for tick in 0..<6 {
        let now = Double(tick) * 0.05
        for i in 0..<2 {
            let s = snapshots[i], other = snapshots[1-i]
            let context = BoundWorldMovementSession.Context(local:ids[i],peer:ids[1-i],instance:s.instance,
                group:s.group,number:s.number,elevation:s.elevation,own:[actor(s)],other:[actor(other)])
            sessions[i].update(context,native:s,at:now)
            var visibility = BoundLetPassVisibility()
            precondition(!visibility.update(enabled:BoundLetPassButton.isShown,distance:s.current.distance(other.current),at:now))
        }
        while !queue.isEmpty { let (i,data) = queue.removeFirst(); sessions[i].receive(data,at:now) }
    }
    for i in 0..<2 {
        precondition(!sessions[i].passing)
        let input = sessions[i].probe.hostInput()!
        try! input.write(to: URL(fileURLWithPath: CommandLine.arguments[3]+"/host-\(i).bin"))
    }
}
'''

def main():
    p = argparse.ArgumentParser(description=__doc__)
    for key in ('rom', 'manifest', 'state-a', 'state-b', 'output'):
        p.add_argument('--'+key, type=Path, required=True)
    p.add_argument('--additional-spawn-state-a', type=Path)
    p.add_argument('--additional-spawn-state-b', type=Path)
    p.add_argument('--baseline-ref', help='Optional prior app commit to reproduce the original trapping')
    a = p.parse_args()
    if bool(a.additional_spawn_state_a) != bool(a.additional_spawn_state_b):
        p.error('Supply both additional spawn states')
    a.output = a.output.resolve(); a.output.mkdir(parents=True, exist_ok=True)
    rom = a.rom.read_bytes(); release = json.loads(a.manifest.read_text()); verify_image(rom, release)
    seeds = [a.state_a.resolve(), a.state_b.resolve()]
    for state in seeds:
        raw = state.read_bytes()
        assert len(raw) == 0x61000 and int.from_bytes(raw[8:12], 'little') == zlib.crc32(rom)
    assert tile(memory(seeds[0])) == tile(memory(seeds[1])) == (6, 6), 'Use exact native bedroom spawn states'
    pref = (ROOT/'Delta/Bound/BoundAppearancePreferences.swift').read_text()
    pref = pref[pref.index('enum BoundLetPassButton {'):pref.index('/// Retired customization-visibility')]
    visibility = (ROOT/'Delta/Bound/BoundFollowerInteraction.swift').read_text()
    visibility = visibility[visibility.index('struct BoundLetPassVisibility {'):visibility.index('@MainActor\nfinal class BoundFollowerInteractionSession')]
    def compile_model(name, model):
        directory = a.output/name; directory.mkdir(exist_ok=True)
        source = model.replace('import DeltaCore', '') + pref + visibility + SWIFT
        (directory/'main.swift').write_text(source)
        with (directory/'compile.log').open('w') as log:
            subprocess.run(['xcrun','swiftc','-module-cache-path',str(directory/'modules'),str(directory/'main.swift'),'-o',str(directory/'host')],check=True,stdout=log,stderr=subprocess.STDOUT)
        return directory/'host'
    model = (ROOT/'Delta/Bound/BoundWorldMovement.swift').read_text()
    binary = compile_model('current-source', model)
    baseline = None
    if a.baseline_ref:
        old = subprocess.check_output(['git','show',a.baseline_ref+':Delta/Bound/BoundWorldMovement.swift'],cwd=ROOT,text=True)
        baseline = compile_model('baseline-source', old)
    checks = []; traces = []; serial = 0
    def ports(states, name, executable=binary):
        out = a.output/name; out.mkdir(exist_ok=True)
        subprocess.run([str(executable),*map(str,states),str(out)],check=True)
        result = [(out/f'host-{i}.bin').read_bytes() for i in range(2)]
        if executable == binary:
            assert all(int.from_bytes(data[12:16],'little') == 1 and not any(data[68:72]+data[128:192]) for data in result)
        return result
    def drive(state, data, name, key=None, frames=45, sample=False):
        out = a.output/name; out.mkdir(parents=True,exist_ok=True)
        args = [str(GAME/'tools/qa-python'),str(GAME/'tools/map_emulator.py'),'--rom',str(a.rom.resolve()),'--state-in',str(state),'--output',str(out),'--frames',str(frames),'--rtc-ms','1735689600000','--state-out',f'{frames}:{out}/final.state']
        if key: args += ['--input',f'1:{frames}:{key}']
        if sample:
            for frame in range(1,frames): args += ['--state-out',f'{frame}:{out}/{frame}.state']
        assert not any(data[192:]) and not any(rom[0x1FC92C0:0x1FC9600])
        for offset in range(0,192,4):
            # Include zero words: a loaded state must not retain an old blocker.
            args += ['--host-port',f'0:{0x09FC9200+offset:#x}:{int.from_bytes(data[offset:offset+4],"little")}:4']
        for frame in range(6,frames,6): args += ['--host-port',f'{frame}:0x09FC9208:{1000+frame*2}:4']
        with (out/'run.log').open('w') as log:
            subprocess.run(args,cwd=GAME,stdout=log,stderr=subprocess.STDOUT,check=True)
        report = json.loads((out/'run-report.json').read_text())
        assert not report['requested_memory_writes']
        return out
    directions = {'LEFT':(-1,0),'RIGHT':(1,0),'UP':(0,-1),'DOWN':(0,1)}
    def step(states, keys, label):
        nonlocal serial
        serial += 1; name = f'{serial:03d}-{label}'; inputs = ports(states,name)
        result = []
        for i,(state,key) in enumerate(zip(states,keys)):
            start = tile(memory(state))
            if key is None:
                result.append(state); continue
            out = drive(state,inputs[i],name+f'/player-{i}-press',key,frames=35,sample=True)
            samples = [(frame,out/f'{frame}.state') for frame in range(1,35)]
            moved = [(frame,s) for frame,s in samples if tile(memory(s)) != start]
            assert moved, (label,i,'trapped',start,key)
            frame,first = moved[0]
            assert frame <= 20, (label,i,'movement delayed',frame)
            for _,s in samples[:frame]: assert not word(memory(s),0x02002014)&(32|64), (label,'peer collision or nearby reservation')
            settled = drive(first,inputs[i],name+f'/player-{i}-release')/'final.state'
            expected = tuple(x+d for x,d in zip(start,directions[key]))
            assert tile(memory(settled)) == expected, (label,i,start,key,tile(memory(settled)),expected)
            assert not word(memory(settled),0x02002014)&(32|64)
            traces.append({'case':label,'player':i,'from':start,'to':expected,'firstMovementFrame':frame})
            result.append(settled)
        checks.append(label)
        print(label, [tile(memory(s)) for s in result], flush=True)
        return result
    # The untouched native spawn has a chair immediately north. Both roles
    # separate immediately in either horizontal direction, then exercise the
    # two vertical escapes on the adjacent open tile reached by real walking.
    for first,second in [('LEFT','RIGHT'),('RIGHT','LEFT')]:
        step(seeds,[first,second],'spawn-apart-'+first+'-'+second)
    open_tile = step(seeds,['LEFT','LEFT'],'walk-together-to-open-tile')
    for first,second in [('UP','DOWN'),('DOWN','UP')]:
        step(open_tile,[first,second],'overlap-apart-'+first+'-'+second)
    # Both roles cross a stationary peer in both directions on both axes,
    # entering the occupied tile and leaving it on the very next button step.
    for axis,back,forward in [('horizontal','LEFT','RIGHT'),('vertical','UP','DOWN')]:
        for moving in (0,1):
            for start_direction,cross_direction in [(back,forward),(forward,back)]:
                states = list(seeds)
                # x=5 avoids the native chair above the bedroom carpet.
                if axis == 'vertical': states = step(states,['LEFT','LEFT'],f'{axis}-{moving}-{start_direction}-position')
                keys = [None,None]; keys[moving] = start_direction
                states = step(states,keys,f'{axis}-{moving}-{start_direction}-approach')
                keys[moving] = cross_direction
                states = step(states,keys,f'{axis}-{moving}-{cross_direction}-enter-partner')
                assert tile(memory(states[0])) == tile(memory(states[1]))
                step(states,keys,f'{axis}-{moving}-{cross_direction}-exit-partner')
    # Simultaneous head-on crossings exercise both incoming and departure tiles.
    for axis,back,forward in [('horizontal','LEFT','RIGHT'),('vertical','UP','DOWN')]:
        for reverse in (False,True):
            states = list(seeds)
            if axis == 'vertical': states = step(states,['LEFT','LEFT'],f'{axis}-{reverse}-center')
            outward = [forward,back] if reverse else [back,forward]
            inward = list(reversed(outward))
            states = step(states,outward,f'{axis}-{reverse}-separate')
            states = step(states,inward,f'{axis}-{reverse}-meet')
            assert tile(memory(states[0])) == tile(memory(states[1]))
            step(states,inward,f'{axis}-{reverse}-pass')
    # Existing native furniture must remain solid: chair directly above spawn.
    wall = seeds
    wallports = ports(wall,'native-chair-ports')
    for i in range(2):
        out = drive(wall[i],wallports[i],f'native-chair-{i}','UP',frames=60)
        assert tile(memory(out/'final.state')) == (6,6), 'Native furniture collision must remain intact'
    checks.append('native-furniture-remains-solid-for-both-players')
    if baseline:
        oldports = ports(seeds,'baseline-overlap-ports',baseline)
        for i,key in enumerate(['LEFT','RIGHT']):
            out = drive(seeds[i],oldports[i],f'baseline-overlap-{i}',key,frames=60)
            assert tile(memory(out/'final.state')) == (6,6), 'Baseline must reproduce overlap trap'
        # A target beside the peer is blocked by the old proximity negotiation.
        near = step(seeds,['LEFT',None],'baseline-near-prepare')
        oldports = ports(near,'baseline-buffer-ports',baseline)
        out = drive(near[0],oldports[0],'baseline-buffer','UP',frames=60)
        assert tile(memory(out/'final.state')) == (5,6), 'Baseline must reproduce one-tile buffer'
        step(near,['UP',None],'fixed-buffer-entry')
        checks += ['baseline-overlap-trap-reproduced','baseline-nearby-buffer-reproduced']
    additional = []
    if a.additional_spawn_state_a:
        additional = [a.additional_spawn_state_a.resolve(), a.additional_spawn_state_b.resolve()]
        for state in additional:
            raw = state.read_bytes()
            assert len(raw) == 0x61000 and int.from_bytes(raw[8:12], 'little') == zlib.crc32(rom)
        assert tile(memory(additional[0])) == tile(memory(additional[1]))
        for first, second in [('LEFT','RIGHT'),('RIGHT','LEFT')]:
            step(additional,[first,second],'additional-native-spawn-apart-'+first+'-'+second)
    result = {'passed':True,'letPassHidden' :True,'letPassRequests':0,'checks':checks,'nativeSteps':traces,
              'romSHA256':hashlib.sha256(rom).hexdigest(),'stateSHA256':[hashlib.sha256(s.read_bytes()).hexdigest() for s in seeds+additional],
              'appMovementSHA256':hashlib.sha256(model.encode()).hexdigest(),'contract':release['contract'],
              'runnerProvenance':json.loads((GAME/'.tools/build/map_emulator/provenance.json').read_text()),
              'limits':'Two isolated exact-ROM mGBA instances with source Swift coordinator ports and native button movement. Local deterministic transport; no physical-device, Delta/VBA-M runtime or WAN verification. Sprite rendering is covered separately by follower compositor tests.'}
    (a.output/'acceptance.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'passed':True,'cases':len(checks),'nativeSteps':len(traces),'romSHA256':result['romSHA256']}))

if __name__ == '__main__': main()
