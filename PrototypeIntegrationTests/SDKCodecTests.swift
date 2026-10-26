import Foundation
import XCTest
@testable import Delta

final class SDKCodecTests: XCTestCase {
    private let first = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let second = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    private let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private func put(_ value: UInt32, _ bytes: inout Data, _ offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }

    private func request(_ value: Phase4ROMRequest?) -> BoundROMRequest? {
        value.map { .init(sequence: $0.sequence, command: $0.command, friendIndex: $0.friendIndex,
                          argument: $0.argument, identifier: $0.identifier, settings: $0.settings,
                          flags: $0.flags, frame: $0.frame, requestID: $0.requestID,
                          debugSetup: $0.debugSetup, setupError: $0.setupError) }
    }

    func testRequestCodecPreservesValidInvalidAndReservedCommandDecisions() {
        var valid = Data((0..<256).map { UInt8(truncatingIfNeeded: $0 * 37) })
        valid.replaceSubrange(0..<8, with: [82, 85, 82, 49, 1, 0, 0, 0])
        put(2, &valid, 8); put(0, &valid, 12)
        for command in Array(UInt32(0)...UInt32(31)) + [UInt32.max] {
            for sequence: UInt32 in [0, 1, 2, 3, UInt32.max - 1, UInt32.max] {
                var data = valid; put(command, &data, 12); put(sequence, &data, 8)
                XCTAssertEqual(BoundROMRequest.decode(data), request(Phase4ROMRequest.decode(data)))
            }
        }
        for count in 0...257 {
            let data = count <= 256 ? Data(valid.prefix(count)) : valid + Data([0])
            XCTAssertEqual(BoundROMRequest.decode(data), request(Phase4ROMRequest.decode(data)), "length \(count)")
        }
        for offset in 0..<valid.count {
            var data = valid; data[offset] ^= 0xFF
            XCTAssertEqual(BoundROMRequest.decode(data), request(Phase4ROMRequest.decode(data)), "byte \(offset)")
        }
        for command: UInt32 in 18...27 {
            var data = valid; put(command, &data, 12)
            XCTAssertNotNil(BoundROMRequest.decode(data), "Reserved commands remain admitted by the original codec")
        }
    }

    private func host(_ value: BoundROMHostState) -> Phase4ROMHostState {
        var old = Phase4ROMHostState()
        old.enabled = value.enabled; old.linked = value.linked; old.connected = value.connected
        old.chooser = value.chooser; old.setupCommitted = value.setupCommitted; old.externalSetup = value.externalSetup
        old.debugPlayer = value.debugPlayer; old.playerProfile = value.playerProfile; old.restartSetup = value.restartSetup
        old.recovery = value.recovery; old.saving = value.saving; old.transferRequired = value.transferRequired
        old.ended = value.ended; old.acknowledgedRequest = value.acknowledgedRequest; old.status = value.status
        old.run = value.run; old.localSeed = value.localSeed; old.partnerSeed = value.partnerSeed
        old.settings = value.settings; old.partnerName = value.partnerName; old.message = value.message
        old.friends = value.friends.map { .init(room: $0.room, name: $0.name, status: $0.status) }
        old.peerCollision = value.peerCollision; old.page = value.page
        return old
    }

    func testHostInputPreservesEveryByteIncludingTruncationTextAndReservedSpace() throws {
        let poseData = try JSONSerialization.data(withJSONObject: [
            "mapGroup": 42, "mapNumber": 255, "elevation": 15, "x": -96, "y": 16,
            "facing": 1, "frameAddress": 0x08000000, "palette": Data(repeating: 0, count: 32).base64EncodedString(),
            "flipX": false, "flipY": false, "priority": 0])
        let collision = try XCTUnwrap(BoundPresenceCollision(pose: JSONDecoder().decode(BoundPresencePose.self, from: poseData)))
        for bits in 0..<2048 {
            var value = BoundROMHostState()
            value.enabled = bits & 1 != 0; value.linked = bits & 2 != 0; value.connected = bits & 4 != 0
            value.chooser = bits & 8 != 0; value.setupCommitted = bits & 16 != 0; value.recovery = bits & 32 != 0
            value.saving = bits & 64 != 0; value.transferRequired = bits & 128 != 0; value.ended = bits & 256 != 0
            value.restartSetup = bits & 512 != 0; value.externalSetup = bits & 1024 != 0
            value.debugPlayer = UInt8(truncatingIfNeeded: bits); value.acknowledgedRequest = UInt32.max
            value.status = BoundROMStatus(rawValue: UInt32(bits % 10))!
            value.run = bits & 1 == 0 ? nil : first; value.localSeed = 0; value.partnerSeed = UInt32.max
            value.settings = Data(repeating: 0xA5, count: [0, 31, 32, 33][bits % 4])
            value.partnerName = "Léaf\n全角Ａ 🙂" + String(repeating: "x", count: bits % 40)
            value.message = String(repeating: "A\nß🙂", count: bits % 80)
            value.friends = (0..<[0, 1, 20, 21][bits % 4]).map { .init(room: second, name: "Friend \($0) Å", status: UInt32($0)) }
            value.peerCollision = collision; value.page = UInt32(bits)
            value.playerProfile = [nil, .init(name: "Leaf123", gender: 1), .init(name: "bad name", gender: 0), .init(name: "Ash", gender: 3)][bits % 4]
            let sequence = [UInt32(0), 1, 2, UInt32.max - 1, UInt32.max][bits % 5]
            XCTAssertEqual(value.encoded(sequence: sequence), host(value).encoded(sequence: sequence), "flags \(bits)")
        }
    }

