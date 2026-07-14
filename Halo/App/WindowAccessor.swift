import AppKit
import SwiftUI

/// Persists the main window's SIZE and POSITION across launches (Brief §7 "remember
/// window layout", P4-states DD-027). It grabs the hosting `NSWindow` once and sets
/// a frame autosave name — AppKit then saves/restores the frame natively, which a
/// pure-SwiftUI `@SceneStorage` cannot do for position. `.defaultSize` still seeds
/// the first run and the `minWidth/minHeight` clamp is untouched.
///
/// UI-only and inert with respect to honesty (DD-013): it touches no audio / MIDI /
/// display path and makes no device claim.
struct WindowAccessor: NSViewRepresentable {
    /// Autosave key — stable across launches so the frame round-trips.
    var autosaveName: String = "halo.main"

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window isn't attached during make; resolve it on the next runloop turn.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            // Idempotent: setting the same name twice is harmless.
            window.setFrameAutosaveName(autosaveName)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
