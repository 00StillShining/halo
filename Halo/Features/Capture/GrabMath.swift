import Foundation

/// Pure, unit-tested math for GRAB loop capture (Brief §5b). No I/O, no actors, no
/// audio hardware — every value is derived from real inputs (frame counts, the
/// observed clock BPM, the captured mono signal). The bar window, zero-cross trim,
/// BPM estimate and filename/title round-trip all live here so the honesty-critical
/// arithmetic is provable without the device.
///
/// HONESTY (Brief §1/§4): bar boundaries come from the observed clock (the caller
/// anchors `lastDownbeatFrame`); the no-clock BPM is explicitly an ESTIMATE and is
/// tagged `est` in the filename and title — never claimed as device truth. When
/// history is short the bar count is reduced to what actually fits; nothing is
/// fabricated to fill a window.
enum GrabMath {

    /// A resolved capture window in absolute frame counts. `bars == 0` marks a
    /// seconds (no-clock) window.
    struct Window: Equatable {
        var startFrame: Int
        var endFrame: Int
        var bars: Int
    }

    // MARK: - Bar / seconds windows

    static func framesPerBeat(sampleRate: Double, bpm: Double) -> Double {
        guard bpm > 0 else { return 0 }
        return sampleRate * 60.0 / bpm
    }

    /// Whole-bar window ending at the most recent passed downbeat, clamped to the
    /// resident history by reducing the bar count until the start is in range. Pure.
    static func barWindow(sampleRate: Double, bpm: Double, beatsPerBar: Int, bars: Int,
                          lastDownbeatFrame: Int, oldestResident: Int) -> Window {
        let perBar = framesPerBeat(sampleRate: sampleRate, bpm: bpm) * Double(max(1, beatsPerBar))
        let fpb = Int(perBar.rounded())
        guard fpb > 0 else {
            return Window(startFrame: lastDownbeatFrame, endFrame: lastDownbeatFrame, bars: 0)
        }
        var n = max(1, bars)
        while n > 0 && lastDownbeatFrame - n * fpb < oldestResident { n -= 1 }
        let start = lastDownbeatFrame - n * fpb
        return Window(startFrame: max(start, oldestResident), endFrame: lastDownbeatFrame, bars: n)
    }

    /// Last-N-seconds window ending at `now`, clamped to the resident history. Pure.
    static func secondsWindow(sampleRate: Double, seconds: Double, now: Int, oldestResident: Int) -> Window {
        let want = Int((seconds * sampleRate).rounded())
        let start = max(now - want, oldestResident)
        return Window(startFrame: start, endFrame: now, bars: 0)
    }

    // MARK: - Zero-cross trim

    /// Nearest rising (neg→pos) zero crossing within ±radius of `target` on a mono
    /// signal. A rising crossing at index `i` means `mono[i-1] < 0 <= mono[i]`. Both
    /// window ends are snapped on the SAME slope so the loop seam is click-free.
    /// Returns `target` (clamped in range) when no crossing is found in the window.
    static func snapToZeroCrossing(_ mono: [Float], target: Int, radius: Int) -> Int {
        let n = mono.count
        guard n > 1 else { return max(0, min(target, n)) }
        let clampedTarget = max(0, min(target, n))
        let lo = max(1, clampedTarget - max(0, radius))
        let hi = min(n - 1, clampedTarget + max(0, radius))
        guard lo <= hi else { return clampedTarget }
        var best = -1
        var bestDist = Int.max
        for i in lo...hi where mono[i - 1] < 0 && mono[i] >= 0 {
            let dist = abs(i - clampedTarget)
            if dist < bestDist { bestDist = dist; best = i }
        }
        return best >= 0 ? best : clampedTarget
    }

    // MARK: - BPM estimate (reference only)

