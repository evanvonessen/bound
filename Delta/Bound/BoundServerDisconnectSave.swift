import Foundation
import UIKit

/// Owns the last in-memory checkpoint after the game coordinator has detached.
/// No save bytes or upload journal are written to disk.
enum BoundServerDisconnectSave {
    static let didFinish = Notification.Name("BoundServerDisconnectSaveDidFinish")

    private struct Outcome {
        let attempt: UInt64
        let gameID: String
        let owner: UUID
        var message: String?
    }
    @MainActor private static var outcomes: [UUID: Outcome] = [:]
    @MainActor private static var attemptSequence: UInt64 = 0

    @MainActor static func failureMessage(run: UUID) -> String? { outcomes[run]?.message }
    @MainActor static func failureMessage(gameID: String, owner: UUID) -> String? {
        outcomes.values.filter { $0.gameID == gameID && $0.owner == owner && $0.message != nil }
            .max { $0.attempt < $1.attempt }?.message
    }
    /// Only an explicit decision to discard unsaved progress acknowledges an
    /// error. It does not produce a successful save notification.
    @MainActor static func acknowledgeFailure(run: UUID) { outcomes[run]?.message = nil }

    @MainActor static func nextAttempt() -> UInt64 {
        attemptSequence += 1
        return attemptSequence
    }
    @discardableResult
    @MainActor static func rememberOutcome(identity: BoundMultiplayerRunIdentity, attempt: UInt64, failure: String?) -> Bool {
        guard outcomes[identity.run].map({ $0.attempt <= attempt }) ?? true else { return false }
        outcomes[identity.run] = .init(attempt: attempt, gameID: identity.gameID, owner: identity.owner, message: failure)
        if outcomes.count > 32, let oldest = outcomes.min(by: { $0.value.attempt < $1.value.attempt })?.key {
            outcomes.removeValue(forKey: oldest)
        }
        return true
    }

    /// Notifications carry runID, ownerID, gameID, status (saved/failed), and
    /// message. A successful result also carries its confirmed checkpointID.
    @MainActor
    static func enqueue(package: BoundMultiplayerSavePackage, previous: Task<Void, Never>?,
                        expectedHead: UUID?, pendingHead: UUID?, session: AppCloudSession,
                        verifiedCursor: BoundMultiplayerSharedCursor = .init(),
                        service: BoundNakamaRunService = .init(),
                        onConfirmed: (@MainActor (UUID) throws -> Void)? = nil) -> Task<Void, Never> {
        let lifetime = Lifetime(identity: package.payload.manifest.identity, previous: previous, attempt: nextAttempt())
        lifetime.begin()
        let task = Task { @MainActor in
            guard !lifetime.finished else { return }
            do {
                if let previous { await previous.value }
                try Task.checkCancellation()
                let checkpoint = try await drain(package: package, expectedHead: expectedHead,
                    pendingHead: pendingHead, session: session, verifiedCursor: verifiedCursor, service: service)
                try Task.checkCancellation()
                // Includes server-confirmed retries of a previously sealed
                // package. The caller settles only the matching activity claim.
                try onConfirmed?(checkpoint)
                lifetime.finish(status: "saved", message: "Saved to server.", checkpoint: checkpoint)
            } catch {
                let message: String
                if error is CancellationError {
                    message = "Saving was interrupted. Reopen the last confirmed server checkpoint."
                } else if isConflict(error) {
                    message = "The server save changed on another device. Reopen its latest checkpoint."
                } else {
                    message = "Disconnect save was not confirmed. Reopen the last server checkpoint."
                }
                lifetime.finish(status: "failed", message: message)
            }
            lifetime.task = nil
        }
        lifetime.task = task
        return task
    }

