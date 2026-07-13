import SwiftUI
import AppKit

/// DEBUG-only launch hooks for the Phase 1 gate-capture script (P1-gate).
///
/// Activated ONLY by environment variables; inert otherwise and compiled out of
/// Release builds. Every hook routes through the SAME model methods a user click
/// would call (`selectPalette`, `select(_:)`), so nothing about the captured
/// state is faked — the screenshots show exactly what the app derives from those
/// real code paths (Brief §1/§4 honesty rule).
///
///   HALO_GATE_WINDOW  = "1440x900" | "1180x720"   exact content size (points)
///   HALO_GATE_PALETTE = "A" | "B"                 initial palette
///   HALO_GATE_MODE    = "PLAY" | "LOAD" | ...      optional initial mode
@MainActor
enum GateCaptureSupport {
    /// Applies any requested gate hooks. A no-op unless the matching env vars are
    /// set, and entirely compiled out of Release.
    static func applyIfRequested(model: HaloAppModel) {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment

        if let raw = env["HALO_GATE_PALETTE"],
           let palette = HaloPalette(rawValue: raw.uppercased()) {
            model.selectPalette(palette)          // real user path: recolours 3D too
        }

        if let raw = env["HALO_GATE_MODE"] {
            let wanted = raw.uppercased()
            if let mode = HaloMode.visible(rackAvailable: model.rackAvailable)
                .first(where: { $0.title.uppercased() == wanted }) {
                model.select(mode)                // real user path: re-frames camera
            }
        }

        if let raw = env["HALO_GATE_WINDOW"] {
            let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2 else { return }
            // The window may not be key yet on first appear; retry briefly.
            resizeWhenWindowExists(to: NSSize(width: parts[0], height: parts[1]),
                                   attempts: 10)
        }
        #endif
    }

    #if DEBUG
    private static func resizeWhenWindowExists(to size: NSSize, attempts: Int) {
        guard attempts > 0 else { return }
        if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
            // `.hiddenTitleBar` + full-size content view ⇒ content size == full
            // window size. Both gate sizes are ≥ the SwiftUI minimums (1180×720),
            // so AppKit won't fight the resize.
            window.setContentSize(size)
            window.center()
            window.makeKeyAndOrderFront(nil)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                resizeWhenWindowExists(to: size, attempts: attempts - 1)
            }
        }
    }
    #endif
}
