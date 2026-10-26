import Foundation
import UIKit

/// Distinguishes the synchronous save performed by an owned capture's pause
/// from a native/manual save request. Never hold this lock while entering a core.
final class BoundServerSaveRequestGate: @unchecked Sendable {
    private final class WeakGate {
        weak var value: BoundServerSaveRequestGate?
        init(_ value: BoundServerSaveRequestGate) { self.value = value }
    }
    private static let lock = NSLock()
    private static var bindings: [ObjectIdentifier: WeakGate] = [:]
    private weak var core: AnyObject?
    private let key: ObjectIdentifier
    private var valid = true
    private var captureThreads: [ObjectIdentifier: Int] = [:]

    private init(core: AnyObject) { self.core = core; key = ObjectIdentifier(core) }
    static func bind(core: AnyObject) -> BoundServerSaveRequestGate {
        lock.lock(); defer { lock.unlock() }
        bindings = bindings.filter { $0.value.value?.core != nil }
        let gate = BoundServerSaveRequestGate(core: core)
        bindings[gate.key]?.value?.valid = false
        bindings[gate.key] = WeakGate(gate)
        return gate
    }
    func invalidate() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        valid = false
        if Self.bindings[key]?.value === self { Self.bindings.removeValue(forKey: key) }
    }
    private func matches(_ source: AnyObject) -> Bool {
        valid && core === source && Self.bindings[key]?.value === self
    }
    /// Evaluate in saveHandler, before a deferred MainActor request can outlive
    /// the pause scope. Other threads' real native saves remain requests.
    func acceptsCallback(from source: AnyObject) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return matches(source) && captureThreads[ObjectIdentifier(Thread.current), default: 0] == 0
    }
    /// Recheck after an asynchronous hop: even a same-core rebind retires old
    /// queued callbacks, and object-address reuse cannot revive this binding.
    func isCurrent(core source: AnyObject) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return matches(source)
    }
    static func withCapturePause<T>(core: AnyObject, _ body: () throws -> T) rethrows -> T {
        let thread = ObjectIdentifier(Thread.current), key = ObjectIdentifier(core)
        lock.lock()
        let gate: BoundServerSaveRequestGate?
        if let current = bindings[key]?.value, current.matches(core) { gate = current }
        else { gate = nil }
        if let gate { gate.captureThreads[thread, default: 0] += 1 }
        lock.unlock()
        defer {
            lock.lock()
            if let gate {
                let depth = gate.captureThreads[thread, default: 0] - 1
                if depth == 0 { gate.captureThreads.removeValue(forKey: thread) }
                else { gate.captureThreads[thread] = depth }
            }
            lock.unlock()
        }
        return try body()
    }
}

/// Owns the paused source until all previously admitted work has drained and
/// one immutable final package has been handed to the disconnect uploader.
/// A failed preparation retains its work and never grants detach permission.
@MainActor
final class BoundServerFinalSaveBoundary {
    enum Phase: Equatable { case idle, draining, captured, failed }
    enum Failure: LocalizedError {
        case backgroundExpired, backgroundUnavailable
        var errorDescription: String? { "Final save preparation was interrupted. Retry before closing this run." }
    }
    typealias Lifetime = (@escaping @MainActor () -> Void) throws -> (@MainActor () -> Void)
    private struct Work {
        let drainRequired: Bool
        let drain: @MainActor () async throws -> Void
        let capture: @MainActor () throws -> Void
        let failed: @MainActor (Error) -> Void
    }
    private let lifetime: Lifetime
    private var work: Work?
    private var generation = UUID()
    private var endLifetime: (@MainActor () -> Void)?
    private(set) var task: Task<Void, Never>?
    private(set) var phase: Phase = .idle
    private(set) var failure: Error?
    var ownsSource: Bool { phase != .idle }
    var captured: Bool { phase == .captured }

    /// The source capture retains its execution token across asynchronous
    /// drain/upload. Publish a destination token only after that source settles.
    static func nextSelection(after source: UUID, current: @MainActor () -> UUID,
                              settle: @MainActor (UUID) async throws -> Void) async throws -> UUID {
        try await settle(source)
        try Task.checkCancellation()
        guard current() == source else { throw CancellationError() }
        return UUID()
    }

    init(lifetime: Lifetime? = nil) {
        self.lifetime = lifetime ?? Self.backgroundLifetime
    }
    deinit {
        task?.cancel()
        let finish = endLifetime
        BoundMainActorDisposal.enqueue { finish?() }
    }
    private static func backgroundLifetime(expired: @escaping @MainActor () -> Void) throws -> (@MainActor () -> Void) {
        let token = UIApplication.shared.beginBackgroundTask(withName: "Bound final save preparation") {
            Task { @MainActor in expired() }
        }
        guard token != .invalid else { throw Failure.backgroundUnavailable }
        return { UIApplication.shared.endBackgroundTask(token) }
    }
    @discardableResult
    func begin(drainRequired: Bool, drain: @escaping @MainActor () async throws -> Void,
               capture: @escaping @MainActor () throws -> Void,
               failed: @escaping @MainActor (Error) -> Void) -> Bool {
        guard !ownsSource else { return captured }
        work = .init(drainRequired: drainRequired, drain: drain, capture: capture, failed: failed)
        launch()
        return captured
    }
    @discardableResult
    func retry() -> Bool {
        guard phase == .failed, work != nil else { return captured }
        launch()
        return captured
    }
    /// Call only after the frozen uploader has completed or an explicit
    /// authorized discard/terminal transition. A newer execution gets no work
    /// or late completion from the prior generation.
    func release() {
        generation = UUID(); task?.cancel(); task = nil
        let finish = endLifetime; endLifetime = nil; finish?()
        work = nil; failure = nil; phase = .idle
    }
    private func launch() {
        guard let work else { return }
        let token = UUID(); generation = token
        phase = .draining; failure = nil
        do {
            let finish = try lifetime { [weak self] in
                guard let self, self.generation == token, self.phase == .draining else { return }
                self.fail(Failure.backgroundExpired, token: token)
            }
            // A lifetime provider may report expiration during acquisition.
            // Do not capture after that failure or leak its returned handle.
            guard generation == token, phase == .draining else { finish(); return }
            endLifetime = finish
            if !work.drainRequired {
                try work.capture()
                finishCapture(token: token)
                return
            }
            task = Task { [weak self] in
                do {
                    try await work.drain()
                    try Task.checkCancellation()
                    guard let self, self.generation == token, self.phase == .draining else { return }
                    try work.capture()
                    self.finishCapture(token: token)
                } catch { self?.fail(error, token: token) }
            }
        } catch { fail(error, token: token) }
    }
    private func finishCapture(token: UUID) {
        guard generation == token, phase == .draining else { return }
        phase = .captured; task = nil; failure = nil
        // The capture closure has already started the uploader's own lifetime.
        let finish = endLifetime; endLifetime = nil; finish?()
        work = nil
    }
    private func fail(_ error: Error, token: UUID) {
        guard generation == token, phase == .draining else { return }
        phase = .failed; failure = error
        task?.cancel(); task = nil
        let finish = endLifetime; endLifetime = nil; finish?()
        work?.failed(error)
    }
}
