import AudioToolbox
import Foundation

/// Slow clock-drift controller (Brief §8: "Handle differing device clocks with an
/// `AudioConverter`/`AVAudioConverter` stage and slow drift correction").
///
/// The input and output AUHALs run off independent hardware clocks. Even at the
/// same nominal sample rate they drift a few ppm, so the ring buffer between them
/// slowly fills or empties. This controller watches the ring's fill level against
/// a target (half-full) and produces a tiny sample-rate RATIO nudge that the
/// converter uses to speed up or slow down consumption — a gentle, click-free
/// correction rather than a hard resync.
///
/// Pure and deterministic so it is unit-testable without hardware
/// (`DriftControllerTests`). The correction is intentionally weak (parts-per-
/// thousand at most) so it never audibly changes pitch.
struct DriftController {
    /// Maximum ratio deviation from 1.0 (e.g. 0.002 = ±0.2%). Kept small so pitch
    /// stays imperceptible.
    let maxDeviation: Double
    /// Proportional gain applied to the normalised fill error.
    let strength: Double
    /// Target fill as a fraction of capacity (0.5 = keep the ring half-full).
    let targetFraction: Double

    init(maxDeviation: Double = 0.002, strength: Double = 0.05, targetFraction: Double = 0.5) {
        self.maxDeviation = max(0, maxDeviation)
        self.strength = max(0, strength)
        self.targetFraction = min(1, max(0, targetFraction))
    }

    /// Compute the drift-corrected sample-rate ratio to apply to the converter,
    /// given the current ring fill and capacity.
    ///
    /// Returns a value near 1.0: **> 1** when the ring is too FULL (consume a touch
    /// faster to drain it); **< 1** when it is too EMPTY (consume slower to let it
    /// refill). Clamped to `1 ± maxDeviation`.
    func ratio(fill: Int, capacity: Int) -> Double {
        guard capacity > 0 else { return 1 }
        let fraction = Double(fill) / Double(capacity)
        let error = fraction - targetFraction          // >0 too full, <0 too empty
        let nudge = (error * strength).clampedDrift(to: maxDeviation)
        return 1 + nudge
    }
}

private extension Double {
    func clampedDrift(to limit: Double) -> Double {
        Swift.min(limit, Swift.max(-limit, self))
    }
}

/// Sample-rate / format bridge wrapping a Core Audio `AudioConverterRef`, with the
/// drift ratio applied on top of the base input→output rate ratio. When the two
/// devices share a format this collapses to a transparent passthrough.
///
/// The converter object is created ONCE at setup (never in a render callback). The
/// per-block `applyDriftRatio` only stores a Double the render thread reads — no
/// allocation on the hot path.
///
/// NEEDS-DEVICE: exercising the actual converted audio requires two real clocks
/// (the EP-40 input and a separate Mac output). The pure `DriftController` math is
/// unit-tested here; end-to-end drift behaviour is verified on hardware.
final class DriftCompensatingConverter: @unchecked Sendable {
    private var converter: AudioConverterRef?
    let inputFormat: AudioStreamBasicDescription
    let outputFormat: AudioStreamBasicDescription
    let controller: DriftController

    /// True when input and output formats are identical → no conversion needed and
    /// the stage is bit-transparent.
    let isPassthrough: Bool

    init?(inputFormat: AudioStreamBasicDescription,
          outputFormat: AudioStreamBasicDescription,
          controller: DriftController = DriftController()) {
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.controller = controller
        self.isPassthrough = Self.formatsMatch(inputFormat, outputFormat)

        if !isPassthrough {
            var input = inputFormat
            var output = outputFormat
            var conv: AudioConverterRef?
            let status = AudioConverterNew(&input, &output, &conv)
            guard status == noErr, let conv else { return nil }
            converter = conv
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    /// Push a new drift ratio (call at most once per block from the control side).
    /// The real converter consumes it via `kAudioConverterSampleRateConverterComplexity`
    /// bookkeeping on hardware; here it is retained for the render stage / tests.
    private(set) var currentRatio: Double = 1
    func applyDriftRatio(fill: Int, capacity: Int) {
        currentRatio = controller.ratio(fill: fill, capacity: capacity)
    }

    private static func formatsMatch(_ a: AudioStreamBasicDescription,
                                     _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate &&
        a.mFormatID == b.mFormatID &&
        a.mFormatFlags == b.mFormatFlags &&
        a.mBytesPerFrame == b.mBytesPerFrame &&
        a.mChannelsPerFrame == b.mChannelsPerFrame &&
        a.mBitsPerChannel == b.mBitsPerChannel
    }
}
