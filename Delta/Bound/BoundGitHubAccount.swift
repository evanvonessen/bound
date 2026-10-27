import Combine
import Foundation
import Security

@MainActor
protocol BoundGitHubCredentialStorage {
    var needsRemoval: Bool { get }
    func read() throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}

extension BoundGitHubCredentialStorage {
    var needsRemoval: Bool { false }
}

/// A separate, device-only credential. Signing out never touches Bound or Dropbox.
@MainActor
struct BoundGitHubKeychainStorage: BoundGitHubCredentialStorage {
    struct Calls {
        var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
        var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
        var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
        var delete: (CFDictionary) -> OSStatus = SecItemDelete
    }
    var calls = Calls()
    var defaults = UserDefaults.standard
    var service = (Bundle.main.bundleIdentifier ?? "Bound") + ".github"
    private var logoutKey: String { service + ".signed-out" }
    var needsRemoval: Bool { defaults.bool(forKey: logoutKey) }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "github.com", kSecAttrSynchronizable as String: false]
    }
    func read() throws -> Data? {
        guard !defaults.bool(forKey: logoutKey) else { return nil }
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = calls.copy(query as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data else { throw BoundGitHubAccount.Failure.storage }
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
        guard result == errSecSuccess else { throw BoundGitHubAccount.Failure.storage }
        defaults.set(false, forKey: logoutKey)
    }
    func remove() throws {
        // Do not restore a login on relaunch if Keychain was locked during sign-out.
        defaults.set(true, forKey: logoutKey)
        let result = calls.delete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw BoundGitHubAccount.Failure.storage }
        defaults.set(false, forKey: logoutKey)
    }
}

private final class BoundGitHubNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// GitHub's native device grant uses a registered public client ID, never a client secret.
/// It is deliberately independent of ROM distribution and the Bound account session.
@MainActor
final class BoundGitHubAccount: ObservableObject {
    // Retained credentials must not initiate network activity on initialization.
    static let shared = BoundGitHubAccount(automaticRefresh: false)
    @Published private(set) var username: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var userCode: String?
    @Published private(set) var verificationURL: URL?
    @Published private(set) var status = ""
    @Published private(set) var needsCredentialRemoval = false
    var isConfigured: Bool { clientID() != nil }

