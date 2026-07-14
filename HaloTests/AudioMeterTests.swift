import XCTest
@testable import Halo

/// Pins the meter math (Brief §8 metering) and the honesty invariant that a fresh
/// meter reads silence until real audio is published.
final class AudioMeterTests: XCTestCase {

    func testPeakFindsMaxAbs() {
        let block: [Float] = [0.2, -0.9, 0.5, -0.1]   // interleaved: L=[0.2,0.5], R=[-0.9,-0.1]
        block.withUnsafeBufferPointer { p in
            XCTAssertEqual(MeterMath.peak(p.baseAddress!, frames: 2, stride: 2, channel: 0), 0.5, accuracy: 1e-6)
            XCTAssertEqual(MeterMath.peak(p.baseAddress!, frames: 2, stride: 2, channel: 1), 0.9, accuracy: 1e-6)
        }
    }

    func testRMSOfFullScaleSquareIsOne() {
        let block: [Float] = [1, -1, -1, 1]   // |x| = 1 everywhere
        block.withUnsafeBufferPointer { p in
            XCTAssertEqual(MeterMath.rms(p.baseAddress!, frames: 2, stride: 2, channel: 0), 1, accuracy: 1e-6)
            XCTAssertEqual(MeterMath.rms(p.baseAddress!, frames: 2, stride: 2, channel: 1), 1, accuracy: 1e-6)
        }
    }

    func testLinearToDBLandmarks() {
        XCTAssertEqual(MeterMath.linearToDB(1), 0, accuracy: 1e-5)
        XCTAssertEqual(MeterMath.linearToDB(0.5), -6.0206, accuracy: 1e-3)
        XCTAssertEqual(MeterMath.linearToDB(0), -.infinity)
    }

    func testBallisticAttackIsFasterThanRelease() {
        // Rising sample jumps most of the way; falling sample decays slowly.
        let rise = MeterMath.ballistic(previous: 0, sample: 1, attack: 1, release: 0.01)
        XCTAssertEqual(rise, 1, accuracy: 1e-6)
        let fall = MeterMath.ballistic(previous: 1, sample: 0, attack: 1, release: 0.01)
        XCTAssertGreaterThan(fall, 0.9, "release holds the meter up briefly")
    }

    func testFreshMeterReadsSilence() {
        let meter = AudioMeter()
        XCTAssertEqual(meter.snapshot(), .silence)
    }

    func testPublishedFullScaleShowsClipAndZeroDBFS() {
        let meter = AudioMeter(sampleRate: 48_000)
        var block = [Float](repeating: 1, count: 512)   // full-scale both channels
        block.withUnsafeMutableBufferPointer { meter.publish($0.baseAddress!, frames: 256) }
        let snap = meter.snapshot()
        XCTAssertEqual(snap.peakL, 0, accuracy: 1e-4, "full scale is 0 dBFS")
        XCTAssertTrue(snap.clippedL, "full scale latches the clip flag")
        XCTAssertTrue(snap.clippedR)
        // Reading cleared the latch.
        XCTAssertFalse(meter.snapshot().clippedL)
    }

    func testClipLatchesFromRawPeaksOnLimitedBuffer() {
        // The render callback publishes the POST-limiter buffer (peaks ≤ 0.891),
        // so clip must come from the raw pre-limiter peaks — pin that seam.
        let meter = AudioMeter(sampleRate: 48_000)
        var limited = [Float](repeating: SafetyLimiter.ceiling, count: 512)
        limited.withUnsafeMutableBufferPointer {
            meter.publish($0.baseAddress!, frames: 256, rawPeakL: 1.4, rawPeakR: 0.7)
        }
        let snap = meter.snapshot()
        XCTAssertTrue(snap.clippedL, "raw overload attempt latches L clip")
        XCTAssertFalse(snap.clippedR, "R never attempted to clip")
        XCTAssertLessThan(snap.peakL, 0, "shown level is the real post-limiter output")
    }

    func testResetReturnsToSilence() {
        let meter = AudioMeter()
        var block = [Float](repeating: 0.8, count: 256)
        block.withUnsafeMutableBufferPointer { meter.publish($0.baseAddress!, frames: 128) }
        meter.reset()
        XCTAssertEqual(meter.snapshot(), .silence)
    }
}
