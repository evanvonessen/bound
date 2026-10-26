import Foundation
import CoreFoundation

/// Issued by the authenticated Bound broker. No Nakama server key or custom
/// authentication secret is shipped to the app.
struct BoundNakamaConfiguration: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let endpoint: URL
    let accessToken: String
    let expiresAt: TimeInterval
    let matchID: String
    let roomID: UUID
    let ownerID: UUID
    let nakamaUserID: UUID
    let joinTicket: String
    let members: [UUID]
    let peerOwnerID: UUID

    var description: String { "BoundNakamaConfiguration(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": "redacted"]) }

    func isValid(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme == "wss", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.path == "/ws",
              (parts.queryItems ?? []).allSatisfy({ ["lang", "status", "format"].contains($0.name) }),
              Set((parts.queryItems ?? []).map(\.name)).count == (parts.queryItems ?? []).count,
              parts.queryItems?.first(where: { $0.name == "format" })?.value == "json",
              (parts.port == nil || (1...65535).contains(parts.port!)),
              !accessToken.isEmpty, accessToken.utf8.count <= 8192,
              !joinTicket.isEmpty, joinTicket.utf8.count <= 8192,
              !matchID.isEmpty, matchID.utf8.count <= 256,
              !matchID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              expiresAt.isFinite, expiresAt > now, expiresAt <= now + 120,
              (2...8).contains(members.count), Set(members).count == members.count,
              members.contains(ownerID), members.contains(peerOwnerID), ownerID != peerOwnerID else { return false }
        return true
    }

    func isValid(room: UUID, owner: UUID, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        roomID == room && ownerID == owner && isValid(now: now)
    }

    var socketURL: URL? {
        guard isValid(), var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "token", value: accessToken)]
        return parts.url
    }
}

/// A small seam for deterministic queue, socket-failure and protocol tests.
protocol BoundNakamaSocket: AnyObject, Sendable {
    func resume()
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void)
    func receive(_ completion: @escaping @Sendable (Result<Data, Error>) -> Void)
    func cancel()
}

private final class BoundNakamaURLSocket: BoundNakamaSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    init(session: URLSession, request: URLRequest) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 65_536
    }
    func resume() { task.resume() }
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        task.send(.string(text), completionHandler: completion)
    }
    func receive(_ completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        task.receive { result in
            completion(result.map { message in
                switch message { case .data(let value): return value; case .string(let value): return Data(value.utf8)
                @unknown default: return Data() }
            })
        }
    }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

/// One room socket. The emulator only copies packets into bounded mailboxes;
/// JSON encoding and all network I/O run on the dedicated worker.
final class BoundNakamaClient: BoundSDKRoomTransport, @unchecked Sendable {
    typealias Configuration = BoundNakamaConfiguration
    typealias Failure = BoundSDKRoomFailure
    typealias Member = BoundSDKRoomMember
    typealias Event = BoundSDKRoomEvent
    typealias SocketFactory = @Sendable (URLRequest) -> any BoundNakamaSocket
    static let maximumPayloadBytes = 8192
    static let maximumReliablePackets = 128
    static let maximumReliableBytes = 262_144

