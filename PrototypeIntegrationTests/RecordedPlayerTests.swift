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

/// Current cartridges require Bound's admitted New Game data, not a legacy
/// Continue button sequence. Only the published host ABI is written; the ROM
/// performs its own intro, settings, map and player initialization.
final class NativePlayerSceneSetup {
    private let probe = BoundROMMultiplayerProbe()
    private var host = BoundROMHostState()
    private var frames = 0
    var isReady: Bool { probe.read()?.permitsFieldInterruption == true && probe.read()?.settingsApplied == true }

    init(core: EmulatorCore) {
        let options = BoundMultiplayerSetupOptions()
        host.enabled = true; host.linked = true; host.setupCommitted = true
        host.externalSetup = true; host.status = .complete; host.run = UUID()
        host.localSeed = 0x12345678; host.partnerSeed = 0x87654321
        host.settings = options.settings; host.playerProfile = options.profile
        probe.configure(core: core); probe.setVerified(true)
    }

    // Accessed only from the emulator's completed-frame callback after init.
    func receive(_ core: EmulatorCore) {
        if frames % 60 == 0 { probe.publish(host) }
        frames += 1; probe.receive(core)
        if probe.read()?.safeField == true { host.externalSetup = false }
    }
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

    func testScriptLockedFieldKeepsSceneAndMasksOnlyNativeWindowTiles() throws {
        var work = Data(repeating: 0, count: 0x40000)
        var internalRAM = Data(repeating: 0, count: 0x8000)
        func bytes(_ value: Int, _ count: Int = 4) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        func put(_ value: Int, _ address: Int, _ count: Int = 4) {
            if address >= 0x03000000 {
                let offset = address - 0x03000000
                internalRAM.replaceSubrange(offset..<offset + count, with: bytes(value, count))
            } else {
                let offset = address - 0x02000000
                work.replaceSubrange(offset..<offset + count, with: bytes(value, count))
            }
        }
        let sprite = 0x0202063C
        put(0x08010000, sprite + 8); put(0x08011000, sprite + 12)
        put(120, sprite + 0x20, 2); put(112, sprite + 0x22, 2)
        put(0xF8, sprite + 0x28, 1); put(0xF0, sprite + 0x29, 1)
        put(3, sprite + 0x3E, 1); put(2 << 10, sprite + 4, 2)
        put(0x08001000, 0x02036DFC)
        put(0x100, 0x03000000, 2) // Native text BG0 remains enabled.
        put(0x02010000, 0x030008EC)
        put(0xF038, 0x02010000 + (15 * 32 + 14) * 2, 2)
        let rom: [Int: [UInt8]] = [
            0x08001000: bytes(0) + bytes(0) + bytes(0) + bytes(0) + bytes(0x08002000) + bytes(0x08003000),
            0x08002000: bytes(0) + bytes(0x08004000),
            0x08003000: bytes(0) + bytes(0x08009000),
            0x08004000: Array(repeating: 0, count: 640 * 32),
            0x08009000: Array(repeating: 0, count: 384 * 32),
            0x08010000: bytes(0x08010010), 0x08010010: bytes(0),
            0x08011000: bytes(0x08012000) + bytes(256),
            0x08012000: Array(repeating: 0x11, count: 256)
        ]
        let player = try XCTUnwrap(reading(frame: 1).player)
        let assets = BoundPlayerSceneAssets()
        func decode() -> BoundPlayerScene? {
            BoundPlayerSceneDecoder.read(player: player,
                memory: BoundGBAMemorySnapshot(copyingWorkRAM: work, internalRAM: internalRAM)!,
                rom: { address, count in
                    guard let value = rom[address], value.count == count else { return nil }
                    return value
                }, assets: assets)
        }
        let unlocked = try XCTUnwrap(decode())
        put(1, 0x03000F9C, 1) // Mom, friend prompts and ordinary scripts lock controls.
        let dialogue = try XCTUnwrap(decode())
        XCTAssertEqual(dialogue.worldFoot, unlocked.worldFoot)
        XCTAssertEqual(dialogue.appearance, unlocked.appearance)
        XCTAssertTrue(dialogue.background.covers(x: 112, y: 120, priority: 2))
        XCTAssertFalse(dialogue.background.covers(x: 112, y: 96, priority: 2))
        let rendered = BoundRecordedPlayerRasterizer.rgba(pose: pose(), scene: dialogue).0
        XCTAssertTrue(stride(from: 3, to: rendered.count, by: 4).contains { rendered[$0] != 0 },
                      "Dialogue must not hide the entire friend")
        // ClearWindowTilemap preserves palette 15 when it selects blank tile 0.
        put(0xF000, 0x02010000 + (15 * 32 + 14) * 2, 2)
        XCTAssertFalse(try XCTUnwrap(decode()).background.covers(x: 112, y: 120, priority: 2),
                       "Closing a window removes its occlusion")
    }

