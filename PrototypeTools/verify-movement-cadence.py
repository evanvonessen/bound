#!/usr/bin/env python3
"""Run an exact-ROM movement replay on one explicitly selected task simulator.

Use PrototypeTools/qa-python with explicit BOUND_GAME_SOURCE. This executes an
existing test build once, preserves every result, and never builds or retries.
It establishes native simulator observations, not physical-device/WAN parity.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time

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
    parser.add_argument('--phase-frames', default='0', help='Comma-separated idle native frames after restore, cycled per repeat (0–600)')
    parser.add_argument('--follower', choices=('0', '1'), default='1')
    parser.add_argument('--source-receipt', type=Path, help='Preserved source/build receipt for this previously built candidate')
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
    if not modes or not all(value in ('native', 'far', 'near', 'moving') for value in modes):
        parser.error('Modes must be native,far,near,moving selections')
    if not 160 <= args.frames <= 36000 or not 1 <= args.repeats <= 10:
        parser.error('Frames must be 160–36000 and repeats 1–10')
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
                    BOUND_MOVEMENT_FOLLOWER=args.follower)
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
    args.output.mkdir(parents=True, mode=0o700)
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
                  provenanceLimit='Checkout-at-launch hashes are diagnostic only and do not identify compiled sources. Binary hashes identify the previously built candidate; the separately preserved source/build receipt establishes source provenance when supplied.',
                  frames=args.frames, repeats=args.repeats, rates=rates, modes=modes, followerRequested=args.follower == '1',
                  phaseFrames=phases, preRollFramesByRepeat=pre_roll_by_repeat,
                  physicalDeviceVerified=False, wanVerified=False, evidence=[])
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
        report['seconds'] = time.monotonic() - start
        write_json(args.output / 'result.json', report)
    print(json.dumps(dict(status=report['status'], output=str(args.output), evidence=report['evidence']), indent=2))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
