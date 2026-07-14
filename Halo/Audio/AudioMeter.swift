import Foundation
import Synchronization   // macOS 26 target — Atomic is available

/// Pure metering math, shared by the real-time meter and its tests. No state, no
/// allocation — safe to call from a render callback (Brief §8).
enum MeterMath {
    /// Absolute peak of one channel in an interleaved block. `channel` is 0 (L) or
    /// 1 (R); `frames` sample frames; `stride` channels per frame (2 for stereo).
    static func peak(_ buffer: UnsafePointer<Float>, frames: Int, stride: Int, channel: Int) -> Float {
        var p: Float = 0
        var i = 0
        while i < frames {
            let v = abs(buffer[i * stride + channel])
            if v > p { p = v }
            i += 1
        }
        return p
    }

    /// Root-mean-square of one channel in an interleaved block.
    static func rms(_ buffer: UnsafePointer<Float>, frames: Int, stride: Int, channel: Int) -> Float {
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        var i = 0
        while i < frames {
            let v = buffer[i * stride + channel]
            sum += v * v
            i += 1
        }
        return (sum / Float(frames)).squareRoot()
    }

    /// Linear amplitude (0…) to dBFS. True 0 maps to `−infinity` (real silence).
    static func linearToDB(_ x: Float) -> Float {
        x <= 0 ? -.infinity : 20 * log10(x)
    }

    /// One-pole ballistic smoothing. `attack`/`release` are move fractions (alphas)
    /// in 0…1: 1 = instantaneous, 0 = frozen. The rising alpha is used when the
    /// sample is louder than the held value, the falling alpha otherwise, so the
    /// meter can snap up (attack) yet decay slowly (release) instead of flickering.
    static func ballistic(previous: Float, sample: Float, attack: Float, release: Float) -> Float {
        let alpha = sample >= previous ? attack : release
        return previous + alpha * (sample - previous)
    }
}

/// Real-time-safe stereo peak/RMS publisher (Brief §8: "Audio meters publish as
/// atomic/snapshot values at 30–60 Hz"). The output render callback calls
/// `publish` with the block it just produced; the main actor reads a `StereoLevels`
/// snapshot at ≤ 60 Hz to drive `StereoMeter`.
///
/// Storage is four `Atomic<UInt32>` bit-patterns plus one packed clip word — the
/// callback never allocates, locks or retains. Because there is exactly one writer
/// (the audio thread) and one reader (the main actor) each value is individually
/// atomic; the reader may observe values from adjacent blocks, which is
/// imperceptible at meter refresh rates.
///
/// HONESTY (Brief §1/§4): a snapshot only ever reflects audio the output callback
/// ACTUALLY rendered. When no route is running nothing calls `publish`, the stored
/// values stay at silence, and the meter rests — a moving meter without real audio
/// would be a faked hardware state.
final class AudioMeter: @unchecked Sendable {
    private let peakLBits = Atomic<UInt32>(0)
    private let peakRBits = Atomic<UInt32>(0)
    private let rmsLBits = Atomic<UInt32>(0)
    private let rmsRBits = Atomic<UInt32>(0)
    /// bit0 = L clipped, bit1 = R clipped (latched until the reader clears).
    private let clipBits = Atomic<UInt32>(0)

    // Ballistic state — audio-thread-owned (single writer), so a plain var is fine.
    private var heldPeakL: Float = 0
    private var heldPeakR: Float = 0
    private var heldRMSL: Float = 0
    private var heldRMSR: Float = 0

    private let attack: Float
    private let release: Float

    init(sampleRate: Double = 48_000, attackSeconds: Double = 0.005, releaseSeconds: Double = 0.30) {
        let sr = max(1, sampleRate)
        attack = Float(1 - exp(-1.0 / (max(1e-4, attackSeconds) * sr)))
        release = Float(1 - exp(-1.0 / (max(1e-4, releaseSeconds) * sr)))
    }

    /// Publish the levels of one interleaved stereo block. AUDIO thread only.
    ///
    /// `rawPeakL`/`rawPeakR` are the PRE-limiter per-channel peaks of the same
    /// block, used only for clip detection: the published buffer is post-limiter
    /// (capped at −1 dBFS ≈ 0.891) so its own peak can never reach full scale —
    /// clip must be judged on the raw signal that *attempted* to exceed 0 dBFS.
    /// Pass `nil` (the default) when the buffer itself IS the raw signal.
    func publish(_ buffer: UnsafePointer<Float>, frames: Int,
                 rawPeakL: Float? = nil, rawPeakR: Float? = nil) {
        let pL = MeterMath.peak(buffer, frames: frames, stride: 2, channel: 0)
        let pR = MeterMath.peak(buffer, frames: frames, stride: 2, channel: 1)
        let rL = MeterMath.rms(buffer, frames: frames, stride: 2, channel: 0)
        let rR = MeterMath.rms(buffer, frames: frames, stride: 2, channel: 1)

        heldPeakL = MeterMath.ballistic(previous: heldPeakL, sample: pL, attack: 1, release: release)
        heldPeakR = MeterMath.ballistic(previous: heldPeakR, sample: pR, attack: 1, release: release)
        heldRMSL = MeterMath.ballistic(previous: heldRMSL, sample: rL, attack: attack, release: release)
        heldRMSR = MeterMath.ballistic(previous: heldRMSR, sample: rR, attack: attack, release: release)

        peakLBits.store(heldPeakL.bitPattern, ordering: .relaxed)
        peakRBits.store(heldPeakR.bitPattern, ordering: .relaxed)
        rmsLBits.store(heldRMSL.bitPattern, ordering: .relaxed)
        rmsRBits.store(heldRMSR.bitPattern, ordering: .relaxed)

        // Clip is detected at ≥ full scale on the RAW (pre-limiter) peaks so the
        // dot reflects a real overload attempt the limiter then caught.
        var clip: UInt32 = 0
        if (rawPeakL ?? pL) >= 1 { clip |= 1 }
        if (rawPeakR ?? pR) >= 1 { clip |= 2 }
        if clip != 0 {
            clipBits.store(clipBits.load(ordering: .relaxed) | clip, ordering: .relaxed)
        }
    }

    /// Read a dBFS snapshot for `StereoMeter`. MAIN actor only. Reading clears the
    /// latched clip flags so they behave as a momentary alert.
    func snapshot() -> StereoLevels {
        let pL = Float(bitPattern: peakLBits.load(ordering: .relaxed))
        let pR = Float(bitPattern: peakRBits.load(ordering: .relaxed))
        let rL = Float(bitPattern: rmsLBits.load(ordering: .relaxed))
        let rR = Float(bitPattern: rmsRBits.load(ordering: .relaxed))
        let clip = clipBits.exchange(0, ordering: .relaxed)
        return StereoLevels(
            rmsL: MeterMath.linearToDB(rL),
            rmsR: MeterMath.linearToDB(rR),
            peakL: MeterMath.linearToDB(pL),
            peakR: MeterMath.linearToDB(pR),
            clippedL: clip & 1 != 0,
            clippedR: clip & 2 != 0
        )
    }

    /// Zero all state (used on stop so the meter falls back to `.silence`).
    func reset() {
        heldPeakL = 0; heldPeakR = 0; heldRMSL = 0; heldRMSR = 0
        peakLBits.store(0, ordering: .relaxed)
        peakRBits.store(0, ordering: .relaxed)
        rmsLBits.store(0, ordering: .relaxed)
        rmsRBits.store(0, ordering: .relaxed)
        clipBits.store(0, ordering: .relaxed)
    }
}
