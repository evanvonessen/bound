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

    init(mapGroup:Int,mapNumber:Int,elevation:Int,x:Int,y:Int,facing:Int) {
        self.mapGroup=mapGroup;self.mapNumber=mapNumber;self.elevation=elevation;self.x=x;self.y=y;self.facing=facing
    }

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
    private(set) var requiresResultAcknowledgement = false
    private(set) var menuPresented = false
    static let invitationLifetime: TimeInterval = 30
    static let maximumRetiredRequests = 256
    private(set) var requestID: UUID?
    var changed: (() -> Void)?
    var context: (() -> Context?)?
    var send: ((Data) -> Bool)?
    /// The native activity adapter can consume this agreement. No save, RAM or
    /// battle result is changed by the invitation layer itself.
    var agreed: ((Packet.Activity, UUID, Bool) -> Void)?
    var canPresent: (() -> Bool)?
    /// Opaque authenticated owner/room/run identity, captured with consent.
    var admissionIdentity: (() -> String?)?
    let inputGate = BoundFriendWorldInputGate()
    var beforeAgreement: ((@escaping () -> Void) -> Void)?
    var nativeDialogueManaged=false, nativeDialogueReady=false, nativeDialogueBusy=false, nativeDialogueInput=false
    func refreshInputGate() {
        inputGate.update(available:canInteract, blocked:(blocksGameplay || nativeDialogueBusy) && !nativeDialogueInput)
    }
    private func notify() { refreshInputGate(); changed?() }
    private(set) var anchorFailure=""
    var contextDiagnostic:(()->String)?
    private var anchor: Context?
    private var initiator = false
    private var lastTransmission: TimeInterval?
    private var agreementAcknowledged = false
    private var agreementScheduled = false
    private var agreementGeneration = UUID()
    private var needsFreshAnchor = false
    private var invitationDeadline: TimeInterval?
    private var anchorIdentity: String?
    private var retired: [UUID] = []
    private var terminalReplies: [UUID: Packet.Action] = [:]
    private(set) var connected = false
    var waitingForConnection: Bool { !connected || needsFreshAnchor }
    var blocksGameplay: Bool { menuPresented || phase == .agreed || phase == .connecting }
    var cancelActivity: (() -> Void)?
    /// Reattach a locally persisted, already consented native activity. The
    /// transport still has to authenticate the same room and complete its fresh handshake.
    func restoreActivity(_ activity:Packet.Activity,id:UUID,initiator:Bool) {
        self.activity=activity;requestID=id;self.initiator=initiator
        phase = .connecting;message="Waiting for your friend…";requiresResultAcknowledgement=false
        agreementAcknowledged=true;agreementScheduled=false;agreementGeneration=UUID()
        menuPresented=false;invitationDeadline=nil
        needsFreshAnchor=true;lastTransmission=nil;notify()
    }
    func activityProgress(_ message: String, playing: Bool) {
        guard activity != nil else { return }
        phase = playing ? .playing : .connecting; self.message = message; notify()
    }
    func activityEnded(_ message: String) { end(message, acknowledgement: true) }
    var canInteract: Bool {
        let pending = [.incoming, .outgoing, .confirming].contains(phase) && !menuPresented
        guard BoundMultiplayerFeatures.isEnabled, connected,
              (pending || retired.count < Self.maximumRetiredRequests && (phase == .idle || phase == .ended && !requiresResultAcknowledgement)),
              (!nativeDialogueManaged || nativeDialogueReady && !nativeDialogueBusy), canPresent?() ?? true,
              admissionIdentity == nil || admissionIdentity?() != nil, let value = context?() else { return false }
        return value.local.isFacing(value.peer)
    }

    func start(send: @escaping (Data) -> Bool) {
        guard BoundMultiplayerFeatures.isEnabled else { return }
        // A reconnect must not erase the save/recovery result before the
        // player has acknowledged it. Retired requests still cannot restart.
        self.send = send; connected = true; lastTransmission = nil; notify()
    }
    /// Socket/roster gaps are not user cancellation. Keep the same native menu,
    /// choice and consent while the authenticated connection is restored.
    func suspend() {
        connected = false; send = nil; lastTransmission = nil
        needsFreshAnchor = true
        agreementGeneration = UUID(); agreementScheduled = false
        notify()
    }
    func peerPreparedActivity() { agreementAcknowledged = true }
    func stop(message: String = "Friend connection ended") {
        if let anchor, ![.idle, .ended, .playing, .connecting].contains(phase) { _ = emit(.cancel, anchor: anchor) }
        connected = false; send = nil
        if phase != .idle && phase != .ended { end(message) }
        refreshInputGate()
    }
    @discardableResult func open(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        expireInvitation(at: now)
        guard canInteract, let value = context?() else { return false }
        if [.incoming, .outgoing, .confirming].contains(phase) {
            guard anchorValidity() == true else { return false }
            menuPresented = true; notify(); return true
        }
        requiresResultAcknowledgement = false
        anchor = value; anchorIdentity = admissionIdentity?(); initiator = true; lastTransmission = nil
        menuPresented = true
        phase = .choosing; message = "Choose an interaction"
        notify(); return true
    }
    func request(_ activity: Packet.Activity, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard phase == .choosing else { return }
        guard anchorValidity() != false else { end("Your friend is no longer next to you"); return }
        self.activity = activity; requestID = UUID(); initiator = true
        menuPresented = false; invitationDeadline = now + Self.invitationLifetime
        agreementAcknowledged = false
        phase = .outgoing; lastTransmission = nil; message = "Waiting for your friend…"
        retry(at: now)
        notify()
    }
    func accept(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        expireInvitation(at: now)
        guard phase == .incoming else { return }
        guard anchorValidity() != false else { end("Your friend is no longer next to you"); return }
        menuPresented = false
        phase = .confirming; lastTransmission = nil; message = "Confirming with your friend…"
        retry(at: now)
        notify()
    }
    func decline() {
        if phase == .incoming, let anchor { _ = emit(.decline, anchor: anchor) }
        if let requestID { terminalReplies[requestID] = .decline }
        reset()
    }
    func cancel() {
        if phase == .connecting || phase == .playing { cancelActivity?(); return }
        if [.outgoing, .confirming, .incoming, .agreed].contains(phase), let anchor { _ = emit(.cancel, anchor: anchor) }
        reset()
    }
    func invalidate() {
        if phase == .connecting || phase == .playing { cancelActivity?(); return }
        guard ![.idle, .ended].contains(phase) else { return }
        if let anchor { _ = emit(.cancel, anchor: anchor) }
        end("Interaction ended")
    }
    func tick(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        expireInvitation(at: now)
        refreshInputGate()
        guard ![.idle, .ended].contains(phase) else { return }
        if [.choosing, .outgoing, .incoming, .confirming].contains(phase), anchorValidity() == false {
            if let anchor { _ = emit(.cancel, anchor: anchor) }
            end("Your friend is no longer next to you")
        } else {
            retry(at: now)
        }
    }
    func receive(_ data: Data, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        expireInvitation(at: now)
        guard BoundMultiplayerFeatures.isEnabled, connected, let packet = Packet.decode(data),
              let current = context?() ?? (packet.action == .request ? nil:anchor),
              packet.sender == current.peerSession, packet.receiver == current.localSession else { return }
        if retired.contains(packet.id) {
            // A lost cancellation/decline is answered again when the other peer
            // retries. Never turn a retired request back into an invitation.
            if let action = terminalReplies[packet.id], [.request, .accept, .confirm].contains(packet.action) {
                let reply = Packet(sender: current.localSession, receiver: current.peerSession, id: packet.id,
                    activity: packet.activity, action: action, origin: packet.origin, target: packet.target)
                if let data = reply.encoded() { _ = send?(data) }
            }
            return
        }
        if anchor != nil, anchorValidity() == false { return }
        if packet.action == .request {
            if packet.id == requestID {
                guard !initiator, packet.activity == activity, let anchor,
                      packet.origin.occupiesSameTile(as: anchor.peer),
                      packet.target.occupiesSameTile(as: anchor.local) else { return }
                retry(at: now, force: true); return
            }
            guard retired.count < Self.maximumRetiredRequests,
                  (phase == .idle || phase == .choosing || phase == .ended && !requiresResultAcknowledgement),
                  (!nativeDialogueManaged || nativeDialogueReady || phase == .choosing), canPresent?() ?? true,
                  admissionIdentity == nil || admissionIdentity?() != nil else {
                // One pending invitation at a time, including crossed requests.
                let reply = Packet(sender: current.localSession, receiver: current.peerSession, id: packet.id,
                    activity: packet.activity, action: .decline, origin: packet.origin, target: packet.target)
                if let data = reply.encoded() { _ = send?(data) }
                return
            }
            guard current.peer.isFacing(current.local), packet.origin.occupiesSameTile(as: current.peer),
                  packet.target.occupiesSameTile(as: current.local) else { return }
            anchor = current; anchorIdentity = admissionIdentity?(); activity = packet.activity; requestID = packet.id; initiator = false
            invitationDeadline = now + Self.invitationLifetime
            agreementAcknowledged = false; lastTransmission = nil
            phase = .incoming; message = "Your friend wants to \(packet.activity.rawValue)"
            notify(); return
        }
        guard packet.id == requestID, packet.activity == activity, let anchor,
              packet.origin.occupiesSameTile(as: initiator ? anchor.local : anchor.peer),
              packet.target.occupiesSameTile(as: initiator ? anchor.peer : anchor.local) else { return }
        switch packet.action {
        case .accept:
            guard initiator else { return }
            if phase == .outgoing {
                invitationDeadline = nil; menuPresented = false
                phase = .agreed; message = "\(packet.activity.title) invitation accepted"
                lastTransmission = nil; notify()
            }
            retry(at: now, force: true)
        case .confirm:
            // Both peers already consented at verified adjacent anchors. The
            // initiator can now pause for its snapshot, withholding live pose.
            guard phase == .confirming, !initiator else { return }
            invitationDeadline = nil; menuPresented = false
            phase = .agreed; message = "\(packet.activity.title) invitation accepted"
            notify(); finishAgreement()
        case .decline:
            guard phase == .outgoing else { return }
            end("Your friend declined the request")
        case .cancel:
            if phase == .connecting || phase == .playing { cancelActivity?() }
            else { end("Your friend cancelled the interaction") }
        case .request: break
        }
    }
    private func retry(at now: TimeInterval, force: Bool = false) {
        guard connected, let anchor, force || (lastTransmission.map({ now - $0 >= 1 }) ?? true) else { return }
        let action: Packet.Action
        switch phase {
        case .outgoing, .confirming:
            guard anchorValidity() == true else { return }
            action = phase == .outgoing ? .request : .accept
        case .agreed, .connecting, .playing:
            // A new authenticated presence epoch can arrive after consent but
            // before the native window has finished closing.
            if phase == .agreed, anchorValidity() == false {
                _ = emit(.cancel, anchor: anchor)
                end("Your friend is no longer next to you"); return
            }
            if phase == .agreed, needsFreshAnchor { return }
            guard initiator, !agreementAcknowledged else {
                if phase == .agreed { finishAgreement() }; return
            }
            action = .confirm
        default: return
        }
        lastTransmission = now
        if emit(action, anchor: self.anchor ?? anchor), phase == .agreed { finishAgreement() }
    }
    private func finishAgreement() {
        guard connected, !needsFreshAnchor, phase == .agreed, !agreementScheduled, let activity, let requestID else { return }
        agreementScheduled = true
        let generation = agreementGeneration
        let completion={ [weak self] in
            guard let self, self.connected, self.agreementGeneration == generation,
                  self.phase == .agreed, self.requestID == requestID else { return }
            guard self.canPresent?() ?? true, self.anchorValidity() != false else {
                if let anchor = self.anchor { _ = self.emit(.cancel, anchor: anchor) }
                self.end("Interaction is no longer available"); return
            }
            self.agreed?(activity,requestID,self.initiator)
        }
        if let beforeAgreement { beforeAgreement(completion) } else { completion() }
    }
    /// nil means evidence is temporarily unavailable; it is not evidence that
    /// either player moved. Admission still requires fresh verified positions.
    private func anchorValidity() -> Bool? {
        guard BoundMultiplayerFeatures.isEnabled, let anchor else { anchorFailure="disabled/no anchor"; return false }
        guard admissionIdentity == nil || admissionIdentity?() == anchorIdentity else { anchorFailure="owner/room/run changed"; return false }
        guard connected, let current=context?() else { anchorFailure=contextDiagnostic?() ?? "waiting for connection"; return nil }
        guard current.local.occupiesSameTile(as:anchor.local),current.peer.occupiesSameTile(as:anchor.peer),current.local.isNextTo(current.peer) else { anchorFailure="tile/map changed"; return false }
        let valid=(initiator || phase == .choosing) ? current.local.isFacing(current.peer):current.peer.isFacing(current.local)
        anchorFailure=valid ? "":"facing changed"
        // Authenticated presence re-handshakes with fresh epochs after a gap.
        // Rebind only after both verified positions still match this consent.
        if valid {
            self.anchor = current
            if needsFreshAnchor { needsFreshAnchor = false; notify() }
        }
        return valid
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
        if let requestID, !retired.contains(requestID) {
            retired.append(requestID)
            if terminalReplies[requestID] == nil { terminalReplies[requestID] = .cancel }
            // Never evict a cancellation while this session can still receive
            // its delayed packets. Refuse new requests at the bounded capacity.
        }
    }
    private func expireInvitation(at now: TimeInterval) {
        guard [.outgoing, .incoming, .confirming].contains(phase),
              let invitationDeadline, now >= invitationDeadline else { return }
        if let anchor { _ = emit(.cancel, anchor: anchor) }
        menuPresented = false
        end("Invitation expired")
    }
    private func end(_ message: String, acknowledgement: Bool = false) {
        requiresResultAcknowledgement = acknowledgement || menuPresented
        menuPresented = false; invitationDeadline = nil
        agreementGeneration = UUID(); agreementScheduled = false
        retireRequest(); phase = .ended; self.message = message; notify()
    }
    private func reset() {
        retireRequest(); phase = .idle; anchor = nil; activity = nil; requestID = nil; lastTransmission = nil; message = ""
        menuPresented = false; invitationDeadline = nil; anchorIdentity = nil
        agreementGeneration = UUID(); agreementScheduled = false; agreementAcknowledged = false
        needsFreshAnchor = false
        requiresResultAcknowledgement = false
        notify()
    }
}

