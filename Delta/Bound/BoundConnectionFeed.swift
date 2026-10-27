import Foundation
import Combine

/// Recent connection transitions only. No frames, tokens, addresses or remote
/// error text are retained, and hiding the companion does not reset this owner.
@MainActor
final class BoundConnectionFeed: ObservableObject {
    enum Kind: String, CaseIterable {
        case connecting, connected, connectionLost, retrying, reconnecting, reconnected
        case friendJoined, friendConnectionLost, friendReconnected, friendDisconnected
        case disconnected, manuallyDisconnected, sessionChanged, connectionUnavailable
        case backgrounded, foregrounded, suspended, resumed

        var title: String {
            switch self {
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .connectionLost: return "Connection lost"
            case .retrying: return "Retrying connection"
            case .reconnecting: return "Reconnecting"
            case .reconnected: return "Reconnected"
            case .friendJoined: return "Friend joined"
            case .friendConnectionLost: return "Friend connection lost"
            case .friendReconnected: return "Friend reconnected"
            case .friendDisconnected: return "Friend left multiplayer"
            case .disconnected: return "Disconnected"
            case .manuallyDisconnected: return "Disconnected by you"
            case .sessionChanged: return "Connection changed"
            case .connectionUnavailable: return "Connection unavailable"
            case .backgrounded: return "Paused in background"
            case .foregrounded: return "Returned to foreground"
            case .suspended: return "Connection paused"
            case .resumed: return "Connection resumed"
            }
        }
        var symbolName: String {
            switch self {
            case .connecting, .retrying, .reconnecting: return "arrow.triangle.2.circlepath"
            case .connected, .reconnected: return "wifi"
            case .friendJoined, .friendReconnected: return "person.fill.checkmark"
            case .friendConnectionLost, .friendDisconnected: return "person.fill.xmark"
            case .backgrounded, .suspended: return "pause.circle"
            case .foregrounded, .resumed: return "play.circle"
            case .connectionLost, .disconnected, .manuallyDisconnected, .sessionChanged, .connectionUnavailable: return "wifi.slash"
            }
        }
    }
    enum Service: String { case multiplayer = "Multiplayer", screenShare = "Screen Share" }
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let timestamp: Date
        let kind: Kind
        let username: String?
        let service: Service
        var title: String {
            let name = username ?? "Friend"
            let event: String
            switch kind {
            case .connecting: event = "Connecting to \(name)"
            case .connected: event = "Connection ready for \(name)"
            case .reconnected: event = "Connection restored for \(name)"
            case .friendJoined: event = "\(name) connected"
            case .friendReconnected: event = "\(name) reconnected"
            case .friendDisconnected: event = "\(name) disconnected"
            case .friendConnectionLost: event = "\(name) connection lost"
            case .manuallyDisconnected: event = "Disconnected from \(name) by you"
            case .disconnected, .sessionChanged: event = "Disconnected from \(name)"
            default: event = "\(name): \(kind.title)"
            }
            return event + " · " + service.rawValue
        }
        var symbolName: String { kind.symbolName }
    }
    enum DisconnectReason { case stopped, manual, sessionChanged, unavailable }
    private enum Phase { case idle, connecting, connected, reconnecting, backgrounded, suspended, stopped }
    private enum FriendState { case absent, present, interrupted }

    @Published private(set) var entries: [Entry] = []
    // Snapshot identity into each event before a room is cleared or replaced.
    var username: String?
    var service: Service = .multiplayer
    var onEntry: ((Entry) -> Void)?
    private let now: () -> Date
    private let capacity: Int
    private var phase: Phase = .idle
    private var hasConnected = false
    private var friend: FriendState = .absent
    private var recordedWithdrawal = false
    private var lastWithdrawalEpoch: UUID?

    init(capacity: Int = 200, now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, min(capacity, 200))
        self.now = now
    }

    func record(_ kind: Kind) {
        let entry = Entry(id: UUID(), timestamp: now(), kind: kind, username: username, service: service)
        append(entry)
        onEntry?(entry)
    }

    func append(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    func clear() { entries.removeAll(keepingCapacity: true) }

    func beginConnection(resuming: Bool = false) {
        guard phase != .connected, phase != .connecting, phase != .reconnecting else { return }
        phase = resuming ? .reconnecting : .connecting
        record(resuming ? (hasConnected ? .reconnecting : .retrying) : .connecting)
    }

    func connected() {
        guard phase != .connected else { return }
        let recovered = hasConnected
        hasConnected = true
        phase = .connected
        record(recovered ? .reconnected : .connected)
    }

    func recovering() {
        guard phase != .reconnecting else { return }
        if phase == .connected { record(.connectionLost) }
        else if phase == .connecting { record(.connectionUnavailable) }
        if friend == .present { friend = .interrupted }
        phase = .reconnecting
        record(hasConnected ? .reconnecting : .retrying)
    }

    func friendJoined() {
        guard phase == .connected, friend != .present else { return }
        let recovered = friend == .interrupted
        friend = .present
        recordedWithdrawal = false; lastWithdrawalEpoch = nil
        record(recovered ? .friendReconnected : .friendJoined)
    }

    func friendUnavailable() {
        guard phase == .connected, friend == .present else { return }
        friend = .interrupted
        record(.friendConnectionLost)
    }

    func friendDisconnected(epoch: UUID? = nil) {
        guard phase == .connected, !recordedWithdrawal || lastWithdrawalEpoch != epoch else { return }
        // Withdrawing multiplayer does not leave the account/video roster.
        // Keep that state independent so a later actual roster loss is visible.
        recordedWithdrawal = true; lastWithdrawalEpoch = epoch
        record(.friendDisconnected)
    }

    func backgrounded(appInBackground: Bool = true) {
        let target: Phase = appInBackground ? .backgrounded : .suspended
        guard phase != .idle, phase != .stopped, phase != target else { return }
        if friend == .present { friend = .interrupted }
        phase = target
        record(appInBackground ? .backgrounded : .suspended)
    }

    func foregrounded() {
        guard phase == .backgrounded || phase == .suspended else { return }
        record(phase == .backgrounded ? .foregrounded : .resumed)
        beginConnection(resuming: true)
    }

    func disconnect(_ reason: DisconnectReason) {
        guard phase != .idle, phase != .stopped else { return }
        phase = .stopped
        hasConnected = false
        friend = .absent
        recordedWithdrawal = false; lastWithdrawalEpoch = nil
        switch reason {
        case .stopped: record(.disconnected)
        case .manual: record(.manuallyDisconnected)
        case .sessionChanged: record(.sessionChanged)
        case .unavailable: record(.connectionUnavailable)
        }
    }
}
