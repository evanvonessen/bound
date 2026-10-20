import XCTest
@testable import Models

/// Synthetic transport only: no signup, account lookup, or deletion is sent to Supabase.
@MainActor
final class AccountLifecycleTests: XCTestCase {
    typealias Store = AccountPersistenceTests.Store
    typealias Network = AccountPersistenceTests.Network
    private let owner = UUID()
    private func reply(_ body: [String: Any], _ status: Int = 200) throws -> BoundAuthTransport.Response {
        .init(data: try JSONSerialization.data(withJSONObject: body), status: status)
    }
    private func login() throws -> BoundAuthTransport.Response {
        let claims = try JSONSerialization.data(withJSONObject: ["sub": owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try reply(["access_token": "fixture.\(payload).signature", "refresh_token": "synthetic-refresh", "user": ["id": owner.uuidString]])
    }
    private func identity(_ id: UUID? = nil, email: String = "fixture@example.invalid") throws -> BoundAuthTransport.Response {
        try reply(["id": (id ?? owner).uuidString, "email": email, "role": "authenticated", "is_anonymous": false, "email_confirmed_at": "2026-01-01T00:00:00Z"])
    }
    private func make(_ store: Store = Store(), deletion: Store = Store(), transport: @escaping @MainActor (URLRequest) async throws -> BoundAuthTransport.Response) -> BoundFriendAccount {
        BoundFriendAccount(storage: store, deletionStorage: deletion, automaticRefresh: false, configuration: { "fixture-key" }, transport: transport)
    }
    func testSignupSendsOnlyEmailPasswordAndPersistsSessionBeforePublishing() async throws {
        let store = Store(); let result = try login(); var requests: [URLRequest] = []
        let account = make(store) { request in requests.append(request); return result }
        let outcome = await account.createAccount(email: " Fixture@Example.invalid \n", password: "synthetic-password")
        XCTAssertTrue(outcome == .signedIn)
        XCTAssertEqual(account.session?.owner, owner); XCTAssertEqual(store.writes, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/auth/v1/signup")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["email": "fixture@example.invalid", "password": "synthetic-password"])
        let persisted = String(decoding: try XCTUnwrap(store.data), as: UTF8.self)
        XCTAssertFalse(persisted.contains("password")); XCTAssertFalse(persisted.contains("example.invalid"))
    }
    func testUserOnlyAndObfuscatedDuplicateRepliesNeverPublishSessionOrClaimCreation() async throws {
        for nested in [false, true] {
            let store = Store(); let user: [String: Any] = ["id": owner.uuidString, "identities": []]
            let result = try reply(nested ? ["user": user] : user)
            let account = make(store) { _ in result }
            let outcome1 = await account.createAccount(email: "fixture@example.invalid", password: "synthetic-password"); XCTAssertTrue(outcome1 == .checkEmail)
            XCTAssertNil(account.session); XCTAssertNil(store.data)
            XCTAssertTrue(account.status.contains("If you already have an account"))
        }
    }
    func testSignupRejectsMalformedRepliesAndDoesNotEchoServerSecrets() async throws {
        for body: [String: Any] in [["access_token": "broken"], [:], ["code": "weak_password", "msg": "synthetic-private-password"]] {
            let result = try reply(body, body["code"] == nil ? 200 : 422)
            let account = make { _ in result }
            let outcome2 = await account.createAccount(email: "fixture@example.invalid", password: "synthetic-password"); XCTAssertTrue(outcome2 == .failed)
            XCTAssertNil(account.session); XCTAssertFalse(account.status.contains("synthetic-private-password"))
        }
    }
    func testInvalidSignupDoesNotMakeRequestAndConcurrentSubmissionIsSingleFlight() async throws {
        let network = Network(); let account = make(transport: network.perform)
        let outcome3 = await account.createAccount(email: "bad", password: "fixture"); XCTAssertTrue(outcome3 == .failed)
        XCTAssertEqual(network.requests.count, 0)
        let first = Task { await account.createAccount(email: "fixture@example.invalid", password: "fixture") }
        for _ in 0..<1000 { if !network.requests.isEmpty { break }; await Task.yield() }
        let outcome4 = await account.createAccount(email: "fixture@example.invalid", password: "fixture"); XCTAssertTrue(outcome4 == .failed)
        await account.signIn(email: "other@example.invalid", password: "fixture")
        XCTAssertEqual(network.requests.count, 1)
        first.cancel(); network.finish(try login())
        let outcome5 = await first.value; XCTAssertTrue(outcome5 == .cancelled); XCTAssertNil(account.session); XCTAssertFalse(account.busy)
    }
    func testSignupKeychainFailureNeverPublishesUnpersistedLogin() async throws {
        let store = Store(); let result = try login()
        let account = make(store) { _ in store.locked = true; return result }
        let outcome6 = await account.createAccount(email: "fixture@example.invalid", password: "fixture"); XCTAssertTrue(outcome6 == .failed)
        XCTAssertNil(account.session); XCTAssertTrue(account.status.contains("could not be saved securely"))
    }
    func testDeletionRequiresServerVerifiedMatchingIdentityAndTypedEmail() async throws {
        let store = Store(); let deletion = Store(); let auth = try login(); let user = try identity(); var requests: [URLRequest] = []
        let account = make(store, deletion: deletion) { request in
            requests.append(request)
            if request.url?.path == "/auth/v1/token" { return auth }
            if request.url?.path == "/auth/v1/user" { return user }
            XCTAssertNotNil(deletion.data, "Intent must be persisted before the destructive request")
            return try self.reply(["status": "complete"])
        }
        await account.signIn(email: "fixture@example.invalid", password: "fixture")
        let holder = try XCTUnwrap(account.session)
        await account.deleteAccount(confirmationEmail: "fixture@example.invalid")
        XCTAssertEqual(requests.count, 1)
        await account.loadDeletionIdentity()
        await account.deleteAccount(confirmationEmail: "other@example.invalid")
        XCTAssertEqual(requests.count, 2)
        await account.deleteAccount(confirmationEmail: " FIXTURE@EXAMPLE.INVALID \n")
        XCTAssertEqual(requests.count, 3)
        let request = requests[2]
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer fixture.") == true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["operationToken", "confirmationEmail"])
        XCTAssertEqual(body["confirmationEmail"], "fixture@example.invalid"); XCTAssertEqual(body["operationToken"]?.count, 64)
        XCTAssertNil(account.session); XCTAssertThrowsError(try holder.credentials()); XCTAssertNil(store.data); XCTAssertNil(deletion.data)
        XCTAssertFalse(account.deletionPending); XCTAssertTrue(account.status.contains("were deleted"))
    }
    func testForeignIdentityCannotEnableDeletion() async throws {
        let auth = try login(); let foreign = try identity(UUID())
        let account = make { request in request.url?.path == "/auth/v1/token" ? auth : foreign }
        await account.signIn(email: "fixture@example.invalid", password: "fixture")
        await account.loadDeletionIdentity(); XCTAssertNil(account.deletionEmail)
    }
    func testLostDeletionResponseResumesAfterRelaunchWithoutAuthOrEmail() async throws {
        let store = Store(); let deletion = Store(); let auth = try login(); let user = try identity()
        let account = make(store, deletion: deletion) { request in
            if request.url?.path == "/auth/v1/token" { return auth }
            if request.url?.path == "/auth/v1/user" { return user }
            throw URLError(.timedOut)
        }
        await account.signIn(email: "fixture@example.invalid", password: "fixture"); await account.loadDeletionIdentity()
        await account.deleteAccount(confirmationEmail: "fixture@example.invalid")
        XCTAssertTrue(account.deletionPending); XCTAssertNil(account.session); XCTAssertNotNil(deletion.data)
        let restored = make(store, deletion: deletion) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
            XCTAssertEqual(Set(body.keys), ["operationToken"])
            return try self.reply(["status": "complete"])
        }
        XCTAssertTrue(restored.deletionPending)
        await restored.resumeAccountDeletion()
        XCTAssertFalse(restored.deletionPending); XCTAssertNil(deletion.data)
    }
    func testUndeployedEmailContractRejectsBeforeDeletionAndKeepsLogin() async throws {
        let auth = try login(); let user = try identity(); let deletion = Store()
        let account = make(deletion: deletion) { request in
            if request.url?.path == "/auth/v1/token" { return auth }
            if request.url?.path == "/auth/v1/user" { return user }
            return try self.reply(["error": "invalid_request"], 400)
        }
        await account.signIn(email: "fixture@example.invalid", password: "fixture"); await account.loadDeletionIdentity()
        await account.deleteAccount(confirmationEmail: "fixture@example.invalid")
        XCTAssertNotNil(account.session); XCTAssertFalse(account.deletionPending); XCTAssertNil(deletion.data)
        XCTAssertFalse(account.status.contains("were deleted"))
    }
    func testEmailNormalizationRejectsControlsAndAmbiguousIdentities() {
        XCTAssertEqual(BoundFriendAccount.normalizedEmail(" USER@EXAMPLE.INVALID\r\n"), "user@example.invalid")
        for email in ["a@@b", "@b", "a@", "a b@c", "a@b\u{0000}", "ä@b"] { XCTAssertNil(BoundFriendAccount.normalizedEmail(email)) }
    }
}