/// Both the app receiver and emulator receiver see the same filtered input.
/// The core ignores this app-only namespace, so interacting cannot also press A
/// on an underlying NPC, sign or door. Mapping lookups have no UI side effects.
enum BoundFriendWorldInput: String, Input {
    case interact, blockedA, blocked, socialBack
    var type: InputType { .controller(GameControllerInputType("com.bound.friend-world")) }
}
final class BoundFriendWorldInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available = false
    private var blocked = false
    private var socialAvailable=false,socialBlocked=false
    func updateSocial(available:Bool,blocked:Bool) {lock.lock();socialAvailable=available;socialBlocked=blocked;lock.unlock()}
    func update(available: Bool, blocked: Bool) {
        lock.lock(); self.available = available; self.blocked = blocked; lock.unlock()
    }
    func filter(_ input: Input) -> Input {
        lock.lock(); let available = available || socialAvailable, blocked = blocked, socialBlocked=socialBlocked; lock.unlock()
        // Preserve app shortcuts and the native pause/menu control.
        if ActionInput(input: input) != nil || StandardGameControllerInput(input: input) == .menu { return input }
        if socialBlocked {
            if Self.isA(input){return BoundFriendWorldInput.blockedA}
            if StandardGameControllerInput(input:input) == .b || (input.type == .game(.gba) && input.stringValue=="b") {return BoundFriendWorldInput.socialBack}
            return BoundFriendWorldInput.blocked
        }
        if blocked { return Self.isA(input) ? BoundFriendWorldInput.blockedA : BoundFriendWorldInput.blocked }
        if available && Self.isA(input) { return BoundFriendWorldInput.interact }
        return input
    }
    static func isA(_ input: Input) -> Bool {
        StandardGameControllerInput(input: input) == .a || (input.type == .game(.gba) && input.stringValue == "a")
    }
}
