import XCTest
@testable import Delta

/// These tests exercise the account-scoped social model and request construction
/// with synthetic sessions only; no Supabase or APNs endpoint is contacted.
@MainActor
final class BoundAccountSocialTests: XCTestCase {
    func testProfileLoadsAndRenamesUsingVerifiedAccountIdentity() async throws {
        let firstOwner = UUID()
        let (account, storage) = try await makeAccount(owner: firstOwner)
        defer { account.signOut(); storage.clear() }
        var calls: [(UUID, String, [String: String])] = []
        let profile = BoundAccountProfile(account: account, enabled: { true }, perform: { session, action, payload in
            calls.append((session.owner, action, payload))
            return BoundSocialResponse(ok: true, username: action == "username" ? payload["username"] : "River")
        })

        await profile.refresh()
        XCTAssertEqual(profile.username, "River")
        await profile.rename("Navi")
        XCTAssertEqual(profile.username, "Navi")
        XCTAssertEqual(profile.status, "Username updated for all your friends.")
        XCTAssertEqual(calls.map { $0.0 }, [firstOwner, firstOwner])
        XCTAssertEqual(calls.map { $0.1 }, ["profile", "username"])
        XCTAssertEqual(calls.last?.2, ["username": "Navi"])
    }

    func testExperimentalGatePreventsProfileRPC() async throws {
        let (account, storage) = try await makeAccount(owner: UUID())
        defer { account.signOut(); storage.clear() }
        var calls = 0
        let profile = BoundAccountProfile(account: account, enabled: { false }, perform: { _, _, _ in
            calls += 1
            return BoundSocialResponse(ok: true, username: "ShouldNotLoad")
        })
        await profile.refresh()
        await profile.rename("NewName")
        XCTAssertEqual(calls, 0)
        XCTAssertNil(profile.username)
    }

    func testLateProfileResponseAfterOwnerChangesIsIgnored() async throws {
        let originalOwner = UUID()
        let (account, storage) = try await makeAccount(owner: originalOwner)
        defer { account.signOut(); storage.clear() }
        let started = expectation(description: "profile request started")
        var continuation: CheckedContinuation<BoundSocialResponse, Never>?
        let profile = BoundAccountProfile(account: account, enabled: { true }, perform: { _, _, _ in
            started.fulfill()
            return await withCheckedContinuation { continuation = $0 }
        })

        let refresh = Task { await profile.refresh() }
        await fulfillment(of: [started], timeout: 2)
        let nextOwner = UUID()
        storage.ownerForSignIn = nextOwner
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        XCTAssertEqual(account.session?.owner, nextOwner, "Fixture transport supplies the configured owner")
        continuation?.resume(returning: BoundSocialResponse(ok: true, username: "StaleName"))
        await refresh.value
        XCTAssertNil(profile.username)
        XCTAssertNotEqual(account.session?.owner, originalOwner)
    }

    func testSocialAndJiggleRequestsUseExactServerContractsAndSessionToken() async throws {
        let firstOwner = UUID()
        let (account, storage) = try await makeAccount(owner: firstOwner)
        defer { account.signOut(); storage.clear() }
        let original = try XCTUnwrap(account.session)
        let oldRequest = try original.friendSocialRequest(action: "profile", payload: [:])
        XCTAssertEqual(oldRequest.url?.absoluteString, BoundFriendAccount.origin + "/rest/v1/rpc/bound_social_v1")
        XCTAssertEqual(oldRequest.httpMethod, "POST")
        XCTAssertEqual(oldRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(try accessToken(owner: firstOwner))")
        let oldBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(oldRequest.httpBody)) as? NSDictionary)
        XCTAssertEqual(oldBody, ["action": "profile", "payload": [:]] as NSDictionary)

