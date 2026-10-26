import Foundation
import UIKit
import XCTest
@testable import Delta

/// Deliberately retains obsolete callbacks so the consumer must fence them.
private final class SDKRoomFixture: BoundSDKRoomTransport, @unchecked Sendable {
    typealias Configuration = BoundNakamaConfiguration
    struct Send: Equatable { let lane: Int; let data: Data; let target: UUID? }
    private let lock = NSLock()
    private var callbacks: [@Sendable (BoundSDKRoomEvent) -> Void] = []
    private var packets: [Send] = []
    func start(configuration: Configuration, event: @escaping @Sendable (BoundSDKRoomEvent) -> Void) throws {
        lock.lock(); callbacks.append(event); lock.unlock(); event(.joined)
    }
    func stop() {}
    func emit(_ event: BoundSDKRoomEvent, session: Int) {
        lock.lock(); let callback = callbacks[session]; lock.unlock(); callback(event)
    }
    var sent: [Send] { lock.lock(); defer { lock.unlock() }; return packets }
    private func record(_ lane: Int, _ data: Data, _ target: UUID?) -> Bool {
        lock.lock(); packets.append(.init(lane: lane, data: data, target: target)); lock.unlock(); return true
    }
    func sendPresence(_ data: Data, targetOwnerID: UUID?) -> Bool { record(1, data, targetOwnerID) }
    func sendInteraction(_ data: Data, targetOwnerID: UUID?) -> Bool { record(2, data, targetOwnerID) }
    func sendBattle(_ data: Data, targetOwnerID: UUID) -> Bool { record(3, data, targetOwnerID) }
    func renewTicket(_ ticket: String, expiresAt: TimeInterval) -> Bool { true }
}

@MainActor private final class SDKUnusedMedia: FriendSharingTransport {
    var starts = 0
    var sends = 0
    var publishedFrames = 0
    var receivedFrames = 0
    func start(configuration: FriendSharingConfiguration, remoteView: UIView,
               event: @escaping @MainActor (FriendSharingEvent) -> Void) { starts += 1 }
    func stop() {}
    func send(_ frame: SharingFrame, completion: @escaping @MainActor (Result<Void, SharingFailure>) -> Void) -> any SharingCancellation {
        sends += 1; completion(.success(())); return SDKFrameCancellation()
    }
}
@MainActor private final class SDKFrameCancellation: SharingCancellation { func cancel() {} }

final class SDKLifecycleTransportTests: XCTestCase {
    func testGenerationDomainsKeepTheirOwnCurrentTokenAndRejectReplacedWork() {
        var room = BoundSDKGeneration(), video = BoundSDKGeneration()
        let oldRoom = room.token, oldVideo = video.token
        XCTAssertTrue(room.admits(oldRoom)); XCTAssertTrue(video.admits(oldVideo))
        XCTAssertFalse(room.admits(oldVideo)); XCTAssertFalse(video.admits(oldRoom))
        video.invalidate()
        XCTAssertFalse(video.admits(oldVideo)); XCTAssertTrue(room.admits(oldRoom))
        let pending = BoundSDKGeneration.Token()
        XCTAssertFalse(room.admits(pending))
        room.replace(with: pending)
        XCTAssertTrue(room.admits(pending)); XCTAssertFalse(room.admits(oldRoom))
        room.invalidate()
        XCTAssertFalse(room.admits(pending)); XCTAssertFalse(room.admits(oldRoom))
    }

    func testRetryDelayPreservesBaselineSequenceCapAndBoundaryValues() {
        XCTAssertEqual((1...9).map { BoundSDKRetryDelay.seconds(attempt: $0) }, [1, 2, 4, 8, 16, 30, 30, 30, 30])
        XCTAssertEqual(BoundSDKRetryDelay.seconds(attempt: 0), 0.5, "Extraction must not introduce an extra clamp")
        XCTAssertEqual(BoundSDKRetryDelay.seconds(attempt: Int.max), 30)
        for attempt in Array(-8...64) + [Int.min + 1, Int.max] {
            let phase4 = min(30.0, pow(2.0, Double(min(attempt - 1, 5))))
            XCTAssertEqual(BoundSDKRetryDelay.seconds(attempt: attempt), phase4)
        }
    }

