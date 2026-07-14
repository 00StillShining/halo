import AVFoundation
import Foundation

/// EDIT-mode UI state (Brief §7). UI-only, the same honesty class as `LoadSession`
/// (DD-013): nothing here touches `displayState`, `ringState`, or any MIDI path, so a
/// mode round-trip through EDIT can never disturb PREVIEW / WAIT / LIVE provenance.
///
/// TWO PROVENANCE CLASSES (DD-022):
///   • LOCAL sample (REAL) — an imported file decoded to a `CanonicalAudioBuffer`. Its
///     waveform, trim/fade/gain/normalise/channel/rate treatment, byte estimate and
///     audition are all real, computed by code that already exists (`SamplePrep`,
///     `SampleTreatment`, `WaveformSummary`, `SampleMemoryEstimator`). No mock.
///   • PAD TARGET (MOCK) — which device pad this edit is *destined for*. Drives the
///     camera ease and shows the current mock assignment from `MockDeviceLibrary.standard`.
///     `SEND CHANGES` is disabled (device transfer = Phase 0B, needsDevice).
///
/// Editing is NON-DESTRUCTIVE: mutating a prep/treatment never touches the asset or its
/// decoded buffer — it only records the recipe (`SamplePrep.apply` returns a new buffer).
@MainActor
@Observable
final class EditSession {

    /// Local imports, newest first. Lightweight (metadata + cached summary only).
    private(set) var library: [SampleAsset] = []

    /// Heavy canonical buffers. Cache-of-1: only the selected asset's buffer is kept
    /// resident to bound RAM; others are evicted on selection change and re-decoded
    /// lazily from `asset.sourceURL` when re-selected (`ensureBuffer`).
    private(set) var buffers: [UUID: CanonicalAudioBuffer] = [:]

    /// The edit subject (a LOCAL sample). Setting it goes through `select`.
    private(set) var selectedAssetID: UUID?

    /// Per-asset non-destructive recipe. Defaults to `.identity` / `.original`.
    private(set) var preps: [UUID: SamplePrep] = [:]
    private(set) var treatments: [UUID: SampleTreatment] = [:]

    // Pad target (MOCK device context) — destination + camera, never the edit subject.
    var selectedGroup = 0                     // 0…3 = A…D
    private(set) var selectedGridIndex: Int?  // 0…11 in EP40Entity.padGridOrder space

    /// True while the rename `TextField` holds focus; gates Space-audition so typing a
    /// space inserts a space instead of toggling playback (Brief §7). The ONLY text
    /// input in Edit — this gate is the single reason it exists.
    var isRenaming = false

    /// The single MOCK device library — the same static value `LoadSession` reads, so
    /// the two can never diverge. Real device reads need the verified protocol (Phase 0B).
    let deviceLibrary = MockDeviceLibrary.standard

    // MARK: - Import (off the main actor)

    /// Import supported files, newest first. Decode runs off `@MainActor` (Brief §2).
    /// An unsupported or undecodable file is skipped honestly (no invented asset).
    func `import`(urls: [URL]) async {
        for url in urls {
            guard SampleProcessor.isSupported(url) else { continue }
            guard let pair = try? await SampleProcessor.importSample(url: url) else { continue }
            library.insert(pair.asset, at: 0)
            preps[pair.asset.id] = .identity
            treatments[pair.asset.id] = .original
            buffers[pair.asset.id] = pair.buffer   // resident until another asset is selected
        }
    }

    // MARK: - Selection

    /// Select an asset (or clear). Cache-of-1: drop every other buffer; a re-selected
    /// asset whose buffer was evicted is re-decoded lazily via `ensureBuffer`.
    func select(_ id: UUID?) {
        selectedAssetID = id
        guard let id else { return }
        buffers = buffers.filter { $0.key == id }
        if buffers[id] == nil { Task { await ensureBuffer(id) } }
    }

    /// Guarantee the selected asset's buffer is resident, re-decoding from disk if it
    /// was evicted by the cache-of-1 policy. Idempotent; safe to await repeatedly.
    func ensureBuffer(_ id: UUID) async {
        guard buffers[id] == nil,
              let asset = library.first(where: { $0.id == id }) else { return }
        if let buffer = try? await SampleProcessor.decode(url: asset.sourceURL) {
            // The selection may have changed while decoding — only keep it if it is
            // still the (or a) resident asset, honouring cache-of-1.
            if selectedAssetID == id { buffers[id] = buffer }
        }
    }

    var selectedAsset: SampleAsset? { library.first { $0.id == selectedAssetID } }
    var selectedPrep: SamplePrep { selectedAssetID.flatMap { preps[$0] } ?? .identity }
    var selectedTreatment: SampleTreatment { selectedAssetID.flatMap { treatments[$0] } ?? .original }
    var selectedBuffer: CanonicalAudioBuffer? { selectedAssetID.flatMap { buffers[$0] } }

