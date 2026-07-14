import Foundation

/// The performable dub FX rack (Brief §5a) — custom DSP inserted at the bypassable
/// point of the P2 monitor route, **post-gain / pre-limiter**. Modules run in the
/// fixed chain order TAPE ECHO → SPRING → SWEEP → LOW END.
///
/// REAL-TIME (Brief §8): every buffer here is preallocated in `init` (never in a
/// callback). `process` does no allocation, lock, log or Swift-object retain — it is
/// a plain value processor over the caller's interleaved stereo memory, the same
/// contract as `MonitorGain` / `SafetyLimiter`. Parameters cross the audio boundary
/// through `RackParameters` (atomics) and are smoothed here per block/per sample, so
/// no control move zippers.
///
/// BIT-TRANSPARENT BYPASS (Brief §5a NULL TEST): while the master is disengaged and
/// the crossfade has settled to zero, `process` returns immediately and leaves the
/// buffer untouched — `out == in`, bit for bit. Engage/bypass and every parameter
/// sweep are click-free (equal-power-free linear dry/wet ramp + continuous module
/// state). Echo self-oscillation is bounded by a soft (tanh) ceiling in the feedback
/// loop so it can never run away past the −1 dBFS safety limiter that follows.
///
/// SPRING choice: a 4-line feedback-delay network (FDN) with a Hadamard mixing
/// matrix and per-line damping, tuned short for a spring "boing/drip" character
/// (the brief's documented default; a convolution IR remains the fallback option).
final class DubRack: @unchecked Sendable {
    private let sampleRate: Float
    private let maxFrames: Int

    private let echo: TapeEcho
    private let spring: SpringReverb
    private let sweep: SweepFilter
    private let lowEnd: LowEnd

    /// Preallocated wet-path scratch (interleaved stereo), sized to the largest block.
    private let wet: UnsafeMutablePointer<Float>

    /// Master dry/wet crossfade, 0 = bypassed (bit-transparent) … 1 = fully inserted.
    private var masterMix: Float = 0
    private let masterCoef: Float   // per-sample smoothing toward the engage target

    init(sampleRate: Double, maxFrames: Int) {
        let sr = Float(max(1, sampleRate))
        self.sampleRate = sr
        self.maxFrames = max(1, maxFrames)
        echo = TapeEcho(sampleRate: sr)
        spring = SpringReverb(sampleRate: sr)
        sweep = SweepFilter(sampleRate: sr)
        lowEnd = LowEnd(sampleRate: sr)
        wet = UnsafeMutablePointer<Float>.allocate(capacity: self.maxFrames * 2)
        wet.initialize(repeating: 0, count: self.maxFrames * 2)
        // ~20 ms master engage fade — click-free without smearing the gesture.
        masterCoef = expf(-1.0 / (0.020 * sr))
    }

    deinit {
        wet.deinitialize(count: maxFrames * 2)
        wet.deallocate()
    }

    /// Process one interleaved stereo block in place. AUDIO/output thread only.
    /// `params` is the shared atomic bridge; targets are loaded once here.
    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int, params: RackParameters) {
        let t = params.loadTargets()
        let masterTarget: Float = t.engaged ? 1 : 0

        // NULL TEST: disengaged and the crossfade has fully settled → leave the
        // buffer exactly as it arrived. This is the bit-transparent bypass.
        if masterTarget == 0 && masterMix == 0 { return }

        let n = min(frames, maxFrames)
        let count = n * 2

        // Dry → wet scratch, then run the chain on the wet copy.
        wet.update(from: buffer, count: count)
        echo.process(wet, frames: n, t: t)
        spring.process(wet, frames: n, t: t)
        sweep.process(wet, frames: n, t: t)
        lowEnd.process(wet, frames: n, t: t)

        // Master dry/wet crossfade (per frame; L/R share the coefficient so the
        // image never pulls). At m == 0 this is `dry + 0`, i.e. exactly dry.
        var m = masterMix
        let coef = masterCoef
        var i = 0
        while i < n {
            m = masterTarget + (m - masterTarget) * coef
            let l = buffer[2 * i]
            let r = buffer[2 * i + 1]
            buffer[2 * i]     = l + (wet[2 * i]     - l) * m
            buffer[2 * i + 1] = r + (wet[2 * i + 1] - r) * m
            i += 1
        }
        masterMix = abs(m - masterTarget) < 1e-5 ? masterTarget : m

        // Just settled into bypass → clear module tails so the next engage starts
        // from silence (no stale burst). Once per toggle, not per block.
        if masterMix == 0 {
            echo.reset(); spring.reset(); sweep.reset(); lowEnd.reset()
        }
    }

    /// Full reset on (re)start so a prior tail never leaks across a stop/start.
    func reset() {
        masterMix = 0
        echo.reset(); spring.reset(); sweep.reset(); lowEnd.reset()
    }
}

