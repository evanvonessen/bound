import XCTest
import UIKit
import CoreData
import CryptoKit
import Security
import Harmony
import SwiftyDropbox
@testable import Delta
@testable import class Delta.Game

/// Explicit, disposable-simulator acceptance test. Absent the one-use fixture,
/// this test skips before accessing accounts, databases or any network service.
/// The paired test uses the real broker and Harmony without a consent presenter.
/// A separate link-only test can open native consent without starting Harmony.
@MainActor
final class BoundDropboxLiveSyncTests: XCTestCase {
    private enum Failure: Error {
        case fixture, disposableDeviceRequired, emptyLibraryRequired, syncMustBeDisabled
        case signInRequired, freshSignInRequired, broker, provider, sync, bytes, relay
        case mismatchedDevices, remoteFolderExists, cleanup
        case brokerTokenPhase, folderPhase, startPhase, authenticatePhase
        case uploadPhase, downloadPhase, updatePhase, restorePhase, cleanupPhase
        case shutdownPhase, legacyCredentialPhase, reconnectPhase, signOutPhase, sessionPreservationPhase
    }

    private struct Fixture: Decodable {
        let disposableSimulator: Bool
        let mode: String
        let runID: UUID
        let role: String
        let folderName: String
        let relayURL: URL
    }

    private struct Report: Codable {
        let runID: UUID
        let stage: String
        let ownerFingerprint: String
        let sessionFingerprint: String
        let connectionFingerprint: String
    }
    private struct RelayState: Decodable { let reports: [String: Report] }

    private final class MemoryStore: BoundSessionStorage {
        var bytes: Data?
        init(_ bytes: Data? = nil) { self.bytes = bytes }
        func read() throws -> Data? { bytes }
        func write(_ data: Data) throws { bytes = data }
        func remove() throws { bytes = nil }
    }

    private var coordinator: SyncCoordinator?
    private var provider: BoundDropboxOAuth?
    private var connection: UUID?
    private var providerRequests = 0

