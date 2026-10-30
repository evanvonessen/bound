#!/usr/bin/env python3
"""Negative controls for the full-host movement acceptance gate."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('host_cadence', Path(__file__).with_name('verify-host-movement-cadence.py'))
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class HostCadenceGateTests(unittest.TestCase):
    def setUp(self):
        self.frames = list(range(1, 121))
        self.events = []
        for frame in self.frames:
            for stage in ('frame.begin', 'video.process', 'render.request', 'render.accept',
                          'render.handoff', 'view.input', 'view.metal.commit',
                          'view.metal.presentCommandCompleted'):
                self.events.append(dict(frame=frame, stage=stage, time=frame / 60,
                                        detail=9 if stage.startswith('view.') else 0,
                                        value=4 if stage.endswith('Completed') else 1))

    def accepted(self, events, rate=1):
        return host.render_delivery(events, self.frames, rate)['passed']

    def test_complete_metal_and_gl_delivery(self):
        self.assertTrue(self.accepted(self.events))
        gl = [dict(event, stage='view.gl.draw') if event['stage'] == 'view.metal.commit' else event
              for event in self.events if event['stage'] != 'view.metal.presentCommandCompleted']
        self.assertTrue(self.accepted(gl))

    def test_one_missing_stage_fails_even_with_high_aggregate_coverage(self):
        for stage in {event['stage'] for event in self.events}:
            with self.subTest(stage=stage):
                self.assertFalse(self.accepted([event for event in self.events
                                                if not (event['frame'] == 100 and event['stage'] == stage)]))

    def test_actual_render_drops_and_failed_command_are_rejected(self):
        for stage in ('render.busyDrop', 'view.layoutDrop', 'view.metal.unavailable'):
            with self.subTest(stage=stage):
                self.assertFalse(self.accepted(self.events + [dict(frame=100, stage=stage, detail=9, value=0)]))
        events = copy.deepcopy(self.events)
        next(event for event in events if event['frame'] == 100
             and event['stage'] == 'view.metal.presentCommandCompleted')['value'] = 5
        self.assertFalse(self.accepted(events))

    def test_fast_forward_selection_does_not_excuse_normal_speed_skips(self):
        events = copy.deepcopy([event for event in self.events
                                if event['frame'] % 3 == 0 or event['stage'] in ('frame.begin', 'video.process')])
        for event in events:
            if event['stage'] == 'frame.begin' and event['frame'] % 3:
                event['value'] = 0
        self.assertTrue(self.accepted(events, rate=3))
        self.assertFalse(self.accepted(events, rate=1))
        sparse = [event for event in events if event['frame'] == 99 or event['stage'] in ('frame.begin', 'video.process')]
        for event in sparse:
            if event['stage'] == 'frame.begin' and event['frame'] != 99:
                event['value'] = 0
        self.assertFalse(self.accepted(sparse, rate=3), 'One complete draw cannot hide sparse3x rendering')

    def test_fast_forward_requires_each_native_process_without_extra_rendering(self):
        events = copy.deepcopy([event for event in self.events
                                if event['frame'] % 3 == 0 or event['stage'] in ('frame.begin', 'video.process')])
        for event in events:
            if event['stage'] == 'frame.begin':
                event['value'] = int(event['frame'] % 3 == 0)
        self.assertTrue(self.accepted(events, rate=3))
        for frame in (99, 100):
            process = next(event for event in events if event['frame'] == frame and event['stage'] == 'video.process')
            with self.subTest(frame=frame):
                self.assertFalse(self.accepted([event for event in events if event is not process], rate=3))
                self.assertFalse(self.accepted(events + [process], rate=3))
        for stage in ('render.request', 'render.accept', 'render.handoff'):
            self.assertFalse(self.accepted(events + [dict(frame=100, stage=stage, detail=0, value=0)], rate=3))

    def test_one_late_authority_withdrawal_is_rejected(self):
        events = []
        for frame in self.frames:
            for stage, value, detail in (('reader.result.live', 1, 0), ('probe.cachedGuest', 0, 7),
                                         ('probe.hostInput', 0, 0), ('native.rawWorldFlags', 7, 2)):
                events.append(dict(frame=frame, stage=stage, value=value, detail=detail))
        self.assertTrue(host.sustained_authority(events, self.frames, 'peer')['passed'])
        next(event for event in events if event['frame'] == 119
             and event['stage'] == 'probe.cachedGuest')['detail'] = 1
        self.assertFalse(host.sustained_authority(events, self.frames, 'peer')['passed'])

    def test_soul_policy_requires_one_installed_even_receipt_every_frame(self):
        events = [dict(stage='qa.soulPolicy', frame=frame, value=13, detail=2) for frame in self.frames]
        accepted = lambda rows: host.sustained_soul_policy(rows, self.frames, True)['passed']
        self.assertTrue(accepted(events))
        self.assertFalse(accepted(events[:-1]))
        self.assertFalse(accepted(events + [events[-1]]))
        for flags, sequence in ((0, 0), (12, 2), (9, 2), (5, 2), (15, 2), (13, 0), (13, 3), (13.5, 2), (13, -2), (13, 2**32)):
            with self.subTest(flags=flags, sequence=sequence):
                broken = copy.deepcopy(events)
                broken[-1].update(value=flags, detail=sequence)
                self.assertFalse(accepted(broken))
        startup = copy.deepcopy(events)
        startup[59].update(value=0, detail=0)
        self.assertTrue(accepted(startup))
        startup[60].update(value=0, detail=0)
        self.assertFalse(accepted(startup))

    def test_soul_off_does_not_accept_hook_or_stale_policy(self):
        events = [dict(stage='qa.soulPolicy', frame=frame, value=2, detail=0) for frame in self.frames]
        accepted = lambda rows: host.sustained_soul_policy(rows, self.frames, False)['passed']
        self.assertTrue(accepted(events), 'An inert resident body is not an installed policy')
        for flags, sequence in ((1, 0), (4, 0), (8, 0), (0, 2), (13, 2)):
            with self.subTest(flags=flags, sequence=sequence):
                broken = copy.deepcopy(events)
                broken[-1].update(value=flags, detail=sequence)
                self.assertFalse(accepted(broken))

    def test_routine_field_fence_rejects_one_blocked_missing_or_duplicate_row(self):
        events = [dict(stage='qa.soulFence.' + phase, frame=frame, value=0)
                  for frame in self.frames for phase in ('beforeOwner', 'afterOwner')]
        accepted = lambda rows: host.sustained_soul_fence(rows, self.frames)['passed']
        self.assertTrue(accepted(events))
        for phase in ('beforeOwner', 'afterOwner'):
            index = next(i for i, row in enumerate(events)
                         if row['frame'] == 119 and row['stage'].endswith(phase))
            blocked = copy.deepcopy(events)
            blocked[index]['value'] = 1
            self.assertFalse(accepted(blocked))
            self.assertFalse(accepted(events[:index] + events[index+1:]))
            self.assertFalse(accepted(events + [events[index]]))

    def test_fainted_fixture_requires_native_ack_and_retained_durable_notice(self):
        identifier = '11111111-2222-3333-4444-555555555555'
        proof = dict(id=identifier, sawActive=True, sawNativeAcknowledgment=True,
                     announced=True, deathAndRecordsRetained=True, nativeAPresses=2)
        summary = dict(faintedPartyRequested=True, mode='peer')
        ledger = dict(dead=['001:0'], battleLosses=dict(notices=[dict(id=identifier, slots=['001:0'], announced=True)]))
        def check(value=proof, data=ledger):
            with patch.object(Path, 'read_text', return_value=json.dumps(value)):
                return host.verify_death_notice_setup(summary, dict(deathNoticeSetup=value), data, Path('/qa'))
        self.assertEqual(check(), proof)
        for key in ('sawActive', 'sawNativeAcknowledgment', 'announced', 'deathAndRecordsRetained'):
            with self.assertRaises(ValueError):
                check(dict(proof, **{key:False}))
        for data in (dict(ledger, dead=[]), dict(ledger, battleLosses=dict(notices=[])),
                     dict(ledger, battleLosses=dict(notices=[dict(id=identifier, slots=['001:0'], announced=False)]))):
            with self.assertRaises(ValueError):
                check(data=data)

    def test_native_variants_require_every_post_startup_observation(self):
        events = copy.deepcopy(self.events)
        for frame in self.frames:
            for stage, value, detail in (('qa.input', 34, 34), ('native.tileX', 36, 0),
                                         ('native.tileY', 20, 0), ('native.map', 3, 1),
                                         ('native.rawWorldFrame', frame, 2), ('native.followerActive', 1, 0)):
                events.append(dict(stage=stage, frame=frame, value=value, detail=detail, time=frame/60))
        for stage in ('owner.romService', 'owner.movement', 'owner.world', 'owner.reader',
                      'owner.cooperative', 'owner.soul', 'owner.battle'):
            events.append(dict(stage=stage, frame=1, value=0, detail=0, time=1/60))
        events.append(dict(stage='qa.measureEnd', frame=120, value=0, detail=0, time=2))
        def check(rows, expected, fainted=False, axis='horizontal', peer='A', mode='off'):
            with patch.object(Path, 'read_text', return_value=json.dumps(rows)):
                return host.trace_window(Path('synthetic-host-events.json'), 120, peer, mode, follower=expected, fainted_party=fainted, axis=axis)
        check(events, True)
        vertical = [dict(row,value=20+row['frame']%3) if row['stage']=='native.tileY' else row for row in events]
        self.assertEqual(check(vertical,True,axis='vertical')['expectedNativeY'],[20,22])
        with self.assertRaises(RuntimeError):check(vertical,True)
        with self.assertRaises(RuntimeError):check(vertical,True,axis='diagonal')
        for stage,value in (('native.tileY',23),('native.tileY',21.5),('native.tileX',35)):
            invalid=copy.deepcopy(vertical)
            next(row for row in invalid if row['stage']==stage and row['frame']==119)['value']=value
            with self.assertRaises(RuntimeError):check(invalid,True,axis='vertical')
        stationary=[dict(row,value=24) if row['stage']=='native.tileY' else row for row in events]
        self.assertEqual(check(stationary,True,axis='vertical',peer='B',mode='peer')['expectedNativeY'],[24,24])
        off = [dict(row, value=0) if row['stage'] == 'native.followerActive' else row for row in events]
        check(off, False)
        for rows, expected in ((events, False), (off, True),
                               ([row for row in events if not (row['stage'] == 'native.followerActive' and row['frame'] == 119)], True),
                               (events + [next(row for row in events if row['stage'] == 'native.followerActive' and row['frame'] == 119)], True)):
            with self.assertRaises(RuntimeError):
                check(rows, expected)
        party = events + [dict(stage='qa.faintedParty', frame=frame, value=2, detail=1, time=frame/60)
                          for frame in self.frames]
        check(party, True, True)
        target = next(i for i, row in enumerate(party) if row['stage'] == 'qa.faintedParty' and row['frame'] == 119)
        for count, hp in ((1, 1), (2, 0), (2, 0x10001), (2, -1), (2, 1.5)):
            broken = copy.deepcopy(party)
            broken[target].update(value=count, detail=hp)
            with self.assertRaises(RuntimeError):
                check(broken, True, True)
        for broken in (party[:target]+party[target+1:], party+[party[target]]):
            with self.assertRaises(RuntimeError):
                check(broken, True, True)


class SceneDiagnosticGateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='scene-gate-', dir=host.ARTIFACTS)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.context = self.root / 'scene-diagnostics'
        self.context.mkdir()
        self.sha = 'a' * 64
        self.manifest = dict(schema=1, sourceROM_SHA256=self.sha, observedFailures=0,
                             capturedCount=0, droppedFailures=0, files={})

    def check(self, enabled=True, summary=None):
        (self.context / 'manifest.json').write_text(json.dumps(self.manifest))
        return host.verify_scene_diagnostics(summary or {'sceneDiagnostics': True}, self.root,
                                             enabled, self.sha, 3600)

    def add_capture(self):
        directory = self.context / 'failure-0'
        directory.mkdir()
        for name, data in [('workRAM.bin', bytes(0x40000)), ('internalRAM.bin', bytes(0x8000)),
                           ('paletteRAM.bin', bytes(0x400)), ('decision.json', json.dumps(dict(
                               schema=1, videoFrame=100, status='live', sourceROM_SHA256=self.sha)).encode())]:
            path = directory / name
            path.write_bytes(data)
            self.manifest['files']['failure-0/' + name] = dict(bytes=len(data), sha256=host.digest(path))
        self.manifest.update(observedFailures=1, capturedCount=1)

    def test_zero_and_complete_capture_are_diagnostic_only(self):
        self.assertFalse(self.check()['candidateAcceptance'])
        self.add_capture()
        self.assertEqual(self.check()['capturedCount'], 1)
        self.assertTrue(self.check()['diagnosticOnly'])

    def test_wrong_identity_and_capture_counts_fail(self):
        for key, value in [('sourceROM_SHA256', 'b' * 64), ('schema', 2), ('capturedCount', 1),
                           ('observedFailures', 3541), ('droppedFailures', 1), ('observedFailures', True)]:
            original = self.manifest[key]
            self.manifest[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.check()
            self.manifest[key] = original

    def test_missing_extra_or_changed_capture_fails(self):
        self.add_capture()
        files = copy.deepcopy(self.manifest['files'])
        self.manifest['files'].pop('failure-0/decision.json')
        with self.assertRaises(ValueError): self.check()
        self.manifest['files'] = files
        self.manifest['files']['../outside.json'] = dict(bytes=2, sha256='b' * 64)
        with self.assertRaises(ValueError): self.check()
        self.manifest['files'].pop('../outside.json')
        (self.context / 'failure-0/paletteRAM.bin').write_bytes(bytes(0x3ff) + b'\x01')
        with self.assertRaises(ValueError): self.check()

    def test_instrumentation_cannot_be_hidden_or_omitted(self):
        with self.assertRaises(ValueError): self.check(enabled=False)
        with self.assertRaises(ValueError): self.check(summary={'sceneDiagnostics': False})
        self.assertEqual(host.verify_scene_diagnostics({}, self.root, False, self.sha, 3600), {'enabled': False})

    def test_rehashed_outside_window_or_wrong_status_decision_fails(self):
        self.add_capture()
        path = self.context / 'failure-0/decision.json'
        original = json.loads(path.read_text())
        for key, value in [('videoFrame', 60), ('videoFrame', 3601), ('videoFrame', True),
                           ('status', 'waiting'), ('sourceROM_SHA256', 'b' * 64)]:
            path.write_text(json.dumps(dict(original, **{key: value})))
            self.manifest['files']['failure-0/decision.json'] = dict(bytes=path.stat().st_size, sha256=host.digest(path))
            with self.subTest(key=key, value=value), self.assertRaises(ValueError): self.check()


if __name__ == '__main__':
    unittest.main()
