#!/usr/bin/env python3
"""Generate one native candidate on the explicitly assigned isolated Simulator.

Use PrototypeTools/qa-python. This does not build, authorize a server run, certify
fixtures, change trusted digests, convert emulator states, or write gameplay RAM.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

ROM_SHA = '02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79'
SIMULATOR = '14BD3EC6-B57B-49A1-98D1-457A9DC0C088'
TARGET = 'BoundIntegrationTests'
ROUTE_SHA = '4d6260979d43f2e650b720fa23c2a00202233b4349b3a7f50396a7043e9c23ea'
ROUTE2_SHA = '1ba52c9e2d50dba7f82ad91780f6c9f369dec0ec8ac49341945a6e5f0f4c23c9'
PALLET_SHA = 'e4711a3605746fc9ce8c0158614a7b460352c88230f939110d76148fc15a4a96'
STAGES = {
    'paired-start': ('01', 'testGeneratePairedStartCandidate', 'native-candidate.json'),
    'route1-gifts': ('02-route1-gifts', 'testRouteToBrendanSetup', 'native-route.json'),
    'route2-setup': ('02-route2-setup', 'testRouteToBrendanSetup', 'native-route.json'),
    'bag-mart-regression': ('02-bag-mart-regression', 'testNativeBagToMartRegression', 'native-bag-mart.json'),
    'pallet-peer-loss': ('qa-two-party-pallet', 'testNativeTwoPartyPalletCandidate', 'native-route.json'),
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def route_recipe(stage='route1-gifts'):
    if stage == 'pallet-peer-loss':
        path = Path(__file__).with_name('debug-fixture-pallet.json')
        assert sha(path) == PALLET_SHA
        recipe = json.loads(path.read_text())
        assert recipe['version'] == 1 and recipe['stage'] == stage and recipe['romSHA256'] == ROM_SHA
        assert recipe['nativeOperations'] == [] and len(recipe['steps']) == 3
        for step, name, map_number, end, count in zip(recipe['steps'],
                ['route1-gift-return-south', 'route1-pallet-connection', 'pallet-peer-loss-staging'],
                [19, 0, 0], [[12, 39], [12, 0], [16, 14]], [9, 0, 19]):
            assert step['id'] == name and step['frames'] == 0 and step['inputs'] == []
            assert [step[k] for k in ['mapGroup', 'mapNumber', 'x', 'y']] == [3, map_number, *end]
            if count:
                walk = step['walk']; assert len(walk) == count and not step.get('connection')
                assert [walk[-1][k] for k in ['x', 'y']] == end
                assert all(abs(a['x'] - b['x']) + abs(a['y'] - b['y']) == 1 for a, b in zip(walk, walk[1:]))
                assert all(tile['block'] & 0xC00 == 0 and tile['block'] >> 12 == 3
                           and tile['behavior'] in [0, 2] for tile in walk)
            else:
                assert step['connection'] is True and 'walk' not in step
        return path
    second = stage in ['route2-setup', 'bag-mart-regression']
    assert stage in ['route1-gifts', 'route2-setup', 'bag-mart-regression']
    path = Path(__file__).with_name('debug-fixture-route2.json' if second else 'debug-fixture-route1.json')
    if sha(path) != (ROUTE2_SHA if second else ROUTE_SHA):
        raise ValueError('Route source must match the digest compiled into the native test')
    recipe = json.loads(path.read_text())
    assert recipe['version'] == (4 if second else 1) and recipe['stage'] == ('route2-setup' if second else stage)
    assert recipe['romSHA256'] == ROM_SHA and recipe['nativeOperations'] == ([3] if second else [1, 2])
    assert len(recipe['steps']) == (28 if second else 9)
    assert len({step['id'] for step in recipe['steps']}) == len(recipe['steps'])
    for step in recipe['steps']:
        assert sum(item['frames'] for item in step['inputs']) == step['frames']
        if 'walk' in step:
            walk = step['walk']
            assert second and step['id'] in ['route1-return-south', 'route1-second-north']
            north = step['id'] == 'route1-second-north'
            assert len(walk) == (58 if north else 57)
            assert step['frames'] == 0 and step['inputs'] == []
            assert [step[k] for k in ['mapGroup', 'mapNumber', 'x', 'y']] == [3, 19, 12, 0 if north else 39]
            assert [walk[0][k] for k in ['x', 'y']] == ([13, 36] if north else [12, 3])
            assert [walk[-1][k] for k in ['x', 'y']] == [12, 0 if north else 39]
            assert all(abs(a['x'] - b['x']) + abs(a['y'] - b['y']) == 1 for a, b in zip(walk, walk[1:]))
            assert all(tile['block'] & 0xC00 == 0 and tile['block'] >> 12 == 3
                       and tile['behavior'] in [0, 2] for tile in walk)
        else:
            assert step['inputs'][-1]['mask'] == 0
        assert all(item['mask'] in [0, 1, 2, 16, 32, 64, 128]
                   and 1 <= item['frames'] <= 3600 for item in step['inputs'])
    assert [recipe['steps'][-1][key] for key in ['mapGroup', 'mapNumber', 'x', 'y']] == ([3, 20, 8, 76] if second else [3, 19, 13, 32])
    return path


def resume_source(candidate, audit, role, run, stage='route1-gifts'):
    candidate, audit = candidate.resolve(strict=True), audit.resolve(strict=True)
    second = stage in ['route2-setup', 'bag-mart-regression', 'pallet-peer-loss']
    assert stage in ['route1-gifts', 'route2-setup', 'bag-mart-regression', 'pallet-peer-loss']
    report_name = 'native-route.json' if second else 'native-candidate.json'
    point = '02-route1-gifts' if second else '01'
    report_path = candidate / report_name
    report = json.loads(report_path.read_text())
    evidence = json.loads(audit.read_text())
    assert report['status'] == ('passed-bounded-route' if second else 'candidate') and report['pointID'] == point
    if second:
        assert report['stage'] == 'route1-gifts' and report['nativeOperations'] == [1, 2]
        assert report['coldRestorationVerified'] is True and report['certifiedFixture'] is False
    assert report['role'] == role and uuid.UUID(report['run']) == run
    assert report['romSHA256'] == ROM_SHA
    assert evidence['status'] == 'passed: supplemental copied-RAM native instruction audit'
    assert evidence['candidate_report_sha256'] == sha(report_path)
    assert evidence['role'] == role and evidence['pointID'] == point
    assert evidence['rom_sha256'] == ROM_SHA
    for name, metadata in report['files'].items():
        assert Path(name).name == name
        source = candidate / name
        assert not source.is_symlink() and source.stat().st_size == metadata['bytes']
        assert sha(source) == metadata['sha256'] == evidence['files'][name]
    files = {name: candidate / name for name in ['checkpoint.state', 'game.sav', 'party.bin', report_name]}
    files['native-audit.json'] = audit
    metadata = {name: dict(sha256=sha(path), bytes=path.stat().st_size) for name, path in files.items()}
    return files, metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xctestrun', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--rom', type=Path, required=True)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--role', choices=['controller', 'buddy'], required=True)
    parser.add_argument('--run', type=uuid.UUID, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--stage', choices=STAGES, default='paired-start')
    parser.add_argument('--resume-candidate', type=Path)
    parser.add_argument('--resume-audit', type=Path)
    parser.add_argument('--validate-only', action='store_true', help='Validate fixed recipe and inputs without creating outputs or touching a Simulator')
    args = parser.parse_args()
    if args.simulator != SIMULATOR:
        parser.error('Only the assigned fixture Simulator B is admitted by this harness')
    args.xctestrun = args.xctestrun.resolve(strict=True)
    args.app = args.app.resolve(strict=True)
    args.rom = args.rom.resolve(strict=True)
    args.output = args.output.resolve()
    if sha(args.rom) != ROM_SHA:
        parser.error('Exact supported ROM required')
    point, method, report_name = STAGES[args.stage]
    source_files, source_metadata = {}, {}
    recipe = None
    if args.stage in ['route1-gifts', 'route2-setup', 'bag-mart-regression', 'pallet-peer-loss']:
        if args.resume_candidate is None or args.resume_audit is None:
            parser.error('Route continuation requires its preceding native result and matching independent audit')
        recipe = route_recipe(args.stage)
        source_files, source_metadata = resume_source(args.resume_candidate, args.resume_audit, args.role, args.run, args.stage)
    elif args.resume_candidate is not None or args.resume_audit is not None:
        parser.error('Paired-start generation cold-boots native setup and takes no resume input')
    if args.validate_only:
        print(json.dumps(dict(status='validated-only; no Simulator or output mutation', stage=args.stage,
                              rom_sha256=ROM_SHA, source_files=source_metadata,
                              recipe_sha256=sha(recipe) if recipe else None)))
        return
    args.output.mkdir(parents=True, exist_ok=False)
    app_info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    bundle = app_info['CFBundleIdentifier']
    if not bundle.startswith(('com.rileytestut.', 'com.evanvonessen.', 'dev.bound.')):
        parser.error('Unexpected application bundle identifier')
    subprocess.run(['/usr/bin/xcrun', 'simctl', 'install', args.simulator, str(args.app)], check=True)
    container = Path(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'get_app_container', args.simulator, bundle, 'data'], text=True).strip())
    # A new candidate must never replace the prior ROM's native inputs/results.
    root = container / 'Documents/DebugFixtureGenerationQA' / ROM_SHA
    root.mkdir(parents=True, exist_ok=True)
    resident_rom = root / 'RadicalRed.gba'
    if resident_rom.exists():
        if sha(resident_rom) != ROM_SHA:
            raise RuntimeError('Preserve unexpected existing fixture input; refusing replacement')
    else:
        shutil.copy2(args.rom, resident_rom)
    attempt = uuid.uuid4()
    request = dict(version=1, pointID=point, role=args.role, run=str(args.run), attempt=str(attempt))
    if source_files:
        request['source'] = dict(files=source_metadata)
        input_root = root / 'inputs' / str(attempt).upper()
        input_root.mkdir(parents=True, exist_ok=False)
        for name, path in source_files.items():
            shutil.copy2(path, input_root / name)
        shutil.copy2(recipe, root / recipe.name)
    request_bytes = (json.dumps(request, indent=2) + '\n').encode()
    (args.output / 'request.json').write_bytes(request_bytes)
    (root / 'request.json').write_bytes(request_bytes)
    original = plistlib.loads(args.xctestrun.read_bytes())
    targets = []
    def transform(value):
        if isinstance(value, dict):
            result = {k: transform(v) for k, v in value.items()}
            if result.get('BlueprintName') == TARGET:
                result.setdefault('EnvironmentVariables', {})['BOUND_DEBUG_FIXTURE_GENERATE'] = '01' if args.stage == 'paired-start' else args.stage
                result['OnlyTestIdentifiers'] = ['DebugFixtureGenerationTests/' + method]
                targets.append(TARGET)
            return result
        if isinstance(value, list):
            return [transform(v) for v in value]
        return value.replace('__TESTROOT__', str(args.xctestrun.parent)) if isinstance(value, str) else value
    configured = transform(original)
    if targets != [TARGET]:
        raise RuntimeError('Expected exactly one explicit native test target')
    run_file = args.output / 'generation.xctestrun'
    run_file.write_bytes(plistlib.dumps(configured))
    command = ['/usr/bin/xcodebuild', 'test-without-building', '-xctestrun', str(run_file),
               '-destination', 'platform=iOS Simulator,id=' + args.simulator,
               '-only-testing:' + TARGET + '/DebugFixtureGenerationTests/' + method, '-parallel-testing-enabled', 'NO',
               '-collect-test-diagnostics', 'never', '-test-timeouts-enabled', 'YES',
               '-default-test-execution-time-allowance', '300', '-maximum-test-execution-time-allowance', '600',
               '-resultBundlePath', str(args.output / 'generation.xcresult')]
    native_products = {'application': args.app / app_info['CFBundleExecutable']}
    for core in ['DeltaCore', 'GBADeltaCore']:
        for label, parent in [('app', args.app / 'Frameworks'), ('products', args.app.parent)]:
            binary = parent / (core + '.framework') / core
            if binary.exists():
                native_products[label + '_' + core] = binary
    receipt = dict(version=1, request=request, simulator=args.simulator, application_bundle=bundle,
                   xctestrun_sha256=sha(args.xctestrun), rom_sha256=sha(args.rom), command=command,
                   generator_sha256=sha(Path(__file__)), stage=args.stage,
                   source_files={name:dict(path=str(path), **source_metadata[name]) for name,path in source_files.items()},
                   recipe_sha256=sha(recipe) if recipe else None,
                   native_products={key:dict(path=str(path), sha256=sha(path)) for key,path in native_products.items()})
    (args.output / 'invocation.json').write_text(json.dumps(receipt, indent=2) + '\n')
    receipt['exit_code'] = -1
    try:
        with (args.output / 'generation.log').open('wb') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=660)
            receipt['exit_code'] = result.returncode
    except subprocess.TimeoutExpired:
        receipt['error'] = 'Native test exceeded the bounded execution time; subprocess terminated'
    finally:
        # Preserve partial native outputs even on failure. Nothing is installed
        # into DEBUGFixtures or the trusted registry by this command.
        # Xcode may reinstall the host and relocate its data container. Resolve
        # it again instead of reporting a successful native write as missing.
        containers = [container]
        try:
            final_container = Path(subprocess.check_output(
                ['/usr/bin/xcrun', 'simctl', 'get_app_container', args.simulator, bundle, 'data'], text=True).strip())
            if final_container not in containers:
                containers.insert(0, final_container)
        except subprocess.CalledProcessError as error:
            receipt['container_lookup_error'] = str(error)
        candidates = [entry / 'Documents/DebugFixtureGenerationQA' / ROM_SHA / 'results' / str(attempt).upper() / point / args.role for entry in containers]
        candidate = next((entry for entry in candidates if entry.is_dir()), None)
        if candidate is not None:
            shutil.copytree(candidate, args.output / 'candidate')
        receipt['data_containers'] = [str(entry) for entry in containers]
        receipt['candidate_exported'] = candidate is not None
        receipt['source_files_unchanged'] = all(sha(path) == source_metadata[name]['sha256'] for name,path in source_files.items())
        passed = receipt['exit_code'] == 0 and (args.output / 'candidate' / report_name).exists() and receipt['source_files_unchanged']
        receipt['status'] = ('native_candidate_passed' if args.stage == 'paired-start' else 'bounded_native_route_passed') if passed else 'failed'
        (args.output / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({k:receipt[k] for k in ['status','exit_code','candidate_exported']}))
    raise SystemExit(0 if receipt['status'] in ['native_candidate_passed', 'bounded_native_route_passed'] else 1)


if __name__ == '__main__':
    main()
