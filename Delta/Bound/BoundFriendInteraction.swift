import Foundation
import DeltaCore

/// Uses settled, un-interpolated positions. A sprite crossing a tile boundary
/// must never become an NPC target in the middle of its step.
struct BoundFriendWorldPosition: Codable, Equatable, Sendable {
    let mapGroup: Int
    let mapNumber: Int
    let elevation: Int
    let x: Int
    let y: Int
    let facing: Int

    init?(pose: BoundPresencePose) {
        guard pose.isValid else { return nil }
        let tx = (pose.x - 8) / 16, ty = (pose.y - 16) / 16
        guard tx == tx.rounded(), ty == ty.rounded() else { return nil }
        mapGroup = pose.mapGroup; mapNumber = pose.mapNumber; elevation = pose.elevation
        x = Int(tx); y = Int(ty); facing = pose.facing
    }
    var isValid: Bool {
        (0...255).contains(mapGroup) && (0...255).contains(mapNumber) && (0...15).contains(elevation)
            && (-7...65535).contains(x) && (-7...65535).contains(y) && (1...4).contains(facing)
    }
    func isNextTo(_ other: Self) -> Bool {
        isValid && other.isValid && mapGroup == other.mapGroup && mapNumber == other.mapNumber
            && elevation == other.elevation && abs(x - other.x) + abs(y - other.y) == 1
    }
    func isFacing(_ other: Self) -> Bool {
        guard isNextTo(other) else { return false }
        switch facing {
        case 1: return other.y == y + 1
        case 2: return other.y == y - 1
        case 3: return other.x == x - 1
        case 4: return other.x == x + 1
        default: return false
        }
    }
    func occupiesSameTile(as other: Self) -> Bool {
        mapGroup == other.mapGroup && mapNumber == other.mapNumber && elevation == other.elevation
            && x == other.x && y == other.y
    }
}

/// A separate namespace and queue from the replaceable movement mailbox.
/// This protocol carries invitations only; an agreement is not a game outcome.
struct BoundFriendInteractionPacket: Codable, Equatable, Sendable {
    static let prefix = Data([0x42, 0x46, 0x49, 0x31]) // BFI1
    static let maximumBytes = 1024
    enum Activity: String, Codable, CaseIterable, Sendable {
        case battle, trade
        var title: String { self == .battle ? "Battle" : "Trade" }
    }
    enum Action: String, Codable, Sendable { case request, accept, confirm, decline, cancel }
    let sender: UUID
    let receiver: UUID
    let id: UUID
    let activity: Activity
    let action: Action
    let origin: BoundFriendWorldPosition
    let target: BoundFriendWorldPosition

    func encoded() -> Data? {
        guard origin.isValid, target.isValid, sender != receiver,
              let json = try? JSONEncoder().encode(self), json.count + Self.prefix.count <= Self.maximumBytes else { return nil }
        return Self.prefix + json
    }
    static func decode(_ data: Data) -> Self? {
        guard data.count <= maximumBytes, data.starts(with: prefix),
              let packet = try? JSONDecoder().decode(Self.self, from: data.dropFirst(prefix.count)),
              packet.sender != packet.receiver, packet.origin.isValid, packet.target.isValid,
              packet.origin.isFacing(packet.target) else { return nil }
        return packet
    }
}

