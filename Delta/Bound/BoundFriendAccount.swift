import Foundation
import Combine
import Security
#if canImport(UIKit)
import UIKit
#endif

/// Build-time selection keeps existing installs on the current backend until cutover.
/// An explicit invalid override never falls back to another account authority.
struct BoundBackendConfiguration: Equatable, Sendable {
    enum Kind: String, Sendable { case legacy, selfhost }
    static let legacyOrigin = "https://qevnxhngdtlyihhmvnjv.supabase.co"
    static let bundled = try? resolve(info: Bundle.main.infoDictionary ?? [:])
    let kind: Kind
    let origin: String

    static func resolve(info: [String: Any]) throws -> Self {
        func setting(_ key: String, placeholder: String) throws -> String? {
            guard let value = info[key] else { return nil }
            guard let text = value as? String else { throw BoundFriendError.unavailable }
            if text.isEmpty || text == placeholder { return nil }
            return text
        }
        let selected = try setting("BoundBackendKind", placeholder: "$(BOUND_BACKEND_KIND)")
        let endpoint = try setting("BoundBackendURL", placeholder: "$(BOUND_BACKEND_URL)")
        guard let kind = Kind(rawValue: selected ?? "legacy") else { throw BoundFriendError.unavailable }
        if kind == .legacy {
            guard endpoint == nil || endpoint == legacyOrigin else { throw BoundFriendError.unavailable }
            return Self(kind: kind, origin: legacyOrigin)
        }
        guard let endpoint, endpoint.utf8.count <= 2048,
              let components = URLComponents(string: endpoint), components.scheme == "https",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port == nil || components.port == 443,
              components.path.isEmpty || components.path == "/",
              let host = components.host, !host.isEmpty, host == host.lowercased(),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") &&
                  $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }), components.url != nil else { throw BoundFriendError.unavailable }
        let origin = "https://" + host
        guard origin != legacyOrigin else { throw BoundFriendError.unavailable }
        return Self(kind: kind, origin: origin)
    }
    static func current() throws -> Self {
        guard let bundled else { throw BoundFriendError.unavailable }
        return bundled
    }
    func url(path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: origin + path), url.scheme == "https", url.host == URL(string: origin)?.host else {
            throw BoundFriendError.unavailable
        }
        return url
    }
    func applyAPIKey(_ key: String, to request: inout URLRequest) {
        if kind == .legacy { request.setValue(key, forHTTPHeaderField: "apikey") }
    }
    func claims(_ claims: [String: Any]) -> [String: Any] {
        kind == .selfhost ? (claims["vrs"] as? [String: Any] ?? [:]) : claims
    }
}

/// A session-scoped snapshot lets existing friend-service holders use renewed credentials.
/// Signing out invalidates all copies, without affecting a different account instance.
struct AppCloudSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let owner: UUID
    private let key: String
    private let backend: BoundBackendConfiguration
    private let snapshot: Snapshot
    var expiresAt: Date { snapshot.read().expiry }

    private final class Snapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        private var expiry: Date
        init(token: String, expiry: Date) { self.token = token; self.expiry = expiry }
        func read() -> (token: String?, expiry: Date) {
            lock.lock(); defer { lock.unlock() }
            return (token, expiry)
        }
        func update(token: String?, expiry: Date) {
            lock.lock(); defer { lock.unlock() }
            self.token = token; self.expiry = expiry
        }
    }

    init(owner: UUID, key: String, token: String, backend: BoundBackendConfiguration? = nil) throws {
        try self.init(owner: owner, key: key, token: token, allowExpired: false, backend: backend)
    }
    fileprivate init(owner: UUID, key: String, token: String, allowExpired: Bool,
                     backend: BoundBackendConfiguration? = nil) throws {
        let backend = try backend ?? BoundBackendConfiguration.current()
        let expiry = try Self.expiry(token: token, owner: owner, backend: backend)
        guard allowExpired || expiry > Date() else { throw BoundFriendError.signIn }
        self.owner = owner; self.key = key; self.backend = backend
        snapshot = Snapshot(token: token, expiry: expiry)
    }
    private static func expiry(token: String, owner: UUID, backend: BoundBackendConfiguration) throws -> Date {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }), token.utf8.count <= 16384 else { throw BoundFriendError.signIn }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded),
              let claims = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let expiry = claims["exp"] as? Double, expiry.isFinite,
              claims[backend.kind == .selfhost ? "uid" : "sub"] as? String == owner.uuidString.lowercased() else { throw BoundFriendError.signIn }
        return Date(timeIntervalSince1970: expiry)
    }
    fileprivate func renew(token: String) throws {
        let expiry = try Self.expiry(token: token, owner: owner, backend: backend)
        guard expiry > Date() else { throw BoundFriendError.signIn }
        snapshot.update(token: token, expiry: expiry)
    }
    fileprivate func invalidate() { snapshot.update(token: nil, expiry: .distantPast) }
    func credentials() throws { _ = try validToken() }
    func isSameSession(as other: AppCloudSession?) -> Bool {
        guard let other else { return false }
        return owner == other.owner && snapshot === other.snapshot && (try? credentials()) != nil
    }
    private func validToken() throws -> String {
        let value = snapshot.read()
        guard let token = value.token, value.expiry > Date() else { throw BoundFriendError.signIn }
        return token
    }
    private func request(path: String, body: [String: Any]) throws -> URLRequest {
        let token = try validToken()
        var request = URLRequest(url: try backend.url(path: path))
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        backend.applyAPIKey(key, to: &request)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func friendOnboardingRequest(action: String, payload: [String: String]) throws -> URLRequest {
        try request(path: "/rest/v1/rpc/cup050_friends", body: ["action": action, "payload": payload])
    }
    func friendSocialRequest(action: String, payload: [String: String]) throws -> URLRequest {
        try request(path: "/rest/v1/rpc/bound_social_v2", body: ["action": action, "payload": payload])
    }
    func friendJiggleRequest(roomID: String, requestID: String) throws -> URLRequest {
        try request(path: "/functions/v1/bound-jiggle", body: ["roomID": roomID, "requestID": requestID])
    }
    func friendSharingRequest(roomID: String) throws -> URLRequest {
        try request(path: "/functions/v1/agora-token", body: ["roomID": roomID])
    }
    func nakamaSessionRequest(roomID: String) throws -> URLRequest {
        try request(path: "/functions/v1/nakama-session", body: ["roomID": roomID, "protocol": "bound-room-v1"])
    }
    func nakamaSaveSessionRequest(roomID: String? = nil) throws -> URLRequest {
        var body = ["protocol": "bound-saves-v1"]
        if let roomID { body["roomID"] = roomID.lowercased() }
        return try request(path: "/functions/v1/nakama-session", body: body)
    }
    func runLeaseRequest(action: String, payload: [String: Any]) throws -> URLRequest {
        try request(path: "/rest/v1/rpc/bound_run_lease_v1", body: ["action": action, "payload": payload])
    }
    func dropboxLinkRequest(action: String, code: String? = nil, verifier: String? = nil) throws -> URLRequest {
        var body = ["action": action]
        if let code { body["code"] = code }
        if let verifier { body["verifier"] = verifier }
        return try request(path: "/functions/v1/bound-dropbox", body: body)
    }
    /// Self-hosted save endpoints reuse the invalidatable account session snapshot.
    func serverBackupRequest(path: String, method: String = "GET", body: Data? = nil,
                             headers: [String: String] = [:]) throws -> URLRequest {
        let prefix = "/backups/v1/saves/"
        let gameID = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
        let savePath = !gameID.isEmpty && gameID.utf8.count <= 128 && gameID.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
        guard backend.kind == .selfhost, ["GET", "PUT", "DELETE"].contains(method),
              path == "/backups/v1/status" || path == "/backups/v1/provider" || path == "/backups/v1/saves" || savePath else { throw BoundFriendError.unavailable }
        var result = URLRequest(url: try backend.url(path: path))
        result.timeoutInterval = 90
        result.httpMethod = method; result.httpBody = body
        for (key, value) in headers { result.setValue(value, forHTTPHeaderField: key) }
        result.setValue("Bearer " + (try validToken()), forHTTPHeaderField: "Authorization")
        return result
    }
    func accountUserRequest() throws -> URLRequest {
        var result = try request(path: "/auth/v1/user", body: [:])
        result.httpMethod = "GET"; result.httpBody = nil
        return result
    }
    fileprivate func accountSecurityRequest(path: String, method: String = "POST", body: [String: Any] = [:]) throws -> URLRequest {
        var result = try request(path: "/auth/v1/" + path, body: body)
        result.httpMethod = method
        if method == "GET" || method == "DELETE" { result.httpBody = nil }
        return result
    }
    func accountEmailChangeRequest(newEmail: String, currentPassword: String) throws -> URLRequest {
        try request(path: "/functions/v1/change-account-email",
                    body: ["newEmail": newEmail, "currentPassword": currentPassword])
    }
    func accountDeletionRequest(operation: String, email: String) throws -> URLRequest {
        try request(path: "/functions/v1/delete-account", body: ["operationToken": operation, "confirmationEmail": email])
    }
    var description: String { "AppCloudSession(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": "redacted"]) }
}