// MARK: - Shared helpers

@inline(__always) private func onePoleCoef(seconds: Float, sampleRate: Float) -> Float {
    expf(-1.0 / (max(1e-4, seconds) * sampleRate))
}

/// One-pole smoothing step toward `target`.
@inline(__always) private func smooth(_ current: Float, _ target: Float, _ coef: Float) -> Float {
    target + (current - target) * coef
}

/// Bounded soft saturation for feedback loops — keeps self-oscillation finite and
/// well under the −1 dBFS limiter (a `tanh` soft ceiling, Brief §5a).
@inline(__always) private func softClip(_ x: Float) -> Float { tanhf(x) }

// MARK: - TAPE ECHO

/// Feedback delay with tempo-independent time (40–1200 ms, set by the UI/tempo
/// layer), low-pass damping in the loop, subtle wow/flutter modulation, and a soft
/// self-oscillation ceiling. The signature dub effect — the feedback knob is meant
/// to be ridden into self-oscillation without ever blowing up.
private final class TapeEcho {
    private let sr: Float
    private let size: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private var writeIdx = 0

    // Loop damping (one-pole LP) state.
    private var dampL: Float = 0
    private var dampR: Float = 0

    // Wow/flutter LFO.
    private var wowPhase: Float = 0
    private var flutPhase: Float = 0
    private let wowInc: Float
    private let flutInc: Float
    private let maxModSamples: Float

    // Smoothed controls.
    private var enable: Float = 0
    private var timeSamples: Float
    private var feedback: Float = 0
    private var tone: Float = 0.5
    private var wow: Float = 0
    private var mix: Float = 0

    private let ctrlCoef: Float   // fast controls (~15 ms)
    private let timeCoef: Float   // delay-time glide (~80 ms — tape-like pitch slew)

    init(sampleRate: Float) {
        sr = sampleRate
        // Room for 1200 ms + modulation headroom.
        maxModSamples = 0.004 * sr                          // ±4 ms wow/flutter
        size = Int(1.2 * sr + maxModSamples) + 4
        bufL = .allocate(capacity: size); bufL.initialize(repeating: 0, count: size)
        bufR = .allocate(capacity: size); bufR.initialize(repeating: 0, count: size)
        timeSamples = 0.360 * sr
        wowInc = 2 * .pi * 0.7 / sr                         // ~0.7 Hz wow
        flutInc = 2 * .pi * 6.3 / sr                        // ~6.3 Hz flutter
        ctrlCoef = onePoleCoef(seconds: 0.015, sampleRate: sr)
        timeCoef = onePoleCoef(seconds: 0.080, sampleRate: sr)
    }

    deinit {
        bufL.deinitialize(count: size); bufL.deallocate()
        bufR.deinitialize(count: size); bufR.deallocate()
    }

    func reset() {
        bufL.update(repeating: 0, count: size)
        bufR.update(repeating: 0, count: size)
        writeIdx = 0; dampL = 0; dampR = 0; wowPhase = 0; flutPhase = 0
        enable = 0
    }

    @inline(__always) private func tap(_ buf: UnsafeMutablePointer<Float>, delay: Float) -> Float {
        let d = min(max(delay, 1), Float(size - 2))
        let readPos = Float(writeIdx) - d
        var i0 = Int(readPos.rounded(.down))
        let frac = readPos - Float(i0)
        i0 = ((i0 % size) + size) % size
        let i1 = (i0 + 1) % size
        return buf[i0] + (buf[i1] - buf[i0]) * frac
    }

