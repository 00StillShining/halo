import XCTest
import CoreGraphics
@testable import Halo

/// Pins the pure dB→fraction mapping used by the resting stereo meter (DD-014):
/// silence floors to 0, 0 dBFS tops out at 1, each tick sits on its own fraction,
/// and the mapping is monotonic.
final class StereoMeterTests: XCTestCase {

    func testSilenceMapsToZero() {
        XCTAssertEqual(StereoMeter.fraction(dB: -.infinity), 0, accuracy: 1e-6)
        XCTAssertEqual(StereoMeter.fraction(dB: -40), 0, accuracy: 1e-6)
        XCTAssertEqual(StereoMeter.fraction(dB: -60), 0, accuracy: 1e-6)
    }

    func testFullScaleMapsToOne() {
        XCTAssertEqual(StereoMeter.fraction(dB: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(StereoMeter.fraction(dB: 3), 1, accuracy: 1e-6)
    }

    func testEachTickSitsOnItsOwnFraction() {
        let ticks = StereoMeter.tickDBs
        for (i, dB) in ticks.enumerated() {
            let expected = CGFloat(i) / CGFloat(ticks.count - 1)
            XCTAssertEqual(StereoMeter.fraction(dB: dB), expected, accuracy: 1e-5,
                           "tick \(dB) dB should sit at fraction \(expected)")
        }
    }

    func testMinusTwelveSitsOnItsTick() {
        // -12 dB is the third of six ticks → fraction 0.4.
        XCTAssertEqual(StereoMeter.fraction(dB: -12), 0.4, accuracy: 1e-5)
    }

    func testMonotonic() {
        var last = StereoMeter.fraction(dB: -50)
        for dB in stride(from: Float(-40), through: 0, by: 0.5) {
            let f = StereoMeter.fraction(dB: dB)
            XCTAssertGreaterThanOrEqual(f, last, "must not decrease at \(dB) dB")
            last = f
        }
    }
}
