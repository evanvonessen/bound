import Foundation

/// A value-only stale-callback fence. Each owner keeps its own instance and
/// its existing lock/actor; rotation performs no cancellation or scheduling.
struct BoundSDKGeneration: Sendable {
    struct Token: Equatable, Sendable {
        private let value = UUID()
        init() {}
    }
    private(set) var token: Token

    init(token: Token = Token()) { self.token = token }
    mutating func replace(with token: Token) { self.token = token }
    mutating func invalidate() { token = Token() }
    func admits(_ token: Token) -> Bool { self.token == token }
}

/// The existing one-second exponential retry, capped at thirty seconds.
/// Callers retain attempt counting, cancellation and retry eligibility policy.
enum BoundSDKRetryDelay {
    static func seconds(attempt: Int) -> TimeInterval {
        min(30.0, pow(2.0, Double(min(attempt - 1, 5))))
    }
}
