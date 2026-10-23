import Foundation
import AuthenticationServices
import UIKit

/// The system owns passkey private keys. This bridge only forwards the server's
/// challenge and the signed WebAuthn response; it never saves credentials.
@MainActor
enum BoundPasskeyAuthorization {
    enum Failure: LocalizedError {
        case notConfigured, invalidOptions, unavailable, inProgress
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Passkeys are not configured for this app yet."
            case .invalidOptions: return "Could not start a secure passkey request. Try again."
            case .unavailable: return "Passkeys are unavailable. Check your device and try again."
            case .inProgress: return "Finish the current passkey request before starting another."
            }
        }
    }

    private static var active: Ceremony?
    static var isConfigured: Bool { configuredRelyingPartyID != nil }

    /// This public configuration must agree with the account service and the app's signed
    /// webcredentials entitlement. Never derive the trusted RP from a response.
    private static var configuredRelyingPartyID: String? {
        guard let url = Bundle.main.url(forResource: "cloud-configuration", withExtension: "json"),
              let bytes = try? Data(contentsOf: url), bytes.count <= 16384,
              let config = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              config["origin"] as? String == BoundFriendAccount.origin,
              let rp = config["passkeyRelyingPartyID"] as? String,
              validRelyingPartyID(rp) else { return nil }
        return rp
    }

    static func registration(options: Data) async throws -> Data {
        try Task.checkCancellation()
        guard let rp = configuredRelyingPartyID else { throw Failure.notConfigured }
        let parsed = try registrationRequest(options: options, relyingPartyID: rp)
        return try await perform(request: parsed.request, challenge: parsed.challenge,
                                 expiresAt: parsed.expiresAt, kind: .registration)
    }

    static func authentication(options: Data) async throws -> Data {
        try Task.checkCancellation()
        guard let rp = configuredRelyingPartyID else { throw Failure.notConfigured }
        let parsed = try authenticationRequest(options: options, relyingPartyID: rp)
        return try await perform(request: parsed.request, challenge: parsed.challenge,
                                 expiresAt: parsed.expiresAt, kind: .authentication)
    }

    static func cancel() { active?.cancel() }

    struct Request {
        let request: ASAuthorizationRequest
        let challenge: Data
        let expiresAt: Date
    }

    /// Kept separate from presentation so malformed responses can be tested
    /// without opening biometric or account-picker UI.
    static func registrationRequest(options data: Data, relyingPartyID: String) throws -> Request {
        let envelope = try envelope(data)
        let options = envelope.options
        guard validRelyingPartyID(relyingPartyID),
              let rp = options["rp"] as? [String: Any], rp["id"] as? String == relyingPartyID,
              let user = options["user"] as? [String: Any],
              let name = user["name"] as? String, !name.isEmpty, name.utf8.count <= 320,
              let userID = decodeBase64URL(user["id"], limit: 64), !userID.isEmpty,
              let params = options["pubKeyCredParams"] as? [[String: Any]],
              params.contains(where: { $0["type"] as? String == "public-key" && $0["alg"] as? Int == -7 }),
              options["attestation"] == nil || options["attestation"] as? String == "none" else { throw Failure.invalidOptions }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyID)
        let request = provider.createCredentialRegistrationRequest(challenge: envelope.challenge, name: name, userID: userID)
        if let displayName = user["displayName"] as? String {
            guard displayName.utf8.count <= 1024 else { throw Failure.invalidOptions }
            request.displayName = displayName
        }
        request.userVerificationPreference = .required
        request.attestationPreference = .none
        let excluded = try credentialDescriptors(options["excludeCredentials"])
        if #available(iOS 17.4, *) { request.excludedCredentials = excluded }
        else if !excluded.isEmpty { throw Failure.unavailable }
        return Request(request: request, challenge: envelope.challenge, expiresAt: envelope.expiresAt)
    }

    static func authenticationRequest(options data: Data, relyingPartyID: String) throws -> Request {
        let envelope = try envelope(data)
        guard validRelyingPartyID(relyingPartyID), envelope.options["rpId"] as? String == relyingPartyID else { throw Failure.invalidOptions }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyID)
        let request = provider.createCredentialAssertionRequest(challenge: envelope.challenge)
        request.userVerificationPreference = .required
        request.allowedCredentials = try credentialDescriptors(envelope.options["allowCredentials"])
        return Request(request: request, challenge: envelope.challenge, expiresAt: envelope.expiresAt)
    }

    private static func validRelyingPartyID(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.count <= 253 && value == value.lowercased() && labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    private static func envelope(_ data: Data) throws -> (options: [String: Any], challenge: Data, expiresAt: Date) {
        guard data.count <= 65536,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = value["challenge_id"] as? String, UUID(uuidString: id) != nil,
              let expires = value["expires_at"] as? Double, expires.isFinite,
              expires > Date().timeIntervalSince1970, expires <= Date().timeIntervalSince1970 + 600,
              let options = value["options"] as? [String: Any],
              let challenge = decodeBase64URL(options["challenge"], limit: 1024), challenge.count >= 16 else { throw Failure.invalidOptions }
        return (options, challenge, Date(timeIntervalSince1970: expires))
    }

    private static func credentialDescriptors(_ raw: Any?) throws -> [ASAuthorizationPlatformPublicKeyCredentialDescriptor] {
        guard let raw else { return [] }
        guard let values = raw as? [[String: Any]], values.count <= 100 else { throw Failure.invalidOptions }
        return try values.map { value in
            guard value["type"] as? String == "public-key", let id = decodeBase64URL(value["id"], limit: 4096), !id.isEmpty else { throw Failure.invalidOptions }
            return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: id)
        }
    }

    private static func decodeBase64URL(_ raw: Any?, limit: Int) -> Data? {
        guard let value = raw as? String, !value.isEmpty, value.utf8.count <= limit * 2,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), data.count <= limit, base64URL(data) == value else { return nil }
        return data
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func registrationCredential(credentialID: Data, clientDataJSON: Data, attestationObject: Data, challenge: Data) throws -> Data {
        try validateClientData(clientDataJSON, type: "webauthn.create", challenge: challenge)
        guard !attestationObject.isEmpty, attestationObject.count <= 65536 else { throw Failure.invalidOptions }
        return try credential(credentialID: credentialID, response: [
            "clientDataJSON": base64URL(clientDataJSON), "attestationObject": base64URL(attestationObject), "transports": ["internal"]
        ])
    }

    static func authenticationCredential(credentialID: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userID: Data, challenge: Data) throws -> Data {
        try validateClientData(clientDataJSON, type: "webauthn.get", challenge: challenge)
        guard !authenticatorData.isEmpty, authenticatorData.count <= 65536, !signature.isEmpty, signature.count <= 16384,
              !userID.isEmpty, userID.count <= 64 else { throw Failure.invalidOptions }
        return try credential(credentialID: credentialID, response: [
            "clientDataJSON": base64URL(clientDataJSON), "authenticatorData": base64URL(authenticatorData),
            "signature": base64URL(signature), "userHandle": base64URL(userID)
        ])
    }

    private static func credential(credentialID: Data, response: [String: Any]) throws -> Data {
        guard !credentialID.isEmpty, credentialID.count <= 4096 else { throw Failure.invalidOptions }
        return try JSONSerialization.data(withJSONObject: [
            "id": base64URL(credentialID), "rawId": base64URL(credentialID), "type": "public-key",
            "response": response, "clientExtensionResults": [String: String]()
        ])
    }

    private static func validateClientData(_ data: Data, type: String, challenge: Data) throws {
        guard data.count <= 16384,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["type"] as? String == type,
              decodeBase64URL(value["challenge"], limit: 1024) == challenge else { throw Failure.invalidOptions }
    }

    private static func perform(request: ASAuthorizationRequest, challenge: Data, expiresAt: Date, kind: Ceremony.Kind) async throws -> Data {
        try Task.checkCancellation()
        guard active == nil else { throw Failure.inProgress }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else { throw Failure.unavailable }
        let ceremony = Ceremony(request: request, window: window, challenge: challenge, expiresAt: expiresAt, kind: kind)
        active = ceremony
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { ceremony.cancelBeforeStarting(continuation) }
                else { ceremony.start(continuation) }
            }
        }, onCancel: { Task { @MainActor in ceremony.cancel() } })
    }

    private final class Ceremony: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        enum Kind { case registration, authentication }
        let controller: ASAuthorizationController
        let window: UIWindow
        let challenge: Data
        let expiresAt: Date
        let kind: Kind
        private var continuation: CheckedContinuation<Data, Error>?
        private var expiryTask: Task<Void, Never>?
        private var cancelled = false
        private var started = false
        init(request: ASAuthorizationRequest, window: UIWindow, challenge: Data, expiresAt: Date, kind: Kind) {
            controller = ASAuthorizationController(authorizationRequests: [request])
            self.window = window; self.challenge = challenge; self.expiresAt = expiresAt; self.kind = kind
            super.init()
            controller.delegate = self; controller.presentationContextProvider = self
        }
        func start(_ continuation: CheckedContinuation<Data, Error>) {
            self.continuation = continuation; started = true
            expiryTask = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(nanoseconds: UInt64(max(0, self.expiresAt.timeIntervalSinceNow) * 1_000_000_000)) }
                catch { return }
                self.cancel()
            }
            controller.performRequests()
        }
        func cancelBeforeStarting(_ continuation: CheckedContinuation<Data, Error>) {
            self.continuation = continuation
            cancelled = true; finish(.failure(CancellationError()))
        }
        func cancel() {
            guard !cancelled else { return }
            cancelled = true; expiryTask?.cancel(); expiryTask = nil
            continuation?.resume(throwing: CancellationError()); continuation = nil
            // Keep the global slot occupied until the system confirms dismissal.
            if started { controller.cancel() }
            else { finish(.failure(CancellationError())) }
        }
        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window }
        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            guard !cancelled, expiresAt > Date() else { finish(.failure(CancellationError())); return }
            do {
                let credential: Data
                if kind == .registration, let value = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
                   let attestation = value.rawAttestationObject, !attestation.isEmpty {
                    credential = try registrationCredential(credentialID: value.credentialID, clientDataJSON: value.rawClientDataJSON,
                                                            attestationObject: attestation, challenge: challenge)
                } else if kind == .authentication, let value = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
                    credential = try authenticationCredential(credentialID: value.credentialID, clientDataJSON: value.rawClientDataJSON,
                                                              authenticatorData: value.rawAuthenticatorData, signature: value.signature,
                                                              userID: value.userID, challenge: challenge)
                } else { throw Failure.unavailable }
                finish(.success(credential))
            } catch { finish(.failure(error)) }
        }
        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            let cancelledByUser = (error as? ASAuthorizationError)?.code == .canceled
            finish(.failure(cancelled || cancelledByUser ? CancellationError() : Failure.unavailable))
        }
        private func finish(_ result: Result<Data, Error>) {
            expiryTask?.cancel(); expiryTask = nil
            if active === self { active = nil }
            controller.delegate = nil; controller.presentationContextProvider = nil
            let waiting = continuation; continuation = nil
            waiting?.resume(with: result)
        }
    }
}
