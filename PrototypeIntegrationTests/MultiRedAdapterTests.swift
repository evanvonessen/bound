import XCTest
import CryptoKit
@preconcurrency import DeltaCore
@testable import Delta

private struct ProfileFixtureGame: GameProtocol {
    let fileURL: URL
    let gameSaveURL: URL
    var type: GameType { .gba }
}

@MainActor
final class MultiRedAdapterTests: XCTestCase {
    func testProfilesPreserveExactCompatibilityAndCooperativeCapability() {
        let old = BoundGameProfiles.original, current = BoundGameProfiles.current
        XCTAssertEqual(current.romSHA256, BoundWorldContract.romSHA256)
        XCTAssertEqual(current.compatibility, BoundWorldContract.compatibility)
        XCTAssertEqual(old.family, current.family)
        XCTAssertNotEqual(old.ruleset, current.ruleset)
        XCTAssertEqual(old.saveStateLayout, 5); XCTAssertEqual(current.saveStateLayout, 6)
        XCTAssertFalse(old.supportsCooperativeDoubles); XCTAssertTrue(current.supportsCooperativeDoubles)
        XCTAssertFalse(old.admits(romSHA256: current.romSHA256, saveStateLayout: old.saveStateLayout))
        XCTAssertFalse(old.admits(romSHA256: old.romSHA256, saveStateLayout: current.saveStateLayout))
    }

    func testWorldPacketsUseTheBoundProfileAndRejectCrossRulesets() throws {
        let packet = BoundWorldPacket(sender: UUID(), receiver: UUID(), sequence: 1,
            state: .init(group: 3, number: 1, checkpoints: Data(repeating: 0, count: 800)))
        for profile in BoundGameProfiles.all {
            let data = try XCTUnwrap(packet.encoded(compatibility: profile.compatibility))
            XCTAssertEqual(BoundWorldPacket.decode(data, compatibility: profile.compatibility), packet)
            for other in BoundGameProfiles.all where other != profile {
                XCTAssertNil(BoundWorldPacket.decode(data, compatibility: other.compatibility))
            }
        }
    }

    func testSavedRunAdmissionKeepsOriginalIdentityAndRejectsCurrentROM() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BoundMultiplayerSaveStore(root: root.appendingPathComponent("runs"), support: root, deviceID: UUID())
        let profile = BoundGameProfiles.original, owner = UUID()
        let identity = BoundMultiplayerRunIdentity(run: UUID(), gameID: profile.gameID, owner: owner, partner: UUID(),
            roomID: "profile-fixture", settingsOwner: owner, settings: Data(), localSeed: 1, partnerSeed: 2,
            romSHA256: profile.romSHA256)
        store.useServerStorage(gameID: profile.gameID)
        try store.beginServerSession(identity: identity, package: nil, target: .init())
        XCTAssertEqual(try store.validateForResume(gameID: profile.gameID, owner: owner, romSHA256: profile.romSHA256)?.identity, identity)
        XCTAssertThrowsError(try store.validateForResume(gameID: profile.gameID, owner: owner, romSHA256: BoundGameProfiles.current.romSHA256))
        XCTAssertEqual(try store.manifest(gameID: profile.gameID)?.identity, identity)
    }

    /// Explicit owned-simulator fixtures; never reads a library ROM or personal save.
    func testActualROMProfilesAndRawStatesRemainSeparate() async throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MultiRedProfilesQA")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("original.gba").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("current.gba").path) else {
            throw XCTSkip("Requires both exact owned profile ROM fixtures in MultiRedProfilesQA")
        }
        let output = root.appendingPathComponent("results-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var states: [String: Data] = [:]
        let pairs = [("original", BoundGameProfiles.original), ("current", BoundGameProfiles.current)]
        for (name, expected) in pairs {
            let rom = root.appendingPathComponent(name + ".gba"), bytes = try Data(contentsOf: rom)
            let profile = try BoundPlayerROMProfile(rom: bytes)
            XCTAssertEqual(profile.gameProfile, expected)
            XCTAssertEqual(try BoundROMUpdateContent.enrollment(data: bytes, gameID: expected.gameID).sha256, expected.romSHA256)
            var corrupt = bytes; corrupt[0x1000] ^= 1
            XCTAssertThrowsError(try MultiRedAdapter(rom: corrupt))
            let battery = output.appendingPathComponent(name + ".sav")
            try Data(repeating: 0xFF, count: 0x20000).write(to: battery)
            let core = try XCTUnwrap(EmulatorCore(game: ProfileFixtureGame(fileURL: rom, gameSaveURL: battery), options: [.metal: true]))
            let setup = NativePlayerSceneSetup(core: core, debugPlayer: 1)
            let ready = expectation(description: name + " committed field")
            var fulfilled = false
            core.updateHandler = { core in
                setup.receive(core)
                if !fulfilled, setup.isReady { fulfilled = true; ready.fulfill() }
            }
            core.rate = 8; XCTAssertTrue(core.start()); core.deltaCore.emulatorBridge.audioRenderer = nil
            await fulfillment(of: [ready], timeout: 90)
            XCTAssertTrue(core.pause())
            let memory = try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }))
            XCTAssertNotNil(profile.adapter.readPlayer(profile, memory: memory, frame: 1, includeScene: true).player?.scene)
            XCTAssertTrue(BoundVBABattleBridge.installROMMultiplayer())
            XCTAssertTrue(BoundVBABattleBridge.installSharedWorld())
            XCTAssertEqual(BoundVBABattleBridge.installCooperativeDoubles(), expected.supportsCooperativeDoubles)
            let state = BoundVBABattleBridge.captureServerState()
            XCTAssertGreaterThan(state.count, 1024)
            XCTAssertTrue(BoundVBABattleBridge.restoreServerState(state))
            states[name] = state; try state.write(to: output.appendingPathComponent(name + ".state"))
            BoundVBABattleBridge.closeSharedWorld(); BoundVBABattleBridge.close(); BoundVBABattleBridge.closeSoulLink()
            XCTAssertTrue(core.stop())
        }
        for (name, _) in pairs {
            let core = try XCTUnwrap(EmulatorCore(game: ProfileFixtureGame(fileURL: root.appendingPathComponent(name + ".gba"),
                gameSaveURL: output.appendingPathComponent(name + ".sav")), options: [.metal: true]))
            try BoundROMMultiplayerCoordinator.prepareServerCoreForSelection(core)
            let own = try XCTUnwrap(states[name]), other = try XCTUnwrap(states[name == "original" ? "current" : "original"])
            XCTAssertTrue(BoundVBABattleBridge.restoreServerState(own))
            let before = BoundVBABattleBridge.captureServerState()
            XCTAssertFalse(BoundVBABattleBridge.restoreServerState(other))
            XCTAssertEqual(BoundVBABattleBridge.captureServerState(), before, "Rejected cross-profile state cannot mutate the core")
            XCTAssertTrue(core.stop())
        }
    }
}
