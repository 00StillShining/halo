import Foundation

/// A locally imported sample — the lightweight, UI-facing model (Brief §8 sample
/// processing). It carries only measured metadata plus the cached `WaveformSummary`,
/// never the heavy `CanonicalAudioBuffer`, so an `@Observable` library of these
/// stays cheap to diff and store. The editor pairs an asset with its buffer via
/// `SampleProcessor.importSample`.
///
/// HONESTY (Brief §1/§4): every field is read from the real decoded file. This is a
/// LOCAL asset — importing a file says nothing about, and claims nothing of, any
/// EP-40 slot. Library slots and pad assignments are a separate device concept
/// (Brief §3) and must never be conflated with a local import.
struct SampleAsset: Identifiable, Sendable, Equatable, Hashable {
    let id: UUID
    /// Where the file was imported from (real on-disk URL).
    let sourceURL: URL
    /// Editable label; defaults to the source filename without extension.
    var displayName: String
    /// The decoded container/codec family.
    let format: SampleSourceFormat
    /// Preserved source sample rate (Hz).
    let sampleRate: Double
    /// Real decoded channel count.
    let channelCount: Int
    /// Real decoded frame count.
    let frameCount: Int
    /// Cached min/max envelope for drawing without rescanning the buffer.
    let summary: WaveformSummary
    let importedAt: Date

    var durationSeconds: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// Canonical-buffer footprint held in memory while editing: Float32 per sample.
    /// This is halo's RAM cost, distinct from the device export estimate — see
    /// `SampleMemoryEstimator` for the on-device 16-bit byte figure.
    var canonicalBytes: Int { frameCount * channelCount * MemoryLayout<Float>.size }

    #if DEBUG
    /// Preview/test fixture — no real file required. Builds a summary from a
    /// supplied mono signal so a `#Preview` can render a real waveform shape.
    static func previewFixture(_ name: String,
                               mono: [Float],
                               sampleRate: Double = 46_875,
                               channels: Int = 2) -> SampleAsset {
        SampleAsset(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/\(name)"),
            displayName: name,
            format: .wav,
            sampleRate: sampleRate,
            channelCount: channels,
            frameCount: mono.count,
            summary: WaveformSummary.build(mono: mono, targetBuckets: WaveformSummary.defaultBucketCount),
            importedAt: Date(timeIntervalSince1970: 1_752_400_000))
    }
    #endif
}
