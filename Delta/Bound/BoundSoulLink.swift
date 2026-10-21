import Foundation
import CryptoKit
import SwiftUI
import DeltaCore
import UIKit

/// Stable across evolutions, nicknames, party ordering, boxes and hatching.
struct BoundSoulIdentity: Codable, Hashable, Comparable, Sendable {
    let personality: UInt32
    let trainer: UInt32
    static func < (a: Self, b: Self) -> Bool {
        a.personality == b.personality ? a.trainer < b.trainer : a.personality < b.personality
    }
    var bytes: Data {
        var result = Data()
        for word in [personality, trainer] { for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: word >> shift)) } }
        return result
    }
    static func read(_ data: Data, at offset: Int) -> Self? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        func word(_ n: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[n + $1]) << ($1 * 8) } }
        return .init(personality: word(offset), trainer: word(offset + 4))
    }
}

struct BoundSoulMon: Equatable, Sendable {
    let identity: BoundSoulIdentity
    let species: Int
    let name: String
    let area: Int
    let eggOrigin: Bool
    let isEgg: Bool
    let hp: Int?
    static func text(_ data: Data) -> String {
        data.prefix(while: { $0 != 255 }).map { b -> String in
            switch b {
            case 0: return " "
            case 161...170: return String(b - 161)
            case 187...212: return String(UnicodeScalar(Int(b - 187) + 65)!)
            case 213...238: return String(UnicodeScalar(Int(b - 213) + 97)!)
            case 173: return "."
            case 174: return "-"
            default: return "?"
            }
        }.joined()
    }
    static func areaNames(rom: Data) -> [Int: String] {
        guard rom.count == 0x2000000 else { return [:] }
        var names: [Int: String] = [:]
        for index in 0..<109 {
            let offset = 0x3F1CAC + index * 4
            let pointer = (0..<4).reduce(0) { $0 | Int(rom[offset + $1]) << ($1 * 8) } - 0x08000000
            guard pointer >= 0, pointer < rom.count - 32 else { continue }
            names[index + 0x58] = text(rom.subdata(in: pointer..<pointer + 32))
        }
        return names
    }
    static func decode(_ data: Data, stride: Int) -> [Self] {
        guard [58, 100].contains(stride), data.count % stride == 0 else { return [] }
        return Swift.stride(from: 0, to: data.count, by: stride).compactMap { offset in
            func half(_ n: Int) -> Int { Int(data[offset + n]) | Int(data[offset + n + 1]) << 8 }
            let species = half(stride == 100 ? 32 : 28)
            guard data[offset + 19] & 2 != 0, (1...4095).contains(species), let identity = BoundSoulIdentity.read(data, at: offset) else { return nil }
            let misc = stride == 100 ? 68 : 50
            let isEgg = data[offset + 19] & 4 != 0 || data[offset + misc + 7] & 0x40 != 0
            // Native hatch preserves metLevel=0 while changing the displayed met
            // location; egg identity remains the original ordinal in the journal.
            let eggOrigin = isEgg || (half(misc + 2) & 127) == 0 || data[offset + misc + 1] == 253
            let name = text(data.subdata(in: (offset + 8)..<(offset + 18)))
            return .init(identity: identity, species: species, name: name.isEmpty ? "Pokémon" : name,
                         area: Int(data[offset + misc + 1]), eggOrigin: eggOrigin, isEgg: isEgg, hp: stride == 100 && half(88) > 0 ? half(86) : nil)
        }
    }
}

struct BoundSoulRecord: Codable, Equatable, Sendable {
    let identity: BoundSoulIdentity
    let slot: String
    var name: String
    let eligible: Bool
    var aliases: Set<BoundSoulIdentity> = []
    var pendingHatch = false
    var identities: Set<BoundSoulIdentity> { aliases.union([identity]) }
}

