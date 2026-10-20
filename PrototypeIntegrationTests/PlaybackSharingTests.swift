import XCTest
import UIKit
import SwiftUI
import CoreVideo
import MetalKit
import ObjectiveC
import DeltaCore
@testable import Delta
@testable import class Delta.GameViewController

private struct FixtureGame: GameProtocol {
    let fileURL: URL
    let gameSaveURL: URL
    var type: GameType { System.gba.gameType }
}
private final class FrameProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [Double] = []
    private var costs: [Double] = []
    private var recording = true
    func record(at stamp: Double, cost: Double) { lock.lock(); defer { lock.unlock() }; guard recording else { return }; stamps.append(stamp); costs.append(cost) }
    func stop() { lock.lock(); recording = false; lock.unlock() }
    func snapshot() -> ([Double], [Double]) { lock.lock(); defer { lock.unlock() }; return (stamps, costs) }
    func reset() { lock.lock(); recording = true; stamps.removeAll(keepingCapacity: true); costs.removeAll(keepingCapacity: true); lock.unlock() }
}
private final class TransitionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record(_ success: Bool) { lock.lock(); if success { value += 1 }; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
@MainActor private final class Pending: SharingCancellation {
    var cancelled = false
    func cancel() { cancelled = true }
}
/// No RTC engine, credentials, network, camera or microphone. Exercises the real
/// outgoing CV pool, decoded callback mailbox and retained canvas boundaries.
@MainActor private final class OfflineVideoTransport: FriendSharingTransport {
    let outgoing = AgoraOutgoingPixels()
    let callbacks = AgoraSharingCallbacks(remoteUID: 2) { _, _ in }
    let presenter = FriendSharingCanvasPresenter()
    private var host: UIView?
    private var generation = 0
    private(set) var publishedFrames = 0
    var receivedFrames: Int { callbacks.receivedFrames }
    var diagnostics: [String: Any] { callbacks.diagnostics }
    private(set) var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var completedAfterStop = 0
    private var event: ((FriendSharingEvent) -> Void)?
    private var previousFingerprint: [UInt8]?
    private(set) var changedFrames = 0
    var delay: UInt64 = 0
    func start(configuration: FriendSharingConfiguration, remoteView: UIView, event: @escaping @MainActor (FriendSharingEvent) -> Void) {
        generation += 1; host = remoteView; self.event = event
        callbacks.resetFrames(enabled: true); event(.joined)
    }
    func stop() { generation += 1; host = nil; event = nil; callbacks.resetFrames(enabled: false); presenter.clear() }
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        let pending = Pending(), run = generation
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        Task {
            var prepared: AgoraOutgoingPixels.Prepared? = await outgoing.prepare(frame)
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            defer { prepared = nil; inFlight -= 1; completion(.success(())) }
            guard !pending.cancelled, run == generation, let buffer = prepared?.buffer else {
                if run != generation { completedAfterStop += 1 }; return
            }
            // Model decoded RGBA without claiming to exercise the SDK codec.
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            var pixels = Data(count: SharingFrame.byteCount)
            pixels.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: UInt8.self).baseAddress!
                for y in 0..<160 { for x in 0..<240 {
                    let i = y * stride + x * 4, o = (y * 240 + x) * 4
                    dst[o] = base[i + 2]; dst[o + 1] = base[i + 1]; dst[o + 2] = base[i]; dst[o + 3] = base[i + 3]
                } }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            let fingerprint = Array(pixels.prefix(4)) + Array(pixels.suffix(4))
            if let previousFingerprint, previousFingerprint != fingerprint { changedFrames += 1 }
            previousFingerprint = fingerprint
            callbacks.receiveFrame(convert: { pixels }); publishedFrames += 1
        }
        return pending
    }
    private(set) var presentationCalls = 0
    func presentLatestFrame() {
        presentationCalls += 1
        if let host, let pixels = callbacks.takeLatestPixels() { presenter.present(pixels, in: host) }
    }
    func interrupt() { callbacks.suspendFrames(); presenter.clear(); event?(.reconnecting) }
    func recover() { callbacks.resumeFrames(); event?(.rejoined) }
}