    enum Failure: LocalizedError {
        case notConfigured, unavailable, denied, expired, unauthorized, storage, disabled
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "GitHub sign-in requires a registered Bound client ID."
            case .unavailable: return "GitHub is unavailable. Try again."
            case .denied: return "GitHub sign-in was declined."
            case .expired: return "GitHub code expired. Sign in again."
            case .unauthorized: return "Sign in to GitHub again."
            case .storage: return "GitHub credentials could not be saved or removed. Unlock your device and try again."
            case .disabled: return "Device sign-in is not enabled for Bound’s GitHub app."
            }
        }
    }
    private struct Credential: Codable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        var clientID: String
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var description: String { "GitHubCredential(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["credential": "redacted"]) }
    }
    private struct DeviceReply: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Double
        let interval: Double
    }
    private struct TokenReply: Decodable {
        let access_token: String?
        let token_type: String?
        let refresh_token: String?
        let expires_in: Double?
        let error: String?
        let interval: Double?
    }
    private struct UserReply: Decodable { let id: Int; let login: String }
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, Int)
    typealias Sleep = @MainActor (Double) async throws -> Void
    private let storage: BoundGitHubCredentialStorage
    private let clientID: () -> String?
    private let transport: Transport
    private let sleep: Sleep
    private let now: () -> Date
    private var credential: Credential?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(storage: BoundGitHubCredentialStorage? = nil,
         clientID: @escaping () -> String? = BoundGitHubAccount.configuredClientID,
         transport: @escaping Transport = BoundGitHubAccount.perform,
         sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         now: @escaping () -> Date = Date.init, automaticRefresh: Bool = true) {
        self.storage = storage ?? BoundGitHubKeychainStorage()
        self.clientID = clientID; self.transport = transport; self.sleep = sleep; self.now = now
        self.needsCredentialRemoval = self.storage.needsRemoval
        if automaticRefresh { refresh() }
    }

    nonisolated static func configuredClientID() -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BOUND_GITHUB_CLIENT_ID") as? String,
              value.range(of: "^[A-Za-z0-9._-]{10,80}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    func signIn(openURL: @escaping @MainActor (URL) -> Void) {
        cancelWork()
        guard !needsCredentialRemoval else { status = Failure.storage.localizedDescription; return }
        guard let clientID = clientID() else { status = Failure.notConfigured.localizedDescription; return }
        let run = generation
        isSigningIn = true; status = "Connecting to GitHub…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let (data, code) = try await transport(Self.request("https://github.com/login/device/code", form: [("client_id", clientID)]))
                try check(run)
                if let error = try? JSONDecoder().decode(TokenReply.self, from: data).error, error == "device_flow_disabled" { throw Failure.disabled }
                guard code == 200, let reply = try? JSONDecoder().decode(DeviceReply.self, from: data),
                      reply.verification_uri == "https://github.com/login/device",
                      !reply.device_code.isEmpty, reply.device_code.count <= 512,
                      reply.user_code.range(of: "^[A-Z0-9]{4}-[A-Z0-9]{4}$", options: .regularExpression) != nil,
                      reply.interval.isFinite, reply.interval >= 1, reply.interval <= 900,
                      reply.expires_in.isFinite, reply.expires_in > 0, reply.expires_in <= 1800 else { throw Failure.unavailable }
                let deadline = now().addingTimeInterval(reply.expires_in)
                var interval = reply.interval
                userCode = reply.user_code
                verificationURL = URL(string: reply.verification_uri)!
                status = "Enter this code on GitHub."
                openURL(verificationURL!)
                while true {
                    try check(run)
                    guard now().addingTimeInterval(interval) < deadline else { throw Failure.expired }
                    try await sleep(interval)
                    try check(run)
                    guard now() < deadline else { throw Failure.expired }
                    let (data, code) = try await transport(Self.request("https://github.com/login/oauth/access_token", form: [
                        ("client_id", clientID), ("device_code", reply.device_code), ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")]))
                    try check(run)
                    guard code == 200, let token = try? JSONDecoder().decode(TokenReply.self, from: data) else { throw Failure.unavailable }
                    switch token.error {
                    case "authorization_pending": continue
                    case "slow_down":
                        interval = max(interval + 5, token.interval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0)
                        continue
                    case "access_denied": throw Failure.denied
                    case "expired_token", "token_expired": throw Failure.expired
                    case "device_flow_disabled": throw Failure.disabled
                    case .some: throw Failure.unavailable
                    case .none: break
                    }
                    let saved = try makeCredential(token, clientID: clientID)
                    let login = try await identify(saved)
                    try check(run)
                    do { try storage.write(JSONEncoder().encode(saved)) } catch { throw Failure.storage }
                    credential = saved; username = login; status = "Signed in as \(login)"
                    finish(run); return
                }
            } catch {
                guard generation == run else { return }
                status = (error as? Failure ?? .unavailable).localizedDescription
                finish(run)
            }
        }
    }

    func cancelSignIn() {
        let wasSigningIn = isSigningIn
        cancelWork()
        if wasSigningIn { status = username.map { "Signed in as \($0)" } ?? "Sign-in cancelled." }
    }

    func signOut() {
        cancelWork(); credential = nil; username = nil; status = ""
        do { try storage.remove(); needsCredentialRemoval = false }
        catch {
            needsCredentialRemoval = true
            status = "Signed out. Unlock your device and retry Sign Out to remove the saved credential."
        }
    }

    func refresh() {
        if needsCredentialRemoval { signOut(); return }
        guard task == nil, let clientID = clientID() else { return }
        let run = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var saved: Credential
                if let credential { saved = credential }
                else {
                    let data: Data?
                    do { data = try storage.read() } catch { throw Failure.storage }
                    guard let data else { finish(run); return }
                    guard let stored = try? JSONDecoder().decode(Credential.self, from: data) else { throw Failure.storage }
                    saved = stored
                }
                guard saved.clientID == clientID else { throw Failure.unauthorized }
                if let expiry = saved.expiresAt, expiry <= now().addingTimeInterval(30) {
                    guard let refresh = saved.refreshToken else { throw Failure.unauthorized }
                    let (data, code) = try await transport(Self.request("https://github.com/login/oauth/access_token", form: [
                        ("client_id", clientID), ("grant_type", "refresh_token"), ("refresh_token", refresh)]))
                    try check(run)
                    guard let token = try? JSONDecoder().decode(TokenReply.self, from: data) else { throw Failure.unavailable }
                    if code == 200 || code == 400 {
                        if token.error == "bad_refresh_token" { throw Failure.unauthorized }
                    }
                    guard code == 200, token.error == nil else { throw Failure.unavailable }
                    saved = try makeCredential(token, clientID: clientID)
                    // Rotation invalidates the old grant; retain the new token even if /user fails.
                    credential = saved
                    do { try storage.write(JSONEncoder().encode(saved)) } catch { throw Failure.storage }
                }
                let login = try await identify(saved)
                try check(run)
                do { try storage.write(JSONEncoder().encode(saved)) } catch { throw Failure.storage }
                credential = saved; username = login; status = "Signed in as \(login)"
            } catch {
                guard generation == run else { return }
                if case Failure.unauthorized = error {
                    credential = nil; username = nil
                    do { try storage.remove(); needsCredentialRemoval = false }
                    catch { needsCredentialRemoval = true }
                }
                status = (error as? Failure ?? .unavailable).localizedDescription
            }
            finish(run)
        }
    }

    private func identify(_ saved: Credential) async throws -> String {
        var request = Self.request("https://api.github.com/user")
        request.setValue("Bearer " + saved.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, code) = try await transport(request)
        if code == 401 { throw Failure.unauthorized }
        guard code == 200, let user = try? JSONDecoder().decode(UserReply.self, from: data), user.id > 0,
              user.login.range(of: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", options: .regularExpression) != nil else { throw Failure.unavailable }
        return user.login
    }

    private func makeCredential(_ reply: TokenReply, clientID: String) throws -> Credential {
        guard let token = reply.access_token, !token.isEmpty, token.count <= 2048,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              reply.token_type?.lowercased() == "bearer" else { throw Failure.unavailable }
        if let seconds = reply.expires_in, !seconds.isFinite || seconds <= 0 { throw Failure.unavailable }
        return Credential(clientID: clientID, accessToken: token, refreshToken: reply.refresh_token,
                          expiresAt: reply.expires_in.map { now().addingTimeInterval($0) })
    }
    private func check(_ run: UUID) throws {
        guard generation == run, !Task.isCancelled else { throw CancellationError() }
    }
    private func cancelWork() {
        generation = UUID(); task?.cancel(); task = nil
        isSigningIn = false; userCode = nil; verificationURL = nil
    }
    private func finish(_ run: UUID) {
        guard generation == run else { return }
        task = nil; isSigningIn = false; userCode = nil; verificationURL = nil
    }
    nonisolated static func request(_ url: String, form: [(String, String)]? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bound", forHTTPHeaderField: "User-Agent")
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            request.httpBody = Data(form.map { key, value in
                "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }.joined(separator: "&").utf8)
        }
        return request
    }
    static func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let client = URLSession(configuration: config, delegate: BoundGitHubNoRedirect(), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        let (bytes, response) = try await client.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw Failure.unavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65_536 else { throw Failure.unavailable }
            data.append(byte)
        }
        return (data, response.statusCode)
    }
}
