import XCTest
import UIKit
import SwiftUI
import Security
@testable import Delta

enum BoundAccountTestFixture {
    static func claims(owner: UUID, expiry: TimeInterval, aal: String? = nil, email: String? = nil) throws -> [String: Any] {
        let backend = try BoundBackendConfiguration.current()
        var details: [String: Any] = [:]
        if let aal { details["aal"] = aal }
        if let email { details["email"] = email }
        if backend.kind == .selfhost {
            return ["uid": owner.uuidString.lowercased(), "exp": expiry, "vrs": details]
        }
        return details.merging(["sub": owner.uuidString.lowercased(), "exp": expiry]) { _, value in value }
    }

    static func apiKey(_ key: String) throws -> String? {
        try BoundBackendConfiguration.current().kind == .legacy ? key : nil
    }
}

/// Synthetic credentials exercise the native Keychain and account lifecycle; no backend is contacted.
@MainActor
final class AccountPersistenceIntegrationTests: XCTestCase {
    #if DEBUG && targetEnvironment(simulator)
    func testLocalQAAuthorityRequiresExplicitLoopbackHTTPSAndKeepsProductionPortRules() throws {
        let info = ["BoundBackendKind": "selfhost", "BoundBackendURL": "https://bound.example"]
        let endpoint = "https://127.0.0.1:58552"
        let qa = try BoundBackendConfiguration.resolveBuild(info: info, environment: [
            "BOUND_QA_LOCAL_BACKEND": "1", "BOUND_QA_BACKEND_URL": endpoint])
        XCTAssertEqual(qa.kind, .selfhost); XCTAssertEqual(qa.origin, endpoint)
        XCTAssertEqual(try qa.url(path: "/auth/v1/user").absoluteString, endpoint + "/auth/v1/user")
        XCTAssertThrowsError(try BoundBackendConfiguration.resolveBuild(info: info, environment: ["BOUND_QA_BACKEND_URL": endpoint]))
        for invalid in ["http://127.0.0.1:58552", "https://localhost:58552", "https://bound.example:58552",
                        "https://127.0.0.1:443", "https://127.0.0.1:58552/path", "https://user@127.0.0.1:58552",
                        "https://127.0.0.1:58552?token=x", "https://127.0.0.1:58552#fragment"] {
            XCTAssertThrowsError(try BoundBackendConfiguration.resolveBuild(info: info, environment: [
                "BOUND_QA_LOCAL_BACKEND": "1", "BOUND_QA_BACKEND_URL": invalid]), invalid)
        }
        XCTAssertThrowsError(try BoundBackendConfiguration.resolve(info: ["BoundBackendKind": "selfhost", "BoundBackendURL": endpoint]))
        XCTAssertEqual(try BoundBackendConfiguration.resolveBuild(info: info, environment: [:]).origin, "https://bound.example")
    }
    #endif

    func testDebugRequestUsesOnlyCurrentSelfhostCredentialsAndBoundedJSON() throws {
        let owner = UUID()
        func session(_ kind: BoundBackendConfiguration.Kind) throws -> AppCloudSession {
            let claims: [String: Any] = [kind == .selfhost ? "uid" : "sub": owner.uuidString.lowercased(),
                                        "exp": Date().timeIntervalSince1970 + 600]
            let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return try .init(owner: owner, key: "must-not-leak", token: "fixture." + payload + ".signature",
                backend: .init(kind: kind, origin: kind == .selfhost ? "https://bound.example" : BoundBackendConfiguration.legacyOrigin))
        }
        let identity = try session(.selfhost), body = Data("{\"action\":\"list\"}".utf8)
        let request = try identity.debugRequest(body: body)
        XCTAssertEqual(request.url?.absoluteString, "https://bound.example/functions/v1/bound-debug")
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.httpBody, body)
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        XCTAssertNil(request.value(forHTTPHeaderField: "apikey"))
        XCTAssertThrowsError(try session(.legacy).debugRequest(body: body))
        XCTAssertThrowsError(try identity.debugRequest(body: Data("[]".utf8)))
        XCTAssertThrowsError(try identity.debugRequest(body: Data(repeating: 32, count: 65_537)))
    }

    func testBackendSelectionFailsClosedAndDefaultsToCurrentService() throws {
        let legacy = try BoundBackendConfiguration.resolve(info: [:])
        XCTAssertEqual(legacy.kind, .legacy)
        XCTAssertEqual(legacy.origin, BoundBackendConfiguration.legacyOrigin)
        XCTAssertEqual(try BoundBackendConfiguration.resolve(info: [
            "BoundBackendKind": "$(BOUND_BACKEND_KIND)", "BoundBackendURL": "$(BOUND_BACKEND_URL)"
        ]), legacy)
        for endpoint in ["", "http://bound.example", "https://user@bound.example", "https://bound.example/path",
                         "https://bound.example?key=value", "https://bound.example#fragment", "https://bound.example:7350",
                         BoundBackendConfiguration.legacyOrigin] {
            XCTAssertThrowsError(try BoundBackendConfiguration.resolve(info: [
                "BoundBackendKind": "selfhost", "BoundBackendURL": endpoint
            ]))
        }
        XCTAssertThrowsError(try BoundBackendConfiguration.resolve(info: ["BoundBackendKind": "unknown"]))
        XCTAssertThrowsError(try BoundBackendConfiguration.resolve(info: ["BoundBackendURL": "https://bound.example"]))
    }

    func testSelfhostSessionUsesNakamaOwnerAndSelectedOrigin() throws {
        let backend = try BoundBackendConfiguration.resolve(info: [
            "BoundBackendKind": "selfhost", "BoundBackendURL": "https://bound.example:443/"
        ])
        let owner = UUID()
        let claims: [String: Any] = ["uid": owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 600,
                                     "vrs": ["aal": "aal2", "email": "fixture@example.com"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "fixture." + payload + ".signature"
        let identity = try AppCloudSession(owner: owner, key: "legacy-key-must-not-leak", token: token, backend: backend)
        let request = try identity.friendSharingRequest(roomID: UUID().uuidString)
        XCTAssertEqual(request.url?.absoluteString, "https://bound.example/functions/v1/agora-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "apikey"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        XCTAssertEqual(backend.claims(claims)["aal"] as? String, "aal2")
        XCTAssertEqual(backend.claims(claims)["email"] as? String, "fixture@example.com")
        XCTAssertThrowsError(try AppCloudSession(owner: UUID(), key: "", token: token, backend: backend))
        XCTAssertThrowsError(try AppCloudSession(owner: owner, key: "", token: token,
            backend: BoundBackendConfiguration.resolve(info: [:])))
    }

    func testBackendKeychainItemsUseSeparateOrigins() throws {
        let namespace = "Bound.BackendIsolation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        var origins: [String] = []
        var calls = BoundKeychainSessionStorage.Calls()
        calls.copy = { query, _ in
            origins.append((query as NSDictionary)[kSecAttrAccount] as? String ?? "")
            return errSecItemNotFound
        }
        calls.delete = { _ in errSecSuccess }
        let legacy = BoundKeychainSessionStorage(calls: calls, defaults: defaults, service: namespace,
            origin: BoundBackendConfiguration.legacyOrigin)
        let selfhost = BoundKeychainSessionStorage(calls: calls, defaults: defaults, service: namespace,
            origin: "https://bound.example")
        _ = try legacy.read(); _ = try selfhost.read()
        try selfhost.remove()
        _ = try legacy.read(); _ = try selfhost.read()
        XCTAssertEqual(origins, [BoundBackendConfiguration.legacyOrigin, "https://bound.example", BoundBackendConfiguration.legacyOrigin])
    }

    func testFriendsObservationStopsOnCloseAndResumesWithoutLosingOwnerChanges() throws {
        let sharing = FriendSharingSession(configuration: nil, authenticatedMode: true)
        var observations: [OnboardingObservation] = []
        var reads = 0
        var identity: AppCloudSession?
        let onboarding = FriendOnboarding(call: { _, _, _ in FriendResponse(ok: true, rooms: []) }, observeAccount: { callback in
            let observation = OnboardingObservation(callback)
            observations.append(observation)
            return observation
        })
        let provider = { reads += 1; return identity }
        onboarding.open(sharing: sharing, existing: provider)
        XCTAssertEqual(observations.count, 1)
        observations[0].fire()
        XCTAssertEqual(reads, 2)
        onboarding.close()
        XCTAssertTrue(observations[0].cancelled)
        observations[0].fire() // A callback already queued before cancellation.
        onboarding.synchronizeAccount()
        XCTAssertEqual(reads, 2, "Dismissed/background Friends must not poll account state")
        onboarding.open(sharing: sharing, existing: provider)
        XCTAssertEqual(observations.count, 2)
        let owner = UUID()
        identity = try AppCloudSession(owner: owner, key: "synthetic-key", token: token(owner: owner))
        observations[1].fire()
        XCTAssertTrue(onboarding.signedIn)
        XCTAssertFalse(observations[1].cancelled, "Changing owner must not cancel visible-sheet observation")
        onboarding.signOut(); identity = nil
        XCTAssertFalse(observations[1].cancelled)
        observations[1].fire()
        XCTAssertFalse(onboarding.signedIn)
        onboarding.close()
        let closedReads = reads
        observations[1].fire()
        XCTAssertEqual(reads, closedReads)
        XCTAssertTrue(observations[1].cancelled)
    }

    func testFriendsSheetUsesSharedLayoutAcrossUIVersionsAndMultiplayerStates() async throws {
        let previousVersion = UserDefaults.standard.object(forKey: BoundUIVersionPreferences.key)
        let previousExperimental = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)

        let namespace = "Bound.FriendsSheetRenderTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        let storage = BoundKeychainSessionStorage(defaults: defaults, service: namespace + ".session")
        let deletionStorage = BoundKeychainSessionStorage(defaults: defaults, service: namespace + ".deletion")
        let owner = UUID()
        let token = try token(owner: owner)
        try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin,
            owner: owner, accessToken: token, refreshToken: "synthetic-friends-render-refresh")))
        let account = BoundFriendAccount(storage: storage, deletionStorage: deletionStorage,
            automaticRefresh: false, configuration: { "fixture-key" }, transport: { _ in
                XCTFail("Rendering the Friends sheet must not contact the backend")
                throw BoundFriendError.unavailable
            })
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "A Long Friend Display Name")
        let onboarding = FriendOnboarding(call: { _, action, _ in
            XCTAssertEqual(action, "list")
            return FriendResponse(ok: true, rooms: [room], username: "LongUsernameForLayoutTestingABCDE")
        }, sendJiggle: { _, _ in
            XCTFail("Rendering the Friends sheet must not send a Jiggle")
            return ""
        }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, authenticatedMode: true)
        let host = UIHostingController(rootView: BoundFriendsSheet(sharing: sharing,
            onboarding: onboarding, account: account))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            onboarding.close()
            sharing.stop()
            account.signOut()
            try? storage.remove()
            try? deletionStorage.remove()
            defaults.removePersistentDomain(forName: namespace)
            if let previousVersion {
                UserDefaults.standard.set(previousVersion, forKey: BoundUIVersionPreferences.key)
            } else {
                UserDefaults.standard.removeObject(forKey: BoundUIVersionPreferences.key)
            }
            if let previousExperimental {
                UserDefaults.standard.set(previousExperimental, forKey: BoundMultiplayerFeatures.key)
            } else {
                UserDefaults.standard.removeObject(forKey: BoundMultiplayerFeatures.key)
            }
            NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
        }

        for _ in 0..<100 {
            if onboarding.accountUsername != nil && onboarding.rooms == [room] { break }
            await Task.yield()
        }
        XCTAssertEqual(onboarding.rooms, [room])
        XCTAssertEqual(onboarding.accountUsername, "LongUsernameForLayoutTestingABCDE")

        func attach(_ name: String, size: CGSize = CGSize(width: 393, height: 852)) throws {
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { _ in
                host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 5000)
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        for (layout, size) in [("iPhone", CGSize(width: 393, height: 852)),
                               ("Mac", CGSize(width: 1024, height: 768))] {
            for version in BoundUIVersion.allCases {
                BoundUIVersionPreferences().version = version
                for experimental in [false, true] {
                    BoundMultiplayerFeatures.setEnabled(experimental)
                    host.rootView = BoundFriendsSheet(sharing: sharing, onboarding: onboarding, account: account)
                    try attach("Friends-\(layout)-option\(version.rawValue)-multiplayer-\(experimental ? "on" : "off")", size: size)
                    XCTAssertEqual(BoundUIVersionPreferences().version, version,
                                   "Friends organization must not rewrite the saved appearance preference")
                }
            }
        }
    }

    private func token(owner: UUID, expires: TimeInterval = 3600) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: BoundAccountTestFixture.claims(owner: owner, expiry: Date().timeIntervalSince1970 + expires, email: "fixture@example.invalid"))
        let payload = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "fixture." + payload + ".signature"
    }
    func testNativeKeychainRestoresSignedInFixtureAndLogoutRemovesIt() async throws {
        let namespace = "Bound.AuthPersistenceTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        let storage = BoundKeychainSessionStorage(defaults: defaults, service: namespace)
        defer { try? storage.remove(); defaults.removePersistentDomain(forName: namespace) }
        let owner = UUID(); let access = try token(owner: owner)
        let fixture = BoundAuthTransport.Response(data: try JSONSerialization.data(withJSONObject: [
            "access_token": access, "refresh_token": "synthetic-native-refresh", "user": ["id": owner.uuidString]
        ]), status: 200)
        var first: BoundFriendAccount? = BoundFriendAccount(storage: storage, automaticRefresh: false,
            configuration: { "fixture-key" }, transport: { _ in fixture })
        await first?.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        XCTAssertEqual(first?.session?.owner, owner)
        let saved = try XCTUnwrap(storage.read())
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("synthetic-password"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("fixture@example.invalid"))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace, kSecAttrAccount as String: BoundFriendAccount.origin,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        first = nil
        let restored = BoundFriendAccount(storage: storage, automaticRefresh: false, configuration: { "fixture-key" }, transport: { _ in
            XCTFail("A valid restored session must not need a network call")
            throw BoundFriendError.unavailable
        })
        XCTAssertEqual(restored.session?.owner, owner)
        let retainedSession = try XCTUnwrap(restored.session)
        XCTAssertNoThrow(try retainedSession.credentials())
        await restored.refreshIfNeeded()
        restored.signOut()
        XCTAssertNil(try storage.read()); XCTAssertNil(restored.session)
        XCTAssertThrowsError(try retainedSession.credentials())
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
        let signedOut = BoundFriendAccount(storage: storage, automaticRefresh: false, configuration: { "fixture-key" })
        XCTAssertNil(signedOut.session)
    }
    func testForegroundRefreshRenewsExpiredNativeFixtureWithoutLogin() async throws {
        let namespace = "Bound.AuthForegroundTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        let storage = BoundKeychainSessionStorage(defaults: defaults, service: namespace)
        defer { try? storage.remove(); defaults.removePersistentDomain(forName: namespace) }
        let owner = UUID()
        try storage.write(JSONEncoder().encode(BoundSavedSession(origin: BoundFriendAccount.origin,
            owner: owner, accessToken: try token(owner: owner, expires: -30), refreshToken: "synthetic-expired-refresh")))
        let completed = expectation(description: "Foreground refresh")
        let replacement = try token(owner: owner)
        let fixture = BoundAuthTransport.Response(data: try JSONSerialization.data(withJSONObject: [
            "access_token": replacement, "refresh_token": "synthetic-rotated-refresh", "user": ["id": owner.uuidString]
        ]), status: 200)
        let restored = BoundFriendAccount(storage: storage, automaticRefresh: false, configuration: { "fixture-key" }, transport: { request in
            XCTAssertEqual(request.url?.query, "grant_type=refresh_token")
            completed.fulfill()
            return fixture
        })
        XCTAssertEqual(restored.session?.owner, owner)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [completed], timeout: 2)
        await restored.refreshIfNeeded()
        XCTAssertNoThrow(try XCTUnwrap(restored.session).credentials())
        let persisted = try JSONDecoder().decode(BoundSavedSession.self, from: XCTUnwrap(storage.read()))
        XCTAssertEqual(persisted.refreshToken, "synthetic-rotated-refresh")
        restored.signOut()
    }

    func testPersistingExpiredRefreshSnapshotDoesNotPublishAccountReplacement() async throws {
        let owner = UUID()
        let storage = AccountFriendsMemoryStorage(try JSONEncoder().encode(BoundSavedSession(
            origin: BoundFriendAccount.origin, owner: owner,
            accessToken: try token(owner: owner, expires: 30), refreshToken: "synthetic-original-refresh")))
        var requests = 0
        let account = BoundFriendAccount(storage: storage, deletionStorage: AccountFriendsMemoryStorage(),
            automaticRefresh: false, configuration: { "fixture-key" }, transport: { request in
                requests += 1
                if requests == 2 { throw URLError(.notConnectedToInternet) }
                XCTAssertEqual(request.url?.query, requests == 1 ? "grant_type=refresh_token" : "grant_type=password")
                return BoundAuthTransport.Response(data: try JSONSerialization.data(withJSONObject: [
                    "access_token": self.token(owner: owner, expires: requests == 1 ? 0.5 : 3600),
                    "refresh_token": "synthetic-rotated-refresh", "user": ["id": owner.uuidString]
                ]), status: 200)
            })
        let original = try XCTUnwrap(account.session)
        var changes: [UUID?] = []
        let observer = NotificationCenter.default.addObserver(
            forName: BoundFriendAccount.sessionDidChangeNotification, object: nil, queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let source = notification.object as? BoundFriendAccount, source === account else { return }
                changes.append(source.session?.owner)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer); account.signOut() }

        storage.failWrites = true
        await account.refreshIfNeeded()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(original.isSameSession(as: account.session))
        XCTAssertTrue(changes.isEmpty)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertThrowsError(try original.credentials())
        XCTAssertFalse(original.isSameSession(as: account.session), "Authenticated guards must reject expired tokens")

        storage.failWrites = false
        await account.refreshIfNeeded()
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(account.session?.owner, owner)
        XCTAssertTrue(changes.isEmpty, "Persisting the same expired snapshot must not reset live multiplayer")
        XCTAssertThrowsError(try XCTUnwrap(account.session).friendSharingRequest(roomID: UUID().uuidString))
        XCTAssertEqual(try JSONDecoder().decode(BoundSavedSession.self, from: XCTUnwrap(storage.read())).refreshToken,
                       "synthetic-rotated-refresh")

        await account.signIn(email: "fixture@example.invalid", password: "synthetic-password")
        XCTAssertEqual(changes, [nil, owner], "An explicit sign-in must publish removal and a new session, even for the same owner")
        XCTAssertFalse(original.isSameSession(as: account.session))
        XCTAssertNoThrow(try XCTUnwrap(account.session).credentials())
        account.signOut()
        XCTAssertEqual(changes, [nil, owner, nil], "Explicit logout must still notify multiplayer")
    }
}

