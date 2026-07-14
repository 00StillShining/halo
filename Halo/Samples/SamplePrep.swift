import Accelerate
import Foundation

/// A non-destructive preparation recipe for an imported sample (Brief §8 "Non-destructive
/// trim/fade/rate/channel preparation", right rail §7 "trim, fade, gain/normalise,
/// mono/stereo"). It is a plain, `Sendable`, `Equatable` value type: it describes the
/// edit, it never mutates the source. `apply(to:)` reads a `CanonicalAudioBuffer` and
/// returns a NEW buffer, still in the float domain at the source rate — the sample-rate
/// treatment (`SampleTreatment`) is a separate, later stage. The original decoded buffer
/// is always retained untouched so any edit is reversible by re-applying a different prep.
///
/// Order of operations (documented, deterministic — see docs/design-decisions.md):
///   1. trim      — select a frame window [start, end)
///   2. channels  — equal-power mono downmix / mono→stereo copy
///   3. gain      — linear gain from `gainDecibels`
///   4. fades     — equal-power (sine/cosine) in/out ramps
///   5. normalise — opt-in peak normalise to `normalizeTargetDecibels` (default −1 dBFS)
///
/// Normalise runs LAST so the output's true peak lands exactly on the target regardless of
/// the prior gain/fade. All maths is on real decoded samples; silence stays silence (a
/// zero-peak buffer is never scaled up into invented signal — Brief §1/§4 honesty).
struct SamplePrep: Sendable, Equatable {

    /// Channel conversion (Brief §8 "Mono conversion equal-power or documented, never a
    /// naïve channel discard").
    enum ChannelMode: String, Sendable, Equatable, CaseIterable {
        /// Leave the channel layout exactly as decoded.
        case preserve
        /// Downmix to a single channel: `Σ ch / √channelCount` (equal-power sum — RMS is
        /// preserved for uncorrelated channels; a correlated full-scale pair can exceed
        /// unity and is caught by opt-in normalise / the export clamp). Never a discard.
        case mono
        /// Force two channels. A mono source is copied to both L and R (documented: mono→
        /// stereo copy, not attenuated). A source with ≥2 channels keeps its first two.
        case stereo
    }

    /// First frame kept, in SOURCE frames (clamped to the buffer at apply time).
    var trimStartFrame: Int = 0
    /// One-past-the-last frame kept, in SOURCE frames; `nil` means "to the end".
    var trimEndFrame: Int? = nil

    /// Equal-power fade-in length in frames (0 = none). Applied within the trimmed window.
    var fadeInFrames: Int = 0
    /// Equal-power fade-out length in frames (0 = none). Applied within the trimmed window.
    var fadeOutFrames: Int = 0

    /// Linear gain expressed in decibels (0 dB = unity). Applied before fades/normalise.
    var gainDecibels: Float = 0

    /// Opt-in peak normalisation (Brief §8 "Peak normalisation defaults to −1 dBFS, opt-in").
    var normalize: Bool = false
    /// Normalise target in dBFS (default −1). Ignored unless `normalize` is true.
    var normalizeTargetDecibels: Float = -1

    /// Channel conversion mode.
    var channelMode: ChannelMode = .preserve

    /// Identity prep — the pure passthrough (no trim, no fade, no gain, no normalise,
    /// channels preserved). Applying it returns an equal buffer.
    static let identity = SamplePrep()

    // MARK: - Frame/channel projection (no buffer needed)

    /// Resolve the kept window `[start, end)` against a real frame count. `start` is
    /// clamped into `[0, n]`; `end` into `[start, n]`. A degenerate/empty selection
    /// yields `start == end`.
    func resolvedTrim(sourceFrameCount n: Int) -> (start: Int, end: Int) {
        let start = min(max(trimStartFrame, 0), max(0, n))
        let rawEnd = trimEndFrame ?? n
        let end = min(max(rawEnd, start), max(0, n))
        return (start, end)
    }

    /// Frames the prep will output for a given source length (trim only — rate change is
    /// a treatment concern). Used by `SampleMemoryEstimator` without decoding a buffer.
    func outputFrameCount(sourceFrameCount n: Int) -> Int {
        let (s, e) = resolvedTrim(sourceFrameCount: n)
        return e - s
    }

    /// Channels the prep will output for a given source channel count.
    func outputChannelCount(sourceChannelCount c: Int) -> Int {
        switch channelMode {
        case .preserve: return max(0, c)
        case .mono: return c > 0 ? 1 : 0
        case .stereo: return c > 0 ? 2 : 0
        }
    }

    // MARK: - Apply

