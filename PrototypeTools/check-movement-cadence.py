#!/usr/bin/env python3
"""Check a completed verify-movement-cadence.py replay without running a simulator.

Use PrototypeTools/qa-python with explicit BOUND_GAME_SOURCE, --input (runner
output or its retained evidence directory), and a fresh --output report.json.
Historical release-loop checks remain unchanged. Continuous tapes compare
actual progress and every held pose with the matched native control.
Actual video callbacks are the measurement boundary; completed-frame RAM is
used only for occupancy/follower diagnostics. This is not device/WAN acceptance.
"""
import argparse
import base64
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
TAPES = ('release-run', 'continuous-run', 'continuous-walk')
AXES = ('horizontal', 'vertical')
ROUTES = {'horizontal': dict(leftTileX=33, rightTileX=36, tileY=20),
          'vertical': dict(tileX=36, topTileY=20, bottomTileY=22)}
ENDPOINT_CONTROL = 'Native avatar/ObjectEvent target and SaveBlock map; no BWO admission'
NATIVE_ENTRIES = {0x4B0: bytes.fromhex('00b50af061fe0006'), 0x56578: bytes.fromhex('00b513f095fa20f0')}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    return json.loads(path.read_text())


def verify_frozen_source(receipt):
    """Archived build trees need no .git directory or current-checkout match."""
    if 'sourceRoot' not in receipt:
        return None
    root = Path(receipt['sourceRoot'])
    files = receipt.get('files', {})
    if not root.is_absolute() or not root.is_dir() or not isinstance(files, dict) or not files:
        raise ValueError('Frozen source receipt requires an existing absolute sourceRoot and file hashes')
    for name, expected in files.items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts or not SHA256.fullmatch(str(expected)):
            raise ValueError(f'Invalid frozen source entry: {name}')
        path = root / relative
        if not path.is_file() or digest(path) != expected:
            raise ValueError(f'Frozen source differs from build receipt: {name}')
    return dict(sourceRoot=str(root), baseCommit=receipt.get('head'), verifiedFiles=len(files),
                scope='Every listed frozen file matches the build receipt; no current-checkout or Git-directory assumption')


def numeric(value):
    return type(value) in (int, float) and math.isfinite(value)


def expected_input(frame):
    if frame == 0:
        return 0
    phase = (frame - 1) % 80
    return ((32 if phase < 40 else 16) | 2) if phase % 40 < 32 else 0


def histogram(values, key):
    return [{key: value, 'count': count} for value, count in sorted(Counter(values).items())]


def continuous_inputs(completed, tape, route, axis='horizontal'):
    vertical = axis == 'vertical'
    direction, masks = (128 if vertical else 32), []
    key, low, high = ('tileY', route['topTileY'], route['bottomTileY']) if vertical else ('tileX', route['leftTileX'], route['rightTileX'])
    for row in completed:
        if row.get(key, math.inf) <= low:
            direction = 128 if vertical else 16
        elif row.get(key, -math.inf) >= high:
            direction = 64 if vertical else 32
        masks.append(direction | (2 if tape == 'continuous-run' else 0))
    return [0] + masks[:-1], masks


def continuous_measurements(rows, route, require, axis='horizontal', tape='continuous-run'):
    vertical = axis == 'vertical'
    along, across, camera = ('pixelY', 'pixelX', 'cameraY') if vertical else ('pixelX', 'pixelY', 'cameraX')
    low, high, fixed = ((route['topTileY'] * 16 + 16, route['bottomTileY'] * 16 + 16, route['tileX'] * 16 + 8)
                        if vertical else (route['leftTileX'] * 16 + 8, route['rightTileX'] * 16 + 8, route['tileY'] * 16 + 16))
    shift_key = 'previousYMinusCurrentY' if vertical else 'previousXMinusCurrentX'
    quantum = 1 if tape == 'continuous-walk' else 2
    require(all(low <= r[along] <= high and r[across] == fixed for r in rows),
            'continuous_lane', 'Native pixels must stay inside the verified paved lane')
    trainer_checks = camera_checks = uncertain = verified_travel = 0
    trainer_errors, camera_errors = [], []
    cumulative, held_pairs, held_poses, longest, held, turns, arrivals = [0], 0, 0, 0, 0, 0, []
    target = high if vertical else low
    for i, row in enumerate(rows):
        native = row.get('nativePixelDiagnostic', {})
        trainer = native.get('trainerTemplate', {})
        if vertical and trainer.get('confident'):
            visible, masked, opaque = (trainer.get(k) for k in ('visiblePixels', 'maskedPixels', 'opaqueTemplatePixels'))
            mask_pixels = trainer.get('nativeFollowerMaskPixels')
            valid = (all(numeric(v) for v in (visible, masked, opaque, mask_pixels))
                     and visible >= 40 and 0 <= masked <= mask_pixels and visible + masked == opaque <= 384
                     and numeric(trainer.get('matchFraction')) and trainer['matchFraction'] >= .8
                     and numeric(trainer.get('margin')) and trainer['margin'] >= .05)
            require(valid, 'trainer_mask_evidence', dict(frame=i, trainer=trainer))
        if trainer.get('confident'):
            trainer_checks += 1
            if (trainer.get('footX'), trainer.get('footY')) != (120, 88) or (
                    row['pixelX'] + row.get('cameraX', math.inf), row['pixelY'] + row.get('cameraY', math.inf)) != (120, 88):
                trainer_errors.append(i)
        if row[along] == target:
            arrivals.append(i)
            target = high if target == low else low
        if i == 0:
            continue
        previous = rows[i - 1]
        dx, dy = row['pixelX'] - previous['pixelX'], row['pixelY'] - previous['pixelY']
        delta, cross_delta = (dy, dx) if vertical else (dx, dy)
        require(abs(delta) <= quantum and cross_delta == 0, 'continuous_pixel_jump', dict(frame=i, dx=dx, dy=dy))
        cumulative.append(cumulative[-1] + abs(dx) + abs(dy))
        background = native.get('backgroundStrips', {})
        if background.get('confident'):
            camera_checks += 1
            shift = background.get(shift_key)
            if (background.get('axis', 'horizontal') != axis or not numeric(shift) or shift != delta
                    or row.get(camera, math.inf) - previous.get(camera, -math.inf) != -shift):
                camera_errors.append(i)
            else:
                verified_travel += abs(shift)
        else:
            uncertain += 1
        # Include direction changes and native startup. The continuous input
        # provides no release period, and no slow part of a turn is discarded.
        if int(previous['input']) & 240 and int(row['input']) & 240:
            held_pairs += 1
            turns += (int(previous['input']) & 240) != (int(row['input']) & 240)
            if dx == 0 and dy == 0:
                held_poses += 1
                held += 1
                longest = max(longest, held)
            else:
                held = 0
        else:
            held = 0
    require(trainer_checks > len(rows) * .99, 'trainer_confidence', dict(confident=trainer_checks, frames=len(rows)))
    require(camera_checks > (len(rows) - 1) * .99, 'background_confidence', dict(confident=camera_checks, transitions=len(rows)-1))
    require(not trainer_errors, 'native_trainer_mismatch', trainer_errors)
    require(not camera_errors, 'native_background_mismatch', camera_errors)
    require(cumulative[-1] > len(rows) / 4 and len(arrivals) >= 2, 'continuous_no_progress',
            dict(pixels=cumulative[-1], endpointArrivals=len(arrivals)))
    return dict(totalPixelTravel=cumulative[-1], verifiedBitmapTravel=verified_travel,
                bitmapTravelBounds=[verified_travel, verified_travel + quantum * uncertain],
                cumulativePixelTravel=cumulative, allHeldPairs=held_pairs, allHeldPixelHolds=held_poses,
                heldPoseFraction=held_poses / held_pairs if held_pairs else 1,
                maximumConsecutiveHeldPoses=longest, directionChanges=turns,
                endpointArrivalFrames=arrivals, trainerChecks=trainer_checks, cameraChecks=camera_checks,
                uncertainBackgroundPairs=uncertain)


