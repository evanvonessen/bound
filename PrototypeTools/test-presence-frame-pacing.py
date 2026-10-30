#!/usr/bin/env python3
"""Exercise the production presence interpolator against independent frame/UI clocks.

Only platform/ROM data types are substituted. This deterministic timing check is
not native gameplay, screen presentation, or WAN performance evidence.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--require-frame-clock', action='store_true')
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
source = (ROOT / 'Delta/Bound/BoundLivePresence.swift').read_text()
display = (ROOT / 'Delta/Bound/BoundPlayerStateDisplay.swift').read_text()
fixed = 'struct BoundPresencePresentationSnapshot: Sendable' in source
cadence_fixed = 'struct BoundPresencePublicationCadence: Sendable' in source
if cadence_fixed:
    cadence = source[source.index('struct BoundPresencePublicationCadence: Sendable'):source.index('struct BoundPresencePresentationSample:')]
else:
    assert 'lastSent.map({ now - $0 >= Self.interval - 0.0001 }) ?? true' in source
    cadence = '''
struct BoundPresencePublicationCadence {
    static let interval: TimeInterval = 0.05
    private var lastSent: TimeInterval?
    mutating func reset() { lastSent = nil }
    mutating func admit(at now: TimeInterval, force: Bool = false) -> Bool {
        guard force || lastSent.map({ now - $0 >= Self.interval - 0.0001 }) ?? true else { return false }
        lastSent = now
        return true
    }
}
'''
if fixed:
    model = source[source.index('struct BoundPresencePresentationSample:'):source.index('/// Main-actor, bounded receive buffer')]
else:
    sample = source[source.index('    private struct Sample {'):source.index('    private var samples: [Sample]')]
    sample = sample.replace('private struct Sample', 'struct BoundPresencePresentationSample')
    pose = source[source.index('    func pose(at now:'):source.index('    func collision(at now:')]
    comparable = source[source.index('    private func comparable('):source.index('    private func updateStatus()')]
    model = sample + '''
struct BoundPresencePresentationSnapshot {
    static let timeout: TimeInterval = 0.75
    static let visibilityGrace: TimeInterval = 60
    let needsReader: Bool, enabled: Bool, romVerified: Bool
    let lastPoseReceived: TimeInterval?, clockOffset: TimeInterval?
    let samples: [BoundPresencePresentationSample]
    let retainedPose: BoundPresencePose?, retainedAt: TimeInterval?
    let sceneProfile: BoundPlayerROMProfile?
''' + pose + comparable + '\n}\n'

stubs = r'''
import Foundation
struct Point: Sendable { var x: Int, y: Int }
struct BoundPresenceFollower: Sendable {
    var identity: UInt64 = 42
    var x: Double, y: Double
    var current = Point(x: 0, y: 0), previous = Point(x: 0, y: 0)
}
struct BoundPresencePose: Sendable {
    var mapGroup = 4, mapNumber = 3, elevation = 0
    var mapInstance: UInt64? = 1
    var x: Double, y: Double = 112
    var follower: BoundPresenceFollower?
    var passing: Bool? = nil
}
final class BoundPlayerROMProfile: @unchecked Sendable {
    let sceneAssets = Assets()
    func bytes(at: Int, count: Int) -> [UInt8]? { nil }
}
final class Assets: @unchecked Sendable {
    func mapOffset(fromGroup: Int, number: Int, toGroup: Int, number other: Int,
                   rom: (Int, Int) -> [UInt8]?) -> Point? { nil }
}
'''
checks = r'''
func timeline(at now: Double) -> BoundPresencePresentationSnapshot {
    let last = max(0, Int(floor((now - 20 + 1e-9) / 0.05)))
    let samples = (max(0, last - 7)...last).map { index in
        let pose = BoundPresencePose(x: 104 + Double(index) * 8,
            follower: .init(x: 88 + Double(index) * 8, y: 112))
        return BoundPresencePresentationSample(time: 10 + Double(index) * 0.05,
            pose: pose, followerPresentation: pose.follower)
    }
    return .init(needsReader: true, enabled: true, romVerified: true,
        lastPoseReceived: 20 + Double(last) * 0.05, clockOffset: 10, samples: samples,
        retainedPose: samples.last!.presentation, retainedAt: 20 + Double(last) * 0.05,
        sceneProfile: nil)
}
var results: [[String: Any]] = []
for hz in [60, 180] {
    for phase in [0.001, 0.004, 0.009] {
        var ticks: [Double] = []
        for tick in 0..<1000 {
            let jitter: Double = tick % 2 == 0 ? -0.004 : 0.004
            let time = 20.0 + Double(tick) / 60.0 + phase + jitter
            if time >= 20 { ticks.append(time) }
        }
        var nextTick = 0, snapshot = timeline(at: 20), held = snapshot.pose(at: 20)!
        var before: [Double] = [], after: [Double] = [], followers: [Double] = []
        for frame in hz..<(hz * 5) {
            let now = 20 + Double(frame) / Double(hz)
            while nextTick < ticks.count, ticks[nextTick] <= now {
                let tick = ticks[nextTick]
                snapshot = timeline(at: tick)
                held = snapshot.pose(at: tick)!
                nextTick += 1
            }
            let pose = snapshot.pose(at: now)!
            before.append(held.x); after.append(pose.x); followers.append(pose.follower!.x)
        }
        func deltas(_ values: [Double]) -> [Double] { zip(values, values.dropFirst()).map { $1 - $0 } }
        let old = deltas(before), new = deltas(after), follower = deltas(followers), expected = 160 / Double(hz)
        precondition(new.allSatisfy { abs($0 - expected) < 1e-8 }, "Frame sampler must preserve constant velocity")
        precondition(follower.allSatisfy { abs($0 - expected) < 1e-8 }, "Follower must share trainer's frame clock")
        precondition(old.contains { abs($0 - expected) > 0.5 }, "Old held-pose path must reproduce uneven movement")
        results.append(["frameHz": hz, "mainPhase": phase, "frames": after.count,
            "heldPoseRepeatedFrames": old.filter { abs($0) < 1e-8 }.count,
            "heldPoseLargestPixelStep": old.max()!, "frameClockRepeatedFrames": new.filter { abs($0) < 1e-8 }.count,
            "frameClockLargestPixelStep": new.max()!, "expectedPixelStep": expected])
    }
}
let frozen = timeline(at: 21)
precondition(frozen.pose(at: 21.4)!.x == frozen.samples.last!.pose.x, "No extrapolation beyond confirmed samples")
precondition(frozen.pose(at: 21.8)!.x == frozen.retainedPose!.x, "Retained presentation remains available")
precondition(frozen.pose(at: 81) == nil, "Snapshot cannot extend retained-pose lifetime")
var cadenceResults: [[String: Any]] = []
var boundary = BoundPresencePublicationCadence()
precondition(boundary.admit(at: 10))
precondition(boundary.admit(at: 10.09995))
precondition(!boundary.admit(at: 10.09995), "A missed slot inside the admission tolerance must not produce a same-time burst")
precondition(!boundary.admit(at: 10.10))
precondition(boundary.admit(at: 10.15))
for jitter in [0.0004, 0.004] {
    var cadence = BoundPresencePublicationCadence(), sends: [Double] = []
    for tick in 0..<1200 {
        let time = 20.0 + Double(tick) / 60.0 + (tick % 2 == 0 ? -jitter : jitter)
        if cadence.admit(at: time) { sends.append(time) }
    }
    let gaps = zip(sends, sends.dropFirst()).map { $1 - $0 }
    precondition(gaps.allSatisfy { $0 >= 0.04 }, "Tick jitter must not generate publication bursts")
    precondition(cadence.admit(at: 45), "Resume after a gap sends one fresh sample")
    precondition(!cadence.admit(at: 45), "Never catch up old samples in bursts")
    precondition(cadence.admit(at: 45.01, force: true), "A withdrawal bypasses cadence")
    precondition(!cadence.admit(at: 45.011), "Forced send owns the next interval")
    cadence.reset(); precondition(cadence.admit(at: 45.012), "New session starts immediately")
    cadenceResults.append(["jitterSeconds": jitter, "sent": sends.count, "expected": 400,
        "smallestGap": gaps.min()!, "largestGap": gaps.max()!])
}
let encoded = try JSONSerialization.data(withJSONObject: ["cases": results, "cadence": cadenceResults, "passed": true], options: [.prettyPrinted, .sortedKeys])
print(String(decoding: encoded, as: UTF8.self))
'''
main = out / 'main.swift'
main.write_text(stubs + cadence + model + checks)
binary = out / 'presence-frame-pacing'
compiled = subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(out / 'modules'),
                           str(main), '-o', str(binary)], capture_output=True, text=True)
(out / 'compile.log').write_text(compiled.stdout + compiled.stderr)
compiled.check_returncode()
run = subprocess.run([str(binary)], capture_output=True, text=True)
(out / 'timing.log').write_text(run.stdout + run.stderr)
run.check_returncode()
report = json.loads(run.stdout)
report.update(sourceSHA256=hashlib.sha256(source.encode()).hexdigest(),
              productionFrameClock=fixed and 'presentation?.pose(at: ProcessInfo.processInfo.systemUptime)' in display,
              productionAnchoredPublication=cadence_fixed,
              limits='Source interpolator with controlled scheduling and substitute data types; no native gameplay, displayed-frame, device or WAN proof.')
(out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
if args.require_frame_clock and not report['productionFrameClock']:
    raise SystemExit('Production compositor still samples a held main-thread pose')
if args.require_frame_clock and (not cadence_fixed or any(case['sent'] != case['expected'] for case in report['cadence'])):
    raise SystemExit('Production presence publisher loses slots under clock jitter')
