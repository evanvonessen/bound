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


def container(simulator):
    return Path(subprocess.check_output(
        ['/usr/bin/xcrun', 'simctl', 'get_app_container', simulator, BUNDLE, 'data'], text=True).strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['xctestrun', 'app', 'rom', 'login-file', 'output']:
        parser.add_argument('--' + key, type=Path, required=True)
    parser.add_argument('--role', choices=list(SIMULATORS), required=True)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--scenario', choices=['ordinary', 'customHold', 'returnHold', 'returnVerifyLostReply', 'customLostReply', 'staleOrdinarySelection', 'unseenPeerDeath', 'customCommitLossPrepare', 'customCommitLossRecover', 'reloadBuiltin', 'reloadCustom', 'buddyLeave', 'controllerRevoke', 'partialRestorePrepare', 'partialRestoreRecover'], default='ordinary')
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
    if args.simulator != SIMULATORS[args.role]:
        parser.error('Role must use its dedicated task simulator')
    for key in ['xctestrun', 'app', 'rom', 'login_file']:
        setattr(args, key, getattr(args, key).resolve(strict=True))
    args.output = args.output.resolve()
    if digest(args.rom) != ROM_SHA or hashlib.sha1(args.rom.read_bytes()).hexdigest() != GAME_ID:
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
    if args.scenario != 'ordinary' and (not args.debug_session_id or not args.reviewed_fixtures or not args.reviewed_digests):
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
    if resident_rom.exists() and digest(resident_rom) != ROM_SHA:
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
                   xctestrun_sha256=digest(args.xctestrun), rom_sha256=ROM_SHA,
                   finalCertification=False, exit_code=-1)
    (args.output / 'invocation.json').write_text(json.dumps(receipt, indent=2) + '\n')
    with (args.output / 'native-boundary.log').open('wb') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    receipt['exit_code'] = result.returncode
    # Xcode may relocate the application's data container while reinstalling.
    evidence = container(args.simulator) / 'Documents' / 'DEBUGLocalQA' / 'native-results' / str(attempt).upper() / args.role
    if evidence.exists():
        shutil.copytree(evidence, args.output / 'evidence')
    required = ['ordinary-native-proof.json', 'final-native-save.json']
    if args.scenario == 'customCommitLossRecover':
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
    receipt['status'] = 'passed' if result.returncode == 0 and all((args.output / 'evidence' / name).exists() for name in required) else 'failed'
    (args.output / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({k: receipt[k] for k in ['status', 'exit_code', 'finalCertification']}))
    raise SystemExit(0 if receipt['status'] == 'passed' else 1)


if __name__ == '__main__':
    main()
