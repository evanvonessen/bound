import XCTest
import AuthenticationServices
@testable import Delta

/// Synthetic WebAuthn options and signed-response encoding only; these tests
/// never contact Auth or open the system credential picker.
@MainActor
final class BoundPasskeyAuthorizationTests: XCTestCase {
    private let rp = "accounts.example.com"
    private let challenge = Data(repeating: 42, count: 32)

    func testRegistrationPinsRelyingPartyAndMapsAccountAndExclusions() throws {
        var options = registrationOptions()
        options["excludeCredentials"] = [["type": "public-key", "id": "AQID"]]
        let parsed = try BoundPasskeyAuthorization.registrationRequest(options: envelope(options), relyingPartyID: rp)
        let request = try XCTUnwrap(parsed.request as? ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest)
        XCTAssertEqual(request.relyingPartyIdentifier, rp)
        XCTAssertEqual(request.name, "user@example.com")
        XCTAssertEqual(request.displayName, "Bound user")
        XCTAssertEqual(request.userID, Data("account-identity".utf8))
        XCTAssertEqual(request.challenge, challenge)
        XCTAssertEqual(request.userVerificationPreference, .required)
        XCTAssertEqual(request.attestationPreference, .none)
        if #available(iOS 17.4, *) { XCTAssertEqual(request.excludedCredentials?.first?.credentialID, Data([1, 2, 3])) }
    }

    func testAuthenticationSupportsDiscoverableAndExplicitCredentials() throws {
        var options: [String: Any] = ["rpId": rp, "challenge": base64(challenge)]
        let discoverable = try BoundPasskeyAuthorization.authenticationRequest(options: envelope(options), relyingPartyID: rp)
        XCTAssertTrue(try XCTUnwrap(discoverable.request as? ASAuthorizationPlatformPublicKeyCredentialAssertionRequest).allowedCredentials.isEmpty)
        options["allowCredentials"] = [["type": "public-key", "id": "AQID"]]
        let explicit = try BoundPasskeyAuthorization.authenticationRequest(options: envelope(options), relyingPartyID: rp)
        let request = try XCTUnwrap(explicit.request as? ASAuthorizationPlatformPublicKeyCredentialAssertionRequest)
        XCTAssertEqual(request.relyingPartyIdentifier, rp)
        XCTAssertEqual(request.allowedCredentials.map(\.credentialID), [Data([1, 2, 3])])
        XCTAssertEqual(request.userVerificationPreference, .required)
    }

