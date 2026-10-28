import Foundation
import XCTest
import DeltaCore

final class AudioRingBufferTests: XCTestCase {
    private func write(_ bytes: [UInt8], to ring: RingBuffer) -> Int {
        bytes.withUnsafeBytes { ring.write($0.baseAddress!, size: $0.count) }
    }

    private func read(_ count: Int, from ring: RingBuffer) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xEE, count: count)
        let copied = bytes.withUnsafeMutableBytes { ring.read(into: $0.baseAddress!, preferredSize: $0.count) }
        return Array(bytes.prefix(copied))
    }

    func testFullBufferDropsWholeChunkWithoutDiscardingQueuedFrames() throws {
        let ring = try XCTUnwrap(RingBuffer(preferredBufferSize: 32))
        let capacity = ring.availableBytesForWriting
        let queued = (0..<(capacity - 4)).map { UInt8(truncatingIfNeeded: $0) }
        XCTAssertEqual(write(queued, to: ring), queued.count)
        XCTAssertEqual(write([1,2,3,4,5,6,7,8], to: ring), 0)
        XCTAssertEqual(ring.availableBytesForReading, queued.count)
        XCTAssertEqual(ring.availableBytesForWriting, 4)
        XCTAssertEqual(read(capacity, from: ring), queued)
        XCTAssertEqual(ring.availableBytesForWriting, capacity)
        let full = [UInt8](repeating: 0x37, count: capacity)
        XCTAssertEqual(write(full, to: ring), capacity)
        XCTAssertEqual(write([1,2,3,4], to: ring), 0)
        XCTAssertEqual(read(capacity, from: ring), full)
        XCTAssertEqual(write([9,8,7,6], to: ring), 4)
        XCTAssertEqual(read(4, from: ring), [9,8,7,6])
    }

    func testMirroredMappingPreservesFIFOAcrossWraparound() throws {
        let ring = try XCTUnwrap(RingBuffer(preferredBufferSize: 32))
        let capacity = ring.availableBytesForWriting
        let first = (0..<(capacity - 8)).map { UInt8(truncatingIfNeeded: $0) }
        XCTAssertEqual(write(first, to: ring), first.count)
        XCTAssertEqual(read(capacity - 16, from: ring), Array(first.prefix(capacity - 16)))
        let second = (0..<32).map { UInt8(200 + $0) }
        XCTAssertEqual(write(second, to: ring), second.count)
        XCTAssertEqual(read(40, from: ring), Array(first.suffix(8)) + second)
        XCTAssertEqual(ring.availableBytesForReading, 0)
        XCTAssertEqual(ring.availableBytesForWriting, capacity)
    }

    func testUnderrunCopiesAvailableFramesAndLeavesRemainingOutputUntouched() throws {
        let ring = try XCTUnwrap(RingBuffer(preferredBufferSize: 32))
        let queued = Array(UInt8(1)...UInt8(16))
        XCTAssertEqual(write(queued, to: ring), 16)
        var output = [UInt8](repeating: 0xEE, count: 64)
        let copied = output.withUnsafeMutableBytes { ring.read(into: $0.baseAddress!, preferredSize: $0.count) }
        XCTAssertEqual(copied, 16)
        XCTAssertEqual(Array(output.prefix(16)), queued)
        XCTAssertEqual(Array(output.dropFirst(16)), [UInt8](repeating: 0xEE, count: 48))
        XCTAssertEqual(read(64, from: ring), [])
        XCTAssertEqual(write([4,3,2,1], to: ring), 4)
        XCTAssertEqual(read(64, from: ring), [4,3,2,1])
    }

    func testInvalidSizesDoNotCopyOrChangeCounts() throws {
        XCTAssertNil(RingBuffer(preferredBufferSize: 0))
        XCTAssertNil(RingBuffer(preferredBufferSize: -1))
        XCTAssertNil(RingBuffer(preferredBufferSize: Int.max))
        let ring = try XCTUnwrap(RingBuffer(preferredBufferSize: 32))
        let capacity = ring.availableBytesForWriting
        var value: UInt32 = 0x12345678
        withUnsafeMutableBytes(of: &value) { bytes in
            for size in [0, -1, Int.min] {
                XCTAssertEqual(ring.write(bytes.baseAddress!, size: size), 0)
                XCTAssertEqual(ring.read(into: bytes.baseAddress!, preferredSize: size), 0)
            }
        }
        XCTAssertEqual(value, 0x12345678)
        XCTAssertEqual(ring.availableBytesForReading, 0)
        XCTAssertEqual(ring.availableBytesForWriting, capacity)
    }

    func testDisabledBufferPreservesQueuedDataUntilEnabledOrExplicitlyReset() throws {
        let ring = try XCTUnwrap(RingBuffer(preferredBufferSize: 32))
        XCTAssertEqual(write([1,2,3,4], to: ring), 4)
        ring.isEnabled = false
        XCTAssertEqual(write([5,6,7,8], to: ring), 0)
        XCTAssertEqual(read(4, from: ring), [])
        XCTAssertEqual(ring.availableBytesForReading, 4)
        ring.isEnabled = true
        XCTAssertEqual(read(8, from: ring), [1,2,3,4])
        XCTAssertEqual(write([9,10,11,12], to: ring), 4)
        ring.reset()
        XCTAssertEqual(ring.availableBytesForReading, 0)
        XCTAssertEqual(write([13,14,15,16], to: ring), 4)
        XCTAssertEqual(read(8, from: ring), [13,14,15,16])
    }

    func testConcurrentSingleProducerConsumerPreservesFramesAndRecoversFromBackpressure() throws {
        let state = StressState(ring: try XCTUnwrap(RingBuffer(preferredBufferSize: 64)))
        let group = DispatchGroup()
        let frameCount = 100_000
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        group.enter()
        DispatchQueue(label: "bound.tests.audio-producer", qos: .userInitiated).async {
            defer { group.leave() }
            var next = 0
            var frames = [UInt64](repeating: 0, count: 31)
            while next < frameCount {
                guard ProcessInfo.processInfo.systemUptime < deadline else { state.fail("Producer timed out"); return }
                let count = min(frames.count, frameCount - next)
                for index in 0..<count { frames[index] = Self.frame(next + index) }
                let written = frames.withUnsafeBytes { state.ring.write($0.baseAddress!, size: count * 8) }
                guard written == 0 || written == count * 8 else { state.fail("Producer split a frame chunk"); return }
                next += written / 8
            }
        }
        group.enter()
        DispatchQueue(label: "bound.tests.audio-consumer", qos: .userInitiated).async {
            defer { group.leave() }
            var next = 0
            var frames = [UInt64](repeating: 0, count: 67)
            while next < frameCount {
                guard ProcessInfo.processInfo.systemUptime < deadline else { state.fail("Consumer timed out"); return }
                let copied = frames.withUnsafeMutableBytes { state.ring.read(into: $0.baseAddress!, preferredSize: $0.count) }
                guard copied % 8 == 0 else { state.fail("Consumer split a PCM frame"); return }
                for index in 0..<(copied / 8) {
                    guard frames[index] == Self.frame(next) else { state.fail("FIFO/frame corruption at frame \(next)"); return }
                    next += 1
                }
            }
        }
        group.enter()
        DispatchQueue(label: "bound.tests.audio-lifecycle", qos: .userInitiated).async {
            defer { state.ring.isEnabled = true; group.leave() }
            for index in 0..<10_000 { state.ring.isEnabled = index % 2 == 0 }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.ring.availableBytesForReading, 0)
    }

    private static func frame(_ index: Int) -> UInt64 {
        UInt64(UInt32(index)) | UInt64(UInt32(index) ^ 0xA5A5_A5A5) << 32
    }

    private final class StressState: @unchecked Sendable {
        let ring: RingBuffer
        private let lock = NSLock()
        private var message: String?
        init(ring: RingBuffer) { self.ring = ring }
        func fail(_ message: String) { lock.lock(); defer { lock.unlock() }; if self.message == nil { self.message = message } }
        var failure: String? { lock.lock(); defer { lock.unlock() }; return message }
    }
}
