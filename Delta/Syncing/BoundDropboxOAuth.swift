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

/// Bound-owned Dropbox OAuth for Bound's configured sync provider. The pinned
/// SwiftyDropbox flow only returns implicit access tokens, so Bound exchanges
/// PKCE authorization codes and keeps the offline refresh token in Keychain.
final class BoundDropboxOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = BoundDropboxOAuth()

    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let error: String?
    }

    private enum OAuthFailure: LocalizedError, Equatable {
        case unavailable
        case malformedResponse
        case authorizationFailed
        case cancelled
        case refreshCredentialRejected

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Dropbox authorization is unavailable."
            case .malformedResponse: return "Dropbox returned an invalid authorization response."
            case .authorizationFailed: return "Dropbox authorization failed."
            case .cancelled: return "Dropbox authorization was cancelled."
            case .refreshCredentialRejected: return "Dropbox needs you to sign in again."
            }
        }
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let keychainService = "com.evanvonessen.bound.dropbox.refresh.v1"
    private let redirectDelegate = NoRedirectDelegate()
    private lazy var tokenSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }()
    private var session: ASWebAuthenticationSession?
    private var tokenTask: URLSessionDataTask?
    private var activeGeneration = UUID()
    private var pending: [(Result<String, Harmony.AuthenticationError>) -> Void] = []
    private var isResolving = false
    private weak var presentationWindow: UIWindow?

    private override init() { super.init() }

    func provideAccessToken(presenting viewController: UIViewController?, completion: @escaping (Result<String, Harmony.AuthenticationError>) -> Void) {
        DispatchQueue.main.async {
            guard let appKey = Self.configuredAppKey else {
                completion(.failure(.invalidClientID))
                return
            }

            self.pending.append(completion)
            if self.isResolving { return }
            self.isResolving = true
            self.presentationWindow = viewController?.viewIfLoaded?.window
            let generation = UUID()
            self.activeGeneration = generation

            if let refreshToken = self.refreshToken(for: appKey) {
                self.refresh(refreshToken: refreshToken, appKey: appKey, generation: generation) { result in
                    switch result {
                    case .success(let token): self.complete(.success(token), generation: generation)
                    case .failure(let error) where Self.isRejectedRefreshCredential(error) && viewController != nil:
                        self.beginInteractiveAuthorization(appKey: appKey, presenter: viewController, generation: generation)
                    case .failure(let error) where Self.isRejectedRefreshCredential(error):
                        self.complete(.failure(.tokenExpired), generation: generation)
                    case .failure(let error): self.complete(.failure(error), generation: generation)
                    }
                }
            } else if let viewController {
                self.beginInteractiveAuthorization(appKey: appKey, presenter: viewController, generation: generation)
            } else {
                self.complete(.failure(.noSavedCredentials), generation: generation)
            }
        }
    }

    /// Cancels pending OAuth callbacks but preserves the refresh credential.
    /// Used to cancel authorization when its owning sync operation is cancelled.
    func cancelPendingAuthorization() {
        onMain {
            self.activeGeneration = UUID()
            self.session?.cancel()
            self.session = nil
            self.tokenTask?.cancel()
            self.tokenTask = nil
            self.presentationWindow = nil
            self.isResolving = false
            let handlers = self.pending
            self.pending.removeAll()
            handlers.forEach { $0(.failure(.noSavedCredentials)) }
        }
    }

    /// Clears Bound's refresh credential on explicit Dropbox deauthentication.
    func clearCredentials() {
        onMain {
            self.cancelPendingAuthorizationOnMain()
            guard let appKey = Self.rawAppKey else { return }
            self.deleteRefreshToken(for: appKey)
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let presentationWindow { return presentationWindow }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
    }

    private static var configuredAppKey: String? {
        return rawAppKey
    }

    private static var rawAppKey: String? {
        guard let raw = Bundle.main.infoDictionary?["BOUND_DROPBOX_APP_KEY"] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[A-Za-z0-9]{8,64}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    private static func isRejectedRefreshCredential(_ error: Harmony.AuthenticationError) -> Bool {
        guard case .other(let underlying) = error else { return false }
        return (underlying as? OAuthFailure) == .refreshCredentialRejected
    }

    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() }
        else { DispatchQueue.main.async(execute: action) }
    }

    private func cancelPendingAuthorizationOnMain() {
        activeGeneration = UUID()
        session?.cancel()
        session = nil
        tokenTask?.cancel()
        tokenTask = nil
        presentationWindow = nil
        isResolving = false
        let handlers = pending
        pending.removeAll()
        handlers.forEach { $0(.failure(.noSavedCredentials)) }
    }

    private func beginInteractiveAuthorization(appKey: String, presenter: UIViewController?, generation: UUID) {
        guard generation == activeGeneration,
              presenter != nil,
              let verifierData = Self.randomData(count: 32),
              let stateData = Self.randomData(count: 32) else {
            complete(.failure(.invalidClientID), generation: generation)
            return
        }

        let verifier = BoundDropboxOAuthProtocol.base64URL(verifierData)
        let state = BoundDropboxOAuthProtocol.base64URL(stateData)
        let callbackScheme = "db-\(appKey)"
        let redirectURI = "\(callbackScheme)://2/token"
        guard let authorizeURL = BoundDropboxOAuthProtocol.authorizationURL(appKey: appKey, state: state, verifier: verifier) else {
            complete(.failure(.invalidClientID), generation: generation)
            return
        }

        let authSession = ASWebAuthenticationSession(url: authorizeURL, callbackURLScheme: callbackScheme) { [weak self] callback, error in
            DispatchQueue.main.async {
                guard let self, generation == self.activeGeneration else { return }
                self.session = nil
                guard let callback else {
                    self.complete(.failure(.other(error ?? OAuthFailure.cancelled)), generation: generation)
                    return
                }
                guard let code = BoundDropboxOAuthProtocol.authorizationCode(from: callback, callbackScheme: callbackScheme, expectedState: state) else {
                    self.complete(.failure(.other(OAuthFailure.authorizationFailed)), generation: generation)
                    return
                }
                self.exchange(code: code, verifier: verifier, redirectURI: redirectURI, appKey: appKey, generation: generation) { result in
                    self.complete(result, generation: generation)
                }
            }
        }
        authSession.presentationContextProvider = self
        authSession.prefersEphemeralWebBrowserSession = false
        session = authSession
        guard authSession.start() else {
            complete(.failure(.other(OAuthFailure.authorizationFailed)), generation: generation)
            return
        }
    }

    private func refresh(refreshToken: String, appKey: String, generation: UUID, completion: @escaping (Result<String, Harmony.AuthenticationError>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = BoundDropboxOAuthProtocol.formBody([("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", appKey)])
        tokenTask = tokenSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard generation == self.activeGeneration else { return }
                self.tokenTask = nil
                if let error {
                    completion(.failure(.other(ServiceError.connectionFailed((error as? URLError) ?? URLError(.unknown)))))
                    return
                }
                if let data, let http = response as? HTTPURLResponse,
                   BoundDropboxOAuthProtocol.isInvalidRefreshCredential(statusCode: http.statusCode, responseBody: data) {
                    self.deleteRefreshToken(for: appKey)
                    completion(.failure(.other(OAuthFailure.refreshCredentialRejected)))
                    return
                }
                guard let data, let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data),
                      let accessToken = tokens.access_token, !accessToken.isEmpty else {
                    completion(.failure(.other(ServiceError.connectionFailed(URLError(.badServerResponse)))))
                    return
                }
                if let newRefresh = tokens.refresh_token, !self.storeRefreshToken(newRefresh, for: appKey) {
                    completion(.failure(.other(OAuthFailure.authorizationFailed)))
                    return
                }
                completion(.success(accessToken))
            }
        }
        tokenTask?.resume()
    }

    private func exchange(code: String, verifier: String, redirectURI: String, appKey: String, generation: UUID, completion: @escaping (Result<String, Harmony.AuthenticationError>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = BoundDropboxOAuthProtocol.formBody([
            ("grant_type", "authorization_code"), ("code", code), ("code_verifier", verifier),
            ("redirect_uri", redirectURI), ("client_id", appKey)
        ])
        tokenTask = tokenSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard generation == self.activeGeneration else { return }
                self.tokenTask = nil
                if let error {
                    completion(.failure(.other(ServiceError.connectionFailed((error as? URLError) ?? URLError(.unknown)))))
                    return
                }
                guard let data, let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data),
                      let accessToken = tokens.access_token, !accessToken.isEmpty,
                      let refreshToken = tokens.refresh_token else {
                    completion(.failure(.other(ServiceError.connectionFailed(URLError(.badServerResponse)))))
                    return
                }
                guard self.storeRefreshToken(refreshToken, for: appKey) else {
                    completion(.failure(.other(OAuthFailure.authorizationFailed)))
                    return
                }
                completion(.success(accessToken))
            }
        }
        tokenTask?.resume()
    }

    private func complete(_ result: Result<String, Harmony.AuthenticationError>, generation: UUID) {
        guard generation == activeGeneration else { return }
        isResolving = false
        session = nil
        presentationWindow = nil
        let handlers = pending
        pending.removeAll()
        handlers.forEach { $0(result) }
    }

    private func refreshToken(for appKey: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: appKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func storeRefreshToken(_ token: String, for appKey: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: appKey]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private func deleteRefreshToken(for appKey: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: appKey]
        SecItemDelete(query as CFDictionary)
    }

    private static func randomData(count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

}