    func testOptionsCannotSelectAnotherRelyingPartyOrAnOriginURL() throws {
        let registration = try envelope(registrationOptions())
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationRequest(options: registration, relyingPartyID: "attacker.example.com"))
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationRequest(options: registration, relyingPartyID: "https://accounts.example.com"))
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationRequest(options: registration, relyingPartyID: "accounts.example.com/path"))
        XCTAssertThrowsError(try BoundPasskeyAuthorization.authenticationRequest(options: envelope(["rpId": "attacker.example.com", "challenge": base64(challenge)]), relyingPartyID: rp))
    }

    func testRequiresFullEnvelopeAndUnexpiredOneTimeChallenge() throws {
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationRequest(options: JSONSerialization.data(withJSONObject: registrationOptions()), relyingPartyID: rp))
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationRequest(options: envelope(registrationOptions(), expiresAt: Date().timeIntervalSince1970 - 1), relyingPartyID: rp))
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationRequest(options: envelope(registrationOptions(), expiresAt: Date().timeIntervalSince1970 + 3600), relyingPartyID: rp))
        var invalidID = try XCTUnwrap(try JSONSerialization.jsonObject(with: envelope(registrationOptions())) as? [String: Any])
        invalidID["challenge_id"] = "not-a-challenge"
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationRequest(options: JSONSerialization.data(withJSONObject: invalidID), relyingPartyID: rp))
    }

    func testRejectsMalformedOrOversizedChallengeAndCredentialIDs() throws {
        for encoded in ["abc=", "abc+", "AQ", String(repeating: "A", count: 3000)] {
            var options = registrationOptions(); options["challenge"] = encoded
            XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationRequest(options: envelope(options), relyingPartyID: rp))
        }
        var options = registrationOptions()
        options["excludeCredentials"] = [["type": "password", "id": "AQID"]]
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationRequest(options: envelope(options), relyingPartyID: rp))
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationRequest(options: Data(repeating: 32, count: 65537), relyingPartyID: rp))
    }

    func testRegistrationRequiresSupportedPublicKeyAlgorithmAndAttestation() throws {
        var options = registrationOptions()
        options["pubKeyCredParams"] = [["type": "public-key", "alg": -257]]
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationRequest(options: envelope(options), relyingPartyID: rp))
        options = registrationOptions(); options["attestation"] = "direct"
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationRequest(options: envelope(options), relyingPartyID: rp))
    }

    func testRegistrationProducesExactWebAuthnCredentialObject() throws {
        let clientData = try clientData(type: "webauthn.create")
        let result = try BoundPasskeyAuthorization.registrationCredential(credentialID: Data([255, 254]), clientDataJSON: clientData,
                                                                         attestationObject: Data([1, 2, 3]), challenge: challenge)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "rawId", "type", "response", "clientExtensionResults"])
        XCTAssertEqual(object["id"] as? String, "__4")
        XCTAssertEqual(object["rawId"] as? String, "__4")
        XCTAssertEqual(object["type"] as? String, "public-key")
        let response = try XCTUnwrap(object["response"] as? [String: Any])
        XCTAssertEqual(response["clientDataJSON"] as? String, base64(clientData))
        XCTAssertEqual(response["attestationObject"] as? String, "AQID")
        XCTAssertEqual(response["transports"] as? [String], ["internal"])
        XCTAssertTrue(try XCTUnwrap(object["clientExtensionResults"] as? [String: Any]).isEmpty)
        XCTAssertNil(object["challenge_id"])
    }

    func testAuthenticationProducesExactAssertionResponseIncludingUserHandle() throws {
        let clientData = try clientData(type: "webauthn.get")
        let result = try BoundPasskeyAuthorization.authenticationCredential(credentialID: Data([1]), clientDataJSON: clientData,
                                                                           authenticatorData: Data([2]), signature: Data([3]), userID: Data([4]), challenge: challenge)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        let response = try XCTUnwrap(object["response"] as? [String: String])
        XCTAssertEqual(response, ["clientDataJSON": base64(clientData), "authenticatorData": "Ag", "signature": "Aw", "userHandle": "BA"])
    }

    func testSignedResponseMustMatchCeremonyTypeAndChallenge() throws {
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationCredential(credentialID: Data([1]), clientDataJSON: clientData(type: "webauthn.get"), attestationObject: Data([2]), challenge: challenge))
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationCredential(credentialID: Data([1]), clientDataJSON: clientData(type: "webauthn.create"), attestationObject: Data([2]), challenge: Data(repeating: 43, count: 32)))
        XCTAssertThrowsError(try BoundPasskeyAuthorization.registrationCredential(credentialID: Data(), clientDataJSON: clientData(type: "webauthn.create"), attestationObject: Data([2]), challenge: challenge))
        XCTAssertThrowsError(try BoundPasskeyAuthorization.authenticationCredential(credentialID: Data([1]), clientDataJSON: clientData(type: "webauthn.get"), authenticatorData: Data([2]), signature: Data([3]), userID: Data(), challenge: challenge))
    }

    func testCancelledRequestsNeverStartCredentialPresentation() async {
        let registration = Task { try await BoundPasskeyAuthorization.registration(options: Data()) }
        registration.cancel()
        do { _ = try await registration.value; XCTFail("Cancelled registration succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let authentication = Task { try await BoundPasskeyAuthorization.authentication(options: Data()) }
        authentication.cancel()
        do { _ = try await authentication.value; XCTFail("Cancelled authentication succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        // Cancelling when no ceremony is active remains safe and repeatable.
        BoundPasskeyAuthorization.cancel(); BoundPasskeyAuthorization.cancel()
    }

    private func registrationOptions() -> [String: Any] {
        ["rp": ["id": rp, "name": "Bound"], "challenge": base64(challenge),
         "user": ["id": base64(Data("account-identity".utf8)), "name": "user@example.com", "displayName": "Bound user"],
         "pubKeyCredParams": [["type": "public-key", "alg": -7]], "attestation": "none"]
    }
    private func envelope(_ options: [String: Any], expiresAt: TimeInterval = Date().timeIntervalSince1970 + 300) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["challenge_id": UUID().uuidString, "expires_at": expiresAt, "options": options])
    }
    private func clientData(type: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "challenge": base64(challenge), "origin": "https://" + rp])
    }
    private func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
