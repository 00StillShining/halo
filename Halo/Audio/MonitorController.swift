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

    /// Monitor gain in dBFS. Default is the safe −12 dB monitoring level.
    var gainDB: Double = MonitorGain.defaultDB {
        didSet { engine.setGainDB(gainDB) }
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
    private var meterTask: Task<Void, Never>?

    /// Meter poll rate (Brief §8: 30–60 Hz). 50 Hz is comfortably inside the band.
    private let meterInterval = Duration.milliseconds(20)

    init(engine: MonitorEngine = EP40AudioRouter(),
         levelBridge: AudioLevelBridge = AudioLevelBridge(),
         captureTap: CaptureTap? = nil) {
        self.engine = engine
        self.levelBridge = levelBridge
        self.captureTap = captureTap
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
