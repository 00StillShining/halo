import Foundation

/// GRAB loop capture (Brief §5b). Owns the bar/seconds preference, the observed-clock
/// model (BPM + last downbeat frame), and the `grab()` action that freezes the recent
/// past out of the always-on `RollingCaptureBuffer` into an auditionable, loopable
/// take. All honesty-critical arithmetic lives in the pure `GrabMath`; this @MainActor
/// layer only threads real inputs through it and writes the resulting WAV.
///
/// HONESTY (Brief §1/§4): a grab is only ever real captured audio. `hasClock` reflects
/// live timing-clock messages; a clocked grab is bar-aligned from the observed downbeat
/// (subject to MIDI/callback latency — verified loop feel is needs-device). Without a
/// clock the window is last-N-seconds and the BPM is an explicit ESTIMATE, tagged `est`.
/// Insufficient / empty history yields no take and an honest reason — never a fabricated
/// loop.
@Observable
@MainActor
final class GrabController {

    /// Outcome of a `grab()`. `.truncated` means the clock path could not fit the
    /// requested bar count in the resident 60 s history and honestly captured fewer.
    enum Result: Equatable {
        case grabbed(Take)
        case truncated(Take, askedBars: Int, gotBars: Int)
        case emptyHistory
        case notMonitoring
        case failed(String)
    }

    /// Bar count for the clocked path (4 / 8 / 16, owner default 8). Persisted.
    var bars = 8 {
        didSet {
            guard !isRestoring, bars != oldValue else { return }
            store.setGrabBars(bars)
        }
    }
    /// Seconds for the no-clock path (5 / 10 / 30). Persisted.
    var seconds = 10 {
        didSet {
            guard !isRestoring, seconds != oldValue else { return }
            store.setGrabSeconds(seconds)
        }
    }

    static let barChoices = [4, 8, 16]
    static let secondsChoices = [5, 10, 30]

    /// True while a recent, fresh timing clock is being observed.
    private(set) var hasClock = false
    /// Observed clock BPM, or nil when no clock.
    private(set) var bpm: Double?
    /// Drives the transient "GRABBED · N BARS" confirmation flash; cleared after ~2 s.
    private(set) var lastResult: Result?

    /// Absolute rolling-buffer frame at the most recently delivered downbeat tick.
    private var lastDownbeatFrame: Int?

    private let store: GrabPreferenceStore
    private var isRestoring = true
    private var flashTask: Task<Void, Never>?

    init(store: GrabPreferenceStore = UserDefaults.standard) {
        self.store = store
        if let b = store.grabBars(), Self.barChoices.contains(b) { bars = b }
        if let s = store.grabSeconds(), Self.secondsChoices.contains(s) { seconds = s }
        isRestoring = false
    }

    // MARK: - Clock model (fed from the MIDI clock on the main actor)

    /// Update the observed clock. `secondsPerClock` is the smoothed 24-PPQN tick
    /// interval; BPM = 60 / (secondsPerClock · 24). Marks the clock present.
    func updateClock(secondsPerClock: Double, sampleRate: Double) {
        guard secondsPerClock > 0 else { return }
        bpm = 60.0 / (secondsPerClock * 24.0)
        hasClock = true
    }

    /// Record the rolling-buffer frame at a delivered downbeat tick (bar boundary).
    func markDownbeat(frame: Int) { lastDownbeatFrame = frame }

    /// The clock stopped / was reset (disconnect, sleep, transport reset). The BPM is
    /// no longer honest, so drop to the seconds path until a clock returns.
    func clockLost() {
        hasClock = false
        bpm = nil
        lastDownbeatFrame = nil
    }

    // MARK: - Grab

