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
                    // DEBUG-only, env-gated gate-capture hooks (P1-gate). Inert in
                    // normal runs and compiled out of Release (DD entry below).
                    .onAppear { GateCaptureSupport.applyIfRequested(model: model) }
            }
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Command-1…N index the VISIBLE mode-bar order (Brief §7). RACK is
            // hidden until Phase 5a, so ⌘5 = BACKUPS today and ⌘6 is unbound;
            // when RACK ships ⌘5 = RACK and ⌘6 = BACKUPS by design.
            CommandMenu("Mode") {
                ForEach(Array(HaloMode.visible(rackAvailable: model.rackAvailable).enumerated()),
                        id: \.element) { index, m in
                    Button(m.title) { model.select(m) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")),
                                          modifiers: .command)
                }
            }
        }
    }
}
