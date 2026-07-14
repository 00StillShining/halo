import Foundation

/// UI-facing state for the dub FX rack (Brief §5a). @MainActor @Observable: every
/// control is a plain value the rail binds to; each `didSet` writes the matching
/// atomic in `RackParameters`, which the audio thread reads once per block. Nothing
/// here touches the render thread directly — the atomic bridge is the only seam.
///
/// HONESTY (Brief §1/§4): the rack is pure Mac-side DSP on the monitor path. These
/// controls never claim or reflect an EP-40 hardware state; the ONLY hardware fact
/// they consume is the observed MIDI clock tempo (when the device sends it), used
/// solely to compute the echo's synced delay time. With no clock, tap-tempo drives
/// it — no tempo is ever invented.
@MainActor
@Observable
final class RackModel {
    let parameters: RackParameters

    // MARK: Master
    var engaged = false { didSet { parameters.setEngaged(engaged) } }

    /// PRINT FX: the next take records the POST-rack signal (labelled) instead of the
    /// raw input (Brief §7). Read by `HaloAppModel.toggleRecording`; purely a capture
    /// routing choice, not a DSP parameter.
    var printFX = false

    // MARK: TAPE ECHO
    var echoBypassed = false { didSet { parameters.setEchoBypassed(echoBypassed) } }
    var echoFeedback = 0.45  { didSet { parameters.setEchoFeedback(echoFeedback) } }
    var echoTone     = 0.5   { didSet { parameters.setEchoTone(echoTone) } }
    var echoWow      = 0.25  { didSet { parameters.setEchoWow(echoWow) } }
    var echoMix      = 0.35  { didSet { parameters.setEchoMix(echoMix) } }

    /// Free delay time (ms) used when NOT tempo-synced. 40…1200 ms.
    var echoFreeMs = 360.0 { didSet { applyEchoTime() } }
    /// Tempo-sync engaged: derive the delay time from the tempo + division instead of
    /// `echoFreeMs`. Enabled only meaningfully when a tempo source exists.
    var echoSync = false { didSet { applyEchoTime() } }
    var echoDivision: EchoDivision = .eighth { didSet { applyEchoTime() } }

    // MARK: SPRING
    var springBypassed = true  { didSet { parameters.setSpringBypassed(springBypassed) } }
    var springMix      = 0.30  { didSet { parameters.setSpringMix(springMix) } }
    var springDecay    = 0.55  { didSet { parameters.setSpringDecay(springDecay) } }
    var springTone     = 0.5   { didSet { parameters.setSpringTone(springTone) } }

    // MARK: SWEEP
    var sweepBypassed = true  { didSet { parameters.setSweepBypassed(sweepBypassed) } }
    var sweepMacro    = 0.5   { didSet { parameters.setSweepMacro(sweepMacro) } }
    var sweepReso     = 0.3   { didSet { parameters.setSweepReso(sweepReso) } }

    // MARK: LOW END
    var lowBypassed = true  { didSet { parameters.setLowBypassed(lowBypassed) } }
    var lowAmount   = 0.4   { didSet { parameters.setLowAmount(lowAmount) } }

    // MARK: Tempo
    /// Observed MIDI-clock tempo (nil when the device sends no clock). Set by
    /// `HaloAppModel` from the same honest clock read the display uses.
    private(set) var clockBPM: Double?
    /// Tap-tempo estimate (nil until enough taps). Used only when no clock is present.
    private(set) var tapBPM: Double?
    private var tapTimes: [TimeInterval] = []

    /// The tempo that actually drives echo sync: the device clock when present, else
    /// the user's taps. Nil when neither exists (sync then falls back to free time).
    var tempoBPM: Double? { clockBPM ?? tapBPM }

    enum TempoSource: String { case clock = "CLOCK", tap = "TAP", none = "—" }
    var tempoSource: TempoSource {
        if clockBPM != nil { return .clock }
        if tapBPM != nil { return .tap }
        return .none
    }

