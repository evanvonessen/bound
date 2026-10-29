import XCTest
import UIKit
import CoreData
import ObjectiveC
import zlib
@preconcurrency import DeltaCore
@testable import Delta
@testable import class Delta.Game
@testable import class Delta.GameViewController

/// Delivery-only faults for ordinary saves. Requests retain their real TLS,
/// credentials, bodies and server CAS; no successful response is synthesized.
private final class LocalOrdinarySaveDelivery: URLProtocol, @unchecked Sendable {
    enum Fault: Equatable { case hold, lose }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var run: UUID?, fault: Fault?, checkpoint: UUID?
        var held: (() -> Void)?, reached = false, delivered = false
        var handled = 0, parsed = 0, acceptedSeals = 0
        var actions: [String: Int] = [:], statuses: [Int: Int] = [:]
    }
    private static let state = State()
    private static let forwarding: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    private var forwardingTask: URLSessionDataTask?
    static func arm(run: UUID, fault: Fault) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.run = run; state.fault = fault; state.checkpoint = nil
        state.reached = false; state.delivered = false
    }
    static func snapshot() -> (reached: Bool, delivered: Bool, checkpoint: UUID?) {
        state.lock.lock(); defer { state.lock.unlock() }
        return (state.reached, state.delivered, state.checkpoint)
    }
    static func diagnostics() -> [String: BoundDebugJSON] {
        state.lock.lock(); defer { state.lock.unlock() }
        return ["handled": .number(Double(state.handled)), "parsed": .number(Double(state.parsed)),
                "acceptedSeals": .number(Double(state.acceptedSeals)),
                "actions": .object(state.actions.mapValues { .number(Double($0)) }),
                "statuses": .object(Dictionary(uniqueKeysWithValues: state.statuses.map { (String($0.key), .number(Double($0.value))) }))]
    }
    static func release() {
        state.lock.lock()
        let held = state.held; state.held = nil; state.fault = nil
        state.lock.unlock()
        held?()
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.port == 58552 &&
        request.url?.path == "/v2/rpc/bound_independent_v2" &&
        URLProtocol.property(forKey: "BoundOrdinaryForwarded", in: request) == nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let forwarded = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: "BoundOrdinaryForwarded", in: forwarded)
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count >= 0, data.count + count <= 131_072 else {
                    client?.urlProtocol(self, didFailWithError: URLError(.dataLengthExceedsMaximum)); return
                }
                if count == 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            body = data; forwarded.httpBody = data
        }
        let fields = body.flatMap { try? JSONDecoder().decode(String.self, from: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let run = (fields?["save_id"] as? String).flatMap(UUID.init(uuidString:))
        let checkpoint = (fields?["checkpoint"] as? String).flatMap(UUID.init(uuidString:))
        let seal = fields?["action"] as? String == "saveSeal"
        Self.state.lock.lock()
        Self.state.handled += 1
        if let action = fields?["action"] as? String {
            Self.state.parsed += 1
            if ["create", "get", "save", "saveChunk", "saveSeal", "saveDownload", "events"].contains(action) {
                Self.state.actions[action, default: 0] += 1
            }
        }
        Self.state.lock.unlock()
        forwardingTask = Self.forwarding.dataTask(with: forwarded as URLRequest) { [self] data, response, error in
            let deliver: () -> Void = { [self] in
                if let error { client?.urlProtocol(self, didFailWithError: error); return }
                guard let response, let data else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            }
            Self.state.lock.lock()
            if let status = (response as? HTTPURLResponse)?.statusCode { Self.state.statuses[status, default: 0] += 1 }
            if seal, (response as? HTTPURLResponse)?.statusCode == 200 { Self.state.acceptedSeals += 1 }
            let selected = seal && run == Self.state.run && !Self.state.reached &&
                Self.state.fault != nil && (response as? HTTPURLResponse)?.statusCode == 200
            if selected {
                Self.state.reached = true; Self.state.checkpoint = checkpoint
                if Self.state.fault == .hold {
                    Self.state.held = {
                        Self.state.lock.lock(); Self.state.delivered = true; Self.state.lock.unlock()
                        deliver()
                    }
                    Self.state.lock.unlock(); return
                }
                Self.state.delivered = true
                Self.state.lock.unlock()
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
            }
            Self.state.lock.unlock(); deliver()
        }
        forwardingTask?.resume()
    }
    override func stopLoading() { forwardingTask?.cancel() }
}

/// Foundation's global protocol registry does not attach a custom protocol to
/// every ephemeral session. Scope the standard configuration factory in this
/// test process, before the ordinary service creates its private session. The
/// forwarding session explicitly clears protocolClasses and still validates TLS.
private final class LocalOrdinaryProtocolRegistration {
    private typealias Factory = @convention(c) (AnyObject, Selector) -> Unmanaged<URLSessionConfiguration>
    private let method: Method, original: IMP, replacement: IMP
    init() throws {
        let selector = NSSelectorFromString("ephemeralSessionConfiguration")
        guard let method = class_getClassMethod(URLSessionConfiguration.self, selector),
              method_getNumberOfArguments(method) == 2 else { throw BoundDebugFailure.unavailable }
        self.method = method; original = method_getImplementation(method)
        let factory = unsafeBitCast(original, to: Factory.self)
        let block: @convention(block) (AnyObject) -> URLSessionConfiguration = { receiver in
            let configuration = factory(receiver, selector).takeUnretainedValue()
            configuration.protocolClasses = [LocalOrdinarySaveDelivery.self] +
                (configuration.protocolClasses ?? []).filter { $0 != LocalOrdinarySaveDelivery.self }
            return configuration
        }
        replacement = imp_implementationWithBlock(block)
        let prior = method_setImplementation(method, replacement)
        guard unsafeBitCast(prior, to: UInt.self) == unsafeBitCast(original, to: UInt.self) else {
            method_setImplementation(method, prior); throw BoundDebugFailure.stale
        }
    }
    func restore() {
        if unsafeBitCast(method_getImplementation(method), to: UInt.self) == unsafeBitCast(replacement, to: UInt.self) {
            method_setImplementation(method, original)
        }
        // Keep this bounded trampoline alive until process exit; a Foundation
        // request already entering the factory may still be returning through it.
    }
}

private final class LocalOrdinaryApplicationTransitions: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredBackground = false, returnedActive = false
    func background() { lock.lock(); enteredBackground = true; lock.unlock() }
    func active() { lock.lock(); returnedActive = enteredBackground; lock.unlock() }
    func snapshot() -> (background: Bool, active: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (enteredBackground, returnedActive)
    }
}

/// A fault changes delivery only. Every accepted response still comes from the
/// task gateway, using the account's current credentials and real server CAS.
private actor LocalDebugBoundaryTransport: BoundDebugServing {
    enum Fault: Sendable, Equatable { case holdReply, loseReplyAndRecovery, holdThenLoseReply, holdBeforeSend }
    private let service = BoundDebugService()
    private var target: String?, fault: Fault?, held = false, released = false, offline = false, replyPending = false
    private var targetGeneration: Int?
    private var accepted: BoundDebugJSON?
    private var actions: [String] = []
    private var customOperations = Set<UUID>()
    private var abortedCustomOperations = Set<UUID>()
    private var lastTrace = ""

    func arm(_ action: String, fault: Fault, generation: Int? = nil) {
        target = action; self.fault = fault; held = false; released = false; replyPending = false; accepted = nil
        targetGeneration = generation
    }
    func snapshot() -> (held: Bool, accepted: BoundDebugJSON?, actions: [String], customOperations: Set<UUID>, abortedCustomOperations: Set<UUID>, replyPending: Bool) {
        (held, accepted, actions, customOperations, abortedCustomOperations, replyPending)
    }
    func release() { released = true; offline = false; target = nil }
    func request(_ body: [String: BoundDebugJSON], session: AppCloudSession) async throws -> BoundDebugJSON {
        try await request(body, session: session, timeout: 10)
    }
    func request(_ body: [String: BoundDebugJSON], session: AppCloudSession, timeout: TimeInterval) async throws -> BoundDebugJSON {
        let action = body["action"]?.string ?? "invalid"
        let diagnosticAction = action == "gameplay" ? "gameplay/" + (body["request"]?["action"]?.string ?? "invalid") : action
        actions.append(action)
        guard !offline else { throw BoundDebugFailure.timedOut }
        let selected = action == target && (targetGeneration == nil || body["generation"]?.integer == targetGeneration)
        if selected, fault == .holdBeforeSend, !held {
            held = true
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while !released, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard released else { throw BoundDebugFailure.timedOut }
        }
        let started = ProcessInfo.processInfo.systemUptime
        let response: BoundDebugJSON
        do { response = try await service.request(body, session: session, timeout: timeout) }
        catch {
            let signature = "\(diagnosticAction) failed \((error as? BoundDebugFailure)?.rawValue ?? String(reflecting: type(of: error)))"
            if signature != lastTrace { print("LOCAL_DEBUG_NATIVE_REQUEST: " + signature); lastTrace = signature }
            throw error
        }
        let state = response["operation"]?["state"]?.string ?? response["session"]?["status"]?.string ?? "accepted"
        let operation = response["operation"]?["operationID"]?.string.flatMap(UUID.init(uuidString:))?.uuidString ?? "none"
        let signature = "\(diagnosticAction) \(state) \(operation)"
        if signature != lastTrace {
            print("LOCAL_DEBUG_NATIVE_REQUEST: \(signature) seconds=\(ProcessInfo.processInfo.systemUptime - started)")
            lastTrace = signature
        }
        if response["operation"]?["kind"]?.string == "custom",
           let rawID = response["operation"]?["operationID"]?.string, let id = UUID(uuidString: rawID) {
            customOperations.insert(id)
            if response["operation"]?["state"]?.string == "aborted" { abortedCustomOperations.insert(id) }
        }
        guard selected, !held else { return response }
        held = true; accepted = response
        switch fault {
        case .loseReplyAndRecovery:
            offline = true
            throw BoundDebugFailure.timedOut
        case .holdReply, .holdThenLoseReply:
            // Respect the real caller's bounded pause budget. A test never
            // manufactures an unlimited HTTP request to make rendezvous pass.
            replyPending = true
            defer { replyPending = false }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while !released, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard released else { throw BoundDebugFailure.timedOut }
            if fault == .holdThenLoseReply { offline = true; throw BoundDebugFailure.timedOut }
            return response
        case nil, .holdBeforeSend: return response
        }
    }
}

/// A denial-only fault at the real native reader. No cartridge bytes, native
/// authority, or verification result are supplied by this test.
private final class LocalDebugStoppedFrameReadFault: @unchecked Sendable {
    private typealias Reader = @convention(c) (AnyObject, Selector) -> Unmanaged<NSData>
    struct Evidence {
        var mainReads = 0, injected = 0
        var firstPermitted = false, injectedWhilePaused = false
        var originalSecondBytes = 0
    }
    private let lock = NSLock()
    private weak var core: EmulatorCore?
    private let method: Method, original: IMP
    private var replacement: IMP?
    private var evidence = Evidence()
    private var restored = false

    @MainActor init(core: EmulatorCore) throws {
        let selector = #selector(BoundVBABattleBridge.romMultiplayerSnapshot)
        guard let method = class_getClassMethod(BoundVBABattleBridge.self, selector),
              method_getNumberOfArguments(method) == 2,
              let encoding = method_getTypeEncoding(method), String(cString: encoding).hasPrefix("@") else {
            throw BoundDebugFailure.nativeVerification
        }
        self.core = core; self.method = method; self.original = method_getImplementation(method)
        let reader = unsafeBitCast(original, to: Reader.self)
        let block: @convention(block) (AnyObject) -> NSData = { [self] receiver in
            let actual = reader(receiver, selector).takeUnretainedValue()
            guard Thread.isMainThread else { return actual }
            lock.lock(); defer { lock.unlock() }
            evidence.mainReads += 1
            if evidence.mainReads == 1 {
                evidence.firstPermitted = BoundROMRequest.decode(actual as Data)?.permitsFieldInterruption == true
            }
            if evidence.mainReads == 2 {
                evidence.injectedWhilePaused = self.core?.state == .paused
                evidence.originalSecondBytes = actual.length
                evidence.injected += 1
                return NSData()
            }
            return actual
        }
        let replacement = imp_implementationWithBlock(block)
        self.replacement = replacement
        let previous = method_setImplementation(method, replacement)
        guard Self.address(previous) == Self.address(original) else {
            method_setImplementation(method, previous)
            throw BoundDebugFailure.nativeVerification
        }
        // These two bounded test block trampolines live until process exit.
        // Removing one immediately after restoring the selector could free it
        // while an already-entered background reader is still returning.
    }
    private static func address(_ imp: IMP) -> UInt { unsafeBitCast(imp, to: UInt.self) }
    @MainActor @discardableResult func restore() -> Bool {
        if restored { return Self.address(method_getImplementation(method)) == Self.address(original) }
        guard let replacement, Self.address(method_getImplementation(method)) == Self.address(replacement) else { return false }
        method_setImplementation(method, original); restored = true
        return Self.address(method_getImplementation(method)) == Self.address(original)
    }
    func snapshot() -> Evidence { lock.lock(); defer { lock.unlock() }; return evidence }
}

private final class LocalDebugFinalReceipt: @unchecked Sendable {
    let identity: BoundMultiplayerRunIdentity
    private let lock = NSLock()
    private var checkpoint: UUID?, failed = false
    private var message: String?
    init(identity: BoundMultiplayerRunIdentity) { self.identity = identity }
    func receive(_ notification: Notification) {
        guard let values = notification.userInfo, values["runID"] as? UUID == identity.run,
              values["ownerID"] as? UUID == identity.owner, values["gameID"] as? String == identity.gameID else { return }
        lock.lock(); defer { lock.unlock() }
        failed = values["status"] as? String == "failed"
        message = values["message"] as? String
        if values["status"] as? String == "saved" { checkpoint = values["checkpointID"] as? UUID }
    }
    func read() -> (checkpoint: UUID?, failed: Bool, message: String?) {
        lock.lock(); defer { lock.unlock() }; return (checkpoint, failed, message)
    }
}

private final class LocalDebugBoundaryRenderer: GameViewControllerDelegate {
    func gameViewController(_ gameViewController: DeltaCore.GameViewController, optionsFor game: GameProtocol) -> [EmulatorCore.Option: Any] { [.metal: true] }
}

/// Candidate acceptance is separate from the production fixture registry. The
/// reviewed digest admits bytes to the same strict reader; it never supplies a
/// native verification result or changes coordinator/server authority.
@MainActor private final class LocalDebugCandidateHost: BoundDebugHost {
    let coordinator: BoundROMMultiplayerCoordinator
    let reviewedCertificates: [String: String]
    let fixtureRoot: URL
    var restoredPayloadCount = 0, recoveredInstallationCount = 0
    var restoredFrames: [UUID: UInt32] = [:], capturedFrames: [UUID: UInt32] = [:]
    var capturedUIRequests: [UUID: Data] = [:]
    var capturePausedUIRequest: (() throws -> Data)?
    private var observedCaptureOperations = Set<UUID>()
    var lastAdmission: BoundDebugAdmission?
    var recoveryObserved: (() async throws -> Void)?
    var restorePreflightObserved: ((Data, BoundDebugManifest) async throws -> Void)?
    var restoreObserved: ((Data, BoundDebugManifest) async throws -> Void)?
    var restoreFailureObserved: ((Error, Data, BoundDebugManifest, Bool) -> Void)?
    init(_ coordinator: BoundROMMultiplayerCoordinator, reviewedCertificates: [String: String], fixtureRoot: URL) {
        self.coordinator = coordinator; self.reviewedCertificates = reviewedCertificates; self.fixtureRoot = fixtureRoot
    }
    private func observed<T>(_ name: String, _ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch {
            print("LOCAL_DEBUG_NATIVE_HOST: \(name) failed \((error as? BoundDebugFailure)?.rawValue ?? String(reflecting: type(of: error)))")
            throw error
        }
    }
    func debugContext() throws -> BoundDebugHostContext { try coordinator.debugContext() }
    func preflightDebugSwitch() throws { try coordinator.preflightDebugSwitch() }
    func debugReturnReady(operation: BoundDebugOperation) async throws -> BoundDebugReturnReady { try await coordinator.debugReturnReady(operation: operation) }
    func prepareDebugTerminalTransition(proof: BoundDebugTerminalProof, manifest: BoundDebugManifest,
                                       identity: BoundMultiplayerRunIdentity) async throws -> BoundDebugBookmark {
        try await observed("terminal preparation") {
            try await coordinator.prepareDebugTerminalTransition(proof: proof, manifest: manifest, identity: identity)
        }
    }
    func debugTerminalReturnReady(operation: BoundDebugOperation, proof: BoundDebugTerminalProof,
                                  manifest: BoundDebugManifest, identity: BoundMultiplayerRunIdentity) async throws -> BoundDebugReturnReady {
        try await observed("terminal return readiness") {
            try await coordinator.debugTerminalReturnReady(operation: operation, proof: proof, manifest: manifest, identity: identity)
        }
    }
    func setDebugContinuation(_ scope: BoundDebugRealtimeScope?) { coordinator.setDebugContinuation(scope) }
    func setDebugSwitchPending(_ pending: Bool) { coordinator.setDebugSwitchPending(pending) }
    func settleForDebugSwitch() async throws -> BoundDebugBookmark { try await observed("settle") { try await coordinator.settleForDebugSwitch() } }
    func rendezvousDebugCapture(operation: BoundDebugOperation) async throws -> BoundDebugCaptureReady { try await observed("rendezvous") { try await coordinator.rendezvousDebugCapture(operation: operation) } }
    func prepareDebugPayload(operation: BoundDebugOperation, cut: BoundDebugHistoryCut?, bookmark: BoundDebugBookmark) async throws -> BoundDebugPreparedPayload {
        guard operation.source.kind == .builtin else { return try await coordinator.prepareDebugPayload(operation: operation, cut: cut, bookmark: bookmark) }
        let context = try coordinator.debugContext()
        return try BoundDebugFixtureStore.prepare(operation: operation, owner: context.session.owner, device: context.deviceID,
            bookmark: bookmark, root: fixtureRoot, reviewedCertificates: reviewedCertificates)
    }
    func restoreDebugPayload(_ payload: Data, manifest: BoundDebugManifest) async throws {
        var coordinatorSucceeded = false
        do {
            try await restorePreflightObserved?(payload, manifest)
            try await coordinator.restoreDebugPayload(payload, manifest: manifest); restoredPayloadCount += 1
            coordinatorSucceeded = true
            restoredFrames[manifest.operationID] = MultiRedAdapter.readSetupRequest()?.frame
            try await restoreObserved?(payload, manifest)
        } catch {
            print("LOCAL_DEBUG_NATIVE_HOST: restore failed \((error as? BoundDebugFailure)?.rawValue ?? String(reflecting: type(of: error))) coordinatorSucceeded=\(coordinatorSucceeded)")
            restoreFailureObserved?(error, payload, manifest, coordinatorSucceeded)
            throw error
        }
    }
    func verifyDebugRestore(manifest: BoundDebugManifest) async throws -> BoundDebugVerification { try await coordinator.verifyDebugRestore(manifest: manifest) }
    func recoverDebugInstallation(manifest: BoundDebugManifest) async throws -> BoundDebugVerification {
        recoveredInstallationCount += 1
        let proof = try await coordinator.recoverDebugInstallation(manifest: manifest)
        try await recoveryObserved?()
        return proof
    }
    func completeDebugRestore(manifest: BoundDebugManifest) async throws { try await coordinator.completeDebugRestore(manifest: manifest) }
    func finishDebugCapture(operation: BoundDebugOperation, captured: Bool) async throws {
        if captured, !observedCaptureOperations.contains(operation.operationID) {
            let raw = try capturePausedUIRequest?()
            if let frame = MultiRedAdapter.readSetupRequest()?.frame { capturedFrames[operation.operationID] = frame }
            if let raw { capturedUIRequests[operation.operationID] = raw }
            // Archive completion repeats this callback after the cut was
            // released. Never replace the first paused observation with live
            // bytes or delete it because a later publication is uncommitted.
            observedCaptureOperations.insert(operation.operationID)
        }
        try await coordinator.finishDebugCapture(operation: operation, captured: captured)
    }
    func returnFromDebug(bookmark: BoundDebugBookmark) async throws -> BoundDebugReturnVerification {
        try await observed("ordinary return restore") { try await coordinator.returnFromDebug(bookmark: bookmark) }
    }
    func verifyDebugReturn(bookmark: BoundDebugBookmark, previous: BoundDebugReturnVerification) async throws -> BoundDebugReturnVerification {
        try await observed("ordinary return verification") { try await coordinator.verifyDebugReturn(bookmark: bookmark, previous: previous) }
    }
    func setDebugAdmission(_ admission: BoundDebugAdmission?) { lastAdmission = admission; coordinator.setDebugAdmission(admission) }
}

