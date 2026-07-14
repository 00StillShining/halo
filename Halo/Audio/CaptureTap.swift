import Synchronization   // macOS 26 target — Atomic is available

/// Raw pre-monitor input tap (Brief §7: "Default recording point is the raw EP-40
/// input before halo monitor gain/limiter/FX"). Created ONCE per app and shared
/// between the render context (PRODUCER = the input AUHAL callback) and the
/// `SessionRecorder`'s drain thread (CONSUMER). The raw stream only exists while
/// the monitor route's input AUHAL is running, so recording is gated on an active
/// monitor route (DD-018) — this taps that existing route rather than opening a
/// second, competing input unit.
///
/// REAL-TIME SAFETY (Brief §8): the input callback only does a single relaxed
/// atomic load of `armed`, and — when armed — a preallocated `ring.write` plus a
/// `meter.publish`. No allocation, lock, log, or Swift-object retain on the audio
/// thread. Everything here is allocated once, in `init`.
///
/// HONESTY (Brief §1/§4): the tap NEVER fabricates samples. When the route is not
/// running nothing calls the producer, the ring stays empty, and the raw meter
/// rests at silence. A silent-but-live instrument yields an honestly-silent take;
/// an absent route yields no take at all (RECORD is refused with a real reason).
final class CaptureTap: @unchecked Sendable {
    /// SPSC bridge: input callback (producer) → drain thread (consumer). This is a
    /// SEPARATE ring from `MonitorRenderContext.ringBuffer` (which is strictly the
    /// input→output monitor bridge). Adding a second reader to that ring would
    /// break its single-consumer contract, so the tap owns its own.
    let ring: AudioRingBuffer

    /// RAW (pre-gain, pre-limiter) peaks for the Capture readout — published from
    /// the input side, so the meter reflects the actual instrument signal being
    /// recorded, not the monitored/limited output.
    let meter: AudioMeter

    /// Main actor writes (arm/disarm around a take); the input callback reads it
    /// (relaxed) once per block. When false the tap costs a single atomic load.
    let armed = Atomic<Bool>(false)

    /// Total STEREO FRAMES committed to the writer (drain thread writes; the main
    /// actor may poll it as an alternative elapsed source).
    let framesWritten = Atomic<Int>(0)

    init() {
        // ~4 s of interleaved stereo headroom @ 48k: the drain thread outruns the
        // producer, so this is slack against a scheduling hiccup, never steady fill.
        ring = AudioRingBuffer(minimumCapacity: 48_000 * 2 * 4)
        meter = AudioMeter(sampleRate: 48_000)
    }

    /// Discard anything buffered before arming so a take never begins with stale
    /// pre-roll samples. Consumer-side; called on the main actor at arm time before
    /// the drain thread starts, so there is no concurrent reader.
    func drain() { ring.drain() }
}
