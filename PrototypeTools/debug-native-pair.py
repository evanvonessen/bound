#!/usr/bin/env python3
"""Run both dedicated native DEBUG roles with explicit, shared task inputs.

Use PrototypeTools/qa-python and pass the isolated --game-source. --audit-only
validates inputs and prints the role assignments without launching or staging
anything. This runner grants no fixture certification or server authority.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import stat
import subprocess
import time
import uuid

SIMULATORS = {
    'controller': '92586556-6715-4BA0-98FC-5C1FF776F0A9',
    'buddy': '14BD3EC6-B57B-49A1-98D1-457A9DC0C088',
}
BUNDLE = 'com.evanvonessen.bound'
ENDPOINT = 'https://127.0.0.1:58552'
ROM_SHA = '02f97ffa88f71015d2da5df114c0bf48d7c80f37f64d10075a81fef2dc6d8a79'
GAME_ID = '4b792d8f8b86e1a65b27965bb523fe0a48a20190'
SCENARIOS = ('customHold', 'returnHold', 'returnVerifyLostReply', 'customLostReply', 'staleOrdinarySelection', 'unseenPeerDeath', 'customCommitLossPrepare', 'customCommitLossRecover', 'reloadBuiltin', 'reloadCustom', 'buddyLeave', 'controllerRevoke', 'partialRestorePrepare', 'partialRestoreRecover')
SCENARIO_PHASES = {
    'reloadBuiltin': ('prepared', 'withheld', 'verified'),
    'reloadCustom': ('archive', 'prepared', 'withheld', 'verified'),
    'buddyLeave': ('prepared', 'denied', 'returned'),
    'controllerRevoke': ('prepared', 'denied', 'returned'),
    'partialRestorePrepare': ('armed', 'observed', 'settled'),
    'partialRestoreRecover': ('armed', 'withheld', 'verified'),
}
TOOLS = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON field')
        result[key] = value
    return result


def small_json(path, maximum=8192):
    """Bound the read itself and reject symlink/non-file handoffs."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise ValueError('Expected bounded regular JSON file')
        data = source.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError('JSON file grew beyond limit')
    value = json.loads(data, object_pairs_hook=unique_object)
    if not isinstance(value, dict):
        raise ValueError('Expected JSON object')
    return value


def uuid_text(value):
    if not isinstance(value, str):
        raise ValueError('Expected UUID string')
    return str(uuid.UUID(value))


def atomic_receipt(path, value):
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('x', encoding='utf8') as destination:
        json.dump(value, destination, indent=2, sort_keys=True)
        destination.write('\n')
    os.replace(temporary, path)


def current_container(role, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return None
    try:
        result = subprocess.run(['/usr/bin/xcrun', 'simctl', 'get_app_container',
            SIMULATORS[role], BUNDLE, 'data'], capture_output=True, text=True, timeout=min(5, remaining))
    except subprocess.TimeoutExpired:
        return None
    if result.returncode != 0:
        return None
    path = Path(result.stdout.strip())
    return path.resolve(strict=True) if path.is_absolute() and path.is_dir() else None


def role_request(args, role):
    try:
        value = small_json(args.output / role / 'request.json')
    except (FileNotFoundError, json.JSONDecodeError):
        # The child writes request.json immediately before its install. A
        # partial first read can be retried while that child remains alive.
        return None
    if (value.get('version') != 1 or value.get('role') != role
            or value.get('scenario') != args.scenario
            or uuid_text(value.get('ordinaryRunID')) != str(args.ordinary_run_id)
            or uuid_text(value.get('debugSessionID')) != str(args.debug_session_id)
            or uuid_text(value.get('creationRequestID')) != str(args.creation_request_id)):
        raise ValueError('Child request does not match the explicit pair')
    if args.recovery_attempt_id is not None and uuid_text(value.get('recoveryAttemptID')) != str(args.recovery_attempt_id):
        raise ValueError('Child recovery scope changed')
    return uuid_text(value.get('attemptID'))


def handoff(args, attempts, deadline):
    """An operation ID is a hint; the buddy must authenticate its status."""
    controller = current_container('controller', deadline)
    buddy = current_container('buddy', deadline)
    if controller is None or buddy is None:
        return None
    source = (controller / 'Documents/DEBUGLocalQA/native-results'
              / attempts['controller'].upper() / 'controller/boundary-operation.json')
    try:
        value = small_json(source, maximum=2048)
    except FileNotFoundError:
        return None
    if (set(value) != {'version', 'sessionID', 'scenario', 'operationID'}
            or type(value['version']) is not int or value['version'] != 1
            or value['scenario'] != args.scenario
            or uuid_text(value['sessionID']) != str(args.debug_session_id)):
        raise ValueError('Controller operation does not match this pair')
    normalized = dict(version=1, sessionID=str(args.debug_session_id),
                      scenario=args.scenario, operationID=uuid_text(value['operationID']))
    data = (json.dumps(normalized, sort_keys=True) + '\n').encode()
    # Re-resolved each time: Xcode may replace the data-container path during
    # installation. Never reuse a path from the previous polling iteration.
    root = buddy / 'Documents/DEBUGLocalQA'
    if not root.is_dir():
        return None
    directory = root / 'native-handoffs'
    if directory.is_symlink() or not root.resolve().is_relative_to(buddy):
        raise ValueError('Unexpected buddy handoff directory')
    directory.mkdir(mode=0o700, exist_ok=True)
    destination = directory / (attempts['buddy'].upper() + '.json')
    if destination.exists() or destination.is_symlink():
        if small_json(destination, maximum=2048) != normalized:
            raise ValueError('Preserve a different existing handoff')
    else:
        # Write completely before linking into the watched filename. link()
        # cannot overwrite a handoff, even if another writer raced this check.
        temporary = directory / ('.' + attempts['buddy'].upper() + '-' + uuid.uuid4().hex)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, 'wb') as output:
                output.write(data); output.flush(); os.fsync(output.fileno())
            try:
                os.link(temporary, destination)
            except FileExistsError:
                if small_json(destination, maximum=2048) != normalized:
                    raise ValueError('Preserve a different existing handoff')
        finally:
            temporary.unlink()
    return dict(operationID=normalized['operationID'], sha256=digest(destination))


