import Foundation

/// The coarse connection lifecycle Halo surfaces to the operator (Brief §8
/// safety & resilience). Every case is backed by an actually observed app/device
/// fact (Brief §1/§4 honesty) — this is a plain-language read of the same truths
/// that drive `HaloRingState`, phrased as STARTING / WAIT / READY / LIVE / SLEEP /
/// ERROR so the status strip reads like a connection state, not a ring glow.
///
/// It never claims a hardware state Halo has not observed: `.live` requires a real
/// live MIDI feed or an engaged monitor route; `.suspended` is only ever set from
/// a real `NSWorkspace` sleep notification; `.error` mirrors an observed failure.
enum HaloLifecyclePhase: Equatable, Sendable {
    case starting                 // observers not yet running (app just launched)
    case waiting                  // observer running, no EP-40 endpoint yet
    case ready                    // endpoint connected, no live activity / monitor
    case live                     // observed MIDI activity or an engaged monitor route
    case suspended                // system asleep — inputs intentionally torn down
    case error(label: String)     // observed failure, e.g. "MIDI"

    struct Inputs: Equatable, Sendable {
        var observerRunning = false   // midiObserver != nil
        var endpointConnected = false // EP40MIDIConnection.isConnected
        var displayLive = false       // displayFeedMode == .live (observed MIDI)
        var monitorEngaged = false    // MonitorController.isRunning
        var systemAsleep = false      // NSWorkspace sleep window
        var errorLabel: String?       // real failures only (CoreMIDI client)
    }

    /// Priority: error > suspended > live > ready > waiting > starting. An observed
    /// failure trumps everything; sleep trumps any stale "live" because no activity
    /// can be observed while the Mac is asleep.
    static func derive(_ i: Inputs) -> HaloLifecyclePhase {
        if let label = i.errorLabel { return .error(label: label) }
        if i.systemAsleep { return .suspended }
        if i.displayLive || i.monitorEngaged { return .live }
        if i.endpointConnected { return .ready }
        if i.observerRunning { return .waiting }
        return .starting
    }

    /// The short status-strip word for the `STATE` chip.
    var word: String {
        switch self {
        case .starting:        return "STARTING"
        case .waiting:         return "WAIT"
        case .ready:           return "READY"
        case .live:            return "LIVE"
        case .suspended:       return "SLEEP"
        case let .error(label): return "ERR \(label)"
        }
    }

    var isError: Bool { if case .error = self { return true }; return false }
    var isLive: Bool { self == .live }
    var isSuspended: Bool { self == .suspended }
}
