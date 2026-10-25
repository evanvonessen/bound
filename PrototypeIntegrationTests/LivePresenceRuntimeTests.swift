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

/// One-use access session for the two dedicated QA accounts. Never a password,
/// refresh token, app certificate or production app's persisted session.
private struct PresenceAgoraIdentity: Decodable {
    let owner: UUID
    let key: String
    let token: String
    let roomID: String
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
    private var presenceSends = 0
    private var presenceReceives = 0
    var presenceConnectionCheck: BoundPresenceTransportCheck {
        .init(kind: .fixture, acceptedSends: presenceSends, receivedMessages: presenceReceives)
    }
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
                        presenceReceives += 1
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
        presenceSends += 1
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
    private var previousExperimentalFeature: Any?
    override func setUp() {
        super.setUp()
        previousExperimentalFeature = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
    }
    override func tearDown() {
        UserDefaults.standard.set(previousExperimentalFeature, forKey: BoundMultiplayerFeatures.key)
        NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
        super.tearDown()
    }

    /// Two independent cores exchange actual production presence packets. One
    /// runs native shoes at 3x while the other remains stationary at 1x, then swap.
    func testConnectedBoundaryRunning() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let peer = env["BOUND_PAIR_PEER"], let port = env["BOUND_PAIR_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Use live-presence-relay.py --boundaries")
        }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MultiplayerValidation")
        let rom = root.appendingPathComponent("RadicalRed.gba"), seed = root.appendingPathComponent("seed.sav")
        let romHash = SHA256.hash(data: try Data(contentsOf: rom)), seedHash = SHA256.hash(data: try Data(contentsOf: seed))
        let battery = root.appendingPathComponent("boundary-\(peer).sav")
        try Data(repeating: 0xFF, count: 0x20000).write(to: battery)
        let profile = try BoundPlayerROMProfile(rom: Data(contentsOf: rom))
        let core = try XCTUnwrap(EmulatorCore(game: PresenceRuntimeGame(fileURL: rom, gameSaveURL: battery), options: [.metal: true]))
        core.audioManager.isEnabled = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), owner = UIViewController(), view = GameView()
        window.rootViewController = owner; window.makeKeyAndVisible(); owner.view.frame = window.bounds
        view.frame = CGRect(x: 0, y: 180, width: owner.view.bounds.width, height: owner.view.bounds.width * 2 / 3)
        owner.view.addSubview(view); core.add(view)
        let transport = PresenceHTTPTransport(peer: peer, port: port)
        let sharing = FriendSharingSession(configuration: .init(appID: String(repeating: "0", count: 32), channel: "boundary-fixture",
            uid: peer == "A" ? 1 : 2, remoteUID: peer == "A" ? 2 : 1, token: "offline-fixture"), transport: transport, authenticatedMode: false)
        let display = BoundPlayerStateDisplay(), presence = sharing.livePresence
        let oldPreference = UserDefaults.standard.object(forKey: BoundPlayerStatePreferences.key)
        UserDefaults.standard.set(true, forKey: BoundPlayerStatePreferences.key)
        display.attachPresence(presence); display.install(in: owner); display.bind(core: core); display.layout(in: owner, gameView: view)
        defer {
            sharing.stop(); display.stop(); _ = core.stop(); window.isHidden = true; oldWindow?.makeKeyAndVisible()
            UserDefaults.standard.set(oldPreference, forKey: BoundPlayerStatePreferences.key)
        }
        presence.setEnabled(true); sharing.start()
        let setup = NativePlayerSceneSetup(core: core, debugPlayer: peer == "A" ? 1 : 2), probe = display.probe
        let booted = expectation(description: "Native field \(peer)")
        var ready = false
        core.updateHandler = { core in
            setup.receive(core)
            if let reading = probe.receive(core), !ready, setup.isReady, reading.player?.scene != nil { ready = true; booted.fulfill() }
        }
        core.rate = 8; XCTAssertTrue(core.start()); core.audioManager.isEnabled = false
        await fulfillment(of: [booted], timeout: 90)
        XCTAssertTrue(core.pause()); core.rate = 1
        XCTAssertTrue(BoundVBABattleBridge.qaWarpPalletEntrance()); XCTAssertTrue(core.resume())
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(20)); display.refreshDisplay()
            if display.hud.reading.player?.mapNumber == 0, display.hud.reading.player?.scene != nil { break }
        }
        let anchor = try XCTUnwrap(display.hud.reading.player)
        XCTAssertTrue(core.pause())
        XCTAssertEqual(anchor.mapNumber, 0)
        UserDefaults.standard.set(false, forKey: BoundPlayerStatePreferences.key)
        NotificationCenter.default.post(name: BoundPlayerStatePreferences.didChange, object: nil)
        let samples = BoundaryPresentationSamples(), control = BoundaryPhaseControl()
        var stage = "", nativeStage = "ready", movementFrame = 0, lastMask = 0, active = false
        probe.compositor.observeFrame = { reading, rendered, pixels in
            guard active else { return }
            samples.append(reading: reading, rendered: rendered, pixels: pixels, profile: profile, anchor: anchor)
        }
        core.updateHandler = { core in
            probe.receive(core)
            let next = control.read()
            if next != nativeStage {
                nativeStage = next; samples.reset(stage: next)
                movementFrame = next == "run" + peer ? 0 : 360
                active = next.hasPrefix("run")
            }
            guard active else { return }
            // Four up/down excursions through the Pallet/Route 1 seam, followed
            // by horizontal running. Inputs and duration use native frames.
            let segment = movementFrame / 36
            let route = [64, 128, 64, 128, 64, 128, 64, 128, 32, 16]
            let mask = segment < route.count ? route[segment] | 2 : 0
            for bit in [2, 16, 32, 64, 128] where (mask & bit) != (lastMask & bit) {
                if mask & bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit, value: 1, playerIndex: 0) }
                else { core.deltaCore.emulatorBridge.deactivateInput(bit, playerIndex: 0) }
            }
            lastMask = mask; movementFrame += 1
        }
        XCTAssertTrue(core.resume())
        var reports: [[String: Any]] = [], missingPoseTicks = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while ProcessInfo.processInfo.systemUptime < deadline {
            let next = try await transport.control()
            if next == "done" { stage = next; break }
            if next != stage {
                if stage.hasPrefix("run") { reports.append(samples.report(stage: stage, moving: stage == "run" + peer)) }
                stage = next; missingPoseTicks = 0
                // Switch roles without pausing either core or the presence session.
                core.rate = stage == "run" + peer ? 3 : 1
                control.set(stage)
                if stage == "reset" {
                    // Separate the two cases at the same clear entrance. The
                    // preceding horizontal route can end behind town scenery.
                    while samples.report(stage: stage, moving: false)["stage"] as? String != stage {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    if peer == "A" {
                        XCTAssertTrue(core.pause()); XCTAssertTrue(BoundVBABattleBridge.qaWarpPalletEntrance())
                        XCTAssertTrue(core.resume()); core.audioManager.isEnabled = false
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(20))
            display.refreshDisplay(); display.layout(in: owner, gameView: view)
            if stage.hasPrefix("run"), presence.pose() == nil { missingPoseTicks += 1 }
            var report = samples.report(stage: stage, moving: stage == "run" + peer)
            report["ready"] = presence.receivedPackets > 10 && presence.pose() != nil
            let local = display.hud.reading.player
            let remote = presence.pose()
            report["resetReady"] = local?.mapNumber == 0 && local?.tile == anchor.tile
                && local?.scene != nil && remote?.mapNumber == 0
                && remote?.x == Double(anchor.scene!.worldFoot.x) && remote?.y == Double(anchor.scene!.worldFoot.y)
            report["finished"] = (report["frames"] as? Int ?? 0) >= 420
            report["received"] = presence.receivedPackets; report["sent"] = presence.sentPackets
            report["missingPoseTicks"] = missingPoseTicks
            try await transport.report(report)
        }
        XCTAssertTrue(core.pause())
        if stage == "done" { reports.append(samples.report(stage: "runB", moving: peer == "B")) }
        XCTAssertEqual(stage, "done")
        for report in reports {
            XCTAssertGreaterThan(report["frames"] as? Int ?? 0, 60)
            XCTAssertEqual(report["missingScenes"] as? Int, 0)
            XCTAssertEqual(report["missingProjectedPeers"] as? Int, 0)
            XCTAssertEqual(report["missingVisibleSprites"] as? Int, 0)
            XCTAssertGreaterThan(report["clearVisibleFrames"] as? Int ?? 0, 10)
            XCTAssertGreaterThan(report["crossMapFrames"] as? Int ?? 0, 10)
            if report["moving"] as? Bool == true {
                XCTAssertGreaterThan(report["routeFrames"] as? Int ?? 0, 10)
                XCTAssertLessThanOrEqual(report["stationaryWorldSpread"] as? Double ?? 999, 0.01)
            }
        }
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: rom)), romHash)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: seed)), seedHash)
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("boundary-\(peer)-report.json"))
    }

    func testTwoVBAMInstancesExchangeLivePoses() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let peer = env["BOUND_PAIR_PEER"], ["A", "B"].contains(peer),
              let port = env["BOUND_PAIR_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Run PrototypeTools/live-presence-relay.py with two dedicated Simulators")
        }
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MultiplayerValidation", isDirectory: true)
        let realAgora = env["BOUND_PAIR_AGORA"] == "1"
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
        let sharing: FriendSharingSession
        if realAgora {
            let input = root.appendingPathComponent("agora-session.json")
            let bytes = try Data(contentsOf: input)
            try FileManager.default.removeItem(at: input)
            guard bytes.count <= 16384,
                  let value = try? JSONDecoder().decode(PresenceAgoraIdentity.self, from: bytes),
                  UUID(uuidString: value.roomID) != nil,
                  let identity = try? AppCloudSession(owner: value.owner, key: value.key, token: value.token) else {
                XCTFail("Invalid one-use QA session; details redacted"); return
            }
            sharing = FriendSharingSession(configuration: nil, authenticatedMode: true)
            sharing.configureAuthenticatedRoom(value.roomID, identity: { identity })
        } else {
            sharing = FriendSharingSession(configuration: .init(appID: String(repeating: "0", count: 32),
                channel: "presence-fixture", uid: peer == "A" ? 1 : 2, remoteUID: peer == "A" ? 2 : 1,
                token: "offline-fixture"), transport: transport, authenticatedMode: false)
        }
        let tap = BoundDeltaFrameTap { frame in sharing.receivePlaybackFrame(frame) }
        tap.setEnabled(realAgora)
        let display = BoundPlayerStateDisplay(), presence = sharing.livePresence
        let oldPreference = UserDefaults.standard.object(forKey: BoundPlayerStatePreferences.key)
        UserDefaults.standard.set(true, forKey: BoundPlayerStatePreferences.key)
        display.attachPresence(presence); display.install(in: owner); display.bind(core: core)
        display.layout(in: owner, gameView: gameView)
        defer {
            tap.setEnabled(false)
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
        presence.connectionCheck.start()
        var movementFrame = 0, lastMask = 0
        let route = peer == "A" ? [32, 64, 16, 128] : [64, 32, 128, 16]
        core.updateHandler = { core in
            probe.receive(core)
            tap.receive(core)
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
        let deadline = ProcessInfo.processInfo.systemUptime + (realAgora ? 300 : 150)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let next = try await transport.control()
            if next != stage {
                stage = next
                if stage == "pauseA", peer == "A" { XCTAssertTrue(core.pause()) }
                if stage == "resumed", peer == "A" { XCTAssertTrue(core.resume()); core.audioManager.isEnabled = false }
                if stage == "restore", peer == "A" { display.didLoadSaveState() }
                if realAgora, stage == "offline", peer == "B" { sharing.stop() }
                if realAgora, stage == "recovered", peer == "B" { sharing.start() }
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
                "epoch": presence.epoch.uuidString, "batteryName": battery.lastPathComponent,
                "agora": realAgora, "joined": sharing.joined,
                "tokenRenewals": presence.connectionCheck.samples.last?.tokenRenewals ?? 0,
                "videoReceivedFrames": sharing.receivedFrames])
        }
        XCTAssertEqual(stage, "done"); XCTAssertGreaterThan(visibleTicks, 30); XCTAssertGreaterThan(positions.count, 10)
        XCTAssertGreaterThan(cameras.count, 16); XCTAssertTrue(pausedHidden); XCTAssertTrue(offlineHidden); XCTAssertTrue(recoveredVisible)
        XCTAssertNotNil(screenshot); XCTAssertTrue(display.hud.isHidden, "Live presence works with the diagnostic card off")
        presence.connectionCheck.stop()
        XCTAssertGreaterThan(presence.connectionCheck.sampleCount, 1)
        XCTAssertTrue(presence.connectionCheck.samples.contains { $0.reader.visiblePixels > 20 && $0.reader.movementChanges > 10 })
        XCTAssertTrue(presence.connectionCheck.samples.allSatisfy { $0.transport.kind == (realAgora ? .agora : .fixture) })
        if realAgora {
            XCTAssertTrue(presence.connectionCheck.samples.contains { $0.authenticated && $0.authorizationReady && $0.joined })
            XCTAssertTrue(presence.connectionCheck.samples.contains { $0.tokenRenewals >= 2 })
            XCTAssertTrue(presence.connectionCheck.samples.contains { $0.videoReceivedFrames > 30 },
                          "Actual native video must also cross Agora before the scripted rejoin resets its counters")
        }
        try presence.connectionCheck.export().write(to: root.appendingPathComponent("connection-check-\(peer).json"), options: .atomic)
        if let screenshot {
            let attachment = XCTAttachment(image: screenshot); attachment.name = "VBA-M live peer \(peer)"; attachment.lifetime = .keepAlways; add(attachment)
            try screenshot.pngData()?.write(to: root.appendingPathComponent("live-peer-\(peer).png"), options: .atomic)
        }
        sharing.stop(); XCTAssertTrue(display.livePlayerOverlay.isHidden)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: rom)), romHash)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: seed)), seedHash)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: battery)), seedHash)
        let report: [String: Any] = ["peer": peer, "engine": "VBA-M", "transport": realAgora ? "authenticated Agora" : "test-only loopback HTTP",
            "visibleTicks": visibleTicks, "distinctRemotePositions": positions.count, "cameraPositions": cameras.count,
            "received": presence.receivedPackets, "sent": presence.sentPackets, "pausedHidden": pausedHidden,
            "offlineHidden": offlineHidden, "recoveredVisible": recoveredVisible, "independentBattery": battery.lastPathComponent,
            "romSeedAndBatteryUnchanged": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("live-peer-\(peer)-report.json"), options: .atomic)
    }
}