def stop_children(children):
    # Only the process groups created below: no simctl terminate/shutdown and
    # no app/container erasure. Give the existing runners time to unwind.
    for sig, allowance in ((signal.SIGINT, 8), (signal.SIGTERM, 5)):
        alive = [child for child in children.values() if child.poll() is None]
        if not alive:
            return
        for child in alive:
            try:
                os.killpg(child.pid, sig)
            except ProcessLookupError:
                pass
        until = time.monotonic() + allowance
        while any(child.poll() is None for child in alive) and time.monotonic() < until:
            time.sleep(0.1)


def recovery_handoff(args, attempts, deadline):
    """Delay cleanup until both native recoveries finish; grants no authority."""
    containers, proofs = {}, {}
    for role in SIMULATORS:
        container = current_container(role, deadline)
        if container is None:
            return None
        containers[role] = container
        source = container / 'Documents/DEBUGLocalQA/native-results' / attempts[role].upper() / role / 'restart-recovered.json'
        try:
            proof = small_json(source, 65536)
        except FileNotFoundError:
            return None
        if (proof.get('scenario') != args.scenario or proof.get('scenarioOutcomeVerified') is not True
                or uuid_text(proof.get('attemptID')) != attempts[role]
                or uuid_text(proof.get('sessionID')) != str(args.debug_session_id)
                or uuid_text(proof.get('recoveryAttemptID')) != str(args.recovery_attempt_id)
                or type(proof.get('processID')) is not int or proof['processID'] == proof.get('previousProcessID')):
            raise ValueError('Native recovery proof does not match this pair')
        proofs[role] = proof
    value = dict(version=1, scenario=args.scenario, sessionID=str(args.debug_session_id),
                 recoveryAttemptID=str(args.recovery_attempt_id), attempts=attempts)
    for role, container in containers.items():
        directory = container / 'Documents/DEBUGLocalQA/native-handoffs'
        if directory.is_symlink() or not directory.parent.resolve().is_relative_to(container):
            raise ValueError('Unexpected recovery handoff directory')
        directory.mkdir(mode=0o700, exist_ok=True)
        destination = directory / (attempts[role].upper() + '.json')
        if destination.exists() or destination.is_symlink():
            if small_json(destination, 4096) != value:
                raise ValueError('Preserve a different existing handoff')
        else:
            atomic_receipt(destination, value)
    return {role: proof['processID'] for role, proof in proofs.items()}


