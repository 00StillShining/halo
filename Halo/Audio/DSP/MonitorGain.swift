import Foundation

/// Smoothed monitor gain stage — the FIRST link of the playback chain
/// (Brief §8: "monitor gain → (FX rack) → limiter"). Defaults to the −12 dB safe
/// monitoring level (Brief §7 workflow: "start at a safe −12 dB monitor gain").
///
/// The target is set in dBFS from the UI; the applied linear gain ramps toward it
/// per sample so a fader move never zippers. Pure value processor over
/// caller-owned interleaved stereo memory — real-time-safe (no allocation/locks/
/// logging). Pinned by `MonitorGainTests`.
struct MonitorGain {
    /// dB below which the gain is treated as hard silence (−∞ handling).
    static let silenceFloorDB: Double = -60

    /// Default safe monitor level.
    static let defaultDB: Double = -12

    private(set) var currentLinear: Float
    private var targetLinear: Float
    private let smoothingCoef: Float

    /// - Parameters:
    ///   - db: initial (and target) level in dBFS.
    ///   - sampleRate: for the smoothing time constant.
    ///   - smoothingSeconds: ramp time constant for target changes (≈ 20 ms).
    init(db: Double = MonitorGain.defaultDB, sampleRate: Double = 48_000, smoothingSeconds: Double = 0.02) {
        let lin = Self.linear(fromDB: db)
        currentLinear = lin
        targetLinear = lin
        let sr = max(1, sampleRate)
        let tau = max(1e-4, smoothingSeconds)
        smoothingCoef = Float(exp(-1.0 / (tau * sr)))
    }

    /// Convert a dBFS level to a linear amplitude, flooring to true 0 at/below the
    /// silence floor so the fader bottom is real silence, not −60 dB of hiss.
    static func linear(fromDB db: Double) -> Float {
        if db <= silenceFloorDB { return 0 }
        return Float(pow(10, db / 20))
    }

    /// Retarget the gain (called from the UI thread; the render thread only reads
    /// `targetLinear` via the atomic seam in the render context, never this type
    /// directly). Value-type, so callers hold their own copy.
    mutating func setTargetDB(_ db: Double) {
        targetLinear = Self.linear(fromDB: db)
    }

    /// Set the linear target directly (used by the render context, which owns the
    /// atomic bridge from the UI).
    mutating func setTargetLinear(_ lin: Float) {
        targetLinear = max(0, lin)
    }

    /// Apply the smoothed gain to an interleaved stereo block in place.
    mutating func processStereo(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var g = currentLinear
        let target = targetLinear
        let coef = smoothingCoef
        var i = 0
        while i < frames {
            g = target + (g - target) * coef
            buffer[2 * i] *= g
            buffer[2 * i + 1] *= g
            i += 1
        }
        // Snap to target once within epsilon so it settles exactly (transparent at
        // unity, true silence at the floor).
        currentLinear = abs(g - target) < 1e-6 ? target : g
    }
}
