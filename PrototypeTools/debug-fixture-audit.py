#!/usr/bin/env python3
"""Audit captured VBA fixture RAM with frozen native read-only instructions.

Use PrototypeTools/qa-python with an explicit --game-source. Instructions execute
only on copied buffers in Unicorn; this never restores or edits a running core.
The result is supplemental native evidence, not server/fixture certification.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

ROM_SHA = '02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79'


def digest(value):
    return hashlib.sha256(value).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-source', type=Path, required=True)
    parser.add_argument('--rom', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--source-candidate', type=Path, help='Required original Route1 gift basis for the separate two-party Pallet audit')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Preserve prior audit; choose a fresh output file')
    root = args.candidate.resolve(strict=True)
    report_names = [name for name in ['native-candidate.json', 'native-route.json'] if (root / name).exists()]
    assert len(report_names) == 1
    report_path = root / report_names[0]
    report = json.loads(report_path.read_text())
    route2 = report['pointID'] == '02-route2-setup'
    pallet = report['pointID'] == 'qa-two-party-pallet'
    route = report['pointID'] in ['02-route1-gifts', '02-route2-setup', 'qa-two-party-pallet']
    if route:
        assert report['status'] == 'passed-bounded-route' and report['stage'] == ('pallet-peer-loss' if pallet else 'route2-setup' if route2 else 'route1-gifts')
        assert report['nativeOperations'] == ([] if pallet else [3] if route2 else [1, 2]) and report['certifiedFixture'] is False
        assert report['coldRestorationVerified'] is True
    else:
        assert report['status'] == 'candidate' and report['pointID'] == '01'
    assert report['role'] in ('controller', 'buddy')
    files = {}
    for name, meta in report['files'].items():
        path = root / name
        assert path.parent == root and not path.is_symlink()
        value = path.read_bytes()
        assert len(value) == meta['bytes'] and digest(value) == meta['sha256']
        files[name] = value
    state, work, internal = (files[k] for k in ['checkpoint.state', 'ewram.bin', 'iwram.bin'])
    assert state[:4] == b'VBA ' and len(state) == int.from_bytes(state[4:8], 'little') + 8
    raw = zlib.decompress(state[8:], wbits=31)
    assert int.from_bytes(raw[:4], 'little') == 10
    assert len(work) == 0x40000 and len(internal) == 0x8000
    assert raw[34271:34271 + 0x40000] == work
    assert raw[479:479 + 0x8000] == internal
    rom = args.rom.read_bytes()
    assert digest(rom) == ROM_SHA == report['romSHA256']
    sys.path.insert(0, str(args.game_source.resolve(strict=True) / 'tools'))
    from verify_event_storage import Machine, FLAG_GET, VAR_GET
    machine = Machine(rom)
    machine.uc.mem_write(0x02000000, work)
    machine.uc.mem_write(0x03000000, internal)
    save1 = int.from_bytes(internal[0x5008:0x500C], 'little')
    save2 = int.from_bytes(internal[0x500C:0x5010], 'little')
    assert 0x02000000 <= save1 <= 0x0203C000 and 0x02000000 <= save2 <= 0x0203F000
    story_spans = [(save1 + 0xEE0, 0x320), (0x0203B174, 0x200), (0x0203B374, 0x400)]
    before_story = [bytes(machine.uc.mem_read(a, n)) for a, n in story_spans]
    before_party = bytes(machine.uc.mem_read(0x02024284, 600))
    flags = {f'{v:04X}': machine.call(FLAG_GET, v)[0] for v in
             [*range(0x820, 0x82A), 0x028, 0x029, 0x02A, 0x02B, 0x02C, 0x02D,
              0x258, 0x291, 0x2CF, 0x906, 0x91E, 0x920, 0x976, 0x977, 0x978,
              0x103F, 0x1040, 0x1045, 0x1056, 0x1083, 0x109D,
              0x1032, 0x1033, 0x1034, 0x103C, 0x10BE, 0x0940, 0x093A, 0x0941, 0x0942]}
    variables = {f'{v:04X}': machine.call(VAR_GET, v)[0] for v in
                 [0x4012, 0x4013, 0x4031, 0x4050, 0x4051, 0x4054, 0x4055, 0x4057, 0x4058, 0x4061, 0x5101]}
    trainer_results = {f'{v:04X}': machine.call(0x08080424, v)[0] for v in [0x2C, 0x2D, 0x38, 0x8E, 0x19E]}
    cap = machine.call(0x090C226C)[0]
    candy_counts = [1, 18, 19] if route2 else [1, 21, 22]
    candy = {str(count): machine.call(0x08099F40, 68, count)[0] for count in candy_counts} if route else None
    story_items = {f'{item:04X}': machine.call(0x0809A7DC, item)[0] for item in [0x015D, 4]} if route2 or pallet else None
    count = machine.read8(0x02024029)
    fields = [0, 1, 3, 4, 5, 6, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
              25, 26, 27, 28, 29, 30, 31, 32, 35, 36, 37, 38, 39, 40, 41, 42, 43,
              44, 45, 46, 49, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    mons = []
    for slot in range(count):
        pointer = 0x02024284 + slot * 100
        mon = {str(field): machine.call(0x0803FBE8, pointer, field, 0)[0] for field in fields}
        for name, field, size in [('nickname_hex', 2, 12), ('ot_name_hex', 7, 8)]:
            machine.uc.mem_write(0x02008000, bytes(16))
            machine.call(0x0803FBE8, pointer, field, 0x02008000)
            mon[name] = bytes(machine.uc.mem_read(0x02008000, size)).hex()
        mons.append(mon)
    assert before_story == [bytes(machine.uc.mem_read(a, n)) for a, n in story_spans]
    assert before_party == bytes(machine.uc.mem_read(0x02024284, 600))
    assert count == (3 if route2 else 2 if route else 1) and cap == 15
    seed = 0x12345678 if report['role'] == 'controller' else 0x87654321
    species = 4 if report['role'] == 'controller' else 7
    assert mons[0]['1'] == seed and mons[0]['11'] == species and mons[0]['56'] == (8 if route2 else 5)
    assert mons[0]['4'] == 0 and mons[0]['5'] == 1 and mons[0]['6'] == 0
    assert mons[0]['57'] == mons[0]['58'] > 0 and mons[0]['12'] == 0
    if route:
        assert mons[0]['35'] == 157
        assert mons[1]['1'] == seed and mons[1]['11'] == 56 and mons[1]['56'] == 8
        assert mons[1]['35'] == 101 and mons[1]['36'] == 8
        assert mons[1]['4'] == 0 and mons[1]['5'] == 1 and mons[1]['6'] == 0 and mons[1]['12'] == 0
        assert mons[1]['57'] == mons[1]['58'] > 0
        assert candy == ({'1': 1, '18': 1, '19': 0} if route2 else {'1': 1, '21': 1, '22': 0})
        assert bytes(machine.uc.mem_read(save1 + 4, 2)) == bytes([3, 0 if pallet else 20 if route2 else 19])
        header = 0x350618 if pallet else 0x350848 if route2 else 0x35082C
        assert bytes(machine.uc.mem_read(0x02036DFC, 28)) == rom[header:header + 28]
        if pallet:
            assert args.source_candidate is not None
            source = args.source_candidate.resolve(strict=True)
            source_report_bytes = (source / 'native-route.json').read_bytes()
            source_report = json.loads(source_report_bytes)
            assert source_report['pointID'] == '02-route1-gifts' and source_report['stage'] == 'route1-gifts'
            assert source_report['role'] == report['role'] and source_report['run'] == report['run']
            assert source_report['romSHA256'] == ROM_SHA and source_report['coldRestorationVerified'] is True
            assert digest(source_report_bytes) == report['sourceReportSHA256']
            source_files = {}
            for name, meta in source_report['files'].items():
                assert Path(name).name == name and not (source/name).is_symlink()
                data = (source/name).read_bytes()
                assert digest(data) == meta['sha256'] and len(data) == meta['bytes']
                source_files[name] = data
            source_work, source_internal = source_files['ewram.bin'], source_files['iwram.bin']
            source_save = int.from_bytes(source_internal[0x5008:0x500C], 'little') - 0x02000000
            current_save = save1 - 0x02000000
            assert 0 <= source_save <= 0x3C000 and struct.unpack_from('<HH', work, current_save) == (16,14)
            def story_bytes(ram, save):
                first = bytearray(ram[save+0xEE0:save+0x1200])
                for offset in [0x162,0x164,0x200]: first[offset:offset+2] = bytes(2)
                return [bytes(first), ram[0x3B174:0x3B374], ram[0x3B374:0x3B774]]
            assert story_bytes(source_work, source_save) == story_bytes(work, current_save)
            assert struct.unpack_from('<H',source_work,source_save+0x10E0)[0] == 1
            assert struct.unpack_from('<H',work,current_save+0x10E0)[0] == 2
            assert struct.unpack_from('<H',work,current_save+0x1044)[0] < 5
            for pocket in range(5):
                source_base, source_count = struct.unpack_from('<IH', source_work, 0x3988C+pocket*8)
                base, quantity = struct.unpack_from('<IH', work, 0x3988C+pocket*8)
                assert source_count == quantity <= 1024
                assert source_work[source_base-0x02000000:source_base-0x02000000+source_count*4] == work[base-0x02000000:base-0x02000000+quantity*4]
            expected_party = bytearray(source_files['party.bin'])
            assert len(expected_party) == len(files['party.bin']) == 200
            before_counter = struct.unpack_from('<H', source_work, source_save+0x1042)[0]
            after_counter = struct.unpack_from('<H', work, current_save+0x1042)[0]
            for slot in range(2):
                offset = slot*100+41
                if expected_party[offset] != files['party.bin'][offset]:
                    assert 0 <= after_counter < before_counter < 128
                    assert 0 < files['party.bin'][offset]-expected_party[offset] <= 2
                    expected_party[offset] = files['party.bin'][offset]
            assert bytes(expected_party) == files['party.bin']
            assert story_items == {'015D':0,'0004':0} and variables['4055'] == 4 and variables['4057'] == 0
            assert report['testOnlyPeerLossInput'] is True and report['nativeSRAMSaveValidated'] is False
            assert report['nativeBagLeveling'] is False
        if route2:
            assert mons[2]['1'] == seed and mons[2]['11'] == 25 and mons[2]['56'] == 8
            assert mons[2]['35'] == 102 and mons[2]['36'] == 8 and mons[2]['12'] == 0
            assert mons[2]['4'] == 0 and mons[2]['5'] == 1 and mons[2]['6'] == 0
            assert mons[2]['57'] == mons[2]['58'] > 0
            assert story_items == {'015D': 0, '0004': 10}
            assert flags['0829'] == 1
            assert all(variables[f'{key:04X}'] == value for key,value in
                       [(0x4051, 2), (0x4054, 1), (0x4055, 6), (0x4057, 2), (0x4058, 1)])
            assert report['nativeBagLeveling'] is True
            expected_moves = [10, 45, 206, 52] if report['role'] == 'controller' else [33, 206, 39, 145]
            assert [mons[0][str(field)] for field in range(13, 17)] == expected_moves
    assert flags['1045'] == 1  # Native Debug New Game's Infinite Repel flag.
    assert all(flags[f'{v:04X}'] == 0 for v in range(0x820, 0x828))
    assert all(result == 0 for result in trainer_results.values())
    assert variables['4031'] == (2 if report['role'] == 'controller' else 1)
    assert variables['4050'] == 1
    if not route:
        assert variables['4055'] == 4
    # These story effects belong to later native route continuations, not start.
    assert all(flags[f'{v:04X}'] == 0 for v in ([0x906, 0x91E, 0x920, 0x976, 0x977, 0x978] + ([] if route2 else [0x829])))
    assert variables['4012'] == 0 and variables['4013'] == 0 and variables['4061'] == 0 and variables['5101'] == 0
    settings = base64.b64decode(report['settings'], validate=True)
    assert len(settings) == 32 and settings[0] == 5 and settings[20] == 1
    option_flags = [0x1032, 0x1033, 0x1034, 0x103C, 0x10BE, 0x0940, 0x093A, 0x0941, 0x0942]
    assert [flags[f'{v:04X}'] for v in option_flags] == list(settings[1:10])
    assert all(flags[f'{v:04X}'] == settings[10] for v in [0x103F, 0x1040, 0x1056, 0x1083, 0x109D])
    assert bytes(machine.uc.mem_read(save1 + 0x3A4C, 8)) == settings[12:20]
    result = dict(version=1, status='passed: supplemental copied-RAM native instruction audit',
                  role=report['role'], pointID=report['pointID'], rom_sha256=ROM_SHA,
                  candidate_report_sha256=digest(report_path.read_bytes()),
                  files={name:digest(value) for name,value in files.items()},
                  vba_container_and_RAM_agree=True, source_files_unchanged=True,
                  native_flags=flags, native_variables=variables, native_trainer_results=trainer_results,
                  native_level_cap=cap, native_party=mons,
                  native_rare_candy_quantity_checks=candy,
                  native_story_item_quantities=story_items,
                  settings_readback_verified=True, native_respawn_and_warp_bytes=work[save1-0x02000000+8:save1-0x02000000+0x28].hex(),
                  read_only_guest_state_preserved=True,
                  addresses={'FlagGet':'0x0806E6D0','VarGet':'0x0806E568','HasTrainerBeenFought':'0x08080424','GetMonData':'0x0803FBE8','LevelCap':'0x090C226C','CheckBagHasItem':'0x08099F40'},
                  limitations=['This does not execute live VBA progression or authenticate paired server ownership.',
                               'Native SRAM save/Continue is distinct from state-plus-battery restoration.',
                               'No fixture certificate or trusted registry entry is produced.'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    assert all(digest((root/name).read_bytes()) == digest(value) for name,value in files.items())
    print(json.dumps({'status':result['status'],'role':result['role'],'cap':cap,'species':species}))


if __name__ == '__main__':
    main()