@MainActor
private final class OnboardingObservation: SharingCancellation {
    private let callback: @MainActor () -> Void
    private(set) var cancelled = false
    init(_ callback: @escaping @MainActor () -> Void) { self.callback = callback }
    func cancel() { cancelled = true }
    func fire() { callback() }
}

@MainActor
final class FriendModerationIntegrationTests: XCTestCase {
    private func identity() throws -> AppCloudSession {
        let owner = UUID()
        let claims = try JSONSerialization.data(withJSONObject: BoundAccountTestFixture.claims(owner: owner, expiry: Date().timeIntervalSince1970 + 3600))
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try AppCloudSession(owner: owner, key: "synthetic-public", token: "fixture.\(payload).signature")
    }
    func testBlockClearsSelectedSharingAndServerReceiptControlsListAndUnblock() async throws {
        let identity = try identity(), room = FriendRoom(roomID: UUID().uuidString, displayName: "Fixture Friend")
        let block = FriendBlock(blockID: UUID(), displayName: room.displayName)
        var calls: [(String, [String: String])] = []
        let model = FriendOnboarding(call: { _, action, payload in
            calls.append((action, payload))
            switch action {
            case "list": return .init(ok: true, rooms: [room], blocks: [])
            case "block": return .init(ok: true, blocks: [block])
            case "unblock": return .init(ok: true, blocks: [])
            default: throw BoundFriendError.unavailable
            }
        }, sendJiggle: { _, _ in
            XCTFail("Default selection must not send a Jiggle")
            return ""
        }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, authenticatedMode: true)
        model.open(sharing: sharing, existing: { identity })
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertEqual(model.rooms, [room]); model.select(room); XCTAssertNotNil(model.screenSelected)
        model.block(room)
        XCTAssertNil(model.screenSelected); XCTAssertFalse(sharing.active)
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertEqual(model.rooms, []); XCTAssertEqual(model.blocks, [block])
        XCTAssertTrue(calls.contains { $0.0 == "block" && $0.1 == ["roomID": room.roomID] })
        model.unblock(block)
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertEqual(model.blocks, []); XCTAssertNil(model.screenSelected); XCTAssertEqual(model.rooms, [])
        model.close()
    }
    func testReportUsesOnlyRoomAndCategoryAndDoesNotClaimReceiptOnDenial() async throws {
        let identity = try identity(), room = FriendRoom(roomID: UUID().uuidString, displayName: "Fixture Friend")
        var denied = false
        let model = FriendOnboarding(call: { _, action, payload in
            if action == "list" { return .init(ok: true, rooms: [room]) }
            XCTAssertEqual(action, "report"); XCTAssertEqual(payload, ["roomID": room.roomID, "reason": "harassment"])
            return denied ? .init(ok: false, error: "rate_limited") : .init(ok: true, reportID: UUID())
        }, sendJiggle: { _, _ in
            XCTFail("A default selection must not send a Jiggle")
            return ""
        }, observeAccount: { OnboardingObservation($0) })
        model.open(sharing: FriendSharingSession(configuration: nil, authenticatedMode: true), existing: { identity })
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        model.report(room, reason: .harassment)
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertEqual(model.message, "Report sent.")
        denied = true; model.report(room, reason: .harassment)
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertEqual(model.message, "Too many attempts. Try again later.")
        model.signOut(); XCTAssertEqual(model.blocks, []); XCTAssertEqual(model.rooms, [])
        model.close()
    }

    func testRemoveFriendStopsSelectedSharingAndOnlyRemovesAfterServerReceipt() async throws {
        let identity = try identity(), room = FriendRoom(roomID: UUID().uuidString, displayName: "Fixture Friend")
        var allowRemoval = false
        var calls: [(String, [String: String])] = []
        let model = FriendOnboarding(call: { _, action, payload in
            calls.append((action, payload))
            if action == "list" { return .init(ok: true, rooms: [room], username: "River") }
            XCTAssertEqual(action, "remove")
            XCTAssertEqual(payload, ["roomID": room.roomID])
            return .init(ok: allowRemoval)
        }, sendJiggle: { _, _ in
            XCTFail("A default selection must not send a Jiggle")
            return ""
        }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, authenticatedMode: true)
        model.open(sharing: sharing, existing: { identity })
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertEqual(model.accountUsername, "River")
        model.select(room)
        model.remove(room)
        XCTAssertNil(model.screenSelected)
        XCTAssertFalse(sharing.active)
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertEqual(model.rooms, [room], "A rejected remove must retain the friend")
        allowRemoval = true
        model.remove(room)
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertTrue(model.rooms.isEmpty)
        let before = calls.count
        model.remove(room)
        await Task.yield()
        XCTAssertEqual(calls.count, before, "A stale row cannot remove another room")
        model.close()
    }
}