        let roomID = UUID().uuidString.lowercased()
        let requestID = UUID().uuidString.lowercased()
        let jiggle = try original.friendJiggleRequest(roomID: roomID, requestID: requestID)
        XCTAssertEqual(jiggle.url?.absoluteString, BoundFriendAccount.origin + "/functions/v1/bound-jiggle")
        XCTAssertEqual(jiggle.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(jiggle.httpBody)) as? [String: String],
                       ["roomID": roomID, "requestID": requestID])

        let secondOwner = UUID()
        storage.ownerForSignIn = secondOwner
        await account.signIn(email: "second@example.invalid", password: "synthetic-password")
        let renewed = try XCTUnwrap(account.session?.friendSocialRequest(action: "username", payload: ["username": "Navi"]))
        XCTAssertEqual(account.session?.owner, secondOwner)
        XCTAssertEqual(oldRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(try accessToken(owner: firstOwner))",
                       "A previously built request keeps its original authorization snapshot")
        XCTAssertEqual(renewed.value(forHTTPHeaderField: "Authorization"), "Bearer \(try accessToken(owner: secondOwner))")
        let renewedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(renewed.httpBody)) as? NSDictionary)
        XCTAssertEqual(renewedBody, ["action": "username", "payload": ["username": "Navi"]] as NSDictionary)
        XCTAssertFalse(original.isSameSession(as: account.session))
        XCTAssertThrowsError(try original.friendSocialRequest(action: "profile", payload: [:]),
                             "A captured old session must not mint new requests after account switching")
    }

    func testUsernameValidationBoundaries() {
        XCTAssertTrue(BoundSocialAPI.validUsername("A"))
        XCTAssertTrue(BoundSocialAPI.validUsername(String(repeating: "x", count: 40)))
        XCTAssertFalse(BoundSocialAPI.validUsername(""))
        XCTAssertFalse(BoundSocialAPI.validUsername(String(repeating: "x", count: 41)))
        XCTAssertFalse(BoundSocialAPI.validUsername(" leading"))
        XCTAssertFalse(BoundSocialAPI.validUsername("trailing "))
        XCTAssertFalse(BoundSocialAPI.validUsername("line\nbreak"))
        XCTAssertFalse(BoundSocialAPI.validUsername("hidden\u{200B}name"))
    }

    func testBoundSyncProviderConfigurationRequiresBoundOwnedValues() {
        let clientID = "bound-client.apps.googleusercontent.com"
        let matchingGoogle = [
            "BOUND_GOOGLE_CLIENT_ID": clientID,
            "BOUND_GOOGLE_REVERSED_CLIENT_ID": "com.googleusercontent.apps.bound-client",
        ]
        XCTAssertTrue(SyncManager.isBoundProviderConfigured(.googleDrive, info: matchingGoogle))
        XCTAssertFalse(SyncManager.isBoundProviderConfigured(.googleDrive, info: [
            "BOUND_GOOGLE_CLIENT_ID": clientID,
            "BOUND_GOOGLE_REVERSED_CLIENT_ID": "com.googleusercontent.apps.some-other-client",
        ]))
        XCTAssertFalse(SyncManager.isBoundProviderConfigured(.googleDrive, info: [
            "BOUND_GOOGLE_CLIENT_ID": "",
            "BOUND_GOOGLE_REVERSED_CLIENT_ID": "bound-google-unconfigured",
        ]))
        XCTAssertFalse(SyncManager.isBoundProviderConfigured(.googleDrive, info: [
            "BOUND_GOOGLE_CLIENT_ID": "$(BOUND_GOOGLE_CLIENT_ID)",
            "BOUND_GOOGLE_REVERSED_CLIENT_ID": "$(BOUND_GOOGLE_REVERSED_CLIENT_ID)",
        ]))

        XCTAssertTrue(SyncManager.isBoundProviderConfigured(.dropbox, info: ["BOUND_DROPBOX_APP_KEY": "boundkey123"]
        ))
        XCTAssertFalse(SyncManager.isBoundProviderConfigured(.dropbox, info: ["BOUND_DROPBOX_APP_KEY": "bound-unconfigured"]))
        XCTAssertFalse(SyncManager.isBoundProviderConfigured(.dropbox, info: ["BOUND_DROPBOX_APP_KEY": "invalid-key!"]))
    }

    func testExpiredRestoredSessionRefreshesInPlaceForForegroundReconnect() async throws {
        let owner = UUID()
        let storage = SocialFixtureStorage()
        let key = "fixture-publishable-key"
        let expiredToken = try accessToken(owner: owner, expiry: Date().timeIntervalSince1970 - 10)
        let saved = BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
                                      accessToken: expiredToken, refreshToken: "synthetic-refresh-token")
        try storage.write(JSONEncoder().encode(saved))
        let renewedToken = try accessToken(owner: owner, expiry: Date().timeIntervalSince1970 + 3600)
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false, configuration: { key }, transport: { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/token")
            let response = try JSONSerialization.data(withJSONObject: [
                "access_token": renewedToken,
                "refresh_token": "rotated-refresh-token",
                "user": ["id": owner.uuidString.lowercased()],
            ])
            return BoundAuthTransport.Response(data: response, status: 200)
        })
        defer { account.signOut(); storage.clear() }

        let original = try XCTUnwrap(account.session)
        XCTAssertThrowsError(try original.friendSharingRequest(roomID: "fixture-room"),
                             "Expired credentials must not build an auth request")
        await account.refreshIfNeeded()

        XCTAssertTrue(original.isSameSession(as: account.session),
                      "A successful refresh should renew the existing account snapshot so the sharing owner fence remains valid")
        let renewedRequest = try original.friendSharingRequest(roomID: "fixture-room")
        XCTAssertEqual(renewedRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(renewedToken)")
    }

    private func makeAccount(owner: UUID) async throws -> (BoundFriendAccount, SocialFixtureStorage) {
        let storage = SocialFixtureStorage()
        storage.ownerForSignIn = owner
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false, configuration: { "fixture-publishable-key" }, transport: { request in
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(object["password"], "synthetic-password")
            let expected = try XCTUnwrap(storage.ownerForSignIn)
            let token = try self.accessToken(owner: expected)
            let data = try JSONSerialization.data(withJSONObject: [
                "access_token": token,
                "refresh_token": "synthetic-refresh-token",
                "user": ["id": expected.uuidString.lowercased()],
            ])
            return BoundAuthTransport.Response(data: data, status: 200)
        })
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        XCTAssertEqual(account.session?.owner, owner)
        return (account, storage)
    }

    private func accessToken(owner: UUID, expiry: TimeInterval = 1_900_000_000) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "sub": owner.uuidString.lowercased(),
            "exp": expiry,
        ])
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "fixture.\(payload).signature"
    }
}

@MainActor
private final class SocialFixtureStorage: BoundSessionStorage {
    private var data: Data?
    var ownerForSignIn: UUID?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func remove() throws { data = nil }
    func clear() { data = nil }
}
