import XCTest
import UIKit
@testable import Delta

@MainActor private final class ConnectionFeedCancellation: SharingCancellation {
    func cancel() {}
}

@MainActor private final class ConnectionFeedTransport: FriendSharingTransport {
    private(set) var callback: (@MainActor (FriendSharingEvent) -> Void)?
    var publishedFrames = 0
    var receivedFrames = 0
    func start(configuration: FriendSharingConfiguration, remoteView: UIView,
               event: @escaping @MainActor (FriendSharingEvent) -> Void) {
        callback = event
        event(.joined)
    }
    func stop() { callback = nil }
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        completion(.success(()))
        return ConnectionFeedCancellation()
    }
}

@MainActor
final class ConnectionFeedTests: XCTestCase {
    private func configuration() -> FriendSharingConfiguration {
        .init(appID: String(repeating: "0", count: 32), channel: "private-fixture-room", uid: 1,
              remoteUID: 2, token: "private-fixture-token")
    }

    func testHistoryIsNewestFirstBoundedAndClearPreservesConnectionState() {
        var time = Date(timeIntervalSince1970: 1_700_000_000)
        let feed = BoundConnectionFeed(capacity: 500, now: { time })
        for _ in 0..<250 {
            feed.record(.connecting)
            time.addTimeInterval(1)
        }
        XCTAssertEqual(feed.entries.count, 200)
        XCTAssertEqual(Set(feed.entries.map(\.id)).count, 200)
        XCTAssertEqual(feed.entries.first?.timestamp, Date(timeIntervalSince1970: 1_700_000_249))
        XCTAssertEqual(feed.entries.last?.timestamp, Date(timeIntervalSince1970: 1_700_000_050))
        feed.beginConnection(); feed.connected(); feed.friendJoined()
        feed.clear()
        feed.connected(); feed.friendJoined()
        XCTAssertTrue(feed.entries.isEmpty, "Clearing history does not invent fresh connection transitions")
        feed.friendUnavailable(); feed.friendUnavailable()
        XCTAssertEqual(feed.entries.map(\.kind), [.friendConnectionLost])
    }

    func testSessionEventsDistinguishPeerLossRecoveryAndManualDisconnectWithoutFrameSampling() {
        var time = Date(timeIntervalSince1970: 100)
        let feed = BoundConnectionFeed(now: { time }), transport = ConnectionFeedTransport()
        let session = FriendSharingSession(configuration: configuration(), transport: transport,
            authenticatedMode: false, connectionFeed: feed)
        defer { session.stop() }
        session.start()
        XCTAssertEqual(feed.entries.map(\.kind), [.connected, .connecting])
        transport.callback?(.joined)
        transport.callback?(.remoteJoined); transport.callback?(.remoteJoined)
        time.addTimeInterval(2)
        transport.callback?(.remoteGone); transport.callback?(.remoteGone)
        XCTAssertEqual(feed.entries.first?.kind, .friendConnectionLost)
        XCTAssertEqual(feed.entries.first?.timestamp, time)
        transport.callback?(.remoteJoined)
        XCTAssertEqual(feed.entries.first?.kind, .friendReconnected)
        transport.callback?(.reconnecting); transport.callback?(.reconnecting)
        transport.callback?(.rejoined); transport.callback?(.rejoined)
        XCTAssertEqual(feed.entries.map(\.kind).filter { $0 == .connectionLost }.count, 1)
        XCTAssertEqual(feed.entries.map(\.kind).filter { $0 == .reconnecting }.count, 1)
        XCTAssertEqual(feed.entries.first?.kind, .reconnected)
        let count = feed.entries.count
        for _ in 0..<100 {
            transport.callback?(.remoteFrame)
            transport.callback?(.connection(state: 3, reason: 1))
        }
        session.receivePlaybackFrame(nil)
        session.setRemotePresentationEnabled(false)
        session.setRemotePresentationEnabled(true)
        XCTAssertEqual(feed.entries.count, count, "Frame traffic, publication pauses and panel visibility do not create connection events")
        let stale = transport.callback
        let onboarding = FriendOnboarding()
        onboarding.setMultiplayerServiceActive(false, sharing: session, existing: { nil }, temporary: true)
        onboarding.disconnect()
        XCTAssertEqual(feed.entries.first?.kind, .manuallyDisconnected)
        let stoppedCount = feed.entries.count
        stale?(.joined); stale?(.remoteJoined); stale?(.failed(.init(.connectionLost)))
        session.stop(reason: .manual)
        XCTAssertEqual(feed.entries.count, stoppedCount, "Old callbacks and repeated stops cannot resurrect feed transitions")
        XCTAssertFalse(feed.entries.contains { $0.title.contains("private-fixture") })
    }