@MainActor
final class FriendTapToShareIntegrationTests: XCTestCase {
    func testExpiredAccountDuringRefreshDoesNotRevokeExistingRoomButCannotSendFriendRequests() async throws {
        let previous = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(previous, forKey: BoundMultiplayerFeatures.key) }
        let owner = UUID(), identity = try makeIdentity(owner: owner, expires: 0.5)
        var current: AppCloudSession? = identity
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Friend")
        var friendRequests = 0
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true,
            tokenFetcher: { room, identity in self.makeLease(room: room, owner: identity.owner, request: 1) })
        let onboarding = FriendOnboarding(call: { _, _, _ in friendRequests += 1; return .init(ok: true, rooms: [room]) },
            observeAccount: { OnboardingObservation($0) })
        defer { onboarding.setMultiplayerServiceActive(false, sharing: sharing, existing: { current }); sharing.stop() }
        XCTAssertTrue(onboarding.selectMultiplayerPartner(roomID: room.roomID, sharing: sharing, existing: { current }))
        await waitUntil { sharing.joined }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertThrowsError(try identity.credentials())
        onboarding.synchronizeAccount()
        XCTAssertNil(onboarding.currentIdentity(), "Expired credentials cannot authorize a friend API request")
        let requests = friendRequests
        onboarding.refresh()
        XCTAssertEqual(friendRequests, requests)
        XCTAssertEqual(onboarding.selected?.roomID, room.roomID)
        XCTAssertEqual(sharing.authenticatedSession?()?.owner, owner)
        XCTAssertTrue(sharing.connectionRequested)
        current = nil; onboarding.synchronizeAccount()
        XCTAssertNil(onboarding.selected)
        XCTAssertFalse(sharing.connectionRequested, "Actual logout/revocation still closes the retained connection")
    }

    func testTemporaryROMServiceBackgroundKeepsInteractionAndAutomaticReconnectIntent() async throws {
        let previous = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(previous, forKey: BoundMultiplayerFeatures.key) }
        let identity = try makeIdentity(owner: UUID())
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Friend")
        var requests = 0
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true,
            tokenFetcher: { room, identity in
                requests += 1; return self.makeLease(room: room, owner: identity.owner, request: requests)
            })
        let onboarding = FriendOnboarding(call: { _, _, _ in .init(ok: true, rooms: [room]) },
            observeAccount: { OnboardingObservation($0) })
        defer { onboarding.setMultiplayerServiceActive(false, sharing: sharing, existing: { identity }); sharing.stop() }
        XCTAssertTrue(onboarding.selectMultiplayerPartner(roomID: room.roomID, sharing: sharing, existing: { identity }))
        await waitUntil { sharing.joined }
        let local = try JSONDecoder().decode(BoundFriendWorldPosition.self, from: Data(
            #"{"mapGroup":4,"mapNumber":1,"elevation":0,"x":6,"y":6,"facing":4}"#.utf8))
        let peer = try JSONDecoder().decode(BoundFriendWorldPosition.self, from: Data(
            #"{"mapGroup":4,"mapNumber":1,"elevation":0,"x":7,"y":6,"facing":3}"#.utf8))
        let context = BoundFriendInteractionSession.Context(localSession: UUID(), peerSession: UUID(), local: local, peer: peer)
        sharing.interactions.context = { context }
        XCTAssertTrue(sharing.interactions.open())
        sharing.background()
        onboarding.setMultiplayerServiceActive(false, sharing: sharing, existing: { identity }, temporary: true)
        onboarding.close()
        XCTAssertFalse(sharing.active)
        XCTAssertTrue(sharing.connectionRequested, "Backgrounding cannot revoke the ROM's retained connection")
        XCTAssertEqual(sharing.interactions.phase, .choosing)
        sharing.foreground()
        onboarding.setMultiplayerServiceActive(true, sharing: sharing, existing: { identity })
        await waitUntil { sharing.joined }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(sharing.interactions.phase, .choosing)
        XCTAssertTrue(sharing.interactions.connected)
        onboarding.setMultiplayerServiceActive(false, sharing: sharing, existing: { identity })
        XCTAssertFalse(sharing.connectionRequested, "Deliberate disable still clears the connection")
        XCTAssertEqual(sharing.interactions.phase, .choosing)
    }

    func testManualMultiplayerCanSwitchFriendsUntilCartridgeOwnsPartner() async throws {
        let previous = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(previous, forKey: BoundMultiplayerFeatures.key) }
        let identity = try makeIdentity(owner: UUID())
        let first = FriendRoom(roomID: UUID().uuidString, displayName: "First")
        let second = FriendRoom(roomID: UUID().uuidString, displayName: "Second")
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true,
            tokenFetcher: { room, identity in self.makeLease(room: room, owner: identity.owner, request: 1) })
        let onboarding = FriendOnboarding(call: { _, _, _ in .init(ok: true, rooms: [first, second]) },
            sendJiggle: { _, _ in XCTFail("Multiplayer must not send sharing notifications"); return "" },
            observeAccount: { OnboardingObservation($0) })
        defer { onboarding.close(); sharing.stop() }
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }
        onboarding.toggleMultiplayer(first)
        await waitUntil { sharing.joined }
        XCTAssertNil(onboarding.multiplayerPartnerRoomID, "A button is not a persisted run")
        onboarding.setMultiplayerPartner(roomID: nil)
        XCTAssertTrue(sharing.joined, "An idle cartridge cannot undo an explicit manual choice")
        onboarding.toggleMultiplayer(second)
        await waitUntil { sharing.joined && sharing.configuredRoomID == second.roomID }
        XCTAssertEqual(sharing.configuredRoomID, second.roomID)
        onboarding.setMultiplayerPartner(roomID: second.roomID, userInitiated: true)
        await waitUntil { sharing.joined }
        onboarding.disconnectMultiplayer()
        onboarding.toggleMultiplayer(first)
        XCTAssertFalse(sharing.connectionRequested)
        XCTAssertEqual(onboarding.multiplayerPartnerRoomID, second.roomID)
        onboarding.toggleMultiplayer(second)
        await waitUntil { sharing.joined }
        XCTAssertEqual(sharing.configuredRoomID, second.roomID)
    }

    func testFriendRowHighlightsOnlyConnectedPeerAndStopRemovesItsBadge() async throws {
        let identity = try makeIdentity(owner: UUID())
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Friend")
        let otherRoom = UUID().uuidString
        let transport = FriendTapSharingTransport()
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, session in self.makeLease(room: room, owner: session.owner, request: 1) })
        let onboarding = FriendOnboarding(call: { _, _, _ in .init(ok: true, rooms: [room]) },
            sendJiggle: { _, _ in "" }, observeAccount: { OnboardingObservation($0) })
        func row(_ roomID: String? = nil) -> BoundFriendRowConnection {
            .init(roomID: roomID ?? room.roomID, selectedRoomID: onboarding.screenSelected?.roomID, sharing: sharing)
        }
        defer { onboarding.close(); sharing.stop() }
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }
        onboarding.select(room)
        XCTAssertEqual(row(), .inactive, "Remembering a friend does not highlight their row")
        XCTAssertEqual(row().title, "Disconnected", "An idle row has no Not sharing badge")
        onboarding.select(room, startSharing: true)
        await waitUntil { sharing.joined }
        XCTAssertTrue(sharing.joined)
        XCTAssertEqual(row(), .disconnected, "Joining locally is not proof that both friends are connected")
        XCTAssertEqual(row(otherRoom), .inactive)
        transport.emit(.remoteJoined)
        XCTAssertTrue(sharing.peerConnected)
        XCTAssertFalse(sharing.remoteVisible, "A connection does not require decoded video")
        XCTAssertEqual(row(), .connected)
        XCTAssertEqual(row().title, "Connected")
        sharing.stop()
        XCTAssertNotNil(onboarding.screenSelected, "A cached row may remain after a transport stops")
        XCTAssertEqual(row(), .inactive, "A stopped selection loses its purple box and badge")
        XCTAssertEqual(row().title, "Disconnected")
        onboarding.select(room, startSharing: true)
        await waitUntil { sharing.joined }
        transport.emit(.remoteJoined)
        XCTAssertEqual(row(), .connected)
        transport.emit(.remoteGone)
        XCTAssertEqual(row(), .disconnected)
        transport.emit(.remoteJoined)
        XCTAssertEqual(row(), .connected)
        transport.emit(.reconnecting)
        XCTAssertEqual(row(), .connecting, "Reconnection clears the connected highlight")
        transport.emit(.remoteJoined)
        XCTAssertFalse(sharing.peerConnected, "A peer event cannot bypass local recovery")
        transport.emit(.rejoined)
        transport.emit(.remoteJoined)
        XCTAssertEqual(row(), .connected)
        onboarding.disconnect()
        XCTAssertEqual(row(), .inactive)
        XCTAssertEqual(row().title, "Disconnected")
        XCTAssertFalse(sharing.connectionRequested)
        XCTAssertFalse(sharing.peerConnected)
        XCTAssertFalse(sharing.active)
        transport.emit(.remoteJoined)
        XCTAssertFalse(sharing.peerConnected, "A late callback cannot restore a stopped highlight")
        XCTAssertEqual(row(), .inactive)
    }

    func testStopDuringROMConnectionRetryClearsRowAndCancelsRetry() async throws {
        let previous = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer {
            UserDefaults.standard.set(previous, forKey: BoundMultiplayerFeatures.key)
            NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
        }
        let identity = try makeIdentity(owner: UUID())
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Friend")
        var requests = 0
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true,
            tokenFetcher: { _, _ in requests += 1; throw FriendSharingTokenError.unavailable })
        let onboarding = FriendOnboarding(call: { _, _, _ in .init(ok: true, rooms: [room]) },
            observeAccount: { OnboardingObservation($0) })
        defer { onboarding.setMultiplayerServiceActive(false, sharing: sharing, existing: { identity }); sharing.stop() }
        XCTAssertTrue(onboarding.selectMultiplayerPartner(roomID: room.roomID, sharing: sharing, existing: { identity }))
        await waitUntil { requests == 1 && !sharing.active }
        let pending = BoundFriendRowConnection(roomID: room.roomID, selectedRoomID: onboarding.selected?.roomID, sharing: sharing)
        XCTAssertEqual(pending, .failed, "Stop remains available during retry backoff")
        XCTAssertTrue(sharing.connectionRequested)
        onboarding.disconnect()
        for _ in 0..<3 { onboarding.setMultiplayerPartner(roomID: room.roomID) }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(requests, 1, "Stop cancels the scheduled retry and suppresses ROM demand")
        XCTAssertFalse(sharing.connectionRequested)
        XCTAssertEqual(BoundFriendRowConnection(roomID: room.roomID,
            selectedRoomID: onboarding.selected?.roomID, sharing: sharing), .inactive)
    }

    func testROMChoiceBootstrapsServiceAndWaitsForAuthorizedFriendList() async throws {
        let previous = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer {
            UserDefaults.standard.set(previous, forKey: BoundMultiplayerFeatures.key)
            NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
        }
        let identity = try makeIdentity(owner: UUID())
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Selected in ROM")
        var pending: CheckedContinuation<FriendResponse, Never>?
        var requestedRooms: [String] = []
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true,
            tokenFetcher: { room, session in
                requestedRooms.append(room)
                return self.makeLease(room: room, owner: session.owner, request: requestedRooms.count)
            })
        let onboarding = FriendOnboarding(call: { _, action, _ in
            XCTAssertEqual(action, "list")
            return await withCheckedContinuation { pending = $0 }
        }, sendJiggle: { _, _ in XCTFail("ROM choices do not send notifications"); return "" },
            observeAccount: { OnboardingObservation($0) })
        defer { onboarding.setMultiplayerServiceActive(false, sharing: sharing, existing: { identity }); sharing.stop() }
        XCTAssertTrue(onboarding.selectMultiplayerPartner(roomID: room.roomID, sharing: sharing, existing: { identity }))
        await waitUntil { pending != nil }
        XCTAssertTrue(requestedRooms.isEmpty, "An uncached selection waits for server authorization")
        pending?.resume(returning: .init(ok: true, rooms: [room])); pending = nil
        await waitUntil { sharing.joined }
        XCTAssertTrue(sharing.joined, "No Friends open or Connect action is needed")
        XCTAssertEqual(requestedRooms, [room.roomID])

        sharing.configureAuthenticatedRoom(nil, identity: { identity })
        XCTAssertFalse(sharing.active)
        XCTAssertTrue(onboarding.selectMultiplayerPartner(roomID: room.roomID, sharing: sharing, existing: { identity }))
        await waitUntil { sharing.joined }
        XCTAssertTrue(sharing.joined, "A cached Friends row must not hide a missing transport configuration")
        XCTAssertEqual(requestedRooms.count, 2)
        onboarding.setMultiplayerPartner(roomID: nil)
        XCTAssertFalse(sharing.active, "Cancelling native setup releases its automatic connection")
    }

    func testCancelledROMChoiceCannotReconnectWhenFriendListArrives() async throws {
        let previous = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer {
            UserDefaults.standard.set(previous, forKey: BoundMultiplayerFeatures.key)
            NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
        }
        let identity = try makeIdentity(owner: UUID())
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Friend")
        var pending: CheckedContinuation<FriendResponse, Never>?
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true,
            tokenFetcher: { _, _ in XCTFail("Cancelled or unlisted choices cannot connect"); throw FriendSharingTokenError.unavailable })
        let onboarding = FriendOnboarding(call: { _, _, _ in
            await withCheckedContinuation { pending = $0 }
        }, observeAccount: { OnboardingObservation($0) })
        defer { onboarding.setMultiplayerServiceActive(false, sharing: sharing, existing: { identity }); sharing.stop() }
        XCTAssertFalse(onboarding.selectMultiplayerPartner(roomID: room.roomID, sharing: sharing, existing: { nil }))
        XCTAssertFalse(onboarding.selectMultiplayerPartner(roomID: "invalid", sharing: sharing, existing: { identity }))
        XCTAssertTrue(onboarding.selectMultiplayerPartner(roomID: room.roomID, sharing: sharing, existing: { identity }))
        await waitUntil { pending != nil }
        onboarding.setMultiplayerPartner(roomID: nil)
        pending?.resume(returning: .init(ok: true, rooms: [room])); pending = nil
        await waitUntil { !onboarding.busy }
        XCTAssertFalse(sharing.active)
        XCTAssertNil(onboarding.multiplayerPartnerRoomID)
        XCTAssertTrue(onboarding.selectMultiplayerPartner(roomID: UUID().uuidString, sharing: sharing, existing: { identity }))
        await settle()
        XCTAssertFalse(sharing.active, "An arbitrary UUID never authorizes a friend connection")
    }

    func testROMPartnerConnectsWithoutOpeningFriendsOrSendingJiggleAndStopsOnOwnerChange() async throws {
        let previous = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer {
            UserDefaults.standard.set(previous, forKey: BoundMultiplayerFeatures.key)
            NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
        }
        var identity: AppCloudSession? = try makeIdentity(owner: UUID())
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "ROM Friend")
        let transport = FriendTapSharingTransport()
        var requests = 0
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            tokenFetcher: { room, session in
                requests += 1
                return self.makeLease(room: room, owner: session.owner, request: requests)
            })
        var observation: OnboardingObservation?
        let onboarding = FriendOnboarding(call: { _, action, _ in
            XCTAssertEqual(action, "list")
            return FriendResponse(ok: true, rooms: [room])
        }, sendJiggle: { _, _ in XCTFail("ROM connection must not send a Jiggle"); return "" },
            observeAccount: { observation = OnboardingObservation($0); return observation! })
        onboarding.setMultiplayerServiceActive(true, sharing: sharing, existing: { identity })
        onboarding.setMultiplayerPartner(roomID: UUID().uuidString)
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(requests, 0, "An unlisted room cannot obtain a transport lease")
        onboarding.setMultiplayerPartner(roomID: room.roomID)
        await waitUntil { sharing.joined }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(sharing.connectedRoomID, room.roomID)
        XCTAssertTrue(sharing.livePresence.enabled)
        XCTAssertTrue(sharing.livePresence.connected)
        onboarding.close()
        XCTAssertFalse(try XCTUnwrap(observation).cancelled, "Closing Friends cannot stop ROM services")
        observation?.fire()
        XCTAssertEqual(requests, 1, "Observation cannot restart a joined partner")
        identity = try makeIdentity(owner: UUID())
        observation?.fire()
        await waitUntil { !onboarding.busy }
        XCTAssertFalse(sharing.active)
        XCTAssertNil(onboarding.multiplayerPartnerRoomID)
        XCTAssertEqual(requests, 1, "A different account cannot inherit the run's partner")
        onboarding.setMultiplayerServiceActive(false, sharing: sharing, existing: { identity })
        XCTAssertTrue(try XCTUnwrap(observation).cancelled)
        sharing.stop()
    }

    func testROMFriendsRefreshWaitsForNewlyAddedFriendAndCoalescesPendingList() async throws {
        let identity = try makeIdentity(owner: UUID())
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Added After Launch")
        var requests = 0
        var pending: CheckedContinuation<FriendResponse, Never>?
        let onboarding = FriendOnboarding(call: { _, action, _ in
            XCTAssertEqual(action, "list"); requests += 1
            return await withCheckedContinuation { pending = $0 }
        }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true)
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { pending != nil }
        let refresh = BoundROMFriendsRefresh()
        refresh.begin(requestID: 7, onboarding: onboarding)
        refresh.begin(requestID: 8, onboarding: onboarding)
        var host = BoundROMHostState()
        host.status = .timeline; host.acknowledgedRequest = 6
        host.friends = [.init(room: UUID(), name: "Old timeline row")]
        refresh.apply(to: &host, onboarding: onboarding)
        XCTAssertEqual(requests, 1, "The ROM reuses an initial list request still in flight")
        XCTAssertEqual(host.status, .waiting)
        XCTAssertEqual(host.acknowledgedRequest, 6, "Network completion, not command receipt, acknowledges the request")
        XCTAssertTrue(host.friends.isEmpty, "Timeline rows must never appear as friends")
        pending?.resume(returning: .init(ok: true, rooms: [room])); pending = nil
        await waitUntil { !onboarding.busy }
        refresh.apply(to: &host, onboarding: onboarding)
        XCTAssertEqual(host.status, .complete)
        XCTAssertEqual(host.acknowledgedRequest, 8)
        XCTAssertEqual(host.friends, [.init(room: try XCTUnwrap(UUID(uuidString: room.roomID)), name: room.displayName)])
        XCTAssertEqual(requests, 1)
        let acknowledged = BoundROMRequest(sequence: 2, command: .none, friendIndex: 0,
            argument: 0, identifier: UUID(), settings: Data(repeating: 0, count: 32),
            flags: 0, frame: 1, requestID: 8)
        refresh.retireIfAcknowledged(acknowledged)
        host.status = .accepted; host.message = "New setup status"
        refresh.apply(to: &host, onboarding: onboarding)
        XCTAssertEqual(host.status, .accepted, "Once the ROM consumes the acknowledgement, refresh cannot mask later status")
        XCTAssertEqual(host.message, "New setup status")
        onboarding.close(); sharing.stop()
    }

    func testROMFriendsRefreshFailurePreservesRowsAndRetryCommitsNewList() async throws {
        let identity = try makeIdentity(owner: UUID())
        let first = FriendRoom(roomID: UUID().uuidString, displayName: "First")
        let added = FriendRoom(roomID: UUID().uuidString, displayName: "Added")
        var response = FriendResponse(ok: true, rooms: [first])
        let onboarding = FriendOnboarding(call: { _, _, _ in response }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true)
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }
        onboarding.select(first)
        let refresh = BoundROMFriendsRefresh()
        var host = BoundROMHostState()
        response = .init(ok: false, error: "rate_limited")
        refresh.begin(requestID: 1, onboarding: onboarding)
        await waitUntil { !onboarding.busy }
        refresh.apply(to: &host, onboarding: onboarding)
        XCTAssertEqual(host.status, .unavailable)
        XCTAssertEqual(host.acknowledgedRequest, 1)
        XCTAssertEqual(host.friends.map(\.name), ["First"])
        XCTAssertTrue(host.message.contains("Refresh"))
        XCTAssertEqual(onboarding.screenSelected, first)
        response = .init(ok: true, rooms: [added])
        refresh.begin(requestID: 2, onboarding: onboarding)
        await waitUntil { !onboarding.busy }
        refresh.apply(to: &host, onboarding: onboarding)
        XCTAssertEqual(host.status, .complete)
        XCTAssertEqual(host.friends.map(\.name), ["Added"])
        XCTAssertNil(onboarding.selected, "A removed selected room cannot retain its old connection authority")
        XCTAssertFalse(sharing.active)
        onboarding.close(); sharing.stop()
    }

    func testROMFriendsRefreshCancelledByCloseOrOwnerChangeCannotPublishStaleRows() async throws {
        var identity: AppCloudSession? = try makeIdentity(owner: UUID())
        let oldRoom = FriendRoom(roomID: UUID().uuidString, displayName: "Old Account Friend")
        var pending: CheckedContinuation<FriendResponse, Never>?
        let onboarding = FriendOnboarding(call: { _, _, _ in
            await withCheckedContinuation { pending = $0 }
        }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true)
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { pending != nil }
        let refresh = BoundROMFriendsRefresh()
        refresh.begin(requestID: 3, onboarding: onboarding)
        onboarding.close()
        var host = BoundROMHostState()
        refresh.apply(to: &host, onboarding: onboarding)
        XCTAssertEqual(host.status, .unavailable)
        XCTAssertEqual(host.acknowledgedRequest, 3)
        pending?.resume(returning: .init(ok: true, rooms: [oldRoom])); pending = nil
        await settle()
        XCTAssertTrue(onboarding.rooms.isEmpty)

        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { pending != nil }
        refresh.begin(requestID: 4, onboarding: onboarding)
        identity = nil; onboarding.synchronizeAccount()
        pending?.resume(returning: .init(ok: true, rooms: [oldRoom])); pending = nil
        await settle()
        refresh.apply(to: &host, onboarding: onboarding)
        XCTAssertEqual(host.status, .unavailable)
        XCTAssertEqual(host.acknowledgedRequest, 4)
        XCTAssertTrue(host.friends.isEmpty)
        refresh.reset()
        host.status = .timeline; host.acknowledgedRequest = 5
        refresh.apply(to: &host, onboarding: onboarding)
        XCTAssertEqual(host.status, .timeline, "An abandoned refresh cannot repaint a newer menu")
        XCTAssertEqual(host.acknowledgedRequest, 5)
        onboarding.close(); sharing.stop()
    }

    func testROMRefreshDuringMutationOrServiceCancellationAlwaysAllowsRetry() async throws {
        let identity = try makeIdentity(owner: UUID())
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Added")
        var pending: CheckedContinuation<FriendResponse, Never>?
        let onboarding = FriendOnboarding(call: { _, action, _ in
            if action == "list" { return .init(ok: true, rooms: []) }
            return await withCheckedContinuation { pending = $0 }
        }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true)
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }
        onboarding.add(username: "Added")
        await waitUntil { pending != nil }
        let refresh = BoundROMFriendsRefresh()
        refresh.begin(requestID: 10, onboarding: onboarding)
        var host = BoundROMHostState()
        refresh.apply(to: &host, onboarding: onboarding)
        XCTAssertEqual(host.status, .unavailable, "An Add response is not a fetched list")
        XCTAssertEqual(host.acknowledgedRequest, 10)
        pending?.resume(returning: .init(ok: true, room: room)); pending = nil
        await waitUntil { !onboarding.busy }
        refresh.begin(requestID: 11, onboarding: onboarding)
        refresh.cancel()
        await waitUntil { !onboarding.busy }
        refresh.apply(to: &host, onboarding: onboarding)
        XCTAssertEqual(host.status, .unavailable, "A cancelled service must not restore a stale success")
        XCTAssertEqual(host.acknowledgedRequest, 11)
        refresh.begin(requestID: 12, onboarding: onboarding)
        await waitUntil { !onboarding.busy }
        refresh.apply(to: &host, onboarding: onboarding)
        XCTAssertEqual(host.status, .complete)
        XCTAssertEqual(host.acknowledgedRequest, 12)
        onboarding.close(); sharing.stop()
    }

    func testExplicitDisconnectSurvivesROMTicksRefreshAndForegroundUntilFriendTap() async throws {
        try await assertExplicitDisconnectSurvivesRestoration(useMacSidebar: false)
    }

    func testMacSidebarDisconnectSurvivesROMTicksRefreshAndForegroundUntilFriendTap() async throws {
        try await assertExplicitDisconnectSurvivesRestoration(useMacSidebar: true)
    }

    func testMacSidebarCanCancelAutomaticReconnectDuringRetryDelay() async throws {
        try await assertExplicitDisconnectSurvivesRestoration(useMacSidebar: true, duringRetry: true)
    }

    private func assertExplicitDisconnectSurvivesRestoration(useMacSidebar: Bool, duringRetry: Bool = false) async throws {
        let previous = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer {
            UserDefaults.standard.set(previous, forKey: BoundMultiplayerFeatures.key)
            NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
        }
        let identity = try makeIdentity(owner: UUID())
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Friend")
        let transport = FriendTapSharingTransport()
        var requests = 0
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            tokenFetcher: { room, identity in
                requests += 1
                return self.makeLease(room: room, owner: identity.owner, request: requests)
            })
        var observation: OnboardingObservation?
        let onboarding = FriendOnboarding(call: { _, _, _ in FriendResponse(ok: true, rooms: [room]) },
            sendJiggle: { _, _ in "" }, observeAccount: { observation = OnboardingObservation($0); return observation! })
        onboarding.setMultiplayerServiceActive(true, sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }
        onboarding.setMultiplayerPartner(roomID: room.roomID)
        await waitUntil { sharing.joined }
        if duringRetry {
            transport.emit(.failed(.init(.connectionLost)))
            XCTAssertFalse(sharing.active); XCTAssertFalse(sharing.joined)
            XCTAssertTrue(sharing.connectionRequested, "The retry delay still belongs to the selected connection")
        }
        if useMacSidebar { onboarding.toggleMultiplayer(room) }
        else { onboarding.disconnect() }
        XCTAssertFalse(sharing.active)
        XCTAssertFalse(sharing.joined)
        XCTAssertFalse(sharing.connectionRequested)
        XCTAssertNil(sharing.connectedRoomID)
        XCTAssertEqual(onboarding.selected?.roomID, room.roomID)
        for _ in 0..<5 { onboarding.setMultiplayerPartner(roomID: room.roomID); observation?.fire() }
        sharing.background(); sharing.foreground()
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }
        await settle()
        if duringRetry { try await Task.sleep(for: .milliseconds(1200)) }
        XCTAssertEqual(requests, 1, "Manual Stop must block background reconnection")
        XCTAssertEqual(onboarding.selected?.roomID, room.roomID, "Manual disconnect retains the gameplay partner")
        onboarding.toggleMultiplayer(room)
        await waitUntil { sharing.joined }
        XCTAssertEqual(requests, 2)
        onboarding.disconnect()
        onboarding.setMultiplayerPartner(roomID: room.roomID, userInitiated: true)
        await waitUntil { sharing.joined }
        XCTAssertEqual(requests, 3, "An explicit ROM friend choice also reconnects")
        onboarding.disconnect()
        onboarding.close()
        onboarding.setMultiplayerServiceActive(false, sharing: sharing, existing: { identity })
    }

    func testDisablingROMServicesPreservesExplicitOrdinaryVideoSharing() async throws {
        let previous = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
        defer {
            UserDefaults.standard.set(previous, forKey: BoundMultiplayerFeatures.key)
            NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
        }
        let identity = try makeIdentity(owner: UUID())
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Video Friend")
        let video = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, identity in self.makeLease(room: room, owner: identity.owner, request: 1) })
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true,
            tokenFetcher: { room, identity in self.makeLease(room: room, owner: identity.owner, request: 1) }, screenSession: video)
        let onboarding = FriendOnboarding(call: { _, _, _ in FriendResponse(ok: true, rooms: [room]) },
            sendJiggle: { _, _ in "" }, observeAccount: { OnboardingObservation($0) })
        onboarding.setMultiplayerServiceActive(true, sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }
        onboarding.setMultiplayerPartner(roomID: room.roomID)
        await waitUntil { sharing.joined }
        onboarding.select(room, startSharing: true)
        await waitUntil { video.joined }
        BoundMultiplayerFeatures.setEnabled(false)
        onboarding.setMultiplayerServiceActive(false, sharing: sharing, existing: { identity })
        XCTAssertTrue(video.joined, "Explicit friend video remains available when multiplayer is disabled")
        XCTAssertFalse(sharing.livePresence.connected)
        XCTAssertFalse(sharing.interactions.connected)
        sharing.stop(); onboarding.close()
    }

    func testFriendTapStartsOnceSwitchesRoomsAndCanRetryAfterStop() async throws {
        let owner = UUID()
        let identity = try makeIdentity(owner: owner)
        let first = FriendRoom(roomID: UUID().uuidString, displayName: "First Friend")
        let second = FriendRoom(roomID: UUID().uuidString, displayName: "Second Friend")
        let transport = FriendTapSharingTransport()
        var requestedRooms: [String] = []
        var jiggleRooms: [String] = []
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, session in
                requestedRooms.append(room)
                return self.makeLease(room: room, owner: session.owner, request: requestedRooms.count)
            })
        let onboarding = FriendOnboarding(call: { _, action, _ in
            action == "list" ? FriendResponse(ok: true, rooms: [first, second]) : FriendResponse(ok: false)
        }, sendJiggle: { room, _ in
            jiggleRooms.append(room.roomID)
            return "Jiggle sent."
        }, observeAccount: { OnboardingObservation($0) })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }

        onboarding.select(first, startSharing: true)
        await waitUntil { transport.configurations.count == 1 }
        XCTAssertEqual(requestedRooms, [first.roomID])
        XCTAssertEqual(transport.configurations.first?.channel, "friend-tap-1")
        XCTAssertTrue(sharing.active)
        await waitUntil { jiggleRooms.count == 1 }
        XCTAssertEqual(jiggleRooms, [first.roomID], "Starting a share from a friend tap sends one Jiggle")

        onboarding.select(first, startSharing: true)
        await settle()
        XCTAssertEqual(requestedRooms.count, 1, "Tapping the active selected friend must not restart sharing")
        XCTAssertEqual(transport.configurations.count, 1)
        XCTAssertEqual(jiggleRooms, [first.roomID], "Repeated taps on the active friend must not send another Jiggle")

        onboarding.select(second, startSharing: true)
        await waitUntil { transport.configurations.count == 2 }
        XCTAssertEqual(requestedRooms, [first.roomID, second.roomID])
        XCTAssertEqual(transport.configurations.last?.channel, "friend-tap-2")
        XCTAssertEqual(onboarding.screenSelected, second)
        await waitUntil { jiggleRooms.count == 2 }
        XCTAssertEqual(jiggleRooms, [first.roomID, second.roomID])

        sharing.stop()
        XCTAssertFalse(sharing.active)
        onboarding.select(second, startSharing: true)
        await waitUntil { transport.configurations.count == 3 }
        XCTAssertEqual(requestedRooms, [first.roomID, second.roomID, second.roomID], "A stopped session can be retried from the selected friend")
        XCTAssertTrue(sharing.active)
        await waitUntil { jiggleRooms.count == 3 }
        XCTAssertEqual(jiggleRooms, [first.roomID, second.roomID, second.roomID], "A new share after stopping sends one new Jiggle")
        onboarding.close()
        sharing.stop()
    }

    func testSelectionWithoutExplicitShareTapNeverAutostarts() async throws {
        let owner = UUID()
        let identity = try makeIdentity(owner: owner)
        let friend = FriendRoom(roomID: UUID().uuidString, displayName: "Fixture Friend")
        let transport = FriendTapSharingTransport()
        var tokenRequests = 0
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, session in
                tokenRequests += 1
                return self.makeLease(room: room, owner: session.owner, request: tokenRequests)
            })
        let onboarding = FriendOnboarding(call: { _, action, _ in
            action == "list" ? FriendResponse(ok: true, rooms: [friend]) : FriendResponse(ok: false)
        }, sendJiggle: { _, _ in
            XCTFail("Selection without the explicit share action must not send a Jiggle")
            return ""
        }, observeAccount: { OnboardingObservation($0) })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }

        onboarding.select(friend)
        await settle()
        XCTAssertEqual(onboarding.screenSelected, friend, "Selection remains available without starting sharing")
        XCTAssertFalse(sharing.active)
        XCTAssertEqual(tokenRequests, 0)
        XCTAssertTrue(transport.configurations.isEmpty)
        onboarding.close()
    }

    func testInvalidUnlistedBusyAndSignedOutSelectionCannotStartAndAcceptedInviteStaysIdle() async throws {
        let owner = UUID()
        var identity: AppCloudSession? = try makeIdentity(owner: owner)
        let friend = FriendRoom(roomID: UUID().uuidString, displayName: "Listed Friend")
        let accepted = FriendRoom(roomID: UUID().uuidString, displayName: "Invited Friend")
        let unlisted = FriendRoom(roomID: UUID().uuidString, displayName: "Unlisted Friend")
        let invalid = FriendRoom(roomID: "not-a-room", displayName: "Invalid Friend")
        let transport = FriendTapSharingTransport()
        var tokenRequests = 0
        var holdReport = false
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, session in
                tokenRequests += 1
                return self.makeLease(room: room, owner: session.owner, request: tokenRequests)
            })
        let onboarding = FriendOnboarding(call: { _, action, _ in
            switch action {
            case "list": return FriendResponse(ok: true, rooms: [friend])
            case "accept": return FriendResponse(ok: true, room: accepted)
            case "report":
                if holdReport { try? await Task.sleep(nanoseconds: 150_000_000) }
                return FriendResponse(ok: true, reportID: UUID())
            default: return FriendResponse(ok: false)
            }
        }, sendJiggle: { _, _ in
            XCTFail("Invalid, busy, or signed-out selection must not send a Jiggle")
            return ""
        }, observeAccount: { OnboardingObservation($0) })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }

        onboarding.select(invalid, startSharing: true)
        onboarding.select(unlisted, startSharing: true)
        XCTAssertNil(onboarding.screenSelected)
        XCTAssertEqual(tokenRequests, 0)
        XCTAssertTrue(transport.configurations.isEmpty)

        holdReport = true
        onboarding.report(friend, reason: .other)
        XCTAssertTrue(onboarding.busy)
        onboarding.select(friend, startSharing: true)
        XCTAssertNil(onboarding.screenSelected)
        XCTAssertEqual(tokenRequests, 0, "A busy onboarding action blocks tap-to-share")
        await waitUntil { !onboarding.busy }

        identity = nil
        onboarding.synchronizeAccount()
        onboarding.select(friend, startSharing: true)
        XCTAssertNil(onboarding.screenSelected)
        XCTAssertEqual(tokenRequests, 0, "A signed-out account cannot start sharing")
        identity = try makeIdentity(owner: owner)
        onboarding.synchronizeAccount()
        await waitUntil { !onboarding.busy }

        onboarding.accept(code: "0123456789ABCDEF", name: "Invited Friend")
        await waitUntil { !onboarding.busy && onboarding.screenSelected == accepted }
        XCTAssertEqual(onboarding.screenSelected, accepted)
        XCTAssertFalse(sharing.active)
        XCTAssertEqual(tokenRequests, 0, "Accepting an invitation selects the room without starting a share")
        XCTAssertTrue(transport.configurations.isEmpty)
        onboarding.close()
    }

    func testPendingJiggleIsCanceledOnNewSelection() async throws {
        let identity = try makeIdentity(owner: UUID())
        let first = FriendRoom(roomID: UUID().uuidString, displayName: "First Friend")
        let second = FriendRoom(roomID: UUID().uuidString, displayName: "Second Friend")
        let transport = FriendTapSharingTransport()
        var tokenRequests = 0
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, session in
                tokenRequests += 1
                return self.makeLease(room: room, owner: session.owner, request: tokenRequests)
            })
        var startedJiggles: [String] = []
        var completedJiggles: [String] = []
        var canceledJiggles: [String] = []
        let onboarding = FriendOnboarding(call: { _, action, _ in
            action == "list" ? FriendResponse(ok: true, rooms: [first, second]) : FriendResponse(ok: false)
        }, sendJiggle: { room, _ in
            startedJiggles.append(room.roomID)
            if room == first {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    completedJiggles.append(room.roomID)
                    return "Jiggle sent."
                } catch {
                    canceledJiggles.append(room.roomID)
                    throw error
                }
            }
            completedJiggles.append(room.roomID)
            return "Jiggle sent."
        }, observeAccount: { OnboardingObservation($0) })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }

        onboarding.select(first, startSharing: true)
        await waitUntil { sharing.active && startedJiggles == [first.roomID] }
        XCTAssertTrue(sharing.active, "Sharing begins without waiting for the notification to finish")
        onboarding.select(second, startSharing: true)
        await waitUntil { sharing.active && canceledJiggles == [first.roomID] && completedJiggles == [second.roomID] }
        XCTAssertEqual(startedJiggles, [first.roomID, second.roomID])
        XCTAssertEqual(canceledJiggles, [first.roomID], "Changing friends cancels the pending notification for the old selection")
        XCTAssertEqual(completedJiggles, [second.roomID])
        XCTAssertTrue(sharing.active, "A canceled notification must not interrupt the new share")
        onboarding.close()
        sharing.stop()
    }

    func testPendingJiggleIsCanceledAcrossAccountSwitchAndSignOut() async throws {
        let firstOwner = UUID(), secondOwner = UUID()
        var identity: AppCloudSession? = try makeIdentity(owner: firstOwner)
        let friend = FriendRoom(roomID: UUID().uuidString, displayName: "Fixture Friend")
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, session in
                self.makeLease(room: room, owner: session.owner, request: 1)
            })
        var jiggleStarts = 0
        var canceledJiggles = 0
        let onboarding = FriendOnboarding(call: { _, action, _ in
            action == "list" ? FriendResponse(ok: true, rooms: [friend]) : FriendResponse(ok: false)
        }, sendJiggle: { _, _ in
            jiggleStarts += 1
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "Jiggle sent."
            } catch {
                canceledJiggles += 1
                throw error
            }
        }, observeAccount: { OnboardingObservation($0) })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }

        onboarding.select(friend, startSharing: true)
        await waitUntil { sharing.active && jiggleStarts == 1 }
        identity = try makeIdentity(owner: secondOwner)
        onboarding.synchronizeAccount()
        await waitUntil { canceledJiggles == 1 && !onboarding.busy }
        XCTAssertEqual(canceledJiggles, 1, "An account switch cancels the old account's notification")
        XCTAssertFalse(sharing.active, "Changing accounts must stop the previous account's share")
        XCTAssertNil(onboarding.screenSelected)
        XCTAssertNotEqual(onboarding.message, "Jiggle sent.", "The previous account's pending result must not replace the new account state")
        XCTAssertEqual(jiggleStarts, 1, "Account synchronization must not resend a pending Jiggle")

        onboarding.select(friend, startSharing: true)
        await waitUntil { sharing.active && jiggleStarts == 2 }
        identity = nil
        onboarding.signOut()
        await waitUntil { canceledJiggles == 2 }
        XCTAssertEqual(canceledJiggles, 2, "Signing out cancels the current account's notification")
        let signedOutMessage = onboarding.message
        await settle()
        XCTAssertEqual(onboarding.message, signedOutMessage, "A canceled notification must not overwrite the signed-out state")
        XCTAssertEqual(onboarding.message, "Sign in above to add a friend.")
        XCTAssertEqual(jiggleStarts, 2, "Signing out must not retry or resend the canceled Jiggle")
        XCTAssertFalse(sharing.active)
        onboarding.close()
    }

    func testStoppingShareCancelsPendingJiggleWithoutStaleMessage() async throws {
        let identity = try makeIdentity(owner: UUID())
        let friend = FriendRoom(roomID: UUID().uuidString, displayName: "Fixture Friend")
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, session in
                self.makeLease(room: room, owner: session.owner, request: 1)
            })
        var jiggleStarts = 0
        var canceledJiggles = 0
        let onboarding = FriendOnboarding(call: { _, action, _ in
            action == "list" ? FriendResponse(ok: true, rooms: [friend]) : FriendResponse(ok: false)
        }, sendJiggle: { _, _ in
            jiggleStarts += 1
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "Jiggle sent."
            } catch {
                canceledJiggles += 1
                throw error
            }
        }, observeAccount: { OnboardingObservation($0) })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }

        onboarding.select(friend, startSharing: true)
        await waitUntil { sharing.active && jiggleStarts == 1 }
        onboarding.close()
        sharing.stop()
        await waitUntil { canceledJiggles == 1 && !onboarding.busy }
        XCTAssertEqual(canceledJiggles, 1, "Stopping a share cancels the in-flight notification")
        XCTAssertEqual(jiggleStarts, 1)
        XCTAssertNotEqual(onboarding.message, "Jiggle sent.", "A canceled Jiggle must not publish a stale success")
        sharing.stop()
    }

    func testRefreshAndForegroundShareReconnectDoNotResendJiggle() async throws {
        let identity = try makeIdentity(owner: UUID())
        let friend = FriendRoom(roomID: UUID().uuidString, displayName: "Fixture Friend")
        let transport = FriendTapSharingTransport()
        var tokenRequests = 0
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, session in
                tokenRequests += 1
                return self.makeLease(room: room, owner: session.owner, request: tokenRequests)
            })
        var jiggleRooms: [String] = []
        var observation: OnboardingObservation?
        let onboarding = FriendOnboarding(call: { _, action, _ in
            action == "list" ? FriendResponse(ok: true, rooms: [friend]) : FriendResponse(ok: false)
        }, sendJiggle: { room, _ in
            jiggleRooms.append(room.roomID)
            return "Jiggle sent."
        }, observeAccount: { callback in
            let value = OnboardingObservation(callback)
            observation = value
            return value
        })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }

        onboarding.select(friend, startSharing: true)
        await waitUntil { sharing.joined && jiggleRooms.count == 1 && tokenRequests == 1 }
        onboarding.refresh()
        await waitUntil { !onboarding.busy }
        observation?.fire()
        await settle()
        sharing.background()
        XCTAssertFalse(sharing.active)
        sharing.foreground()
        await waitUntil { sharing.active && transport.configurations.count == 2 && tokenRequests == 2 }
        onboarding.refresh()
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(jiggleRooms, [friend.roomID], "List refresh and automatic foreground reconnect must not notify the friend again")
        XCTAssertTrue(sharing.active)
        onboarding.close()
        sharing.stop()
    }

    func testJiggleFailureDoesNotStopOrDelaySharing() async throws {
        let identity = try makeIdentity(owner: UUID())
        let friend = FriendRoom(roomID: UUID().uuidString, displayName: "Fixture Friend")
        let transport = FriendTapSharingTransport()
        var tokenRequests = 0
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, session in
                tokenRequests += 1
                return self.makeLease(room: room, owner: session.owner, request: tokenRequests)
            })
        var jiggleAttempts = 0
        let onboarding = FriendOnboarding(call: { _, action, _ in
            action == "list" ? FriendResponse(ok: true, rooms: [friend]) : FriendResponse(ok: false)
        }, sendJiggle: { _, _ in
            jiggleAttempts += 1
            throw BoundFriendError.unavailable
        }, observeAccount: { OnboardingObservation($0) })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }

        onboarding.select(friend, startSharing: true)
        await waitUntil { sharing.active && tokenRequests == 1 && jiggleAttempts == 1 }
        XCTAssertTrue(sharing.active, "The share starts while notification delivery runs")
        await settle()
        XCTAssertTrue(sharing.active, "Notification failure must not stop sharing")
        XCTAssertEqual(tokenRequests, 1)
        XCTAssertEqual(transport.configurations.count, 1)
        onboarding.close()
        sharing.stop()
    }

    func testClosingFriendsKeepsPendingJiggleRunningWithActiveShare() async throws {
        let identity = try makeIdentity(owner: UUID())
        let friend = FriendRoom(roomID: UUID().uuidString, displayName: "Fixture Friend")
        let transport = FriendTapSharingTransport()
        var tokenRequests = 0
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, session in
                tokenRequests += 1
                return self.makeLease(room: room, owner: session.owner, request: tokenRequests)
            })
        var started = false
        var completed = false
        let onboarding = FriendOnboarding(call: { _, action, _ in
            action == "list" ? FriendResponse(ok: true, rooms: [friend]) : FriendResponse(ok: false)
        }, sendJiggle: { _, _ in
            started = true
            try await Task.sleep(nanoseconds: 50_000_000)
            completed = true
            return "Jiggle sent."
        }, observeAccount: { OnboardingObservation($0) })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }

        onboarding.select(friend, startSharing: true)
        await waitUntil { sharing.active && started }
        onboarding.close()
        await waitUntil { completed }
        XCTAssertTrue(sharing.active, "Closing Friends keeps the active share running")
        XCTAssertTrue(completed, "Closing Friends does not cancel an in-flight Jiggle")
        sharing.stop()
    }

    func testUsernameAddUsesTrimmedNameKeepsOwnProfileAndDoesNotStartSharing() async throws {
        let identity = try makeIdentity(owner: UUID())
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Navi")
        var additions: [[String: String]] = []
        let onboarding = FriendOnboarding(call: { _, action, payload in
            if action == "list" { return .init(ok: true, rooms: [], username: "River") }
            XCTAssertEqual(action, "add")
            additions.append(payload)
            return .init(ok: true, room: room, username: "River")
        }, sendJiggle: { _, _ in
            XCTFail("Adding a friend must not send a Jiggle")
            return ""
        }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { _, _ in XCTFail("Adding a friend must not start sharing"); throw BoundFriendError.unavailable })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }
        onboarding.add(username: "  nAvI  ")
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(additions, [["username": "nAvI"]])
        XCTAssertEqual(onboarding.rooms, [room])
        XCTAssertEqual(onboarding.screenSelected, room)
        XCTAssertEqual(onboarding.accountUsername, "River")
        XCTAssertEqual(onboarding.message, "Friend added.")
        XCTAssertFalse(sharing.active)
        onboarding.add(username: "NAVI")
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(onboarding.rooms, [room], "Repeated adds must not duplicate the friend row")
        onboarding.close()
    }

    func testUsernameAddErrorsKeepFriendsAndLegacyFalseDoesNotDisablePairing() async throws {
        let identity = try makeIdentity(owner: UUID())
        var additions = 0
        let onboarding = FriendOnboarding(call: { _, action, _ in
            if action == "list" { return .init(ok: true, rooms: [], username: "River") }
            additions += 1
            return .init(ok: false, error: "friend_not_found")
        }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true)
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }
        onboarding.add(username: "Missing")
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(additions, 1)
        XCTAssertEqual(onboarding.message, "No friend found with that username.")
        XCTAssertTrue(onboarding.rooms.isEmpty)
        XCTAssertNil(onboarding.screenSelected)
        onboarding.add(username: " ")
        XCTAssertEqual(additions, 1)
        let legacyKey = BoundLegacyPreferences.experimentalFeaturesKey
        let previousLegacy = UserDefaults.standard.object(forKey: legacyKey)
        UserDefaults.standard.set(false, forKey: legacyKey)
        defer {
            if let previousLegacy { UserDefaults.standard.set(previousLegacy, forKey: legacyKey) }
            else { UserDefaults.standard.removeObject(forKey: legacyKey) }
        }
        onboarding.add(username: "Navi")
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(additions, 2, "The retired preference cannot disable username pairing")
        onboarding.close()
    }

    func testAccountFriendsReusesGameSessionAcrossSubmenusAndRemovesItOnlyOnSignOut() async throws {
        let account = try accountFixture()
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Navi")
        let transport = FriendTapSharingTransport()
        var leaseRequests = 0
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { room, identity in
                leaseRequests += 1
                return self.makeLease(room: room, owner: identity.owner, request: leaseRequests)
            })
        let onboarding = FriendOnboarding(call: { _, action, _ in
            XCTAssertEqual(action, "list")
            return FriendResponse(ok: true, rooms: [room], username: "River")
        }, sendJiggle: { _, _ in "" }, observeAccount: { OnboardingObservation($0) })
        onboarding.open(sharing: sharing, existing: { account.session })
        await waitUntil { !onboarding.busy }
        onboarding.select(room, startSharing: true)
        await waitUntil { sharing.joined }

        var context: BoundAccountFriendsContext? = BoundAccountFriendsContext(sharing: sharing, onboarding: onboarding, account: account)
        XCTAssertTrue(context?.sharing === sharing)
        XCTAssertTrue(context?.onboarding === onboarding)
        context?.open()
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(context?.signedInUsername, "River")
        context?.close() // Pushing Account and Security or Sync must keep the game connected.
        XCTAssertTrue(sharing.joined)
        context?.open()
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(leaseRequests, 1, "Entering Account and returning from a submenu must not start another connection")
        context?.close()
        context = nil
        BoundMainActorDisposal.drainPending()
        XCTAssertTrue(sharing.joined, "Dismissing Account must preserve a borrowed game connection")

        let reopened = BoundAccountFriendsContext(sharing: sharing, onboarding: onboarding, account: account)
        reopened.open()
        await waitUntil { !onboarding.busy }
        reopened.prepareForAccountRemoval()
        account.signOut()
        XCTAssertFalse(sharing.active)
        XCTAssertFalse(sharing.joined)
        XCTAssertNil(onboarding.screenSelected)
        XCTAssertNil(reopened.signedInUsername)
        reopened.close()
    }

    func testAccountFriendsFooterTracksProfileAndNeverLeaksPreviousOwnerName() async throws {
        let account = try accountFixture()
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true)
        var username = "River"
        let onboarding = FriendOnboarding(call: { _, action, _ in
            XCTAssertEqual(action, "list")
            return FriendResponse(ok: true, rooms: [], username: username)
        }, observeAccount: { OnboardingObservation($0) })
        let context = BoundAccountFriendsContext(sharing: sharing, onboarding: onboarding, account: account)
        XCTAssertNil(context.signedInUsername, "No placeholder footer is shown before a profile is loaded")
        context.open()
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(context.signedInUsername, "River")
        username = "Renamed River"
        onboarding.refresh()
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(context.signedInUsername, "Renamed River")

        let replacementAccount = try accountFixture()
        let replacement = BoundAccountFriendsContext(sharing: sharing, onboarding: onboarding, account: replacementAccount)
        XCTAssertNil(replacement.signedInUsername, "A retained list from another owner cannot expose their name")
        username = "New Owner"
        replacement.open()
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(replacement.signedInUsername, "New Owner")
        XCTAssertNil(context.signedInUsername)
        replacementAccount.signOut()
        XCTAssertNil(replacement.signedInUsername, "Signing out immediately hides the footer before the next account observation")
        replacement.close()
        account.signOut()
    }

    func testSignedInAccountFriendsRendersPhoneAndMacAndRefreshesProfile() async throws {
        let account = try accountFixture()
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Navi")
        var username = "River"
        let onboarding = FriendOnboarding(call: { _, action, _ in
            XCTAssertEqual(action, "list")
            return FriendResponse(ok: true, rooms: [room], username: username)
        }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true, mediaOnly: true,
            tokenFetcher: { _, _ in XCTFail("Rendering Account must not start a share"); throw BoundFriendError.unavailable })
        let context = BoundAccountFriendsContext(sharing: sharing, onboarding: onboarding, account: account)
        let host = UIHostingController(rootView: NavigationStack { BoundAccountFriendsSyncSettings(context: context) })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            context.close()
            account.signOut()
        }
        for (layout, size) in [("iPhone", CGSize(width: 393, height: 852)),
                               ("Mac", CGSize(width: 1024, height: 768))] {
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await waitUntil { context.signedInUsername == "River" }
            XCTAssertEqual(context.signedInUsername, "River")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 5000)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Account-Friends-Sync-Signed-In-\(layout)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(onboarding.rooms, [room])
            XCTAssertFalse(sharing.active)
        }
        username = "Renamed River"
        NotificationCenter.default.post(name: BoundAccountProfile.didChangeNotification, object: account.session?.owner)
        await waitUntil { context.signedInUsername == "Renamed River" }
        XCTAssertEqual(context.signedInUsername, "Renamed River", "An open Account screen refreshes its footer after the shared profile changes")
        account.signOut()
        XCTAssertNil(context.signedInUsername)
        XCTAssertFalse(sharing.active)
    }

    func testSettingsKeepsFriendsOpenAcrossChildPagesAndClosesOnDismissal() async throws {
        let account = try accountFixture()
        var observation: OnboardingObservation?
        var actions: [String] = []
        let newFriend = FriendRoom(roomID: UUID().uuidString, displayName: "Navi")
        let onboarding = FriendOnboarding(call: { _, action, _ in
            actions.append(action)
            return FriendResponse(ok: true, room: action == "add" ? newFriend : nil,
                                  rooms: action == "list" ? [] : nil, username: "River")
        }, observeAccount: { observation = OnboardingObservation($0); return observation! })
        let sharing = FriendSharingSession(configuration: nil, authenticatedMode: true)
        let context = BoundAccountFriendsContext(sharing: sharing, onboarding: onboarding, account: account)
        let settings = BoundSettingsHostingController(
            gameplay: BoundSettingsGameplayContext(emulationDetails: nil, friends: context),
            syncOnClose: {})
        let page = UIHostingController(rootView: AnyView(NavigationStack { BoundAccountFriendsSyncSettings(context: context) }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = page
        window.makeKeyAndVisible()
        page.view.layoutIfNeeded()
        defer {
            settings.finishPresentation()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
            account.signOut()
        }
        await waitUntil { context.signedInUsername == "River" && !onboarding.busy }
        XCTAssertEqual(context.signedInUsername, "River")
        XCTAssertFalse(try XCTUnwrap(observation).cancelled)

        // A navigation destination replaces the visible Account page. Its
        // disappearance must not cancel the session the child still uses.
        page.rootView = AnyView(Text("Add a Friend"))
        page.view.layoutIfNeeded()
        await settle()
        XCTAssertFalse(try XCTUnwrap(observation).cancelled)
        onboarding.add(username: "Navi")
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(actions, ["list", "add"])
        XCTAssertEqual(onboarding.rooms, [newFriend])

        settings.finishPresentation()
        XCTAssertTrue(try XCTUnwrap(observation).cancelled,
                      "Only closing the outer Settings presentation stops its account observation")
    }

    func testLibraryAccountFriendsDisposalCancelsItsObservation() async throws {
        let account = try accountFixture()
        var observation: OnboardingObservation?
        let onboarding = FriendOnboarding(call: { _, _, _ in FriendResponse(ok: true, rooms: [], username: "River") },
            observeAccount: { observation = OnboardingObservation($0); return observation! })
        var context: BoundAccountFriendsContext? = BoundAccountFriendsContext(onboarding: onboarding, account: account)
        weak var released = context
        context?.open()
        await waitUntil { !onboarding.busy }
        XCTAssertFalse(try XCTUnwrap(observation).cancelled)
        context = nil
        XCTAssertNil(released)
        BoundMainActorDisposal.drainPending()
        XCTAssertTrue(try XCTUnwrap(observation).cancelled, "Library Account must not leave a friend refresh timer running after dismissal")
        account.signOut()
    }

    private func accountFixture() throws -> BoundFriendAccount {
        let owner = UUID()
        let claims = try JSONSerialization.data(withJSONObject: BoundAccountTestFixture.claims(owner: owner, expiry: Date().timeIntervalSince1970 + 3600))
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let saved = BoundSavedSession(origin: BoundFriendAccount.origin, owner: owner,
            accessToken: "fixture.\(payload).signature", refreshToken: "synthetic-account-friends-refresh")
        return BoundFriendAccount(storage: AccountFriendsMemoryStorage(try JSONEncoder().encode(saved)),
            deletionStorage: AccountFriendsMemoryStorage(), automaticRefresh: false,
            configuration: { "fixture-public-key" }, transport: { _ in
                XCTFail("Account Friends fixtures must not contact the account service")
                throw BoundFriendError.unavailable
            })
    }

    private func makeIdentity(owner: UUID, expires: TimeInterval = 3600) throws -> AppCloudSession {
        let claims = try JSONSerialization.data(withJSONObject: BoundAccountTestFixture.claims(owner: owner, expiry: Date().timeIntervalSince1970 + expires))
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try AppCloudSession(owner: owner, key: "fixture-public-key", token: "fixture.\(payload).signature")
    }

    private func makeLease(room: String, owner: UUID, request: Int) -> FriendSharingTokenLease {
        FriendSharingTokenLease(roomID: room, ownerID: owner,
            appID: String(repeating: "0", count: 32), channel: "friend-tap-\(request)", uid: 1, remoteUID: 2,
            token: "fixture-token-\(request)", issuedAt: Date().timeIntervalSince1970,
            expiresAt: Date().timeIntervalSince1970 + 90)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 30_000_000) }
}

