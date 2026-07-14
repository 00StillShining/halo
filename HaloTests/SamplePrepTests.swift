import AVFoundation
import XCTest
@testable import Halo

/// Pins non-destructive prep, offline treatment encoders, and the prep+treatment memory
/// estimate (Brief §8 sample processing / Phase 3 exit criterion "same source prepared
/// with different treatments reports predictable sizes"). All LOCAL — no device.
final class SamplePrepTests: XCTestCase {

    // MARK: - Helpers

    /// A stereo canonical buffer whose channels carry the supplied signals.
    private func buffer(_ channels: [[Float]], rate: Double = 44_100) -> CanonicalAudioBuffer {
        CanonicalAudioBuffer(channels: channels, sampleRate: rate)
    }

    private func peak(_ channels: [[Float]]) -> Float {
        var p: Float = 0
        for ch in channels { for v in ch where abs(v) > p { p = abs(v) } }
        return p
    }

    // MARK: - Trim (non-destructive)

    func testTrimSelectsWindowAndLeavesSourceUntouched() {
        let src = buffer([[0, 1, 2, 3, 4, 5], [10, 11, 12, 13, 14, 15]])
        var prep = SamplePrep()
        prep.trimStartFrame = 2
        prep.trimEndFrame = 5   // exclusive → frames 2,3,4
        let out = prep.apply(to: src)
        XCTAssertEqual(out.frameCount, 3)
        XCTAssertEqual(out.channels[0], [2, 3, 4])
        XCTAssertEqual(out.channels[1], [12, 13, 14])
        // Source is unchanged (non-destructive).
        XCTAssertEqual(src.channels[0], [0, 1, 2, 3, 4, 5])
    }

    func testTrimClampsOutOfRangeAndEmptySelection() {
        let src = buffer([[1, 2, 3]])
        var prep = SamplePrep()
        prep.trimStartFrame = 10
        prep.trimEndFrame = 20
        let out = prep.apply(to: src)
        XCTAssertEqual(out.frameCount, 0, "clamped empty selection → zero-length, honest")
        XCTAssertEqual(out.channelCount, 1)
    }

    func testIdentityPrepIsPassthrough() {
        let src = buffer([[0.1, -0.2, 0.3], [0.4, -0.5, 0.6]])
        let out = SamplePrep.identity.apply(to: src)
        XCTAssertEqual(out.channels, src.channels)
        XCTAssertEqual(out.sampleRate, src.sampleRate)
    }

    // MARK: - Gain

    func testGainDecibelsScalesLinearly() {
        let src = buffer([[0.5, -0.5]])
        var prep = SamplePrep()
        prep.gainDecibels = 6.0206   // ×2
        let out = prep.apply(to: src)
        XCTAssertEqual(out.channels[0][0], 1.0, accuracy: 1e-3)
        XCTAssertEqual(out.channels[0][1], -1.0, accuracy: 1e-3)
    }

    // MARK: - Equal-power fades

    func testEqualPowerFadeInEndpointsAndCurve() {
        // Constant 1.0 signal, fade-in over the whole 5-frame buffer.
        let src = buffer([[1, 1, 1, 1, 1]])
        var prep = SamplePrep()
        prep.fadeInFrames = 5
        let out = prep.apply(to: src).channels[0]
        XCTAssertEqual(out.first ?? -1, 0, accuracy: 1e-6, "fade-in starts at 0")
        XCTAssertEqual(out.last ?? -1, 1, accuracy: 1e-6, "fade-in reaches unity")
        // Midpoint of a sine fade over t=0.5 → sin(π/4) ≈ 0.7071.
        XCTAssertEqual(out[2], sinf(0.5 * .pi * 0.5), accuracy: 1e-6)
    }

