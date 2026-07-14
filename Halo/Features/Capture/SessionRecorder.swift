import Foundation
import Synchronization   // macOS 26 target — Atomic is available

/// Session recorder lifecycle (Brief §7 Capture). @MainActor @Observable: owns the
/// recordings directory, the drain thread, and the honest published readouts. It
/// taps the RAW pre-monitor input through the shared `CaptureTap` (DD-018), so a
/// recording only exists while a monitor route is live; the caller (`HaloAppModel`)
/// gates `start` on `monitor.isRunning` and refuses otherwise with a real reason.
///
/// HONESTY (Brief §1/§4): `state` and every readout reflect only what actually
/// happened. `.recording` is set ONLY while the drain thread is running, so it is
/// the true producer of `HaloRingState.recording`. A silent instrument yields an
/// honestly-silent WAV; an absent route yields no take. On a route drop mid-record
/// the owner calls `finishIfRecording()` and the partial take is finalized (valid
/// WAV), never faked.
@MainActor
@Observable
final class SessionRecorder {
    enum Reason: Equatable {
        case monitorOff
        case fileOpen(String)
    }

    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case failed(Reason)
    }

    private(set) var state: State = .idle
    /// Seconds since the take started (wall clock), refreshed by the poll loop.
    private(set) var elapsed: TimeInterval = 0
    /// RAW pre-monitor peaks (dBFS) for the capture readout.
    private(set) var peaks: StereoLevels = .silence
    /// Max-hold peaks across the whole take (dBFS; -inf until first audio).
    private(set) var peakHoldL: Float = -.infinity
    private(set) var peakHoldR: Float = -.infinity
    private(set) var diskFreeBytes: Int64 = 0
    /// Sample rate the current/last take is being written at (for disk-time math).
    private(set) var sampleRate: Double = 48_000
    /// Whether the current/last take is a PRINT FX (post-rack) capture (Brief §7).
    private(set) var printFX: Bool = false

    var isRecording: Bool { if case .recording = state { return true }; return false }
    var startedAt: Date? { if case let .recording(t) = state { return t }; return nil }

    private let tap: CaptureTap
    private let takes: TakesStore
    private var drain: RecordingDrain?
    private var pollTask: Task<Void, Never>?
    private var currentURL: URL?
    private var lastDiskRefresh: Date = .distantPast

    init(tap: CaptureTap, takes: TakesStore) {
        self.tap = tap
        self.takes = takes
        diskFreeBytes = Self.diskFree()
    }

    /// ⌘R / RECORD. `sampleRate` comes from the running route's output device — the
    /// recorder does not guess it (see `HaloAppModel.toggleRecording`). Precondition:
    /// the monitor route is running (the caller gates this); if the file cannot be
    /// opened the recorder fails honestly and records nothing.
    ///
    /// `printFX` (Brief §7, Phase 5a): when true the take records the POST-rack signal
    /// (the output callback becomes the tap producer) and the file is tagged so a
    /// print-FX take is never mistaken for a raw one. Default false = raw input.
    func start(sampleRate: Double, printFX: Bool = false) {
        guard !isRecording else { return }
        self.sampleRate = sampleRate
        self.printFX = printFX
        let url = TakesStore.recordingsDir().appendingPathComponent(Self.filename(printFX: printFX))
        do {
            let writer = try WAVFileWriter(url: url, sampleRate: sampleRate)
            tap.framesWritten.store(0, ordering: .relaxed)
            tap.meter.reset()
            tap.drain()                                  // discard any pre-roll
            // Route the tap BEFORE arming so exactly one callback produces (SPSC).
            tap.postFX.store(printFX, ordering: .relaxed)
            tap.armed.store(true, ordering: .relaxed)    // arm the producer
            drain = RecordingDrain(tap: tap, writer: writer)   // spawns the drain thread
            currentURL = url
            peakHoldL = -.infinity
            peakHoldR = -.infinity
            peaks = .silence
            elapsed = 0
            state = .recording(startedAt: Date())
            startPolling()
        } catch {
            tap.armed.store(false, ordering: .relaxed)
            tap.postFX.store(false, ordering: .relaxed)
            state = .failed(.fileOpen("\(error)"))
        }
    }

    /// STOP. Disarms the producer, drains the remainder, closes the file, then
    /// ingests the REAL take metadata.
    func stop() {
        guard isRecording, let drain, let url = currentURL else { return }
        tap.armed.store(false, ordering: .relaxed)   // stop the producer first
        tap.postFX.store(false, ordering: .relaxed)  // reset the tap route to raw
        drain.finish()                               // flush remainder, close, join
        self.drain = nil
        pollTask?.cancel(); pollTask = nil
        currentURL = nil
        state = .idle
        elapsed = 0
        peaks = .silence
        peakHoldL = -.infinity
        peakHoldR = -.infinity
        takes.ingest(url: url)                        // real file → Take (post-flush)
    }

    /// Called wherever the route stops (USB removal, stopMonitor) so a yank
    /// finalizes the take instead of leaving a dangling writer.
    func finishIfRecording() {
        if isRecording { stop() }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, case let .recording(startedAt) = self.state else { return }
                let snap = self.tap.meter.snapshot()
                self.peaks = snap
                if snap.peakL.isFinite { self.peakHoldL = max(self.peakHoldL, snap.peakL) }
                if snap.peakR.isFinite { self.peakHoldR = max(self.peakHoldR, snap.peakR) }
                self.elapsed = Date().timeIntervalSince(startedAt)
                // Refresh free-disk ~1 Hz (a stat call is cheap but not free).
                let now = Date()
                if now.timeIntervalSince(self.lastDiskRefresh) > 1 {
                    self.diskFreeBytes = Self.diskFree()
                    self.lastDiskRefresh = now
                }
                try? await Task.sleep(for: .milliseconds(20))   // 50 Hz
            }
        }
    }

    // MARK: - Helpers

    nonisolated static func filename(date: Date = Date(), printFX: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm-ss"
        // PRINT FX takes carry an "-fx" tag so a post-rack capture is never mistaken
        // for a raw one on disk (Brief §7: "clearly labelled on the take").
        let tag = printFX ? "-fx" : ""
        return "take-\(f.string(from: date))\(tag).wav"
    }

    nonisolated static func diskFree() -> Int64 {
        let dir = TakesStore.recordingsDir()
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

/// The sole consumer thread for one recording (AudioRingBuffer is single-consumer).
/// The `WAVFileWriter` is constructed on the main actor and handed here; after
/// construction it is touched ONLY by this thread, so the crossing is safe under
/// the documented single-thread contract (same pattern as `AudioRingBuffer`,
/// `AudioMeter`, `MonitorRenderContext`).
final class RecordingDrain: @unchecked Sendable {
    private let tap: CaptureTap
    private let writer: WAVFileWriter
    private let scratchCapacity = 8192
    private let scratch: UnsafeMutablePointer<Float>
    private let stopFlag = Atomic<Bool>(false)
    private let done = DispatchSemaphore(value: 0)

    init(tap: CaptureTap, writer: WAVFileWriter) {
        self.tap = tap
        self.writer = writer
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        let thread = Thread { [self] in run() }
        thread.name = "halo.recording.drain"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func run() {
        while !stopFlag.load(ordering: .relaxed) {
            if pump() == 0 { usleep(4_000) }   // ~4 ms idle when the ring is empty
        }
        // Final non-blocking drain of whatever remains after the producer disarmed.
        while pump() > 0 {}
        done.signal()
    }

    /// Read available samples and write them; update the tap's frame counter.
    /// Returns floats drained (0 on underrun — safe no-op for silent/absent input).
    @discardableResult
    private func pump() -> Int {
        let got = tap.ring.read(into: scratch, count: scratchCapacity)
        guard got > 0 else { return 0 }
        let frames = got / 2
        if frames > 0 {
            try? writer.write(interleaved: scratch, frames: frames)
            // Single writer of framesWritten (this thread) — plain RMW is safe.
            tap.framesWritten.store(tap.framesWritten.load(ordering: .relaxed) + frames,
                                    ordering: .relaxed)
        }
        return got
    }

    /// Stop the loop, drain the remainder, and JOIN — guarantees the file is fully
    /// written and closed before the caller reopens it for metadata.
    func finish() {
        stopFlag.store(true, ordering: .relaxed)
        done.wait()
        scratch.deallocate()
    }
}
