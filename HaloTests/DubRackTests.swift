import XCTest
@testable import Halo

/// Pins the Phase 5a dub-rack exit criteria (Brief §5a):
///   1. bypass is bit-transparent (NULL TEST),
///   2. no clicks on engage / bypass / parameter sweeps,
///   3. echo self-oscillation stays finite and under the −1 dBFS safety limiter,
///   4. per-module bypass is transparent,
/// plus the parameter-bridge round-trip. Pure DSP — no hardware (device-gated live
/// audio is excluded).
final class DubRackTests: XCTestCase {

    private let sr = 48_000.0
    private let block = 512

    /// Run one interleaved-stereo block in place through the rack.
    private func process(_ rack: DubRack, _ buf: inout [Float], params: RackParameters) {
        let frames = buf.count / 2
        buf.withUnsafeMutableBufferPointer { rack.process($0.baseAddress!, frames: frames, params: params) }
    }

    /// Deterministic pseudo-random interleaved stereo block in [-0.5, 0.5].
    private func noiseBlock(seed: UInt64) -> [Float] {
        var state = seed &+ 0x9E3779B97F4A7C15
        var out = [Float](repeating: 0, count: block * 2)
        for i in out.indices {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            let u = Float(state &* 0x2545F4914F6CDD1D >> 40) / Float(1 << 24)
            out[i] = u - 0.5
        }
        return out
    }

    // MARK: 1 · NULL TEST — disengaged bypass is bit-transparent

    func testBypassIsBitTransparent() {
        let rack = DubRack(sampleRate: sr, maxFrames: block)
        let params = RackParameters()        // engaged defaults to false
        for seed in 0..<40 {
            var buf = noiseBlock(seed: UInt64(seed))
            let original = buf
            process(rack, &buf, params: params)
            XCTAssertEqual(buf, original, "disengaged rack must be bit-for-bit transparent")
        }
    }

    /// After ENGAGING then DISENGAGING and letting the fade settle, the rack must
    /// return to exact bit-transparency (not a permanently altered near-copy).
    func testReturnsToBitTransparentAfterDisengage() {
        let rack = DubRack(sampleRate: sr, maxFrames: block)
        let params = RackParameters()
        params.setEngaged(true)
        for seed in 0..<40 { var b = noiseBlock(seed: UInt64(seed)); process(rack, &b, params: params) }
        params.setEngaged(false)
        // Let the ~20 ms master fade settle (well under 40 blocks @ 512/48k ≈ 0.42 s).
        for seed in 100..<140 { var b = noiseBlock(seed: UInt64(seed)); process(rack, &b, params: params) }
        // Now every further block must be exactly transparent again.
        for seed in 200..<240 {
            var buf = noiseBlock(seed: UInt64(seed))
            let original = buf
            process(rack, &buf, params: params)
            XCTAssertEqual(buf, original, "rack must be bit-transparent again once disengaged and settled")
        }
    }

    // MARK: 2 · No clicks on engage / param sweep

    func testNoClickOnEngageAndSweep() {
        let rack = DubRack(sampleRate: sr, maxFrames: block)
        let params = RackParameters()
        params.setEchoBypassed(false)
        params.setEchoFeedback(0.6)
        params.setEchoMix(0.5)

        var last: Float = 0
        var maxDelta: Float = 0
        var everNonFinite = false

        // 60 blocks of a steady 300 Hz sine; engage at block 10, then sweep the
        // sweep-filter macro and echo feedback continuously.
        var phase: Float = 0
        let inc = 2 * Float.pi * 300 / Float(sr)
        for blk in 0..<60 {
            if blk == 10 { params.setEngaged(true) }
            if blk == 25 { params.setSweepBypassed(false) }
            // Continuous parameter motion (worst case for zipper).
            params.setSweepMacro(Double((sinf(Float(blk) * 0.3) + 1) / 2))
            params.setEchoFeedback(Double(0.3 + 0.4 * Float(blk) / 60))

            var buf = [Float](repeating: 0, count: block * 2)
            for f in 0..<block {
                let s = sinf(phase) * 0.3
                phase += inc; if phase > 2 * .pi { phase -= 2 * .pi }
                buf[2 * f] = s; buf[2 * f + 1] = s
            }
            process(rack, &buf, params: params)
            for v in buf {
                if !v.isFinite { everNonFinite = true }
                maxDelta = max(maxDelta, abs(v - last))
                last = v
            }
        }
        XCTAssertFalse(everNonFinite, "no NaN/Inf across engage + sweep")
        // The dry sine's own per-sample delta is ~0.012; a click would be a step of
        // order the amplitude (0.3). A smooth fade keeps deltas small.
        XCTAssertLessThan(maxDelta, 0.08, "engage/sweep must not produce a click (sample step)")
    }

    // MARK: 3 · Echo self-oscillation stays finite and under the limiter

