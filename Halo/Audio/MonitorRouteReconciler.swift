import Foundation

/// Pure resilience rule for a RUNNING monitor route (Brief §8: "observe device-
/// list, sample-rate, default-output and sleep/wake changes"; "USB removal stops
/// input and output units promptly").
///
/// A route is opened against two STABLE device UIDs (the EP-40 input and the
/// chosen Mac output). If either device vanishes from a fresh Core Audio snapshot
/// — the output headphones unplugged, the EP-40 yanked, a device removed when the
/// system default changes — the honest response is to stop: the sink/source Halo
/// opened no longer exists, so continuing would imply audio is flowing where it is
/// not. Halo never silently re-points a live route at a different device (that
/// would change what the user is hearing without asking); it stops and lets the
/// operator re-engage explicitly.
///
/// Kept pure (no Core Audio, no actor) so the decision is exhaustively unit-tested.
enum MonitorRouteReconciler {
    /// Whether a route running on `activeInputUID` → `activeOutputUID` must stop
    /// because a device it depends on is absent from `snapshot`. Returns `false`
    /// when no route is running (nil UIDs) so an idle controller is never disturbed.
    static func shouldStop(activeInputUID: String?,
                           activeOutputUID: String?,
                           snapshot: AudioDeviceSnapshot) -> Bool {
        guard let activeInputUID, let activeOutputUID else { return false }
        let inputPresent = snapshot.inputs.contains { $0.uid == activeInputUID }
        let outputPresent = snapshot.outputs.contains { $0.uid == activeOutputUID }
        return !(inputPresent && outputPresent)
    }
}