    func process(_ buf: UnsafeMutablePointer<Float>, frames: Int, t: RackTargets) {
        let enTarget: Float = t.echoEnabled ? 1 : 0
        let timeTarget = min(max(t.echoTimeMs, 40), 1200) / 1000 * sr
        // Feedback 0…1 maps to 0…1.05 so the top of the knob self-oscillates; the
        // soft ceiling keeps it bounded.
        let fbTarget = min(max(t.echoFeedback, 0), 1) * 1.05
        let toneTarget = min(max(t.echoTone, 0), 1)
        let wowTarget = min(max(t.echoWow, 0), 1)
        let mixTarget = min(max(t.echoMix, 0), 1)

        var f = 0
        while f < frames {
            enable = smooth(enable, enTarget, ctrlCoef)
            timeSamples = smooth(timeSamples, timeTarget, timeCoef)
            feedback = smooth(feedback, fbTarget, ctrlCoef)
            tone = smooth(tone, toneTarget, ctrlCoef)
            wow = smooth(wow, wowTarget, ctrlCoef)
            mix = smooth(mix, mixTarget, ctrlCoef)

            // Combined wow (slow) + flutter (fast), scaled by depth.
            wowPhase += wowInc; if wowPhase > 2 * .pi { wowPhase -= 2 * .pi }
            flutPhase += flutInc; if flutPhase > 2 * .pi { flutPhase -= 2 * .pi }
            let mod = (sinf(wowPhase) * 0.7 + sinf(flutPhase) * 0.3) * wow * maxModSamples
            let delay = timeSamples + mod

            let dl = tap(bufL, delay: delay)
            let dr = tap(bufR, delay: delay)

            // Loop low-pass damping: tone 0 = dark (heavy LP), 1 = bright (open).
            let lpCoef = 0.05 + 0.94 * tone
            dampL += lpCoef * (dl - dampL)
            dampR += lpCoef * (dr - dampR)

            let inL = buf[2 * f]
            let inR = buf[2 * f + 1]
            // Write input + soft-clipped feedback into the line (continuous even
            // while the module fades in/out, so bypass never pops).
            bufL[writeIdx] = inL + softClip(feedback * dampL)
            bufR[writeIdx] = inR + softClip(feedback * dampR)
            writeIdx += 1; if writeIdx >= size { writeIdx = 0 }

            let wetAmt = enable * mix
            buf[2 * f]     = inL + (dl - inL) * wetAmt
            buf[2 * f + 1] = inR + (dr - inR) * wetAmt
            f += 1
        }
    }
}

// MARK: - SPRING (FDN reverb)

/// Short 4-line feedback-delay network with a Hadamard mixing matrix and per-line
/// damping, tuned for a spring-reverb "boing/drip" character (documented choice).
private final class SpringReverb {
    private let sr: Float
    private let lines: [UnsafeMutablePointer<Float>]
    private let lengths: [Int]
    private var idx = [0, 0, 0, 0]
    private var damp = [Float](repeating: 0, count: 4)

    private var enable: Float = 0
    private var mix: Float = 0
    private var decay: Float = 0.55
    private var tone: Float = 0.5
    private let ctrlCoef: Float