@MainActor final class PlaybackSharingTests: XCTestCase {
    private func configuration() -> FriendSharingConfiguration {
        .init(appID: String(repeating: "0", count: 32), channel: "offline-fixture", uid: 1, remoteUID: 2, token: "offline-not-an-RTC-token")
    }
    private func wait(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
    func testMalformedCanvasPreservesValidFrame() throws {
        let presenter = FriendSharingCanvasPresenter(), host = UIView()
        XCTAssertFalse(presenter.present(Data(count: 1), in: host)); XCTAssertTrue(host.subviews.isEmpty)
        XCTAssertTrue(presenter.present(FriendSharingPixels.rgba(sequence: 1, uid: 1), in: host))
        let image = (host.subviews.first as? UIImageView)?.image
        XCTAssertFalse(presenter.present(Data(count: 12), in: host))
        XCTAssertTrue((host.subviews.first as? UIImageView)?.image === image)
        presenter.clear(); XCTAssertTrue(host.subviews.isEmpty)
    }
    func testActualI420ConversionAndStaleCallbackFence() async throws {
        let callbacks = AgoraSharingCallbacks(remoteUID: 2) { _, _ in }
        let y = [UInt8](repeating: 81, count: 240 * 160)
        let u = [UInt8](repeating: 90, count: 128 * 80), v = [UInt8](repeating: 240, count: 128 * 80)
        let pixels = try XCTUnwrap(y.withUnsafeBufferPointer { yy in
            u.withUnsafeBufferPointer { uu in v.withUnsafeBufferPointer { vv in
                FriendSharingPixels.rgbaFromI420(width: 240, height: 160, yStride: 240, uStride: 128, vStride: 128, y: yy.baseAddress!, u: uu.baseAddress!, v: vv.baseAddress!)
            } }
        })
        XCTAssertEqual(Array(pixels.prefix(4)), [255, 0, 0, 255])
        let entered = expectation(description: "SDK-style borrowed conversion entered"), release = DispatchSemaphore(value: 0)
        let work = Task.detached {
            callbacks.receiveFrame(convert: { entered.fulfill(); _ = release.wait(timeout: .now() + 2); return pixels })
        }
        await fulfillment(of: [entered], timeout: 2)
        callbacks.resetFrames(enabled: false); release.signal(); await work.value
        XCTAssertNil(callbacks.takeLatestPixels()); XCTAssertEqual(callbacks.diagnostics["staleConversionDrops"], 1)
        callbacks.resetFrames(enabled: true); callbacks.receiveFrame(convert: { pixels })
        XCTAssertEqual(callbacks.takeLatestPixels(), pixels)
    }
    func testOfflinePixelsBackpressureRecoveryAndStop() async throws {
        let transport = OfflineVideoTransport()
        let session = FriendSharingSession(configuration: configuration(), transport: transport, authenticatedMode: false)
        session.start(); XCTAssertTrue(session.joined)
        let rgba = FriendSharingPixels.rgba(sequence: 1, uid: 1)
        for i in 1...6 {
            session.receivePlaybackFrame(GameFrame(rgba: rgba, number: UInt64(i), buttons: 0))
            try await wait(0.04)
        }
        XCTAssertGreaterThan(transport.publishedFrames, 2)
        XCTAssertTrue(session.remoteVisible); XCTAssertTrue(transport.presenter.isVisible)
        let rendered = try XCTUnwrap((session.remoteView.subviews.first as? UIImageView)?.image?.cgImage)
        let displayed = try XCTUnwrap(rendered.dataProvider?.data) as Data
        XCTAssertEqual(displayed, rgba, "Actual CV conversion/mailbox/canvas must preserve the detached pixels")
        transport.delay = 150_000_000
        for i in 7...106 { session.receivePlaybackFrame(GameFrame(rgba: rgba, number: UInt64(i), buttons: 0)) }
        XCTAssertEqual(transport.maximumInFlight, 1)
        transport.interrupt(); XCTAssertFalse(session.joined); XCTAssertFalse(session.remoteVisible)
        transport.recover(); XCTAssertTrue(session.joined)
        session.receivePlaybackFrame(GameFrame(rgba: rgba, number: 107, buttons: 0))
        session.background(); XCTAssertFalse(session.active); XCTAssertFalse(transport.presenter.isVisible)
        try await wait(0.3)
        XCTAssertEqual(transport.inFlight, 0); XCTAssertFalse(transport.presenter.isVisible)
        session.foreground(); transport.delay = 0; session.start()
        session.receivePlaybackFrame(GameFrame(rgba: rgba, number: 108, buttons: 0))
        try await wait(0.1); XCTAssertTrue(transport.presenter.isVisible)
        session.stop(); XCTAssertFalse(transport.presenter.isVisible)
    }
    func testHiddenFriendKeepsSharingWithoutPresentingImages() async throws {
        let transport = OfflineVideoTransport()
        let session = FriendSharingSession(configuration: configuration(), transport: transport, authenticatedMode: false)
        session.setRemotePresentationEnabled(false)
        session.start(); defer { session.stop() }
        for i in 1...4 {
            session.receivePlaybackFrame(GameFrame(rgba: FriendSharingPixels.rgba(sequence: UInt64(i), uid: 1), number: UInt64(i), buttons: 0))
            try await wait(0.1)
        }
        XCTAssertTrue(session.active); XCTAssertTrue(session.joined)
        XCTAssertGreaterThan(transport.publishedFrames, 0)
        XCTAssertGreaterThan(transport.receivedFrames, 0)
        XCTAssertEqual(transport.presentationCalls, 0)
        XCTAssertFalse(transport.presenter.isVisible)
        session.setRemotePresentationEnabled(true)
        for _ in 0..<20 where !transport.presenter.isVisible { try await wait(0.05) }
        XCTAssertTrue(transport.presenter.isVisible, "Returning to Friend presents the newest retained frame")
        XCTAssertGreaterThan(transport.presentationCalls, 0)
        session.setRemotePresentationEnabled(false)
        let calls = transport.presentationCalls
        try await wait(0.15)
        XCTAssertEqual(transport.presentationCalls, calls)
        XCTAssertTrue(session.active)
    }
    func testDecodedFrameDiagnosticsAreDisabledInRelease() {
        let callbacks = AgoraSharingCallbacks(remoteUID: 2) { _, _ in }
        var samples = 0
        let bytes = Data(repeating: 42, count: SharingFrame.byteCount)
        for _ in 0..<24 {
            callbacks.receiveFrame(convert: { bytes }, evidence: { samples += 1; return ["sampleCount": 64] })
        }
        // The test target does not define DEBUG; its optimization configuration
        // follows the host's Debug/Release configuration instead.
        XCTAssertEqual(samples, _isDebugAssertConfiguration() ? 3 : 0)
        XCTAssertEqual(callbacks.receivedFrames, 24)
        XCTAssertEqual(callbacks.takeLatestPixels(), bytes)
    }

    func testNativePlaybackPanelAndCaptureBenchmark() async throws {
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "BoundDiagnostic", withExtension: "gba"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rom = dir.appendingPathComponent("fixture.gba"); try FileManager.default.copyItem(at: fixture, to: rom)
        var results: [[String: Any]] = []
        // Repeat in reverse order to expose VM/order effects instead of declaring
        // regressions from one six-second sample.
        for (panelShown, capture) in [(false, false), (true, false), (false, true), (true, true),
                                      (true, true), (false, true), (true, false), (false, false)] {
            let core = try XCTUnwrap(EmulatorCore(game: FixtureGame(fileURL: rom, gameSaveURL: dir.appendingPathComponent("fixture.sav")), options: [.metal: true]))
            defer { _ = core.stop() }
            let transport = OfflineVideoTransport()
            let sharing = FriendSharingSession(configuration: configuration(), transport: transport, authenticatedMode: false)
            let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
            let owner = UIViewController(); window.rootViewController = owner; window.makeKeyAndVisible()
            defer { window.isHidden = true; sharing.stop() }
            let gameView = GameView(frame: CGRect(x: 0, y: 0, width: 390, height: panelShown ? 400 : 650)); owner.view.addSubview(gameView); core.add(gameView)
            var host: UIHostingController<BoundCompanionPanel>?
            if panelShown {
                let panel = BoundCompanionPanel(sharing: sharing, state: BoundCompanionState(), gameID: "benchmark", editingChanged: { _ in })
                host = UIHostingController(rootView: panel); owner.addChild(host!); owner.view.addSubview(host!.view)
                host!.view.frame = CGRect(x: 0, y: 410, width: 390, height: 250); host!.didMove(toParent: owner)
            }
            if capture { sharing.start() }
            let probe = FrameProbe()
            let tap = BoundDeltaFrameTap { frame in sharing.receivePlaybackFrame(frame) }
            tap.setEnabled(capture)
            core.updateHandler = { core in
                let start = ProcessInfo.processInfo.systemUptime
                tap.receive(core)
                probe.record(at: start, cost: (ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            XCTAssertTrue(core.start()); try await wait(6)
            let visibleBeforeStop = transport.presenter.isVisible
            XCTAssertTrue(core.stop()); tap.setEnabled(false); sharing.stop(); window.isHidden = true
            let (stamps, costs) = probe.snapshot()
            let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
            func percentile(_ values: [Double], _ fraction: Double) -> Double { let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))] }
            XCTAssertGreaterThan(stamps.count, 180)
            guard stamps.count >= 2, !costs.isEmpty else { XCTFail("No native frame samples"); continue }
            if capture {
                XCTAssertGreaterThan(transport.publishedFrames, 60); XCTAssertEqual(transport.maximumInFlight, 1)
                XCTAssertTrue(visibleBeforeStop); XCTAssertGreaterThan(transport.changedFrames, 5, "Animated native pixels must reach the receive canvas")
            }
            let row: [String: Any] = ["panel": panelShown, "capture": capture, "durationSeconds": stamps.last! - stamps.first!, "callbacks": stamps.count,
              "meanGapMs": gaps.reduce(0, +) / Double(gaps.count), "p95GapMs": percentile(gaps, 0.95), "p99GapMs": percentile(gaps, 0.99), "maximumGapMs": gaps.max()!,
              "ownerTapP95Ms": percentile(costs, 0.95), "publishedFrames": transport.publishedFrames, "maximumSendsInFlight": transport.maximumInFlight]
            results.append(row); print("BOUND_OFFLINE_BENCH \(row)")
            core.updateHandler = nil; core.remove(gameView); host?.willMove(toParent: nil); host?.view.removeFromSuperview(); host?.removeFromParent()
        }
        let bytes = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json"); attachment.name = "offline-playback-benchmark"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

extension PlaybackSharingTests {
    func testPortraitCustomControlsCanMoveAboveNativeControllerWithoutStretchingOthers() throws {
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .standard, orientation: .portrait)
        let original = try XCTUnwrap(base.items(for: traits))
        let a = try XCTUnwrap(original.first(where: { $0.inputs.allInputs.map(\.stringValue) == ["a"] }))
        let b = try XCTUnwrap(original.first(where: { $0.inputs.allInputs.map(\.stringValue) == ["b"] }))
        let canvas = CGSize(width: 390, height: 844), native = CGRect(x: 0, y: 550, width: 390, height: 294)
        let custom = BoundPlacedControllerSkin(base: base, layout: .init(positions: [a.id: .init(x: 0.8, y: 0.15, scale: 1)]), canvasSize: canvas, sourceFrame: native)
        let items = try XCTUnwrap(custom.items(for: traits))
        let movedA = try XCTUnwrap(items.first(where: { $0.id == a.id }))
        let unchangedB = try XCTUnwrap(items.first(where: { $0.id == b.id }))
        XCTAssertLessThan(movedA.frame.midY * canvas.height, native.minY)
        XCTAssertEqual(unchangedB.frame.midY * canvas.height, native.minY + b.frame.midY * native.height, accuracy: 0.001)
        XCTAssertEqual(unchangedB.frame.height * canvas.height, b.frame.height * native.height, accuracy: 0.001)
        let (_, originalSize) = try XCTUnwrap(base.image(for: b, traits: traits, preferredSize: .small))
        let (_, actualSize) = try XCTUnwrap(custom.image(for: unchangedB, traits: traits, preferredSize: .small))
        XCTAssertEqual(actualSize.height * canvas.height, originalSize.height * native.height, accuracy: 0.001)
        XCTAssertEqual(custom.image(for: traits, preferredSize: .small)?.size, canvas)
    }

    func testNativeControlPlacementUsesIdenticalArtworkAndHitGeometryAndResets() throws {
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let canvas = CGSize(width: 390, height: 280)
        let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .standard, orientation: .portrait)
        let original = try XCTUnwrap(base.items(for: traits))
        let dpad = try XCTUnwrap(original.first(where: { $0.kind == .dPad }))
        let defaults = BoundPlacedControllerSkin(base: base, layout: .init(), canvasSize: canvas)
        XCTAssertEqual(defaults.items(for: traits)?.map(\.frame), original.map(\.frame))
        XCTAssertEqual(defaults.image(for: traits, preferredSize: .small)?.pngData(), base.image(for: traits, preferredSize: .small)?.pngData())
        let placement = BoundControlLayout(positions: [dpad.id: .init(x: 0.65, y: 0.65, scale: 1.2)])
        let custom = BoundPlacedControllerSkin(base: base, layout: placement, canvasSize: canvas)
        let first = BoundControlLayout(positions: ["a": .init(x: 0.2, y: 0.3, scale: 1), "b": .init(x: 0.4, y: 0.5, scale: 1.1)])
        var reverse = BoundControlLayout(); reverse.positions["b"] = first.positions["b"]; reverse.positions["a"] = first.positions["a"]
        XCTAssertEqual(BoundPlacedControllerSkin(base: base, layout: first, canvasSize: canvas).identifier,
                       BoundPlacedControllerSkin(base: base, layout: reverse, canvasSize: canvas).identifier)
        let moved = try XCTUnwrap(custom.items(for: traits)?.first(where: { $0.id == dpad.id }))
        let expected = placement.frame(id: dpad.id, base: dpad.frame.applying(.init(scaleX: canvas.width, y: canvas.height)), canvas: canvas, directional: true)
        XCTAssertEqual(moved.frame.minX * canvas.width, expected.minX, accuracy: 0.001)
        XCTAssertEqual(moved.frame.width * canvas.width, expected.width, accuracy: 0.001)
        XCTAssertEqual(moved.inputs.allInputs.map(\.stringValue), dpad.inputs.allInputs.map(\.stringValue))
        let (_, originalSize) = try XCTUnwrap(base.image(for: dpad, traits: traits, preferredSize: .small))
        let (_, movedSize) = try XCTUnwrap(custom.image(for: moved, traits: traits, preferredSize: .small))
        XCTAssertEqual(movedSize.width / originalSize.width, moved.frame.width / dpad.frame.width, accuracy: 0.001)
        let controller = ControllerView(frame: CGRect(origin: .zero, size: canvas))
        controller.overrideControllerSkinTraits = traits; controller.controllerSkin = custom
        XCTAssertTrue(controller.controlHitFrames.contains { abs($0.minX - moved.extendedFrame.minX * canvas.width) < 0.001 && abs($0.width - moved.extendedFrame.width * canvas.width) < 0.001 })
        controller.cancelTouchInputs(); controller.cancelTouchInputs()
        controller.usesControlOnlyHitTesting = true
        let blank = CGPoint(x: 5, y: 5)
        if !controller.controlHitFrames.contains(where: { $0.contains(blank) }) { XCTAssertNil(controller.hitTest(blank, with: nil)) }
        controller.isUserInteractionEnabled = false
        XCTAssertNil(controller.hitTest(CGPoint(x: expected.midX, y: expected.midY), with: nil)) // Idempotent without a held touch.
        controller.controllerSkin = defaults
        XCTAssertEqual(controller.controlHitFrames.count, original.count)
    }
    func testLandscapeFlattenedSkinMovesControlArtworkAndPreservesNativeInputIdentifiers() throws {
        let base = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .standard, orientation: .landscape)
        let items = try XCTUnwrap(base.items(for: traits))
        let a = try XCTUnwrap(items.first(where: { $0.inputs.allInputs.map(\.stringValue) == ["a"] }))
        let layout = BoundControlLayout(positions: [a.id: .init(x: 0.6, y: 0.3, scale: 1.15)])
        let custom = BoundPlacedControllerSkin(base: base, layout: layout, canvasSize: CGSize(width: 844, height: 390))
        let moved = try XCTUnwrap(custom.items(for: traits))
        XCTAssertEqual(moved.map(\.id), items.map(\.id))
        XCTAssertEqual(moved.map { $0.inputs.allInputs.map(\.stringValue) }, items.map { $0.inputs.allInputs.map(\.stringValue) })
        XCTAssertNotEqual(custom.image(for: traits, preferredSize: .small)?.pngData(), base.image(for: traits, preferredSize: .small)?.pngData())
        XCTAssertEqual(custom.screens(for: traits)?.first?.outputFrame, base.screens(for: traits)?.first?.outputFrame)
    }
}