    func testEqualPowerFadeOutEndpoints() {
        let src = buffer([[1, 1, 1, 1, 1]])
        var prep = SamplePrep()
        prep.fadeOutFrames = 5
        let out = prep.apply(to: src).channels[0]
        XCTAssertEqual(out.first ?? -1, 1, accuracy: 1e-6, "fade-out starts at unity")
        XCTAssertEqual(out.last ?? -1, 0, accuracy: 1e-6, "fade-out ends at 0")
    }

    func testFadesClampWhenLongerThanBuffer() {
        let src = buffer([[1, 1, 1]])
        var prep = SamplePrep()
        prep.fadeInFrames = 100
        prep.fadeOutFrames = 100
        let out = prep.apply(to: src).channels[0]
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(out.allSatisfy { $0.isFinite }, "no out-of-bounds / NaN when fades exceed length")
    }

    // MARK: - Normalise (opt-in, honest on silence)

    func testNormalizeScalesPeakToMinusOneDbFS() {
        let src = buffer([[0.25, -0.1, 0.05], [0.2, -0.05, 0.1]])
        var prep = SamplePrep()
        prep.normalize = true   // default target −1 dBFS
        let out = prep.apply(to: src)
        let target = SamplePrep.decibelsToLinear(-1)  // ≈ 0.8913
        XCTAssertEqual(peak(out.channels), target, accuracy: 1e-4)
    }

    func testNormalizeOffLeavesLevelsUnchanged() {
        let src = buffer([[0.25, -0.1]])
        let out = SamplePrep().apply(to: src)
        XCTAssertEqual(out.channels[0], [0.25, -0.1])
    }

    func testNormalizeSilenceStaysSilentNoInventedGain() {
        let src = buffer([[0, 0, 0, 0]])
        var prep = SamplePrep()
        prep.normalize = true
        let out = prep.apply(to: src)
        XCTAssertEqual(out.channels[0], [0, 0, 0, 0], "silence is never amplified into invented signal")
    }

    // MARK: - Equal-power channel conversion

    func testEqualPowerMonoDownmixPreservesUncorrelatedPower() {
        // L and R uncorrelated (one hot per frame). Equal-power sum ÷√2.
        let src = buffer([[1, 0], [0, 1]])
        var prep = SamplePrep()
        prep.channelMode = .mono
        let out = prep.apply(to: src)
        XCTAssertEqual(out.channelCount, 1)
        let inv2 = 1 / sqrtf(2)
        XCTAssertEqual(out.channels[0][0], inv2, accuracy: 1e-6)
        XCTAssertEqual(out.channels[0][1], inv2, accuracy: 1e-6)
    }

    func testMonoDownmixIsNotNaiveDiscard() {
        // Naïve "keep channel 0" would give [1,1]; equal-power sum gives ≈1.414 (÷√2 of 2).
        let src = buffer([[1, 1], [1, 1]])
        var prep = SamplePrep()
        prep.channelMode = .mono
        let out = prep.apply(to: src)
        XCTAssertEqual(out.channels[0][0], sqrtf(2), accuracy: 1e-6)
    }

    func testMonoToStereoCopiesChannel() {
        let src = buffer([[0.3, -0.4]])
        var prep = SamplePrep()
        prep.channelMode = .stereo
        let out = prep.apply(to: src)
        XCTAssertEqual(out.channelCount, 2)
        XCTAssertEqual(out.channels[0], [0.3, -0.4])
        XCTAssertEqual(out.channels[1], [0.3, -0.4])
    }

    // MARK: - Treatment rate resolution

    func testOriginalPreservesCompatibleRateAndClampsAboveMax() {
        XCTAssertEqual(SampleTreatment.original.resolvedSampleRate(sourceSampleRate: 44_100), 44_100)
        XCTAssertEqual(SampleTreatment.original.resolvedSampleRate(sourceSampleRate: 48_000),
                       SampleTreatment.deviceMaxSampleRate, "above device max is clamped, never upsampled")
        XCTAssertEqual(SampleTreatment.original.resolvedSampleRate(sourceSampleRate: 22_050), 22_050)
    }

