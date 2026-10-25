import XCTest
import UIKit
import CryptoKit
import DeltaCore
@testable import Delta

private struct ReaderFixture {
    var work = Data(repeating: 0, count: 0x40000)
    var internalRAM = Data(repeating: 0, count: 0x8000)
    var rom: [Int: [UInt8]] = [:]
    init() {
        put(0x08056535, at: 0x030030F0); put(0x080565B5, at: 0x030030F4)
        put(0x0202552C, at: 0x03005008)
        put(6, at: 0x0202552C, count: 2); put(6, at: 0x0202552E, count: 2)
        put(4, at: 0x02025530, count: 1); put(1, at: 0x02025531, count: 1)
        put(0x082D52FC, at: 0x02036DFC)
        put(0x10001, at: 0x02036E38)
        put(255, at: 0x02036E40, count: 1)
        put(1, at: 0x02036E41, count: 1); put(4, at: 0x02036E42, count: 1)
        for offset in [0x10, 0x12, 0x14, 0x16] { put(13, at: 0x02036E38 + offset, count: 2) }
        put(0x11, at: 0x02036E50, count: 1)
        put(3, at: 0x0202063C + 0x3E, count: 1)
        rom[0x083526B8] = Self.bytes(0x083523FC)
        rom[0x08352400] = Self.bytes(0x08350D6C)
        rom[0x08350D6C] = Array(work[0x36DFC..<0x36DFC + 28])
        rom[0x082D52FC] = Self.bytes(12) + Self.bytes(9)
    }
    static func bytes(_ value: Int, count: Int = 4) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    mutating func put(_ value: Int, at address: Int, count: Int = 4) {
        let bytes = Self.bytes(value, count: count)
        if address >= 0x03000000 { internalRAM.replaceSubrange(address - 0x03000000..<address - 0x03000000 + count, with: bytes) }
        else { work.replaceSubrange(address - 0x02000000..<address - 0x02000000 + count, with: bytes) }
    }
    func decode(frame: UInt64 = 1, presentationOnly: Bool = false) -> BoundPlayerStateReading {
        let snapshot = BoundGBAMemorySnapshot(copyingWorkRAM: work, internalRAM: internalRAM)!
        return BoundPlayerStateDecoder.decode(memory: snapshot, frame: frame, romBytes: { address, count in
            guard let value = rom[address], value.count == count else { return nil }; return value
        }, presentationOnly: presentationOnly)
    }
}

private struct ReaderGame: GameProtocol {
    let fileURL: URL
    let gameSaveURL: URL
    var type: GameType { .gba }
}

private final class ReaderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [BoundPlayerStateReading] = []
    func record(_ reading: BoundPlayerStateReading) { lock.lock(); readings.append(reading); lock.unlock() }
    func snapshot() -> [BoundPlayerStateReading] { lock.lock(); defer { lock.unlock() }; return readings }
}

@MainActor
final class PlayerStateTests: XCTestCase {
    func testROMIdentityAndNormalizedLiveCoordinates() throws {
        XCTAssertThrowsError(try BoundPlayerROMProfile(rom: Data(repeating: 0, count: 512)))
        let reading = ReaderFixture().decode()
        XCTAssertEqual(reading.status, .live)
        let player = try XCTUnwrap(reading.player)
        XCTAssertEqual(player.mapGroup, 4); XCTAssertEqual(player.mapNumber, 1)
        XCTAssertEqual(player.tile, .init(x: 6, y: 6))
        XCTAssertEqual(player.previousTile, player.tile)
        XCTAssertEqual(player.facing, "South")
    }

    func testPendingRunningStepIsPresentationOnlyAndUsesActualCameraTile() throws {
        var fixture = ReaderFixture()
        fixture.put(12, at: 0x02036E38 + 0x12, count: 2) // Destination one tile north.
        fixture.put(2, at: 0x02037078 + 2, count: 1)
        fixture.put(2, at: 0x02037078 + 3, count: 1)
        XCTAssertEqual(fixture.decode().status, .invalidMemory, "Interaction admission remains strict")
        let player = try XCTUnwrap(fixture.decode(presentationOnly: true).player)
        XCTAssertEqual(player.tile, .init(x: 6, y: 5))
        XCTAssertEqual(player.cameraTile, .init(x: 6, y: 6))
        fixture.put(11, at: 0x02036E38 + 0x12, count: 2)
        XCTAssertNil(fixture.decode(presentationOnly: true).player, "Larger coordinate disagreements remain invalid")
        fixture.put(12, at: 0x02036E38 + 0x12, count: 2)
        fixture.put(0, at: 0x02037078 + 2, count: 1)
        XCTAssertNil(fixture.decode(presentationOnly: true).player, "Stationary mismatches are not a running-camera transition")
    }

