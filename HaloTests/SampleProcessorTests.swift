import AVFoundation
import XCTest
@testable import Halo

/// Pins local sample import (Brief §8): decode into the canonical float buffer,
/// min/max waveform bucketing, and the device-byte estimate. All LOCAL — a
/// generated on-disk fixture, no device.
final class SampleProcessorTests: XCTestCase {

    // MARK: - Fixture generation

    /// Write a real `.wav` fixture of a known signal to a temp URL and return it.
    /// `signal` supplies the mono sample for a frame; it is duplicated to `channels`
    /// so the decode/mono-mixdown paths see a real multi-channel file.
    private func writeWAVFixture(frames: Int,
                                 sampleRate: Double,
                                 channels: Int,
                                 signal: (Int) -> Float) throws -> URL {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let procFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sampleRate,
                                       channels: AVAudioChannelCount(channels),
                                       interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-fixture-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let cap = AVAudioFrameCount(frames)
        let buf = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: cap)!
        buf.frameLength = cap
        let data = buf.floatChannelData!
        for i in 0..<frames {
            let v = signal(i)
            for c in 0..<channels { data[c][i] = v }
        }
        try file.write(from: buf)
        return url
    }

    override func tearDownWithError() throws {
        // Best-effort cleanup of temp fixtures.
        let tmp = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: tmp,
            includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix("halo-fixture-") {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: - Decode

    func testDecodePreservesRateChannelsAndFrames() async throws {
        let frames = 4_096
        let rate = 44_100.0
        // Full-scale ramp -1 → +1 across the file.
        let url = try writeWAVFixture(frames: frames, sampleRate: rate, channels: 2) { i in
            -1 + 2 * Float(i) / Float(frames - 1)
        }
        let buffer = try await SampleProcessor.decode(url: url)
        XCTAssertEqual(buffer.sampleRate, rate, accuracy: 1e-6)
        XCTAssertEqual(buffer.channelCount, 2)
        XCTAssertEqual(buffer.frameCount, frames)
        // Endpoints of the ramp survive the round-trip (16-bit quantisation tolerance).
        XCTAssertEqual(buffer.channels[0].first ?? 0, -1, accuracy: 1e-3)
        XCTAssertEqual(buffer.channels[0].last ?? 0, 1, accuracy: 1e-3)
    }

    func testDecodeChunkBoundaryLongFile() async throws {
        // Longer than one read chunk so the chunked accumulation path is exercised.
        let frames = Int(SampleProcessor.readChunkFrames) + 777
        let url = try writeWAVFixture(frames: frames, sampleRate: 48_000, channels: 1) { i in
            (i % 2 == 0) ? 0.5 : -0.5
        }
        let buffer = try await SampleProcessor.decode(url: url)
        XCTAssertEqual(buffer.frameCount, frames, "no frames lost across chunk boundary")
        XCTAssertEqual(buffer.channelCount, 1)
    }

    func testUnsupportedExtensionRejectedBeforeDisk() async {
        let url = URL(fileURLWithPath: "/nonexistent/file.flac")
        do {
            _ = try await SampleProcessor.decode(url: url)
            XCTFail("expected rejection")
        } catch let e as SampleProcessorError {
            XCTAssertEqual(e, .unsupportedFormat("flac"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testUnreadableSupportedFileThrows() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-fixture-missing.wav")
        do {
            _ = try await SampleProcessor.decode(url: url)
            XCTFail("expected unreadable")
        } catch let e as SampleProcessorError {
            XCTAssertEqual(e, .unreadable)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testIsSupportedAcceptList() {
        for ext in ["wav", "aif", "aiff", "caf", "mp3", "m4a", "WAV", "M4A"] {
            XCTAssertTrue(SampleProcessor.isSupported(URL(fileURLWithPath: "/x.\(ext)")), ext)
        }
        for ext in ["flac", "ogg", "txt", ""] {
            XCTAssertFalse(SampleProcessor.isSupported(URL(fileURLWithPath: "/x.\(ext)")), ext)
        }
    }

    // MARK: - Import (asset + buffer)

    func testImportBuildsAssetWithSummary() async throws {
        let frames = 10_000
        let url = try writeWAVFixture(frames: frames, sampleRate: 32_000, channels: 2) { i in
            sin(2 * .pi * 4 * Float(i) / Float(frames))
        }
        let (asset, buffer) = try await SampleProcessor.importSample(
            url: url, summaryBuckets: 256,
            importedAt: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(asset.format, .wav)
        XCTAssertEqual(asset.sampleRate, 32_000, accuracy: 1e-6)
        XCTAssertEqual(asset.channelCount, 2)
        XCTAssertEqual(asset.frameCount, frames)
        XCTAssertEqual(asset.frameCount, buffer.frameCount)
        XCTAssertEqual(asset.summary.bucketCount, 256)
        XCTAssertEqual(asset.durationSeconds, Double(frames) / 32_000, accuracy: 1e-6)
        // Full-scale sine → summary peak near 1.
        XCTAssertEqual(asset.summary.peakMagnitude, 1, accuracy: 2e-2)
    }

    // MARK: - Waveform bucketing (pure math)

    func testBucketingMinMaxPerBucket() {
        // 8 samples, 4 buckets → perBucket 2. Known extrema per pair.
        let mono: [Float] = [0.1, -0.2, 0.9, 0.3, -0.8, -0.4, 0.5, 0.5]
        let s = WaveformSummary.build(mono: mono, targetBuckets: 4)
        XCTAssertEqual(s.bucketCount, 4)
        XCTAssertEqual(s.framesPerBucket, 2)
        XCTAssertEqual(s.minima, [-0.2, 0.3, -0.8, 0.5])
        XCTAssertEqual(s.maxima, [0.1, 0.9, -0.4, 0.5])
    }

    func testBucketingCeilDivideTilesWholeSignal() {
        // 7 samples, 3 buckets → perBucket ceil(7/3)=3 → windows [0..2],[3..5],[6].
        let mono: [Float] = [1, 2, 3, 4, 5, 6, 7]
        let s = WaveformSummary.build(mono: mono, targetBuckets: 3)
        XCTAssertEqual(s.bucketCount, 3)
        XCTAssertEqual(s.framesPerBucket, 3)
        XCTAssertEqual(s.minima, [1, 4, 7])
        XCTAssertEqual(s.maxima, [3, 6, 7], "last short bucket still summarised")
    }

    func testBucketingNeverMoreBucketsThanFrames() {
        let mono: [Float] = [0.5, -0.5, 0.25]
        let s = WaveformSummary.build(mono: mono, targetBuckets: 512)
        XCTAssertEqual(s.bucketCount, 3, "one bucket per frame, none invented")
        XCTAssertEqual(s.minima, mono)
        XCTAssertEqual(s.maxima, mono)
    }

    func testBucketingEmptySignalIsEmptySummary() {
        let s = WaveformSummary.build(mono: [], targetBuckets: 64)
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.bucketCount, 0)
        XCTAssertEqual(s.sourceFrameCount, 0)
    }

    func testPeakMagnitudeFromTroughOrCrest() {
        let s = WaveformSummary.build(mono: [0.1, -0.95, 0.4, 0.2], targetBuckets: 4)
        XCTAssertEqual(s.peakMagnitude, 0.95, accuracy: 1e-6, "deepest trough counts as peak")
    }

    // MARK: - Mono mixdown

    func testMonoMixdownEqualAverageNotDiscard() {
        // L=+1, R=-1 → average 0 (a naïve discard would show ±1).
        let buffer = CanonicalAudioBuffer(channels: [[1, 1], [-1, -1]], sampleRate: 48_000)
        XCTAssertEqual(buffer.monoMixdown(), [0, 0])
    }

    func testMonoMixdownSingleChannelPassthrough() {
        let buffer = CanonicalAudioBuffer(channels: [[0.3, -0.7]], sampleRate: 48_000)
        XCTAssertEqual(buffer.monoMixdown(), [0.3, -0.7])
    }

    // MARK: - Memory estimate

    func testMemoryPayloadFormula() {
        // frames × channels × 2.
        XCTAssertEqual(SampleMemoryEstimator.payloadBytes(frames: 1_000, channels: 2), 4_000)
        XCTAssertEqual(SampleMemoryEstimator.payloadBytes(frames: 1_000, channels: 1), 2_000)
    }

    func testMemoryEstimateAddsMeasuredOverhead() {
        let bytes = SampleMemoryEstimator.estimatedBytes(frames: 100, channels: 2, containerOverhead: 44)
        XCTAssertEqual(bytes, 100 * 2 * 2 + 44)
    }

    func testMemoryEstimateForAssetDefaultsToPayload() {
        let asset = SampleAsset.previewFixture("x", mono: [Float](repeating: 0, count: 500), channels: 2)
        XCTAssertEqual(SampleMemoryEstimator.estimatedBytes(for: asset), 500 * 2 * 2)
    }
}
