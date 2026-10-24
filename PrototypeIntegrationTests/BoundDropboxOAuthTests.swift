import XCTest
import Security
import Harmony
import SwiftyDropbox
@testable import Delta

@MainActor
final class BoundDropboxOAuthTests: XCTestCase {
    func testSaveClearRequiresStartedDropboxStoreOwnedByCurrentAccount() throws {
        let owner = UUID()
        XCTAssertThrowsError(try SyncManager.validateSaveClearRecordStore(owner: owner, recordedOwner: owner.uuidString,
            service: nil, isStarted: false, isChangingAccount: false))
        XCTAssertThrowsError(try SyncManager.validateSaveClearRecordStore(owner: owner, recordedOwner: UUID().uuidString,
            service: .dropbox, isStarted: true, isChangingAccount: false))
        XCTAssertThrowsError(try SyncManager.validateSaveClearRecordStore(owner: owner, recordedOwner: owner.uuidString,
            service: .dropbox, isStarted: true, isChangingAccount: true))
        XCTAssertNoThrow(try SyncManager.validateSaveClearRecordStore(owner: owner, recordedOwner: owner.uuidString,
            service: .dropbox, isStarted: true, isChangingAccount: false))
    }

    func testPKCEChallengeUsesS256Base64URLEncoding() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(BoundDropboxOAuthProtocol.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizeURLRequestsOfflinePKCEWithRegisteredNativeRedirect() throws {
        let url = try XCTUnwrap(BoundDropboxOAuthProtocol.authorizationURL(
            appKey: "testappkey12345678", state: "state-value", verifier: String(repeating: "a", count: 43)
        ))
        let values = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.host, "www.dropbox.com")
        XCTAssertEqual(url.path, "/oauth2/authorize")
        XCTAssertEqual(values["client_id"], "testappkey12345678")
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["token_access_type"], "offline")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["redirect_uri"], "db-testappkey12345678://2/token")
        XCTAssertEqual(values["state"], "state-value")
        XCTAssertNil(values["client_secret"])
        XCTAssertEqual(values["scope"], "account_info.read files.metadata.read files.metadata.write files.content.read files.content.write")
    }

    func testAuthorizationCallbackRequiresSchemePathAndMatchingState() throws {
        let callback = try XCTUnwrap(URL(string: "db-testappkey12345678://2/token?code=auth-code&state=expected"))
        XCTAssertEqual(BoundDropboxOAuthProtocol.authorizationCode(from: callback, callbackScheme: "db-testappkey12345678", expectedState: "expected"), "auth-code")
        XCTAssertNil(BoundDropboxOAuthProtocol.authorizationCode(from: callback, callbackScheme: "db-other", expectedState: "expected"))
        XCTAssertNil(BoundDropboxOAuthProtocol.authorizationCode(from: callback, callbackScheme: "db-testappkey12345678", expectedState: "wrong"))
        let wrongPath = try XCTUnwrap(URL(string: "db-testappkey12345678://2/other?code=auth-code&state=expected"))
        XCTAssertNil(BoundDropboxOAuthProtocol.authorizationCode(from: wrongPath, callbackScheme: "db-testappkey12345678", expectedState: "expected"))
    }

    func testRefreshCredentialIsPreservedForNetworkAndServiceFailures() {
        XCTAssertFalse(BoundDropboxOAuthProtocol.isInvalidRefreshCredential(statusCode: 500, responseBody: Data(#"{"error":"invalid_grant"}"#.utf8)))
        XCTAssertFalse(BoundDropboxOAuthProtocol.isInvalidRefreshCredential(statusCode: 400, responseBody: Data(#"{"error":"temporarily_unavailable"}"#.utf8)))
        XCTAssertTrue(BoundDropboxOAuthProtocol.isInvalidRefreshCredential(statusCode: 400, responseBody: Data(#"{"error":"invalid_grant"}"#.utf8)))
    }

    private final class Store: BoundSessionStorage {
        var data: Data?
        func read() throws -> Data? { data }
        func write(_ data: Data) throws { self.data = data }
        func remove() throws { data = nil }
    }
    private func token(_ owner: UUID) throws -> String {
        let claims = try JSONSerialization.data(withJSONObject: BoundAccountTestFixture.claims(owner: owner, expiry: Date().addingTimeInterval(3600).timeIntervalSince1970))
        return "header." + BoundDropboxOAuthProtocol.base64URL(claims) + ".signature"
    }
    private func account(owner: UUID = UUID()) throws -> BoundFriendAccount {
        let storage = Store()
        let saved = BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
            accessToken: try token(owner), refreshToken: "synthetic-bound-refresh")
        storage.data = try JSONEncoder().encode(saved)
        return BoundFriendAccount(storage: storage, deletionStorage: Store(), automaticRefresh: false,
            configuration: { "fixture-key" }, transport: { _ in
                XCTFail("Dropbox tests must not contact Bound Auth"); throw BoundFriendError.unavailable
            })
    }
    private func access(_ provider: BoundDropboxOAuth) async -> Result<String, Harmony.AuthenticationError> {
        await withCheckedContinuation { continuation in
            provider.provideAccessToken(presenting: nil) { continuation.resume(returning: $0) }
        }
    }
    func testSignedInDeviceRestoresLinkedDropboxWithoutInteractiveAuthorization() async throws {
        let account = try account()
        var calls = 0
        let provider = BoundDropboxOAuth(account: account, appKey: { "fixtureappkey1234" }) { request in
            calls += 1
            XCTAssertEqual(request.url?.path, "/functions/v1/bound-dropbox")
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
            XCTAssertEqual(body, ["action": "token"])
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            return (Data(#"{"accessToken":"short-lived","expiresIn":14400,"connectionID":"33333333-3333-4333-8333-333333333333"}"#.utf8), 200)
        }
        let value = await access(provider)
        XCTAssertEqual(try value.get(), "short-lived")
        XCTAssertEqual(calls, 1)
        // Device disconnect never removes the server-side connection.
        provider.clearCredentials()
        let restored = await access(provider)
        XCTAssertEqual(try restored.get(), "short-lived")
        XCTAssertEqual(calls, 2)
    }
    func testSignedOutDeviceNeverRequestsDropboxToken() async throws {
        let account = try account(); account.signOut()
        let provider = BoundDropboxOAuth(account: account) { _ in
            XCTFail("Signed-out devices must not request Dropbox access"); return (Data(), 500)
        }
        if case .success = await access(provider) { XCTFail("Signed out must fail") }
    }
    func testMissingConnectionInBackgroundNeverStartsOAuth() async throws {
        let provider = BoundDropboxOAuth(account: try account()) { _ in
            (Data(#"{"error":"not_linked"}"#.utf8), 404)
        }
        let result = await access(provider)
        guard case .failure(.noSavedCredentials) = result else { return XCTFail("Expected no saved connection") }
    }
    func testBrokerConfigurationFailureExplainsServiceSetupAndAllowsRetry() async throws {
        var available = false
        let provider = BoundDropboxOAuth(account: try account()) { _ in
            if available {
                return (Data(#"{"accessToken":"restored-token","expiresIn":14400,"connectionID":"33333333-3333-4333-8333-333333333333"}"#.utf8), 200)
            }
            return (Data(#"{"error":"not_configured"}"#.utf8), 503)
        }
        let failure = await access(provider)
        guard case .failure(.other(BoundDropboxOAuth.Failure.notConfigured)) = failure else {
            return XCTFail("Server setup must not be reported as a Bound sign-in or connectivity failure")
        }
        available = true
        let restored = await access(provider)
        XCTAssertEqual(try restored.get(), "restored-token")
    }

    func testRetryableBrokerAndNetworkFailuresPreserveHarmonySyncHistory() {
        let failures: [Harmony.AuthenticationError] = [
            .other(BoundDropboxOAuth.Failure.unavailable),
            .other(BoundDropboxOAuth.Failure.notConfigured),
            .other(BoundDropboxOAuth.Failure.rateLimited),
            .other(BoundDropboxOAuth.Failure.secondFactorRequired),
            .other(ServiceError.connectionFailed(URLError(.notConnectedToInternet))),
            .other(ServiceError.rateLimitExceeded)
        ]
        for failure in failures {
            XCTAssertTrue(SyncManager.shouldPreserveSyncState(after: failure))
        }
        XCTAssertFalse(SyncManager.shouldPreserveSyncState(after: .other(BoundDropboxOAuth.Failure.changed)))
        XCTAssertFalse(SyncManager.shouldPreserveSyncState(after: .other(BoundDropboxOAuth.Failure.signIn)))
    }

    func testRateLimitingAndSecondFactorRequirementRemainActionable() async throws {
        for (body, status) in [(#"{"error":"rate_limited"}"#, 429), (#"{"error":"second_factor_required"}"#, 403)] {
            let provider = BoundDropboxOAuth(account: try account()) { _ in (Data(body.utf8), status) }
            let result = await access(provider)
            if status == 429 {
                guard case .failure(.other(BoundDropboxOAuth.Failure.rateLimited)) = result else {
                    return XCTFail("Rate limiting must allow a later retry")
                }
            } else {
                guard case .failure(.other(BoundDropboxOAuth.Failure.secondFactorRequired)) = result else {
                    return XCTFail("Two-factor requirement must be distinguished from signed-out state")
                }
            }
        }
    }
    func testLateTokenAfterAccountSignOutIsRejected() async throws {
        let account = try account()
        let provider = BoundDropboxOAuth(account: account) { _ in
            account.signOut()
            return (Data(#"{"accessToken":"OLD-OWNER-TOKEN","expiresIn":14400,"connectionID":"33333333-3333-4333-8333-333333333333"}"#.utf8), 200)
        }
        if case .success = await access(provider) { XCTFail("Old account token must be discarded") }
    }
    func testAccountSwitchDiscardsOldTokenEvenWhenTransportIgnoresCancellation() async throws {
        let first = UUID(), second = UUID()
        let store = Store()
        store.data = try JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin,
            owner: first, accessToken: try token(first), refreshToken: "synthetic-refresh-A"))
        let nextToken = try token(second)
        let account = BoundFriendAccount(storage: store, deletionStorage: Store(), automaticRefresh: false,
            configuration: { "fixture-key" }, transport: { _ in
                let data = try JSONSerialization.data(withJSONObject: ["access_token": nextToken,
                    "refresh_token": "synthetic-refresh-B", "user": ["id": second.uuidString.lowercased()]])
                return BoundAuthTransport.Response(data: data, status: 200)
            })
        let provider = BoundDropboxOAuth(account: account) { _ in
            await account.signIn(email: "second@example.invalid", password: "synthetic-password")
            XCTAssertEqual(account.session?.owner, second)
            return (Data(#"{"accessToken":"OLD-OWNER-TOKEN","expiresIn":14400,"connectionID":"33333333-3333-4333-8333-333333333333"}"#.utf8), 200)
        }
        if case .success = await access(provider) { XCTFail("Old owner's token must not cross accounts") }
    }

    func testCancellationCompletesOnceAndDiscardsLateResponse() async throws {
        let account = try account()
        var release: CheckedContinuation<(Data, Int), Never>?
        let started = expectation(description: "Token request started")
        var acceptedConnections = 0
        let provider = BoundDropboxOAuth(account: account, acceptConnection: { _, _ in
            acceptedConnections += 1; return true
        }) { _ in
            await withCheckedContinuation { continuation in release = continuation; started.fulfill() }
        }
        var callbacks = 0
        let completed = expectation(description: "Cancelled token callback")
        provider.provideAccessToken(presenting: nil) { result in
            callbacks += 1
            if case .success = result { XCTFail("Cancelled response must not succeed") }
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        provider.cancelPendingAuthorization()
        await fulfillment(of: [completed], timeout: 2)
        release?.resume(returning: (Data(#"{"accessToken":"late-token","expiresIn":14400,"connectionID":"33333333-3333-4333-8333-333333333333"}"#.utf8), 200))
        await Task.yield()
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(acceptedConnections, 0)
    }
    func testUnlinkUsesAuthenticatedBoundEndpoint() async throws {
        var actions: [String] = []
        let provider = BoundDropboxOAuth(account: try account()) { request in
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
            actions.append(try XCTUnwrap(body["action"]))
            return (Data(#"{"ok":true}"#.utf8), 200)
        }
        try await provider.unlink()
        XCTAssertEqual(actions, ["unlink"])
    }
    func testConnectionChangeCanFenceTokenUntilHarmonyMetadataIsReset() async throws {
        var acceptedOwner: UUID?
        let account = try account()
        let provider = BoundDropboxOAuth(account: account, acceptConnection: { owner, _ in
            acceptedOwner = owner
            return false
        }) { _ in
            (Data(#"{"accessToken":"new-account-token","expiresIn":14400,"connectionID":"33333333-3333-4333-8333-333333333333"}"#.utf8),200)
        }
        if case .success = await access(provider) { XCTFail("Connection change must be fenced") }
        XCTAssertEqual(acceptedOwner, account.session?.owner)
    }

    func testInvalidBackendReplyNeverBecomesAnAccessToken() async throws {
        for (body, status) in [(#"{"accessToken":"x","expiresIn":0}"#,200), (#"{"error":"unavailable"}"#,503), (#"{"error":"unauthorized"}"#,401)] {
            let provider = BoundDropboxOAuth(account: try account()) { _ in (Data(body.utf8),status) }
            if case .success = await access(provider) { XCTFail("Invalid response must fail") }
        }
    }
}

@MainActor
final class BoundDropboxSaveDeletionTests: XCTestCase {
    private let gameID = String(repeating: "a", count: 40)
    private let otherGameID = String(repeating: "b", count: 40)
    private let snapshot = "11111111-1111-4111-8111-111111111111"
    private let otherSnapshot = "22222222-2222-4222-8222-222222222222"

    private func entry(_ name: String, metadata: [String: String] = [:]) -> [String: Any] {
        [".tag": "file", "id": "id:" + name, "name": name, "path_lower": "/delta emulator/" + name.lowercased(),
         "property_groups": [["fields": metadata.map { ["name": $0.key, "value": $0.value] }]]]
    }
    private func record(_ identifier: String, game: String) -> [String: Any] {
        entry("SaveState-" + identifier, metadata: ["harmony_recordedObjectType": "SaveState",
             "harmony_recordedObjectIdentifier": identifier, "gameID": game])
    }
    private func encoded(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func entries(_ value: [[String: Any]]) throws -> [BoundDropboxSaveDeletion.Entry] {
        try JSONDecoder().decode([BoundDropboxSaveDeletion.Entry].self, from: encoded(value))
    }
    private func page(_ values: [[String: Any]], cursor: String = "end", more: Bool = false) throws -> (Data, Int) {
        (try encoded(["entries": values, "cursor": cursor, "has_more": more]), 200)
    }

    func testSelectsOnlyExactCartridgeAndCloudSnapshotFiles() throws {
        let values = [entry("Game-" + gameID), entry("GameSave-" + gameID), entry("GameSave-" + gameID + "-gameSave"),
                      entry("GameSave-" + otherGameID + "-gameSave"), record(snapshot, game: gameID),
                      entry("SaveState-" + snapshot + "-saveState"), entry("SaveState-" + snapshot + "-thumbnail"),
                      record(otherSnapshot, game: otherGameID), entry("SaveState-" + otherSnapshot + "-saveState"),
                      entry("GameSave-" + gameID + "-gameSave-other")]
        let selected = try BoundDropboxSaveDeletion.selectedEntries(entries(values), gameID: gameID, localSaveStateIDs: [], directory: "Delta Emulator")
        XCTAssertEqual(Set(selected.map(\.name)), ["GameSave-" + gameID, "GameSave-" + gameID + "-gameSave",
                                                  "SaveState-" + snapshot, "SaveState-" + snapshot + "-saveState", "SaveState-" + snapshot + "-thumbnail"])
        XCTAssertEqual(selected.last?.name, "SaveState-" + snapshot)
    }

    func testRefusesLocalSnapshotIDThatBelongsToAnotherROMRemotely() throws {
        let values = [record(snapshot, game: otherGameID)]
        XCTAssertThrowsError(try BoundDropboxSaveDeletion.selectedEntries(entries(values), gameID: gameID,
            localSaveStateIDs: [snapshot], directory: "Delta Emulator"))
    }

    func testPaginatesAndRemovesPayloadsBeforeCloudOnlyRecord() async throws {
        var routes = [String](); var deleted = [String](); var listCalls = 0
        let deletion = BoundDropboxSaveDeletion(token: "fixture", directory: "Delta Emulator", transport: { request in
            let route = try XCTUnwrap(request.url?.path); routes.append(route)
            switch route {
            case "/2/file_properties/templates/list_for_user":
                XCTAssertEqual(request.httpBody, Data("null".utf8))
                return (try self.encoded(["template_ids": ["fixture-template"]]), 200)
            case "/2/files/list_folder":
                listCalls += 1
                return try self.page(listCalls == 1 ? [self.record(self.snapshot, game: self.gameID)] : [], cursor: "next", more: listCalls == 1)
            case "/2/files/list_folder/continue": return try self.page([self.entry("SaveState-" + self.snapshot + "-saveState")])
            case "/2/files/delete_v2":
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
                deleted.append(try XCTUnwrap(body["path"]))
                return (try self.encoded([:]), 200)
            default: XCTFail("Unexpected request"); throw BoundDropboxSaveDeletion.Failure.response
            }
        })
        try await deletion.delete(gameID: gameID, localSaveStateIDs: [])
        XCTAssertEqual(deleted, ["id:SaveState-" + snapshot + "-saveState", "id:SaveState-" + snapshot])
        XCTAssertEqual(listCalls, 2)
        XCTAssertTrue(routes.contains("/2/files/list_folder/continue"))
    }

    func testFailedPayloadDeletionDoesNotDeleteRecordAndCanBeRetried() async throws {
        var deleted = [String](); var failed = false; var listCalls = 0
        let deletion = BoundDropboxSaveDeletion(token: "fixture", directory: "Delta Emulator", transport: { request in
            switch request.url?.path {
            case "/2/file_properties/templates/list_for_user": return (try self.encoded(["template_ids": ["fixture-template"]]), 200)
            case "/2/files/list_folder":
                listCalls += 1
                return try self.page(listCalls < 3 ? [self.record(self.snapshot, game: self.gameID), self.entry("SaveState-" + self.snapshot + "-saveState")] : [])
            case "/2/files/delete_v2":
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
                let path = try XCTUnwrap(body["path"])
                if !failed { failed = true; return (Data(), 503) }
                deleted.append(path); return (try self.encoded([:]), 200)
            default: XCTFail("Unexpected request"); throw BoundDropboxSaveDeletion.Failure.response
            }
        })
        do { try await deletion.delete(gameID: gameID, localSaveStateIDs: []); XCTFail("Failure must keep deletion pending") }
        catch { XCTAssertTrue(deleted.isEmpty) }
        try await deletion.delete(gameID: gameID, localSaveStateIDs: [])
        XCTAssertEqual(deleted.last, "id:SaveState-" + snapshot)
    }

    func testMissingMetadataReadsOnlyRecordJSONToFindOwner() async throws {
        var listed = false; var downloads = 0; var deleted = [String]()
        let deletion = BoundDropboxSaveDeletion(token: "fixture", directory: "Delta Emulator", transport: { request in
            switch request.url?.path {
            case "/2/file_properties/templates/list_for_user": return (try self.encoded(["template_ids": []]), 200)
            case "/2/files/list_folder":
                if listed { return try self.page([]) }; listed = true
                return try self.page([self.entry("SaveState-" + self.snapshot), self.entry("SaveState-" + self.snapshot + "-saveState")])
            case "/2/files/download":
                downloads += 1
                XCTAssertEqual(request.url?.host, "content.dropboxapi.com")
                return (try self.encoded(["type": "SaveState", "identifier": self.snapshot,
                    "relationships": ["game": ["type": "Game", "identifier": self.gameID]]]), 200)
            case "/2/files/delete_v2":
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
                deleted.append(try XCTUnwrap(body["path"])); return (try self.encoded([:]), 200)
            default: XCTFail("Unexpected request"); throw BoundDropboxSaveDeletion.Failure.response
            }
        })
        try await deletion.delete(gameID: gameID, localSaveStateIDs: [])
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(deleted.count, 2)
    }

    func testAccountFencePreventsDeletionAfterIdentityChanges() async throws {
        var changed = false; var deletes = 0
        let deletion = BoundDropboxSaveDeletion(token: "fixture", directory: "Delta Emulator", transport: { request in
            switch request.url?.path {
            case "/2/file_properties/templates/list_for_user": return (try self.encoded(["template_ids": []]), 200)
            case "/2/files/list_folder": changed = true; return try self.page([self.entry("GameSave-" + self.gameID)])
            case "/2/files/delete_v2": deletes += 1; return (Data(), 200)
            default: throw BoundDropboxSaveDeletion.Failure.response
            }
        }, validate: { if changed { throw BoundDropboxSaveDeletion.Failure.changed } })
        do { try await deletion.delete(gameID: gameID, localSaveStateIDs: []); XCTFail("Changed identity must fail") }
        catch { XCTAssertEqual(deletes, 0) }
    }
}
