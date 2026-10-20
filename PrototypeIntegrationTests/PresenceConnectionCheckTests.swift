import XCTest
import UIKit
@testable import Delta

@MainActor private final class ConnectionCheckTransport: FriendSharingTransport {
    var publishedFrames = 0
    var receivedFrames = 0
    var starts = 0
    var sends = 0
    var renewals = 0
    var diagnostics: [String: Any] { ["token": "fixture-secret-token", "channel": "fixture-secret-room", "uid": 987654] }
    var presenceConnectionCheck: BoundPresenceTransportCheck {
        .init(kind: .fixture, streamCreated: false, createResult: nil, sendResult: nil, acceptedSends: sends, receivedMessages: 0)
    }
    func sendPresence(_ data: Data) -> Bool { sends += 1; return true }
    func start(configuration: FriendSharingConfiguration, remoteView: UIView,
               event: @escaping @MainActor (FriendSharingEvent) -> Void) { starts += 1; event(.joined) }
    func stop() {}
    func renewToken(_ token: String) -> Bool { renewals += 1; return true }
    func recordRecoveryTimeout() {}
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        completion(.success(())); return CheckCancellation()
    }
}
@MainActor private final class CheckCancellation: SharingCancellation { func cancel() {} }

@MainActor final class PresenceConnectionCheckTests: XCTestCase {
    func testOffDoesNoSamplingAndRecordingBoundsRateDurationAndResourceProbes() throws {
        var now = 10.0, snapshots = 0, probes = 0
        let check = BoundPresenceConnectionCheck(clock: { now }, residentMemory: { probes += 1; return 1234 })
        check.snapshot = { snapshots += 1; return .init() }
        check.capture(); XCTAssertEqual(snapshots, 0); XCTAssertEqual(probes, 0)
        check.start(schedule: false)
        for _ in 0..<100 { check.capture() }
        XCTAssertEqual(check.sampleCount, 1); XCTAssertEqual(probes, 1)
        for second in 1...1200 { now = 10 + Double(second); check.capture() }
        XCTAssertEqual(check.sampleCount, 900); XCTAssertEqual(probes, 900); XCTAssertFalse(check.recording)
        let data = try check.export()
        XCTAssertLessThan(data.count, 2_000_000)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(value["schema"] as? Int, 1)
        let samples = try XCTUnwrap(value["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.first?["elapsed"] as? Int, 0); XCTAssertEqual(samples.last?["elapsed"] as? Int, 899)
        XCTAssertEqual(samples.last?["residentBytes"] as? Int, 1234)
        check.clear(); XCTAssertTrue(check.samples.isEmpty); XCTAssertEqual(check.sampleCount, 0)
        now = 10; check.start(schedule: false); now = 1000; check.capture()
        XCTAssertEqual(check.sampleCount, 1); XCTAssertFalse(check.recording, "Background gaps must not extend the recording past 15 minutes")
    }

    func testMissingOwnerStopsRecordingAndClockRegressionCannotGrowSamples() {
        var now = 10.0
        let check = BoundPresenceConnectionCheck(clock: { now }, residentMemory: { nil })
        check.snapshot = { .init() }; check.start(schedule: false)
        now = 9; check.capture(); XCTAssertEqual(check.sampleCount, 1)
        now = 11; check.snapshot = nil; check.capture()
        XCTAssertFalse(check.recording); XCTAssertEqual(check.sampleCount, 1)
    }

    func testExportWhitelistAndStartingCheckCannotStartSharingRenewOrEnableRAMCapture() throws {
        let transport = ConnectionCheckTransport()
        let sharing = FriendSharingSession(configuration: .init(appID: String(repeating: "a", count: 32),
            channel: "fixture-secret-room", uid: 987654, remoteUID: 987655, token: "fixture-secret-token"),
            transport: transport, authenticatedMode: false)
        let presence = sharing.livePresence, check = presence.connectionCheck
        check.start(schedule: false)
        XCTAssertFalse(sharing.active); XCTAssertFalse(presence.enabled); XCTAssertFalse(presence.needsReader)
        XCTAssertEqual(transport.starts, 0); XCTAssertEqual(transport.sends, 0); XCTAssertEqual(transport.renewals, 0)
        let data = try check.export(), string = try XCTUnwrap(String(data: data, encoding: .utf8))
        for secret in ["fixture-secret-token", "fixture-secret-room", "987654", "987655", String(repeating: "a", count: 32)] {
            XCTAssertFalse(string.contains(secret))
        }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["schema", "appVersion", "appBuild", "qaInstall", "runtime", "sampleIntervalSeconds", "limitSamples", "samples"])
        XCTAssertEqual(root["runtime"] as? String, "simulator")
        XCTAssertFalse(string.contains("coordinates")); XCTAssertFalse(string.contains("palette")); XCTAssertFalse(string.contains("frameAddress"))
        sharing.start(); XCTAssertEqual(transport.starts, 1)
        XCTAssertFalse(presence.enabled); XCTAssertFalse(presence.needsReader)
        check.stop(); XCTAssertTrue(sharing.active, "Stopping a report must not stop current sharing")
        XCTAssertEqual(transport.sends, 0); sharing.stop()
    }
}
