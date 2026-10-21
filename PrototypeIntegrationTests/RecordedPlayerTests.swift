import XCTest
import UIKit
import CryptoKit
@preconcurrency import DeltaCore
@testable import Delta

private struct ReplayGame: GameProtocol {
    let fileURL: URL
    let gameSaveURL: URL
    var type: GameType { .gba }
}

private final class ReplayReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BoundPlayerStateReading] = []
    func append(_ value: BoundPlayerStateReading) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [BoundPlayerStateReading] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
final class RecordedPlayerTests: XCTestCase {
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

    private func sprite(priority: Int = 2, flip: Bool = false) -> BoundPlayerSprite {
        var palette = Data(repeating: 0, count: 32); palette[2] = 31
        return .init(width: 16, height: 32, tiles: Data(repeating: 0x11, count: 256), palette: palette,
                     flipX: flip, flipY: false, priority: priority)
    }
    private func scene(x: Int = 104, y: Int = 112, cameraX: Int = 16, cameraY: Int = -24,
                       background: BoundPlayerBackground? = nil, objects: [BoundPlayerSceneObject] = []) -> BoundPlayerScene {
        .init(worldFoot: .init(x: x, y: y), camera: .init(x: cameraX, y: cameraY), appearance: sprite(),
              background: background ?? .init(tiles: Data(repeating: 0, count: 32768), layers: []), objects: objects)
    }
    private func pose(x: Double = 104, y: Double = 112, map: Int = 1) -> BoundRecordedPlayerPose {
        .init(mapGroup: 4, mapNumber: map, elevation: 0, x: x, y: y, appearance: sprite())
    }
    private func reading(frame: UInt64, x: Int = 104, map: Int = 1) -> BoundPlayerStateReading {
        var player = BoundPlayerState(mapGroup: 4, mapNumber: map, tile: .init(x: 6, y: 6), previousTile: .init(x: 6, y: 6),
            facing: "South", elevation: 0, graphicsID: 0, runningState: 0, tileTransitionState: 0)
        player.scene = scene(x: x)
        return .init(frame: frame, status: .live, detail: "Fixture", player: player)
    }

    func testCameraMovesByOnePixelAcrossDestinationTileAndSignedWrap() {
        func camera(x: Int = 6, y: Int = 6, rx: Int = 0, ry: Int = 0, total: Int = 0) -> BoundPlayerState.Point {
            BoundPlayerSceneDecoder.camera(save: .init(x: x, y: y), residual: .init(x: rx, y: ry),
                total: .init(x: total, y: total), offset: .init(x: BoundSceneBytes.wrap(total), y: BoundSceneBytes.wrap(total - 40)))
        }
        XCTAssertEqual(camera(), .init(x: 16, y: -24))
        for progress in 1...15 {
            XCTAssertEqual(camera(x: 7, rx: progress).x, 16 - progress)
            XCTAssertEqual(camera(x: 5, rx: -progress).x, 16 + progress)
            XCTAssertEqual(camera(y: 7, ry: progress).y, -24 - progress)
            XCTAssertEqual(camera(y: 5, ry: -progress).y, -24 + progress)
        }
        XCTAssertEqual(camera(x: 7).x, 0)
        XCTAssertEqual(camera(total: 32760), camera())
        XCTAssertEqual(camera(total: -32760), camera())
    }

    func testFourBitTilesRespectTransparencyAndHorizontalFlip() {
        var bytes = Data(repeating: 0, count: 256); bytes[0] = 0x21; bytes[32] = 0x43
        let normal = BoundPlayerSprite(width: 16, height: 32, tiles: bytes, palette: Data(repeating: 0, count: 32),
                                       flipX: false, flipY: false, priority: 2)
        let flipped = BoundPlayerSprite(width: 16, height: 32, tiles: bytes, palette: normal.palette,
                                        flipX: true, flipY: false, priority: 2)
        XCTAssertEqual(normal.colorIndex(x: 0, y: 0), 1); XCTAssertEqual(normal.colorIndex(x: 1, y: 0), 2)
        XCTAssertEqual(normal.colorIndex(x: 8, y: 0), 3)
        XCTAssertEqual(flipped.colorIndex(x: 15, y: 0), 1)
        XCTAssertEqual(flipped.colorIndex(x: 7, y: 0), 3)
        XCTAssertEqual(normal.colorIndex(x: -1, y: 0), 0)
    }

