import XCTest
import UIKit
import Security
@testable import Delta

/// Synthetic credentials exercise the native Keychain and account lifecycle; no backend is contacted.
@MainActor
final class AccountPersistenceIntegrationTests: XCTestCase {
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

    private func token(owner: UUID, expires: TimeInterval = 3600) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: ["sub": owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + expires])
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
        let claims = try JSONSerialization.data(withJSONObject: ["sub": owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
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
        }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, authenticatedMode: true)
        model.open(sharing: sharing, existing: { identity })
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertEqual(model.rooms, [room]); model.select(room); XCTAssertNotNil(model.selected)
        model.block(room)
        XCTAssertNil(model.selected); XCTAssertFalse(sharing.active)
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertEqual(model.rooms, []); XCTAssertEqual(model.blocks, [block])
        XCTAssertTrue(calls.contains { $0.0 == "block" && $0.1 == ["roomID": room.roomID] })
        model.unblock(block)
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertEqual(model.blocks, []); XCTAssertNil(model.selected); XCTAssertEqual(model.rooms, [])
        model.close()
    }
    func testReportUsesOnlyRoomAndCategoryAndDoesNotClaimReceiptOnDenial() async throws {
        let identity = try identity(), room = FriendRoom(roomID: UUID().uuidString, displayName: "Fixture Friend")
        var denied = false
        let model = FriendOnboarding(call: { _, action, payload in
            if action == "list" { return .init(ok: true, rooms: [room]) }
            XCTAssertEqual(action, "report"); XCTAssertEqual(payload, ["roomID": room.roomID, "reason": "harassment"])
            return denied ? .init(ok: false, error: "rate_limited") : .init(ok: true, reportID: UUID())
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
}
