import XCTest
@testable import Halo

/// Pins the Brief §6 velocity-response contract (DD-012): velocity affects LED
/// intensity MUCH more than physical travel. A regression here is a brief
/// violation, the same spirit as the DD-010 projection reflection guard.
final class HaloMechanicsVelocityTests: XCTestCase {

    func testPadLEDOpacityFloorAndCeiling() {
        XCTAssertEqual(HaloMechanics.padLEDOpacity(velocity: 0),
                       HaloMechanics.padLEDFloor, accuracy: 1e-6)
        XCTAssertEqual(HaloMechanics.padLEDOpacity(velocity: 1),
                       HaloMechanics.padLEDFloor + HaloMechanics.padLEDScale, accuracy: 1e-6)
    }

    func testPadLEDOpacityMonotonicAndClamped() {
        var last = HaloMechanics.padLEDOpacity(velocity: -0.5)   // clamps to 0
        XCTAssertEqual(last, HaloMechanics.padLEDFloor, accuracy: 1e-6)
        for step in 1...10 {
            let v = Float(step) / 10
            let cur = HaloMechanics.padLEDOpacity(velocity: v)
            XCTAssertGreaterThan(cur, last, "LED opacity must increase with velocity")
            last = cur
        }
        // Over-unity clamps to the ceiling.
        XCTAssertEqual(HaloMechanics.padLEDOpacity(velocity: 2),
                       HaloMechanics.padLEDFloor + HaloMechanics.padLEDScale, accuracy: 1e-6)
    }

    func testTravelDepthWithinBriefRange() {
        for step in 0...10 {
            let v = Float(step) / 10
            let d = HaloMechanics.travelDepth(velocity: v)
            XCTAssertGreaterThanOrEqual(d, HaloMechanics.travelMinMeters)
            XCTAssertLessThanOrEqual(d, HaloMechanics.travelMaxMeters)
        }
        // Brief mandate: 1.1–1.3 mm.
        XCTAssertEqual(HaloMechanics.travelDepth(velocity: 0), 0.0011, accuracy: 1e-6)
        XCTAssertEqual(HaloMechanics.travelDepth(velocity: 1), 0.0013, accuracy: 1e-6)
    }

    // The core Brief §6 asymmetry: LED span (~5.6x) ≫ travel span (~1.18x).
    func testVelocityAffectsLEDMoreThanTravel() {
        let ledSpan = HaloMechanics.padLEDOpacity(velocity: 1)
                    / HaloMechanics.padLEDOpacity(velocity: 0)
        let travelSpan = HaloMechanics.travelDepth(velocity: 1)
                       / HaloMechanics.travelDepth(velocity: 0)
        XCTAssertGreaterThan(ledSpan, travelSpan,
            "velocity must drive LED intensity more than physical travel (Brief §6)")
        // Not just barely — the intent is a clearly stronger LED response.
        XCTAssertGreaterThan(ledSpan, 3 * travelSpan)
    }
}