    func testLZ77BoundsAndOverlappingCopy() {
        func decode(_ bytes: [UInt8]) -> [UInt8]? {
            BoundPlayerSceneAssets.decompress(address: 0) { address, count in
                guard address >= 0, address + count <= bytes.count else { return nil }
                return Array(bytes[address..<address + count])
            }
        }
        XCTAssertEqual(decode([0x10, 6, 0, 0, 0x40, 7, 0x20, 0]), [7, 7, 7, 7, 7, 7])
        XCTAssertNil(decode([0x10, 6, 0, 0, 0x80, 0, 0]))
        XCTAssertNil(decode([0x10, 0, 0, 1]))
        XCTAssertNil(decode([0x10, 1, 0, 0, 0]))
    }

    func testTrackInterpolatesOnlyContinuousWorldMovementAndHasBoundedDuration() {
        var track = BoundRecordedPlayerTrack()
        track.append(frame: 0, pose: pose()); track.append(frame: 4, pose: pose(x: 108))
        XCTAssertEqual(track.pose(at: 2)?.x, 106)
        track.append(frame: 5, pose: nil); track.append(frame: 7, pose: pose(x: 112))
        XCTAssertNil(track.pose(at: 6))
        track.append(frame: 10, pose: pose(x: 112, map: 2))
        XCTAssertNil(track.pose(at: 8))
        track.append(frame: 30, pose: pose(x: 113, map: 2))
        XCTAssertNil(track.pose(at: 15))
        track.append(frame: 31, pose: pose(x: 999, map: 2))
        track.append(frame: 1801, pose: pose())
        XCTAssertEqual(track.end, 31)
        XCTAssertNil(track.pose(at: 32))
    }

    func testRecordingPlaybackPauseMapMismatchAndSaveRestoreNeverKeepOldPose() {
        let session = BoundRecordedPlayerSession()
        session.record()
        for frame in UInt64(1)...20 { session.consume(reading(frame: frame, x: 104 + Int(frame))) }
        session.suspend()
        XCTAssertTrue(session.hasRecording); XCTAssertEqual(session.mode, .idle)
        session.play(); session.consume(reading(frame: 1))
        XCTAssertEqual(session.pose?.x, 105)
        session.consume(.inactive(.paused, "Pause")); XCTAssertNil(session.pose)
        session.consume(reading(frame: 1, map: 2)); XCTAssertNil(session.pose)
        session.consume(reading(frame: 2)); XCTAssertNotNil(session.pose)
        session.stop(); XCTAssertNil(session.pose)
        session.play()
        for frame in UInt64(1)...25 { session.consume(reading(frame: frame)) }
        XCTAssertEqual(session.mode, .idle); XCTAssertNil(session.pose)
        session.clear(); XCTAssertFalse(session.hasRecording)
    }

    func testRasterizerUsesViewerCameraClipsAndMasksForegroundAndNearerObjects() {
        let p = pose(), s = scene()
        let (pixels, origin) = BoundRecordedPlayerRasterizer.rgba(pose: p, scene: s)
        XCTAssertEqual(origin, .init(x: 112, y: 56))
        XCTAssertEqual(pixels[3], 255); XCTAssertEqual(pixels[0], 255)
        let shifted = BoundRecordedPlayerRasterizer.rgba(pose: p, scene: scene(cameraX: -16)).1
        XCTAssertEqual(shifted.x, origin.x - 32)
        var tiles = Data(repeating: 0, count: 32768)
        tiles.replaceSubrange(32..<64, with: repeatElement(UInt8(0x11), count: 32))
        var map = Data(repeating: 0, count: 2048)
        for index in stride(from: 0, to: map.count, by: 2) { map[index] = 1 }
        let foreground = BoundPlayerBackground(tiles: tiles, layers: [.init(priority: 1, scrollX: 0, scrollY: 0, map: map)])
        let hidden = BoundRecordedPlayerRasterizer.rgba(pose: p, scene: scene(background: foreground)).0
        XCTAssertFalse(stride(from: 3, to: hidden.count, by: 4).contains { hidden[$0] != 0 })
        let behind = BoundPlayerBackground(tiles: tiles, layers: [.init(priority: 2, scrollX: 0, scrollY: 0, map: map)])
        XCTAssertEqual(BoundRecordedPlayerRasterizer.rgba(pose: p, scene: scene(background: behind)).0, pixels)
        let nearer = BoundPlayerSceneObject(origin: origin, footY: 88, appearance: sprite())
        let masked = BoundRecordedPlayerRasterizer.rgba(pose: p, scene: scene(objects: [nearer])).0
        XCTAssertFalse(stride(from: 3, to: masked.count, by: 4).contains { masked[$0] != 0 })
        let offscreen = BoundRecordedPlayerRasterizer.rgba(pose: pose(x: -100), scene: s).0
        XCTAssertFalse(stride(from: 3, to: offscreen.count, by: 4).contains { offscreen[$0] != 0 })
    }

