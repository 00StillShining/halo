import Foundation

/// A Core Audio device described by STABLE, persistable facts (Brief §8 audio
/// routing). The `uid` is the value we persist and bind the picker to — never the
/// display `name`, which the user can rename and which is not stable across
/// reboots or reconnects.
///
/// This is a pure value type: it carries no Core Audio object IDs (those are not
/// stable and must never be persisted) and no live handles, so it is trivially
/// `Sendable`, `Equatable` and unit-testable without any hardware.
struct AudioDevice: Sendable, Equatable, Identifiable {
    /// Stable, persistable identity (`kAudioDevicePropertyDeviceUID`).
    let uid: String
    /// Human-facing name (`kAudioObjectPropertyName`). Display only — never keyed on.
    let name: String
    /// Channels on the input scope. `> 0` ⇒ the device can be an audio source.
    let inputChannels: Int
    /// Channels on the output scope. `> 0` ⇒ the device can be an audio sink.
    let outputChannels: Int
    /// Current nominal sample rate in Hz (`kAudioDevicePropertyNominalSampleRate`).
    let currentSampleRate: Double
    /// Supported nominal sample rates in Hz, ascending
    /// (`kAudioDevicePropertyAvailableNominalSampleRates`, ranges expanded).
    let supportedSampleRates: [Double]
    /// Inclusive IO buffer frame range (`kAudioDevicePropertyBufferFrameSizeRange`).
    /// `nil` when the device does not report one.
    let bufferFrameRange: BufferFrameRange?

    var id: String { uid }
    var isInput: Bool { inputChannels > 0 }
    var isOutput: Bool { outputChannels > 0 }

    /// Inclusive `[min, max]` IO buffer-size window in frames. A plain pair rather
    /// than `ClosedRange` so it survives `min == max` hardware without trapping.
    struct BufferFrameRange: Sendable, Equatable {
        let minFrames: UInt32
        let maxFrames: UInt32
    }
}

/// An immutable point-in-time picture of the machine's audio devices plus which
/// UIDs the system currently treats as default input/output. The discovery layer
/// republishes a fresh snapshot on every relevant Core Audio property change; all
/// selection logic is a pure function of this value (Brief §8, honesty §1/§4 — no
/// state is invented, everything shown traces to a real Core Audio read).
struct AudioDeviceSnapshot: Sendable, Equatable {
    var devices: [AudioDevice]
    /// UID the system reports as default input, if known. Reflected, never changed.
    var defaultInputUID: String?
    /// UID the system reports as default output, if known. Reflected, never changed.
    var defaultOutputUID: String?

    static let empty = AudioDeviceSnapshot(devices: [], defaultInputUID: nil, defaultOutputUID: nil)

    var outputs: [AudioDevice] { devices.filter(\.isOutput) }
    var inputs: [AudioDevice] { devices.filter(\.isInput) }
}

/// How the effective monitor output was resolved from a snapshot and the user's
/// persisted preference. The `reason` lets the UI stay honest: it can show whether
/// the highlighted device is the user's actual pick or a fallback because their
/// remembered device is currently absent.
enum AudioOutputResolution: Sendable, Equatable {
    /// No output-capable devices exist at all.
    case none
    /// The user's persisted UID is present — this is exactly their choice.
    case preferred(AudioDevice)
    /// Persisted UID absent (or never set) → fell back to the system default output.
    case fallbackDefault(AudioDevice)
    /// Persisted UID absent and no usable system default → first output device.
    case fallbackFirst(AudioDevice)

    var device: AudioDevice? {
        switch self {
        case .none: return nil
        case let .preferred(d), let .fallbackDefault(d), let .fallbackFirst(d): return d
        }
    }

    /// True when the highlighted device is the user's own persisted pick.
    var isExactPreference: Bool { if case .preferred = self { return true }; return false }
}

/// The pure resolution rule (no Core Audio, no actor isolation) so it can be
/// exhaustively unit-tested. Given the persisted preferred UID and a device
/// snapshot, decide which output device is "effective":
///
/// 1. persisted UID present in the snapshot        → `.preferred`
/// 2. else system default output present           → `.fallbackDefault`
/// 3. else first output device (deterministic order) → `.fallbackFirst`
/// 4. no outputs                                    → `.none`
///
/// This never mutates system state; it only chooses which device halo would
/// route its (Phase 2) monitor path to.
enum AudioOutputResolver {
    static func resolve(preferredUID: String?, snapshot: AudioDeviceSnapshot) -> AudioOutputResolution {
        let outputs = snapshot.outputs
        guard !outputs.isEmpty else { return .none }

        if let preferredUID,
           let match = outputs.first(where: { $0.uid == preferredUID }) {
            return .preferred(match)
        }
        if let defaultUID = snapshot.defaultOutputUID,
           let def = outputs.first(where: { $0.uid == defaultUID }) {
            return .fallbackDefault(def)
        }
        return .fallbackFirst(outputs[0])
    }
}

/// Persistence seam for the remembered output UID. A protocol so unit tests can
/// use an in-memory double instead of the shared `UserDefaults`.
protocol AudioPreferenceStore: AnyObject {
    func preferredOutputUID() -> String?
    func setPreferredOutputUID(_ uid: String?)
}

extension UserDefaults: AudioPreferenceStore {
    private static let preferredOutputKey = "halo.audio.preferredOutputUID"

    func preferredOutputUID() -> String? {
        string(forKey: Self.preferredOutputKey)
    }

    func setPreferredOutputUID(_ uid: String?) {
        if let uid {
            set(uid, forKey: Self.preferredOutputKey)
        } else {
            removeObject(forKey: Self.preferredOutputKey)
        }
    }
}

/// UI-facing, observable holder for the user's monitor-output choice. It persists
/// only the STABLE UID (Brief §8) and never touches system defaults — selecting a
/// device here records which output halo's monitor path will target once the
/// audio engine ships (Phase 2). All resolution goes through `AudioOutputResolver`
/// so the decision logic stays pure and tested.
@MainActor
@Observable
final class AudioOutputSelection {
    private let store: AudioPreferenceStore
    /// The user's remembered output UID, or `nil` if they've never chosen one.
    private(set) var preferredUID: String?

    init(store: AudioPreferenceStore = UserDefaults.standard) {
        self.store = store
        preferredUID = store.preferredOutputUID()
    }

    /// Remember `uid` as the user's monitor output (persisted). Passing `nil`
    /// clears the preference so resolution falls back to the system default.
    func select(_ uid: String?) {
        guard uid != preferredUID else { return }
        preferredUID = uid
        store.setPreferredOutputUID(uid)
    }

    func resolution(in snapshot: AudioDeviceSnapshot) -> AudioOutputResolution {
        AudioOutputResolver.resolve(preferredUID: preferredUID, snapshot: snapshot)
    }
}