extension PlaybackSharingTests {
    func testOpacityPreviewCancellationAndCommitAcrossLifecycle() throws {
        let suite = "BoundOpacityLifecycle." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        let coordinator = BoundCompanionCoordinator(state: BoundCompanionState(preferences: preferences))
        coordinator.state.landscape = true
        coordinator.fade(.began, dy: 0)
        coordinator.fade(.changed, dy: 80)
        XCTAssertEqual(preferences.opacity(for: .friend), 1, "Preview must not write preferences")
        coordinator.cancelInteractions()
        XCTAssertEqual(preferences.opacity(for: .friend), 1)
        coordinator.fade(.began, dy: 0)
        coordinator.fade(.changed, dy: 80)
        coordinator.fade(.ended, dy: 80)
        XCTAssertEqual(preferences.opacity(for: .friend), 0.5)
        coordinator.fade(.began, dy: 0)
        coordinator.fade(.changed, dy: -80)
        coordinator.fade(.cancelled, dy: -80)
        XCTAssertEqual(preferences.opacity(for: .friend), 0.5)
        XCTAssertEqual(BoundPiPPreferences(defaults: defaults).opacity(for: .friend), 0.5)
    }
    func testPiPReleaseKeepsLastPreviewAndPanelPreferencesAcrossRestart() throws {
        let suite = "BoundPiPRelease." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BoundPiPPreferences(defaults: defaults)
        let state = BoundCompanionState(preferences: preferences)
        state.landscape = true
        let coordinator = BoundCompanionCoordinator(state: state)
        for (selected, content) in [(0, BoundPiPContent.friend), (1, .notes), (2, .types)] {
            state.selected = selected
            coordinator.resize(.began, scale: 1)
            coordinator.resize(.changed, scale: 1.2 + CGFloat(selected) * 0.1)
            // Lifting may report a default value. Commit the last preview, exactly once.
            coordinator.resize(.ended, scale: 1)
            coordinator.resize(.ended, scale: 0.1)
            XCTAssertEqual(preferences.scale(for: content), 1.2 + Double(selected) * 0.1, accuracy: 0.0001)
            coordinator.resize(.began, scale: 1)
            coordinator.resize(.changed, scale: 0.2)
            coordinator.resize(.cancelled, scale: 0.2)
            XCTAssertEqual(preferences.scale(for: content), 1.2 + Double(selected) * 0.1, accuracy: 0.0001)
        }
        for (selected, content) in [(0, BoundPiPContent.friend), (1, .notes)] {
            state.selected = selected
            coordinator.fade(.began, dy: 0)
            coordinator.fade(.changed, dy: 40)
            coordinator.fade(.ended, dy: 0)
            coordinator.fade(.ended, dy: 160)
            XCTAssertLessThan(preferences.opacity(for: content), 1)
            let stored = preferences.opacity(for: content)
            coordinator.fade(.began, dy: 0)
            coordinator.fade(.changed, dy: -40)
            coordinator.cancelInteractions() // Rotation/game exit must abandon preview.
            coordinator.fade(.ended, dy: -40)
            XCTAssertEqual(preferences.opacity(for: content), stored)
        }
        state.selected = 2
        XCTAssertFalse(coordinator.allowsOpacityGesture)
        coordinator.fade(.began, dy: 0); coordinator.fade(.changed, dy: 80); coordinator.fade(.ended, dy: 0)
        XCTAssertEqual(preferences.opacity(for: .types), 1)
        state.selected = 0; state.landscape = false
        XCTAssertFalse(coordinator.allowsOpacityGesture)
        let prior = preferences.opacity(for: .friend)
        coordinator.fade(.began, dy: 0); coordinator.fade(.changed, dy: 80); coordinator.fade(.ended, dy: 0)
        XCTAssertEqual(preferences.opacity(for: .friend), prior)
        let restarted = BoundPiPPreferences(defaults: defaults)
        for content in BoundPiPContent.allCases {
            XCTAssertEqual(restarted.scale(for: content), preferences.scale(for: content))
            XCTAssertEqual(restarted.opacity(for: content), preferences.opacity(for: content))
        }
    }
}


