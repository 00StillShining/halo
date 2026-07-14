import XCTest
@testable import Halo

/// Pins the preallocated SPSC ring buffer used to bridge the input AUHAL to the
/// output AUHAL (Brief §8). The buffer is the correctness-critical seam of the
/// monitor path, so these tests exercise capacity rounding, partial writes/reads,
/// wraparound and underrun/overrun.
final class AudioRingBufferTests: XCTestCase {

    private func writeRead(_ ring: AudioRingBuffer, values: [Float]) -> Int {
        var v = values
        return v.withUnsafeMutableBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    }

    func testCapacityRoundsUpToPowerOfTwo() {
        XCTAssertEqual(AudioRingBuffer(minimumCapacity: 100).capacity, 128)
        XCTAssertEqual(AudioRingBuffer(minimumCapacity: 128).capacity, 128)
        XCTAssertEqual(AudioRingBuffer(minimumCapacity: 129).capacity, 256)
        XCTAssertEqual(AudioRingBuffer(minimumCapacity: 1).capacity, 2)
    }

    func testWriteThenReadRoundTrips() {
        let ring = AudioRingBuffer(minimumCapacity: 16)
        let input: [Float] = [1, 2, 3, 4, 5]
        XCTAssertEqual(writeRead(ring, values: input), 5)
        XCTAssertEqual(ring.availableToRead, 5)

        var out = [Float](repeating: -1, count: 5)
        let got = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 5) }
        XCTAssertEqual(got, 5)
        XCTAssertEqual(out, input)
        XCTAssertEqual(ring.availableToRead, 0)
    }

    func testOverrunWritesOnlyWhatFits() {
        let ring = AudioRingBuffer(minimumCapacity: 4)   // capacity 4
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(writeRead(ring, values: input), 4)   // only 4 fit
        XCTAssertEqual(ring.availableToWrite, 0)
    }

    func testUnderrunReadsOnlyWhatIsAvailable() {
        let ring = AudioRingBuffer(minimumCapacity: 8)
        _ = writeRead(ring, values: [1, 2, 3])
        var out = [Float](repeating: -1, count: 8)
        let got = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 8) }
        XCTAssertEqual(got, 3)
        XCTAssertEqual(Array(out.prefix(3)), [1, 2, 3])
    }

    func testWraparoundPreservesOrder() {
        let ring = AudioRingBuffer(minimumCapacity: 4)   // capacity 4
        // Fill, drain most, then write across the wrap boundary.
        _ = writeRead(ring, values: [1, 2, 3, 4])
        var out = [Float](repeating: 0, count: 3)
        _ = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 3) }
        XCTAssertEqual(out, [1, 2, 3])

        // 1 remaining (value 4), 3 free — write 3 more that wrap.
        XCTAssertEqual(writeRead(ring, values: [5, 6, 7]), 3)
        var out2 = [Float](repeating: 0, count: 4)
        let got = out2.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 4) }
        XCTAssertEqual(got, 4)
        XCTAssertEqual(out2, [4, 5, 6, 7])
    }

    func testDrainDiscardsBufferedSamples() {
        let ring = AudioRingBuffer(minimumCapacity: 8)
        _ = writeRead(ring, values: [1, 2, 3, 4])
        ring.drain()
        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertEqual(ring.availableToWrite, ring.capacity)
    }

    /// Interleave many writes/reads (single producer, single consumer sequentially)
    /// across the wrap many times; the stream must reproduce exactly.
    func testLongStreamThroughWrapIsLossless() {
        let ring = AudioRingBuffer(minimumCapacity: 64)
        var nextWrite: Float = 0
        var nextExpectedRead: Float = 0
        for step in 0..<2000 {
            let chunk = (step % 7) + 1
            var block = (0..<chunk).map { _ -> Float in defer { nextWrite += 1 }; return nextWrite }
            let wrote = block.withUnsafeMutableBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
            // If not everything fit, roll back the counter for the unwritten tail.
            nextWrite -= Float(block.count - wrote)

            var out = [Float](repeating: -999, count: chunk)
            let got = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: chunk) }
            for i in 0..<got {
                XCTAssertEqual(out[i], nextExpectedRead, "mismatch at step \(step)")
                nextExpectedRead += 1
            }
        }
    }
}