    /// Freeze the recent past into a take. Pure decisions delegate to `GrabMath`; the
    /// only side effect is writing one WAV into the Recordings directory and ingesting
    /// it. Returns the outcome and mirrors it into `lastResult` for the UI flash.
    @discardableResult
    func grab(buffer: RollingCaptureBuffer, takes: TakesStore,
              sampleRate: Double, isMonitoring: Bool, now: Date = Date()) -> Result {
        guard isMonitoring else { return finish(.notMonitoring) }

        let head = buffer.nowFrame
        let oldest = buffer.oldestResidentFrame

        // Choose the clocked bar window when a fresh clock + downbeat anchor gives at
        // least one whole bar of resident history; else fall back to last-N-seconds.
        var isClockPath = false
        var window = GrabMath.secondsWindow(sampleRate: sampleRate, seconds: Double(seconds),
                                            now: head, oldestResident: oldest)
        if hasClock, let bpm, let down = lastDownbeatFrame {
            let anchored = min(down, head)
            let w = GrabMath.barWindow(sampleRate: sampleRate, bpm: bpm, beatsPerBar: 4,
                                       bars: bars, lastDownbeatFrame: anchored,
                                       oldestResident: oldest)
            if w.bars > 0 {
                window = w
                isClockPath = true
            }
        }

        let frames = window.endFrame - window.startFrame
        let minFrames = Int(sampleRate * 0.25)   // < a quarter second is not a loop
        guard frames >= minFrames else { return finish(.emptyHistory) }

        // Seqlock snapshot; retry once if the producer overran mid-copy, else refuse
        // honestly rather than write a torn loop.
        var scratch = [Float](repeating: 0, count: frames * 2)
        var ok = buffer.snapshot(startFrame: window.startFrame, endFrame: window.endFrame, into: &scratch)
        if !ok {
            ok = buffer.snapshot(startFrame: window.startFrame, endFrame: window.endFrame, into: &scratch)
        }
        guard ok else { return finish(.failed("HISTORY MOVED — TRY AGAIN")) }

        // Mono mixdown for zero-cross detection (both ends on the same rising slope).
        var mono = [Float](repeating: 0, count: frames)
        for i in 0..<frames { mono[i] = 0.5 * (scratch[i * 2] + scratch[i * 2 + 1]) }
        let radius = min(frames / 4, max(1, Int(sampleRate * 0.010)))
        let startIdx = GrabMath.snapToZeroCrossing(mono, target: 0, radius: radius)
        let endIdx = GrabMath.snapToZeroCrossing(mono, target: frames, radius: radius)
        // Only accept the trim if it still leaves a real loop; else keep the full window.
        let trimOK = endIdx - startIdx >= minFrames
        let s = trimOK ? startIdx : 0
        let e = trimOK ? endIdx : frames
        let finalFrames = e - s

        // BPM: clocked → the observed value; unclocked → an EST from onset autocorr.
        let estBPM: Int? = isClockPath
            ? nil
            : GrabMath.estimateBPM(mono: Array(mono[s..<e]), sampleRate: sampleRate)
                .map { Int($0.rounded()) }
        let actualSeconds = max(1, Int((Double(finalFrames) / sampleRate).rounded()))
        let kind: GrabMath.Kind = isClockPath
            ? .barsClocked(bars: window.bars, bpm: Int((bpm ?? 0).rounded()))
            : .secondsUnclocked(seconds: actualSeconds, estBPM: estBPM)

        let url = TakesStore.recordingsDir()
            .appendingPathComponent(GrabMath.filename(kind: kind, date: now))
        do {
            var writer: WAVFileWriter? = try WAVFileWriter(url: url, sampleRate: sampleRate)
            try scratch.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                try writer!.write(interleaved: base + s * 2, frames: finalFrames)
            }
            writer = nil   // drop → finalize the WAV header
        } catch {
            return finish(.failed("COULD NOT WRITE GRAB"))
        }

        takes.ingest(url: url)
        guard let take = takes.takes.first(where: { $0.url == url }) else {
            return finish(.failed("GRAB FILE UNREADABLE"))
        }

        if isClockPath, window.bars < bars {
            return finish(.truncated(take, askedBars: bars, gotBars: window.bars))
        }
        return finish(.grabbed(take))
    }

    /// Set `lastResult` and schedule it to clear after ~2 s so the confirmation flash
    /// is transient. Returns the result so callers can `return finish(...)`.
    @discardableResult
    private func finish(_ result: Result) -> Result {
        lastResult = result
        flashTask?.cancel()
        // Only the positive outcomes flash-and-clear; failures/empties clear too so
        // the caption returns to its steady honest line.
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.lastResult = nil
        }
        return result
    }
}

// MARK: - Persistence seam (mirror LoadPreferenceStore / MonitorPreferenceStore)

/// Remembered GRAB preferences (bar count + seconds). A protocol so unit tests use an
/// in-memory double instead of shared `UserDefaults`. `nil` means "never set" → default.
protocol GrabPreferenceStore: AnyObject {
    func grabBars() -> Int?
    func setGrabBars(_ bars: Int)
    func grabSeconds() -> Int?
    func setGrabSeconds(_ seconds: Int)
}

extension UserDefaults: GrabPreferenceStore {
    private static let grabBarsKey = "halo.grab.bars"
    private static let grabSecondsKey = "halo.grab.seconds"

    func grabBars() -> Int? {
        object(forKey: Self.grabBarsKey) == nil ? nil : integer(forKey: Self.grabBarsKey)
    }
    func setGrabBars(_ bars: Int) { set(bars, forKey: Self.grabBarsKey) }
    func grabSeconds() -> Int? {
        object(forKey: Self.grabSecondsKey) == nil ? nil : integer(forKey: Self.grabSecondsKey)
    }
    func setGrabSeconds(_ seconds: Int) { set(seconds, forKey: Self.grabSecondsKey) }
}
