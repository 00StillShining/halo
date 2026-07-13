import XCTest
@testable import Halo

/// The attack/release envelope that smooths audio-responsive `.monitoring`
/// luminance. Pure and deterministic; guards monotonicity, no overshoot, the
/// dt-safety contract, and the 0.55 hard cap at full scale.
final class RingLuminanceSmootherTests: XCTestCase {

    func testRisesTowardTargetWithAttackTimeConstant() {
        var s = RingLuminanceSmoother()
        // After one time-constant (50 ms attack) a one-pole envelope reaches ~1−e⁻¹.
        _ = s.step(target: 1.0, dt: 0.050)
        XCTAssertEqual(s.value, 1 - exp(-1), accuracy: 0.02)
    }

    func testFallsTowardZeroWithReleaseTimeConstant() {
        var s = RingLuminanceSmoother()
        // Prime near full, then release for one 350 ms time-constant.
        for _ in 0..<200 { _ = s.step(target: 1.0, dt: 0.050) }
        let start = s.value
        _ = s.step(target: 0.0, dt: 0.350)
        // Remaining fraction should be ~e⁻¹ of the starting value.
        XCTAssertEqual(s.value, start * exp(-1), accuracy: 0.03)
    }

    func testMonotonicRiseAndNeverOvershoots() {
        var s = RingLuminanceSmoother()
        var last: Float = 0
        for _ in 0..<500 {
            let v = s.step(target: 1.0, dt: 0.016)
            XCTAssertGreaterThanOrEqual(v, last)   // monotonic up
            XCTAssertLessThanOrEqual(v, 1.0)       // never overshoots target
            last = v
        }
    }

    func testZeroAndNegativeDtAreSafe() {
        var s = RingLuminanceSmoother()
        _ = s.step(target: 0.6, dt: 0.050)
        let before = s.value
        XCTAssertEqual(s.step(target: 1.0, dt: 0), before)      // dt=0 → no movement
        XCTAssertEqual(s.step(target: 1.0, dt: -0.5), before)   // negative dt clamped
    }

    func testMonitorCapExactlyAtFullScale() {
        // The monitoring branch maps a fully-settled envelope through
        // base + scale·s, capped. At s = 1.0 the raw value equals the cap exactly.
        let raw = HaloRingMechanics.monitorBase + HaloRingMechanics.monitorScale * 1.0
        XCTAssertEqual(raw, 0.55, accuracy: 1e-6)
        XCTAssertEqual(min(raw, HaloRingMechanics.monitorCap), 0.55, accuracy: 1e-6)
    }
}
