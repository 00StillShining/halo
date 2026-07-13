import SwiftUI

@main
struct HaloApp: App {
    /// True when this process is the XCTest host (`TEST_HOST` runs the full app
    /// binary). Skipping the RealityKit stage there avoids a teardown race:
    /// XCTest exits milliseconds after the last test, while the async USDZ
    /// import is still running on CoreRealityIO's live-scene-update queue, and
    /// that in-flight import segfaults against the half-destroyed process
    /// (observed SIGSEGV in UsdSchemaRegistry::FindSchemaInfo). Unit tests
    /// exercise logic, never this scene, so nothing real is hidden (DD-009).
    private static let isUnitTestHost: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }()

    @State private var model = HaloAppModel()

    var body: some Scene {
        WindowGroup {
            if Self.isUnitTestHost {
                Text("HALO UNIT-TEST HOST")
                    .font(HaloType.label())
                    .haloLabelCase()
            } else {
                HaloRootView()
                    .environment(model)
                    .frame(minWidth: 1180, minHeight: 720)
            }
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
    }
}