    init(sampleRate: Float) {
        sr = sampleRate
        // Short, coprime-ish lengths → dense spring shimmer without a long room tail.
        let seconds: [Float] = [0.0197, 0.0259, 0.0331, 0.0413]
        let lens = seconds.map { max(4, Int($0 * sampleRate)) }
        lengths = lens
        lines = lens.map { len in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: len)
            p.initialize(repeating: 0, count: len)
            return p
        }
        ctrlCoef = onePoleCoef(seconds: 0.015, sampleRate: sr)
    }

    deinit {
        for (i, p) in lines.enumerated() { p.deinitialize(count: lengths[i]); p.deallocate() }
    }

    func reset() {
        for (i, p) in lines.enumerated() { p.update(repeating: 0, count: lengths[i]) }
        idx = [0, 0, 0, 0]; damp = [0, 0, 0, 0]; enable = 0
    }

    func process(_ buf: UnsafeMutablePointer<Float>, frames: Int, t: RackTargets) {
        let enTarget: Float = t.springEnabled ? 1 : 0
        let mixTarget = min(max(t.springMix, 0), 1)
        let decayTarget = min(max(t.springDecay, 0), 1)
        let toneTarget = min(max(t.springTone, 0), 1)

        var f = 0
        while f < frames {
            enable = smooth(enable, enTarget, ctrlCoef)
            mix = smooth(mix, mixTarget, ctrlCoef)
            decay = smooth(decay, decayTarget, ctrlCoef)
            tone = smooth(tone, toneTarget, ctrlCoef)

            // Feedback gain: up to ~0.86 (bounded so the tail always decays).
            let g = 0.5 + 0.36 * decay
            let lpCoef = 0.15 + 0.8 * tone

            let inL = buf[2 * f]
            let inR = buf[2 * f + 1]
            let input = (inL + inR) * 0.5

            // Read the four delayed outputs.
            let y0 = lines[0][idx[0]]
            let y1 = lines[1][idx[1]]
            let y2 = lines[2][idx[2]]
            let y3 = lines[3][idx[3]]

            // Per-line damping (one-pole LP in the loop).
            damp[0] += lpCoef * (y0 - damp[0])
            damp[1] += lpCoef * (y1 - damp[1])
            damp[2] += lpCoef * (y2 - damp[2])
            damp[3] += lpCoef * (y3 - damp[3])

            // Normalised 4×4 Hadamard mix of the damped outputs.
            let h = Float(0.5)
            let m0 = h * ( damp[0] + damp[1] + damp[2] + damp[3])
            let m1 = h * ( damp[0] - damp[1] + damp[2] - damp[3])
            let m2 = h * ( damp[0] + damp[1] - damp[2] - damp[3])
            let m3 = h * ( damp[0] - damp[1] - damp[2] + damp[3])

            // Write input + feedback back into the lines.
            lines[0][idx[0]] = input + g * m0
            lines[1][idx[1]] = input + g * m1
            lines[2][idx[2]] = input + g * m2
            lines[3][idx[3]] = input + g * m3
            for k in 0..<4 { idx[k] += 1; if idx[k] >= lengths[k] { idx[k] = 0 } }

            // Decorrelated stereo pickup.
            let wetL = (y0 + y2) * 0.5
            let wetR = (y1 + y3) * 0.5

            let wetAmt = enable * mix
            buf[2 * f]     = inL + (wetL - inL) * wetAmt
            buf[2 * f + 1] = inR + (wetR - inR) * wetAmt
            f += 1
        }
    }
}

// MARK: - SWEEP (morphing resonant SVF)

/// One big macro knob sweeping a resonant TPT state-variable filter LP→BP→HP with a
/// separate resonance control (Brief §5a). Coefficients are recomputed per block
/// from a block-smoothed macro so a sweep never zippers; filter state is continuous.
private final class SweepFilter {
    private let sr: Float
    private var ic1L: Float = 0, ic2L: Float = 0
    private var ic1R: Float = 0, ic2R: Float = 0

    private var enable: Float = 0
    private var macro: Float = 0.5
    private var reso: Float = 0.3
    private let ctrlCoef: Float

    init(sampleRate: Float) {
        sr = sampleRate
        ctrlCoef = onePoleCoef(seconds: 0.020, sampleRate: sr)
    }

    func reset() { ic1L = 0; ic2L = 0; ic1R = 0; ic2R = 0; enable = 0 }

    func process(_ buf: UnsafeMutablePointer<Float>, frames: Int, t: RackTargets) {
        let enTarget: Float = t.sweepEnabled ? 1 : 0
        let macroTarget = min(max(t.sweepMacro, 0), 1)
        let resoTarget = min(max(t.sweepReso, 0), 1)

        // Block-rate control smoothing → per-block coefficient update.
        enable = smooth(enable, enTarget, ctrlCoef)
        macro = smooth(macro, macroTarget, ctrlCoef)
        reso = smooth(reso, resoTarget, ctrlCoef)

        // Log frequency sweep 60 Hz → 12 kHz, clamped under Nyquist.
        let fc = min(60 * powf(200, macro), sr * 0.45)
        let g = tanf(.pi * fc / sr)
        // Resonance → Q 0.5 … 8.
        let q = 0.5 + reso * 7.5
        let k = 1 / q
        let a1 = 1 / (1 + g * (g + k))
        let a2 = g * a1
        let a3 = g * a2

        // LP→BP→HP morph weights (triangular, peak BP at macro 0.5).
        let wHP = max(0, 2 * macro - 1)
        let wLP = max(0, 1 - 2 * macro)
        let wBP = 1 - abs(2 * macro - 1)
        let en = enable

        var f = 0
        while f < frames {
            for ch in 0..<2 {
                let v0 = buf[2 * f + ch]
                var ic1 = ch == 0 ? ic1L : ic1R
                var ic2 = ch == 0 ? ic2L : ic2R
                let v3 = v0 - ic2
                let v1 = a1 * ic1 + a2 * v3
                let v2 = ic2 + a2 * ic1 + a3 * v3
                ic1 = 2 * v1 - ic1
                ic2 = 2 * v2 - ic2
                let low = v2
                let band = v1
                let high = v0 - k * v1 - v2
                let filtered = wLP * low + wBP * band + wHP * high
                buf[2 * f + ch] = v0 + (filtered - v0) * en
                if ch == 0 { ic1L = ic1; ic2L = ic2 } else { ic1R = ic1; ic2R = ic2 }
            }
            f += 1
        }
    }
}