@MainActor
final class BoundFriendInteractionSession {
    typealias Packet = BoundFriendInteractionPacket
    struct Context: Equatable {
        let localSession: UUID
        let peerSession: UUID
        let local: BoundFriendWorldPosition
        let peer: BoundFriendWorldPosition
    }
    enum Phase: Equatable {
        case idle, choosing, outgoing, incoming, confirming, agreed, connecting, playing, ended
    }
    private(set) var phase: Phase = .idle
    private(set) var activity: Packet.Activity?
    private(set) var message = ""
    private(set) var requestID: UUID?
    var changed: (() -> Void)?
    var context: (() -> Context?)?
    var send: ((Data) -> Bool)?
    /// The native activity adapter can consume this agreement. No save, RAM or
    /// battle result is changed by the invitation layer itself.
    var agreed: ((Packet.Activity, UUID, Bool) -> Void)?
    var canPresent: (() -> Bool)?
    let inputGate = BoundFriendWorldInputGate()
    func refreshInputGate() { inputGate.update(available: canInteract, blocked: blocksGameplay) }
    private func notify() { refreshInputGate(); changed?() }
    private var anchor: Context?
    private var initiator = false
    private var deadline: TimeInterval?
    private var retired: [UUID] = []
    private var connected = false
    var blocksGameplay: Bool { phase != .idle && phase != .playing }
    var cancelActivity: (() -> Void)?
    func activityProgress(_ message: String, playing: Bool) {
        guard activity == .battle else { return }
        phase = playing ? .playing : .connecting; self.message = message; deadline = nil; notify()
    }
    func activityEnded(_ message: String) { end(message) }
    var canInteract: Bool {
        guard connected, phase == .idle, canPresent?() ?? true, let value = context?() else { return false }
        return value.local.isFacing(value.peer)
    }

