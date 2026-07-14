import AVFoundation
import XCTest
@testable import Halo

/// Pins the WAV writer used by the session recorder (Brief §7). The writer is the
/// unit-tested unit of the recorder: a written file must reopen and match the
/// expected stereo duration/format, and silent/short-block writes must be safe.
final class WAVFileWriterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-wav-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func url(_ name: String) -> URL {
        tempDir.appendingPathComponent(name)
    }

    /// A stereo ramp: L rises, R falls, `frames` frames interleaved.
    private func ramp(frames: Int) -> [Float] {
        var buf = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let t = Float(i) / Float(max(1, frames))
            buf[i * 2] = t * 0.5
            buf[i * 2 + 1] = (1 - t) * -0.5
        }
        return buf
    }

    func testWrittenWAVReopensWithExpectedStereoDurationAndFormat() throws {
        let out = url("two-seconds.wav")
        let frames = 96_000                 // 2.0 s @ 48 kHz
        let samples = ramp(frames: frames)

        var writer: WAVFileWriter? = try WAVFileWriter(url: out, sampleRate: 48_000)
        try samples.withUnsafeBufferPointer {
            try writer!.write(interleaved: $0.baseAddress!, frames: frames)
        }
        XCTAssertEqual(writer!.framesWritten, AVAudioFramePosition(frames))
        writer = nil                        // drop → finalize the WAV header

        let read = try AVAudioFile(forReading: out)
        XCTAssertEqual(read.fileFormat.channelCount, 2)
        XCTAssertEqual(read.fileFormat.sampleRate, 48_000, accuracy: 0.5)
        XCTAssertEqual(Double(read.length) / read.fileFormat.sampleRate, 2.0, accuracy: 0.01)
        XCTAssertEqual(out.pathExtension, "wav")
    }

    func testZeroFrameAndShortBlockWritesAreSafe() throws {
        let out = url("short.wav")
        var writer: WAVFileWriter? = try WAVFileWriter(url: out, sampleRate: 48_000)

        // A single scratch buffer serves both writes; frames:0 must be a no-op that
        // never dereferences the pointer (silent/absent robustness).
        let ten = ramp(frames: 10)
        try ten.withUnsafeBufferPointer { ptr in
            try writer!.write(interleaved: ptr.baseAddress!, frames: 0)   // no-op
            try writer!.write(interleaved: ptr.baseAddress!, frames: 10)  // sub-block
        }
        XCTAssertEqual(writer!.framesWritten, 10)
        writer = nil

        let read = try AVAudioFile(forReading: out)
        XCTAssertEqual(read.length, 10)
        XCTAssertEqual(read.fileFormat.channelCount, 2)
    }

    func testSampleRateIsHonoredNotHardcoded() throws {
        let out = url("rate.wav")
        let frames = 44_100                 // 1.0 s @ 44.1 kHz
        let samples = ramp(frames: frames)

        var writer: WAVFileWriter? = try WAVFileWriter(url: out, sampleRate: 44_100)
        try samples.withUnsafeBufferPointer {
            try writer!.write(interleaved: $0.baseAddress!, frames: frames)
        }
        writer = nil

        let read = try AVAudioFile(forReading: out)
        XCTAssertEqual(read.fileFormat.sampleRate, 44_100, accuracy: 0.5)
        XCTAssertEqual(Double(read.length) / read.fileFormat.sampleRate, 1.0, accuracy: 0.01)
    }
}
