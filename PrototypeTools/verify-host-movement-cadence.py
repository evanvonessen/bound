#!/usr/bin/env python3
"""Run the exact full-coordinator XCTest on explicitly owned, booted simulators.

Launch with the selected app's PrototypeTools/qa-python and BOUND_GAME_SOURCE.
This tool never builds, retries, creates simulators, or uses a backend.
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid

sys.dont_write_bytecode = True
APP = Path(__file__).resolve().parents[1]
ARTIFACTS = APP.parent / 'artifacts/multiplayer-isolation'
BUNDLE = 'com.evanvonessen.bound'
TEST = 'RecordedPlayerTests/testFullCoordinatorLocalHostFrameCadence'
AUTHORITY_STARTUP_FRAMES = 60


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def load_tool(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def container(simulator, env):
    result = subprocess.run(['/usr/bin/xcrun', 'simctl', 'get_app_container', simulator, BUNDLE, 'data'],
                            env=env, capture_output=True, text=True)
    return Path(result.stdout.strip()) if result.returncode == 0 else None


def configure_run(original, products, values, allowance):
    targets = []

    def visit(value):
        if isinstance(value, str):
            return value.replace('__TESTROOT__', str(products))
        if isinstance(value, list):
            return [visit(child) for child in value]
        if isinstance(value, dict):
            result = {key: visit(child) for key, child in value.items()}
            if result.get('BlueprintName') == 'BoundIntegrationTests':
                for key in ('EnvironmentVariables', 'UITargetAppEnvironmentVariables'):
                    # Explicit fixture switches supersede retained test settings.
                    retained = result.setdefault(key, {})
                    for name in list(retained):
                        if name.startswith(('BOUND_', 'TEST_RUNNER_BOUND_')):
                            del retained[name]
                    retained.update(values)
                result['OnlyTestIdentifiers'] = [TEST]
                result['SkipTestIdentifiers'] = []
                result['DefaultTestExecutionTimeAllowance'] = allowance
                result['MaximumTestExecutionTimeAllowance'] = allowance
                targets.append(result)
            return result
        return value

    result = visit(original)
    if len(targets) != 1 or targets[0].get('TestHostBundleIdentifier') != BUNDLE:
        raise ValueError('Requires exactly one BoundIntegrationTests target hosted by the explicit Bound bundle')
    return result, targets[0]



def verify_fixture_producer(summary, relay_status, peer, namespace, mode):
    producers = relay_status.get('presenceProducers', {}).get(peer, {})
    if mode == 'off':
        if producers:
            raise ValueError('Off mode unexpectedly published fixture presence')
        return dict(producers={}, scope='Experimental feature off; no fixture presence producer')
    instances = [item for item in summary.get('fixtureInstances', []) if item.get('running') is True]
    if (len(instances) != 1 or instances[0].get('peer') != peer
            or instances[0].get('namespace') != namespace):
        raise ValueError('Requires exactly one running fixture owner matching this peer and namespace')
    owner = instances[0].get('id')
    if set(producers) != {owner} or not isinstance(producers.get(owner), int) or producers[owner] <= 0:
        raise ValueError('Relay presence producer must be exactly the single recorded fixture owner')
    return dict(instanceID=owner, producers=producers)


def binary_manifest(target):
    host = Path(target['TestHostPath'])
    app = host if host.suffix == '.app' else host.parent
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = app / info['CFBundleExecutable']
    test_bundle = Path(target['TestBundlePath'].replace('__TESTHOST__', str(app)))
    test = test_bundle / 'BoundIntegrationTests'
    if not executable.is_file() or not test.is_file():
        raise ValueError('Selected previously built app or integration-test executable is missing')
    paths = [executable, test, app / 'Bound.debug.dylib']
    paths += [path for path in (app / 'Frameworks').glob('*.framework/*') if path.is_file() and not path.suffix]
    return {str(path): digest(path) for path in paths if path.is_file()}


def export_xctest(peer_dir, env):
    values = {}
    bundle = peer_dir / 'host.xcresult'
    if not bundle.exists():
        raise RuntimeError('Missing XCTest result bundle')
    for kind in ('summary', 'tests'):
        result = subprocess.run(['/usr/bin/xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(bundle)],
                                env=env, capture_output=True, text=True)
        (peer_dir / ('xcresult-' + kind + '.stderr.log')).write_text(result.stderr)
        if result.returncode:
            raise RuntimeError('Could not export XCTest ' + kind)
        values[kind] = json.loads(result.stdout)
        write_json(peer_dir / ('xctest-' + kind + '.json'), values[kind])
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

    visit(values['tests'])
    summary = values['summary']
    if (summary.get('totalTestCount') != 1 or summary.get('passedTests') != 1
            or any(summary.get(key, 0) for key in ('failedTests', 'skippedTests', 'expectedFailures'))
            or len(cases) != 1 or cases[0].get('result') != 'Passed'
            or cases[0].get('nodeIdentifier') not in (TEST, TEST + '()')):
        raise RuntimeError('Expected exactly one passed host-trace test, with no skips, failures or retries')
    return values


def verify_scene_diagnostics(summary, evidence, enabled, rom_sha, frames):
    if not enabled:
        if summary.get('sceneDiagnostics') is True:
            raise ValueError('Unexpected scene instrumentation in a performance run')
        return dict(enabled=False)
    if summary.get('sceneDiagnostics') is not True:
        raise ValueError('Requested scene diagnostic capture is missing')
    root = evidence / 'scene-diagnostics'
    manifest_path = root / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    counts = [manifest.get(key) for key in ('observedFailures', 'capturedCount', 'droppedFailures')]
    if (manifest.get('schema') != 1 or manifest.get('sourceROM_SHA256') != rom_sha
            or any(type(value) is not int or value < 0 for value in counts)):
        raise ValueError('Scene diagnostic identity/counts are invalid')
    observed, captured, dropped = counts
    if observed > frames - AUTHORITY_STARTUP_FRAMES or captured != min(observed, 4) or dropped != observed - captured:
        raise ValueError('Scene diagnostic capture exceeded its measured-window/count bounds')
    sizes = dict(workRAM=0x40000, internalRAM=0x8000, paletteRAM=0x400)
    expected = {f'failure-{index}/{name}.bin' for index in range(captured) for name in sizes}
    expected |= {f'failure-{index}/decision.json' for index in range(captured)}
    files = manifest.get('files', {})
    if set(files) != expected:
        raise ValueError('Scene diagnostic file set is incomplete or unexpected')
    decisions = {}
    for name, item in files.items():
        path = root / name
        size = path.stat().st_size
        if not size or size != item.get('bytes') or digest(path) != item.get('sha256'):
            raise ValueError('Scene diagnostic file failed size/hash verification: ' + name)
        if path.suffix == '.bin' and size != sizes[path.stem]:
            raise ValueError('Scene diagnostic memory bank has the wrong size: ' + name)
        if path.suffix == '.json':
            decision = json.loads(path.read_text())
            if (not isinstance(decision, dict) or decision.get('schema') != 1
                    or decision.get('sourceROM_SHA256') != rom_sha or decision.get('status') != 'live'
                    or type(decision.get('videoFrame')) is not int
                    or not AUTHORITY_STARTUP_FRAMES < decision['videoFrame'] <= frames):
                raise ValueError('Scene diagnostic decision has invalid identity/frame/status')
            decisions[name] = decision['videoFrame']
    capture_frames = [decisions[f'failure-{index}/decision.json'] for index in range(captured)]
    if capture_frames != sorted(set(capture_frames)):
        raise ValueError('Scene diagnostic captures must be distinct and ordered')
    return dict(enabled=True, diagnosticOnly=True, candidateAcceptance=False,
                observedFailures=observed, capturedCount=captured, droppedFailures=dropped,
                captureFrames=capture_frames,
                manifest=str(manifest_path), manifestSHA256=digest(manifest_path))


def frame_ranges(frames):
    result = []
    for frame in sorted(set(frames)):
        if result and frame == result[-1][1] + 1:
            result[-1][1] = frame
        else:
            result.append([frame, frame])
    return result


def sustained_authority(window, expected_ids, mode, port_diagnostics=False):
    """Reject any observed withdrawal after a fixed, recorded startup window.

    Raw flags are only evidence of a completed publication when the native
    writer sequence is even. The admitted probe and host-input checks still
    apply on every measured frame, including frames with an odd raw sequence.
    """
    post_ids = expected_ids[AUTHORITY_STARTUP_FRAMES:]
    post_set = set(post_ids)
    post = [event for event in window if event['frame'] in post_set]
    findings = {}
    counts = Counter(event['stage'] for event in post)

    def fail(name, ids):
        ids = sorted(set(ids))
        if ids:
            findings[name] = dict(count=len(ids), frameRanges=frame_ranges(ids))

    def exactly_one(name, rows):
        by_frame = Counter(event['frame'] for event in rows)
        fail(name, [frame for frame in post_ids if by_frame[frame] != 1])

    if mode != 'off':
        reader = [event for event in post if event['stage'].startswith('reader.result.')]
        exactly_one('missingOrDuplicateReader', reader)
        fail('readerUnavailableOrSceneMissing', [event['frame'] for event in reader
             if event['stage'] != 'reader.result.live' or event['value'] != 1])
    committed = []
    if mode == 'peer':
        admitted = [event for event in post if event['stage'] == 'probe.cachedGuest']
        host = [event for event in post if event['stage'] == 'probe.hostInput']
        raw = [event for event in post if event['stage'] == 'native.rawWorldFlags']
        exactly_one('missingOrDuplicateAdmittedState', admitted)
        exactly_one('missingOrDuplicateHostInput', host)
        exactly_one('missingOrDuplicateRawFlags', raw)
        fail('admittedAuthorityWithdrawnOrBlocked', [event['frame'] for event in admitted
             if int(event['detail']) & 7 != 7 or int(event['detail']) & (32 | 64)])
        committed = [event for event in raw if int(event['detail']) & 1 == 0]
        if not committed:
            fail('noCompletedNativePublication', post_ids)
        fail('completedNativeAuthorityWithdrawnOrBlocked', [event['frame'] for event in committed
             if int(event['value']) & 7 != 7 or int(event['value']) & (32 | 64)])
        # These optional diagnostics are recorded by the bounded discovery
        # mode. The per-frame checks above also run in long, uninstrumented
        # host replays; enabling diagnostics cannot relax those checks.
        main_reader = [event for event in post if event['stage'].startswith('main.reader.')]
        fail('mainReaderStaleOrUnavailable', [event['frame'] for event in main_reader
             if event['stage'] != 'main.reader.live' or event['value'] != 1])
        fail('mainMovementContextWithdrawn', [event['frame'] for event in post
             if event['stage'] == 'main.movement' and (event['value'] != 0 or event['detail'] != 1)])
        presence_stages = tuple('transport.presence.' + stage for stage in
                                ('send', 'sendCollision', 'arrived', 'arrivedCollision', 'delivered', 'deliveredCollision'))
        fail('nilPresenceOrCollision', [event['frame'] for event in post
             if event['stage'] in presence_stages and event['value'] != 1])
        if port_diagnostics:
            missing = [stage for stage in ('main.movement', *presence_stages) if counts[stage] == 0]
            if not main_reader:
                missing.append('main.reader.*')
            if missing:
                findings['missingRequestedContextDiagnostics'] = dict(stages=missing)
    return dict(passed=not findings, startupFrames=AUTHORITY_STARTUP_FRAMES,
                startupFrameRanges=frame_ranges(expected_ids[:AUTHORITY_STARTUP_FRAMES]),
                checkedFrameRanges=frame_ranges(post_ids), checkedFrames=len(post_ids),
                committedNativeFlagSamples=len(committed), stageCounts=dict(counts), failures=findings,
                scope='After the first60 measured native frames, require every enabled reader to be live with a scene; peer mode additionally requires uninterrupted admitted authority and host input, and rejects inactive even-sequence native publications. Odd raw writer sequences are diagnostic only. Optional context/presence diagnostics must remain non-nil. This supplements, not replaces, the XCTest whole-window coverage gate.')


def render_delivery(events, expected_ids, rate):
    """Account for each requested graphics frame through the real renderer.

    Completion is asynchronous, so retain later events bearing a measured
    frame ID. The fixture drains callbacks after pausing before exporting.
    Metal completion proves command execution, never drawable presentation.
    """
    post_ids = expected_ids[AUTHORITY_STARTUP_FRAMES:]
    post_set = set(post_ids)
    post = [event for event in events if event['frame'] in post_set]
    failures = {}

    def fail(name, ids):
        ids = sorted(set(ids))
        if ids:
            failures[name] = dict(count=len(ids), frameRanges=frame_ranges(ids))

    begins = [event for event in post if event['stage'] == 'frame.begin']
    counts = Counter(event['frame'] for event in begins)
    fail('missingOrDuplicateFrameBegin', [frame for frame in post_ids if counts[frame] != 1])
    graphics = {event['frame'] for event in begins if event['value'] == 1}
    fail('invalidGraphicsSelection', [event['frame'] for event in begins if event['value'] not in (0, 1)])
    if not graphics:
        fail('noGraphicsFrames', post_ids)
    if rate == 1:
        fail('normalSpeedGraphicsSkipped', [event['frame'] for event in begins if event['value'] != 1])
    elif rate == 3 and graphics:
        # The pinned VBA bridge reports exactly1/60s. runGameLoop resets
        # its counter at each draw, selecting every third native frame at3x.
        # Accept any initial phase, never arbitrary sparsity or phase shifts.
        phase = min(graphics) % 3
        expected_graphics = {frame for frame in post_ids if frame % 3 == phase}
        fail('fastForwardGraphicsCadence', graphics ^ expected_graphics)
    # The pinned VBA bridge processes every native video frame, including
    # fast-forward frames for which the host deliberately skips rendering.
    processed = Counter(event['frame'] for event in post if event['stage'] == 'video.process')
    fail('missingOrDuplicate.video.process', [frame for frame in post_ids if processed[frame] != 1])
    for stage in ('render.request', 'render.accept', 'render.handoff'):
        observed = Counter(event['frame'] for event in post if event['stage'] == stage)
        fail('missingOrDuplicate.' + stage,
             [frame for frame in graphics | set(observed) if observed[frame] != (1 if frame in graphics else 0)])
    for stage in ('render.busyDrop', 'view.layoutDrop', 'view.metal.unavailable'):
        fail(stage, [event['frame'] for event in post if event['stage'] == stage])
    inputs = {(event['frame'], event['detail']) for event in post if event['stage'] == 'view.input'}
    fail('missingViewInput', graphics - {frame for frame, _ in inputs})
    metal = {(event['frame'], event['detail']) for event in post if event['stage'] == 'view.metal.commit'}
    gl = {(event['frame'], event['detail']) for event in post if event['stage'] == 'view.gl.draw'}
    fail('missingViewDraw', [frame for frame, view in inputs if (frame, view) not in metal | gl])
    completed = {(event['frame'], event['detail']) for event in post
                 if event['stage'] == 'view.metal.presentCommandCompleted' and event['value'] == 4}
    fail('missingMetalCommandCompletion', [frame for frame, view in metal if (frame, view) not in completed])
    fail('metalCommandFailed', [event['frame'] for event in post
         if event['stage'] == 'view.metal.presentCommandCompleted' and event['value'] != 4])
    return dict(passed=not failures, failures=failures, checkedFrames=len(post_ids),
                graphicsFrames=len(graphics), viewInputs=len(inputs), metalCommands=len(metal),
                completedMetalCommands=len(completed), glDraws=len(gl),
                scope='Measured native frame IDs after the fixed60-frame startup, including their asynchronous drain after measurement. The pinned VBA bridge must process every native video frame. Rendering requires every frame at1x and every third frame at3x; every graphics frame must be accepted and reach a view draw, with no busy/layout/drawable drop. Metal feedback is presentation-command-buffer completion, neither Core Image completion nor drawable presentation/scanout; GL is draw handoff.')


def wall_clock_cadence(events, expected_ids, rate):
    """Retain timing distributions alongside frame-completeness acceptance.

    Per-view streams stay separate. Host scheduling and command completion are
    observed here; neither measures the physical screen's presentation time.
    """
    post_ids = set(expected_ids[AUTHORITY_STARTUP_FRAMES:])
    stages = ('frame.begin', 'video.process', 'render.handoff', 'view.gl.draw',
              'view.metal.commit', 'view.metal.presentCommandCompleted')
    streams = {}
    for event in events:
        if event['frame'] not in post_ids or event['stage'] not in stages:
            continue
        key = event['stage']
        if key.startswith('view.'):
            key += '.' + str(event['detail'])
        streams.setdefault(key, []).append(event)
    results = {}
    for name, rows in streams.items():
        rows.sort(key=lambda event: (event['frame'], event['time']))
        gaps = [(b['time'] - a['time']) * 1000 for a, b in zip(rows, rows[1:])]
        ordered = sorted(gaps)
        quantum = 1000 / (60 * rate) if name in ('frame.begin', 'video.process') else 1000 / 60
        results[name] = dict(samples=len(rows), intervals=len(gaps),
                            nominalIntervalMS=quantum,
                            quantilesMS={str(q): ordered[int(q * (len(ordered) - 1))]
                                         if ordered else None for q in (.5, .95, .99, 1)},
                            intervalsOverTwoQuanta=sum(gap > 2 * quantum for gap in gaps),
                            nonpositiveIntervals=sum(gap <= 0 for gap in gaps))
    return dict(streams=results,
                scope='Observed wall-clock gaps after the fixed60-frame startup, with each view separate and measured-frame asynchronous completion retained. Compare repeated off/no-peer/peer runs under the same host load. Diagnostic distributions supplement strict delivery/authority and guest-pixel gates; they do not establish physical display cadence.')


def sustained_soul_policy(window, expected_ids, enabled):
    """Observe actual installed entries and committed policy after each owner."""
    post_ids = expected_ids[AUTHORITY_STARTUP_FRAMES:]
    post_set = set(post_ids)
    rows = [event for event in window if event['stage'] == 'qa.soulPolicy' and event['frame'] in post_set]
    counts = Counter(event['frame'] for event in rows)
    failures = {}
    missing = [frame for frame in post_ids if counts[frame] != 1]
    if missing:
        failures['missingOrDuplicateStatus'] = frame_ranges(missing)
    invalid = []
    for event in rows:
        flags, sequence = event['value'], event['detail']
        if (not isinstance(flags, (int, float)) or not math.isfinite(flags) or flags != int(flags)
                or not 0 <= flags <= 15 or not isinstance(sequence, int) or not 0 <= sequence <= 0xFFFFFFFF):
            invalid.append(event['frame'])
        elif (enabled and (flags != 13 or sequence == 0 or sequence & 1)
              or not enabled and (int(flags) & 13 or sequence != 0)):
            invalid.append(event['frame'])
    if invalid:
        failures['unexpectedInstalledPolicy'] = frame_ranges(invalid)
    return dict(passed=not failures, requested=enabled, checkedFrames=len(post_ids),
                startupFrames=AUTHORITY_STARTUP_FRAMES, failures=failures,
                scope='Frame-owner observation after the complete production callback: exact owned entry hooks, policy magic/count and committed active elimination header. An inert resident body is allowed only with all hooks/policy disabled. This offline task ledger exercises native policy cost; no linked partner, backend admission or battle-history claim.')


def sustained_soul_fence(window, expected_ids):
    """The field-only tape must not suspend the native frame for observation."""
    post_ids = expected_ids[AUTHORITY_STARTUP_FRAMES:]
    post_set = set(post_ids)
    failures = {}
    for phase in ('beforeOwner', 'afterOwner'):
        rows = [event for event in window if event['stage'] == 'qa.soulFence.' + phase
                and event['frame'] in post_set]
        counts = Counter(event['frame'] for event in rows)
        invalid = [frame for frame in post_ids if counts[frame] != 1]
        invalid += [event['frame'] for event in rows if event['value'] != 0]
        if invalid:
            failures[phase] = frame_ranges(sorted(set(invalid)))
    return dict(passed=not failures, checkedFrames=len(post_ids), failures=failures,
                scope='Actual native frame-fence bit before and after the production owner. This ordinary field tape has no faint, acquisition or other policy transition that requires a critical fence.')


def verify_death_notice_setup(summary, setup, ledger, evidence):
    if not summary.get('faintedPartyRequested') or summary.get('mode') == 'off':
        return None
    proof = setup.get('deathNoticeSetup', {})
    if (any(proof.get(key) is not True for key in
            ('sawActive', 'sawNativeAcknowledgment', 'announced', 'deathAndRecordsRetained'))
            or type(proof.get('nativeAPresses')) is not int or not 1 <= proof['nativeAPresses'] <= 200):
        raise ValueError('Fainted fixture did not acknowledge its actual native loss notice before measurement')
    identifier = str(uuid.UUID(proof['id'])).upper()
    notices = [notice for notice in ledger.get('battleLosses', {}).get('notices', [])
               if notice.get('id', '').upper() == identifier]
    if (len(notices) != 1 or notices[0].get('announced') is not True
            or not notices[0].get('slots') or not set(notices[0]['slots']) <= set(ledger.get('dead', []))
            or json.loads((evidence / 'death-notice-setup.json').read_text()) != proof):
        raise ValueError('Acknowledged setup notice or its durable death facts were not retained')
    return proof


def verify_soul_fixture(summary, evidence, enabled, namespace, peer, rom_sha):
    setup = summary.get('soulPolicySetup', {})
    if (summary.get('soulPolicyRequested') is not enabled or setup.get('requested') is not enabled
            or setup.get('historyScope') != 'offlineNone'):
        raise ValueError('Soul policy request/history scope differs from executed fixture')
    if not enabled:
        if setup.get('flags') not in (0, 2) or setup.get('sequence') != 0:
            raise ValueError('Disabled Soul variant began with an active hook/policy')
        return dict(requested=False, historyScope='offlineNone')
    binding = hashlib.sha256(f'host-soul:{namespace}:{peer}:{rom_sha}'.encode()).hexdigest()
    if (setup.get('run') != namespace or setup.get('binding') != binding or setup.get('ready') is not True
            or setup.get('error') is not None or setup.get('monCount', 0) < 1 or setup.get('flags') != 13
            or not isinstance(setup.get('sequence'), int) or setup['sequence'] <= 0 or setup['sequence'] & 1
            or setup.get('ledgerFile') != 'host-soul-ready.json' or setup.get('originalLedgerFile') != 'host-soul.json'):
        raise ValueError('Soul fixture lacks a ready task-owned installed policy')
    uuid.UUID(setup['gameID'])
    ledger_path = evidence / setup['ledgerFile']
    if not ledger_path.is_file() or not 0 < ledger_path.stat().st_size <= 2_097_152 or digest(ledger_path) != setup.get('ledgerSHA256'):
        raise ValueError('The durable ready ledger snapshot is missing or changed')
    ledger = json.loads(ledger_path.read_text())
    if ledger.get('run') != namespace or ledger.get('binding') != binding or ledger.get('ended') is not False:
        raise ValueError('Ready ledger identity/state differs from the task policy')
    if json.loads((evidence / 'soul-setup.json').read_text()) != setup:
        raise ValueError('Soul setup receipt differs from the summary')
    death_notice = verify_death_notice_setup(summary, setup, ledger, evidence)
    teardown = json.loads((evidence / 'soul-teardown.json').read_text())
    if teardown.get('taskPolicyClosed') is not True or teardown.get('flags') not in (0, 2) or teardown.get('sequence') != 0:
        raise ValueError('The task policy was not closed at teardown')
    return dict(requested=True, historyScope='offlineNone', readyLedgerSHA256=digest(ledger_path),
                acknowledgedSetupNotice=death_notice, teardown=teardown)


def trace_window(path, frames, peer, mode, port_diagnostics=False, rate=1, follower=None, soul_policy=None, fainted_party=False, axis='horizontal'):
    if axis not in ('horizontal', 'vertical'):
        raise RuntimeError('Unknown native movement axis')
    events = json.loads(path.read_text())
    ends = [event for event in events if event.get('stage') == 'qa.measureEnd']
    if len(ends) != 1:
        raise RuntimeError('Trace requires exactly one completed measurement marker')
    end = ends[0]
    # Native owners define the measurement window. Async rendering can append
    # later events; retain them in events.json but never count them as activity
    # occurring before the measurement stopped.
    window = [event for event in events if 0 < event['frame'] <= end['frame'] and event['time'] <= end['time']]
    inputs = [event for event in window if event['stage'] == 'qa.input']
    expected_ids = list(range(end['frame'] - frames + 1, end['frame'] + 1))
    if len(inputs) != frames or [event['frame'] for event in inputs] != expected_ids:
        raise RuntimeError('Host controller did not observe each requested native frame exactly once')
    stationary = mode == 'peer' and peer == 'B'
    expected_x = (36,36) if axis == 'vertical' or stationary else (33,36)
    expected_y = (24,24) if stationary else ((20,22) if axis == 'vertical' else (20,20))
    for stage in ('native.tileX', 'native.tileY', 'native.map', 'native.rawWorldFrame'):
        rows = [event for event in window if event['stage'] == stage]
        if [event['frame'] for event in rows] != expected_ids:
            raise RuntimeError('Missing or duplicated native controller observations: ' + stage)
        if stage in ('native.tileX','native.tileY'):
            lower, upper = expected_x if stage == 'native.tileX' else expected_y
            if not all(lower <= event['value'] <= upper and event['value'] == int(event['value']) for event in rows):
                raise RuntimeError('Native host controller left its verified '+axis+' lane: '+stage)
        if stage == 'native.map' and not all(event['value'] == 3 and event['detail'] == 1 for event in rows):
            raise RuntimeError('Native host controller left the verified Viridian map')
    counts = Counter(event['stage'] for event in window)
    required = ('owner.romService', 'owner.movement', 'owner.world', 'owner.reader', 'owner.cooperative',
                'owner.soul', 'owner.battle', 'render.request', 'render.accept', 'view.input')
    if any(counts[stage] == 0 for stage in required) or counts['view.metal.commit'] + counts['view.gl.draw'] == 0:
        raise RuntimeError('The production owner/render chain did not execute inside the measured window')
    if counts['native.tileMissing']:
        raise RuntimeError('Native controller state was unavailable during measurement')
    if follower is not None:
        post_ids = set(expected_ids[AUTHORITY_STARTUP_FRAMES:])
        rows = [event for event in window if event['stage'] == 'native.followerActive'
                and event['frame'] in post_ids]
        if ([event['frame'] for event in rows] != expected_ids[AUTHORITY_STARTUP_FRAMES:]
                or any(event['value'] != int(follower) for event in rows)):
            raise RuntimeError('Observed native follower state differed from the requested host variant')
    if fainted_party:
        post_ids = expected_ids[AUTHORITY_STARTUP_FRAMES:]
        post_set = set(post_ids)
        rows = [event for event in window if event['stage'] == 'qa.faintedParty' and event['frame'] in post_set]
        if ([event['frame'] for event in rows] != post_ids
                or any(event['value'] != 2 or type(event['detail']) is not int
                       or not 0 < event['detail'] <= 0xFFFF for event in rows)):
            raise RuntimeError('The native fainted-first/living-second party was not retained throughout measurement')
    return dict(firstFrame=expected_ids[0], lastFrame=end['frame'], endTime=end['time'],
                measuredInputFrames=len(inputs), stageCounts=dict(counts),
                excludedPostMeasurementEvents=len(events)-len(window), axis=axis,
                expectedNativeX=list(expected_x), expectedNativeY=list(expected_y),
                sustainedAuthority=sustained_authority(window, expected_ids, mode, port_diagnostics),
                renderDelivery=render_delivery(events, expected_ids, rate),
                wallClockCadence=wall_clock_cadence(events, expected_ids, rate),
                soulPolicy=sustained_soul_policy(window, expected_ids, soul_policy) if soul_policy is not None else None,
                soulFrameFence=sustained_soul_fence(window, expected_ids) if soul_policy is not None else None,
                scope='Events with native frame IDs through qa.measureEnd and timestamps no later than that marker; retained raw events also include asynchronous completion after measurement')


def terminate_owned(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait(timeout=5)
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('xctestrun', 'rom', 'output', 'source-receipt'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--simulator-a', required=True)
    parser.add_argument('--simulator-b')
    parser.add_argument('--mode', choices=('off', 'no-peer', 'peer'), required=True)
    parser.add_argument('--axis', choices=('horizontal', 'vertical'), default='horizontal')
    parser.add_argument('--rate', type=int, choices=(1, 3), default=1)
    parser.add_argument('--frames', type=int, default=1800)
    parser.add_argument('--walk', action='store_true')
    parser.add_argument('--fainted-party', action='store_true',
                        help='Exercise the existing disposable two-member fixture with slot zero fainted and slot one living; verify every post-startup frame')
    parser.add_argument('--follower', choices=('0', '1'), default='0',
                        help='Select native follower state; both variants require per-frame observation in the follower-aware fixture')
    parser.add_argument('--soul-policy', choices=('0', '1'), default='0',
                        help='Use the production Soul probe and a task-owned offline ledger; require installed policy status on every post-startup frame')
    parser.add_argument('--port-diagnostics', action='store_true', help='Trace native host-port admission at three boundaries; limited to 600 frames')
    parser.add_argument('--scene-diagnostics', action='store_true',
                        help='Capture bounded nil-scene decoder evidence; diagnostic only, excluded from movement performance acceptance')
    args = parser.parse_args()
    if 'BOUND_GAME_SOURCE' not in os.environ:
        parser.error('Set BOUND_GAME_SOURCE to the explicit selected game checkout')
    game = Path(os.environ['BOUND_GAME_SOURCE']).resolve(strict=True)
    sys.path.insert(0, str(game / 'tools'))
    from qa_python import ensure_qa_python
    ensure_qa_python()
    if not 120 <= args.frames <= 21600:
        parser.error('Frames must be 120–21600')
    if args.port_diagnostics and args.frames > 600:
        parser.error('Port diagnostics require --frames <= 600')
    if (args.mode == 'peer') != bool(args.simulator_b):
        parser.error('Peer mode requires --simulator-b; off/no-peer modes run only simulator A')
    devices = {'A': str(uuid.UUID(args.simulator_a)).upper()}
    if args.simulator_b:
        devices['B'] = str(uuid.UUID(args.simulator_b)).upper()
        if devices['A'] == devices['B']:
            parser.error('Peer mode requires two distinct dedicated simulators')
    args.xctestrun = args.xctestrun.resolve(strict=True)
    args.rom = args.rom.resolve(strict=True)
    args.source_receipt = args.source_receipt.resolve(strict=True)
    args.output = args.output.resolve()
    if args.output.exists() or not args.output.is_relative_to(ARTIFACTS.resolve()):
        parser.error('Use a fresh explicit output directory under artifacts/multiplayer-isolation')
    if not re.fullmatch(r'[0-9a-f]{64}', args.sha256) or digest(args.rom) != args.sha256 or args.rom.stat().st_size != 33554432:
        parser.error('The explicit SHA256 must match the selected 32MiB cartridge')
    env = {key: value for key, value in os.environ.items() if not key.startswith(('BOUND_', 'TEST_RUNNER_BOUND_'))}
    env.setdefault('DEVELOPER_DIR', '/Applications/Developer/Xcode.app/Contents/Developer')
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    inventory = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'list', 'devices', 'available', '--json'], env=env))
    known = {item['udid'].upper(): item for values in inventory['devices'].values() for item in values}
    for peer, simulator in devices.items():
        item = known.get(simulator, {})
        if item.get('state') != 'Booted' or not item.get('name', '').startswith('Bound Movement'):
            parser.error(peer + ' must select an already booted task simulator named Bound Movement…')
    relay_path = APP / 'PrototypeTools/paired-simulator-relay.py'
    provenance_path = APP / 'PrototypeTools/verify-movement-cadence.py'
    relay = load_tool(relay_path, 'host_trace_relay')
    provenance = load_tool(provenance_path, 'host_trace_provenance')
    receipt = json.loads(args.source_receipt.read_text())
    frozen_source = provenance.verify_frozen_source(receipt)
    if not receipt.get('configuration') or not re.fullmatch(r'[0-9a-f]{40}', receipt.get('head', '')):
        parser.error('The preserved source receipt must identify build configuration and app base revision')
    if not re.fullmatch(r'[0-9a-f]{64}', receipt.get('files', {}).get('PrototypeIntegrationTests/RecordedPlayerTests.swift', '')):
        parser.error('The source receipt must include the actual host replay test')
    original = plistlib.loads(args.xctestrun.read_bytes())
    allowance = max(360, math.ceil(args.frames / (60 * args.rate)) + 300)
    _, target = configure_run(original, args.xctestrun.parent, {}, allowance)
    binaries = binary_manifest(target)
    namespace = str(uuid.uuid4()).upper()
    args.output.mkdir(parents=True, mode=0o700)
    shutil.copyfile(args.source_receipt, args.output / 'build-source-receipt.json')
    for source, name in ((Path(__file__).resolve(), 'launcher-source.py'), (relay_path, 'relay-source.py'),
                         (provenance_path, 'provenance-tool-source.py')):
        shutil.copyfile(source, args.output / name)
    write_json(args.output / 'binary-hashes.json', binaries)
    report = dict(status='preparing', namespace=namespace, mode=args.mode, axis=args.axis, rate=args.rate, frames=args.frames,
                  walk=args.walk, faintedPartyRequested=args.fainted_party, nativeFollowerRequested=args.follower == '1', soulPolicyRequested=args.soul_policy == '1', portDiagnostics=args.port_diagnostics,
                  sceneDiagnostics=args.scene_diagnostics, diagnosticOnly=args.port_diagnostics or args.scene_diagnostics,
                  rom=str(args.rom), romSHA256=args.sha256, xctestrun=str(args.xctestrun),
                  xctestrunSHA256=digest(args.xctestrun), appToolsSource=str(APP), gameSource=str(game),
                  sourceReceipt=dict(path=str(args.source_receipt), sha256=digest(args.source_receipt)),
                  verifiedFrozenSource=frozen_source, binaries=binaries,
                  launcherSHA256=digest(Path(__file__).resolve()), relaySourceSHA256=digest(relay_path),
                  authorityStartupFrames=AUTHORITY_STARTUP_FRAMES,
                  provenanceToolSHA256=digest(provenance_path), peers={}, failures=[],
                  limits='Full app/coordinator and simulator rendering with UUID-scoped localhost presence; no backend account, server-save, WAN or physical display acceptance')
    state = relay.RelayState(presence_namespace=namespace, interaction_peers=tuple(devices))
    server = thread = None
    processes, logs, previous = {}, {}, {}
    started = time.monotonic()
    try:
        server = relay.RelayServer(state, port=0)  # Explicit ephemeral loopback binding.
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        report['relay'] = dict(host='127.0.0.1', requestedPort=0, assignedPort=server.server_port)
        for peer, simulator in devices.items():
            peer_dir = args.output / peer
            peer_dir.mkdir()
            before = container(simulator, env)
            previous[peer] = {p.name for p in (before / 'Documents').glob('MovementHost-*')} if before else set()
            values = dict(BOUND_HOST_TRACE='1', BOUND_PAIR_PRESENCE_ONLY='1', BOUND_PAIR_NAMESPACE=namespace,
                          BOUND_PAIR_PEER=peer, BOUND_PAIR_PORT=str(server.server_port), BOUND_MOVEMENT_ROM=str(args.rom),
                          BOUND_MOVEMENT_SHA256=args.sha256, BOUND_HOST_MODE=args.mode, BOUND_HOST_AXIS=args.axis, BOUND_HOST_RATE=str(args.rate),
                          BOUND_HOST_FRAMES=str(args.frames), BOUND_HOST_WALK='1' if args.walk else '0',
                          BOUND_HOST_FOLLOWER=args.follower,
                          BOUND_HOST_FAINTED_PARTY='1' if args.fainted_party else '0',
                          BOUND_HOST_SOUL_POLICY=args.soul_policy,
                          BOUND_HOST_PORT_DIAGNOSTICS='1' if args.port_diagnostics else '0',
                          BOUND_HOST_SCENE_DIAGNOSTICS='1' if args.scene_diagnostics else '0')
            configuration, _ = configure_run(original, args.xctestrun.parent, values, allowance)
            run = peer_dir / 'host.xctestrun'
            run.write_bytes(plistlib.dumps(configuration))
            command = ['xcodebuild', 'test-without-building', '-xctestrun', str(run),
                       '-destination', 'platform=iOS Simulator,id=' + simulator, '-parallel-testing-enabled', 'NO',
                       '-collect-test-diagnostics', 'never', '-test-timeouts-enabled', 'YES',
                       '-default-test-execution-time-allowance', str(allowance),
                       '-maximum-test-execution-time-allowance', str(allowance),
                       '-only-testing:BoundIntegrationTests/' + TEST, '-resultBundlePath', str(peer_dir / 'host.xcresult')]
            report['peers'][peer] = dict(simulator=simulator, simulatorName=known[simulator]['name'], command=command,
                                         environment=values, status='prepared', evidence=[])
        report['status'] = 'running'
        write_json(args.output / 'invocation.json', report)
        # Spawn every requested peer before waiting for either; the test itself
        # has a namespace-scoped ready barrier after B leaves A's movement lane.
        for peer in devices:
            logs[peer] = (args.output / peer / 'test.log').open('xb')
            processes[peer] = subprocess.Popen(report['peers'][peer]['command'], cwd=APP, env=env,
                                               stdout=logs[peer], stderr=subprocess.STDOUT, start_new_session=True)
            report['peers'][peer]['status'] = 'running'
        deadline = time.monotonic() + allowance + 120
        while any(process.poll() is None for process in processes.values()):
            if time.monotonic() >= deadline:
                raise TimeoutError('Host replay exceeded its explicit test/launch allowance')
            time.sleep(.25)
    except (Exception, KeyboardInterrupt) as error:
        report['failures'].append(str(error) or type(error).__name__)
    finally:
        for peer, process in processes.items():
            try:
                terminate_owned(process)
            except Exception as error:
                report['failures'].append(peer + ' cleanup: ' + str(error))
            report['peers'][peer]['exitCode'] = process.returncode
        for log in logs.values():
            log.close()
        for peer, simulator in devices.items():
            if peer not in report['peers']:
                continue
            detail = report['peers'][peer]
            peer_dir = args.output / peer
            try:
                after = container(simulator, env)
                if after:
                    prefix = 'MovementHost-' + namespace + '-' + peer + '-'
                    for source in sorted((after / 'Documents').glob(prefix + '*')):
                        if source.is_dir() and source.name not in previous.get(peer, set()):
                            destination = peer_dir / 'evidence' / source.name
                            destination.parent.mkdir(exist_ok=True)
                            shutil.copytree(source, destination)
                            detail['evidence'].append(dict(simulatorPath=str(source), copiedPath=str(destination)))
                detail['xctest'] = export_xctest(peer_dir, env)
                if detail.get('exitCode') != 0:
                    raise RuntimeError('xcodebuild failed or did not run')
                summaries = list((peer_dir / 'evidence').glob('MovementHost-*/summary.json'))
                if len(summaries) != 1:
                    raise RuntimeError('Expected exactly one new host trace evidence directory')
                summary = json.loads(summaries[0].read_text())
                events = summaries[0].parent / 'events.json'
                if ((summary.get('romSHA256'), summary.get('namespace'), summary.get('peer'), summary.get('mode'),
                     summary.get('rate'), summary.get('requestedFrames'), summary.get('axis')) !=
                    (args.sha256, namespace, peer, args.mode, args.rate, args.frames, args.axis)
                        or summary.get('finished') is not True or summary.get('droppedTraceEvents') != 0
                        or summary.get('gameViews', 0) < 1 or not events.is_file() or events.stat().st_size <= 2):
                    raise RuntimeError('Host trace evidence is missing, incomplete, or has the wrong identity')
                if args.mode == 'peer' and (summary.get('peerConfirmed') is not True or summary.get('presenceReceived', 0) < 3):
                    raise RuntimeError('The peer transport did not exercise confirmed bidirectional presence')
                if summary.get('nativeFollowerRequested') is not (args.follower == '1'):
                    raise RuntimeError('Native follower request differs from the executed host fixture')
                if summary.get('faintedPartyRequested') is not args.fainted_party:
                    raise RuntimeError('Native party variant differs from the executed host fixture')
                soul_proof = verify_soul_fixture(summary, summaries[0].parent, args.soul_policy == '1', namespace, peer, args.sha256)
                detail['sceneDiagnosticsProof'] = verify_scene_diagnostics(
                    summary, summaries[0].parent, args.scene_diagnostics, args.sha256, args.frames)
                window = trace_window(events, args.frames, peer, args.mode, args.port_diagnostics, args.rate, args.follower == '1', args.soul_policy == '1', args.fainted_party, args.axis)
                if args.port_diagnostics and (summary.get('portDiagnostics') is not True
                        or any(window['stageCounts'].get('qa.port.' + phase + '.reject') != args.frames
                               for phase in ('video', 'beforeOwner', 'afterOwner'))):
                    raise ValueError('Requested port diagnostics are missing from one or more measured boundaries')
                if args.port_diagnostics:
                    context = summaries[0].parent / 'native-context'
                    manifest = json.loads((context / 'manifest.json').read_text())
                    sizes = dict(rom=0x2000000, workRAM=0x40000, internalRAM=0x8000,
                                 ioMem=0x400, paletteRAM=0x400, vram=0x20000, oam=0x400)
                    expected = {name + '.bin' for name in sizes} | {'exact-runtime.state'}
                    if (manifest.get('schema') != 1 or manifest.get('sourceROM_SHA256') != args.sha256
                            or set(manifest.get('files', {})) != expected):
                        raise ValueError('Native context has the wrong ROM/schema/bank manifest')
                    for name, item in manifest['files'].items():
                        path = context / name
                        size = path.stat().st_size
                        if (not size or size != item.get('bytes') or digest(path) != item.get('sha256')
                                or (name.endswith('.bin') and size != sizes[name[:-4]])):
                            raise ValueError('Native context bank failed size/hash verification: ' + name)
                    detail['nativeContext'] = dict(manifest=str(context / 'manifest.json'),
                                                   manifestSHA256=digest(context / 'manifest.json'),
                                                   scope='Diagnostic capture only; runtime policies differ from the source ROM')
                write_json(peer_dir / 'measured-window.json', window)
                if not window['sustainedAuthority']['passed']:
                    raise RuntimeError('Post-startup authority/reader regression: ' +
                                       ', '.join(window['sustainedAuthority']['failures']))
                if not window['renderDelivery']['passed']:
                    raise RuntimeError('Post-startup render delivery regression: ' +
                                       ', '.join(window['renderDelivery']['failures']))
                if not window['soulPolicy']['passed']:
                    raise RuntimeError('Post-startup Soul policy regression: ' + ', '.join(window['soulPolicy']['failures']))
                if not window['soulFrameFence']['passed']:
                    raise RuntimeError('Routine field observation blocked native frames: ' + ', '.join(window['soulFrameFence']['failures']))
                detail.update(status='passed', hostSummary=summary, measuredWindow=window, soulPolicyProof=soul_proof, eventsSHA256=digest(events))
            except Exception as error:
                detail.update(status='failed', error=str(error))
                report['failures'].append(peer + ': ' + str(error))
            write_json(peer_dir / 'result.json', detail)
        with state.lock:
            report['relayStatus'] = dict(state.status(history=True), readyPeers=sorted(state.host_ready))
        if report['relayStatus']['interactionPeers'] != sorted(devices):
            report['failures'].append('Relay interaction recipients differ from the explicit fixture peers')
        if args.mode == 'peer' and any(report['relayStatus']['unroutedInteractionPackets'].values()):
            report['failures'].append('Paired fixture discarded an ordered interaction packet')
        if args.mode == 'peer' and (set(report['relayStatus']['readyPeers']) != {'A', 'B'}
                                   or any(report['relayStatus']['presencePackets'][p] == 0 for p in devices)):
            report['failures'].append('Relay did not confirm both ready peers and actual presence publications')
        for peer, detail in report['peers'].items():
            if detail.get('status') != 'passed':
                continue
            try:
                detail['fixtureProducerCheck'] = verify_fixture_producer(
                    detail['hostSummary'], report['relayStatus'], peer, namespace, args.mode)
            except Exception as error:
                detail.update(status='failed', error=str(error))
                report['failures'].append(peer + ': ' + str(error))
            write_json(args.output / peer / 'result.json', detail)
        write_json(args.output / 'relay-status.json', report['relayStatus'])
        if server:
            if thread and thread.is_alive():
                server.shutdown()
            server.server_close()
        if thread:
            thread.join(timeout=5)
        report['seconds'] = time.monotonic() - started
        report['status'] = 'failed' if report['failures'] or len(processes) != len(devices) else 'passed'
        write_json(args.output / 'result.json', report)
    print(json.dumps(dict(status=report['status'], output=str(args.output), namespace=namespace,
                          failures=report['failures']), indent=2))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
