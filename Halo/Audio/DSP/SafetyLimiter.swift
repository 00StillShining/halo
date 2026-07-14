import Foundation

/// Transparent stereo-linked brick-wall safety limiter with a fixed −1 dBFS
/// ceiling (Brief §8: "transparent −1 dBFS safety limiter"; §11 rack exit
/// criterion: "echo self-oscillation stays under the safety limiter").
///
/// This is the LAST stage of the monitor chain. It exists to make runaway gain
/// physically impossible at the output, not to colour the sound. Two guarantees,
/// both pinned by `SafetyLimiterTests`:
///
/// 1. **No overshoot** — for every processed sample, `|out| ≤ ceiling`. Gain
///    reduction is applied instantaneously (zero-lookahead) when a peak would
///    exceed the ceiling, then released slowly toward unity.
/// 2. **Bit-transparent below the ceiling** — while the stereo peak stays at or
///    under the ceiling the gain sits at exactly 1.0, so `out == in` bit-for-bit.
///    Nothing is touched until the signal actually threatens to clip.
///
/// Real-time-safe: a plain value processor over caller-owned interleaved memory —
/// no allocation, locks, logging or object traffic (Brief §8). Stereo channels
/// share one gain envelope so the image is never pulled off-centre by limiting.
struct SafetyLimiter {
    /// −1 dBFS as a linear amplitude (≈ 0.891251).
    static let ceiling: Float = 0.8912509381337456   // pow(10, -1/20)

    /// Current smoothing gain, 0…1. Public-readable for tests/telemetry.
    private(set) var gain: Float = 1

    /// Per-sample release coefficient toward unity. Derived from a release time so
    /// recovery is smooth (no pumping) yet audibly transparent. Default ≈ 100 ms at
    /// 48 kHz.
    private let releaseCoef: Float

    /// - Parameters:
    ///   - sampleRate: output sample rate in Hz (for the release time constant).
    ///   - releaseSeconds: time constant for recovering toward unity gain.
    init(sampleRate: Double = 48_000, releaseSeconds: Double = 0.10) {
        let sr = max(1, sampleRate)
        let tau = max(1e-4, releaseSeconds)
        releaseCoef = Float(exp(-1.0 / (tau * sr)))
    }

    /// Process one interleaved stereo block in place. `frames` is the number of
    /// sample frames; the pointer holds `frames * 2` floats (L,R,L,R,…).
    /// CONSUMER/output thread only.
    mutating func processStereo(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        let ceiling = Self.ceiling
        var g = gain
        var i = 0
        while i < frames {
            let l = buffer[2 * i]
            let r = buffer[2 * i + 1]
            let peak = max(abs(l), abs(r))

            // Required gain to keep this sample's peak at/under the ceiling.
            let required = peak > ceiling ? ceiling / peak : 1

            if required < g {
                // Attack is instantaneous → guarantees no overshoot on this sample.
                g = required
            } else {
                // Release slowly back toward unity.
                g += (1 - g) * (1 - releaseCoef)
                if g > 1 { g = 1 }
                // Guard: even while releasing, never let this sample exceed the
                // ceiling (a fast-rising peak could otherwise slip through).
                if peak * g > ceiling { g = required }
            }

            buffer[2 * i] = l * g
            buffer[2 * i + 1] = r * g
            i += 1
        }
        gain = g
    }

    /// Reset to unity (used on (re)start so a prior reduction doesn't leak across
    /// a stop/start). Not real-time-called.
    mutating func reset() { gain = 1 }
}