extension PlaybackSharingTests {
    func testControllerModeCancellationPreservesActualNativeExternalHeldAndSustainedA() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try XCTUnwrap(EmulatorCore(game: FixtureGame(fileURL: fixture, gameSaveURL: directory.appendingPathComponent("fixture.sav")), options: [.metal: true]))
        let touch = ControllerView(), external = BoundHeldExternalController()
        touch.playerIndex = 0
        let touchA = AnyInput(stringValue: "a", intValue: nil, type: .controller(.controllerSkin))
        var touchMapping = DeltaCore.GameControllerInputMapping(gameControllerInputType: .controllerSkin)
        touchMapping.set(StandardGameControllerInput.a, forControllerInput: touchA)
        var externalMapping = DeltaCore.GameControllerInputMapping(gameControllerInputType: .mfi)
        externalMapping.set(StandardGameControllerInput.a, forControllerInput: MFiGameController.Input.a)
        touch.addReceiver(core, inputMapping: touchMapping)
        external.addReceiver(core, inputMapping: externalMapping)
        var waiting: XCTestExpectation?
        var expectedPressed = true
        var consecutive = 0
        let tap = BoundDeltaFrameTap { frame in
            guard let expectation = waiting else { return }
            // The original fixture's ten bottom indicators expose actual KEYINPUT.
            // Probe both bitmap orientations; its animated top stripe is never yellow/gray.
            let offsets = [15, 144].map { ($0 * 240 + 12) * 4 }
            let matches = offsets.contains { offset in
                let r = Int(frame.rgba[offset]), g = Int(frame.rgba[offset + 1]), b = Int(frame.rgba[offset + 2])
                return expectedPressed ? r > 200 && g > 200 && b < 50
                    : (30...110).contains(r) && abs(r-g) < 5 && abs(r-b) < 5
            }
            consecutive = matches ? consecutive + 1 : 0
            if consecutive >= 3 { waiting = nil; expectation.fulfill() }
        }
        tap.setEnabled(true)
        core.updateHandler = { tap.receive($0) }
        defer {
            waiting = nil; tap.setEnabled(false); _ = core.stop()
            touch.removeReceiver(core); external.removeReceiver(core)
        }
        XCTAssertTrue(core.start()); core.audioManager.isEnabled = false
        for sustained in [false, true] {
            external.activate(MFiGameController.Input.a)
            if sustained { external.sustain(MFiGameController.Input.a) }
            touch.activate(touchA)
            expectedPressed = true; consecutive = 0
            let initiallyHeld = expectation(description: "Native A is held by both controllers")
            waiting = initiallyHeld
            await fulfillment(of: [initiallyHeld], timeout: 3)
            BoundControllerModeSkin.cancelTouchInputs(in: touch, preservingExternalInputsFrom: [external], emulatorCore: core)
            XCTAssertTrue(touch.activatedInputs.isEmpty)
            XCTAssertFalse(external.activatedInputs.isEmpty)
            consecutive = 0
            let stillHeld = expectation(description: "Actual native KEYINPUT A stays held after virtual cancellation")
            waiting = stillHeld
            await fulfillment(of: [stillHeld], timeout: 3)
            if sustained { external.unsustain(MFiGameController.Input.a) }
            else { external.deactivate(MFiGameController.Input.a) }
            expectedPressed = false; consecutive = 0
            let released = expectation(description: "Actual native KEYINPUT A releases with external controller")
            waiting = released
            await fulfillment(of: [released], timeout: 3)
        }
    }
    func testNativeRepeatedStartPauseResumeStopAcknowledgesEveryTransition() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try XCTUnwrap(EmulatorCore(game: FixtureGame(fileURL: fixture, gameSaveURL: directory.appendingPathComponent("fixture.sav")), options: [.metal: true]))
        defer { _ = core.stop() }
        for _ in 0..<12 {
            XCTAssertTrue(core.start()); XCTAssertEqual(core.state, .running)
            XCTAssertTrue(core.pause()); XCTAssertEqual(core.state, .paused)
            XCTAssertTrue(core.resume()); XCTAssertEqual(core.state, .running)
            XCTAssertTrue(core.stop()); XCTAssertEqual(core.state, .stopped)
        }
        XCTAssertTrue(core.start())
        let pauses = TransitionCount()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in pauses.record(core.pause()) }
        XCTAssertEqual(pauses.count, 1); XCTAssertEqual(core.state, .paused)
        let resumes = TransitionCount()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in resumes.record(core.resume()) }
        XCTAssertEqual(resumes.count, 1); XCTAssertEqual(core.state, .running)
        let stops = TransitionCount()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in stops.record(core.stop()) }
        XCTAssertEqual(stops.count, 1); XCTAssertEqual(core.state, .stopped)
    }
}

