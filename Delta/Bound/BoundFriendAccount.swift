import Foundation
import Combine
import Security
#if canImport(UIKit)
import UIKit
#endif

/// A session-scoped snapshot lets existing friend-service holders use renewed credentials.
/// Signing out invalidates all copies, without affecting a different account instance.
struct AppCloudSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let owner: UUID
    private let key: String
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

    init(owner: UUID, key: String, token: String) throws {
        try self.init(owner: owner, key: key, token: token, allowExpired: false)
    }
    fileprivate init(owner: UUID, key: String, token: String, allowExpired: Bool) throws {
        let expiry = try Self.expiry(token: token, owner: owner)
        guard allowExpired || expiry > Date() else { throw BoundFriendError.signIn }
        self.owner = owner; self.key = key; snapshot = Snapshot(token: token, expiry: expiry)
    }
    private static func expiry(token: String, owner: UUID) throws -> Date {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }), token.utf8.count <= 16384 else { throw BoundFriendError.signIn }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded),
              let claims = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let expiry = claims["exp"] as? Double, expiry.isFinite,
              claims["sub"] as? String == owner.uuidString.lowercased() else { throw BoundFriendError.signIn }
        return Date(timeIntervalSince1970: expiry)
    }
    fileprivate func renew(token: String) throws {
        let expiry = try Self.expiry(token: token, owner: owner)
        guard expiry > Date() else { throw BoundFriendError.signIn }
        snapshot.update(token: token, expiry: expiry)
    }
    fileprivate func invalidate() { snapshot.update(token: nil, expiry: .distantPast) }
    func credentials() throws { _ = try validToken() }
    private func validToken() throws -> String {
        let value = snapshot.read()
        guard let token = value.token, value.expiry > Date() else { throw BoundFriendError.signIn }
        return token
    }
    private func request(path: String, body: [String: Any]) throws -> URLRequest {
        let token = try validToken()
        var request = URLRequest(url: URL(string: BoundFriendAccount.origin + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func friendOnboardingRequest(action: String, payload: [String: String]) throws -> URLRequest {
        try request(path: "/rest/v1/rpc/cup050_friends", body: ["action": action, "payload": payload])
    }
    func friendSharingRequest(roomID: String) throws -> URLRequest {
        try request(path: "/functions/v1/agora-token", body: ["roomID": roomID])
    }
    func accountUserRequest() throws -> URLRequest {
        var result = try request(path: "/auth/v1/user", body: [:])
        result.httpMethod = "GET"; result.httpBody = nil
        return result
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
    // A non-secret logout marker prevents resurrection if Keychain deletion fails while locked.
    private var logoutKey: String { service + ".signed-out." + BoundFriendAccount.origin }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: BoundFriendAccount.origin,
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

@MainActor
final class BoundFriendAccount: ObservableObject {
    nonisolated static let origin = "https://qevnxhngdtlyihhmvnjv.supabase.co"
    // All production game coordinators share one owner of the rotating refresh token.
    static let shared = BoundFriendAccount()
    @Published private(set) var session: AppCloudSession?
    @Published private(set) var busy = false
    @Published private(set) var status = "Sign in with your existing Bound account."
    @Published private(set) var deletionEmail: String?
    @Published private(set) var deletionPending = false
    private let storage: any BoundSessionStorage
    private let deletionStorage: any BoundSessionStorage
    private let configuration: () throws -> String
    private let transport: @MainActor (URLRequest) async throws -> BoundAuthTransport.Response
    private let automaticRefresh: Bool
    private var saved: BoundSavedSession?
    private var generation = UUID()
    private var refreshTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var activeObserver: BoundAuthObservation?
    private var restorePending = true
    private var removalPending = false
    private var savePending = false
    private var retryDelay: TimeInterval = 5
    private var pendingDeletion: BoundDeletionRecord?
    private var deletionIdentityOwner: UUID?

    init(storage: (any BoundSessionStorage)? = nil, deletionStorage: (any BoundSessionStorage)? = nil, automaticRefresh: Bool = true,
         configuration: @escaping () throws -> String = BoundFriendAccount.bundledKey,
         transport: @escaping @MainActor (URLRequest) async throws -> BoundAuthTransport.Response = BoundAuthTransport.perform) {
        self.storage = storage ?? BoundKeychainSessionStorage()
        self.deletionStorage = deletionStorage ?? BoundKeychainSessionStorage(service: (Bundle.main.bundleIdentifier ?? "Bound") + ".friend-account-deletion")
        self.configuration = configuration; self.transport = transport; self.automaticRefresh = automaticRefresh
        restore()
        restoreDeletion()
        #if canImport(UIKit)
        activeObserver = BoundAuthObservation(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshIfNeeded() }
        })
        #endif
    }
    deinit {
        timer?.cancel(); refreshTask?.cancel()
    }
    nonisolated static func bundledKey() throws -> String {
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
                saved = value; restorePending = false; status = "Signed in."
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
            let identity = try AppCloudSession(owner: next.owner, key: key, token: next.accessToken)
            // Publish a new login only after secure persistence succeeds.
            try storage.write(JSONEncoder().encode(next))
            saved = next; session = identity; retryDelay = 5; status = "Signed in."
            schedule(after: max(1, identity.expiresAt.timeIntervalSinceNow - 60))
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
        guard !busy, let saved, let session else { return }
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
            guard next.owner == previous.owner else { signOut(); return }
            // Keep a rotated refresh token in memory even if Keychain is temporarily locked.
            try session?.renew(token: next.accessToken)
            saved = next; savePending = true
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
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil; timer?.cancel(); timer = nil
        session?.invalidate(); session = nil; saved = nil; busy = false
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
        var request = URLRequest(url: URL(string: Self.origin + "/auth/v1/token?grant_type=" + grant)!)
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    enum SignupResult { case signedIn, checkEmail, failed, cancelled }
    func createAccount(email: String, password: String) async -> SignupResult {
        guard !busy, session == nil, !deletionPending else { return .failed }
        guard let email = Self.normalizedEmail(email), !password.isEmpty else {
            status = "Enter a valid email and a password."; return .failed
        }
        signOut()
        guard !removalPending else { return .failed }
        let run = generation; busy = true
        defer { if generation == run { busy = false } }
        var receivedSession = false
        do {
            let key = try configuration()
            var request = try tokenRequest(grant: "password", key: key, body: ["email": email, "password": password])
            request.url = URL(string: Self.origin + "/auth/v1/signup")!
            let response = try await transport(request)
            guard generation == run, !Task.isCancelled else { return .cancelled }
            guard (200..<300).contains(response.status) else {
                status = Self.signupError(response); return .failed
            }
            guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw BoundFriendError.unavailable }
            if object["access_token"] != nil || object["refresh_token"] != nil {
                let next = try decode(response.data)
                let identity = try AppCloudSession(owner: next.owner, key: key, token: next.accessToken)
                receivedSession = true
                try storage.write(JSONEncoder().encode(next))
                saved = next; session = identity; retryDelay = 5; status = "Signed in."
                schedule(after: max(1, identity.expiresAt.timeIntervalSinceNow - 60))
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
            status = receivedSession ? "Your account responded, but sign-in could not be saved securely. Unlock your device, then sign in." : "Could not finish account creation. Check your connection, then try signing in or creating an account again."
            return .failed
        }
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
            var request = URLRequest(url: URL(string: Self.origin + "/functions/v1/delete-account")!)
            request.httpMethod = "POST"; request.timeoutInterval = 10
            request.setValue(try configuration(), forHTTPHeaderField: "apikey")
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
