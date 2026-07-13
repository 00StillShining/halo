import Synchronization   // macOS 26 target — Atomic is available

/// Single-writer/single-reader Float handoff. The (future) audio render callback
/// stores a peak here — no locks, no allocation, no Swift object retain (Brief §8).
/// The ring tick reads it on the main actor at ≤ 60 Hz. Audio data NEVER goes
/// straight into RealityKit; it always passes through this bridge and then the
/// main-actor `HaloRingRig.tick`.
///
/// No producer exists today (there is no audio engine yet), so `read()` returns
/// 0 and the `.monitoring` state is unreachable — that is correct, not a gap.
final class AudioLevelBridge: Sendable {
    private let bits = Atomic<UInt32>(0)

    /// Called from the audio render callback (single writer). Lock-free.
    func publish(peak: Float) { bits.store(peak.bitPattern, ordering: .relaxed) }

    /// Called from the main-actor ring tick (single reader). Clamped to 0…1.
    func read() -> Float { max(0, min(1, Float(bitPattern: bits.load(ordering: .relaxed)))) }
}
