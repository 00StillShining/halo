import AVFoundation
import Accelerate
import Foundation

/// The export storage treatment for a prepared sample (Brief §8 "Export treatments
/// (test each on hardware before exposing): `ORIGINAL`, `HIGH`, `BALANCED`, `LO-FI`").
///
/// A treatment is purely the OUTPUT sample-rate policy; all treatments store 16-bit
/// LinearPCM (the EP-40's native depth, Brief §3). It is deliberately separate from
/// `SamplePrep` (trim/fade/gain/channel): prep shapes the audio in the float domain at
/// the source rate, then a treatment resamples + quantises to a device-storable form.
///
/// ON-DEVICE COMPATIBILITY IS NEEDS-DEVICE: the rates below come from the brief's stated
/// device capabilities (§3: native 46,875 Hz/16-bit; 32,000 Hz mode; preserves imported
/// rates ≤46,875 Hz). Whether a produced file is actually accepted by a real EP-40 slot is
/// established only by Phase 0B. These encoders are verified LOCALLY (real, decodable WAV
/// at the target rate/depth) and claim nothing about the hardware.
enum SampleTreatment: Sendable, Equatable, Hashable {
    /// Preserve the source rate/channels when compatible; clamp to the device max if the
    /// source rate exceeds it.
    case original
    /// 46,875 Hz / 16-bit (device native).
    case high
    /// 32,000 Hz / 16-bit (device recording mode).
    case balanced
    /// 22,050 Hz or 11,025 Hz / 16-bit.
    case loFi(LoFiRate)

    /// The two documented LO-FI rates (Brief §8 "`LO-FI` (22,050 or 11,025 Hz/16-bit)").
    enum LoFiRate: Double, Sendable, Equatable, Hashable, CaseIterable {
        case r22050 = 22_050
        case r11025 = 11_025
    }

    /// The EP-40 native/maximum sample rate (Brief §3: "native sampling is 46,875 Hz").
    static let deviceMaxSampleRate: Double = 46_875

    /// Every device stores 16-bit LinearPCM.
    static let bitDepth: Int = 16

    /// A stable, exhaustive list for menus (ORIGINAL is source-dependent; both LO-FI rates
    /// are exposed so the owner picks explicitly).
    static let allSelectable: [SampleTreatment] =
        [.original, .high, .balanced, .loFi(.r22050), .loFi(.r11025)]

    /// Short uppercase label for the right-rail preset control.
    var label: String {
        switch self {
        case .original: return "ORIGINAL"
        case .high: return "HIGH"
        case .balanced: return "BALANCED"
        case .loFi(.r22050): return "LO-FI 22K"
        case .loFi(.r11025): return "LO-FI 11K"
        }
    }

    /// Resolve the OUTPUT sample rate for a given source rate.
    /// - `original`: preserve the source rate when ≤ device max; otherwise clamp to the
    ///   device max (never upsample a low-rate source — "preserve when compatible").
    /// - fixed treatments: their nominal rate, independent of source.
    func resolvedSampleRate(sourceSampleRate: Double) -> Double {
        switch self {
        case .original:
            guard sourceSampleRate > 0 else { return Self.deviceMaxSampleRate }
            return min(sourceSampleRate, Self.deviceMaxSampleRate)
        case .high:
            return Self.deviceMaxSampleRate
        case .balanced:
            return 32_000
        case .loFi(let r):
            return r.rawValue
        }
    }

    /// Output frame count after resampling `sourceFrameCount` frames from `sourceSampleRate`
    /// to this treatment's rate. Pure arithmetic (round-to-nearest) so the estimator and
    /// tests are deterministic; the real encoder targets the same count.
    func outputFrameCount(sourceFrameCount: Int, sourceSampleRate: Double) -> Int {
        guard sourceFrameCount > 0, sourceSampleRate > 0 else { return 0 }
        let target = resolvedSampleRate(sourceSampleRate: sourceSampleRate)
        if target == sourceSampleRate { return sourceFrameCount }
        return Int((Double(sourceFrameCount) * target / sourceSampleRate).rounded())
    }
}