    func testFixedTreatmentRates() {
        XCTAssertEqual(SampleTreatment.high.resolvedSampleRate(sourceSampleRate: 44_100), 46_875)
        XCTAssertEqual(SampleTreatment.balanced.resolvedSampleRate(sourceSampleRate: 44_100), 32_000)
        XCTAssertEqual(SampleTreatment.loFi(.r22050).resolvedSampleRate(sourceSampleRate: 44_100), 22_050)
        XCTAssertEqual(SampleTreatment.loFi(.r11025).resolvedSampleRate(sourceSampleRate: 44_100), 11_025)
    }

    // MARK: - Predictable sizes across treatments (Phase 3 exit criterion)

    func testSameSourceDifferentTreatmentsReportPredictableSizes() {
        // 1 second stereo @ 44,100 Hz, no trim/channel change.
        let frames = 44_100, channels = 2, rate = 44_100.0
        let prep = SamplePrep.identity

        func est(_ t: SampleTreatment) -> SampleSizeEstimate {
            SampleMemoryEstimator.estimate(sourceFrameCount: frames, sourceChannelCount: channels,
                                           sourceSampleRate: rate, prep: prep, treatment: t)
        }

        XCTAssertEqual(est(.original).frames, 44_100)
        XCTAssertEqual(est(.original).payloadBytes, 44_100 * 2 * 2)
        XCTAssertEqual(est(.high).frames, 46_875)
        XCTAssertEqual(est(.high).payloadBytes, 46_875 * 2 * 2)
        XCTAssertEqual(est(.balanced).frames, 32_000)
        XCTAssertEqual(est(.balanced).payloadBytes, 32_000 * 2 * 2)
        XCTAssertEqual(est(.loFi(.r22050)).frames, 22_050)
        XCTAssertEqual(est(.loFi(.r22050)).payloadBytes, 22_050 * 2 * 2)
        XCTAssertEqual(est(.loFi(.r11025)).frames, 11_025)
        XCTAssertEqual(est(.loFi(.r11025)).payloadBytes, 11_025 * 2 * 2)

        // Monotonic: lower rate → fewer bytes.
        XCTAssertGreaterThan(est(.high).totalBytes, est(.balanced).totalBytes)
        XCTAssertGreaterThan(est(.balanced).totalBytes, est(.loFi(.r22050)).totalBytes)
        XCTAssertGreaterThan(est(.loFi(.r22050)).totalBytes, est(.loFi(.r11025)).totalBytes)
    }

    func testEstimateReflectsTrimAndMonoAndOverhead() {
        // Trim to half, mono downmix, BALANCED (32k) from 44.1k, 44-byte measured overhead.
        var prep = SamplePrep()
        prep.trimStartFrame = 0
        prep.trimEndFrame = 22_050            // half of 44,100 frames
        prep.channelMode = .mono
        let e = SampleMemoryEstimator.estimate(sourceFrameCount: 44_100, sourceChannelCount: 2,
                                               sourceSampleRate: 44_100, prep: prep,
                                               treatment: .balanced, containerOverhead: 44)
        XCTAssertEqual(e.channels, 1)
        // 22,050 src frames resampled 44.1k→32k → round(22050 * 32000/44100) = 16000.
        XCTAssertEqual(e.frames, 16_000)
        XCTAssertEqual(e.payloadBytes, 16_000 * 1 * 2)
        XCTAssertEqual(e.totalBytes, 16_000 * 1 * 2 + 44)
        XCTAssertEqual(e.sampleRate, 32_000)
    }

    // MARK: - Quantisation

    func testQuantizeInterleavedClampsAndInterleaves() {
        // Two channels, second value over full-scale to exercise the clamp.
        let q = SampleTreatmentEncoder.quantizeInterleaved([[0, 1.5], [-1.5, 0]], frames: 2)
        XCTAssertEqual(q.count, 4)
        XCTAssertEqual(q[0], 0)          // ch0 frame0
        XCTAssertEqual(q[1], -32767)     // ch1 frame0 clamped from −1.5
        XCTAssertEqual(q[2], 32767)      // ch0 frame1 clamped from +1.5
        XCTAssertEqual(q[3], 0)          // ch1 frame1
    }

