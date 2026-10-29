#!/usr/bin/env python3
"""Repeat ordinary authenticated save/recovery and paired native battle checks.

Run through qa-python with explicit main game checkout, ROM, owned simulators, local
synthetic login and build paths. This never starts services or delivers a build.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import uuid

TOOLS = Path(__file__).resolve().parent
APP = TOOLS.parent
WORKSPACE = APP.parent
ARTIFACTS = WORKSPACE / 'artifacts/multiplayer-isolation'
ROLES = ('controller', 'buddy')
BUNDLE = 'com.evanvonessen.bound'


def digest(path, algorithm='sha256'):
    return hashlib.new(algorithm, path.read_bytes()).hexdigest()


def atomic(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def source_manifest():
    paths = subprocess.check_output(['git', 'ls-files', '-z', '--', 'Delta', 'Cores/DeltaCore',
        'Cores/GBADeltaCore', 'PrototypeIntegrationTests', 'PrototypeConfiguration', 'PrototypePatches',
        'Bound.xcodeproj', 'PrototypeTools', 'Backend/nakama', 'Backend/selfhost'], cwd=APP).decode().split('\0')
    # Include this task's new Swift component/tests before their local commit.
    paths += [str(path.relative_to(APP)) for root in ('Delta/Bound', 'PrototypeIntegrationTests')
              for path in (APP / root).rglob('*.swift')]
    paths.append('PrototypeTools/verify-coordinator-recovery.py')
    return {name: digest(APP / name) for name in sorted(set(paths)) if name and (APP / name).is_file()}


def verify_xcresult(path, expected_suites, env):
    command = ['/usr/bin/xcrun', 'xcresulttool', 'get', 'test-results']
    summary = json.loads(subprocess.check_output(command + ['summary', '--path', str(path)], env=env))
    tests = json.loads(subprocess.check_output(command + ['tests', '--path', str(path)], env=env))
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
    visit(tests)
    suites = {item.get('nodeIdentifier', '').split('/')[0] for item in cases}
    if (summary.get('totalTestCount', 0) <= 0 or summary.get('failedTests', 0) or summary.get('expectedFailures', 0) or
            summary.get('skippedTests', 0) or summary.get('passedTests', 0) != summary.get('totalTestCount') or
            any(item.get('result') != 'Passed' for item in cases) or not expected_suites.issubset(suites)):
        raise RuntimeError('Regression selection was empty, skipped, failed, or omitted a required suite')
    return dict(summary=summary, executedSuites=sorted(suites))


def main():
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Developer/Xcode.app/Contents/Developer')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=('journeys', 'battle', 'regressions', 'build', 'release', 'all'), default='journeys')
    for name in ('game-source', 'rom', 'login-file', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--sim-controller', required=True)
    parser.add_argument('--sim-buddy', required=True)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--xctestrun', type=Path)
    parser.add_argument('--derived-data', type=Path)
    parser.add_argument('--release-derived-data', type=Path)
    parser.add_argument('--source-packages', type=Path)
    parser.add_argument('--package-cache', type=Path)
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--os-background', action='store_true', help='Require actual simulator background/foreground handshakes in recovery runs')
    args = parser.parse_args()
    args.game_source = args.game_source.resolve(strict=True)
    if APP.name != 'bound' or args.game_source != (WORKSPACE / 'multi_red').resolve(strict=True):
        parser.error('Use the workspace bound/ and multi_red/ main checkouts')
    for repository in (APP, args.game_source):
        branch = subprocess.check_output(['git', 'branch', '--show-current'], cwd=repository, text=True).strip()
        if branch != 'main':
            parser.error('Both selected repositories must be on main; preserve other worktrees')
    if not 1 <= args.repetitions <= 10 or args.sim_controller == args.sim_buddy:
        parser.error('Require two distinct owned simulators and 1–10 repetitions')
    args.rom = args.rom.resolve(strict=True)
    args.login_file = args.login_file.resolve(strict=True)
    args.output = args.output.resolve()
    if not args.output.is_relative_to(ARTIFACTS.resolve()) or args.output.exists():
        parser.error('Output must be a fresh directory under artifacts/multiplayer-isolation')
    devices = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'list', 'devices', '--json'], text=True))
    inventory = {item['udid']: item for values in devices['devices'].values() for item in values}
    simulators = dict(controller=args.sim_controller, buddy=args.sim_buddy)
    for role, letter in zip(ROLES, ('A', 'B')):
        if not inventory.get(simulators[role], {}).get('name', '').startswith('Bound Coordinator Stability ' + letter + ' '):
            parser.error('Only explicitly named Coordinator Stability role simulators are allowed')
    if args.phase in ('all', 'build', 'release'):
        if not args.source_packages or not args.package_cache:
            parser.error('Build phases require explicit existing task SourcePackages and PackageCache paths')
        if args.phase in ('all', 'build') and not args.derived_data:
            parser.error('Simulator build requires explicit task --derived-data')
        if args.phase in ('all', 'release') and not args.release_derived_data:
            parser.error('Release build requires explicit task --release-derived-data')
    elif not args.app or not args.xctestrun:
        parser.error('Execution phases require the exact --app and --xctestrun from a completed build')
    for value in (args.derived_data, args.release_derived_data, args.source_packages, args.package_cache):
        if value is not None and not value.resolve().is_relative_to(ARTIFACTS.resolve()):
            parser.error('Mutable build/cache paths must remain in task artifacts')
    args.output.mkdir(parents=True, mode=0o700)
    env = dict(os.environ, BOUND_GAME_SOURCE=str(args.game_source),
               DEVELOPER_DIR='/Applications/Developer/Xcode.app/Contents/Developer')
    report = dict(version=1, status='running', commands=[], scenarios=[], simulators=simulators,
                  appSource=str(APP), gameSource=str(args.game_source),
                  appCommit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=APP, text=True).strip(),
                  gameCommit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=args.game_source, text=True).strip(),
                  romSHA256=digest(args.rom), gameID=digest(args.rom, 'sha1'), repetitions=args.repetitions,
                  physicalDeviceVerified=False, wanVerified=False, interStagePauseSeconds=65, pacing=[])
    summary = args.output / 'summary.json'
    initial_sources = source_manifest()
    atomic(args.output / 'source-hashes.json', initial_sources)
    report['sourceManifestSHA256'] = digest(args.output / 'source-hashes.json')
    report['coreTrees'] = {name: subprocess.check_output(['git', 'rev-parse', 'HEAD:' + name], cwd=APP, text=True).strip()
                           for name in ('Cores/DeltaCore', 'Cores/GBADeltaCore')}
    report['contractAndPins'] = {name: digest(APP / name) for name in (
        'PrototypeConfiguration/dependency-pins.json', 'PrototypeConfiguration/integrated-game.json',
        'Delta/Bound/SharedWorld/BoundGameABI.h', 'Delta/Bound/SDK/Generated/BoundSDKProtocol.swift',
        'Delta/Bound/SDK/Generated/BoundGameProfiles.swift',
        'Bound.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved') if (APP / name).is_file()}
    backend = ARTIFACTS / 'local-backend/phase7-runtime'
    module = backend / 'nakama-data/modules/index.js'
    identity = backend / 'run/runtime-identity.json'
    report['backend'] = dict(endpoint='https://127.0.0.1:58552',
        runtimeModuleSHA256=digest(module) if module.is_file() else None,
        recordedRuntimeIdentity=json.loads(identity.read_text()) if identity.is_file() else None)
    atomic(summary, report)

    def run(name, command, cwd=APP):
        start = time.monotonic()
        with (args.output / (name + '.log')).open('xb') as log:
            completed = subprocess.run(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
        return dict(name=name, command=command, exitCode=completed.returncode, seconds=time.monotonic() - start)

    def checked(name, command, cwd=APP):
        result = run(name, command, cwd)
        report['commands'].append(result); atomic(summary, report)
        if result['exitCode']:
            raise RuntimeError(name + ' failed; retained log and owner evidence')

    def build(release):
        name = 'release' if release else 'build'
        command = ['xcodebuild', '-project', str(APP / 'Bound.xcodeproj'),
                   '-scheme', 'Bound' if release else 'BoundIntegrationQA',
                   '-configuration', 'Release' if release else 'Debug',
                   '-destination', 'generic/platform=iOS' if release else 'generic/platform=iOS Simulator',
                   '-derivedDataPath', str(args.release_derived_data if release else args.derived_data),
                   '-clonedSourcePackagesDirPath', str(args.source_packages), '-packageCachePath', str(args.package_cache),
                   '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile', '-skipPackageUpdates',
                   'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', 'COMPILER_INDEX_STORE_ENABLE=NO', '-jobs', '4',
                   'CODE_SIGNING_ALLOWED=' + ('NO' if release else 'YES')]
        if not release:
            command += ['CODE_SIGN_IDENTITY=-']
        command += ['build' if release else 'build-for-testing']
        checked(name, command)
        if not release:
            products = args.derived_data / 'Build/Products'
            candidates = list(products.glob('BoundIntegrationQA_*.xctestrun'))
            if len(candidates) != 1:
                raise RuntimeError('Choose the exact xctestrun; simulator build output was ambiguous')
            args.xctestrun = candidates[0]
            args.app = products / 'Debug-iphonesimulator/Bound.app'

    def boundary(role, name, scenario, run_id=None, previous=None, termination=None):
        output = args.output / name
        command = [str(TOOLS / 'qa-python'), str(TOOLS / 'debug-native-boundary.py'),
                   '--ordinary-task', '--role', role, '--simulator', simulators[role], '--scenario', scenario,
                   '--rom', str(args.rom), '--rom-sha256', report['romSHA256'], '--game-id', report['gameID'],
                   '--app', str(args.app), '--xctestrun', str(args.xctestrun),
                   '--login-file', str(args.login_file), '--output', str(output)]
        if run_id:
            command += ['--ordinary-run-id', run_id]
        if previous:
            command += ['--previous-final-save', str(previous)]
        if termination:
            command += ['--previous-termination', str(termination)]
        if args.os_background and scenario == 'ordinaryRecovery':
            command += ['--os-background']
        return output, command

    def journeys():
        def pace(next_stage):
            # The isolated gateway has the real 120/IP/min general quota.
            # Let its window expire between scenarios; do not retry failures
            # or weaken authentication/rate limits to make QA pass.
            seconds = report['interStagePauseSeconds']
            print(f'Pacing {seconds}s before {next_stage}; preserving backend rate limits.', flush=True)
            report['pacing'].append(dict(before=next_stage, seconds=seconds))
            atomic(summary, report)
            time.sleep(seconds)

        prior = {}
        pace('baseline-controller')
        output, command = boundary('controller', 'baseline-controller', 'ordinary')
        checked('baseline-controller-launch', command)
        created = json.loads((output / 'evidence/ordinary-created.json').read_text())
        run_id = str(uuid.UUID(created['ordinaryRunID']))
        report['ordinaryRunID'] = run_id
        prior['controller'] = output / 'evidence/final-native-save.json'
        pace('baseline-buddy')
        output, command = boundary('buddy', 'baseline-buddy', 'ordinary', run_id)
        checked('baseline-buddy-launch', command)
        prior['buddy'] = output / 'evidence/final-native-save.json'

        def paired_stage(iteration, stage, jobs, expected_status):
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                tasks = {role: executor.submit(run, f'{stage}-{iteration:02}-{role}-launch', command)
                         for role, (_, command) in jobs.items()}
                results = {role: task.result() for role, task in tasks.items()}
            report['commands'].extend(results.values())
            statuses = {}
            for role, (output, _) in jobs.items():
                result = json.loads((output / 'result.json').read_text()) if (output / 'result.json').is_file() else {}
                statuses[role] = result.get('status', 'missing')
                report['scenarios'].append(dict(iteration=iteration, stage=stage, role=role,
                    status=statuses[role], completedRecovery=stage == 'recovery' and statuses[role] == 'passed', output=str(output)))
            atomic(summary, report)
            if any(result['exitCode'] for result in results.values()) or any(value != expected_status for value in statuses.values()):
                raise RuntimeError('Paired ' + stage + ' failed; preserve both owner executions before another attempt')

        for iteration in range(1, args.repetitions + 1):
            # Expected termination is only preparation, never a passed test.
            # Each fresh recovery must verify that exact accepted owner head,
            # a different PID, and a later confirmed final save.
            pace(f'terminate-{iteration:02}')
            prepared = {role: boundary(role, f'terminate-{iteration:02}-{role}', 'ordinaryTerminateAccepted', run_id, prior[role]) for role in ROLES}
            paired_stage(iteration, 'terminate', prepared, 'prepared-and-terminated')
            pace(f'recovery-{iteration:02}')
            jobs = {role: boundary(role, f'recovery-{iteration:02}-{role}', 'ordinaryRecovery', run_id,
                termination=prepared[role][0] / 'intentional-termination.json') for role in ROLES}
            paired_stage(iteration, 'recovery', jobs, 'passed')
            for role, (output, _) in jobs.items():
                prior[role] = output / 'evidence/final-native-save.json'

    def battles():
        # The existing native test cold-boots owned copies and never consumes
        # this all-FF seed as an archived gameplay checkpoint.
        for role in ROLES:
            checked('battle-install-' + role, ['/usr/bin/xcrun', 'simctl', 'install', simulators[role], str(args.app)])
            container = Path(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'get_app_container', simulators[role], BUNDLE, 'data'], text=True).strip())
            fixture = container / 'Documents/FullAppGameplayQA'
            fixture.mkdir(parents=True, exist_ok=True)
            for name, data in [('RadicalRed.gba', args.rom.read_bytes()), ('seed.sav', bytes([255]) * 131072)]:
                target = fixture / name
                if target.exists() and target.read_bytes() != data:
                    raise RuntimeError('Preserve different existing native battle fixture: ' + str(target))
                if not target.exists():
                    target.write_bytes(data)
        for name, flags in [('battle-complete', ['--initiator', 'A', '--rate-a', '8', '--rate-b', '1']),
                            ('battle-reconnect-return', ['--initiator', 'B', '--rate-a', '1', '--rate-b', '8', '--battle-run', '--disconnect-seconds', '3', '--silent-disconnect'])]:
            checked(name, [str(TOOLS / 'qa-python'), str(TOOLS / 'native-link-battle.py'),
                           '--xctestrun', str(args.xctestrun), '--sim-a', args.sim_controller, '--sim-b', args.sim_buddy,
                           '--output', str(args.output / name), '--relay', '--field-services'] + flags)

    try:
        if args.phase in ('all', 'build'):
            build(False)
        if args.phase in ('all', 'regressions'):
            suites = ['ServerAutomaticCheckpointTests', 'ServerFinalSaveLifecycleTests', 'ServerCheckpointSettlementTests',
                      'ServerDisconnectSaveTests', 'MultiplayerSavePackageTests', 'ObservationRecoveryTests', 'SDKLifecycleTransportTests']
            if any(not (APP / 'PrototypeIntegrationTests' / (suite + '.swift')).is_file() for suite in suites):
                raise RuntimeError('Required regression suite source is missing')
            checked('regressions', ['xcodebuild', 'test-without-building', '-xctestrun', str(args.xctestrun),
                    '-destination', 'platform=iOS Simulator,id=' + args.sim_controller, '-parallel-testing-enabled', 'NO',
                    '-collect-test-diagnostics', 'never', '-resultBundlePath', str(args.output / 'regressions.xcresult')] +
                    ['-only-testing:BoundIntegrationTests/' + suite for suite in suites])
            report['regressionEvidence'] = verify_xcresult(args.output / 'regressions.xcresult', set(suites), env)
        if args.app:
            info = plistlib.loads((args.app / 'Info.plist').read_bytes())
            report['applicationSHA256'] = digest(args.app / info['CFBundleExecutable'])
            report['xctestrunSHA256'] = digest(args.xctestrun)
        if args.phase in ('all', 'battle'):
            battles()
        if args.phase in ('all', 'release'):
            build(True)
        # Finish the final-candidate gate with repeated real interruptions and
        # fresh-process recovery after the build and representative battles.
        if args.phase in ('all', 'journeys'):
            journeys()
        if source_manifest() != initial_sources:
            raise RuntimeError('Candidate source changed during validation; rerun on one final candidate')
        report['status'] = 'passed'
    except Exception as error:
        report['status'] = 'failed'; report['failure'] = str(error)
    atomic(summary, report)
    print(json.dumps(dict(status=report['status'], summary=str(summary))))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
