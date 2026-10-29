#!/usr/bin/env python3
"""Replay Pallet -> Viridian Center -> PC withdrawal -> outside with native inputs.

Use qa-python and explicit BOUND_GAME_SOURCE, --rom, --state and --output.
The seed is a disposable Pallet (10,10) fixture from verify-friend-route-exits.
Initial preparation creates one party member and one boxed Pikachu using native
APIs and enables native Infinite Repel. All subsequent travel, PC menus and
withdrawal use ordinary buttons. No position, collision or outcome is patched.
The output pairs.json can be checked with verify-friend-route-exits.py.
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


def memory(raw, address, count):
    if 0x02000000 <= address < 0x02040000:
        offset = address - 0x02000000 + 0x21000
    elif 0x03000000 <= address < 0x03008000:
        offset = address - 0x03000000 + 0x19000
    else:
        raise ValueError(hex(address))
    return raw[offset:offset + count]


def observation(path):
    raw = path.read_bytes()
    save = int.from_bytes(memory(raw, 0x03005008, 4), 'little')
    return dict(state=str(path), map=list(memory(raw, save + 4, 2)),
                tile=list(struct.unpack('<hh', memory(raw, save, 4))),
                party=memory(raw, 0x02024029, 1)[0], sha256=digest(path))


# Every coordinate is asserted after running the cartridge. Timings were
# recorded on pinned mGBA 0.10.5 with the declared synthetic fixture only.
STEPS = [
    ('pallet-north', 300, ['1:17:RIGHT', '50:200:UP'], [3, 0], [11, 2]),
    ('pallet-exit-ready', 180, ['1:40:RIGHT'], [3, 0], [13, 2]),
    ('route1-entry', 240, ['1:65:UP'], [3, 19], [13, 38]),
    ('route1-south', 500, ['1:350:UP'], [3, 19], [13, 32]),
    ('route1-west', 500, ['1:90:LEFT', '130:350:UP'], [3, 19], [8, 27]),
    ('route1-mid', 600, ['1:90:RIGHT', '130:450:UP'], [3, 19], [14, 21]),
    ('route1-ledge2', 600, ['1:90:LEFT', '130:450:UP'], [3, 19], [9, 16]),
    ('route1-east', 600, ['1:33:DOWN', '80:215:RIGHT', '260:490:UP'], [3, 19], [17, 4]),
    ('viridian-entry', 500, ['1:65:LEFT', '120:300:UP'], [3, 1], [25, 33]),
    ('center-approach', 500, ['1:81:LEFT', '120:217:UP', '260:357:RIGHT'], [3, 1], [26, 32]),
    ('center-door', 550, ['1:65:LEFT', '110:191:UP', '240:305:RIGHT'], [3, 1], [26, 27]),
    ('center-entry', 500, ['1:33:UP'], [5, 4], [7, 8]),
    ('center-ready', 600, [f'{f}:{f + 4}:B' for f in range(1, 482, 80)], [5, 4], [7, 8]),
    ('pc-approach', 500, ['1:97:RIGHT', '140:220:UP', '300:304:A'], [5, 4], [7, 4]),
    ('pc-pending', 500, ['1:65:RIGHT', '120:153:UP', '220:224:A'], [5, 4], [7, 4]),
    ('pc-face', 600, ['1:5:B', '80:84:B', '180:245:RIGHT', '300:333:UP', '430:434:A'], [5, 4], [11, 2]),
    ('pc-menu', 400, ['1:5:A', '180:184:A'], [5, 4], [11, 2]),
    ('storage-menu', 400, ['1:5:A'], [5, 4], [11, 2]),
    ('storage-options', 400, ['1:5:A'], [5, 4], [11, 2]),
    ('box', 500, ['1:5:A'], [5, 4], [11, 2]),
    ('withdraw-menu', 300, ['1:5:A'], [5, 4], [11, 2]),
    ('withdrawn', 400, ['1:5:A'], [5, 4], [11, 2]),
    ('close-box', 400, ['1:5:B'], [5, 4], [11, 2]),
    ('close-pc', 600, ['1:5:A', '220:224:B', '400:404:B'], [5, 4], [11, 2]),
    ('center-exit-ready', 500, ['1:33:DOWN', '100:165:LEFT', '220:285:DOWN'], [5, 4], [7, 8]),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('rom', 'state', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
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
    rom, seed = args.rom.read_bytes(), args.state.read_bytes()
    rom_hash, seed_hash = digest(args.rom), digest(args.state)
    assert len(rom) == 0x2000000 and len(seed) == 0x61000
    assert struct.unpack_from('<I', seed, 8)[0] == zlib.crc32(rom), 'Exact ROM/core seed mismatch'
    initial = observation(args.state)
    assert initial['map'] == [3, 0] and initial['tile'] == [10, 10], 'Requires declared Pallet seed'
    native = Machine(rom, seed)
    for index in range(6):
        native.u.mem_write(0x02024284 + 100 * index, bytes(100))
    native.call(0x0806E681, 0x1045)  # Native Infinite Repel for deterministic travel.
    native.mon(0x02024284, 0xD010, 4)
    native.put(0x02024029, 1, 1)
    withdrawn_identity = native.mon(0x0202402C, 0xD011, 25)
    native.call(0x0808BBB5, 0, 0, 0x0202402C)
    prepared = bytearray(seed)
    prepared[0x19000:0x21000] = native.bytes(0x03000000, 0x8000)
    prepared[0x21000:] = native.bytes(0x02000000, 0x40000)
    current = args.output / 'stationary-p1.state'
    current.write_bytes(prepared)
    fixtures, pairs, observations = [], [], []

    def record(name, path, paired=True):
        row = observation(path)
        row['name'] = name
        observations.append(row)
        fixtures.append(dict(name=name, group=row['map'][0], number=row['map'][1],
                             state=str(path), sha256=row['sha256']))
        if paired:
            pairs.append({'name': name, 'from': 'stationary-p1', 'to': name})
        return row

    record('stationary-p1', current, paired=False)

    def drive(state, name, frames, inputs, samples=None):
        output = args.output / name
        output.mkdir(exist_ok=True)
        samples = samples or [frames]
        command = [sys.executable, str(game / 'tools/map_emulator.py'), '--rom', str(args.rom),
                   '--state-in', str(state), '--output', str(output), '--frames', str(frames),
                   '--rtc-ms', '1735689600000']
        for keys in inputs:
            command += ['--input', keys]
        for frame in samples:
            command += ['--state-out', f'{frame}:{output}/frame-{frame:03}.state']
        for frame in samples if len(samples) == 1 else [88, 92, 120, 140, 144, 148, 152, 156, 160, 400]:
            command += ['--screenshot-at', str(frame)]
        subprocess.run(command, cwd=game, check=True, stdout=subprocess.DEVNULL)
        return output / f'frame-{frames:03}.state'

    checkpoint_names = {'pallet-exit-ready', 'route1-entry', 'viridian-entry', 'center-door',
                        'center-entry', 'center-ready', 'pc-face', 'close-pc', 'center-exit-ready'}
    for name, frames, inputs, expected_map, expected_tile in STEPS:
        current = drive(current, name, frames, inputs)
        row = observation(current)
        assert row['map'] == expected_map and row['tile'] == expected_tile, (name, row)
        if name in checkpoint_names:
            record(name, current)
        print(name, row['map'], row['tile'], 'party', row['party'], flush=True)
    assert observation(current)['party'] == 2, 'PC withdrawal did not update party'
    raw = current.read_bytes()
    assert struct.unpack('<II', memory(raw, 0x02024284 + 100, 8)) == withdrawn_identity
    box0 = struct.unpack_from('<I', rom, 0x1148930)[0]
    assert memory(raw, box0, 58) == bytes(58), 'Withdrawn PC slot was not removed'
    current = drive(current, 'center-exit', 400, ['1:17:DOWN'], list(range(4, 201, 4)) + [400])
    assert observation(current)['map'] == [3, 1] and observation(current)['tile'] == [26, 27]
    # Presence decoding must distinguish published visible animation frames
    # from the hidden middle of the transition. Retain all raw samples for it.
    for frame in [88, 92, 144, 148, 152, 156, 160, 200, 400]:
        record(f'center-exit-{frame}', args.output / 'center-exit' / f'frame-{frame:03}.state')
    # A second real scenario continues west after leaving the Center. The
    # wandering NPC has vacated its template origin, but P1 projects it there.
    current = drive(current, 'after-center-npc-approach', 650, ['1:161:LEFT', '220:301:UP'])
    assert observation(current)['tile'] == [17, 22]
    current = drive(current, 'after-center-npc-origin', 300, ['1:20:LEFT'])
    assert observation(current)['map'] == [3, 1] and observation(current)['tile'] == [16, 22]
    record('after-center-npc-origin', current)
    current = drive(current, 'after-center-npc-stationary', 600, [])
    assert observation(current)['tile'] == [16, 22]
    record('after-center-npc-stationary', current)
    assert digest(args.rom) == rom_hash and digest(args.state) == seed_hash
    report = dict(passed=True, romSHA256=rom_hash, seedSHA256=seed_hash, fixtures=fixtures, pairs=pairs,
                  requiredPublished=[row['name'] for row in fixtures],
                  observations=observations, withdrawnIdentity=list(withdrawn_identity),
                  scope='Native button journey and PC withdrawal; route pairs require separate production Swift check. '
                        'P1 stationary snapshot; no live transport, iOS app or physical-device claim. '
                        'Initial synthetic party/storage and Infinite Repel only; original seed and ROM unchanged.')
    (args.output / 'pairs.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: continuous native journey, PC withdrawal and exit; both-direction checkpoint manifest written')


if __name__ == '__main__':
    main()
