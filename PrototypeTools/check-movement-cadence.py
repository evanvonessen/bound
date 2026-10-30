#!/usr/bin/env python3
"""Check a completed verify-movement-cadence.py replay without running a simulator.

Use PrototypeTools/qa-python with explicit BOUND_GAME_SOURCE, --input (runner
output or its retained evidence directory), and a fresh --output report.json.
Acceptance applies to the declared 32-frame run / 8-frame release loop only.
Actual video callbacks are the measurement boundary; completed-frame RAM is
used only for occupancy/follower diagnostics. This is not device/WAN acceptance.
"""
import argparse
from collections import Counter
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys

ARTIFACTS = Path(__file__).resolve().parents[2] / 'artifacts/multiplayer-isolation'
BOUNDARY = 'Actual native video processFrame; completed-frame RAM observations are separate diagnostics'
TEST = 'WorldMovementRuntimeTests/testRepeatedNativeMovementCadence'
SHA256 = re.compile(r'[0-9a-f]{64}')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    return json.loads(path.read_text())


def numeric(value):
    return type(value) in (int, float) and math.isfinite(value)


def expected_input(frame):
    if frame == 0:
        return 0
    phase = (frame - 1) % 80
    return ((32 if phase < 40 else 16) | 2) if phase % 40 < 32 else 0


def histogram(values, key):
    return [{key: value, 'count': count} for value, count in sorted(Counter(values).items())]