    init(parameters: RackParameters = RackParameters()) {
        self.parameters = parameters
        syncAll()
    }

    // MARK: - Tempo control

    /// Forward the observed MIDI-clock tempo (or nil when it drops). Only re-applies
    /// when the integer BPM actually changes, so a jittering clock never churns the
    /// UI or the atomic. Called from the app model's clock path.
    func updateClockBPM(_ bpm: Double?) {
        let rounded = bpm.map { ($0).rounded() }
        let currentRounded = clockBPM.map { ($0).rounded() }
        guard rounded != currentRounded else { return }
        clockBPM = rounded
        applyEchoTime()
    }

    /// TAP TEMPO (Brief §5a: "otherwise a tap-tempo control"). Records the tap and
    /// re-estimates BPM from the recent inter-tap intervals. Only used when the
    /// device sends no clock.
    func tapTempo(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Reset the run if the gap is too long to be part of the same tempo.
        if let last = tapTimes.last, now - last > 2.0 { tapTimes.removeAll() }
        tapTimes.append(now)
        if tapTimes.count > 5 { tapTimes.removeFirst(tapTimes.count - 5) }
        guard tapTimes.count >= 2 else { return }
        var intervals: [Double] = []
        for i in 1..<tapTimes.count { intervals.append(tapTimes[i] - tapTimes[i - 1]) }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        guard mean > 0 else { return }
        let bpm = (60.0 / mean).rounded()
        if (30...300).contains(bpm) {
            tapBPM = bpm
            applyEchoTime()
        }
    }

    // MARK: - Echo time resolution

    /// The delay time (ms) currently applied — synced from tempo, or the free knob.
    var effectiveEchoMs: Double {
        if echoSync, let bpm = tempoBPM, bpm > 0 {
            let beatMs = 60_000.0 / bpm
            let ms = beatMs * echoDivision.beatFraction
            return min(max(ms, 40), 1200)
        }
        return min(max(echoFreeMs, 40), 1200)
    }

    private func applyEchoTime() { parameters.setEchoTimeMs(effectiveEchoMs) }

    /// Push every control to the atomic bridge once (init) so the render side and the
    /// UI can never start out of lockstep even if a default drifts.
    private func syncAll() {
        parameters.setEngaged(engaged)
        parameters.setEchoBypassed(echoBypassed)
        parameters.setEchoFeedback(echoFeedback)
        parameters.setEchoTone(echoTone)
        parameters.setEchoWow(echoWow)
        parameters.setEchoMix(echoMix)
        parameters.setSpringBypassed(springBypassed)
        parameters.setSpringMix(springMix)
        parameters.setSpringDecay(springDecay)
        parameters.setSpringTone(springTone)
        parameters.setSweepBypassed(sweepBypassed)
        parameters.setSweepMacro(sweepMacro)
        parameters.setSweepReso(sweepReso)
        parameters.setLowBypassed(lowBypassed)
        parameters.setLowAmount(lowAmount)
        applyEchoTime()
    }
}

/// Tempo-sync divisions offered by TAPE ECHO (Brief §5a). `beatFraction` is the
/// delay length as a fraction of one quarter-note beat.
enum EchoDivision: String, CaseIterable, Identifiable, Sendable {
    case eighth        // 1/8
    case dottedEighth  // dotted 1/8
    case quarter       // 1/4
    case triplet       // 1/8 triplet

    var id: String { rawValue }
    var label: String {
        switch self {
        case .eighth:       "1/8"
        case .dottedEighth: "1/8."
        case .quarter:      "1/4"
        case .triplet:      "1/8T"
        }
    }
    /// Multiplier on the quarter-note beat length.
    var beatFraction: Double {
        switch self {
        case .eighth:       0.5
        case .dottedEighth: 0.75
        case .quarter:      1.0
        case .triplet:      1.0 / 3.0
        }
    }
}
