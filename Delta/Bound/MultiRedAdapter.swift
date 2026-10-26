import Foundation
import CryptoKit

/// Immutable cartridge identity. ABI agreement alone never admits a saved run.
struct BoundGameProfile: Equatable, Sendable {
    let romSHA256: String
    let gameID: String
    let family: Data
    let ruleset: Data
    let compatibility: Data
    let saveStateLayout: UInt32
    let supportsCooperativeDoubles: Bool
    let coreIdentifier: String
    let coreStateVersion: UInt32

    func admits(romSHA256: String, saveStateLayout: UInt32) -> Bool {
        self.romSHA256 == romSHA256 && self.saveStateLayout == saveStateLayout
    }
}

/// Selection is made from the complete owned file once, before activity admission.
/// Native code uses the corresponding descriptor and complete restoration table.
struct MultiRedAdapter: Sendable {
    let profile: BoundGameProfile
    enum Failure: Error { case unsupportedROM }

    init(rom: Data) throws {
        guard rom.count == 32 * 1024 * 1024 else { throw Failure.unsupportedROM }
        let digest = SHA256.hash(data: rom).map { String(format: "%02x", $0) }.joined()
        guard let profile = Self.profile(romSHA256: digest) else { throw Failure.unsupportedROM }
        self.profile = profile
    }
    static func profile(romSHA256: String) -> BoundGameProfile? {
        BoundGameProfiles.all.first { $0.romSHA256 == romSHA256 }
    }
    static func profile(gameID: String) -> BoundGameProfile? {
        BoundGameProfiles.all.first { $0.gameID == gameID }
    }

    func readPlayer(_ source: BoundPlayerROMProfile, memory: BoundGBAMemorySnapshot, frame: UInt64,
                    includeScene: Bool, presentationOnly: Bool = false) -> BoundPlayerStateReading {
        guard source.gameProfile == profile else { return .inactive(.unsupportedROM, "Game profile changed", frame: frame) }
        return BoundPlayerStateDecoder.read(profile: source, memory: memory, frame: frame,
                                            includeScene: includeScene, presentationOnly: presentationOnly)
    }
    static func encodeSetupHost(_ state: BoundROMHostState, sequence: UInt32) -> Data { state.encoded(sequence: sequence) }
    static func readSetupRequest() -> BoundROMRequest? { BoundROMRequest.decode(BoundVBABattleBridge.romMultiplayerSnapshot()) }
    static func applySetupHost(_ data: Data) { BoundVBABattleBridge.setROMMultiplayerHost(data) }
    static func captureWorld() -> (state: BoundWorldState, sequence: UInt32)? {
        let value = BoundVBABattleBridge.sharedWorldSnapshot()
        guard let checkpoints = value["checkpoints"] as? Data, let group = value["group"] as? UInt8,
              let number = value["number"] as? UInt8, let sequence = value["sequence"] as? UInt32 else { return nil }
        return (.init(group: group, number: number, checkpoints: checkpoints, boulders: value["boulders"] as? Data ?? Data()), sequence)
    }
    static func applyWorld(_ state: BoundWorldState?, fresh: Bool) {
        BoundVBABattleBridge.setSharedWorldPeer(state?.checkpoints ?? Data(), group: UInt(state?.group ?? 0),
            number: UInt(state?.number ?? 0), boulders: state?.boulders ?? Data(), fresh: fresh)
    }
    // Existing native injection and recovery bodies stay in the VBA bridge.
    // Its selected immutable descriptor owns the ruleset/layout checks.
    static func captureState() -> Data { BoundVBABattleBridge.captureServerState() }
    static func restoreState(_ data: Data) -> Bool { BoundVBABattleBridge.restoreServerState(data) }
    static func prepareBattle(player: UInt) -> Bool { BoundVBABattleBridge.prepareBattle(forPlayer: player) }
    static func prepareTrade(player: UInt) -> Bool { BoundVBABattleBridge.prepareTrade(forPlayer: player) }
}
