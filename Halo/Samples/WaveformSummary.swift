import Accelerate
import Foundation

/// A cached min/max envelope of an imported sample (Brief §8 "Cache min/max
/// waveform summaries; never render a long file sample-by-sample on the main
/// thread"). Built ONCE off the main actor from a `CanonicalAudioBuffer`; the UI
/// then draws `bucketCount` vertical bars straight from `minima`/`maxima` regardless
/// of how many million frames the source has.
///
/// The envelope is taken over an equal-average mono mixdown so a stereo file draws
/// as one coherent waveform (per-channel envelopes remain a later opt-in).
///
/// HONESTY (Brief §1/§4): buckets are the true peak/trough of real decoded samples.
/// Empty input yields an empty summary, never a fabricated shape.
struct WaveformSummary: Sendable, Equatable, Hashable {
    /// Per-bucket minimum sample value, in [-1, 1]. `count == bucketCount`.
    let minima: [Float]
    /// Per-bucket maximum sample value, in [-1, 1]. `count == bucketCount`.
    let maxima: [Float]
    /// Number of source frames each bucket spans (the last bucket may cover fewer).
    let framesPerBucket: Int
    /// Total source frames summarised — lets a caller map a bucket back to a time.
    let sourceFrameCount: Int

    var bucketCount: Int { minima.count }
    var isEmpty: Bool { minima.isEmpty }

    /// The largest absolute excursion across the whole summary — a cheap true peak
    /// for the header/meter ("peak −1.2 dBFS") without rescanning the buffer.
    var peakMagnitude: Float {
        var p: Float = 0
        for v in maxima where v > p { p = v }
        for v in minima where -v > p { p = -v }
        return p
    }

    /// Default target bar count. A sane on-screen resolution for the Load rail
    /// waveform strip; callers override for wider/narrower displays.
    static let defaultBucketCount = 512

    /// Build the summary from a canonical buffer. `targetBuckets` is an upper bound:
    /// a file shorter than that many frames produces one bucket per frame (never
    /// more buckets than frames, so no bucket is empty/invented).
    static func build(from buffer: CanonicalAudioBuffer, targetBuckets: Int = defaultBucketCount) -> WaveformSummary {
        build(mono: buffer.monoMixdown(), targetBuckets: targetBuckets)
    }

    /// Bucket a mono signal into min/max pairs. Kept separate from the buffer type
    /// so tests can pin the pure bucketing math on a hand-built signal.
    static func build(mono samples: [Float], targetBuckets: Int) -> WaveformSummary {
        let n = samples.count
        guard n > 0, targetBuckets > 0 else {
            return WaveformSummary(minima: [], maxima: [],
                                   framesPerBucket: 0, sourceFrameCount: n)
        }

        // At most one bucket per frame; ceil-divide so the buckets tile the whole
        // signal and the final (possibly short) bucket still gets summarised.
        let buckets = min(targetBuckets, n)
        let perBucket = (n + buckets - 1) / buckets

        var minima = [Float](repeating: 0, count: buckets)
        var maxima = [Float](repeating: 0, count: buckets)

        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            var b = 0
            var start = 0
            while start < n {
                let len = min(perBucket, n - start)
                var lo: Float = 0
                var hi: Float = 0
                // vDSP min/max over the bucket window (Brief §8 uses vDSP for
                // waveform summaries) — branchless and fast on long files.
                vDSP_minv(base + start, 1, &lo, vDSP_Length(len))
                vDSP_maxv(base + start, 1, &hi, vDSP_Length(len))
                minima[b] = lo
                maxima[b] = hi
                b += 1
                start += len
            }
        }

        return WaveformSummary(minima: minima, maxima: maxima,
                               framesPerBucket: perBucket, sourceFrameCount: n)
    }
}
