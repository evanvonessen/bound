import XCTest
import Security
import Harmony
import SwiftyDropbox
@testable import Delta

final class BoundDropboxOAuthTests: XCTestCase {
    func testPKCEChallengeUsesS256Base64URLEncoding() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(BoundDropboxOAuthProtocol.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizeURLRequestsOfflinePKCEWithRegisteredNativeRedirect() throws {
        let url = try XCTUnwrap(BoundDropboxOAuthProtocol.authorizationURL(
            appKey: "testappkey12345678", state: "state-value", verifier: "a".repeated(43)
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

    func testLiveDropboxPKCERefreshAndHarmonyFolderValidation() async throws {
        guard SyncManager.isBoundProviderConfigured(.dropbox, info: Bundle.main.infoDictionary ?? [:]),
              let appKey = Bundle.main.infoDictionary?["BOUND_DROPBOX_APP_KEY"] as? String else {
            throw XCTSkip("Live Dropbox QA requires the Bound Dropbox app key.")
        }

        let fixtureURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BoundDropboxLiveQA.json")
        guard let fixtureData = try? Data(contentsOf: fixtureURL) else {
            throw XCTSkip("No one-use Dropbox QA fixture is present.")
        }
        // Remove the one-use fixture before decoding or any XCTest output can
        // contain a credential-bearing error.
        do { try FileManager.default.removeItem(at: fixtureURL) }
        catch { throw LiveDropboxQAFailure.fixtureCleanup }
        guard let fixture = try? JSONDecoder().decode(LiveDropboxFixture.self, from: fixtureData),
              !fixture.refreshToken.isEmpty else { throw LiveDropboxQAFailure.invalidFixture }

        let keychainService = "com.evanvonessen.bound.dropbox.refresh.v1"
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: appKey
        ]
        guard SecItemCopyMatching(keychainQuery as CFDictionary, nil) == errSecItemNotFound else {
            throw LiveDropboxQAFailure.keychainAlreadySeeded
        }

        // Run the normal first-start path before seeding. On a fresh QA
        // simulator, SyncManager may deauthenticate once to initialize its
        // Harmony database; seeding afterward prevents that one-time cleanup
        // from deleting the fixture credential.
        try await startDatabase()
        try await startDropboxSyncManager()
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: appKey,
            kSecValueData as String: Data(fixture.refreshToken.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw LiveDropboxQAFailure.keychainSeedFailed
        }

        do {
            let account = try await authenticateDropboxInBackground()
            XCTAssertFalse(account.name.isEmpty)
            XCTAssertEqual(SyncManager.shared.service, .dropbox)
            XCTAssertNotNil(SyncManager.shared.coordinator?.account)

            // Force another background auth to exercise a second refresh grant
            // through the real Bound provider and Harmony validation path.
            let refreshedAccount = try await authenticateDropboxInBackground()
            XCTAssertFalse(refreshedAccount.name.isEmpty)

            print("Bound Dropbox live QA phase: byte round trip")
            try await verifyDropboxByteRoundTrip()

            // Exercise Harmony's actual record, ROM-file, and battery-save
            // upload paths with unique synthetic fixtures.
            let game = try await importSyntheticGame()
            defer { try? deleteLocalGame(game) }
            let gameSave = try attachSyntheticBatterySave(to: game)
            let gameRecordID = try recordID(for: game)
            let saveRecordID = try recordID(for: gameSave)
            print("Bound Dropbox live QA phase: Harmony ROM and battery sync")
            let uploadedRecords = try await syncOnce(waitingFor: [gameRecordID, saveRecordID])
            for recordID in [gameRecordID, saveRecordID] {
                guard let recordResult = uploadedRecords[recordID] else { throw LiveDropboxQAFailure.harmonyRecordMissing }
                try recordResult.get()
            }

            print("Bound Dropbox live QA phase: Harmony fixture cleanup")
            try deleteLocalGame(game)
            let cleanupRecords = try await syncOnce(waitingFor: [gameRecordID, saveRecordID])
            for recordID in [gameRecordID, saveRecordID] {
                guard let recordResult = cleanupRecords[recordID] else { throw LiveDropboxQAFailure.cleanupRecordMissing }
                try recordResult.get()
            }
            try await deauthenticateDropbox()
            XCTAssertEqual(SecItemCopyMatching(keychainQuery as CFDictionary, nil), errSecItemNotFound)
        } catch {
            try? await deauthenticateDropbox()
            throw error
        }
    }

    private func startDropboxSyncManager() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            SyncManager.shared.start(service: .dropbox) { continuation.resume(with: $0) }
        }
    }

    private func authenticateDropboxInBackground() async throws -> Account {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Account, Swift.Error>) in
            SyncManager.shared.authenticate(presentingViewController: nil) { continuation.resume(with: $0) }
        }
    }

    private func deauthenticateDropbox() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            SyncManager.shared.deauthenticate { continuation.resume(with: $0) }
        }
    }

    private func startDatabase() async throws {
        guard !DatabaseManager.shared.isStarted else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            DatabaseManager.shared.start { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func importSyntheticGame() async throws -> Game {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoundDropboxLiveQA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundledROM = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
        var bytes = try Data(contentsOf: bundledROM)
        bytes.append(contentsOf: UUID().uuidString.utf8)
        let source = directory.appendingPathComponent("BoundDropboxLiveQA-\(UUID().uuidString).gba")
        try bytes.write(to: source, options: .atomic)

        let imported = await withCheckedContinuation { continuation in
            DatabaseManager.shared.importGames(at: [source]) { games, errors in
                continuation.resume(returning: (games, errors))
            }
        }
        guard imported.1.isEmpty, let game = imported.0.first else { throw LiveDropboxQAFailure.syntheticGameImport }
        return game
    }

    private func attachSyntheticBatterySave(to game: Game) throws -> GameSave {
        guard let context = game.managedObjectContext else { throw LiveDropboxQAFailure.syntheticGameImport }
        var gameSave: GameSave!
        try context.performAndWait {
            gameSave = GameSave(context: context)
            gameSave.identifier = game.identifier
            gameSave.game = game
            let battery = Data((0..<128 * 1024).map { UInt8(($0 * 31 + 7) & 0xff) })
            try battery.write(to: game.gameSaveURL, options: .atomic)
            gameSave.sha1 = nil
            try context.save()
        }
        SyncManager.shared.recordController?.updateRecord(for: game)
        SyncManager.shared.recordController?.updateRecord(for: gameSave)
        return gameSave
    }

    private func deleteLocalGame(_ game: Game) throws {
        guard let context = game.managedObjectContext else { throw LiveDropboxQAFailure.syntheticGameImport }
        try context.performAndWait {
            guard !game.isDeleted else { return }
            try? FileManager.default.removeItem(at: game.gameSaveURL)
            if let gameSave = game.gameSave { context.delete(gameSave) }
            context.delete(game)
            try context.save()
        }
    }

    private func syncOnce(waitingFor targetRecordIDs: Set<RecordID>) async throws -> [RecordID: Result<Void, RecordError>] {
        let coordinator = try XCTUnwrap(SyncManager.shared.coordinator)
        let expectation = expectation(description: "Harmony sync includes the synthetic QA records")
        let resultBox = LiveDropboxSyncResultBox()
        let observer = NotificationCenter.default.addObserver(forName: SyncCoordinator.didFinishSyncingNotification, object: coordinator, queue: .main) { notification in
            guard let syncResult = notification.userInfo?[SyncCoordinator.syncResultKey] as? SyncResult else { return }
            resultBox.record(syncResult, waitingFor: targetRecordIDs, expectation: expectation)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        SyncManager.shared.sync()
        await fulfillment(of: [expectation], timeout: 120)
        return try XCTUnwrap(resultBox.takeResult()).get()
    }

    private func recordID(for object: some Syncable) throws -> RecordID {
        guard let context = object.managedObjectContext else { throw LiveDropboxQAFailure.syntheticGameImport }
        return context.performAndWait {
            RecordID(type: object.syncableType, identifier: object.syncableIdentifier!)
        }
    }

    private func verifyDropboxByteRoundTrip() async throws {
        let client = try XCTUnwrap(DropboxClientsManager.authorizedClient)
        let path = "/Delta Emulator/Bound OAuth QA \(UUID().uuidString).bin"
        var bytes = Data(count: 16 * 1024)
        for index in bytes.indices { bytes[index] = UInt8((index * 47 + 19) & 0xff) }
        do {
            try await upload(bytes, to: path, using: client)
            let downloaded = try await download(from: path, using: client)
            guard downloaded == bytes else { throw LiveDropboxQAFailure.apiRoundTrip }
            try await delete(path, using: client)
        } catch {
            try? await delete(path, using: client)
            throw LiveDropboxQAFailure.apiRoundTrip
        }
    }

    private func upload(_ data: Data, to path: String, using client: DropboxClient) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            client.files.upload(path: path, mode: .add, input: data).response { result, error in
                if error != nil { continuation.resume(throwing: LiveDropboxQAFailure.apiRoundTrip) }
                else if result != nil { continuation.resume(returning: ()) }
                else { continuation.resume(throwing: LiveDropboxQAFailure.apiRoundTrip) }
            }
        }
    }

    private func download(from path: String, using client: DropboxClient) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Swift.Error>) in
            client.files.download(path: path).response { result, error in
                if error != nil { continuation.resume(throwing: LiveDropboxQAFailure.apiRoundTrip) }
                else if let result { continuation.resume(returning: result.1) }
                else { continuation.resume(throwing: LiveDropboxQAFailure.apiRoundTrip) }
            }
        }
    }

    private func delete(_ path: String, using client: DropboxClient) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            client.files.deleteV2(path: path).response { result, error in
                if error != nil { continuation.resume(throwing: LiveDropboxQAFailure.apiRoundTrip) }
                else if result != nil { continuation.resume(returning: ()) }
                else { continuation.resume(throwing: LiveDropboxQAFailure.apiRoundTrip) }
            }
        }
    }
}

