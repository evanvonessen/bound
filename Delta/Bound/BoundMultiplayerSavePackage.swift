import Foundation
import CryptoKit

/// Shared run configuration. Battery saves, seeds and recovery remain player-owned.
struct BoundMultiplayerRunIdentity: Codable, Equatable, Sendable {
    var run: UUID
    var gameID: String
    var owner: UUID
    var partner: UUID
    var roomID: String
    var settingsOwner: UUID
    var settings: Data
    var localSeed: UInt32
    var partnerSeed: UInt32
    var romSHA256: String
    var protocolVersion: Int = 1
    var saveVersion: Int = 1

    var valid: Bool {
        !gameID.isEmpty && gameID.utf8.count <= 256 && owner != partner &&
        [owner, partner].contains(settingsOwner) && !roomID.isEmpty && roomID.utf8.count <= 256 &&
        settings.count <= 4096 && localSeed != 0 && partnerSeed != 0 && localSeed != partnerSeed &&
        BoundMultiplayerSaveStore.isDigest(romSHA256) && protocolVersion == 1 && saveVersion == 1
    }
}

struct BoundMultiplayerCheckpointReceipt: Codable, Equatable, Sendable {
    var run: UUID
    var checkpoint: UUID
    var owner: UUID
    var payloadSHA256: String
    var sharedEventDigest: String
}

struct BoundMultiplayerRunManifest: Codable, Equatable, Sendable {
    var identity: BoundMultiplayerRunIdentity
    var deviceOwner: UUID
    var releasedForTransfer: Bool = false
    var ended: Bool = false
    private enum CodingKeys: String, CodingKey { case identity, deviceOwner, releasedForTransfer, ended }
    init(identity: BoundMultiplayerRunIdentity, deviceOwner: UUID, releasedForTransfer: Bool = false, ended: Bool = false) {
        self.identity = identity; self.deviceOwner = deviceOwner
        self.releasedForTransfer = releasedForTransfer; self.ended = ended
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(BoundMultiplayerRunIdentity.self, forKey: .identity)
        deviceOwner = try values.decode(UUID.self, forKey: .deviceOwner)
        releasedForTransfer = try values.decodeIfPresent(Bool.self, forKey: .releasedForTransfer) ?? false
        ended = try values.decodeIfPresent(Bool.self, forKey: .ended) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(identity, forKey: .identity)
        try values.encode(deviceOwner, forKey: .deviceOwner)
        try values.encode(releasedForTransfer, forKey: .releasedForTransfer)
        if ended { try values.encode(true, forKey: .ended) }
    }
}

struct BoundMultiplayerSavePackage: Codable, Equatable, Sendable {
    struct Blob: Codable, Equatable, Sendable {
        var data: Data
        var sha256: String
        init(_ data: Data) { self.data = data; sha256 = BoundMultiplayerSaveStore.hash(data) }
    }
    struct Payload: Codable, Equatable, Sendable {
        var version = 1
        var manifest: BoundMultiplayerRunManifest
        var checkpoint: UUID
        var predecessor: UUID?
        var sharedEventDigest: String
        var files: [String: Blob]
    }
    var payload: Payload
    var receipt: BoundMultiplayerCheckpointReceipt
    var partnerReceipt: BoundMultiplayerCheckpointReceipt?
    var complete: Bool { partnerReceipt != nil }
}

/// This store has no network dependency. Writes must finish before a peer receives
/// a checkpoint receipt. Harmony transports only immutable completed checkpoints.
final class BoundMultiplayerSaveStore: @unchecked Sendable {
    enum Failure: LocalizedError, Equatable {
        case corrupt, incompatible, ownerMismatch, deviceOwned, activeGame, conflict, incomplete, missingSave
        var errorDescription: String? {
            switch self {
            case .corrupt: return "The Soul Link package needs recovery. Original files were kept."
            case .incompatible: return "This Soul Link package needs its original ROM and save version."
            case .ownerMismatch: return "Sign in to the account that owns this Soul Link save."
            case .deviceOwned: return "Continue this run on its current device, or transfer it from that device."
            case .activeGame: return "Close this game before restoring a Soul Link package."
            case .conflict: return "Conflicting Soul Link checkpoints were kept for recovery."
            case .incomplete: return "Waiting for both players to finish saving."
            case .missingSave: return "The game has not finished saving yet."
            }
        }
    }
    struct CloudArchive: Codable {
        var version = 1
        var checkpoints: [BoundMultiplayerSavePackage]
    }
    struct Incoming {
        let archiveURL: URL
        let manifest: BoundMultiplayerRunManifest
        let receipt: BoundMultiplayerCheckpointReceipt
    }
    struct Suspension: Codable, Equatable {
        let package: BoundMultiplayerSavePackage
        var previous: UUID? = nil
        var snapshot: Data { package.payload.files["checkpoint.state"]?.data ?? Data() }
        var batterySHA256: String { package.payload.files["game.sav"]?.sha256 ?? "" }
        var journalSHA256: String? { package.payload.files["soul.json"]?.sha256 }
        var timelineSHA256: String? { package.payload.files["timeline.json"]?.sha256 }
        var manifest: BoundMultiplayerRunManifest { package.payload.manifest }
    }
    static let shared = BoundMultiplayerSaveStore()
    static let packageIdentifier = "boundMultiplayerPackage"
    static let maximumPackageBytes = 96 * 1024 * 1024
    let root: URL
    let support: URL
    let deviceID: UUID
    private let identityAvailable: Bool
    private let lock = NSRecursiveLock()
    private var activeGames = Set<String>()
    private let fm = FileManager.default

