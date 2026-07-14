import Accelerate
import Foundation

/// Spectral-flux onset detection (Brief §5c CHOP). Pure, deterministic, off-main.
/// Operates on a real mono mixdown of a decoded sample and returns SOURCE-frame onset
/// indices — the interior transient cut points a break/vocal/grab is sliced at.
///
/// HONESTY (Brief §1/§4): every onset is computed from real decoded samples. Empty,
/// silent, or too-short input yields NO onsets — never a fabricated grid. The maths is
/// deterministic (fixed FFT + adaptive peak-pick), so it is unit-tested against a
/// synthesized break fixture with planted transients (see `OnsetDetectorTests`).
enum OnsetDetector {

    struct Parameters: Sendable, Equatable {
        /// UI knob 0…1. Higher = more slices (lower adaptive threshold multiplier).
        var sensitivity: Double = 0.5
        /// Reject onsets closer than this (double-trigger guard + micro-fade room).
        var minSliceMilliseconds: Double = 40
        var windowSize = 1024      // FFT size (power of two)
        var hopSize = 512          // 50% overlap
    }

    /// Ascending SOURCE-frame onset indices, each strictly inside `(0, n)`. Frame 0 and
    /// frame n are the implicit first-slice-start / last-slice-end (see `SliceSet`); these
    /// are only the interior cut points. Honest: silent/short input → `[]`.
    static func detectOnsets(mono: [Float], sampleRate: Double, parameters p: Parameters) -> [Int] {
        let n = mono.count
        guard n >= p.windowSize, sampleRate > 0,
              p.windowSize.nonzeroBitCount == 1, p.hopSize > 0 else { return [] }

        // 1. Framewise half-wave-rectified spectral flux (Hann-windowed real FFT).
        let flux = spectralFlux(mono: mono, windowSize: p.windowSize, hopSize: p.hopSize)
        guard flux.count > 2 else { return [] }

        // 2. Adaptive peak-pick. threshold = localMean(±W) * mult + floor.
        //    sensitivity 0…1 → mult 2.2…0.8 (few…many onsets).
        let mult = Float(2.2 - 1.4 * min(max(p.sensitivity, 0), 1))
        let minGapFrames = max(1, Int(p.minSliceMilliseconds / 1000 * sampleRate))
        let onsets = pickPeaks(flux: flux, hopSize: p.hopSize,
                               multiplier: mult, minGapFrames: minGapFrames)
        return onsets.filter { $0 > 0 && $0 < n }
    }

    // MARK: - Spectral flux (classic vDSP real FFT)

    private static func spectralFlux(mono: [Float], windowSize: Int, hopSize: Int) -> [Float] {
        let log2n = vDSP_Length(log2(Float(windowSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let half = windowSize / 2

        var window = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        var prevMag = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: windowSize)
        var flux: [Float] = []

        var start = 0
        var isFirstFrame = true
        while start + windowSize <= mono.count {
            // Hann-window the frame.
            mono.withUnsafeBufferPointer { mp in
                vDSP_vmul(mp.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(windowSize))
            }
            // Real forward FFT → per-bin magnitude.
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                }
            }
            // Half-wave-rectified positive spectral difference, summed. The very first
            // frame has no predecessor, so its flux is a DC startup artefact — zero it
            // rather than emit a phantom onset at the head.
            if isFirstFrame {
                flux.append(0)
                isFirstFrame = false
            } else {
                var s: Float = 0
                for k in 0..<half {
                    let d = mag[k] - prevMag[k]
                    if d > 0 { s += d }
                }
                flux.append(s)
            }
            swap(&prevMag, &mag)   // prevMag ← current; mag scratch is overwritten next frame
            start += hopSize
        }
        return flux
    }

    // MARK: - Adaptive peak picking

    private static func pickPeaks(flux: [Float], hopSize: Int,
                                  multiplier: Float, minGapFrames: Int) -> [Int] {
        let W = 6                                   // local-mean half-window (frames)
        var onsets: [Int] = []
        var lastFrame = -minGapFrames
        for m in 1..<(flux.count - 1) {
            let lo = max(0, m - W), hi = min(flux.count - 1, m + W)
            var mean: Float = 0
            for i in lo...hi { mean += flux[i] }
            mean /= Float(hi - lo + 1)
            let threshold = mean * multiplier + 1e-6
            let isLocalMax = flux[m] > flux[m - 1] && flux[m] >= flux[m + 1]
            let frame = m * hopSize
            if flux[m] > threshold, isLocalMax, frame - lastFrame >= minGapFrames {
                onsets.append(frame)
                lastFrame = frame
            }
        }
        return onsets
    }
}

/// One slice window in SOURCE frames. `id` (0-based) is the stable list/pad key.
struct SliceRange: Identifiable, Sendable, Equatable, Hashable {
    let id: Int          // slice index (0-based)
    let startFrame: Int
    let endFrame: Int    // exclusive
    var frameCount: Int { max(0, endFrame - startFrame) }
}

/// The editable slice model (Brief §5c). Slice 1 always starts at frame 0 and the last
/// slice always ends at frame n; the detector's onsets become interior cut points that
/// can be moved, added and deleted. Pure value type, deterministic, unit-tested — no
/// invented cuts (silence → zero interior cuts → one whole-signal slice).
struct SliceSet: Sendable, Equatable {
    let sourceFrameCount: Int
    private(set) var cuts: [Int]     // sorted, unique interior cuts in (0, n)

    init(sourceFrameCount n: Int, onsets: [Int]) {
        let count = max(0, n)
        sourceFrameCount = count
        var seen = Set<Int>()
        cuts = onsets.filter { $0 > 0 && $0 < count && seen.insert($0).inserted }.sorted()
    }

    var sliceCount: Int { sourceFrameCount > 0 ? cuts.count + 1 : 0 }

    func slices() -> [SliceRange] {
        guard sourceFrameCount > 0 else { return [] }
        let bounds = [0] + cuts + [sourceFrameCount]
        return (0..<sliceCount).map {
            SliceRange(id: $0, startFrame: bounds[$0], endFrame: bounds[$0 + 1])
        }
    }

    /// Add an interior cut, keeping every slice at least `minGap` frames wide.
    mutating func addCut(at frame: Int, minGap: Int) {
        let g = max(1, minGap)
        let f = min(max(frame, 0), sourceFrameCount)
        guard f > 0, f < sourceFrameCount,
              f >= g, sourceFrameCount - f >= g,
              !cuts.contains(where: { abs($0 - f) < g }) else { return }
        cuts.append(f)
        cuts.sort()
    }

    mutating func removeCut(index i: Int) {
        guard cuts.indices.contains(i) else { return }
        cuts.remove(at: i)
    }

    /// Move cut `i`, clamped between its neighbours with a `minGap` margin on each side.
    mutating func moveCut(index i: Int, to frame: Int, minGap: Int) {
        guard cuts.indices.contains(i) else { return }
        let g = max(1, minGap)
        let lower = (i == 0 ? 0 : cuts[i - 1]) + g
        let upper = (i == cuts.count - 1 ? sourceFrameCount : cuts[i + 1]) - g
        guard lower <= upper else { return }
        cuts[i] = min(max(frame, lower), upper)
    }

    mutating func clear() { cuts.removeAll() }
}