// MARK: - LOW END (gentle low-shelf loudness)

/// Conservative low-shelf boost for laptop-speaker listening — off by default
/// (Brief §5a). A sub-harmonic synthesiser was deliberately NOT used; a bounded
/// RBJ low-shelf is the safe, documented choice (it can never generate runaway
/// energy). Amount 0…1 → 0…+6 dB below ~120 Hz.
private final class LowEnd {
    private let sr: Float
    private var x1L: Float = 0, x2L: Float = 0, y1L: Float = 0, y2L: Float = 0
    private var x1R: Float = 0, x2R: Float = 0, y1R: Float = 0, y2R: Float = 0

    private var enable: Float = 0
    private var amount: Float = 0
    private let ctrlCoef: Float
    private let f0: Float = 120

    init(sampleRate: Float) {
        sr = sampleRate
        ctrlCoef = onePoleCoef(seconds: 0.020, sampleRate: sr)
    }

    func reset() {
        x1L = 0; x2L = 0; y1L = 0; y2L = 0
        x1R = 0; x2R = 0; y1R = 0; y2R = 0
        enable = 0
    }

    func process(_ buf: UnsafeMutablePointer<Float>, frames: Int, t: RackTargets) {
        let enTarget: Float = t.lowEnabled ? 1 : 0
        let amtTarget = min(max(t.lowAmount, 0), 1)

        enable = smooth(enable, enTarget, ctrlCoef)
        amount = smooth(amount, amtTarget, ctrlCoef)

        // RBJ low-shelf. gainDB 0…+6, Slope S = 0.7 (gentle).
        let gainDB = amount * 6
        let a = powf(10, gainDB / 40)
        let w0 = 2 * Float.pi * f0 / sr
        let cosw = cosf(w0)
        let sinw = sinf(w0)
        let s: Float = 0.7
        let alpha = sinw / 2 * sqrtf((a + 1 / a) * (1 / s - 1) + 2)
        let twoSqrtAalpha = 2 * sqrtf(a) * alpha

        let b0 =      a * ((a + 1) - (a - 1) * cosw + twoSqrtAalpha)
        let b1 =  2 * a * ((a - 1) - (a + 1) * cosw)
        let b2 =      a * ((a + 1) - (a - 1) * cosw - twoSqrtAalpha)
        let a0 =           (a + 1) + (a - 1) * cosw + twoSqrtAalpha
        let a1 = -2 *     ((a - 1) + (a + 1) * cosw)
        let a2 =           (a + 1) + (a - 1) * cosw - twoSqrtAalpha

        let nb0 = b0 / a0, nb1 = b1 / a0, nb2 = b2 / a0
        let na1 = a1 / a0, na2 = a2 / a0
        let en = enable

        var f = 0
        while f < frames {
            // Left
            let xl = buf[2 * f]
            let yl = nb0 * xl + nb1 * x1L + nb2 * x2L - na1 * y1L - na2 * y2L
            x2L = x1L; x1L = xl; y2L = y1L; y1L = yl
            buf[2 * f] = xl + (yl - xl) * en
            // Right
            let xr = buf[2 * f + 1]
            let yr = nb0 * xr + nb1 * x1R + nb2 * x2R - na1 * y1R - na2 * y2R
            x2R = x1R; x1R = xr; y2R = y1R; y1R = yr
            buf[2 * f + 1] = xr + (yr - xr) * en
            f += 1
        }
    }
}
