import Foundation

/// One-pole attack/release envelope: fast rise (50 ms), slow fall (350 ms).
/// Used to smooth the audio-responsive `.monitoring` luminance so the ring
/// reacts quickly to transients but never flickers. Pure and unit-testable;
/// no UI or RealityKit dependency.
struct RingLuminanceSmoother: Equatable {
    private(set) var value: Float = 0

    /// Advance one step toward `target`. `dt` is seconds since the last step;
    /// non-positive `dt` is safe (no movement). Never overshoots the target.
    mutating func step(target: Float, dt: Float,
                       attack: Float = 0.050, release: Float = 0.350) -> Float {
        let tau = target > value ? attack : release
        value += (target - value) * (1 - exp(-max(dt, 0) / tau))
        return value
    }

    /// Reset to zero on state exit so a later monitor engage starts from dark.
    mutating func reset() { value = 0 }
}
