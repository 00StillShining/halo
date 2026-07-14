import XCTest
@testable import Halo

/// Pins the P4-states scene LOAD-phase derivation (DD-025/DD-026): the terminal
/// phase is a pure function of the loader's placeholder result — a real USDZ load is
/// `.loaded`, the procedural fallback is `.fallback` — so the stage LOADING plate
/// disappears the instant EITHER lands (never a lingering spinner). The initial
/// default is `.loading`. Pure logic, no RealityKit scene.
final class SceneLoadPhaseTests: XCTestCase {

    func testTerminalLoadedWhenNotPlaceholder() {
        XCTAssertEqual(EP40SceneController.LoadPhase.terminal(isPlaceholder: false), .loaded)
    }

    func testTerminalFallbackWhenPlaceholder() {
        XCTAssertEqual(EP40SceneController.LoadPhase.terminal(isPlaceholder: true), .fallback)
    }

    func testTerminalIsNeverLoading() {
        // Whatever the loader reports, the terminal phase closes the LOADING window.
        for placeholder in [true, false] {
            XCTAssertNotEqual(EP40SceneController.LoadPhase.terminal(isPlaceholder: placeholder), .loading)
        }
    }

    @MainActor
    func testInitialPhaseIsLoading() {
        XCTAssertEqual(EP40SceneController().loadPhase, .loading)
    }
}