    private struct Packet {
        let opcode: Int
        let data: Data
        let target: UUID?
        let ticket: String?
    }
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "dev.bound.nakama.gameplay", qos: .userInitiated)
    private let makeSocket: SocketFactory
    private var socket: (any BoundNakamaSocket)?
    private var configuration: BoundNakamaConfiguration?
    private var callback: (@Sendable (Event) -> Void)?
    private var generation = BoundSDKGeneration()
    private var active = false
    private var queueFault = false
    private var joined = false
    private var sending = false
    private var drainScheduled = false
    private var reliable: [Packet] = []
    private var reliableBytes = 0
    private var latestPresence: Packet?
    private var reliableBurst = 0
    private var joinCID = ""
    private var deadline: TimeInterval = 0
    private var lastReceived: TimeInterval = 0
    private var lastPing: TimeInterval = 0
    private var joinDeadline: TimeInterval = 0
    private var timer: DispatchSourceTimer?

    init(session: URLSession = .shared, socketFactory: SocketFactory? = nil) {
        makeSocket = socketFactory ?? { BoundNakamaURLSocket(session: session, request: $0) }
    }
    deinit { stop() }

    func start(configuration: BoundNakamaConfiguration, event: @escaping @Sendable (Event) -> Void) throws {
        stop()
        guard configuration.isValid(), let url = configuration.socketURL else { throw Failure.invalidConfiguration }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        let socket = makeSocket(request), run = BoundSDKGeneration.Token(), cid = UUID().uuidString
        lock.lock()
        self.socket = socket; self.configuration = configuration; callback = event
        generation.replace(with: run); active = true; queueFault = false; joined = false; sending = true; joinCID = cid
        deadline = configuration.expiresAt; lastReceived = Date().timeIntervalSince1970; lastPing = lastReceived
        joinDeadline = lastReceived + 15
        lock.unlock()
        worker.async { [weak self] in
            guard let self, self.isActive(run) else { return }
            socket.resume()
            self.receive(socket, run: run)
            let payload: [String: Any] = ["cid": cid, "match_join": ["match_id": configuration.matchID,
                                         "metadata": ["bound_ticket": configuration.joinTicket]]]
            self.write(payload, socket: socket, run: run)
            self.startTimer(run: run)
        }
    }

    func stop() {
        lock.lock()
        let previous = socket, timer = self.timer
        self.timer = nil; socket = nil; configuration = nil; callback = nil
        generation.invalidate(); active = false; queueFault = false; joined = false; sending = false; drainScheduled = false
        reliable.removeAll(); reliableBytes = 0; latestPresence = nil; reliableBurst = 0
        lock.unlock()
        timer?.cancel(); previous?.cancel()
    }

    @discardableResult func sendPresence(_ data: Data, targetOwnerID: UUID? = nil) -> Bool {
        enqueue(opcode: 1, data: data, target: targetOwnerID)
    }
    @discardableResult func sendInteraction(_ data: Data, targetOwnerID: UUID? = nil) -> Bool {
        enqueue(opcode: 2, data: data, target: targetOwnerID)
    }
    @discardableResult func sendBattle(_ data: Data, targetOwnerID: UUID) -> Bool {
        enqueue(opcode: 3, data: data, target: targetOwnerID)
    }
    @discardableResult func renewTicket(_ ticket: String, expiresAt: TimeInterval) -> Bool {
        let now = Date().timeIntervalSince1970
        guard !ticket.isEmpty, ticket.utf8.count <= 8192, expiresAt.isFinite, expiresAt > now, expiresAt <= now + 120 else { return false }
        lock.lock()
        guard active, !queueFault, joined, reliable.count < Self.maximumReliablePackets,
              reliableBytes + ticket.utf8.count <= Self.maximumReliableBytes else { lock.unlock(); return false }
        // Local renewal does not grant membership: the server verifies its HMAC
        // and account/room binding before accepting any further packets.
        deadline = expiresAt
        reliable.insert(Packet(opcode: 5, data: Data(), target: nil, ticket: ticket), at: 0)
        reliableBytes += ticket.utf8.count
        let run = generation.token
        lock.unlock(); scheduleDrain(run)
        return true
    }

    private func enqueue(opcode: Int, data: Data, target: UUID?) -> Bool {
        guard !data.isEmpty, data.count <= Self.payloadLimit(opcode) else { return false }
        lock.lock()
        guard active, !queueFault, joined, let configuration, deadline > Date().timeIntervalSince1970,
              target == nil || (target != configuration.ownerID && configuration.members.contains(target!)) else { lock.unlock(); return false }
        let packet = Packet(opcode: opcode, data: data, target: target, ticket: nil), run = generation.token
        if opcode == 1 { latestPresence = packet }
        else {
            guard reliable.count < Self.maximumReliablePackets, reliableBytes + data.count <= Self.maximumReliableBytes else {
                queueFault = true
                lock.unlock()
                worker.async { [weak self] in self?.fail(.queueFull, run: run) }
                return false
            }
            reliable.append(packet); reliableBytes += data.count
        }
        lock.unlock(); scheduleDrain(run)
        return true
    }
    private func scheduleDrain(_ run: BoundSDKGeneration.Token) {
        lock.lock()
        guard active, generation.admits(run), !drainScheduled else { lock.unlock(); return }
        drainScheduled = true; lock.unlock()
        worker.async { [weak self] in
            guard let self, self.isActive(run) else { return }
            self.lock.lock(); self.drainScheduled = false; self.lock.unlock()
            self.drain(run)
        }
    }
    private func isActive(_ run: BoundSDKGeneration.Token) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active && generation.admits(run)
    }

    private func drain(_ run: BoundSDKGeneration.Token) {
        lock.lock()
        guard active, generation.admits(run), joined, !sending, let socket, let configuration else { lock.unlock(); return }
        let packet: Packet
        if !reliable.isEmpty && (latestPresence == nil || reliableBurst < 8) {
            packet = reliable.removeFirst(); reliableBytes -= packet.data.count + (packet.ticket?.utf8.count ?? 0); reliableBurst += 1
        } else if let pose = latestPresence { packet = pose; latestPresence = nil; reliableBurst = 0 }
        else { lock.unlock(); return }
        sending = true
        lock.unlock()
        var body: [String: Any] = ["v": 1]
        if let ticket = packet.ticket { body["ticket"] = ticket }
        else { body["body"] = packet.data.base64EncodedString() }
        if let target = packet.target { body["targetOwnerID"] = target.uuidString.lowercased() }
        guard let bytes = try? JSONSerialization.data(withJSONObject: body) else { fail(.invalidMessage, run: run); return }
        write(["match_data_send": ["match_id": configuration.matchID, "op_code": String(packet.opcode),
                                   "data": bytes.base64EncodedString(), "reliable": true]], socket: socket, run: run)
    }

    private func write(_ value: [String: Any], socket: any BoundNakamaSocket, run: BoundSDKGeneration.Token) {
        guard isActive(run), let bytes = try? JSONSerialization.data(withJSONObject: value), let text = String(data: bytes, encoding: .utf8) else { return }
        socket.send(text) { [weak self] error in
            guard let self else { return }
            self.worker.async {
                guard self.isActive(run) else { return }
                if error != nil { self.fail(.connectionLost, run: run); return }
                self.lock.lock(); self.sending = false; self.lock.unlock()
                self.drain(run)
            }
        }
    }

    private func receive(_ socket: any BoundNakamaSocket, run: BoundSDKGeneration.Token) {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.worker.async {
                guard self.isActive(run) else { return }
                switch result {
                case .failure: self.fail(.connectionLost, run: run); return
                case .success(let data): self.consume(data, run: run)
                }
                if self.isActive(run) { self.receive(socket, run: run) }
            }
        }
    }

    private func consume(_ data: Data, run: BoundSDKGeneration.Token) {
        guard data.count <= 65_536, let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { fail(.invalidMessage, run: run); return }
        lock.lock()
        guard active, generation.admits(run), let configuration else { lock.unlock(); return }
        lastReceived = Date().timeIntervalSince1970
        let expectedCID = joinCID
        lock.unlock()
        if value["error"] != nil { fail(value["cid"] as? String == expectedCID ? .joinRejected : .connectionLost, run: run); return }
        if let match = value["match"] as? [String: Any], value["cid"] as? String == expectedCID {
            guard match["match_id"] as? String == configuration.matchID else { fail(.joinRejected, run: run); return }
            lock.lock(); let first = !joined; joined = true; lock.unlock()
            if first { emit(.joined, run: run) }; drain(run); return
        }
        if value["ping"] != nil {
            // Server ping envelopes are uncommon, but keep the reply serialized.
            lock.lock(); let canWrite = !sending; let socket = self.socket; if canWrite { sending = true }; lock.unlock()
            if canWrite, let socket { write(["pong": [:]], socket: socket, run: run) }
            return
        }
        guard let packet = value["match_data"] as? [String: Any] else { return }
        guard packet["match_id"] as? String == configuration.matchID,
              let opcode = Self.integer(packet["op_code"]), [1, 2, 3, 4, 6].contains(opcode),
              let encoded = packet["data"] as? String, encoded.utf8.count <= 48_000,
              let bytes = Data(base64Encoded: encoded),
              let envelope = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any], Self.integer(envelope["v"]) == 1 else { fail(.invalidMessage, run: run); return }
        if opcode == 6 {
            guard let rows = envelope["positions"] as? [[String: Any]], rows.count <= 8 else { fail(.invalidMessage, run: run); return }
            for row in rows {
                guard let ownerText = row["ownerID"] as? String, let owner = UUID(uuidString: ownerText),
                      configuration.members.contains(owner), owner != configuration.ownerID,
                      let age = row["age"] as? Double, age.isFinite, age >= 0, age < 60,
                      let encoded = row["body"] as? String, encoded.utf8.count <= 1024,
                      let body = Data(base64Encoded: encoded), body.count <= 768 else { fail(.invalidMessage, run: run); return }
                emit(.retainedPresence(data: body, ownerID: owner, age: age), run: run)
            }
            return
        }
        if opcode == 4 {
            guard let rows = envelope["members"] as? [[String: Any]], rows.count <= 8 else { fail(.invalidMessage, run: run); return }
            var members: [Member] = []
            for row in rows {
                guard let text = row["ownerID"] as? String, let owner = UUID(uuidString: text), configuration.members.contains(owner),
                      let online = row["online"] as? Bool, !members.contains(where: { $0.ownerID == owner }) else { fail(.invalidMessage, run: run); return }
                members.append(Member(ownerID: owner, online: online))
            }
            emit(.roster(members), run: run); return
        }
        guard let sender = envelope["senderOwnerID"] as? String, let owner = UUID(uuidString: sender),
              configuration.members.contains(owner),
              let body = envelope["body"] as? String, body.utf8.count <= 11_000,
              let payload = Data(base64Encoded: body), !payload.isEmpty, payload.count <= Self.payloadLimit(opcode) else { fail(.invalidMessage, run: run); return }
        if let target = envelope["targetOwnerID"] {
            guard let target = target as? String, UUID(uuidString: target) == configuration.ownerID else { fail(.invalidMessage, run: run); return }
        } else if opcode == 3 { fail(.invalidMessage, run: run); return }
        if owner == configuration.ownerID { return }
        emit(.message(opcode: opcode, data: payload, senderOwnerID: owner), run: run)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let string = value as? String { return Int(string) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue == Double(number.intValue) { return number.intValue }
        return nil
    }
    private static func payloadLimit(_ opcode: Int) -> Int { opcode == 1 ? 768 : (opcode == 2 ? 4096 : maximumPayloadBytes) }
    private func emit(_ event: Event, run: BoundSDKGeneration.Token) {
        lock.lock(); let callback = active && generation.admits(run) ? self.callback : nil; lock.unlock()
        callback?(event)
    }
    private func fail(_ failure: Failure, run: BoundSDKGeneration.Token) {
        lock.lock()
        guard active, generation.admits(run) else { lock.unlock(); return }
        let callback = self.callback, socket = self.socket, timer = self.timer
        active = false; joined = false; sending = false; self.callback = nil; self.socket = nil; self.timer = nil
        reliable.removeAll(); reliableBytes = 0; latestPresence = nil
        lock.unlock()
        timer?.cancel(); socket?.cancel(); callback?(.failed(failure))
    }
    private func startTimer(run: BoundSDKGeneration.Token) {
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick(run) }
        lock.lock()
        guard active, generation.admits(run) else { lock.unlock(); timer.cancel(); return }
        self.timer = timer; lock.unlock(); timer.resume()
    }
    private func tick(_ run: BoundSDKGeneration.Token) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        guard active, generation.admits(run) else { lock.unlock(); return }
        let expired = now >= deadline, timedOut = joined ? now - lastReceived > 45 : now >= joinDeadline
        let shouldPing = joined && !sending && now - lastPing >= 15
        let socket = self.socket
        if shouldPing { sending = true; lastPing = now }
        lock.unlock()
        if expired { fail(.expired, run: run) }
        else if timedOut { fail(.connectionLost, run: run) }
        else if shouldPing, let socket { write(["ping": [:]], socket: socket, run: run) }
    }
}

