import Foundation

/// Lobby membership is deliberately independent of cartridge saves and Soul Link runs.
struct BoundLobbySnapshot: Codable, Equatable, Sendable {
    struct Member: Codable, Equatable, Sendable {
        var ownerID: UUID
        var displayName: String
        var uid: UInt
        var state: String
        var ready: Bool
        var mode: String?
        var runID: UUID?
        var partnerOwnerID: UUID?
        var online: Bool
        var sessionID: UUID?
        var generation: String?
        var joined: Bool { state == "joined" }
        var valid: Bool {
            (1...4).contains(uid) && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName.count <= 40 && displayName.utf8.count <= 160
            && !displayName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && ["invited", "joined", "left", "declined"].contains(state)
            && (mode == "solo" || mode == "soulLink")
            && partnerOwnerID != ownerID
            && (mode != "solo" || partnerOwnerID == nil)
            && (mode != "soulLink" || partnerOwnerID != nil)
            && sessionID != nil && generation.flatMap(BoundLobbySnapshot.positiveDecimal) != nil
        }
    }
    var lobbyID: UUID
    var creatorID: UUID?
    var state: String
    var revision: String
    var members: [Member]
    var started: Bool { state == "started" }
    func member(_ owner: UUID?) -> Member? { members.first { $0.ownerID == owner } }
    static func positiveDecimal(_ value: String) -> UInt64? {
        guard value.utf8.count <= 19, let first = value.utf8.first, (49...57).contains(first),
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let result = UInt64(value), result <= UInt64(Int64.max) else { return nil }
        return result
    }
    var valid: Bool {
        ["waiting", "started"].contains(state) && Self.positiveDecimal(revision) != nil
        && (1...4).contains(members.count) && members.allSatisfy(\.valid)
        && Set(members.map(\.ownerID)).count == members.count
        && Set(members.map(\.uid)).count == members.count
        && Set(members.compactMap(\.sessionID)).count == members.count
        && (creatorID == nil ? !members.contains(where: \.joined) : member(creatorID) != nil)
    }
    /// The launch coordinator is a lobby role only; it never owns another save.
    func canStart(owner: UUID) -> Bool {
        owner == creatorID && !started && members.filter(\.joined).count >= 2
        && members.filter(\.joined).allSatisfy { $0.ready && $0.online }
    }
}

struct BoundLobbyResponse: Decodable, Sendable {
    var ok: Bool
    var lobby: BoundLobbySnapshot?
    var lobbies: [BoundLobbySnapshot]?
    var memberToken: UUID?
    var error: String?
    var serverTime: Double?
    var expiresAt: Double?
}

@MainActor
final class BoundLobbySession {
    typealias Call = @MainActor (AppCloudSession, String, [String: Any]) async throws -> BoundLobbyResponse
    private let call: Call
    private var session: AppCloudSession?
    private var gameID = ""
    private var operation = UUID()
    private var task: Task<Void, Never>?
    private var nextPoll: TimeInterval = 0
    private var nextHeartbeat: TimeInterval = 0
    private(set) var snapshot: BoundLobbySnapshot?
    private(set) var invitations: [BoundLobbySnapshot] = []
    private(set) var memberToken: UUID?
    private(set) var message: String?
    private(set) var busy = false
    private var createRequest: UUID?
    var changed: (() -> Void)?
    var joined: Bool { session.flatMap { snapshot?.member($0.owner)?.joined } == true && memberToken != nil }
    var invitation: BoundLobbySnapshot? {
        guard let owner = session?.owner else { return nil }
        return invitations.first { $0.member(owner)?.state == "invited" } ?? invitations.first
    }
    var owner: UUID? { session?.owner }

    init(call: @escaping Call = { session, action, payload in
        let data = try await FriendSharingTokens.perform(try session.lobbyRequest(action: action, payload: payload))
        return try JSONDecoder().decode(BoundLobbyResponse.self, from: data)
    }) { self.call = call }
    deinit { task?.cancel() }

