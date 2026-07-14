import XCTest
@testable import Halo

/// Pins the two guarantees of the −1 dBFS safety limiter (Brief §8): output never
/// exceeds the ceiling, and it is bit-transparent while the signal stays under it.
final class SafetyLimiterTests: XCTestCase {

    private func process(_ limiter: inout SafetyLimiter, _ interleaved: [Float]) -> [Float] {
        var buf = interleaved
        let frames = interleaved.count / 2
        buf.withUnsafeMutableBufferPointer { limiter.processStereo($0.baseAddress!, frames: frames) }
        return buf
    }

    func testNeverExceedsCeilingOnLoudSignal() {
        var limiter = SafetyLimiter(sampleRate: 48_000)
        // A full-scale-plus block on both channels (well above the ceiling).
        var block = [Float]()
        for i in 0..<4096 {
            let phase = Float(i) / 48_000 * 1_000 * 2 * .pi
            let s = sin(phase) * 1.8            // +5 dBFS peaks
            block.append(s); block.append(-s)
        }
        let out = process(&limiter, block)
        let maxOut = out.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(maxOut, SafetyLimiter.ceiling + 1e-6,
                                 "limiter must brick-wall at −1 dBFS")
    }

    func testExtremeImpulseIsClamped() {
        var limiter = SafetyLimiter(sampleRate: 48_000)
        // Alternating huge spikes — worst case for a zero-lookahead limiter.
        var block = [Float]()
        for i in 0..<1024 {
            let s: Float = (i % 2 == 0) ? 9.0 : -9.0
            block.append(s); block.append(s)
        }
        let out = process(&limiter, block)
        let maxOut = out.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(maxOut, SafetyLimiter.ceiling + 1e-6)
    }

    func testBitTransparentBelowCeiling() {
        var limiter = SafetyLimiter(sampleRate: 48_000)
        // A signal comfortably under the ceiling must pass through unchanged.
        var block = [Float]()
        for i in 0..<2048 {
            let phase = Float(i) / 48_000 * 440 * 2 * .pi
            let s = sin(phase) * 0.5            // −6 dBFS, below −1 dBFS ceiling
            block.append(s); block.append(s * 0.9)
        }
        let out = process(&limiter, block)
        for (a, b) in zip(block, out) {
            XCTAssertEqual(a, b, "below-ceiling signal must be bit-transparent")
        }
        XCTAssertEqual(limiter.gain, 1, accuracy: 0, "gain stays at exactly unity")
    }

    func testExactlyAtCeilingIsTransparent() {
        var limiter = SafetyLimiter(sampleRate: 48_000)
        let c = SafetyLimiter.ceiling
        let block: [Float] = [c, -c, c, -c]
        let out = process(&limiter, block)
        XCTAssertEqual(out, block, "a signal exactly at the ceiling is untouched")
    }
}
