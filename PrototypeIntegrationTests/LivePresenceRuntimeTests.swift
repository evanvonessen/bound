import XCTest
import UIKit
import CryptoKit
@preconcurrency import DeltaCore
@testable import Delta

private struct PresenceRuntimeGame: GameProtocol {
    let fileURL: URL
    let gameSaveURL: URL
    var type: GameType { .gba }
}

/// Test-only, bounded loopback wire transport. Uses the production friend-session
/// lifecycle and presence packets; deliberately makes no Agora/Internet claim.
@MainActor
private final class PresenceHTTPTransport: FriendSharingTransport {
    var publishedFrames = 0
    var receivedFrames = 0
    let peer: String
    let port: Int
    private var receiver: (@MainActor (Data) -> Void)?
    private var event: (@MainActor (FriendSharingEvent) -> Void)?
    private var polling: Task<Void, Never>?
    private var sending: Task<Void, Never>?
    private var run = UUID()
    private var online = true
    private let session: URLSession
    init(peer: String, port: Int) {
        self.peer = peer; self.port = port
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1; config.timeoutIntervalForResource = 2
        session = URLSession(configuration: config)
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func setPresenceReceiver(_ receiver: (@MainActor (Data) -> Void)?) { self.receiver = receiver }
    func start(configuration: FriendSharingConfiguration, remoteView: UIView,
               event: @escaping @MainActor (FriendSharingEvent) -> Void) {
        stop(); self.event = event; online = true; event(.joined)
        let generation = run
        polling = Task { [weak self] in
            var cursor = "0"
            while !Task.isCancelled {
                guard let self, run == generation else { return }
                do {
                    let (data, response) = try await session.data(from: url("/presence/\(peer)?after=\(cursor)"))
                    guard run == generation, let http = response as? HTTPURLResponse else { return }
                    let available = http.statusCode == 200 || http.statusCode == 404
                    if available != online { online = available; event(available ? .rejoined : .reconnecting) }
                    if http.statusCode == 200, data.count <= BoundPresencePacket.maximumBytes {
                        cursor = http.value(forHTTPHeaderField: "X-Relay-Sequence") ?? cursor
                        receiver?(data)
                    }
                } catch {
                    guard run == generation else { return }
                    if online { online = false; event(.reconnecting) }
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }
    func sendPresence(_ data: Data) -> Bool {
        guard sending == nil, event != nil, online else { return false }
        let generation = run
        var request = URLRequest(url: url("/presence/\(peer)")); request.httpMethod = "PUT"; request.httpBody = data
        sending = Task { [weak self] in
            guard let self else { return }
            _ = try? await session.data(for: request)
            if run == generation { sending = nil }
        }
        return true
    }
    func stop() {
        run = UUID(); polling?.cancel(); sending?.cancel(); polling = nil; sending = nil; event = nil
    }
    func recordRecoveryTimeout() {}
    func renewToken(_ token: String) -> Bool { true }
    func presentLatestFrame() {}
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        completion(.success(())); return RuntimeCancellation()
    }
    func control() async throws -> String {
        let (data, _) = try await session.data(from: url("/status"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["stage"] as? String ?? ""
    }
    func report(_ value: [String: Any]) async throws {
        var request = URLRequest(url: url("/report/\(peer)")); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: value)
        _ = try await session.data(for: request)
    }
}
@MainActor private final class RuntimeCancellation: SharingCancellation { func cancel() {} }

@MainActor
final class LivePresenceRuntimeTests: XCTestCase {
    func testTwoVBAMInstancesExchangeLivePoses() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let peer = env["BOUND_PAIR_PEER"], ["A", "B"].contains(peer),
              let port = env["BOUND_PAIR_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Run PrototypeTools/live-presence-relay.py with two dedicated Simulators")
        }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MultiplayerValidation", isDirectory: true)
        let rom = root.appendingPathComponent("RadicalRed.gba"), seed = root.appendingPathComponent("seed.sav")
        let romHash = SHA256.hash(data: try Data(contentsOf: rom)), seedHash = SHA256.hash(data: try Data(contentsOf: seed))
        let battery = root.appendingPathComponent("presence-\(peer).sav")
        try Data(contentsOf: seed).write(to: battery, options: .atomic)
        let core = try XCTUnwrap(EmulatorCore(game: PresenceRuntimeGame(fileURL: rom, gameSaveURL: battery), options: [.metal: true]))
        // This pose/pixel test keeps its audio renderer disabled because paired
        // Simulator audio services can contend for the host output device.
        core.audioManager.isEnabled = false
        core.audioManager.mixesWithOtherAudio = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), owner = UIViewController(), gameView = GameView()
        window.rootViewController = owner; window.makeKeyAndVisible(); owner.view.frame = window.bounds
        owner.view.backgroundColor = .black
        gameView.frame = CGRect(x: 0, y: 180, width: owner.view.bounds.width, height: owner.view.bounds.width * 2 / 3)
        owner.view.addSubview(gameView); core.add(gameView)
        let transport = PresenceHTTPTransport(peer: peer, port: port)
        let sharing = FriendSharingSession(configuration: .init(appID: String(repeating: "0", count: 32),
            channel: "presence-fixture", uid: peer == "A" ? 1 : 2, remoteUID: peer == "A" ? 2 : 1,
            token: "offline-fixture"), transport: transport, authenticatedMode: false)
        let display = BoundPlayerStateDisplay(), presence = sharing.livePresence
        let oldPreference = UserDefaults.standard.object(forKey: BoundPlayerStatePreferences.key)
        UserDefaults.standard.set(true, forKey: BoundPlayerStatePreferences.key)
        display.attachPresence(presence); display.install(in: owner); display.bind(core: core)
        display.layout(in: owner, gameView: gameView)
        defer {
            sharing.stop(); display.stop(); _ = core.stop(); window.isHidden = true; oldWindow?.makeKeyAndVisible()
            if let oldPreference { UserDefaults.standard.set(oldPreference, forKey: BoundPlayerStatePreferences.key) }
            else { UserDefaults.standard.removeObject(forKey: BoundPlayerStatePreferences.key) }
        }
        let probe = display.probe, booted = expectation(description: "VBA-M \(peer) overworld")
        var frame = 0, bootFinished = false, previousMask = 0
        core.updateHandler = { core in
            frame += 1
            if let reading = probe.receive(core), reading.status == .live, !bootFinished { bootFinished = true; booted.fulfill() }
            let mask = (1300..<1302).contains(frame) ? 8 : (1600..<1602).contains(frame) || (2200..<2202).contains(frame) ? 1 : 0
            for bit in [1, 8] where (mask & bit) != (previousMask & bit) {
                if mask & bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit, value: 1, playerIndex: 0) }
                else { core.deltaCore.emulatorBridge.deactivateInput(bit, playerIndex: 0) }
            }
            previousMask = mask
        }
        core.rate = 8; XCTAssertTrue(core.start()); await fulfillment(of: [booted], timeout: 90)
        XCTAssertTrue(core.pause()); core.rate = 1
        UserDefaults.standard.set(false, forKey: BoundPlayerStatePreferences.key)
        NotificationCenter.default.post(name: BoundPlayerStatePreferences.didChange, object: nil)
        presence.setEnabled(true); sharing.start()
        var movementFrame = 0, lastMask = 0
        let route = peer == "A" ? [32, 64, 16, 128] : [64, 32, 128, 16]
        core.updateHandler = { core in
            probe.receive(core)
            let segment = movementFrame % 208
            let mask = segment < 160 ? route[segment / 40] : 0
            for bit in [16, 32, 64, 128] where (mask & bit) != (lastMask & bit) {
                if mask & bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit, value: 1, playerIndex: 0) }
                else { core.deltaCore.emulatorBridge.deactivateInput(bit, playerIndex: 0) }
            }
            lastMask = mask; movementFrame += 1
        }
        XCTAssertTrue(core.resume()); core.audioManager.isEnabled = false
        var stage = "", visibleTicks = 0, positions = Set<String>(), cameras = Set<String>()
        var pausedHidden = false, offlineHidden = false, recoveredVisible = false, screenshot: UIImage?
        let deadline = ProcessInfo.processInfo.systemUptime + 150
        while ProcessInfo.processInfo.systemUptime < deadline {
            let next = try await transport.control()
            if next != stage {
                stage = next
                if stage == "pauseA", peer == "A" { XCTAssertTrue(core.pause()) }
                if stage == "resumed", peer == "A" { XCTAssertTrue(core.resume()); core.audioManager.isEnabled = false }
                if stage == "restore", peer == "A" { display.didLoadSaveState() }
            }
            if stage == "done" { break }
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(16))
                display.refreshDisplay(); display.layout(in: owner, gameView: gameView); gameView.layoutIfNeeded()
                if display.livePlayerOverlay.visiblePixels > 20 {
                    visibleTicks += 1
                    if let pose = presence.pose() { positions.insert("\(Int(pose.x)),\(Int(pose.y))") }
                    if ["recovered", "restore"].contains(stage) { recoveredVisible = true }
                    if screenshot == nil, let pose = presence.pose(), let local = display.hud.reading.player?.scene,
                       abs(pose.x - Double(local.worldFoot.x)) + abs(pose.y - Double(local.worldFoot.y)) >= 24 {
                        screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    }
                }
                if let scene = display.hud.reading.player?.scene { cameras.insert("\(scene.camera.x),\(scene.camera.y)") }
            }
            let hidden = display.livePlayerOverlay.isHidden
            if stage == "pauseA", hidden { pausedHidden = true }
            if stage == "offline", hidden { offlineHidden = true }
            try await transport.report(["stage": stage, "visibleTicks": visibleTicks, "positions": positions.count,
                "cameraPositions": cameras.count, "hidden": hidden, "received": presence.receivedPackets,
                "sent": presence.sentPackets, "rejected": presence.rejectedPackets,
                "epoch": presence.epoch.uuidString, "batteryName": battery.lastPathComponent])
        }
        XCTAssertEqual(stage, "done"); XCTAssertGreaterThan(visibleTicks, 30); XCTAssertGreaterThan(positions.count, 10)
        XCTAssertGreaterThan(cameras.count, 16); XCTAssertTrue(pausedHidden); XCTAssertTrue(offlineHidden); XCTAssertTrue(recoveredVisible)
        XCTAssertNotNil(screenshot); XCTAssertTrue(display.hud.isHidden, "Live presence works with the diagnostic card off")
        if let screenshot {
            let attachment = XCTAttachment(image: screenshot); attachment.name = "VBA-M live peer \(peer)"; attachment.lifetime = .keepAlways; add(attachment)
            try screenshot.pngData()?.write(to: root.appendingPathComponent("live-peer-\(peer).png"), options: .atomic)
        }
        sharing.stop(); XCTAssertTrue(display.livePlayerOverlay.isHidden)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: rom)), romHash)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: seed)), seedHash)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: battery)), seedHash)
        let report: [String: Any] = ["peer": peer, "engine": "VBA-M", "transport": "test-only loopback HTTP",
            "visibleTicks": visibleTicks, "distinctRemotePositions": positions.count, "cameraPositions": cameras.count,
            "received": presence.receivedPackets, "sent": presence.sentPackets, "pausedHidden": pausedHidden,
            "offlineHidden": offlineHidden, "recoveredVisible": recoveredVisible, "independentBattery": battery.lastPathComponent,
            "romSeedAndBatteryUnchanged": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("live-peer-\(peer)-report.json"), options: .atomic)
    }
}