/// One role and one VBA instance per dedicated simulator process. Inputs live
/// under Documents/DEBUGLocalQA; outputs contain receipts/hashes, never tokens.
/// Run the ordinary case first. Paired cases additionally require the reviewed
/// point-01 trust entries and the native files accepted by FixtureStore.
/// native-boundary-input.json: version=1, attemptID/creationRequestID UUIDs,
/// role=controller|buddy, scenario=ordinary|customHold|returnHold|returnVerifyLostReply|customLostReply
/// |staleOrdinarySelection|unseenPeerDeath, ordinaryRunID (required for buddy),
/// debugSessionID (same UUID in both processes), unrelatedOrdinaryRunID (stale
/// case), reviewedCandidateCertificates (the two reviewed certificate hashes).
/// The controller emits ordinary-created.json for the runner to hand to buddy.
/// No runner may infer a run by "latest", change credentials, or share a core.
@MainActor final class LocalDebugNativeBoundaryTests: XCTestCase {
    private struct Login: Decodable {
        struct Account: Decodable { let role: String; let ownerID: UUID; let email: String; let password: String }
        let endpoint: String, roomID: UUID, accounts: [Account]
    }
    private struct Input: Decodable {
        enum Scenario: String, Decodable { case ordinary, ordinaryRecovery, ordinaryTerminateAccepted, customHold, returnHold, returnVerifyLostReply, customLostReply, unseenPeerDeath, staleOrdinarySelection, customCommitLossPrepare, customCommitLossRecover, reloadBuiltin, reloadCustom, buddyLeave, controllerRevoke, partialRestorePrepare, partialRestoreRecover }
        let version: Int, attemptID: UUID, role: String, scenario: Scenario
        let creationRequestID: UUID
        let ordinaryRunID: UUID?
        let debugSessionID: UUID?
        let unrelatedOrdinaryRunID: UUID?
        /// Exact certificate.json hashes reviewed after standalone native
        /// setup/restore/audit. These are not final certification claims.
        let reviewedCandidateCertificates: [String: String]?
        /// A native-produced peer loss must be staged by the other role. This
        /// test never fabricates a loss or writes guest RAM to create one.
        let expectedPeerLossSlot: String?
        let recoveryAttemptID: UUID?
        let expectedROM: String?
        let expectedGameID: String?
        let previousReceipt: BoundMultiplayerCheckpointReceipt?
        let previousProcessID: Int32?
        let previousTerminationAttemptID: UUID?
        let restoreExperimentalPreferencePresent: Bool?
        let restoreExperimentalPreferenceEnabled: Bool?
        let exerciseOSBackground: Bool?
    }
    private struct RestartProof: Codable {
        let version: Int, processID: Int32, attemptID: UUID, recoveryAttemptID: UUID
        let ownerID: UUID, deviceID: UUID, sessionID: UUID, operationID: UUID
        let activeGeneration: Int, archiveGeneration: Int, activeManifestDigest: String
        let receipt: BoundMultiplayerCheckpointReceipt
        let stateSHA256: String, archiveStateSHA256: String, frame: UInt32, soulSHA256: String
        let ordinary: BoundDebugJSON
    }
    private struct PartialRestoreProof: Codable {
        let version: Int, processID: Int32, attemptID: UUID, recoveryAttemptID: UUID
        let ownerID: UUID, deviceID: UUID, installed: Bool
        let target: BoundDebugManifest, outgoing: BoundMultiplayerCheckpointReceipt
        let nativeIdentity: BoundMultiplayerRunIdentity, frame: UInt32, soulSHA256: String, stateSHA256: String
        let candidateSHA256: String, ordinary: BoundDebugJSON
    }
    private var owner: GameViewController?, window: UIWindow?, previousWindow: UIWindow?
    private let renderer = LocalDebugBoundaryRenderer()
    private var transport: LocalDebugBoundaryTransport?
    private var previousExperimental: Any?
    private var previousDeveloperFeatures: Any?
    private var restartDetached = false
    private var ownsAccountSession = false
    private var candidateHost: LocalDebugCandidateHost?
    private var finalReceipt: LocalDebugFinalReceipt?
    private var diagnosticOutput: URL?
    private var stage = "inputs"
    private var ordinaryProfile: BoundGameProfile?
    private var root: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DEBUGLocalQA") }

    private func trace(_ label: String) {
        stage = label
        print("LOCAL_DEBUG_NATIVE_STAGE: " + label)
        guard let output = diagnosticOutput else { return }
        // Persist before native calls that may block the actor. No account
        // credentials, capabilities, or server response bodies are included.
        let values: [String: BoundDebugJSON] = ["stage": .string(label),
            "uptime": .number(ProcessInfo.processInfo.systemUptime)]
        if let bytes = try? BoundDebugJSON.object(values).data() {
            try? bytes.write(to: output.appendingPathComponent("last-stage.json"), options: .atomic)
        }
    }