/// A battle command is accepted into a bounded queue without sleeping on the
/// emulator's completed-frame worker. Close fences subsequent commands.
final class BoundNakamaBattleChannel: BoundBattleChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var client: (any BoundSDKRoomTransport<BoundNakamaConfiguration>)?
    private let targetOwnerID: UUID
    init(client: any BoundSDKRoomTransport<BoundNakamaConfiguration>, targetOwnerID: UUID) { self.client = client; self.targetOwnerID = targetOwnerID }
    func send(_ data: Data) -> Bool {
        guard data.count >= 38, data.count <= 4134, data.starts(with: BoundBattleWire.prefix) else { return false }
        lock.lock(); defer { lock.unlock() }
        return client?.sendBattle(data, targetOwnerID: targetOwnerID) ?? false
    }
    func close() { lock.lock(); client = nil; lock.unlock() }
}

/// Durable run and manual-checkpoint RPCs share the room's short-lived admission
/// ticket, but have no dependency on its WebSocket. No emulator work runs here.
actor BoundNakamaRunService {
    static let shared = BoundNakamaRunService()
    struct Upload: Decodable, Sendable {
        let receipt: BoundMultiplayerCheckpointReceipt
        let count: Int
        let bytes: Int
    }
    struct Checkpoint: Decodable, Sendable {
        let id: UUID
        let predecessor: UUID?
        let history: String
        let uploads: [String: Upload]
        let reservations: [String: Bool]?
        func upload(for owner: UUID) -> Upload? { uploads[owner.uuidString.lowercased()] }
    }
    struct State: Decodable, Sendable {
        let version: Int
        let revision: UInt64
        let ended: Bool
        let head: Checkpoint?
        let pending: Checkpoint?
    }
    enum Failure: LocalizedError {
        case unavailable, conflict, tooLarge
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Server save unavailable. Retry Save when connected."
            case .conflict: return "The server save changed. Refresh and reopen it."
            case .tooLarge: return "This save exceeds the server checkpoint limit."
            }
        }
    }
    private var configuration: BoundNakamaConfiguration?
    private var saveConfiguration: BoundNakamaAuthorization.SaveConfiguration?
    private var saveSession: AppCloudSession?
    private struct DebugRoute:Sendable {
        let identity:BoundMultiplayerRunIdentity,sessionID:UUID,generation:Int
        let perform:@Sendable ([String:BoundDebugJSON]) async throws -> Data
        let revalidate:@Sendable () async throws -> Void
    }
    private let debugRoute:DebugRoute?
    var isDebug:Bool { debugRoute != nil }
    init(debugIdentity:BoundMultiplayerRunIdentity,sessionID:UUID,generation:Int,
         performDebug:@escaping @Sendable ([String:BoundDebugJSON]) async throws -> Data,
         revalidateDebug:@escaping @Sendable () async throws -> Void) {
        debugRoute = .init(identity:debugIdentity,sessionID:sessionID,generation:generation,perform:performDebug,revalidate:revalidateDebug)
        perform={ _ in throw Failure.unavailable };authorizeSaves={ _,_ in throw Failure.unavailable }
    }
    func revalidateDebugScope() async throws {
        guard let debugRoute else { throw Failure.unavailable };try await debugRoute.revalidate()
    }
    private static let memorySession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
    private let perform: @Sendable (URLRequest) async throws -> Data
    private let authorizeSaves: @Sendable (AppCloudSession, String?) async throws -> BoundNakamaAuthorization.SaveConfiguration
    init(authorizeSaves: @escaping @Sendable (AppCloudSession, String?) async throws -> BoundNakamaAuthorization.SaveConfiguration = {
        try await BoundNakamaAuthorization.fetchSaves(session: $0, room: $1)
    }, perform: @escaping @Sendable (URLRequest) async throws -> Data = { request in
        let (data, response) = try await BoundNakamaRunService.memorySession.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
        if [400, 403, 404, 409].contains(response.statusCode) { throw Failure.conflict }
        guard response.statusCode == 200 else { throw Failure.unavailable }
        return data
    }) { self.perform = perform; self.authorizeSaves = authorizeSaves;debugRoute=nil }
    func configure(_ configuration: BoundNakamaConfiguration) {
        guard debugRoute==nil else { return }
        guard configuration.isValid() else { return }
        if let old = self.configuration, old.ownerID == configuration.ownerID, old.roomID == configuration.roomID,
           old.expiresAt > configuration.expiresAt { return }
        self.configuration = configuration
    }
    private func request(_ action: String, identity: BoundMultiplayerRunIdentity, fields: [String: Any] = [:], rpc: String = "bound_run_v1") async throws -> Data {
        if let debugRoute {
            guard rpc=="bound_independent_v2",identity==debugRoute.identity else { throw Failure.conflict }
            return try await debugRequest(action,fields:fields)
        }
        if rpc == "bound_independent_v2", let saveSession {
            guard saveSession.owner == identity.owner else { throw Failure.conflict }
            try saveSession.credentials()
            var fields = fields; fields["save_id"] = identity.run.uuidString.lowercased()
            return try await saveRequest(action, fields: fields)
        }
        guard let configuration, configuration.isValid(), configuration.ownerID == identity.owner,
              configuration.roomID.uuidString.lowercased() == identity.roomID.lowercased(),
              configuration.members.contains(identity.partner),
              var url = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false) else { throw Failure.unavailable }
        url.scheme = "https"; url.path = "/v2/rpc/" + rpc; url.queryItems = nil
        guard let endpoint = url.url else { throw Failure.unavailable }
        var body = fields
        body["action"] = action; body["runID"] = identity.run.uuidString.lowercased(); body["ticket"] = configuration.joinTicket
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + configuration.accessToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(String(decoding: json, as: UTF8.self))
        let data = try await perform(request)
        struct Envelope: Decodable { let payload: String }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw Failure.unavailable }
        return Data(envelope.payload.utf8)
    }
    struct PlayerProfile: Codable, Equatable, Sendable {
        var name: String
        var gender: Int
        var valid: Bool { (1...7).contains(name.utf8.count) && name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) } && (0...1).contains(gender) }
    }
    struct ServerRun: Decodable, Identifiable, Sendable {
        let save_id: UUID
        let game_id: String
        let identity: BoundMultiplayerRunIdentity
        let participants: [UUID]
        let revision: UInt64
        let created_at: String
        let updated_at: String
        let saves: [String: Upload]
        var gameOver: GameOverState? = nil
        var id: UUID { save_id }
    }
    func configureSaves(session: AppCloudSession, room: String? = nil) async throws -> BoundNakamaAuthorization.SaveConfiguration {
        guard debugRoute==nil else { throw Failure.conflict }
        let value = try await authorizeSaves(session, room)
        saveSession = session; saveConfiguration = value
        return value
    }
    private func refreshSaveAuthorization(preserveCreationScope: Bool = false) async throws {
        guard let session = saveSession else { throw Failure.unavailable }
        try session.credentials()
        if let value = saveConfiguration, value.valid, value.ownerID == session.owner,
           value.expiresAt > Date().timeIntervalSince1970 + 25 { return }
        saveConfiguration = try await authorizeSaves(session, preserveCreationScope ? saveConfiguration?.roomID?.uuidString : nil)
    }
    private func saveRequest(_ action: String, fields: [String: Any] = [:]) async throws -> Data {
        if let debugRoute {
            var scoped=fields
            if let run=scoped.removeValue(forKey:"save_id") as? String {
                guard UUID(uuidString:run)==debugRoute.identity.run else { throw Failure.conflict }
            }
            return try await debugRequest(action,fields:scoped)
        }
        try await refreshSaveAuthorization(preserveCreationScope: action == "create")
        guard let value = saveConfiguration, value.valid else { throw Failure.unavailable }
        var body = fields; body["action"] = action; body["saveTicket"] = value.saveTicket
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var request = URLRequest(url: value.httpEndpoint.appendingPathComponent("v2/rpc/bound_independent_v2"))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + value.accessToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(String(decoding: json, as: UTF8.self))
        struct Envelope: Decodable { let payload: String }
        return Data(try JSONDecoder().decode(Envelope.self, from: await perform(request)).payload.utf8)
    }
    func listSaves(gameID: String) async throws -> [ServerRun] {
        struct Page: Decodable { let runs: [ServerRun]; let cursor: String? }
        var runs: [ServerRun] = [], cursor: String?, visited = Set<String>()
        repeat {
            var fields: [String: Any] = ["gameID": gameID]
            if let cursor { guard visited.insert(cursor).inserted else { throw Failure.conflict }; fields["cursor"] = cursor }
            let page = try JSONDecoder().decode(Page.self, from: await saveRequest("list", fields: fields))
            runs += page.runs; cursor = page.cursor
        } while cursor != nil
        return runs.sorted { $0.updated_at > $1.updated_at }
    }
    func createSave(gameID: String, romSHA256: String, settings: Data, profile: PlayerProfile, partnerProfile: PlayerProfile, requestID: UUID) async throws -> IndependentState {
        guard let partner = saveConfiguration?.partnerID, profile.valid, partnerProfile.valid else { throw Failure.unavailable }
        let fields: [String: Any] = ["request_id": requestID.uuidString.lowercased(), "partnerID": partner.uuidString.lowercased(),
            "gameID": gameID, "romSHA256": romSHA256, "settings": settings.base64EncodedString(),
            "profile": ["name": profile.name, "gender": profile.gender],
            "partnerProfile": ["name": partnerProfile.name, "gender": partnerProfile.gender]]
        return try JSONDecoder().decode(IndependentState.self, from: await saveRequest("create", fields: fields))
    }
    func getSave(_ id: UUID) async throws -> IndependentState {
        try JSONDecoder().decode(IndependentState.self, from: await saveRequest("get", fields: ["save_id": id.uuidString.lowercased()]))
    }
    func setProfile(_ profile: PlayerProfile, saveID: UUID) async throws -> IndependentState {
        guard profile.valid else { throw Failure.conflict }
        return try JSONDecoder().decode(IndependentState.self, from: await saveRequest("profile", fields: ["save_id": saveID.uuidString.lowercased(),
            "profile": ["name": profile.name, "gender": profile.gender]]))
    }
    func deleteSave(_ id: UUID, expectedRevision: UInt64) async throws {
        _ = try await saveRequest("delete", fields: ["save_id": id.uuidString.lowercased(), "expectedRevision": expectedRevision, "confirmSharedDeletion": true])
    }
    struct GameOverState: Codable, Equatable, Sendable {
        let id: UUID
        let returnRequested: Bool
        let returned: [UUID]
        let deleted: Bool
    }
    func gameOver(saveID: UUID, action: String, eventID: UUID? = nil) async throws -> GameOverState {
        guard ["gameOver", "gameOverReturn", "gameOverMenu", "gameOverStatus"].contains(action),
              action == "gameOverStatus" || eventID != nil else { throw Failure.conflict }
        var fields: [String: Any] = ["save_id": saveID.uuidString.lowercased()]
        if let eventID { fields["eventID"] = eventID.uuidString.lowercased() }
        let state = try JSONDecoder().decode(GameOverState.self, from: await saveRequest(action, fields: fields))
        guard Set(state.returned).count == state.returned.count, state.returned.count <= 2,
              state.returnRequested || state.returned.isEmpty,
              !state.deleted || state.returnRequested && state.returned.count == 2,
              action == "gameOver" || eventID == nil || state.id == eventID else { throw Failure.conflict }
        return state
    }
    func downloadIndependent(identity: BoundMultiplayerRunIdentity, upload: Upload) async throws -> BoundMultiplayerSavePackage {
        guard upload.receipt.run == identity.run, upload.receipt.owner == identity.owner,
              upload.bytes > 0, upload.bytes <= 16 * 1024 * 1024,
              upload.count == ((upload.bytes + 2) / 3 * 4 + 11999) / 12000 else { throw Failure.conflict }
        struct Chunk: Decodable { let data: String }
        var encoded = ""
        for index in 0..<upload.count {
            let data = try await request("saveDownload", identity: identity, fields: ["checkpoint": upload.receipt.checkpoint.uuidString.lowercased(), "index": index], rpc: "bound_independent_v2")
            let chunk = try JSONDecoder().decode(Chunk.self, from: data)
            guard chunk.data.utf8.count <= 12000 else { throw Failure.conflict }
            encoded += chunk.data
        }
        guard let bytes = Data(base64Encoded: encoded), bytes.count == upload.bytes,
              BoundMultiplayerSaveStore.hash(bytes) == upload.receipt.payloadSHA256 else { throw Failure.conflict }
        let payload = try JSONDecoder().decode(BoundMultiplayerSavePackage.Payload.self, from: bytes)
        guard payload.version == 2, payload.manifest.identity == identity,
              payload.checkpoint == upload.receipt.checkpoint, payload.sharedEventDigest == upload.receipt.sharedEventDigest else { throw Failure.conflict }
        return .init(payload: payload, receipt: upload.receipt)
    }
    func session(identity: BoundMultiplayerRunIdentity, history: String, bits: Data, head: BoundMultiplayerSavePackage?, world: BoundWorldState? = nil) async throws -> State {
        let value = try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(identity))
        var fields: [String: Any] = ["identity": value, "history": history,
            "bits": bits.base64EncodedString(), "checkpoint": head?.payload.checkpoint.uuidString.lowercased() as Any? ?? NSNull(),
            "checkpointHistory": head?.payload.sharedEventDigest as Any? ?? NSNull()]
        if let world, world.valid { fields["world"] = try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(world)) }
        let data = try await request("session", identity: identity, fields: fields)
        return try JSONDecoder().decode(State.self, from: data)
    }

    struct IndependentState: Decodable, Sendable {
        struct LegacyHistory: Decodable, Sendable { let history: String; let bits: Data }
        let version: Int
        let identity: BoundMultiplayerRunIdentity
        let committed: Bool
        let cancelled: Bool
        let epoch: UInt64
        let revision: UInt64
        let cursors: [String: BoundMultiplayerSharedCursor.Position]
        let deliveries: [String: [String: UInt64]]
        let saves: [String: Upload]
        let events: [BoundMultiplayerSharedEvent]
        let legacyHistory: [String: LegacyHistory]?
        let profiles: [String: PlayerProfile]?
        let save_id: UUID?
        let updated_at: String?
        var gameOver: GameOverState? = nil

        var serverCursor: BoundMultiplayerSharedCursor {
            .init(origins: Dictionary(uniqueKeysWithValues: cursors.compactMap { key, value in UUID(uuidString:key).map { ($0.uuidString,value) } }))
        }
        func peerCursor(_ owner: UUID) -> BoundMultiplayerSharedCursor {
            .init(origins: Dictionary(uniqueKeysWithValues: (deliveries[owner.uuidString.lowercased()] ?? [:]).compactMap { key, value in
                UUID(uuidString:key).map { ($0.uuidString,.init(contiguous:value)) }
            }))
        }
    }
    func sharedSetup(identity: BoundMultiplayerRunIdentity, action: String = "setup", epoch: UInt64 = 0) async throws -> IndependentState {
        let value = try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(identity))
        let data = try await request(action, identity:identity, fields:["identity":value,"epoch":epoch,"authorized":action == "takeover"], rpc:"bound_independent_v2")
        return try JSONDecoder().decode(IndependentState.self,from:data)
    }
    func sharedEvents(identity: BoundMultiplayerRunIdentity, events: [BoundMultiplayerSharedEvent], cursor: BoundMultiplayerSharedCursor) async throws -> IndependentState {
        var batch: [BoundMultiplayerSharedEvent] = []
        for event in events.prefix(16) {
            let candidate = batch + [event]
            if try BoundMultiplayerSaveStore.encode(candidate).count > 14000 {
                guard !batch.isEmpty else { throw Failure.tooLarge }
                break
            }
            batch = candidate
        }
        let values = try JSONSerialization.jsonObject(with:BoundMultiplayerSaveStore.encode(batch))
        let after = Dictionary(uniqueKeysWithValues: cursor.origins.map { ($0.key.lowercased(),$0.value.contiguous) })
        let data = try await request("events",identity:identity,
            fields:["events":values,"after":after,"checkpointAcquisitions":true],rpc:"bound_independent_v2")
        return try JSONDecoder().decode(IndependentState.self,from:data)
    }
    func uploadIndependent(_ package: BoundMultiplayerSavePackage, expectedHead: UUID?, session: AppCloudSession? = nil,
                           authorize: (@Sendable () async throws -> Void)? = nil) async throws -> IndependentState {
        let bytes = try BoundMultiplayerSaveStore.encode(package.payload)
        guard bytes.count <= 16 * 1024 * 1024, package.payload.version == 2 else { throw Failure.tooLarge }
        let encoded = Array(bytes.base64EncodedString().utf8), size = 12000, count = (encoded.count + size - 1) / size
        let receipt = try JSONSerialization.jsonObject(with:BoundMultiplayerSaveStore.encode(package.receipt))
        let identity = package.payload.manifest.identity
        try await authorize?()
        try await refreshUploadAuthorization(identity:identity,session:session)
        var fields: [String:Any] = ["checkpoint":package.payload.checkpoint.uuidString.lowercased(),"receipt":receipt,
            "count":count,"bytes":bytes.count,"expectedHead":expectedHead?.uuidString.lowercased() as Any? ?? NSNull()]
        _ = try await request("save",identity:identity,fields:fields,rpc:"bound_independent_v2")
        for index in 0..<count {
            try Task.checkCancellation()
            try await authorize?()
            try await refreshUploadAuthorization(identity:identity,session:session)
            fields["index"] = index
            fields["data"] = String(decoding:encoded[(index*size)..<min(encoded.count,(index+1)*size)],as:UTF8.self)
            _ = try await request("saveChunk",identity:identity,fields:fields,rpc:"bound_independent_v2")
        }
        fields.removeValue(forKey:"data"); fields.removeValue(forKey:"index")
        try await authorize?()
        try await refreshUploadAuthorization(identity:identity,session:session)
        let data = try await request("saveSeal",identity:identity,fields:fields,rpc:"bound_independent_v2")
        return try JSONDecoder().decode(IndependentState.self,from:data)
    }
    private func refreshUploadAuthorization(identity: BoundMultiplayerRunIdentity, session: AppCloudSession?) async throws {
        if let debugRoute {
            guard identity==debugRoute.identity,session==nil || session?.owner==identity.owner else { throw Failure.conflict }
            try await debugRoute.revalidate();return
        }
        if saveSession != nil { try await refreshSaveAuthorization(); return }
        guard let session else { return }
        guard session.owner == identity.owner else { throw Failure.conflict }
        if let configuration, configuration.ownerID == identity.owner,
           configuration.roomID.uuidString.lowercased() == identity.roomID.lowercased(),
           configuration.expiresAt > Date().timeIntervalSince1970 + 25 { return }
        let value = try await BoundNakamaAuthorization.fetch(room:identity.roomID,session:session)
        configure(value)
    }
    private func debugRequest(_ action:String,fields:[String:Any]) async throws -> Data {
        guard let debugRoute,debugRoute.identity.valid,debugRoute.generation>0,
              ["get","events","save","saveChunk","saveSeal","saveDownload","gameOver","gameOverReturn","gameOverMenu","gameOverStatus"].contains(action),
              Set(fields.keys).isDisjoint(with:["owner","ownerID","runID","save_id","identity","namespace","collection","key","ticket","saveTicket","capability"]) else { throw Failure.conflict }
        var value=try BoundDebugJSON(data:JSONSerialization.data(withJSONObject:fields)).object ?? [:]
        value["action"] = .string(action)
        return try await debugRoute.perform(value)
    }
    func begin(identity: BoundMultiplayerRunIdentity, history: String, predecessor: UUID?) async throws -> State {
        let data = try await request("begin", identity: identity, fields: ["history": history,
            "predecessor": predecessor?.uuidString.lowercased() as Any? ?? NSNull()])
        return try JSONDecoder().decode(State.self, from: data)
    }
    func cancel(identity: BoundMultiplayerRunIdentity, checkpoint: UUID) async throws -> State {
        let data = try await request("cancel", identity: identity, fields: ["checkpoint": checkpoint.uuidString.lowercased()])
        return try JSONDecoder().decode(State.self, from: data)
    }
    func prepare(identity: BoundMultiplayerRunIdentity, checkpoint: UUID, history: String) async throws -> State {
        let data = try await request("prepare", identity: identity, fields: ["checkpoint": checkpoint.uuidString.lowercased(), "history": history])
        return try JSONDecoder().decode(State.self, from: data)
    }
    func end(identity: BoundMultiplayerRunIdentity) async throws {
        _ = try await request("end", identity: identity)
    }
    func upload(_ package: BoundMultiplayerSavePackage) async throws -> State {
        let bytes = try BoundMultiplayerSaveStore.encode(package.payload)
        guard bytes.count <= 16 * 1024 * 1024 else { throw Failure.tooLarge }
        let encoded = bytes.base64EncodedString(), size = 12000, count = (encoded.utf8.count + size - 1) / size
        let receipt = try JSONSerialization.jsonObject(with: BoundMultiplayerSaveStore.encode(package.receipt))
        let identity = package.payload.manifest.identity
        var fields: [String: Any] = ["checkpoint": package.payload.checkpoint.uuidString.lowercased(),
            "receipt": receipt, "count": count, "bytes": bytes.count]
        _ = try await request("upload", identity: identity, fields: fields)
        let ascii = Array(encoded.utf8)
        for index in 0..<count {
            try Task.checkCancellation()
            var chunk = fields; chunk["index"] = index
            chunk["data"] = String(decoding: ascii[(index * size)..<min(ascii.count, (index + 1) * size)], as: UTF8.self)
            _ = try await request("chunk", identity: identity, fields: chunk)
        }
        fields["checkpoint"] = package.payload.checkpoint.uuidString.lowercased()
        let data = try await request("seal", identity: identity, fields: fields)
        return try JSONDecoder().decode(State.self, from: data)
    }
    func download(identity: BoundMultiplayerRunIdentity, checkpoint: Checkpoint) async throws -> BoundMultiplayerSavePackage {
        guard let own = checkpoint.upload(for: identity.owner), let partner = checkpoint.upload(for: identity.partner),
              own.bytes > 0, own.bytes <= 16 * 1024 * 1024, own.count == ((own.bytes + 2) / 3 * 4 + 11999) / 12000 else { throw Failure.conflict }
        var encoded = ""
        struct Chunk: Decodable { let data: String }
        for index in 0..<own.count {
            try Task.checkCancellation()
            let data = try await request("download", identity: identity, fields: ["checkpoint": checkpoint.id.uuidString.lowercased(), "index": index])
            let chunk = try JSONDecoder().decode(Chunk.self, from: data)
            guard chunk.data.utf8.count <= 12000 else { throw Failure.conflict }
            encoded += chunk.data
        }
        guard let bytes = Data(base64Encoded: encoded), bytes.count == own.bytes,
              BoundMultiplayerSaveStore.hash(bytes) == own.receipt.payloadSHA256 else { throw Failure.conflict }
        let payload = try JSONDecoder().decode(BoundMultiplayerSavePackage.Payload.self, from: bytes)
        guard payload.manifest.identity == identity, payload.checkpoint == checkpoint.id,
              payload.sharedEventDigest == checkpoint.history else { throw Failure.conflict }
        return .init(payload: payload, receipt: own.receipt, partnerReceipt: partner.receipt)
    }
}