/// Stores scalar evidence only; no ROM, RAM or image payloads in relay reports.
private final class BoundaryPresentationSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var measuredStage = "ready"
    private var missingDetails: [String] = []
    private var frames = 0, missingScenes = 0, missingPeers = 0, missingSprites = 0
    private var visible = 0, crossMap = 0, route = 0
    private var xs: [Double] = [], ys: [Double] = []
    func reset(stage: String) {
        lock.lock(); defer { lock.unlock() }; measuredStage = stage
        frames = 0; missingScenes = 0; missingPeers = 0; missingSprites = 0; missingDetails = []
        visible = 0; crossMap = 0; route = 0; xs = []; ys = []
    }
    func append(reading: BoundPlayerStateReading, rendered: BoundRecordedPlayerPose?, pixels: Int,
                profile: BoundPlayerROMProfile, anchor: BoundPlayerState) {
        lock.lock(); defer { lock.unlock() }; frames += 1
        guard let player = reading.player, let scene = player.scene else {
            missingScenes += 1; if missingDetails.count < 5 { missingDetails.append(reading.detail) }; return
        }
        if player.mapNumber == 19 { route += 1 }
        guard let rendered else { missingPeers += 1; return }
        if let offset = profile.sceneAssets.mapOffset(fromGroup: anchor.mapGroup, number: anchor.mapNumber,
            toGroup: player.mapGroup, number: player.mapNumber, rom: profile.bytes) {
            xs.append(rendered.x + Double(offset.x * 16)); ys.append(rendered.y + Double(offset.y * 16))
        }
        // Different local maps are evidenced by the stationary peer being in
        // Pallet while the mover's native map is Route 1 (or vice versa).
        if player.mapNumber == 19 || rendered.y < 0 { crossMap += 1 }
        let origin = BoundPlayerViewport.origin(pose: rendered, scene: scene)
        if abs(rendered.y - Double(scene.worldFoot.y)) >= 32,
           abs(rendered.x - Double(scene.worldFoot.x)) < 16 {
            // The town camera is clamped at its north edge: the approaching
            // runner is partially visible at the top, not a full 32px sprite.
            // Account for clipping and the native map-name popup explicitly.
            let ui = BoundPlayerBackground(tiles: scene.background.tiles,
                layers: scene.background.layers.filter(\.masksWholeTiles))
            let expected = (0..<32).reduce(0) { count, y in count + (0..<16).filter { x in
                let sx = origin.x + x, sy = origin.y + y
                return (0..<240).contains(sx) && (0..<160).contains(sy)
                    && rendered.appearance.colorIndex(x: x, y: y) != 0
                    && !ui.covers(x: sx, y: sy, priority: rendered.appearance.priority)
            }.count }
            if expected > 0 { visible += 1; if pixels == 0 { missingSprites += 1 } }
        }
    }
    func report(stage: String, moving: Bool) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["stage": measuredStage, "moving": moving, "frames": frames, "missingScenes": missingScenes,
            "missingProjectedPeers": missingPeers, "missingVisibleSprites": missingSprites, "missingDetails": missingDetails,
            "clearVisibleFrames": visible, "crossMapFrames": crossMap, "routeFrames": route,
            "stationaryWorldSpread": (xs.max() ?? 0) - (xs.min() ?? 0) + (ys.max() ?? 0) - (ys.min() ?? 0)]
    }
}

private final class BoundaryPhaseControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stage = "ready"
    func set(_ value: String) { lock.lock(); stage = value; lock.unlock() }
    func read() -> String { lock.lock(); defer { lock.unlock() }; return stage }
}
