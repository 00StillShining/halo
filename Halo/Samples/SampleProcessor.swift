import AVFoundation
import Foundation

/// The canonical internal audio representation for imported samples (Brief §8
/// "Decode into a canonical internal floating-point buffer for editing").
///
/// Non-interleaved, deinterleaved Float32 per channel, at the source's own sample
/// rate. This is the single format every edit/summary/export stage reads from — the
/// container/codec of the file on disk is decoded away exactly once, here, off the
/// main actor. It is a plain value type (Sendable) so it can cross actor boundaries
/// without locks.
///
/// HONESTY (Brief §1/§4): every field is measured from the real decoded file. There
/// is no invented audio, no synthesized rate, no assumed channel count.
struct CanonicalAudioBuffer: Sendable, Equatable {
    /// One Float32 array per channel, each `frameCount` long. `channels.count` is
    /// the real channel count; `channels[c].count == frameCount` for every c.
    let channels: [[Float]]
    /// The file's own sample rate, preserved (Brief §8 "Preserve the original
    /// sample rate when compatible"). Any rate conversion is a later, explicit step.
    let sampleRate: Double

    var channelCount: Int { channels.count }
    var frameCount: Int { channels.first?.count ?? 0 }
    var durationSeconds: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// Equal-average mono mixdown (Brief §8 forbids naïve channel discard). Mono
    /// buffers return their single channel unchanged; silence/absent → empty.
    func monoMixdown() -> [Float] {
        guard let first = channels.first else { return [] }
        if channels.count == 1 { return first }
        let n = first.count
        var out = [Float](repeating: 0, count: n)
        let scale = 1.0 / Float(channels.count)
        for ch in channels {
            // ch.count == n by construction; guard defensively anyway.
            let m = min(n, ch.count)
            for i in 0..<m { out[i] += ch[i] * scale }
        }
        return out
    }
}

/// The container/codec family of an imported file. Membership here is the accept
/// list (Brief §8 "Accept WAV, AIFF, CAF, MP3 and M4A. Add another format only
/// after a real import test."). Extension is a fast pre-filter; the real decode is
/// still performed by `AVAudioFile`, which is the source of truth for whether the
/// bytes are actually decodable.
enum SampleSourceFormat: String, Sendable, Equatable, CaseIterable {
    case wav = "WAV"
    case aiff = "AIFF"
    case caf = "CAF"
    case mp3 = "MP3"
    case m4a = "M4A"

    /// Map a file extension to a supported format, or nil if unsupported.
    init?(pathExtension ext: String) {
        switch ext.lowercased() {
        case "wav", "wave": self = .wav
        case "aif", "aiff", "aifc": self = .aiff
        case "caf": self = .caf
        case "mp3": self = .mp3
        case "m4a", "aac", "mp4": self = .m4a
        default: return nil
        }
    }
}

enum SampleProcessorError: Error, Equatable {
    /// Extension is not in the Brief §8 accept list.
    case unsupportedFormat(String)
    /// `AVAudioFile` opened but the format is unusable (0 Hz / 0 channels).
    case undecodableFormat
    /// The file could not be opened/read at all (missing, corrupt, permissions).
    case unreadable
}

/// Local sample import (Brief §8 sample processing). ALL LOCAL — no device, no
/// protocol, no network. Decoding runs off the main actor: every entry point is a
/// non-isolated `async` function, so `AVAudioFile`'s blocking reads execute on the
/// cooperative pool, never on `@MainActor` (Brief §2 "File conversion, waveform
/// generation and onset detection run off the main actor").
enum SampleProcessor {

    /// Read-in chunk size. Bounds peak scratch memory while decoding an arbitrarily
    /// long file; the whole file still lands in the canonical buffer.
    static let readChunkFrames: AVAudioFrameCount = 65_536

    /// Whether a URL's extension is on the accept list. Cheap pre-check for UI
    /// (drag-drop highlight, file-picker filter) that does not touch disk.
    static func isSupported(_ url: URL) -> Bool {
        SampleSourceFormat(pathExtension: url.pathExtension) != nil
    }

    /// Decode a supported file into the canonical float buffer, off the main actor.
    /// Throws `.unsupportedFormat` before touching disk for a rejected extension,
    /// `.unreadable` if the file cannot be opened, `.undecodableFormat` if the
    /// opened format is unusable.
    static func decode(url: URL) async throws -> CanonicalAudioBuffer {
        guard SampleSourceFormat(pathExtension: url.pathExtension) != nil else {
            throw SampleProcessorError.unsupportedFormat(url.pathExtension)
        }
        return try decodeSynchronously(url: url)
    }

    /// Decode + build the lightweight `SampleAsset` (metadata + waveform summary)
    /// AND return the heavy canonical buffer, in one pass off the main actor. The
    /// UI keeps the small `SampleAsset`; the editor holds the buffer. Splitting the
    /// two keeps `@Observable` UI models cheap to diff.
    static func importSample(url: URL,
                             summaryBuckets: Int = WaveformSummary.defaultBucketCount,
                             importedAt: Date = Date()) async throws
        -> (asset: SampleAsset, buffer: CanonicalAudioBuffer) {
        guard let format = SampleSourceFormat(pathExtension: url.pathExtension) else {
            throw SampleProcessorError.unsupportedFormat(url.pathExtension)
        }
        let buffer = try decodeSynchronously(url: url)
        let summary = WaveformSummary.build(from: buffer, targetBuckets: summaryBuckets)
        let asset = SampleAsset(
            id: UUID(),
            sourceURL: url,
            displayName: url.deletingPathExtension().lastPathComponent,
            format: format,
            sampleRate: buffer.sampleRate,
            channelCount: buffer.channelCount,
            frameCount: buffer.frameCount,
            summary: summary,
            importedAt: importedAt)
        return (asset, buffer)
    }

    // MARK: - Blocking core

    /// The actual `AVAudioFile` read. Blocking; only ever reached from an `async`
    /// entry point above (hence off `@MainActor`). Extracted so tests can exercise
    /// the decode directly and so both public entry points share one implementation.
    private static func decodeSynchronously(url: URL) throws -> CanonicalAudioBuffer {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SampleProcessorError.unreadable
        }

        // `processingFormat` is deinterleaved Float32 for every container AVAudioFile
        // supports — this is where MP3/M4A become linear PCM.
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard sampleRate > 0, channelCount > 0 else {
            throw SampleProcessorError.undecodableFormat
        }

        let totalFrames = file.length
        guard totalFrames > 0 else {
            // A real, decodable, but empty file: honest zero-length buffer, not an error.
            return CanonicalAudioBuffer(
                channels: Array(repeating: [Float](), count: channelCount),
                sampleRate: sampleRate)
        }

        var channels = [[Float]](repeating: [Float](), count: channelCount)
        for c in 0..<channelCount { channels[c].reserveCapacity(Int(totalFrames)) }

        guard let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readChunkFrames) else {
            throw SampleProcessorError.undecodableFormat
        }

        while file.framePosition < totalFrames {
            scratch.frameLength = 0
            do {
                try file.read(into: scratch, frameCount: readChunkFrames)
            } catch {
                throw SampleProcessorError.unreadable
            }
            let got = Int(scratch.frameLength)
            if got == 0 { break }
            guard let data = scratch.floatChannelData else {
                throw SampleProcessorError.undecodableFormat
            }
            for c in 0..<channelCount {
                let src = data[c]
                channels[c].append(contentsOf: UnsafeBufferPointer(start: src, count: got))
            }
        }

        return CanonicalAudioBuffer(channels: channels, sampleRate: sampleRate)
    }
}
