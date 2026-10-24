import XCTest
@testable import Delta

/// Native account-bound security flow tests. All credentials and transports are synthetic.
@MainActor
final class BoundAccountSecurityTests: XCTestCase {
    private let owner = UUID(uuidString: "30111111-2222-4333-8444-555555555555")!
    private let factor = UUID(uuidString: "40111111-2222-4333-8444-555555555555")!
    private let challenge = UUID(uuidString: "50111111-2222-4333-8444-555555555555")!

    func testPasswordMFAKeepsFirstFactorOutOfServicesAndKeychain() async throws {
        let storage = SecurityFixtureStorage()
        let data = try sessionData(aal: "aal1", factors: [factorObject()])
        let account = make(storage: storage) { _ in .init(data: data, status: 200) }
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        defer { account.signOut() }
        XCTAssertTrue(account.pendingMFA)
        XCTAssertNil(account.session)
        XCTAssertNil(account.emailAddress)
        XCTAssertNil(try storage.read())
        XCTAssertEqual(storage.writes, 0)
        XCTAssertEqual(account.securityFactors.first?.id, factor.uuidString.lowercased())
    }

    func testSecondFactorPublishesOnlyVerifiedAAL2AndRotatedRefreshToken() async throws {
        let storage = SecurityFixtureStorage()
        var paths: [String] = []
        let account = make(storage: storage) { request in
            let path = try XCTUnwrap(request.url?.path); paths.append(path)
            if path.hasSuffix("/challenge") { return try self.challengeResponse() }
            if path.hasSuffix("/verify") {
                let body = try self.object(request)
                XCTAssertEqual(body["challenge_id"] as? String, self.challenge.uuidString.lowercased())
                XCTAssertEqual(body["code"] as? String, "123456")
                return .init(data: try self.sessionData(aal: "aal2", refresh: "rotated-after-mfa", factors: [self.factorObject()]), status: 200)
            }
            return .init(data: try self.sessionData(aal: "aal1", factors: [self.factorObject()]), status: 200)
        }
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        let verified = await account.verifySecondFactor(code: "123456")
        defer { account.signOut() }
        XCTAssertTrue(verified)
        XCTAssertFalse(account.pendingMFA)
        XCTAssertTrue(account.securityAAL2)
        XCTAssertEqual(account.session?.owner, owner)
        XCTAssertEqual(storage.writes, 1)
        let saved = try JSONDecoder().decode(BoundSavedSession.self, from: XCTUnwrap(storage.read()))
        XCTAssertEqual(saved.refreshToken, "rotated-after-mfa")
        XCTAssertEqual(paths.count, 3)
    }

    func testMFARejectsWrongOwnerAndUnupgradedCredentials() async throws {
        for wrongOwner in [false, true] {
            let storage = SecurityFixtureStorage()
            let account = make(storage: storage) { request in
                if request.url?.path.hasSuffix("/challenge") == true { return try self.challengeResponse() }
                if request.url?.path.hasSuffix("/verify") == true {
                    return .init(data: try self.sessionData(owner: wrongOwner ? UUID() : self.owner,
                                                           aal: wrongOwner ? "aal2" : "aal1", factors: [self.factorObject()]), status: 200)
                }
                return .init(data: try self.sessionData(aal: "aal1", factors: [self.factorObject()]), status: 200)
            }
            await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
            let result = await account.verifySecondFactor(code: "123456")
            XCTAssertFalse(result)
            XCTAssertNil(account.session)
            XCTAssertTrue(account.pendingMFA)
            XCTAssertEqual(storage.writes, 0)
            account.signOut()
        }
    }

    func testSignOutRejectsLateChallengeWithoutVerifyingOrSaving() async throws {
        let storage = SecurityFixtureStorage()
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Never>?
        var challengeStarted = false
        var verifies = 0
        let account = make(storage: storage) { request in
            if request.url?.path.hasSuffix("/challenge") == true {
                challengeStarted = true
                return await withCheckedContinuation { continuation = $0 }
            }
            if request.url?.path.hasSuffix("/verify") == true { verifies += 1 }
            return .init(data: try self.sessionData(aal: "aal1", factors: [self.factorObject()]), status: 200)
        }
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        let task = Task { await account.verifySecondFactor(code: "123456") }
        while !challengeStarted { await Task.yield() }
        account.signOut()
        continuation?.resume(returning: try challengeResponse())
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertNil(account.session)
        XCTAssertFalse(account.pendingMFA)
        XCTAssertFalse(account.securityBusy)
        XCTAssertEqual(verifies, 0)
        XCTAssertEqual(storage.writes, 0)
    }

