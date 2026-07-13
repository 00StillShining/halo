import SwiftUI

/// Escape-stack infrastructure (Brief §7: Escape closes the topmost transient /
/// cancels an uncommitted action). A LIFO register of dismiss closures.
///
/// **Honesty guarantee (DD-013).** By construction this touches UI dismiss
/// closures only — it holds no audio handle and calls nothing on the audio path,
/// so Escape can never stop audio. Audio controls must NEVER register as
/// transients; that invariant is a review contract, not a runtime check.
@MainActor
@Observable
final class TransientCoordinator {
    private var stack: [(id: UUID, dismiss: () -> Void)] = []

    /// Register (or re-register) a transient. Re-registering the same id moves it
    /// to the top rather than duplicating it.
    func register(id: UUID, dismiss: @escaping () -> Void) {
        stack.removeAll { $0.id == id }
        stack.append((id, dismiss))
    }

    func unregister(id: UUID) {
        stack.removeAll { $0.id == id }
    }

    /// Dismiss the topmost transient. Returns whether Escape was consumed; when
    /// nothing is registered the caller lets Escape fall through (`.ignored`).
    @discardableResult
    func handleEscape() -> Bool {
        guard let top = stack.popLast() else { return false }
        // Pop before dismissing: the entry is gone regardless of when the view's
        // own `onDisappear` fires (which then unregisters as a harmless no-op),
        // so a repeated Escape can never re-fire the same closure.
        top.dismiss()
        return true
    }
}

// MARK: - Registration modifier

extension View {
    /// Marks this view as a transient: the topmost Escape closes it (Brief §7).
    /// Never apply to audio controls (DD-013).
    func haloTransient(onEscape: @escaping () -> Void) -> some View {
        modifier(HaloTransientModifier(onEscape: onEscape))
    }

    /// Return-confirms this control. ONLY for safe actions (Brief §7): never apply
    /// to overwrite / delete / send-to-device. The single sanctioned, grep-able
    /// way to bind Return so "never a destructive default" is enforceable at
    /// review time (DD-013).
    func haloSafeDefault() -> some View {
        keyboardShortcut(.defaultAction)
    }
}

private struct HaloTransientModifier: ViewModifier {
    @Environment(HaloAppModel.self) private var model
    let onEscape: () -> Void
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { model.transients.register(id: id, dismiss: onEscape) }
            .onDisappear { model.transients.unregister(id: id) }
    }
}
