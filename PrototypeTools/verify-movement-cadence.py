#!/usr/bin/env python3
"""Run an exact-ROM movement replay on one explicitly selected task simulator.

Use PrototypeTools/qa-python with explicit BOUND_GAME_SOURCE. This executes an
existing test build once, preserves every result, and never builds or retries.
It establishes native simulator observations, not physical-device/WAN parity.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import time
import zlib

APP = Path(__file__).resolve().parents[1]
ARTIFACTS = APP.parent / 'artifacts/multiplayer-isolation'
BUNDLE = 'com.evanvonessen.bound'
TEST = 'WorldMovementRuntimeTests/testRepeatedNativeMovementCadence'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def container(simulator, env):
    result = subprocess.run(['/usr/bin/xcrun', 'simctl', 'get_app_container', simulator, BUNDLE, 'data'],
                            env=env, capture_output=True, text=True)
    return Path(result.stdout.strip()) if result.returncode == 0 else None


def source_manifest():
    selected = ['Delta', 'Cores/DeltaCore', 'Cores/GBADeltaCore', 'PrototypeIntegrationTests',
                'PrototypeConfiguration', 'PrototypePatches', 'Bound.xcodeproj', 'PrototypeTools']
    files = subprocess.check_output(['git', 'ls-files', '-z', '--', *selected], cwd=APP).decode().split('\0')
    files += ['PrototypeTools/verify-movement-cadence.py']
    return {name: digest(APP / name) for name in sorted(set(files)) if name and (APP / name).is_file()}


def verify_frozen_source(receipt):
    """Verify a preserved tree, never substitute the current Git checkout."""
    if 'sourceRoot' not in receipt:
        return None  # Historical receipts did not retain a complete source tree.
    root = Path(receipt['sourceRoot'])
    files = receipt.get('files', {})
    if not root.is_absolute() or not root.is_dir() or not isinstance(files, dict) or not files:
        raise ValueError('Frozen source receipt requires an existing absolute sourceRoot and file hashes')
    for name, expected in files.items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or not re.fullmatch(r'[0-9a-f]{64}', str(expected)):
            raise ValueError(f'Invalid frozen source entry: {name}')
        path = root / relative
        if not path.is_file() or digest(path) != expected:
            raise ValueError(f'Frozen source differs from build receipt: {name}')
    return dict(sourceRoot=str(root), baseCommit=receipt.get('head'), verifiedFiles=len(files),
                scope='Every listed frozen file matches the build receipt; no current-checkout or Git-directory assumption')


def verified_anchor_run(origin, rom, rom_sha256, source_receipt, binary_hashes, *, axis, tape, follower, phases):
    """Admit one completed ordinary VBA producer, never a loose/cross-core state."""
    if not origin.is_absolute() or not origin.is_dir() or not source_receipt:
        raise ValueError('Anchor replay requires an absolute completed run and a current frozen source receipt')
    result_path = origin / 'result.json'
    prior = json.loads(result_path.read_text())
    summary = prior.get('xctestSummary', {})
    if (prior.get('status') != 'passed' or prior.get('romSHA256') != rom_sha256
            or prior.get('diagnosticOnly') or prior.get('nativeFloorDiagnostic') or prior.get('guestTimingDiagnostic')
            or prior.get('anchorReplay') or summary.get('totalTestCount') != 1 or summary.get('passedTests') != 1
            or any(summary.get(key, 0) for key in ('failedTests', 'skippedTests', 'expectedFailures'))):
        raise ValueError('Anchor origin must be a complete successful ordinary exact-ROM cadence test')
    expected = dict(axis=axis, tape=tape, followerRequested=follower, phaseFrames=phases)
    if any(prior.get(key) != value for key, value in expected.items()):
        raise ValueError('Anchor origin axis/tape/follower/phase differs from this replay')
    directories = list((origin / 'evidence').glob('MovementCadence-*'))
    if len(directories) != 1 or not directories[0].is_dir() or len(prior.get('evidence', [])) != 1:
        raise ValueError('Anchor origin requires exactly one retained cadence evidence directory')
    evidence = directories[0]
    fixture_path, state_path = evidence / 'fixture.json', evidence / 'exact-ROM-anchor.state'
    fixture = json.loads(fixture_path.read_text())
    if (any(fixture.get(key) != value for key, value in expected.items())
            or fixture.get('romSHA256') != rom_sha256 or fixture.get('nativeFloorDiagnostic') is not False
            or fixture.get('guestTimingDiagnostic') is not False or fixture.get('anchorReplay')
            or fixture.get('localSeed') != 0x12345678 or fixture.get('partnerSeed') != 0x87654321
            or fixture.get('run') != '11111111-2222-3333-4444-555555555555' or fixture.get('debugPlayer') != 1
            or fixture.get('settings') != 'BQEBAAAAAAAAAAEAwdXm7f////8BAAAAAAAAAAAAAAA='):
        raise ValueError('Anchor fixture settings/seeds/identity/diagnostic provenance differ from the cold fixture')
    entries_path = evidence / 'summary.json'
    entries = json.loads(entries_path.read_text())
    expected_cases = {(repeat + 1, rate, mode, prior['phaseFrames'][repeat % len(prior['phaseFrames'])])
                      for repeat in range(prior['repeats']) for rate in prior['rates'] for mode in prior['modes']}
    observed_cases = {(case.get('repeat'), case.get('rate'), case.get('mode'), case.get('preRollFrames')) for case in entries}
    if len(entries) != len(expected_cases) or observed_cases != expected_cases:
        raise ValueError('Anchor origin is missing completed matrix cases')
    for case in entries:
        name = case.get('name', '')
        if (not re.fullmatch(r'repeat-[0-9]+-(native|far|near|moving)-[13]\.0', name)
                or not (evidence / (name + '.json')).is_file()
                or case.get('romSHA256') != rom_sha256 or case.get('axis') != axis or case.get('tape') != tape):
            raise ValueError('Anchor origin case identity/evidence is incomplete')
    old_receipt_path = origin / 'build-source-receipt.json'
    if digest(old_receipt_path) != prior.get('buildSourceReceipt', {}).get('sha256'):
        raise ValueError('Anchor origin frozen source receipt changed')
    old_receipt = json.loads(old_receipt_path.read_text())
    if verify_frozen_source(old_receipt) is None or 'sourceRoot' not in source_receipt:
        raise ValueError('Anchor replay requires frozen source provenance on both builds')
    core_prefixes = ('Cores/GBADeltaCore/', 'Cores/DeltaCore/')
    old_core = {key: value for key, value in old_receipt['files'].items() if key.startswith(core_prefixes)}
    new_core = {key: value for key, value in source_receipt['files'].items() if key.startswith(core_prefixes)}
    serializer = 'Delta/Bound/BoundVBABattleBridge.mm'
    if (not old_core or old_core != new_core
            or old_receipt['files'].get(serializer) != source_receipt['files'].get(serializer)):
        raise ValueError('Anchor producer core or state serializer source differs from selected build')
    core_binaries = {}
    for framework in ('GBADeltaCore', 'DeltaCore'):
        suffix = f'/Frameworks/{framework}.framework/{framework}'
        old = [(Path(path), value) for path, value in prior.get('binaryHashes', {}).items() if path.endswith(suffix)]
        new = [(Path(path), value) for path, value in binary_hashes.items() if path.endswith(suffix)]
        if (len(old) != 1 or len(new) != 1 or old[0][1] != new[0][1]
                or not old[0][0].is_file() or digest(old[0][0]) != old[0][1]
                or not new[0][0].is_file() or digest(new[0][0]) != new[0][1]):
            raise ValueError('Anchor replay requires identical actual ' + framework + ' binaries')
        core_binaries[framework] = new[0][1]
    state = state_path.read_bytes()
    if (not 92 < len(state) <= 4 * 1024 * 1024 or state[:4] != b'VBA '
            or struct.unpack_from('<I', state, 4)[0] + 8 != len(state)
            or state[11] & 4 == 0 or state[20:24] != b'BR\x44\x00'
            or struct.unpack_from('<H', state, 18)[0] != 72
            or state[24:56].hex() != rom_sha256 or struct.unpack_from('<I', state, 56)[0] != 16
            or hashlib.sha256(state[92:]).digest() != state[60:92]
            or hashlib.sha256(state).hexdigest() != fixture.get('anchorSHA256')):
        raise ValueError('Anchor saved-state exact-ROM/layout/integrity binding failed')
    inflater = zlib.decompressobj(15 + 16)
    raw = inflater.decompress(state[8:], 4 * 1024 * 1024)
    if (not inflater.eof or inflater.unused_data or inflater.unconsumed_tail or len(raw) < 700000
            or raw[:4] != struct.pack('<I', 10) or raw[4:20] != rom.read_bytes()[0xA0:0xB0]):
        raise ValueError('Anchor must be the pinned VBA v10 saved-state format')
    core_source = Path(old_receipt['sourceRoot']) / 'Cores/GBADeltaCore/visualboyadvance-m/src/gba/GBA.cpp'
    producer = 'PrototypeIntegrationTests/WorldMovementRuntimeTests.swift'
    return state_path, dict(schema=1, diagnosticOnly=True, candidateAcceptance=False,
        originRun=str(origin), originResultSHA256=digest(result_path), originFixtureSHA256=digest(fixture_path),
        originSummarySHA256=digest(entries_path), originSourceReceiptSHA256=digest(old_receipt_path),
        selectedSourceManifestSHA256=hashlib.sha256((json.dumps(source_receipt, sort_keys=True)).encode()).hexdigest(),
        producerSourceSHA256=old_receipt['files'][producer], coreSourceSHA256=digest(core_source),
        serializerSHA256=old_receipt['files'][serializer], coreBinarySHA256=core_binaries,
        anchorSHA256=fixture['anchorSHA256'], stateLayout=16, nativeStateVersion=10, fixture=fixture,
        scope='Exact prior native anchor; identical ROM/core binaries and serializer. Diagnostic replay only; no new cold-run acceptance.')


def guest_timing_configuration(watch_path, manifest_path, rom_path, rom_sha256):
    """Pin opt-in interpreter watches to the exact supplied cartridge."""
    watch = json.loads(watch_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    if not isinstance(watch, dict) or not isinstance(manifest, dict):
        raise ValueError('Guest timing watch and manifest must be JSON objects')
    if watch.get('romSHA256') != rom_sha256 or manifest.get('integrated_sha256') != rom_sha256:
        raise ValueError('Guest timing watch and manifest must identify the exact selected ROM')
    symbols = manifest.get('symbols', {})
    entries = watch.get('watch')
    if not isinstance(symbols, dict) or not isinstance(entries, list) or not entries:
        raise ValueError('Guest timing requires a nonempty watch list and manifest symbols')
    entries = [dict(entry) for entry in entries]
    for name, pc in (('nativeMainDispatch', 0x080004B0), ('nativeFieldDispatch', 0x08056578)):
        present = [entry for entry in entries if entry.get('name') == name]
        if not present:
            entries.append(dict(name=name, pc=pc, kind='native pinned body'))
        elif len(present) != 1 or present[0].get('pc') != pc or present[0].get('kind') != 'native pinned body':
            raise ValueError('Native diagnostic dispatch watch must retain its exact pinned entry: ' + name)
    if len(entries) > 64:
        raise ValueError('Guest timing supports at most64 distinct watch points including both native dispatch entries')
    rom = rom_path.read_bytes()
    if hashlib.sha256(rom).hexdigest() != rom_sha256:
        raise ValueError('Guest timing ROM changed while preparing its watches')
    points = []
    names, addresses = set(), set()
    for entry in entries:
        name, address, kind = entry.get('name'), entry.get('pc'), entry.get('kind', '')
        if (not isinstance(name, str) or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.]*', name)
                or type(address) is not int or address & 1
                or not 0x08000000 <= address <= 0x0A000000 - 16
                or name in names or address in addresses):
            raise ValueError('Guest timing requires unique named even ROM addresses')
        if isinstance(kind, str) and kind.endswith(' compiled symbol'):
            if type(symbols.get(name)) is not int or symbols[name] & ~1 != address:
                raise ValueError('Guest timing compiled symbol differs from manifest: ' + name)
        elif kind != 'native pinned body':
            raise ValueError('Guest timing entry must be a manifest symbol or explicitly pinned native body: ' + name)
        names.add(name)
        addresses.add(address)
        start = address - 0x08000000
        points.append(dict(name=name, address=address, bytes=base64.b64encode(rom[start:start + 16]).decode(),
                           trackReturn=name != 'nativeWaitVBlank'))
    return dict(schema=1, romSHA256=rom_sha256, manifestSHA256=digest(manifest_path),
                watchSHA256=digest(watch_path), points=points)


def verify_guest_timing_case(case, evidence_directory, config, config_sha256):
    """Require real bounded interpreter output, never silently accept a no-op."""
    timing = case.get('guestTiming', {})
    if (not isinstance(timing, dict) or case.get('diagnosticOnly') is not True or timing.get('enabled') is not True
            or timing.get('schema') != 1 or timing.get('recordBytes') != 136):
        raise ValueError('Requested guest timing was not enabled with the expected diagnostic schema')
    for key in ('recordCount', 'dropped', 'stackOverflows', 'invalidated', 'cycles', 'videoFrames',
                'dmaCycles', 'idleCycles', 'openCalls', 'openInterrupts'):
        if type(timing.get(key)) is not int or timing[key] < 0:
            raise ValueError('Guest timing is missing a nonnegative integer counter: ' + key)
    if (not 1 <= timing['recordCount'] <= 262144 or timing['cycles'] == 0 or timing['videoFrames'] == 0
            or any(timing[key] for key in ('dropped', 'stackOverflows', 'invalidated'))):
        raise ValueError('Guest timing is empty, overflowed, or invalidated')
    for key, expected in (('sourceROM_SHA256', config['romSHA256']), ('configSHA256', config_sha256),
                          ('manifestSHA256', config['manifestSHA256']), ('watchSHA256', config['watchSHA256'])):
        if timing.get(key) != expected:
            raise ValueError('Guest timing identity differs from the requested input: ' + key)
    filename = timing.get('binaryFile')
    if not isinstance(filename, str) or Path(filename).name != filename or not filename.endswith('-guest-timing.bin'):
        raise ValueError('Guest timing binary must be a named file inside this case evidence directory')
    binary = evidence_directory / filename
    if (not binary.is_file() or binary.stat().st_size != timing['recordCount'] * 136
            or digest(binary) != timing.get('binarySHA256')):
        raise ValueError('Guest timing binary is missing or differs from its exact length/hash receipt')
    kinds = {}
    for words in struct.iter_unpack('<17Q', binary.read_bytes()):
        kinds[words[0]] = kinds.get(words[0], 0) + 1
    if (any(not kinds.get(kind) for kind in (1, 2, 5, 6, 7))
            or kinds.get(8) or kinds[5] != timing['videoFrames']):
        raise ValueError('Guest timing lacks exercised call/return/video boundaries or its binary counters disagree')
    receipt = binary.with_suffix('.json')
    if not receipt.is_file():
        raise ValueError('Guest timing JSON receipt is missing')
    retained = json.loads(receipt.read_text())
    if not isinstance(retained, dict) or any(retained.get(key) != value for key, value in timing.items()):
        raise ValueError('Guest timing case metadata differs from its retained JSON receipt')
    if not isinstance(timing.get('columns'), list) or len(timing['columns']) != 17:
        raise ValueError('Guest timing record column schema is missing')
    if timing.get('points') != config['points']:
        raise ValueError('Guest timing recorded watch identities differ from the exact requested points')
    return dict(binaryFile=filename, binarySHA256=timing['binarySHA256'], recordCount=timing['recordCount'],
                videoFrames=timing['videoFrames'], openCalls=timing['openCalls'], openInterrupts=timing['openInterrupts'],
                recordKinds=kinds)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('xctestrun', 'rom', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('simulator', 'sha256', 'label'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--frames', type=int, default=3600)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--rates', default='1,3')
    parser.add_argument('--modes', default='native,far,near,moving')
    parser.add_argument('--native-floor-diagnostic', action='store_true',
                        help='Private same-anchor main/field entry ablation; requires --modes native,raw-native or native,far,raw-native and a continuous tape; never candidate acceptance')
    parser.add_argument('--phase-frames', default='0', help='Comma-separated idle native frames after restore, cycled per repeat (0–600)')
    parser.add_argument('--tape', choices=('release-run', 'continuous-run', 'continuous-walk'), default='release-run',
                        help='Historical release loop or continuously held endpoint reversals on the same paved lane')
    parser.add_argument('--axis', choices=('horizontal', 'vertical'), default='horizontal',
                        help='Continuous lane: horizontal x33–36,y20 or vertical x36,y20–22; historical tape remains horizontal')
    parser.add_argument('--follower', choices=('0', '1'), default='1')
    parser.add_argument('--source-receipt', type=Path, help='Preserved source/build receipt for this previously built candidate')
    parser.add_argument('--anchor-run', type=Path,
                        help='Absolute completed ordinary cadence run to replay with identical ROM/core; diagnostic only, never a loose state')
    parser.add_argument('--guest-timing-watch', type=Path,
                        help='Explicit exact-ROM watch JSON; opt-in diagnostic only, requires a timing-instrumented test build')
    parser.add_argument('--guest-timing-manifest', type=Path,
                        help='Exact generated ROM manifest for --guest-timing-watch')
    args = parser.parse_args()
    if 'BOUND_GAME_SOURCE' not in os.environ:
        parser.error('Set BOUND_GAME_SOURCE to the explicit selected game checkout')
    game = Path(os.environ['BOUND_GAME_SOURCE']).resolve(strict=True)
    sys.path.insert(0, str(game / 'tools'))
    from qa_python import ensure_qa_python
    ensure_qa_python()
    args.xctestrun = args.xctestrun.resolve(strict=True)
    args.rom = args.rom.resolve(strict=True)
    if args.source_receipt:
        args.source_receipt = args.source_receipt.resolve(strict=True)
    try:
        source_receipt = json.loads(args.source_receipt.read_text()) if args.source_receipt else None
        frozen_source = verify_frozen_source(source_receipt) if source_receipt else None
    except (OSError, ValueError, TypeError) as error:
        parser.error(str(error))
    args.output = args.output.resolve()
    if args.output.exists() or not args.output.is_relative_to(ARTIFACTS.resolve()):
        parser.error('Use a fresh output directory within artifacts/multiplayer-isolation')
    if not re.fullmatch(r'[0-9a-f]{64}', args.sha256) or digest(args.rom) != args.sha256:
        parser.error('Explicit ROM hash does not match the selected cartridge')
    if args.rom.stat().st_size != 33554432:
        parser.error('Expected the selected 32 MiB RRv4.1M cartridge')
    try:
        rates = [float(value) for value in args.rates.split(',')]
    except ValueError:
        parser.error('Rates must be comma-separated 1 or 3')
    modes = args.modes.split(',')
    try:
        phases = [int(value) for value in args.phase_frames.split(',')]
    except ValueError:
        parser.error('Phase frames must be comma-separated integers from 0 to 600')
    if not phases or not all(0 <= value <= 600 for value in phases):
        parser.error('Phase frames must be comma-separated integers from 0 to 600')
    if not rates or not all(value in (1, 3) for value in rates):
        parser.error('Rates must be comma-separated 1 or 3')
    if args.native_floor_diagnostic:
        if (len(modes) != len(set(modes)) or set(modes) not in ({'native', 'raw-native'}, {'native', 'far', 'raw-native'})
                or args.tape == 'release-run'):
            parser.error('Native-floor diagnostic requires exactly native,raw-native or native,far,raw-native and a continuous tape')
    elif not modes or not all(value in ('native', 'far', 'near', 'moving') for value in modes):
        parser.error('Modes must be native,far,near,moving selections')
    if args.tape != 'release-run' and 'native' not in modes:
        parser.error('Continuous replay requires a matched native control')
    if args.axis == 'vertical' and args.tape == 'release-run':
        parser.error('Vertical replay requires a continuous tape')
    if not 160 <= args.frames <= 36000 or not 1 <= args.repeats <= 10:
        parser.error('Frames must be 160–36000 and repeats 1–10')
    timing_config = None
    if bool(args.guest_timing_watch) != bool(args.guest_timing_manifest):
        parser.error('Guest timing requires both --guest-timing-watch and --guest-timing-manifest')
    if args.guest_timing_watch:
        if args.frames > 3600 or args.repeats != 1 or rates != [1]:
            parser.error('Guest timing is bounded to at most3600 frames, one repeat, and rate1')
        try:
            args.guest_timing_watch = args.guest_timing_watch.resolve(strict=True)
            args.guest_timing_manifest = args.guest_timing_manifest.resolve(strict=True)
            timing_config = guest_timing_configuration(args.guest_timing_watch, args.guest_timing_manifest,
                                                       args.rom, args.sha256)
        except (OSError, ValueError, TypeError) as error:
            parser.error(str(error))
    if args.anchor_run and (timing_config or args.native_floor_diagnostic):
        parser.error('Anchor replay currently requires an ordinary uninstrumented core without entry ablation')
    env = dict(os.environ)
    env.setdefault('DEVELOPER_DIR', '/Applications/Developer/Xcode.app/Contents/Developer')
    devices = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'list', 'devices', 'available', '--json'], env=env))
    found = [item for values in devices['devices'].values() for item in values if item['udid'] == args.simulator]
    if len(found) != 1 or not found[0]['name'].startswith('Bound Movement') or found[0]['state'] != 'Booted':
        parser.error('Use an already booted dedicated simulator named Bound Movement…')
    products = args.xctestrun.parent
    targets = []
    pre_roll_by_repeat = [phases[repeat % len(phases)] for repeat in range(args.repeats)]
    allowance = int((args.frames * args.repeats + sum(pre_roll_by_repeat)) / 60
                    * sum(1 / rate for rate in rates) * len(modes) + 180)

    def configure(value):
        if isinstance(value, str):
            return value.replace('__TESTROOT__', str(products))
        if isinstance(value, list):
            return [configure(child) for child in value]
        if isinstance(value, dict):
            result = {key: configure(child) for key, child in value.items()}
            if result.get('BlueprintName') == 'BoundIntegrationTests':
                result.setdefault('EnvironmentVariables', {}).update(
                    BOUND_MOVEMENT_SMOOTHNESS='1', BOUND_MOVEMENT_ROM=str(args.rom),
                    BOUND_MOVEMENT_SHA256=args.sha256, BOUND_MOVEMENT_FRAMES=str(args.frames),
                    BOUND_MOVEMENT_REPEATS=str(args.repeats), BOUND_MOVEMENT_RATES=args.rates,
                    BOUND_MOVEMENT_MODES=args.modes, BOUND_MOVEMENT_LABEL=args.label,
                    BOUND_MOVEMENT_PHASES=','.join(str(value) for value in phases),
                    BOUND_MOVEMENT_TAPE=args.tape,
                    BOUND_MOVEMENT_AXIS=args.axis,
                    BOUND_MOVEMENT_NATIVE_FLOOR='1' if args.native_floor_diagnostic else '0',
                    BOUND_MOVEMENT_FOLLOWER=args.follower,
                    BOUND_MOVEMENT_GUEST_TIMING='1' if timing_config else '0',
                    BOUND_MOVEMENT_ANCHOR_REPLAY='1' if args.anchor_run else '0')
                for key in ('BOUND_MOVEMENT_GUEST_TIMING_CONFIG', 'BOUND_MOVEMENT_GUEST_TIMING_CONFIG_SHA256',
                            'BOUND_MOVEMENT_ANCHOR_STATE', 'BOUND_MOVEMENT_ANCHOR_RECEIPT', 'BOUND_MOVEMENT_ANCHOR_RECEIPT_SHA256'):
                    result['EnvironmentVariables'].pop(key, None)
                if timing_config:
                    encoded = (json.dumps(timing_config, indent=2, sort_keys=True) + '\n').encode()
                    result['EnvironmentVariables'].update(
                        BOUND_MOVEMENT_GUEST_TIMING_CONFIG=str(args.output / 'guest-timing-config.json'),
                        BOUND_MOVEMENT_GUEST_TIMING_CONFIG_SHA256=hashlib.sha256(encoded).hexdigest())
                if args.tape != 'release-run':
                    result['EnvironmentVariables']['BOUND_MOVEMENT_PIXEL_DIAGNOSTICS'] = '1'
                result['OnlyTestIdentifiers'] = [TEST]
                result['SkipTestIdentifiers'] = []
                result['DefaultTestExecutionTimeAllowance'] = allowance
                result['MaximumTestExecutionTimeAllowance'] = allowance
                targets.append(result)
            return result
        return value

    configuration = configure(plistlib.loads(args.xctestrun.read_bytes()))
    if len(targets) != 1:
        parser.error('Expected exactly one BoundIntegrationTests target')
    target = targets[0]
    if target.get('TestHostBundleIdentifier') != BUNDLE:
        parser.error('Test host must be the explicit Bound app bundle')
    host = Path(target['TestHostPath'])
    app = host if host.suffix == '.app' else host.parent
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = app / info['CFBundleExecutable']
    test_bundle = Path(target['TestBundlePath'].replace('__TESTHOST__', str(app)))
    paths = [executable, app / 'Bound.debug.dylib', test_bundle / 'BoundIntegrationTests']
    paths += [path for path in (app / 'Frameworks').glob('*.framework/*') if path.is_file() and not path.suffix]
    binary_hashes = {str(path): digest(path) for path in paths if path.is_file()}
    if not executable.is_file() or not (test_bundle / 'BoundIntegrationTests').is_file():
        parser.error('Selected app/test executable is missing')
    anchor_replay = None
    if args.anchor_run:
        try:
            anchor_state, anchor_replay = verified_anchor_run(args.anchor_run, args.rom, args.sha256,
                source_receipt, binary_hashes, axis=args.axis, tape=args.tape, follower=args.follower == '1', phases=phases)
        except (OSError, ValueError, TypeError, KeyError, zlib.error) as error:
            parser.error(str(error))
    args.output.mkdir(parents=True, mode=0o700)
    if anchor_replay:
        shutil.copyfile(anchor_state, args.output / 'verified-anchor.state')
        write_json(args.output / 'verified-anchor.json', anchor_replay)
        target['EnvironmentVariables'].update(
            BOUND_MOVEMENT_ANCHOR_STATE=str(args.output / 'verified-anchor.state'),
            BOUND_MOVEMENT_ANCHOR_RECEIPT=str(args.output / 'verified-anchor.json'),
            BOUND_MOVEMENT_ANCHOR_RECEIPT_SHA256=digest(args.output / 'verified-anchor.json'))
    if timing_config:
        write_json(args.output / 'guest-timing-config.json', timing_config)
        shutil.copyfile(args.guest_timing_watch, args.output / 'guest-timing-watch.json')
        shutil.copyfile(args.guest_timing_manifest, args.output / 'guest-timing-manifest.json')
    run = args.output / 'movement.xctestrun'
    run.write_bytes(plistlib.dumps(configuration))
    write_json(args.output / 'checkout-at-launch-hashes.json', source_manifest())
    if args.source_receipt:
        shutil.copyfile(args.source_receipt, args.output / 'build-source-receipt.json')
    write_json(args.output / 'binary-hashes.json', binary_hashes)
    before = container(args.simulator, env)
    previous = {path.name for path in (before / 'Documents').glob('MovementCadence-*')} if before else set()
    result_bundle = args.output / 'movement.xcresult'
    command = ['xcodebuild', 'test-without-building', '-xctestrun', str(run),
               '-destination', 'platform=iOS Simulator,id=' + args.simulator,
               '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never',
               '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', str(allowance),
               '-maximum-test-execution-time-allowance', str(allowance),
               '-only-testing:BoundIntegrationTests/' + TEST, '-resultBundlePath', str(result_bundle)]
    report = dict(label=args.label, status='running', command=command, simulator=args.simulator,
                  simulatorName=found[0]['name'], bundle=BUNDLE, rom=str(args.rom), romSHA256=args.sha256,
                  xctestrun=str(args.xctestrun), xctestrunSHA256=digest(args.xctestrun),
                  gameSource=str(game), appSource=str(APP),
                  appCommit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=APP, text=True).strip(),
                  gameCommit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=game, text=True).strip(),
                  checkoutAtLaunchManifestSHA256=digest(args.output / 'checkout-at-launch-hashes.json'), binaryHashes=binary_hashes,
                  buildSourceReceipt=dict(path=str(args.source_receipt), sha256=digest(args.source_receipt)) if args.source_receipt else None,
                  verifiedFrozenSource=frozen_source,
                  provenanceLimit='Checkout-at-launch hashes are diagnostic only and do not identify compiled sources. Binary hashes identify the previously built candidate; the separately preserved source/build receipt establishes source provenance when supplied.',
                  frames=args.frames, repeats=args.repeats, rates=rates, modes=modes, followerRequested=args.follower == '1',
                  phaseFrames=phases, preRollFramesByRepeat=pre_roll_by_repeat, tape=args.tape, axis=args.axis,
                  nativeFloorDiagnostic=args.native_floor_diagnostic,
                  acceptanceScope='native-floor-diagnostic' if args.native_floor_diagnostic else 'production-candidate',
                  physicalDeviceVerified=False, wanVerified=False, evidence=[])
    if timing_config:
        report.update(guestTimingDiagnostic=True, diagnosticOnly=True, candidateAcceptance=False,
                      acceptanceScope='guest-timing-diagnostic',
                      guestTimingConfig=dict(path=str(args.output / 'guest-timing-config.json'),
                                             sha256=digest(args.output / 'guest-timing-config.json'),
                                             manifestSHA256=timing_config['manifestSHA256'],
                                             watchSHA256=timing_config['watchSHA256'],
                                             points=len(timing_config['points'])),
                      timingScope='Opt-in instrumented interpreter. Guest cycle evidence only; host wall timing and production candidate acceptance require an uninstrumented build.')
    if anchor_replay:
        report.update(anchorReplay=anchor_replay, diagnosticOnly=True, candidateAcceptance=False,
                      acceptanceScope='exact-anchor-diagnostic')
    write_json(args.output / 'invocation.json', report)
    start = time.monotonic()
    try:
        print(f'Running {args.label}; log: {args.output / "test.log"}', flush=True)
        with (args.output / 'test.log').open('xb') as log:
            result = subprocess.run(command, cwd=APP, env=env, stdout=log, stderr=subprocess.STDOUT)
        report.update(exitCode=result.returncode, seconds=time.monotonic() - start)
        if result_bundle.exists():
            for kind in ('summary', 'tests'):
                value = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'xcresulttool', 'get', 'test-results', kind,
                                                          '--path', str(result_bundle)], env=env))
                write_json(args.output / ('xctest-' + kind + '.json'), value)
                report['xctest' + kind.title()] = value
        summary = report.get('xctestSummary', {})
        cases = []

        def visit(value):
            if isinstance(value, dict):
                if value.get('nodeType') == 'Test Case':
                    cases.append(value)
                for child in value.values():
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)

        visit(report.get('xctestTests', {}))
        if (result.returncode or summary.get('totalTestCount') != 1 or summary.get('passedTests') != 1
                or summary.get('failedTests', 0) or summary.get('skippedTests', 0) or summary.get('expectedFailures', 0)
                or len(cases) != 1 or cases[0].get('result') != 'Passed'
                or TEST not in cases[0].get('nodeIdentifier', '')):
            raise RuntimeError('Movement replay failed, skipped, or did not execute its exact one-test selection')
        report['status'] = 'passed'
    except Exception as error:
        report.update(status='failed', error=str(error))
    finally:
        after = container(args.simulator, env)
        if after:
            evidence = args.output / 'evidence'
            for source in sorted((after / 'Documents').glob('MovementCadence-*')):
                if source.name not in previous and source.is_dir():
                    evidence.mkdir(exist_ok=True)
                    destination = evidence / source.name
                    shutil.copytree(source, destination)
                    report['evidence'].append(dict(simulatorPath=str(source), copiedPath=str(destination)))
        if report['status'] == 'passed':
            summaries = list((args.output / 'evidence').glob('MovementCadence-*/summary.json'))
            expected = args.repeats * len(rates) * len(modes)
            if len(summaries) != 1 or len(json.loads(summaries[0].read_text())) != expected:
                report.update(status='failed', error='Missing complete native replay evidence for the selected matrix')
            else:
                expected_cases = {(repeat + 1, rate, mode, phase)
                                  for repeat, phase in enumerate(pre_roll_by_repeat) for rate in rates for mode in modes}
                observed_cases = {(case.get('repeat'), case.get('rate'), case.get('mode'), case.get('preRollFrames', 0))
                                  for case in json.loads(summaries[0].read_text())}
                if observed_cases != expected_cases:
                    report.update(status='failed', error='Native replay evidence does not match the requested phases and matrix')
                if any(case.get('tape', 'release-run') != args.tape for case in json.loads(summaries[0].read_text())):
                    report.update(status='failed', error='Native replay evidence does not match the requested input tape')
                if any(case.get('axis', 'horizontal') != args.axis for case in json.loads(summaries[0].read_text())):
                    report.update(status='failed', error='Native replay evidence does not match the requested movement axis')
                if any(case.get('nativeFloorDiagnostic', False) != args.native_floor_diagnostic for case in json.loads(summaries[0].read_text())):
                    report.update(status='failed', error='Native-floor diagnostic label differs from the explicit invocation')
                if timing_config:
                    try:
                        report['guestTimingEvidence'] = [verify_guest_timing_case(
                            case, summaries[0].parent, timing_config,
                            digest(args.output / 'guest-timing-config.json'))
                            for case in json.loads(summaries[0].read_text())]
                    except (OSError, ValueError, TypeError) as error:
                        report.update(status='failed', error=str(error))
                if anchor_replay:
                    fixture = json.loads((summaries[0].parent / 'fixture.json').read_text())
                    entries = json.loads(summaries[0].read_text())
                    if (fixture.get('anchorSHA256') != anchor_replay['anchorSHA256']
                            or fixture.get('anchorReplay') != anchor_replay or fixture.get('diagnosticOnly') is not True
                            or any(case.get('diagnosticOnly') is not True or case.get('candidateAcceptance') is not False
                                   or case.get('anchorSHA256') != anchor_replay['anchorSHA256'] for case in entries)):
                        report.update(status='failed', error='Exact anchor diagnostic identity/labels are missing or changed')
        report['seconds'] = time.monotonic() - start
        write_json(args.output / 'result.json', report)
    print(json.dumps(dict(status=report['status'], output=str(args.output), evidence=report['evidence']), indent=2))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