def scenario_handoff(args, attempts, phase, deadline):
    """Coordinate test observation/cleanup without granting runtime authority."""
    containers, proofs = {}, {}
    for role in SIMULATORS:
        container = current_container(role, deadline)
        if container is None:
            return None
        containers[role] = container
        source = container / 'Documents/DEBUGLocalQA/native-results' / attempts[role].upper() / role / ('phase-' + phase + '.json')
        try:
            proof = small_json(source, 65536)
        except FileNotFoundError:
            return None
        if (proof.get('version') != 1 or proof.get('scenario') != args.scenario or proof.get('phase') != phase
                or proof.get('role') != role or uuid_text(proof.get('attemptID')) != attempts[role]
                or uuid_text(proof.get('sessionID')) != str(args.debug_session_id)
                or type(proof.get('processID')) is not int or proof['processID'] <= 0):
            raise ValueError('Native phase proof does not match this pair')
        proofs[role] = proof
    if phase == 'archive' and (proofs['controller'].get('operationID') != proofs['buddy'].get('operationID')
                               or proofs['controller'].get('generation') != proofs['buddy'].get('generation')):
        raise ValueError('Native owners observed different custom archives')
    if phase == 'verified' and proofs['controller'].get('generation') != proofs['buddy'].get('generation'):
        raise ValueError('Native owners verified different generations')
    if args.scenario.startswith('partialRestore') and phase in ('observed', 'settled', 'verified'):
        if (proofs['controller'].get('generation') != proofs['buddy'].get('generation')
                or proofs['controller'].get('manifestDigest') != proofs['buddy'].get('manifestDigest')):
            raise ValueError('Partial native owners observed different committed targets')
        if phase in ('observed', 'settled') and (proofs['controller'].get('installed') is not True or proofs['buddy'].get('installed') is not False):
            raise ValueError('Partial preparation must leave exactly the buddy uninstalled')
        if phase == 'observed' and (proofs['controller'].get('nativeRestoreCount') != 1 or proofs['buddy'].get('nativeRestoreCount') != 0):
            raise ValueError('Partial native observation counts do not match the installed roles')
    value = dict(version=1, scenario=args.scenario, phase=phase, sessionID=str(args.debug_session_id), attempts=attempts)
    for role, container in containers.items():
        directory = container / 'Documents/DEBUGLocalQA/native-handoffs'
        if directory.is_symlink() or not directory.parent.resolve().is_relative_to(container):
            raise ValueError('Unexpected native phase handoff directory')
        directory.mkdir(mode=0o700, exist_ok=True)
        destination = directory / (attempts[role].upper() + '-' + phase + '.json')
        if destination.exists() or destination.is_symlink():
            if small_json(destination, 4096) != value:
                raise ValueError('Preserve a different existing native phase handoff')
        else:
            atomic_receipt(destination, value)
    return {role: proof['processID'] for role, proof in proofs.items()}


def validate(args):
    if args.scenario.startswith(('customCommitLoss', 'partialRestore')) != (args.recovery_attempt_id is not None):
        raise ValueError('Restart stages require one explicit recovery attempt ID')
    expected_game = TOOLS.parent.parent / 'multi_red-multiplayer-isolation'
    args.game_source = args.game_source.resolve(strict=True)
    if args.game_source != expected_game.resolve(strict=True):
        raise ValueError('Only the isolated task game checkout is allowed')
    for name in ('rom', 'login_file', 'reviewed_fixtures', 'reviewed_digests',
                 'controller_app', 'buddy_app', 'controller_xctestrun', 'buddy_xctestrun'):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    args.output = args.output.absolute()
    if args.output.exists() or args.output.is_symlink():
        raise ValueError('Output must be a new directory; preserve prior attempts')
    if digest(args.rom) != ROM_SHA or hashlib.sha1(args.rom.read_bytes()).hexdigest() != GAME_ID:
        raise ValueError('Exact frozen ROM required')
    if args.login_file.stat().st_mode & 0o077:
        raise ValueError('Synthetic login file must be private')
    login = small_json(args.login_file)
    accounts = login.get('accounts', [])
    if (login.get('endpoint') != ENDPOINT or len(accounts) != 2
            or {a.get('role') for a in accounts} != set(SIMULATORS)
            or len({uuid_text(a.get('ownerID')) for a in accounts}) != 2
            or any(not a.get('email', '').endswith('@bound-debug.invalid') for a in accounts)):
        raise ValueError('Only the fixed task-local synthetic account pair is allowed')
    reviewed = small_json(args.reviewed_digests)
    if set(reviewed) != {'01/controller', '01/buddy'}:
        raise ValueError('Explicit reviewed point01 pair required')
    for role in SIMULATORS:
        app = getattr(args, role + '_app')
        if plistlib.loads((app / 'Info.plist').read_bytes()).get('CFBundleIdentifier') != BUNDLE:
            raise ValueError('Unexpected application bundle')
        plistlib.loads(getattr(args, role + '_xctestrun').read_bytes())
        fixture = args.reviewed_fixtures / 'multiplayer-isolation-v1/01' / role
        if digest(fixture / 'certificate.json') != reviewed['01/' + role]:
            raise ValueError('Reviewed candidate certificate changed')
        certificate = small_json(fixture / 'certificate.json', maximum=65536)
        if (certificate.get('compatibility', {}).get('romSHA256') != ROM_SHA
                or certificate.get('compatibility', {}).get('gameID') != GAME_ID):
            raise ValueError('Reviewed candidate belongs to a different current ROM profile')
        files = certificate.get('files', {})
        if set(files) != {'checkpoint.state', 'game.sav', 'soul-template.json'}:
            raise ValueError('Unexpected candidate files')
        for name, expected in files.items():
            path = fixture / name
            if (path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= 4194304
                    or path.stat().st_size != expected.get('bytes') or digest(path) != expected.get('sha256')):
                raise ValueError('Native candidate bytes changed')
    if args.scenario == 'staleOrdinarySelection' and (not args.unrelated_ordinary_run_id
            or args.unrelated_ordinary_run_id == args.ordinary_run_id):
        raise ValueError('Stale selection needs a different explicit task ordinary run')


