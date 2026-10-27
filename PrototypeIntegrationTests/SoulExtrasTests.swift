import Foundation
import XCTest
@testable import Delta

final class SoulExtrasTests: XCTestCase {
    private func packet(_ category: String = "gift", rows: [BoundSoulRow] = []) -> BoundSoulExtrasPacket {
        .init(category: category, run: UUID(), sender: UUID(), receiver: UUID(),
              acquired: BoundSoulExtrasPacket.bits(["\(category):1", "\(category):2048"], category: category),
              losses: BoundSoulExtrasPacket.bits(["\(category):1"], category: category),
              boxed: BoundSoulExtrasPacket.bits(["\(category):2048"], category: category), rows: rows)
    }
    func testWorstCasePacketCarriesCompleteFactsAndTwoUnicodeNames() throws {
        for category in ["gift", "static"] {
            let value = packet(category, rows: [1, 2048].map {
                .init(slot: "\(category):\($0)", name: String(repeating: "🐉", count: 20), dead: $0 == 1)
            })
            let bytes = try XCTUnwrap(value.encoded())
            XCTAssertEqual(bytes.count, 990)
            let decoded = try XCTUnwrap(BoundSoulExtrasPacket.decode(bytes))
            XCTAssertEqual(decoded.category, category)
            XCTAssertEqual(decoded.run, value.run); XCTAssertEqual(decoded.sender, value.sender); XCTAssertEqual(decoded.receiver, value.receiver)
            XCTAssertEqual(decoded.acquired, value.acquired); XCTAssertEqual(decoded.losses, value.losses); XCTAssertEqual(decoded.boxed, value.boxed)
            XCTAssertEqual(decoded.rows.map(\.slot), value.rows.map(\.slot))
            XCTAssertEqual(decoded.rows.map(\.name), value.rows.map(\.name))
            XCTAssertEqual(decoded.rows.map(\.dead), value.rows.map(\.dead))
        }
    }
    func testEmptyCategoryPacketsAdvertiseCompleteFactsAndCategoriesStayIndependent() throws {
        let value = packet("static")
        let bytes = try XCTUnwrap(value.encoded())
        XCTAssertEqual(bytes.count, 822)
        XCTAssertTrue(BoundSoulExtrasPacket.recognizes(bytes))
        XCTAssertEqual(try XCTUnwrap(BoundSoulExtrasPacket.decode(bytes)).rows.count, 0)
        let all = Set((1...2048).map { "gift:\($0)" })
        XCTAssertEqual(BoundSoulExtrasPacket.slots(BoundSoulExtrasPacket.bits(all, category: "gift"), category: "gift"), all)
        XCTAssertEqual(BoundSoulExtrasPacket.slots(BoundSoulExtrasPacket.bits(["egg:1", "area:100", "static:1"], category: "gift"), category: "gift"), [])
        XCTAssertEqual(BoundSoulExtrasPacket.slots(Data(repeating: 255, count: 255), category: "gift"), [])
        XCTAssertEqual(BoundSoulExtrasPacket.slots(Data(repeating: 255, count: 256), category: "egg"), [])
    }
    func testEncoderRejectsMixedDuplicateNoncanonicalAndOutOfRangeRows() {
        for slot in ["static:1", "egg:1", "gift:0", "gift:2049", "gift:01", "gift:+1", "gift:1:2"] {
            XCTAssertNil(packet(rows: [.init(slot: slot, name: "Mon", dead: false)]).encoded())
        }
        let row = BoundSoulRow(slot: "gift:1", name: "Mon", dead: false)
        XCTAssertNil(packet(rows: [row, row]).encoded())
        XCTAssertNil(packet(rows: [row, row, row]).encoded())
        XCTAssertNil(packet("egg").encoded())
        XCTAssertNil(packet(rows: [.init(slot: "gift:1", name: String(repeating: "A", count: 21), dead: false)]).encoded())
        XCTAssertNil(packet(rows: [.init(slot: "gift:1", name: String(repeating: "e\u{301}", count: 40), dead: false)]).encoded())
        let value = packet()
        XCTAssertNil(BoundSoulExtrasPacket(category: value.category, run: value.run, sender: value.sender, receiver: value.receiver,
                                          acquired: Data(), losses: value.losses, boxed: value.boxed).encoded())
    }
    func testDecoderRejectsTruncationTrailingBytesUnknownKindsAndInvalidBooleans() throws {
        let bytes = try XCTUnwrap(packet(rows: [.init(slot: "gift:1", name: "Mon", dead: false)]).encoded())
        for length in 0..<bytes.count { XCTAssertNil(BoundSoulExtrasPacket.decode(bytes.prefix(length))) }
        var changed = bytes; changed.append(0); XCTAssertNil(BoundSoulExtrasPacket.decode(changed))
        changed = bytes; changed[4] = 2; XCTAssertNil(BoundSoulExtrasPacket.decode(changed))
        changed = bytes; changed[821] = 3; XCTAssertNil(BoundSoulExtrasPacket.decode(changed))
        changed = bytes; changed[824] = 2; XCTAssertNil(BoundSoulExtrasPacket.decode(changed))
        changed = bytes; changed[0] = 0; XCTAssertNil(BoundSoulExtrasPacket.decode(changed))
        XCTAssertFalse(BoundSoulExtrasPacket.recognizes(changed))
    }
    func testDecoderRejectsDuplicateOrdinalOutOfRangeAndMalformedUTF8() throws {
        let bytes = try XCTUnwrap(packet(rows: [1, 2].map { .init(slot: "gift:\($0)", name: "A", dead: false) }).encoded())
        var changed = bytes; changed[827] = 1; XCTAssertNil(BoundSoulExtrasPacket.decode(changed))
        changed = bytes; changed[822] = 0; changed[823] = 0; XCTAssertNil(BoundSoulExtrasPacket.decode(changed))
        changed = bytes; changed[822] = 1; changed[823] = 8; XCTAssertNil(BoundSoulExtrasPacket.decode(changed))
        changed = bytes; changed[826] = 255; XCTAssertNil(BoundSoulExtrasPacket.decode(changed))
        changed = bytes; changed[825] = 81; XCTAssertNil(BoundSoulExtrasPacket.decode(changed))
    }
    func testReadinessRequiresBothFreshBaselinesAndExpiresWithoutAnEpochChange() {
        var readiness = BoundSoulExtrasReadiness()
        XCTAssertFalse(readiness.ready(at: 100))
        readiness.mark(category: "gift", at: 100)
        XCTAssertFalse(readiness.ready(at: 100))
        readiness.mark(category: "static", at: 100.1)
        XCTAssertTrue(readiness.ready(at: 100.2))
        XCTAssertFalse(readiness.ready(at: 103), "Each baseline expires at three seconds")
        XCTAssertFalse(readiness.ready(at: 103.2), "A fresh primary heartbeat cannot renew either supplemental category")
        readiness.mark(category: "gift", at: 103.3)
        XCTAssertFalse(readiness.ready(at: 103.4), "Renewing only one category leaves the other baseline stale")
        readiness.mark(category: "static", at: 103.4)
        XCTAssertTrue(readiness.ready(at: 103.5))
        XCTAssertFalse(readiness.ready(at: 103), "Clock reversal must not make future receipts fresh")
        readiness.reset()
        XCTAssertFalse(readiness.ready(at: 103.5))
        readiness.mark(category: "egg", at: 104)
        readiness.mark(category: "area", at: 104)
        XCTAssertFalse(readiness.ready(at: 104), "Unrelated packet categories cannot establish readiness")
        readiness.mark(category: "gift", at: .nan)
        readiness.mark(category: "static", at: .infinity)
        XCTAssertFalse(readiness.ready(at: 104))
        XCTAssertFalse(readiness.ready(at: .nan))
    }

}
