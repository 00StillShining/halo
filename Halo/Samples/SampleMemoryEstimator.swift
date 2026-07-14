import Foundation

/// Estimates the on-device byte footprint of a sample (Brief §8 "Show exact
/// estimated bytes: frames × channels × 2 plus measured container overhead").
///
/// The EP-40 stores 16-bit LinearPCM, hence 2 bytes per sample. The audio payload
/// is therefore exactly `frames × channels × 2`; the only unknown is the container
/// header/metadata overhead, which is a MEASURED value, never a guessed constant.
/// Until Phase 0B establishes the device's real container overhead, the honest
/// default is 0 with the payload shown as a lower bound (DEVICE-GATED — see
/// `needsDevice`). Callers that have measured a real header pass it in.
///
/// LOCAL and honest: this computes arithmetic on measured frame/channel counts. It
/// makes no claim about free space or acceptance on a real EP-40.
enum SampleMemoryEstimator {

    /// Bytes per sample of the device's 16-bit LinearPCM storage.
    static let bytesPerSample = 2

    /// Payload bytes only: `frames × channels × 2`. Exact for the audio data; the
    /// true file adds container overhead (see `estimatedBytes`).
    static func payloadBytes(frames: Int, channels: Int) -> Int {
        max(0, frames) * max(0, channels) * bytesPerSample
    }

    /// Full estimate: payload + a MEASURED container overhead. `containerOverhead`
    /// defaults to 0 because the EP-40's real header size is device-gated and must
    /// not be invented; pass the measured value once known.
    static func estimatedBytes(frames: Int, channels: Int, containerOverhead: Int = 0) -> Int {
        payloadBytes(frames: frames, channels: channels) + max(0, containerOverhead)
    }

    /// Convenience over a decoded asset at its own frame/channel count.
    static func estimatedBytes(for asset: SampleAsset, containerOverhead: Int = 0) -> Int {
        estimatedBytes(frames: asset.frameCount, channels: asset.channelCount,
                       containerOverhead: containerOverhead)
    }

    // MARK: - Prep + treatment aware estimate

    /// The predicted on-device footprint of a source once a `SamplePrep` and a
    /// `SampleTreatment` are applied (Brief §8 exit criterion: "The same source prepared
    /// with different treatments reports predictable sizes"). Pure arithmetic on measured
    /// counts — it decodes nothing and invents nothing:
    ///   • trim → `prep.outputFrameCount`
    ///   • channels → `prep.outputChannelCount`
    ///   • rate → `treatment.outputFrameCount` (round-to-nearest resample)
    ///   • bytes → `frames × channels × 2 + measured overhead`
    static func estimate(sourceFrameCount: Int,
                         sourceChannelCount: Int,
                         sourceSampleRate: Double,
                         prep: SamplePrep,
                         treatment: SampleTreatment,
                         containerOverhead: Int = 0) -> SampleSizeEstimate {
        let preppedFrames = prep.outputFrameCount(sourceFrameCount: sourceFrameCount)
        let channels = prep.outputChannelCount(sourceChannelCount: sourceChannelCount)
        let rate = treatment.resolvedSampleRate(sourceSampleRate: sourceSampleRate)
        let frames = treatment.outputFrameCount(sourceFrameCount: preppedFrames,
                                                sourceSampleRate: sourceSampleRate)
        let payload = payloadBytes(frames: frames, channels: channels)
        return SampleSizeEstimate(frames: frames, channels: channels, sampleRate: rate,
                                  payloadBytes: payload, containerOverhead: max(0, containerOverhead))
    }

    /// Convenience over a decoded `SampleAsset`.
    static func estimate(for asset: SampleAsset,
                         prep: SamplePrep,
                         treatment: SampleTreatment,
                         containerOverhead: Int = 0) -> SampleSizeEstimate {
        estimate(sourceFrameCount: asset.frameCount,
                 sourceChannelCount: asset.channelCount,
                 sourceSampleRate: asset.sampleRate,
                 prep: prep, treatment: treatment, containerOverhead: containerOverhead)
    }
}

/// A resolved size estimate for one prep+treatment combination. Value type for the right
/// rail's "memory impact" readout (Brief §7); all fields are derived arithmetically from
/// measured source counts.
struct SampleSizeEstimate: Sendable, Equatable {
    let frames: Int
    let channels: Int
    let sampleRate: Double
    let payloadBytes: Int
    let containerOverhead: Int

    /// Total on-device bytes = audio payload + measured container overhead.
    var totalBytes: Int { payloadBytes + containerOverhead }

    var durationSeconds: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
}
