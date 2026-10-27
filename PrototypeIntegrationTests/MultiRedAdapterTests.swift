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
    func testNativeWildLossFeedsGameOverAndSurvivesBlackoutHealingWithoutOverridingSavedOptOut() throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DebugDefaultsQA")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("native-loss-proof.json").path) else {
            throw XCTSkip("Requires the button-only native wild-loss evidence for the exact candidate ROM")
        }
        let proof = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("native-loss-proof.json"))) as? [String: Any])
        XCTAssertEqual(proof["romSHA256"] as? String, BoundGameProfiles.debugDefaults.romSHA256)
        XCTAssertEqual(proof["nativeBattleOutcome"] as? Int, 2)
        XCTAssertEqual(proof["gameplayMemoryWrites"] as? Int, 0)
        let hashes = try XCTUnwrap(proof["partySHA256"] as? [String: String])
        func party(_ name: String) throws -> [BoundSoulMon] {
            let data = try Data(contentsOf: root.appendingPathComponent(name + ".bin"))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), hashes[name])
            let values = BoundSoulMon.decode(data, stride: 100)
            XCTAssertEqual(values.count, 1)
            return values
        }
        let before = try party("healthy"), lost = try party("fainted"), healed = try party("blackout-healed")
        XCTAssertEqual(before.first?.hp, 20); XCTAssertEqual(lost.first?.hp, 0); XCTAssertEqual(healed.first?.hp, 20)
        XCTAssertEqual(before.first?.identity, lost.first?.identity)
        XCTAssertEqual(lost.first?.identity, healed.first?.identity)
        var ledger = BoundSoulLedger(run: UUID(), binding: BoundGameProfiles.debugDefaults.romSHA256)
        try ledger.observe(before, registering: true, fainted: [])
        XCTAssertFalse(BoundSoulWipeout.occurred(party: before, ledger: ledger))
        try ledger.observe(lost, registering: false, fainted: [])
        XCTAssertTrue(BoundSoulWipeout.occurred(party: lost, ledger: ledger))
        let persisted = try BoundMultiplayerSaveStore.encode(ledger)
        let reopened = try JSONDecoder().decode(BoundSoulLedger.self, from: persisted)
        XCTAssertTrue(BoundSoulWipeout.occurred(party: healed, ledger: reopened), "Native blackout healing cannot erase the permanent loss")
        XCTAssertFalse(BoundSoulWipeout.occurred(party: lost, ledger: reopened, friendly: true))
        var defaults = BoundMultiplayerSetupOptions(); defaults.debug = true
        XCTAssertEqual(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: defaults.settings), true)
        var existing = defaults.settings; existing[2] = 0; existing[21] = 1
        XCTAssertEqual(BoundMultiplayerSetupOptions.deletesSaveOnGameOver(settings: existing), false, "An existing Debug run's opt-out remains authoritative")
    }
    func testFreshDebugGamesUseEasyAndNativeLMenuCanToggleRepelBothWays() async throws {
        let rom = try XCTUnwrap(Bundle(for: Game.self).url(forResource: "multiplayer", withExtension: "gba"))
        let profile = try BoundPlayerROMProfile(rom: Data(contentsOf: rom))
        XCTAssertEqual(profile.gameProfile, BoundGameProfiles.current)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for role in [UInt8(1), 2] {
            let battery = root.appendingPathComponent("role-\(role).sav")
            try Data(repeating: 0xFF, count: 0x20000).write(to: battery)
            let core = try XCTUnwrap(EmulatorCore(game: ProfileFixtureGame(fileURL: rom, gameSaveURL: battery), options: [.metal: true]))
            defer { _ = core.pause(); _ = core.stop() }
            let setup = NativePlayerSceneSetup(core: core, debugPlayer: role)
            let ready = expectation(description: "native Debug start \(role)")
            var fulfilled = false
            core.updateHandler = { core in
                setup.receive(core)
                if !fulfilled, setup.isReady { fulfilled = true; ready.fulfill() }
            }
            core.rate = 8; XCTAssertTrue(core.start()); core.deltaCore.emulatorBridge.audioRenderer = nil
            await fulfillment(of: [ready], timeout: 90)
            func flags() throws -> [Bool] {
                XCTAssertTrue(core.pause())
                defer { XCTAssertTrue(core.resume()) }
                let memory = try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }))
                return try [0x1033, 0x1034, 0x103C, 0x1057, 0x1045].map { flag in
                    let address = 0x0203B174 + (flag - 0x900) / 8
                    let byte = try XCTUnwrap(memory.bytes(at: address, count: 1)?.first)
                    return byte & (1 << (flag % 8)) != 0
                }
            }
            XCTAssertEqual(try flags(), [true, false, false, true, false])
            func press(_ input: Int) async throws {
                core.deltaCore.emulatorBridge.activateInput(input, value: 1, playerIndex: 0)
                try await Task.sleep(for: .milliseconds(40))
                core.deltaCore.emulatorBridge.deactivateInput(input, playerIndex: 0)
                try await Task.sleep(for: .milliseconds(600))
            }
            for expected in [true, false] {
                try await press(512) // Original L-button skills menu.
                try await press(128) // Inf. Repel, the second native row.
                try await press(1); try await press(1) // Native dialogue and acknowledgement.
                XCTAssertEqual(try flags(), [true, false, false, true, expected])
            }
            XCTAssertTrue(core.pause())
            let state = BoundVBABattleBridge.captureServerState()
            XCTAssertFalse(state.isEmpty)
            XCTAssertTrue(BoundVBABattleBridge.restoreServerState(state))
            XCTAssertTrue(core.resume())
            XCTAssertEqual(try flags(), [true, false, false, true, false], "Restore retains the player's native choice")
            XCTAssertTrue(core.stop())
        }
    }
    func testProfilesPreserveExactCompatibilityAndCooperativeCapability() {
        let old = BoundGameProfiles.original, current = BoundGameProfiles.current
        XCTAssertEqual(current.romSHA256, BoundWorldContract.romSHA256)
        XCTAssertEqual(current.compatibility, BoundWorldContract.compatibility)
        XCTAssertEqual(old.family, current.family)
        XCTAssertNotEqual(old.ruleset, current.ruleset)
        XCTAssertEqual(old.saveStateLayout, 5); XCTAssertEqual(BoundGameProfiles.stackSafe.saveStateLayout, 6)
        XCTAssertEqual(current.saveStateLayout, 12)
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
              FileManager.default.fileExists(atPath: root.appendingPathComponent("stack-safe.gba").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("debug-defaults.gba").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("friends-multiview.gba").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("current.gba").path) else {
            throw XCTSkip("Requires both exact owned profile ROM fixtures in MultiRedProfilesQA")
        }
        let output = root.appendingPathComponent("results-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var states: [String: Data] = [:]
        let pairs = [("original", BoundGameProfiles.original), ("stack-safe", BoundGameProfiles.stackSafe), ("debug-defaults", BoundGameProfiles.debugDefaults), ("friends-multiview", BoundGameProfiles.friendsMultiview), ("current", BoundGameProfiles.current)]
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
            var options = BoundMultiplayerSetupOptions(); options.debug = true
            var settings = options.settings
            if expected != BoundGameProfiles.current {
                settings[2] = 0; settings[21] = 1 // Retained Normal Debug run, Game Over opted out.
            }
            let setup = NativePlayerSceneSetup(core: core, debugPlayer: 1, settings: settings)
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
            XCTAssertEqual(memory.bytes(at: 0x02000828, count: 32), Array(settings))
            let easyAddress = 0x0203B174 + (0x1033 - 0x900) / 8
            XCTAssertEqual(try XCTUnwrap(memory.bytes(at: easyAddress, count: 1)?.first) & 8 != 0,
                           expected == BoundGameProfiles.current)
            XCTAssertNotNil(profile.adapter.readPlayer(profile, memory: memory, frame: 1, includeScene: true).player?.scene)
            XCTAssertTrue(BoundVBABattleBridge.installROMMultiplayer())
            XCTAssertTrue(BoundVBABattleBridge.installSharedWorld())
            XCTAssertEqual(BoundVBABattleBridge.installCooperativeDoubles(), expected.supportsCooperativeDoubles)
            let state = BoundVBABattleBridge.captureServerState()
            XCTAssertGreaterThan(state.count, 1024)
            XCTAssertTrue(BoundVBABattleBridge.restoreServerState(state))
            let restored = try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }))
            XCTAssertEqual(restored.bytes(at: 0x02000828, count: 32), Array(settings), "Raw restore must retain the saved difficulty and Game Over choice")
            states[name] = state; try state.write(to: output.appendingPathComponent(name + ".state"))
            BoundVBABattleBridge.closeSharedWorld(); BoundVBABattleBridge.close(); BoundVBABattleBridge.closeSoulLink()
            XCTAssertTrue(core.stop())
        }
        for (name, _) in pairs {
            let core = try XCTUnwrap(EmulatorCore(game: ProfileFixtureGame(fileURL: root.appendingPathComponent(name + ".gba"),
                gameSaveURL: output.appendingPathComponent(name + ".sav")), options: [.metal: true]))
            try BoundROMMultiplayerCoordinator.prepareServerCoreForSelection(core)
            let own = try XCTUnwrap(states[name])
            XCTAssertTrue(BoundVBABattleBridge.restoreServerState(own))
            let before = BoundVBABattleBridge.captureServerState()
            for (otherName, _) in pairs where otherName != name {
                XCTAssertFalse(BoundVBABattleBridge.restoreServerState(try XCTUnwrap(states[otherName])))
            }
            XCTAssertEqual(BoundVBABattleBridge.captureServerState(), before, "Rejected cross-profile state cannot mutate the core")
            XCTAssertTrue(core.stop())
        }
    }
}
