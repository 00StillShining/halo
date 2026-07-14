import Foundation
import SwiftUI

/// UI-facing monitor lifecycle (Brief §7/§8). Owns the engine start/stop, the
/// −12 dB-default gain, the LOW/BALANCED/SAFE profile and the 30–60 Hz meter poll,
/// and exposes only honest state: the meter reflects real rendered audio and falls
/// to `.silence` whenever no route runs (a moving meter without a live route would
/// be a faked hardware state — Brief §1/§4).
///
/// Monitoring starts ONLY on an explicit `start` (Brief §8: "Monitoring begins only
/// after explicit user action and defaults to −12 dB"). The engine is injectable so
/// the controller is unit-tested with a mock; the production engine is
/// `EP40AudioRouter` (live audio = needs-device).
@MainActor
@Observable
final class MonitorController {
    enum State: Equatable {
        case idle
        case running
        case failed(MonitorRouteError)

        var isRunning: Bool { if case .running = self { return true }; return false }
    }

    private(set) var state: State = .idle
    private(set) var levels: StereoLevels = .silence

    /// Monitor gain in dBFS. Default is the safe −12 dB monitoring level, restored
    /// from the persisted fader position on launch (P4-states, DD-027). Clamped to
    /// the fader's −40…0 range. HONESTY CAVEAT: persisting the fader POSITION is a
    /// daily-use nicety — it never auto-starts monitoring (the route still only opens
    /// on an explicit press, Brief §8) and never mutates a running route; a restored
    /// value applies to the NEXT start, matching current semantics.
    var gainDB: Double = MonitorGain.defaultDB {
        didSet {
            let clamped = min(max(gainDB, -40), 0)
            guard clamped == gainDB else { gainDB = clamped; return }   // re-clamp, re-enters
            engine.setGainDB(gainDB)
            gainStore.setMonitorGainDB(gainDB)
        }
    }

    /// IO buffer profile. Applied on the next `start` (changing it live would glitch
    /// the stream, so a running route keeps its profile until restarted).
    var profile: MonitorProfile = .default

    /// UID of the input actually being captured while running (for the feedback
    /// guard and honest status). Nil when idle.
    private(set) var activeInputUID: String?
    private(set) var activeOutputUID: String?

    private let engine: MonitorEngine
    private let levelBridge: AudioLevelBridge
    /// Shared RAW-input recorder tap (P2-recorder). Passed into every route config
    /// so the recorder can tap the live input; nil when no recorder is attached.
    private let captureTap: CaptureTap?
    private let gainStore: MonitorPreferenceStore
    private var meterTask: Task<Void, Never>?

    /// Meter poll rate (Brief §8: 30–60 Hz). 50 Hz is comfortably inside the band.
    private let meterInterval = Duration.milliseconds(20)

    init(engine: MonitorEngine = EP40AudioRouter(),
         levelBridge: AudioLevelBridge = AudioLevelBridge(),
         captureTap: CaptureTap? = nil,
         gainStore: MonitorPreferenceStore = UserDefaults.standard) {
        self.engine = engine
        self.levelBridge = levelBridge
        self.captureTap = captureTap
        self.gainStore = gainStore
        // Restore the remembered fader position (clamped), or the −12 dB default when
        // unset. Assigning in `init` does NOT fire `didSet`, so this neither persists
        // a no-op write nor touches the (idle) engine — the value applies on `start`.
        if let stored = gainStore.monitorGainDB() {
            gainDB = min(max(stored, -40), 0)
        }
    }

    var isRunning: Bool { state.isRunning }

    /// Whether starting/continuing with these two devices would feed the EP-40 back
    /// into itself (Brief §8 safety). Pure — the UI surfaces the warning; the user
    /// still chooses whether to proceed.
    static func feedbackRisk(inputUID: String?, outputUID: String?) -> Bool {
        FeedbackGuard.wouldFeedBack(inputUID: inputUID, outputUID: outputUID)
    }

    var hasFeedbackRisk: Bool {
        Self.feedbackRisk(inputUID: activeInputUID, outputUID: activeOutputUID)
    }

    /// Explicit user start. Resolves nothing itself — the caller passes the EP-40
    /// input UID and the chosen output UID so the decision stays in the UI layer.
    /// A `nil` input means the EP-40 audio input isn't present → honest failure.
    func start(inputUID: String?, outputUID: String?) {
        guard let inputUID else { state = .failed(.noInputDevice); return }
        guard let outputUID else { state = .failed(.noOutputDevice); return }

        let config = MonitorRouteConfig(
            inputUID: inputUID,
            outputUID: outputUID,
            profile: profile,
            initialGainDB: gainDB,
            levelBridge: levelBridge,
            captureTap: captureTap)
        do {
            try engine.start(config: config)
            activeInputUID = inputUID
            activeOutputUID = outputUID
            state = .running
            startMeterPoll()
        } catch let error as MonitorRouteError {
            state = .failed(error)
        } catch {
            state = .failed(.configuration(-1))
        }
    }

    /// Reflect a pre-start refusal without opening the engine (Brief §1/§4). Used
    /// when the caller knows the route cannot honestly run — e.g. microphone access
    /// is denied, so an opened AUHAL would only capture silence. Ensures any prior
    /// route is torn down and the meter rests at silence, then reports the reason.
    func fail(_ error: MonitorRouteError) {
        stop()
        state = .failed(error)
    }

    /// Stop the route (explicit user action, USB removal, or app teardown). Drops
    /// the meter to silence.
    func stop() {
        engine.stop()
        stopMeterPoll()
        activeInputUID = nil
        activeOutputUID = nil
        levels = .silence
        state = .idle
    }

    private func startMeterPoll() {
        stopMeterPoll()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.state.isRunning else { return }
                self.levels = self.engine.meterSnapshot()
                try? await Task.sleep(for: self.meterInterval)
            }
        }
    }

    private func stopMeterPoll() {
        meterTask?.cancel()
        meterTask = nil
    }
}

/// Persistence seam for the remembered monitor fader position (P4-states, DD-027).
/// A protocol so unit tests use an in-memory double instead of shared `UserDefaults`,
/// mirroring the `AudioPreferenceStore` pattern. `nil` means "never set" → default.
protocol MonitorPreferenceStore: AnyObject {
    func monitorGainDB() -> Double?
    func setMonitorGainDB(_ db: Double)
}

extension UserDefaults: MonitorPreferenceStore {
    private static let monitorGainKey = "halo.audio.monitorGainDB"

    func monitorGainDB() -> Double? {
        // Distinguish an unset key from a stored 0 dB (a valid fader position).
        object(forKey: Self.monitorGainKey) == nil ? nil : double(forKey: Self.monitorGainKey)
    }

    func setMonitorGainDB(_ db: Double) {
        set(db, forKey: Self.monitorGainKey)
    }
}

extension AudioDeviceSnapshot {
    /// Best-effort resolution of the EP-40's audio INPUT device by name. The EP-40
    /// enumerates as a class-compliant USB device whose name contains "EP-40"
    /// (same family as its MIDI endpoint). This is a documented inference, not a
    /// verified fact (see docs/device-capabilities.md) — real confirmation is
    /// needs-device. Returns the first input-capable match, or nil.
    var ep40AudioInput: AudioDevice? {
        inputs.first { $0.name.range(of: "EP-40", options: .caseInsensitive) != nil }
            ?? inputs.first { $0.name.range(of: "EP40", options: .caseInsensitive) != nil }
    }
}
