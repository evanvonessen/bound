import Foundation
import Security

enum BoundMultiplayerDeviceIdentity {
    private static let lock = NSLock()
    static func current() throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.evanvonessen.bound.multiplayer-device.v1",
            kSecAttrAccount as String: "installation", kSecAttrSynchronizable as String: false]
        var item: CFTypeRef?
        var read = query; read[kSecReturnData as String] = true
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let value = String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:)) { return value }
        guard status == errSecItemNotFound else { throw BoundRunLeaseError.deviceUnavailable }
        let value = UUID()
        var add = query
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = Data(value.uuidString.utf8)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw BoundRunLeaseError.deviceUnavailable }
        return value
    }
}

enum BoundRunLeaseError: Error, Equatable {
    case deviceUnavailable, unavailable, leaseHeld, leaseExpired, transferRequired, unauthorized, anchorConflict, runEnded
}

/// Only a validated server reply can create this grant. Neither its token nor
/// its deadline is included in save packages, cloud backups or diagnostics.
struct BoundRunLeaseGrant: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let ownerID: UUID
    let runID: UUID
    let deviceID: UUID
    let fence: UInt64
    let expiresAt: Date
    let allowsTransfer: Bool
    let checkpointID: UUID?
    let checkpointHistory: String?
    let historyDigest: String?
    let anchorVersion: UInt64
    fileprivate final class Authority: @unchecked Sendable {
        private let lock = NSLock()
        private var valid = true
        var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
        func invalidate() { lock.lock(); valid = false; lock.unlock() }
    }
    fileprivate let authority = Authority()
    fileprivate let token: UUID
    // ContinuousClock advances while the device sleeps. An uptime clock that
    // stops in sleep could let this device resume after the server transferred.
    fileprivate let deadline: ContinuousClock.Instant
    fileprivate let identity: AppCloudSession
    var remaining: TimeInterval {
        let duration = ContinuousClock.now.duration(to: deadline).components
        return max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }
    var isCurrent: Bool { authority.isValid && remaining > 0 && (try? identity.credentials()) != nil }
    var description: String { "BoundRunLeaseGrant(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": "redacted"]) }
    fileprivate init(ownerID: UUID, runID: UUID, deviceID: UUID, fence: UInt64, expiresAt: Date,
                     token: UUID, deadline: ContinuousClock.Instant, identity: AppCloudSession, allowsTransfer: Bool,
                     checkpointID: UUID?, checkpointHistory: String?, historyDigest: String?, anchorVersion: UInt64) {
        self.ownerID = ownerID; self.runID = runID; self.deviceID = deviceID; self.fence = fence
        self.expiresAt = expiresAt; self.token = token; self.deadline = deadline; self.identity = identity
        self.allowsTransfer = allowsTransfer
        self.checkpointID = checkpointID; self.checkpointHistory = checkpointHistory
        self.historyDigest = historyDigest; self.anchorVersion = anchorVersion
    }
}