/// The result of encoding a prepared buffer under a treatment: interleaved 16-bit PCM
/// plus the exact format it was produced at. Value type, `Sendable`. `payloadBytes` is the
/// authoritative measured audio-data size (`frames × channels × 2`).
struct EncodedSample: Sendable, Equatable {
    /// Interleaved little-endian 16-bit samples, `frameCount × channelCount` long.
    let interleaved: [Int16]
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int

    /// Exact audio payload bytes (`frames × channels × 2`).
    var payloadBytes: Int { interleaved.count * MemoryLayout<Int16>.size }
}

enum SampleTreatmentEncoderError: Error, Equatable {
    case formatUnavailable
    case resampleFailed
}

/// Offline encoder: takes a prepared `CanonicalAudioBuffer` and produces a device-storable
/// 16-bit PCM `EncodedSample` (and, optionally, a real `.wav` on disk). Runs OFF the main
/// actor — every entry point is `nonisolated async` so the AVAudioConverter resample runs
/// on the cooperative pool, not `@MainActor` (Brief §2). NOT a real-time path: this is
/// bulk offline work, allocation is expected.
///
/// Resampling uses `AVAudioConverter` (the platform's anti-aliased sample-rate converter)
/// so a downsampled LO-FI export is band-limited rather than aliased — honest quality, no
/// hand-rolled filter to misrepresent. Quantisation to 16-bit clamps to [−1, 1] then scales
/// by 32767 with round-to-nearest (no dither; documented).
enum SampleTreatmentEncoder {

    /// Encode `buffer` under `treatment`. If the treatment rate equals the buffer rate the
    /// samples are quantised directly (no resample); otherwise they are converted first.
    static func encode(_ buffer: CanonicalAudioBuffer,
                       treatment: SampleTreatment) async throws -> EncodedSample {
        try encodeSynchronously(buffer, treatment: treatment)
    }

    /// Encode and write a real 16-bit interleaved `.wav` to `url`. Returns the encoded
    /// payload plus the MEASURED container overhead (`fileSize − payloadBytes`) so the
    /// estimator can report exact on-disk bytes instead of a guessed header constant.
    @discardableResult
    static func encodeToWAV(_ buffer: CanonicalAudioBuffer,
                            treatment: SampleTreatment,
                            url: URL) async throws -> (encoded: EncodedSample, containerOverhead: Int) {
        let encoded = try encodeSynchronously(buffer, treatment: treatment)
        try writeWAV(encoded, to: url)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        let overhead = max(0, (fileSize ?? encoded.payloadBytes) - encoded.payloadBytes)
        return (encoded, overhead)
    }

    // MARK: - Core

    private static func encodeSynchronously(_ buffer: CanonicalAudioBuffer,
                                            treatment: SampleTreatment) throws -> EncodedSample {
        let srcRate = buffer.sampleRate
        let channelCount = buffer.channelCount
        let dstRate = treatment.resolvedSampleRate(sourceSampleRate: srcRate)

        // Empty / silent-length buffer → honest zero-frame encode at the target format.
        guard channelCount > 0, buffer.frameCount > 0 else {
            return EncodedSample(interleaved: [], sampleRate: dstRate,
                                 channelCount: max(0, channelCount), frameCount: 0)
        }

        // Resample in the float domain (deinterleaved per channel) unless rates already match.
        let resampled: [[Float]]
        if dstRate == srcRate {
            resampled = buffer.channels
        } else {
            resampled = try resample(buffer.channels, from: srcRate, to: dstRate)
        }

        let frames = resampled.first?.count ?? 0
        return EncodedSample(interleaved: quantizeInterleaved(resampled, frames: frames),
                             sampleRate: dstRate,
                             channelCount: channelCount,
                             frameCount: frames)
    }

