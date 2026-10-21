import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit
import Harmony
import SwiftyDropbox

enum BoundDropboxOAuthProtocol {
    private struct RefreshError: Decodable { let error: String? }

    static func challenge(for verifier: String) -> String {
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        return base64URL(digest)
    }

    static func authorizationURL(appKey: String, state: String, verifier: String) -> URL? {
        let callbackScheme = "db-\(appKey)"
        var components = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "token_access_type", value: "offline"),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: "\(callbackScheme)://2/token"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: "account_info.read files.metadata.read files.metadata.write files.content.read files.content.write")
        ]
        return components?.url
    }

    static func authorizationCode(from url: URL, callbackScheme: String, expectedState: String) -> String? {
        guard url.scheme == callbackScheme, url.host == "2", url.path == "/token",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "state" })?.value == expectedState,
              let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { return nil }
        return code
    }

    static func isInvalidRefreshCredential(statusCode: Int, responseBody: Data) -> Bool {
        statusCode == 400 && (try? JSONDecoder().decode(RefreshError.self, from: responseBody).error) == "invalid_grant"
    }

    static func formBody(_ items: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let string = items.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(string.utf8)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Account-linked OAuth. Only short-lived access tokens reach this device;
/// the Bound backend encrypts the offline grant and binds it to the Auth owner.
@MainActor
final class BoundDropboxOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = BoundDropboxOAuth(acceptConnection: { owner, connection in
        SyncManager.shared.acceptDropboxConnection(owner: owner, connection: connection)
    })

    enum Failure: LocalizedError {
        case signIn, notLinked, notConfigured, unavailable, rateLimited, secondFactorRequired, changed, cancelled
        var errorDescription: String? {
            switch self {
            case .signIn: return "Sign in to your Bound account in Account & Sync before connecting Dropbox."
            case .notLinked: return "Connect Dropbox to your Bound account to enable cloud sync."
            case .notConfigured: return "Dropbox sync is unavailable because Bound’s connection service has not been set up yet. Please try again later."
            case .unavailable: return "Dropbox connection is unavailable. Check your connection and try again."
            case .rateLimited: return "Dropbox connection requests are temporarily limited. Wait a moment, then try again."
            case .secondFactorRequired: return "Complete two-factor sign-in to your Bound account before connecting Dropbox."
            case .changed: return "Your account or Dropbox connection changed. Please try again."
            case .cancelled: return "Dropbox authorization was cancelled."
            }
        }
    }
    private struct Reply: Decodable { let accessToken: String?; let expiresIn: Double?; let error: String?; let ok: Bool?; let connectionID: UUID? }
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, Int)
    private let account: BoundFriendAccount
    private let transport: Transport
    private let appKey: () -> String?
    private let acceptConnection: @MainActor (UUID, UUID) -> Bool
    private var webSession: ASWebAuthenticationSession?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var pending: [(Result<String, Harmony.AuthenticationError>) -> Void] = []
    private weak var presentationWindow: UIWindow?

    init(account: BoundFriendAccount? = nil,
         appKey: @escaping () -> String? = BoundDropboxOAuth.configuredAppKey,
         acceptConnection: @escaping @MainActor (UUID, UUID) -> Bool = { _, _ in true },
         transport: @escaping Transport = BoundDropboxOAuth.perform) {
        self.account = account ?? .shared; self.appKey = appKey; self.transport = transport; self.acceptConnection = acceptConnection
        super.init()
    }

    nonisolated static func configuredAppKey() -> String? {
        guard let value = Bundle.main.infoDictionary?["BOUND_DROPBOX_APP_KEY"] as? String,
              value.range(of: "^[A-Za-z0-9]{8,64}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static let network: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()
    static func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await network.data(for: request)
        guard data.count <= 32768, let response = response as? HTTPURLResponse else { throw Failure.unavailable }
        return (data, response.statusCode)
    }

    func provideAccessToken(presenting viewController: UIViewController?, completion: @escaping (Result<String, Harmony.AuthenticationError>) -> Void) {
        pending.append(completion)
        guard task == nil, webSession == nil else { return }
        let run = generation
        presentationWindow = viewController?.viewIfLoaded?.window
        task = Task { [weak self] in
            guard let self else { return }
            await account.refreshIfNeeded()
            guard generation == run, !Task.isCancelled else { return }
            guard let identity = account.session, !account.deletionPending else {
                complete(.failure(.other(Failure.signIn)), run: run); return
            }
            do {
                let access = try await request(identity, action: "token")
                guard accepts(identity, run: run) else { throw Failure.changed }
                complete(.success(access), run: run)
            } catch Failure.notLinked {
                guard accepts(identity, run: run) else { complete(.failure(.other(Failure.changed)), run: run); return }
                task = nil
                if let viewController { beginAuthorization(identity, presenter: viewController, run: run) }
                else { complete(.failure(.noSavedCredentials), run: run) }
            } catch {
                complete(.failure(.other(error)), run: run)
            }
        }
    }

    private func accepts(_ identity: AppCloudSession, run: UUID) -> Bool {
        generation == run && !Task.isCancelled && !account.deletionPending && identity.isSameSession(as: account.session)
    }

    private func request(_ identity: AppCloudSession, action: String, code: String? = nil, verifier: String? = nil) async throws -> String {
        let result: (Data, Int)
        do { result = try await transport(identity.dropboxLinkRequest(action: action, code: code, verifier: verifier)) }
        catch { throw Failure.unavailable }
        let (data, status) = result
        // Never propagate backend bodies or transport diagnostics containing credentials.
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw Failure.unavailable }
        if status == 404 && reply.error == "not_linked" || status == 409 && reply.error == "reconnect_required" { throw Failure.notLinked }
        if status == 503 && reply.error == "not_configured" { throw Failure.notConfigured }
        if status == 429 { throw Failure.rateLimited }
        if status == 403 && reply.error == "second_factor_required" { throw Failure.secondFactorRequired }
        if status == 401 || status == 403 { throw Failure.signIn }
        if status == 409 { throw Failure.changed }
        guard status == 200 else { throw Failure.unavailable }
        if action == "unlink" {
            guard reply.ok == true else { throw Failure.unavailable }
            return ""
        }
        guard let token = reply.accessToken, !token.isEmpty, token.utf8.count <= 16384,
              let expiry = reply.expiresIn, expiry.isFinite, expiry > 0,
              let connection = reply.connectionID else { throw Failure.unavailable }
        guard !Task.isCancelled, identity.isSameSession(as: account.session), !account.deletionPending,
              acceptConnection(identity.owner, connection) else { throw Failure.changed }
        return token
    }

    func unlink() async throws {
        await account.refreshIfNeeded()
        guard let identity = account.session, !account.deletionPending else { throw Failure.signIn }
        let run = generation
        _ = try await request(identity, action: "unlink")
        guard accepts(identity, run: run) else { throw Failure.changed }
        clearCredentials()
    }

    /// Device sign-out/cancellation never unlinks the server grant.
    func cancelPendingAuthorization() {
        generation = UUID()
        task?.cancel(); task = nil
        webSession?.cancel(); webSession = nil
        presentationWindow = nil
        let handlers = pending; pending.removeAll()
        handlers.forEach { $0(.failure(.other(Failure.changed))) }
    }
    func clearCredentials() {
        cancelPendingAuthorization()
        // Retire legacy unowned credentials; never silently attach them to a user.
        guard let appKey = appKey() else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.evanvonessen.bound.dropbox.refresh.v1", kSecAttrAccount as String: appKey]
        SecItemDelete(query as CFDictionary)
    }
    private func complete(_ result: Result<String, Harmony.AuthenticationError>, run: UUID) {
        guard generation == run else { return }
        task = nil; webSession = nil; presentationWindow = nil
        let handlers = pending; pending.removeAll()
        handlers.forEach { $0(result) }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationWindow ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
    }
    private func beginAuthorization(_ identity: AppCloudSession, presenter: UIViewController, run: UUID) {
        guard let appKey = appKey(), let verifierData = Self.randomData(), let stateData = Self.randomData() else {
            complete(.failure(.invalidClientID), run: run); return
        }
        let verifier = BoundDropboxOAuthProtocol.base64URL(verifierData)
        let state = BoundDropboxOAuthProtocol.base64URL(stateData)
        let scheme = "db-\(appKey)"
        guard let url = BoundDropboxOAuthProtocol.authorizationURL(appKey: appKey, state: state, verifier: verifier) else {
            complete(.failure(.invalidClientID), run: run); return
        }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] callback, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == run else { return }
                guard self.accepts(identity, run: run) else {
                    self.complete(.failure(.other(Failure.changed)), run: run); return
                }
                self.webSession = nil
                guard let callback, let code = BoundDropboxOAuthProtocol.authorizationCode(from: callback, callbackScheme: scheme, expectedState: state) else {
                    self.complete(.failure(.other(Failure.cancelled)), run: run); return
                }
                self.task = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let access = try await self.request(identity, action: "link", code: code, verifier: verifier)
                        guard self.accepts(identity, run: run) else { throw Failure.changed }
                        self.complete(.success(access), run: run)
                    } catch { self.complete(.failure(.other(error)), run: run) }
                }
            }
        }
        presentationWindow = presenter.viewIfLoaded?.window
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        webSession = session
        if !session.start() { complete(.failure(.other(Failure.unavailable)), run: run) }
    }
    private static func randomData() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }
}
