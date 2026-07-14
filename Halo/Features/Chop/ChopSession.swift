import AVFoundation
import Foundation

/// The audio source a CHOP surface slices — a small value type built from any of:
/// a decoded imported sample+buffer (from Edit), or a captured take/grab URL decoded
/// via `SampleProcessor`. All LOCAL and REAL (a decoded `CanonicalAudioBuffer`).
struct ChopSource: Sendable, Equatable {
    let name: String
    let buffer: CanonicalAudioBuffer
    var sampleRate: Double { buffer.sampleRate }
    var channelCount: Int { buffer.channelCount }
    var frameCount: Int { buffer.frameCount }

    /// Decode a captured take/grab (or any supported file) off the main actor.
    static func fromURL(_ url: URL) async -> ChopSource? {
        guard let buffer = try? await SampleProcessor.decode(url: url) else { return nil }
        return ChopSource(name: url.deletingPathExtension().lastPathComponent, buffer: buffer)
    }

    /// Reuse an already-resident Edit buffer (no re-decode).
    static func fromEditBuffer(name: String, buffer: CanonicalAudioBuffer) -> ChopSource {
        ChopSource(name: name, buffer: buffer)
    }
}

/// CHOP surface state (Brief §5c). Presented as a transient panel, NOT a seventh mode
/// (DD-030). UI-only + LOCAL DSP, the same honesty class as `EditSession` (DD-022):
///
///   • SOURCE audio, onsets, slices, per-slice fades, audition and byte estimates are
///     LOCAL and REAL — computed off-main from the decoded buffer (`OnsetDetector`,
///     `SamplePrep`, `SampleTreatment`, `SampleMemoryEstimator`).
///   • The pad/slot DESTINATION is MOCK device context (`MockDeviceLibrary.standard`),
///     and SEND TO PADS is DISABLED (device transfer = Phase 0B, needsDevice).
///
/// Detection runs off `@MainActor` (Brief §2); this class only threads values.
@MainActor
@Observable
final class ChopSession {

    private(set) var isOpen = false
    private(set) var source: ChopSource?
    private(set) var mono: [Float] = []
    private(set) var summary: WaveformSummary = WaveformSummary(minima: [], maxima: [],
                                                                framesPerBucket: 0, sourceFrameCount: 0)
    var params = OnsetDetector.Parameters()
    private(set) var sliceSet = SliceSet(sourceFrameCount: 0, onsets: [])
    var selectedSlice: Int?
    private(set) var slicePreps: [Int: SamplePrep] = [:]   // per-slice fade/gain (default micro-fade)

    // Destination (MOCK)
    var group = 0
    var startGridIndex = 0
    var treatment: SampleTreatment = .original
    var baseName = "CHOP"
    let deviceLibrary = MockDeviceLibrary.standard
    let sender: any ChopSending = DeviceUnavailableChopSender()

    // Audition provenance (LOCAL). The model plays the shared `AuditionPlayer`; these let
    // the waveform draw the playhead only on the slice that is actually playing.
    private(set) var auditioningSlice: Int?
    private(set) var auditionID: UUID?

    private var detectGeneration = 0

    // MARK: - Lifecycle

    /// Equal-power micro-fade (~4 ms both ends) — the anti-click default per slice.
    static func microFadePrep(rate: Double) -> SamplePrep {
        var p = SamplePrep.identity
        let f = max(1, Int(0.004 * max(0, rate)))
        p.fadeInFrames = f
        p.fadeOutFrames = f
        return p
    }

    func begin(source: ChopSource) {
        self.source = source
        self.mono = source.buffer.monoMixdown()
        self.summary = WaveformSummary.build(mono: mono, targetBuckets: WaveformSummary.defaultBucketCount)
        self.selectedSlice = nil
        self.slicePreps = [:]
        self.startGridIndex = 0
        self.group = 0
        self.baseName = source.name.isEmpty ? "CHOP" : String(source.name.prefix(12)).uppercased()
        self.isOpen = true
        detect()
    }

    func close() {
        isOpen = false
        source = nil
        mono = []
        summary = WaveformSummary(minima: [], maxima: [], framesPerBucket: 0, sourceFrameCount: 0)
        sliceSet = SliceSet(sourceFrameCount: 0, onsets: [])
        slicePreps = [:]
        selectedSlice = nil
        auditioningSlice = nil
        auditionID = nil
    }

    // MARK: - Detection (off-main)

    /// Re-run onset detection. Any manual cut edits are replaced by the fresh grid (the
    /// UI caption warns). Detection runs off `@MainActor`; a stale result is ignored via
    /// the generation token.
    func detect() {
        guard let rate = source?.sampleRate, rate > 0 else {
            sliceSet = SliceSet(sourceFrameCount: mono.count, onsets: [])
            reseedPreps()
            return
        }
        detectGeneration += 1
        let generation = detectGeneration
        let mono = self.mono
        let p = params
        let n = mono.count
        Task { @MainActor in
            let onsets = await Task.detached(priority: .userInitiated) {
                OnsetDetector.detectOnsets(mono: mono, sampleRate: rate, parameters: p)
            }.value
            guard generation == self.detectGeneration else { return }   // superseded
            self.sliceSet = SliceSet(sourceFrameCount: n, onsets: onsets)
            self.selectedSlice = nil
            self.slicePreps = [:]
            self.reseedPreps()
        }
    }