    func testBorrowedVBAViewsAreCopiedAndAddressTranslationIsBounded() throws {
        let work = UnsafeMutableRawPointer.allocate(byteCount: 0x40000, alignment: 4)
        let internalRAM = UnsafeMutableRawPointer.allocate(byteCount: 0x8000, alignment: 4)
        defer { work.deallocate(); internalRAM.deallocate() }
        work.initializeMemory(as: UInt8.self, repeating: 19, count: 0x40000)
        internalRAM.initializeMemory(as: UInt8.self, repeating: 27, count: 0x8000)
        var requests: [(Int, Int)] = []
        let snapshot = try XCTUnwrap(BoundGBAMemorySnapshot.capture { address, count in
            requests.append((address, count))
            return Data(bytesNoCopy: address == 0x8000 ? work : internalRAM, count: count, deallocator: .none)
        })
        work.storeBytes(of: UInt8(99), as: UInt8.self)
        internalRAM.storeBytes(of: UInt8(88), as: UInt8.self)
        XCTAssertEqual(requests.map { $0.0 }, [0x8000, 0])
        XCTAssertEqual(requests.map { $0.1 }, [0x40000, 0x8000])
        XCTAssertEqual(snapshot.bytes(at: 0x02000000, count: 1), [19])
        XCTAssertEqual(snapshot.bytes(at: 0x03000000, count: 1), [27])
        for address in [0, 0x02040000, 0x03008000, 0x04000000] {
            XCTAssertNil(snapshot.bytes(at: address, count: 1))
        }
        XCTAssertNil(BoundGBAMemorySnapshot.capture { _, _ in Data() })
    }

    func testBattleMenuHiddenPlayerAndBlackFadeNeverExposeCoordinates() {
        let cases: [(Int, Int, Int, BoundPlayerStateReading.Status)] = [
            (0x03003529, 2, 1, .battle), (0x030030F4, 0, 4, .outsideOverworld),
            (0x02037ABF, 128, 1, .transition),
            // Fade active has cleared but its coefficient remains fully black.
            (0x02037ABC, 16 << 6, 2, .transition),
            (0x02036E39, 32, 1, .transition), (0x0202063C + 0x3E, 7, 1, .transition),
            (0x03005008, 0, 4, .invalidMemory), (0x0203707D, 16, 1, .invalidMemory),
            (0x0203707C, 64, 1, .invalidMemory), (0x0202552C, 7, 2, .invalidMemory),
            (0x02036E50, 0, 1, .invalidMemory), (0x02036DFC, 0, 4, .invalidMemory)
        ]
        for (address, value, count, status) in cases {
            var fixture = ReaderFixture(); fixture.put(value, at: address, count: count)
            let reading = fixture.decode()
            XCTAssertEqual(reading.status, status, String(format: "%08x", address))
            XCTAssertNil(reading.player)
        }
    }

    func testLiveSavePointerAndObjectSlotsAreFollowed() {
        var fixture = ReaderFixture()
        fixture.work.replaceSubrange(0x3E000..<0x3E00C, with: fixture.work[0x2552C..<0x25538])
        fixture.put(0x0203E000, at: 0x03005008)
        fixture.put(99, at: 0x0202552C, count: 2)
        fixture.work.replaceSubrange(0x36E38 + 72..<0x36E38 + 108, with: fixture.work[0x36E38..<0x36E38 + 36])
        fixture.put(0, at: 0x02036E38)
        fixture.put(2, at: 0x0203707D, count: 1)
        fixture.put(2, at: 0x0202063C + 0x2E, count: 2)
        XCTAssertEqual(fixture.decode().player?.tile, .init(x: 6, y: 6))
    }

    func testConnectedMapCrossingKeepsPlayerSpawnIdentityAndPublishesCurrentMap() throws {
        var fixture = ReaderFixture()
        // Native camera connections rebase this retained object's coordinates;
        // only a full object rebuild changes its spawn map 4:1.
        fixture.rom[0x08352404] = ReaderFixture.bytes(0x08350D6C)
        var tracker = BoundPlayerPresenceTracker()
        _ = tracker.update(fixture.decode(frame: 1))
        XCTAssertEqual(tracker.update(fixture.decode(frame: 2)).status, .live)
        fixture.put(2, at: 0x02025531, count: 1)
        XCTAssertEqual(fixture.decode().player?.mapNumber, 2)
        XCTAssertEqual(tracker.update(fixture.decode(frame: 3)).status, .waiting)
        XCTAssertEqual(tracker.update(fixture.decode(frame: 4)).player?.mapNumber, 2)
        fixture.put(7, at: 0x0202552C, count: 2)
        for offset in [0x10, 0x14] { fixture.put(14, at: 0x02036E38 + offset, count: 2) }
        XCTAssertEqual(tracker.update(fixture.decode(frame: 5)).player?.tile.x, 7)
        fixture.put(1, at: 0x02025531, count: 1)
        XCTAssertEqual(tracker.update(fixture.decode(frame: 6)).status, .waiting)
        XCTAssertEqual(tracker.update(fixture.decode(frame: 7)).player?.mapNumber, 1)
        // The authoritative header agreement and unique player/sprite ownership
        // remain mandatory even though spawn-map bytes are not live identity.
        fixture.put(3, at: 0x02025531, count: 1)
        XCTAssertEqual(fixture.decode().status, .invalidMemory)
    }