    func testClearedWindowPaletteAndFlipAttributesDoNotHideFriend() {
        for attributes in 0..<64 {
            let entry = attributes << 10 // Tile 0, with every palette/flip combination.
            var map = Data(repeating: 0, count: 2048)
            for offset in stride(from: 0, to: map.count, by: 2) {
                map[offset] = UInt8(truncatingIfNeeded: entry)
                map[offset + 1] = UInt8(entry >> 8)
            }
            let background = BoundPlayerBackground(tiles: Data(), layers: [
                .init(priority: 0, scrollX: 253, scrollY: 255, map: map, masksWholeTiles: true)
            ])
            for point in [(0, 0), (7, 7), (112, 120), (239, 159)] {
                XCTAssertFalse(background.covers(x: point.0, y: point.1, priority: 2),
                               "Blank UI tile must stay transparent regardless of attributes: \(entry)")
            }
        }
    }

    func testFriendCrossesClearedDialogueRegionAndViewportEdgesWithoutPixelLoss() {
        // Native bedroom state after intro dialogue: the bottom six tile rows
        // retain palette 14 (border) and 15 (text) even though the window is gone.
        var map = Data(repeating: 0, count: 2048)
        for row in 14..<20 {
            for column in 0..<30 {
                map[(row * 32 + column) * 2 + 1] =
                    (15..<19).contains(row) && (2..<28).contains(column) ? 0xF0 : 0xE0
            }
        }
        let background = BoundPlayerBackground(tiles: Data(), layers: [
            .init(priority: 0, scrollX: 0, scrollY: 0, map: map, masksWholeTiles: true)
        ])
        let friend = pose(x: 104, y: 144)
        for shift in -176...160 {
            for camera in [(16, shift), (shift, 0)] {
                let actual = scene(cameraX: camera.0, cameraY: camera.1, background: background)
                let clear = scene(cameraX: camera.0, cameraY: camera.1)
                XCTAssertEqual(BoundRecordedPlayerRasterizer.rgba(pose: friend, scene: actual).0,
                               BoundRecordedPlayerRasterizer.rgba(pose: friend, scene: clear).0,
                               "A closed dialogue must not clip the friend at camera \(camera)")
            }
        }
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

    func testViewportUsesCameraRatherThanDistanceAndSwitchesAtSpriteBounds() throws {
        let local = scene()
        for tiles in [1, 3, 5] {
            let remote = pose(x: 104 + Double(tiles * 16))
            XCTAssertNil(BoundPlayerViewport.indicator(pose: remote, scene: local))
            let pixels = BoundRecordedPlayerRasterizer.rgba(pose: remote, scene: local).0
            XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] != 0 })
        }
        let distant = pose(x: 264)
        XCTAssertEqual(try XCTUnwrap(BoundPlayerViewport.indicator(pose: distant, scene: local)).distanceInTiles, 10)
        // The same retained world position immediately appears when the camera
        // reaches it, without receiving another network packet.
        let movedCamera = scene(x: 200, cameraX: -80)
        XCTAssertNil(BoundPlayerViewport.indicator(pose: distant, scene: movedCamera))
        let partial = pose(x: 231) // Origin 239; one column is still visible.
        XCTAssertNil(BoundPlayerViewport.indicator(pose: partial, scene: local))
        XCTAssertNotNil(BoundPlayerViewport.indicator(pose: pose(x: 232), scene: local))
    }

    func testOffscreenIndicatorsFollowEveryDirectionAndKeepEntireLabelInset() throws {
        let label = CGSize(width: 100, height: 14)
        for (x, y) in [(500.0, 112.0), (-500, 112), (104, -500), (104, 500), (500, 500), (-500, -500)] {
            let indicator = try XCTUnwrap(BoundPlayerViewport.indicator(pose: pose(x: x, y: y), scene: scene()))
            let center = indicator.center(labelSize: label)
            XCTAssertGreaterThanOrEqual(center.x - label.width / 2, 4)
            XCTAssertLessThanOrEqual(center.x + label.width / 2, 236)
            XCTAssertGreaterThanOrEqual(center.y - label.height / 2, 4)
            XCTAssertLessThanOrEqual(center.y + label.height / 2, 156)
            let expectedAngle = atan2(y - 24 - 80, x + 16 - 120)
            XCTAssertEqual(Double(indicator.angle), expectedAngle, accuracy: 0.0001)
        }
        let remote = pose(x: 500, y: 500)
        let before = try XCTUnwrap(BoundPlayerViewport.indicator(pose: remote, scene: scene()))
        let after = try XCTUnwrap(BoundPlayerViewport.indicator(pose: remote, scene: scene(x: 300, cameraX: -180)))
        XCTAssertNotEqual(before.angle, after.angle)
        XCTAssertGreaterThan(before.distanceInTiles, after.distanceInTiles)
    }

    func testOverlaySwitchesSpriteAndIndicatorWithoutMistakingOcclusionForOffscreen() throws {
        let overlay = BoundRecordedPlayerOverlay(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
        overlay.show(pose: pose(x: 264), scene: scene(), offscreenName: "Alex")
        overlay.layoutIfNeeded()
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.visiblePixels, 0)
        XCTAssertEqual(overlay.offscreenText, "Alex · 10 tiles")
        XCTAssertNotNil(overlay.offscreenIndicator)
        overlay.show(pose: pose(x: 264), scene: scene(x: 200, cameraX: -80), offscreenName: "Alex")
        XCTAssertFalse(overlay.isHidden)
        XCTAssertGreaterThan(overlay.visiblePixels, 0)
        XCTAssertNil(overlay.offscreenIndicator)

        let origin = BoundPlayerViewport.origin(pose: pose(), scene: scene())
        let nearer = BoundPlayerSceneObject(origin: origin, footY: 88, appearance: sprite())
        overlay.show(pose: pose(), scene: scene(objects: [nearer]), offscreenName: "Alex")
        XCTAssertEqual(overlay.visiblePixels, 0)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertNil(overlay.offscreenIndicator, "Foreground occlusion is not physical offscreen movement")
        overlay.show(pose: nil, scene: nil, offscreenName: "Alex")
        XCTAssertNil(overlay.offscreenText)
        XCTAssertNil(overlay.offscreenIndicator)
    }

    func testRecordingLargeMovementStepOnlyDisablesSmoothing() {
        var track = BoundRecordedPlayerTrack()
        track.append(frame: 0, pose: pose()); track.append(frame: 4, pose: pose(x: 500))
        XCTAssertEqual(track.pose(at: 2)?.x, 104)
        XCTAssertEqual(track.pose(at: 4)?.x, 500)
    }

    func testPresenceFrameCompositionTracksCameraAndRestoresSourcePixels() {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 240 * 160 * 4)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 37, count: 240 * 160 * 4)
        let original = Data(bytes: buffer, count: 240 * 160 * 4)
        let peer = pose(x: 104)
        // A stationary friend must move by exactly the local camera delta in
        // every immutable presentation, including reversals and running steps.
        for x in [16, 14, 12, 10, 12, 14, 16, 18] {
            let local = scene(cameraX: x)
            let origin = BoundPlayerViewport.origin(pose: peer, scene: local)
            BoundPresenceFrameCompositor.composite(peer, scene: local, into: buffer) {
                let pixel = (origin.y * 240 + origin.x) * 4
                XCTAssertEqual(Array(UnsafeBufferPointer(start: buffer + pixel, count: 4)), [0, 0, 255, 255])
                XCTAssertEqual(buffer[pixel - 4], 37)
            }
            XCTAssertEqual(Data(bytes: buffer, count: original.count), original, "Compositing must not alter the core's source pixels")
        }
        let covered = BoundPlayerBackground(tiles: Data(repeating: 0x11, count: 32768),
            layers: [.init(priority: 0, scrollX: 0, scrollY: 0, map: Data(repeating: 0, count: 2048))])
        BoundPresenceFrameCompositor.composite(peer, scene: scene(background: covered), into: buffer) {
            XCTAssertEqual(Data(bytes: buffer, count: original.count), original, "Foreground terrain still occludes the friend")
        }
    }

    func testActualPalletRouteOneCrossingKeepsDecodedScene() async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MultiplayerValidation")
        let romURL = root.appendingPathComponent("RadicalRed.gba")
        guard FileManager.default.fileExists(atPath: romURL.path) else { throw XCTSkip("Requires owned ROM fixture") }
        let profile = try BoundPlayerROMProfile(rom: Data(contentsOf: romURL))
        let output = root.appendingPathComponent("map-crossing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let battery = output.appendingPathComponent("work.sav")
        try Data(repeating: 0xFF, count: 0x20000).write(to: battery)
        let core = try XCTUnwrap(EmulatorCore(game: ReplayGame(fileURL: romURL, gameSaveURL: battery), options: [.metal: true]))
        let setup = NativePlayerSceneSetup(core: core)
        let captured = ReplayReadings(), presented = ReplayReadings()
        let compositor = BoundPresenceFrameCompositor()
        let booted = expectation(description: "Admitted native field")
        var ready = false, frame: UInt64 = 0
        core.updateHandler = { core in
            autoreleasepool {
                setup.receive(core); compositor.receive(core); frame += 1
                guard let memory = BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }) else { return }
                let reading = BoundPlayerStateDecoder.read(profile: profile, memory: memory, frame: frame, includeScene: true)
                captured.append(reading)
                if !ready, setup.isReady, reading.player?.scene != nil { ready = true; booted.fulfill() }
            }
        }
        defer { _ = core.stop() }
        core.rate = 8; XCTAssertTrue(core.start())
        await fulfillment(of: [booted], timeout: 60)
        XCTAssertTrue(core.pause()); core.rate = 1
        XCTAssertTrue(BoundVBABattleBridge.qaWarpPalletEntrance())
        XCTAssertTrue(core.resume())
        for _ in 0..<300 {
            if let p = captured.snapshot().last?.player, p.mapGroup == 3, p.mapNumber == 0, p.scene != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(core.pause())
        let start = captured.snapshot().count
        let waitingFriend = try XCTUnwrap(captured.snapshot().last.flatMap(BoundPresencePose.init(reading:)))
        compositor.configure(profile: profile, pose: waitingFriend, coreID: ObjectIdentifier(core))
        compositor.observeFrame = { reading, rendered, pixels in
            presented.append(reading)
            if let scene = reading.player?.scene, let rendered,
               abs(rendered.y - Double(scene.worldFoot.y)) >= 32 {
                let origin = BoundPlayerViewport.origin(pose: rendered, scene: scene)
                if origin.x >= 0, origin.x + 16 <= 240, origin.y >= 32, origin.y + 32 <= 160 {
                    XCTAssertGreaterThan(pixels, 0, "Stationary friend vanished from the actual native presentation")
                }
            }
        }
        try core.videoManager.snapshot()?.pngData()?.write(to: output.appendingPathComponent("pallet.png"))
        // Hold B and use native running shoes to reproduce a stationary peer
        // viewed by a running player crossing the seam in both directions.
        core.deltaCore.emulatorBridge.activateInput(2, value: 1, playerIndex: 0)
        for (input, rate) in [(64, 1.0), (128, 1.0), (32, 3.0), (16, 3.0)] {
            core.rate = rate
            core.deltaCore.emulatorBridge.activateInput(input, value: 1, playerIndex: 0)
            XCTAssertTrue(core.resume())
            try await Task.sleep(for: .milliseconds(1200))
            XCTAssertTrue(core.pause())
            core.deltaCore.emulatorBridge.deactivateInput(input, playerIndex: 0)
        }
        let crossings = Array(captured.snapshot().dropFirst(start))
        let diagnostic = crossings.map { r -> [String: Any] in
            ["frame": r.frame, "status": r.status.rawValue, "detail": r.detail,
             "map": r.player.map { [$0.mapGroup, $0.mapNumber] } ?? [],
             "tile": r.player.map { [$0.tile.x, $0.tile.y, $0.elevation] } ?? [],
             "scene": r.player?.scene != nil,
             "foot": r.player?.scene.map { [$0.worldFoot.x, $0.worldFoot.y] } ?? [],
             "camera": r.player?.scene.map { [$0.camera.x, $0.camera.y] } ?? []]
        }
        try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("frames.json"))
        NSLog("Native map crossing diagnostics: %@", output.path)
        let route = crossings.filter { $0.player?.mapNumber == 19 }
        XCTAssertGreaterThan(presented.snapshot().count, 60, "Exercise the actual video-renderer delegate, not only a UIKit overlay")
        let missing = presented.snapshot().filter { $0.status != .live || $0.player?.scene == nil }
        XCTAssertTrue(missing.isEmpty, "No presentation gaps while running across the seamless boundary: \(missing.prefix(3))")
        XCTAssertGreaterThan(route.count, 10, "Must walk into Route 1, not just warp to it")
        XCTAssertGreaterThan(route.filter { $0.player?.scene != nil }.count, 10)
        XCTAssertEqual(crossings.last?.player?.mapNumber, 0, "Must walk back into Pallet Town")
        XCTAssertNotNil(crossings.last?.player?.scene)
        let stationary = try XCTUnwrap(crossings.first { $0.player?.mapNumber == 0 && $0.player?.scene != nil })
        let stationaryPose = try XCTUnwrap(BoundPresencePose(reading: stationary))
        let stationaryViewer = try XCTUnwrap(stationary.player)
        let receiver = BoundLivePresenceSession(), sender = UUID()
        receiver.setROMVerified(true, profile: profile); receiver.setEnabled(true); receiver.start { _ in true }
        var previousSmoothed: BoundRecordedPlayerPose?
        var visibleAcrossBoundary = 0
        var clippedRoadFrames: [String] = []
        // Both viewpoints use actual RAM tilemaps/cameras and ROM connections:
        // one player waits in Pallet while the other walks into Route 1.
        for (index, reading) in crossings.enumerated() {
            let now = 20 + Double(index) / 60
            let packet = BoundPresencePacket(version: 1, rom: BoundPlayerROMProfile.supportedSHA256,
                sender: sender, receiver: receiver.epoch, sequence: UInt64(index + 1), time: now - 10,
                pose: BoundPresencePose(reading: reading))
            receiver.receive(try XCTUnwrap(packet.encoded()), at: now)
            if let smoothed = receiver.pose(at: now + 0.05)?.rendered(profile: profile, viewer: stationaryViewer) {
                if let previousSmoothed {
                    XCTAssertLessThanOrEqual(abs(smoothed.x - previousSmoothed.x) + abs(smoothed.y - previousSmoothed.y), 4.01,
                        "Crossing a connected map must not jump ahead of delayed interpolation")
                }
                previousSmoothed = smoothed
            }
            guard reading.player?.scene != nil else { continue }
            let moving = try XCTUnwrap(reading.player), movingPose = try XCTUnwrap(receiver.pose(at: now + 0.101))
            XCTAssertEqual(movingPose.mapNumber, moving.mapNumber, "The receiving client must switch maps with the native sender")
            for (peer, viewer) in [(movingPose, stationaryViewer), (stationaryPose, moving)] {
                let rendered = try XCTUnwrap(peer.rendered(profile: profile, viewer: viewer))
                let scene = try XCTUnwrap(viewer.scene)
                let origin = BoundPlayerViewport.origin(pose: rendered, scene: scene)
                guard abs(rendered.y - Double(scene.worldFoot.y)) >= 32,
                      origin.x >= 0, origin.x + 16 <= 240, origin.y >= 0, origin.y + 32 <= 160 else { continue }
                let rgba = BoundRecordedPlayerRasterizer.rgba(pose: rendered, scene: scene).0
                let visible = stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] != 0 }.count
                XCTAssertGreaterThan(visible, 0, "Native road sprite disappeared: viewer \(viewer.mapNumber), peer \(peer.mapNumber), origin \(origin)")
                let opaque = (0..<32).reduce(0) { count, y in
                    count + (0..<16).filter { rendered.appearance.colorIndex(x: $0, y: y) != 0 }.count
                }
                // The real, visible Pallet/Route name popup legitimately
                // covers pixels. Terrain on the entrance path must not.
                let ui = BoundPlayerBackground(tiles: scene.background.tiles,
                    layers: scene.background.layers.filter(\.masksWholeTiles))
                let uiPixels = (0..<32).reduce(0) { count, y in count + (0..<16).filter {
                    rendered.appearance.colorIndex(x: $0, y: y) != 0 && ui.covers(x: origin.x + $0, y: origin.y + y, priority: rendered.appearance.priority)
                }.count }
                if visible != opaque - uiPixels {
                    clippedRoadFrames.append("\(viewer.mapNumber)/\(peer.mapNumber) \(origin) pixels=\(visible)/\(opaque - uiPixels)")
                }
                if peer.mapNumber != viewer.mapNumber { visibleAcrossBoundary += 1 }
            }
        }
        XCTAssertGreaterThan(visibleAcrossBoundary, 10)
        XCTAssertEqual(receiver.receivedPackets, crossings.count)
        XCTAssertTrue(clippedRoadFrames.isEmpty, "The clear entrance path must not partially erase the friend: \(clippedRoadFrames.prefix(3))")
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
        let oldDeveloperPreference = UserDefaults.standard.object(forKey: BoundDeveloperFeatures.key)
        UserDefaults.standard.set(true, forKey: BoundDeveloperFeatures.key)
        UserDefaults.standard.set(true, forKey: BoundPlayerStatePreferences.key)
        display.install(in: owner); display.bind(core: core); display.layout(in: owner, gameView: gameView)
        defer {
            display.stop(); _ = core.stop(); window.isHidden = true; oldWindow?.makeKeyAndVisible()
            if let oldPreference { UserDefaults.standard.set(oldPreference, forKey: BoundPlayerStatePreferences.key) }
            else { UserDefaults.standard.removeObject(forKey: BoundPlayerStatePreferences.key) }
            UserDefaults.standard.set(oldDeveloperPreference, forKey: BoundDeveloperFeatures.key)
        }
        let probe = display.probe, booted = expectation(description: "VBA-M overworld")
        let setup = NativePlayerSceneSetup(core: core)
        var bootFinished = false
        core.updateHandler = { core in
            setup.receive(core)
            if let reading = probe.receive(core), reading.status == .live, setup.isReady, !bootFinished {
                bootFinished = true; booted.fulfill()
            }
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
                setup.receive(core)
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

        // Exercise the actual native tilemaps, not just a zero-filled synthetic
        // scene. Closing native windows leaves palette-only entries behind.
        var clearedWindowTiles = 0
        for scene in scenes {
            for layer in scene.background.layers where layer.masksWholeTiles {
                let windows = BoundPlayerBackground(tiles: Data(), layers: [layer])
                for y in stride(from: 0, to: 160, by: 8) {
                    for x in stride(from: 0, to: 240, by: 8) {
                        let offset = (((y + layer.scrollY) & 255) / 8 * 32 + ((x + layer.scrollX) & 255) / 8) * 2
                        let entry = Int(layer.map[offset]) | Int(layer.map[offset + 1]) << 8
                        if entry != 0, entry & 1023 == 0 {
                            clearedWindowTiles += 1
                            XCTAssertFalse(windows.covers(x: x, y: y, priority: 2),
                                           "Native cleared window must not erase the friend: \(entry)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(clearedWindowTiles, 0, "Native run must exercise the reported window-clear regression")

        UserDefaults.standard.set(true, forKey: BoundPlayerStatePreferences.key)
        NotificationCenter.default.post(name: BoundPlayerStatePreferences.didChange, object: nil)
        await movement([(16, 40), (0, 8)], name: "Move viewer independently")
        display.recordingSession.play()
        // A different input route runs while the recorded player follows its own.
        var replayFrame = 0
        core.updateHandler = { core in
            setup.receive(core)
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