    func start(send: @escaping (Data) -> Bool) {
        reset(); self.send = send; connected = true; refreshInputGate()
    }
    func stop(message: String = "Friend connection ended") {
        guard connected else { refreshInputGate(); return }
        connected = false; send = nil
        if phase != .idle { end(message) }
        refreshInputGate()
    }
    @discardableResult func open(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard canInteract, let value = context?() else { return false }
        anchor = value; deadline = now + 30; phase = .choosing; message = "Choose an interaction"
        notify(); return true
    }
    func request(_ activity: Packet.Activity, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard phase == .choosing, validAnchor(), let anchor else { return }
        self.activity = activity; requestID = UUID(); initiator = true
        phase = .outgoing; deadline = now + 30; message = "Waiting for your friend…"
        guard emit(.request, anchor: anchor) else { end("Couldn’t send the request"); return }
        notify()
    }
    func accept(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard phase == .incoming, validAnchor(), let anchor else { return }
        phase = .confirming; deadline = now + 10; message = "Confirming with your friend…"
        guard emit(.accept, anchor: anchor) else { end("Couldn’t confirm the request"); return }
        notify()
    }
    func decline() {
        if phase == .incoming, let anchor { _ = emit(.decline, anchor: anchor) }
        reset()
    }
    func cancel() {
        if phase == .connecting || phase == .playing { cancelActivity?(); return }
        if [.outgoing, .confirming, .incoming].contains(phase), let anchor { _ = emit(.cancel, anchor: anchor) }
        reset()
    }
    func invalidate() {
        if phase == .connecting || phase == .playing { cancelActivity?(); return }
        guard ![.idle, .ended].contains(phase) else { return }
        if let anchor { _ = emit(.cancel, anchor: anchor) }
        end("Interaction ended")
    }
    func tick(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        refreshInputGate()
        guard ![.idle, .ended, .connecting, .playing].contains(phase) else { return }
        if !validAnchor() {
            if let anchor { _ = emit(.cancel, anchor: anchor) }
            end("Your friend is no longer next to you")
        } else if let deadline, now >= deadline {
            if let anchor { _ = emit(.cancel, anchor: anchor) }
            end("Request timed out")
        }
    }
    func receive(_ data: Data, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard connected, let packet = Packet.decode(data), !retired.contains(packet.id),
              let current = context?(), packet.sender == current.peerSession,
              packet.receiver == current.localSession else { return }
        if packet.action == .request {
            if packet.id == requestID { return } // Duplicate delivery is idempotent.
            guard (phase == .idle || phase == .choosing), canPresent?() ?? true else {
                // One pending invitation at a time, including crossed requests.
                let reply = Packet(sender: current.localSession, receiver: current.peerSession, id: packet.id,
                    activity: packet.activity, action: .decline, origin: packet.origin, target: packet.target)
                if let data = reply.encoded() { _ = send?(data) }
                return
            }
            guard current.peer.isFacing(current.local), packet.origin.occupiesSameTile(as: current.peer),
                  packet.target.occupiesSameTile(as: current.local) else { return }
            anchor = current; activity = packet.activity; requestID = packet.id; initiator = false
            phase = .incoming; deadline = now + 30; message = "Your friend wants to \(packet.activity.rawValue)"
            notify(); return
        }
        guard packet.id == requestID, packet.activity == activity, let anchor,
              packet.origin.occupiesSameTile(as: initiator ? anchor.local : anchor.peer),
              packet.target.occupiesSameTile(as: initiator ? anchor.peer : anchor.local) else { return }
        switch packet.action {
        case .accept:
            guard phase == .outgoing, initiator, validAnchor() else { return }
            phase = .agreed; deadline = nil; message = "\(packet.activity.title) invitation accepted"
            guard emit(.confirm, anchor: anchor) else { end("Couldn’t confirm the request"); return }
            notify(); agreed?(packet.activity, packet.id, true)
        case .confirm:
            guard phase == .confirming, !initiator, validAnchor() else { return }
            phase = .agreed; deadline = nil; message = "\(packet.activity.title) invitation accepted"
            notify(); agreed?(packet.activity, packet.id, false)
        case .decline:
            guard phase == .outgoing else { return }
            end("Your friend declined the request")
        case .cancel: end("Your friend cancelled the interaction")
        case .request: break
        }
    }
    private func validAnchor() -> Bool {
        guard connected, let anchor, let current = context?(),
              current.localSession == anchor.localSession, current.peerSession == anchor.peerSession,
              current.local.occupiesSameTile(as: anchor.local), current.peer.occupiesSameTile(as: anchor.peer),
              current.local.isNextTo(current.peer) else { return false }
        return (initiator || phase == .choosing) ? current.local.isFacing(current.peer) : current.peer.isFacing(current.local)
    }
    private func emit(_ action: Packet.Action, anchor: Context) -> Bool {
        guard let activity, let requestID else { return false }
        let packet = Packet(sender: anchor.localSession, receiver: anchor.peerSession, id: requestID,
            activity: activity, action: action, origin: initiator ? anchor.local : anchor.peer,
            target: initiator ? anchor.peer : anchor.local)
        guard let data = packet.encoded() else { return false }
        return send?(data) == true
    }
    private func retireRequest() {
        if let requestID { retired.append(requestID); if retired.count > 32 { retired.removeFirst() } }
    }
    private func end(_ message: String) {
        retireRequest(); deadline = nil; phase = .ended; self.message = message; notify()
    }
    private func reset() {
        retireRequest(); phase = .idle; anchor = nil; activity = nil; requestID = nil; deadline = nil; message = ""
        notify()
    }
}

/// Both the app receiver and emulator receiver see the same filtered input.
/// The core ignores this app-only namespace, so interacting cannot also press A
/// on an underlying NPC, sign or door. Mapping lookups have no UI side effects.
enum BoundFriendWorldInput: String, Input {
    case interact, blockedA, blocked
    var type: InputType { .controller(GameControllerInputType("com.bound.friend-world")) }
}
final class BoundFriendWorldInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available = false
    private var blocked = false
    func update(available: Bool, blocked: Bool) {
        lock.lock(); self.available = available; self.blocked = blocked; lock.unlock()
    }
    func filter(_ input: Input) -> Input {
        lock.lock(); let available = available, blocked = blocked; lock.unlock()
        // Preserve app shortcuts and the native pause/menu control.
        if ActionInput(input: input) != nil || StandardGameControllerInput(input: input) == .menu { return input }
        if blocked { return Self.isA(input) ? BoundFriendWorldInput.blockedA : BoundFriendWorldInput.blocked }
        if available && Self.isA(input) { return BoundFriendWorldInput.interact }
        return input
    }
    static func isA(_ input: Input) -> Bool {
        StandardGameControllerInput(input: input) == .a || (input.type == .game(.gba) && input.stringValue == "a")
    }
}
