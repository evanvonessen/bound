#!/usr/bin/env python3
"""Run actual native DEBUG acceptance on an explicitly assigned task simulator.

Use PrototypeTools/qa-python. This installs only the provided task build, stages
synthetic loopback credentials privately, and never grants fixture certification.
Run paired roles concurrently in separate processes after the ordinary baseline.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import uuid

SIMULATORS = {
    'controller': '92586556-6715-4BA0-98FC-5C1FF776F0A9',
    'buddy': '14BD3EC6-B57B-49A1-98D1-457A9DC0C088',
}
ROM_SHA = '02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79'
GAME_ID = '4b792d8f8b86e1a65b27965bb523fe0a48a20190'
ENDPOINT = 'https://127.0.0.1:58552'
BUNDLE = 'com.evanvonessen.bound'
TARGET = 'BoundIntegrationTests'
METHOD = 'LocalDebugNativeBoundaryTests/testActualNativeBoundaryAcceptance'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def container(simulator, quiet=False):
    return Path(subprocess.check_output(
        ['/usr/bin/xcrun', 'simctl', 'get_app_container', simulator, BUNDLE, 'data'], text=True,
        stderr=subprocess.DEVNULL if quiet else None).strip())


def process_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def main():
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Developer/Xcode.app/Contents/Developer')
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['xctestrun', 'app', 'rom', 'login-file', 'output']:
        parser.add_argument('--' + key, type=Path, required=True)
    parser.add_argument('--role', choices=list(SIMULATORS), required=True)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--scenario', choices=['ordinary', 'ordinaryRecovery', 'ordinaryTerminateAccepted', 'customHold', 'returnHold', 'returnVerifyLostReply', 'customLostReply', 'staleOrdinarySelection', 'unseenPeerDeath', 'customCommitLossPrepare', 'customCommitLossRecover', 'reloadBuiltin', 'reloadCustom', 'buddyLeave', 'controllerRevoke', 'partialRestorePrepare', 'partialRestoreRecover'], default='ordinary')
    parser.add_argument('--ordinary-task', action='store_true', help='Fresh ordinary-run QA on named Coordinator Stability simulators')
    parser.add_argument('--rom-sha256', help='Explicit ordinary-task cartridge SHA-256; the app also verifies its admitted profile')
    parser.add_argument('--game-id', help='Explicit ordinary-task cartridge SHA-1/game identity')
    parser.add_argument('--previous-final-save', type=Path, help='Prior same-owner confirmed final-native-save.json for fresh-process recovery')
    parser.add_argument('--previous-termination', type=Path, help='Exact accepted checkpoint from the explicitly terminated preceding attempt')
    parser.add_argument('--os-background', action='store_true', help='Exercise actual app background/foreground on its dedicated simulator')
    parser.add_argument('--recovery-attempt-id', type=uuid.UUID)
    parser.add_argument('--ordinary-run-id', type=uuid.UUID)
    parser.add_argument('--debug-session-id', type=uuid.UUID)
    parser.add_argument('--unrelated-ordinary-run-id', type=uuid.UUID)
    parser.add_argument('--creation-request-id', type=uuid.UUID)
    parser.add_argument('--reviewed-fixtures', type=Path,
                        help='Explicitly reviewed candidate root containing multiplayer-isolation-v1/01/<role>')
    parser.add_argument('--reviewed-digests', type=Path, help='Explicit reviewed candidate certificate digest mapping')
    args = parser.parse_args()
    if args.scenario.startswith(('customCommitLoss', 'partialRestore')) != (args.recovery_attempt_id is not None):
        parser.error('Restart stages require one explicit shared recovery attempt ID')
    ordinary_scenario = args.scenario in ('ordinary', 'ordinaryRecovery', 'ordinaryTerminateAccepted')
    if args.ordinary_task:
        if not ordinary_scenario or not args.rom_sha256 or not args.game_id:
            parser.error('Ordinary task requires an ordinary scenario and explicit ROM identities')
        inventory = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'list', 'devices', '--json'], text=True))
        devices = [item for values in inventory['devices'].values() for item in values if item['udid'] == args.simulator]
        expected_name = 'Bound Coordinator Stability ' + ('A' if args.role == 'controller' else 'B') + ' '
        if len(devices) != 1 or not devices[0]['name'].startswith(expected_name):
            parser.error('Ordinary task requires its explicitly named dedicated role simulator')
    elif args.simulator != SIMULATORS[args.role] or args.scenario in ('ordinaryRecovery', 'ordinaryTerminateAccepted'):
        parser.error('Role must use its dedicated task simulator')
    for key in ['xctestrun', 'app', 'rom', 'login_file']:
        setattr(args, key, getattr(args, key).resolve(strict=True))
    args.output = args.output.resolve()
    rom_sha = args.rom_sha256 if args.ordinary_task else ROM_SHA
    game_id = args.game_id if args.ordinary_task else GAME_ID
    if digest(args.rom) != rom_sha or hashlib.sha1(args.rom.read_bytes()).hexdigest() != game_id:
        parser.error('Exact frozen ROM required')
    if args.login_file.stat().st_mode & 0o077 or args.login_file.stat().st_size > 8192:
        parser.error('Synthetic login file must be bounded and private (mode0600)')
    login_bytes = args.login_file.read_bytes()
    login = json.loads(login_bytes)
    accounts = login.get('accounts', [])
    if (login.get('endpoint') != ENDPOINT or len(accounts) != 2
            or {a.get('role') for a in accounts} != set(SIMULATORS)
            or len({a.get('ownerID') for a in accounts}) != 2
            or any(not a.get('email', '').endswith('@bound-debug.invalid') for a in accounts)):
        parser.error('Only the task synthetic pair on the fixed loopback gateway is allowed')
    if args.role == 'buddy' and not args.ordinary_run_id:
        parser.error('Buddy requires the exact ordinary run ID emitted by controller')
    if args.scenario == 'ordinaryTerminateAccepted' and not args.ordinary_run_id:
        parser.error('Intentional termination requires an already confirmed explicit ordinary run')
    if args.previous_final_save and args.previous_termination:
        parser.error('Recovery must name one exact prior checkpoint source')
    if not ordinary_scenario and (not args.debug_session_id or not args.reviewed_fixtures or not args.reviewed_digests):
        parser.error('Paired scenario requires explicit session ID and reviewed native candidate files')
    app_info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    if app_info['CFBundleIdentifier'] != BUNDLE:
        parser.error('Unexpected application bundle')
    reviewed = None
    if args.reviewed_fixtures:
        args.reviewed_fixtures = args.reviewed_fixtures.resolve(strict=True)
        if not args.reviewed_digests:
            parser.error('Explicit reviewed digest file required')
        reviewed = json.loads(args.reviewed_digests.resolve(strict=True).read_text())
        if set(reviewed) != {'01/controller', '01/buddy'}:
            parser.error('Only an explicitly reviewed pair of point01 candidates is supported')
        for role in SIMULATORS:
            source = args.reviewed_fixtures / 'multiplayer-isolation-v1' / '01' / role
            certificate = source / 'certificate.json'
            if digest(certificate) != reviewed['01/' + role]:
                parser.error('Reviewed certificate digest changed')
            metadata = json.loads(certificate.read_text())
            if (metadata.get('compatibility', {}).get('romSHA256') != ROM_SHA
                    or metadata.get('compatibility', {}).get('gameID') != GAME_ID):
                parser.error('Reviewed candidate belongs to a different current ROM profile')
            if set(metadata['files']) != {'checkpoint.state', 'game.sav', 'soul-template.json'}:
                parser.error('Unexpected candidate files')
            for name, expected in metadata['files'].items():
                f = source / name
                if f.is_symlink() or not 0 < f.stat().st_size <= 4_194_304 or f.stat().st_size != expected['bytes'] or digest(f) != expected['sha256']:
                    parser.error('Native candidate bytes changed')
    args.output.mkdir(parents=True, exist_ok=False)
    attempt = uuid.uuid4()
    request = dict(version=1, attemptID=str(attempt), role=args.role, scenario=args.scenario,
                   creationRequestID=str(args.creation_request_id or uuid.uuid4()))
    if args.ordinary_task:
        request.update(expectedROM=rom_sha, expectedGameID=game_id)
    if args.os_background:
        if not args.ordinary_task or args.scenario != 'ordinaryRecovery':
            parser.error('OS background requires the explicitly scoped ordinary recovery scenario')
        request['exerciseOSBackground'] = True
    if args.previous_final_save:
        if not args.ordinary_task or not args.ordinary_run_id:
            parser.error('Previous receipt requires an explicit ordinary run')
        previous = json.loads(args.previous_final_save.resolve(strict=True).read_text())
        if previous.get('confirmedBeforeSignOut') is not True or type(previous.get('processID')) is not int:
            parser.error('Previous attempt must have confirmed its final save before sign-out')
        receipt = previous['receipt']
        owner = next(account['ownerID'] for account in accounts if account['role'] == args.role)
        if uuid.UUID(receipt['run']) != args.ordinary_run_id or uuid.UUID(receipt['owner']) != uuid.UUID(owner):
            parser.error('Previous confirmed receipt belongs to another run or owner')
        request.update(previousReceipt=receipt, previousProcessID=previous['processID'])
    if args.previous_termination:
        if not args.ordinary_task or args.scenario != 'ordinaryRecovery' or not args.ordinary_run_id:
            parser.error('Termination recovery requires an explicit ordinary recovery run')
        previous = json.loads(args.previous_termination.resolve(strict=True).read_text())
        prepared = previous.get('prepared', {})
        owner = next(account['ownerID'] for account in accounts if account['role'] == args.role)
        if (previous.get('status') != 'prepared-and-terminated' or previous.get('terminationExit') != 0
                or previous.get('preparedProcessAliveBefore') is not True or previous.get('preparedProcessExitedAfter') is not True
                or previous.get('driverFinishedNaturally') is not True
                or previous.get('finalSaveProofPresentBefore') is not False or previous.get('finalSaveProofPresentAfter') is not False
                or previous.get('simulator') != args.simulator or previous.get('romSHA256') != rom_sha or previous.get('gameID') != game_id
                or prepared.get('role') != args.role or type(prepared.get('processID')) is not int
                or prepared.get('acceptedPackageDownloaded') is not True or prepared.get('responseDelivered') is not False
                or prepared.get('finalSaveTeardownStarted') is not False
                or prepared.get('previousExperimental') is not None and type(prepared['previousExperimental']) is not bool):
            parser.error('Previous attempt did not prove this role was intentionally terminated at an accepted undelivered save')
        receipt = prepared['receipt']
        if uuid.UUID(receipt['run']) != args.ordinary_run_id or uuid.UUID(receipt['owner']) != uuid.UUID(owner):
            parser.error('Terminated checkpoint belongs to another run or owner')
        request.update(previousReceipt=receipt, previousProcessID=prepared['processID'],
                       previousTerminationAttemptID=str(uuid.UUID(prepared['attemptID'])),
                       restoreExperimentalPreferencePresent=prepared['previousExperimental'] is not None,
                       restoreExperimentalPreferenceEnabled=prepared['previousExperimental'])
    for field, value in [('ordinaryRunID', args.ordinary_run_id), ('debugSessionID', args.debug_session_id),
                         ('unrelatedOrdinaryRunID', args.unrelated_ordinary_run_id), ('reviewedCandidateCertificates', reviewed),
                         ('recoveryAttemptID', args.recovery_attempt_id)]:
        if value is not None:
            request[field] = str(value) if isinstance(value, uuid.UUID) else value
    request_bytes = (json.dumps(request, indent=2) + '\n').encode()
    (args.output / 'request.json').write_bytes(request_bytes)
    subprocess.run(['/usr/bin/xcrun', 'simctl', 'install', args.simulator, str(args.app)], check=True)
    documents = container(args.simulator) / 'Documents'
    root = documents / 'DEBUGLocalQA'
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.scenario in ('customCommitLossRecover', 'partialRestoreRecover'):
        directory = 'native-partial' if args.scenario == 'partialRestoreRecover' else 'native-restart'
        proof = root / directory / str(args.recovery_attempt_id).upper() / (args.role + '.json')
        if proof.is_symlink() or not proof.is_file() or proof.stat().st_size > 65536:
            raise RuntimeError('Recovery requires the original private stage-one proof in this simulator')
    resident_rom = root / 'RadicalRed.gba'
    if resident_rom.exists() and digest(resident_rom) != rom_sha:
        raise RuntimeError('Refusing to replace unexpected simulator input')
    if not resident_rom.exists():
        shutil.copy2(args.rom, resident_rom)
    secret = root / 'synthetic-login.json'
    fd = os.open(secret, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(login_bytes)
    os.chmod(secret, 0o600)
    (root / 'native-boundary-input.json').write_bytes(request_bytes)
    if reviewed:
        source = args.reviewed_fixtures / 'multiplayer-isolation-v1' / '01' / args.role
        target = documents / 'DEBUGFixtures' / 'multiplayer-isolation-v1' / '01' / args.role
        if target.exists():
            if any(not (target / p.name).exists() or digest(target / p.name) != digest(p) for p in source.iterdir() if p.is_file()):
                raise RuntimeError('Preserve existing different candidate fixture; use a fresh task input directory')
        else:
            shutil.copytree(source, target)
    targets = []
    def configure(value):
        if isinstance(value, dict):
            result = {k: configure(v) for k, v in value.items()}
            if result.get('BlueprintName') == TARGET:
                result.setdefault('EnvironmentVariables', {}).update(
                    BOUND_LOCAL_DEBUG_NATIVE_TEST='1', BOUND_QA_LOCAL_BACKEND='1', BOUND_QA_BACKEND_URL=ENDPOINT)
                if args.ordinary_task:
                    result['EnvironmentVariables'].update(BOUND_ORDINARY_QA_TASK='coordinator-stability',
                                                          BOUND_ORDINARY_QA_SIMULATOR=args.simulator)
                result['OnlyTestIdentifiers'] = [METHOD]
                targets.append(TARGET)
            return result
        if isinstance(value, list):
            return [configure(v) for v in value]
        return value.replace('__TESTROOT__', str(args.xctestrun.parent)) if isinstance(value, str) else value
    configured = configure(plistlib.loads(args.xctestrun.read_bytes()))
    if targets != [TARGET]:
        raise RuntimeError('Expected one explicit native test target')
    run_file = args.output / 'native-boundary.xctestrun'
    run_file.write_bytes(plistlib.dumps(configured))
    command = ['/usr/bin/xcodebuild', 'test-without-building', '-xctestrun', str(run_file),
               '-destination', 'platform=iOS Simulator,id=' + args.simulator,
               '-only-testing:' + TARGET + '/' + METHOD, '-parallel-testing-enabled', 'NO',
               '-collect-test-diagnostics', 'never', '-test-timeouts-enabled', 'YES',
               '-default-test-execution-time-allowance', '600', '-maximum-test-execution-time-allowance', '900',
               '-resultBundlePath', str(args.output / 'native-boundary.xcresult')]
    receipt = dict(version=1, simulator=args.simulator, request=request, command=command,
                   application_sha256=digest(args.app / app_info['CFBundleExecutable']),
                   xctestrun_sha256=digest(args.xctestrun), rom_sha256=rom_sha, game_id=game_id,
                   finalCertification=False, exit_code=-1)
    (args.output / 'invocation.json').write_text(json.dumps(receipt, indent=2) + '\n')
    background_handled = False
    termination = None
    with (args.output / 'native-boundary.log').open('wb') as log:
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 960
        while child.poll() is None:
            if time.monotonic() > deadline:
                child.terminate()
                child.wait(timeout=20)
                break
            if args.scenario == 'ordinaryTerminateAccepted':
                try:
                    current = container(args.simulator, quiet=True) / 'Documents/DEBUGLocalQA/native-results' / str(attempt).upper() / args.role
                except (OSError, subprocess.CalledProcessError):
                    time.sleep(0.25)
                    continue
                marker = current / 'ordinary-termination-prepared.json'
                if marker.is_file():
                    value = json.loads(marker.read_text())
                    owner = next(account['ownerID'] for account in accounts if account['role'] == args.role)
                    forbidden = ['final-native-save.json', 'failure.json', 'teardown-failure.json']
                    if (uuid.UUID(value['attemptID']) != attempt or value.get('role') != args.role
                            or type(value.get('processID')) is not int or value['processID'] <= 0
                            or uuid.UUID(value['receipt']['run']) != args.ordinary_run_id
                            or uuid.UUID(value['receipt']['owner']) != uuid.UUID(owner)
                            or value.get('acceptedPackageDownloaded') is not True or value.get('responseDelivered') is not False
                            or value.get('finalSaveTeardownStarted') is not False or any((current / name).exists() for name in forbidden)):
                        child.terminate(); child.wait(timeout=20)
                        raise RuntimeError('Refusing termination without an exact accepted, undelivered owner checkpoint')
                    # Preserve the atomic app statement before terminating
                    # its owner. A failed XCTest is never this proof.
                    shutil.copy2(marker, args.output / 'termination-prepared.json')
                    terminate_command = ['/usr/bin/xcrun', 'simctl', 'terminate', args.simulator, BUNDLE]
                    if not process_alive(value['processID']):
                        child.terminate(); child.wait(timeout=20)
                        raise RuntimeError('Prepared app already exited; an arbitrary crash is not intentional termination')
                    stopped = subprocess.run(terminate_command, capture_output=True, text=True, timeout=20)
                    termination = dict(version=1, status='pending', prepared=value,
                        simulator=args.simulator, romSHA256=rom_sha, gameID=game_id,
                        command=terminate_command, terminationExit=stopped.returncode,
                        preparedProcessAliveBefore=True, preparedProcessExitedAfter=False,
                        finalSaveProofPresentBefore=False, finalSaveProofPresentAfter=None,
                        driverFinishedNaturally=False, completedRecovery=False)
                    (args.output / 'intentional-termination.json').write_text(json.dumps(termination, indent=2) + '\n')
                    # Let XCTest/testmanager complete their expected crash
                    # handling. Killing the driver here can leave a stale
                    # launch/termination request racing the next recovery.
                    # The app blocks a prepared same-attempt rerun before auth
                    # or mutation; it cannot replace the original marker.
                    try:
                        child.wait(timeout=180)
                        termination['driverFinishedNaturally'] = True
                    except subprocess.TimeoutExpired:
                        child.terminate()
                        try:
                            child.wait(timeout=20)
                        except subprocess.TimeoutExpired:
                            child.kill(); child.wait(timeout=10)
                    exit_deadline = time.monotonic() + 5
                    while process_alive(value['processID']) and time.monotonic() < exit_deadline:
                        time.sleep(0.1)
                    termination['preparedProcessExitedAfter'] = not process_alive(value['processID'])
                    break
            if args.os_background and not background_handled:
                try:
                    current = container(args.simulator, quiet=True) / 'Documents/DEBUGLocalQA/native-results' / str(attempt).upper() / args.role
                except (OSError, subprocess.CalledProcessError):
                    # Xcode can briefly replace the data container during
                    # installation. Re-resolve only this task's explicit app.
                    time.sleep(0.25)
                    continue
                marker = current / 'ordinary-background-request.json'
                if marker.is_file():
                    value = json.loads(marker.read_text())
                    if uuid.UUID(value['attemptID']) != attempt or value['role'] != args.role:
                        raise RuntimeError('Background request changed owner/attempt')
                    background_command = ['/usr/bin/xcrun', 'simctl', 'launch', args.simulator, 'com.apple.Preferences']
                    foreground_command = ['/usr/bin/xcrun', 'simctl', 'launch', args.simulator, BUNDLE]
                    background = subprocess.run(background_command, capture_output=True, text=True, timeout=20)
                    time.sleep(2)
                    foreground = subprocess.run(foreground_command, capture_output=True, text=True, timeout=20)
                    acknowledgement = dict(attemptID=str(attempt), role=args.role,
                        backgroundExit=background.returncode, foregroundExit=foreground.returncode)
                    (current / 'ordinary-background-ack.json').write_text(json.dumps(acknowledgement) + '\n')
                    receipt['backgroundCommands'] = [background_command, foreground_command]
                    background_handled = True
            time.sleep(0.25)
        exit_code = child.returncode
    receipt['exit_code'] = exit_code
    # Xcode may relocate the application's data container while reinstalling.
    evidence = container(args.simulator) / 'Documents' / 'DEBUGLocalQA' / 'native-results' / str(attempt).upper() / args.role
    if evidence.exists():
        shutil.copytree(evidence, args.output / 'evidence')
    required = ['ordinary-native-proof.json', 'final-native-save.json']
    if args.previous_final_save or args.previous_termination:
        required.append('ordinary-restart-proof.json')
    if args.scenario == 'ordinaryTerminateAccepted':
        required += ['ordinary-termination-prepared.json']
        required.remove('final-native-save.json')
    elif args.scenario == 'ordinaryRecovery':
        required += ['ordinary-held-reply.json', 'ordinary-recovery-proof.json']
        if args.os_background:
            required.append('ordinary-background-proof.json')
    elif args.scenario == 'customCommitLossRecover':
        required = ['restart-recovered.json', 'final-native-save.json']
    elif args.scenario == 'partialRestorePrepare':
        required += ['partial-prepared.json', 'boundary-proof.json', 'phase-armed.json', 'phase-observed.json', 'phase-settled.json',
                     'partial-install-observation.json', 'partial-admission-observation.json']
    elif args.scenario == 'partialRestoreRecover':
        required = ['partial-recovered.json', 'final-native-save.json', 'boundary-proof.json',
                    'phase-armed.json', 'phase-withheld.json', 'phase-verified.json']
        if args.role == 'buddy':
            required.append('partial-history-replay.json')
    elif args.scenario != 'ordinary':
        if args.role == 'buddy' or args.scenario != 'staleOrdinarySelection':
            required.append('paired-native-proof.json')
            required.append('sanitized-debug-report.json')
        if args.role == 'controller':
            required.append('boundary-proof.json')
        if args.scenario == 'customCommitLossPrepare':
            required += ['restart-prepared.json', 'boundary-proof.json']
        if args.scenario in ('reloadBuiltin', 'reloadCustom', 'buddyLeave', 'controllerRevoke'):
            phases = ['prepared', 'withheld', 'verified'] if args.scenario.startswith('reload') else ['prepared', 'denied', 'returned']
            if args.scenario == 'reloadCustom':
                phases.insert(0, 'archive')
            required += ['boundary-proof.json'] + ['phase-' + phase + '.json' for phase in phases]
    proofs_present = all((args.output / 'evidence' / name).exists() for name in required)
    if args.scenario == 'ordinaryTerminateAccepted':
        final_present = (args.output / 'evidence/final-native-save.json').exists()
        failure_present = any((args.output / 'evidence' / name).exists() for name in ['failure.json', 'teardown-failure.json'])
        prepared_ok = (termination is not None and termination['terminationExit'] == 0
                       and termination['preparedProcessAliveBefore'] and termination['preparedProcessExitedAfter']
                       and termination['driverFinishedNaturally']
                       and proofs_present and not final_present and not failure_present)
        receipt['status'] = 'prepared-and-terminated' if prepared_ok else 'failed'
        receipt['completedRecovery'] = False
        if termination is not None:
            termination.update(status=receipt['status'], finalSaveProofPresentAfter=final_present, xcodeExit=exit_code,
                sameAttemptRerunBlocked=(args.output / 'evidence/ordinary-termination-rerun-blocked.json').is_file())
            (args.output / 'intentional-termination.json').write_text(json.dumps(termination, indent=2) + '\n')
    else:
        receipt['status'] = 'passed' if exit_code == 0 and proofs_present else 'failed'
    (args.output / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({k: receipt[k] for k in ['status', 'exit_code', 'finalCertification']}))
    raise SystemExit(0 if receipt['status'] in ('passed', 'prepared-and-terminated') else 1)


if __name__ == '__main__':
    main()
