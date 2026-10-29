import Foundation

/// Owns automatic checkpoint upload admission, confirmation and retry timing.
/// Native capture and journal ordering stay with the coordinator. A detached
/// upload may settle its captured activity, but cannot update a new execution.
@MainActor
final class BoundServerCheckpointUpload {
    enum Destination {
        case managed(makeService: @MainActor () throws -> BoundNakamaRunService,
                     isSessionCurrent: @MainActor () -> Bool,
                     settleCapturedContinuation: @MainActor () throws -> Void)
        case leased(client: BoundRunLeaseClient, deviceID: UUID)

        var isManaged: Bool {
            if case .managed = self { return true }
            return false
        }
    }
    struct Request {
        let package: BoundMultiplayerSavePackage
        let expectedHead: UUID?
        let session: AppCloudSession
        let verifiedCursor: BoundMultiplayerSharedCursor
        let destination: Destination
        let isAlreadyConfirmed: @MainActor () -> Bool
    }
    enum Failure: Equatable {
        case invalidJournal, incompatibleServer(String), conflict, transferRequired
    }
    struct Callbacks {
        let isCurrentRun: @MainActor () -> Bool
        let confirmed: @MainActor ([BoundMultiplayerSharedEvent.ID]) -> Void
        let discoverGameOver: @MainActor () async -> Bool
        let failed: @MainActor (Failure) -> Void
    }

    private let clock: @MainActor () -> TimeInterval
    private let legacyService: BoundNakamaRunService
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var retryAt: TimeInterval = 0
    var isUploading: Bool { task != nil }

    init(clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         legacyService: BoundNakamaRunService = .init()) {
        self.clock = clock
        self.legacyService = legacyService
    }
    deinit { task?.cancel() }

    /// Await only the upload currently owned by this execution. Detaching does
    /// not make a later execution wait for a previous run's background upload.
    func awaitCurrent() async { await task?.value }

    func cancel(resetRetry: Bool = false) {
        task?.cancel()
        invalidate(resetRetry: resetRetry)
    }
    func detach() { invalidate(resetRetry: true) }
    private func invalidate(resetRetry: Bool) {
        generation = UUID()
        task = nil
        if resetRetry { retryAt = 0 }
    }

    @discardableResult
    func start(_ request: Request, callbacks: Callbacks) -> Bool {
        guard task == nil, clock() >= retryAt,
              request.session.owner == request.package.payload.manifest.identity.owner else { return false }
        if request.destination.isManaged {
            do {
                // Ordinary durable events must be acknowledged by history
                // first. Acquisitions become durable atomically with this cut.
                guard try BoundServerDisconnectSave.pendingEvents(in: request.package,
                    verifiedCursor: request.verifiedCursor).allSatisfy(\.requiresNativeCheckpoint) else { return false }
            } catch {
                callbacks.failed(.invalidJournal)
                return false
            }
        }
        let operation = UUID()
        generation = operation
        let legacyService = self.legacyService
        task = Task { [weak self] in
            defer {
                if self?.generation == operation { self?.task = nil }
            }
            do {
                guard let acquisitions = try await Self.upload(request, legacyService: legacyService) else { return }
                guard !Task.isCancelled, self?.generation == operation, callbacks.isCurrentRun() else { return }
                callbacks.confirmed(acquisitions)
            } catch {
                guard let self, self.generation == operation else { return }
                self.retryAt = self.clock() + 3
                if request.destination.isManaged, case BoundNakamaRunService.Failure.incompatibleServer = error {
                    callbacks.failed(.incompatibleServer(error.localizedDescription))
                } else if request.destination.isManaged, Self.isConflict(error) {
                    if await callbacks.discoverGameOver() { return }
                    // Discovery can suspend while a new run or upload replaces
                    // this one. Neither its error nor defer may affect that run.
                    guard !Task.isCancelled, self.generation == operation else { return }
                    callbacks.failed(.conflict)
                } else if error as? BoundRunLeaseError == .transferRequired {
                    callbacks.failed(.transferRequired)
                }
            }
        }
        return true
    }

    private static func upload(_ request: Request, legacyService: BoundNakamaRunService) async throws -> [BoundMultiplayerSharedEvent.ID]? {
        try Task.checkCancellation()
        let package = request.package, session = request.session
        let identity = package.payload.manifest.identity
        let service: BoundNakamaRunService
        switch request.destination {
        case .managed(let makeService, _, _): service = try makeService()
        case .leased: service = legacyService
        }
        var acquisitions: [BoundMultiplayerSharedEvent.ID] = []
        if !request.isAlreadyConfirmed() {
            switch request.destination {
            case .managed:
                try session.credentials()
                if await service.isDebug { try await service.revalidateDebugScope() }
                else { _ = try await service.configureSaves(session: session) }
                let confirmed = try await service.uploadIndependent(package, expectedHead: request.expectedHead, session: session)
                guard confirmed.identity == identity, confirmed.save_id == identity.run,
                      confirmed.committed, !confirmed.cancelled,
                      confirmed.saves[session.owner.uuidString.lowercased()]?.receipt == package.receipt else {
                    throw BoundNakamaRunService.Failure.conflict
                }
                let events = try BoundServerDisconnectSave.pendingEvents(in: package, verifiedCursor: .init())
                    .filter(\.requiresNativeCheckpoint)
                guard events.allSatisfy({ confirmed.serverCursor.contains($0.id) }) else {
                    throw BoundNakamaRunService.Failure.unavailable
                }
                acquisitions = events.map(\.id)
            case .leased(let client, _):
                _ = try await service.uploadIndependent(package, expectedHead: request.expectedHead, session: session,
                    authorize: { _ = try await client.independentAuthority(runID: identity.run, session: session) })
            }
        }
        switch request.destination {
        case .leased(let client, let deviceID):
            if package.payload.manifest.deviceOwner == deviceID {
                _ = try await client.publishIndependentCheckpoint(package: package, session: session)
            }
        case .managed(_, let isSessionCurrent, let settle):
            // A detach retires presentation ownership, not an authenticated
            // confirmation of these exact bytes. Settle only the captured token;
            // its ticket/claimant checks protect any newer activity claim.
            guard !Task.isCancelled, isSessionCurrent() else { return nil }
            try settle()
        }
        return acquisitions
    }

    private static func isConflict(_ error: Error) -> Bool {
        if case BoundNakamaRunService.Failure.conflict = error { return true }
        if case BoundMultiplayerSaveStore.Failure.conflict = error { return true }
        if case BoundMultiplayerSaveStore.Failure.ownerMismatch = error { return true }
        return false
    }
}
