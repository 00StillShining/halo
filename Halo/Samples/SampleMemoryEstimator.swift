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
}