    private static func drain(package original: BoundMultiplayerSavePackage, expectedHead: UUID?, pendingHead: UUID?,
                              session: AppCloudSession, verifiedCursor: BoundMultiplayerSharedCursor,
                              service: BoundNakamaRunService) async throws -> UUID {
        let identity = original.payload.manifest.identity
        guard session.owner == identity.owner else { throw BoundNakamaRunService.Failure.conflict }
        let ownEvents = try pendingEvents(in: original, verifiedCursor: verifiedCursor)
        var offset = 0
        var candidate = original
        var candidates = [original.payload.checkpoint: original.receipt]
        for attempt in 0..<3 {
            do {
                try Task.checkCancellation(); try session.credentials()
                _ = try await service.configureSaves(session: session)
                var state = try await service.getSave(identity.run)
                try validate(state, identity: identity, expectedHead: expectedHead, pendingHead: pendingHead, candidates: candidates)
                while offset < ownEvents.count {
                    try Task.checkCancellation()
                    let batch = try eventBatch(Array(ownEvents[offset..<min(offset + 16, ownEvents.count)]))
                    // Only the prior locally verified cursor can skip an event.
                    // A fresh GET cursor cannot prove identical payload bytes.
                    state = try await service.sharedEvents(identity: identity, events: batch, cursor: .init())
                    try validate(state, identity: identity, expectedHead: expectedHead, pendingHead: pendingHead, candidates: candidates)
                    guard batch.allSatisfy({ state.serverCursor.contains($0.id) }) else { throw BoundNakamaRunService.Failure.unavailable }
                    offset += batch.count
                }
                try Task.checkCancellation()
                state = try await service.getSave(identity.run)
                let actual = try validate(state, identity: identity, expectedHead: expectedHead, pendingHead: pendingHead, candidates: candidates)
                if let actual, candidates[actual] != nil { return actual }
                if candidate.payload.predecessor != actual {
                    candidate = try rebased(original, predecessor: actual)
                    candidates[candidate.payload.checkpoint] = candidate.receipt
                }
                let confirmed = try await service.uploadIndependent(candidate, expectedHead: actual, session: session)
                let sealed = try validate(confirmed, identity: identity, expectedHead: expectedHead, pendingHead: pendingHead, candidates: candidates)
                guard sealed == candidate.payload.checkpoint else { throw BoundNakamaRunService.Failure.conflict }
                return candidate.payload.checkpoint
            } catch {
                guard attempt < 2, retryable(error), !Task.isCancelled else { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
            }
        }
        throw BoundNakamaRunService.Failure.unavailable
    }

    @discardableResult
    private static func validate(_ state: BoundNakamaRunService.IndependentState, identity: BoundMultiplayerRunIdentity,
                                 expectedHead: UUID?, pendingHead: UUID?, candidates: [UUID: BoundMultiplayerCheckpointReceipt]) throws -> UUID? {
        guard state.version == 2, state.save_id == identity.run, state.committed, !state.cancelled,
              state.identity == identity else { throw BoundNakamaRunService.Failure.conflict }
        let saved = state.saves[identity.owner.uuidString.lowercased()]
        let head = saved?.receipt.checkpoint
        guard permits(head: head, expectedHead: expectedHead, pendingHead: pendingHead, checkpoints: Set(candidates.keys)) else {
            throw BoundNakamaRunService.Failure.conflict
        }
        if let head, let candidate = candidates[head], saved?.receipt != candidate { throw BoundNakamaRunService.Failure.conflict }
        return head
    }

    static func permits(head: UUID?, expectedHead: UUID?, pendingHead: UUID?, checkpoints: Set<UUID>) -> Bool {
        guard let head else { return expectedHead == nil }
        return head == expectedHead || head == pendingHead || checkpoints.contains(head)
    }

    /// Changing ancestry changes immutable bytes, so it always gets a new
    /// checkpoint ID. The original run ID and frozen game contents are retained.
    static func rebased(_ original: BoundMultiplayerSavePackage, predecessor: UUID?) throws -> BoundMultiplayerSavePackage {
        guard predecessor != original.payload.checkpoint else { throw BoundNakamaRunService.Failure.conflict }
        if original.payload.predecessor == predecessor { return original }
        var result = original
        result.payload.predecessor = predecessor; result.payload.checkpoint = UUID()
        result.receipt.checkpoint = result.payload.checkpoint
        result.receipt.payloadSHA256 = BoundMultiplayerSaveStore.hash(try BoundMultiplayerSaveStore.encode(result.payload))
        result.partnerReceipt = nil
        return result
    }

    static func pendingEvents(in package: BoundMultiplayerSavePackage,
                              verifiedCursor: BoundMultiplayerSharedCursor) throws -> [BoundMultiplayerSharedEvent] {
        let payload = package.payload, identity = payload.manifest.identity, receipt = package.receipt
        guard payload.version == 2, identity.valid, receipt.run == identity.run, receipt.owner == identity.owner,
              receipt.checkpoint == payload.checkpoint, receipt.sharedEventDigest == payload.sharedEventDigest,
              receipt.payloadSHA256 == BoundMultiplayerSaveStore.hash(try BoundMultiplayerSaveStore.encode(payload)),
              let blob = payload.files["shared-events.json"], BoundMultiplayerSaveStore.hash(blob.data) == blob.sha256 else {
            throw BoundMultiplayerSaveStore.Failure.corrupt
        }
        let journal = try JSONDecoder().decode(BoundMultiplayerSharedJournal.self, from: blob.data)
        guard journal.version == 1, journal.run == identity.run, journal.owner == identity.owner,
              journal.partner == identity.partner, journal.events.count <= 100_000,
              Set(journal.events.map(\.id)).count == journal.events.count,
              journal.events.allSatisfy({ $0.run == identity.run && [identity.owner, identity.partner].contains($0.id.origin) && $0.id.sequence > 0 }) else {
            throw BoundMultiplayerSaveStore.Failure.corrupt
        }
        return journal.events.filter { $0.id.origin == identity.owner && !verifiedCursor.contains($0.id) }
            .sorted { $0.id.sequence < $1.id.sequence }
    }

    static func eventBatch(_ events: [BoundMultiplayerSharedEvent]) throws -> [BoundMultiplayerSharedEvent] {
        var batch: [BoundMultiplayerSharedEvent] = []
        for event in events.prefix(16) {
            let proposed = batch + [event]
            guard try BoundMultiplayerSaveStore.encode(proposed).count <= 14_000 else { break }
            batch = proposed
        }
        guard !batch.isEmpty else { throw BoundNakamaRunService.Failure.tooLarge }
        return batch
    }

    private static func isConflict(_ error: Error) -> Bool {
        if case BoundNakamaRunService.Failure.conflict = error { return true }
        if case BoundMultiplayerSaveStore.Failure.conflict = error { return true }
        return false
    }
    private static func retryable(_ error: Error) -> Bool {
        if case BoundNakamaRunService.Failure.unavailable = error { return true }
        if let error = error as? FriendSharingTokenError { return error.retryable }
        guard let url = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet].contains(url.code)
    }