    /// Anti-aliased sample-rate conversion via `AVAudioConverter`, per the platform's
    /// high-quality converter. Input/output are non-interleaved Float32.
    static func resample(_ channels: [[Float]], from srcRate: Double, to dstRate: Double) throws -> [[Float]] {
        let channelCount = channels.count
        let srcFrames = channels.first?.count ?? 0
        guard channelCount > 0, srcFrames > 0 else { return channels }

        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcRate,
                                           channels: AVAudioChannelCount(channelCount), interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: dstRate,
                                            channels: AVAudioChannelCount(channelCount), interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw SampleTreatmentEncoderError.formatUnavailable
        }
        // Full-quality, no priming latency in the output timeline.
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .none

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(srcFrames)),
              let inData = inBuffer.floatChannelData else {
            throw SampleTreatmentEncoderError.formatUnavailable
        }
        inBuffer.frameLength = AVAudioFrameCount(srcFrames)
        for c in 0..<channelCount {
            channels[c].withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    inData[c].update(from: base, count: min(srcFrames, src.count))
                }
            }
        }

        // Expected output frames (round-to-nearest); allocate a little slack for the
        // converter's internal rounding.
        let expected = Int((Double(srcFrames) * dstRate / srcRate).rounded())
        let capacity = AVAudioFrameCount(expected + 32)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity),
              let outData = outBuffer.floatChannelData else {
            throw SampleTreatmentEncoderError.formatUnavailable
        }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error || conversionError != nil {
            throw SampleTreatmentEncoderError.resampleFailed
        }

        // Trim/pad the converter output to exactly `expected` frames so the encoded size
        // matches the estimator arithmetic deterministically.
        let produced = Int(outBuffer.frameLength)
        var out = [[Float]](repeating: [Float](repeating: 0, count: expected), count: channelCount)
        let copy = min(produced, expected)
        for c in 0..<channelCount {
            out[c].withUnsafeMutableBufferPointer { dst in
                if let base = dst.baseAddress {
                    base.update(from: outData[c], count: copy)
                }
            }
        }
        return out
    }

    /// Quantise deinterleaved Float32 channels to interleaved little-endian Int16. Clamps
    /// to [−1, 1] then scales by 32767 with round-to-nearest (no dither; documented).
    static func quantizeInterleaved(_ channels: [[Float]], frames: Int) -> [Int16] {
        let channelCount = channels.count
        guard channelCount > 0, frames > 0 else { return [] }
        var out = [Int16](repeating: 0, count: frames * channelCount)
        for c in 0..<channelCount {
            let ch = channels[c]
            let m = min(frames, ch.count)
            for i in 0..<m {
                var v = ch[i]
                if v > 1 { v = 1 } else if v < -1 { v = -1 }
                let scaled = (v * 32767).rounded()
                out[i * channelCount + c] = Int16(scaled)
            }
        }
        return out
    }

    /// Write an `EncodedSample` as a real interleaved 16-bit LinearPCM `.wav`. Uses
    /// `AVAudioFile` so the file is a standard, re-openable WAV (verified locally by the
    /// tests reopening it).
    static func writeWAV(_ encoded: EncodedSample, to url: URL) throws {
        let channels = max(1, encoded.channelCount)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: encoded.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let procFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: encoded.sampleRate,
                                             channels: AVAudioChannelCount(channels),
                                             interleaved: false) else {
            throw SampleTreatmentEncoderError.formatUnavailable
        }
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard encoded.frameCount > 0 else { return }  // valid empty file (header only)
        guard let buf = AVAudioPCMBuffer(pcmFormat: procFormat,
                                         frameCapacity: AVAudioFrameCount(encoded.frameCount)),
              let data = buf.floatChannelData else {
            throw SampleTreatmentEncoderError.formatUnavailable
        }
        buf.frameLength = AVAudioFrameCount(encoded.frameCount)
        // De-interleave Int16 back to float for AVAudioFile (it re-quantises to 16-bit int
        // on disk; the round-trip is lossless for our already-16-bit values).
        for i in 0..<encoded.frameCount {
            for c in 0..<channels {
                data[c][i] = Float(encoded.interleaved[i * channels + c]) / 32767
            }
        }
        try file.write(from: buf)
    }
}
