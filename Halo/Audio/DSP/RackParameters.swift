import Synchronization   // macOS 26 target — Atomic is available

/// The lock-free UI→render parameter bridge for the dub FX rack (Brief §5a). Created
/// ONCE in `HaloAppModel` and shared (unretained) with each monitor route's
/// `MonitorRenderContext.rack`, exactly like `CaptureTap` and `AudioLevelBridge`.
///
/// REAL-TIME SAFETY (Brief §8): the render callback performs a single `loadTargets()`
/// per block — a fixed set of relaxed atomic loads into a stack `RackTargets`, no
/// allocation/lock/log/retain. The UI (main actor) writes each control through a
/// plain atomic store. `DubRack` owns the smoothing so no zipper crosses the boundary.
///
/// HONESTY (Brief §1/§4): these are pure Mac-side DSP parameters — the rack lives on
/// the monitor path, NOT on the EP-40. Nothing here claims or reflects a hardware
/// state; when the route is idle nothing reads them and the chain is silent.
///
/// Floats cross as `UInt32` IEEE bit patterns (same trick as `MonitorGain`'s gain
/// seam); bools as `Atomic<Bool>`. `engaged` is the master bypass — when it is false
/// and the rack has settled, `DubRack` is bit-transparent (the NULL TEST, §5a exit).
final class RackParameters: @unchecked Sendable {

    // MARK: Master
    /// Master engage. false (default) = bypassed → bit-transparent once settled.
    let engaged = Atomic<Bool>(false)

    // MARK: TAPE ECHO
    let echoBypassed = Atomic<Bool>(false)            // module enabled by default (signature effect)
    private let echoTimeMs   = Atomic<UInt32>(Float(360).bitPattern)   // 40…1200 ms
    private let echoFeedback = Atomic<UInt32>(Float(0.45).bitPattern)  // 0…1 (→ soft self-osc)
    private let echoTone     = Atomic<UInt32>(Float(0.5).bitPattern)   // 0=dark …1=bright (loop LP)
    private let echoWow      = Atomic<UInt32>(Float(0.25).bitPattern)  // 0…1 wow/flutter depth
    private let echoMix      = Atomic<UInt32>(Float(0.35).bitPattern)  // 0…1 echo depth

    // MARK: SPRING
    let springBypassed = Atomic<Bool>(true)
    private let springMix   = Atomic<UInt32>(Float(0.30).bitPattern)   // 0…1 reverb amount
    private let springDecay = Atomic<UInt32>(Float(0.55).bitPattern)   // 0…1 tail length
    private let springTone  = Atomic<UInt32>(Float(0.5).bitPattern)    // 0=dark …1=bright

    // MARK: SWEEP
    let sweepBypassed = Atomic<Bool>(true)
    private let sweepMacro = Atomic<UInt32>(Float(0.5).bitPattern)     // 0=LP …0.5=BP …1=HP + sweep
    private let sweepReso  = Atomic<UInt32>(Float(0.3).bitPattern)     // 0…1 resonance

    // MARK: LOW END
    let lowBypassed = Atomic<Bool>(true)              // OFF by default (Brief §5a)
    private let lowAmount = Atomic<UInt32>(Float(0.4).bitPattern)      // 0…1 conservative shelf

    // MARK: - UI writers (main actor)

    func setEngaged(_ on: Bool) { engaged.store(on, ordering: .relaxed) }

    func setEchoBypassed(_ b: Bool)   { echoBypassed.store(b, ordering: .relaxed) }
    func setEchoTimeMs(_ v: Double)   { echoTimeMs.store(Float(v).bitPattern, ordering: .relaxed) }
    func setEchoFeedback(_ v: Double) { echoFeedback.store(Float(v).bitPattern, ordering: .relaxed) }
    func setEchoTone(_ v: Double)     { echoTone.store(Float(v).bitPattern, ordering: .relaxed) }
    func setEchoWow(_ v: Double)      { echoWow.store(Float(v).bitPattern, ordering: .relaxed) }
    func setEchoMix(_ v: Double)      { echoMix.store(Float(v).bitPattern, ordering: .relaxed) }

    func setSpringBypassed(_ b: Bool) { springBypassed.store(b, ordering: .relaxed) }
    func setSpringMix(_ v: Double)    { springMix.store(Float(v).bitPattern, ordering: .relaxed) }
    func setSpringDecay(_ v: Double)  { springDecay.store(Float(v).bitPattern, ordering: .relaxed) }
    func setSpringTone(_ v: Double)   { springTone.store(Float(v).bitPattern, ordering: .relaxed) }

    func setSweepBypassed(_ b: Bool)  { sweepBypassed.store(b, ordering: .relaxed) }
    func setSweepMacro(_ v: Double)   { sweepMacro.store(Float(v).bitPattern, ordering: .relaxed) }
    func setSweepReso(_ v: Double)    { sweepReso.store(Float(v).bitPattern, ordering: .relaxed) }

    func setLowBypassed(_ b: Bool)    { lowBypassed.store(b, ordering: .relaxed) }
    func setLowAmount(_ v: Double)    { lowAmount.store(Float(v).bitPattern, ordering: .relaxed) }

    // MARK: - Render reader (audio thread)

    /// Read every target into a stack struct in one shot. RT-safe: only relaxed
    /// atomic loads, no allocation. Called once per output block by `DubRack`.
    func loadTargets() -> RackTargets {
        RackTargets(
            engaged: engaged.load(ordering: .relaxed),
            echoEnabled: !echoBypassed.load(ordering: .relaxed),
            echoTimeMs: Float(bitPattern: echoTimeMs.load(ordering: .relaxed)),
            echoFeedback: Float(bitPattern: echoFeedback.load(ordering: .relaxed)),
            echoTone: Float(bitPattern: echoTone.load(ordering: .relaxed)),
            echoWow: Float(bitPattern: echoWow.load(ordering: .relaxed)),
            echoMix: Float(bitPattern: echoMix.load(ordering: .relaxed)),
            springEnabled: !springBypassed.load(ordering: .relaxed),
            springMix: Float(bitPattern: springMix.load(ordering: .relaxed)),
            springDecay: Float(bitPattern: springDecay.load(ordering: .relaxed)),
            springTone: Float(bitPattern: springTone.load(ordering: .relaxed)),
            sweepEnabled: !sweepBypassed.load(ordering: .relaxed),
            sweepMacro: Float(bitPattern: sweepMacro.load(ordering: .relaxed)),
            sweepReso: Float(bitPattern: sweepReso.load(ordering: .relaxed)),
            lowEnabled: !lowBypassed.load(ordering: .relaxed),
            lowAmount: Float(bitPattern: lowAmount.load(ordering: .relaxed)))
    }
}

/// One immutable snapshot of every rack target, read on the audio thread. A plain
/// value type living on the render stack — never heap-allocated in the callback.
struct RackTargets {
    var engaged: Bool

    var echoEnabled: Bool
    var echoTimeMs: Float
    var echoFeedback: Float
    var echoTone: Float
    var echoWow: Float
    var echoMix: Float

    var springEnabled: Bool
    var springMix: Float
    var springDecay: Float
    var springTone: Float

    var sweepEnabled: Bool
    var sweepMacro: Float
    var sweepReso: Float

    var lowEnabled: Bool
    var lowAmount: Float
}