    func testConsecutiveFramesInvalidateOnGapRewindMapChangeAndBattle() {
        var tracker = BoundPlayerPresenceTracker()
        XCTAssertEqual(tracker.update(ReaderFixture().decode(frame: 1)).status, .waiting)
        XCTAssertEqual(tracker.update(ReaderFixture().decode(frame: 2)).status, .live)
        XCTAssertNil(tracker.update(ReaderFixture().decode(frame: 2)).player)
        XCTAssertEqual(tracker.update(ReaderFixture().decode(frame: 3)).status, .live)
        XCTAssertNil(tracker.update(ReaderFixture().decode(frame: 20)).player)
        XCTAssertNil(tracker.update(.inactive(.battle, "Battle", frame: 21)).player)
        XCTAssertNil(tracker.update(ReaderFixture().decode(frame: 22)).player)
        XCTAssertEqual(tracker.update(ReaderFixture().decode(frame: 23)).status, .live)
        XCTAssertNil(tracker.update(ReaderFixture().decode(frame: 1)).player)
        let player = ReaderFixture().decode().player!
        let differentMap = BoundPlayerState(mapGroup: 3, mapNumber: 0, tile: player.tile,
            previousTile: player.previousTile, facing: player.facing, elevation: 0, graphicsID: 0, runningState: 0, tileTransitionState: 0)
        XCTAssertNil(tracker.update(.init(frame: 2, status: .live, detail: "", player: differentMap)).player)
    }

    func testDisabledAndWrongOwnerProbeDoesNotReadRAM() {
        let probe = BoundVBAPlayerStateProbe(), owner = NSObject()
        probe.configure(coreID: ObjectIdentifier(owner), profile: nil, active: false, status: .disabled, detail: "Off")
        probe.receive(coreID: ObjectIdentifier(owner)) { _, _ in XCTFail("Disabled reader must not read RAM"); return nil }
        XCTAssertEqual(probe.takeLatest()?.status, .disabled)
        XCTAssertNil(probe.takeLatest())
    }

    func testHUDClearsCoordinatesAndPreferenceResetsAndExports() throws {
        let hud = BoundPlayerStateHUD()
        hud.update(ReaderFixture().decode())
        XCTAssertTrue(hud.text?.contains("Map 4:1") == true)
        XCTAssertTrue(hud.text?.contains("Position 6, 6") == true)
        XCTAssertTrue(hud.text?.contains("Facing South") == true)
        hud.update(.inactive(.paused, "Paused"))
        XCTAssertFalse(hud.text?.contains("6, 6") == true)
        XCTAssertEqual(hud.accessibilityValue, "paused")
        let name = "PlayerStatePreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: BoundPlayerStatePreferences.key)
        let export = try BoundConfigurationExport.snapshot(defaults: defaults, mappings: [])
        let preferences = try XCTUnwrap(export["preferences"] as? [String: [String: Any]])
        XCTAssertEqual(preferences["settings"]?[BoundPlayerStatePreferences.key] as? Bool, true)
        Settings.resetPreferenceValues(in: defaults)
        XCTAssertFalse(defaults.bool(forKey: BoundPlayerStatePreferences.key))
    }