private final class BoundHeldExternalController: NSObject, GameController {
    let name = "Bound native held-input regression"
    var playerIndex: Int? = 0
    let inputType = GameControllerInputType.mfi
    var defaultInputMapping: GameControllerInputMappingProtocol? { nil }
}

@MainActor private final class DisposalProbeTransport: FriendSharingTransport {
    var publishedFrames = 0
    var receivedFrames = 0
    var stopped = false
    var stoppedOnMain = false
    func start(configuration: FriendSharingConfiguration, remoteView: UIView, event: @escaping @MainActor (FriendSharingEvent) -> Void) { event(.joined) }
    func stop() { stopped = true; stoppedOnMain = Thread.isMainThread }
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation { Pending() }
}
/// The box transfers its sole owner to the detached release task, then is never read again.
private final class DisposalReleaseBox: @unchecked Sendable {
    var owner: FriendSharingSession?
    init(_ owner: FriendSharingSession) { self.owner = owner }
}

extension PlaybackSharingTests {
    func testMainAndOffMainDisposalRunsCapturedCleanupWithoutRetainingOwner() async throws {
        for offMain in [false, true] {
            let transport = DisposalProbeTransport()
            var owner: FriendSharingSession? = FriendSharingSession(configuration: configuration(), transport: transport, authenticatedMode: false)
            owner?.start()
            weak var released = owner
            if offMain {
                let box = DisposalReleaseBox(try XCTUnwrap(owner)); owner = nil
                await Task.detached { box.owner = nil }.value
            } else { owner = nil }
            XCTAssertNil(released, "Cleanup must not capture the disposed session")
            BoundMainActorDisposal.drainPending()
            XCTAssertTrue(transport.stopped)
            XCTAssertTrue(transport.stoppedOnMain)
        }
    }
    func testCapturedCleanupDrainsBeforeReplacementAndAllowsNestedCancellation() async {
        var events: [Int] = []
        BoundMainActorDisposal.enqueue {
            events.append(1)
            BoundMainActorDisposal.enqueue { events.append(2) }
            BoundMainActorDisposal.drainPending() // Reentrant cancellation is harmless.
        }
        BoundMainActorDisposal.drainPending()
        XCTAssertEqual(events, [1, 2])
        let timer = FriendSharingTimer(after: 10) { XCTFail("Cancelled timer fired") }
        timer.cancel()
        let link = FriendSharingDisplayLink { _ in XCTFail("Cancelled display link fired") }
        link.cancel()
        let onboarding = FriendOnboarding()
        onboarding.close()
    }
}