    func testInvalidAuthenticatorCodeNeverRequestsChallenge() async throws {
        let storage = SecurityFixtureStorage()
        var requests = 0
        let account = make(storage: storage) { _ in
            requests += 1
            return .init(data: try self.sessionData(aal: "aal1", factors: [self.factorObject()]), status: 200)
        }
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        defer { account.signOut() }
        for code in ["", "12345", "1234567", "１２３４５６", "123 56", "12345\n"] {
            let result = await account.verifySecondFactor(code: code)
            XCTAssertFalse(result)
        }
        XCTAssertEqual(requests, 1)
    }

    func testTOTPEnrollmentSecretIsEphemeralAndVerificationRenewsSameSnapshot() async throws {
        let storage = SecurityFixtureStorage()
        let account = make(storage: storage) { request in
            switch request.url?.path {
            case "/auth/v1/factors":
                let body = try self.object(request)
                XCTAssertEqual(body["factor_type"] as? String, "totp")
                XCTAssertEqual(body["issuer"] as? String, "Bound")
                return .init(data: try JSONSerialization.data(withJSONObject: ["id": self.factor.uuidString.lowercased(), "totp": ["secret": "SYNTHETICSETUPKEY", "uri": "otpauth://totp/Bound?secret=SYNTHETICSETUPKEY"]]), status: 200)
            case let path? where path.hasSuffix("/challenge"): return try self.challengeResponse()
            case let path? where path.hasSuffix("/verify"):
                return .init(data: try self.sessionData(aal: "aal2", refresh: "mfa-rotated", factors: [self.factorObject()]), status: 200)
            default: return .init(data: try self.sessionData(aal: "aal1"), status: 200)
            }
        }
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        let identity = try XCTUnwrap(account.session)
        let enrolled = await account.enrollTOTP()
        XCTAssertTrue(enrolled)
        XCTAssertEqual(account.totpEnrollment?.secret, "SYNTHETICSETUPKEY")
        XCTAssertEqual(account.totpEnrollment?.description, "BoundTOTPEnrollment(redacted)")
        let savedBefore = String(decoding: try XCTUnwrap(storage.read()), as: UTF8.self)
        XCTAssertFalse(savedBefore.contains("SYNTHETICSETUPKEY"))
        let verified = await account.verifyTOTPEnrollment(code: "123456")
        defer { account.signOut() }
        XCTAssertTrue(verified)
        XCTAssertNil(account.totpEnrollment)
        XCTAssertTrue(identity.isSameSession(as: account.session))
        XCTAssertTrue(account.securityAAL2)
        let saved = try JSONDecoder().decode(BoundSavedSession.self, from: XCTUnwrap(storage.read()))
        XCTAssertEqual(saved.refreshToken, "mfa-rotated")
    }

    func testCancellingLostEnrollmentResponseDoesNotDeleteVerifiedFactor() async throws {
        let storage = SecurityFixtureStorage()
        var deletes = 0
        let account = make(storage: storage) { request in
            if request.httpMethod == "DELETE" { deletes += 1 }
            if request.url?.path == "/auth/v1/factors" {
                return .init(data: try JSONSerialization.data(withJSONObject: ["id": self.factor.uuidString.lowercased(), "totp": ["secret": "SYNTHETICSETUPKEY", "uri": "otpauth://totp/Bound?secret=SYNTHETICSETUPKEY"]]), status: 200)
            }
            if request.url?.path == "/auth/v1/user" {
                return .init(data: try JSONSerialization.data(withJSONObject: ["id": self.owner.uuidString.lowercased(), "factors": [self.factorObject()]]), status: 200)
            }
            return .init(data: try self.sessionData(aal: "aal1"), status: 200)
        }
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        _ = await account.enrollTOTP()
        await account.cancelTOTPEnrollment()
        defer { account.signOut() }
        XCTAssertNil(account.totpEnrollment)
        XCTAssertEqual(deletes, 0)
        XCTAssertEqual(account.securityFactors.first?.status, "verified")
    }