struct BoundSoulLedger: Codable, Equatable, Sendable {
    static let version = 1
    var version = Self.version
    let run: UUID
    let binding: String
    var records: [BoundSoulRecord] = []
    var dead: Set<String> = []
    var nextEgg = 1
    var offering = false
    var ended = false
    static func validSlot(_ slot: String) -> Bool {
        let parts = slot.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[1]), String(n) == parts[1] else { return false }
        return parts[0] == "area" ? (0...255).contains(n) : parts[0] == "egg" && (1...2048).contains(n)
    }
    var valid: Bool {
        version == Self.version && binding.count == 64 && records.count <= 2048 && dead.count <= 2304
        && (1...2049).contains(nextEgg) && Set(records.flatMap(\.identities)).count == records.reduce(0, { $0 + $1.identities.count })
        && records.reduce(0, { $0 + $1.identities.count }) <= 2048
        && records.allSatisfy { Self.validSlot($0.slot) && $0.name.count <= 20 }
        && dead.allSatisfy(Self.validSlot)
        && Set(records.filter(\.eligible).map(\.slot)).count == records.filter(\.eligible).count
    }
    var lossBits: Data {
        var bits = Data(repeating: 0, count: 288)
        for key in dead {
            let parts = key.split(separator: ":")
            guard let value = Int(parts[1]) else { continue }
            let bit = parts[0] == "area" ? value : 256 + value - 1
            bits[bit / 8] |= 1 << (bit % 8)
        }
        return bits
    }
    static func losses(_ bits: Data) -> Set<String> {
        guard bits.count == 288 else { return [] }
        return Set((0..<2304).filter { bits[$0 / 8] & (1 << ($0 % 8)) != 0 }
            .map { $0 < 256 ? "area:\($0)" : "egg:\($0 - 255)" })
    }
    var denied: Set<BoundSoulIdentity> {
        Set(records.filter { !$0.eligible || dead.contains($0.slot) }.flatMap(\.identities))
    }
    mutating func observe(_ mons: [BoundSoulMon], registering: Bool, fainted: Set<BoundSoulIdentity>) throws {
        for mon in mons {
            if let index = records.firstIndex(where: { $0.identities.contains(mon.identity) }) {
                records[index].name = mon.name
                if !mon.isEgg { records[index].pendingHatch = false }
            } else if !mon.isEgg,
                      let index = records.firstIndex(where: { $0.pendingHatch && $0.identity.personality == mon.identity.personality }),
                      records.filter({ $0.pendingHatch && $0.identity.personality == mon.identity.personality }).count == 1 {
                // Native hatching can replace an egg's OT with this trainer.
                // Preserve the egg ordinal and retain both identity aliases.
                records[index].aliases.insert(mon.identity)
                records[index].pendingHatch = false; records[index].name = mon.name
            } else if registering {
                guard records.count < 2048, nextEgg <= 2048 else { throw Error.capacity }
                let slot: String
                if mon.eggOrigin { slot = "egg:\(nextEgg)"; nextEgg += 1 }
                else { slot = "area:\(mon.area)" }
                let eligible = !records.contains { $0.slot == slot && $0.eligible }
                records.append(.init(identity: mon.identity, slot: slot, name: mon.name, eligible: eligible, pendingHatch: mon.isEgg))
            }
        }
        for record in records where record.eligible {
            if !fainted.isDisjoint(with: record.identities) || mons.contains(where: { record.identities.contains($0.identity) && !$0.isEgg && $0.hp == 0 }) {
                dead.insert(record.slot)
            }
        }
        guard valid else { throw Error.capacity }
    }
    enum Error: Swift.Error { case capacity, corrupt }
}

struct BoundSoulRow: Codable, Equatable, Sendable {
    let slot: String
    let name: String
    let dead: Bool
    var valid: Bool { BoundSoulLedger.validSlot(slot) && name.count <= 20 }
}
struct BoundSoulPacket: Codable, Sendable {
    static let prefix = Data([0x42, 0x53, 0x4C, 0x31]) // BSL1
    enum Kind: String, Codable { case offer, accept, confirm, decline, state, end }
    let version: Int
    let run: UUID
    let kind: Kind
    var rows: [BoundSoulRow] = []
    var losses = Data(repeating: 0, count: 288)
    var sender = UUID()
    var receiver: UUID? = nil
    func encoded() -> Data? {
        guard let data = try? JSONEncoder().encode(self), data.count + 4 <= 1024 else { return nil }
        return Self.prefix + data
    }
    static func decode(_ data: Data) -> Self? {
        guard data.count <= 1024, data.starts(with: prefix),
              let value = try? JSONDecoder().decode(Self.self, from: data.dropFirst(4)), value.version == 1,
              value.rows.count <= 8, value.losses.count == 288, value.rows.allSatisfy(\.valid) else { return nil }
        return value
    }
}