@MainActor
private final class FriendTapSharingTransport: FriendSharingTransport {
    private(set) var configurations: [FriendSharingConfiguration] = []
    private var event: (@MainActor (FriendSharingEvent) -> Void)?
    var publishedFrames: Int { 0 }
    var receivedFrames: Int { 0 }
    var diagnostics: [String: Any] { [:] }

    func start(configuration: FriendSharingConfiguration, remoteView: UIView,
               event: @escaping @MainActor (FriendSharingEvent) -> Void) {
        configurations.append(configuration)
        self.event = event
        event(.joined)
    }

    func emit(_ event: FriendSharingEvent) { self.event?(event) }
    func stop() {}
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        OnboardingObservation({})
    }
}

private actor RunLeaseClientFixture {
    let owner: UUID
    let token = UUID()
    var failNext = false
    var invalidOwner = false
    var holdRenewal = false
    var pendingRenewal: CheckedContinuation<Void, Never>?
    var requests: [String] = []
    var actions: [String] = []
    var checkpointParents: [String?] = []
    var anchorVersion: UInt64 = 0
    var checkpointID: String?
    var checkpointHistory: String?
    var historyDigest: String?
    var loseReply = false
    var regressReply = false
    var ended = false
    init(owner: UUID) { self.owner = owner }
    func failOnce() { failNext = true }
    func rejectOwner() { invalidOwner = true }
    func hold() { holdRenewal = true }
    func resume() { holdRenewal = false; pendingRenewal?.resume(); pendingRenewal = nil }
    func loseOnce() { loseReply = true }
    func regressOnce() { regressReply = true }
    var isWaiting: Bool { pendingRenewal != nil }
    func perform(_ request: URLRequest) async throws -> Data {
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let action = try XCTUnwrap(body["action"] as? String)
        let payload = try XCTUnwrap(body["payload"] as? [String: Any])
        actions.append(action)
        if action == "checkpoint" { checkpointParents.append(payload["predecessor"] as? String) }
        if action == "release" { return Data("{\"ok\":true}".utf8) }
        if action == "end" {
            ended = true
            if loseReply { loseReply = false; throw BoundRunLeaseError.unavailable }
            return Data("{\"ok\":true}".utf8)
        }
        if ended { return Data("{\"ok\":false,\"error\":\"run_ended\"}".utf8) }
        if let id = payload["requestID"] as? String { requests.append(id) }
        if failNext { failNext = false; throw BoundRunLeaseError.unavailable }
        if action == "renew", holdRenewal { await withCheckedContinuation { pendingRenewal = $0 } }
        if action == "history", let digest = payload["history"] as? String, digest != historyDigest {
            historyDigest = digest; anchorVersion += 1
        }
        if action == "checkpoint", let id = payload["checkpointID"] as? String, id != checkpointID {
            checkpointID = id; checkpointHistory = payload["history"] as? String; anchorVersion += 1
        }
        if loseReply { loseReply = false; throw BoundRunLeaseError.unavailable }
        let regressed = regressReply; regressReply = false
        let now = Date().timeIntervalSince1970
        return try JSONSerialization.data(withJSONObject: ["ok": true,
            "ownerID": (invalidOwner ? UUID() : owner).uuidString,
            "runID": try XCTUnwrap(payload["runID"]), "deviceID": try XCTUnwrap(payload["deviceID"]),
            "token": token.uuidString, "fence": "1", "serverTime": now, "expiresAt": now + 60,
            "anchorVersion": regressed ? "0" : String(anchorVersion),
            "checkpointID": regressed ? NSNull() : checkpointID.map { $0 as Any } ?? NSNull(),
            "checkpointHistory": regressed ? NSNull() : checkpointHistory.map { $0 as Any } ?? NSNull(),
            "historyDigest": regressed ? NSNull() : historyDigest.map { $0 as Any } ?? NSNull()])
    }
}

