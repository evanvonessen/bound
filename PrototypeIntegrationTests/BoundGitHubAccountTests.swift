import XCTest
import Security
@testable import Delta

@MainActor
final class BoundGitHubAccountTests: XCTestCase {
    private final class Store: BoundGitHubCredentialStorage {
        var data: Data?
        var failWrite = false
        var failRemove = false
        var needsRemoval = false
        var reads = 0
        func read() throws -> Data? { reads += 1; return needsRemoval ? nil : data }
        func write(_ data: Data) throws {
            if failWrite { throw BoundGitHubAccount.Failure.storage }
            self.data = data
        }
        func remove() throws {
            if failRemove { needsRemoval = true; throw BoundGitHubAccount.Failure.storage }
            data = nil; needsRemoval = false
        }
    }
    private let device = Data(#"{"device_code":"synthetic-device-code","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#.utf8)
    private let token = Data(#"{"access_token":"synthetic-access","token_type":"bearer"}"#.utf8)
    private let profile = Data(#"{"id":123,"login":"fixture-user"}"#.utf8)
    private func finish(_ account: BoundGitHubAccount) async {
        for _ in 0..<1000 {
            if !account.isSigningIn { return }
            await Task.yield()
        }
        XCTFail("Sign-in did not finish")
    }
    private func settle() async { for _ in 0..<100 { await Task.yield() } }
    private func client(_ store: Store? = nil, transport: @escaping BoundGitHubAccount.Transport,
                        sleep: @escaping BoundGitHubAccount.Sleep = { _ in }) -> BoundGitHubAccount {
        BoundGitHubAccount(storage: store ?? Store(), clientID: { "fixture-public-client" }, transport: transport,
                           sleep: sleep, automaticRefresh: false)
    }

    func testDeviceFlowRequestsNoSecretsOrRepositoryScopesAndVerifiesIdentity() async throws {
        let store = Store(); var requests: [URLRequest] = []; var opened: URL?
        let account = client(store) { request in
            requests.append(request)
            switch request.url?.path {
            case "/login/device/code": return (self.device, 200)
            case "/login/oauth/access_token": return (self.token, 200)
            case "/user":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access")
                return (self.profile, 200)
            default: XCTFail("Unexpected request"); return (Data(), 500)
            }
        }
        account.signIn { opened = $0; XCTAssertEqual(account.userCode, "ABCD-1234") }
        await finish(account)
        XCTAssertEqual(opened?.absoluteString, "https://github.com/login/device")
        XCTAssertEqual(account.username, "fixture-user")
        XCTAssertNotNil(store.data)
        XCTAssertNil(account.userCode)
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertFalse(body.contains("client_secret"))
            XCTAssertFalse(body.contains("scope="))
        }
        XCTAssertTrue(String(data: try XCTUnwrap(requests[1].httpBody), encoding: .utf8)!.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
    }

    func testPendingAndSlowDownHonorServerPollingInterval() async {
        var polls = 0; var sleeps: [Double] = []
        let account = client(transport: { request in
            if request.url?.path == "/login/device/code" { return (self.device, 200) }
            if request.url?.path == "/user" { return (self.profile, 200) }
            polls += 1
            if polls == 1 { return (Data(#"{"error":"authorization_pending"}"#.utf8), 200) }
            if polls == 2 { return (Data(#"{"error":"slow_down","interval":12}"#.utf8), 200) }
            return (self.token, 200)
        }, sleep: { sleeps.append($0) })
        account.signIn { _ in }; await finish(account)
        XCTAssertEqual(sleeps, [5, 5, 12]); XCTAssertEqual(account.username, "fixture-user")
    }

    func testDenialAndExpiredCodesNeverPersistCredential() async {
        for error in ["access_denied", "expired_token", "device_flow_disabled"] {
            let store = Store()
            let account = client(store) { request in
                request.url?.path == "/login/device/code" ? (self.device, 200)
                    : (Data("{\"error\":\"\(error)\"}".utf8), 200)
            }
            account.signIn { _ in }; await finish(account)
            XCTAssertNil(account.username); XCTAssertNil(store.data); XCTAssertFalse(account.status.isEmpty)
        }
    }

    func testMissingRegistrationDoesNotOpenFakeSignInOrContactServer() {
        let account = BoundGitHubAccount(storage: Store(), clientID: { nil }, transport: { _ in
            XCTFail("Unconfigured client must not contact GitHub"); return (Data(), 500)
        }, automaticRefresh: false)
        account.signIn { _ in XCTFail("No browser without a real device grant") }
        XCTAssertFalse(account.isSigningIn); XCTAssertFalse(account.isConfigured)
        XCTAssertTrue(account.status.contains("registered Bound client ID"))
    }

    func testDisabledFeatureDoesNotReadCredentialsOrContactGitHubAndCanRefreshAfterReenable() async {
        let store = Store()
        store.data = Data(#"{"clientID":"fixture-public-client","accessToken":"synthetic-access"}"#.utf8)
        var requests = 0
        var complete: CheckedContinuation<(Data, Int), Error>?
        let account = client(store) { request in
            requests += 1
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/user")
            if requests == 1 { return try await withCheckedThrowingContinuation { complete = $0 } }
            return (self.profile, 200)
        }
        await settle()
        XCTAssertEqual(store.reads, 0); XCTAssertEqual(requests, 0); XCTAssertNil(account.username)
        account.refresh()
        for _ in 0..<1000 { if complete != nil { break }; await Task.yield() }
        XCTAssertEqual(store.reads, 1); XCTAssertEqual(requests, 1)
        XCTAssertNotNil(complete)
        // Disabling the feature cancels refresh without erasing the saved account.
        account.cancelSignIn()
        complete?.resume(returning: (profile, 200)); await settle()
        XCTAssertNil(account.username); XCTAssertNotNil(store.data)
        account.refresh(); await settle()
        XCTAssertEqual(requests, 2); XCTAssertEqual(account.username, "fixture-user")
    }

    func testUntrustedVerificationURLNeverOpens() async {
        let data = Data(#"{"device_code":"synthetic","user_code":"ABCD-1234","verification_uri":"https://github.com.attacker.invalid/login/device","expires_in":900,"interval":5}"#.utf8)
        let account = client { _ in (data, 200) }
        account.signIn { _ in XCTFail("Reject untrusted verification host") }
        await finish(account); XCTAssertNil(account.username)
    }

    func testCancellationAfterBrowserOpenNeverPollsOrPersists() async {
        let store = Store(); var requests = 0
        let account = client(store) { _ in requests += 1; return (self.device, 200) }
        account.signIn { _ in account.cancelSignIn() }
        await settle()
        XCTAssertEqual(requests, 1); XCTAssertNil(account.username); XCTAssertNil(store.data)
        XCTAssertNil(account.userCode); XCTAssertFalse(account.isSigningIn)
    }

    func testSignOutDuringIdentityVerificationCannotResurrectSession() async {
        let store = Store(); var complete: CheckedContinuation<(Data, Int), Error>?
        let account = client(store) { request in
            if request.url?.path == "/login/device/code" { return (self.device, 200) }
            if request.url?.path == "/login/oauth/access_token" { return (self.token, 200) }
            return try await withCheckedThrowingContinuation { complete = $0 }
        }
        account.signIn { _ in }
        for _ in 0..<1000 { if complete != nil { break }; await Task.yield() }
        XCTAssertNotNil(complete)
        account.signOut(); complete?.resume(returning: (profile, 200)); await settle()
        XCTAssertNil(account.username); XCTAssertNil(store.data)
    }

    func testProfileFailureAndKeychainFailureNeverReportSignedIn() async {
        for failStorage in [false, true] {
            let store = Store(); store.failWrite = failStorage
            let account = client(store) { request in
                if request.url?.path == "/login/device/code" { return (self.device, 200) }
                if request.url?.path == "/login/oauth/access_token" { return (self.token, 200) }
                return (self.profile, failStorage ? 200 : 401)
            }
            account.signIn { _ in }; await finish(account)
            XCTAssertNil(account.username); XCTAssertNil(store.data)
        }
    }

    func testExpiredDeviceCredentialRefreshesWithoutClientSecretAndRevalidatesUser() async throws {
        let store = Store(); var date = Date(timeIntervalSince1970: 1000); var bodies: [String] = []
        var refreshes = 0
        let account = BoundGitHubAccount(storage: store, clientID: { "fixture-public-client" }, transport: { request in
            if request.url?.path == "/login/device/code" { return (self.device, 200) }
            if request.url?.path == "/user" { return (self.profile, 200) }
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            bodies.append(body)
            if body.contains("grant_type=refresh_token") {
                refreshes += 1
                return (Data(#"{"access_token":"synthetic-rotated","refresh_token":"synthetic-next-refresh","expires_in":28800,"token_type":"bearer"}"#.utf8), 200)
            }
            return (Data(#"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":60,"token_type":"bearer"}"#.utf8), 200)
        }, sleep: { _ in }, now: { date }, automaticRefresh: false)
        account.signIn { _ in }; await finish(account)
        date = date.addingTimeInterval(120); account.refresh(); await settle()
        XCTAssertEqual(refreshes, 1); XCTAssertEqual(account.username, "fixture-user")
        XCTAssertFalse(bodies.joined().contains("client_secret"))
        XCTAssertTrue(String(data: try XCTUnwrap(store.data), encoding: .utf8)!.contains("synthetic-next-refresh"))
    }

    func testFailedSignOutRemainsSignedOutAndCanRetryRemoval() async {
        let store = Store()
        let account = client(store) { request in
            if request.url?.path == "/login/device/code" { return (self.device, 200) }
            if request.url?.path == "/user" { return (self.profile, 200) }
            return (self.token, 200)
        }
        account.signIn { _ in }; await finish(account)
        store.failRemove = true; account.signOut()
        XCTAssertNil(account.username); XCTAssertTrue(account.needsCredentialRemoval)
        account.signIn { _ in XCTFail("Cannot sign in before removal is resolved") }
        XCTAssertFalse(account.isSigningIn)
        store.failRemove = false; account.signOut()
        XCTAssertFalse(account.needsCredentialRemoval); XCTAssertNil(store.data)
    }

    func testKeychainIsDeviceOnlyAndLogoutMarkerPreventsRestorationOnDeletionFailure() throws {
        let suite = "BoundGitHubTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var storage = BoundGitHubKeychainStorage(defaults: defaults, service: "fixture.github")
        var copied = false
        storage.calls.update = { query, attributes in
            let query = query as! [String: Any]; let attributes = attributes as! [String: Any]
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            return errSecSuccess
        }
        storage.calls.delete = { _ in errSecInteractionNotAllowed }
        storage.calls.copy = { _, _ in copied = true; return errSecSuccess }
        try storage.write(Data("synthetic-credential".utf8))
        XCTAssertThrowsError(try storage.remove())
        XCTAssertNil(try storage.read()); XCTAssertFalse(copied); XCTAssertTrue(storage.needsRemoval)
        storage.calls.delete = { _ in errSecSuccess }; try storage.remove()
        XCTAssertFalse(storage.needsRemoval)
    }
}