    init(root: URL? = nil, support: URL? = nil, deviceID: UUID? = nil) {
        let support = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.support = support
        self.root = root ?? support.appendingPathComponent("Soul Link Packages", isDirectory: true)
        if let deviceID { self.deviceID = deviceID; identityAvailable = true }
        else if let deviceID = try? BoundMultiplayerDeviceIdentity.current() {
            self.deviceID = deviceID; identityAvailable = true
        } else {
            // A locked/unavailable keychain must never silently mint a durable
            // replacement owner. Every operation that could advance fails closed.
            self.deviceID = UUID(); identityAvailable = false
        }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    func directory(gameID: String) -> URL { root.appendingPathComponent(Self.hash(Data(gameID.utf8)), isDirectory: true) }
    func cloudURL(gameID: String) -> URL { directory(gameID: gameID).appendingPathComponent("complete.boundrun") }
    func cloudBatteryURL(gameID: String) -> URL { directory(gameID: gameID).appendingPathComponent("complete.sav") }
    func hasRun(gameID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let manifest = try? manifest(gameID: gameID), manifest.ended {
            do {
                if try inspectIncoming(gameID: gameID) != nil { return true }
                let inbox = directory(gameID: gameID).appendingPathComponent("Incoming", isDirectory: true)
                for folder in (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [] {
                    if fm.fileExists(atPath: folder.appendingPathComponent("complete.boundrun").path) { continue }
                    let run: UUID = try read(folder.appendingPathComponent("run-hint.json"), maximum: 128)
                    if run != manifest.identity.run { return true }
                }
                return false
            } catch { return true }
        }
        let folder = directory(gameID: gameID)
        return ["run.json", "head.json", "suspension-head.json", "complete.boundrun", "Restore", "Incoming"].contains {
            fm.fileExists(atPath: folder.appendingPathComponent($0).path)
        } || !pendingImports(gameID: gameID).isEmpty
    }
    func setActive(_ active: Bool, gameID: String) {
        lock.lock(); defer { lock.unlock() }
        if active { activeGames.insert(gameID) } else { activeGames.remove(gameID) }
    }
    func manifest(gameID: String) throws -> BoundMultiplayerRunManifest? {
        lock.lock(); defer { lock.unlock() }
        let url = directory(gameID: gameID).appendingPathComponent("run.json")
        guard fm.fileExists(atPath: url.path) else { return nil }
        let manifest: BoundMultiplayerRunManifest = try read(url, maximum: 16_384)
        guard manifest.identity.valid, manifest.identity.gameID == gameID else { throw Failure.corrupt }
        return manifest
    }
    /// Persist once before setup acceptance. Never reroll configuration on reopen.
    func begin(_ identity: BoundMultiplayerRunIdentity, gameSaveURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard identityAvailable else { throw Failure.deviceOwned }
        guard identity.valid else { throw Failure.incompatible }
        if let existing = try manifest(gameID: identity.gameID) {
            if existing.ended {
                guard existing.identity.run != identity.run else { throw Failure.conflict }
                let archive = root.appendingPathComponent("Finished Runs", isDirectory: true)
                try create(archive)
                let destination = archive.appendingPathComponent(existing.identity.run.uuidString, isDirectory: true)
                guard !fm.fileExists(atPath: destination.path) else { throw Failure.conflict }
                try fm.moveItem(at: directory(gameID: identity.gameID), to: destination)
            } else {
                guard existing.identity == identity else { throw Failure.conflict }
                try checkDevice(existing); return
            }
        }
        guard !hasRun(gameID: identity.gameID) else { throw Failure.conflict }
        let folder = directory(gameID: identity.gameID)
        try create(folder)
        let backup = folder.appendingPathComponent("pre-run-solo.sav")
        if fm.fileExists(atPath: gameSaveURL.path), !fm.fileExists(atPath: backup.path) {
            try writeData(Data(contentsOf: gameSaveURL), to: backup)
        }
        try write(BoundMultiplayerRunManifest(identity: identity, deviceOwner: deviceID), to: folder.appendingPathComponent("run.json"))
    }
    func validateForResume(gameID: String, owner: UUID, romSHA256: String) throws -> BoundMultiplayerRunManifest? {
        lock.lock(); defer { lock.unlock() }
        guard let manifest = try manifest(gameID: gameID) else {
            guard !hasRun(gameID: gameID) else { throw Failure.conflict }
            return nil
        }
        guard !manifest.ended else { return nil }
        guard !fm.fileExists(atPath: directory(gameID: gameID).appendingPathComponent("Restore").path) else { throw Failure.conflict }
        guard manifest.identity.owner == owner else { throw Failure.ownerMismatch }
        guard manifest.identity.romSHA256 == romSHA256 else { throw Failure.incompatible }
        try checkDevice(manifest)
        _ = try latestComplete(gameID: gameID)
        return manifest
    }
    private func checkDevice(_ manifest: BoundMultiplayerRunManifest) throws {
        guard identityAvailable, manifest.deviceOwner == deviceID, !manifest.releasedForTransfer, !manifest.ended else { throw Failure.deviceOwned }
    }
    /// Called only for a mutually acknowledged ROM End Soul Link action, after the
    /// permanent Soul ledger records its end. Feature disable never calls this.
    func endRun(gameID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard var manifest = try manifest(gameID: gameID) else { throw Failure.incompatible }
        if manifest.ended { return }
        try checkDevice(manifest)
        let stem = Self.hash(Data(gameID.utf8))
        let url = support.appendingPathComponent("Soul Link/" + stem + ".json")
        guard let ledger = try JSONSerialization.jsonObject(with: readData(url, maximum: 4_194_304)) as? [String: Any],
              ledger["ended"] as? Bool == true, let run = ledger["run"] as? String,
              UUID(uuidString: run) == manifest.identity.run else { throw Failure.incomplete }
        manifest.ended = true
        try write(manifest, to: directory(gameID: gameID).appendingPathComponent("run.json"))
        activeGames.remove(gameID)
    }
    private struct NewGameArchive: Codable {
        let identity: BoundMultiplayerRunIdentity
        let device: UUID
        let files: [String: String]
    }
    func pendingNewGame(gameID: String) throws -> UUID? {
        lock.lock(); defer { lock.unlock() }
        let url = directory(gameID: gameID).appendingPathComponent("pending-new-game.json")
        return fm.fileExists(atPath: url.path) ? try read(url, maximum: 128) : nil
    }
    private func newGameManifest(gameID: String, run: UUID, owner: UUID) throws -> BoundMultiplayerRunManifest {
        guard let value = try manifest(gameID: gameID), value.identity.run == run else { throw Failure.conflict }
        guard value.identity.owner == owner else { throw Failure.ownerMismatch }
        guard identityAvailable, value.deviceOwner == deviceID, !value.releasedForTransfer else { throw Failure.deviceOwned }
        return value
    }
    private func newGameArchiveURL(_ run: UUID) -> URL {
        root.appendingPathComponent("New Game Originals", isDirectory: true).appendingPathComponent(run.uuidString, isDirectory: true)
    }
    private func validateNewGameArchive(_ manifest: BoundMultiplayerRunManifest) throws {
        let folder = newGameArchiveURL(manifest.identity.run)
        let receipt: NewGameArchive = try read(folder.appendingPathComponent("receipt.json"), maximum: 4_194_304)
        guard receipt.identity == manifest.identity, receipt.device == deviceID, !receipt.files.isEmpty else { throw Failure.corrupt }
        for (name, hash) in receipt.files {
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), Self.isDigest(hash),
                  Self.hash(try readData(folder.appendingPathComponent(name), maximum: Self.maximumPackageBytes)) == hash else { throw Failure.corrupt }
        }
    }
    /// An explicit fresh game retires a run, so damaged checkpoint contents are
    /// preserved as raw files, not interpreted as a playable recovery snapshot.
    /// The active manifest and account/device identity must still be trustworthy.
    func preserveForNewGame(gameID: String, run: UUID, owner: UUID, gameSaveURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let manifest = try newGameManifest(gameID: gameID, run: run, owner: owner)
        let destination = newGameArchiveURL(run)
        if fm.fileExists(atPath: destination.path) {
            try validateNewGameArchive(manifest)
        } else {
            let staging = destination.deletingLastPathComponent().appendingPathComponent(run.uuidString + "." + UUID().uuidString + ".pending", isDirectory: true)
            try create(staging)
            var hashes: [String: String] = [:]
            func copy(_ source: URL, _ name: String) throws {
                let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw Failure.corrupt }
                if values.isDirectory == true {
                    try create(staging.appendingPathComponent(name, isDirectory: true))
                    for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                        try copy(child, name + "/" + child.lastPathComponent)
                    }
                } else {
                    let data = try readData(source, maximum: Self.maximumPackageBytes)
                    let target = staging.appendingPathComponent(name)
                    try create(target.deletingLastPathComponent())
                    try writeData(data, to: target)
                    let hash = Self.hash(data)
                    guard Self.hash(try readData(target, maximum: Self.maximumPackageBytes)) == hash else { throw Failure.corrupt }
                    hashes[name] = hash
                }
            }
            try copy(directory(gameID: gameID), "Package")
            if fm.fileExists(atPath: gameSaveURL.path) { try copy(gameSaveURL, "Personal/game.sav") }
            let stem = Self.hash(Data(gameID.utf8))
            for (name, suffix) in [("soul.json", ".json"), ("timeline.json", ".timeline.json")] {
                let source = support.appendingPathComponent("Soul Link/" + stem + suffix)
                if fm.fileExists(atPath: source.path) { try copy(source, "Personal/" + name) }
            }
            // Include even malformed native journals without inferring which
            // game they belong to. Active native recovery is never discarded.
            let recovery = support.appendingPathComponent("Friend Battles", isDirectory: true)
            if fm.fileExists(atPath: recovery.path) { try copy(recovery, "Native Recovery") }
            try write(NewGameArchive(identity: manifest.identity, device: deviceID, files: hashes), to: staging.appendingPathComponent("receipt.json"))
            try fm.moveItem(at: staging, to: destination)
            try validateNewGameArchive(manifest)
        }
        try write(run, to: directory(gameID: gameID).appendingPathComponent("pending-new-game.json"))
    }
    func isNewGameReady(gameID: String, run: UUID, owner: UUID) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let manifest = try newGameManifest(gameID: gameID, run: run, owner: owner)
        let url = directory(gameID: gameID).appendingPathComponent("new-game-ready.json")
        guard manifest.ended, fm.fileExists(atPath: url.path) else { return false }
        let recorded: UUID = try read(url, maximum: 128)
        guard recorded == run else { throw Failure.conflict }
        try validateNewGameArchive(manifest)
        return true
    }
    func hasStartedNewGame(gameID: String, run: UUID) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let url = directory(gameID: gameID).appendingPathComponent("new-game-started.json")
        guard fm.fileExists(atPath: url.path) else { return false }
        let recorded: UUID = try read(url, maximum: 128)
        guard recorded == run else { throw Failure.conflict }
        return true
    }
    /// The native Oak handshake confirms that the fresh game actually started.
    /// A solo choice may never call begin(), so consume recovery intent here.
    func acknowledgeNewGameStarted(gameID: String, run: UUID, owner: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard try pendingNewGame(gameID: gameID) == run,
              try isNewGameReady(gameID: gameID, run: run, owner: owner) else { throw Failure.incomplete }
        if try hasStartedNewGame(gameID: gameID, run: run) { return }
        try write(run, to: directory(gameID: gameID).appendingPathComponent("new-game-started.json"))
    }
    /// The coordinator calls this only after the authenticated server end (or
    /// its idempotent already-ended reply). Unlike ordinary End Soul Link, this
    /// can retire a corrupt ledger because its exact original was archived.
    func finishNewGame(gameID: String, run: UUID, owner: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var manifest = try newGameManifest(gameID: gameID, run: run, owner: owner)
        guard try pendingNewGame(gameID: gameID) == run else { throw Failure.conflict }
        try validateNewGameArchive(manifest)
        if try isNewGameReady(gameID: gameID, run: run, owner: owner) { return }
        let retired = directory(gameID: gameID).appendingPathComponent("Restarted Originals", isDirectory: true)
        try create(retired)
        let stem = Self.hash(Data(gameID.utf8))
        var sources = [("soul.json", support.appendingPathComponent("Soul Link/" + stem + ".json")),
                       ("timeline.json", support.appendingPathComponent("Soul Link/" + stem + ".timeline.json"))]
        for name in ["Incoming", "Restore"] { sources.append((name, directory(gameID: gameID).appendingPathComponent(name))) }
        for (name, source) in sources where fm.fileExists(atPath: source.path) {
            // Unique names also retain any files delivered during a prior
            // interrupted attempt. Never overwrite an earlier original.
            try fm.moveItem(at: source, to: retired.appendingPathComponent(UUID().uuidString + "-" + name))
        }
        manifest.ended = true
        try write(manifest, to: directory(gameID: gameID).appendingPathComponent("run.json"))
        try write(run, to: directory(gameID: gameID).appendingPathComponent("new-game-ready.json"))
        activeGames.remove(gameID)
    }

    /// Only the broker's live, typed lease can authorize adopting a foreign device
    /// checkpoint. The grant's initializer belongs to the lease client.
    func adoptOwnership(gameID: String, grant: BoundRunLeaseGrant) throws {
        lock.lock(); defer { lock.unlock() }
        guard !activeGames.contains(gameID), var manifest = try manifest(gameID: gameID) else { throw Failure.activeGame }
        guard !manifest.ended else { throw Failure.conflict }
        try validateGrant(grant, identity: manifest.identity)
        guard manifest.deviceOwner == deviceID || grant.allowsTransfer else { throw Failure.deviceOwned }
        manifest.deviceOwner = deviceID; manifest.releasedForTransfer = false
        try write(manifest, to: directory(gameID: gameID).appendingPathComponent("run.json"))
    }
    private func validateGrant(_ grant: BoundRunLeaseGrant, identity: BoundMultiplayerRunIdentity) throws {
        guard identityAvailable, grant.isCurrent, grant.ownerID == identity.owner, grant.runID == identity.run,
              grant.deviceID == deviceID, grant.fence > 0 else { throw Failure.deviceOwned }
    }
    /// Local crash/disconnect recovery is deliberately not a paired checkpoint.
    /// Caller pauses the core and flushes its battery, then supplies the matching
    /// exact-ROM snapshot. Previous suspensions and native recovery stay preserved.
    @discardableResult
    func captureSuspension(gameID: String, romSHA256: String, gameSaveURL: URL, snapshot: Data) throws -> Suspension {
        lock.lock(); defer { lock.unlock() }
        guard let manifest = try manifest(gameID: gameID), manifest.identity.romSHA256 == romSHA256 else { throw Failure.incompatible }
        try checkDevice(manifest)
        let files = try captureFiles(manifest: manifest, gameSaveURL: gameSaveURL, additionalFiles: ["checkpoint.state": snapshot])
        let digest = Self.hash((files["soul.json"]?.data ?? Data()) + (files["timeline.json"]?.data ?? Data()))
        let payload = BoundMultiplayerSavePackage.Payload(manifest: manifest, checkpoint: UUID(),
            predecessor: try latestComplete(gameID: gameID)?.payload.checkpoint, sharedEventDigest: digest, files: files)
        let receipt = BoundMultiplayerCheckpointReceipt(run: manifest.identity.run, checkpoint: payload.checkpoint,
            owner: manifest.identity.owner, payloadSHA256: Self.hash(try Self.encode(payload)), sharedEventDigest: digest)
        let headURL = directory(gameID: gameID).appendingPathComponent("suspension-head.json")
        let previous: UUID? = fm.fileExists(atPath: headURL.path) ? try read(headURL, maximum: 128) : nil
        let suspension = Suspension(package: .init(payload: payload, receipt: receipt), previous: previous)
        try validate(suspension.package, complete: false)
        // Even if a native recovery journal is deleted after a completed trade,
        // the earlier suspension still retains its original journal and state.
        let folder = directory(gameID: gameID).appendingPathComponent("Suspensions", isDirectory: true)
        try write(suspension, to: folder.appendingPathComponent(payload.checkpoint.uuidString + ".json"))
        try write(payload.checkpoint, to: headURL)
        pruneSuspensions(gameID: gameID, current: suspension)
        return suspension
    }
    /// A lightweight change detector for durable personal history. Native state
    /// bytes are represented by their recovery journal's verified digest field.
    /// This is separate from the shared peer digest, which excludes local events.
    func workingRevision(gameID: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let manifest = try manifest(gameID: gameID), !manifest.ended else { return nil }
        var hashes: [String: String] = [:]
        let stem = Self.hash(Data(gameID.utf8))
        for (name, url) in [
            ("soul.json", support.appendingPathComponent("Soul Link/" + stem + ".json")),
            ("timeline.json", support.appendingPathComponent("Soul Link/" + stem + ".timeline.json"))
        ] where fm.fileExists(atPath: url.path) {
            hashes[name] = Self.hash(try readData(url, maximum: 4_194_304))
        }
        let folder = support.appendingPathComponent("Friend Battles", isDirectory: true)
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            let bytes = try readData(url, maximum: 4096)
            guard let values = try JSONSerialization.jsonObject(with: bytes) as? [String: String], values["gameID"] == gameID else { continue }
            guard values["rom"] == manifest.identity.romSHA256, let state = values["state"],
                  validRecoveryName(state, extension: "state"), validRecoveryName(url.lastPathComponent, extension: "json"),
                  let digest = values["sha256"], Self.isDigest(digest) else { throw Failure.corrupt }
            hashes["recovery/" + url.lastPathComponent] = Self.hash(bytes)
        }
        return Self.hash(try Self.encode(hashes))
    }
    private func pruneSuspensions(gameID: String, current: Suspension) {
        let folder = directory(gameID: gameID).appendingPathComponent("Suspensions", isDirectory: true)
        var keep: Set<UUID> = [current.package.payload.checkpoint]
        var previous = current.previous
        // Follow durable capture order, never filesystem timestamps. A missing
        // older link is normal after pruning; unknown/corrupt files stay intact.
        while keep.count < 3, let id = previous, !keep.contains(id),
              let capture: Suspension = try? read(folder.appendingPathComponent(id.uuidString + ".json"), maximum: Self.maximumPackageBytes),
              capture.package.payload.checkpoint == id, capture.manifest.identity == current.manifest.identity,
              (try? validate(capture.package, complete: false)) != nil {
            keep.insert(id); previous = capture.previous
        }
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            guard let capture: Suspension = try? read(url, maximum: Self.maximumPackageBytes),
                  capture.manifest.identity == current.manifest.identity,
                  url.lastPathComponent == capture.package.payload.checkpoint.uuidString + ".json",
                  !keep.contains(capture.package.payload.checkpoint),
                  (try? validate(capture.package, complete: false)) != nil else { continue }
            let recoveryIsRetained = capture.package.payload.files.allSatisfy { name, blob in
                !name.hasPrefix("recovery/") || current.package.payload.files[name]?.sha256 == blob.sha256
            }
            if recoveryIsRetained { try? fm.removeItem(at: url) }
        }
    }
    func suspension(gameID: String) throws -> Suspension? {
        lock.lock(); defer { lock.unlock() }
        let head = directory(gameID: gameID).appendingPathComponent("suspension-head.json")
        guard fm.fileExists(atPath: head.path) else { return nil }
        let id: UUID = try read(head, maximum: 128)
        let url = directory(gameID: gameID).appendingPathComponent("Suspensions/" + id.uuidString + ".json")
        let suspension: Suspension = try read(url, maximum: Self.maximumPackageBytes)
        try validate(suspension.package, complete: false)
        guard suspension.package.partnerReceipt == nil, !suspension.snapshot.isEmpty,
              suspension.package.payload.checkpoint == id, let manifest = try manifest(gameID: gameID),
              suspension.manifest.identity == manifest.identity else { throw Failure.corrupt }
        try checkDevice(suspension.manifest)
        // A completed checkpoint after this capture supersedes the old local
        // snapshot. Retain its bytes without treating it as current progress.
        guard suspension.package.payload.predecessor == (try latestComplete(gameID: gameID))?.payload.checkpoint else { return nil }
        return suspension
    }
    /// Reopen only the current personal snapshot. Journals may advance by merging
    /// partner history after this check, but an old snapshot never erases them.
    func validateSuspensionForResume(gameID: String, owner: UUID, romSHA256: String, gameSaveURL: URL) throws -> Suspension? {
        lock.lock(); defer { lock.unlock() }
        guard let suspension = try suspension(gameID: gameID) else { return nil }
        guard suspension.manifest.identity.owner == owner else { throw Failure.ownerMismatch }
        guard suspension.manifest.identity.romSHA256 == romSHA256 else { throw Failure.incompatible }
        try validatePersonalFiles(suspension.package, gameSaveURL: gameSaveURL)
        return suspension
    }
    /// Validate local progress once, before reconnect begins merging peer deaths
    /// and history. Loading its emulator state must never replace those journals.
    func validateCheckpointForResume(gameID: String, checkpointID: UUID, owner: UUID,
                                     romSHA256: String, gameSaveURL: URL) throws -> BoundMultiplayerSavePackage? {
        lock.lock(); defer { lock.unlock() }
        guard let package = try checkpoint(gameID: gameID, id: checkpointID) else { return nil }
        guard let manifest = try manifest(gameID: gameID), manifest.identity == package.payload.manifest.identity else { throw Failure.conflict }
        guard manifest.identity.owner == owner else { throw Failure.ownerMismatch }
        guard manifest.identity.romSHA256 == romSHA256 else { throw Failure.incompatible }
        try checkDevice(manifest)
        guard !hasInterruptedRestore(gameID: gameID) else { throw Failure.conflict }
        try validatePersonalFiles(package, gameSaveURL: gameSaveURL)
        return package
    }
    private func validatePersonalFiles(_ package: BoundMultiplayerSavePackage, gameSaveURL: URL) throws {
        var additional = [String: Data]()
        if package.payload.files["setup.json"] != nil {
            additional["setup.json"] = try readData(directory(gameID: package.payload.manifest.identity.gameID).appendingPathComponent("setup.json"), maximum: 16_384)
        }
        let current = try captureFiles(manifest: package.payload.manifest, gameSaveURL: gameSaveURL, additionalFiles: additional)
        for (name, blob) in package.payload.files where name != "checkpoint.state" {
            guard current[name]?.sha256 == blob.sha256 else { throw Failure.conflict }
        }
        for (name, blob) in current where name != "checkpoint.state" {
            guard package.payload.files[name]?.sha256 == blob.sha256 else { throw Failure.conflict }
        }
    }
    /// Caller pauses the emulator and flushes cartridge SRAM before this call.
    /// `additionalFiles` is restricted to checkpoint.state and setup.json.
    func prepare(gameID: String, checkpointID: UUID, predecessor: UUID?, sharedEventDigest: String,
                 gameSaveURL: URL, additionalFiles: [String: Data] = [:]) throws -> BoundMultiplayerCheckpointReceipt {
        lock.lock(); defer { lock.unlock() }
        guard let manifest = try manifest(gameID: gameID) else { throw Failure.incompatible }
        try checkDevice(manifest)
        guard Self.isDigest(sharedEventDigest), additionalFiles.keys.allSatisfy({ ["checkpoint.state", "setup.json"].contains($0) }) else { throw Failure.corrupt }
        if let old = try checkpoint(gameID: gameID, id: checkpointID) {
            guard old.payload.predecessor == predecessor, old.payload.sharedEventDigest == sharedEventDigest else { throw Failure.conflict }
            return old.receipt
        }
        let head = try latestComplete(gameID: gameID)
        guard head?.payload.checkpoint == predecessor else { throw Failure.conflict }
        let files = try captureFiles(manifest: manifest, gameSaveURL: gameSaveURL, additionalFiles: additionalFiles)
        let payload = BoundMultiplayerSavePackage.Payload(manifest: manifest, checkpoint: checkpointID,
            predecessor: predecessor, sharedEventDigest: sharedEventDigest, files: files)
        let receipt = BoundMultiplayerCheckpointReceipt(run: manifest.identity.run, checkpoint: checkpointID,
            owner: manifest.identity.owner, payloadSHA256: Self.hash(try Self.encode(payload)), sharedEventDigest: sharedEventDigest)
        let package = BoundMultiplayerSavePackage(payload: payload, receipt: receipt)
        try validate(package, complete: false)
        try write(package, to: checkpointURL(gameID: gameID, id: checkpointID, complete: false))
        return receipt
    }
    /// A complete marker is written after both durable receipts agree on run,
    /// checkpoint and shared history. A failed cloud upload never reverses it.
    @discardableResult
    func commit(gameID: String, checkpointID: UUID, partnerReceipt: BoundMultiplayerCheckpointReceipt) throws -> BoundMultiplayerSavePackage {
        lock.lock(); defer { lock.unlock() }
        guard var package = try checkpoint(gameID: gameID, id: checkpointID) else { throw Failure.incomplete }
        try checkDevice(package.payload.manifest)
        if let old = package.partnerReceipt, old != partnerReceipt { throw Failure.conflict }
        package.partnerReceipt = partnerReceipt
        try validate(package, complete: true)
        let head = try latestComplete(gameID: gameID)
        guard head?.payload.checkpoint == checkpointID || head?.payload.checkpoint == package.payload.predecessor else { throw Failure.conflict }
        try write(package, to: checkpointURL(gameID: gameID, id: checkpointID, complete: true))
        try write(checkpointID, to: directory(gameID: gameID).appendingPathComponent("head.json"))
        try exportCloud(gameID: gameID)
        return package
    }
    func latestComplete(gameID: String) throws -> BoundMultiplayerSavePackage? {
        lock.lock(); defer { lock.unlock() }
        let head = directory(gameID: gameID).appendingPathComponent("head.json")
        guard fm.fileExists(atPath: head.path) else { return nil }
        let id: UUID = try read(head, maximum: 128)
        guard let result = try checkpoint(gameID: gameID, id: id), result.complete else { throw Failure.corrupt }
        return result
    }
    func checkpoint(gameID: String, id: UUID) throws -> BoundMultiplayerSavePackage? {
        lock.lock(); defer { lock.unlock() }
        for complete in [true, false] {
            let url = checkpointURL(gameID: gameID, id: id, complete: complete)
            guard fm.fileExists(atPath: url.path) else { continue }
            let package: BoundMultiplayerSavePackage = try read(url, maximum: Self.maximumPackageBytes)
            try validate(package, complete: complete)
            guard package.payload.manifest.identity.gameID == gameID, package.payload.checkpoint == id else { throw Failure.corrupt }
            return package
        }
        return nil
    }
    func validateCloudExport(gameID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let manifest = try manifest(gameID: gameID) else {
            guard !hasRun(gameID: gameID) else { throw Failure.incomplete }
            return
        }
        guard !manifest.ended else { throw Failure.incomplete }
        let archive: CloudArchive = try read(cloudURL(gameID: gameID), maximum: Self.maximumPackageBytes)
        guard let first = archive.checkpoints.first, first.payload.manifest.identity == manifest.identity,
              first.payload.checkpoint == (try latestComplete(gameID: gameID))?.payload.checkpoint else { throw Failure.incomplete }
        try validateArchive(archive)
        let battery = try readData(cloudBatteryURL(gameID: gameID), maximum: 262_144)
        guard battery == first.payload.files["game.sav"]?.data else { throw Failure.corrupt }
    }
    /// Harmony hashes and uploads multiple files asynchronously. Give each upload
    /// immutable copies so a later checkpoint cannot mix two save generations.
    func snapshotCloudExport(gameID: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try validateCloudExport(gameID: gameID)
        let folder = directory(gameID: gameID).appendingPathComponent("Uploads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try create(folder)
        try fm.copyItem(at: cloudURL(gameID: gameID), to: folder.appendingPathComponent("complete.boundrun"))
        try fm.copyItem(at: cloudBatteryURL(gameID: gameID), to: folder.appendingPathComponent("game.sav"))
        return folder
    }
    func preparedCheckpoints(gameID: String) throws -> [BoundMultiplayerSavePackage] {
        lock.lock(); defer { lock.unlock() }
        let folder = directory(gameID: gameID).appendingPathComponent("Checkpoints", isDirectory: true)
        return try ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".prepared.json") }
            .compactMap { url in
                let package: BoundMultiplayerSavePackage = try read(url, maximum: Self.maximumPackageBytes)
                guard !fm.fileExists(atPath: checkpointURL(gameID: gameID, id: package.payload.checkpoint, complete: true).path) else { return nil }
                try validate(package, complete: false)
                return package
            }
    }
    /// Always route incoming files to a version-specific inbox. Nothing downloaded
    /// by Harmony writes into a running core's battery, journal or recovery files.
    func stageDownload(gameID: String, version: String, run: UUID? = nil) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let inbox = directory(gameID: gameID).appendingPathComponent("Incoming", isDirectory: true)
            .appendingPathComponent(Self.hash(Data(version.utf8)), isDirectory: true)
        try create(inbox)
        if let incomingRun = try run ?? manifest(gameID: gameID)?.identity.run {
            try write(incomingRun, to: inbox.appendingPathComponent("run-hint.json"))
        }
        return inbox
    }
    func pendingImports(gameID: String) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let inbox = directory(gameID: gameID).appendingPathComponent("Incoming", isDirectory: true)
        return ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("complete.boundrun") }.filter { fm.fileExists(atPath: $0.path) }
    }
    /// Select only a provable descendant, never the newest modification date.
    /// The caller can use this identity to request a lease before restoration.
    /// Conflicting archives remain intact and produce an explicit recovery error.
    func inspectIncoming(gameID: String) throws -> Incoming? {
        lock.lock(); defer { lock.unlock() }
        let existingManifest = try manifest(gameID: gameID)
        let endedRun = existingManifest?.ended == true ? existingManifest?.identity.run : nil
        var known = [UUID: BoundMultiplayerSavePackage]()
        var local = endedRun == nil ? try latestComplete(gameID: gameID) : nil
        while let package = local {
            guard known[package.payload.checkpoint] == nil else { throw Failure.corrupt }
            known[package.payload.checkpoint] = package
            local = try package.payload.predecessor.flatMap { try checkpoint(gameID: gameID, id: $0) }
        }
        var selected: (URL, CloudArchive)?
        for url in pendingImports(gameID: gameID).sorted(by: { $0.path < $1.path }) {
            let archive: CloudArchive = try read(url, maximum: Self.maximumPackageBytes)
            try validateArchive(archive)
            let package = archive.checkpoints[0]
            guard package.payload.manifest.identity.gameID == gameID else { throw Failure.incompatible }
            // A delayed download cannot resurrect a run explicitly ended here.
            if package.payload.manifest.identity.run == endedRun { continue }
            if let existing = known[package.payload.checkpoint] {
                guard existing == package else { throw Failure.conflict }
                continue
            }
            if let current = selected {
                let first = current.1.checkpoints[0]
                guard first.payload.manifest.identity == package.payload.manifest.identity else { throw Failure.conflict }
                if let same = archive.checkpoints.first(where: { $0.payload.checkpoint == first.payload.checkpoint }) {
                    guard same == first else { throw Failure.conflict }
                    selected = (url, archive)
                } else if let same = current.1.checkpoints.first(where: { $0.payload.checkpoint == package.payload.checkpoint }) {
                    guard same == package else { throw Failure.conflict }
                } else { throw Failure.conflict }
            } else { selected = (url, archive) }
        }
        guard let selected else { return nil }
        let package = selected.1.checkpoints[0]
        if endedRun == nil, let head = try latestComplete(gameID: gameID), !selected.1.checkpoints.contains(where: { $0 == head }) { throw Failure.conflict }
        return Incoming(archiveURL: selected.0, manifest: package.payload.manifest, receipt: package.receipt)
    }
    func hasInterruptedRestore(gameID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return fm.fileExists(atPath: directory(gameID: gameID).appendingPathComponent("Restore").path)
    }
    /// Reapply one fully validated restore transaction after a crash. Originals
    /// stay untouched in its backup directory. A half-written transaction without
    /// its complete package is preserved for explicit recovery instead.
    func finishInterruptedRestore(gameID: String, owner: UUID, romSHA256: String, gameSaveURL: URL,
                                  grant: BoundRunLeaseGrant? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard !activeGames.contains(gameID) else { throw Failure.activeGame }
        let transaction = directory(gameID: gameID).appendingPathComponent("Restore", isDirectory: true)
        let package: BoundMultiplayerSavePackage = try read(transaction.appendingPathComponent("pending.boundrun"), maximum: Self.maximumPackageBytes)
        try validate(package, complete: true)
        var manifest = package.payload.manifest
        guard manifest.identity.gameID == gameID, manifest.identity.romSHA256 == romSHA256 else { throw Failure.incompatible }
        guard manifest.identity.owner == owner else { throw Failure.ownerMismatch }
        if let grant {
            try validateGrant(grant, identity: manifest.identity)
            guard manifest.deviceOwner == deviceID || grant.allowsTransfer else { throw Failure.deviceOwned }
            if manifest.deviceOwner != deviceID {
                guard grant.checkpointID == package.payload.checkpoint,
                      grant.checkpointHistory == package.payload.sharedEventDigest,
                      grant.historyDigest == package.payload.sharedEventDigest else { throw Failure.conflict }
            }
            manifest.deviceOwner = deviceID; manifest.releasedForTransfer = false
        } else { try checkDevice(manifest) }
        for (name, url) in try restoreDestinations(package, gameSaveURL: gameSaveURL) {
            guard let blob = package.payload.files[name] else { continue }
            try create(url.deletingLastPathComponent())
            try writeData(blob.data, to: url)
        }
        try write(package, to: checkpointURL(gameID: gameID, id: package.payload.checkpoint, complete: true))
        try write(manifest, to: directory(gameID: gameID).appendingPathComponent("run.json"))
        try write(package.payload.checkpoint, to: directory(gameID: gameID).appendingPathComponent("head.json"))
        try exportCloud(gameID: gameID)
        let preserved = directory(gameID: gameID).appendingPathComponent("Restored Originals", isDirectory: true)
        try create(preserved)
        try fm.moveItem(at: transaction, to: preserved.appendingPathComponent(UUID().uuidString, isDirectory: true))
    }
    /// Import validates the whole archive before touching gameplay files. Active,
    /// divergent and differently owned versions stay in Incoming for ROM recovery.
    func restore(archiveURL: URL, gameID: String, owner: UUID, romSHA256: String, gameSaveURL: URL,
                 grant: BoundRunLeaseGrant? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard !activeGames.contains(gameID) else { throw Failure.activeGame }
        let archive: CloudArchive = try read(archiveURL, maximum: Self.maximumPackageBytes)
        try validateArchive(archive)
        guard let newest = archive.checkpoints.first else { throw Failure.corrupt }
        var manifest = newest.payload.manifest
        let identity = manifest.identity
        let existing = try self.manifest(gameID: gameID)
        let replacesEnded = existing?.ended == true && existing?.identity.run != identity.run
        guard identity.gameID == gameID, identity.romSHA256 == romSHA256 else { throw Failure.incompatible }
        guard identity.owner == owner else { throw Failure.ownerMismatch }
        if let grant {
            try validateGrant(grant, identity: identity)
            guard manifest.deviceOwner == deviceID || grant.allowsTransfer else { throw Failure.deviceOwned }
            if manifest.deviceOwner != deviceID || replacesEnded {
                guard grant.checkpointID == newest.payload.checkpoint,
                      grant.checkpointHistory == newest.payload.sharedEventDigest,
                      grant.historyDigest == newest.payload.sharedEventDigest else { throw Failure.conflict }
            }
            manifest.deviceOwner = deviceID; manifest.releasedForTransfer = false
        } else { try checkDevice(manifest) }
        if let existing {
            if replacesEnded {
                guard grant != nil, existing.identity.owner == owner,
                      existing.identity.romSHA256 == romSHA256 else { throw Failure.conflict }
            } else {
                guard existing.identity == identity, !existing.ended else { throw Failure.conflict }
            }
            if !replacesEnded, fm.fileExists(atPath: gameSaveURL.path) {
                let battery = try readData(gameSaveURL, maximum: 262_144)
                let headBattery = try latestComplete(gameID: gameID)?.payload.files["game.sav"]?.data
                guard battery == newest.payload.files["game.sav"]?.data || battery == headBattery else { throw Failure.conflict }
            }
        }
        if !replacesEnded, let head = try latestComplete(gameID: gameID), head.payload.checkpoint != newest.payload.checkpoint,
           !archive.checkpoints.contains(where: { $0.payload.checkpoint == head.payload.checkpoint }) { throw Failure.conflict }
        if replacesEnded, let existing {
            try checkNativeRecoveryRetained(newest)
            try archiveEndedRun(existing, gameSaveURL: gameSaveURL)
        } else { try checkHistoryDoesNotRegress(newest) }
        for package in archive.checkpoints {
            let url = checkpointURL(gameID: gameID, id: package.payload.checkpoint, complete: true)
            if fm.fileExists(atPath: url.path) {
                guard try read(url, maximum: Self.maximumPackageBytes) as BoundMultiplayerSavePackage == package else { throw Failure.conflict }
            } else { try write(package, to: url) }
        }
        // Keep a transaction with every original file before the first replacement.
        // An interrupted restore is replayed explicitly, never chosen by timestamp.
        let transaction = directory(gameID: gameID).appendingPathComponent("Restore", isDirectory: true)
        if fm.fileExists(atPath: transaction.path) { throw Failure.conflict }
        try create(transaction)
        let destinations = try restoreDestinations(newest, gameSaveURL: gameSaveURL)
        for (name, url) in destinations where fm.fileExists(atPath: url.path) {
            let backup = transaction.appendingPathComponent("originals", isDirectory: true).appendingPathComponent(name)
            try create(backup.deletingLastPathComponent())
            try fm.copyItem(at: url, to: backup)
        }
        try write(newest, to: transaction.appendingPathComponent("pending.boundrun"))
        for (name, url) in destinations {
            guard let blob = newest.payload.files[name] else { continue }
            try create(url.deletingLastPathComponent())
            try writeData(blob.data, to: url)
        }
        try write(manifest, to: directory(gameID: gameID).appendingPathComponent("run.json"))
        try write(newest.payload.checkpoint, to: directory(gameID: gameID).appendingPathComponent("head.json"))
        try exportCloud(gameID: gameID)
        let preserved = directory(gameID: gameID).appendingPathComponent("Restored Originals", isDirectory: true)
        try create(preserved)
        try fm.moveItem(at: transaction, to: preserved.appendingPathComponent(UUID().uuidString, isDirectory: true))
    }
    private func captureFiles(manifest: BoundMultiplayerRunManifest, gameSaveURL: URL,
                              additionalFiles: [String: Data]) throws -> [String: BoundMultiplayerSavePackage.Blob] {
        let gameID = manifest.identity.gameID
        let battery = try readData(gameSaveURL, maximum: 262_144)
        guard battery.count == 131_072 else { throw Failure.missingSave }
        var files = additionalFiles.mapValues(BoundMultiplayerSavePackage.Blob.init)
        files["game.sav"] = .init(battery)
        let stem = Self.hash(Data(gameID.utf8))
        for (name, url) in [
            ("soul.json", support.appendingPathComponent("Soul Link/" + stem + ".json")),
            ("timeline.json", support.appendingPathComponent("Soul Link/" + stem + ".timeline.json"))
        ] where fm.fileExists(atPath: url.path) {
            files[name] = .init(try readData(url, maximum: 4_194_304))
        }
        // Only this game's native journals and their verified referenced states.
        let recovery = support.appendingPathComponent("Friend Battles", isDirectory: true)
        for journal in (try? fm.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)) ?? [] where journal.pathExtension == "json" {
            let data = try readData(journal, maximum: 4096)
            guard let values = try JSONSerialization.jsonObject(with: data) as? [String: String], values["gameID"] == gameID else { continue }
            guard values["rom"] == manifest.identity.romSHA256, let name = values["state"],
                  validRecoveryName(name, extension: "state"), validRecoveryName(journal.lastPathComponent, extension: "json"),
                  let digest = values["sha256"] else { throw Failure.corrupt }
            let state = try readData(recovery.appendingPathComponent(name), maximum: 16_777_216)
            guard Self.hash(state) == digest else { throw Failure.corrupt }
            files["recovery/" + journal.lastPathComponent] = .init(data)
            files["recovery/" + name] = .init(state)
        }
        return files
    }
    private func validate(_ package: BoundMultiplayerSavePackage, complete: Bool) throws {
        let p = package.payload, identity = p.manifest.identity, receipt = package.receipt
        guard p.version == 1, identity.valid, p.predecessor != p.checkpoint, Self.isDigest(p.sharedEventDigest), p.files.count <= 40,
              p.files["game.sav"]?.data.count == 131_072,
              p.files.reduce(0, { $0 + $1.value.data.count }) <= 48 * 1024 * 1024,
              p.files.allSatisfy({ validFileName($0.key) && Self.hash($0.value.data) == $0.value.sha256 }),
              receipt.run == identity.run, receipt.checkpoint == p.checkpoint, receipt.owner == identity.owner,
              receipt.sharedEventDigest == p.sharedEventDigest, receipt.payloadSHA256 == Self.hash(try Self.encode(p)) else { throw Failure.corrupt }
        if let state = p.files["checkpoint.state"] {
            guard (1025...16_777_216).contains(state.data.count) else { throw Failure.corrupt }
        }
        if let setup = p.files["setup.json"] { guard setup.data.count <= 16_384 else { throw Failure.corrupt } }
        if let soul = p.files["soul.json"] {
            guard let value = try JSONSerialization.jsonObject(with: soul.data) as? [String: Any],
                  let run = value["run"] as? String, UUID(uuidString: run) == identity.run else { throw Failure.corrupt }
        }
        if complete || package.partnerReceipt != nil {
            guard let peer = package.partnerReceipt, peer.run == identity.run, peer.checkpoint == p.checkpoint,
                  peer.owner == identity.partner, peer.sharedEventDigest == p.sharedEventDigest,
                  Self.isDigest(peer.payloadSHA256) else { throw Failure.incomplete }
        }
        for (name, blob) in p.files where name.hasPrefix("recovery/") && name.hasSuffix(".json") {
            guard let values = try JSONSerialization.jsonObject(with: blob.data) as? [String: String],
                  values["gameID"] == identity.gameID, values["rom"] == identity.romSHA256,
                  let state = values["state"], validRecoveryName(state, extension: "state"),
                  let digest = values["sha256"], p.files["recovery/" + state]?.sha256 == digest else { throw Failure.corrupt }
        }
    }
    private func validateArchive(_ archive: CloudArchive) throws {
        guard archive.version == 1, !archive.checkpoints.isEmpty, archive.checkpoints.count <= 3 else { throw Failure.corrupt }
        guard Set(archive.checkpoints.map { $0.payload.checkpoint }).count == archive.checkpoints.count else { throw Failure.corrupt }
        var expected: UUID?
        let identity = archive.checkpoints[0].payload.manifest.identity
        for (index, package) in archive.checkpoints.enumerated() {
            try validate(package, complete: true)
            guard package.payload.manifest.identity == identity,
                  index == 0 || package.payload.checkpoint == expected else { throw Failure.conflict }
            expected = package.payload.predecessor
        }
    }
    private func exportCloud(gameID: String) throws {
        guard var package = try latestComplete(gameID: gameID) else { throw Failure.incomplete }
        var packages = [package]
        while packages.count < 3, let previous = package.payload.predecessor,
              let parent = try checkpoint(gameID: gameID, id: previous), parent.complete {
            packages.append(parent); package = parent
        }
        let archive = CloudArchive(checkpoints: packages)
        try validateArchive(archive)
        guard let battery = packages[0].payload.files["game.sav"]?.data else { throw Failure.corrupt }
        try writeData(battery, to: cloudBatteryURL(gameID: gameID))
        try write(archive, to: cloudURL(gameID: gameID))
    }
    private func restoreDestinations(_ package: BoundMultiplayerSavePackage, gameSaveURL: URL) throws -> [String: URL] {
        let stem = Self.hash(Data(package.payload.manifest.identity.gameID.utf8))
        var result = ["game.sav": gameSaveURL]
        for name in package.payload.files.keys {
            switch name {
            case "game.sav": break
            case "soul.json": result[name] = support.appendingPathComponent("Soul Link/" + stem + ".json")
            case "timeline.json": result[name] = support.appendingPathComponent("Soul Link/" + stem + ".timeline.json")
            case "setup.json": result[name] = directory(gameID: package.payload.manifest.identity.gameID).appendingPathComponent("setup.json")
            case "checkpoint.state": break // Read via package; never auto-load a snapshot.
            default:
                guard name.hasPrefix("recovery/"), validFileName(name) else { throw Failure.corrupt }
                result[name] = support.appendingPathComponent("Friend Battles/" + String(name.dropFirst(9)))
            }
        }
        return result
    }
    private func checkHistoryDoesNotRegress(_ package: BoundMultiplayerSavePackage) throws {
        let stem = Self.hash(Data(package.payload.manifest.identity.gameID.utf8))
        for (name, filename, field) in [("soul.json", stem + ".json", "dead"),
                                      ("timeline.json", stem + ".timeline.json", "events")] {
            let url = support.appendingPathComponent("Soul Link/" + filename)
            guard fm.fileExists(atPath: url.path) else { continue }
            guard let incoming = package.payload.files[name],
                  let old = try JSONSerialization.jsonObject(with: readData(url, maximum: 4_194_304)) as? [String: Any],
                  let new = try JSONSerialization.jsonObject(with: incoming.data) as? [String: Any] else { throw Failure.conflict }
            if field == "dead" {
                guard old["run"] as? String == new["run"] as? String,
                      let previous = old[field] as? [String], let current = new[field] as? [String],
                      Set(previous).isSubset(of: Set(current)) else { throw Failure.conflict }
            } else {
                guard let previous = old[field] as? [[String: Any]], let current = new[field] as? [[String: Any]] else { throw Failure.conflict }
                let ids = Set(current.compactMap { $0["id"] as? String })
                guard previous.allSatisfy({ ($0["id"] as? String).map(ids.contains) == true }) else { throw Failure.conflict }
            }
        }
        try checkNativeRecoveryRetained(package)
    }
    private func checkNativeRecoveryRetained(_ package: BoundMultiplayerSavePackage) throws {
        let recovery = support.appendingPathComponent("Friend Battles", isDirectory: true)
        for url in (try? fm.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            let data = try readData(url, maximum: 4096)
            guard let values = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  values["gameID"] == package.payload.manifest.identity.gameID else { continue }
            guard package.payload.files["recovery/" + url.lastPathComponent]?.data == data else { throw Failure.conflict }
        }
    }
    private func archiveEndedRun(_ manifest: BoundMultiplayerRunManifest, gameSaveURL: URL) throws {
        let finished = root.appendingPathComponent("Finished Runs", isDirectory: true)
        try create(finished)
        let destination = finished.appendingPathComponent(manifest.identity.run.uuidString, isDirectory: true)
        guard manifest.ended, !fm.fileExists(atPath: destination.path) else { throw Failure.conflict }
        let folder = directory(gameID: manifest.identity.gameID)
        let personal = folder.appendingPathComponent("Ended Personal Files", isDirectory: true)
        try create(personal)
        if fm.fileExists(atPath: gameSaveURL.path) {
            try writeData(try readData(gameSaveURL, maximum: 262_144), to: personal.appendingPathComponent("game.sav"))
        }
        // The ended run and its originals move atomically. Current journal files
        // follow into that archive before the new run replaces personal history.
        try fm.moveItem(at: folder, to: destination)
        let stem = Self.hash(Data(manifest.identity.gameID.utf8))
        for (name, suffix) in [("soul.json", ".json"), ("timeline.json", ".timeline.json")] {
            let source = support.appendingPathComponent("Soul Link/" + stem + suffix)
            if fm.fileExists(atPath: source.path) {
                try fm.moveItem(at: source, to: destination.appendingPathComponent("Ended Personal Files/" + name))
            }
        }
    }
    private func validFileName(_ name: String) -> Bool {
        if ["game.sav", "soul.json", "timeline.json", "checkpoint.state", "setup.json"].contains(name) { return true }
        guard name.hasPrefix("recovery/") else { return false }
        let base = String(name.dropFirst(9))
        return validRecoveryName(base, extension: "json") || validRecoveryName(base, extension: "state")
    }
    private func validRecoveryName(_ name: String, extension ext: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        return url.lastPathComponent == name && url.pathExtension == ext && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }
    private func checkpointURL(gameID: String, id: UUID, complete: Bool) -> URL {
        directory(gameID: gameID).appendingPathComponent("Checkpoints", isDirectory: true)
            .appendingPathComponent(id.uuidString + (complete ? ".complete.json" : ".prepared.json"))
    }
    private func create(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func readData(_ url: URL, maximum: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard size.isRegularFile == true, size.isSymbolicLink != true, let count = size.fileSize, count <= maximum else { throw Failure.corrupt }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw Failure.corrupt }
        return data
    }
    private func read<T: Decodable>(_ url: URL, maximum: Int) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: readData(url, maximum: maximum)) }
        catch { throw Failure.corrupt }
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try Self.encode(value)
        guard data.count <= Self.maximumPackageBytes else { throw Failure.corrupt }
        try create(url.deletingLastPathComponent())
        try writeData(data, to: url)
    }
    private func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