def command(args, role):
    result = [str(TOOLS / 'qa-python'), str(TOOLS / 'debug-native-boundary.py'),
        '--role', role, '--simulator', SIMULATORS[role], '--scenario', args.scenario,
        '--app', str(getattr(args, role + '_app')),
        '--xctestrun', str(getattr(args, role + '_xctestrun')),
        '--rom', str(args.rom), '--login-file', str(args.login_file),
        '--output', str(args.output / role), '--ordinary-run-id', str(args.ordinary_run_id),
        '--debug-session-id', str(args.debug_session_id), '--creation-request-id', str(args.creation_request_id),
        '--reviewed-fixtures', str(args.reviewed_fixtures), '--reviewed-digests', str(args.reviewed_digests)]
    if args.unrelated_ordinary_run_id:
        result += ['--unrelated-ordinary-run-id', str(args.unrelated_ordinary_run_id)]
    if args.recovery_attempt_id:
        result += ['--recovery-attempt-id', str(args.recovery_attempt_id)]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('game-source', 'rom', 'login-file', 'reviewed-fixtures', 'reviewed-digests',
                 'controller-app', 'buddy-app', 'controller-xctestrun', 'buddy-xctestrun', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('ordinary-run-id', 'debug-session-id', 'creation-request-id'):
        parser.add_argument('--' + name, type=uuid.UUID, required=True)
    parser.add_argument('--unrelated-ordinary-run-id', type=uuid.UUID)
    parser.add_argument('--recovery-attempt-id', type=uuid.UUID)
    parser.add_argument('--scenario', choices=SCENARIOS, required=True)
    parser.add_argument('--timeout-seconds', type=int, default=1200, help='Pair deadline, 30–1200 seconds, including 13 seconds reserved for polite shutdown')
    parser.add_argument('--audit-only', action='store_true')
    args = parser.parse_args()
    if not 30 <= args.timeout_seconds <= 1200:
        parser.error('Timeout must be between 30 and 1200 seconds')
    try:
        validate(args)
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        parser.error('Input validation failed; check explicit paths, task identities, and reviewed file hashes')
    receipt = dict(version=1, scenario=args.scenario, ordinaryRunID=str(args.ordinary_run_id),
        sessionID=str(args.debug_session_id), creationRequestID=str(args.creation_request_id),
        status='audited' if args.audit_only else 'running', finalCertification=False,
        roles={role: dict(simulatorID=simulator) for role, simulator in SIMULATORS.items()}, handoff=None, scenarioHandoffs={})
    if args.audit_only:
        print(json.dumps(receipt, sort_keys=True)); return 0
    args.output.mkdir(parents=True, mode=0o700, exist_ok=False)
    atomic_receipt(args.output / 'pair-result.json', receipt)
    children, logs, attempts = {}, [], {}
    next_handoff = 0
    interrupted = False
    def interruption(_signal, _frame):
        nonlocal interrupted
        interrupted = True
    handlers = {sig: signal.signal(sig, interruption) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        environment = os.environ.copy(); environment['BOUND_GAME_SOURCE'] = str(args.game_source)
        deadline = time.monotonic() + args.timeout_seconds - 13
        for role in SIMULATORS:
            if interrupted:
                break
            log = (args.output / (role + '-runner.log')).open('xb'); logs.append(log)
            children[role] = subprocess.Popen(command(args, role), env=environment,
                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        while any(child.poll() is None for child in children.values()):
            if interrupted or time.monotonic() >= deadline:
                receipt['reason'] = 'interrupted' if interrupted else 'deadline'
                break
            for role in children:
                if role not in attempts:
                    attempt = role_request(args, role)
                    if attempt:
                        attempts[role] = attempt
            if (args.scenario == 'customLostReply' and len(attempts) == 2
                    and children['buddy'].poll() is None and time.monotonic() >= next_handoff):
                delivered = handoff(args, attempts, deadline)
                next_handoff = time.monotonic() + 1
                if delivered:
                    if receipt['handoff'] is not None and receipt['handoff'] != delivered:
                        raise ValueError('Controller operation changed after handoff')
                    receipt['handoff'] = delivered
            if (args.scenario == 'customCommitLossRecover' and len(attempts) == 2
                    and time.monotonic() >= next_handoff and receipt['handoff'] is None):
                receipt['handoff'] = recovery_handoff(args, attempts, deadline)
                next_handoff = time.monotonic() + 1
            if args.scenario in SCENARIO_PHASES and len(attempts) == 2 and time.monotonic() >= next_handoff:
                for phase in SCENARIO_PHASES[args.scenario]:
                    if phase not in receipt['scenarioHandoffs']:
                        delivered = scenario_handoff(args, attempts, phase, deadline)
                        if delivered:
                            receipt['scenarioHandoffs'][phase] = delivered
                        break
                next_handoff = time.monotonic() + 0.25
            time.sleep(0.25)
    except (OSError, ValueError, subprocess.SubprocessError):
        receipt['reason'] = 'orchestration-error'
    finally:
        stop_children(children)
        for log in logs:
            log.close()
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
        for role, details in receipt['roles'].items():
            child = children.get(role)
            if role not in attempts:
                try:
                    attempt = role_request(args, role)
                    if attempt:
                        attempts[role] = attempt
                except (OSError, ValueError):
                    pass
            details.update(attemptID=attempts.get(role), exitCode=child.poll() if child else None)
            try:
                result = small_json(args.output / role / 'result.json', maximum=65536)
                details['runnerStatus'] = result.get('status')
            except (OSError, ValueError):
                details['runnerStatus'] = 'missing'
            evidence = args.output / role / 'evidence'
            names = ['ordinary-native-proof', 'paired-native-proof', 'sanitized-debug-report', 'final-native-save']
            if args.scenario == 'customCommitLossRecover':
                names = ['restart-recovered', 'final-native-save']
            elif args.scenario == 'partialRestorePrepare':
                names = ['ordinary-native-proof', 'final-native-save', 'partial-prepared']
            elif args.scenario == 'partialRestoreRecover':
                names = ['partial-recovered', 'final-native-save']
                if role == 'buddy':
                    names.append('partial-history-replay')
            elif role == 'controller':
                names.append('boundary-proof')
                if args.scenario == 'staleOrdinarySelection':
                    names.remove('paired-native-proof')
                    names.remove('sanitized-debug-report')
            if args.scenario == 'customCommitLossPrepare':
                names += ['restart-prepared', 'boundary-proof']
            if args.scenario in SCENARIO_PHASES:
                names += ['boundary-proof'] + ['phase-' + phase for phase in SCENARIO_PHASES[args.scenario]]
            details['evidence'] = {name: (evidence / (name + '.json')).is_file() for name in names}
        success = (not interrupted and 'reason' not in receipt
            and all(v['attemptID'] is not None and v['exitCode'] == 0
                    and v['runnerStatus'] == 'passed' and all(v['evidence'].values())
                    for v in receipt['roles'].values())
            and (args.scenario not in ('customLostReply', 'customCommitLossRecover') or receipt['handoff'] is not None)
            and all(phase in receipt['scenarioHandoffs'] for phase in SCENARIO_PHASES.get(args.scenario, ())))
        receipt['status'] = 'passed' if success else 'failed'
        atomic_receipt(args.output / 'pair-result.json', receipt)
    print(json.dumps(receipt, sort_keys=True))
    return 0 if success else 1


if __name__ == '__main__':
    raise SystemExit(main())