def check_case(case, frames, follower):
    failures = []

    def require(condition, code, detail):
        if not condition:
            failures.append(dict(code=code, detail=detail))

    rows, completed = case.get('videoRaw'), case.get('raw')
    metrics = case.get('metrics', {})
    require(metrics.get('observationBoundary') == BOUNDARY, 'video_boundary',
            'Requires actual native video processFrame observations, not completed-frame RAM metrics')
    require(isinstance(rows, list) and len(rows) == frames, 'video_count',
            f'Expected exactly {frames} video callbacks')
    require(isinstance(completed, list) and len(completed) == frames, 'completed_count',
            f'Expected exactly {frames} completed-frame diagnostics')
    if not isinstance(rows, list) or not rows or not isinstance(completed, list):
        return dict(name=case.get('name'), status='failed', failures=failures)
    required = ('frame', 'completedFrameIndex', 'time', 'input', 'tileX', 'tileY',
                'mapGroup', 'mapNumber', 'pixelX', 'pixelY', 'overlayPixels', 'safeField')
    malformed = [i for i, row in enumerate(rows) if not isinstance(row, dict)
                 or any(not numeric(row.get(key)) for key in required)]
    require(not malformed, 'missing_video_fields', dict(frames=malformed))
    if malformed:
        return dict(name=case.get('name'), status='failed', failures=failures)
    require(all(row['frame'] == i and row['completedFrameIndex'] == i for i, row in enumerate(rows)),
            'video_sequence', 'Every native frame must have exactly one ordered video observation')
    require(all(row['input'] == expected_input(i) for i, row in enumerate(rows)),
            'input_tape', 'Video input must match the declared 32-frame run / 8-frame release loop')
    require(all(row.get('status') == 'live' and row['safeField'] == 1 for row in rows),
            'video_field', 'Every video observation must decode a live field player')
    require(len({(row['mapGroup'], row['mapNumber']) for row in rows}) == 1,
            'map_changed', 'The declared straight-road loop must stay on its original map')
    overlays = [i for i, row in enumerate(rows) if row['overlayPixels'] != 0]
    require(not overlays, 'overlay_pixels', dict(frames=overlays))
    gaps = [(b['time'] - a['time']) * 1000 for a, b in zip(rows, rows[1:])]
    require(all(gap > 0 for gap in gaps), 'video_clock', 'Video callback times must strictly increase')
    slow_callbacks = [dict(frame=i + 1, milliseconds=gap) for i, gap in enumerate(gaps) if gap > 50]
    require(not slow_callbacks, 'video_callback_gap', slow_callbacks)

    # A segment ends on ANY release or input change. Never filter intervals by
    # their length: a 20-frame stall under held input must remain a failure.
    changes, intervals, holds = [], [], []
    last_change, held, moving = None, 0, False
    for i, (a, b) in enumerate(zip(rows, rows[1:]), 1):
        stable = a['input'] == b['input'] and int(b['input']) & 48 != 0
        if not stable:
            last_change = None
            holds.append(held)
            held, moving = 0, False
        changed = (a['tileX'], a['tileY']) != (b['tileX'], b['tileY'])
        if changed:
            changes.append(i)
            require(abs(b['tileX'] - a['tileX']) + abs(b['tileY'] - a['tileY']) == 1,
                    'tile_jump', dict(frame=i, before=[a['tileX'], a['tileY']], after=[b['tileX'], b['tileY']]))
            if stable:
                if last_change is not None:
                    intervals.append(dict(startFrame=last_change, endFrame=i, frames=i - last_change,
                                          input=int(b['input'])))
                last_change = i
        if stable:
            if (a['pixelX'], a['pixelY']) != (b['pixelX'], b['pixelY']):
                moving = True
                holds.append(held)
                held = 0
            elif moving:
                held += 1
    holds.append(held)
    expected = frames // 40 * 3
    require(len(changes) == expected, 'transition_count', dict(expected=expected, actual=len(changes)))
    loop_counts = [sum(start <= change < start + 40 for change in changes) for start in range(0, frames, 40)]
    require(all(count == 3 for count in loop_counts), 'loop_transition_count',
            [dict(startFrame=i * 40, expected=3, actual=count) for i, count in enumerate(loop_counts) if count != 3])
    require(len(intervals) == frames // 40 * 2, 'held_interval_count',
            dict(expected=frames // 40 * 2, actual=len(intervals)))
    long_intervals = [item for item in intervals if item['frames'] > 9]
    require(not long_intervals, 'held_tile_interval', long_intervals)
    require(max(holds, default=0) <= 1, 'held_pixel_freeze', dict(longest=max(holds, default=0)))

    # Completed RAM may be observed mid-update; do not use its transient pixel
    # decoder or tile timing as video evidence. Occupancy and follower state are
    # still required, independently of the reported aggregate metrics.
    valid_completed = all(isinstance(row, dict) and row.get('frame') == i
                          and row.get('input') == expected_input(i) and numeric(row.get('time'))
                          for i, row in enumerate(completed))
    require(valid_completed, 'completed_sequence', 'Completed diagnostics must cover the declared ordered input tape')
    diagnostic = {}
    if valid_completed:
        blocked = [i for i, row in enumerate(completed) if int(row.get('guestFlags', 0)) & (32 | 64)]
        followers = sum(row.get('followerActive') == 1 for row in completed)
        admitted = sum(int(row.get('guestFlags', 0)) & 6 == 6 for row in completed)
        diagnostic = dict(remoteBlockedSamples=len(blocked), activeFollowerSamples=followers,
                          admittedPortSamples=admitted, frames=len(completed))
        require(not blocked, 'remote_block', dict(frames=blocked))
        require(not follower or followers == frames, 'follower_inactive', dict(expected=frames, actual=followers))
        require(case.get('mode') == 'native' or admitted > frames * .9, 'port_not_active', diagnostic)
        completed_metrics = case.get('completedFrameMetrics', {})
        for key, actual in diagnostic.items():
            require(completed_metrics.get(key) == actual, 'completed_metric_mismatch',
                    dict(metric=key, reported=completed_metrics.get(key), actual=actual))
        completed_gaps = [(b['time'] - a['time']) * 1000 for a, b in zip(completed, completed[1:])]
        require(all(0 < gap <= 50 for gap in completed_gaps), 'completed_callback_gap',
                [dict(frame=i + 1, milliseconds=gap) for i, gap in enumerate(completed_gaps) if not 0 < gap <= 50])
    recomputed = dict(frames=len(rows), tileTransitions=len(changes), missingPixelSamples=0,
                      overlayPixelSamples=len(overlays), longestHeldInputPixelFreeze=max(holds, default=0),
                      over50ms=len(slow_callbacks), maxGapMs=max(gaps, default=0),
                      heldTileIntervalHistogram=histogram([item['frames'] for item in intervals], 'frames'),
                      longestHeldTileInterval=max((item['frames'] for item in intervals), default=0),
                      loopTransitionCounts=loop_counts)
    for key in ('frames', 'tileTransitions', 'missingPixelSamples', 'overlayPixelSamples',
                'longestHeldInputPixelFreeze', 'over50ms', 'maxGapMs'):
        reported, actual = metrics.get(key), recomputed[key]
        matches = numeric(reported) and math.isclose(reported, actual, rel_tol=1e-9, abs_tol=1e-6)
        require(matches, 'video_metric_mismatch', dict(metric=key, reported=reported, actual=actual))
    return dict(name=case.get('name'), status='failed' if failures else 'passed', metrics=recomputed,
                completedDiagnostics=diagnostic, failures=failures)


def self_checks():
    # All negative variants retain the claimed aggregate count of three tiles.
    # The long stall is >16 frames, so a broad interval cutoff cannot hide it.
    rows = []
    for frame in range(40):
        tile = 36 - sum(frame >= change for change in (8, 16, 24))
        rows.append(dict(frame=frame, completedFrameIndex=frame, input=expected_input(frame),
                         time=frame / 60, tileX=tile, tileY=20, mapGroup=3, mapNumber=1,
                         pixelX=584 - frame * 2, pixelY=336, overlayPixels=0, safeField=1, status='live'))
    completed = [dict(frame=i, input=expected_input(i), time=i / 60, guestFlags=7, followerActive=1) for i in range(40)]
    case = dict(name='synthetic', mode='far', videoRaw=rows, raw=completed,
                metrics=dict(observationBoundary=BOUNDARY, frames=40, tileTransitions=3,
                             missingPixelSamples=0, overlayPixelSamples=0, longestHeldInputPixelFreeze=0,
                             over50ms=0, maxGapMs=1000 / 60),
                completedFrameMetrics=dict(frames=40, remoteBlockedSamples=0, activeFollowerSamples=40, admittedPortSamples=40))
    checks = [('smooth', case, None)]
    stalled = copy.deepcopy(case)
    for row in stalled['videoRaw']:
        row['tileX'] = 36 - sum(row['frame'] >= change for change in (3, 24, 31))
    checks.append(('long_stall_despite_correct_total', stalled, 'held_tile_interval'))
    missing = copy.deepcopy(case)
    del missing['videoRaw'][15]['pixelY']
    checks.append(('missing_video_pixel', missing, 'missing_video_fields'))
    boundary = copy.deepcopy(case)
    boundary['metrics']['observationBoundary'] = 'Completed-frame RAM'
    checks.append(('false_video_boundary', boundary, 'video_boundary'))
    lost = copy.deepcopy(case)
    del lost['videoRaw'][15]
    checks.append(('missing_video_callback', lost, 'video_count'))
    frozen = copy.deepcopy(case)
    for frame in (10, 11):
        frozen['videoRaw'][frame]['pixelX'] = frozen['videoRaw'][9]['pixelX']
    checks.append(('held_two_frame_freeze', frozen, 'held_pixel_freeze'))
    outcomes = []
    for name, value, expected in checks:
        result = check_case(value, 40, True)
        codes = {item['code'] for item in result['failures']}
        passed = not codes if expected is None else expected in codes
        outcomes.append(dict(name=name, passed=passed, expectedFailure=expected, observedFailures=sorted(codes)))
    return outcomes


def check_run(input_path):
    # Evidence alone cannot prove the requested matrix or a completed run.
    root = next((path for path in (input_path, *input_path.parents)
                 if (path / 'invocation.json').is_file()), None)
    if root is None:
        raise ValueError('Input must retain its runner invocation.json and result.json ancestors')
    invocation = read_json(root / 'invocation.json')
    result = read_json(root / 'result.json')  # Missing final result is never accepted.
    failures, references = [], {}

    def require(condition, code, detail):
        if not condition:
            failures.append(dict(code=code, detail=detail))

    def reference(path, expected=None):
        path = Path(path)
        if not path.is_absolute() or not path.is_file():
            raise ValueError(f'Missing absolute provenance reference: {path}')
        actual = digest(path)
        references[str(path)] = actual
        require(expected is None or actual == expected, 'provenance_hash',
                dict(path=str(path), expected=expected, actual=actual))
        return actual

    for name in ('invocation.json', 'result.json', 'xctest-summary.json', 'xctest-tests.json'):
        reference(root / name)
    require(result.get('status') == 'passed' and result.get('exitCode') == 0, 'runner_incomplete',
            dict(status=result.get('status'), exitCode=result.get('exitCode')))
    for key, value in invocation.items():
        if key not in ('status', 'evidence'):
            require(result.get(key) == value, 'invocation_result_mismatch', key)
    frames, repeats = invocation.get('frames'), invocation.get('repeats')
    rates, modes = invocation.get('rates'), invocation.get('modes')
    if not (type(frames) is int and 160 <= frames <= 36000 and frames % 40 == 0
            and type(repeats) is int and 1 <= repeats <= 10
            and isinstance(rates, list) and rates and all(rate in (1, 3) for rate in rates)
            and isinstance(modes, list) and modes and all(mode in ('native', 'far', 'near', 'moving') for mode in modes)
            and len(set(rates)) == len(rates) and len(set(modes)) == len(modes)
            and type(invocation.get('followerRequested')) is bool):
        raise ValueError('Unsupported invocation matrix: exact 40-frame loop multiples and unique declared modes/rates required')
    rom_hash = invocation.get('romSHA256', '')
    require(bool(SHA256.fullmatch(rom_hash)), 'rom_hash', 'Requires an exact SHA256 ROM identity')
    reference(invocation['rom'], rom_hash)
    reference(invocation['xctestrun'], invocation['xctestrunSHA256'])
    reference(root / 'checkout-at-launch-hashes.json', invocation['checkoutAtLaunchManifestSHA256'])
    reference(root / 'binary-hashes.json')
    require(read_json(root / 'binary-hashes.json') == invocation.get('binaryHashes'), 'binary_manifest', 'Binary hashes must match invocation')
    binaries = invocation.get('binaryHashes', {})
    require(bool(binaries), 'binary_manifest', 'Missing compiled binary identities')
    for path, expected in binaries.items():
        require(isinstance(expected, str) and bool(SHA256.fullmatch(expected)),
                'binary_hash', dict(path=path, sha256=expected))
        reference(path, expected)
    receipt_ref = invocation.get('buildSourceReceipt')
    if not isinstance(receipt_ref, dict) or not SHA256.fullmatch(receipt_ref.get('sha256', '')):
        raise ValueError('Requires the separately preserved build source receipt; launch checkout hashes are insufficient')
    reference(root / 'build-source-receipt.json', receipt_ref['sha256'])
    receipt = read_json(root / 'build-source-receipt.json')
    source_files = receipt.get('files', {})
    required_sources = ('Delta/Bound/BoundLivePresence.swift', 'Delta/Bound/BoundPlayerStateDisplay.swift',
                        'PrototypeIntegrationTests/WorldMovementRuntimeTests.swift')
    require(receipt.get('head') == invocation.get('appCommit') and bool(receipt.get('configuration')),
            'source_receipt', 'Build receipt must identify the app source revision and build configuration')
    require(all(SHA256.fullmatch(source_files.get(path, '')) for path in required_sources),
            'source_receipt', 'Build receipt must hash the production movement/presentation sources and actual video test')
    for key in ('appSource', 'gameSource'):
        require(isinstance(invocation.get(key), str) and Path(invocation[key]).is_absolute(), 'source_reference', key)
    require(bool(re.fullmatch(r'[0-9a-f]{40}', invocation.get('gameCommit', ''))), 'game_revision', 'Missing game source revision')

    summary = read_json(root / 'xctest-summary.json')
    require(summary.get('totalTestCount') == 1 and summary.get('passedTests') == 1
            and all(summary.get(key) == 0 for key in ('failedTests', 'skippedTests', 'expectedFailures')),
            'xctest_result', 'Exactly one passed test, no failures or skips, is required')
    tests = []

    def visit(value):
        if isinstance(value, dict):
            if value.get('nodeType') == 'Test Case':
                tests.append(value)
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(read_json(root / 'xctest-tests.json'))
    require(len(tests) == 1 and tests[0].get('result') == 'Passed'
            and tests[0].get('nodeIdentifier') in (TEST, TEST + '()'), 'xctest_selection', tests)
    directories = list((root / 'evidence').glob('MovementCadence-*'))
    if len(directories) != 1:
        raise ValueError('Requires exactly one retained movement evidence directory')
    evidence = directories[0]
    require(input_path in (root, root / 'evidence', evidence), 'input_directory', 'Select the runner output or its retained evidence directory')
    reference(evidence / 'fixture.json')
    fixture = read_json(evidence / 'fixture.json')
    require(fixture.get('romSHA256') == rom_hash and fixture.get('followerRequested') == invocation['followerRequested'],
            'fixture_identity', 'Fixture must match exact ROM and requested follower state')
    require(isinstance(fixture.get('anchorSHA256'), str) and bool(SHA256.fullmatch(fixture['anchorSHA256'])),
            'anchor_identity', 'Requires an exact hash for the native same-ROM anchor')
    reference(evidence / 'exact-ROM-anchor.state', fixture.get('anchorSHA256'))
    expected = {f'repeat-{repeat}-{mode}-{float(rate):.1f}': (repeat, mode, rate)
                for repeat in range(1, repeats + 1) for rate in rates for mode in modes}
    files = {path.stem: path for path in evidence.glob('repeat-*.json')}
    require(set(files) == set(expected), 'case_matrix', dict(missing=sorted(set(expected) - set(files)),
                                                          unexpected=sorted(set(files) - set(expected))))
    reference(evidence / 'summary.json')
    summaries = read_json(evidence / 'summary.json')
    require(isinstance(summaries, list) and len(summaries) == len(expected)
            and Counter(item.get('name') for item in summaries) == Counter(expected.keys()),
            'summary_matrix', 'Summary must include each declared case exactly once')
    cases = []
    for name in sorted(expected.keys() & files.keys()):
        path = files[name]
        reference(path)
        case = read_json(path)
        repeat, mode, rate = expected[name]
        require((case.get('name'), case.get('repeat'), case.get('mode'), case.get('rate'), case.get('romSHA256'))
                == (name, repeat, mode, rate, rom_hash), 'case_identity', name)
        reduced = {key: value for key, value in case.items() if key not in ('raw', 'videoRaw')}
        require(sum(item == reduced for item in summaries) == 1, 'summary_case_mismatch', name)
        cases.append(check_case(case, frames, invocation['followerRequested']))
    return dict(status='failed' if failures or any(case['status'] != 'passed' for case in cases) else 'passed',
                input=str(input_path), runnerOutput=str(root), romSHA256=rom_hash,
                matrix=dict(frames=frames, repeats=repeats, rates=rates, modes=modes, expectedCases=len(expected)),
                thresholds=dict(transitionsPer40Frames=3, maxHeldTileIntervalFrames=9,
                                maxHeldPixelFreezeFrames=1, maxCallbackGapMs=50, missingVideoSamples=0, overlayPixels=0),
                sourceReceipt=receipt_ref,
                sourceProvenance=dict(appSource=invocation['appSource'], appBaseCommit=invocation['appCommit'],
                                      gameSource=invocation['gameSource'], gameBaseCommit=invocation['gameCommit'],
                                      limit='The retained app build receipt identifies compiled app sources. A game base commit alone does not identify uncommitted ROM changes; pair the exact ROM hash with its separately retained game build/native-verification receipt.'),
                references=references, failures=failures, cases=cases,
                scope='Simulator native video callback cadence and occupancy/follower diagnostics; no physical scanout or WAN claim')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--self-check', action='store_true', help='Run synthetic positive and rejection cases only')
    args = parser.parse_args()
    if not args.self_check and args.input is None:
        parser.error('--input is required unless --self-check is selected')
    if 'BOUND_GAME_SOURCE' not in os.environ:
        parser.error('Set BOUND_GAME_SOURCE to the explicit selected game checkout')
    game = Path(os.environ['BOUND_GAME_SOURCE']).resolve(strict=True)
    sys.path.insert(0, str(game / 'tools'))
    from qa_python import ensure_qa_python
    ensure_qa_python()
    output = args.output.resolve()
    if output.exists() or not output.is_relative_to(ARTIFACTS.resolve()):
        parser.error('Use a fresh explicit output report within artifacts/multiplayer-isolation')
    checks = self_checks()
    try:
        report = dict(status='passed') if args.self_check else check_run(args.input.resolve(strict=True))
    except (OSError, ValueError, KeyError, TypeError) as error:
        report = dict(status='failed', failures=[dict(code='incomplete_or_invalid_evidence', detail=str(error))])
    report['selfChecks'] = checks
    if not all(check['passed'] for check in checks):
        report['status'] = 'failed'
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('x') as stream:
        json.dump(report, stream, indent=2, sort_keys=True)
        stream.write('\n')
    print(json.dumps(dict(status=report['status'], output=str(output),
                          failedCases=[case['name'] for case in report.get('cases', []) if case['status'] == 'failed'],
                          failures=report.get('failures', [])), indent=2))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