enum BoundFriendError: Error { case signIn, unavailable }

/// Passwords and configuration keys are never part of the saved session.
struct BoundSavedSession: Codable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let origin: String
    let owner: UUID
    let accessToken: String
    let refreshToken: String
    var description: String { "BoundSavedSession(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": "redacted"]) }
}

/// A preauthorized deletion capability survives session revocation and process death.
/// It is stored in a separate device-only Keychain item, never in preferences or logs.
private struct BoundDeletionRecord: Codable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let owner: UUID
    let operation: String
    var description: String { "BoundDeletionRecord(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["capability": "redacted"]) }
}

@MainActor
protocol BoundSessionStorage {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}

/// Injectable Security calls allow tests to verify the actual Keychain policy and error handling.
@MainActor
struct BoundKeychainSessionStorage: BoundSessionStorage {
    struct Calls {
        var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
        var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
        var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
        var delete: (CFDictionary) -> OSStatus = SecItemDelete
    }
    struct Failure: Error { let status: OSStatus }
    var calls = Calls()
    var defaults: UserDefaults = .standard
    var service = (Bundle.main.bundleIdentifier ?? "Bound") + ".friend-account"
    var origin = BoundFriendAccount.origin
    // A non-secret logout marker prevents resurrection if Keychain deletion fails while locked.
    private var logoutKey: String { service + ".signed-out." + origin }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: origin,
         kSecAttrSynchronizable as String: false]
    }
    func read() throws -> Data? {
        if defaults.bool(forKey: logoutKey) { return nil }
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = calls.copy(query as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data else { throw Failure(status: result) }
        return data
    }
    func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var result = calls.update(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            result = calls.add(query.merging(attributes) { _, value in value } as CFDictionary, nil)
            if result == errSecDuplicateItem { result = calls.update(query as CFDictionary, attributes as CFDictionary) }
        }
        guard result == errSecSuccess else { throw Failure(status: result) }
        defaults.set(false, forKey: logoutKey)
    }
    func remove() throws {
        defaults.set(true, forKey: logoutKey)
        let result = calls.delete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw Failure(status: result) }
    }
}

private final class BoundAuthNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private final class BoundAuthObservation: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

enum BoundAuthTransport {
    struct Response: Sendable { let data: Data; let status: Int }
    static func perform(_ request: URLRequest) async throws -> Response {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 10
        let client = URLSession(configuration: config, delegate: BoundAuthNoRedirect(), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        let (bytes, response) = try await client.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw BoundFriendError.unavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65536 else { throw BoundFriendError.unavailable }
            data.append(byte)
        }
        return Response(data: data, status: response.statusCode)
    }
}

struct BoundSecurityFactor: Identifiable, Equatable {
    let id: String
    let friendlyName: String
    let factorType: String
    let status: String
}
struct BoundAccountPasskey: Identifiable, Equatable {
    let id: String
    let name: String
}
/// Enrollment secrets live only in memory until verified or cancelled.
struct BoundTOTPEnrollment: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let factorID: String
    let secret: String
    let uri: String
    var description: String { "BoundTOTPEnrollment(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["secret": "redacted"]) }
}