    /// Opt-in private fixture, installed under the dedicated QA app's Documents.
    /// It is a disposable ROM and battery copy; neither is a bundled resource.
    func testActualRadicalRedColdBootAndMovementInVBAM() async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MultiplayerValidation", isDirectory: true)
        let romURL = root.appendingPathComponent("RadicalRed.gba")
        guard FileManager.default.fileExists(atPath: romURL.path) else {
            throw XCTSkip("Install the private exact-ROM and disposable generated battery fixtures described in Docs/BOUND-MULTIPLAYER.md")
        }
        let rom = try Data(contentsOf: romURL)
        _ = try BoundPlayerROMProfile(rom: rom)
        let battery = root.appendingPathComponent("seed.sav")
        let workBattery = root.appendingPathComponent("vbam-test.sav")
        try Data(contentsOf: battery).write(to: workBattery, options: .atomic)
        let seedHash = SHA256.hash(data: try Data(contentsOf: battery))
        let core = try XCTUnwrap(EmulatorCore(game: ReaderGame(fileURL: romURL, gameSaveURL: workBattery), options: [.metal: true]))
        let oldPreference = UserDefaults.standard.object(forKey: BoundPlayerStatePreferences.key)
        let oldDeveloperPreference = UserDefaults.standard.object(forKey: BoundDeveloperFeatures.key)
        let oldMultiplayerPreference = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        UserDefaults.standard.set(true, forKey: BoundDeveloperFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        UserDefaults.standard.set(true, forKey: BoundPlayerStatePreferences.key)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), owner = UIViewController(), gameView = GameView()
        owner.view.backgroundColor = .black
        window.rootViewController = owner; window.makeKeyAndVisible()
        gameView.frame = CGRect(x: 0, y: 200, width: window.bounds.width, height: window.bounds.width * 2 / 3)
        owner.view.addSubview(gameView); core.add(gameView)
        let display = BoundPlayerStateDisplay(), recorder = ReaderRecorder()
        display.install(in: owner); display.bind(core: core)
        let probe = display.probe
        defer {
            display.stop(); _ = core.stop(); window.isHidden = true; previousWindow?.makeKeyAndVisible()
            if let oldPreference { UserDefaults.standard.set(oldPreference, forKey: BoundPlayerStatePreferences.key) }
            else { UserDefaults.standard.removeObject(forKey: BoundPlayerStatePreferences.key) }
            UserDefaults.standard.set(oldDeveloperPreference, forKey: BoundDeveloperFeatures.key)
            UserDefaults.standard.set(oldMultiplayerPreference, forKey: BoundMultiplayerFeatures.key)
        }
        let completed = expectation(description: "VBA-M reaches overworld and reads moving player")
        let setup = NativePlayerSceneSetup(core: core)
        // All counters and input scheduling below belong only to the core's owner.
        var frame = 0, movingSince: Int?, previousMask = 0, finished = false
        core.updateHandler = { core in
            frame += 1
            setup.receive(core)
            if let reading = probe.receive(core) {
                recorder.record(reading)
                if reading.status == .live, setup.isReady, movingSince == nil { movingSince = frame }
            }
            let mask: Int
            if let since = movingSince {
                let elapsed = frame - since
                mask = elapsed < 40 ? 32 : elapsed < 80 ? 64 : elapsed < 120 ? 16 : elapsed < 160 ? 128 : 0
                if elapsed >= 200, !finished { finished = true; completed.fulfill() }
            } else {
                mask = 0 // Bound setup starts the current cartridge automatically.
                if frame >= 7000, !finished { finished = true; completed.fulfill() }
            }
            for bit in [1, 8, 16, 32, 64, 128] where (mask & bit) != (previousMask & bit) {
                if mask & bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit, value: 1, playerIndex: 0) }
                else { core.deltaCore.emulatorBridge.deactivateInput(bit, playerIndex: 0) }
            }
            previousMask = mask
        }
        core.rate = 8
        XCTAssertTrue(core.start())
        await fulfillment(of: [completed], timeout: 90)
        display.refreshDisplay(); display.layout(in: owner, gameView: gameView)
        XCTAssertEqual(display.hud.reading.status, .live)
        XCTAssertTrue(display.hud.text?.contains("VBA-M · Live") == true)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "VBA-M live player-state display"; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: root.appendingPathComponent("vbam-reader-display.png"), options: .atomic)
        XCTAssertTrue(core.pause())
        display.refreshDisplay()
        XCTAssertEqual(display.hud.reading.status, .paused)
        XCTAssertNil(display.hud.reading.player)
        let readings = recorder.snapshot(), live = readings.compactMap(\.player)
        XCTAssertGreaterThan(live.count, 100)
        let first = try XCTUnwrap(live.first)
        XCTAssertEqual(first.mapGroup, 4); XCTAssertEqual(first.mapNumber, 1)
        XCTAssertEqual(first.tile, .init(x: 6, y: 6))
        XCTAssertEqual(Set(live.map(\.facing)), Set(["North", "South", "East", "West"]))
        XCTAssertTrue(live.contains { $0.tile != first.tile })
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: battery)), seedHash)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: romURL)), SHA256.hash(data: rom))
        _ = core.stop()
        XCTAssertEqual(core.state, .stopped)
        let summary: [String: Any] = ["engine": "VBA-M", "romSHA256": BoundPlayerROMProfile.supportedSHA256,
            "frames": readings.count, "liveFrames": live.count, "firstMap": [first.mapGroup, first.mapNumber],
            "firstTile": [first.tile.x, first.tile.y], "facings": Array(Set(live.map(\.facing))).sorted(),
            "moved": live.contains { $0.tile != first.tile }, "seedBatteryUnchanged": true]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("vbam-reader-report.json"), options: .atomic)
    }
}
