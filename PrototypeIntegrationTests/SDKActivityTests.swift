import XCTest
@testable import Delta

final class SDKActivityTests: XCTestCase {
    private let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    func testReliableSessionMatchesFrozenHandshakeAndReplayDecisions() throws {
        let epoch = UUID(), stranger = UUID()
        var old = SDKPhase5AChannel(epoch: epoch), session = BoundSDKReliableSession(epoch: epoch)
        let peers = (0..<80).map { _ in UUID() }
        var now: TimeInterval = 100
        func packet(_ peer: UUID, _ receiver: UUID?, _ sequence: UInt64, _ kind: BoundROMPacket.Kind) -> BoundROMPacket {
            .init(kind: kind, owner: owner, epoch: peer, receiver: receiver, sequence: sequence, body: Data())
        }
        var cases = [packet(epoch, epoch, 1, .hello)]
        for peer in peers {
            cases += [packet(peer, nil, 1, .hello), packet(peer, stranger, 2, .proposal),
                      packet(peer, epoch, 0, .hello), packet(peer, epoch, 1, .hello),
                      packet(peer, epoch, 1, .settings), packet(peer, epoch, 3, .settings),
                      packet(peer, epoch, 2, .cancel), packet(peer, epoch, UInt64.max, .checkpoint)]
            // Revisiting a retired peer must not replace the current epoch.
            cases.append(packet(peers[0], epoch, UInt64.max, .hello))
        }
        for incoming in cases {
            XCTAssertEqual(old.admit(incoming, at: now),
                           session.admit(epoch: incoming.epoch, receiver: incoming.receiver,
                                         sequence: incoming.sequence, hello: incoming.kind == .hello, at: now))
            XCTAssertEqual(old.peerEpoch, session.peerEpoch)
            XCTAssertEqual(old.proposedEpoch, session.proposedEpoch)
            XCTAssertEqual(old.receivedAt, session.receivedAt)
            for age in [-1.0, 0, 2.999, 3, 30] { XCTAssertEqual(old.fresh(at: now + age), session.fresh(at: now + age)) }
            let encoded = try XCTUnwrap(old.packet(.hello, owner: owner, body: ["value": 7]))
            let previous = try XCTUnwrap(BoundROMPacket.decode(encoded))
            let next = BoundROMPacket(kind: .hello, owner: owner, epoch: session.epoch,
                                     receiver: session.receiver, sequence: try XCTUnwrap(session.nextSequence()),
                                     body: previous.body)
            XCTAssertEqual(next.encoded(), encoded)
            now += 0.1
        }
    }

    func testDeferredActionMatchesFrozenConnectedClockAndNativeAdmission() {
        func request(_ flags: UInt32) -> BoundROMRequest {
            .init(sequence: 2, command: .none, friendIndex: 0, argument: 0, identifier: owner,
                  settings: Data(repeating: 0, count: 32), flags: flags, frame: 1, requestID: 1)
        }
        for command in [BoundROMCommand.battle, .trade, .watch] {
            for flags: UInt32 in [0, 1, 2, 4, 65, 67, 69] {
                var old = SDKPhase5AActionQueue(), current = BoundROMActionQueue()
                old.enqueue(command, at: 100); current.enqueue(command, at: 100)
                for (time, connected) in [(100.0, true), (103, true), (102, true), (104, false),
                                          (10000, false), (10001, true), (10005, true), (10020, true)] {
                    XCTAssertEqual(old.ready(request: request(flags), connected: connected, at: time),
                                   current.ready(request: request(flags), connected: connected, at: time))
                    XCTAssertEqual(old.command, current.command)
                }
                old.clear(); current.clear()
                XCTAssertEqual(old.ready(request: request(65), connected: true, at: 10021),
                               current.ready(request: request(65), connected: true, at: 10021))
                XCTAssertNil(current.command)
            }
        }
    }

    func testCancellationMatchesFrozenDurabilityAndTimeoutTransitions() {
        for requested in [false, true] {
            for requestDurable in [false, true] {
                var old = SDKPhase5ACancellation(), current = BoundSDKCheckpointCancellation()
                if requested {
                    XCTAssertEqual(String(describing: old.request(at: 100, durable: requestDurable)),
                                   String(describing: current.request(at: 100, durable: requestDurable)))
                }
                for durable in [false, true] {
                    for localSafe in [false, true] {
                        for peerSafe: Bool? in [nil, false, true] {
                            for now in [99.0, 100, 107.999, 108, 129.999, 130, 1000] {
                                XCTAssertEqual(String(describing: old.action(at: now, startedAt: 100, localSafe: localSafe,
                                                                           peerSafe: peerSafe, durable: durable)),
                                               String(describing: current.action(at: now, startedAt: 100, localSafe: localSafe,
                                                                               peerSafe: peerSafe, durable: durable)))
                            }
                        }
                    }
                    for acknowledgement in [false, true] {
                        XCTAssertEqual(String(describing: old.receive(acknowledgement: acknowledgement, durable: durable)),
                                       String(describing: current.receive(acknowledgement: acknowledgement, durable: durable)))
                    }
                }
                XCTAssertEqual(old.requestedAt, current.requestedAt)
            }
        }
    }
}