    @MainActor
    private final class Lifetime {
        let identity: BoundMultiplayerRunIdentity
        let previous: Task<Void, Never>?
        let attempt: UInt64
        var task: Task<Void, Never>?
        var background: UIBackgroundTaskIdentifier = .invalid
        var finished = false
        init(identity: BoundMultiplayerRunIdentity, previous: Task<Void, Never>?, attempt: UInt64) {
            self.identity = identity; self.previous = previous; self.attempt = attempt
        }
        func begin() {
            background = UIApplication.shared.beginBackgroundTask(withName: "Bound disconnect save") { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.task?.cancel(); self.previous?.cancel()
                    self.finish(status: "failed", message: "Saving was interrupted. Reopen the last confirmed server checkpoint.")
                }
            }
        }
        func finish(status: String, message: String, checkpoint: UUID? = nil) {
            guard !finished else { return }
            finished = true
            if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
            guard BoundServerDisconnectSave.rememberOutcome(identity: identity, attempt: attempt, failure: status == "saved" ? nil : message) else { return }
            var info: [String: Any] = ["runID": identity.run, "ownerID": identity.owner, "gameID": identity.gameID,
                                       "status": status, "message": message]
            if let checkpoint { info["checkpointID"] = checkpoint }
            NotificationCenter.default.post(name: BoundServerDisconnectSave.didFinish, object: nil, userInfo: info)
        }
    }
}