    func testVerifiedFactorRemovalRequiresSecondFactor() async throws {
        let storage = SecurityFixtureStorage()
        var deletes = 0
        let account = make(storage: storage) { request in
            if request.httpMethod == "DELETE" { deletes += 1 }
            return .init(data: try self.sessionData(aal: "aal1", factors: [self.factorObject()]), status: 200)
        }
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        let result = await account.unenrollTOTP(factorID: factor.uuidString.lowercased())
        defer { account.signOut() }
        XCTAssertFalse(result)
        XCTAssertEqual(deletes, 0)
    }

    func testMalformedPresentFactorsFailClosedWhileMissingFactorsRemainCompatible() async throws {
        let storage = SecurityFixtureStorage()
        let account = make(storage: storage) { _ in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: self.sessionData(aal: "aal1")) as? [String: Any])
            var user = try XCTUnwrap(object["user"] as? [String: Any]); user["factors"] = "malformed"; object["user"] = user
            return .init(data: try JSONSerialization.data(withJSONObject: object), status: 200)
        }
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        defer { account.signOut() }
        XCTAssertNil(account.session)
        XCTAssertFalse(account.pendingMFA)
        XCTAssertEqual(storage.writes, 0)
    }

    func testPasskeySignInWrapsCredentialAndStillRequiresAuthenticator() async throws {
        let storage = SecurityFixtureStorage()
        let options = try optionsData()
        var bridgeCalls = 0
        var requests: [URLRequest] = []
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false, configuration: { "fixture-publishable" }, transport: { request in
            requests.append(request)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url?.path.hasSuffix("/options") == true { return .init(data: options, status: 200) }
            let body = try self.object(request)
            XCTAssertEqual(Set(body.keys), ["challenge_id", "credential"])
            XCTAssertEqual(body["challenge_id"] as? String, self.challenge.uuidString.lowercased())
            XCTAssertEqual((body["credential"] as? [String: Any])?["type"] as? String, "public-key")
            return .init(data: try self.sessionData(aal: "aal1", factors: [self.factorObject()]), status: 200)
        }, passkeyAuthentication: { data in
            XCTAssertEqual(data, options); bridgeCalls += 1
            return try self.credentialData()
        }, passkeysConfigurationAvailable: { true })
        await account.signInWithPasskey()
        defer { account.signOut() }
        XCTAssertTrue(account.pendingMFA)
        XCTAssertNil(account.session)
        XCTAssertEqual(storage.writes, 0)
        XCTAssertEqual(bridgeCalls, 1)
        XCTAssertEqual(requests.map { $0.url!.path }, ["/auth/v1/passkeys/authentication/options", "/auth/v1/passkeys/authentication/verify"])
    }

    func testLatePasskeyCeremonyCannotPublishAfterSignOut() async throws {
        let storage = SecurityFixtureStorage()
        var continuation: CheckedContinuation<Data, Never>?
        var started = false
        var verifies = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false, configuration: { "fixture-publishable" }, transport: { request in
            if request.url?.path.hasSuffix("/verify") == true { verifies += 1 }
            return .init(data: try self.optionsData(), status: 200)
        }, passkeyAuthentication: { _ in
            started = true
            return await withCheckedContinuation { continuation = $0 }
        }, passkeysConfigurationAvailable: { true })
        let task = Task { await account.signInWithPasskey() }
        while !started { await Task.yield() }
        account.signOut()
        continuation?.resume(returning: try credentialData())
        await task.value
        XCTAssertNil(account.session)
        XCTAssertFalse(account.busy)
        XCTAssertEqual(verifies, 0)
        XCTAssertEqual(storage.writes, 0)
    }

    func testPendingMFAPersistenceFailureRetainsRotatedTokenInMemoryOnly() async throws {
        let storage = SecurityFixtureStorage()
        var challengeBearers: [String?] = []
        let account = make(storage: storage) { request in
            if request.url?.path.hasSuffix("/challenge") == true {
                challengeBearers.append(request.value(forHTTPHeaderField: "Authorization"))
                return try self.challengeResponse()
            }
            if request.url?.path.hasSuffix("/verify") == true {
                return .init(data: try self.sessionData(aal: "aal2", refresh: "rotated-after-mfa", factors: [self.factorObject()]), status: 200)
            }
            return .init(data: try self.sessionData(aal: "aal1", factors: [self.factorObject()]), status: 200)
        }
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        storage.failWrites = true
        let first = await account.verifySecondFactor(code: "123456")
        XCTAssertFalse(first)
        XCTAssertTrue(account.pendingMFA)
        XCTAssertNil(account.session)
        XCTAssertNil(try storage.read())
        storage.failWrites = false
        let second = await account.verifySecondFactor(code: "123456")
        defer { account.signOut() }
        XCTAssertTrue(second)
        XCTAssertEqual(challengeBearers, ["Bearer " + (try token(aal: "aal1")), "Bearer " + (try token(aal: "aal2"))])
    }

    func testRestoredAAL1IsSuspendedWhenAuthReportsVerifiedFactor() async throws {
        let storage = SecurityFixtureStorage()
        try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner, accessToken: token(aal: "aal1"), refreshToken: "old-build-compatible-refresh")))
        let account = make(storage: storage) { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/user")
            return .init(data: try JSONSerialization.data(withJSONObject: ["id": self.owner.uuidString.lowercased(), "is_anonymous": false, "factors": [self.factorObject()]]), status: 200)
        }
        let previous = try XCTUnwrap(account.session)
        await account.loadAccountSecurity()
        defer { account.signOut() }
        XCTAssertNil(account.session)
        XCTAssertTrue(account.pendingMFA)
        XCTAssertNil(try storage.read())
        XCTAssertThrowsError(try previous.credentials())
    }

    func testSecuritySettingsDoNotQueryHiddenPasskeyService() async throws {
        let storage = SecurityFixtureStorage()
        try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner, accessToken: token(aal: "aal1"), refreshToken: "fixture-refresh")))
        var paths: [String] = []
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false, configuration: { "fixture-publishable" }, transport: { request in
            paths.append(request.url!.path)
            if request.url!.path == "/auth/v1/user" {
                return .init(data: try JSONSerialization.data(withJSONObject: ["id": self.owner.uuidString.lowercased(), "is_anonymous": false, "factors": []]), status: 200)
            }
            return .init(data: Data(), status: 501)
        }, passkeysConfigurationAvailable: { true })
        await account.loadAccountSecurity()
        defer { account.signOut() }
        XCTAssertEqual(paths, ["/auth/v1/user"])
        XCTAssertTrue(account.securityStatus.isEmpty)
        XCTAssertNotNil(account.session)
    }

    func testUnconfiguredPasskeysDoNotContactServerOrClearExistingSignIn() async throws {
        let storage = SecurityFixtureStorage()
        var requests = 0
        let account = BoundFriendAccount(storage: storage, automaticRefresh: false, configuration: { "fixture-publishable" }, transport: { _ in
            requests += 1; return .init(data: try self.sessionData(aal: "aal1"), status: 200)
        }, passkeysConfigurationAvailable: { false })
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        let identity = try XCTUnwrap(account.session)
        await account.signInWithPasskey()
        defer { account.signOut() }
        XCTAssertTrue(identity.isSameSession(as: account.session))
        XCTAssertEqual(requests, 1)
    }

    func testLateMFAResponseCannotOverwriteSameOwnerNewSignIn() async throws {
        let storage = SecurityFixtureStorage()
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Never>?
        var verifying = false
        var signIns = 0
        let account = make(storage: storage) { request in
            if request.url?.path.hasSuffix("/challenge") == true { return try self.challengeResponse() }
            if request.url?.path.hasSuffix("/verify") == true {
                verifying = true
                return await withCheckedContinuation { continuation = $0 }
            }
            signIns += 1
            return .init(data: try self.sessionData(aal: signIns == 1 ? "aal1" : "aal2", refresh: signIns == 1 ? "old-refresh" : "new-login-refresh", factors: [self.factorObject()]), status: 200)
        }
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        let oldTask = Task { await account.verifySecondFactor(code: "123456") }
        while !verifying { await Task.yield() }
        account.signOut()
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        let current = try XCTUnwrap(account.session)
        continuation?.resume(returning: .init(data: try sessionData(aal: "aal2", refresh: "stale-rotated-refresh", factors: [factorObject()]), status: 200))
        let result = await oldTask.value
        defer { account.signOut() }
        XCTAssertFalse(result)
        XCTAssertTrue(current.isSameSession(as: account.session))
        XCTAssertEqual(storage.writes, 1)
        let persisted = try JSONDecoder().decode(BoundSavedSession.self, from: XCTUnwrap(storage.read()))
        XCTAssertEqual(persisted.refreshToken, "new-login-refresh")
        XCTAssertFalse(account.securityBusy)
    }

    func testSecurityLookupRejectsOtherOwnerFactorList() async throws {
        let storage = SecurityFixtureStorage()
        let account = make(storage: storage) { request in
            if request.url?.path == "/auth/v1/user" {
                return .init(data: try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString.lowercased(), "factors": [self.factorObject()]]), status: 200)
            }
            return .init(data: try self.sessionData(aal: "aal1"), status: 200)
        }
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        let previous = try XCTUnwrap(account.session)
        await account.loadAccountSecurity()
        defer { account.signOut() }
        XCTAssertTrue(previous.isSameSession(as: account.session))
        XCTAssertTrue(account.securityFactors.isEmpty)
        XCTAssertFalse(account.pendingMFA)
        XCTAssertEqual(storage.writes, 1)
    }

    func testRefreshDiscoveringMFAInvalidatesOldSnapshotAndKeepsRotatedAAL1OnlyInMemory() async throws {
        let storage = SecurityFixtureStorage()
        try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
                                                                accessToken: token(aal: "aal1", expiry: Date().timeIntervalSince1970 + 30),
                                                                refreshToken: "legacy-device-refresh")))
        var challengeBearer: String?
        let account = make(storage: storage) { request in
            if request.url?.path.hasSuffix("/challenge") == true {
                challengeBearer = request.value(forHTTPHeaderField: "Authorization")
                return try self.challengeResponse()
            }
            if request.url?.path.hasSuffix("/verify") == true {
                return .init(data: try self.sessionData(aal: "aal2", refresh: "verified-device-refresh", factors: [self.factorObject()]), status: 200)
            }
            XCTAssertEqual(request.url?.path, "/auth/v1/token")
            XCTAssertEqual(try self.object(request)["refresh_token"] as? String, "legacy-device-refresh")
            return .init(data: try self.sessionData(aal: "aal1", refresh: "rotated-pending-refresh", factors: [self.factorObject()]), status: 200)
        }
        let previous = try XCTUnwrap(account.session)
        try previous.credentials()
        await account.refreshIfNeeded()
        XCTAssertNil(account.session)
        XCTAssertTrue(account.pendingMFA)
        XCTAssertFalse(account.securityAAL2)
        XCTAssertNil(try storage.read())
        XCTAssertEqual(storage.writes, 1, "The refreshed AAL1 must never overwrite secure storage")
        XCTAssertThrowsError(try previous.credentials())
        let verified = await account.verifySecondFactor(code: "123456")
        defer { account.signOut() }
        XCTAssertTrue(verified)
        XCTAssertEqual(challengeBearer, "Bearer " + (try token(aal: "aal1")))
        let persisted = try JSONDecoder().decode(BoundSavedSession.self, from: XCTUnwrap(storage.read()))
        XCTAssertEqual(persisted.refreshToken, "verified-device-refresh")
    }

    func testLateRefreshMFARequirementCannotSuspendNewGeneration() async throws {
        let storage = SecurityFixtureStorage()
        try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
                                                                accessToken: token(aal: "aal1", expiry: Date().timeIntervalSince1970 + 30),
                                                                refreshToken: "old-refresh")))
        var continuation: CheckedContinuation<BoundAuthTransport.Response, Never>?
        var refreshing = false
        let account = make(storage: storage) { request in
            if request.url?.query == "grant_type=refresh_token" {
                refreshing = true
                return await withCheckedContinuation { continuation = $0 }
            }
            return .init(data: try self.sessionData(aal: "aal2", refresh: "current-generation-refresh", factors: [self.factorObject()]), status: 200)
        }
        let oldTask = Task { await account.refreshIfNeeded() }
        while !refreshing { await Task.yield() }
        account.signOut()
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        let current = try XCTUnwrap(account.session)
        continuation?.resume(returning: .init(data: try sessionData(aal: "aal1", refresh: "stale-pending-refresh", factors: [factorObject()]), status: 200))
        await oldTask.value
        defer { account.signOut() }
        XCTAssertTrue(current.isSameSession(as: account.session))
        XCTAssertFalse(account.pendingMFA)
        XCTAssertTrue(account.securityAAL2)
        XCTAssertEqual(storage.writes, 2)
        let persisted = try JSONDecoder().decode(BoundSavedSession.self, from: XCTUnwrap(storage.read()))
        XCTAssertEqual(persisted.refreshToken, "current-generation-refresh")
    }

    func testProductionRestoreAutomaticallyChecksAuthoritativeFactorsAfterInitialization() async throws {
        let storage = SecurityFixtureStorage()
        try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
                                                                accessToken: token(aal: "aal1"), refreshToken: "restored-refresh")))
        let lookup = expectation(description: "Automatic restored-session factor lookup")
        let account = BoundFriendAccount(storage: storage, automaticRefresh: true, configuration: { "fixture-publishable" }, transport: { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/user")
            lookup.fulfill()
            return .init(data: try JSONSerialization.data(withJSONObject: ["id": self.owner.uuidString.lowercased(), "is_anonymous": false, "factors": [self.factorObject()]]), status: 200)
        }, passkeysConfigurationAvailable: { false })
        let previous = try XCTUnwrap(account.session)
        await fulfillment(of: [lookup], timeout: 3)
        defer { account.signOut() }
        XCTAssertNil(account.session)
        XCTAssertTrue(account.pendingMFA)
        XCTAssertNil(try storage.read())
        XCTAssertThrowsError(try previous.credentials())
    }

    func testBackupAuthenticatorCanBeSelectedWithoutTryingPrimaryFactor() async throws {
        let storage = SecurityFixtureStorage()
        let backup = UUID().uuidString.lowercased()
        var selected: String?
        var backupFactor = factorObject(); backupFactor["id"] = backup; backupFactor["friendly_name"] = "Backup authenticator"
        let factors = [factorObject(), backupFactor]
        let account = make(storage: storage) { request in
            if request.url?.path.hasSuffix("/challenge") == true {
                selected = request.url?.path
                return try self.challengeResponse()
            }
            if request.url?.path.hasSuffix("/verify") == true {
                return .init(data: try self.sessionData(aal: "aal2", factors: factors), status: 200)
            }
            return .init(data: try self.sessionData(aal: "aal1", factors: factors), status: 200)
        }
        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        let verified = await account.verifySecondFactor(code: "123456", factorID: backup)
        defer { account.signOut() }
        XCTAssertTrue(verified)
        XCTAssertEqual(selected, "/auth/v1/factors/" + backup + "/challenge")
        XCTAssertEqual(account.session?.owner, owner)
    }

    func testDiscardClearsSetupSecretImmediatelyDuringCancelledVerificationAndDeletesOnlyUnverifiedFactor() async throws {
        for serverAccepted in [false, true] {
            let storage = SecurityFixtureStorage()
            var continuation: CheckedContinuation<BoundAuthTransport.Response, Never>?
            var verifying = false
            var verificationReturned = false
            var lookups = 0
            var deletes = 0
            let account = make(storage: storage) { request in
                if request.url?.path == "/auth/v1/factors" {
                    return .init(data: try JSONSerialization.data(withJSONObject: ["id": self.factor.uuidString.lowercased(), "totp": ["secret": "SYNTHETICSETUPKEY", "uri": "otpauth://totp/Bound?secret=SYNTHETICSETUPKEY"]]), status: 200)
                }
                if request.url?.path.hasSuffix("/challenge") == true { return try self.challengeResponse() }
                if request.url?.path.hasSuffix("/verify") == true {
                    verifying = true
                    let response = await withCheckedContinuation { continuation = $0 }
                    verificationReturned = true
                    return response
                }
                if request.url?.path == "/auth/v1/user" {
                    XCTAssertTrue(verificationReturned, "Cleanup must wait until the in-flight verification drains")
                    lookups += 1
                    var factor = self.factorObject(); factor["status"] = serverAccepted ? "verified" : "unverified"
                    return .init(data: try JSONSerialization.data(withJSONObject: ["id": self.owner.uuidString.lowercased(), "factors": [factor]]), status: 200)
                }
                if request.httpMethod == "DELETE" {
                    deletes += 1
                    return .init(data: Data(), status: 204)
                }
                return .init(data: try self.sessionData(aal: "aal1"), status: 200)
            }
            await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
            _ = await account.enrollTOTP()
            let verify = Task { await account.verifyTOTPEnrollment(code: "123456") }
            while !verifying { await Task.yield() }
            verify.cancel()
            account.discardTOTPEnrollment()
            XCTAssertNil(account.totpEnrollment, "Leaving setup must clear its secret synchronously")
            XCTAssertTrue(account.securityBusy)
            let cleanup = Task { await account.cancelTOTPEnrollment() }
            continuation?.resume(returning: serverAccepted
                                 ? .init(data: try sessionData(aal: "aal2", factors: [factorObject()]), status: 200)
                                 : .init(data: Data(), status: 400))
            let result = await verify.value
            await cleanup.value
            XCTAssertFalse(result)
            XCTAssertNil(account.totpEnrollment)
            XCTAssertEqual(lookups, 1)
            XCTAssertEqual(deletes, serverAccepted ? 0 : 1)
            XCTAssertFalse(account.securityBusy)
            XCTAssertFalse(String(decoding: try XCTUnwrap(storage.read()), as: UTF8.self).contains("SYNTHETICSETUPKEY"))
            account.signOut()
        }
    }

    private func make(storage: SecurityFixtureStorage, transport: @escaping @MainActor (URLRequest) async throws -> BoundAuthTransport.Response) -> BoundFriendAccount {
        BoundFriendAccount(storage: storage, automaticRefresh: false, configuration: { "fixture-publishable" }, transport: transport, passkeysConfigurationAvailable: { false })
    }
    private func object(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private func factorObject() -> [String: Any] {
        ["id": factor.uuidString.lowercased(), "friendly_name": "Synthetic Authenticator", "factor_type": "totp", "status": "verified"]
    }
    private func challengeResponse() throws -> BoundAuthTransport.Response {
        .init(data: try JSONSerialization.data(withJSONObject: ["id": challenge.uuidString.lowercased()]), status: 200)
    }
    private func optionsData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["challenge_id": challenge.uuidString.lowercased(), "expires_at": 1_900_000_000, "options": ["challenge": "c3ludGhldGlj", "rpId": "example.invalid"]])
    }
    private func credentialData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": "c3ludGhldGlj", "rawId": "c3ludGhldGlj", "type": "public-key", "response": ["clientDataJSON": "c3ludGhldGlj", "authenticatorData": "c3ludGhldGlj", "signature": "c3ludGhldGlj"]])
    }
    private func sessionData(owner: UUID? = nil, aal: String, refresh: String = "synthetic-refresh", factors: [[String: Any]]? = nil) throws -> Data {
        let identity = owner ?? self.owner
        var user: [String: Any] = ["id": identity.uuidString.lowercased(), "email": "fixture@example.invalid"]
        if let factors { user["factors"] = factors }
        return try JSONSerialization.data(withJSONObject: ["access_token": token(owner: identity, aal: aal), "refresh_token": refresh, "user": user])
    }
    private func token(owner: UUID? = nil, aal: String, expiry: TimeInterval = 1_900_000_000) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: BoundAccountTestFixture.claims(owner: owner ?? self.owner, expiry: expiry, aal: aal), options: [.sortedKeys])
        return "fixture." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
    }
}

@MainActor
private final class SecurityFixtureStorage: BoundSessionStorage {
    private var data: Data?
    var failWrites = false
    private(set) var writes = 0
    func read() throws -> Data? { data }
    func write(_ data: Data) throws {
        if failWrites { throw BoundFriendError.unavailable }
        self.data = data; writes += 1
    }
    func remove() throws { data = nil }
}