    func testExplicitPeerWithdrawalIsDifferentFromUncertainRosterLoss() {
        let feed = BoundConnectionFeed(), transport = ConnectionFeedTransport()
        let session = FriendSharingSession(configuration: configuration(), transport: transport,
            authenticatedMode: false, connectionFeed: feed)
        defer { session.stop() }
        session.start(); transport.callback?(.remoteJoined)
        transport.callback?(.remoteGone)
        session.livePresence.peerWithdrew?(); session.livePresence.peerWithdrew?()
        XCTAssertEqual(Array(feed.entries.prefix(2)).map(\.kind), [.friendDisconnected, .friendConnectionLost])
        XCTAssertEqual(feed.entries.first?.title, "Friend left multiplayer",
            "Presence withdrawal can disable multiplayer while friend video remains connected")
        XCTAssertEqual(feed.entries.filter { $0.kind == .friendDisconnected }.count, 1)
        transport.callback?(.remoteJoined)
        session.livePresence.peerWithdrew?()
        transport.callback?(.remoteGone)
        XCTAssertEqual(feed.entries.first?.kind, .friendConnectionLost,
            "Leaving multiplayer cannot hide a later actual roster disconnect")
        XCTAssertEqual(feed.entries.filter { $0.kind == .friendDisconnected }.count, 2,
            "A fresh friend connection permits a new withdrawal")
    }

    func testAuthenticatedBackgroundRejoinRetainsHistoryAndDoesNotClaimManualDisconnect() async throws {
        let owner = UUID(), room = UUID().uuidString, feed = BoundConnectionFeed()
        let claims = try JSONSerialization.data(withJSONObject: BoundAccountTestFixture.claims(owner: owner,
            expiry: Date().timeIntervalSince1970 + 3600))
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let identity = try AppCloudSession(owner: owner, key: "fixture-public-key", token: "fixture.\(payload).signature")
        let transport = ConnectionFeedTransport()
        let session = FriendSharingSession(configuration: nil, transport: transport, authenticatedMode: true,
            roomProvider: { room }, tokenFetcher: { room, identity in
                .init(roomID: room, ownerID: identity.owner, appID: String(repeating: "0", count: 32),
                    channel: "private-fixture-room", uid: 1, remoteUID: 2, token: "private-fixture-token",
                    issuedAt: Date().timeIntervalSince1970, expiresAt: Date().timeIntervalSince1970 + 90)
            }, connectionFeed: feed, applicationIsBackgrounded: { true })
        defer { session.stop() }
        session.configureAuthenticatedRoom(room, identity: { identity })
        session.start(); try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(session.joined)
        transport.callback?(.remoteJoined)
        let first = try XCTUnwrap(feed.entries.last?.id)
        session.background()
        XCTAssertEqual(feed.entries.first?.kind, .backgrounded)
        XCTAssertFalse(feed.entries.contains { [.disconnected, .manuallyDisconnected, .friendDisconnected].contains($0.kind) })
        session.foreground(); try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(session.joined)
        XCTAssertEqual(feed.entries.first?.kind, .reconnected)
        XCTAssertTrue(feed.entries.contains { $0.kind == .foregrounded })
        XCTAssertTrue(feed.entries.contains { $0.id == first })
        session.configureAuthenticatedRoom(nil, identity: { nil })
        XCTAssertEqual(feed.entries.first?.kind, .sessionChanged)
    }

    func testRepeatedAuthorizationFailuresCollapseUntilRecoveryAndLabelsContainOnlyKnownText() {
        let feed = BoundConnectionFeed()
        feed.beginConnection(); feed.recovering()
        for _ in 0..<20 { feed.beginConnection(resuming: true); feed.recovering() }
        XCTAssertEqual(feed.entries.map(\.kind), [.reconnecting, .connectionUnavailable, .connecting])
        feed.connected()
        XCTAssertEqual(feed.entries.first?.kind, .reconnected)
        for kind in BoundConnectionFeed.Kind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.symbolName.isEmpty)
            XCTAssertLessThan(kind.title.count, 40)
        }
    }

    func testForegroundMenuSuspensionDoesNotClaimTheAppWasBackgrounded() {
        let feed = BoundConnectionFeed()
        feed.beginConnection(); feed.connected()
        feed.backgrounded(appInBackground: false)
        feed.foregrounded(); feed.connected()
        XCTAssertEqual(Array(feed.entries.prefix(4)).map(\.kind), [.reconnected, .reconnecting, .resumed, .suspended])
        XCTAssertFalse(feed.entries.contains { $0.kind == .backgrounded || $0.kind == .foregrounded })
    }

    func testMultiplayerWithdrawalDeduplicatesOnlyWithinTheSamePresenceEpoch() {
        let feed = BoundConnectionFeed(), first = UUID(), second = UUID()
        feed.beginConnection(); feed.connected(); feed.friendJoined()
        feed.friendDisconnected(epoch: first); feed.friendDisconnected(epoch: first)
        feed.friendDisconnected(epoch: second); feed.friendDisconnected(epoch: second)
        XCTAssertEqual(feed.entries.filter { $0.kind == .friendDisconnected }.count, 2)
        feed.friendUnavailable()
        XCTAssertEqual(feed.entries.first?.kind, .friendConnectionLost)
        feed.disconnect(.stopped); feed.beginConnection(); feed.connected(); feed.friendJoined()
        feed.friendDisconnected(epoch: second)
        XCTAssertEqual(feed.entries.filter { $0.kind == .friendDisconnected }.count, 3,
            "An explicit new connection resets withdrawal deduplication")
    }
}
