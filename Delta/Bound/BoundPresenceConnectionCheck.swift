import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Darwin

/// A whitelist of numeric SDK observations, never the SDK's configuration,
/// channel, UID, token, video geometry, image or diagnostic dictionary.
struct BoundPresenceTransportCheck: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case agora, fixture, unavailable }
    var kind = Kind.unavailable
    var streamCreated = false
    var createResult: Int?
    var sendResult: Int?
    var acceptedSends = 0
    var receivedMessages = 0
}

struct BoundPresenceReaderCheck: Codable, Equatable, Sendable {
    var romVerified = false
    var status = "waiting"
    var localPoseFresh = false
    var peerConfirmed = false
    var peerPoseAvailable = false
    var mapMatches: Bool?
    var elevationMatches: Bool?
    var frameResolved = false
    var visiblePixels = 0
    var renderedTicks = 0
    var movementChanges = 0
    var facingChanges = 0
    var animationChanges = 0
    var sent = 0
    var received = 0
    var rejected = 0
    var buffered = 0
    var lastReceiveAgeMS: Int?
}

struct BoundPresenceConnectionSample: Codable, Equatable, Sendable {
    var elapsed: Double = 0
    var authenticated = false
    var authorizationReady = false
    var active = false
    var joined = false
    var reconnecting = false
    var tokenRenewals = 0
    var reconnectCompletions = 0
    var videoAcceptedSends = 0
    var videoReceivedFrames = 0
    var transport = BoundPresenceTransportCheck()
    var reader = BoundPresenceReaderCheck()
    var residentBytes: UInt64?
    var thermalState: Int?
}

struct BoundPresenceConnectionReport: Encodable, Sendable {
    let schema = 1
    let appVersion: String
    let appBuild: String
    let qaInstall: Bool
    let runtime: String
    let sourceRevision: String?
    let sourceDirty: Bool?
    let sampleIntervalSeconds = 1
    let limitSamples: Int
    let samples: [BoundPresenceConnectionSample]
}

/// Explicitly opt-in. No disk or console I/O, no network calls, no reader
/// demand changes. Retains at most 900 one-second samples, then stops.
@MainActor
final class BoundPresenceConnectionCheck: ObservableObject {
    static let maximumSamples = 900
    @Published private(set) var recording = false
    @Published private(set) var sampleCount = 0
    private(set) var samples: [BoundPresenceConnectionSample] = []
    var snapshot: (() -> BoundPresenceConnectionSample?)?
    private let clock: () -> TimeInterval
    private let residentMemory: () -> UInt64?
    private var startedAt: TimeInterval?
    private var lastSampleAt: TimeInterval?
    private var timer: Timer?

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         residentMemory: (() -> UInt64?)? = nil) {
        self.clock = clock; self.residentMemory = residentMemory ?? Self.residentBytes
    }
    deinit { timer?.invalidate() }

    func start(schedule: Bool = true) {
        stop(); samples.removeAll(keepingCapacity: true); sampleCount = 0
        startedAt = clock(); lastSampleAt = nil; recording = true
        capture()
        guard schedule, recording else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil; recording = false }
    func clear() { stop(); samples.removeAll(keepingCapacity: true); sampleCount = 0 }

    func capture() {
        guard recording, let startedAt else { return }
        let now = clock()
        if now - startedAt >= Double(Self.maximumSamples) { stop(); return }
        guard now.isFinite, now >= startedAt,
              lastSampleAt.map({ now - $0 >= 1 - 0.0001 }) ?? true else { return }
        guard var sample = snapshot?() else { stop(); return }
        sample.elapsed = (now - startedAt).rounded(.down)
        sample.residentBytes = residentMemory()
        sample.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        samples.append(sample); sampleCount = samples.count; lastSampleAt = now
        if samples.count >= Self.maximumSamples { stop() }
    }

    func export() throws -> Data {
        let info = Bundle.main.infoDictionary ?? [:]
        #if targetEnvironment(simulator)
        let runtime = "simulator"
        #else
        let runtime = "device"
        #endif
        let revision = (info["BoundPresenceSourceRevision"] as? String).flatMap {
            $0.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil ? $0 : nil
        }
        let report = BoundPresenceConnectionReport(appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info["CFBundleVersion"] as? String ?? "unknown",
            qaInstall: Bundle.main.bundleIdentifier == "com.evanvonessen.bound.multiplayerqa",
            runtime: runtime, sourceRevision: revision, sourceDirty: info["BoundPresenceSourceDirty"] as? Bool,
            limitSamples: Self.maximumSamples, samples: samples)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    nonisolated private static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}

private struct BoundPresenceCheckFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

struct BoundPresenceConnectionCheckControls: View {
    @ObservedObject var check: BoundPresenceConnectionCheck
    @State private var file: BoundPresenceCheckFile?
    @State private var exporting = false
    @State private var failed = false
    var body: some View {
        DisclosureGroup("Connection check") {
            Text("Record up to 15 minutes of connection, reader and display counters. Recording stays on this device until you export it.")
                .font(.footnote).foregroundStyle(.secondary)
            if check.recording {
                Button("Stop recording check") { check.stop() }
                    .accessibilityIdentifier("bound.presence-check-stop")
            } else {
                Button("Record connection check") { file = nil; check.start() }
                    .accessibilityIdentifier("bound.presence-check-start")
            }
            Text("\(check.sampleCount) / \(BoundPresenceConnectionCheck.maximumSamples) samples")
                .font(.footnote).monospacedDigit()
            if check.sampleCount > 0 {
                Button("Export connection report") {
                    do { file = try .init(data: check.export()); exporting = true }
                    catch { failed = true }
                }.accessibilityIdentifier("bound.presence-check-export")
                Button("Clear connection report", role: .destructive) { check.clear(); file = nil }
            }
        }
        .fileExporter(isPresented: $exporting, document: file, contentType: .json,
                      defaultFilename: "Bound-live-presence-check") { result in
            if case .failure = result { failed = true }
        }
        .alert("Couldn’t export connection report", isPresented: $failed) { Button("OK", role: .cancel) {} }
    }
}
