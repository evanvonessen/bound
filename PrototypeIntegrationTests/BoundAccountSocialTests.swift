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
        let profile = BoundAccountProfile(account: account, perform: { session, action, payload in
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

    func testProfileRPCIsAvailableWithoutExperimentalPreference() async throws {
        let key = BoundLegacyPreferences.experimentalFeaturesKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let (account, storage) = try await makeAccount(owner: UUID())
        defer { account.signOut(); storage.clear() }
        var calls = 0
        let profile = BoundAccountProfile(account: account, perform: { _, _, _ in
            calls += 1
            return BoundSocialResponse(ok: true, username: calls == 1 ? "River" : "NewName")
        })
        await profile.refresh()
        await profile.rename("NewName")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(profile.username, "NewName")
    }

    func testLateProfileResponseAfterOwnerChangesIsIgnored() async throws {
        let originalOwner = UUID()
        let (account, storage) = try await makeAccount(owner: originalOwner)
        defer { account.signOut(); storage.clear() }
        let started = expectation(description: "profile request started")
        var continuation: CheckedContinuation<BoundSocialResponse, Never>?
        let profile = BoundAccountProfile(account: account, perform: { _, _, _ in
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
        let originalAuthorization = try XCTUnwrap(oldRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(oldRequest.url?.absoluteString, BoundFriendAccount.origin + "/rest/v1/rpc/bound_social_v2")
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
        XCTAssertEqual(oldRequest.value(forHTTPHeaderField: "Authorization"), originalAuthorization,
                       "A previously built request keeps its original authorization snapshot")
        XCTAssertNotEqual(renewed.value(forHTTPHeaderField: "Authorization"), originalAuthorization)
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

    func testSignupChecksUsernameAndSendsMetadata() async throws {
        let owner = UUID()
        let storage = SocialFixtureStorage()
        var requests: [URLRequest] = []
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            requests.append(request)
            if request.url?.path == "/rest/v1/rpc/bound_username_available" {
                return try self.jsonResponse(["ok": true, "available": true])
            }
            let token = try self.accessToken(owner: owner)
            return try self.jsonResponse([
                "access_token": token,
                "refresh_token": "synthetic-refresh-token",
                "user": ["id": owner.uuidString.lowercased(), "email": "verified-signup@example.invalid"],
            ])
        })
        defer { account.signOut(); storage.clear() }

        let result = await account.createAccount(email: "friend@example.invalid", password: "secret-password", username: "  River  ")
        XCTAssertEqual(requests.map { $0.url?.path }, ["/rest/v1/rpc/bound_username_available", "/auth/v1/signup"])
        let availability = try XCTUnwrap(requests.first)
        XCTAssertEqual(availability.httpMethod, "POST")
        XCTAssertEqual(availability.value(forHTTPHeaderField: "apikey"), try BoundAccountTestFixture.apiKey("fixture-publishable-key"))
        XCTAssertNil(availability.value(forHTTPHeaderField: "Authorization"), "Availability does not require a signed-in account")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(availability.httpBody)) as? [String: String], ["username": "River"])

        let signup = try XCTUnwrap(requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(signup.httpBody)) as? [String: Any])
        XCTAssertEqual(body["email"] as? String, "friend@example.invalid")
        XCTAssertEqual(body["password"] as? String, "secret-password")
        XCTAssertEqual(body["data"] as? [String: String], ["bound_username_v1": "River"])
        XCTAssertEqual(Set(body.keys), ["email", "password", "data"])
        XCTAssertEqual(result, .signedIn)
        XCTAssertEqual(account.session?.owner, owner)
        XCTAssertEqual(account.emailAddress, "verified-signup@example.invalid",
                       "The displayed address must come from Auth, rather than the signup form")
    }

    func testSignupStopsBeforeAuthWhenUsernameIsUnavailable() async throws {
        let storage = SocialFixtureStorage()
        var paths: [String] = []
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            paths.append(request.url?.path ?? "")
            return try self.jsonResponse(["ok": true, "available": false])
        })
        defer { account.signOut(); storage.clear() }

        let result = await account.createAccount(email: "friend@example.invalid", password: "secret-password", username: "River")
        XCTAssertEqual(result, .usernameTaken)
        XCTAssertEqual(paths, ["/rest/v1/rpc/bound_username_available"])
        XCTAssertNil(account.session)
        XCTAssertEqual(account.status, "That username is already taken. Choose another.")
    }

    func testLegacyFalsePreferenceStillUsesUsernameSignup() async throws {
        let storage = SocialFixtureStorage()
        var requests: [URLRequest] = []
        let key = BoundLegacyPreferences.experimentalFeaturesKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            requests.append(request)
            if request.url?.path == "/rest/v1/rpc/bound_username_available" {
                return try self.jsonResponse(["ok": true, "available": true])
            }
            return try self.jsonResponse(["id": UUID().uuidString.lowercased()])
        })
        defer { account.signOut(); storage.clear() }

        let result = await account.createAccount(email: "friend@example.invalid", password: "secret-password", username: "River")
        XCTAssertEqual(result, .checkEmail)
        XCTAssertEqual(requests.map { $0.url?.path }, ["/rest/v1/rpc/bound_username_available", "/auth/v1/signup"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["data"] as? [String: String], ["bound_username_v1": "River"])
    }

    func testSignupRechecksUsernameAfterUniqueClaimRace() async throws {
        let storage = SocialFixtureStorage()
        var availabilityChecks = 0
        var signupRequests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            if request.url?.path == "/rest/v1/rpc/bound_username_available" {
                availabilityChecks += 1
                return try self.jsonResponse(["ok": true, "available": availabilityChecks == 1])
            }
            signupRequests += 1
            return try self.jsonResponse(["code": "database_error"], status: 500)
        })
        defer { account.signOut(); storage.clear() }

        let result = await account.createAccount(email: "friend@example.invalid", password: "secret-password", username: "River")
        XCTAssertEqual(result, .usernameTaken)
        XCTAssertEqual(availabilityChecks, 2)
        XCTAssertEqual(signupRequests, 1)
        XCTAssertNil(account.session, "A failed Auth signup must never be reported or stored as a created account")
        XCTAssertNil(try storage.read())
    }

    func testSignupCancellationDuringAvailabilityDoesNotSubmitSignup() async throws {
        let storage = SocialFixtureStorage()
        let started = expectation(description: "availability request started")
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
        var signupRequests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            if request.url?.path == "/rest/v1/rpc/bound_username_available" {
                started.fulfill()
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            signupRequests += 1
            return try self.jsonResponse(["id": UUID().uuidString.lowercased()])
        })
        defer { account.signOut(); storage.clear() }

        let task = Task { await account.createAccount(email: "friend@example.invalid", password: "secret-password", username: "River") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        continuation?.resume(returning: try jsonResponse(["ok": true, "available": true]))
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(signupRequests, 0)
        XCTAssertNil(account.session)
    }

    func testSignupStillHandlesEmailConfirmationResponse() async throws {
        let storage = SocialFixtureStorage()
        let owner = UUID()
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            if request.url?.path == "/rest/v1/rpc/bound_username_available" {
                return try self.jsonResponse(["ok": true, "available": true])
            }
            return try self.jsonResponse(["id": owner.uuidString.lowercased(), "email": "friend@example.invalid"])
        })
        defer { account.signOut(); storage.clear() }

        let result = await account.createAccount(email: "friend@example.invalid", password: "secret-password", username: "River")
        XCTAssertEqual(result, .checkEmail)
        XCTAssertNil(account.session)
        XCTAssertTrue(account.status.contains("Check your email"))
    }

    private func jsonResponse(_ object: [String: Any], status: Int = 200) throws -> BoundAuthTransport.Response {
        BoundAuthTransport.Response(data: try JSONSerialization.data(withJSONObject: object), status: status)
    }

    func testPasswordResetUsesPublicRecoveryContractWithoutSavingSession() async throws {
        let storage = SocialFixtureStorage()
        var requests: [URLRequest] = []
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            requests.append(request)
            return try self.jsonResponse([:])
        })
        defer { account.signOut(); storage.clear() }
        let originalStatus = account.status
        let originalWrites = storage.writeCount
        let originalRemovals = storage.removeCount

        let result = await account.requestPasswordReset(email: "  Friend@Example.Invalid \n")

        XCTAssertTrue(result)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, URL(string: BoundFriendAccount.origin)?.host)
        XCTAssertEqual(request.url?.path, "/auth/v1/recover")
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, [URLQueryItem(name: "redirect_to", value: "https://evanvonessen.github.io/bound/reset-password.html")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), try BoundAccountTestFixture.apiKey("fixture-publishable-key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String],
                       ["email": "friend@example.invalid"])
        XCTAssertFalse(account.passwordResetStatus.isEmpty)
        XCTAssertFalse(account.sendingPasswordReset)
        XCTAssertNil(account.session)
        XCTAssertNil(account.emailAddress)
        XCTAssertNil(try storage.read())
        XCTAssertEqual(account.status, originalStatus)
        XCTAssertEqual(storage.writeCount, originalWrites)
        XCTAssertEqual(storage.removeCount, originalRemovals)
    }

    func testPasswordResetSuccessfulStatusDoesNotRevealAccountExistenceOrServerMessages() async throws {
        let existingStorage = SocialFixtureStorage()
        let missingStorage = SocialFixtureStorage()
        let existing = BoundFriendAccount(storage: existingStorage, automaticRefresh: false,
                                          configuration: { "fixture-publishable-key" }, transport: { _ in
            try self.jsonResponse(["message": "private-existing-account-details", "user_exists": true])
        })
        let missing = BoundFriendAccount(storage: missingStorage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { _ in
            try self.jsonResponse(["message": "private-missing-account-details", "user_exists": false])
        })
        defer { existing.signOut(); missing.signOut(); existingStorage.clear(); missingStorage.clear() }

        let existingResult = await existing.requestPasswordReset(email: "existing@example.invalid")
        let missingResult = await missing.requestPasswordReset(email: "missing@example.invalid")

        XCTAssertTrue(existingResult)
        XCTAssertTrue(missingResult)
        XCTAssertEqual(existing.passwordResetStatus, missing.passwordResetStatus)
        XCTAssertFalse(existing.passwordResetStatus.isEmpty)
        XCTAssertFalse(existing.passwordResetStatus.contains("private-"))
        XCTAssertFalse(existing.passwordResetStatus.contains("existing@example.invalid"))
        XCTAssertNil(existing.session)
        XCTAssertNil(missing.session)
    }

    func testPasswordResetValidatesBeforeSendingAndPreventsImmediateResend() async throws {
        let storage = SocialFixtureStorage()
        var requests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { _ in
            requests += 1
            return try self.jsonResponse([:])
        })
        defer { account.signOut(); storage.clear() }

        for address in ["", "plain-address", "friend@", "a b@example.invalid", "friend@example.invalid\nInjected: value"] {
            let result = await account.requestPasswordReset(email: address)
            XCTAssertFalse(result, address)
        }
        XCTAssertEqual(requests, 0)
        let first = await account.requestPasswordReset(email: "friend@example.invalid")
        let repeated = await account.requestPasswordReset(email: "other@example.invalid")
        XCTAssertTrue(first, "Invalid input must not consume the resend cooldown")
        XCTAssertFalse(repeated)
        XCTAssertEqual(requests, 1, "The in-memory cooldown applies across entered addresses")
        XCTAssertFalse(account.sendingPasswordReset)
    }

    func testPasswordResetCooldownSurvivesLocalSignOutWithoutPersistence() async throws {
        let storage = SocialFixtureStorage()
        var requests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { _ in
            requests += 1
            return try self.jsonResponse([:])
        })
        defer { account.signOut(); storage.clear() }

        let first = await account.requestPasswordReset(email: "friend@example.invalid")
        XCTAssertTrue(first)
        account.signOut()
        let repeated = await account.requestPasswordReset(email: "friend@example.invalid")

        XCTAssertFalse(repeated)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(storage.writeCount, 0, "The resend cooldown must not store an email or extra account state")
        XCTAssertNil(try storage.read())
    }

    func testPasswordResetDoesNotSendForSignedInAccount() async throws {
        let owner = UUID()
        let storage = SocialFixtureStorage()
        let saved = BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
                                      accessToken: try accessToken(owner: owner, email: "verified@example.invalid"),
                                      refreshToken: "synthetic-refresh-token")
        try storage.write(JSONEncoder().encode(saved))
        let original = try storage.read()
        var requests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { _ in
            requests += 1
            return try self.jsonResponse([:])
        })
        defer { account.signOut(); storage.clear() }
        let originalStatus = account.status

        let result = await account.requestPasswordReset(email: "verified@example.invalid")

        XCTAssertFalse(result)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(account.session?.owner, owner)
        XCTAssertEqual(account.emailAddress, "verified@example.invalid")
        XCTAssertEqual(account.status, originalStatus)
        XCTAssertEqual(try storage.read(), original)
        XCTAssertEqual(storage.writeCount, 1)
        XCTAssertEqual(storage.removeCount, 0)
    }

    func testSignedInPasswordResetUsesAuthenticatedEmailWithoutChangingSession() async throws {
        let owner = UUID()
        let storage = SocialFixtureStorage()
        try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
            accessToken: accessToken(owner: owner, email: "verified@example.invalid"), refreshToken: "synthetic-refresh-token")))
        var requests: [URLRequest] = []
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            requests.append(request)
            return try self.jsonResponse([:])
        })
        defer { account.signOut(); storage.clear() }
        let originalSession = try XCTUnwrap(account.session)
        let originalStorage = try storage.read()
        let originalStatus = account.status

        let result = await account.requestPasswordResetForCurrentAccount()

        XCTAssertTrue(result)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.path, "/auth/v1/recover")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), try BoundAccountTestFixture.apiKey("fixture-publishable-key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "Recovery does not send the saved session token")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String],
                       ["email": "verified@example.invalid"])
        XCTAssertTrue(originalSession.isSameSession(as: account.session))
        XCTAssertEqual(account.emailAddress, "verified@example.invalid")
        XCTAssertEqual(account.status, originalStatus)
        XCTAssertFalse(account.passwordResetStatus.isEmpty)
        XCTAssertFalse(account.sendingPasswordReset)
        XCTAssertEqual(try storage.read(), originalStorage)
        XCTAssertEqual(storage.writeCount, 1)
        XCTAssertEqual(storage.removeCount, 0)

        account.signOut()
        let repeated = await account.requestPasswordReset(email: "verified@example.invalid")
        XCTAssertFalse(repeated, "Signed-in and signed-out recovery share the resend cooldown")
        XCTAssertEqual(requests.count, 1)
    }

    func testSignedInPasswordResetResolvesLegacyEmailBeforeSending() async throws {
        let owner = UUID()
        let storage = SocialFixtureStorage()
        try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
            accessToken: accessToken(owner: owner), refreshToken: "synthetic-refresh-token")))
        var requests: [URLRequest] = []
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            requests.append(request)
            if request.url?.path == "/auth/v1/user" {
                return try self.jsonResponse(["id": owner.uuidString.lowercased(), "role": "authenticated",
                                              "is_anonymous": false, "email": "verified@example.invalid"])
            }
            return try self.jsonResponse([:])
        })
        defer { account.signOut(); storage.clear() }
        let original = try storage.read()
        XCTAssertNil(account.emailAddress)

        let result = await account.requestPasswordResetForCurrentAccount()

        XCTAssertTrue(result)
        XCTAssertEqual(requests.compactMap { $0.url?.path }, ["/auth/v1/user", "/auth/v1/recover"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: String],
                       ["email": "verified@example.invalid"])
        XCTAssertEqual(account.session?.owner, owner)
        XCTAssertEqual(try storage.read(), original)
        XCTAssertEqual(storage.writeCount, 1)
        XCTAssertEqual(storage.removeCount, 0)
    }

    func testSignedInPasswordResetRefreshesExpiredSessionAndReportsRefreshFailure() async throws {
        for refreshSucceeds in [true, false] {
            let owner = UUID()
            let storage = SocialFixtureStorage()
            try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
                accessToken: accessToken(owner: owner, expiry: Date().timeIntervalSince1970 - 60,
                                         email: "cached@example.invalid"), refreshToken: "synthetic-refresh-token")))
            let originalStorage = try storage.read()
            var requests: [URLRequest] = []
            let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                             configuration: { "fixture-publishable-key" }, transport: { request in
                requests.append(request)
                if request.url?.path == "/auth/v1/token" {
                    guard refreshSucceeds else { throw URLError(.notConnectedToInternet) }
                    return try self.jsonResponse(["access_token": self.accessToken(owner: owner),
                                                  "refresh_token": "rotated-refresh-token",
                                                  "user": ["id": owner.uuidString.lowercased(), "email": "refreshed@example.invalid"]])
                }
                return try self.jsonResponse([:])
            })
            let originalSession = try XCTUnwrap(account.session)

            let result = await account.requestPasswordResetForCurrentAccount()

            XCTAssertEqual(result, refreshSucceeds)
            XCTAssertEqual(account.session?.owner, owner)
            XCTAssertFalse(account.sendingPasswordReset)
            XCTAssertFalse(account.passwordResetStatus.isEmpty, "An unavailable expired session must explain how to retry")
            XCTAssertEqual(storage.removeCount, 0)
            if refreshSucceeds {
                XCTAssertEqual(requests.compactMap { $0.url?.path }, ["/auth/v1/token", "/auth/v1/recover"])
                XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: String],
                               ["email": "refreshed@example.invalid"])
                XCTAssertTrue(originalSession.isSameSession(as: account.session))
                XCTAssertEqual(storage.writeCount, 2, "Only the normal token refresh updates saved credentials")
            } else {
                XCTAssertEqual(requests.compactMap { $0.url?.path }, ["/auth/v1/token"])
                XCTAssertEqual(try storage.read(), originalStorage)
                XCTAssertEqual(storage.writeCount, 1)
            }
            account.signOut(); storage.clear()
        }
    }

    func testSignedInPasswordResetWaitsForInFlightEmailLookup() async throws {
        let owner = UUID()
        let storage = SocialFixtureStorage()
        try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
            accessToken: accessToken(owner: owner), refreshToken: "synthetic-refresh-token")))
        let lookupStarted = expectation(description: "account email lookup started")
        let resetStarted = expectation(description: "reset started during lookup")
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
        var requests: [URLRequest] = []
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            requests.append(request)
            if request.url?.path == "/auth/v1/user" {
                lookupStarted.fulfill()
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return try self.jsonResponse([:])
        })
        defer { account.signOut(); storage.clear() }
        let lookup = Task { await account.loadEmailAddress() }
        await fulfillment(of: [lookupStarted], timeout: 2)
        let reset = Task {
            resetStarted.fulfill()
            return await account.requestPasswordResetForCurrentAccount()
        }
        await fulfillment(of: [resetStarted], timeout: 2)
        XCTAssertTrue(account.sendingPasswordReset)
        continuation?.resume(returning: try jsonResponse(["id": owner.uuidString.lowercased(), "role": "authenticated",
                                                         "is_anonymous": false, "email": "verified@example.invalid"]))
        await lookup.value
        let result = await reset.value

        XCTAssertTrue(result)
        XCTAssertEqual(requests.compactMap { $0.url?.path }, ["/auth/v1/user", "/auth/v1/recover"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String: String],
                       ["email": "verified@example.invalid"])
        XCTAssertFalse(account.sendingPasswordReset)
        XCTAssertEqual(storage.writeCount, 1)
    }

    func testSignedInPasswordResetRejectsUnverifiedEmailWithoutSendingRecoveryMail() async throws {
        for offline in [false, true] {
            let owner = UUID()
            let storage = SocialFixtureStorage()
            try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
                accessToken: accessToken(owner: owner), refreshToken: "synthetic-refresh-token")))
            var paths: [String] = []
            let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                             configuration: { "fixture-publishable-key" }, transport: { request in
                paths.append(request.url!.path)
                if offline { throw URLError(.notConnectedToInternet) }
                return try self.jsonResponse(["id": UUID().uuidString.lowercased(), "role": "authenticated",
                                              "is_anonymous": false, "email": "different-owner@example.invalid"])
            })

            let result = await account.requestPasswordResetForCurrentAccount()

            XCTAssertFalse(result)
            XCTAssertEqual(paths, ["/auth/v1/user"])
            XCTAssertNil(account.emailAddress)
            XCTAssertEqual(account.session?.owner, owner)
            XCTAssertFalse(account.passwordResetStatus.isEmpty)
            XCTAssertFalse(account.passwordResetStatus.contains("different-owner"))
            XCTAssertFalse(account.sendingPasswordReset)
            XCTAssertEqual(storage.writeCount, 1)
            XCTAssertEqual(storage.removeCount, 0)
            account.signOut(); storage.clear()
        }
    }

    func testSignedInPasswordResetIgnoresLateResponseAfterSignOut() async throws {
        let started = expectation(description: "signed-in recovery started")
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
        let (account, storage) = try makeEmailChangeAccount(transport: { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/recover")
            started.fulfill()
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        defer { account.signOut(); storage.clear() }

        let task = Task { await account.requestPasswordResetForCurrentAccount() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(account.sendingPasswordReset)
        account.signOut()
        continuation?.resume(returning: try jsonResponse([:]))
        let result = await task.value

        XCTAssertFalse(result)
        XCTAssertNil(account.session)
        XCTAssertTrue(account.passwordResetStatus.isEmpty)
        XCTAssertFalse(account.sendingPasswordReset)
        XCTAssertNil(try storage.read())
        XCTAssertEqual(storage.writeCount, 1)
    }

    func testSignedInPasswordResetDoesNotSendAfterAccountSwitchDuringEmailLookup() async throws {
        let owner = UUID(), nextOwner = UUID()
        let storage = SocialFixtureStorage()
        try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
            accessToken: accessToken(owner: owner), refreshToken: "synthetic-refresh-token")))
        let started = expectation(description: "legacy account email lookup")
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
        var recoveryRequests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            if request.url?.path == "/auth/v1/user" {
                started.fulfill()
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            if request.url?.path == "/auth/v1/recover" { recoveryRequests += 1 }
            return try self.jsonResponse(["access_token": self.accessToken(owner: nextOwner),
                                          "refresh_token": "next-refresh-token",
                                          "user": ["id": nextOwner.uuidString.lowercased(), "email": "next@example.invalid"]])
        })
        defer { account.signOut(); storage.clear() }

        let task = Task { await account.requestPasswordResetForCurrentAccount() }
        await fulfillment(of: [started], timeout: 2)
        await account.signIn(email: "next@example.invalid", password: "synthetic-password")
        continuation?.resume(returning: try jsonResponse(["id": owner.uuidString.lowercased(), "role": "authenticated",
                                                         "is_anonymous": false, "email": "previous@example.invalid"]))
        let result = await task.value

        XCTAssertFalse(result)
        XCTAssertEqual(recoveryRequests, 0)
        XCTAssertEqual(account.session?.owner, nextOwner)
        XCTAssertEqual(account.emailAddress, "next@example.invalid")
        XCTAssertTrue(account.passwordResetStatus.isEmpty)
        XCTAssertFalse(account.sendingPasswordReset)
    }

    func testSignedInPasswordResetRequiresCurrentSession() async throws {
        let storage = SocialFixtureStorage()
        var requests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { _ in
            requests += 1
            return try self.jsonResponse([:])
        })
        defer { account.signOut(); storage.clear() }

        let result = await account.requestPasswordResetForCurrentAccount()

        XCTAssertFalse(result)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(storage.writeCount, 0)
        XCTAssertFalse(account.sendingPasswordReset)
    }

    func testPasswordResetHandlesRateLimitsAndNetworkFailureWithoutServerDetails() async throws {
        let rateLimitedStorage = SocialFixtureStorage()
        let offlineStorage = SocialFixtureStorage()
        let rateLimited = BoundFriendAccount(storage: rateLimitedStorage, automaticRefresh: false,
                                             configuration: { "fixture-publishable-key" }, transport: { _ in
            try self.jsonResponse(["msg": "private-provider-error", "email": "private@example.invalid"], status: 429)
        })
        let offline = BoundFriendAccount(storage: offlineStorage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { _ in
            throw URLError(.notConnectedToInternet)
        })
        defer { rateLimited.signOut(); offline.signOut(); rateLimitedStorage.clear(); offlineStorage.clear() }

        let rateLimitedResult = await rateLimited.requestPasswordReset(email: "friend@example.invalid")
        let offlineResult = await offline.requestPasswordReset(email: "friend@example.invalid")

        XCTAssertFalse(rateLimitedResult)
        XCTAssertFalse(offlineResult)
        XCTAssertFalse(rateLimited.passwordResetStatus.isEmpty)
        XCTAssertFalse(offline.passwordResetStatus.isEmpty)
        XCTAssertFalse(rateLimited.passwordResetStatus.contains("private"))
        XCTAssertFalse(rateLimited.sendingPasswordReset)
        XCTAssertFalse(offline.sendingPasswordReset)
        XCTAssertNil(rateLimited.session)
        XCTAssertNil(offline.session)
        XCTAssertEqual(rateLimitedStorage.writeCount, 0)
        XCTAssertEqual(offlineStorage.writeCount, 0)
    }

    func testPasswordResetCancellationIgnoresLateSuccessAndClearsProgress() async throws {
        let storage = SocialFixtureStorage()
        let started = expectation(description: "password recovery started")
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
        var requests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { _ in
            requests += 1
            started.fulfill()
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        defer { account.signOut(); storage.clear() }
        let initialStatus = account.passwordResetStatus

        let task = Task { await account.requestPasswordReset(email: "friend@example.invalid") }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(account.sendingPasswordReset)
        let duplicate = await account.requestPasswordReset(email: "other@example.invalid")
        XCTAssertFalse(duplicate)
        XCTAssertEqual(requests, 1)
        task.cancel()
        continuation?.resume(returning: try jsonResponse([:]))
        let result = await task.value

        XCTAssertFalse(result)
        XCTAssertFalse(account.sendingPasswordReset)
        XCTAssertEqual(account.passwordResetStatus, initialStatus)
        XCTAssertNil(account.session)
        XCTAssertEqual(storage.writeCount, 0)
    }

    func testPasswordResetLateSuccessAfterAccountSwitchIsIgnored() async throws {
        let owner = UUID()
        let storage = SocialFixtureStorage()
        let started = expectation(description: "password recovery started")
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
        var recoveryRequests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            if request.url?.path == "/auth/v1/recover" {
                recoveryRequests += 1
                started.fulfill()
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return try self.jsonResponse([
                "access_token": self.accessToken(owner: owner),
                "refresh_token": "synthetic-refresh-token",
                "user": ["id": owner.uuidString.lowercased(), "email": "verified@example.invalid"],
            ])
        })
        defer { account.signOut(); storage.clear() }

        let reset = Task { await account.requestPasswordReset(email: "previous@example.invalid") }
        await fulfillment(of: [started], timeout: 2)
        await account.signIn(email: "typed@example.invalid", password: "synthetic-password")
        let savedAfterSignIn = try storage.read()
        let writesAfterSignIn = storage.writeCount
        let signedInStatus = account.status
        continuation?.resume(returning: try jsonResponse([:]))
        let result = await reset.value
        let signedInReset = await account.requestPasswordReset(email: "verified@example.invalid")

        XCTAssertFalse(result)
        XCTAssertFalse(signedInReset, "A logged-in account must not send recovery mail from its login-only flow")
        XCTAssertEqual(recoveryRequests, 1)
        XCTAssertEqual(account.session?.owner, owner)
        XCTAssertEqual(account.emailAddress, "verified@example.invalid")
        XCTAssertEqual(account.status, signedInStatus)
        XCTAssertTrue(account.passwordResetStatus.isEmpty)
        XCTAssertFalse(account.sendingPasswordReset)
        XCTAssertEqual(try storage.read(), savedAfterSignIn)
        XCTAssertEqual(storage.writeCount, writesAfterSignIn)
    }

    func testAccountEmailUsesAuthenticatedResponseAndClearsOnSignOut() async throws {
        let owner = UUID()
        let storage = SocialFixtureStorage()
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { _ in
            try self.jsonResponse([
                "access_token": self.accessToken(owner: owner, email: "jwt@example.invalid"),
                "refresh_token": "synthetic-refresh-token",
                "user": ["id": owner.uuidString.lowercased(), "email": "  Verified@Example.Invalid  "],
            ])
        })
        defer { account.signOut(); storage.clear() }

        await account.signIn(email: "typed@example.invalid", password: "synthetic-password")

        XCTAssertEqual(account.emailAddress, "verified@example.invalid")
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(storage.read())) as? [String: Any])
        XCTAssertNil(persisted["email"])
        XCTAssertNil(persisted["emailAddress"], "The display address must not introduce a separate plaintext persisted field")
        account.signOut()
        XCTAssertNil(account.emailAddress)
        XCTAssertNil(account.session)
    }

    func testRestoredAccountEmailUsesJWTClaimWithoutExtraPersistenceOrNetwork() throws {
        let owner = UUID()
        let storage = SocialFixtureStorage()
        let saved = BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
                                      accessToken: try accessToken(owner: owner, email: "  Restored@Example.Invalid  "),
                                      refreshToken: "synthetic-refresh-token")
        try storage.write(JSONEncoder().encode(saved))
        let original = try storage.read()
        var requests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        })
        defer { account.signOut(); storage.clear() }

        XCTAssertEqual(account.emailAddress, "restored@example.invalid")
        XCTAssertEqual(account.session?.owner, owner)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(storage.writeCount, 1)
        XCTAssertEqual(try storage.read(), original)
    }

    func testAccountEmailHydratesMissingClaimUsingAuthenticatedUserEndpointOnlyOnce() async throws {
        let owner = UUID()
        let storage = SocialFixtureStorage()
        let token = try accessToken(owner: owner)
        let saved = BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
                                      accessToken: token, refreshToken: "synthetic-refresh-token")
        try storage.write(JSONEncoder().encode(saved))
        var requests: [URLRequest] = []
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            requests.append(request)
            return try self.jsonResponse(["id": owner.uuidString.lowercased(), "email": "verified@example.invalid",
                                          "role": "authenticated", "is_anonymous": false])
        })
        defer { account.signOut(); storage.clear() }
        XCTAssertNil(account.emailAddress)
        let original = try storage.read()

        await account.loadEmailAddress()
        await account.loadEmailAddress()

        XCTAssertEqual(account.emailAddress, "verified@example.invalid")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/auth/v1/user")
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertNil(requests.first?.httpBody)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        XCTAssertEqual(try storage.read(), original)
        XCTAssertEqual(storage.writeCount, 1)
    }

    func testAccountEmailLateHydrationAfterAccountSwitchIsIgnored() async throws {
        let oldOwner = UUID()
        let newOwner = UUID()
        let storage = SocialFixtureStorage()
        let saved = BoundSavedSession(origin: BoundFriendAccount.origin, owner: oldOwner,
                                      accessToken: try accessToken(owner: oldOwner), refreshToken: "synthetic-refresh-token")
        try storage.write(JSONEncoder().encode(saved))
        let started = expectation(description: "email lookup started")
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { request in
            if request.url?.path == "/auth/v1/user" {
                started.fulfill()
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return try self.jsonResponse([
                "access_token": self.accessToken(owner: newOwner),
                "refresh_token": "new-synthetic-refresh-token",
                "user": ["id": newOwner.uuidString.lowercased(), "email": "new@example.invalid"],
            ])
        })
        defer { account.signOut(); storage.clear() }

        let lookup = Task { await account.loadEmailAddress() }
        await fulfillment(of: [started], timeout: 2)
        await account.signIn(email: "typed@example.invalid", password: "synthetic-password")
        continuation?.resume(returning: try jsonResponse(["id": oldOwner.uuidString.lowercased(), "email": "old@example.invalid",
                                                        "role": "authenticated", "is_anonymous": false]))
        await lookup.value

        XCTAssertEqual(account.session?.owner, newOwner)
        XCTAssertEqual(account.emailAddress, "new@example.invalid")
    }

    func testAccountEmailHydrationRejectsDifferentOwnerAndAnonymousIdentity() async throws {
        let owner = UUID()
        let storage = SocialFixtureStorage()
        let saved = BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
                                      accessToken: try accessToken(owner: owner), refreshToken: "synthetic-refresh-token")
        try storage.write(JSONEncoder().encode(saved))
        let responses: [[String: Any]] = [
            ["id": UUID().uuidString.lowercased(), "email": "other@example.invalid", "role": "authenticated", "is_anonymous": false],
            ["id": owner.uuidString.lowercased(), "email": "anonymous@example.invalid", "role": "authenticated", "is_anonymous": true],
        ]
        var requests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { _ in
            defer { requests += 1 }
            return try self.jsonResponse(responses[requests])
        })
        defer { account.signOut(); storage.clear() }
        let originalStatus = account.status

        await account.loadEmailAddress()
        XCTAssertNil(account.emailAddress)
        await account.loadEmailAddress()

        XCTAssertNil(account.emailAddress)
        XCTAssertEqual(account.session?.owner, owner)
        XCTAssertEqual(account.status, originalStatus)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(storage.writeCount, 1)
        XCTAssertEqual(storage.removeCount, 0)
    }

    func testEmailChangeSendsOnlyNewAddressAndExactPasswordThenClearsLocalAccount() async throws {
        let owner = UUID()
        var requests: [URLRequest] = []
        let (account, storage) = try makeEmailChangeAccount(owner: owner, transport: { request in
            requests.append(request)
            return try self.jsonResponse(["ok": true, "email": "new@example.invalid"])
        })
        defer { account.signOut(); storage.clear() }
        let originalSession = try XCTUnwrap(account.session)
        let token = try JSONDecoder().decode(BoundSavedSession.self, from: XCTUnwrap(storage.read())).accessToken
        let originalWrites = storage.writeCount
        let password = "  Exact-Pass word\n"

        let result = await account.changeEmail(to: "  New@Example.Invalid \n", currentPassword: password)

        XCTAssertTrue(result)
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, BoundFriendAccount.origin + "/functions/v1/change-account-email")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), try BoundAccountTestFixture.apiKey("fixture-publishable-key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String],
                       ["newEmail": "new@example.invalid", "currentPassword": password],
                       "The client must not send an owner or any auto-confirm flag")
        XCTAssertNil(account.session)
        XCTAssertNil(account.emailAddress)
        XCTAssertNil(try storage.read())
        XCTAssertEqual(storage.writeCount, originalWrites, "Changing email must never persist the supplied password")
        XCTAssertEqual(storage.removeCount, 1)
        XCTAssertThrowsError(try originalSession.credentials(), "Successful email change must invalidate old native holders")
        XCTAssertEqual(account.emailChangeStatus, "Email updated. Sign in with your new email and current password.")
        XCTAssertFalse(account.changingEmail)
    }

    func testEmailChangeRequiresSignedInAccountWithoutSendingOrSaving() async throws {
        let storage = SocialFixtureStorage()
        var requests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: { _ in
            requests += 1
            return try self.jsonResponse(["ok": true, "email": "new@example.invalid"])
        })
        defer { account.signOut(); storage.clear() }

        let result = await account.changeEmail(to: "new@example.invalid", currentPassword: "synthetic-password")

        XCTAssertFalse(result)
        XCTAssertEqual(requests, 0)
        XCTAssertNil(account.session)
        XCTAssertNil(account.emailAddress)
        XCTAssertEqual(storage.writeCount, 0)
        XCTAssertNil(try storage.read())
        XCTAssertFalse(account.changingEmail)
    }

    func testEmailChangeValidatesNewAddressAndPasswordBeforeNetwork() async throws {
        var requests = 0
        let (account, storage) = try makeEmailChangeAccount(transport: { _ in
            requests += 1
            return try self.jsonResponse(["ok": true, "email": "new@example.invalid"])
        })
        defer { account.signOut(); storage.clear() }
        let originalSession = try XCTUnwrap(account.session)
        let original = try storage.read()

        for address in ["", "plain-address", "friend@", "a b@example.invalid", "friend@example.invalid\nInjected: value", "  CURRENT@EXAMPLE.INVALID  "] {
            let result = await account.changeEmail(to: address, currentPassword: "synthetic-password")
            XCTAssertFalse(result, address)
        }
        let missingPassword = await account.changeEmail(to: "new@example.invalid", currentPassword: "")

        XCTAssertFalse(missingPassword)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(originalSession.isSameSession(as: account.session))
        XCTAssertEqual(account.emailAddress, "current@example.invalid")
        XCTAssertEqual(try storage.read(), original)
        XCTAssertEqual(storage.writeCount, 1)
        XCTAssertEqual(storage.removeCount, 0)
        XCTAssertFalse(account.changingEmail)
    }

    func testEmailChangePreventsDuplicateSubmissionWhileRequestIsInFlight() async throws {
        let started = expectation(description: "email change started")
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
        var requests = 0
        let (account, storage) = try makeEmailChangeAccount(transport: { _ in
            requests += 1
            started.fulfill()
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        defer { account.signOut(); storage.clear() }

        let task = Task { await account.changeEmail(to: "new@example.invalid", currentPassword: "synthetic-password") }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(account.changingEmail)
        let duplicate = await account.changeEmail(to: "other@example.invalid", currentPassword: "other-password")
        XCTAssertFalse(duplicate)
        XCTAssertTrue(account.changingEmail, "A duplicate must not clear the original request's progress")
        XCTAssertEqual(requests, 1)
        continuation?.resume(returning: try jsonResponse(["ok": true, "email": "new@example.invalid"]))
        let result = await task.value

        XCTAssertTrue(result)
        XCTAssertFalse(account.changingEmail)
        XCTAssertNil(account.session)
    }

    func testEmailChangeRejectsMissingMismatchedAndMalformedSuccessReceipts() async throws {
        let responses = try [
            jsonResponse([:]),
            jsonResponse(["ok": false, "email": "new@example.invalid"]),
            jsonResponse(["ok": true]),
            jsonResponse(["ok": true, "email": "other@example.invalid"]),
            jsonResponse(["ok": "true", "email": "new@example.invalid"]),
            BoundAuthTransport.Response(data: Data("not-json".utf8), status: 200),
        ]
        for response in responses {
            let (account, storage) = try makeEmailChangeAccount(transport: { _ in response })
            let originalSession = try XCTUnwrap(account.session)
            let original = try storage.read()

            let result = await account.changeEmail(to: "new@example.invalid", currentPassword: "synthetic-password")

            XCTAssertFalse(result)
            XCTAssertTrue(originalSession.isSameSession(as: account.session))
            XCTAssertEqual(account.emailAddress, "current@example.invalid")
            XCTAssertEqual(try storage.read(), original)
            XCTAssertEqual(storage.writeCount, 1)
            XCTAssertEqual(storage.removeCount, 0)
            XCTAssertFalse(account.emailChangeStatus.isEmpty)
            XCTAssertFalse(account.changingEmail)
            account.signOut()
            storage.clear()
        }
    }

    func testEmailChangeErrorsRetainCurrentAccountAndHideServerDetails() async throws {
        for status in [401, 403, 409, 429, 500] {
            let (account, storage) = try makeEmailChangeAccount(transport: { _ in
                try self.jsonResponse(["message": "private-provider-details", "email": "private@example.invalid"], status: status)
            })
            let originalSession = try XCTUnwrap(account.session)
            let original = try storage.read()
            let originalStatus = account.status

            let result = await account.changeEmail(to: "new@example.invalid", currentPassword: "synthetic-password")

            XCTAssertFalse(result, "HTTP \(status)")
            XCTAssertTrue(originalSession.isSameSession(as: account.session), "HTTP \(status)")
            XCTAssertEqual(account.emailAddress, "current@example.invalid")
            XCTAssertEqual(account.status, originalStatus)
            XCTAssertEqual(try storage.read(), original)
            XCTAssertEqual(storage.writeCount, 1)
            XCTAssertEqual(storage.removeCount, 0)
            XCTAssertFalse(account.emailChangeStatus.isEmpty)
            XCTAssertFalse(account.emailChangeStatus.contains("private"))
            XCTAssertFalse(account.changingEmail)
            account.signOut()
            storage.clear()
        }
    }

    func testEmailChangeNetworkFailureRetainsCurrentAccount() async throws {
        let (account, storage) = try makeEmailChangeAccount(transport: { _ in
            throw URLError(.notConnectedToInternet)
        })
        defer { account.signOut(); storage.clear() }
        let originalSession = try XCTUnwrap(account.session)
        let original = try storage.read()

        let result = await account.changeEmail(to: "new@example.invalid", currentPassword: "synthetic-password")

        XCTAssertFalse(result)
        XCTAssertTrue(originalSession.isSameSession(as: account.session))
        XCTAssertEqual(account.emailAddress, "current@example.invalid")
        XCTAssertEqual(try storage.read(), original)
        XCTAssertEqual(storage.writeCount, 1)
        XCTAssertEqual(storage.removeCount, 0)
        XCTAssertFalse(account.emailChangeStatus.isEmpty)
        XCTAssertFalse(account.changingEmail)
    }

    func testEmailChangeCancellationIgnoresLateSuccessAndKeepsCurrentSession() async throws {
        let started = expectation(description: "email change started")
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
        let (account, storage) = try makeEmailChangeAccount(transport: { _ in
            started.fulfill()
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        defer { account.signOut(); storage.clear() }
        let originalSession = try XCTUnwrap(account.session)
        let original = try storage.read()
        let initialStatus = account.emailChangeStatus

        let task = Task { await account.changeEmail(to: "new@example.invalid", currentPassword: "synthetic-password") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        continuation?.resume(returning: try jsonResponse(["ok": true, "email": "new@example.invalid"]))
        let result = await task.value

        XCTAssertFalse(result)
        XCTAssertTrue(originalSession.isSameSession(as: account.session))
        XCTAssertEqual(account.emailAddress, "current@example.invalid")
        XCTAssertEqual(try storage.read(), original)
        XCTAssertEqual(storage.writeCount, 1)
        XCTAssertEqual(storage.removeCount, 0)
        XCTAssertEqual(account.emailChangeStatus, initialStatus)
        XCTAssertFalse(account.changingEmail)
    }

    func testEmailChangeLateSuccessAfterSignOutCannotRestoreAccountOrStatus() async throws {
        let started = expectation(description: "email change started")
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
        let (account, storage) = try makeEmailChangeAccount(transport: { _ in
            started.fulfill()
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        defer { account.signOut(); storage.clear() }

        let task = Task { await account.changeEmail(to: "new@example.invalid", currentPassword: "synthetic-password") }
        await fulfillment(of: [started], timeout: 2)
        account.signOut()
        let signedOutStatus = account.status
        let signedOutEmailChangeStatus = account.emailChangeStatus
        let removalsAfterSignOut = storage.removeCount
        continuation?.resume(returning: try jsonResponse(["ok": true, "email": "new@example.invalid"]))
        let result = await task.value

        XCTAssertFalse(result)
        XCTAssertNil(account.session)
        XCTAssertNil(account.emailAddress)
        XCTAssertNil(try storage.read())
        XCTAssertEqual(account.status, signedOutStatus)
        XCTAssertEqual(account.emailChangeStatus, signedOutEmailChangeStatus)
        XCTAssertEqual(storage.removeCount, removalsAfterSignOut)
        XCTAssertFalse(account.changingEmail)
    }

    func testEmailChangeLateResponsesAfterAccountSwitchCannotSignOutNewSession() async throws {
        let originalOwner = UUID()
        for (nextOwner, responseStatus) in [(UUID(), 200), (UUID(), 401), (originalOwner, 200)] {
            let started = expectation(description: "email change started")
            var continuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
            let (account, storage) = try makeEmailChangeAccount(owner: originalOwner, transport: { request in
                if request.url?.path == "/functions/v1/change-account-email" {
                    started.fulfill()
                    return try await withCheckedThrowingContinuation { continuation = $0 }
                }
                return try self.jsonResponse([
                    "access_token": self.accessToken(owner: nextOwner, email: "next@example.invalid"),
                    "refresh_token": "next-synthetic-refresh-token",
                    "user": ["id": nextOwner.uuidString.lowercased(), "email": "next@example.invalid"],
                ])
            })
            let originalSession = try XCTUnwrap(account.session)

            let task = Task { await account.changeEmail(to: "new@example.invalid", currentPassword: "synthetic-password") }
            await fulfillment(of: [started], timeout: 2)
            await account.signIn(email: "next@example.invalid", password: "next-password")
            let nextSession = try XCTUnwrap(account.session)
            let savedAfterSwitch = try storage.read()
            let statusAfterSwitch = account.status
            let changeStatusAfterSwitch = account.emailChangeStatus
            let writesAfterSwitch = storage.writeCount
            let removalsAfterSwitch = storage.removeCount
            continuation?.resume(returning: try jsonResponse(["ok": true, "email": "new@example.invalid"], status: responseStatus))
            let result = await task.value

            XCTAssertFalse(result)
            XCTAssertFalse(originalSession.isSameSession(as: account.session), "A same-owner re-login still creates a different session")
            XCTAssertTrue(nextSession.isSameSession(as: account.session))
            XCTAssertEqual(account.session?.owner, nextOwner)
            XCTAssertEqual(account.emailAddress, "next@example.invalid")
            XCTAssertEqual(account.status, statusAfterSwitch)
            XCTAssertEqual(account.emailChangeStatus, changeStatusAfterSwitch)
            XCTAssertEqual(try storage.read(), savedAfterSwitch)
            XCTAssertEqual(storage.writeCount, writesAfterSwitch)
            XCTAssertEqual(storage.removeCount, removalsAfterSwitch)
            XCTAssertFalse(account.changingEmail)
            account.signOut()
            storage.clear()
        }
    }

    func testOldEmailChangeCompletionCannotClearNewAccountsInFlightProgress() async throws {
        let nextOwner = UUID()
        let oldStarted = expectation(description: "old email change started")
        let nextStarted = expectation(description: "next email change started")
        var oldContinuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
        var nextContinuation: CheckedContinuation<BoundAuthTransport.Response, Error>?
        let (account, storage) = try makeEmailChangeAccount(transport: { request in
            if request.url?.path == "/functions/v1/change-account-email" {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
                if body["newEmail"] == "old-new@example.invalid" {
                    oldStarted.fulfill()
                    return try await withCheckedThrowingContinuation { oldContinuation = $0 }
                }
                nextStarted.fulfill()
                return try await withCheckedThrowingContinuation { nextContinuation = $0 }
            }
            return try self.jsonResponse([
                "access_token": self.accessToken(owner: nextOwner, email: "next@example.invalid"),
                "refresh_token": "next-synthetic-refresh-token",
                "user": ["id": nextOwner.uuidString.lowercased(), "email": "next@example.invalid"],
            ])
        })
        defer { account.signOut(); storage.clear() }

        let oldTask = Task { await account.changeEmail(to: "old-new@example.invalid", currentPassword: "old-password") }
        await fulfillment(of: [oldStarted], timeout: 2)
        await account.signIn(email: "next@example.invalid", password: "next-password")
        let nextSession = try XCTUnwrap(account.session)
        let nextTask = Task { await account.changeEmail(to: "next-new@example.invalid", currentPassword: "next-password") }
        await fulfillment(of: [nextStarted], timeout: 2)
        let nextStatus = account.emailChangeStatus
        oldContinuation?.resume(returning: try jsonResponse(["ok": true, "email": "old-new@example.invalid"]))
        let oldResult = await oldTask.value

        XCTAssertFalse(oldResult)
        XCTAssertTrue(nextSession.isSameSession(as: account.session))
        XCTAssertEqual(account.emailAddress, "next@example.invalid")
        XCTAssertTrue(account.changingEmail, "The old request's cleanup must not end the new request's progress")
        XCTAssertEqual(account.emailChangeStatus, nextStatus)
        nextContinuation?.resume(returning: try jsonResponse(["ok": true, "email": "next-new@example.invalid"]))
        let nextResult = await nextTask.value

        XCTAssertTrue(nextResult)
        XCTAssertNil(account.session)
        XCTAssertFalse(account.changingEmail)
    }

    func testEmailChangeHydratesMissingEmailWithAuthenticatedUserBeforeSubmission() async throws {
        let owner = UUID()
        var requests: [URLRequest] = []
        let (account, storage) = try makeEmailChangeAccount(owner: owner, email: nil, transport: { request in
            requests.append(request)
            if request.url?.path == "/auth/v1/user" {
                return try self.jsonResponse(["id": owner.uuidString.lowercased(), "email": "current@example.invalid",
                                              "role": "authenticated", "is_anonymous": false])
            }
            return try self.jsonResponse(["ok": true, "email": "new@example.invalid"])
        })
        defer { account.signOut(); storage.clear() }
        let token = try JSONDecoder().decode(BoundSavedSession.self, from: XCTUnwrap(storage.read())).accessToken

        let result = await account.changeEmail(to: "new@example.invalid", currentPassword: "synthetic-password")

        XCTAssertTrue(result)
        XCTAssertEqual(requests.map { $0.url?.path }, ["/auth/v1/user", "/functions/v1/change-account-email"])
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        XCTAssertNil(account.session)
        XCTAssertNil(account.emailAddress)
        XCTAssertNil(try storage.read())
    }

    func testEmailChangeDoesNotSubmitWithoutVerifiedCurrentEmail() async throws {
        let owner = UUID()
        var paths: [String] = []
        let (account, storage) = try makeEmailChangeAccount(owner: owner, email: nil, transport: { request in
            paths.append(request.url?.path ?? "")
            return try self.jsonResponse(["id": UUID().uuidString.lowercased(), "email": "other@example.invalid",
                                          "role": "authenticated", "is_anonymous": false])
        })
        defer { account.signOut(); storage.clear() }
        let original = try storage.read()

        let result = await account.changeEmail(to: "new@example.invalid", currentPassword: "synthetic-password")

        XCTAssertFalse(result)
        XCTAssertEqual(paths, ["/auth/v1/user"])
        XCTAssertEqual(account.session?.owner, owner)
        XCTAssertNil(account.emailAddress)
        XCTAssertEqual(try storage.read(), original)
        XCTAssertEqual(storage.writeCount, 1)
        XCTAssertEqual(storage.removeCount, 0)
        XCTAssertFalse(account.changingEmail)
    }

    private func makeEmailChangeAccount(owner: UUID = UUID(), email: String? = "current@example.invalid",
                                        transport: @escaping @MainActor (URLRequest) async throws -> BoundAuthTransport.Response) throws -> (BoundFriendAccount, SocialFixtureStorage) {
        let storage = SocialFixtureStorage()
        let saved = BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
                                      accessToken: try accessToken(owner: owner, email: email),
                                      refreshToken: "synthetic-refresh-token")
        try storage.write(JSONEncoder().encode(saved))
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false,
                                         configuration: { "fixture-publishable-key" }, transport: transport)
        return (account, storage)
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
        let expiredToken = try accessToken(owner: owner, expiry: Date().timeIntervalSince1970 - 10,
                                          email: "previous@example.invalid")
        let saved = BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
                                      accessToken: expiredToken, refreshToken: "synthetic-refresh-token")
        try storage.write(JSONEncoder().encode(saved))
        let renewedToken = try accessToken(owner: owner, expiry: Date().timeIntervalSince1970 + 3600)
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false, configuration: { key }, transport: { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/token")
            let response = try JSONSerialization.data(withJSONObject: [
                "access_token": renewedToken,
                "refresh_token": "rotated-refresh-token",
                "user": ["id": owner.uuidString.lowercased(), "email": "refreshed@example.invalid"],
            ])
            return BoundAuthTransport.Response(data: response, status: 200)
        })
        defer { account.signOut(); storage.clear() }

        XCTAssertEqual(account.emailAddress, "previous@example.invalid")
        let original = try XCTUnwrap(account.session)
        XCTAssertThrowsError(try original.friendSharingRequest(roomID: "fixture-room"),
                             "Expired credentials must not build an auth request")
        await account.refreshIfNeeded()

        XCTAssertTrue(original.isSameSession(as: account.session),
                      "A successful refresh should renew the existing account snapshot so the sharing owner fence remains valid")
        let renewedRequest = try original.friendSharingRequest(roomID: "fixture-room")
        XCTAssertEqual(renewedRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(renewedToken)")
        XCTAssertEqual(account.emailAddress, "refreshed@example.invalid")
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

    private func accessToken(owner: UUID, expiry: TimeInterval = 1_900_000_000, email: String? = nil) throws -> String {
        let claims = try BoundAccountTestFixture.claims(owner: owner, expiry: expiry, email: email)
        let data = try JSONSerialization.data(withJSONObject: claims)
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
    private(set) var writeCount = 0
    private(set) var removeCount = 0
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data; writeCount += 1 }
    func remove() throws { data = nil; removeCount += 1 }
    func clear() { data = nil }
}