    private func wait(_ label: String, seconds: TimeInterval = 30,
                      until condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        trace("Timed out: " + label)
        throw BoundDebugFailure.timedOut
    }
    private func record(_ value: [String: BoundDebugJSON], name: String, output: URL) throws {
        let data = try BoundDebugJSON.object(value).data(limit: 524_288)
        try data.write(to: output.appendingPathComponent(name + ".json"), options: .atomic)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func invokeReadyBoundary(coordinator: BoundROMMultiplayerCoordinator, debug: BoundDebugSession,
                                     transport: LocalDebugBoundaryTransport, output: URL,
                                     action: @MainActor () async -> Void) async throws {
        let previousOperation = debug.operation?.operationID
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        var attempts = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if debug.isBusy { try await Task.sleep(for: .milliseconds(25)); continue }
            do { try coordinator.preflightDebugSwitch() }
            catch BoundDebugFailure.busy { try await Task.sleep(for: .milliseconds(25)); continue }
            attempts += 1
            await action()
            if await transport.snapshot().held { return }
            let report = try BoundDebugJSON(data: debug.exportReport())
            try record(["attempts": .number(Double(attempts)), "status": .string(debug.status.rawValue),
                        "failure": debug.failure.map { .string($0.rawValue) } ?? .null,
                        "localPhase": report["localPhase"] ?? .null], name: "boundary-action-admission", output: output)
            // A polling operation can acquire isBusy after the UI-style check
            // above. Retry only when both remote and durable local identity
            // prove that this action never left the verified starting point.
            guard debug.operation?.operationID == previousOperation, report["localPhase"]?.string == "verified" else { return }
            if let failure = debug.failure, failure != .busy { throw failure }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw BoundDebugFailure.timedOut
    }
    private func nativeRAM(_ core: EmulatorCore) throws -> Data {
        guard core.state == .paused else { throw BoundDebugFailure.busy }
        let memory = try XCTUnwrap(BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }))
        return Data(memory.workRAM) + Data(memory.internalRAM)
    }
    private func checkpointRAM(_ state: Data) throws -> Data {
        // Same bounded gzip decode used by ServerFinalSaveLifecycleTests.
        // These offsets are the pinned VBA-M v10 serialization verified by
        // BoundVBABattleBridge: IWRAM, palette, then EWRAM. No state is edited.
        guard state.count > 32, state.count <= 4 * 1024 * 1024,
              state.prefix(4) == Data("VBA ".utf8) else { throw BoundDebugFailure.incompatible }
        var stream = z_stream(), decoded = Data(count: 4 * 1024 * 1024)
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw BoundDebugFailure.storage }
        defer { inflateEnd(&stream) }
        let capacity = decoded.count
        let result = state.withUnsafeBytes { input in
            decoded.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 8))
                stream.avail_in = uInt(state.count - 8)
                stream.next_out = output.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = uInt(capacity)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.avail_in == 0, stream.total_out >= 34271 + 0x40000,
              decoded.prefix(4) == Data([10, 0, 0, 0]) else { throw BoundDebugFailure.incompatible }
        return decoded.subdata(in: 34271 ..< 34271 + 0x40000) + decoded.subdata(in: 479 ..< 479 + 0x8000)
    }
    private func pausedUIRequest(_ core: EmulatorCore) throws -> Data {
        let view = try XCTUnwrap(owner), context = try view.boundCompanionForTesting.romMultiplayer.debugContext()
        guard view.emulatorCore === core, core.state == .paused,
              context.compatibility == BoundDebugCompatibility(profile: BoundGameProfiles.current) else { throw BoundDebugFailure.stale }
        // Current-profile EWRAM 0x02000800 is exposed at 0x8800 by VBA's public
        // reader. Copy borrowed bytes immediately; odd sequence bytes remain
        // diagnostics and never confer frame credit or field permission.
        let borrowed = try XCTUnwrap(core.deltaCore.emulatorBridge.readMemory?(at: 0x8800, size: BoundSDKProtocol.UIRequest.byteSize))
        let bytes = Data([UInt8](borrowed))
        guard bytes.count == BoundSDKProtocol.UIRequest.byteSize,
              bytes.prefix(8) == Data(BoundSDKProtocol.UIRequest.prefix) else { throw BoundDebugFailure.nativeVerification }
        return bytes
    }
    private func intentStorage(_ input: Input) -> BoundDebugDiskStore {
        BoundDebugDiskStore(directory: root.appendingPathComponent("native-intents")
            .appendingPathComponent((input.recoveryAttemptID ?? input.attemptID).uuidString))
    }
    private func restartProofURL(_ input: Input) throws -> URL {
        let id = try XCTUnwrap(input.recoveryAttemptID)
        return root.appendingPathComponent("native-restart").appendingPathComponent(id.uuidString)
            .appendingPathComponent(input.role + ".json")
    }
    private func partialProofURL(_ input: Input) throws -> URL {
        root.appendingPathComponent("native-partial").appendingPathComponent(try XCTUnwrap(input.recoveryAttemptID).uuidString)
            .appendingPathComponent(input.role + ".json")
    }
    private func soulDigest() throws -> String {
        let ledger = try XCTUnwrap(owner?.boundCompanionForTesting.sharing.soulLink.probe.read().ledger)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var value = try XCTUnwrap(BoundDebugJSON(data: encoder.encode(ledger)).object)
        for key in ["dead", "partnerAcquisitions", "consumedSlots"] {
            if let values = value[key]?.array { value[key] = .array(values.sorted { ($0.string ?? "") < ($1.string ?? "") }) }
        }
        return BoundMultiplayerSaveStore.hash(try BoundDebugJSON.object(value).data())
    }
    private func scenarioBarrier(_ input: Input, phase: String, evidence: [String: BoundDebugJSON], output: URL,
                                 seconds: TimeInterval = 90) async throws {
        var values = evidence
        values.merge(["version": .number(1), "scenario": .string(input.scenario.rawValue), "phase": .string(phase),
            "sessionID": .string(try XCTUnwrap(input.debugSessionID).uuidString.lowercased()),
            "attemptID": .string(input.attemptID.uuidString.lowercased()), "role": .string(input.role),
            "processID": .number(Double(ProcessInfo.processInfo.processIdentifier))]) { _, new in new }
        try record(values, name: "phase-" + phase, output: output)
        try await wait("Both native roles must complete " + phase, seconds: seconds) {
            let url = self.root.appendingPathComponent("native-handoffs").appendingPathComponent(input.attemptID.uuidString + "-" + phase + ".json")
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) <= 4096 else { throw BoundDebugFailure.storage }
            let value = try BoundDebugJSON(data: Data(contentsOf: url), limit: 4096)
            guard value["version"]?.integer == 1, value["scenario"]?.string == input.scenario.rawValue,
                  value["phase"]?.string == phase, value["sessionID"]?.string.flatMap(UUID.init(uuidString:)) == input.debugSessionID,
                  value["attempts"]?[input.role]?.string.flatMap(UUID.init(uuidString:)) == input.attemptID else { throw BoundDebugFailure.stale }
            return true
        }
    }
    private func admissionRequest(_ sessionID: UUID, generation: Int, account: AppCloudSession) async throws -> [String: BoundDebugJSON] {
        let response = try await BoundDebugService().request(["action": .string("resume"),
            "sessionID": .string(sessionID.uuidString.lowercased())], session: account)
        return ["action": .string("admission"), "sessionID": .string(sessionID.uuidString.lowercased()),
            "membershipEpoch": .number(Double(try XCTUnwrap(response["session"]?["membershipEpoch"]?.integer))),
            "capability": .string(try XCTUnwrap(response["capability"]?.string)), "generation": .number(Double(generation))]
    }
    private func assertServerScopeDenied(_ request: [String: BoundDebugJSON], account: AppCloudSession) async throws {
        do { _ = try await BoundDebugService().request(request, session: account); XCTFail("Server accepted obsolete DEBUG scope") }
        catch let error as BoundDebugFailure {
            guard error == .rejected || error == .busy else { throw error }
        }
    }
    private func advanceNative(_ core: EmulatorCore, frames: UInt32 = 20) async throws {
        let view = try XCTUnwrap(owner), coordinator = view.boundCompanionForTesting.romMultiplayer
        let context = try coordinator.debugContext()
        func sameOwner() throws {
            guard view.emulatorCore === core, context.sameAuthority(as: try coordinator.debugContext()) else { throw BoundDebugFailure.stale }
        }
        try sameOwner()
        if core.state == .paused {
            guard view.boundCanResumeEmulation(resumingNativeActivity: false), core.resume() else { throw BoundDebugFailure.busy }
        }
        var baseline: UInt32?
        try await wait("Ordinary field execution must keep advancing", seconds: 3) {
            try sameOwner()
            guard core.state == .running, let request = MultiRedAdapter.readSetupRequest(), request.permitsFieldInterruption else { return false }
            guard let firstFrame = baseline else { baseline = request.frame; return false }
            let delta = request.frame &- firstFrame
            guard delta < 0x8000_0000 else { throw BoundDebugFailure.nativeVerification }
            return delta >= frames
        }
        try await wait("Inspection pause must retain a committed native field", seconds: 5) {
            try sameOwner()
            guard core.state == .running else { return false }
            guard MultiRedAdapter.readSetupRequest()?.permitsFieldInterruption == true else { return false }
            guard core.pause() else { throw BoundDebugFailure.busy }
            // Only this newly acquired inspection pause may be released on a
            // torn/busy stopped publication. Product-owned holds stay intact.
            if MultiRedAdapter.readSetupRequest()?.permitsFieldInterruption == true { return true }
            try sameOwner()
            guard core.state == .paused, view.boundCanResumeEmulation(resumingNativeActivity: false), core.resume() else {
                throw BoundDebugFailure.busy
            }
            return false
        }
    }
    private func archiveReloadPrerequisite(coordinator: BoundROMMultiplayerCoordinator, debug: BoundDebugSession,
                                           transport: LocalDebugBoundaryTransport, output: URL) async throws -> BoundDebugCapture {
        let context = try coordinator.debugContext(), original = try XCTUnwrap(debug.activeManifest)
        let initialOperations = await transport.snapshot().customOperations
        let initialCaptures = Set(debug.captures.map(\.id))
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        var attempts = 0, observation = 0
        var confirmedAborts = Set<UUID>(), observedOperations = Set<UUID>()
        var lastDiagnostic: [String: BoundDebugJSON]?
        func sameSource() throws {
            guard context.sameAuthority(as: try coordinator.debugContext()), debug.activeManifest == original,
                  debug.serverSession?.sessionID == original.sessionID,
                  debug.serverSession?.membershipEpoch == original.membershipEpoch,
                  debug.serverSession?.currentGeneration == original.generation,
                  debug.serverSession?.status == .active else { throw BoundDebugFailure.stale }
        }
        func diagnostic(_ event: String, response: BoundDebugJSON? = nil) throws {
            let report = try BoundDebugJSON(data: debug.exportReport())
            let values: [String: BoundDebugJSON] = ["event": .string(event), "attempts": .number(Double(attempts)),
                "operationIDs": .array(observedOperations.map { $0.uuidString.lowercased() }.sorted().map { .string($0) }),
                "confirmedAborts": .array(confirmedAborts.map { $0.uuidString.lowercased() }.sorted().map { .string($0) }),
                "sessionID": .string(original.sessionID.uuidString.lowercased()), "generation": .number(Double(original.generation)),
                "manifestDigest": .string(original.digest), "status": .string(debug.status.rawValue),
                "failure": debug.failure.map { .string($0.rawValue) } ?? .null, "localPhase": report["localPhase"] ?? .null,
                "nativeHold": .bool(coordinator.debugBlocksCoreResume), "clientBusy": .bool(debug.isBusy),
                "authenticatedOperationID": response?["operation"]?["operationID"] ?? .null,
                "authenticatedOperationState": response?["operation"]?["state"] ?? .null]
            guard values != lastDiagnostic else { return }
            observation += 1; lastDiagnostic = values
            try record(values, name: String(format: "reload-custom-prerequisite-%03d", observation), output: output)
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation(); try sameSource()
            await debug.reconcile(); await debug.refreshCaptures()
            try sameSource()
            let observed = await transport.snapshot()
            observedOperations = observed.customOperations.subtracting(initialOperations)
            guard observedOperations.count <= attempts else { throw BoundDebugFailure.stale }
            if let capture = debug.captures.first(where: { !initialCaptures.contains($0.id) }) {
                guard observedOperations.contains(capture.id), !confirmedAborts.contains(capture.id),
                      capture.operation.kind == .custom, capture.operation.source.kind == .current,
                      capture.operation.source.sourceGeneration == original.generation,
                      capture.manifest.runID == original.runID,
                      ProcessInfo.processInfo.systemUptime < deadline else { throw BoundDebugFailure.stale }
                try diagnostic("archived"); return capture
            }
            let unresolved = observedOperations.subtracting(confirmedAborts)
            guard unresolved.count <= 1 else { throw BoundDebugFailure.stale }
            if let operationID = unresolved.first {
                // A default status may already show the active baseline again.
                // Only an authenticated reply for this exact observed custom
                // operation can establish the abort that permits a new tap.
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { break }
                let response: BoundDebugJSON
                do {
                    response = try await transport.request(["action": .string("status"),
                        "sessionID": .string(original.sessionID.uuidString.lowercased()),
                        "operationID": .string(operationID.uuidString.lowercased())],
                        session: context.session, timeout: min(1, remaining))
                } catch let error as BoundDebugFailure where error == .busy || error == .timedOut {
                    try diagnostic("status-uncertain"); continue
                }
                try sameSource()
                let session = try XCTUnwrap(response["session"]).decode(BoundDebugServerSession.self)
                let operation = try XCTUnwrap(response["operation"]).decode(BoundDebugOperation.self)
                guard operation.valid(session: session), operation.operationID == operationID, operation.kind == .custom,
                      operation.source.kind == .current, operation.source.sourceGeneration == original.generation,
                      operation.runID == original.runID, operation.membershipEpoch == original.membershipEpoch,
                      session.sessionID == original.sessionID, session.membershipEpoch == original.membershipEpoch,
                      session.currentGeneration == original.generation, session.currentManifestDigest == original.digest,
                      session.status == .active else { throw BoundDebugFailure.stale }
                if operation.state == .aborted { confirmedAborts.insert(operationID) }
                try diagnostic("authenticated-status", response: response)
            }
            // No observed ID is an uncertain attempt, not permission to retry.
            // A pending/prepared/committed operation likewise only reconciles.
            let mayStart = attempts == observedOperations.count && observedOperations == confirmedAborts
            if mayStart {
                guard attempts < 3 else { try diagnostic("attempt-limit"); throw BoundDebugFailure.timedOut }
                let report = try BoundDebugJSON(data: debug.exportReport())
                if !debug.isBusy, report["localPhase"]?.string == "verified", !coordinator.debugBlocksCoreResume {
                    do { try coordinator.preflightDebugSwitch() }
                    catch BoundDebugFailure.busy {
                        try diagnostic("waiting-for-safe-boundary"); try await Task.sleep(for: .milliseconds(25)); continue
                    }
                    try sameSource()
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    attempts += 1; try diagnostic("new-user-attempt")
                    await debug.saveCustom()
                    try sameSource()
                    observedOperations = await transport.snapshot().customOperations.subtracting(initialOperations)
                    try diagnostic("action-returned")
                    continue
                }
            }
            try diagnostic("reconciling")
            try await Task.sleep(for: .milliseconds(25))
        }
        try diagnostic("deadline"); throw BoundDebugFailure.timedOut
    }
    private func exerciseReload(_ input: Input, coordinator: BoundROMMultiplayerCoordinator, debug: BoundDebugSession,
                                transport: LocalDebugBoundaryTransport, core: EmulatorCore, output: URL) async throws {
        let host = try XCTUnwrap(candidateHost), context = try coordinator.debugContext(), original = try XCTUnwrap(debug.activeManifest)
        let oldIdentity = try XCTUnwrap(BoundMultiplayerSaveStore.shared.manifest(gameID: context.compatibility.gameID)?.identity)
        let oldService = try debug.makeRunService(identity: oldIdentity)
        let oldScope = try await admissionRequest(original.sessionID, generation: original.generation, account: context.session)
        var capture: BoundDebugCapture?
        if input.scenario == .reloadCustom {
            if input.role == "controller" {
                capture = try await archiveReloadPrerequisite(coordinator: coordinator, debug: debug, transport: transport, output: output)
            } else {
                try await wait("Both owners must archive the actual custom cut", seconds: 90) {
                    await debug.reconcile(); await debug.refreshCaptures(); return !debug.captures.isEmpty
                }
                capture = try XCTUnwrap(debug.captures.first)
            }
            try await scenarioBarrier(input, phase: "archive", evidence: ["operationID": .string(capture!.id.uuidString.lowercased()),
                "generation": .number(Double(capture!.manifest.generation))], output: output)
        }
        let expected = capture?.manifest ?? original, descriptor = try XCTUnwrap(expected.owners[context.session.owner.uuidString.lowercased()])
        let expectedFrame: UInt32?, expectedUI: Data?, storedCustom: Data?
        if let capture {
            expectedFrame = host.capturedFrames[capture.id]
            expectedUI = try XCTUnwrap(host.capturedUIRequests[capture.id])
            storedCustom = try await intentStorage(input).payload(owner: context.session.owner, operation: capture.id)
            try record(["operationID": .string(capture.id.uuidString.lowercased()),
                        "rawUIBase64": .string(try XCTUnwrap(expectedUI).base64EncodedString()),
                        "decodedFrame": expectedFrame.map { .number(Double($0)) } ?? .null,
                        "rawBytesAreDiagnosticOnly": .bool(true)], name: "custom-archive-ui", output: output)
        } else {
            expectedFrame = try XCTUnwrap(host.restoredFrames[original.operationID]); expectedUI = nil; storedCustom = nil
        }
        let nextGeneration = expected.generation + 1
        try await advanceNative(core)
        let progressedFrame = try XCTUnwrap(MultiRedAdapter.readSetupRequest()?.frame)
        if let expectedFrame { XCTAssertNotEqual(progressedFrame, expectedFrame) }
        var observed = false
        host.restoreObserved = { bytes, manifest in
            guard manifest.generation == nextGeneration else { throw BoundDebugFailure.stale }
            guard core.state == .paused else { throw BoundDebugFailure.busy }
            if let expectedUI {
                let restoredUI = try self.pausedUIRequest(core)
                try self.record(["operationID": .string(manifest.operationID.uuidString.lowercased()),
                                 "expectedRawUIBase64": .string(expectedUI.base64EncodedString()),
                                 "restoredRawUIBase64": .string(restoredUI.base64EncodedString()),
                                 "equal": .bool(restoredUI == expectedUI), "rawBytesAreDiagnosticOnly": .bool(true)],
                                name: "custom-reload-ui", output: output)
                guard restoredUI == expectedUI else { throw BoundDebugFailure.nativeVerification }
            } else {
                XCTAssertEqual(MultiRedAdapter.readSetupRequest()?.frame, expectedFrame)
            }
            XCTAssertEqual(try MultiRedAdapter.debugTrainer(core: core), descriptor.trainer)
            let payload = try JSONDecoder().decode(BoundMultiplayerSavePackage.Payload.self, from: bytes)
            XCTAssertEqual(payload.manifest.identity.owner, context.session.owner); XCTAssertEqual(payload.manifest.deviceOwner, context.deviceID)
            XCTAssertEqual(payload.files["checkpoint.state"]?.sha256, descriptor.files["checkpoint.state"]?.sha256)
            if let capture {
                XCTAssertEqual(bytes, try XCTUnwrap(storedCustom)); XCTAssertEqual(manifest.runID, original.runID)
                XCTAssertEqual(manifest.cut, capture.manifest.cut); XCTAssertEqual(payload.checkpoint, descriptor.receipt.checkpoint)
                XCTAssertEqual(manifest.owners[context.session.owner.uuidString.lowercased()]?.applied, descriptor.applied)
            } else { XCTAssertNotEqual(manifest.runID, original.runID) }
            observed = true
        }
        defer { host.restoreObserved = nil }
        if input.role == "buddy" { await transport.arm("verify", fault: .holdBeforeSend, generation: nextGeneration) }
        try await scenarioBarrier(input, phase: "prepared", evidence: ["nativeFrame": .number(Double(try XCTUnwrap(MultiRedAdapter.readSetupRequest()?.frame)))], output: output)
        if input.role == "controller" {
            if let capture { await debug.reloadCustom(capture) } else { await debug.reload() }
            try await wait("Controller must wait for the withheld buddy verification", seconds: 90) {
                await debug.reconcile(); return debug.activeManifest?.generation == nextGeneration && debug.status == .waiting
            }
            XCTAssertTrue(observed); XCTAssertNil(host.lastAdmission)
            let body = try await admissionRequest(original.sessionID, generation: nextGeneration, account: context.session)
            let denied = try await BoundDebugService().request(body, session: context.session)
            XCTAssertEqual(denied["admission"]?["allowed"]?.boolean, false)
            try await advanceNative(core, frames: 10)
            try await scenarioBarrier(input, phase: "withheld", evidence: ["ready": .bool(false), "nativeFramesContinued": .bool(true),
                "serverAdmission": .bool(false)], output: output, seconds: 5)
        } else {
            let polling = Task {
                while !Task.isCancelled, !(await transport.snapshot().held) {
                    await debug.reconcile(); try? await Task.sleep(for: .milliseconds(25))
                }
            }
            defer { polling.cancel() }
            try await wait("Buddy's actual verification must be withheld before network send", seconds: 90) { await transport.snapshot().held }
            XCTAssertTrue(observed); XCTAssertNil(host.lastAdmission)
            let held = await transport.snapshot(); XCTAssertNil(held.accepted)
            try await scenarioBarrier(input, phase: "withheld", evidence: ["nativeVerified": .bool(true), "requestNotSent": .bool(true)], output: output, seconds: 5)
            await transport.release(); await polling.value
        }
        try await wait("Both restored owners must verify the same new generation", seconds: 30) {
            await debug.reconcile(); return debug.status == .ready && debug.activeManifest?.generation == nextGeneration
        }
        XCTAssertEqual(host.lastAdmission?.generation, nextGeneration)
        do { _ = try await oldService.getSave(oldIdentity.run); XCTFail("Old generation service survived reload") }
        catch let error as BoundDebugFailure { XCTAssertEqual(error, .stale) }
        try await assertServerScopeDenied(oldScope, account: context.session)
        try await scenarioBarrier(input, phase: "verified", evidence: ["generation": .number(Double(nextGeneration)),
            "ownerID": .string(context.session.owner.uuidString.lowercased()), "nativeVerified": .bool(observed),
            "oldScopeRejected": .bool(true)], output: output)
        try record(["scenario": .string(input.scenario.rawValue), "scenarioOutcomeVerified": .bool(true),
            "generation": .number(Double(nextGeneration)), "nativeRestoreVerified": .bool(observed),
            "waitingAdmissionDenied": .bool(true), "oldScopeRejected": .bool(true)], name: "boundary-proof", output: output)
    }
    private func exerciseRevocation(_ input: Input, coordinator: BoundROMMultiplayerCoordinator, debug: BoundDebugSession,
                                    core: EmulatorCore, output: URL) async throws {
        let host = try XCTUnwrap(candidateHost), context = try coordinator.debugContext(), active = try XCTUnwrap(debug.activeManifest)
        let bookmark = try XCTUnwrap(debug.bookmark)
        let identity = try XCTUnwrap(BoundMultiplayerSaveStore.shared.manifest(gameID: context.compatibility.gameID)?.identity)
        let oldService = try debug.makeRunService(identity: identity)
        let authority = try await admissionRequest(active.sessionID, generation: active.generation, account: context.session)
        try await wait("Revocation must first settle a safe field checkpoint", seconds: 15) {
            do { try coordinator.preflightDebugSwitch(); _ = try await coordinator.settleForDebugSwitch(); return true }
            catch BoundDebugFailure.busy { return false }
        }
        guard core.state == .paused || core.pause() else { throw BoundDebugFailure.busy }
        let memory = try nativeRAM(core), soul = try soulDigest(), restoreCount = host.restoredPayloadCount
        let frame = try XCTUnwrap(MultiRedAdapter.readSetupRequest()?.frame), world = try XCTUnwrap(MultiRedAdapter.captureWorld()?.state)
        let trainer = try MultiRedAdapter.debugTrainer(core: core)
        let ordinary = BoundNakamaRunService(); _ = try await ordinary.configureSaves(session: context.session)
        let ordinaryBefore = try ordinaryFence(await ordinary.getSave(bookmark.identity.run))
        try await scenarioBarrier(input, phase: "prepared", evidence: ["generation": .number(Double(active.generation)),
            "nativeRAMSHA256": .string(BoundMultiplayerSaveStore.hash(memory)), "safeField": .bool(true)], output: output)
        let acts = input.scenario == .buddyLeave ? input.role == "buddy" : input.role == "controller"
        if acts {
            if input.scenario == .buddyLeave { await debug.leave() } else { await debug.revoke() }
        }
        try await wait("Both owners must authenticate the revoked membership", seconds: 30) {
            await debug.reconcile(); return debug.serverSession?.status == .revoked
        }
        XCTAssertGreaterThan(try XCTUnwrap(debug.serverSession?.membershipEpoch), active.membershipEpoch)
        XCTAssertNil(host.lastAdmission); XCTAssertEqual(debug.activeManifest, active); XCTAssertEqual(debug.bookmark, bookmark)
        // Host mailboxes may publish disconnected status while the cartridge
        // is paused. Compare native frame and canonical game facts, not those
        // expected host-side RAM writes.
        XCTAssertEqual(core.state, .paused); XCTAssertEqual(MultiRedAdapter.readSetupRequest()?.frame, frame)
        XCTAssertEqual(MultiRedAdapter.captureWorld()?.state, world); XCTAssertEqual(try MultiRedAdapter.debugTrainer(core: core), trainer)
        XCTAssertEqual(try soulDigest(), soul)
        XCTAssertEqual(host.restoredPayloadCount, restoreCount)
        XCTAssertEqual(try BoundMultiplayerSaveStore.shared.manifest(gameID: context.compatibility.gameID)?.identity, identity)
        do { _ = try await oldService.getSave(identity.run); XCTFail("Revoked scope survived") }
        catch let error as BoundDebugFailure { XCTAssertEqual(error, .stale) }
        try await assertServerScopeDenied(authority, account: context.session)
        let afterRevocation = try ordinaryFence(await ordinary.getSave(bookmark.identity.run))
        XCTAssertEqual(afterRevocation, ordinaryBefore)
        let intent = try await intentStorage(input).load(owner: context.session.owner, room: context.roomID)
        XCTAssertEqual(intent?.manifest, active); XCTAssertEqual(intent?.bookmark, bookmark)
        if acts { XCTAssertEqual(intent?.membershipEnded, true) }
        try await scenarioBarrier(input, phase: "denied", evidence: ["revoked": .bool(true), "nativeExecutionPreserved": .bool(true),
            "ordinaryUnchanged": .bool(true), "scopeRejected": .bool(true)], output: output)
        // Revoked DEBUG writes are forbidden. Cleanup deliberately uses only
        // the product's explicit, normally authorized ordinary Return path.
        await debug.returnToPreviousRun()
        try await wait("Explicit ordinary Return must finish its fresh verification", seconds: 30) {
            await debug.reconcile()
            return debug.failure == nil && debug.activeManifest == nil
        }
        XCTAssertNil(debug.failure); XCTAssertNil(debug.activeManifest)
        XCTAssertEqual(try BoundMultiplayerSaveStore.shared.manifest(gameID: context.compatibility.gameID)?.identity, bookmark.identity)
        try await scenarioBarrier(input, phase: "returned", evidence: ["ordinaryRunID": .string(bookmark.identity.run.uuidString.lowercased()),
            "explicitReturn": .bool(true)], output: output)
        try record(["scenario": .string(input.scenario.rawValue), "scenarioOutcomeVerified": .bool(true),
            "membershipRevoked": .bool(true), "nativeExecutionPreservedUntilExplicitReturn": .bool(true),
            "ordinaryUnchangedBeforeReturn": .bool(true)], name: "boundary-proof", output: output)
    }
    private func finalRestartCheckpoint(_ debug: BoundDebugSession, coordinator: BoundROMMultiplayerCoordinator,
                                        output: URL, scoped: Bool = true) async throws -> BoundMultiplayerSavePackage {
        let view = try XCTUnwrap(owner), game = try XCTUnwrap(view.game as? Game)
        let identity = try XCTUnwrap(BoundMultiplayerSaveStore.shared.manifest(gameID: game.identifier)?.identity)
        let receipt = LocalDebugFinalReceipt(identity: identity); finalReceipt = receipt
        let observation = NotificationCenter.default.addObserver(forName: BoundServerDisconnectSave.didFinish,
            object: nil, queue: nil) { receipt.receive($0) }
        defer { NotificationCenter.default.removeObserver(observation) }
        try await wait("Restart checkpoint must use normal scoped final-save authority", seconds: 8) {
            if receipt.read().failed { throw BoundDebugFailure.storage }
            return coordinator.prepareForCoreReplacement() && receipt.read().checkpoint != nil && !coordinator.hasUnconfirmedServerSave
        }
        let service: BoundNakamaRunService
        if scoped { service = try debug.makeRunService(identity: identity, requestTimeout: 1) }
        else {
            service = BoundNakamaRunService()
            let account = try XCTUnwrap(view.boundCompanionForTesting.account.session)
            _ = try await service.configureSaves(session: account)
        }
        let state = try await service.getSave(identity.run), upload = try XCTUnwrap(state.saves[identity.owner.uuidString.lowercased()])
        guard upload.receipt.checkpoint == receipt.read().checkpoint, state.identity == identity else {
            throw BoundDebugFailure.stale
        }
        let package = try await service.downloadIndependent(identity: identity, upload: upload)
        let final = receipt.read()
        guard package.receipt == upload.receipt, final.checkpoint == upload.receipt.checkpoint,
              !final.failed, !coordinator.hasUnconfirmedServerSave else { throw BoundDebugFailure.storage }
        try record(["receipt": try .wire(upload.receipt), "confirmedBeforeRestart": .bool(true)], name: "final-native-save", output: output)
        return package
    }
    private func detachRestart(_ debug: BoundDebugSession, core: EmulatorCore) throws {
        let view = try XCTUnwrap(owner)
        guard view.emulatorCore === core else { throw BoundDebugFailure.stale }
        debug.suspend(); view.game = nil
        guard view.game == nil, core.state == .stopped else { throw BoundDebugFailure.busy }
        window?.isHidden = true; window?.rootViewController = nil; window = nil; previousWindow?.makeKeyAndVisible()
        self.owner = nil; candidateHost = nil; restartDetached = true
        UserDefaults.standard.set(previousExperimental, forKey: BoundMultiplayerFeatures.key)
        NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
    }
    private func preparePartial(_ input: Input, coordinator: BoundROMMultiplayerCoordinator,
                                debug: BoundDebugSession, transport: LocalDebugBoundaryTransport,
                                core: EmulatorCore, options: BoundMultiplayerSetupOptions, output: URL) async throws {
        let context = try coordinator.debugContext(), host = try XCTUnwrap(candidateHost), storage = intentStorage(input)
        let ordinaryIdentity = try XCTUnwrap(BoundMultiplayerSaveStore.shared.manifest(gameID: context.compatibility.gameID)?.identity)
        if input.role == "buddy" { await transport.arm("download", fault: .loseReplyAndRecovery, generation: 1) }
        // This file handoff only ensures the fault is armed before Load. All
        // preparation, commit and membership authority still comes from HTTP.
        try await scenarioBarrier(input, phase: "armed", evidence: ["downloadFaultArmed": .bool(input.role == "buddy")], output: output)
        if input.role == "controller" {
            await debug.load(source: .init(kind: .builtin, pointID: "01", fixtureVersion: BoundDebugCatalog.fixtureVersion), settings: options.settings)
            try await wait("Controller must install while its buddy has no native installation", seconds: 90) {
                await debug.reconcile(); return debug.activeManifest?.generation == 1 && debug.status == .waiting
            }
        } else {
            try await wait("Buddy must lose a real committed download before native restore", seconds: 90) {
                await debug.reconcile(); return await transport.snapshot().held
            }
        }
        let savedValue = try await storage.load(owner: context.session.owner, room: context.roomID)
        let saved = try XCTUnwrap(savedValue), target = try XCTUnwrap(saved.manifest), bookmark = try XCTUnwrap(saved.bookmark)
        let installed = input.role == "controller"
        trace("Validate partial local installation")
        try record(["generation": .number(Double(target.generation)), "manifestDigest": .string(target.digest),
            "localPhase": .string(saved.phase.rawValue), "status": .string(debug.status.rawValue),
            "nativeRestoreCount": .number(Double(host.restoredPayloadCount)), "latestRecoveryCount": .number(Double(host.recoveredInstallationCount)),
            "hasAdmission": .bool(host.lastAdmission != nil), "coreResumeBlocked": .bool(coordinator.debugBlocksCoreResume),
            "expectedInstalled": .bool(installed)], name: "partial-install-observation", output: output)
        guard target.generation == 1, target.sessionID == input.debugSessionID,
              host.restoredPayloadCount == (installed ? 1 : 0), host.recoveredInstallationCount == 0,
              host.lastAdmission == nil, saved.phase == (installed ? .verified : .committed),
              !coordinator.debugBlocksCoreResume else { throw BoundDebugFailure.nativeVerification }
        let currentIdentity = try XCTUnwrap(BoundMultiplayerSaveStore.shared.manifest(gameID: context.compatibility.gameID)?.identity)
        guard installed ? currentIdentity.run == target.runID : currentIdentity == ordinaryIdentity else { throw BoundDebugFailure.stale }
        // A committed download can return before the other owner's native
        // restore finishes. Observe both local boundaries before requiring its
        // server verification; the handoff itself grants no admission.
        trace("Wait for both partial installation observations")
        try await scenarioBarrier(input, phase: "observed", evidence: ["generation": .number(Double(target.generation)),
            "manifestDigest": .string(target.digest), "installed": .bool(installed),
            "nativeRestoreCount": .number(Double(host.restoredPayloadCount))], output: output)
        trace("Validate authenticated partial admission")
        let authority = try await admissionRequest(target.sessionID, generation: target.generation, account: context.session)
        let response = try await BoundDebugService().request(authority, session: context.session)
        let verified = try XCTUnwrap(response["operation"]?["verifiedOwners"]?.array).compactMap { $0.string.flatMap(UUID.init(uuidString:)) }
        try record(["generation": .number(Double(target.generation)), "manifestDigest": .string(target.digest),
            "serverGeneration": response["session"]?["currentGeneration"] ?? .null,
            "serverManifestDigest": response["session"]?["currentManifestDigest"] ?? .null,
            "admissionAllowed": response["admission"]?["allowed"] ?? .null,
            "verifiedOwners": .array(verified.map { .string($0.uuidString.lowercased()) })], name: "partial-admission-observation", output: output)
        guard response["admission"]?["allowed"]?.boolean == false,
              verified == [try XCTUnwrap(debug.serverSession?.controllerID)] else { throw BoundDebugFailure.nativeVerification }
        let candidateValue = try await storage.payload(owner: context.session.owner, operation: target.operationID)
        let candidate = try XCTUnwrap(candidateValue), descriptor = try XCTUnwrap(target.owners[context.session.owner.uuidString.lowercased()])
        guard BoundDebugJSON.digest(candidate) == descriptor.receipt.payloadSHA256 else { throw BoundDebugFailure.storage }
        if installed { try await advanceNative(core, frames: 20) }
        else {
            let lost = await transport.snapshot()
            guard lost.accepted?["chunk"] != nil, !lost.actions.contains("verify"), debug.activeManifest == nil else { throw BoundDebugFailure.nativeVerification }
            // No native hold was acquired: retain ordinary authority and stop
            // only DEBUG polling before its normal outgoing final save.
            debug.suspend()
        }
        trace("Confirm partial outgoing checkpoint")
        let package = try await finalRestartCheckpoint(debug, coordinator: coordinator, output: output, scoped: installed)
        let frame = try XCTUnwrap(MultiRedAdapter.readSetupRequest()?.frame), soul = try soulDigest()
        let stateSHA = try XCTUnwrap(package.payload.files["checkpoint.state"]?.sha256)
        if installed {
            guard package.receipt.checkpoint != descriptor.receipt.checkpoint,
                  stateSHA != descriptor.files["checkpoint.state"]?.sha256 else { throw BoundDebugFailure.nativeVerification }
            debug.suspend()
        }
        // Both the old ordinary outgoing save and the installed DEBUG final
        // save must settle before either process freezes the shared baseline.
        try await scenarioBarrier(input, phase: "settled", evidence: ["generation": .number(Double(target.generation)),
            "manifestDigest": .string(target.digest), "installed": .bool(installed), "finalReceipt": try .wire(package.receipt)], output: output)
        let ordinary = BoundNakamaRunService(); _ = try await ordinary.configureSaves(session: context.session)
        let fence = try ordinaryFence(await ordinary.getSave(bookmark.identity.run))
        let proof = PartialRestoreProof(version: 1, processID: ProcessInfo.processInfo.processIdentifier,
            attemptID: input.attemptID, recoveryAttemptID: try XCTUnwrap(input.recoveryAttemptID), ownerID: context.session.owner,
            deviceID: context.deviceID, installed: installed, target: target, outgoing: package.receipt,
            nativeIdentity: currentIdentity, frame: frame, soulSHA256: soul, stateSHA256: stateSHA,
            candidateSHA256: BoundDebugJSON.digest(candidate), ordinary: fence)
        let proofURL = try partialProofURL(input)
        guard !FileManager.default.fileExists(atPath: proofURL.path) else { throw BoundDebugFailure.storage }
        try FileManager.default.createDirectory(at: proofURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(proof).write(to: proofURL, options: .atomic)
        try record(try XCTUnwrap(BoundDebugJSON.wire(proof).object), name: "partial-prepared", output: output)
        try detachRestart(debug, core: core)
        try record(["scenario": .string(input.scenario.rawValue), "scenarioOutcomeVerified": .bool(true),
            "nativeInstallCount": .number(Double(installed ? 1 : 0)), "ready": .bool(false),
            "membershipPreserved": .bool(true)], name: "boundary-proof", output: output)
    }
    private func recoverPartial(_ input: Input, login: Login, coordinator: BoundROMMultiplayerCoordinator,
                                core: EmulatorCore, output: URL) async throws {
        let proofURL = try partialProofURL(input), properties = try proofURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true, (properties.fileSize ?? Int.max) <= 65_536 else { throw BoundDebugFailure.storage }
        let proof = try JSONDecoder().decode(PartialRestoreProof.self, from: Data(contentsOf: proofURL))
        guard proof.version == 1, proof.recoveryAttemptID == input.recoveryAttemptID, proof.target.sessionID == input.debugSessionID,
              proof.attemptID != input.attemptID, proof.processID != ProcessInfo.processInfo.processIdentifier,
              proof.installed == (input.role == "controller") else { throw BoundDebugFailure.stale }
        try await wait("Fresh partial-restore core must expose its normal authenticated context") { (try? coordinator.debugContext()) != nil }
        let context = try coordinator.debugContext(), storage = intentStorage(input)
        guard context.session.owner == proof.ownerID, context.deviceID == proof.deviceID, context.roomID == login.roomID else { throw BoundDebugFailure.stale }
        let savedValue = try await storage.load(owner: context.session.owner, room: context.roomID), saved = try XCTUnwrap(savedValue)
        let bookmark = try XCTUnwrap(saved.bookmark), descriptor = try XCTUnwrap(proof.target.owners[proof.ownerID.uuidString.lowercased()])
        guard saved.manifest == proof.target, saved.phase == (proof.installed ? .verified : .committed) else { throw BoundDebugFailure.stale }
        let candidateValue = try await storage.payload(owner: proof.ownerID, operation: proof.target.operationID), candidate = try XCTUnwrap(candidateValue)
        guard BoundDebugJSON.digest(candidate) == proof.candidateSHA256 else { throw BoundDebugFailure.storage }
        let ordinary = BoundNakamaRunService(); _ = try await ordinary.configureSaves(session: context.session)
        let before = try ordinaryFence(await ordinary.getSave(bookmark.identity.run))
        guard before == proof.ordinary else { throw BoundDebugFailure.stale }
        let transport = LocalDebugBoundaryTransport(); self.transport = transport
        let host = LocalDebugCandidateHost(coordinator, reviewedCertificates: input.reviewedCandidateCertificates ?? [:],
            fixtureRoot: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DEBUGFixtures"))
        candidateHost = host
        let debug = BoundDebugSession(host: host, storage: storage, service: transport, enabled: { BoundMultiplayerFeatures.isEnabled })
        coordinator.debugSession = debug
        var observedFrame: UInt32?, observedReceipt: BoundMultiplayerCheckpointReceipt?
        var restoreFailures = 0
        host.restoreFailureObserved = { [weak self] error, bytes, target, coordinatorSucceeded in
            guard let self else { return }
            restoreFailures += 1
            self.trace("Partial restore rejected before verification")
            var facts: [String: BoundDebugJSON] = ["failureType": .string(String(reflecting: type(of: error))),
                "failure": .string((error as? BoundDebugFailure)?.rawValue ?? "other"),
                "coordinatorRestoreSucceeded": .bool(coordinatorSucceeded), "corePaused": .bool(core.state == .paused),
                "manifestMatches": .bool(target == proof.target), "candidateBytesMatch": .bool(bytes == candidate),
                "generation": .number(Double(target.generation)), "manifestDigest": .string(target.digest),
                "descriptorSoulDigest": .string(descriptor.soulDigest), "descriptorApplied": (try? .wire(descriptor.applied)) ?? .null]
            do {
                let payload = try JSONDecoder().decode(BoundMultiplayerSavePackage.Payload.self, from: bytes)
                let identity = payload.manifest.identity
                guard let memoryBytes = payload.files["memory-files.json"]?.data,
                      let journalBytes = payload.files["shared-events.json"]?.data else { throw BoundDebugFailure.invalidResponse }
                let sealedMemory = try JSONDecoder().decode([String: Data].self, from: memoryBytes)
                let liveMemory = BoundServerMemoryFiles.snapshot(gameID: identity.gameID)
                let sealedBytes = try BoundDebugNativePayload.ledgerBytes(in: sealedMemory, identity: identity)
                let liveBytes = try BoundDebugNativePayload.ledgerBytes(in: liveMemory, identity: identity)
                let sealedLedger = try BoundDebugNativePayload.ledger(in: sealedMemory, identity: identity)
                let liveLedger = try BoundDebugNativePayload.ledger(in: liveMemory, identity: identity)
                let liveJournal = try BoundMultiplayerSaveStore.shared.journal(gameID: identity.gameID)
                let sealedJournal = try JSONDecoder().decode(BoundMultiplayerSharedJournal.self, from: journalBytes)
                facts["sealedSoulDigest"] = .string(BoundMultiplayerSaveStore.hash(sealedBytes))
                facts["liveSoulDigest"] = .string(BoundMultiplayerSaveStore.hash(liveBytes))
                facts["ledgerModelsEqual"] = .bool(liveLedger == sealedLedger)
                facts["ledgerRawBytesEqual"] = .bool(liveBytes == sealedBytes)
                facts["sealedApplied"] = try .wire(BoundDebugCursor(sealedJournal.applied))
                facts["liveApplied"] = try .wire(BoundDebugCursor(liveJournal.applied))
                facts["liveReceived"] = try .wire(BoundDebugCursor(liveJournal.received))
                facts["liveAppliedEqualsDescriptor"] = .bool(BoundDebugCursor(liveJournal.applied) == descriptor.applied)
                facts["liveAppliedCoversDescriptor"] = .bool(liveJournal.applied.covers(descriptor.applied.sdk))
                facts["nativeTrainerMatches"] = .bool(try MultiRedAdapter.debugTrainer(core: core) == descriptor.trainer)
            } catch {
                facts["diagnosticReadFailure"] = .string(String(reflecting: type(of: error)))
            }
            try? self.record(facts, name: "partial-restore-failure-" + String(restoreFailures), output: output)
        }
        host.recoveryObserved = { [weak self] in
            guard let self, proof.installed, core.state == .paused,
                  MultiRedAdapter.readSetupRequest()?.frame == proof.frame,
                  try self.soulDigest() == proof.soulSHA256 else { throw BoundDebugFailure.nativeVerification }
            let identity = try XCTUnwrap(BoundMultiplayerSaveStore.shared.manifest(gameID: context.compatibility.gameID)?.identity)
            guard identity == proof.nativeIdentity else { throw BoundDebugFailure.stale }
            let service = try debug.makeRunService(identity: identity, requestTimeout: 1)
            let state = try await service.getSave(identity.run), upload = try XCTUnwrap(state.saves[proof.ownerID.uuidString.lowercased()])
            let package = try await service.downloadIndependent(identity: identity, upload: upload)
            guard upload.receipt == proof.outgoing, package.payload.files["checkpoint.state"]?.sha256 == proof.stateSHA256,
                  upload.receipt.checkpoint != descriptor.receipt.checkpoint,
                  try MultiRedAdapter.debugTrainer(core: core) == descriptor.trainer else { throw BoundDebugFailure.nativeVerification }
            observedFrame = proof.frame; observedReceipt = upload.receipt
        }
        host.restoreObserved = { [weak self] bytes, target in
            guard let self, !proof.installed, core.state == .paused, target == proof.target, bytes == candidate,
                  try MultiRedAdapter.debugTrainer(core: core) == descriptor.trainer else { throw BoundDebugFailure.nativeVerification }
            // The coordinator has independently validated the actual battery,
            // native trainer, full owner identity, Soul ledger and applied cut.
            let native = try await coordinator.verifyDebugRestore(manifest: target)
            guard native.valid(descriptor: descriptor) else { throw BoundDebugFailure.nativeVerification }
            let payload = try JSONDecoder().decode(BoundMultiplayerSavePackage.Payload.self, from: bytes)
            let identity = payload.manifest.identity
            let service = try debug.makeRunService(identity: identity, requestTimeout: 1)
            let state = try await service.getSave(identity.run)
            let journal = try BoundMultiplayerSaveStore.shared.journal(gameID: identity.gameID)
            let additions = journal.events.filter { $0.id.origin == identity.partner && !descriptor.applied.sdk.contains($0.id)
                && journal.applied.contains($0.id) && state.serverCursor.contains($0.id) }
            let memory = BoundServerMemoryFiles.snapshot(gameID: identity.gameID)
            _ = try BoundDebugNativePayload.ledger(in: memory, identity: identity)
            let liveDigest = BoundMultiplayerSaveStore.hash(try BoundDebugNativePayload.ledgerBytes(in: memory, identity: identity))
            let coversCurrent = journal.received.covers(state.serverCursor) && journal.applied.covers(state.serverCursor)
            let beyondBaseline = journal.applied.covers(descriptor.applied.sdk) && !descriptor.applied.sdk.covers(journal.applied)
            try self.record(["generation": .number(Double(target.generation)), "manifestDigest": .string(target.digest),
                "baselineApplied": try .wire(descriptor.applied), "currentServerCursor": try .wire(BoundDebugCursor(state.serverCursor)),
                "liveReceived": try .wire(BoundDebugCursor(journal.received)), "liveApplied": try .wire(BoundDebugCursor(journal.applied)),
                "appliedCoversCurrent": .bool(coversCurrent), "strictlyBeyondBaseline": .bool(beyondBaseline),
                "liveSoulDigest": .string(liveDigest), "baselineSoulDigest": .string(descriptor.soulDigest),
                "peerReceipt": try state.saves[identity.partner.uuidString.lowercased()].map { try .wire($0.receipt) } ?? .null,
                "newPeerEvents": .array(additions.map { .object(["origin": .string($0.id.origin.uuidString.lowercased()),
                    "sequence": .number(Double($0.id.sequence)), "kind": .string($0.kind),
                    "payloadSHA256": .string(BoundMultiplayerSaveStore.hash($0.payload))]) }),
                "nativeVerified": .bool(true)], name: "partial-history-replay", output: output)
            guard state.identity == identity, state.epoch == UInt64(descriptor.ownershipEpoch), state.gameOver == nil,
                  !state.cancelled, state.saves[identity.owner.uuidString.lowercased()]?.receipt == descriptor.receipt,
                  coversCurrent, beyondBaseline, !additions.isEmpty else { throw BoundDebugFailure.nativeVerification }
            observedFrame = try XCTUnwrap(MultiRedAdapter.readSetupRequest()?.frame); observedReceipt = descriptor.receipt
        }
        if !proof.installed { await transport.arm("verify", fault: .holdBeforeSend, generation: proof.target.generation) }
        try await scenarioBarrier(input, phase: "armed", evidence: ["generation": .number(Double(proof.target.generation))], output: output)
        var driveFailure: BoundDebugFailure?
        trace("Recover partial native installation")
        let drive = Task {
            while !Task.isCancelled {
                await debug.reconcile()
                if let failure = debug.failure {
                    driveFailure = failure
                    try? record(["failure": .string(failure.rawValue), "status": .string(debug.status.rawValue),
                        "nativeRestoreCount": .number(Double(host.restoredPayloadCount)),
                        "latestRecoveryCount": .number(Double(host.recoveredInstallationCount))], name: "partial-recovery-drive-failure", output: output)
                    return
                }
                let held = await transport.snapshot().held
                if proof.installed ? debug.status == .waiting : held { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        defer { drive.cancel() }
        if proof.installed {
            try await wait("Installed owner must recover latest head while buddy remains unverified", seconds: 90) {
                if let driveFailure { throw driveFailure }
                return observedReceipt != nil && debug.status == .waiting
            }
            let request = try await admissionRequest(proof.target.sessionID, generation: proof.target.generation, account: context.session)
            let response = try await BoundDebugService().request(request, session: context.session)
            guard response["admission"]?["allowed"]?.boolean == false, host.lastAdmission == nil else { throw BoundDebugFailure.nativeVerification }
        } else {
            try await wait("Restored buddy verification is withheld before network send", seconds: 90) {
                if let driveFailure { throw driveFailure }
                return await transport.snapshot().held
            }
            let held = await transport.snapshot()
            guard observedReceipt != nil, held.accepted == nil, host.lastAdmission == nil else { throw BoundDebugFailure.nativeVerification }
        }
        try await scenarioBarrier(input, phase: "withheld", evidence: ["generation": .number(Double(proof.target.generation)),
            "nativeVerified": .bool(true), "ready": .bool(false)], output: output, seconds: proof.installed ? 90 : 5)
        // Only the buddy has a held HTTP request (bounded at10 seconds). Its
        // marker gets five seconds; the running controller may wait for the
        // buddy's expensive native restore without holding a network request.
        if !proof.installed { await transport.release() }
        await drive.value
        try await wait("Ready requires both actual restored owners on the committed manifest", seconds: 30) {
            await debug.reconcile()
            if let failure = debug.failure { throw failure }
            return debug.status == .ready
        }
        await debug.reconcile()
        guard debug.failure == nil, debug.activeManifest == proof.target,
              host.restoredPayloadCount == (proof.installed ? 0 : 1), host.recoveredInstallationCount == (proof.installed ? 1 : 0),
              host.lastAdmission?.generation == proof.target.generation else { throw BoundDebugFailure.nativeVerification }
        host.restoreObserved = nil; host.recoveryObserved = nil; host.restoreFailureObserved = nil
        let after = try ordinaryFence(await ordinary.getSave(bookmark.identity.run))
        guard after == proof.ordinary else { throw BoundDebugFailure.stale }
        let actions = await transport.snapshot().actions
        guard !actions.contains(where: { ["create", "join", "prepare", "captureReady", "ownerPrepare", "chunk", "seal", "commit"].contains($0) }),
              !proof.installed || !actions.contains("download") else { throw BoundDebugFailure.nativeVerification }
        try record(["scenario": .string(input.scenario.rawValue), "scenarioOutcomeVerified": .bool(true),
            "attemptID": .string(input.attemptID.uuidString.lowercased()), "recoveryAttemptID": .string(proof.recoveryAttemptID.uuidString.lowercased()),
            "sessionID": .string(proof.target.sessionID.uuidString.lowercased()), "generation": .number(Double(proof.target.generation)),
            "manifestDigest": .string(proof.target.digest), "ownerID": .string(proof.ownerID.uuidString.lowercased()),
            "deviceID": .string(proof.deviceID.uuidString.lowercased()), "previousProcessID": .number(Double(proof.processID)),
            "processID": .number(Double(ProcessInfo.processInfo.processIdentifier)), "wasInstalled": .bool(proof.installed),
            "nativeFrame": .number(Double(try XCTUnwrap(observedFrame))), "installedReceipt": try .wire(try XCTUnwrap(observedReceipt)),
            "nativeRestoreCount": .number(Double(host.restoredPayloadCount)), "latestRecoveryCount": .number(Double(host.recoveredInstallationCount)),
            "candidateSHA256": .string(proof.candidateSHA256), "ordinaryUnchanged": .bool(true), "ready": .bool(true)], name: "partial-recovered", output: output)
        try await scenarioBarrier(input, phase: "verified", evidence: ["generation": .number(Double(proof.target.generation)),
            "manifestDigest": .string(proof.target.digest), "ready": .bool(true)], output: output)
        try record(["scenario": .string(input.scenario.rawValue), "scenarioOutcomeVerified": .bool(true),
            "ordinaryUnchanged": .bool(true), "nativeInstalledExactlyOnce": .bool(true)], name: "boundary-proof", output: output)
    }
    private func prepareRestart(_ input: Input, coordinator: BoundROMMultiplayerCoordinator,
                                debug: BoundDebugSession, transport: LocalDebugBoundaryTransport,
                                core: EmulatorCore, output: URL) async throws {
        guard let view = owner, let active = debug.activeManifest, let bookmark = debug.bookmark,
              let recoveryAttemptID = input.recoveryAttemptID else { throw BoundDebugFailure.nativeVerification }
        let context = try coordinator.debugContext(), storage = intentStorage(input)
        let ordinary = BoundNakamaRunService(); _ = try await ordinary.configureSaves(session: context.session)
        let ordinaryBefore = try ordinaryFence(await ordinary.getSave(bookmark.identity.run))
        var pending: Task<Void, Never>?
        let archive: BoundDebugManifest
        if input.role == "controller" {
            await transport.arm("commit", fault: .holdThenLoseReply)
            pending = Task { await debug.saveCustom() }
            try await wait("Custom commit must be accepted before its reply is lost", seconds: 90) { await transport.snapshot().held }
            guard let accepted = await transport.snapshot().accepted, let value = accepted["manifest"] else {
                throw BoundDebugFailure.nativeVerification
            }
            archive = try value.decode(BoundDebugManifest.self)
        } else {
            try await wait("Buddy must observe the committed custom archive", seconds: 90) {
                await debug.reconcile(); await debug.refreshCaptures(); return !debug.captures.isEmpty
            }
            guard let value = debug.captures.first?.manifest else { throw BoundDebugFailure.nativeVerification }
            archive = value
        }
        guard archive.sessionID == active.sessionID, archive.generation == active.generation + 1,
              let archiveOwner = archive.owners[context.session.owner.uuidString.lowercased()],
              let archiveBytes = try await storage.payload(owner: context.session.owner, operation: archive.operationID) else {
            throw BoundDebugFailure.nativeVerification
        }
        let archivePayload = try JSONDecoder().decode(BoundMultiplayerSavePackage.Payload.self, from: archiveBytes)
        guard let archiveState = archivePayload.files["checkpoint.state"]?.sha256,
              let before = MultiRedAdapter.readSetupRequest()?.frame else { throw BoundDebugFailure.nativeVerification }
        if core.state == .paused {
            guard view.emulatorCore === core, view.boundCanResumeEmulation(resumingNativeActivity: false), core.resume() else { throw BoundDebugFailure.busy }
        }
        try await wait("Active native progress must advance beyond archived cut", seconds: 3) {
            guard let frame = MultiRedAdapter.readSetupRequest()?.frame else { return false }; return frame &- before >= 20
        }
        guard core.state == .paused || core.pause() else { throw BoundDebugFailure.busy }
        let package = try await finalRestartCheckpoint(debug, coordinator: coordinator, output: output)
        guard let frame = MultiRedAdapter.readSetupRequest()?.frame, let stateSHA = package.payload.files["checkpoint.state"]?.sha256,
              stateSHA != archiveState, package.receipt.checkpoint != archiveOwner.receipt.checkpoint else {
            throw BoundDebugFailure.nativeVerification
        }
        let ordinaryAfter = try ordinaryFence(await ordinary.getSave(bookmark.identity.run))
        guard ordinaryAfter == ordinaryBefore else { throw BoundDebugFailure.stale }
        if let pending {
            let held = await transport.snapshot()
            guard held.held, held.replyPending, let accepted = held.accepted,
                  let manifestValue = accepted["manifest"], let operationValue = accepted["operation"] else {
                throw BoundDebugFailure.nativeVerification
            }
            let acceptedManifest = try manifestValue.decode(BoundDebugManifest.self)
            let acceptedOperation = try operationValue.decode(BoundDebugOperation.self)
            guard acceptedManifest == archive, acceptedOperation.sessionID == archive.sessionID,
                  acceptedOperation.operationID == archive.operationID, acceptedOperation.generation == archive.generation,
                  acceptedOperation.kind == .custom, acceptedOperation.state == .committed else { throw BoundDebugFailure.stale }
            // Polling may own the held commit request after saveCustom has
            // returned. End this process's session before releasing that reply;
            // the durable sealed intent below, not a transient failure value,
            // proves the fresh process must reconcile the committed archive.
            debug.suspend()
            try record(["operationID": .string(archive.operationID.uuidString.lowercased()),
                "sessionID": .string(archive.sessionID.uuidString.lowercased()), "generation": .number(Double(archive.generation)),
                "manifestDigest": .string(archive.digest), "replyPendingBeforeSuspend": .bool(true),
                "acceptedCommittedArchive": .bool(true)], name: "commit-withheld-at-suspend", output: output)
            await transport.release(); await pending.value
        }
        guard let intent = try await storage.load(owner: context.session.owner, room: context.roomID) else { throw BoundDebugFailure.storage }
        if input.role == "controller" {
            guard intent.phase == .sealed, intent.operationID == archive.operationID,
                  intent.generation == archive.generation, intent.sessionID == archive.sessionID else { throw BoundDebugFailure.stale }
        } else {
            guard intent.phase == .verified else { throw BoundDebugFailure.stale }
        }
        let proof = RestartProof(version: 1, processID: ProcessInfo.processInfo.processIdentifier,
            attemptID: input.attemptID, recoveryAttemptID: recoveryAttemptID, ownerID: context.session.owner,
            deviceID: context.deviceID, sessionID: active.sessionID, operationID: archive.operationID,
            activeGeneration: active.generation, archiveGeneration: archive.generation, activeManifestDigest: active.digest,
            receipt: package.receipt, stateSHA256: stateSHA, archiveStateSHA256: archiveState, frame: frame,
            soulSHA256: try soulDigest(), ordinary: ordinaryBefore)
        let proofURL = try restartProofURL(input)
        guard !FileManager.default.fileExists(atPath: proofURL.path) else { throw BoundDebugFailure.storage }
        try FileManager.default.createDirectory(at: proofURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(proof).write(to: proofURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: proofURL.path)
        try record(try BoundDebugJSON.wire(proof).object!, name: "restart-prepared", output: output)
        // The final scoped save is already confirmed. Clear only local polling
        // and capabilities before normal detach, so bind cannot revoke the pair.
        try detachRestart(debug, core: core)
        try record(["scenario": .string(input.scenario.rawValue), "scenarioOutcomeVerified": .bool(true),
            "membershipPreserved": .bool(true), "ordinaryUnchanged": .bool(true)], name: "boundary-proof", output: output)
    }
    private func recoverRestart(_ input: Input, login: Login, coordinator: BoundROMMultiplayerCoordinator,
                                core: EmulatorCore, output: URL) async throws {
        let proofURL = try restartProofURL(input), properties = try proofURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true, (properties.fileSize ?? Int.max) <= 65_536 else { throw BoundDebugFailure.storage }
        let proof = try JSONDecoder().decode(RestartProof.self, from: Data(contentsOf: proofURL))
        guard proof.version == 1, proof.recoveryAttemptID == input.recoveryAttemptID, proof.sessionID == input.debugSessionID,
              proof.attemptID != input.attemptID, proof.processID != ProcessInfo.processInfo.processIdentifier else { throw BoundDebugFailure.stale }
        try await wait("Fresh core must pass full-ROM admission and expose public DEBUG context") { (try? coordinator.debugContext()) != nil }
        let context = try coordinator.debugContext()
        guard context.session.owner == proof.ownerID, context.deviceID == proof.deviceID,
              context.roomID == login.roomID else { throw BoundDebugFailure.stale }
        let storage = intentStorage(input), savedValue = try await storage.load(owner: context.session.owner, room: context.roomID)
        let saved = try XCTUnwrap(savedValue), bookmark = try XCTUnwrap(saved.bookmark)
        guard saved.sessionID == proof.sessionID else { throw BoundDebugFailure.stale }
        if input.role == "controller" {
            guard saved.phase == .sealed, saved.operationID == proof.operationID else { throw BoundDebugFailure.stale }
        }
        let ordinary = BoundNakamaRunService(); _ = try await ordinary.configureSaves(session: context.session)
        let ordinaryBefore = try ordinaryFence(await ordinary.getSave(bookmark.identity.run))
        guard ordinaryBefore == proof.ordinary else { throw BoundDebugFailure.stale }
        let transport = LocalDebugBoundaryTransport(); self.transport = transport
        let host = LocalDebugCandidateHost(coordinator, reviewedCertificates: input.reviewedCandidateCertificates ?? [:],
            fixtureRoot: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DEBUGFixtures"))
        candidateHost = host
        let debug = BoundDebugSession(host: host, storage: storage, service: transport, enabled: { BoundMultiplayerFeatures.isEnabled })
        coordinator.debugSession = debug
        var observed = false
        host.recoveryObserved = { [weak self] in
            guard let self else { throw BoundDebugFailure.unavailable }
            XCTAssertEqual(core.state, .paused)
            XCTAssertEqual(MultiRedAdapter.readSetupRequest()?.frame, proof.frame)
            XCTAssertEqual(try self.soulDigest(), proof.soulSHA256)
            let identity = try XCTUnwrap(BoundMultiplayerSaveStore.shared.manifest(gameID: context.compatibility.gameID)?.identity)
            let service = try debug.makeRunService(identity: identity, requestTimeout: 1)
            let state = try await service.getSave(identity.run), upload = try XCTUnwrap(state.saves[proof.ownerID.uuidString.lowercased()])
            XCTAssertEqual(upload.receipt, proof.receipt)
            let package = try await service.downloadIndependent(identity: identity, upload: upload)
            XCTAssertEqual(package.payload.files["checkpoint.state"]?.sha256, proof.stateSHA256)
            XCTAssertNotEqual(package.payload.files["checkpoint.state"]?.sha256, proof.archiveStateSHA256)
            XCTAssertEqual(try MultiRedAdapter.debugTrainer(core: core).id, identity.localSeed)
            observed = true
        }
        await debug.reconcile()
        XCTAssertNil(debug.failure); XCTAssertTrue(observed); XCTAssertEqual(host.recoveredInstallationCount, 1); XCTAssertEqual(host.restoredPayloadCount, 0)
        host.recoveryObserved = nil
        await debug.refreshCaptures()
        XCTAssertTrue(debug.captures.contains { $0.id == proof.operationID && $0.manifest.generation == proof.archiveGeneration })
        XCTAssertEqual(debug.activeManifest?.generation, proof.activeGeneration); XCTAssertEqual(debug.activeManifest?.digest, proof.activeManifestDigest)
        let latest = try await storage.load(owner: context.session.owner, room: context.roomID)
        XCTAssertEqual(latest?.phase, .verified); XCTAssertEqual(latest?.generation, proof.activeGeneration)
        let ordinaryAfter = try ordinaryFence(await ordinary.getSave(bookmark.identity.run))
        XCTAssertEqual(ordinaryAfter, proof.ordinary)
        let actions = await transport.snapshot().actions
        XCTAssertFalse(actions.contains { ["create", "join", "prepare", "captureReady", "ownerPrepare", "chunk", "seal", "commit", "download"].contains($0) })
        try record(["scenario": .string(input.scenario.rawValue), "scenarioOutcomeVerified": .bool(true),
            "attemptID": .string(input.attemptID.uuidString.lowercased()), "recoveryAttemptID": .string(proof.recoveryAttemptID.uuidString.lowercased()),
            "sessionID": .string(proof.sessionID.uuidString.lowercased()),
            "previousProcessID": .number(Double(proof.processID)), "processID": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "activeGeneration": .number(Double(proof.activeGeneration)), "archiveGeneration": .number(Double(proof.archiveGeneration)),
            "latestActiveReceipt": try .wire(proof.receipt), "nativeFrame": .number(Double(proof.frame)),
            "ordinaryUnchanged": .bool(true), "archiveNotRestored": .bool(true)], name: "restart-recovered", output: output)
        // The runner releases cleanup only after both real processes have
        // recorded recovery. This hint grants no game/server authority.
        try await wait("Both native recovery proofs must exist before either role signs out", seconds: 120) {
            let url = self.root.appendingPathComponent("native-handoffs").appendingPathComponent(input.attemptID.uuidString + ".json")
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) <= 4096 else { throw BoundDebugFailure.storage }
            let value = try BoundDebugJSON(data: Data(contentsOf: url), limit: 4096)
            guard value["version"]?.integer == 1, value["scenario"]?.string == input.scenario.rawValue,
                  value["sessionID"]?.string.flatMap(UUID.init(uuidString:)) == proof.sessionID,
                  value["recoveryAttemptID"]?.string.flatMap(UUID.init(uuidString:)) == proof.recoveryAttemptID,
                  value["attempts"]?[input.role]?.string.flatMap(UUID.init(uuidString:)) == input.attemptID else { throw BoundDebugFailure.stale }
            return true
        }
    }
    private func game() async throws -> Game {
        let source = root.appendingPathComponent("RadicalRed.gba")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Awaiting exact task-local current ROM at DEBUGLocalQA/RadicalRed.gba") }
        let bytes = try Data(contentsOf: source), profile = try MultiRedAdapter(rom: bytes).profile
        guard profile == (ordinaryProfile ?? BoundGameProfiles.current) else { throw BoundDebugFailure.incompatible }
        if !DatabaseManager.shared.isStarted {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DatabaseManager.shared.start { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
        func existing() throws -> Game? {
            let request = Game.fetchRequest()
            request.predicate = NSPredicate(format: "%K == %@", #keyPath(Game.identifier), profile.gameID)
            return try DatabaseManager.shared.viewContext.fetch(request).first
        }
        if let value = try existing() {
            guard try Data(contentsOf: value.fileURL) == bytes else { throw BoundDebugFailure.incompatible }
            return value
        }
        let copied = root.appendingPathComponent("native-boundary-import-" + UUID().uuidString + ".gba")
        try bytes.write(to: copied, options: .atomic)
        defer { try? FileManager.default.removeItem(at: copied) }
        let success = await withCheckedContinuation { continuation in
            DatabaseManager.shared.importGames(at: [copied]) { games, errors in
                continuation.resume(returning: games.count == 1 && errors.isEmpty)
            }
        }
        guard success, let value = try existing(), value.boundUsesServerMultiplayer else { throw BoundDebugFailure.incompatible }
        return value
    }

    func testActualNativeBoundaryAcceptance() async throws {
        // Throwing unwraps must reach the catch below and preserve the final
        // checkpoint instead of letting XCTest terminate the owning process.
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["BOUND_LOCAL_DEBUG_NATIVE_TEST"] == "1", "Explicit task-owned native acceptance only")
        let inputURL = root.appendingPathComponent("native-boundary-input.json")
        guard FileManager.default.fileExists(atPath: inputURL.path) else { throw XCTSkip("Awaiting role-specific native-boundary-input.json") }
        let inputBytes = try Data(contentsOf: inputURL), loginBytes = try Data(contentsOf: root.appendingPathComponent("synthetic-login.json"))
        guard inputBytes.count <= 8192, loginBytes.count <= 8192 else { throw BoundDebugFailure.rejected }
        let input = try JSONDecoder().decode(Input.self, from: inputBytes), login = try JSONDecoder().decode(Login.self, from: loginBytes)
        let ordinaryTask = input.expectedROM != nil && [.ordinary, .ordinaryRecovery, .ordinaryTerminateAccepted].contains(input.scenario)
        let simulator = ordinaryTask ? env["BOUND_ORDINARY_QA_SIMULATOR"] :
            (input.role == "controller" ? "92586556-6715-4BA0-98FC-5C1FF776F0A9" : "14BD3EC6-B57B-49A1-98D1-457A9DC0C088")
        guard input.version == 1, ["controller", "buddy"].contains(input.role), env["SIMULATOR_UDID"] == simulator,
              env["BOUND_QA_LOCAL_BACKEND"] == "1", login.endpoint == "https://127.0.0.1:58552",
              try BoundBackendConfiguration.current().origin == login.endpoint,
              login.accounts.count == 2, Set(login.accounts.map(\.ownerID)).count == 2,
              let credentials = login.accounts.first(where: { $0.role == input.role }) else { throw BoundDebugFailure.rejected }
        let output = root.appendingPathComponent("native-results").appendingPathComponent(input.attemptID.uuidString).appendingPathComponent(input.role)
        let preparedMarker = output.appendingPathComponent("ordinary-termination-prepared.json")
        if ordinaryTask, input.scenario == .ordinaryTerminateAccepted,
           FileManager.default.fileExists(atPath: preparedMarker.path) {
            let prepared = try BoundDebugJSON(data: Data(contentsOf: preparedMarker))
            guard prepared["attemptID"]?.string.flatMap(UUID.init(uuidString:)) == input.attemptID,
                  prepared["role"]?.string == input.role else { throw BoundDebugFailure.stale }
            try record(["attemptID": .string(input.attemptID.uuidString), "role": .string(input.role),
                        "originalProcessID": prepared["processID"] ?? .null, "processID": .number(Double(getpid())),
                        "blockedBeforeAuthenticationAndMutation": .bool(true)], name: "ordinary-termination-rerun-blocked", output: output)
            // XCTest may restart its crashed host while finishing a run even
            // with one requested iteration. Never repeat authentication,
            // preference changes, native selection, or the prepared save.
            throw XCTSkip("This attempt already prepared its intentional process termination; recovery requires a new attempt")
        }
        let protocolRegistration = ordinaryTask ? try LocalOrdinaryProtocolRegistration() : nil
        defer { protocolRegistration?.restore() }
        if ordinaryTask {
            guard let expectedROM = input.expectedROM, let expectedGame = input.expectedGameID,
                  simulator != nil, env["BOUND_ORDINARY_QA_TASK"] == "coordinator-stability" else { throw BoundDebugFailure.rejected }
            let bytes = try Data(contentsOf: root.appendingPathComponent("RadicalRed.gba"))
            let profile = try MultiRedAdapter(rom: bytes).profile
            guard profile.romSHA256 == expectedROM, profile.gameID == expectedGame else { throw BoundDebugFailure.incompatible }
            ordinaryProfile = profile
            guard URLProtocol.registerClass(LocalOrdinarySaveDelivery.self) else { throw BoundDebugFailure.unavailable }
        }
        defer {
            LocalOrdinarySaveDelivery.release()
            URLProtocol.unregisterClass(LocalOrdinarySaveDelivery.self)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        diagnosticOutput = output
        previousExperimental = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        if input.previousTerminationAttemptID != nil {
            guard ordinaryTask, input.scenario == .ordinaryRecovery, input.previousReceipt != nil,
                  let present = input.restoreExperimentalPreferencePresent,
                  !present || input.restoreExperimentalPreferenceEnabled != nil else { throw BoundDebugFailure.rejected }
            // Intentional process death cannot execute the earlier attempt's
            // cleanup. Restore that attempt's original preference on recovery.
            previousExperimental = present ? input.restoreExperimentalPreferenceEnabled : nil
        }
        previousDeveloperFeatures = UserDefaults.standard.object(forKey: BoundDeveloperFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        if [.customCommitLossRecover, .partialRestoreRecover].contains(input.scenario) { UserDefaults.standard.set(true, forKey: BoundDeveloperFeatures.key) }
        defer {
            if [.customCommitLossRecover, .partialRestoreRecover].contains(input.scenario) { UserDefaults.standard.set(previousDeveloperFeatures, forKey: BoundDeveloperFeatures.key) }
        }
        do {
            try await run(input, login: login, credentials: credentials, output: output)
            if !restartDetached { try await finish(output: output) }
        } catch {
            try? record(["stage": .string(stage), "errorType": .string(String(reflecting: type(of: error))),
                         "debugFailure": .string((error as? BoundDebugFailure)?.rawValue ?? "other")], name: "failure", output: output)
            if let debug = owner?.boundCompanionForTesting.romMultiplayer.debugSession {
                try? debug.exportReport().write(to: output.appendingPathComponent("failure-debug-report.json"), options: .atomic)
            }
            // A failed assertion must not use raw stop/rebind to discard a held
            // native owner. Reconcile using actual authority before teardown.
            do { try await finish(output: output) }
            catch {
                try? record(["errorType": .string(String(reflecting: type(of: error))),
                             "debugFailure": .string((error as? BoundDebugFailure)?.rawValue ?? "other")], name: "teardown-failure", output: output)
            }
            throw error
        }
    }

    private func run(_ input: Input, login: Login, credentials: Login.Account, output: URL) async throws {
        trace("Import exact game")
        let game = try await game()
        trace("Create game view")
        let view = GameViewController(); owner = view; view.delegate = renderer; view.loadViewIfNeeded()
        let companion = view.boundCompanionForTesting, coordinator = companion.romMultiplayer
        // A terminated acceptance run may retain this synthetic login. Admit
        // only the exact role's owner, then use normal sign-in to reauthorize.
        guard companion.account.session == nil || companion.account.session?.owner == credentials.ownerID else { throw BoundDebugFailure.rejected }
        ownsAccountSession = true
        if input.previousTerminationAttemptID != nil {
            trace("Restore persisted synthetic owner after intentional termination")
            await companion.account.refreshIfNeeded()
            guard companion.account.session?.owner == credentials.ownerID else { throw BoundDebugFailure.rejected }
        } else {
            trace("Sign in synthetic owner")
            await companion.account.signIn(email: credentials.email, password: credentials.password)
        }
        let session = try XCTUnwrap(companion.account.session)
        guard session.owner == credentials.ownerID else { throw BoundDebugFailure.rejected }
        try session.credentials()
        trace("Attach actual core")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); self.window = window
        window.rootViewController = view; window.makeKeyAndVisible(); view.game = game
        guard (view.game as? Game) === game else { throw BoundDebugFailure.stale }
        let core = try XCTUnwrap(view.emulatorCore); core.audioManager.isEnabled = false
        companion.onboarding.open(sharing: companion.sharing, existing: { companion.account.session })
        try await wait("The real friend list must contain the dedicated pair") {
            companion.onboarding.rooms.contains { $0.roomID.lowercased() == login.roomID.uuidString.lowercased() }
        }
        let room = try XCTUnwrap(companion.onboarding.rooms.first { $0.roomID.lowercased() == login.roomID.uuidString.lowercased() })
        if [.customCommitLossRecover, .partialRestoreRecover].contains(input.scenario) {
            companion.onboarding.select(room, startSharing: false)
            if input.scenario == .partialRestoreRecover { try await recoverPartial(input, login: login, coordinator: coordinator, core: core, output: output) }
            else { try await recoverRestart(input, login: login, coordinator: coordinator, core: core, output: output) }
            return
        }
        let ordinary = BoundNakamaRunService()
        trace("Configure ordinary server scope")
        _ = try await ordinary.configureSaves(session: session, room: room.roomID)
        var options = BoundMultiplayerSetupOptions(); options.debug = true
        let runID: UUID
        if let existing = input.ordinaryRunID { runID = existing }
        else {
            guard input.role == "controller" else { throw XCTSkip("Buddy awaits controller ordinaryRunID from ordinary-created.json; no guessed run selection") }
            let created = try await ordinary.createSave(gameID: game.identifier, romSHA256: (ordinaryProfile ?? BoundGameProfiles.current).romSHA256,
                settings: options.settings, profile: options.profile, partnerProfile: options.partnerProfile, requestID: input.creationRequestID)
            runID = try XCTUnwrap(created.save_id)
            try record(["ordinaryRunID": .string(runID.uuidString.lowercased()), "attemptID": .string(input.attemptID.uuidString.lowercased())], name: "ordinary-created", output: output)
        }
        let originalRestoreCallback = coordinator.didRestoreSnapshot
        var observedRestores = 0, nativeRestoreMatched = false
        var restartProof: [String: BoundDebugJSON]?
        defer { coordinator.didRestoreSnapshot = originalRestoreCallback }
        if let previous = input.previousReceipt {
            let state = try await ordinary.getSave(runID)
            guard let previousPID = input.previousProcessID, previousPID != getpid(),
                  previous.run == runID, previous.owner == session.owner,
                  state.saves[session.owner.uuidString.lowercased()]?.receipt == previous else { throw BoundDebugFailure.stale }
            let package = try await ordinary.downloadIndependent(identity: state.identity,
                upload: try XCTUnwrap(state.saves[session.owner.uuidString.lowercased()]))
            guard package.receipt == previous, package.payload.manifest.identity.owner == session.owner else { throw BoundDebugFailure.nativeVerification }
            let expectedBattery = try XCTUnwrap(package.payload.files["game.sav"]?.data)
            let expectedRAM = try checkpointRAM(XCTUnwrap(package.payload.files["checkpoint.state"]?.data))
            coordinator.didRestoreSnapshot = {
                observedRestores += 1
                nativeRestoreMatched = core.state == .paused &&
                    BoundVBABattleBridge.captureServerBattery() == expectedBattery &&
                    (try? self.nativeRAM(core)) == expectedRAM
                // Preserve the product's existing restore observer after the
                // read-only paused native inspection, before gameplay resumes.
                originalRestoreCallback?()
            }
            restartProof = ["receipt": try .wire(previous), "previousProcessID": .number(Double(previousPID)),
                        "processID": .number(Double(getpid())), "exactConfirmedHeadBeforeSelection": .bool(true),
                        "expectedBatterySHA256": .string(BoundMultiplayerSaveStore.hash(expectedBattery)),
                        "expectedNativeRAMSHA256": .string(BoundMultiplayerSaveStore.hash(expectedRAM)),
                        "afterIntentionalTermination": .bool(input.previousTerminationAttemptID != nil),
                        "previousTerminationAttemptID": input.previousTerminationAttemptID.map { .string($0.uuidString) } ?? .null]
        }
        // selectServerRun refuses execution until asynchronous full-ROM
        // admission succeeds. Observe its real store result, never a private
        // verified/workingStateAuthorized flag or a test-only setter.
        try await wait("Full ROM admission and real server selection must succeed") {
            trace("Select ordinary run")
            _ = await coordinator.selectServerRun(runID, profile: input.role == "controller" ? options.profile : options.partnerProfile)
            return try BoundMultiplayerSaveStore.shared.manifest(gameID: game.identifier)?.identity.run == runID
        }
        if var proof = restartProof {
            proof["actualNativeRestoreCount"] = .number(Double(observedRestores))
            proof["restoredNativeBatteryAndRAMMatchAcceptedPackage"] = .bool(nativeRestoreMatched)
            try record(proof, name: "ordinary-restart-proof", output: output)
            guard observedRestores == 1, nativeRestoreMatched else { throw BoundDebugFailure.nativeVerification }
        }
        coordinator.didRestoreSnapshot = originalRestoreCallback
        trace("Wait for native Debug New Game")
        try await wait("The actual cartridge must complete admitted Debug New Game", seconds: 90) {
            coordinator.probe.read()?.settingsApplied == true && coordinator.probe.read()?.permitsFieldInterruption == true && !coordinator.needsServerMenu
        }
        // A restored header can be available before the UI timer observes its
        // Debug-mode flag. Wait for the same public authority used by the tab.
        try await wait("The restored native Debug context must become available") {
            (try? coordinator.debugContext()) != nil
        }
        trace("Settle ordinary checkpoint")
        var settledBookmark: BoundDebugBookmark?
        try await wait("Ordinary field authority must admit and settle a safe outgoing checkpoint", seconds: 15) {
            do {
                try coordinator.preflightDebugSwitch()
                settledBookmark = try await coordinator.settleForDebugSwitch()
                return true
            } catch BoundDebugFailure.busy {
                // Native/context publication can precede the actual field
                // boundary. Retry only that explicit temporary gate; storage,
                // stale authority and server errors still fail this attempt.
                return false
            }
        }
        let bookmark = try XCTUnwrap(settledBookmark)
        trace("Read confirmed ordinary checkpoint")
        let state = try await ordinary.getSave(runID), own = try XCTUnwrap(state.saves[session.owner.uuidString.lowercased()])
        let package = try await ordinary.downloadIndependent(identity: state.identity, upload: own)
        guard bookmark.identity == state.identity, let settledReceipt = bookmark.receipt,
              settledReceipt == own.receipt, package.receipt == own.receipt,
              package.payload.manifest.identity == state.identity,
              package.payload.files["game.sav"]?.data.count == 131_072,
              let nativeStateBytes = package.payload.files["checkpoint.state"]?.data.count,
              nativeStateBytes > 1024 else { throw BoundDebugFailure.nativeVerification }
        let ordinaryProofWasRunning = core.state == .running
        guard core.state == .paused || core.pause() else { throw BoundDebugFailure.busy }
        guard try MultiRedAdapter.debugTrainer(core: core).id == state.identity.localSeed else { throw BoundDebugFailure.nativeVerification }
        try record(["ordinaryRunID": .string(runID.uuidString.lowercased()), "receipt": try .wire(own.receipt),
                    "nativeTrainerID": .number(Double(state.identity.localSeed)), "actualCoordinator": .bool(true),
                    "nativeStateBytes": .number(Double(nativeStateBytes))], name: "ordinary-native-proof", output: output)
        if input.scenario == .ordinary { return }
        // This pause belongs only to the native trainer inspection above.
        // Restore normal execution through the same resume gate as the UI;
        // otherwise an odd native publication can stay paused indefinitely
        // while the first DEBUG load correctly reports a busy boundary.
        if ordinaryProofWasRunning, core.state == .paused {
            guard view.emulatorCore === core, view.boundCanResumeEmulation(resumingNativeActivity: false), core.resume() else {
                throw BoundDebugFailure.busy
            }
        }
        if input.scenario == .ordinaryRecovery {
            try await exerciseOrdinaryRecovery(input, coordinator: coordinator, ordinary: ordinary,
                                              core: core, identity: state.identity, output: output)
            return
        }
        if input.scenario == .ordinaryTerminateAccepted {
            try await prepareOrdinaryTermination(input, coordinator: coordinator, ordinary: ordinary,
                                                 core: core, identity: state.identity, output: output)
            return
        }
        let reviewed = input.reviewedCandidateCertificates ?? BoundDebugFixtureStore.certificates
        guard Set(reviewed.keys) == Set(["01/controller", "01/buddy"]), reviewed.values.allSatisfy(BoundDebugJSON.validDigest) else {
            throw XCTSkip("Ordinary native proof passed; paired cases await independently reviewed point01 certificate digests and native files")
        }
        let fixtureDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DEBUGFixtures").appendingPathComponent(BoundDebugCatalog.fixtureVersion)
            .appendingPathComponent("01").appendingPathComponent(input.role)
        guard ["certificate.json", "game.sav", "checkpoint.state", "soul-template.json"].allSatisfy({ FileManager.default.fileExists(atPath: fixtureDirectory.appendingPathComponent($0).path) }) else {
            throw XCTSkip("Awaiting reviewed point01 native files for this role; FixtureStore will independently verify every certificate/file hash")
        }
        guard let debugID = input.debugSessionID else { throw XCTSkip("Paired role processes need the same explicit debugSessionID") }
        let transport = LocalDebugBoundaryTransport(); self.transport = transport
        let storage = intentStorage(input)
        // The UUID is an invitation intent, not authority. create/join must
        // still succeed against the authenticated real server.
        if try await storage.load(owner: session.owner, room: login.roomID) == nil {
            try await storage.save(.init(ownerID: session.owner, roomID: login.roomID, deviceID: bookmark.deviceID, sessionID: debugID))
        }
        let host = LocalDebugCandidateHost(coordinator, reviewedCertificates: reviewed,
            fixtureRoot: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DEBUGFixtures"))
        candidateHost = host
        host.capturePausedUIRequest = { [weak self, weak core] in
            guard let self, let core else { throw BoundDebugFailure.unavailable }
            return try self.pausedUIRequest(core)
        }
        var recordedRestoreFailure = false
        host.restoreFailureObserved = { [weak self] error, _, target, coordinatorSucceeded in
            guard !recordedRestoreFailure else { return }
            recordedRestoreFailure = true
            let request = MultiRedAdapter.readSetupRequest()
            try? self?.record([
                "failure": .string((error as? BoundDebugFailure)?.rawValue ?? String(reflecting: type(of: error))),
                "coordinatorSucceeded": .bool(coordinatorSucceeded),
                "operationID": .string(target.operationID.uuidString.lowercased()),
                "coreState": .string(String(describing: core.state)),
                "frame": request.map { .number(Double($0.frame)) } ?? .null,
                "requestFlags": request.map { .number(Double($0.flags)) } ?? .null,
                "permitsFieldInterruption": request.map { .bool($0.permitsFieldInterruption) } ?? .null,
                "debugBlocksCoreResume": .bool(coordinator.debugBlocksCoreResume),
                "observationRecoveryRequired": .bool(coordinator.observationRecoveryRequired),
                "finalSaveBlocksCoreResume": .bool(coordinator.finalSaveBlocksCoreResume),
                "needsServerMenu": .bool(coordinator.needsServerMenu)
            ], name: "first-restore-failure", output: output)
        }
        let debug = BoundDebugSession(host: host, storage: storage, service: transport, enabled: { BoundMultiplayerFeatures.isEnabled })
        coordinator.debugSession = debug
        if input.scenario == .customHold, input.role == "controller" {
            var attemptedReadFault = false, passedReadFault = false
            host.restorePreflightObserved = { [weak self, weak host] payload, target in
                guard let self, let host else { throw BoundDebugFailure.unavailable }
                if attemptedReadFault {
                    guard passedReadFault else { throw BoundDebugFailure.nativeVerification }
                    return
                }
                attemptedReadFault = true
                try await self.exerciseStoppedFrameReadFault(payload: payload, target: target, coordinator: coordinator,
                    host: host, transport: transport, core: core, output: output)
                passedReadFault = true
            }
        }
        trace("Create or join paired DEBUG session")
        if input.role == "controller" { await debug.createSession() }
        else {
            try await wait("Controller must create the exact paired invitation", seconds: 90) {
                await debug.listInvitations(); return debug.invitations.contains { $0.sessionID == debugID }
            }
            let invitation = try XCTUnwrap(debug.invitations.first { $0.sessionID == debugID })
            await debug.join(sessionID: debugID, membershipEpoch: invitation.membershipEpoch)
        }
        try await wait("Both actual owners must join", seconds: 90) {
            await debug.reconcile(); return debug.serverSession?.status == .active
        }
        if input.scenario == .partialRestorePrepare {
            try await preparePartial(input, coordinator: coordinator, debug: debug, transport: transport,
                core: core, options: options, output: output)
            return
        }
        if input.scenario == .staleOrdinarySelection, input.role == "controller" {
            try await exerciseStaleSelection(input, coordinator: coordinator, debug: debug, transport: transport,
                game: game, options: options, core: core, output: output)
            return
        }
        if input.role == "controller" {
            // The fault scenario starts at an actual safe ordinary boundary.
            // A one-shot load during a transient native menu/script is correctly
            // rejected; polling status afterwards cannot create that operation.
            trace("Wait for initial ordinary native boundary")
            try await wait("Initial ordinary native boundary must permit DEBUG preparation", seconds: 30) {
                do { try coordinator.preflightDebugSwitch(); return true }
                catch BoundDebugFailure.busy { return false }
            }
            trace("Prepare existing reviewed native pair")
            await debug.load(source: .init(kind: .builtin, pointID: "01", fixtureVersion: BoundDebugCatalog.fixtureVersion), settings: options.settings)
            try record(["status": .string(debug.status.rawValue),
                        "failure": debug.failure.map { .string($0.rawValue) } ?? .null,
                        "isBusy": .bool(debug.isBusy),
                        "finalSaveBlocksCoreResume": .bool(coordinator.finalSaveBlocksCoreResume),
                        "needsServerMenu": .bool(coordinator.needsServerMenu)], name: "initial-pair-load", output: output)
            if let failure = debug.failure, debug.operation == nil {
                try debug.exportReport().write(to: output.appendingPathComponent("initial-pair-failure-report.json"), options: .atomic)
                throw failure
            }
        }
        var recordedInitialFailure = false
        try await wait("Reviewed point01 must restore and verify on both native owners", seconds: 120) {
            await debug.reconcile()
            if !recordedInitialFailure, !debug.isBusy, debug.failure != nil {
                recordedInitialFailure = true
                try debug.exportReport().write(to: output.appendingPathComponent("first-initial-reconcile-failure.json"), options: .atomic)
            }
            if input.scenario == .staleOrdinarySelection, let installed = debug.activeManifest {
                // The controller deliberately refuses this obsolete install;
                // the buddy proves only its own actual native restore.
                return (try? await coordinator.verifyDebugRestore(manifest: installed)) != nil
            }
            return debug.status == .ready
        }
        guard let active = debug.activeManifest else { throw BoundDebugFailure.invalidResponse }
        try record(["sessionID": .string(debugID.uuidString.lowercased()), "generation": .number(Double(active.generation)),
                    "manifestDigest": .string(active.digest), "nativeVerified": .bool(true),
                    "finalCertification": .bool(false), "reviewedCandidateCertificates": .object(reviewed.mapValues(BoundDebugJSON.string))], name: "paired-native-proof", output: output)
        let reportBytes = try debug.exportReport(), report = try BoundDebugJSON(data: reportBytes)
        let reportText = String(decoding: reportBytes, as: UTF8.self)
        XCTAssertEqual(report["sessionID"]?.string.flatMap(UUID.init(uuidString:)), debugID)
        XCTAssertEqual(report["manifestDigest"]?.string, active.digest)
        XCTAssertEqual(report["localValidationOnly"]?.boolean, true)
        for secret in login.accounts.flatMap({ [$0.email, $0.password] }) {
            XCTAssertFalse(reportText.contains(secret), "An exported report must exclude account credentials")
        }
        for forbidden in ["capability", "checkpoint.state", "game.sav", "Authorization", "Bearer "] {
            XCTAssertFalse(reportText.contains(forbidden), "An exported report must exclude credentials and native payloads")
        }
        try reportBytes.write(to: output.appendingPathComponent("sanitized-debug-report.json"), options: .atomic)
        if input.scenario != .staleOrdinarySelection {
            // Initial load settles both ordinary owners again. Take the fence
            // only after both native verifications, before DEBUG-only work.
            let ordinaryBefore = try ordinaryFence(await ordinary.getSave(runID))
            try record(["ordinary": ordinaryBefore], name: "ordinary-before-debug-operation", output: output)
            try await exercise(input, coordinator: coordinator, debug: debug, transport: transport, ordinary: ordinary, core: core, output: output)
            let ordinaryAfter = try ordinaryFence(await ordinary.getSave(runID))
            let returnsOrdinary = [.returnHold, .returnVerifyLostReply, .buddyLeave, .controllerRevoke].contains(input.scenario)
            if !returnsOrdinary {
                XCTAssertEqual(ordinaryAfter, ordinaryBefore, "DEBUG cannot mutate ordinary heads or durable event history")
            }
            // Return intentionally restores ordinary execution. The other
            // owner may already have confirmed its normal final save by now.
            try record(["ordinary": ordinaryAfter, "unchangedChecked": .bool(!returnsOrdinary)], name: "ordinary-after-debug-operation", output: output)
        }
    }

    private func exerciseStoppedFrameReadFault(payload: Data, target: BoundDebugManifest,
        coordinator: BoundROMMultiplayerCoordinator, host: LocalDebugCandidateHost,
        transport: LocalDebugBoundaryTransport, core: EmulatorCore, output: URL) async throws {
        let view = try XCTUnwrap(owner), context = try coordinator.debugContext()
        let source = try XCTUnwrap(BoundMultiplayerSaveStore.shared.manifest(gameID: context.compatibility.gameID))
        guard source.identity.run != target.runID, source.identity.owner == context.session.owner,
              source.deviceOwner == context.deviceID, view.emulatorCore === core,
              !coordinator.debugBlocksCoreResume, host.restoredPayloadCount == 0 else { throw BoundDebugFailure.stale }
        let ordinary = BoundNakamaRunService(); _ = try await ordinary.configureSaves(session: context.session)
        let authority = try await ordinary.getSave(source.identity.run)
        guard authority.identity == source.identity, authority.committed, !authority.cancelled, authority.gameOver == nil else {
            throw BoundDebugFailure.stale
        }
        var cases = [BoundDebugJSON]()
        for alreadyPaused in [false, true] {
            var ownsInspectionPause = false
            defer {
                if ownsInspectionPause, view.emulatorCore === core, core.state == .paused,
                   let current = try? coordinator.debugContext(), context.sameAuthority(as: current),
                   (try? BoundMultiplayerSaveStore.shared.manifest(gameID: source.identity.gameID)) == source,
                   view.boundCanResumeEmulation(resumingNativeActivity: false), !core.resume() {
                    // A defer cannot throw. Leave the failed pause owned and
                    // record it; normal final-save teardown must resolve it.
                    try? record(["alreadyPausedCase": .bool(alreadyPaused), "coreStillPaused": .bool(core.state == .paused)],
                                name: "read-fault-cleanup-resume-failed", output: output)
                }
            }
            let label = alreadyPaused ? "already-paused" : "running"
            trace("Stopped-frame read fault: " + label)
            try await wait("Read fault needs the real running ordinary field", seconds: 10) {
                guard core.state == .running else { return false }
                do { try coordinator.preflightDebugSwitch(); return true }
                catch BoundDebugFailure.busy { return false }
            }
            if alreadyPaused {
                // This inspection pause belongs to the test. If its natural
                // stopped header is already torn, release only our pause via
                // the real UI gate and try a later ordinary frame.
                try await wait("Inspection pause needs a committed native field", seconds: 5) {
                    guard core.state == .running, core.pause() else { throw BoundDebugFailure.busy }
                    ownsInspectionPause = true
                    do { try coordinator.preflightDebugSwitch(); return true }
                    catch BoundDebugFailure.busy {
                        guard view.emulatorCore === core, view.boundCanResumeEmulation(resumingNativeActivity: false), core.resume() else { throw BoundDebugFailure.busy }
                        ownsInspectionPause = false
                        return false
                    }
                }
            }
            let actionsBefore = await transport.snapshot().actions.count
            guard core.state == (alreadyPaused ? .paused : .running) else { throw BoundDebugFailure.busy }
            try coordinator.preflightDebugSwitch()
            let manifestBefore = try BoundMultiplayerSaveStore.shared.manifest(gameID: source.identity.gameID)
            let headBefore = try BoundMultiplayerSaveStore.shared.latestComplete(gameID: source.identity.gameID)?.receipt
            let restoredBefore = host.restoredPayloadCount
            let fault = try LocalDebugStoppedFrameReadFault(core: core)
            var caught: Error?, restoredIMP = false
            do {
                defer { restoredIMP = fault.restore() }
                do { try await coordinator.restoreDebugPayload(payload, manifest: target) }
                catch { caught = error }
            }
            let evidence = fault.snapshot()
            let retainedManifest = try BoundMultiplayerSaveStore.shared.manifest(gameID: source.identity.gameID)
            let retainedHead = try BoundMultiplayerSaveStore.shared.latestComplete(gameID: source.identity.gameID)?.receipt
            let retainedAuthority = context.sameAuthority(as: try coordinator.debugContext())
            let noHold = !coordinator.debugBlocksCoreResume
            let sourceUnchanged = manifestBefore == source && retainedManifest == source && retainedHead == headBefore
            let rejectionValid = (caught as? BoundDebugFailure) == .busy && restoredIMP && evidence.mainReads == 2 &&
                evidence.injected == 1 && evidence.firstPermitted && evidence.injectedWhilePaused &&
                noHold && retainedAuthority && sourceUnchanged && view.emulatorCore === core &&
                host.restoredPayloadCount == restoredBefore && core.state == .paused
            // Record the exact stopped-frame result before yielding to the
            // deferred UI resume callback or any normal checkpoint producer.
            var proof: [String: BoundDebugJSON] = ["case": .string(label), "busy": .bool((caught as? BoundDebugFailure) == .busy),
                "mainReads": .number(Double(evidence.mainReads)), "injections": .number(Double(evidence.injected)),
                "firstNativeReadPermitted": .bool(evidence.firstPermitted), "injectedWhilePaused": .bool(evidence.injectedWhilePaused),
                "originalSecondReadBytes": .number(Double(evidence.originalSecondBytes)), "originalIMPRestored": .bool(restoredIMP),
                "noNewDebugHold": .bool(noHold), "contextAuthorityRetained": .bool(retainedAuthority),
                "sourceManifestAndHeadRetained": .bool(sourceUnchanged), "nativeRestoreCountUnchanged": .bool(host.restoredPayloadCount == restoredBefore),
                "sourceRunID": .string(source.identity.run.uuidString.lowercased()), "targetRunID": .string(target.runID.uuidString.lowercased())]
            try record(proof, name: "stopped-frame-read-fault-" + label, output: output)
            guard rejectionValid else {
                trace("Stopped-frame read fault did not reject before hold/save/native installation")
                throw BoundDebugFailure.nativeVerification
            }
            let actionsAfter = await transport.snapshot().actions
            guard !actionsAfter.dropFirst(actionsBefore).contains("gameplay") else {
                trace("Stopped-frame read rejection issued scoped gameplay/get"); throw BoundDebugFailure.nativeVerification
            }
            proof["noScopedGameplayRequest"] = .bool(true)
            if alreadyPaused {
                try await Task.sleep(for: .milliseconds(100))
                guard core.state == .paused, !coordinator.debugBlocksCoreResume,
                      context.sameAuthority(as: try coordinator.debugContext()) else {
                    trace("Stopped-frame read rejection lost the existing inspection pause"); throw BoundDebugFailure.nativeVerification
                }
                proof["existingPauseRetained"] = .bool(true)
                // Release only our inspection pause, under the same public UI
                // gate used by the ordinary trainer inspection in this test.
                guard view.emulatorCore === core, view.boundCanResumeEmulation(resumingNativeActivity: false), core.resume() else { throw BoundDebugFailure.busy }
                ownsInspectionPause = false
            }
            try await wait("The same ordinary owner must resume through its existing UI gate", seconds: 5) {
                guard core.state == .running, view.emulatorCore === core,
                      context.sameAuthority(as: try coordinator.debugContext()),
                      try BoundMultiplayerSaveStore.shared.manifest(gameID: source.identity.gameID) == source else { return false }
                do { try coordinator.preflightDebugSwitch(); return true }
                catch BoundDebugFailure.busy { return false }
            }
            proof["ordinaryOwnerRunningAfterward"] = .bool(true)
            proof["resumeWasDeferredHostCallback"] = .bool(!alreadyPaused)
            try record(proof, name: "stopped-frame-read-fault-" + label, output: output)
            cases.append(.object(proof))
        }
        let confirmed = try await ordinary.getSave(source.identity.run)
        guard confirmed.identity == authority.identity, confirmed.epoch == authority.epoch,
              confirmed.committed, !confirmed.cancelled, confirmed.gameOver == nil,
              context.sameAuthority(as: try coordinator.debugContext()) else { throw BoundDebugFailure.stale }
        try record(["version": .number(1), "cases": .array(cases), "ordinaryOwnershipEpochRetained": .bool(true),
                    "nativeMemoryModifiedByFault": .bool(false), "authoritySuppliedByFault": .bool(false),
                    "reviewedPayloadSHA256": .string(BoundMultiplayerSaveStore.hash(payload))],
                   name: "stopped-frame-read-fault-proof", output: output)
    }

    private func ordinaryFence(_ state: BoundNakamaRunService.IndependentState) throws -> BoundDebugJSON {
        .object(["identity": try .wire(state.identity), "epoch": .number(Double(state.epoch)),
            "committed": .bool(state.committed), "cancelled": .bool(state.cancelled),
            "gameOver": try state.gameOver.map { try .wire($0) } ?? .null,
            "heads": .object(try state.saves.mapValues { try .wire($0.receipt) }),
            "cursor": try .wire(state.serverCursor)])
    }

    private func exerciseStaleSelection(_ input: Input, coordinator: BoundROMMultiplayerCoordinator, debug: BoundDebugSession,
                                       transport: LocalDebugBoundaryTransport, game: Game, options: BoundMultiplayerSetupOptions,
                                       core: EmulatorCore, output: URL) async throws {
        guard let unrelated = input.unrelatedOrdinaryRunID, unrelated != input.ordinaryRunID else {
            throw XCTSkip("Awaiting a second task-owned ordinary run with a real current native checkpoint")
        }
        guard let host = candidateHost else { throw BoundDebugFailure.unavailable }
        let priorContext = try coordinator.debugContext()
        await transport.arm("download", fault: .holdReply)
        let pending = Task { await debug.load(source: .init(kind: .builtin, pointID: "01", fixtureVersion: BoundDebugCatalog.fixtureVersion), settings: options.settings) }
        defer { pending.cancel() }
        try await wait("Initial DEBUG upload must commit before its delayed native download", seconds: 120) { await transport.snapshot().held }
        _ = await coordinator.selectServerRun(unrelated)
        guard let selected = try BoundMultiplayerSaveStore.shared.manifest(gameID: game.identifier)?.identity,
              selected.run == unrelated, core.state == .paused || core.pause() else {
            trace("Stale selection did not establish the unrelated paused native run"); throw BoundDebugFailure.nativeVerification
        }
        let before = try nativeRAM(core)
        await transport.release(); await pending.value
        let currentContext = try? coordinator.debugContext()
        let invalidated = debug.serverSession == nil || currentContext.map { !priorContext.sameAuthority(as: $0) } == true
        guard debug.failure == .stale || debug.failure == nil && invalidated else {
            trace("Stale download lacked an explicit rejection or authority invalidation"); throw BoundDebugFailure.nativeVerification
        }
        let beforeReconcile = await transport.snapshot()
        guard host.restoredPayloadCount == 0, !beforeReconcile.actions.contains("verify"),
              try BoundMultiplayerSaveStore.shared.manifest(gameID: game.identifier)?.identity == selected,
              !coordinator.debugBlocksCoreResume, try nativeRAM(core) == before else {
            trace("Obsolete download changed the unrelated native execution"); throw BoundDebugFailure.nativeVerification
        }
        await debug.reconcile()
        let afterReconcile = await transport.snapshot()
        guard host.restoredPayloadCount == 0, !afterReconcile.actions.contains("verify"),
              try BoundMultiplayerSaveStore.shared.manifest(gameID: game.identifier)?.identity == selected,
              !coordinator.debugBlocksCoreResume, try nativeRAM(core) == before else {
            trace("Reconcile installed obsolete intent over an unrelated run"); throw BoundDebugFailure.nativeVerification
        }
        try record(["scenario": .string(input.scenario.rawValue), "unrelatedRunID": .string(unrelated.uuidString.lowercased()),
                    "staleInstallRejected": .bool(true), "authorityInvalidated": .bool(invalidated), "reconcilePreservedExecution": .bool(true),
                    "successfulDebugRestores": .number(Double(host.restoredPayloadCount)), "nativeVerifySent": .bool(false),
                    "nativeRAMSHA256": .string(BoundMultiplayerSaveStore.hash(before))], name: "boundary-proof", output: output)
    }

    private func exercise(_ input: Input, coordinator: BoundROMMultiplayerCoordinator, debug: BoundDebugSession,
                          transport: LocalDebugBoundaryTransport, ordinary: BoundNakamaRunService, core: EmulatorCore, output: URL) async throws {
        if input.scenario == .customCommitLossPrepare {
            try await prepareRestart(input, coordinator: coordinator, debug: debug, transport: transport, core: core, output: output)
            return
        }
        if input.scenario == .reloadBuiltin || input.scenario == .reloadCustom {
            try await exerciseReload(input, coordinator: coordinator, debug: debug, transport: transport, core: core, output: output)
            return
        }
        if input.scenario == .buddyLeave || input.scenario == .controllerRevoke {
            try await exerciseRevocation(input, coordinator: coordinator, debug: debug, core: core, output: output)
            return
        }
        guard input.role == "controller" else {
            let generation = debug.activeManifest?.generation
            try await wait("Controller boundary scenario must finish", seconds: 120) {
                await debug.reconcile()
                guard !coordinator.debugBlocksCoreResume else { return false }
                if debug.serverSession?.status == .revoked { return true }
                await debug.refreshCaptures()
                if !debug.captures.isEmpty { return true }
                var observed = await transport.snapshot()
                if input.scenario == .customLostReply, let sessionID = debug.serverSession?.sessionID {
                    // An abort clears activeOperationID. Query the exact
                    // operation already observed from the server, so returning
                    // to the prior active manifest cannot hide its outcome.
                    let context = try coordinator.debugContext()
                    var candidates = observed.customOperations
                    // The runner may carry the exact controller-observed ID
                    // across processes. It conveys no authority or outcome;
                    // every candidate still needs an authenticated status RPC.
                    let handoffURL = root.appendingPathComponent("native-handoffs").appendingPathComponent(input.attemptID.uuidString + ".json")
                    if FileManager.default.fileExists(atPath: handoffURL.path) {
                        let handoff = try BoundDebugJSON(data: Data(contentsOf: handoffURL), limit: 1024)
                        guard Set(handoff.object?.keys.map { $0 } ?? []) == Set(["version", "sessionID", "scenario", "operationID"]),
                              handoff["version"]?.integer == 1, handoff["scenario"]?.string == input.scenario.rawValue,
                              handoff["sessionID"]?.string.flatMap(UUID.init(uuidString:)) == sessionID,
                              let id = handoff["operationID"]?.string.flatMap(UUID.init(uuidString:)) else { throw BoundDebugFailure.rejected }
                        candidates.insert(id)
                    }
                    for operationID in candidates.subtracting(observed.abortedCustomOperations) {
                        _ = try await transport.request(["action": .string("status"), "sessionID": .string(sessionID.uuidString.lowercased()),
                            "operationID": .string(operationID.uuidString.lowercased())], session: context.session, timeout: 1)
                    }
                    observed = await transport.snapshot()
                }
                if input.scenario == .customLostReply, !observed.abortedCustomOperations.isEmpty,
                   let active = debug.activeManifest, active.generation == generation,
                   debug.serverSession?.currentGeneration == generation,
                   debug.serverSession?.currentManifestDigest == active.digest {
                    return (try? await coordinator.verifyDebugRestore(manifest: active)) != nil
                }
                return false
            }
            return
        }
        if input.scenario == .unseenPeerDeath {
            throw XCTSkip("Awaiting coordinated native buddy-loss input and delayed peer upload; no synthetic death or native verification is fabricated")
        }
        guard let owner else { throw BoundDebugFailure.unavailable }
        let initialManifest = try XCTUnwrap(debug.activeManifest)
        let ordinaryBookmark = try XCTUnwrap(debug.bookmark)
        if input.scenario == .returnVerifyLostReply {
            trace("Exercise lost Return verification reply")
            await transport.arm("returnVerify", fault: .loseReplyAndRecovery)
            let returning = Task { await debug.returnToPreviousRun() }
            try await wait("Actual ordinary restore must reach returnVerify", seconds: 45) { await transport.snapshot().held }
            await returning.value
            XCTAssertEqual(try BoundMultiplayerSaveStore.shared.manifest(gameID: ordinaryBookmark.identity.gameID)?.identity, ordinaryBookmark.identity)
            XCTAssertFalse(coordinator.debugBlocksCoreResume)
            let initialFrame = try XCTUnwrap(MultiRedAdapter.readSetupRequest()?.frame)
            if core.state == .paused {
                guard owner.emulatorCore === core, owner.boundCanResumeEmulation(resumingNativeActivity: false), core.resume() else {
                    throw BoundDebugFailure.busy
                }
            }
            try await wait("Returned ordinary execution must make native progress") {
                guard let frame = MultiRedAdapter.readSetupRequest()?.frame else { return false }
                return frame &- initialFrame >= 20
            }
            // Automatic checkpoint capture pauses the real core. That pause
            // must not feed another save request back into the next timer tick.
            // One already-due ordinary checkpoint is allowed; repeated heads
            // during this idle two-second window expose the callback loop.
            let headWindowStart = ProcessInfo.processInfo.systemUptime
            var observedHeads = Set<UUID>()
            while ProcessInfo.processInfo.systemUptime - headWindowStart < 2 {
                let ordinaryState = try await ordinary.getSave(ordinaryBookmark.identity.run)
                XCTAssertEqual(ordinaryState.identity, ordinaryBookmark.identity)
                let receipt = try XCTUnwrap(ordinaryState.saves[ordinaryBookmark.identity.owner.uuidString.lowercased()]?.receipt)
                observedHeads.insert(receipt.checkpoint)
                try await Task.sleep(for: .milliseconds(200))
            }
            try record(["observedHeadCount": .number(Double(observedHeads.count)),
                        "elapsedSeconds": .number(ProcessInfo.processInfo.systemUptime - headWindowStart),
                        "ordinaryCoreRunning": .bool(core.state == .running)], name: "ordinary-save-feedback-check", output: output)
            XCTAssertLessThanOrEqual(observedHeads.count, 2, "Checkpoint capture must not recursively request another automatic save")
            guard core.state == .paused || core.pause() else { throw BoundDebugFailure.busy }
            let progressedFrame = try XCTUnwrap(MultiRedAdapter.readSetupRequest()?.frame)
            await transport.release()
            try await wait("Return verification must reconcile after its lost reply") {
                await debug.reconcile()
                return debug.failure == nil && debug.activeManifest == nil
            }
            XCTAssertEqual(core.state, .paused, "Verification retry must not restore and resume an already returned core")
            XCTAssertEqual(MultiRedAdapter.readSetupRequest()?.frame, progressedFrame, "Ordinary native progress must survive verification retry")
            XCTAssertEqual(try MultiRedAdapter.debugTrainer(core: core).id, ordinaryBookmark.identity.localSeed)
            try record(["scenario": .string(input.scenario.rawValue), "scenarioOutcomeVerified": .bool(true),
                        "initialFrame": .number(Double(initialFrame)), "retainedFrame": .number(Double(progressedFrame)),
                        "ordinaryProgressPreserved": .bool(true), "resolvedThroughReconcile": .bool(true)], name: "boundary-proof", output: output)
            return
        }
        await debug.refreshCaptures()
        let originalCaptures = Set(debug.captures.map(\.id))
        XCTAssertFalse(coordinator.debugBlocksCoreResume)
        guard owner.emulatorCore === core, owner.boundCanResumeEmulation(resumingNativeActivity: false) else {
            throw BoundDebugFailure.busy
        }
        let returning = input.scenario == .returnHold, losing = input.scenario == .customLostReply
        await transport.arm(returning ? "returnReady" : "captureReady", fault: losing ? .loseReplyAndRecovery : .holdReply)
        var admissionFailure: Error?
        let operation = Task {
            do {
                try await invokeReadyBoundary(coordinator: coordinator, debug: debug, transport: transport, output: output) {
                    if returning { await debug.returnToPreviousRun() } else { await debug.saveCustom() }
                }
            } catch { admissionFailure = error }
        }
        defer { operation.cancel() }
        try await wait("Native boundary request must reach the real server", seconds: 30) {
            if let admissionFailure { throw admissionFailure }
            return await transport.snapshot().held
        }
        let accepted = await transport.snapshot().accepted
        let operationID = try XCTUnwrap(accepted?["operation"]?["operationID"]?.string.flatMap(UUID.init(uuidString:)))
        if losing, let sessionID = input.debugSessionID {
            try record(["version": .number(1), "sessionID": .string(sessionID.uuidString.lowercased()),
                        "scenario": .string(input.scenario.rawValue), "operationID": .string(operationID.uuidString.lowercased())],
                       name: "boundary-operation", output: output)
        }
        XCTAssertEqual(core.state, .paused); XCTAssertTrue(coordinator.debugBlocksCoreResume)
        let ram = try nativeRAM(core), ledger = owner.boundCompanionForTesting.sharing.soulLink.probe.read().ledger
        XCTAssertFalse(owner.boundCanResumeEmulation(resumingNativeActivity: false))
        XCTAssertFalse(owner.gameViewControllerShouldResumeEmulation(owner))
        XCTAssertFalse(coordinator.suspend(), "A held source cut or partial restore cannot become a final save")
        XCTAssertFalse(coordinator.prepareForCoreReplacement(), "Core replacement must retain the held execution")
        coordinator.setServiceActive(false, temporary: true)
        XCTAssertEqual(core.state, .paused); XCTAssertEqual(try nativeRAM(core), ram)
        coordinator.setServiceActive(true, temporary: true)
        coordinator.resumeAfterDebugSwitch?()
        await Task.yield()
        XCTAssertEqual(core.state, .paused); XCTAssertEqual(try nativeRAM(core), ram)
        if losing {
            await operation.value
            XCTAssertTrue(coordinator.debugBlocksCoreResume, "Lost fence and abort replies cannot release native execution")
            XCTAssertEqual(owner.boundCompanionForTesting.sharing.soulLink.probe.read().ledger, ledger)
            XCTAssertEqual(try nativeRAM(core), ram)
        }
        await transport.release()
        await operation.value
        try await wait("Authoritative abort/commit must resolve the held boundary", seconds: 30) {
            await debug.reconcile(); return !coordinator.debugBlocksCoreResume
        }
        if returning {
            XCTAssertEqual(debug.serverSession?.status, .revoked)
            XCTAssertEqual(try BoundMultiplayerSaveStore.shared.manifest(gameID: ordinaryBookmark.identity.gameID)?.identity, ordinaryBookmark.identity)
        } else if losing {
            try await wait("Lost reply must resolve to the exact confirmed abort") {
                await debug.reconcile()
                return await transport.snapshot().abortedCustomOperations.contains(operationID)
            }
            XCTAssertEqual(debug.activeManifest?.digest, initialManifest.digest)
        } else {
            try await wait("Successful custom capture must publish the exact new archive", seconds: 60) {
                await debug.reconcile(); await debug.refreshCaptures()
                return debug.captures.contains { $0.id == operationID && !originalCaptures.contains($0.id) }
            }
            XCTAssertEqual(debug.activeManifest?.digest, initialManifest.digest)
            XCTAssertEqual(debug.activeManifest?.generation, initialManifest.generation)
        }
        try record(["scenario": .string(input.scenario.rawValue), "heldNativeRAMSHA256": .string(BoundMultiplayerSaveStore.hash(ram)),
                    "operationID": .string(operationID.uuidString.lowercased()), "scenarioOutcomeVerified": .bool(true),
                    "uiResumeDenied": .bool(true), "serverAccepted": .bool(true), "resolvedThroughReconcile": .bool(true)], name: "boundary-proof", output: output)
    }

    private func prepareOrdinaryTermination(_ input: Input, coordinator: BoundROMMultiplayerCoordinator,
                                             ordinary: BoundNakamaRunService, core: EmulatorCore,
                                             identity: BoundMultiplayerRunIdentity, output: URL) async throws {
        let view = try XCTUnwrap(owner)
        coordinator.setServiceActive(true)
        if core.state == .paused {
            guard view.emulatorCore === core, view.boundCanResumeEmulation(resumingNativeActivity: false),
                  core.resume() else { throw BoundDebugFailure.busy }
        }
        try await wait("Native field must admit the checkpoint preceding process death") {
            core.state == .running && coordinator.probe.read()?.permitsFieldInterruption == true
        }
        trace("Hold accepted ordinary checkpoint before intentional process death")
        LocalOrdinarySaveDelivery.arm(run: identity.run, fault: .hold)
        core.save()
        try await wait("Termination requires a real accepted automatic seal", seconds: 45) {
            LocalOrdinarySaveDelivery.snapshot().reached
        }
        let checkpoint = try XCTUnwrap(LocalOrdinarySaveDelivery.snapshot().checkpoint)
        let state = try await ordinary.getSave(identity.run)
        let own = try XCTUnwrap(state.saves[identity.owner.uuidString.lowercased()])
        let package = try await ordinary.downloadIndependent(identity: identity, upload: own)
        let delivery = LocalOrdinarySaveDelivery.snapshot()
        guard state.identity == identity, own.receipt.checkpoint == checkpoint,
              own.receipt.owner == identity.owner, package.receipt == own.receipt,
              package.payload.manifest.identity == identity,
              let battery = package.payload.files["game.sav"]?.data, battery.count == 131_072,
              let nativeState = package.payload.files["checkpoint.state"]?.data, nativeState.count > 1024,
              delivery.reached, !delivery.delivered, delivery.checkpoint == checkpoint,
              !FileManager.default.fileExists(atPath: output.appendingPathComponent("final-native-save.json").path),
              previousExperimental == nil || previousExperimental is Bool else { throw BoundDebugFailure.nativeVerification }
        // Only this credential-free, atomically persisted marker authorizes
        // the runner's deliberate process termination. Do not release the
        // reply or run final-save teardown on the successful prepare path.
        try record(["version": .number(1), "attemptID": .string(input.attemptID.uuidString), "role": .string(input.role),
                    "processID": .number(Double(getpid())), "receipt": try .wire(own.receipt),
                    "acceptedPackageDownloaded": .bool(true), "responseDelivered": .bool(false),
                    "finalSaveTeardownStarted": .bool(false),
                    "batterySHA256": .string(BoundMultiplayerSaveStore.hash(battery)),
                    "stateSHA256": .string(BoundMultiplayerSaveStore.hash(nativeState)),
                    "previousExperimental": (previousExperimental as? Bool).map(BoundDebugJSON.bool) ?? .null],
                   name: "ordinary-termination-prepared", output: output)
        trace("Await runner termination without delivering accepted seal or final-save teardown")
        try await wait("Runner must intentionally terminate the prepared process", seconds: 90) {
            guard !LocalOrdinarySaveDelivery.snapshot().delivered else { throw BoundDebugFailure.stale }
            return false
        }
    }

    private func exerciseOrdinaryRecovery(_ input: Input, coordinator: BoundROMMultiplayerCoordinator,
                                          ordinary: BoundNakamaRunService, core: EmulatorCore,
                                          identity: BoundMultiplayerRunIdentity, output: URL) async throws {
        let view = try XCTUnwrap(owner)
        func resumeOwnedPause() throws {
            coordinator.setServiceActive(true)
            if core.state == .paused {
                guard view.emulatorCore === core, view.boundCanResumeEmulation(resumingNativeActivity: false),
                      core.resume() else { throw BoundDebugFailure.busy }
            }
        }
        try resumeOwnedPause()
        try await wait("Ordinary field must admit manual native saving") {
            coordinator.probe.read()?.permitsFieldInterruption == true && core.state == .running
        }
        trace("Hold an authenticated ordinary automatic save reply")
        LocalOrdinarySaveDelivery.arm(run: identity.run, fault: .hold)
        core.save()
        do {
            try await wait("Real automatic saveSeal must reach the authenticated backend", seconds: 45) {
                LocalOrdinarySaveDelivery.snapshot().reached
            }
        } catch {
            var diagnostic = LocalOrdinarySaveDelivery.diagnostics()
            diagnostic["coreRunning"] = .bool(core.state == .running)
            diagnostic["fieldSafe"] = .bool(coordinator.probe.read()?.permitsFieldInterruption == true)
            diagnostic["serverMenuError"] = coordinator.serverMenuError.map(BoundDebugJSON.string) ?? .null
            if let host = Mirror(reflecting: coordinator).children.first(where: { $0.label == "host" })?.value as? BoundROMHostState {
                diagnostic["hostMessage"] = .string(host.message)
            }
            try record(diagnostic, name: "ordinary-delivery-diagnostic", output: output)
            throw error
        }
        let held = try XCTUnwrap(LocalOrdinarySaveDelivery.snapshot().checkpoint)
        let confirmedWhileHeld = try await ordinary.getSave(identity.run)
        XCTAssertEqual(confirmedWhileHeld.saves[identity.owner.uuidString.lowercased()]?.receipt.checkpoint, held)
        XCTAssertFalse(LocalOrdinarySaveDelivery.snapshot().delivered)

        // Queue a newer native save while the old reply is held, then use the
        // real temporary-background boundary. Inactive services cannot capture
        // the pending cut, even though the previous native request was safe.
        coordinator.nativeServerSaveRequested(core: core)
        coordinator.setServiceActive(false, temporary: true)
        XCTAssertEqual(core.state, .paused)
        LocalOrdinarySaveDelivery.release()
        try await wait("Held seal reply must be delivered") { LocalOrdinarySaveDelivery.snapshot().delivered }
        try await Task.sleep(for: .milliseconds(300))
        let host = try XCTUnwrap(Mirror(reflecting: coordinator).children.first { $0.label == "host" }?.value as? BoundROMHostState,
                                "Read-only observation of the actual native save status")
        let falseSuccess = host.status == .complete && host.message == "Saved to server."
        try record(["runID": .string(identity.run.uuidString), "checkpoint": .string(held.uuidString),
                    "serverAcceptedBeforeReply": .bool(true), "newerNativeSavePending": .bool(true),
                    "corePaused": .bool(core.state == .paused), "reportedMessage": .string(host.message),
                    "falseSaveSuccess": .bool(falseSuccess)], name: "ordinary-held-reply", output: output)
        XCTAssertFalse(falseSuccess, "An older upload cannot report Saved while a newer background checkpoint remains uncaptured")

        trace("Reactivate the same native owner after the held reply")
        let previousFrame = coordinator.probe.read()?.frame
        try resumeOwnedPause()
        try await wait("Native frames must resume after the temporary interruption") {
            core.state == .running && coordinator.probe.read()?.frame != previousFrame
        }
        var settled: BoundDebugBookmark?
        try await wait("The newer pending checkpoint must settle", seconds: 45) {
            do { settled = try await coordinator.settleForDebugSwitch(); return true }
            catch BoundDebugFailure.busy { return false }
        }
        let afterHeld = try XCTUnwrap(settled?.receipt)
        XCTAssertNotEqual(afterHeld.checkpoint, held)
        XCTAssertEqual(afterHeld.owner, identity.owner)
        let afterHeldState = try await ordinary.getSave(identity.run)
        XCTAssertEqual(afterHeldState.saves[identity.owner.uuidString.lowercased()]?.receipt, afterHeld)

        trace("Lose an accepted authenticated ordinary seal reply")
        LocalOrdinarySaveDelivery.arm(run: identity.run, fault: .lose)
        core.save()
        try await wait("Real automatic seal must be accepted before losing its reply", seconds: 45) {
            LocalOrdinarySaveDelivery.snapshot().reached
        }
        let lost = try XCTUnwrap(LocalOrdinarySaveDelivery.snapshot().checkpoint)
        let accepted = try await ordinary.getSave(identity.run)
        XCTAssertEqual(accepted.saves[identity.owner.uuidString.lowercased()]?.receipt.checkpoint, lost)
        LocalOrdinarySaveDelivery.release()
        try await wait("Lost reply recovery must settle the same ordinary owner", seconds: 45) {
            do { settled = try await coordinator.settleForDebugSwitch(); return true }
            catch BoundDebugFailure.busy { return false }
        }
        let recovered = try XCTUnwrap(settled?.receipt)
        let state = try await ordinary.getSave(identity.run)
        guard state.identity == identity, state.saves[identity.owner.uuidString.lowercased()]?.receipt == recovered,
              recovered.owner == identity.owner, !coordinator.hasUnconfirmedServerSave else { throw BoundDebugFailure.nativeVerification }
        let downloaded = try await ordinary.downloadIndependent(identity: identity,
            upload: try XCTUnwrap(state.saves[identity.owner.uuidString.lowercased()]))
        XCTAssertEqual(downloaded.receipt, recovered)
        XCTAssertEqual(downloaded.payload.manifest.identity.owner, identity.owner)
        try record(["acceptedCheckpointWithLostReply": .string(lost.uuidString), "confirmedReceipt": try .wire(recovered),
                    "ownerPreserved": .bool(true), "nativeFramesRecovered": .bool(true),
                    "interruption": .string("actual coordinator temporary-background lifecycle; not OS suspension"),
                    "processID": .number(Double(getpid()))], name: "ordinary-recovery-proof", output: output)
        if input.exerciseOSBackground == true {
            trace("Await actual OS background while an ordinary seal reply is held")
            let transitions = LocalOrdinaryApplicationTransitions()
            let notifications = NotificationCenter.default
            let background = notifications.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
                transitions.background()
            }
            let active = notifications.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
                transitions.active()
            }
            defer { notifications.removeObserver(background); notifications.removeObserver(active) }
            LocalOrdinarySaveDelivery.arm(run: identity.run, fault: .hold)
            core.save()
            try await wait("OS interruption must start with an actual held saveSeal", seconds: 45) {
                LocalOrdinarySaveDelivery.snapshot().reached
            }
            coordinator.nativeServerSaveRequested(core: core)
            let process = getpid()
            try record(["attemptID": .string(input.attemptID.uuidString), "role": .string(input.role),
                        "processID": .number(Double(process))], name: "ordinary-background-request", output: output)
            try await wait("The app must observe real OS background and foreground", seconds: 45) {
                let observed = transitions.snapshot()
                return observed.background && observed.active && UIApplication.shared.applicationState == .active &&
                    FileManager.default.fileExists(atPath: output.appendingPathComponent("ordinary-background-ack.json").path)
            }
            let ack = try BoundDebugJSON(data: Data(contentsOf: output.appendingPathComponent("ordinary-background-ack.json")))
            guard ack["attemptID"]?.string.flatMap(UUID.init(uuidString:)) == input.attemptID,
                  ack["role"]?.string == input.role, ack["backgroundExit"]?.integer == 0,
                  ack["foregroundExit"]?.integer == 0, getpid() == process else { throw BoundDebugFailure.stale }
            LocalOrdinarySaveDelivery.release()
            try resumeOwnedPause()
            let frame = coordinator.probe.read()?.frame
            try await wait("Native frames must recover after actual OS foreground") {
                core.state == .running && coordinator.probe.read()?.frame != frame
            }
            try await wait("OS-interrupted newer native checkpoint must be confirmed", seconds: 45) {
                do { settled = try await coordinator.settleForDebugSwitch(); return true }
                catch BoundDebugFailure.busy { return false }
            }
            let finalReceipt = try XCTUnwrap(settled?.receipt)
            let finalState = try await ordinary.getSave(identity.run)
            guard finalState.saves[identity.owner.uuidString.lowercased()]?.receipt == finalReceipt else { throw BoundDebugFailure.nativeVerification }
            try record(["observedOSBackground": .bool(transitions.snapshot().background),
                        "observedOSForeground": .bool(transitions.snapshot().active),
                        "sameProcess": .bool(getpid() == process), "nativeFramesRecovered": .bool(true),
                        "confirmedReceipt": try .wire(finalReceipt)], name: "ordinary-background-proof", output: output)
        }
    }

    private func finish(output: URL) async throws {
        trace("Preserve final native checkpoint before teardown")
        LocalOrdinarySaveDelivery.release()
        await transport?.release()
        defer {
            if owner == nil {
                UserDefaults.standard.set(previousExperimental, forKey: BoundMultiplayerFeatures.key)
                NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
            }
        }
        guard let owner else { return }
        let companion = owner.boundCompanionForTesting, coordinator = companion.romMultiplayer
        if coordinator.debugBlocksCoreResume { await coordinator.debugSession.reconcile() }
        let manifest = try (owner.game as? Game).flatMap { try BoundMultiplayerSaveStore.shared.manifest(gameID: $0.identifier) }
        let receipt: LocalDebugFinalReceipt?
        if let identity = manifest?.identity {
            if finalReceipt?.identity != identity { finalReceipt = .init(identity: identity) }
            receipt = finalReceipt
        } else { receipt = nil }
        let observer = receipt.map { receipt in
            NotificationCenter.default.addObserver(forName: BoundServerDisconnectSave.didFinish, object: nil, queue: nil) { receipt.receive($0) }
        }
        defer { if let observer { NotificationCenter.default.removeObserver(observer) } }
        try await wait("Teardown must preserve the normal final checkpoint and retained observations", seconds: 30) {
            coordinator.prepareForCoreReplacement()
        }
        if let receipt {
            trace("Await exact final native save receipt")
            // The public flag starts false before enqueue; it alone cannot
            // prove completion. Observe the exact authenticated save result,
            // then independently read that head before invalidating credentials.
            try await wait("Final native checkpoint must be confirmed before sign-out", seconds: 30) {
                let value = receipt.read()
                guard !value.failed, !coordinator.hasUnconfirmedServerSave,
                      BoundServerDisconnectSave.failureMessage(run: receipt.identity.run) == nil else {
                    try record([
                        "identity": try .wire(receipt.identity),
                        "receiptFailed": .bool(value.failed),
                        "receiptCheckpoint": value.checkpoint.map { .string($0.uuidString) } ?? .null,
                        "receiptMessage": value.message.map(BoundDebugJSON.string) ?? .null,
                        "unconfirmedServerSave": .bool(coordinator.hasUnconfirmedServerSave),
                        "failureMessage": BoundServerDisconnectSave.failureMessage(run: receipt.identity.run).map(BoundDebugJSON.string) ?? .null,
                        "serverMenuError": coordinator.serverMenuError.map(BoundDebugJSON.string) ?? .null
                    ], name: "final-save-failure-detail", output: output)
                    // Keep a failed synthetic execution inspectable after
                    // XCTest ends its process. These are diagnostic copies,
                    // never a fabricated receipt or a replacement checkpoint.
                    if owner.emulatorCore?.state == .paused {
                        try MultiRedAdapter.captureState().write(to: output.appendingPathComponent("final-save-failure.state"), options: .atomic)
                        try BoundVBABattleBridge.captureServerBattery().write(to: output.appendingPathComponent("final-save-failure.sav"), options: .atomic)
                        let memory = BoundServerMemoryFiles.snapshot(gameID: receipt.identity.gameID)
                        try JSONEncoder().encode(memory).write(to: output.appendingPathComponent("final-save-failure-memory.json"), options: .atomic)
                    }
                    throw BoundDebugFailure.storage
                }
                return value.checkpoint != nil
            }
            let session = try XCTUnwrap(companion.account.session)
            let client: BoundNakamaRunService
            if coordinator.debugSession.activeManifest?.runID == receipt.identity.run {
                client = try coordinator.debugSession.makeRunService(identity: receipt.identity)
            } else {
                client = BoundNakamaRunService()
                _ = try await client.configureSaves(session: session)
            }
            let state = try await client.getSave(receipt.identity.run)
            let confirmed = try XCTUnwrap(state.saves[receipt.identity.owner.uuidString.lowercased()])
            let final = receipt.read()
            guard state.identity == receipt.identity, confirmed.receipt.checkpoint == final.checkpoint,
                  !final.failed, !coordinator.hasUnconfirmedServerSave,
                  BoundServerDisconnectSave.failureMessage(run: receipt.identity.run) == nil else {
                throw BoundDebugFailure.storage
            }
            try record(["receipt": try .wire(confirmed.receipt), "confirmedBeforeSignOut": .bool(true),
                        "processID": .number(Double(getpid()))], name: "final-native-save", output: output)
        }
        let previousCore = owner.emulatorCore
        owner.game = nil
        guard owner.game == nil, previousCore == nil || previousCore?.state == .stopped else {
            throw BoundDebugFailure.busy
        }
        if ownsAccountSession { companion.account.signOut(); ownsAccountSession = false }
        window?.isHidden = true; window?.rootViewController = nil; window = nil; previousWindow?.makeKeyAndVisible()
        self.owner = nil
        candidateHost = nil
    }
}