private struct LiveDropboxFixture: Decodable { let refreshToken: String }

private enum LiveDropboxQAFailure: Error {
    case fixtureCleanup, invalidFixture, keychainAlreadySeeded, keychainSeedFailed, apiRoundTrip, syntheticGameImport, harmonyRecordMissing, cleanupRecordMissing
}

private final class LiveDropboxSyncResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulated: [RecordID: Result<Void, RecordError>] = [:]
    private var failure: SyncError?
    private var fulfilled = false

    func record(_ syncResult: SyncResult, waitingFor targets: Set<RecordID>, expectation: XCTestExpectation) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.fulfilled else { return }
        switch syncResult {
        case .success(let records):
            for (record, result) in records { self.accumulated[record.recordID] = result }
        case .failure(.partial(let records)):
            for (record, result) in records { self.accumulated[record.recordID] = result }
        case .failure(let error):
            self.failure = error
            self.fulfilled = true
            expectation.fulfill()
            return
        }
        if targets.isSubset(of: Set(self.accumulated.keys)) {
            self.fulfilled = true
            expectation.fulfill()
        }
    }

    func takeResult() -> Result<[RecordID: Result<Void, RecordError>], SyncError>? {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let failure { return .failure(failure) }
        return .success(accumulated)
    }
}

private extension String {
    func repeated(_ count: Int) -> String { String(repeating: self, count: count) }
}
