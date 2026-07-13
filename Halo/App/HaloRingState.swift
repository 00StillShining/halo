import Foundation

/// Brief §5 halo-ring states. Every case is backed by an actually observed
/// app/device fact (Brief §1/§4 honesty). FX inner ring is Phase 5 — not here.
///
/// The ring is driven by connection/monitor/record truth ONLY. It is never
/// driven by `EP40DisplayState` preview/demo frames — a faked hardware state is
/// an automatic review failure. `.monitoring`, `.recording`, and `.transfer`
/// have no producers yet (no audio engine; SysEx transfer is device-gated), so
/// they are defined and rendered but remain unreachable until a real producer
/// exists.
enum HaloRingState: Equatable, Sendable {
    case disconnected                    // CoreMIDI client not running (or torn down)
    case discovering                     // client alive, watching, no EP-40 endpoint
    case connected                       // endpoint present, monitor off
    case monitoring                      // Halo's own audio monitor engaged (Phase 2)
    case recording(startedAt: Date)      // Halo's own recorder running (Phase 2/5b)
    case transfer(progress: Double)      // real device transfer only — needsDevice
    case error(label: String)            // observed failure, e.g. "MIDI"

    struct Inputs: Equatable, Sendable {
        var observerRunning = false      // midiObserver != nil
        var endpointConnected = false    // EP40MIDIConnection.isConnected
        var errorLabel: String?          // model.ringErrorLabel (real failures only)
        var monitorEngaged = false       // FUTURE: audio engine — no producer yet
        var recordingStartedAt: Date?    // FUTURE: recorder — no producer yet
        var transferProgress: Double?    // FUTURE: device transfer — needsDevice
    }

    /// Priority: error > transfer > recording > monitoring > connected > discovering.
    static func derive(_ i: Inputs) -> HaloRingState {
        if let label = i.errorLabel { return .error(label: label) }
        if let p = i.transferProgress { return .transfer(progress: min(max(p, 0), 1)) }
        if let t = i.recordingStartedAt { return .recording(startedAt: t) }
        if i.monitorEngaged { return .monitoring }
        if i.endpointConnected { return .connected }
        if i.observerRunning { return .discovering }
        return .disconnected
    }

    /// The short status-bar word for the `HALO` chip. Transfer shows a percentage.
    var statusWord: String {
        switch self {
        case .disconnected:            return "DARK"
        case .discovering:             return "SCAN"
        case .connected:               return "LINK"
        case .monitoring:              return "MON"
        case .recording:               return "REC"
        case let .transfer(progress):  return "TX \(Int((progress * 100).rounded()))%"
        case let .error(label):        return "ERR \(label)"
        }
    }

    /// True when the chip should carry the warning tint (observed failure).
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
