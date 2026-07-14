import AVFoundation

/// A testable WAV file writer (Brief §7 Capture). Fully separable from threads and
/// rings: it takes interleaved stereo Float32 blocks and appends them to a real
/// LinearPCM `.wav` on disk (24-bit int), so the unit tests can feed it buffers
/// directly and reopen the file to verify duration/format.
///
/// THREADING: one-thread-at-a-time contract. In the app it is constructed on the
/// main actor and then touched ONLY by `RecordingDrain`'s thread (Brief §8 forbids
/// main-thread file I/O on the audio path — `AVAudioFile.write` runs off-main).
/// It is never called from the real-time render callback.
///
/// The WAV header is finalized when the last reference to the `AVAudioFile` drops,
/// so the owner must release the writer after the final drain before reopening the
/// file for metadata (see `RecordingDrain.finish`).
final class WAVFileWriter: @unchecked Sendable {
    private let file: AVAudioFile
    /// Preallocated non-interleaved Float32 scratch handed to `AVAudioFile.write`.
    private let pcm: AVAudioPCMBuffer
    private let maxFrames: AVAudioFrameCount
    private(set) var framesWritten: AVAudioFramePosition = 0
    let sampleRate: Double

    init(url: URL, sampleRate: Double, maxBlockFrames: Int = 4096) throws {
        self.sampleRate = sampleRate
        self.maxFrames = AVAudioFrameCount(max(1, maxBlockFrames))

        // On-disk format: interleaved 24-bit int LinearPCM → a standard .wav.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Processing (client) format we hand AVAudioFile: non-interleaved float; it
        // converts to the on-disk 24-bit int for us.
        guard let proc = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sampleRate, channels: 2, interleaved: false) else {
            throw WAVFileWriterError.formatUnavailable
        }
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: proc, frameCapacity: maxFrames) else {
            throw WAVFileWriterError.formatUnavailable
        }
        pcm = buffer
    }

    /// De-interleave `frames` of stereo Float32 from `src` and append. Chunked to
    /// `maxFrames` so an arbitrarily large block is written safely. `frames == 0`
    /// is a valid no-op (silent/absent robustness at the file layer).
    func write(interleaved src: UnsafePointer<Float>, frames: Int) throws {
        guard frames > 0 else { return }
        guard let ch = pcm.floatChannelData else { throw WAVFileWriterError.noChannelData }
        var offset = 0
        while offset < frames {
            let n = min(frames - offset, Int(maxFrames))
            for i in 0..<n {
                ch[0][i] = src[(offset + i) * 2]
                ch[1][i] = src[(offset + i) * 2 + 1]
            }
            pcm.frameLength = AVAudioFrameCount(n)
            try file.write(from: pcm)
            framesWritten += AVAudioFramePosition(n)
            offset += n
        }
    }
}

enum WAVFileWriterError: Error, Equatable {
    case formatUnavailable
    case noChannelData
}

/// Drain body extracted as a free function so the ring → writer path is unit-tested
/// deterministically WITHOUT spawning a thread. Reads up to `capacity` interleaved
/// floats from `ring` into `scratch`, then appends the whole (even) stereo run to
/// `writer`. Returns the number of stereo FRAMES written this call (0 on underrun —
/// the "silent/absent" drain is a safe no-op).
///
/// The ring only ever holds even (stereo-interleaved) counts because the producer
/// writes `frames * 2` at a time, so `got` is even and no straggler sample is lost.
@discardableResult
func drainAvailable(ring: AudioRingBuffer,
                    scratch: UnsafeMutablePointer<Float>,
                    capacity: Int,
                    writer: WAVFileWriter) throws -> Int {
    let got = ring.read(into: scratch, count: capacity)
    guard got > 0 else { return 0 }
    let frames = got / 2
    if frames > 0 {
        try writer.write(interleaved: scratch, frames: frames)
    }
    return frames
}
