import XCTest
import simd
@testable import Halo

/// Pins the pure drop-ray unprojection used to hit-test file drops on the model
/// pads (DD-014). No live RealityKit scene needed — `dropRay` is a pure function of
/// point, view size and the settled mode framing.
final class PadDropRayTests: XCTestCase {

    private let framing = EP40SceneController.framing(for: .load)

    func testCenterRayLooksAtOrigin() {
        let size = CGSize(width: 1440, height: 900)
        let ray = EP40SceneController.dropRay(
            at: CGPoint(x: size.width / 2, y: size.height / 2),
            viewSize: size, framing: framing)

        let cam = EP40SceneController.heroTransform(framing)
        let expected = -simd_normalize(cam.translation)
        XCTAssertEqual(ray.direction.x, expected.x, accuracy: 1e-4)
        XCTAssertEqual(ray.direction.y, expected.y, accuracy: 1e-4)
        XCTAssertEqual(ray.direction.z, expected.z, accuracy: 1e-4)
        // Origin is the camera position.
        XCTAssertEqual(ray.origin.x, cam.translation.x, accuracy: 1e-5)
        XCTAssertEqual(ray.origin.y, cam.translation.y, accuracy: 1e-5)
        XCTAssertEqual(ray.origin.z, cam.translation.z, accuracy: 1e-5)
    }

    func testRayDirectionIsUnitLength() {
        let size = CGSize(width: 1440, height: 900)
        for p in [CGPoint(x: 100, y: 100), CGPoint(x: 1300, y: 800), CGPoint(x: 720, y: 450)] {
            let ray = EP40SceneController.dropRay(at: p, viewSize: size, framing: framing)
            XCTAssertEqual(simd_length(ray.direction), 1, accuracy: 1e-4)
        }
    }

    func testHorizontalMonotonicity() {
        // Moving the point rightward rotates the ray consistently: the camera-space
        // u grows, so the world direction moves monotonically along the camera's
        // right axis. We verify the projection onto that right axis is ordered.
        let size = CGSize(width: 1440, height: 900)
        let cam = EP40SceneController.heroTransform(framing)
        let right = simd_normalize(cam.rotation.act(SIMD3<Float>(1, 0, 0)))

        let xs: [CGFloat] = [200, 720, 1240]
        let projections = xs.map { x -> Float in
            let ray = EP40SceneController.dropRay(
                at: CGPoint(x: x, y: 450), viewSize: size, framing: framing)
            return simd_dot(ray.direction, right)
        }
        XCTAssertLessThan(projections[0], projections[1])
        XCTAssertLessThan(projections[1], projections[2])
    }

    func testAspectRatioChangesRay() {
        // Same pixel point, two different viewport sizes → different rays (the
        // aspect term must be applied).
        let p = CGPoint(x: 1000, y: 300)
        let wide = EP40SceneController.dropRay(
            at: p, viewSize: CGSize(width: 1440, height: 900), framing: framing)
        let tall = EP40SceneController.dropRay(
            at: p, viewSize: CGSize(width: 1000, height: 1400), framing: framing)
        XCTAssertGreaterThan(simd_length(wide.direction - tall.direction), 1e-3)
    }
}
