#!/usr/bin/env python3
"""Run two actual paired DEBUG processes, then recover their private intents.

The default prepare stage confirms gameplay before losing an archive reply.
--kind partialRestore leaves exactly one owner uninstalled after durable commit.
The recover stage must run in new app PIDs on the same two dedicated simulators.
Use qa-python and the isolated game checkout. --audit-only changes nothing.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import uuid

TOOLS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('debug_native_pair', TOOLS / 'debug-native-pair.py')
pair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pair)
PATHS = ('game-source', 'rom', 'login-file', 'reviewed-fixtures', 'reviewed-digests',
         'controller-app', 'buddy-app', 'controller-xctestrun', 'buddy-xctestrun')
IDS = ('ordinary-run-id', 'debug-session-id', 'creation-request-id', 'recovery-attempt-id')


def stage_command(args, stage):
    command = [str(TOOLS / 'qa-python'), str(TOOLS / 'debug-native-pair.py')]
    for name in PATHS + IDS:
        command += ['--' + name, str(getattr(args, name.replace('-', '_')))]
    command += ['--scenario', args.kind + ('Prepare' if stage == 'prepare' else 'Recover'),
                '--output', str(args.output / stage), '--timeout-seconds', str(args.timeout_seconds)]
    return command


def verify_recovery(args):
    if args.kind == 'partialRestore':
        return verify_partial_recovery(args)
    result = {}
    operations = set()
    for role in pair.SIMULATORS:
        first = pair.small_json(args.output / 'prepare' / role / 'evidence/restart-prepared.json', 65536)
        second = pair.small_json(args.output / 'recover' / role / 'evidence/restart-recovered.json', 65536)
        first_request = pair.small_json(args.output / 'prepare' / role / 'request.json')
        second_request = pair.small_json(args.output / 'recover' / role / 'request.json')
        if (first['version'] != 1 or pair.uuid_text(first['recoveryAttemptID']) != str(args.recovery_attempt_id)
                or pair.uuid_text(first['sessionID']) != str(args.debug_session_id)
                or first_request['attemptID'] == second_request['attemptID']
                or pair.uuid_text(first['attemptID']) != pair.uuid_text(first_request['attemptID'])
                or type(first['processID']) is not int or type(second['processID']) is not int
                or first['processID'] == second['processID'] or first['processID'] != second['previousProcessID']
                or second['scenarioOutcomeVerified'] is not True or second['archiveNotRestored'] is not True
                or second['ordinaryUnchanged'] is not True or first['receipt'] != second['latestActiveReceipt']
                or first['frame'] != second['nativeFrame'] or first['activeGeneration'] != second['activeGeneration']
                or first['archiveGeneration'] != second['archiveGeneration']
                or first['stateSHA256'] == first['archiveStateSHA256']):
            raise ValueError('Fresh-process native recovery evidence does not match its exact prepared scope')
        operations.add(pair.uuid_text(first['operationID']))
        result[role] = dict(previousProcessID=first['processID'], processID=second['processID'],
                            activeGeneration=first['activeGeneration'], archiveGeneration=first['archiveGeneration'],
                            checkpoint=first['receipt']['checkpoint'], nativeFrame=first['frame'])
    if len(operations) != 1:
        raise ValueError('The two roles did not archive the same operation')
    return result


def verify_partial_recovery(args):
    result, targets, owners, devices, ordinary, prepared = {}, set(), set(), set(), [], {}
    for role in pair.SIMULATORS:
        first = pair.small_json(args.output / 'prepare' / role / 'evidence/partial-prepared.json', 65536)
        prepared[role] = first
        second = pair.small_json(args.output / 'recover' / role / 'evidence/partial-recovered.json', 65536)
        initial = pair.small_json(args.output / 'prepare' / role / 'request.json')
        resumed = pair.small_json(args.output / 'recover' / role / 'request.json')
        installed = role == 'controller'
        target = first['target']
        owner = pair.uuid_text(first['ownerID'])
        descriptor = target['owners'][owner]
        receipt = first['outgoing'] if installed else descriptor['receipt']
        if (first['version'] != 1 or first['installed'] is not installed or second['wasInstalled'] is not installed
                or pair.uuid_text(first['recoveryAttemptID']) != str(args.recovery_attempt_id)
                or pair.uuid_text(second['recoveryAttemptID']) != str(args.recovery_attempt_id)
                or pair.uuid_text(target['sessionID']) != str(args.debug_session_id)
                or pair.uuid_text(second['sessionID']) != str(args.debug_session_id)
                or pair.uuid_text(initial['attemptID']) == pair.uuid_text(resumed['attemptID'])
                or pair.uuid_text(first['attemptID']) != pair.uuid_text(initial['attemptID'])
                or pair.uuid_text(second['attemptID']) != pair.uuid_text(resumed['attemptID'])
                or type(first['processID']) is not int or type(second['processID']) is not int
                or first['processID'] == second['processID'] or first['processID'] != second['previousProcessID']
                or pair.uuid_text(second['ownerID']) != owner or pair.uuid_text(descriptor['deviceID']) != pair.uuid_text(first['deviceID'])
                or pair.uuid_text(second['deviceID']) != pair.uuid_text(first['deviceID'])
                or target['generation'] != 1 or second['generation'] != target['generation']
                or second['manifestDigest'] != target['digest'] or second['candidateSHA256'] != first['candidateSHA256']
                or first['candidateSHA256'] != descriptor['receipt']['payloadSHA256']
                or second['scenarioOutcomeVerified'] is not True or second['ordinaryUnchanged'] is not True or second['ready'] is not True
                or second['nativeRestoreCount'] != (0 if installed else 1) or second['latestRecoveryCount'] != (1 if installed else 0)
                or second['installedReceipt'] != receipt):
            raise ValueError('Partial native recovery does not match the original private owner/generation proof')
        if installed and (second['nativeFrame'] != first['frame'] or first['outgoing'] == descriptor['receipt']
                          or first['stateSHA256'] == descriptor['files']['checkpoint.state']['sha256']):
            raise ValueError('Installed owner rewound to its baseline instead of recovering the latest checkpoint')
        if not installed and pair.uuid_text(first['nativeIdentity']['run']) == pair.uuid_text(target['runID']):
            raise ValueError('Buddy already installed the target in the preparation process')
        targets.add((target['digest'], pair.uuid_text(target['operationID'])))
        owners.add(owner); devices.add(pair.uuid_text(first['deviceID'])); ordinary.append(first['ordinary'])
        result[role] = dict(previousProcessID=first['processID'], processID=second['processID'], generation=target['generation'],
            nativeRestoreCount=second['nativeRestoreCount'], latestRecoveryCount=second['latestRecoveryCount'],
            checkpoint=receipt['checkpoint'], nativeFrame=second['nativeFrame'])
    # GET identities are deliberately owner-relative. Compare the same shared
    # run/fence, with reciprocal owner seeds, rather than requiring equal owners.
    left, right = ordinary[0]['identity'], ordinary[1]['identity']
    common = ('run', 'gameID', 'roomID', 'settingsOwner', 'settings', 'romSHA256', 'protocolVersion', 'saveVersion')
    same_fence = ({key: value for key, value in ordinary[0].items() if key != 'identity'}
                  == {key: value for key, value in ordinary[1].items() if key != 'identity'})
    if (len(targets) != 1 or len(owners) != 2 or len(devices) != 2 or not same_fence
            or any(left[key] != right[key] for key in common)
            or pair.uuid_text(left['run']) != str(args.ordinary_run_id)
            or pair.uuid_text(left['owner']) != pair.uuid_text(right['partner'])
            or pair.uuid_text(left['partner']) != pair.uuid_text(right['owner'])
            or left['localSeed'] != right['partnerSeed'] or left['partnerSeed'] != right['localSeed']):
        raise ValueError('Partial restore roles do not share the same target and settled ordinary fence')
    history = pair.small_json(args.output / 'recover/buddy/evidence/partial-history-replay.json', 65536)
    if (history['nativeVerified'] is not True or history['appliedCoversCurrent'] is not True
            or history['strictlyBeyondBaseline'] is not True
            or pair.uuid_text(history['peerReceipt']['owner']) != pair.uuid_text(prepared['controller']['ownerID'])
            or pair.uuid_text(history['peerReceipt']['run']) != pair.uuid_text(prepared['controller']['target']['runID'])
            or history['manifestDigest'] != prepared['buddy']['target']['digest']
            or not history['newPeerEvents']
            or any(pair.uuid_text(event['origin']) != pair.uuid_text(prepared['controller']['ownerID'])
                   or type(event['sequence']) is not int or event['sequence'] <= 0
                   for event in history['newPeerEvents'])):
        raise ValueError('Buddy did not apply real later peer history after its exact native baseline')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in PATHS + ('output',):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in IDS:
        parser.add_argument('--' + name, type=uuid.UUID, required=True)
    parser.add_argument('--timeout-seconds', type=int, default=1200, help='Bound for each pair stage, 30–1200 seconds')
    parser.add_argument('--kind', choices=('customCommitLoss', 'partialRestore'), default='customCommitLoss')
    parser.add_argument('--audit-only', action='store_true')
    args = parser.parse_args()
    args.scenario = args.kind + 'Prepare'; args.unrelated_ordinary_run_id = None
    if not 30 <= args.timeout_seconds <= 1200:
        parser.error('Stage timeout must be 30–1200 seconds')
    try:
        pair.validate(args)
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        parser.error('Input validation failed; use exact task paths, private synthetic accounts, and reviewed fixtures')
    receipt = dict(version=1, kind=args.kind, recoveryAttemptID=str(args.recovery_attempt_id), sessionID=str(args.debug_session_id),
                   status='audited' if args.audit_only else 'running', finalCertification=False,
                   simulators=pair.SIMULATORS, stages={}, roles={})
    if args.audit_only:
        print(json.dumps(receipt, sort_keys=True)); return 0
    args.output.mkdir(parents=True, mode=0o700, exist_ok=False)
    pair.atomic_receipt(args.output / 'restart-result.json', receipt)
    environment = os.environ.copy(); environment['BOUND_GAME_SOURCE'] = str(args.game_source)
    children = {}
    try:
        for stage in ('prepare', 'recover'):
            command = stage_command(args, stage)
            with (args.output / (stage + '-pair.log')).open('xb') as log:
                child = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                children[stage] = child
                code = child.wait(timeout=args.timeout_seconds + 20)
            result = pair.small_json(args.output / stage / 'pair-result.json', 65536)
            receipt['stages'][stage] = dict(exitCode=code, status=result.get('status'))
            if code != 0 or result.get('status') != 'passed':
                raise ValueError('Native stage failed; retain all evidence and owner recovery state')
            # The next xcodebuild invocation launches a fresh test host. The
            # harness and final verifier both reject a reused application PID.
        receipt['roles'] = verify_recovery(args)
        receipt['status'] = 'passed'
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, KeyboardInterrupt):
        receipt['status'] = 'failed'
    finally:
        pair.stop_children(children)
        pair.atomic_receipt(args.output / 'restart-result.json', receipt)
    print(json.dumps(receipt, sort_keys=True))
    return 0 if receipt['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