    func bind(session: AppCloudSession?, gameID: String) {
        guard self.gameID != gameID || !(session?.isSameSession(as: self.session) ?? (self.session == nil)) else { return }
        task?.cancel(); task = nil; operation = UUID(); busy = false
        self.session = session; self.gameID = gameID
        snapshot = nil; invitations = []; memberToken = nil; message = nil
        nextPoll = 0; nextHeartbeat = 0; createRequest = nil; changed?()
    }
    func tick(active: Bool, now: TimeInterval) {
        guard active, !busy, session != nil, !gameID.isEmpty, now >= nextPoll else { return }
        nextPoll = now + 2
        if joined, now >= nextHeartbeat {
            nextHeartbeat = now + 15
            perform("heartbeat", payload: authenticatedPayload())
        } else if joined, let id = snapshot?.lobbyID {
            perform("get", payload: ["lobbyID": id.uuidString.lowercased()])
        } else {
            perform("list", payload: [:])
        }
    }
    private func authenticatedPayload() -> [String: Any] {
        guard let snapshot, let memberToken else { return [:] }
        return ["lobbyID": snapshot.lobbyID.uuidString.lowercased(), "memberToken": memberToken.uuidString.lowercased()]
    }
    private func runPayload(run: UUID?, solo: Bool, partnerRoom: String?) -> [String: Any] {
        ["runID": run.map { $0.uuidString.lowercased() } as Any? ?? NSNull(),
         "mode": solo ? "solo" : "soulLink", "partnerRoomID": partnerRoom as Any? ?? NSNull()]
    }
    func create(run: UUID?, solo: Bool, partnerRoom: String?, extraRooms: [UUID]) {
        guard !busy, snapshot == nil || !joined else { return }
        let rooms = Array(Set(extraRooms.map { $0.uuidString.lowercased() }).union(partnerRoom.map { [$0.lowercased()] } ?? [])).sorted()
        guard rooms.count <= 3, !rooms.isEmpty else { message = "Choose up to three friends."; return }
        if createRequest == nil { createRequest = UUID() }
        var payload = runPayload(run: run, solo: solo, partnerRoom: partnerRoom)
        payload["requestID"] = createRequest!.uuidString.lowercased(); payload["roomIDs"] = rooms
        perform("create", payload: payload)
    }
    func accept(run: UUID?, solo: Bool, partnerRoom: String?) {
        guard !busy, let invitation else { return }
        var payload = runPayload(run: run, solo: solo, partnerRoom: partnerRoom)
        payload["lobbyID"] = invitation.lobbyID.uuidString.lowercased()
        perform(invitation.member(session!.owner)?.state == "invited" ? "accept" : "rejoin", payload: payload)
    }
    func configureRun(run: UUID, solo: Bool, partnerRoom: String?) {
        guard joined, !busy, snapshot?.member(session!.owner)?.runID == nil else { return }
        var payload = authenticatedPayload()
        payload.merge(runPayload(run: run, solo: solo, partnerRoom: partnerRoom)) { _, new in new }
        perform("configure", payload: payload)
    }
    func invite(_ rooms: [UUID]) {
        guard joined, !busy, let room = rooms.first else { return }
        var payload = authenticatedPayload(); payload["roomID"] = room.uuidString.lowercased()
        // Serialize invitations so each admission observes the server's four-slot limit.
        perform("invite", payload: payload) { [weak self] in if rooms.count > 1 { self?.invite(Array(rooms.dropFirst())) } }
    }
    func setReady(_ value: Bool) {
        guard joined else { return }; var payload = authenticatedPayload(); payload["ready"] = value
        perform("ready", payload: payload)
    }
    func start() { guard joined else { return }; perform("start", payload: authenticatedPayload()) }
    func leave() { guard joined else { return }; perform("leave", payload: authenticatedPayload()) }
    func decline() {
        guard let invitation else { return }
        perform("decline", payload: ["lobbyID": invitation.lobbyID.uuidString.lowercased()])
    }
    func clearMessage() { message = nil }
    private func perform(_ action: String, payload: [String: Any], completion: (() -> Void)? = nil) {
        guard !busy, let session else { return }
        busy = true; message = nil
        let operation = self.operation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await call(session, action, payload)
                guard !Task.isCancelled, operation == self.operation, session.isSameSession(as: self.session) else { return }
                guard response.ok else { throw Failure.server(response.error ?? "unavailable") }
                if action == "list" {
                    guard response.lobbies != nil, response.lobby == nil, response.memberToken == nil else { throw Failure.invalid }
                } else {
                    guard let lobby = response.lobby, response.lobbies == nil,
                          action == "create" || lobby.lobbyID.uuidString.lowercased() == payload["lobbyID"] as? String else { throw Failure.invalid }
                }
                if let lobby = response.lobby {
                    guard lobby.valid, lobby.member(session.owner) != nil else { throw Failure.invalid }
                    if let current = snapshot, current.lobbyID == lobby.lobbyID,
                       UInt64(lobby.revision)! < UInt64(current.revision)! { throw Failure.invalid }
                    let local = lobby.member(session.owner)!
                    if ["create", "accept", "rejoin", "configure", "ready", "start", "invite", "heartbeat"].contains(action) {
                        guard local.joined, local.online, response.memberToken != nil,
                              let server = response.serverTime, let expiry = response.expiresAt,
                              server.isFinite, expiry.isFinite, expiry > server, expiry - server <= 91 else { throw Failure.invalid }
                    } else if response.memberToken != nil { throw Failure.invalid }
                    if action == "leave", local.state != "left" { throw Failure.invalid }
                    if action == "decline", local.state != "declined" { throw Failure.invalid }
                    if ["create", "accept", "rejoin", "configure"].contains(action) {
                        guard local.mode == payload["mode"] as? String,
                              local.runID == (payload["runID"] as? String).flatMap(UUID.init(uuidString:)) else { throw Failure.invalid }
                    }
                    snapshot = lobby
                    if let token = response.memberToken { memberToken = token }
                    if lobby.member(session.owner)?.joined != true { memberToken = nil }
                    invitations.removeAll { $0.lobbyID == lobby.lobbyID }
                    if action == "create" { createRequest = nil }
                }
                if let lobbies = response.lobbies {
                    guard lobbies.count <= 32, Set(lobbies.map(\.lobbyID)).count == lobbies.count,
                          lobbies.allSatisfy({ $0.valid && $0.member(session.owner) != nil }) else { throw Failure.invalid }
                    for lobby in lobbies {
                        if let previous = ([snapshot].compactMap { $0 } + invitations).first(where: { $0.lobbyID == lobby.lobbyID }),
                           UInt64(lobby.revision)! < UInt64(previous.revision)! { throw Failure.invalid }
                    }
                    invitations = lobbies.filter { ["invited", "left", "joined"].contains($0.member(session.owner)!.state) }
                }
                if action == "leave" { memberToken = nil }
                if action == "decline" { invitations.removeAll { $0.lobbyID.uuidString.lowercased() == payload["lobbyID"] as? String } }
                busy = false; task = nil; changed?(); completion?()
            } catch {
                guard !Task.isCancelled, operation == self.operation else { return }
                busy = false; task = nil
                message = (error as? Failure)?.message ?? "Lobby connection unavailable."
                if case Failure.server(let reason) = error,
                   ["membership_expired", "fenced", "forbidden", "unauthorized"].contains(reason) {
                    memberToken = nil; nextPoll = 0; nextHeartbeat = 0
                }
                // A transient lobby outage never ends or replaces a cartridge run.
                changed?()
            }
        }
    }
    enum Failure: Error {
        case invalid, server(String)
        var message: String {
            switch self {
            case .invalid: return "Lobby response is incompatible."
            case .server(let value):
                switch value {
                case "lobby_full": return "This lobby has four players."
                case "not_ready": return "Waiting for players to ready up."
                case "run_mismatch": return "Continue with this lobby's original run."
                default: return "Lobby unavailable. Try again."
                }
            }
        }
    }
}
