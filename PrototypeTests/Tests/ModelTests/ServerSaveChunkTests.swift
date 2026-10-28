import XCTest
@testable import Models

final class ServerSaveChunkTests: XCTestCase {
    func testExactServerPagesReassembleEveryPaddingAndPageBoundary() {
        for count in [1, 2, 3, 8999, 9000, 9001, 9002, 9003, 18000, 18001] {
            let original = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
            let encoded = Array(original.base64EncodedString().utf8)
            var restored = Data()
            for offset in stride(from: 0, to: encoded.count, by: 12000) {
                let chunk = String(decoding: encoded[offset..<min(offset + 12000, encoded.count)], as: UTF8.self)
                XCTAssertTrue(BoundServerSaveChunks.valid(chunk, index: offset / 12000, byteCount: count))
                restored.append(Data(base64Encoded: chunk)!)
            }
            XCTAssertEqual(restored, original)
        }
    }
    func testTruncatedOversizedInvalidAndNoncanonicalPagesAreRejected() {
        for chunk in ["", "AA==", String(repeating: "A", count: 11996), String(repeating: "A", count: 12004), String(repeating: "!", count: 12000)] {
            XCTAssertFalse(BoundServerSaveChunks.valid(chunk, index: 0, byteCount: 18000))
        }
        XCTAssertTrue(BoundServerSaveChunks.valid("Zg==", index: 1, byteCount: 9001))
        XCTAssertFalse(BoundServerSaveChunks.valid("Zh==", index: 1, byteCount: 9001))
        XCTAssertFalse(BoundServerSaveChunks.valid("Zg=", index: 1, byteCount: 9001))
        XCTAssertFalse(BoundServerSaveChunks.valid("Zm8=", index: 1, byteCount: 9001))
    }
    func testInvalidSizesAndOutOfRangeIndexesRemainBounded() {
        for count in [Int.min, -1, 0, 16_777_217, Int.max] {
            XCTAssertFalse(BoundServerSaveChunks.valid("AA==", index: 0, byteCount: count))
        }
        for index in [Int.min, -1, 1, Int.max] {
            XCTAssertFalse(BoundServerSaveChunks.valid("AA==", index: index, byteCount: 1))
        }
    }
}