    func testLinkDropboxUsingNativeConsent() async throws {
        let fixture = try consumeFixture(mode: "link")
        try validate(fixture)
        try await requireEmptyDisposableLibrary()
        let nativeSession = try BoundKeychainSessionStorage().read()
        let saved = try savedSession(nativeSession)
        let account = BoundFriendAccount(storage: MemoryStore(nativeSession), deletionStorage: MemoryStore(), automaticRefresh: false)
        guard account.session?.owner == saved.owner else { throw Failure.signInRequired }
        var linkedConnection: UUID?
        let broker = BoundDropboxOAuth(account: account, acceptConnection: { owner, connection in
            guard owner == saved.owner else { return false }
            linkedConnection = connection; return true
        })
        let presenter = UIViewController()
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw Failure.provider }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = presenter; window.makeKeyAndVisible()
        let completed = expectation(description: "Complete Dropbox consent in the dedicated QA simulator")
        let result = ConsentResult()
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            broker.cancelPendingAuthorization()
        }
        defer {
            timeout.cancel(); broker.cancelPendingAuthorization()
            window.isHidden = true; window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        broker.provideAccessToken(presenting: presenter) { reply in
            if case .success = reply { result.success = true }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 610)
        guard result.success else { throw Failure.broker }
        guard try BoundKeychainSessionStorage().read() == nativeSession else { throw Failure.cleanup }
        guard let linkedConnection else { throw Failure.broker }
        let linked = Report(runID: fixture.runID, stage: "linked",
            ownerFingerprint: Self.hash(Data((fixture.runID.uuidString + saved.owner.uuidString).utf8)),
            sessionFingerprint: Self.hash(Data((fixture.runID.uuidString + (try sessionIdentifier(saved))).utf8)),
            connectionFingerprint: Self.hash(Data((fixture.runID.uuidString + linkedConnection.uuidString).utf8)))
        try await Relay(base: fixture.relayURL).publish(linked, role: fixture.role)
        let evidence = ["linkedThroughRealBroker": true, "nativeSessionPreserved": true,
                        "harmonyStarted": false, "cloudFilesTransferred": false]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Dropbox native account link"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private final class ConsentResult { var success = false }

    func testLiveTwoDeviceBrokerAndHarmonySaveRestore() async throws {
        let fixture = try consumeFixture(mode: "pair")
        #if !targetEnvironment(simulator)
        throw Failure.disposableDeviceRequired
        #else
        try validate(fixture)
        try await requireEmptyDisposableLibrary()
        let nativeSession = try BoundKeychainSessionStorage().read()
        let saved = try savedSession(nativeSession)
        let sessionID = try sessionIdentifier(saved)
        let account = BoundFriendAccount(storage: MemoryStore(nativeSession), deletionStorage: MemoryStore(), automaticRefresh: false)
        guard account.session?.owner == saved.owner else { throw Failure.signInRequired }
        let ownerFingerprint = Self.hash(Data((fixture.runID.uuidString + saved.owner.uuidString).utf8))
        let sessionFingerprint = Self.hash(Data((fixture.runID.uuidString + sessionID).utf8))
        let relay = Relay(base: fixture.relayURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoundDropboxLiveSync-" + fixture.runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let service = DropboxService.shared
        let oldDirectory = service.preferredDirectoryName
        let oldProvider = service.accessTokenProvider
        let oldDeauthentication = service.deauthenticationHandler
        let oldAccountID = UserDefaults.standard.object(forKey: "harmony-dropbox_accountID")
        defer {
            service.preferredDirectoryName = oldDirectory
            service.accessTokenProvider = oldProvider
            service.deauthenticationHandler = oldDeauthentication
            if let oldAccountID { UserDefaults.standard.set(oldAccountID, forKey: "harmony-dropbox_accountID") }
            else { UserDefaults.standard.removeObject(forKey: "harmony-dropbox_accountID") }
            try? FileManager.default.removeItem(at: directory)
        }

        var generatedID: String?
        var generatedROM: Data?
        var ownsRemoteFolder = false
        var cleanupClient: DropboxClient?
        var phase = Failure.brokerTokenPhase
        do {
            guard let appKey = BoundDropboxOAuth.configuredAppKey() else { throw Failure.provider }
            if let configured = service.clientID {
                guard configured == appKey else { throw Failure.provider }
            } else { service.clientID = appKey }
            service.preferredDirectoryName = fixture.folderName
            let broker = BoundDropboxOAuth(account: account, acceptConnection: { [weak self] owner, connection in
                guard owner == saved.owner else { return false }
                if let previous = self?.connection, previous != connection { return false }
                self?.connection = connection
                return true
            })
            provider = broker
            service.accessTokenProvider = { [weak self] presenter, completion in
                Task { @MainActor in
                    // Intentionally never forwards a presenter: successful B
                    // authentication proves consent-free account restoration.
                    guard presenter == nil else { completion(.failure(.notAuthenticated)); return }
                    self?.providerRequests += 1
                    broker.provideAccessToken(presenting: nil, completion: completion)
                }
            }
            service.deauthenticationHandler = {
                // Harmony's callback is synchronous. Complete cancellation
                // before it reports deauthentication, so a later reconnect
                // cannot be cancelled by a queued task from the old lifecycle.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { broker.cancelPendingAuthorization() }
                } else {
                    DispatchQueue.main.sync { MainActor.assumeIsolated { broker.cancelPendingAuthorization() } }
                }
            }
            let access = try await brokerAccess(broker)
            guard let connection else { throw Failure.broker }
            let connectionFingerprint = Self.hash(Data((fixture.runID.uuidString + connection.uuidString).utf8))
            let report: (String) -> Report = { stage in
                Report(runID: fixture.runID, stage: stage, ownerFingerprint: ownerFingerprint,
                       sessionFingerprint: sessionFingerprint, connectionFingerprint: connectionFingerprint)
            }
            let client = DropboxClient(accessToken: access)
            cleanupClient = client

            let bundled = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
            var rom = try Data(contentsOf: bundled)
            rom.append(contentsOf: fixture.runID.uuidString.utf8)
            generatedROM = rom
            let identifier = Self.sha1(rom)
            generatedID = identifier
            let records: Set<RecordID> = [RecordID(type: "Game", identifier: identifier), RecordID(type: "GameSave", identifier: identifier)]

            if fixture.role == "A" {
                phase = .folderPhase
                try await requireMissingFolder("/" + fixture.folderName, client: client)
                ownsRemoteFolder = true
            } else {
                let other = try await relay.wait(role: "A", stage: "uploaded", runID: fixture.runID)
                try Self.validatePeer(other, local: report("ready"))
            }

            let sync = SyncCoordinator(service: service, persistentContainer: DatabaseManager.shared)
            // Separate Harmony metadata store: ordinary on-device sync history
            // is never reset, deleted or associated with this test directory.
            let descriptions = sync.recordController.persistentStoreDescriptions
            guard let first = descriptions.first else { throw Failure.sync }
            first.url = directory.appendingPathComponent("Harmony.sqlite")
            coordinator = sync
            phase = .startPhase
            try await start(sync)
            phase = .authenticatePhase
            try await authenticate(sync)
            guard sync.isAuthenticated, providerRequests > 0 else { throw Failure.broker }

            if fixture.role == "A" {
                phase = .uploadPhase
                let game = try await importGame(rom, runID: fixture.runID)
                try setBattery(Self.battery(updated: false), game: game, coordinator: sync)
                try await synchronize(sync, waitingFor: records)
                try await relay.publish(report("uploaded"), role: "A")
                let other = try await relay.wait(role: "B", stage: "updated", runID: fixture.runID)
                try Self.validatePeer(other, local: report("uploaded"))
                phase = .restorePhase
                try await synchronize(sync, waitingFor: [RecordID(type: "GameSave", identifier: identifier)])
                try verifyGame(identifier, rom: rom, battery: Self.battery(updated: true))
                try await relay.publish(report("restored"), role: "A")
                _ = try await relay.wait(role: "B", stage: "finished", runID: fixture.runID)
                phase = .cleanupPhase
                try deleteGeneratedGame(identifier)
                try await synchronize(sync, waitingFor: records)
                try await removeFolder("/" + fixture.folderName, client: client)
                ownsRemoteFolder = false
                try await relay.publish(report("cleaned"), role: "A")
            } else {
                phase = .downloadPhase
                try await synchronize(sync, waitingFor: records)
                try verifyGame(identifier, rom: rom, battery: Self.battery(updated: false))
                let game = try fetchGame(identifier)
                phase = .updatePhase
                try setBattery(Self.battery(updated: true), game: game, coordinator: sync)
                try await synchronize(sync, waitingFor: [RecordID(type: "GameSave", identifier: identifier)])
                try await relay.publish(report("updated"), role: "B")
                _ = try await relay.wait(role: "A", stage: "restored", runID: fixture.runID)
                try await relay.publish(report("finished"), role: "B")
                _ = try await relay.wait(role: "A", stage: "cleaned", runID: fixture.runID)
                try deleteGeneratedGame(identifier)
            }
            phase = .shutdownPhase
            try await shutdown()
            // No unowned legacy Dropbox token may be touched by this check.
            // The only account being signed out is the in-memory QA copy.
            phase = .legacyCredentialPhase
            guard !hasLegacyDropboxCredential(appKey: appKey) else { throw Failure.cleanup }
            phase = .reconnectPhase
            broker.clearCredentials()
            _ = try await brokerAccess(broker)
            guard self.connection == connection else { throw Failure.broker }
            phase = .signOutPhase
            account.signOut()
            let denied = await withCheckedContinuation { continuation in
                broker.provideAccessToken(presenting: nil) { reply in
                    if case .failure = reply { continuation.resume(returning: true) }
                    else { continuation.resume(returning: false) }
                }
            }
            guard denied else { throw Failure.broker }
            phase = .sessionPreservationPhase
            guard try BoundKeychainSessionStorage().read() == nativeSession else { throw Failure.cleanup }
            XCTAssertGreaterThan(providerRequests, 0)
            // Public metadata only. Never attach account, token, upstream error,
            // ROM, save or request bodies to the result bundle.
            let evidence: [String: Any] = ["role": fixture.role, "runID": fixture.runID.uuidString,
                "brokerRequests": providerRequests, "romSHA256": Self.hash(rom),
                "saveBytes": Self.battery(updated: true).count, "saveSHA256": Self.hash(Self.battery(updated: true)),
                "consentPresented": false, "nativeSessionPreserved": true, "remoteCleanupConfirmed": true,
                "disconnectRestoredWithoutConsent": true, "signedOutCopyDenied": true]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "Dropbox account-linked two-device sync"; attachment.lifetime = .keepAlways; add(attachment)
        } catch {
            let failed = Report(runID: fixture.runID, stage: "failed", ownerFingerprint: ownerFingerprint,
                                sessionFingerprint: sessionFingerprint, connectionFingerprint: String(repeating: "0", count: 64))
            try? await shutdown()
            try? await relay.publish(failed, role: fixture.role)
            if let generatedID, generatedROM != nil { try? deleteGeneratedGame(generatedID) }
            // Only A may remove the uniquely named directory it first proved
            // absent. Never unlink/revoke the shared account's Dropbox grant.
            if ownsRemoteFolder, let client = cleanupClient,
               await relay.peerHasStopped(role: fixture.role == "A" ? "B" : "A", runID: fixture.runID) {
                try? await removeFolder("/" + fixture.folderName, client: client)
            }
            // Underlying errors may include access tokens or private provider
            // response bodies. Only the fixed safe phase reaches XCTest.
            throw phase
        }
        #endif
    }

    private func consumeFixture(mode: String) throws -> Fixture {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BoundDropboxLiveSyncQA.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Live Dropbox QA requires the explicit one-use disposable-simulator fixture.")
        }
        guard let bytes = try? Data(contentsOf: url) else { throw Failure.fixture }
        do { try FileManager.default.removeItem(at: url) } catch { throw Failure.fixture }
        guard bytes.count <= 65536,
              let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(fields.keys) == ["disposableSimulator", "mode", "runID", "role", "folderName", "relayURL"],
              let fixture = try? JSONDecoder().decode(Fixture.self, from: bytes) else { throw Failure.fixture }
        guard fixture.mode == mode else { throw XCTSkip("One-use Dropbox fixture targets the other live QA mode.") }
        return fixture
    }

    private func validate(_ fixture: Fixture) throws {
        #if !targetEnvironment(simulator)
        throw Failure.disposableDeviceRequired
        #else
        guard fixture.disposableSimulator,
              fixture.role == "A" || fixture.role == "B",
              fixture.folderName == "Bound Dropbox QA " + fixture.runID.uuidString.lowercased(),
              fixture.relayURL.scheme == "http", fixture.relayURL.host == "127.0.0.1",
              fixture.relayURL.port != nil,
              fixture.relayURL.path.isEmpty || fixture.relayURL.path == "/",
              fixture.relayURL.user == nil, fixture.relayURL.password == nil,
              fixture.relayURL.query == nil, fixture.relayURL.fragment == nil else { throw Failure.fixture }
        #endif
    }

    private func requireEmptyDisposableLibrary() async throws {
        // Never stop a user's coordinator or seed their Keychain. Existing
        // library files and ordinary Harmony history survive these checks.
        guard SyncManager.shared.coordinator == nil,
              DropboxClientsManager.authorizedClient == nil else { throw Failure.syncMustBeDisabled }
        try await startDatabase()
        let context = DatabaseManager.shared.viewContext
        guard try context.count(for: Game.fetchRequest()) == 0,
              try context.count(for: GameSave.fetchRequest()) == 0,
              try context.count(for: SaveState.fetchRequest()) == 0 else { throw Failure.emptyLibraryRequired }
    }

    private func savedSession(_ bytes: Data?) throws -> BoundSavedSession {
        guard let bytes, bytes.count <= 65536,
              let saved = try? JSONDecoder().decode(BoundSavedSession.self, from: bytes),
              saved.origin == BoundFriendAccount.origin,
              let claims = Self.claims(saved.accessToken),
              let subject = claims["sub"] as? String, UUID(uuidString: subject) == saved.owner else { throw Failure.signInRequired }
        _ = try sessionIdentifier(saved)
        // The test must never rotate a copied refresh token behind the normal
        // app's Keychain. A recent independent UI sign-in gives ample lifetime.
        guard let expiry = claims["exp"] as? Double,
              expiry > Date().timeIntervalSince1970 + 1800 else { throw Failure.freshSignInRequired }
        return saved
    }

    private func hasLegacyDropboxCredential(appKey: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.evanvonessen.bound.dropbox.refresh.v1",
            kSecAttrAccount as String: appKey]
        return SecItemCopyMatching(query as CFDictionary, nil) != errSecItemNotFound
    }

    private func sessionIdentifier(_ saved: BoundSavedSession) throws -> String {
        guard let value = Self.claims(saved.accessToken)?["session_id"] as? String,
              UUID(uuidString: value) != nil else { throw Failure.signInRequired }
        return value
    }

    private static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func sha1(_ data: Data) -> String { Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func battery(updated: Bool) -> Data {
        Data((0..<128 * 1024).map { UInt8(($0 * (updated ? 17 : 31) + (updated ? 83 : 7)) & 0xff) })
    }
    private static func validatePeer(_ peer: Report, local: Report) throws {
        guard peer.runID == local.runID, peer.ownerFingerprint == local.ownerFingerprint,
              peer.sessionFingerprint != local.sessionFingerprint,
              peer.connectionFingerprint == local.connectionFingerprint else { throw Failure.mismatchedDevices }
    }
    private func brokerAccess(_ broker: BoundDropboxOAuth) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            broker.provideAccessToken(presenting: nil) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure: continuation.resume(throwing: Failure.broker)
                }
            }
        }
    }
    private func startDatabase() async throws {
        guard !DatabaseManager.shared.isStarted else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DatabaseManager.shared.start { error in
                if error != nil { continuation.resume(throwing: Failure.sync) } else { continuation.resume() }
            }
        }
    }
    private func start(_ sync: SyncCoordinator) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sync.start { result in
                switch result {
                case .success: continuation.resume()
                case .failure: continuation.resume(throwing: Failure.sync)
                }
            }
        }
    }
    private func authenticate(_ sync: SyncCoordinator) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sync.authenticate(presentingViewController: nil) { result in
                switch result {
                case .success: continuation.resume()
                case .failure: continuation.resume(throwing: Failure.provider)
                }
            }
        }
    }
    private func shutdown() async throws {
        provider?.cancelPendingAuthorization()
        guard let sync = coordinator else { return }
        await withCheckedContinuation { continuation in sync.cancelSyncing { continuation.resume() } }
        try sync.stop()
        // SyncCoordinator.deauthenticate() resets RecordController's *default*
        // directory even when its SQLite URL was overridden. Stop our isolated
        // store, then clear only provider memory without that destructive reset.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sync.service.deauthenticate { result in
                switch result {
                case .success: continuation.resume()
                case .failure: continuation.resume(throwing: Failure.cleanup)
                }
            }
        }
        coordinator = nil; provider = nil
    }
    private func importGame(_ bytes: Data, runID: UUID) async throws -> Game {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("BoundDropboxQA-" + runID.uuidString + ".gba")
        try bytes.write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        let success = await withCheckedContinuation { continuation in
            DatabaseManager.shared.importGames(at: [source]) { games, errors in
                continuation.resume(returning: games.count == 1 && errors.isEmpty)
            }
        }
        guard success else { throw Failure.sync }
        return try fetchGame(Self.sha1(bytes))
    }
    private func fetchGame(_ identifier: String) throws -> Game {
        let context = DatabaseManager.shared.viewContext
        context.refreshAllObjects()
        let request = Game.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", #keyPath(Game.identifier), identifier)
        guard let game = try context.fetch(request).first else { throw Failure.sync }
        return game
    }
    private func setBattery(_ bytes: Data, game: Game, coordinator sync: SyncCoordinator) throws {
        guard let context = game.managedObjectContext else { throw Failure.sync }
        let save = game.gameSave ?? GameSave(context: context)
        save.identifier = game.identifier; save.game = game
        try bytes.write(to: game.gameSaveURL, options: .atomic)
        save.sha1 = Self.sha1(bytes); save.modifiedDate = Date()
        try context.save()
        sync.recordController.updateRecord(for: game)
        sync.recordController.updateRecord(for: save)
    }
    private func verifyGame(_ identifier: String, rom: Data, battery: Data) throws {
        let game = try fetchGame(identifier)
        guard game.gameSave?.identifier == identifier,
              try Data(contentsOf: game.fileURL) == rom,
              try Data(contentsOf: game.gameSaveURL) == battery else { throw Failure.bytes }
    }
    private func deleteGeneratedGame(_ identifier: String) throws {
        let game = try fetchGame(identifier)
        guard let context = game.managedObjectContext else { throw Failure.cleanup }
        try? FileManager.default.removeItem(at: game.gameSaveURL)
        // Game.prepareForDeletion removes its ROM and its now-empty collection;
        // deleting the file first would bypass that normal cascade.
        if let save = game.gameSave { context.delete(save) }
        context.delete(game)
        try context.save()
    }
    private func synchronize(_ sync: SyncCoordinator, waitingFor targets: Set<RecordID>) async throws {
        let finished = expectation(description: "Generated Dropbox QA records synchronized")
        let result = ResultBox()
        let observer = NotificationCenter.default.addObserver(forName: SyncCoordinator.didFinishSyncingNotification, object: sync, queue: .main) { notification in
            if let value = notification.userInfo?[SyncCoordinator.syncResultKey] as? SyncResult {
                result.receive(value, targets: targets, finished: finished)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        guard sync.sync() != nil else { throw Failure.sync }
        await fulfillment(of: [finished], timeout: 120)
        guard result.success else { throw Failure.sync }
    }
    private func requireMissingFolder(_ path: String, client: DropboxClient) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.files.getMetadata(path: path).response { metadata, error in
                if metadata == nil, case .routeError(let route, _, _, _)? = error, case .path(.notFound) = route.unboxed {
                    continuation.resume()
                } else { continuation.resume(throwing: Failure.remoteFolderExists) }
            }
        }
    }
    private func removeFolder(_ path: String, client: DropboxClient) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.files.deleteV2(path: path).response { metadata, error in
                if metadata != nil, error == nil { continuation.resume() }
                else { continuation.resume(throwing: Failure.cleanup) }
            }
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var records = Set<RecordID>()
        private var finished = false
        private var passed = false
        var success: Bool { lock.lock(); defer { lock.unlock() }; return passed }
        func receive(_ value: SyncResult, targets: Set<RecordID>, finished expectation: XCTestExpectation) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            switch value {
            case .failure:
                finished = true; expectation.fulfill()
            case .success(let values):
                for (record, result) in values where targets.contains(record.recordID) {
                    guard case .success = result else { finished = true; expectation.fulfill(); return }
                    records.insert(record.recordID)
                }
                if targets.isSubset(of: records) { passed = true; finished = true; expectation.fulfill() }
            }
        }
    }

    /// Relay carries fingerprints and stages only, never credentials or saves.
    /// GET /status -> {"reports":{"A":Report,"B":Report}}
    /// POST /report/A or /report/B receives the corresponding Report.
    private final class Relay {
        private final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        }
        let base: URL
        let session: URLSession
        init(base: URL) {
            self.base = base
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 5
            session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        }
        func publish(_ report: Report, role: String) async throws {
            var request = URLRequest(url: base.appendingPathComponent("report/" + role))
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(report)
            let (_, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.relay }
        }
        func wait(role: String, stage: String, runID: UUID) async throws -> Report {
            let deadline = Date().addingTimeInterval(240)
            while Date() < deadline, !Task.isCancelled {
                let (data, response) = try await session.data(from: base.appendingPathComponent("status"))
                guard data.count <= 8192, (response as? HTTPURLResponse)?.statusCode == 200,
                      let state = try? JSONDecoder().decode(RelayState.self, from: data) else { throw Failure.relay }
                if state.reports.values.contains(where: { $0.runID == runID && $0.stage == "failed" }) { throw Failure.relay }
                if let peer = state.reports[role], peer.runID == runID, peer.stage == stage { return peer }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw Failure.relay
        }
        func peerHasStopped(role: String, runID: UUID) async -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                do {
                    let (data, response) = try await session.data(from: base.appendingPathComponent("status"))
                    guard data.count <= 8192, (response as? HTTPURLResponse)?.statusCode == 200,
                          let state = try? JSONDecoder().decode(RelayState.self, from: data) else { return false }
                    if let peer = state.reports[role], peer.runID == runID,
                       ["failed", "finished", "cleaned"].contains(peer.stage) { return true }
                    try await Task.sleep(for: .milliseconds(250))
                } catch { return false }
            }
            return false
        }
    }
}