    // MARK: - Pad target (MOCK)

    /// The mock assignment currently on the selected pad, if any.
    var selectedAssignment: MockPadAssignment? {
        guard let gridIndex = selectedGridIndex else { return nil }
        return deviceLibrary.project.assignment(group: selectedGroup, gridIndex: gridIndex)
    }

    /// The mock sound the selected pad currently references, if any.
    var selectedPadSound: MockDeviceSound? {
        selectedAssignment?.slot.flatMap { deviceLibrary.sound(for: $0) }
    }

    /// Lowest addressable slot not currently occupied (mock). "next free".
    var nextFreeSlot: SampleSlotID? {
        let used = Set(deviceLibrary.sounds.map { $0.slot.raw })
        guard let free = (1...999).first(where: { !used.contains($0) }) else { return nil }
        return SampleSlotID(free)
    }

    // MARK: - Prep mutators (non-destructive; each drives one rail control)

    func setTrim(start: Int, end: Int?) { mutatePrep { $0.trimStartFrame = start; $0.trimEndFrame = end } }
    func setFadeIn(_ frames: Int)  { mutatePrep { $0.fadeInFrames = max(0, frames) } }
    func setFadeOut(_ frames: Int) { mutatePrep { $0.fadeOutFrames = max(0, frames) } }
    func setGainDB(_ db: Float)    { mutatePrep { $0.gainDecibels = db } }
    func setNormalize(_ on: Bool)  { mutatePrep { $0.normalize = on } }
    func setChannelMode(_ mode: SamplePrep.ChannelMode) { mutatePrep { $0.channelMode = mode } }
    func setTreatment(_ t: SampleTreatment) { if let id = selectedAssetID { treatments[id] = t } }
    func resetPrep() { if let id = selectedAssetID { preps[id] = .identity } }

    private func mutatePrep(_ transform: (inout SamplePrep) -> Void) {
        guard let id = selectedAssetID else { return }
        var p = preps[id] ?? .identity
        transform(&p)
        preps[id] = p
    }

    /// Rename the selected (or given) asset. Structs are value types, so this rebuilds
    /// the library entry in place; the label is editable UI metadata, never a device claim.
    func rename(id: UUID, to newName: String) {
        guard let index = library.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        library[index].displayName = trimmed
    }

    // MARK: - Memory impact (REAL local estimate)

    /// The on-device byte estimate for the current prep+treatment (Brief §7). Pure
    /// arithmetic on measured counts — decodes nothing, invents nothing.
    var selectedEstimate: SampleSizeEstimate? {
        guard let a = selectedAsset else { return nil }
        return SampleMemoryEstimator.estimate(for: a, prep: selectedPrep, treatment: selectedTreatment)
    }

    // MARK: - Audition buffer (LOCAL, honest)

    /// Prepared + treated float buffer for LOCAL audition: the prep is applied so you
    /// HEAR the edit, and it is resampled to the treatment rate so a LO-FI preset
    /// actually sounds lo-fi (honest). Heavy DSP runs off `@MainActor` (Brief §2); the
    /// result crosses back as Sendable `[[Float]]` and the AVAudioPCMBuffer is built here.
    func auditionBuffer() async -> AVAudioPCMBuffer? {
        guard let id = selectedAssetID else { return nil }
        await ensureBuffer(id)
        guard let source = buffers[id] else { return nil }
        let prep = selectedPrep
        let treatment = selectedTreatment

        let rendered: (channels: [[Float]], rate: Double)? = await Task.detached(priority: .userInitiated) {
            let prepped = prep.apply(to: source)
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

    // MARK: - Space-audition gate (pure, unit-testable)

    /// The Space-to-audition rule (Brief §7): audition only in Edit, only when a sample
    /// is selected, and never while the rename field is focused (so Space types a space).
    static func shouldAudition(mode: HaloMode, isRenaming: Bool, hasSelection: Bool) -> Bool {
        mode == .edit && !isRenaming && hasSelection
    }

    // MARK: - Optional: import from local takes

    #if DEBUG
    /// Test/preview injection: add an already-decoded asset+buffer without touching disk.
    func injectPreview(asset: SampleAsset, buffer: CanonicalAudioBuffer) {
        library.insert(asset, at: 0)
        preps[asset.id] = .identity
        treatments[asset.id] = .original
        buffers[asset.id] = buffer
    }
    #endif

    /// Set (or clear) the pad target. The camera ease is driven by `HaloAppModel`.
    func setPadTarget(gridIndex: Int?) { selectedGridIndex = gridIndex }
}