    // MARK: - Offline encoder verified locally (real, decodable WAV)

    func testEncodeNoResampleMatchesEstimateAndRoundTrips() async throws {
        // ORIGINAL of a 32k stereo source: rate preserved, no resample.
        let n = 4_096
        let mono = (0..<n).map { sinf(2 * .pi * 8 * Float($0) / Float(n)) }
        let src = buffer([mono, mono], rate: 32_000)
        let encoded = try await SampleTreatmentEncoder.encode(src, treatment: .original)
        XCTAssertEqual(encoded.sampleRate, 32_000)
        XCTAssertEqual(encoded.channelCount, 2)
        XCTAssertEqual(encoded.frameCount, n, "no-resample encode preserves frame count")
        XCTAssertEqual(encoded.payloadBytes, n * 2 * 2)

        // Estimate agrees with the real encode.
        let est = SampleMemoryEstimator.estimate(sourceFrameCount: n, sourceChannelCount: 2,
                                                  sourceSampleRate: 32_000, prep: .identity,
                                                  treatment: .original)
        XCTAssertEqual(est.frames, encoded.frameCount)
        XCTAssertEqual(est.payloadBytes, encoded.payloadBytes)

        // Write and reopen: a real, decodable 16-bit WAV at the target format.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-prep-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SampleTreatmentEncoder.writeWAV(encoded, to: url)
        let reopened = try AVAudioFile(forReading: url)
        XCTAssertEqual(reopened.processingFormat.sampleRate, 32_000, accuracy: 1e-6)
        XCTAssertEqual(reopened.processingFormat.channelCount, 2)
        XCTAssertEqual(reopened.length, AVAudioFramePosition(n))
    }

    func testEncodeResampleDownToLoFiProducesTargetRate() async throws {
        // 44.1k → LO-FI 22,050: frame count ≈ half, target rate exact.
        let n = 8_820   // 0.2 s @ 44.1k
        let mono = (0..<n).map { sinf(2 * .pi * 20 * Float($0) / Float(n)) }
        let src = buffer([mono], rate: 44_100)
        let encoded = try await SampleTreatmentEncoder.encode(src, treatment: .loFi(.r22050))
        XCTAssertEqual(encoded.sampleRate, 22_050)
        XCTAssertEqual(encoded.channelCount, 1)
        // Deterministic: round(8820 * 22050/44100) = 4410.
        XCTAssertEqual(encoded.frameCount, 4_410)
        XCTAssertEqual(encoded.payloadBytes, 4_410 * 1 * 2)
    }

    func testEncodeEmptyBufferIsHonestZeroFrames() async throws {
        let src = buffer([[], []], rate: 44_100)
        let encoded = try await SampleTreatmentEncoder.encode(src, treatment: .high)
        XCTAssertEqual(encoded.frameCount, 0)
        XCTAssertTrue(encoded.interleaved.isEmpty)
        XCTAssertEqual(encoded.sampleRate, 46_875, "target rate still resolved for an empty source")
    }

    func testEncodeToWAVMeasuresContainerOverhead() async throws {
        let n = 1_000
        let src = buffer([[Float](repeating: 0.5, count: n)], rate: 32_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-prep-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let (encoded, overhead) = try await SampleTreatmentEncoder.encodeToWAV(
            src, treatment: .original, url: url)
        XCTAssertEqual(encoded.frameCount, n)
        // Overhead is the MEASURED file-minus-payload (WAV headers are > 0), not invented.
        XCTAssertGreaterThan(overhead, 0)
        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual((fileSize ?? 0) - encoded.payloadBytes, overhead)
    }
}