@MainActor
final class BoundFriendAccount: ObservableObject {
    nonisolated static let origin = BoundBackendConfiguration.bundled?.origin ?? "invalid-backend-configuration"
    // All production game coordinators share one owner of the rotating refresh token.
    static let shared = BoundFriendAccount()
    nonisolated static let willSignOutNotification = Notification.Name("BoundFriendAccountWillSignOut")
    nonisolated static let sessionDidChangeNotification = Notification.Name("BoundFriendAccountSessionDidChange")
    @Published private(set) var session: AppCloudSession? {
        didSet {
            guard publishesSessionChanges else { return }
            if oldValue == nil && session == nil { return }
            if let oldValue, oldValue.isSameSession(as: session) { return }
            NotificationCenter.default.post(name: Self.sessionDidChangeNotification, object: self)
        }
    }
    @Published private(set) var emailAddress: String?
    @Published private(set) var changingEmail = false
    @Published private(set) var emailChangeStatus = ""
    @Published private(set) var sendingPasswordReset = false
    @Published private(set) var passwordResetStatus = ""
    @Published private(set) var securityBusy = false {
        didSet {
            if !securityBusy {
                let waiters = securityIdleWaiters; securityIdleWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
    }
    @Published private(set) var securityStatus = ""
    @Published private(set) var securityFactors: [BoundSecurityFactor] = []
    @Published private(set) var passkeys: [BoundAccountPasskey] = []
    @Published private(set) var totpEnrollment: BoundTOTPEnrollment?
    @Published private(set) var pendingMFA = false
    @Published private(set) var securityAAL2 = false
    var securityIdentityID: UUID? { session?.owner ?? pendingMFASession?.owner }
    var passkeysAvailable: Bool { passkeysConfigurationAvailable() }
    @Published private(set) var busy = false
    @Published private(set) var status = "Sign in with your existing Bound account."
    @Published private(set) var deletionEmail: String?
    @Published private(set) var deletionPending = false
    private let storage: any BoundSessionStorage
    private let deletionStorage: any BoundSessionStorage
    private let configuration: () throws -> String
    private let transport: @MainActor (URLRequest) async throws -> BoundAuthTransport.Response
    private let automaticRefresh: Bool
    private let passkeyRegistration: @MainActor (Data) async throws -> Data
    private let passkeyAuthentication: @MainActor (Data) async throws -> Data
    private let passkeysConfigurationAvailable: @MainActor () -> Bool
    private var pendingMFASession: BoundSavedSession?
    private var pendingMFAIdentity: AppCloudSession?
    private var securityIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var enrollmentCleanupTask: Task<Void, Never>?
    // Initialization must not publish through observers that resolve `.shared`
    // while the singleton is still being constructed.
    private var publishesSessionChanges = false
    private var saved: BoundSavedSession?
    private var generation = UUID()
    private var refreshTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var activeObserver: BoundAuthObservation?
    private var restorePending = true
    private var removalPending = false
    private var savePending = false
    private var retryDelay: TimeInterval = 5
    private var emailAddressTask: Task<Void, Never>?
    private var nextPasswordResetAt = Date.distantPast
    private var pendingDeletion: BoundDeletionRecord?
    private var deletionIdentityOwner: UUID?

    init(storage: (any BoundSessionStorage)? = nil, deletionStorage: (any BoundSessionStorage)? = nil, automaticRefresh: Bool = true,
         configuration: @escaping () throws -> String = BoundFriendAccount.bundledKey,
         transport: @escaping @MainActor (URLRequest) async throws -> BoundAuthTransport.Response = BoundAuthTransport.perform,
         passkeyRegistration: @escaping @MainActor (Data) async throws -> Data = BoundPasskeyAuthorization.registration,
         passkeyAuthentication: @escaping @MainActor (Data) async throws -> Data = BoundPasskeyAuthorization.authentication,
         passkeysConfigurationAvailable: @escaping @MainActor () -> Bool = { BoundPasskeyAuthorization.isConfigured }) {
        self.storage = storage ?? BoundKeychainSessionStorage()
        self.deletionStorage = deletionStorage ?? BoundKeychainSessionStorage(service: (Bundle.main.bundleIdentifier ?? "Bound") + ".friend-account-deletion")
        self.configuration = configuration; self.transport = transport; self.automaticRefresh = automaticRefresh
        self.passkeyRegistration = passkeyRegistration; self.passkeyAuthentication = passkeyAuthentication
        self.passkeysConfigurationAvailable = passkeysConfigurationAvailable
        restore()
        restoreDeletion()
        publishesSessionChanges = true
        if automaticRefresh {
            // Enqueue after initialization: observers may resolve `.shared` while this
            // singleton is being constructed, so no asynchronous lookup starts inline.
            Task { @MainActor [weak self] in
                await self?.refreshIfNeeded()
                await self?.loadAccountSecurity()
            }
        }
        #if canImport(UIKit)
        activeObserver = BoundAuthObservation(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshIfNeeded()
                if self.automaticRefresh { await self.loadAccountSecurity() }
            }
        })
        #endif
    }
    deinit {
        timer?.cancel(); refreshTask?.cancel(); enrollmentCleanupTask?.cancel()
    }
    nonisolated static func bundledKey() throws -> String {
        let backend = try BoundBackendConfiguration.current()
        if backend.kind == .selfhost { return "" }
        guard let url = Bundle.main.url(forResource: "cloud-configuration", withExtension: "json"),
              let config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              config["origin"] as? String == origin,
              let key = config["publishableKey"] as? String, key.hasPrefix("sb_publishable_") else { throw BoundFriendError.unavailable }
        return key
    }
    private func restore() {
        guard restorePending else { return }
        do {
            guard let bytes = try storage.read() else { restorePending = false; return }
            let key = try configuration()
            do {
                guard bytes.count <= 65536 else { throw BoundFriendError.signIn }
                let value = try JSONDecoder().decode(BoundSavedSession.self, from: bytes)
                guard value.origin == Self.origin, !value.refreshToken.isEmpty, value.refreshToken.utf8.count <= 16384 else { throw BoundFriendError.signIn }
                session = try AppCloudSession(owner: value.owner, key: key, token: value.accessToken, allowExpired: true)
                saved = value; securityAAL2 = Self.assuranceLevel(value.accessToken) == "aal2"; emailAddress = Self.emailClaim(value.accessToken)
                restorePending = false; status = "Signed in."
                schedule(after: max(0, session!.expiresAt.timeIntervalSinceNow - 60))
            } catch {
                restorePending = false
                signOut()
                status = removalPending ? status : "Please sign in again."
            }
        } catch {
            // A locked Keychain or unavailable configuration must never erase a stored login.
            status = "Saved sign-in is temporarily unavailable. Try again after unlocking."
            scheduleRetry()
        }
    }
    func signIn(email: String, password: String) async {
        guard !busy, !deletionPending else { return }
        // An explicit account switch invalidates old service holders and any outstanding refresh.
        signOut()
        guard !removalPending else { return }
        let run = generation; busy = true
        defer { if generation == run { busy = false } }
        do {
            let key = try configuration()
            let request = try tokenRequest(grant: "password", key: key,
                                           body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password])
            let response = try await transport(request)
            guard generation == run, !Task.isCancelled else { return }
            guard response.status == 200 else { throw BoundFriendError.signIn }
            let next = try decode(response.data)
            try acceptSignIn(next, responseData: response.data, key: key)
        } catch {
            guard generation == run else { return }
            status = "Could not save your sign-in. Check your account, connection, and device lock."
        }
    }
    func refreshIfNeeded() async {
        if removalPending {
            do { try storage.remove(); removalPending = false; status = "Signed out." }
            catch { scheduleRetry(); return }
        }
        restore()
        guard !busy, !securityBusy, let saved, let session else { return }
        if let refreshTask { await refreshTask.value; return }
        if savePending {
            do {
                try storage.write(JSONEncoder().encode(saved)); savePending = false
                retryDelay = 5; status = "Signed in."
                self.session = session
            }
            catch { scheduleRetry(); return }
        }
        guard session.expiresAt.timeIntervalSinceNow <= 60 else {
            schedule(after: session.expiresAt.timeIntervalSinceNow - 60); return
        }
        let run = generation
        let shared = Task<Void, Never> { [weak self] in await self?.refresh(saved, run: run) }
        refreshTask = shared
        await shared.value
        if generation == run { refreshTask = nil }
    }
    private func refresh(_ previous: BoundSavedSession, run: UUID) async {
        do {
            let key = try configuration()
            let response = try await transport(tokenRequest(grant: "refresh_token", key: key, body: ["refresh_token": previous.refreshToken]))
            guard generation == run, !Task.isCancelled else { return }
            if Self.requiresSignIn(response) { signOut(); if !removalPending { status = "Your session ended. Please sign in again." }; return }
            guard response.status == 200 else { throw BoundFriendError.unavailable }
            let next = try decode(response.data)
            guard next.owner == previous.owner,
                  let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let user = object["user"] as? [String: Any] else { signOut(); return }
            let factors = try Self.factors(in: user)
            if factors.contains(where: { $0.status == "verified" }) && Self.assuranceLevel(next.accessToken) != "aal2" {
                // Auth can discover factors added on another device during refresh.
                // Preserve the rotated token only in memory and invalidate all old holders.
                try suspendForSecondFactor(next, factors: factors, key: key)
                return
            }
            securityFactors = factors
            // Keep a rotated refresh token in memory even if Keychain is temporarily locked.
            try session?.renew(token: next.accessToken)
            saved = next; savePending = true; securityAAL2 = Self.assuranceLevel(next.accessToken) == "aal2"
            emailAddress = Self.accountEmail(response.data, owner: next.owner, token: next.accessToken) ?? emailAddress
            try storage.write(JSONEncoder().encode(next))
            savePending = false; retryDelay = 5; status = "Signed in."
            // Publish the renewed snapshot for the UI without replacing its identity.
            if let current = session { session = current }
            schedule(after: max(1, session!.expiresAt.timeIntervalSinceNow - 60))
        } catch {
            guard generation == run else { return }
            status = savePending ? "Sign-in renewed. Waiting to save securely." : "Your sign-in is saved. Waiting for a connection."
            scheduleRetry()
        }
    }
    func signOut() {
        if session != nil && publishesSessionChanges { NotificationCenter.default.post(name: Self.willSignOutNotification, object: self) }
        BoundPasskeyAuthorization.cancel()
        enrollmentCleanupTask?.cancel(); enrollmentCleanupTask = nil
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil; timer?.cancel(); timer = nil
        session?.invalidate(); session = nil; saved = nil; busy = false
        pendingMFAIdentity?.invalidate(); pendingMFAIdentity = nil; pendingMFASession = nil
        pendingMFA = false; securityAAL2 = false; securityBusy = false
        securityFactors = []; passkeys = []; totpEnrollment = nil; securityStatus = ""
        emailAddress = nil; emailAddressTask?.cancel(); emailAddressTask = nil
        changingEmail = false; emailChangeStatus = ""
        sendingPasswordReset = false; passwordResetStatus = ""
        deletionEmail = nil; deletionIdentityOwner = nil
        restorePending = false; savePending = false; retryDelay = 5
        do { try storage.remove(); removalPending = false; status = "Signed out." }
        catch { removalPending = true; status = "Could not remove saved sign-in. Unlock your device and try again."; scheduleRetry() }
    }
    private func scheduleRetry() {
        schedule(after: retryDelay); retryDelay = min(300, retryDelay * 2)
    }
    private func schedule(after seconds: TimeInterval) {
        guard automaticRefresh else { return }
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 86400)) * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.refreshIfNeeded()
        }
    }
    private func tokenRequest(grant: String, key: String, body: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: try BoundBackendConfiguration.current().url(path: "/auth/v1/token?grant_type=" + grant))
        request.httpMethod = "POST"; request.timeoutInterval = 10
        try BoundBackendConfiguration.current().applyAPIKey(key, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func assuranceLevel(_ token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.utf8.count <= 16384 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return BoundBackendConfiguration.bundled?.claims(object)["aal"] as? String
    }
    private static func factors(in user: [String: Any]) throws -> [BoundSecurityFactor] {
        // Older Auth responses omit factors when none exist. Present malformed data is rejected.
        guard let raw = user["factors"] else { return [] }
        guard let values = raw as? [[String: Any]], values.count <= 100 else { throw BoundFriendError.unavailable }
        return try values.map { value in
            guard let id = value["id"] as? String, UUID(uuidString: id) != nil,
                  let status = value["status"] as? String, ["verified", "unverified"].contains(status),
                  let type = value["factor_type"] as? String, !type.isEmpty, type.count <= 40 else { throw BoundFriendError.unavailable }
            return BoundSecurityFactor(id: id, friendlyName: String((value["friendly_name"] as? String ?? "Authenticator").prefix(100)), factorType: type, status: status)
        }
    }
    private func suspendForSecondFactor(_ value: BoundSavedSession, factors: [BoundSecurityFactor], key: String) throws {
        let pending = try AppCloudSession(owner: value.owner, key: key, token: value.accessToken)
        // This is a local capability transition, not remote logout: the same live
        // Auth session is needed to challenge and verify the required factor.
        signOut()
        pendingMFASession = value; pendingMFAIdentity = pending; pendingMFA = true
        securityFactors = factors
        status = "Enter your authenticator code to finish signing in."
        securityStatus = factors.contains(where: { $0.status == "verified" && $0.factorType == "totp" }) ? "" : "This account requires a security factor supported by another current client."
    }
    private func acceptSignIn(_ next: BoundSavedSession, responseData: Data, key: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let user = object["user"] as? [String: Any] else { throw BoundFriendError.signIn }
        let factors = try Self.factors(in: user)
        let identity = try AppCloudSession(owner: next.owner, key: key, token: next.accessToken)
        let aal2 = Self.assuranceLevel(next.accessToken) == "aal2"
        if factors.contains(where: { $0.status == "verified" }) && !aal2 {
            // Never give service holders, Keychain, or account observers a first-factor token.
            pendingMFASession = next; pendingMFAIdentity = identity
            securityFactors = factors; pendingMFA = true; securityAAL2 = false
            status = "Enter your authenticator code to finish signing in."
            securityStatus = factors.contains(where: { $0.status == "verified" && $0.factorType == "totp" }) ? "" : "This account requires a security factor supported by another current client."
            return
        }
        try storage.write(JSONEncoder().encode(next))
        saved = next; securityFactors = factors; securityAAL2 = aal2
        emailAddress = Self.accountEmail(responseData, owner: next.owner, token: next.accessToken)
        session = identity; retryDelay = 5; status = "Signed in."
        schedule(after: max(1, identity.expiresAt.timeIntervalSinceNow - 60))
    }
    private func securityRequest(path: String, method: String = "POST", body: [String: Any] = [:], identity: AppCloudSession? = nil) throws -> URLRequest {
        if let identity { return try identity.accountSecurityRequest(path: path, method: method, body: body) }
        var request = URLRequest(url: try BoundBackendConfiguration.current().url(path: "/auth/v1/" + path))
        request.httpMethod = method; request.timeoutInterval = 10
        try BoundBackendConfiguration.current().applyAPIKey(configuration(), to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method != "GET" && method != "DELETE" { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }
    private func securityMessage(_ response: BoundAuthTransport.Response) -> String {
        if response.status == 429 { return "Too many attempts. Wait before trying again." }
        if [401, 403].contains(response.status) { return "Verify your authenticator code or sign in again before changing security settings." }
        if [404, 501].contains(response.status) { return "This security option is not enabled on the server yet." }
        return "Could not finish the security request. Check your connection and try again."
    }
    func cancelPendingMFA() { signOut() }
    func loadAccountSecurity() async {
        guard !busy, !securityBusy, !changingEmail, !deletionPending else { return }
        await refreshIfNeeded()
        guard !busy, !securityBusy, !changingEmail, !deletionPending, let identity = session else { return }
        let run = generation; securityBusy = true; securityStatus = ""
        defer { if generation == run { securityBusy = false } }
        do {
            let response = try await transport(identity.accountUserRequest())
            guard generation == run, !Task.isCancelled, identity.isSameSession(as: session) else { return }
            guard response.status == 200, let user = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let id = user["id"] as? String, UUID(uuidString: id) == identity.owner,
                  user["is_anonymous"] as? Bool != true else { throw BoundFriendError.unavailable }
            let factors = try Self.factors(in: user)
            securityFactors = factors
            // A restored legacy session is suspended as soon as Auth reports a required factor.
            if factors.contains(where: { $0.status == "verified" }) && !securityAAL2, let previous = saved {
                try suspendForSecondFactor(previous, factors: factors, key: configuration())
                return
            }
            // Account settings expose authenticators only. Do not query the
            // hidden passkey service or surface its availability errors here.
        } catch {
            guard generation == run, !Task.isCancelled else { return }
            securityStatus = "Could not load account security. Check your connection and try again."
        }
    }
    private static func decodePasskeys(_ data: Data) throws -> [BoundAccountPasskey] {
        let object = try JSONSerialization.jsonObject(with: data)
        let values: [[String: Any]]
        if let array = object as? [[String: Any]] { values = array }
        else if let wrapper = object as? [String: Any], let array = wrapper["passkeys"] as? [[String: Any]] { values = array }
        else { throw BoundFriendError.unavailable }
        guard values.count <= 100 else { throw BoundFriendError.unavailable }
        return try values.map { value in
            guard let id = value["id"] as? String, UUID(uuidString: id) != nil else { throw BoundFriendError.unavailable }
            return BoundAccountPasskey(id: id, name: String((value["friendly_name"] as? String ?? "Passkey").prefix(100)))
        }
    }
    func enrollTOTP() async -> Bool {
        guard !busy, !securityBusy, !changingEmail, !deletionPending, totpEnrollment == nil else { return false }
        await refreshIfNeeded()
        guard !busy, !securityBusy, !changingEmail, let identity = session else { return false }
        if securityFactors.contains(where: { $0.status == "verified" }) && !securityAAL2 {
            securityStatus = "Verify your existing authenticator code first."; return false
        }
        let run = generation; securityBusy = true; securityStatus = ""
        defer { if generation == run { securityBusy = false } }
        do {
            let response = try await transport(identity.accountSecurityRequest(path: "factors", body: ["factor_type": "totp", "friendly_name": "Bound Authenticator " + UUID().uuidString.prefix(8), "issuer": "Bound"]))
            guard generation == run, !Task.isCancelled, identity.isSameSession(as: session) else { return false }
            guard response.status == 200 else { securityStatus = securityMessage(response); return false }
            guard let value = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let id = value["id"] as? String, UUID(uuidString: id) != nil,
                  let totp = value["totp"] as? [String: Any], let secret = totp["secret"] as? String,
                  !secret.isEmpty, secret.utf8.count <= 1024, let uri = totp["uri"] as? String,
                  uri.hasPrefix("otpauth://totp/"), uri.utf8.count <= 4096 else { throw BoundFriendError.unavailable }
            totpEnrollment = BoundTOTPEnrollment(factorID: id, secret: secret, uri: uri)
            securityStatus = "Add the setup key to your authenticator, then enter its six-digit code."
            return true
        } catch {
            guard generation == run, !Task.isCancelled else { return false }
            securityStatus = "Could not start authenticator setup. Try again."; return false
        }
    }
    /// Clear setup secrets synchronously when their view leaves. Cleanup retains
    /// only the factor ID, owner and generation, and never deletes a verified factor.
    func discardTOTPEnrollment() {
        guard let factorID = totpEnrollment?.factorID else { return }
        totpEnrollment = nil
        guard let owner = session?.owner else { return }
        let run = generation
        enrollmentCleanupTask = Task { @MainActor [weak self] in
            await self?.cleanupDiscardedEnrollment(factorID: factorID, owner: owner, run: run)
        }
    }
    func cancelTOTPEnrollment() async {
        discardTOTPEnrollment()
        await enrollmentCleanupTask?.value
    }
    private func waitForSecurityIdle() async {
        while securityBusy && !Task.isCancelled {
            await withCheckedContinuation { securityIdleWaiters.append($0) }
        }
    }
    private func cleanupDiscardedEnrollment(factorID: String, owner: UUID, run: UUID) async {
        // Verification may be returning from a cancelled network request. Waiting
        // for its completion avoids dropping cleanup or racing an accepted verify.
        await waitForSecurityIdle()
        guard generation == run, !Task.isCancelled, !busy, !changingEmail,
              !deletionPending, session?.owner == owner else { return }
        await refreshIfNeeded()
        await waitForSecurityIdle()
        guard generation == run, !Task.isCancelled, !busy, !changingEmail,
              !deletionPending, let identity = session, identity.owner == owner else { return }
        securityBusy = true
        defer { if generation == run { securityBusy = false } }
        do {
            // A verification response may have been lost. Remove only a factor Auth still
            // reports as unverified; cancelling a sheet must never disable working MFA.
            let current = try await transport(identity.accountUserRequest())
            guard generation == run, !Task.isCancelled, identity.isSameSession(as: session) else { return }
            guard current.status == 200, let user = try JSONSerialization.jsonObject(with: current.data) as? [String: Any],
                  let userID = user["id"] as? String, UUID(uuidString: userID) == identity.owner else { throw BoundFriendError.unavailable }
            securityFactors = try Self.factors(in: user)
            guard securityFactors.contains(where: { $0.id == factorID && $0.status == "unverified" }) else {
                securityStatus = "Setup key cleared. Reload account security to check your authenticator."; return
            }
            let response = try await transport(identity.accountSecurityRequest(path: "factors/" + factorID, method: "DELETE"))
            guard generation == run, !Task.isCancelled, identity.isSameSession(as: session) else { return }
            if (200..<300).contains(response.status) {
                securityFactors.removeAll { $0.id == factorID }
                securityStatus = "Authenticator setup cancelled."
            } else {
                securityStatus = "Setup key cleared. An unfinished factor may remain; reload security settings to remove it."
            }
        } catch {
            guard generation == run, !Task.isCancelled else { return }
            securityStatus = "Setup key cleared. Reload security settings to remove any unfinished factor."
        }
    }
    func verifyTOTPEnrollment(code: String) async -> Bool {
        guard let enrollment = totpEnrollment else { return false }
        return await verifySecurityFactor(id: enrollment.factorID, code: code, enrollment: true)
    }
    func verifySecondFactor(code: String, factorID: String? = nil) async -> Bool {
        guard let factor = securityFactors.first(where: { $0.status == "verified" && $0.factorType == "totp" && (factorID == nil || $0.id == factorID) }) else {
            securityStatus = "No supported authenticator is available on this account."; return false
        }
        return await verifySecurityFactor(id: factor.id, code: code, enrollment: false)
    }
    private func verifySecurityFactor(id: String, code: String, enrollment: Bool) async -> Bool {
        guard !busy, !securityBusy, !changingEmail, !deletionPending else { return false }
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            securityStatus = "Enter the six-digit authenticator code."; return false
        }
        if !pendingMFA { await refreshIfNeeded() }
        guard !busy, !securityBusy, let identity = pendingMFAIdentity ?? session else { return false }
        let wasPending = pendingMFA; let run = generation
        securityBusy = true; securityStatus = ""
        defer { if generation == run { securityBusy = false } }
        func stillCurrent() -> Bool {
            generation == run && !Task.isCancelled && (wasPending ? pendingMFAIdentity.map { identity.isSameSession(as: $0) } == true : identity.isSameSession(as: session))
        }
        do {
            let challenge = try await transport(identity.accountSecurityRequest(path: "factors/" + id + "/challenge"))
            guard stillCurrent() else { return false }
            guard challenge.status == 200 else { securityStatus = securityMessage(challenge); return false }
            guard let object = try JSONSerialization.jsonObject(with: challenge.data) as? [String: Any],
                  let challengeID = object["id"] as? String, UUID(uuidString: challengeID) != nil else { throw BoundFriendError.unavailable }
            let response = try await transport(identity.accountSecurityRequest(path: "factors/" + id + "/verify", body: ["challenge_id": challengeID, "code": code]))
            guard stillCurrent() else { return false }
            guard response.status == 200 else { securityStatus = response.status == 400 || response.status == 422 ? "That code was not accepted. Try the current code from your authenticator." : securityMessage(response); return false }
            let next = try decode(response.data)
            guard next.owner == identity.owner, Self.assuranceLevel(next.accessToken) == "aal2",
                  let value = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let user = value["user"] as? [String: Any] else { throw BoundFriendError.signIn }
            let factors = try Self.factors(in: user)
            if enrollment { totpEnrollment = nil }
            if wasPending {
                // Keep the rotated, verified credential in memory if Keychain is locked.
                // No first-factor credential or service capability is published or persisted.
                try identity.renew(token: next.accessToken)
                pendingMFASession = next
                do { try storage.write(JSONEncoder().encode(next)) }
                catch {
                    securityStatus = "Authenticator verified. Unlock your device and try verifying again to save your sign-in."
                    return false
                }
                pendingMFAIdentity = nil; pendingMFASession = nil; pendingMFA = false
                removalPending = false
                saved = next; session = identity
            } else {
                // MFA rotates refresh tokens; retain that token even if Keychain is temporarily locked.
                try identity.renew(token: next.accessToken)
                saved = next; savePending = true
                do { try storage.write(JSONEncoder().encode(next)); savePending = false }
                catch { /* Retry secure persistence after leaving the current security operation. */ }
                session = identity
            }
            securityAAL2 = true
            emailAddress = Self.accountEmail(response.data, owner: next.owner, token: next.accessToken) ?? emailAddress
            securityFactors = factors
            if enrollment {
                totpEnrollment = nil
                if !securityFactors.contains(where: { $0.id == id }) { securityFactors.append(BoundSecurityFactor(id: id, friendlyName: "Bound Authenticator", factorType: "totp", status: "verified")) }
            }
            securityStatus = enrollment ? "Two-factor authentication enabled." : "Authenticator verified."
            status = savePending ? "Sign-in renewed. Waiting to save securely." : "Signed in."
            retryDelay = 5
            if savePending { scheduleRetry() }
            else { schedule(after: max(1, nextExpiry(next) - 60)) }
            return true
        } catch {
            guard stillCurrent() else { return false }
            securityStatus = "Could not verify and securely save your sign-in. Try again or sign in again."; return false
        }
    }
    private func nextExpiry(_ value: BoundSavedSession) -> TimeInterval {
        (try? AppCloudSession(owner: value.owner, key: configuration(), token: value.accessToken).expiresAt.timeIntervalSinceNow) ?? 60
    }
    func unenrollTOTP(factorID: String) async -> Bool {
        guard !busy, !securityBusy, !changingEmail, !deletionPending,
              let factor = securityFactors.first(where: { $0.id == factorID && $0.factorType == "totp" }),
              factor.status != "verified" || securityAAL2 else {
            securityStatus = "Verify your existing authenticator code first."; return false
        }
        await refreshIfNeeded()
        guard let identity = session, !busy, !securityBusy else { return false }
        let run = generation; securityBusy = true
        defer { if generation == run { securityBusy = false } }
        do {
            let response = try await transport(identity.accountSecurityRequest(path: "factors/" + factor.id, method: "DELETE"))
            guard generation == run, !Task.isCancelled, identity.isSameSession(as: session) else { return false }
            guard (200..<300).contains(response.status) else { securityStatus = securityMessage(response); return false }
            securityFactors.removeAll { $0.id == factor.id }; securityStatus = "Authenticator removed."
            if totpEnrollment?.factorID == factor.id { totpEnrollment = nil }
            return true
        } catch {
            guard generation == run, !Task.isCancelled else { return false }
            securityStatus = "Could not confirm authenticator removal. Reload security settings before retrying."; return false
        }
    }
    private static func passkeyVerificationBody(options: Data, credential: Data) throws -> [String: Any] {
        guard options.count <= 65536, credential.count <= 65536,
              let envelope = try JSONSerialization.jsonObject(with: options) as? [String: Any],
              let id = envelope["challenge_id"] as? String, UUID(uuidString: id) != nil,
              let value = try JSONSerialization.jsonObject(with: credential) as? [String: Any],
              value["type"] as? String == "public-key" else { throw BoundFriendError.unavailable }
        return ["challenge_id": id, "credential": value]
    }
    func registerPasskey(name: String) async -> Bool {
        guard passkeysAvailable else { securityStatus = "Passkeys need the Bound account domain to be configured first."; return false }
        guard !busy, !securityBusy, !changingEmail, !deletionPending else { return false }
        await refreshIfNeeded()
        guard !busy, !securityBusy, !changingEmail, let identity = session else { return false }
        if securityFactors.contains(where: { $0.status == "verified" }) && !securityAAL2 { securityStatus = "Verify your authenticator code first."; return false }
        let normalized = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let run = generation; securityBusy = true; securityStatus = ""
        defer { if generation == run { securityBusy = false } }
        do {
            let options = try await transport(identity.accountSecurityRequest(path: "passkeys/registration/options"))
            guard generation == run, !Task.isCancelled, identity.isSameSession(as: session) else { return false }
            guard options.status == 200 else { securityStatus = securityMessage(options); return false }
            let credential = try await passkeyRegistration(options.data)
            guard generation == run, !Task.isCancelled, identity.isSameSession(as: session) else { return false }
            let body = try Self.passkeyVerificationBody(options: options.data, credential: credential)
            let result = try await transport(identity.accountSecurityRequest(path: "passkeys/registration/verify", body: body))
            guard generation == run, !Task.isCancelled, identity.isSameSession(as: session) else { return false }
            guard result.status == 200 || result.status == 201 else { securityStatus = securityMessage(result); return false }
            guard let object = try JSONSerialization.jsonObject(with: result.data) as? [String: Any],
                  let id = object["id"] as? String, UUID(uuidString: id) != nil else { throw BoundFriendError.unavailable }
            passkeys.append(BoundAccountPasskey(id: id, name: String((object["friendly_name"] as? String ?? (normalized.isEmpty ? "Passkey" : normalized)).prefix(100))))
            securityStatus = "Passkey added to your Bound account."; return true
        } catch is CancellationError {
            guard generation == run else { return false }
            securityStatus = "Passkey setup cancelled."; return false
        } catch {
            guard generation == run, !Task.isCancelled else { return false }
            securityStatus = "Could not add the passkey. Check account security before retrying."; return false
        }
    }
    func deletePasskey(id: String) async -> Bool {
        guard !busy, !securityBusy, !changingEmail, !deletionPending, let passkey = passkeys.first(where: { $0.id == id }) else { return false }
        if securityFactors.contains(where: { $0.status == "verified" }) && !securityAAL2 { securityStatus = "Verify your authenticator code first."; return false }
        await refreshIfNeeded()
        guard !busy, !securityBusy, !changingEmail, let identity = session else { return false }
        let run = generation; securityBusy = true
        defer { if generation == run { securityBusy = false } }
        do {
            let response = try await transport(identity.accountSecurityRequest(path: "passkeys/" + passkey.id, method: "DELETE"))
            guard generation == run, !Task.isCancelled, identity.isSameSession(as: session) else { return false }
            guard (200..<300).contains(response.status) else { securityStatus = securityMessage(response); return false }
            passkeys.removeAll { $0.id == passkey.id }; securityStatus = "Passkey removed."; return true
        } catch {
            guard generation == run, !Task.isCancelled else { return false }
            securityStatus = "Could not confirm passkey removal. Reload security settings before retrying."; return false
        }
    }
    func signInWithPasskey() async {
        guard passkeysAvailable else { status = "Passkeys need the Bound account domain to be configured first."; return }
        guard !busy, !securityBusy, !changingEmail, !deletionPending else { return }
        signOut()
        guard !removalPending else { return }
        let run = generation; busy = true
        defer { if generation == run { busy = false } }
        do {
            let options = try await transport(securityRequest(path: "passkeys/authentication/options"))
            guard generation == run, !Task.isCancelled else { return }
            guard options.status == 200 else { status = securityMessage(options); return }
            let credential = try await passkeyAuthentication(options.data)
            guard generation == run, !Task.isCancelled else { return }
            let body = try Self.passkeyVerificationBody(options: options.data, credential: credential)
            let response = try await transport(securityRequest(path: "passkeys/authentication/verify", body: body))
            guard generation == run, !Task.isCancelled else { return }
            guard response.status == 200 else { status = securityMessage(response); return }
            let next = try decode(response.data)
            try acceptSignIn(next, responseData: response.data, key: configuration())
        } catch is CancellationError {
            guard generation == run else { return }; status = "Passkey sign-in cancelled."
        } catch {
            guard generation == run, !Task.isCancelled else { return }
            status = "Could not sign in with the passkey. Try again or use your password."
        }
    }

    /// Display-only email comes from Auth, never the text supplied at login.
    /// Decoding a locally retained JWT here does not make authorization decisions.
    private static func emailClaim(_ token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.utf8.count <= 16384 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded),
              let claims = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let email = BoundBackendConfiguration.bundled?.claims(claims)["email"] as? String else { return nil }
        return normalizedEmail(email)
    }
    private static func accountEmail(_ data: Data, owner: UUID, token: String) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let user = object["user"] as? [String: Any],
           let id = user["id"] as? String, UUID(uuidString: id) == owner,
           let email = user["email"] as? String, let normalized = normalizedEmail(email) { return normalized }
        return emailClaim(token)
    }
    func loadEmailAddress() async {
        guard emailAddress == nil, !deletionPending else { return }
        if let emailAddressTask { await emailAddressTask.value; return }
        let run = generation
        let lookup = Task<Void, Never> { @MainActor [weak self] in
            await self?.fetchEmailAddress(run: run)
        }
        emailAddressTask = lookup
        await lookup.value
        if generation == run { emailAddressTask = nil }
    }
    private func fetchEmailAddress(run: UUID) async {
        await refreshIfNeeded()
        guard generation == run, !Task.isCancelled, emailAddress == nil,
              !deletionPending, let identity = session else { return }
        do {
            let response = try await transport(identity.accountUserRequest())
            guard generation == run, !Task.isCancelled, identity.isSameSession(as: session),
                  response.status == 200,
                  let user = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let id = user["id"] as? String, UUID(uuidString: id) == identity.owner,
                  user["role"] as? String == "authenticated", user["is_anonymous"] as? Bool == false,
                  let email = user["email"] as? String else { return }
            emailAddress = Self.normalizedEmail(email)
        } catch { /* Offline email lookup must not change login or account status. */ }
    }

    private struct EmailChangeReceipt: Decodable { let ok: Bool; let email: String }
    func changeEmail(to newEmail: String, currentPassword: String) async -> Bool {
        guard !busy, !securityBusy, !changingEmail, !deletionPending, let identity = session else { return false }
        guard let normalized = Self.normalizedEmail(newEmail) else {
            emailChangeStatus = "Enter a valid new email address."; return false
        }
        guard !currentPassword.isEmpty, currentPassword.utf8.count <= 1024, !currentPassword.contains("\0") else {
            emailChangeStatus = "Enter your current password."; return false
        }
        guard normalized != emailAddress else {
            emailChangeStatus = "Enter a different email address."; return false
        }
        let run = generation; changingEmail = true; emailChangeStatus = ""
        defer { if generation == run { changingEmail = false } }
        await refreshIfNeeded()
        guard generation == run, !Task.isCancelled else { return false }
        guard identity.isSameSession(as: session), !deletionPending else {
            emailChangeStatus = "Sign in again before changing your email."; return false
        }
        if emailAddress == nil { await loadEmailAddress() }
        guard generation == run, !Task.isCancelled, identity.isSameSession(as: session), !deletionPending else { return false }
        guard let emailAddress else {
            emailChangeStatus = "Could not load your current email. Check your connection and try again."; return false
        }
        guard normalized != emailAddress else {
            emailChangeStatus = "Enter a different email address."; return false
        }
        do {
            let response = try await transport(identity.accountEmailChangeRequest(newEmail: normalized, currentPassword: currentPassword))
            guard generation == run, !Task.isCancelled, identity.isSameSession(as: session), !deletionPending else { return false }
            guard response.status == 200 else {
                switch response.status {
                case 401, 403: emailChangeStatus = "Your password or session could not be verified. Check your current password or sign in again."
                case 409: emailChangeStatus = "That email cannot be used right now. Try another address or try again later."
                case 429: emailChangeStatus = "Too many attempts. Please wait and try again later."
                default: emailChangeStatus = "Email changes are unavailable. Please try again later."
                }
                return false
            }
            guard let receipt = try? JSONDecoder().decode(EmailChangeReceipt.self, from: response.data),
                  receipt.ok, Self.normalizedEmail(receipt.email) == normalized else {
                emailChangeStatus = "Could not confirm the email change. Try signing in with the new email before retrying."; return false
            }
            // The account UUID and its cloud data do not change. Retire native
            // credentials containing the old email and request a fresh login.
            signOut()
            emailChangeStatus = "Email updated. Sign in with your new email and current password."
            status = emailChangeStatus
            return true
        } catch {
            guard generation == run, !Task.isCancelled, identity.isSameSession(as: session) else { return false }
            emailChangeStatus = "Could not confirm the email change. Check your connection; if needed, try signing in with the new email."
            return false
        }
    }

    nonisolated static let passwordRecoveryRedirect = "https://evanvonessen.github.io/bound/reset-password.html"
    func requestPasswordReset(email: String) async -> Bool {
        guard session == nil else { return false }
        return await sendPasswordReset(email: email, identity: nil)
    }

    /// Signed-in recovery always uses the account's authenticated email, never
    /// an editable field or credentials from the browser's recovery session.
    func requestPasswordResetForCurrentAccount() async -> Bool {
        guard let identity = session else { return false }
        return await sendPasswordReset(email: nil, identity: identity)
    }

    private func passwordResetSessionMatches(_ identity: AppCloudSession?) -> Bool {
        if let identity { return identity.isSameSession(as: session) }
        return session == nil
    }

    private func sendPasswordReset(email: String?, identity: AppCloudSession?) async -> Bool {
        guard !busy, !securityBusy, !changingEmail, !sendingPasswordReset, !deletionPending else { return false }
        guard Date() >= nextPasswordResetAt else {
            passwordResetStatus = "Please wait a minute before requesting another reset link."; return false
        }
        let run = generation; sendingPasswordReset = true; passwordResetStatus = ""
        defer { if generation == run { sendingPasswordReset = false } }
        if identity != nil { await refreshIfNeeded() }
        guard generation == run, !Task.isCancelled, !deletionPending else { return false }
        guard passwordResetSessionMatches(identity) else {
            passwordResetStatus = "Could not verify your account. Check your connection or sign in again before resetting your password."
            return false
        }
        if identity != nil && emailAddress == nil { await loadEmailAddress() }
        guard generation == run, !Task.isCancelled, !deletionPending,
              passwordResetSessionMatches(identity) else { return false }
        guard let normalized = Self.normalizedEmail((identity == nil ? email : emailAddress) ?? "") else {
            passwordResetStatus = identity == nil
                ? "Enter a valid email address."
                : "Could not load your account email. Check your connection and try again."
            return false
        }
        do {
            let key = try configuration()
            var components = URLComponents(url: try BoundBackendConfiguration.current().url(path: "/auth/v1/recover"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "redirect_to", value: Self.passwordRecoveryRedirect)]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"; request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            try BoundBackendConfiguration.current().applyAPIKey(key, to: &request)
            request.httpBody = try JSONSerialization.data(withJSONObject: ["email": normalized])
            nextPasswordResetAt = Date().addingTimeInterval(60)
            let response = try await transport(request)
            guard generation == run, !Task.isCancelled, !deletionPending,
                  passwordResetSessionMatches(identity) else { return false }
            guard (200..<300).contains(response.status) else {
                passwordResetStatus = response.status == 429
                    ? "Too many reset requests. Please wait and try again later."
                    : "Could not request a reset link. Check your connection and try again later."
                return false
            }
            // Account recovery returns the same response for unknown emails.
            passwordResetStatus = "If an account uses that email, a password reset link will arrive shortly. Check your inbox and spam folder."
            return true
        } catch {
            guard generation == run, !Task.isCancelled, !deletionPending,
                  passwordResetSessionMatches(identity) else { return false }
            passwordResetStatus = "Could not request a reset link. Check your connection and try again later."
            return false
        }
    }

    enum SignupResult: Equatable { case signedIn, checkEmail, usernameTaken, failed, cancelled }
    func createAccount(email: String, password: String, username: String) async -> SignupResult {
        guard !busy, session == nil, !deletionPending else { return .failed }
        guard let email = Self.normalizedEmail(email), !password.isEmpty else {
            status = "Enter a valid email and a password."; return .failed
        }
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BoundSocialAPI.validUsername(normalizedUsername) else {
            status = "Choose a username with 1–40 characters. Links, email addresses and unsafe names aren't allowed."
            return .failed
        }
        signOut()
        guard !removalPending else { return .failed }
        let run = generation; busy = true
        defer { if generation == run { busy = false } }
        var receivedSession = false
        do {
            let key = try configuration()
            let available = try await checkUsernameAvailability(normalizedUsername, key: key)
            guard generation == run, !Task.isCancelled else { return .cancelled }
            guard available else {
                status = Self.usernameTakenMessage
                return .usernameTaken
            }
            let request = try Self.signupRequest(email: email, password: password,
                                                 username: normalizedUsername, key: key)
            let response = try await transport(request)
            guard generation == run, !Task.isCancelled else { return .cancelled }
            guard (200..<300).contains(response.status) else {
                if (try? await checkUsernameAvailability(normalizedUsername, key: key)) == false {
                    guard generation == run, !Task.isCancelled else { return .cancelled }
                    status = Self.usernameTakenMessage
                    return .usernameTaken
                }
                guard generation == run, !Task.isCancelled else { return .cancelled }
                status = Self.signupError(response); return .failed
            }
            guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw BoundFriendError.unavailable }
            if object["access_token"] != nil || object["refresh_token"] != nil {
                let next = try decode(response.data)
                receivedSession = true
                try acceptSignIn(next, responseData: response.data, key: key)
                return .signedIn
            }
            // Auth deliberately returns an obfuscated user for some existing accounts.
            // Never claim a new account exists from a user-only response.
            let user = object["user"] as? [String: Any] ?? object
            guard let id = user["id"] as? String, UUID(uuidString: id) != nil else { throw BoundFriendError.unavailable }
            status = "Check your email for a confirmation link, then return here to sign in. If you already have an account, sign in."
            return .checkEmail
        } catch {
            guard generation == run, !Task.isCancelled else { return .cancelled }
            if let socialError = error as? BoundSocialError {
                status = socialError.localizedDescription
            } else {
                status = receivedSession ? "Your account responded, but sign-in could not be saved securely. Unlock your device, then sign in." : "Could not finish account creation. Check your connection, then try signing in or creating an account again."
            }
            return .failed
        }
    }
    private static let usernameTakenMessage = "That username is already taken. Choose another."

    /// Builds a username-based request for the selected account authority.
    static func signupRequest(email: String, password: String, username: String, key: String) throws -> URLRequest {
        var request = URLRequest(url: try BoundBackendConfiguration.current().url(path: "/auth/v1/signup"))
        request.httpMethod = "POST"; request.timeoutInterval = 10
        try BoundBackendConfiguration.current().applyAPIKey(key, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["email": email, "password": password]
        body["data"] = ["bound_username_v1": username]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func usernameAvailabilityRequest(username: String, key: String) throws -> URLRequest {
        var request = URLRequest(url: try BoundBackendConfiguration.current().url(path: "/rest/v1/rpc/bound_username_available"))
        request.httpMethod = "POST"; request.timeoutInterval = 10
        try BoundBackendConfiguration.current().applyAPIKey(key, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username])
        return request
    }

    private func checkUsernameAvailability(_ username: String, key: String) async throws -> Bool {
        let request = try Self.usernameAvailabilityRequest(username: username, key: key)
        let response = try await transport(request)
        guard (200..<300).contains(response.status),
              let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let ok = object["ok"] as? Bool else { throw BoundFriendError.unavailable }
        if !ok {
            if object["error"] as? String == "name_not_allowed" { throw BoundSocialError.rejected("name_not_allowed") }
            throw BoundFriendError.unavailable
        }
        guard let available = object["available"] as? Bool else { throw BoundFriendError.unavailable }
        return available
    }
    private static func signupError(_ response: BoundAuthTransport.Response) -> String {
        let object = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        let code = object?["code"] as? String ?? object?["error_code"] as? String
        switch code {
        case "weak_password": return "Choose a stronger password and try again."
        case "email_address_invalid": return "Enter a valid email address."
        case "user_already_exists", "email_exists": return "An account may already use this email. Try signing in."
        case "signup_disabled", "email_provider_disabled": return "Account creation is temporarily unavailable."
        case "captcha_failed": return "Account creation needs an additional verification step. Please contact support."
        default: return response.status == 429 ? "Too many attempts. Wait a moment and try again." : "Could not create an account. Check your connection and try again."
        }
    }
    /// ASCII emails use the same trim and case rules in the app and server adapter.
    /// Neither a display name nor editable user metadata authorizes deletion.
    nonisolated static func normalizedEmail(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n")).lowercased()
        let parts = result.split(separator: "@", omittingEmptySubsequences: false)
        guard result.utf8.count <= 254, result.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return result
    }
    func loadDeletionIdentity() async {
        guard !busy, !deletionPending else { return }
        await refreshIfNeeded()
        guard !busy, !deletionPending, let current = session else { return }
        deletionEmail = nil; deletionIdentityOwner = nil
        let run = generation; busy = true
        defer { if generation == run { busy = false } }
        do {
            let response = try await transport(current.accountUserRequest())
            guard generation == run, !Task.isCancelled else { return }
            guard response.status == 200,
                  let user = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let id = user["id"] as? String, UUID(uuidString: id) == current.owner,
                  user["role"] as? String == "authenticated", user["is_anonymous"] as? Bool == false,
                  let confirmed = user["email_confirmed_at"] as? String, !confirmed.isEmpty,
                  let email = user["email"] as? String, let normalized = Self.normalizedEmail(email) else { throw BoundFriendError.signIn }
            deletionEmail = normalized; deletionIdentityOwner = current.owner
            status = "Type your account email to confirm permanent deletion."
        } catch {
            guard generation == run else { return }
            status = "Could not verify your account email. Check your connection or sign in again."
        }
    }
    func deleteAccount(confirmationEmail: String) async {
        guard !busy, !deletionPending, let current = session, deletionIdentityOwner == current.owner,
              let expected = deletionEmail, Self.normalizedEmail(confirmationEmail) == expected else { return }
        let run = generation; busy = true
        defer { if generation == run { busy = false } }
        do {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw BoundFriendError.unavailable }
            let record = BoundDeletionRecord(owner: current.owner, operation: bytes.map { String(format: "%02x", $0) }.joined())
            let request = try current.accountDeletionRequest(operation: record.operation, email: expected)
            // Persist before a request can freeze the account or revoke its session.
            try deletionStorage.write(JSONEncoder().encode(record))
            pendingDeletion = record; deletionPending = true
            await performDeletion(request, run: run, beginning: true)
        } catch {
            guard generation == run else { return }
            status = "Could not securely prepare deletion. Unlock your device and try again."
        }
    }
    func resumeAccountDeletion() async {
        guard !busy else { return }
        restoreDeletion()
        guard let record = pendingDeletion else { return }
        let run = generation; busy = true
        defer { if generation == run { busy = false } }
        do {
            var request = URLRequest(url: try BoundBackendConfiguration.current().url(path: "/functions/v1/delete-account"))
            request.httpMethod = "POST"; request.timeoutInterval = 10
            try BoundBackendConfiguration.current().applyAPIKey(configuration(), to: &request)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["operationToken": record.operation])
            await performDeletion(request, run: run, beginning: false)
        } catch { status = "Deletion is not confirmed. Check your connection and retry deletion." }
    }
    private func performDeletion(_ request: URLRequest, run: UUID, beginning: Bool) async {
        do {
            let response = try await transport(request)
            guard generation == run else { return }
            let object = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
            if response.status == 200, object?["status"] as? String == "complete" {
                signOut()
                do { try deletionStorage.remove(); pendingDeletion = nil; deletionPending = false; status = "Your account and its Bound cloud data were deleted. Local games and notes remain on this device." }
                catch { status = "Account deletion was confirmed. Unlock your device and retry to clear the saved deletion receipt." }
                return
            }
            // These definitive responses occur before begin, or prove no job exists.
            let rejected = beginning && [400, 401, 403, 405].contains(response.status)
            let notStarted = !beginning && response.status == 404 && object?["status"] as? String == "not_started"
            if rejected || notStarted || (response.status == 200 && object?["status"] as? String == "cancelled") {
                try deletionStorage.remove(); pendingDeletion = nil; deletionPending = false
                status = rejected ? "Deletion could not start. Verify your account email and try again later." : "No deletion was started. You can sign in again."
                return
            }
        } catch { /* Lost responses retain the capability; never manufacture success. */ }
        guard generation == run else { return }
        signOut()
        status = "Account deletion is not yet confirmed. Retry deletion to finish removing your account and cloud data."
    }
    private func restoreDeletion() {
        do {
            guard let bytes = try deletionStorage.read() else { pendingDeletion = nil; deletionPending = false; return }
            guard bytes.count <= 4096 else { throw BoundFriendError.unavailable }
            let record = try JSONDecoder().decode(BoundDeletionRecord.self, from: bytes)
            guard record.operation.count == 64, record.operation.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw BoundFriendError.unavailable }
            pendingDeletion = record; deletionPending = true
            if session != nil { signOut() }
            status = "Account deletion is not yet confirmed. Retry deletion to check and finish it."
        } catch {
            deletionPending = true
            status = "Unlock your device to check a saved account-deletion request."
        }
    }
    private func decode(_ data: Data) throws -> BoundSavedSession {
        guard data.count <= 65536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String,
              let refresh = object["refresh_token"] as? String, !refresh.isEmpty, refresh.utf8.count <= 16384,
              let user = object["user"] as? [String: Any], let id = user["id"] as? String,
              let owner = UUID(uuidString: id) else { throw BoundFriendError.signIn }
        return BoundSavedSession(origin: Self.origin, owner: owner, accessToken: token, refreshToken: refresh)
    }
    static func requiresSignIn(_ response: BoundAuthTransport.Response) -> Bool {
        guard (400..<500).contains(response.status), response.status != 429,
              let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { return false }
        let code = object["code"] as? String ?? object["error_code"] as? String ?? object["error"] as? String
        return ["refresh_token_not_found", "refresh_token_already_used", "session_not_found", "session_expired",
                "user_not_found", "user_banned", "invalid_grant"].contains(code ?? "")
    }
}