/// The frame owner commits catch/death changes before allowing another frame.
/// Only main updates peer tombstones; neither Agora nor SwiftUI accesses live RAM.
final class BoundSoulProbe: @unchecked Sendable {
    struct Snapshot: Sendable {
        var ready = false
        var mons: [BoundSoulMon] = []
        var ledger: BoundSoulLedger?
        var error: String?
        var activeDenied = false
    }
    private let lock = NSRecursiveLock()
    private var previewEnabled = false
    private var verified = false
    private var coreID: ObjectIdentifier?
    private var url: URL?
    private var ledger: BoundSoulLedger?
    private var installed = false
    private var reachedField = false
    private var frame = 0
    private var snapshot = Snapshot()
    private var lastPolicy = Data()
    private var lastBoxes = Data()
    private var cachedBoxes: [BoundSoulMon] = []
    func configure(core: EmulatorCore?, url: URL?) {
        lock.lock(); defer { lock.unlock() }
        self.coreID = core.map(ObjectIdentifier.init); self.url = url
        verified = false; ledger = nil; installed = false; reachedField = false; frame = 0; snapshot = Snapshot(); lastPolicy = Data(); lastBoxes = Data(); cachedBoxes = []
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576 else { throw BoundSoulLedger.Error.corrupt }
            let value = try JSONDecoder().decode(BoundSoulLedger.self, from: data)
            guard value.valid else { throw BoundSoulLedger.Error.corrupt }
            ledger = value; snapshot.ledger = value
        } catch { snapshot.error = "Soul Link record couldn’t be read. Your run is paused." }
    }
    func setPreviewEnabled(_ value: Bool) { lock.lock(); previewEnabled = value; lock.unlock() }
    func setVerified(_ value: Bool) { lock.lock(); verified = value; lock.unlock() }
    func start(run: UUID, binding: String, offering: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.ready, (ledger == nil || ledger?.ended == true), snapshot.mons.count == 1, let starter = snapshot.mons.first,
              !starter.eggOrigin, (starter.hp ?? 0) > 0 else { throw BoundSoulLedger.Error.corrupt }
        var value = BoundSoulLedger(run: run, binding: binding)
        value.offering = offering
        try value.observe(snapshot.mons, registering: true, fainted: [])
        if let old = ledger, old.ended, let url {
            let archive = url.deletingLastPathComponent().appendingPathComponent("Finished Runs", isDirectory: true)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            let destination = archive.appendingPathComponent(old.run.uuidString + ".json")
            if !FileManager.default.fileExists(atPath: destination.path) { try JSONEncoder().encode(old).write(to: destination, options: .atomic) }
        }
        try persist(value); ledger = value; snapshot.ledger = value
    }
    func endRun() throws {
        lock.lock(); defer { lock.unlock() }
        guard var value = ledger else { return }
        value.ended = true; value.offering = false
        try persist(value); ledger = value; snapshot.ledger = value
        if installed { BoundVBABattleBridge.closeSoulLink(); installed = false; lastPolicy = Data() }
    }
    func markAccepted() throws {
        lock.lock(); defer { lock.unlock() }
        guard var value = ledger, value.offering else { return }
        value.offering = false; try persist(value); ledger = value; snapshot.ledger = value
    }
    func cancelOffer() throws {
        lock.lock(); defer { lock.unlock() }
        guard let value = ledger, value.offering, let url else { return }
        let archive = url.deletingLastPathComponent().appendingPathComponent("Cancelled Invitations", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: archive.appendingPathComponent(value.run.uuidString + ".json"))
        ledger = nil; snapshot.ledger = nil
        if installed { BoundVBABattleBridge.closeSoulLink(); installed = false; lastPolicy = Data() }
    }
    private func persist(_ value: BoundSoulLedger) throws {
        do {
            guard let url, value.valid else { throw BoundSoulLedger.Error.corrupt }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            snapshot.error = nil
        } catch {
            snapshot.error = "Soul Link couldn’t save its rules. Your run is paused."
            throw error
        }
    }
    func merge(run: UUID, rows: [BoundSoulRow], losses: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard var value = ledger, value.run == run else { return }
        let previous = value
        value.dead.formUnion(BoundSoulLedger.losses(losses))
        value.dead.formUnion(rows.filter(\.dead).map(\.slot))
        if value != previous { try persist(value); ledger = value; snapshot.ledger = value }
    }
    func read() -> Snapshot { lock.lock(); defer { lock.unlock() }; return snapshot }
    func receive(_ core: EmulatorCore) {
        lock.lock(); defer { lock.unlock() }
        guard verified, (previewEnabled || (ledger != nil && ledger?.ended == false)), coreID == ObjectIdentifier(core) else { return }
        frame += 1
        // No ROM/RAM access on unrelated cores or before exact file verification.
        guard core.deltaCore.identifier == "com.rileytestut.GBADeltaCore" else { return }
        if ledger == nil || ledger?.ended == true { if frame % 30 != 1 { return } }
        if ledger != nil, ledger?.ended == false, !installed {
            installed = BoundVBABattleBridge.installSoulLink()
            if !installed { snapshot.error = "Soul Link requires the supported Radical Red 4.1 game."; return }
        }
        if let ledger, !ledger.ended {
            let policy = ledger.denied.sorted().reduce(into: Data()) { $0.append($1.bytes) }
            if policy != lastPolicy {
                guard BoundVBABattleBridge.setSoulLinkDenied(policy) else { snapshot.error = "Soul Link enforcement unavailable."; return }
                lastPolicy = policy
            }
            BoundVBABattleBridge.enforceSoulLink()
        }
        let native = BoundVBABattleBridge.soulLinkSnapshot()
        let ready = native["ready"] as? Bool == true
        reachedField = reachedField || ready
        let party = BoundSoulMon.decode(native["party"] as? Data ?? Data(), stride: 100)
        let boxBytes = native["boxes"] as? Data ?? Data()
        let boxesChanged = ready && boxBytes != lastBoxes
        if boxesChanged { lastBoxes = boxBytes; cachedBoxes = BoundSoulMon.decode(boxBytes, stride: 58) }
        snapshot.ready = ready
        if ready { snapshot.mons = party + cachedBoxes }
        guard reachedField, var value = ledger, !value.ended else { return }
        do {
            guard native["overflow"] as? Bool != true else { throw BoundSoulLedger.Error.capacity }
            var fainted: Set<BoundSoulIdentity> = []
            for key in ["faints", "battleFaints"] {
                let data = native[key] as? Data ?? Data()
                for offset in stride(from: 0, to: data.count, by: 8) {
                    if let id = BoundSoulIdentity.read(data, at: offset) { fainted.insert(id) }
                }
            }
            let previous = value
            try value.observe(ready && boxesChanged ? party + cachedBoxes : party, registering: ready, fainted: fainted)
            if value != previous { try persist(value); ledger = value; snapshot.ledger = value }
            BoundVBABattleBridge.acknowledgeSoulLinkFaints()
            let policy = value.denied.sorted().reduce(into: Data()) { $0.append($1.bytes) }
            if policy != lastPolicy || !installed {
                guard BoundVBABattleBridge.setSoulLinkDenied(policy) else { throw BoundSoulLedger.Error.corrupt }
                lastPolicy = policy
            }
            BoundVBABattleBridge.enforceSoulLink()
        } catch { snapshot.error = "Soul Link couldn’t save its rules. Your run is paused." }
    }
}