    @MainActor
    func testSharingConsumesNeutralRoomInterfaceWithoutMediaAndFencesObsoleteSessions() async throws {
        let room = SDKRoomFixture(), media = SDKUnusedMedia()
        let transport = BoundNakamaSharingTransport(media: media, client: room)
        let owner = UUID(), peer = UUID()
        let configuration = BoundNakamaConfiguration(endpoint: URL(string: "wss://bound.example/ws?format=json")!,
            accessToken: "fixture", expiresAt: Date().timeIntervalSince1970 + 90, matchID: "fixture-match",
            roomID: UUID(), ownerID: owner, nakamaUserID: UUID(), joinTicket: "fixture",
            members: [owner, peer], peerOwnerID: peer)
        let video = FriendSharingConfiguration(appID: String(repeating: "0", count: 32), channel: "fixture", uid: 1,
                                               remoteUID: 2, token: "fixture")
        defer { transport.stop() }
        let joined = expectation(description: "protocol room joined")
        var events: [FriendSharingEvent] = []
        transport.configureGameplay(configuration); transport.setVideoRequired(false)
        transport.start(configuration: video, remoteView: UIView()) { event in
            events.append(event); if event == .joined { joined.fulfill() }
        }
        await fulfillment(of: [joined], timeout: 2)
        let presence = Data([1, 2]), interaction = Data("BRM1fixture".utf8)
        let battle = BoundBattleWire.prefix + Data(repeating: 1, count: 40)
        XCTAssertTrue(transport.sendPresence(presence)); XCTAssertTrue(transport.sendInteraction(interaction))
        XCTAssertFalse(transport.sendInteraction(Data(repeating: 1, count: 1025)))
        let receivedBattle = expectation(description: "direct battle lane")
        let original = try XCTUnwrap(transport.makeBattleChannel(receiver: { data in
            XCTAssertEqual(data, battle); receivedBattle.fulfill()
        }, failed: { XCTFail("Healthy room must retain its battle lane") }))
        XCTAssertTrue(original.send(battle))
        room.emit(.message(opcode: 3, data: battle, senderOwnerID: peer), session: 0)
        await fulfillment(of: [receivedBattle], timeout: 2)
        XCTAssertEqual(room.sent, [.init(lane: 1, data: presence, target: peer),
                                   .init(lane: 2, data: interaction, target: peer),
                                   .init(lane: 3, data: battle, target: peer)])
        transport.stop()
        XCTAssertFalse(original.send(battle))
        let rejoined = expectation(description: "replacement protocol room joined")
        transport.configureGameplay(configuration)
        transport.start(configuration: video, remoteView: UIView()) { event in
            events.append(event); if event == .joined { rejoined.fulfill() }
        }
        await fulfillment(of: [rejoined], timeout: 2)
        var receivedPresence: [Data] = []
        transport.setPresenceReceiver { receivedPresence.append($0) }
        room.emit(.failed(.connectionLost), session: 0)
        room.emit(.message(opcode: 1, data: Data([7]), senderOwnerID: peer), session: 0)
        room.emit(.message(opcode: 1, data: Data([8]), senderOwnerID: peer), session: 1)
        let drained = expectation(description: "main delivery queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        transport.pollPresence()
        XCTAssertEqual(events, [.joined, .joined]); XCTAssertEqual(receivedPresence, [Data([8])])
        XCTAssertEqual(media.starts, 0); XCTAssertEqual(media.sends, 0)
        XCTAssertTrue(transport.sendPresence(Data([9])))
    }
}