    func testEchoSelfOscillationStaysUnderLimiter() {
        let rack = DubRack(sampleRate: sr, maxFrames: block)
        var limiter = SafetyLimiter(sampleRate: sr)
        let params = RackParameters()
        params.setEngaged(true)
        params.setEchoBypassed(false)
        params.setEchoFeedback(1.0)     // top of the knob → self-oscillation
        params.setEchoMix(1.0)
        params.setEchoTimeMs(120)
        params.setEchoTone(1.0)

        var preLimiterMax: Float = 0
        var postLimiterMax: Float = 0
        var everNonFinite = false

        let blocks = Int(sr * 6 / Double(block))   // ~6 s of sustained feedback
        for blk in 0..<blocks {
            var buf = [Float](repeating: 0, count: block * 2)
            if blk == 0 { buf[0] = 1; buf[1] = 1 }   // a single impulse to excite the loop
            process(rack, &buf, params: params)
            for v in buf { if !v.isFinite { everNonFinite = true }; preLimiterMax = max(preLimiterMax, abs(v)) }
            buf.withUnsafeMutableBufferPointer { limiter.processStereo($0.baseAddress!, frames: block) }
            for v in buf { postLimiterMax = max(postLimiterMax, abs(v)) }
        }
        XCTAssertFalse(everNonFinite, "self-oscillation must never diverge to NaN/Inf")
        XCTAssertLessThan(preLimiterMax, 4.0, "soft ceiling keeps the loop bounded well before the limiter")
        XCTAssertLessThanOrEqual(postLimiterMax, SafetyLimiter.ceiling + 1e-6,
                                 "the −1 dBFS limiter always catches self-oscillation")
    }

    // MARK: 4 · Per-module bypass is transparent

    func testEngagedWithAllModulesBypassedIsTransparent() {
        let rack = DubRack(sampleRate: sr, maxFrames: block)
        let params = RackParameters()
        params.setEngaged(true)
        params.setEchoBypassed(true)     // default echo is ON — turn it off
        params.setSpringBypassed(true)
        params.setSweepBypassed(true)
        params.setLowBypassed(true)
        // Let the module-enable fades settle to exactly zero.
        for seed in 0..<40 { var b = noiseBlock(seed: UInt64(seed)); process(rack, &b, params: params) }
        for seed in 100..<130 {
            var buf = noiseBlock(seed: UInt64(seed))
            let original = buf
            process(rack, &buf, params: params)
            XCTAssertEqual(buf, original,
                           "engaged rack with every module bypassed passes the signal untouched")
        }
    }

    // MARK: 5 · Parameter bridge round-trips

    func testParameterBridgeRoundTrip() {
        let p = RackParameters()
        p.setEngaged(true)
        p.setEchoBypassed(true)
        p.setEchoTimeMs(640)
        p.setEchoFeedback(0.8)
        p.setSpringBypassed(false)
        p.setSweepMacro(0.25)
        p.setLowAmount(0.9)
        let t = p.loadTargets()
        XCTAssertTrue(t.engaged)
        XCTAssertFalse(t.echoEnabled)           // bypassed → not enabled
        XCTAssertEqual(t.echoTimeMs, 640, accuracy: 1e-3)
        XCTAssertEqual(t.echoFeedback, 0.8, accuracy: 1e-6)
        XCTAssertTrue(t.springEnabled)
        XCTAssertEqual(t.sweepMacro, 0.25, accuracy: 1e-6)
        XCTAssertEqual(t.lowAmount, 0.9, accuracy: 1e-6)
    }
}

/// Pins the RACK UI model's tempo-sync + tap-tempo math (Brief §5a) — pure, no audio.
final class RackModelTests: XCTestCase {

    @MainActor
    func testEchoSyncDerivesDelayFromTempo() {
        let model = RackModel()
        model.updateClockBPM(120)          // quarter = 500 ms
        model.echoSync = true
        model.echoDivision = .eighth
        XCTAssertEqual(model.effectiveEchoMs, 250, accuracy: 0.5)
        model.echoDivision = .dottedEighth
        XCTAssertEqual(model.effectiveEchoMs, 375, accuracy: 0.5)
        model.echoDivision = .quarter
        XCTAssertEqual(model.effectiveEchoMs, 500, accuracy: 0.5)
        model.echoDivision = .triplet
        XCTAssertEqual(model.effectiveEchoMs, 500.0 / 3, accuracy: 0.5)
    }

    @MainActor
    func testFreeTimeUsedWithoutSync() {
        let model = RackModel()
        model.echoSync = false
        model.echoFreeMs = 800
        XCTAssertEqual(model.effectiveEchoMs, 800, accuracy: 0.5)
        // Even synced, with no tempo source it falls back to the free time (never invents one).
        model.echoSync = true
        XCTAssertNil(model.tempoBPM)
        XCTAssertEqual(model.effectiveEchoMs, 800, accuracy: 0.5)
        XCTAssertEqual(model.tempoSource, .none)
    }

    @MainActor
    func testTapTempoEstimatesBPM() {
        let model = RackModel()
        // Four taps 0.5 s apart → 120 BPM.
        var t = 10.0
        for _ in 0..<4 { model.tapTempo(now: t); t += 0.5 }
        XCTAssertEqual(model.tapBPM ?? 0, 120, accuracy: 1)
        XCTAssertEqual(model.tempoSource, .tap)
        // A live clock overrides tap tempo.
        model.updateClockBPM(90)
        XCTAssertEqual(model.tempoBPM, 90)
        XCTAssertEqual(model.tempoSource, .clock)
    }

    @MainActor
    func testEngageWritesBridge() {
        let params = RackParameters()
        let model = RackModel(parameters: params)
        XCTAssertFalse(params.loadTargets().engaged)
        model.engaged = true
        XCTAssertTrue(params.loadTargets().engaged)
    }
}