@MainActor
final class BoundSoulSession: ObservableObject {
    let probe: BoundSoulProbe
    @Published private(set) var status = "Receive your starter, then connect to your partner."
    @Published private(set) var ledger: BoundSoulLedger?
    @Published private(set) var incoming: UUID?
    @Published private(set) var offered: UUID?
    @Published private(set) var peerRows: [BoundSoulRow] = []
    @Published private(set) var canStart = false
    @Published private(set) var areaNames: [Int: String] = [:]
    private let clock: () -> TimeInterval
    private weak var core: EmulatorCore?
    private var gameID = ""
    private var supported = false
    private var binding: String?
    private var connection: String?
    private var confirmed = false
    private var epoch = UUID()
    private var peerEpoch: UUID?
    private var proposedEpoch: UUID?
    private var proposalAt: TimeInterval = 0
    private var retiredEpochs: [UUID] = []
    private var lastPeer: TimeInterval = 0
    private var sent: TimeInterval = 0
    private var cursor = 0
    private var offeredAt: TimeInterval = 0
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    var bannerChanged: ((String?) -> Void)?
    var send: ((Data) -> Bool)?
    var connected: (() -> Bool)?
    var nativeActivity: (() -> Bool)?
    var active: Bool { ledger != nil && ledger?.ended == false }
    var paired: Bool { confirmed && clock() - lastPeer < 3 }
    var permitsNativeActivity: Bool { !active }
    init(probe: BoundSoulProbe = BoundSoulProbe(), clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock; self.probe = probe; self.ledger = probe.read().ledger
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    deinit {
        let timer = timer
        BoundMainActorDisposal.enqueue { timer?.invalidate() }
        loadTask?.cancel()
    }
    func bind(core: EmulatorCore?, gameID: String) {
        guard self.core !== core || self.gameID != gameID else { return }
        self.core = core; self.gameID = gameID; supported = false
        confirmed = false; lastPeer = 0; offered = nil; incoming = nil; peerRows = []; cursor = 0
        let url = core.map { _ in Self.directory.appendingPathComponent(Self.hash(gameID) + ".json") }
        probe.configure(core: core, url: url); ledger = probe.read().ledger
        loadTask?.cancel()
        guard let core, core.deltaCore.identifier == "com.rileytestut.GBADeltaCore" else { return }
        let id = ObjectIdentifier(core), file = core.game.fileURL
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (Bool, [Int: String]) in
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                      (try? BoundPlayerROMProfile(rom: data)) != nil else { return (false, [:]) }
                return (true, BoundSoulMon.areaNames(rom: data))
            }.value
            guard !Task.isCancelled, let self, self.core.map(ObjectIdentifier.init) == id else { return }
            self.supported = result.0; self.areaNames = result.1; self.probe.setVerified(result.0)
        }
    }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soul Link", isDirectory: true)
    }
    static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    func setConnection(owner: String?, room: String?) {
        let value = owner.flatMap { owner in room.map { Self.hash(owner + ":" + $0) } }
        if value != connection { peerGone(); peerRows = []; offered = nil; incoming = nil; connection = value }
        binding = value
    }
    private func transmit(_ kind: BoundSoulPacket.Kind, run: UUID, rows: [BoundSoulRow] = []) {
        if let data = BoundSoulPacket(version: 1, run: run, kind: kind, rows: rows,
                                      losses: ledger?.lossBits ?? Data(repeating: 0, count: 288),
                                      sender: epoch, receiver: proposedEpoch ?? peerEpoch).encoded() { _ = send?(data) }
    }
    func invite() {
        guard canStart else { return }
        guard let binding else { return }
        let run = UUID()
        do {
            try probe.start(run: run, binding: binding, offering: true)
            ledger = probe.read().ledger; peerRows = []; offered = run; offeredAt = clock()
            transmit(.offer, run: run); status = "Waiting for your partner to accept Soul Link."
        } catch { status = "Couldn’t save the Soul Link invitation." }
    }
    func accept() {
        guard canStart, let incoming, let binding else { return }
        do {
            try probe.start(run: incoming, binding: binding); ledger = probe.read().ledger; peerRows = []
            transmit(.accept, run: incoming); self.incoming = nil; confirmed = false
        } catch { status = "Start a new game and receive only your starter first." }
    }
    func decline() {
        if let incoming { transmit(.decline, run: incoming) }
        incoming = nil
    }
    func receive(_ data: Data) {
        guard BoundMultiplayerFeatures.isEnabled, connected?() == true, let packet = BoundSoulPacket.decode(data), let binding else { return }
        if ledger?.run == packet.run, ledger?.ended == true, packet.kind != .end { return }
        guard !retiredEpochs.contains(packet.sender) else { return }
        let fresh = packet.receiver == epoch
        if fresh {
            if let old = peerEpoch, old != packet.sender {
                retiredEpochs.append(old); if retiredEpochs.count > 16 { retiredEpochs.removeFirst() }
            }
            peerEpoch = packet.sender; proposedEpoch = nil
        } else if proposedEpoch == nil {
            proposedEpoch = packet.sender; proposalAt = clock()
        }
        // Tombstones are monotonic and safe even before the challenge completes.
        // An old alive packet can never mark a reconnected partner ready.
        if ledger?.run == packet.run, packet.kind == .state {
            do { try probe.merge(run: packet.run, rows: packet.rows, losses: packet.losses); ledger = probe.read().ledger }
            catch { status = "Couldn’t preserve your partner’s Soul Link record."; _ = core?.pause(); return }
        }
        if !fresh && ![.offer, .end].contains(packet.kind) { return }
        switch packet.kind {
        case .end:
            guard let ledger, ledger.run == packet.run, ledger.binding == binding else { return }
            if !ledger.ended { endRun() }
            confirmed = true; lastPeer = clock()
        case .offer:
            if let ledger, ledger.run == packet.run, ledger.binding == binding { transmit(.accept, run: ledger.run) }
            else if canStart, offered == nil, incoming == nil { incoming = packet.run; offeredAt = clock() }
            else { transmit(.decline, run: packet.run) }
        case .accept:
            if let ledger, ledger.run == packet.run, ledger.binding == binding {
                do { try probe.markAccepted(); self.ledger = probe.read().ledger }
                catch { status = "Couldn’t save Soul Link acceptance."; _ = core?.pause(); return }
                offered = nil; transmit(.confirm, run: ledger.run); confirmed = true; lastPeer = clock()
            }
            else if offered == packet.run, canStart {
                do {
                    try probe.start(run: packet.run, binding: binding); ledger = probe.read().ledger
                    offered = nil; confirmed = true; lastPeer = clock()
                    transmit(.confirm, run: packet.run)
                } catch { status = "Couldn’t start Soul Link. Keep only your starter." }
            }
        case .confirm, .state:
            guard let ledger, ledger.run == packet.run, ledger.binding == binding else { return }
            do {
                try probe.merge(run: packet.run, rows: packet.rows, losses: packet.losses)
                try probe.markAccepted(); offered = nil
                self.ledger = probe.read().ledger
                for row in packet.rows {
                    if let i = peerRows.firstIndex(where: { $0.slot == row.slot }) { peerRows[i] = row }
                    else { peerRows.append(row) }
                }
                confirmed = true; lastPeer = clock()
            } catch { status = "Couldn’t preserve your partner’s Soul Link record."; _ = core?.pause() }
        case .decline:
            if ledger?.run == packet.run, ledger?.offering == true { cancelInvitation() }
        }
    }
    func endRun() {
        if let core, core.state == .running, !core.pause() { status = "Couldn’t pause this run safely."; return }
        do {
            try probe.endRun(); ledger = probe.read().ledger
            if let ledger { transmit(.end, run: ledger.run) }
            status = "Soul Link ended. Your run record is kept."; offered = nil; incoming = nil
        } catch { status = "Couldn’t save the end of this run." }
    }
    func cancelInvitation() {
        let wasRunning = core?.state == .running
        if wasRunning, core?.pause() != true { status = "Couldn’t pause this run safely."; return }
        do { try probe.cancelOffer(); ledger = probe.read().ledger; offered = nil; status = "Soul Link invitation cancelled." }
        catch { status = "Couldn’t cancel the Soul Link invitation." }
    }
    func peerGone() {
        confirmed = false; lastPeer = 0; epoch = UUID(); peerEpoch = nil
        proposedEpoch = nil; retiredEpochs = []
    }
    func tick(at time: TimeInterval? = nil) {
        let now = time ?? clock()
        if proposedEpoch != nil, now - proposalAt > 1 { peerGone() }
        probe.setPreviewEnabled(BoundMultiplayerFeatures.isEnabled)
        defer { bannerChanged?((probe.read().error != nil || (active && !paired)) ? status : nil) }
        let snapshot = probe.read(); if snapshot.ledger != ledger { ledger = snapshot.ledger }
        canStart = BoundMultiplayerFeatures.isEnabled && supported && snapshot.ready && snapshot.mons.count == 1
            && !snapshot.mons.contains(where: { $0.eggOrigin || ($0.hp ?? 0) <= 0 })
            && (ledger == nil || ledger?.ended == true) && binding != nil && connected?() == true && nativeActivity?() != true
        if let error = snapshot.error { status = error; _ = core?.pause(); return }
        if incoming != nil, now - offeredAt > 30 { incoming = nil }
        guard let ledger else {
            if offered == nil && incoming == nil {
                status = canStart ? "Ready to start Soul Link." : "Start a new game, receive only your starter, and connect to your partner."
            }
            if let offered, now - sent > 1 { sent = now; transmit(.offer, run: offered) }
            return
        }
        let transportReady = BoundMultiplayerFeatures.isEnabled && connected?() == true && binding == ledger.binding
        if ledger.ended { status = "Soul Link ended. Your run record is kept." }
        else if !transportReady || !confirmed || now - lastPeer > 3 {
            status = "Soul Link paused. Reconnect to your partner to continue."
            if core?.state == .running { _ = core?.pause() }
        } else { status = "Soul Link active" }
        guard transportReady, now - sent >= 0.25 else { return }
        sent = now
        if ledger.ended { transmit(.end, run: ledger.run); return }
        if ledger.offering { transmit(.offer, run: ledger.run); return }
        let records = ledger.records.filter(\.eligible)
        let slots = Set(records.map(\.slot)).union(ledger.dead).sorted()
        let rows = slots.map { key in BoundSoulRow(slot: key, name: records.first(where: { $0.slot == key })?.name ?? "", dead: ledger.dead.contains(key)) }
        let chunk: [BoundSoulRow]
        if rows.isEmpty { chunk = [] }
        else {
            cursor = cursor % rows.count; chunk = Array(rows[cursor..<min(cursor + 3, rows.count)]); cursor = (cursor + chunk.count) % rows.count
        }
        transmit(.state, run: ledger.run, rows: chunk)
    }
}

