import XCTest
@testable import Halo

/// Pins the P4-states canonical state vocabulary (DD-025): the kind→tone mapping
/// (attention vs neutral, which drives the warning-vs-metal accent + title colour)
/// and the no-flash rule — ERROR / EMPTY / OFFLINE / etc. never drive a continuous
/// animation, and BUSY with a determinate % is a static track, by construction.
/// Pure value logic, no view rendering — headless.
final class HaloStatePlateTests: XCTestCase {

    // MARK: - Tone mapping (attention → warning accent/title; else neutral metal)

    func testAttentionKindsAreOnlyPermissionAndError() {
        XCTAssertTrue(HaloStateKind.permission.isAttention)
        XCTAssertTrue(HaloStateKind.error.isAttention)
        for kind: HaloStateKind in [.empty, .loading, .offline, .disconnected, .suspended, .busy] {
            XCTAssertFalse(kind.isAttention, "\(kind) must be neutral-toned")
        }
    }

    // MARK: - No-flash / stability rule (Brief §5/§10)

    func testErrorNeverAnimates() {
        // A recoverable error is a STABLE labelled hold — never a sweep, in any
        // Reduce-Motion state and with or without a (nonsensical) progress value.
        for reduce in [true, false] {
            XCTAssertFalse(HaloStateKind.error.usesContinuousAnimation(progress: nil, reduceMotion: reduce))
            XCTAssertFalse(HaloStateKind.error.usesContinuousAnimation(progress: 0.5, reduceMotion: reduce))
        }
    }

    func testStaticKindsNeverAnimate() {
        for kind: HaloStateKind in [.empty, .offline, .disconnected, .suspended, .permission] {
            XCTAssertFalse(kind.usesContinuousAnimation(progress: nil, reduceMotion: false))
            XCTAssertFalse(kind.usesContinuousAnimation(progress: nil, reduceMotion: true))
        }
    }

    func testBusyDeterminateIsStaticIndeterminateSweeps() {
        // Determinate % → static numeric track (no sweep). Indeterminate BUSY sweeps
        // only when motion is allowed.
        XCTAssertFalse(HaloStateKind.busy.usesContinuousAnimation(progress: 0.4, reduceMotion: false))
        XCTAssertTrue(HaloStateKind.busy.usesContinuousAnimation(progress: nil, reduceMotion: false))
        XCTAssertFalse(HaloStateKind.busy.usesContinuousAnimation(progress: nil, reduceMotion: true))
    }

    func testLoadingSweepsOnlyWhenMotionAllowedAndIndeterminate() {
        XCTAssertTrue(HaloStateKind.loading.usesContinuousAnimation(progress: nil, reduceMotion: false))
        XCTAssertFalse(HaloStateKind.loading.usesContinuousAnimation(progress: nil, reduceMotion: true))
        XCTAssertFalse(HaloStateKind.loading.usesContinuousAnimation(progress: 0.3, reduceMotion: false))
    }
}