    func setSensitivity(_ v: Double) {
        params.sensitivity = min(max(v, 0), 1)
        detect()
    }

    func clearCuts() {
        sliceSet.clear()
        selectedSlice = nil
        slicePreps = [:]
        reseedPreps()
    }

    private func reseedPreps() {
        let rate = source?.sampleRate ?? 0
        for slice in sliceSet.slices() where slicePreps[slice.id] == nil {
            slicePreps[slice.id] = Self.microFadePrep(rate: rate)
        }
    }

    /// A cut must be at least one summary bucket + one micro-fade wide.
    var minGap: Int {
        let rate = source?.sampleRate ?? 0
        return max(summary.framesPerBucket, Int(params.minSliceMilliseconds / 1000 * rate), 1)
    }

    // MARK: - Marker edits

    func addCut(atFrame frame: Int) {
        sliceSet.addCut(at: frame, minGap: minGap)
        reseedPreps()
        // Select the slice the new cut created (the one whose start is at/just after frame).
        if let idx = sliceSet.slices().firstIndex(where: { $0.startFrame >= frame }) {
            selectedSlice = idx
        }
    }

    func moveCut(index i: Int, toFrame frame: Int) {
        sliceSet.moveCut(index: i, to: frame, minGap: minGap)
    }

    func removeCut(index i: Int) {
        sliceSet.removeCut(index: i)
        reseedPreps()
        if let sel = selectedSlice, sel >= sliceSet.sliceCount { selectedSlice = nil }
    }

    /// Delete the cut at the selected slice's START, merging it with the previous slice
    /// (⌫ path). The first slice has no leading cut, so it is a no-op there.
    func removeCutAtSelectedSliceStart() {
        guard let sel = selectedSlice, sel > 0 else { return }
        removeCut(index: sel - 1)         // cut (sel-1) is slice `sel`'s leading boundary
        selectedSlice = sel - 1
    }

    // MARK: - Per-slice prep

    func prep(forSlice i: Int) -> SamplePrep {
        slicePreps[i] ?? Self.microFadePrep(rate: source?.sampleRate ?? 0)
    }

    func setFadeIn(_ frames: Int, forSlice i: Int)  { mutatePrep(i) { $0.fadeInFrames = max(0, frames) } }
    func setFadeOut(_ frames: Int, forSlice i: Int) { mutatePrep(i) { $0.fadeOutFrames = max(0, frames) } }
    func setGainDB(_ db: Float, forSlice i: Int)    { mutatePrep(i) { $0.gainDecibels = db } }

    private func mutatePrep(_ i: Int, _ transform: (inout SamplePrep) -> Void) {
        var p = prep(forSlice: i)
        transform(&p)
        slicePreps[i] = p
    }

    // MARK: - Audition (LOCAL, honest)

    /// Build the prepared+treated float buffer for slice `i`: apply the slice window as a
    /// trim, the per-slice micro-fade/gain prep, then resample to the treatment rate so a
    /// LO-FI preset actually sounds lo-fi (mirrors `EditSession.auditionBuffer`, DD-022).
    /// Heavy DSP runs off `@MainActor`.
    func sliceAuditionBuffer(index i: Int) async -> AVAudioPCMBuffer? {
        let all = sliceSet.slices()
        guard let source, all.indices.contains(i) else { return nil }
        let slice = all[i]
        var prep = prep(forSlice: i)
        prep.trimStartFrame = slice.startFrame
        prep.trimEndFrame = slice.endFrame
        let treatment = self.treatment
        let buffer = source.buffer

        let rendered: (channels: [[Float]], rate: Double)? = await Task.detached(priority: .userInitiated) {
            let prepped = prep.apply(to: buffer)
            let rate = treatment.resolvedSampleRate(sourceSampleRate: prepped.sampleRate)
            let channels: [[Float]]
            if rate == prepped.sampleRate {
                channels = prepped.channels
            } else {
                channels = (try? SampleTreatmentEncoder.resample(prepped.channels,
                                                                 from: prepped.sampleRate,
                                                                 to: rate)) ?? prepped.channels
            }
            return (channels, rate)
        }.value

        guard let rendered else { return nil }
        return AuditionPlayer.makeBuffer(channels: rendered.channels, sampleRate: rendered.rate)
    }

    /// Mark that slice `i` is about to be auditioned; returns a fresh id for the shared
    /// `AuditionPlayer` so the waveform playhead binds to this exact playback.
    func beginAudition(slice i: Int) -> UUID {
        let id = UUID()
        auditioningSlice = i
        auditionID = id
        selectedSlice = i
        return id
    }

    // MARK: - Plan (pure, derived)

    var plan: SendToPadsPlan {
        ChopPlanner.plan(slices: sliceSet.slices(),
                         channelCount: source?.channelCount ?? 0,
                         treatment: treatment,
                         sourceRate: source?.sampleRate ?? 0,
                         group: group,
                         startGridIndex: startGridIndex,
                         baseName: baseName,
                         library: deviceLibrary)
    }

    #if DEBUG
    /// Test/preview injection: open on an already-decoded buffer without touching disk.
    func injectPreview(source: ChopSource) { begin(source: source) }
    #endif
}