    private func packet(_ value: Phase4ROMPacket?) -> BoundROMPacket? {
        value.map { .init(kind: BoundROMPacket.Kind(rawValue: $0.kind.rawValue)!, owner: $0.owner,
                          epoch: $0.epoch, receiver: $0.receiver, sequence: $0.sequence, body: $0.body) }
    }

    func testReliableEnvelopeMatchesFrozenEncoderAndMalformedAdmission() throws {
        for kind in UInt8(0)...10 {
            for sequence: UInt64 in [0, 1, UInt64.max] {
                for count in [0, 1, 960, 961] {
                    for owner in [first, zero] {
                        let body = Data(repeating: 0xA5, count: count)
                        let now = BoundROMPacket(kind: .init(rawValue: kind)!, owner: owner, epoch: second,
                                                 receiver: nil, sequence: sequence, body: body).encoded()
                        let old = Phase4ROMPacket(kind: .init(rawValue: kind)!, owner: owner, epoch: second,
                                                  receiver: nil, sequence: sequence, body: body).encoded()
                        XCTAssertEqual(now, old)
                        if let now { XCTAssertEqual(BoundROMPacket.decode(now), packet(Phase4ROMPacket.decode(now))) }
                    }
                }
            }
        }
        let valid = try XCTUnwrap(BoundROMPacket(kind: .settings, owner: first, epoch: second,
                                                receiver: first, sequence: UInt64.max, body: Data(repeating: 0x5A, count: 960)).encoded())
        for offset in 0..<valid.count {
            var data = valid; data[offset] ^= 0xFF
            XCTAssertEqual(BoundROMPacket.decode(data), packet(Phase4ROMPacket.decode(data)), "byte \(offset)")
        }
        for count in 0...1025 {
            let data = count <= 1024 ? Data(valid.prefix(count)) : valid + Data([0])
            XCTAssertEqual(BoundROMPacket.decode(data), packet(Phase4ROMPacket.decode(data)), "length \(count)")
        }
    }

    private func world(_ value: Phase4WorldPacket?) -> BoundWorldPacket? {
        value.map { .init(sender: $0.sender, receiver: $0.receiver, sequence: $0.sequence,
                          state: .init(group: $0.state.group, number: $0.state.number,
                                       checkpoints: $0.state.checkpoints, boulders: $0.state.boulders)) }
    }

    func testWorldEnvelopePreservesOpaqueBytesCompatibilityAndGameValidation() throws {
        var valid: Data?
        for group: UInt8 in [0, 42, 43, 255] {
            for count in [0, 1, 16, 17] {
                for sequence: UInt64 in [0, 1, UInt64.max] {
                    let boulders = Data((0..<count).flatMap { [UInt8($0 + 1), 15, 3, 4, 5, 6] })
                    let state = BoundWorldState(group: group, number: 255, checkpoints: Data(repeating: 0xCC, count: 800), boulders: boulders)
                    let now = BoundWorldPacket(sender: first, receiver: second, sequence: sequence, state: state).encoded()
                    let old = Phase4WorldPacket(sender: first, receiver: second, sequence: sequence,
                        state: .init(group: group, number: 255, checkpoints: state.checkpoints, boulders: boulders)).encoded()
                    XCTAssertEqual(now, old)
                    if let now {
                        XCTAssertEqual(BoundWorldPacket.decode(now), world(Phase4WorldPacket.decode(now)))
                        if count == 16 { valid = now }
                    }
                }
            }
        }
        let bytes = try XCTUnwrap(valid)
        for offset in 0..<bytes.count {
            var data = bytes; data[offset] ^= 0xFF
            XCTAssertEqual(BoundWorldPacket.decode(data), world(Phase4WorldPacket.decode(data)), "byte \(offset)")
        }
        for count in 0...968 {
            let data = count <= bytes.count ? Data(bytes.prefix(count)) : bytes + Data([0])
            XCTAssertEqual(BoundWorldPacket.decode(data), world(Phase4WorldPacket.decode(data)), "length \(count)")
        }
    }
}