/// This baseline is DeltaCore's native controller, not the original Delta app.
/// The app cases instantiate the shipping Bound GameViewController/coordinator.
/// Keep the distinction in every exported result and never infer phone parity.
private final class AppPacingDrawableObserver: @unchecked Sendable {
    static let shared = AppPacingDrawableObserver()
    private let lock = NSLock()
    private weak var layer: CAMetalLayer?
    private var probe: FrameProbe?
    func observe(_ layer: CAMetalLayer?, probe: FrameProbe?) {
        lock.lock(); self.layer = layer; self.probe = probe; lock.unlock()
    }
    func received(_ drawable: CAMetalDrawable, from source: CAMetalLayer) {
        lock.lock(); let target = source === layer ? probe : nil; lock.unlock()
        guard let target else { return }
        #if targetEnvironment(simulator)
        // Simulator's Metal SDK intentionally omits presented handlers/times.
        // This counts drawable acquisitions only, never displayed frames.
        target.record(at: ProcessInfo.processInfo.systemUptime, cost: 0)
        #else
        drawable.addPresentedHandler { drawable in
            // presentedTime is the drawable's presentation timestamp, not the
            // emulator update callback or a guessed display-link timestamp.
            if drawable.presentedTime > 0 { target.record(at: drawable.presentedTime, cost: 0) }
        }
        #endif
    }
}
private extension CAMetalLayer {
    @objc func boundTestNextDrawable() -> CAMetalDrawable? {
        let drawable = boundTestNextDrawable() // Original IMP while exchanged.
        if let drawable { AppPacingDrawableObserver.shared.received(drawable, from: self) }
        return drawable
    }
}
@MainActor private final class AppPacingTicks: NSObject {
    let probe = FrameProbe()
    private var link: CADisplayLink?
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 60; link.add(to: .main, forMode: .common); self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) { probe.record(at: ProcessInfo.processInfo.systemUptime, cost: 0) }
    func stop() { link?.invalidate(); link = nil }
}
private final class AppPacingNativeDelegate: GameViewControllerDelegate {
    let metal: Bool
    init(metal: Bool) { self.metal = metal }
    func gameViewController(_ gameViewController: DeltaCore.GameViewController, optionsFor game: GameProtocol) -> [EmulatorCore.Option: Any] { [.metal: metal] }
}