    /// Onset-envelope autocorrelation BPM guess (reference only, never device truth).
    /// ~10 ms energy hops → half-wave-rectified first difference (onset novelty) →
    /// autocorrelation over the lags in `bpmRange` → argmax. Returns nil when the
    /// signal is too weak/flat to yield a confident peak.
    static func estimateBPM(mono: [Float], sampleRate: Double,
                            bpmRange: ClosedRange<Double> = 60...180) -> Double? {
        guard sampleRate > 0, mono.count > Int(sampleRate) else { return nil }
        let hop = max(1, Int((sampleRate * 0.010).rounded()))   // ~10 ms
        let hopCount = mono.count / hop
        guard hopCount > 8 else { return nil }

        // Per-hop energy (RMS-ish; sum of squares is enough for a novelty curve).
        var energy = [Float](repeating: 0, count: hopCount)
        for k in 0..<hopCount {
            var sum: Float = 0
            let base = k * hop
            for i in 0..<hop { let s = mono[base + i]; sum += s * s }
            energy[k] = sum
        }

        // Half-wave-rectified first difference → onset novelty.
        var novelty = [Float](repeating: 0, count: hopCount)
        for k in 1..<hopCount { novelty[k] = max(0, energy[k] - energy[k - 1]) }
        let noveltyPower = novelty.reduce(0) { $0 + $1 * $1 }
        guard noveltyPower > 0 else { return nil }

        let hopSeconds = Double(hop) / sampleRate
        let minLag = max(1, Int((60.0 / bpmRange.upperBound / hopSeconds).rounded()))
        let maxLag = min(hopCount - 1, Int((60.0 / bpmRange.lowerBound / hopSeconds).rounded()))
        guard minLag <= maxLag else { return nil }

        var bestLag = -1
        var bestScore: Float = 0
        for lag in minLag...maxLag {
            var acc: Float = 0
            for k in lag..<hopCount { acc += novelty[k] * novelty[k - lag] }
            if acc > bestScore { bestScore = acc; bestLag = lag }
        }
        guard bestLag > 0 else { return nil }
        // Confidence gate: the winning lag must carry a real fraction of the novelty
        // energy, else the signal is too flat to call a tempo honestly.
        guard bestScore > noveltyPower * 0.05 else { return nil }

        let bpm = 60.0 / (Double(bestLag) * hopSeconds)
        guard bpmRange.contains(bpm) else { return nil }
        return bpm
    }

    // MARK: - Naming (persistence IS the file — no sidecar DB)

    /// The two honest grab kinds. Every displayed/stored bar/bpm value is a real
    /// computed number; the unclocked kind carries an EST marker.
    enum Kind: Equatable {
        case barsClocked(bars: Int, bpm: Int)
        case secondsUnclocked(seconds: Int, estBPM: Int?)
    }

    /// e.g. `grab-2026-07-13-2142-07-08bars-92bpm.wav`
    ///      `grab-2026-07-13-2142-07-10s-est92bpm.wav`
    static func filename(kind: Kind, date: Date) -> String {
        let stamp = stampFormatter.string(from: date)   // yyyy-MM-dd-HHmm-ss
        switch kind {
        case let .barsClocked(bars, bpm):
            return "grab-\(stamp)-\(pad2(bars))bars-\(bpm)bpm.wav"
        case let .secondsUnclocked(seconds, estBPM):
            if let estBPM {
                return "grab-\(stamp)-\(seconds)s-est\(estBPM)bpm.wav"
            }
            return "grab-\(stamp)-\(seconds)s.wav"
        }
    }

    /// Parse a grab filename back to a display title, or nil if it is not a grab file.
    /// e.g. `GRAB · 2026-07-13 21.42 · 8 BARS · 92 BPM`
    ///      `GRAB · 2026-07-13 21.42 · 10 S · ~92 BPM (EST)`
    static func title(fromFilename name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        let parts = stem.split(separator: "-").map(String.init)
        // grab | yyyy | MM | dd | HHmm | ss | <spec> [| bpmspec]
        guard parts.count >= 7, parts[0] == "grab" else { return nil }
        let year = parts[1], month = parts[2], day = parts[3]
        let hhmm = parts[4], ss = parts[5]
        guard hhmm.count == 4 else { return nil }
        let hh = String(hhmm.prefix(2)), mm = String(hhmm.suffix(2))
        let when = "\(year)-\(month)-\(day) \(hh).\(mm)"
        _ = ss   // seconds are captured in the file; the title stays to the minute

        let spec = parts[6]
        if spec.hasSuffix("bars") {
            let barsStr = String(spec.dropLast(4))
            let bars = Int(barsStr) ?? 0
            let bpm = parts.count >= 8 ? bpmValue(parts[7]) : nil
            let bpmPart = bpm.map { " · \($0) BPM" } ?? ""
            return "GRAB · \(when) · \(bars) BARS\(bpmPart)"
        }
        if spec.hasSuffix("s") {
            let secsStr = String(spec.dropLast())
            let secs = Int(secsStr) ?? 0
            // The bpm token is `estNNbpm` for the unclocked kind.
            let est = parts.count >= 8 ? bpmValue(parts[7]) : nil
            let bpmPart = est.map { " · ~\($0) BPM (EST)" } ?? ""
            return "GRAB · \(when) · \(secs) S\(bpmPart)"
        }
        return nil
    }

    /// Extract the integer BPM from a token like `92bpm` or `est92bpm`.
    private static func bpmValue(_ token: String) -> Int? {
        var t = token
        if t.hasPrefix("est") { t.removeFirst(3) }
        guard t.hasSuffix("bpm") else { return nil }
        return Int(t.dropLast(3))
    }

    private static func pad2(_ n: Int) -> String { String(format: "%02d", n) }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm-ss"
        return f
    }()
}
