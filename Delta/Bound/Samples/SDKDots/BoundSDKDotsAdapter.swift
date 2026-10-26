import Foundation
import CryptoKit
import DeltaCore

/// Exact homebrew profile. None of these addresses or payload rules enter the SDK.
enum BoundSDKDotsAdapter {
    static let profile = "bound-sdk-dots-v1"
    static let sha256 = "958456f9a7e088eb2543e8cfcc0fb1825175113747adb1e93513b269642da0ec"
    static let gameID = "4d32b337153e7a871a0f1d646db31414bfcd6745"
    static let coreID = "com.rileytestut.GBADeltaCore"
    static let ruleset = Data([83,68,75,68,79,84,83,45,80,85,76,83,69,0,0,1])
    static let maximum: UInt32 = 0xfffffffe
    enum Failure: Error { case profile, boundary, corrupt, exhausted, ownership }

    static func admit(_ rom: Data) throws {
        guard rom.count == 2602,
              SHA256.hash(data: rom).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw Failure.profile }
    }

    struct Snapshot: Equatable {
        let sequence, flags, x, y, frame, pending, emitted, durable, peerApplied, peerCount: UInt32
        let generation, hostSequence, receipt, rejected, journalRevision: UInt32
        let run, owner, peer: UUID
        var bound: Bool { run != BoundSDKBytes.zero }
    }

    static func snapshot(_ control: Data) throws -> Snapshot {
        typealias C = BoundSDKProtocol.SnapshotControl
        typealias S = BoundSDKProtocol.GameSnapshot
        guard control.count == C.byteSize, control.starts(with: C.prefix),
              BoundSDKBytes.word(control, C.sizeOffset) == C.byteSize,
              BoundSDKBytes.word(control, C.payloadSizeOffset) == S.byteSize else { throw Failure.corrupt }
        let page = Int(BoundSDKBytes.word(control, C.bufferIndexOffset))
        guard page < C.bufferCount else { throw Failure.corrupt }
        let offset = C.bufferOffset + page * C.payloadSize
        let data = control.subdata(in: offset..<offset + S.byteSize)
        let word = { BoundSDKBytes.word(data, $0) }
        let sequence = word(S.sequenceOffset), flags = word(68)
        guard data.starts(with: S.prefix), word(S.sizeOffset) == S.byteSize, sequence > 0, sequence & 1 == 0,
              word(S.statusOffset) == 1, data.subdata(in: 32..<48) == ruleset,
              word(48) == 1, word(52) == 1, word(56) == 0x53440001,
              word(64) == 0x314f4453, flags & ~3 == 0, word(72) <= 232, word(76) <= 152,
              word(124) == 1, word(80) == word(S.frameOffset), word(92) <= word(88),
              word(88) <= maximum, word(96) <= maximum, word(112) <= word(88),
              word(84) == 0 || word(84) == word(88), data[176...].allSatisfy({ $0 == 0 }) else { throw Failure.corrupt }
        return Snapshot(sequence: sequence, flags: flags, x: word(72), y: word(76), frame: word(80),
            pending: word(84), emitted: word(88), durable: word(92), peerApplied: word(96), peerCount: word(100),
            generation: word(104), hostSequence: word(108), receipt: word(112), rejected: word(116), journalRevision: word(120),
            run: BoundSDKBytes.uuid(data, 128), owner: BoundSDKBytes.uuid(data, 144), peer: BoundSDKBytes.uuid(data, 160))
    }

    struct Input {
        let run, owner, peer: UUID
        let generation, sequence: UInt32
        var x: UInt32 = 0, y: UInt32 = 0, lease: UInt32 = 0
        var delivery: UInt32 = 0, durable: UInt32 = 0, receipt: UInt32 = 0
        var paused = false
    }
    static func host(_ value: Input) throws -> Data {
        typealias H = BoundSDKProtocol.GameHost
        guard ![value.run, value.owner, value.peer].contains(BoundSDKBytes.zero), value.owner != value.peer,
              value.generation > 0, value.generation <= maximum, value.sequence > 0, value.sequence & 1 == 0,
              value.x <= 232, value.y <= 152, value.lease <= 180,
              [value.delivery, value.durable, value.receipt].allSatisfy({ $0 <= maximum }) else { throw Failure.corrupt }
        var data = Data(repeating: 0, count: H.byteSize)
        data.replaceSubrange(0..<H.prefix.count, with: H.prefix)
        BoundSDKBytes.put(value.sequence, into: &data, at: H.sequenceOffset)
        BoundSDKBytes.put(value.run, into: &data, at: H.sessionOffset)
        data.replaceSubrange(H.rulesetOffset..<H.rulesetOffset + 16, with: ruleset)
        for (offset, word) in [(64, UInt32(0x31484453)), (68, 1), (72, 7), (76, value.generation),
            (112, value.x), (116, value.y), (120, value.lease > 0 ? 1 : 0), (124, value.lease),
            (128, value.delivery), (132, value.durable), (136, value.receipt), (140, value.paused ? 1 : 0)] {
            BoundSDKBytes.put(word, into: &data, at: offset)
        }
        BoundSDKBytes.put(value.owner, into: &data, at: 80)
        BoundSDKBytes.put(value.peer, into: &data, at: 96)
        return data
    }
}

/// Explicitly owned completed-frame boundary; this adapter never runs or pauses a core.
@MainActor final class BoundSDKDotsCore {
    private weak var core: EmulatorCore?
    private let owner: String
    private let generation: UInt64
    static func prepareForStart() throws {
        guard BoundSDKDotsNative.installObserver() else { throw BoundSDKDotsAdapter.Failure.boundary }
    }
    private static func ownsPausedBridge(_ core: EmulatorCore) -> Bool {
        core.state == .paused && core.deltaCore.identifier == BoundSDKDotsAdapter.coreID &&
            core.deltaCore.emulatorBridge.audioRenderer === core.audioManager &&
            core.deltaCore.emulatorBridge.videoRenderer === core.videoManager
    }
    init(core: EmulatorCore) throws {
        guard Self.ownsPausedBridge(core) else { throw BoundSDKDotsAdapter.Failure.boundary }
        let url = core.game.fileURL
        try BoundSDKDotsAdapter.admit(Data(contentsOf: url))
        let owner = UUID().uuidString
        let generation = BoundSDKDotsNative.claim(owner: owner, gameURL: url, audioRenderer: core.audioManager, videoRenderer: core.videoManager)
        guard generation > 0 else { throw BoundSDKDotsAdapter.Failure.ownership }
        self.core = core; self.owner = owner; self.generation = generation
    }
    func read() throws -> BoundSDKDotsAdapter.Snapshot {
        guard let core, Self.ownsPausedBridge(core), let data = BoundSDKDotsNative.read(owner: owner, generation: generation) else { throw BoundSDKDotsAdapter.Failure.ownership }
        return try BoundSDKDotsAdapter.snapshot(data)
    }
    func publish(_ data: Data) throws {
        guard let core, Self.ownsPausedBridge(core), BoundSDKDotsNative.publish(data, owner: owner, generation: generation) else { throw BoundSDKDotsAdapter.Failure.ownership }
    }
    func release() { BoundSDKDotsNative.release(owner: owner, generation: generation) }
    deinit { BoundSDKDotsNative.release(owner: owner, generation: generation) }
}