def compare_continuous(cases):
    comparisons, failures = [], []
    for active in cases:
        if active.get('mode') == 'native':
            continue
        native = next((c for c in cases if c.get('mode') == 'native' and
                       (c.get('repeat'), c.get('rate'), c.get('preRollFrames'), c.get('axis', 'horizontal'), c.get('tape')) ==
                       (active.get('repeat'), active.get('rate'), active.get('preRollFrames'), active.get('axis', 'horizontal'), active.get('tape'))), None)
        if native is None or 'continuous' not in active or 'continuous' not in native:
            failures.append(dict(code='missing_matched_native', detail=active.get('name')))
            continue
        a, n = active['continuous'], native['continuous']
        deficit = n['totalPixelTravel'] - a['totalPixelTravel']
        prefix_deficit = max((y-x for x,y in zip(a['cumulativePixelTravel'], n['cumulativePixelTravel'])), default=0)
        extra_holds = a['allHeldPixelHolds'] - n['allHeldPixelHolds']
        item = dict(active=active['name'], native=native['name'], preRollFrames=active['preRollFrames'],
                    progressDeficitPixels=deficit, maximumCumulativeDeficitPixels=prefix_deficit,
                    extraHeldPoses=extra_holds, holdFractionDifference=a['heldPoseFraction']-n['heldPoseFraction'],
                    endpointArrivalDifference=len(a['endpointArrivalFrames'])-len(n['endpointArrivalFrames']),
                    bitmapProgressDeficitBounds=[n['bitmapTravelBounds'][0]-a['bitmapTravelBounds'][1],
                                                 n['bitmapTravelBounds'][1]-a['bitmapTravelBounds'][0]])
        comparisons.append(item)
        # At most one native 2px movement quantum / one held observation may
        # straddle the finite measurement boundary. This is not a percentage
        # budget that can conceal accumulating multiplayer slowdown.
        for condition, code in ((deficit <= 2, 'continuous_progress_loss'),
                                (prefix_deficit <= 2, 'continuous_accumulating_loss'),
                                (extra_holds <= 1, 'continuous_extra_held_poses'),
                                (a['maximumConsecutiveHeldPoses'] <= n['maximumConsecutiveHeldPoses'], 'continuous_extra_freeze')):
            if not condition:
                failures.append(dict(code=code, detail=item))
    return comparisons, failures


