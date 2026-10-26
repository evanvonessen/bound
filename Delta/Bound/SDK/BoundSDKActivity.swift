import Foundation

/// A deferred optional action counts only connected waiting time. The adapter
/// supplies native admission readiness and invalidates actions on context loss.
struct BoundSDKDeferredAction<Action> {
    private(set) var command: Action?
    private var observedAt: TimeInterval = 0
    private var connectedElapsed: TimeInterval = 0
    private var wasConnected = false
    mutating func enqueue(_ command: Action, at now: TimeInterval) {
        self.command = command; observedAt = now; connectedElapsed = 0; wasConnected = false
    }
    mutating func clear() { command = nil; connectedElapsed = 0; wasConnected = false }
    mutating func ready(permitted: Bool, connected: Bool, at now: TimeInterval) -> Action? {
        if connected && wasConnected { connectedElapsed += max(0, now - observedAt) }
        observedAt = now; wasConnected = connected
        if connectedElapsed >= 15 { clear() }
        guard connected, permitted else { return nil }
        return command
    }
}

/// Cancellation cannot discard a durable prepare. The persistence owner decides
/// whether such evidence exists; unknown/read-failed evidence remains durable.
struct BoundSDKCheckpointCancellation: Sendable {
    enum Action: Equatable, Sendable { case wait, request, acknowledge, finish, recover }
    static let timeout: TimeInterval = 8
    private(set) var requestedAt: TimeInterval?
    mutating func request(at now: TimeInterval, durable: Bool) -> Action {
        guard !durable else { return .recover }
        if requestedAt == nil { requestedAt = now }
        return .request
    }
    func receive(acknowledgement: Bool, durable: Bool) -> Action {
        guard !durable else { return .recover }
        if acknowledgement { return requestedAt == nil ? .wait : .finish }
        return .acknowledge
    }
    func action(at now: TimeInterval, startedAt: TimeInterval, localSafe: Bool,
                peerSafe: Bool?, durable: Bool) -> Action {
        if let requestedAt {
            return durable || now - requestedAt >= Self.timeout ? .recover : .wait
        }
        if durable { return now - startedAt >= 30 ? .recover : .wait }
        return !localSafe || peerSafe == false || now - startedAt >= Self.timeout ? .request : .wait
    }
}
