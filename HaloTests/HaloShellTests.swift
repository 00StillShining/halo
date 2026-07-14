import XCTest
import simd
@testable import Halo

/// Covers the P1-shell contracts (Brief §7): the ⌘-number visible-mode order,
/// mode-switch guarding, the mode-framing camera math, the Escape transient
/// stack, and the data-rail width band.
final class HaloShellTests: XCTestCase {

    // MARK: - Visible mode order (⌘-number contract)

    func testVisibleModesWithoutRack() {
        XCTAssertEqual(HaloMode.visible(rackAvailable: false),
                       [.play, .load, .edit, .capture, .backups])
    }

    func testVisibleModesWithRackInsertsAtIndexFour() {
        let modes = HaloMode.visible(rackAvailable: true)
        XCTAssertEqual(modes, [.play, .load, .edit, .capture, .rack, .backups])
        XCTAssertEqual(modes[4], .rack)     // ⌘5 becomes RACK when it ships
        XCTAssertEqual(modes[5], .backups)  // ⌘6 becomes BACKUPS
    }

    // MARK: - Mode switching guard

    @MainActor
    func testSelectRackSwitchesNowThatItShips() {
        // RACK ships in Phase 5a (P5a-rack): it is in the visible bar and selectable.
        let model = HaloAppModel()
        XCTAssertEqual(model.mode, .play)
        XCTAssertTrue(model.rackAvailable)
        model.select(.rack)
        XCTAssertEqual(model.mode, .rack)
    }

    @MainActor
    func testSelectVisibleModeSwitches() {
        let model = HaloAppModel()
        model.select(.load)
        XCTAssertEqual(model.mode, .load)
    }

    // MARK: - Mode framing camera math

    func testPlayFramingEqualsOriginalHero() {
        let f = EP40SceneController.framing(for: .play)
        XCTAssertEqual(f.radius, 0.70, accuracy: 1e-6)
        XCTAssertEqual(f.yawDeg, 28, accuracy: 1e-6)
        XCTAssertEqual(f.pitchDeg, 42, accuracy: 1e-6)
    }

    func testHeroTransformIsOrthonormalAndLooksAtOrigin() {
        for mode in HaloMode.allCases {
            let f = EP40SceneController.framing(for: mode)
            let t = EP40SceneController.heroTransform(f)
            let m = simd_float3x3(t.rotation)

            // Columns orthonormal.
            XCTAssertEqual(simd_length(m.columns.0), 1, accuracy: 1e-4, "right unit \(mode)")
            XCTAssertEqual(simd_length(m.columns.1), 1, accuracy: 1e-4, "up unit \(mode)")
            XCTAssertEqual(simd_length(m.columns.2), 1, accuracy: 1e-4, "back unit \(mode)")
            XCTAssertEqual(simd_dot(m.columns.0, m.columns.1), 0, accuracy: 1e-4, "r·u \(mode)")
            XCTAssertEqual(simd_dot(m.columns.0, m.columns.2), 0, accuracy: 1e-4, "r·b \(mode)")
            XCTAssertEqual(simd_dot(m.columns.1, m.columns.2), 0, accuracy: 1e-4, "u·b \(mode)")

            // Camera forward is −Z; it must point from the camera toward the origin.
            let forward = t.rotation.act(SIMD3<Float>(0, 0, -1))
            let expected = -simd_normalize(t.translation)
            XCTAssertEqual(forward.x, expected.x, accuracy: 1e-4, "look-at x \(mode)")
            XCTAssertEqual(forward.y, expected.y, accuracy: 1e-4, "look-at y \(mode)")
            XCTAssertEqual(forward.z, expected.z, accuracy: 1e-4, "look-at z \(mode)")
        }
    }

    // MARK: - Transient coordinator (Escape stack)

    @MainActor
    func testTransientHandleEscapeFalseWhenEmpty() {
        let coord = TransientCoordinator()
        XCTAssertFalse(coord.handleEscape())
    }

    @MainActor
    func testTransientLIFODismissal() {
        let coord = TransientCoordinator()
        var log: [Int] = []
        let a = UUID(), b = UUID()
        coord.register(id: a) { log.append(1) }
        coord.register(id: b) { log.append(2) }
        XCTAssertTrue(coord.handleEscape())   // topmost (b) first
        XCTAssertTrue(coord.handleEscape())   // then a
        XCTAssertFalse(coord.handleEscape())  // empty
        XCTAssertEqual(log, [2, 1])
    }

    @MainActor
    func testTransientReRegisterReplacesNotDuplicates() {
        let coord = TransientCoordinator()
        var count = 0
        let a = UUID()
        coord.register(id: a) { count += 1 }
        coord.register(id: a) { count += 1 }   // same id — moves to top, no dup
        XCTAssertTrue(coord.handleEscape())
        XCTAssertFalse(coord.handleEscape())   // only one entry existed
        XCTAssertEqual(count, 1)
    }

    // MARK: - Data-rail width band

    func testDataRailWidthWithinBand() {
        for total in [CGFloat(1180), 1440] {
            let w = HaloMetrics.dataRailWidth(total: total)
            let fraction = w / total
            XCTAssertGreaterThanOrEqual(fraction, HaloMetrics.railMinFraction)
            XCTAssertLessThanOrEqual(fraction, HaloMetrics.railMaxFraction)
        }
    }
}