def check_case(case, frames, follower, native_floor=False):
    failures = []

    def require(condition, code, detail):
        if not condition:
            failures.append(dict(code=code, detail=detail))

    rows, completed = case.get('videoRaw'), case.get('raw')
    tape = case.get('tape', 'release-run')
    axis = case.get('axis', 'horizontal')
    require(axis in AXES and (axis == 'horizontal' or tape != 'release-run'), 'axis_identity', axis)
    if axis not in AXES:
        return dict(name=case.get('name'), status='failed', failures=failures)
    continuous = tape in ('continuous-run', 'continuous-walk')
    raw_native = case.get('mode') == 'raw-native'
    require(case.get('nativeFloorDiagnostic', False) is native_floor, 'diagnostic_label',
            'Diagnostic evidence must never be relabeled as a production candidate')
    require(not raw_native or native_floor, 'raw_native_not_candidate', 'Raw native is a separately authorized causal diagnostic only')
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
    if continuous:
        route = case.get('route', {})
        require(route == ROUTES[axis], 'route_identity', route)
        if route != ROUTES[axis]:
            return dict(name=case.get('name'), status='failed', failures=failures)
        require(all(isinstance(row, dict) and numeric(row.get('tileX')) and numeric(row.get('tileY')) for row in completed),
                'continuous_target_tile', 'Each native endpoint decision requires its observed target tile')
        if not all(isinstance(row, dict) and numeric(row.get('tileX')) and numeric(row.get('tileY')) for row in completed):
            return dict(name=case.get('name'), status='failed', failures=failures)
        if 'endpointControl' in case or native_floor or axis == 'vertical':
            require(case.get('endpointControl') == ENDPOINT_CONTROL, 'endpoint_control', case.get('endpointControl'))
            require(all(row.get('nativeTargetAvailable') == 1 and row.get('mapGroup') == 3 and row.get('mapNumber') == 1
                        and (33 <= row['tileX'] <= 36 and row['tileY'] == 20 if axis == 'horizontal' else
                             row['tileX'] == 36 and 20 <= row['tileY'] <= 22) for row in completed),
                    'native_endpoint_missing', 'Each endpoint decision needs the directly observed native target on the declared lane')
        inputs, next_inputs = continuous_inputs(completed, tape, route, axis)
        require(len(inputs) == len(rows) and all(row['input'] == mask for row, mask in zip(rows, inputs)),
                'input_tape', 'Continuous video input must follow the native target-tile endpoint controller without releases')
        require(all(row.get('nextInput') == mask for row, mask in zip(completed, next_inputs)),
                'continuous_next_input', 'Every applied next input must be explained by its native target tile')
    else:
        inputs = [expected_input(i) for i in range(len(rows))]
        require(tape == 'release-run', 'tape_identity', tape)
        require(all(row['input'] == mask for row, mask in zip(rows, inputs)),
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
        stable = a['input'] == b['input'] and int(b['input']) & 240 != 0
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
    if not continuous:
        require(len(changes) == expected, 'transition_count', dict(expected=expected, actual=len(changes)))
    loop_counts = [sum(start <= change < start + 40 for change in changes) for start in range(0, frames, 40)]
    if not continuous:
        require(all(count == 3 for count in loop_counts), 'loop_transition_count',
                [dict(startFrame=i * 40, expected=3, actual=count) for i, count in enumerate(loop_counts) if count != 3])
        require(len(intervals) == frames // 40 * 2, 'held_interval_count',
                dict(expected=frames // 40 * 2, actual=len(intervals)))
    long_intervals = [item for item in intervals if item['frames'] > 9]
    if not continuous:
        require(not long_intervals, 'held_tile_interval', long_intervals)
        require(max(holds, default=0) <= 1, 'held_pixel_freeze', dict(longest=max(holds, default=0)))

    # Completed RAM may be observed mid-update; do not use its transient pixel
    # decoder or tile timing as video evidence. Occupancy and follower state are
    # still required, independently of the reported aggregate metrics.
    valid_completed = all(isinstance(row, dict) and row.get('frame') == i
                          and i < len(inputs) and row.get('input') == inputs[i] and numeric(row.get('time'))
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
        require(case.get('mode') == 'native' or (raw_native and native_floor) or admitted > frames * .9, 'port_not_active', diagnostic)
        if raw_native:
            require(all('guestFlags' not in row and 'guestFrame' not in row and 'admittedGuestFrame' not in row for row in completed),
                    'raw_native_fake_admission', 'A diagnostic with removed native publication must not claim admitted BWO snapshots')
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
        if continuous and key == 'longestHeldInputPixelFreeze':
            continue  # Continuous acceptance includes all poses, even during native turns.
        reported, actual = metrics.get(key), recomputed[key]
        matches = numeric(reported) and math.isclose(reported, actual, rel_tol=1e-9, abs_tol=1e-6)
        require(matches, 'video_metric_mismatch', dict(metric=key, reported=reported, actual=actual))
    extra = {}
    if continuous:
        extra['continuous'] = continuous_measurements(rows, route, require, axis, tape)
        for key in ('totalPixelTravel', 'allHeldPairs', 'allHeldPixelHolds', 'directionChanges'):
            require(metrics.get(key) == extra['continuous'][key], 'continuous_metric_mismatch',
                    dict(metric=key, reported=metrics.get(key), actual=extra['continuous'][key]))
    return dict(name=case.get('name'), mode=case.get('mode'), repeat=case.get('repeat'), rate=case.get('rate'),
                preRollFrames=case.get('preRollFrames', 0), tape=tape, axis=axis,
                status='failed' if failures else 'passed', metrics=recomputed,
                completedDiagnostics=diagnostic, failures=failures, **extra)


def verify_native_entry_receipt(case, image, require):
    """Recompute the private two-entry image identity; no diagnostic ROM saved."""
    receipt, restoration = case.get('nativeEntryDiagnostic', {}), case.get('nativeEntryRestoration', {})
    patched = bytearray(image)
    patches = []
    for offset, native in NATIVE_ENTRIES.items():
        patches.append(dict(offset=offset, before=base64.b64encode(image[offset:offset+8]).decode(),
                            after=base64.b64encode(native).decode()))
        patched[offset:offset+8] = native
    require(receipt.get('sourceROM_SHA256') == hashlib.sha256(image).hexdigest()
            and receipt.get('diagnosticROM_SHA256') == hashlib.sha256(patched).hexdigest()
            and receipt.get('patches') == patches, 'native_entry_identity', case.get('name'))
    for key in ('residentBeforeSHA256', 'residentAfterSHA256', 'normalizedSourceSHA256'):
        require(bool(SHA256.fullmatch(str(receipt.get(key, '')))), 'native_entry_resident_hash', key)
    pc = receipt.get('pausedNextPC')
    require(type(pc) is int and not (0x08000000 <= pc < 0x0E000000
            and any(offset - 4 <= (pc & 0x1FFFFFF) < offset + 12 for offset in NATIVE_ENTRIES)),
            'native_entry_pipeline', pc)
    require(restoration.get('restored') is True and restoration.get('wasActive') is True
            and restoration.get('normalizedIdentityRestored') is True
            and restoration.get('normalizedRestoredSHA256') == receipt.get('normalizedSourceSHA256')
            and bool(SHA256.fullmatch(str(restoration.get('residentRestoredSHA256', '')))),
            'native_entry_restoration', case.get('name'))


def compare_native_floor(cases):
    """Describe inactive/active costs against one anchor's private native floor."""
    comparisons, failures = [], []
    for wrapped in (case for case in cases if case.get('mode') in ('native', 'far')):
        floor = next((case for case in cases if case.get('mode') == 'raw-native' and
                      (case.get('repeat'), case.get('rate'), case.get('preRollFrames'), case.get('axis', 'horizontal'), case.get('tape')) ==
                      (wrapped.get('repeat'), wrapped.get('rate'), wrapped.get('preRollFrames'), wrapped.get('axis', 'horizontal'), wrapped.get('tape'))), None)
        if floor is None or 'continuous' not in wrapped or 'continuous' not in floor:
            failures.append(dict(code='missing_native_floor_pair', detail=wrapped.get('name')))
            continue
        # Reuse arithmetic, never its candidate acceptance decision. Both raw
        # reports still have to pass all frame, input and actual-bitmap checks.
        a = dict(wrapped, mode='wrapped-' + wrapped['mode'])
        n = dict(floor, mode='native')
        values, _ = compare_continuous([a, n])
        comparisons.extend(dict(value, comparedMode=wrapped['mode'], referenceMode='raw-native',
                                scope='Descriptive native entry ablation; no production acceptance decision') for value in values)
    return comparisons, failures


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
    native = synthetic_continuous_case('native', False)
    equivalent = synthetic_continuous_case('far', False)
    slower = synthetic_continuous_case('far', True)
    native_result = check_case(native, 240, True)
    for name, value, should_fail in [('continuous_equal_progress', equivalent, False),
                                     ('continuous_isolated_holds_accumulate', slower, True)]:
        result = check_case(value, 240, True)
        _, failures = compare_continuous([native_result, result])
        codes = {item['code'] for item in failures}
        accepted = native_result['status'] == result['status'] == 'passed'
        passed = accepted and ('continuous_progress_loss' in codes and 'continuous_extra_held_poses' in codes
                               if should_fail else not codes)
        outcomes.append(dict(name=name, passed=passed, expectedPairedFailure=should_fail,
                             observedFailures=sorted(codes), longestHold=result.get('continuous', {}).get('maximumConsecutiveHeldPoses')))
    wrong_bitmap = copy.deepcopy(equivalent)
    wrong_bitmap['videoRaw'][30]['nativePixelDiagnostic']['backgroundStrips']['previousXMinusCurrentX'] += 2
    hidden_release = copy.deepcopy(equivalent)
    hidden_release['videoRaw'][30]['input'] = 0
    for name, value, expected in [('continuous_false_bitmap', wrong_bitmap, 'native_background_mismatch'),
                                  ('continuous_hidden_release', hidden_release, 'input_tape')]:
        result = check_case(value, 240, True)
        codes = {item['code'] for item in result['failures']}
        outcomes.append(dict(name=name, passed=expected in codes, expectedFailure=expected, observedFailures=sorted(codes)))
    vertical_native = check_case(synthetic_continuous_case('native', False, axis='vertical'), 240, True)
    vertical = synthetic_continuous_case('far', False, axis='vertical')
    for name, value, should_fail in [('vertical_equal_progress', vertical, False),
                                    ('vertical_isolated_holds_accumulate', synthetic_continuous_case('far', True, axis='vertical'), True)]:
        result = check_case(value, 240, True)
        _, failures = compare_continuous([vertical_native, result])
        codes = {item['code'] for item in failures}
        outcomes.append(dict(name=name, passed=vertical_native['status'] == result['status'] == 'passed'
                             and (('continuous_progress_loss' in codes and 'continuous_extra_held_poses' in codes)
                                  if should_fail else not codes), observedFailures=sorted(codes)))
    for axis in AXES:
        values = [check_case(synthetic_continuous_case(mode, False, axis=axis, walk=True), 240, True) for mode in ('native', 'far')]
        _, failures = compare_continuous(values)
        outcomes.append(dict(name=axis+'_walking_one_pixel_progress', passed=all(v['status'] == 'passed' for v in values) and not failures))
    for name, mutate, expected in [
            ('vertical_false_y_bitmap', lambda c: c['videoRaw'][30]['nativePixelDiagnostic']['backgroundStrips'].update(previousYMinusCurrentY=6), 'native_background_mismatch'),
            ('vertical_x_bitmap_cannot_substitute', lambda c: c['videoRaw'][30]['nativePixelDiagnostic'].update(backgroundStrips=dict(confident=True, previousXMinusCurrentX=2)), 'native_background_mismatch'),
            ('vertical_horizontal_input', lambda c: c['videoRaw'][30].update(input=34), 'input_tape'),
            ('vertical_hidden_release', lambda c: c['videoRaw'][30].update(input=0), 'input_tape'),
            ('vertical_off_lane', lambda c: c['videoRaw'][30].update(pixelX=586), 'continuous_lane'),
            ('vertical_diagonal_jump', lambda c: c['videoRaw'][30].update(pixelX=586), 'continuous_pixel_jump'),
            ('vertical_encounter_row_endpoint', lambda c: c['raw'][30].update(tileY=23), 'native_endpoint_missing'),
            ('vertical_missing_target', lambda c: c['raw'][30].pop('tileY'), 'continuous_target_tile'),
            ('vertical_encounter_route', lambda c: c['route'].update(bottomTileY=23), 'route_identity'),
            ('vertical_battle_cannot_pass_as_field', lambda c: c['videoRaw'][30].update(status='battle', safeField=0), 'video_field'),
            ('vertical_wrong_trainer_y', lambda c: c['videoRaw'][30]['nativePixelDiagnostic']['trainerTemplate'].update(footY=90), 'native_trainer_mismatch'),
            ('vertical_shifted_trainer', lambda c: c['videoRaw'][30]['nativePixelDiagnostic']['trainerTemplate'].update(footX=122), 'native_trainer_mismatch'),
            ('vertical_overbroad_mask', lambda c: c['videoRaw'][30]['nativePixelDiagnostic']['trainerTemplate'].update(visiblePixels=39, maskedPixels=121, nativeFollowerMaskPixels=121), 'trainer_mask_evidence'),
            ('vertical_fake_mask_counts', lambda c: c['videoRaw'][30]['nativePixelDiagnostic']['trainerTemplate'].update(maskedPixels=10), 'trainer_mask_evidence'),
            ('vertical_false_confident_score', lambda c: c['videoRaw'][30]['nativePixelDiagnostic']['trainerTemplate'].update(matchFraction=.79), 'trainer_mask_evidence'),
            ('vertical_untextured_bitmap_rejected', lambda c: [r['nativePixelDiagnostic']['backgroundStrips'].update(confident=False) for r in c['videoRaw'][30:34]], 'background_confidence'),
            ('vertical_unknown_axis', lambda c: c.update(axis='diagonal'), 'axis_identity'),
            ('vertical_historical_tape', lambda c: c.update(tape='release-run'), 'axis_identity')]:
        value = copy.deepcopy(vertical)
        mutate(value)
        result = check_case(value, 240, True)
        codes = {item['code'] for item in result['failures']}
        outcomes.append(dict(name=name, passed=expected in codes, expectedFailure=expected, observedFailures=sorted(codes)))
    outcomes.append(dict(name='vertical_pavement_endpoint_reverses_at22', passed=
        {r['tileY'] for r in vertical['raw']} == {20,21,22} and
        all(int(r['nextInput']) & 64 for r in vertical['raw'] if r['tileY']==22) and
        all(int(r['nextInput']) & 128 for r in vertical['raw'] if r['tileY']==20)))
    _, failures = compare_continuous([native_result, check_case(vertical, 240, True)])
    outcomes.append(dict(name='vertical_rejects_horizontal_control', passed=any(f['code'] == 'missing_matched_native' for f in failures)))
    raw_native = copy.deepcopy(native)
    raw_native.update(mode='raw-native', name='synthetic-raw-native', nativeFloorDiagnostic=True, endpointControl=ENDPOINT_CONTROL)
    wrapped = copy.deepcopy(native)
    wrapped.update(nativeFloorDiagnostic=True, endpointControl=ENDPOINT_CONTROL)
    for value in (raw_native, wrapped):
        for row in value['raw']:
            row.update(nativeTargetAvailable=1, mapGroup=3, mapNumber=1)
    for row in raw_native['raw']:
        row.pop('guestFlags')
    raw_result = check_case(raw_native, 240, True, native_floor=True)
    wrapped_result = check_case(wrapped, 240, True, native_floor=True)
    values, failures = compare_native_floor([raw_result, wrapped_result])
    outcomes.append(dict(name='native_floor_separately_labeled', passed=raw_result['status'] == wrapped_result['status'] == 'passed'
                         and not failures and len(values) == 1))
    vertical_floor = synthetic_continuous_case('native', False, axis='vertical')
    vertical_floor.update(mode='raw-native', name='vertical-raw-native', nativeFloorDiagnostic=True)
    for row in vertical_floor['raw']:
        row.pop('guestFlags')
    vertical_wrapped = synthetic_continuous_case('native', False, axis='vertical')
    vertical_wrapped['nativeFloorDiagnostic'] = True
    floor_result = check_case(vertical_floor, 240, True, native_floor=True)
    wrap_result = check_case(vertical_wrapped, 240, True, native_floor=True)
    values, failures = compare_native_floor([floor_result, wrap_result])
    outcomes.append(dict(name='vertical_native_floor_separately_labeled', passed=floor_result['status'] == wrap_result['status'] == 'passed'
                         and not failures and len(values) == 1))
    active = copy.deepcopy(slower)
    active.update(nativeFloorDiagnostic=True, endpointControl=ENDPOINT_CONTROL)
    for row in active['raw']:
        row.update(nativeTargetAvailable=1, mapGroup=3, mapNumber=1)
    active_result = check_case(active, 240, True, native_floor=True)
    values, failures = compare_native_floor([raw_result, wrapped_result, active_result])
    _, production_failures = compare_continuous([native_result, active_result])
    outcomes.append(dict(name='native_floor_same_anchor_active_comparison',
                         passed=active_result['status'] == 'passed' and not failures and len(values) == 2
                         and {value['comparedMode'] for value in values} == {'native', 'far'}
                         and all(value['native'] == raw_result['name'] for value in values)
                         and any(value['comparedMode'] == 'far' and value['progressDeficitPixels'] > 2
                                 and value['extraHeldPoses'] > 1 for value in values)
                         and any(failure['code'] == 'continuous_progress_loss' for failure in production_failures)))
    mismatched_phase = dict(active_result, preRollFrames=1)
    _, failures = compare_native_floor([raw_result, wrapped_result, mismatched_phase])
    outcomes.append(dict(name='native_floor_rejects_cross_phase_comparison',
                         passed=any(failure['code'] == 'missing_native_floor_pair' for failure in failures)))
    _, failures = compare_native_floor([raw_result, dict(wrapped_result, axis='vertical')])
    outcomes.append(dict(name='native_floor_rejects_cross_axis_comparison',
                         passed=any(f['code'] == 'missing_native_floor_pair' for f in failures)))
    rejected = check_case(raw_native, 240, True)
    outcomes.append(dict(name='native_floor_cannot_be_candidate',
                         passed=any(f['code'] == 'raw_native_not_candidate' for f in rejected['failures'])))
    missing_target = copy.deepcopy(wrapped)
    missing_target['raw'][30]['nativeTargetAvailable'] = 0
    rejected = check_case(missing_target, 240, True, native_floor=True)
    outcomes.append(dict(name='native_target_cannot_fallback_to_cached_BWO',
                         passed=any(f['code'] == 'native_endpoint_missing' for f in rejected['failures'])))
    fake_admission = copy.deepcopy(raw_native)
    fake_admission['raw'][30]['guestFlags'] = 1
    rejected = check_case(fake_admission, 240, True, native_floor=True)
    outcomes.append(dict(name='native_floor_rejects_fake_BWO',
                         passed=any(f['code'] == 'raw_native_fake_admission' for f in rejected['failures'])))
    # A small synthetic byte array exercises provenance arithmetic only; it
    # is never loaded as a cartridge or accepted by the runtime ROM guard.
    source = bytes(0x56580)
    patched = bytearray(source)
    patches = []
    for offset, native_bytes in NATIVE_ENTRIES.items():
        patches.append(dict(offset=offset, before=base64.b64encode(source[offset:offset+8]).decode(),
                            after=base64.b64encode(native_bytes).decode()))
        patched[offset:offset+8] = native_bytes
    receipt_case = dict(nativeEntryDiagnostic=dict(sourceROM_SHA256=hashlib.sha256(source).hexdigest(),
                        diagnosticROM_SHA256=hashlib.sha256(patched).hexdigest(), patches=patches,
                        normalizedSourceSHA256='1'*64, residentBeforeSHA256='2'*64,
                        residentAfterSHA256='3'*64, pausedNextPC=0x08000600),
                        nativeEntryRestoration=dict(restored=True, wasActive=True, normalizedIdentityRestored=True,
                        normalizedRestoredSHA256='1'*64, residentRestoredSHA256='4'*64))
    for name, changed, expected in [('native_entry_exact_receipt', None, None),
                                    ('native_entry_wrong_hash', 'hash', 'native_entry_identity'),
                                    ('native_entry_not_restored', 'restore', 'native_entry_restoration'),
                                    ('native_entry_prefetch_overlap', 'pc', 'native_entry_pipeline')]:
        value = copy.deepcopy(receipt_case)
        if changed == 'hash': value['nativeEntryDiagnostic']['diagnosticROM_SHA256'] = '0'*64
        if changed == 'restore': value['nativeEntryRestoration']['restored'] = False
        if changed == 'pc': value['nativeEntryDiagnostic']['pausedNextPC'] = 0x080004B2
        failures = []
        verify_native_entry_receipt(value, source, lambda ok, code, detail: failures.append(code) if not ok else None)
        outcomes.append(dict(name=name, passed=not failures if expected is None else expected in failures))
    return outcomes


def synthetic_continuous_case(mode, isolated_holds, axis='horizontal', walk=False):
    """A committed 16px native step model, used only to test checker rejection.

    The negative control never freezes for two consecutive frames. It must
    nevertheless fail because isolated holds reduce sustained progress.
    """
    rows, completed = [], []
    x = target = 584
    mask, direction = 0, 32
    for frame in range(240):
        previous_x = x
        if frame:
            if x == target:
                target += -16 if mask & 32 else 16
            if not isolated_holds or frame % 12:
                x += (-1 if target < x else 1) * (1 if walk else 2)
        tile = (target - 8) // 16
        if tile <= (34 if axis == 'vertical' else 33):
            direction = 16
        elif tile >= 36:
            direction = 32
        next_mask = direction | (0 if walk else 2)
        row = dict(frame=frame, completedFrameIndex=frame, input=mask, time=frame/60,
                   tileX=tile, tileY=20, mapGroup=3, mapNumber=1, pixelX=x, pixelY=336,
                   cameraX=120-x, cameraY=-248, overlayPixels=0, safeField=1, status='live',
                   nativePixelDiagnostic=dict(trainerTemplate=dict(confident=True, footX=120, footY=88),
                                              backgroundStrips=dict(confident=frame>0, previousXMinusCurrentX=x-previous_x)))
        rows.append(row)
        completed.append(dict(frame=frame, input=mask, nextInput=next_mask, time=frame/60,
                              tileX=tile, tileY=20, guestFlags=1 if mode == 'native' else 7, followerActive=1))
        mask = next_mask
    pairs = list(zip(rows, rows[1:]))
    held = [(a,b) for a,b in pairs if int(a['input']) & 48 and int(b['input']) & 48]
    travel = sum(abs(b['pixelX']-a['pixelX']) for a,b in pairs)
    changes = sum(a['tileX'] != b['tileX'] for a,b in pairs)
    result = dict(name='synthetic-'+mode, mode=mode, repeat=1, rate=1, preRollFrames=0,
                tape='continuous-walk' if walk else 'continuous-run', route=dict(ROUTES['horizontal']),
                videoRaw=rows, raw=completed,
                metrics=dict(observationBoundary=BOUNDARY, frames=240, tileTransitions=changes,
                             missingPixelSamples=0, overlayPixelSamples=0, longestHeldInputPixelFreeze=int(isolated_holds),
                             over50ms=0, maxGapMs=1000/60, totalPixelTravel=travel, allHeldPairs=len(held),
                             allHeldPixelHolds=sum(a['pixelX']==b['pixelX'] for a,b in held),
                             directionChanges=sum(a['input']!=b['input'] for a,b in held)),
                completedFrameMetrics=dict(frames=240, remoteBlockedSamples=0, activeFollowerSamples=240,
                                           admittedPortSamples=0 if mode=='native' else 240))
    if axis == 'vertical':
        result.update(axis=axis, route=dict(ROUTES[axis]), endpointControl=ENDPOINT_CONTROL)
        def rotate_mask(mask):
            return (128 if mask & 32 else 64 if mask & 16 else 0) | (mask & 2)
        for row in rows:
            row.update(tileY=56-row['tileX'], tileX=36, pixelY=920-row['pixelX'], pixelX=584,
                       input=rotate_mask(row['input']))
            row.update(cameraX=-464, cameraY=88-row['pixelY'])
            background = row['nativePixelDiagnostic']['backgroundStrips']
            background.update(axis=axis, previousYMinusCurrentY=-background.pop('previousXMinusCurrentX'))
            row['nativePixelDiagnostic']['trainerTemplate'].update(visiblePixels=160,maskedPixels=0,
                opaqueTemplatePixels=160,nativeFollowerMaskPixels=0,matchFraction=1,margin=.25)
        for row in completed:
            row.update(tileY=56-row['tileX'], tileX=36, input=rotate_mask(row['input']),
                       nextInput=rotate_mask(row['nextInput']), nativeTargetAvailable=1, mapGroup=3, mapNumber=1)
    return result


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
    tape = invocation.get('tape', 'release-run')
    axis = invocation.get('axis', 'horizontal')
    native_floor = invocation.get('nativeFloorDiagnostic', False)
    anchor_replay = invocation.get('anchorReplay')
    if anchor_replay is not None and not isinstance(anchor_replay, dict):
        raise ValueError('Anchor replay requires its exact retained verification receipt')
    if type(native_floor) is not bool:
        raise ValueError('Native-floor diagnostic flag must be explicit boolean')
    allowed_modes = ('native', 'far', 'raw-native') if native_floor else ('native', 'far', 'near', 'moving')
    if not (tape in TAPES and axis in AXES and (axis == 'horizontal' or tape != 'release-run')
            and type(frames) is int and 160 <= frames <= 36000
            and (tape != 'release-run' or frames % 40 == 0)
            and type(repeats) is int and 1 <= repeats <= 10
            and isinstance(rates, list) and rates and all(rate in (1, 3) for rate in rates)
            and isinstance(modes, list) and modes and all(mode in allowed_modes for mode in modes)
            and len(set(rates)) == len(rates) and len(set(modes)) == len(modes)
            and type(invocation.get('followerRequested')) is bool):
        raise ValueError('Unsupported invocation matrix: known tape and unique declared modes/rates required; historical tape needs40-frame multiples')
    require(tape == 'release-run' or 'native' in modes, 'native_control', 'Continuous acceptance requires a matched native control')
    if native_floor:
        require(set(modes) in ({'native', 'raw-native'}, {'native', 'far', 'raw-native'})
                and tape != 'release-run', 'native_floor_matrix', modes)
        require(invocation.get('acceptanceScope') == 'native-floor-diagnostic', 'native_floor_scope',
                'A private entry diagnostic cannot establish production acceptance')
    elif anchor_replay is not None:
        require(invocation.get('acceptanceScope') == 'exact-anchor-diagnostic'
                and invocation.get('diagnosticOnly') is True and invocation.get('candidateAcceptance') is False,
                'anchor_diagnostic_scope', 'A retained anchor cannot establish new cold-run candidate acceptance')
        require(anchor_replay.get('diagnosticOnly') is True and anchor_replay.get('candidateAcceptance') is False,
                'anchor_receipt_scope', 'Anchor receipt must retain diagnostic-only scope')
        reference(root / 'verified-anchor.state', anchor_replay.get('anchorSHA256'))
        reference(root / 'verified-anchor.json')
        require(read_json(root / 'verified-anchor.json') == anchor_replay, 'anchor_receipt_identity',
                'Selected anchor receipt differs from retained invocation')
        reference(Path(anchor_replay['originRun']) / 'result.json', anchor_replay.get('originResultSHA256'))
    else:
        require(invocation.get('acceptanceScope', 'production-candidate') == 'production-candidate', 'candidate_scope',
                'Production acceptance cannot consume a native-floor invocation')
    phases = invocation.get('preRollFramesByRepeat', [0] * repeats)
    require(isinstance(phases, list) and len(phases) == repeats
            and all(type(p) is int and 0 <= p <= 600 for p in phases), 'phase_matrix', phases)
    if not isinstance(phases, list) or len(phases) != repeats:
        raise ValueError('Missing complete native pre-roll phase selection')
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
    if native_floor:
        required_sources += ('Delta/Bound/BoundVBABattleBridge.h', 'Delta/Bound/BoundVBABattleBridge.mm')
    require(bool(re.fullmatch(r'[0-9a-f]{40}', receipt.get('head', ''))) and bool(receipt.get('configuration')),
            'source_receipt', 'Build receipt must identify the app source revision and build configuration')
    require(all(SHA256.fullmatch(source_files.get(path, '')) for path in required_sources),
            'source_receipt', 'Build receipt must hash the production movement/presentation sources and actual video test')
    frozen_source = verify_frozen_source(receipt)
    if invocation.get('verifiedFrozenSource') is not None:
        require(invocation['verifiedFrozenSource'] == frozen_source, 'frozen_source_identity',
                'Frozen file verification must match the runner receipt')
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
    require(fixture.get('tape', 'release-run') == tape, 'fixture_tape', 'Fixture must identify the declared input tape')
    require(fixture.get('axis', 'horizontal') == axis, 'fixture_axis', 'Fixture must identify the declared movement axis')
    require(fixture.get('nativeFloorDiagnostic', False) is native_floor, 'fixture_diagnostic_scope', 'Diagnostic labels must agree')
    if anchor_replay is not None:
        require(fixture.get('anchorReplay') == anchor_replay and fixture.get('diagnosticOnly') is True
                and fixture.get('candidateAcceptance') is False
                and fixture.get('anchorSHA256') == anchor_replay.get('anchorSHA256'),
                'anchor_fixture_identity', 'Fixture must retain the selected exact anchor and diagnostic scope')
    else:
        require('anchorReplay' not in fixture, 'unexpected_anchor_replay', 'Ordinary candidate runs require their own cold anchor')
    if native_floor:
        require(fixture.get('endpointControl') == ENDPOINT_CONTROL, 'fixture_native_endpoint', 'Native floor requires the same raw endpoint controller')
    if tape != 'release-run':
        require(fixture.get('pixelDiagnostics') is True, 'bitmap_required', 'Continuous acceptance requires actual native bitmap diagnostics')
        require(fixture.get('route') == ROUTES[axis], 'fixture_route', fixture.get('route'))
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
    diagnostic_source_image = Path(invocation['rom']).read_bytes() if native_floor else None
    for name in sorted(expected.keys() & files.keys()):
        path = files[name]
        reference(path)
        case = read_json(path)
        repeat, mode, rate = expected[name]
        require((case.get('name'), case.get('repeat'), case.get('mode'), case.get('rate'), case.get('romSHA256'))
                == (name, repeat, mode, rate, rom_hash), 'case_identity', name)
        require(case.get('tape', 'release-run') == tape and case.get('preRollFrames', 0) == phases[repeat-1],
                'case_tape_phase', name)
        require(case.get('axis', 'horizontal') == axis, 'case_axis', name)
        require(case.get('endpointControl') == fixture.get('endpointControl'), 'case_endpoint_control', name)
        if anchor_replay is not None:
            require(case.get('diagnosticOnly') is True and case.get('candidateAcceptance') is False
                    and case.get('anchorSHA256') == anchor_replay.get('anchorSHA256'),
                    'anchor_case_scope', name)
        if mode == 'raw-native':
            verify_native_entry_receipt(case, diagnostic_source_image, require)
        else:
            require('nativeEntryDiagnostic' not in case and 'nativeEntryRestoration' not in case,
                    'unexpected_native_ablation', name)
        reduced = {key: value for key, value in case.items() if key not in ('raw', 'videoRaw')}
        require(sum(item == reduced for item in summaries) == 1, 'summary_case_mismatch', name)
        cases.append(check_case(case, frames, invocation['followerRequested'], native_floor=native_floor))
    comparisons, diagnostic_comparisons = [], []
    if native_floor:
        diagnostic_comparisons, diagnostic_failures = compare_native_floor(cases)
        failures.extend(diagnostic_failures)
    elif tape != 'release-run':
        comparisons, paired_failures = compare_continuous(cases)
        failures.extend(paired_failures)
        for case in cases:
            extra = [f for f in paired_failures if isinstance(f['detail'], dict) and f['detail'].get('active') == case['name']]
            if extra:
                case['failures'].extend(extra)
                case['status'] = 'failed'
    return dict(status='failed' if failures or any(case['status'] != 'passed' for case in cases) else 'passed',
                acceptanceScope=('native-floor-diagnostic' if native_floor else
                                 'exact-anchor-diagnostic' if anchor_replay is not None else 'production-candidate'),
                candidateAcceptance=not native_floor and anchor_replay is None and any(mode != 'native' for mode in modes)
                                    and not failures and all(case['status'] == 'passed' for case in cases),
                input=str(input_path), runnerOutput=str(root), romSHA256=rom_hash,
                matrix=dict(frames=frames, repeats=repeats, rates=rates, modes=modes, expectedCases=len(expected),
                            tape=tape, axis=axis, preRollFramesByRepeat=phases),
                thresholds=(dict(minimumBitmapConfidence=.99, maxCallbackGapMs=50, missingVideoSamples=0, overlayPixels=0,
                                 performanceComparison='Descriptive only; private native floor cannot pass candidate acceptance') if native_floor else
                            dict(transitionsPer40Frames=3, maxHeldTileIntervalFrames=9,
                                 maxHeldPixelFreezeFrames=1, maxCallbackGapMs=50, missingVideoSamples=0, overlayPixels=0)
                            if tape == 'release-run' else
                            dict(maxProgressLossPixels=2, maxCumulativeLossPixels=2, maxExtraHeldPoses=1,
                                 maxConsecutiveHolds='Matched native control', minimumBitmapConfidence=.99,
                                 maxCallbackGapMs=50, missingVideoSamples=0, overlayPixels=0)),
                matchedComparisons=comparisons, checkerSourceSHA256=digest(Path(__file__).resolve()),
                diagnosticComparisons=diagnostic_comparisons,
                sourceReceipt=receipt_ref,
                sourceProvenance=dict(appSource=receipt.get('sourceRoot', invocation['appSource']), appBaseCommit=receipt['head'],
                                      launchAppCheckout=invocation['appSource'], launchAppCommit=invocation['appCommit'],
                                      verifiedFrozenSource=frozen_source,
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