extension PlaybackSharingTests {
    func testNativeControllerPortraitGeometry() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let owner = DeltaCore.GameViewController(), delegate = AppPacingNativeDelegate(metal: true)
        owner.delegate = delegate; owner.automaticallyPausesWhileInactive = false
        owner.loadViewIfNeeded()
        owner.game = FixtureGame(fileURL: fixture, gameSaveURL: FileManager.default.temporaryDirectory.appendingPathComponent("portrait-geometry.sav"))
        owner.controllerView.playerIndex = 0
        let window = UIWindow(windowScene: scene); window.rootViewController = owner; window.makeKeyAndVisible()
        defer { _ = owner.emulatorCore?.stop(); owner.game = nil; window.isHidden = true; window.rootViewController = nil }
        try await wait(0.5); owner.view.layoutIfNeeded()
        let traits = try XCTUnwrap(owner.controllerView.controllerSkinTraits)
        let skin = try XCTUnwrap(owner.controllerView.controllerSkin)
        let aspect = try XCTUnwrap(skin.aspectRatio(for: traits))
        let controller = owner.controllerView.convert(owner.controllerView.bounds, to: owner.view)
        let game = owner.gameView.convert(owner.gameView.bounds, to: owner.view)
        XCTAssertEqual(controller.maxY, owner.view.bounds.maxY, accuracy: 1)
        XCTAssertEqual(controller.height, owner.view.bounds.width * aspect.height / aspect.width, accuracy: 1)
        XCTAssertLessThanOrEqual(game.maxY, controller.minY + 1)
        let items = try XCTUnwrap(skin.items(for: traits))
        var rows: [[String: Any]] = []
        for name in ["l", "r"] {
            let item = try XCTUnwrap(items.first { $0.inputs.allInputs.contains { $0.stringValue == name } })
            let frame = item.frame.applying(.init(scaleX: controller.width, y: controller.height)).offsetBy(dx: controller.minX, dy: controller.minY)
            rows.append(["input": name, "frame": [frame.minX, frame.minY, frame.width, frame.height]])
        }
        let data = try JSONSerialization.data(withJSONObject: ["screen": [window.bounds.width, window.bounds.height],
            "game": [game.minX, game.minY, game.width, game.height], "controller": [controller.minX, controller.minY, controller.width, controller.height],
            "nativeShoulders": rows], options: [.prettyPrinted, .sortedKeys])
        let geometry = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        geometry.name = "native-controller-portrait-geometry"; geometry.lifetime = .keepAlways; add(geometry)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "Native-Delta-controller-portrait"; screenshot.lifetime = .keepAlways; add(screenshot)
        withExtendedLifetime(delegate) {}
    }

    /// Opt-in because other UI/build work on the shared host invalidates timing.
    /// Set BOUND_APP_PACING=1 in the generated xctestrun EnvironmentVariables.
    func testActualAppAndNativeControllerPacing() async throws {
        let runMode = ProcessInfo.processInfo.environment["BOUND_APP_PACING"]
        guard runMode == "1" || runMode == "smoke" else {
            throw XCTSkip("Requires an exclusive host timing slot and explicit opt-in")
        }
        // Smoke only validates the harness; its numbers are not performance evidence.
        let smoke = runMode == "smoke", warmup = smoke ? 0.5 : 5.0, duration = smoke ? 1.0 : 15.0
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DatabaseManager.shared.start { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
        let imported = await withCheckedContinuation { continuation in
            DatabaseManager.shared.importGames(at: [fixture]) { continuation.resume(returning: ($0, $1)) }
        }
        XCTAssertTrue(imported.1.isEmpty)
        let game = try XCTUnwrap(imported.0.first)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let controllers = ExternalGameControllerManager.shared
        let savedAutomaticIndexes = controllers.automaticallyAssignsPlayerIndexes
        let savedControllerIndexes = controllers.connectedControllers.map { ($0, $0.playerIndex) }
        let savedLocalIndex = Settings.localControllerPlayerIndex
        controllers.automaticallyAssignsPlayerIndexes = false
        controllers.connectedControllers.forEach { $0.playerIndex = nil }
        Settings.localControllerPlayerIndex = 0
        defer {
            controllers.automaticallyAssignsPlayerIndexes = savedAutomaticIndexes
            savedControllerIndexes.forEach { $0.0.playerIndex = $0.1 }
            Settings.localControllerPlayerIndex = savedLocalIndex
        }
        let preferences = BoundAppearancePreferences(), savedTheme = preferences.theme, savedLayout = preferences.screenLayout
        let original = try XCTUnwrap(class_getInstanceMethod(CAMetalLayer.self, #selector(CAMetalLayer.nextDrawable)))
        let replacement = try XCTUnwrap(class_getInstanceMethod(CAMetalLayer.self, #selector(CAMetalLayer.boundTestNextDrawable)))
        method_exchangeImplementations(original, replacement)
        defer {
            AppPacingDrawableObserver.shared.observe(nil, probe: nil)
            method_exchangeImplementations(original, replacement)
            preferences.theme = savedTheme; preferences.screenLayout = savedLayout
        }
        preferences.theme = .delta
        func metalLayer(_ layer: CALayer) -> CAMetalLayer? {
            if let layer = layer as? CAMetalLayer { return layer }
            return layer.sublayers?.compactMap { metalLayer($0) }.first
        }
        func summary(_ probe: FrameProbe) -> [String: Any] {
            let (stamps, costs) = probe.snapshot()
            let gaps = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }.filter { $0 >= 0 }.sorted()
            guard !gaps.isEmpty else { return ["samples": stamps.count] }
            func p(_ q: Double) -> Double { gaps[Int(Double(gaps.count - 1) * q)] }
            return ["samples": stamps.count, "meanGapMs": gaps.reduce(0, +) / Double(gaps.count),
                "p50GapMs": p(0.5), "p95GapMs": p(0.95), "p99GapMs": p(0.99), "maxGapMs": gaps.last!,
                "gapsOver25Ms": gaps.filter { $0 > 25 }.count, "gapsOver50Ms": gaps.filter { $0 > 50 }.count,
                "meanCallbackWorkMs": costs.reduce(0, +) / Double(max(1, costs.count))]
        }
        var rows: [[String: Any]] = []
        // Reverse the order on every other repeat to expose order effects.
        let standardModes = ["native-controller-gl", "native-controller-metal", "bound-classic", "bound-arrangement"]
        let requestedModes = ProcessInfo.processInfo.environment["BOUND_APP_PACING_MODES"]?.split(separator: ",").map(String.init)
        let modes = requestedModes ?? standardModes
        XCTAssertFalse(modes.isEmpty)
        XCTAssertTrue(modes.allSatisfy { standardModes.contains($0) })
        let repeats = ProcessInfo.processInfo.environment["BOUND_APP_PACING_REPEATS"] == "1" ? 1 : (smoke ? 1 : 3)
        for repeatIndex in 0..<repeats {
            for mode in repeatIndex.isMultiple(of: 2) ? modes : Array(modes.reversed()) {
                let native = mode.hasPrefix("native-"), usesMetal = mode != "native-controller-gl"
                preferences.screenLayout = mode == "bound-arrangement" ? .bound : .delta
                let owner: DeltaCore.GameViewController = native ? DeltaCore.GameViewController() : GameViewController()
                let nativeDelegate = AppPacingNativeDelegate(metal: usesMetal)
                if native { owner.delegate = nativeDelegate }
                owner.automaticallyPausesWhileInactive = false
                owner.loadViewIfNeeded(); owner.game = game
                owner.controllerView.playerIndex = 0
                let window = UIWindow(windowScene: scene)
                window.rootViewController = owner; window.makeKeyAndVisible()
                // Appearance starts the existing core on its native queue. Refresh
                // controller settings after attachment so upstream can load its skin.
                NotificationCenter.default.post(name: Settings.didChangeNotification, object: nil,
                    userInfo: [Settings.NotificationUserInfoKey.name: Settings.Name.localControllerPlayerIndex])
                owner.view.layoutIfNeeded()
                let core = try XCTUnwrap(owner.emulatorCore)
                let prior = core.updateHandler, callbacks = FrameProbe(), presentations = FrameProbe(), ticks = AppPacingTicks()
                core.updateHandler = { core in
                    let start = ProcessInfo.processInfo.systemUptime
                    prior?(core)
                    callbacks.record(at: start, cost: (ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
                // Let the controller's native appearance queue own startup.
                // Starting here too can race that queue's synchronous main hop.
                try await wait(warmup) // Equal warmup, excluded from every distribution.
                XCTAssertEqual(core.state, .running)
                XCTAssertEqual(core.rate, 1)
                XCTAssertFalse(controllers.connectedControllers.contains { $0.playerIndex != nil })
                XCTAssertFalse(owner.controllerView.isHidden)
                XCTAssertNotNil(owner.controllerView.controllerSkin)
                XCTAssertNotNil(owner.controllerView.controllerSkinTraits)
                XCTAssertNotNil(owner.gameView.outputImage)
                XCTAssertEqual(owner.controllerView.playerIndex, 0)
                let layer = metalLayer(owner.gameView.layer)
                if usesMetal { XCTAssertNotNil(layer) }
                AppPacingDrawableObserver.shared.observe(layer, probe: presentations)
                let measurementStartedAt = Date().timeIntervalSince1970
                callbacks.reset(); ticks.start()
                try await wait(duration)
                ticks.stop(); AppPacingDrawableObserver.shared.observe(nil, probe: nil)
                // Freeze callback observations before any post-measurement layout work.
                callbacks.stop(); core.updateHandler = prior
                let measurementEndedAt = Date().timeIntervalSince1970
                let callbackSummary = summary(callbacks), presentationSummary = summary(presentations), tickSummary = summary(ticks.probe)
                XCTAssertGreaterThan(callbacks.snapshot().0.count, smoke ? 10 : 500)
                if usesMetal { XCTAssertGreaterThan(presentations.snapshot().0.count, smoke ? 3 : 100) }
                var layoutCosts: [Double] = []
                for _ in 0..<30 {
                    let start = ProcessInfo.processInfo.systemUptime
                    owner.view.setNeedsLayout(); owner.view.layoutIfNeeded()
                    layoutCosts.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
                let frame = owner.gameView.convert(owner.gameView.bounds, to: owner.view)
                var row: [String: Any] = ["mode": mode, "repeat": repeatIndex, "configuration": _isDebugAssertConfiguration() ? "Debug" : "Release",
                    "baselineScope": native ? "DeltaCore native controller; not original Delta app" : "actual Bound app controller and companion coordinator",
                    "renderer": usesMetal ? "Metal" : "OpenGL", "sharing": "off", "speed": core.rate,
                    "measurementStartUnix": measurementStartedAt, "measurementEndUnix": measurementEndedAt,
                    "smokeOnly": smoke, "warmupSeconds": warmup, "sampleSeconds": duration, "screenPoints": [window.bounds.width, window.bounds.height],
                    "gameFramePoints": [frame.minX, frame.minY, frame.width, frame.height],
                    "controllerVisible": !owner.controllerView.isHidden,
                    "controllerSkin": owner.controllerView.controllerSkin?.identifier ?? "missing",
                    "controllerTraits": String(describing: owner.controllerView.controllerSkinTraits),
                    "controllerFramePoints": [owner.controllerView.frame.minX, owner.controllerView.frame.minY, owner.controllerView.frame.width, owner.controllerView.frame.height],
                    "externalControllerCount": ExternalGameControllerManager.shared.connectedControllers.count,
                    "drawablePixels": layer.map { [$0.drawableSize.width, $0.drawableSize.height] } ?? [],
                    "coreCallbacks": callbackSummary, "metalDrawableObservations": presentationSummary,
                    "metalMetric": ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == nil ? "actual presented timestamps" : "drawable acquisitions; presentation timestamps unavailable in Simulator SDK",
                    "mainRunLoopTicks": tickSummary,
                    "settledLayoutMeanMs": layoutCosts.reduce(0, +) / Double(layoutCosts.count)]
                print("BOUND_APP_PACING \(row)")
                row["rawCoreCallbackSeconds"] = callbacks.snapshot().0
                row["rawDrawableObservationSeconds"] = presentations.snapshot().0
                row["rawMainTickSeconds"] = ticks.probe.snapshot().0
                rows.append(row)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let screenshot = XCTAttachment(image: image)
                screenshot.name = "pacing-\(mode)-\(repeatIndex)"; screenshot.lifetime = .keepAlways; add(screenshot)
                _ = core.stop(); core.updateHandler = prior
                owner.game = nil; window.isHidden = true; window.rootViewController = nil
                withExtendedLifetime(nativeDelegate) {}
                try await wait(0.3)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "actual-app-native-controller-pacing"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