@MainActor
final class RunLeaseClientTests: XCTestCase {
    private func identity(owner: UUID) throws -> AppCloudSession {
        let data = try JSONSerialization.data(withJSONObject: BoundAccountTestFixture.claims(owner: owner, expiry: Date().timeIntervalSince1970 + 3600))
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try AppCloudSession(owner: owner, key: "fixture", token: "fixture." + payload + ".signature")
    }
    private func independentPackage(owner: UUID, run: UUID, device: UUID, checkpoint: UUID = UUID(),
                                    predecessor: UUID? = nil, digest: String = String(repeating: "a", count: 64)) throws -> BoundMultiplayerSavePackage {
        let identity = BoundMultiplayerRunIdentity(run: run, gameID: "fixture", owner: owner, partner: UUID(),
            roomID: "room-fixture", settingsOwner: owner, settings: Data(), localSeed: 1, partnerSeed: 2,
            romSHA256: String(repeating: "a", count: 64))
        let payload = BoundMultiplayerSavePackage.Payload(version: 2, manifest: .init(identity: identity, deviceOwner: device),
            checkpoint: checkpoint, predecessor: predecessor, sharedEventDigest: digest,
            files: ["game.sav": .init(Data(repeating: 7, count: 131_072)), "checkpoint.state": .init(Data(repeating: 8, count: 2048))])
        let receipt = BoundMultiplayerCheckpointReceipt(run: run, checkpoint: checkpoint, owner: owner,
            payloadSHA256: BoundMultiplayerSaveStore.hash(try BoundMultiplayerSaveStore.encode(payload)), sharedEventDigest: digest)
        return .init(payload: payload, receipt: receipt)
    }
    func testIndependentUploadAnchorsSavedGenerationWithServerParentAndRetriesWithoutRewritingCheckpoint() async throws {
        let owner = UUID(), run = UUID(), device = UUID(), session = try identity(owner: owner)
        let fixture = RunLeaseClientFixture(owner: owner)
        let client = BoundRunLeaseClient(perform: { try await fixture.perform($0) }, device: { device })
        let authority = try await client.independentAuthority(runID: run, session: session)
        XCTAssertFalse(authority.allowsTransfer)
        let cached = try await client.independentAuthority(runID: run, session: session)
        XCTAssertTrue(cached.isCurrent)
        let first = try independentPackage(owner: owner, run: run, device: device)
        let firstGrant = try await client.publishIndependentCheckpoint(package: first, session: session)
        XCTAssertEqual(firstGrant.checkpointID, first.payload.checkpoint)
        XCTAssertEqual(firstGrant.historyDigest, first.payload.sharedEventDigest)
        let firstActions = await fixture.actions
        XCTAssertEqual(firstActions, ["acquire", "history", "checkpoint"])
        _ = try await client.publishIndependentCheckpoint(package: first, session: session)
        let retriedActions = await fixture.actions
        XCTAssertEqual(retriedActions, ["acquire", "history", "checkpoint"], "A lost publish response cannot change the remembered checkpoint parent")
        let second = try independentPackage(owner: owner, run: run, device: device, predecessor: UUID(), digest: String(repeating: "b", count: 64))
        let secondGrant = try await client.publishIndependentCheckpoint(package: second, session: session)
        XCTAssertEqual(secondGrant.checkpointID, second.payload.checkpoint)
        XCTAssertEqual(secondGrant.checkpointHistory, second.payload.sharedEventDigest)
        let parents = await fixture.checkpointParents, finalActions = await fixture.actions
        XCTAssertEqual(parents, [nil, first.payload.checkpoint.uuidString.lowercased()], "Offline local saves may skip the last uploaded generation")
        XCTAssertEqual(finalActions, ["acquire", "history", "checkpoint", "history", "checkpoint"])
    }
    func testIndependentPublishRejectsForeignDeviceAccountAndChangedConfigurationBeforeNetworkAccess() async throws {
        let owner = UUID(), run = UUID(), device = UUID(), session = try identity(owner: owner)
        let fixture = RunLeaseClientFixture(owner: owner)
        let client = BoundRunLeaseClient(perform: { try await fixture.perform($0) }, device: { device })
        let original = try independentPackage(owner: owner, run: run, device: device)
        for variation in ["account", "device", "seed", "rom"] {
            var package = original
            switch variation {
            case "account": package.payload.manifest.identity.owner = UUID()
            case "device": package.payload.manifest.deviceOwner = UUID()
            case "seed": package.payload.manifest.identity.localSeed = 11
            default: package.payload.manifest.identity.romSHA256 = String(repeating: "b", count: 64)
            }
            do { _ = try await client.publishIndependentCheckpoint(package: package, session: session); XCTFail("Changed package must fail") }
            catch BoundRunLeaseError.unauthorized {}
        }
        let actions = await fixture.actions
        XCTAssertTrue(actions.isEmpty)
    }
    func testUncertainAcquireReusesRequestAndRenewReleaseInvalidateOldGrants() async throws {
        let owner = UUID(), run = UUID(), device = UUID(), session = try identity(owner: owner)
        let fixture = RunLeaseClientFixture(owner: owner)
        let client = BoundRunLeaseClient(perform: { try await fixture.perform($0) }, device: { device })
        await fixture.failOnce()
        do { _ = try await client.acquire(runID: run, session: session); XCTFail("Expected transport failure") }
        catch BoundRunLeaseError.unavailable {}
        let grant = try await client.acquire(runID: run, session: session, allowTransfer: true)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(grant.ownerID, owner); XCTAssertEqual(grant.runID, run); XCTAssertEqual(grant.deviceID, device)
        XCTAssertTrue(grant.isCurrent); XCTAssertTrue(grant.allowsTransfer)
        XCTAssertGreaterThan(grant.remaining, 50); XCTAssertLessThanOrEqual(grant.remaining, 55)
        let token = await fixture.token
        XCTAssertFalse(String(describing: grant).contains(token.uuidString))
        let renewed = try await client.renew(grant: grant, session: session)
        XCTAssertFalse(grant.isCurrent); XCTAssertTrue(renewed.isCurrent)
        try await client.release(grant: renewed, session: session)
        XCTAssertFalse(renewed.isCurrent)
    }
    func testWrongAccountReplyAndLateRenewalCannotGrantAuthority() async throws {
        let owner = UUID(), run = UUID(), device = UUID(), session = try identity(owner: owner)
        let badFixture = RunLeaseClientFixture(owner: owner)
        await badFixture.rejectOwner()
        let badClient = BoundRunLeaseClient(perform: { try await badFixture.perform($0) }, device: { device })
        do { _ = try await badClient.acquire(runID: run, session: session); XCTFail("Wrong owner reply must fail") }
        catch BoundRunLeaseError.unavailable {}
        let fixture = RunLeaseClientFixture(owner: owner)
        let client = BoundRunLeaseClient(perform: { try await fixture.perform($0) }, device: { device })
        let grant = try await client.acquire(runID: run, session: session)
        await fixture.hold()
        let renewal = Task { try await client.renew(grant: grant, session: session) }
        for _ in 0..<100 {
            if await fixture.isWaiting { break }
            await Task.yield()
        }
        let waiting = await fixture.isWaiting
        XCTAssertTrue(waiting)
        let release = Task { try await client.release(grant: grant, session: session) }
        for _ in 0..<100 {
            if !grant.isCurrent { break }
            await Task.yield()
        }
        XCTAssertFalse(grant.isCurrent)
        await fixture.resume()
        do { _ = try await renewal.value; XCTFail("Late renewal cannot revive released authority") }
        catch BoundRunLeaseError.leaseExpired {}
        try await release.value
        XCTAssertFalse(grant.isCurrent)
    }
    func testHistoryAndCheckpointAnchorsSurviveUncertainRepliesAndRejectRegression() async throws {
        let owner = UUID(), run = UUID(), device = UUID(), session = try identity(owner: owner)
        let fixture = RunLeaseClientFixture(owner: owner)
        let client = BoundRunLeaseClient(perform: { try await fixture.perform($0) }, device: { device })
        let initial = try await client.acquire(runID: run, session: session)
        let digest = String(repeating: "a", count: 64), checkpoint = UUID()
        await fixture.loseOnce()
        do { _ = try await client.recordHistory(grant: initial, digest: digest, session: session); XCTFail("Expected uncertain reply") }
        catch BoundRunLeaseError.unavailable {}
        let anchored = try await client.recordHistory(grant: initial, digest: digest, session: session)
        XCTAssertEqual(anchored.anchorVersion, 1); XCTAssertEqual(anchored.historyDigest, digest)
        XCTAssertNil(anchored.checkpointID); XCTAssertFalse(initial.isCurrent)
        let committed = try await client.checkpoint(grant: anchored, checkpointID: checkpoint, predecessor: nil, history: digest, session: session)
        XCTAssertEqual(committed.checkpointID, checkpoint); XCTAssertEqual(committed.checkpointHistory, digest)
        XCTAssertEqual(committed.anchorVersion, 2); XCTAssertFalse(anchored.isCurrent)
        let renewed = try await client.renew(grant: committed, session: session)
        XCTAssertEqual(renewed.checkpointID, checkpoint); XCTAssertEqual(renewed.historyDigest, digest)
        await fixture.regressOnce()
        do { _ = try await client.renew(grant: renewed, session: session); XCTFail("Server response cannot regress remembered anchors") }
        catch BoundRunLeaseError.anchorConflict {}
        XCTAssertFalse(renewed.isCurrent)
    }
    func testQueuedAnchorMutationCannotUseGrantSupersededByRenewal() async throws {
        let owner = UUID(), run = UUID(), device = UUID(), session = try identity(owner: owner)
        let fixture = RunLeaseClientFixture(owner: owner)
        let client = BoundRunLeaseClient(perform: { try await fixture.perform($0) }, device: { device })
        let grant = try await client.acquire(runID: run, session: session)
        await fixture.hold()
        let renewal = Task { try await client.renew(grant: grant, session: session) }
        for _ in 0..<100 { if await fixture.isWaiting { break }; await Task.yield() }
        let anchor = Task { try await client.recordHistory(grant: grant, digest: String(repeating: "b", count: 64), session: session) }
        for _ in 0..<10 { await Task.yield() }
        let before = await fixture.actions
        XCTAssertEqual(before, ["acquire", "renew"])
        await fixture.resume()
        let renewed = try await renewal.value
        do { _ = try await anchor.value; XCTFail("Queued write must revalidate authority") }
        catch BoundRunLeaseError.leaseExpired {}
        XCTAssertTrue(renewed.isCurrent)
    }
    func testPermanentEndInvalidatesAuthorityAndRetriesAnUncertainReply() async throws {
        let owner = UUID(), run = UUID(), device = UUID(), session = try identity(owner: owner)
        let fixture = RunLeaseClientFixture(owner: owner)
        let client = BoundRunLeaseClient(perform: { try await fixture.perform($0) }, device: { device })
        let grant = try await client.acquire(runID: run, session: session)
        await fixture.loseOnce()
        do { try await client.end(grant: grant, session: session); XCTFail("Expected uncertain end reply") }
        catch BoundRunLeaseError.unavailable {}
        XCTAssertFalse(grant.isCurrent)
        try await client.end(grant: grant, session: session)
        try await client.release(grant: grant, session: session)
        do { _ = try await client.acquire(runID: run, session: session, allowTransfer: true); XCTFail("Ended runs never reacquire") }
        catch BoundRunLeaseError.runEnded {}
    }
}

@MainActor
private final class AccountFriendsMemoryStorage: BoundSessionStorage {
    private var data: Data?
    var failWrites = false
    init(_ data: Data? = nil) { self.data = data }
    func read() throws -> Data? { data }
    func write(_ data: Data) throws {
        if failWrites { throw BoundKeychainSessionStorage.Failure(status: errSecInteractionNotAllowed) }
        self.data = data
    }
    func remove() throws { data = nil }
}