struct BoundSoulControls: View {
    @ObservedObject var session: BoundSoulSession
    @State private var confirming = false
    @State private var ending = false
    var body: some View {
        if BoundMultiplayerFeatures.isEnabled {
            Section("Soul Link") {
                Text(session.status).font(.caption).accessibilityIdentifier("bound.soul-link.status")
                if session.ledger == nil || session.ledger?.ended == true {
                    if session.incoming != nil {
                        Button("Accept Soul Link") { confirming = true }.disabled(!session.canStart)
                        Button("Decline", role: .cancel) { session.decline() }
                    } else {
                        Button(session.offered == nil ? "Start Soul Link" : "Invitation sent") { confirming = true }
                            .disabled(!session.canStart || session.offered != nil)
                            .accessibilityIdentifier("bound.soul-link.start")
                    }
                }
                if let ledger = session.ledger {
                    if ledger.offering { Button("Cancel invitation", role: .cancel) { session.cancelInvitation() } }
                    else if !ledger.ended { Button("End Soul Link run", role: .destructive) { ending = true } }
                    ForEach(ledger.records.filter(\.eligible).sorted { $0.slot < $1.slot }, id: \.slot) { record in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(Self.title(record.slot, names: session.areaNames))
                                Text(record.name + " ↔ " + (session.peerRows.first(where: { $0.slot == record.slot })?.name.nilIfEmpty ?? "Waiting for partner’s catch"))
                                    .font(.caption)
                            }
                            Spacer()
                            Text(ledger.dead.contains(record.slot) ? "Fainted" : "Alive")
                                .foregroundStyle(ledger.dead.contains(record.slot) ? .red : .primary)
                        }
                    }
                }
            }
            .confirmationDialog("End this Soul Link run?", isPresented: $ending, titleVisibility: .visible) {
                Button("End run", role: .destructive) { session.endRun() }
            } message: {
                Text("This ends the challenge for both players. Your Pokémon and the run record are kept. Your partner receives the result when you reconnect.")
            }
            .confirmationDialog("Start Soul Link with this friend?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Start Soul Link") { if session.incoming != nil { session.accept() } else { session.invite() } }
            } message: {
                Text("Start after receiving only your starter. One catch per named area, including raids. Eggs pair as Egg 1, Egg 2. Fainting permanently disables both linked Pokémon. Stay connected to play this run. Friend battles and trades are unavailable during the run.")
            }
        }
    }
    static func title(_ slot: String, names: [Int: String] = [:]) -> String {
        let parts = slot.split(separator: ":")
        if parts.first == "area", let value = Int(parts.last ?? ""), let name = names[value] { return name }
        return (parts.first == "egg" ? "Egg " : "Area ") + String(parts.last ?? "")
    }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

@MainActor
final class BoundSoulBanner: UILabel {
    init() {
        super.init(frame: .zero)
        numberOfLines = 0; textAlignment = .center
        font = .preferredFont(forTextStyle: .caption1)
        backgroundColor = .secondarySystemBackground; textColor = .label
        layer.cornerRadius = 8; clipsToBounds = true; isHidden = true
        accessibilityIdentifier = "bound.soul-link.paused"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func show(_ message: String?) {
        guard text != message || isHidden != (message == nil) else { return }
        text = message; isHidden = message == nil
        if message != nil { superview?.bringSubviewToFront(self) }
    }
}