    func testActualVBAMRecordingAndReplayAgainstMovingCamera() async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MultiplayerValidation", isDirectory: true)
        let rom = root.appendingPathComponent("RadicalRed.gba"), seed = root.appendingPathComponent("seed.sav")
        guard FileManager.default.fileExists(atPath: rom.path) else { throw XCTSkip("Install private fixtures per Docs/BOUND-MULTIPLAYER.md") }
        let originalROM = SHA256.hash(data: try Data(contentsOf: rom)), originalSeed = SHA256.hash(data: try Data(contentsOf: seed))
        let battery = root.appendingPathComponent("vbam-replay-test.sav")
        try Data(contentsOf: seed).write(to: battery, options: .atomic)
        let core = try XCTUnwrap(EmulatorCore(game: ReplayGame(fileURL: rom, gameSaveURL: battery), options: [.metal: true]))
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = windowScene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: windowScene), owner = UIViewController(), gameView = GameView()
        window.rootViewController = owner; window.makeKeyAndVisible(); owner.view.frame = window.bounds
        owner.view.backgroundColor = .black
        gameView.frame = CGRect(x: 0, y: 180, width: owner.view.bounds.width, height: owner.view.bounds.width * 2 / 3)
        owner.view.addSubview(gameView); core.add(gameView)
        let display = BoundPlayerStateDisplay(), readings = ReplayReadings()
        let oldPreference = UserDefaults.standard.object(forKey: BoundPlayerStatePreferences.key)
        UserDefaults.standard.set(true, forKey: BoundPlayerStatePreferences.key)
        display.install(in: owner); display.bind(core: core); display.layout(in: owner, gameView: gameView)
        defer {
            display.stop(); _ = core.stop(); window.isHidden = true; oldWindow?.makeKeyAndVisible()
            if let oldPreference { UserDefaults.standard.set(oldPreference, forKey: BoundPlayerStatePreferences.key) }
            else { UserDefaults.standard.removeObject(forKey: BoundPlayerStatePreferences.key) }
        }
        let probe = display.probe, booted = expectation(description: "VBA-M overworld")
        var bootFrame = 0, bootFinished = false, previousMask = 0
        core.updateHandler = { core in
            bootFrame += 1
            if let reading = probe.receive(core), reading.status == .live, !bootFinished { bootFinished = true; booted.fulfill() }
            let mask = (1300..<1302).contains(bootFrame) ? 8 : (1600..<1602).contains(bootFrame) || (2200..<2202).contains(bootFrame) ? 1 : 0
            for bit in [1, 8] where (mask & bit) != (previousMask & bit) {
                if mask & bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit, value: 1, playerIndex: 0) }
                else { core.deltaCore.emulatorBridge.deactivateInput(bit, playerIndex: 0) }
            }
            previousMask = mask
        }
        core.rate = 8; XCTAssertTrue(core.start()); await fulfillment(of: [booted], timeout: 60)
        XCTAssertTrue(core.pause()); core.rate = 1
        gameView.frame = CGRect(x: 0, y: 180, width: owner.view.bounds.width, height: owner.view.bounds.width * 2 / 3)
        gameView.layoutIfNeeded()

        func movement(_ segments: [(Int, Int)], name: String) async {
            let done = expectation(description: name)
            var frame = 0, lastMask = 0, finished = false
            let duration = segments.reduce(0) { $0 + $1.1 }
            core.updateHandler = { core in
                if let reading = probe.receive(core) {
                    readings.append(reading)
                }
                var start = 0, mask = 0
                for (buttons, count) in segments {
                    if frame >= start, frame < start + count { mask = buttons; break }; start += count
                }
                for bit in [16, 32, 64, 128] where (mask & bit) != (lastMask & bit) {
                    if mask & bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit, value: 1, playerIndex: 0) }
                    else { core.deltaCore.emulatorBridge.deactivateInput(bit, playerIndex: 0) }
                }
                lastMask = mask; frame += 1
                if frame > duration, !finished { finished = true; done.fulfill() }
            }
            XCTAssertTrue(core.resume()); await fulfillment(of: [done], timeout: 20)
            XCTAssertTrue(core.pause())
        }

        UserDefaults.standard.set(false, forKey: BoundPlayerStatePreferences.key)
        NotificationCenter.default.post(name: BoundPlayerStatePreferences.didChange, object: nil)
        display.recordingSession.record()
        XCTAssertTrue(display.hud.isHidden, "Recording works independently of the diagnostic card")
        await movement([(32, 40), (64, 40), (16, 40), (128, 40), (0, 40)], name: "Record four directions")
        let captured = readings.snapshot(), scenes = captured.compactMap { $0.player?.scene }
        let diagnostic: [String: Any] = ["readings": captured.count, "scenes": scenes.count,
            "camera": scenes.prefix(40).map { [$0.camera.x, $0.camera.y] },
            "world": scenes.prefix(40).map { [$0.worldFoot.x, $0.worldFoot.y] }]
        try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("vbam-replay-diagnostic.json"), options: .atomic)
        XCTAssertGreaterThan(scenes.count, 100)
        XCTAssertTrue(display.recordingSession.hasRecording)
        XCTAssertGreaterThan(display.recordingSession.track.samples.count, 60)
        XCTAssertGreaterThan(Set(scenes.map { $0.camera.x }).count, 16)
        XCTAssertGreaterThan(Set(scenes.map { $0.worldFoot.x }).count, 16)
        XCTAssertGreaterThan(Set(scenes.map(\.appearance)).count, 6)

        UserDefaults.standard.set(true, forKey: BoundPlayerStatePreferences.key)
        NotificationCenter.default.post(name: BoundPlayerStatePreferences.didChange, object: nil)
        await movement([(16, 40), (0, 8)], name: "Move viewer independently")
        display.recordingSession.play()
        // A different input route runs while the recorded player follows its own.
        var replayFrame = 0
        core.updateHandler = { core in
            if let reading = probe.receive(core) { readings.append(reading) }
            if replayFrame == 0 { core.deltaCore.emulatorBridge.activateInput(64, value: 1, playerIndex: 0) }
            if replayFrame == 40 { core.deltaCore.emulatorBridge.deactivateInput(64, playerIndex: 0) }
            replayFrame += 1
        }
        XCTAssertTrue(core.resume())
        var visible = 0, positions = Set<String>(), screenshot: UIImage?, replayDiagnostic: [[String: Any]] = []
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(16))
            display.refreshDisplay(); display.layout(in: owner, gameView: gameView); gameView.layoutIfNeeded()
            let current = display.hud.reading
            replayDiagnostic.append(["status": current.status.rawValue, "mode": String(describing: display.recordingSession.mode),
                "message": display.recordingSession.message, "frame": current.frame, "scene": current.player?.scene != nil,
                "pose": display.recordingSession.pose.map { [$0.x, $0.y] } ?? [],
                "pixels": display.recordedPlayerOverlay.visiblePixels,
                "layers": current.player?.scene?.background.layers.map { [$0.priority, $0.scrollX, $0.scrollY] } ?? []])
            if display.recordedPlayerOverlay.visiblePixels > 20, !display.recordedPlayerOverlay.isHidden {
                visible += 1
                positions.insert(display.recordedPlayerOverlay.accessibilityValue ?? "")
                var separation = 0.0
                if let pose = display.recordingSession.pose, let local = current.player?.scene {
                    separation = abs(pose.x - Double(local.worldFoot.x)) + abs(pose.y - Double(local.worldFoot.y))
                }
                if screenshot == nil, separation >= 32 {
                    screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                }
            }
        }
        XCTAssertGreaterThan(visible, 30); XCTAssertGreaterThan(positions.count, 10)
        XCTAssertNotNil(screenshot, "Capture two separately positioned player sprites")
        try JSONSerialization.data(withJSONObject: replayDiagnostic, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("vbam-replay-ticks.json"), options: .atomic)
        if let screenshot {
            let attachment = XCTAttachment(image: screenshot); attachment.name = "VBA-M recorded player on live map"; attachment.lifetime = .keepAlways; add(attachment)
            try screenshot.pngData()?.write(to: root.appendingPathComponent("vbam-recorded-player.png"), options: .atomic)
        }
        XCTAssertTrue(core.pause())
        XCTAssertTrue(display.recordedPlayerOverlay.isHidden)
        display.didLoadSaveState(); XCTAssertEqual(display.recordingSession.mode, .idle)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: rom)), originalROM)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: seed)), originalSeed)
        let report: [String: Any] = ["engine": "VBA-M", "sceneFrames": scenes.count, "recordedSamples": display.recordingSession.track.samples.count,
            "visibleReplayTicks": visible, "distinctReplayPositions": positions.count, "cameraPixelPositions": Set(scenes.map { $0.camera.x }).count,
            "worldPixelPositions": Set(scenes.map { $0.worldFoot.x }).count, "spriteFrames": Set(scenes.map(\.appearance)).count,
            "recordedWithDiagnosticCardOff": true, "romAndSeedUnchanged": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("vbam-recorded-player-report.json"), options: .atomic)
    }
}
