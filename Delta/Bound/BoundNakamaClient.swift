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
final class BoundNakamaClient: @unchecked Sendable {
    enum Failure: Error, Equatable, Sendable { case invalidConfiguration, connectionLost, joinRejected, invalidMessage, queueFull, expired }
    struct Member: Equatable, Sendable { let ownerID: UUID; let online: Bool }
    enum Event: Sendable {
        case joined
        case roster([Member])
        case message(opcode: Int, data: Data, senderOwnerID: UUID)
        case failed(Failure)
    }
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
    private var generation = UUID()
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
        let socket = makeSocket(request), run = UUID(), cid = UUID().uuidString
        lock.lock()
        self.socket = socket; self.configuration = configuration; callback = event
        generation = run; active = true; queueFault = false; joined = false; sending = true; joinCID = cid
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
        generation = UUID(); active = false; queueFault = false; joined = false; sending = false; drainScheduled = false
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
        let run = generation
        lock.unlock(); scheduleDrain(run)
        return true
    }

    private func enqueue(opcode: Int, data: Data, target: UUID?) -> Bool {
        guard !data.isEmpty, data.count <= Self.payloadLimit(opcode) else { return false }
        lock.lock()
        guard active, !queueFault, joined, let configuration, deadline > Date().timeIntervalSince1970,
              target == nil || (target != configuration.ownerID && configuration.members.contains(target!)) else { lock.unlock(); return false }
        let packet = Packet(opcode: opcode, data: data, target: target, ticket: nil), run = generation
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
    private func scheduleDrain(_ run: UUID) {
        lock.lock()
        guard active, generation == run, !drainScheduled else { lock.unlock(); return }
        drainScheduled = true; lock.unlock()
        worker.async { [weak self] in
            guard let self, self.isActive(run) else { return }
            self.lock.lock(); self.drainScheduled = false; self.lock.unlock()
            self.drain(run)
        }
    }
    private func isActive(_ run: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active && generation == run
    }

    private func drain(_ run: UUID) {
        lock.lock()
        guard active, generation == run, joined, !sending, let socket, let configuration else { lock.unlock(); return }
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

    private func write(_ value: [String: Any], socket: any BoundNakamaSocket, run: UUID) {
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

    private func receive(_ socket: any BoundNakamaSocket, run: UUID) {
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

    private func consume(_ data: Data, run: UUID) {
        guard data.count <= 65_536, let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { fail(.invalidMessage, run: run); return }
        lock.lock()
        guard active, generation == run, let configuration else { lock.unlock(); return }
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
              let opcode = Self.integer(packet["op_code"]), (1...4).contains(opcode),
              let encoded = packet["data"] as? String, encoded.utf8.count <= 48_000,
              let bytes = Data(base64Encoded: encoded),
              let envelope = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any], Self.integer(envelope["v"]) == 1 else { fail(.invalidMessage, run: run); return }
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
    private func emit(_ event: Event, run: UUID) {
        lock.lock(); let callback = active && generation == run ? self.callback : nil; lock.unlock()
        callback?(event)
    }
    private func fail(_ failure: Failure, run: UUID) {
        lock.lock()
        guard active, generation == run else { lock.unlock(); return }
        let callback = self.callback, socket = self.socket, timer = self.timer
        active = false; joined = false; sending = false; self.callback = nil; self.socket = nil; self.timer = nil
        reliable.removeAll(); reliableBytes = 0; latestPresence = nil
        lock.unlock()
        timer?.cancel(); socket?.cancel(); callback?(.failed(failure))
    }
    private func startTimer(run: UUID) {
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick(run) }
        lock.lock()
        guard active, generation == run else { lock.unlock(); timer.cancel(); return }
        self.timer = timer; lock.unlock(); timer.resume()
    }
    private func tick(_ run: UUID) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        guard active, generation == run else { lock.unlock(); return }
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
    private var client: BoundNakamaClient?
    private let targetOwnerID: UUID
    init(client: BoundNakamaClient, targetOwnerID: UUID) { self.client = client; self.targetOwnerID = targetOwnerID }
    func send(_ data: Data) -> Bool {
        guard data.count > 30, data.count <= 4126, data.starts(with: BoundBattleWire.prefix) else { return false }
        lock.lock(); defer { lock.unlock() }
        return client?.sendBattle(data, targetOwnerID: targetOwnerID) ?? false
    }
    func close() { lock.lock(); client = nil; lock.unlock() }
}
