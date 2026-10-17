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
        }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, authenticatedMode: true)
        model.open(sharing: sharing, existing: { identity })
        for _ in 0..<1000 { if !model.busy { break }; await Task.yield() }
        XCTAssertEqual(model.accountUsername, "River")
        model.select(room)
        model.remove(room)
        XCTAssertNil(model.selected)
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
    func testExperimentalFriendTapStartsOnceSwitchesRoomsAndCanRetryAfterStop() async throws {
        let preferences = BoundExperimentalFeaturesPreferences()
        let previousExperimentalState = preferences.isEnabled
        preferences.isEnabled = true
        defer { preferences.isEnabled = previousExperimentalState }

        let owner = UUID()
        let identity = try makeIdentity(owner: owner)
        let first = FriendRoom(roomID: UUID().uuidString, displayName: "First Friend")
        let second = FriendRoom(roomID: UUID().uuidString, displayName: "Second Friend")
        let transport = FriendTapSharingTransport()
        var requestedRooms: [String] = []
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            experimentalFeaturesEnabled: { true }, tokenFetcher: { room, session in
                requestedRooms.append(room)
                return self.makeLease(room: room, owner: session.owner, request: requestedRooms.count)
            })
        let onboarding = FriendOnboarding(call: { _, action, _ in
            action == "list" ? FriendResponse(ok: true, rooms: [first, second]) : FriendResponse(ok: false)
        }, observeAccount: { OnboardingObservation($0) })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }

        onboarding.select(first, startSharing: true)
        await waitUntil { transport.configurations.count == 1 }
        XCTAssertEqual(requestedRooms, [first.roomID])
        XCTAssertEqual(transport.configurations.first?.channel, "friend-tap-1")
        XCTAssertTrue(sharing.active)

        onboarding.select(first, startSharing: true)
        await settle()
        XCTAssertEqual(requestedRooms.count, 1, "Tapping the active selected friend must not restart sharing")
        XCTAssertEqual(transport.configurations.count, 1)

        onboarding.select(second, startSharing: true)
        await waitUntil { transport.configurations.count == 2 }
        XCTAssertEqual(requestedRooms, [first.roomID, second.roomID])
        XCTAssertEqual(transport.configurations.last?.channel, "friend-tap-2")
        XCTAssertEqual(onboarding.selected, second)

        sharing.stop()
        XCTAssertFalse(sharing.active)
        onboarding.select(second, startSharing: true)
        await waitUntil { transport.configurations.count == 3 }
        XCTAssertEqual(requestedRooms, [first.roomID, second.roomID, second.roomID], "A stopped session can be retried from the selected friend")
        XCTAssertTrue(sharing.active)
        onboarding.close()
        sharing.stop()
    }

    func testSelectionNeverAutostartsWhenExperimentalFeaturesAreOff() async throws {
        let preferences = BoundExperimentalFeaturesPreferences()
        let previousExperimentalState = preferences.isEnabled
        preferences.isEnabled = false
        defer { preferences.isEnabled = previousExperimentalState }

        let owner = UUID()
        let identity = try makeIdentity(owner: owner)
        let friend = FriendRoom(roomID: UUID().uuidString, displayName: "Fixture Friend")
        let transport = FriendTapSharingTransport()
        var tokenRequests = 0
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            experimentalFeaturesEnabled: { true }, tokenFetcher: { room, session in
                tokenRequests += 1
                return self.makeLease(room: room, owner: session.owner, request: tokenRequests)
            })
        let onboarding = FriendOnboarding(call: { _, action, _ in
            action == "list" ? FriendResponse(ok: true, rooms: [friend]) : FriendResponse(ok: false)
        }, observeAccount: { OnboardingObservation($0) })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }

        onboarding.select(friend, startSharing: true)
        await settle()
        XCTAssertEqual(onboarding.selected, friend, "Selection remains available while experimental sharing is disabled")
        XCTAssertFalse(sharing.active)
        XCTAssertEqual(tokenRequests, 0)
        XCTAssertTrue(transport.configurations.isEmpty)
        onboarding.close()
    }

    func testInvalidUnlistedBusyAndSignedOutSelectionCannotStartAndAcceptedInviteStaysIdle() async throws {
        let preferences = BoundExperimentalFeaturesPreferences()
        let previousExperimentalState = preferences.isEnabled
        preferences.isEnabled = true
        defer { preferences.isEnabled = previousExperimentalState }

        let owner = UUID()
        var identity: AppCloudSession? = try makeIdentity(owner: owner)
        let friend = FriendRoom(roomID: UUID().uuidString, displayName: "Listed Friend")
        let accepted = FriendRoom(roomID: UUID().uuidString, displayName: "Invited Friend")
        let unlisted = FriendRoom(roomID: UUID().uuidString, displayName: "Unlisted Friend")
        let invalid = FriendRoom(roomID: "not-a-room", displayName: "Invalid Friend")
        let transport = FriendTapSharingTransport()
        var tokenRequests = 0
        var holdReport = false
        let sharing = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            experimentalFeaturesEnabled: { true }, tokenFetcher: { room, session in
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
        }, observeAccount: { OnboardingObservation($0) })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }

        onboarding.select(invalid, startSharing: true)
        onboarding.select(unlisted, startSharing: true)
        XCTAssertNil(onboarding.selected)
        XCTAssertEqual(tokenRequests, 0)
        XCTAssertTrue(transport.configurations.isEmpty)

        holdReport = true
        onboarding.report(friend, reason: .other)
        XCTAssertTrue(onboarding.busy)
        onboarding.select(friend, startSharing: true)
        XCTAssertNil(onboarding.selected)
        XCTAssertEqual(tokenRequests, 0, "A busy onboarding action blocks tap-to-share")
        await waitUntil { !onboarding.busy }

        identity = nil
        onboarding.synchronizeAccount()
        onboarding.select(friend, startSharing: true)
        XCTAssertNil(onboarding.selected)
        XCTAssertEqual(tokenRequests, 0, "A signed-out account cannot start sharing")
        identity = try makeIdentity(owner: owner)
        onboarding.synchronizeAccount()
        await waitUntil { !onboarding.busy }

        onboarding.accept(code: "0123456789ABCDEF", name: "Invited Friend")
        await waitUntil { !onboarding.busy && onboarding.selected == accepted }
        XCTAssertEqual(onboarding.selected, accepted)
        XCTAssertFalse(sharing.active)
        XCTAssertEqual(tokenRequests, 0, "Accepting an invitation selects the room without starting a share")
        XCTAssertTrue(transport.configurations.isEmpty)
        onboarding.close()
    }

    func testUsernameAddUsesTrimmedNameKeepsOwnProfileAndDoesNotStartSharing() async throws {
        let preferences = BoundExperimentalFeaturesPreferences()
        let previous = preferences.isEnabled
        preferences.isEnabled = true
        defer { preferences.isEnabled = previous }
        let identity = try makeIdentity(owner: UUID())
        let room = FriendRoom(roomID: UUID().uuidString, displayName: "Navi")
        var additions: [[String: String]] = []
        let onboarding = FriendOnboarding(call: { _, action, payload in
            if action == "list" { return .init(ok: true, rooms: [], username: "River") }
            XCTAssertEqual(action, "add")
            additions.append(payload)
            return .init(ok: true, room: room, username: "River")
        }, observeAccount: { OnboardingObservation($0) })
        let sharing = FriendSharingSession(configuration: nil, transport: FriendTapSharingTransport(), authenticatedMode: true,
            tokenFetcher: { _, _ in XCTFail("Adding a friend must not start sharing"); throw BoundFriendError.unavailable })
        onboarding.open(sharing: sharing, existing: { identity })
        await waitUntil { !onboarding.busy }
        onboarding.add(username: "  nAvI  ")
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(additions, [["username": "nAvI"]])
        XCTAssertEqual(onboarding.rooms, [room])
        XCTAssertEqual(onboarding.selected, room)
        XCTAssertEqual(onboarding.accountUsername, "River")
        XCTAssertEqual(onboarding.message, "Friend added.")
        XCTAssertFalse(sharing.active)
        onboarding.add(username: "NAVI")
        await waitUntil { !onboarding.busy }
        XCTAssertEqual(onboarding.rooms, [room], "Repeated adds must not duplicate the friend row")
        onboarding.close()
    }

    func testUsernameAddErrorsKeepFriendsAndExperimentalOptOutMakesNoRequest() async throws {
        let preferences = BoundExperimentalFeaturesPreferences()
        let previous = preferences.isEnabled
        preferences.isEnabled = true
        defer { preferences.isEnabled = previous }
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
        XCTAssertNil(onboarding.selected)
        onboarding.add(username: " ")
        XCTAssertEqual(additions, 1)
        preferences.isEnabled = false
        onboarding.add(username: "Navi")
        await settle()
        XCTAssertEqual(additions, 1, "Build 13 must never invoke username pairing")
        onboarding.close()
    }

    private func makeIdentity(owner: UUID) throws -> AppCloudSession {
        let claims = try JSONSerialization.data(withJSONObject: ["sub": owner.uuidString.lowercased(), "exp": Date().timeIntervalSince1970 + 3600])
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
    var publishedFrames: Int { 0 }
    var receivedFrames: Int { 0 }
    var diagnostics: [String: Any] { [:] }

    func start(configuration: FriendSharingConfiguration, remoteView: UIView,
               event: @escaping @MainActor (FriendSharingEvent) -> Void) {
        configurations.append(configuration)
        event(.joined)
    }

    func stop() {}
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        OnboardingObservation({})
    }
}
