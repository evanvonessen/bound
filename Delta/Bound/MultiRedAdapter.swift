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

    private static let profileLock = NSLock()
    nonisolated(unsafe) private static var runtimeProfiles: [String: BoundGameProfile] = [:]
    init(rom: Data) throws {
        guard rom.count == 32 * 1024 * 1024 else { throw Failure.unsupportedROM }
        let digest = SHA256.hash(data: rom).map { String(format: "%02x", $0) }.joined()
        if let known = BoundGameProfiles.all.first(where: { $0.romSHA256 == digest }) {
            self.profile = known; return
        }
        guard let descriptor = BoundVBABattleBridge.compatibleROMDescriptor(rom), descriptor.count == 128 else { throw Failure.unsupportedROM }
        let gameID = Insecure.SHA1.hash(data: rom).map { String(format: "%02x", $0) }.joined()
        let ruleset = descriptor.subdata(in: 20..<36)
        var signature = ruleset
        signature.append(contentsOf: [1,0,0,0,1,0,1,0])
        let profile = BoundGameProfile(romSHA256: digest, gameID: gameID,
            family: descriptor.subdata(in: 36..<52), ruleset: ruleset, compatibility: signature,
            saveStateLayout: 16, supportsCooperativeDoubles: true,
            coreIdentifier: "com.rileytestut.GBADeltaCore", coreStateVersion: 10)
        Self.profileLock.lock(); Self.runtimeProfiles[gameID] = profile; Self.profileLock.unlock()
        self.profile = profile
    }
    static func profile(romSHA256: String) -> BoundGameProfile? {
        if let known = BoundGameProfiles.all.first(where: { $0.romSHA256 == romSHA256 }) { return known }
        profileLock.lock(); let cached = runtimeProfiles.values.first { $0.romSHA256 == romSHA256 }; profileLock.unlock()
        if let cached { return cached }
        if let manifest = try? BoundROMServerInstallJournal(storage: .live).installed()?.manifest,
           manifest.sha256 == romSHA256 { return profile(gameID: manifest.gameID) }
        return nil
    }
    static func profile(gameID: String) -> BoundGameProfile? {
        if let known = BoundGameProfiles.all.first(where: { $0.gameID == gameID }) { return known }
        profileLock.lock(); let cached = runtimeProfiles[gameID]; profileLock.unlock()
        if let cached { return cached }
        guard gameID.count == 40, gameID.allSatisfy({ $0.isHexDigit }),
              let data = try? Data(contentsOf: DatabaseManager.gamesDirectoryURL.appendingPathComponent(gameID + ".gba")),
              let adapter = try? MultiRedAdapter(rom: data), adapter.profile.gameID == gameID else { return nil }
        return adapter.profile
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