actor BoundRunLeaseClient {
    private struct Key: Hashable { let owner: UUID; let run: UUID; let device: UUID }
    private struct Reply: Decodable {
        let ok: Bool
        let error: String?
        let ownerID: UUID?
        let runID: UUID?
        let deviceID: UUID?
        let fence: String?
        let token: UUID?
        let serverTime: TimeInterval?
        let expiresAt: TimeInterval?
        let checkpointID: UUID?
        let checkpointHistory: String?
        let historyDigest: String?
        let anchorVersion: String?
    }
    private var acquisitions: [Key: UUID] = [:]
    private var generations: [Key: UInt64] = [:]
    private var authorities: [Key: BoundRunLeaseGrant.Authority] = [:]
    private var lastGrants: [Key: BoundRunLeaseGrant] = [:]
    private var performingOperation = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private let perform: @Sendable (URLRequest) async throws -> Data
    private let device: @Sendable () throws -> UUID
    init(perform: @escaping @Sendable (URLRequest) async throws -> Data = { try await FriendSharingTokens.perform($0) },
         device: @escaping @Sendable () throws -> UUID = { try BoundMultiplayerDeviceIdentity.current() }) {
        self.perform = perform; self.device = device
    }
    func acquire(runID: UUID, session: AppCloudSession, allowTransfer: Bool = false) async throws -> BoundRunLeaseGrant {
        let deviceID = try device(), key = Key(owner: session.owner, run: runID, device: deviceID)
        let generation = generations[key, default: 0]
        await enterOperation(); defer { leaveOperation() }; try Task.checkCancellation()
        let request = acquisitions[key] ?? UUID(); acquisitions[key] = request
        let grant = try await obtain(action: "acquire", runID: runID, deviceID: deviceID, session: session,
            extra: ["requestID": request.uuidString.lowercased(), "transfer": allowTransfer], allowsTransfer: allowTransfer)
        try Task.checkCancellation()
        try install(grant, key: key, generation: generation)
        return grant
    }
    func renew(grant: BoundRunLeaseGrant, session: AppCloudSession) async throws -> BoundRunLeaseGrant {
        guard grant.ownerID == session.owner, grant.identity.isSameSession(as: session),
              grant.deviceID == (try device()) else { throw BoundRunLeaseError.unauthorized }
        let key = Key(owner: grant.ownerID, run: grant.runID, device: grant.deviceID)
        let generation = generations[key, default: 0]
        await enterOperation(); defer { leaveOperation() }; try Task.checkCancellation()
        guard grant.isCurrent else { throw BoundRunLeaseError.leaseExpired }
        do {
            let renewed = try await obtain(action: "renew", runID: grant.runID, deviceID: grant.deviceID, session: session,
                extra: ["token": grant.token.uuidString.lowercased(), "fence": String(grant.fence)], allowsTransfer: grant.allowsTransfer)
            try Task.checkCancellation()
            guard generation == generations[key, default: 0], renewed.fence == grant.fence,
                  renewed.token == grant.token else { throw BoundRunLeaseError.leaseExpired }
            try install(renewed, key: key, generation: generation)
            return renewed
        } catch let error as BoundRunLeaseError {
            if error == .leaseExpired || error == .unauthorized || error == .anchorConflict || error == .runEnded { grant.authority.invalidate() }
            throw error
        }
    }
    func recordHistory(grant: BoundRunLeaseGrant, digest: String, session: AppCloudSession) async throws -> BoundRunLeaseGrant {
        try await mutate(grant: grant, action: "history", history: digest, extra: [:], session: session)
    }
    func checkpoint(grant: BoundRunLeaseGrant, checkpointID: UUID, predecessor: UUID?, history: String,
                    session: AppCloudSession) async throws -> BoundRunLeaseGrant {
        try await mutate(grant: grant, action: "checkpoint", history: history,
            extra: ["checkpointID": checkpointID.uuidString.lowercased(),
                    "predecessor": predecessor.map { $0.uuidString.lowercased() as Any } ?? NSNull()], session: session)
    }
    private func mutate(grant: BoundRunLeaseGrant, action: String, history: String, extra: [String: Any],
                        session: AppCloudSession) async throws -> BoundRunLeaseGrant {
        guard Self.validDigest(history), grant.ownerID == session.owner, grant.identity.isSameSession(as: session),
              grant.deviceID == (try device()) else { throw BoundRunLeaseError.unauthorized }
        let key = Key(owner: grant.ownerID, run: grant.runID, device: grant.deviceID)
        let generation = generations[key, default: 0]
        await enterOperation(); defer { leaveOperation() }; try Task.checkCancellation()
        guard grant.isCurrent else { throw BoundRunLeaseError.leaseExpired }
        var payload = extra
        payload["history"] = history; payload["expectedVersion"] = String(grant.anchorVersion)
        payload["token"] = grant.token.uuidString.lowercased(); payload["fence"] = String(grant.fence)
        do {
            let value = try await obtain(action: action, runID: grant.runID, deviceID: grant.deviceID, session: session,
                extra: payload, allowsTransfer: grant.allowsTransfer)
            try Task.checkCancellation()
            guard value.fence == grant.fence, value.token == grant.token,
                  value.historyDigest == history,
                  action != "checkpoint" || value.checkpointID?.uuidString.lowercased() == extra["checkpointID"] as? String && value.checkpointHistory == history else {
                throw BoundRunLeaseError.anchorConflict
            }
            try install(value, key: key, generation: generation)
            return value
        } catch let error as BoundRunLeaseError {
            if error == .leaseExpired || error == .unauthorized || error == .anchorConflict || error == .runEnded { grant.authority.invalidate() }
            throw error
        }
    }
    func release(grant: BoundRunLeaseGrant, session: AppCloudSession) async throws {
        try await finish(grant: grant, action: "release", session: session)
    }
    /// The server permanently tombstones this run UUID. A lost reply can be
    /// retried with the same proof even after local authority was invalidated.
    func end(grant: BoundRunLeaseGrant, session: AppCloudSession) async throws {
        try await finish(grant: grant, action: "end", session: session)
    }
    private func finish(grant: BoundRunLeaseGrant, action: String, session: AppCloudSession) async throws {
        guard grant.ownerID == session.owner, grant.identity.isSameSession(as: session),
              grant.deviceID == (try device()) else { throw BoundRunLeaseError.unauthorized }
        let key = Key(owner: grant.ownerID, run: grant.runID, device: grant.deviceID)
        generations[key, default: 0] &+= 1
        authorities.removeValue(forKey: key)?.invalidate()
        grant.authority.invalidate()
        await enterOperation(); defer { leaveOperation() }; try Task.checkCancellation()
        let request = try session.runLeaseRequest(action: action, payload: [
            "runID": grant.runID.uuidString.lowercased(), "deviceID": grant.deviceID.uuidString.lowercased(),
            "token": grant.token.uuidString.lowercased(), "fence": String(grant.fence)])
        let reply = try JSONDecoder().decode(Reply.self, from: await perform(request))
        try Self.check(reply)
        acquisitions.removeValue(forKey: Key(owner: grant.ownerID, run: grant.runID, device: grant.deviceID))
    }
    private func enterOperation() async {
        if performingOperation { await withCheckedContinuation { operationWaiters.append($0) } }
        else { performingOperation = true }
    }
    private func leaveOperation() {
        if operationWaiters.isEmpty { performingOperation = false }
        else { operationWaiters.removeFirst().resume() }
    }
    private func install(_ grant: BoundRunLeaseGrant, key: Key, generation: UInt64) throws {
        guard generation == generations[key, default: 0] else { throw BoundRunLeaseError.leaseExpired }
        if let previous = lastGrants[key] {
            guard grant.fence >= previous.fence, grant.anchorVersion >= previous.anchorVersion,
                  previous.checkpointID == nil || grant.checkpointID != nil,
                  previous.historyDigest == nil || grant.historyDigest != nil else { throw BoundRunLeaseError.anchorConflict }
            if grant.anchorVersion == previous.anchorVersion {
                guard grant.checkpointID == previous.checkpointID, grant.checkpointHistory == previous.checkpointHistory,
                      grant.historyDigest == previous.historyDigest else { throw BoundRunLeaseError.anchorConflict }
            }
        }
        authorities[key]?.invalidate(); authorities[key] = grant.authority; lastGrants[key] = grant
    }
    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func obtain(action: String, runID: UUID, deviceID: UUID, session: AppCloudSession,
                        extra: [String: Any], allowsTransfer: Bool) async throws -> BoundRunLeaseGrant {
        var payload = extra
        payload["runID"] = runID.uuidString.lowercased(); payload["deviceID"] = deviceID.uuidString.lowercased()
        let request = try session.runLeaseRequest(action: action, payload: payload)
        let started = ContinuousClock.now
        let reply = try JSONDecoder().decode(Reply.self, from: await perform(request))
        try Self.check(reply)
        guard reply.ownerID == session.owner, reply.runID == runID, reply.deviceID == deviceID,
              let fenceText = reply.fence, let fence = UInt64(fenceText), fence > 0, fence <= UInt64(Int64.max),
              let token = reply.token, let serverTime = reply.serverTime, let expiry = reply.expiresAt,
              let anchorText = reply.anchorVersion, let anchor = UInt64(anchorText), anchor <= UInt64(Int64.max),
              (reply.checkpointID == nil) == (reply.checkpointHistory == nil),
              reply.checkpointHistory.map(Self.validDigest) ?? true,
              reply.historyDigest.map(Self.validDigest) ?? true,
              anchor != 0 || reply.checkpointID == nil && reply.historyDigest == nil,
              anchor == 0 || reply.historyDigest != nil,
              serverTime.isFinite, expiry.isFinite, expiry > serverTime, expiry - serverTime <= 60.01,
              (try? session.credentials()) != nil else { throw BoundRunLeaseError.unavailable }
        let deadline = started.advanced(by: .seconds(min(60, expiry - serverTime) - 5))
        guard deadline > ContinuousClock.now else { throw BoundRunLeaseError.leaseExpired }
        return BoundRunLeaseGrant(ownerID: session.owner, runID: runID, deviceID: deviceID, fence: fence,
            expiresAt: Date(timeIntervalSince1970: expiry), token: token, deadline: deadline, identity: session, allowsTransfer: allowsTransfer,
            checkpointID: reply.checkpointID, checkpointHistory: reply.checkpointHistory, historyDigest: reply.historyDigest, anchorVersion: anchor)
    }
    private static func check(_ reply: Reply) throws {
        guard !reply.ok else { return }
        switch reply.error {
        case "lease_held": throw BoundRunLeaseError.leaseHeld
        case "lease_expired", "fenced": throw BoundRunLeaseError.leaseExpired
        case "transfer_required": throw BoundRunLeaseError.transferRequired
        case "unauthorized": throw BoundRunLeaseError.unauthorized
        case "anchor_conflict": throw BoundRunLeaseError.anchorConflict
        case "run_ended": throw BoundRunLeaseError.runEnded
        default: throw BoundRunLeaseError.unavailable
        }
    }
}