    /// Produce a new, prepared `CanonicalAudioBuffer` from `source` without mutating it.
    /// Runs the full pipeline (trim → channels → gain → fades → normalise) in the float
    /// domain at the source rate. Deterministic; safe to call off the main actor.
    func apply(to source: CanonicalAudioBuffer) -> CanonicalAudioBuffer {
        let n = source.frameCount
        let (start, end) = resolvedTrim(sourceFrameCount: n)
        let outCount = end - start

        // Empty selection → honest zero-length buffer at the (converted) channel count.
        guard outCount > 0, !source.channels.isEmpty else {
            let ch = outputChannelCount(sourceChannelCount: source.channelCount)
            return CanonicalAudioBuffer(
                channels: Array(repeating: [Float](), count: ch),
                sampleRate: source.sampleRate)
        }

        // 1. Trim: copy the kept window per source channel.
        var trimmed: [[Float]] = source.channels.map { chan in
            Array(chan[min(start, chan.count)..<min(end, chan.count)])
        }

        // 2. Channel conversion.
        var channels = Self.convertChannels(trimmed, mode: channelMode)
        trimmed = []  // release

        // 3. Gain (linear). Skip the multiply when unity.
        if gainDecibels != 0 {
            var g = Self.decibelsToLinear(gainDecibels)
            for c in 0..<channels.count {
                vDSP_vsmul(channels[c], 1, &g, &channels[c], 1, vDSP_Length(channels[c].count))
            }
        }

        // 4. Fades (equal-power sine/cosine), applied per channel over the output window.
        Self.applyFades(&channels, fadeInFrames: fadeInFrames, fadeOutFrames: fadeOutFrames)

        // 5. Normalise (opt-in) — measure peak across all channels, scale to target.
        if normalize {
            Self.normalizePeak(&channels, targetDecibels: normalizeTargetDecibels)
        }

        return CanonicalAudioBuffer(channels: channels, sampleRate: source.sampleRate)
    }

    // MARK: - Building blocks (static, pure, unit-testable in isolation)

    static func decibelsToLinear(_ db: Float) -> Float { powf(10, db / 20) }

    /// Equal-power channel conversion. Documented in the `ChannelMode` cases.
    static func convertChannels(_ channels: [[Float]], mode: ChannelMode) -> [[Float]] {
        guard !channels.isEmpty else { return channels }
        switch mode {
        case .preserve:
            return channels
        case .mono:
            let n = channels[0].count
            let count = channels.count
            if count == 1 { return channels }
            var out = [Float](repeating: 0, count: n)
            // Equal-power sum: Σ ch / √count. vDSP accumulate then scale.
            for ch in channels {
                let m = min(n, ch.count)
                vDSP_vadd(out, 1, ch, 1, &out, 1, vDSP_Length(m))
            }
            var scale = 1 / sqrtf(Float(count))
            vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
            return [out]
        case .stereo:
            if channels.count >= 2 { return [channels[0], channels[1]] }
            // Mono → stereo: copy the single channel to both (documented, not attenuated).
            let mono = channels[0]
            return [mono, mono]
        }
    }

    /// Apply equal-power fade-in/out ramps in place, per channel. Fade lengths are clamped
    /// so overlapping in/out ramps never exceed the buffer.
    static func applyFades(_ channels: inout [[Float]], fadeInFrames: Int, fadeOutFrames: Int) {
        guard let n = channels.first?.count, n > 0 else { return }
        let fin = max(0, min(fadeInFrames, n))
        let fout = max(0, min(fadeOutFrames, n))
        guard fin > 0 || fout > 0 else { return }

        // Equal-power fade-in gain at index i over an F-frame ramp: sin(½π · i/(F−1)),
        // giving g[0]=0 … g[F−1]=1. F==1 → single unchanged sample (no click to shape).
        for c in 0..<channels.count {
            if fin > 1 {
                for i in 0..<fin {
                    let t = Float(i) / Float(fin - 1)
                    channels[c][i] *= sinf(0.5 * .pi * t)
                }
            }
            if fout > 1 {
                for j in 0..<fout {
                    // Position from the start of the fade-out window: g[0]=1 … g[F−1]=0.
                    let t = Float(j) / Float(fout - 1)
                    channels[c][n - fout + j] *= cosf(0.5 * .pi * t)
                }
            }
        }
    }

    /// Peak-normalise in place: scale every channel so the largest absolute sample lands
    /// on `targetDecibels` dBFS. A silent buffer (peak 0) is left untouched — no invented
    /// gain (Brief honesty).
    static func normalizePeak(_ channels: inout [[Float]], targetDecibels: Float) {
        var peak: Float = 0
        for ch in channels {
            guard !ch.isEmpty else { continue }
            var m: Float = 0
            vDSP_maxmgv(ch, 1, &m, vDSP_Length(ch.count))  // max magnitude
            if m > peak { peak = m }
        }
        guard peak > 0 else { return }
        let target = decibelsToLinear(targetDecibels)
        var scale = target / peak
        for c in 0..<channels.count {
            vDSP_vsmul(channels[c], 1, &scale, &channels[c], 1, vDSP_Length(channels[c].count))
        }
    }
}
