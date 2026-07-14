import AVFoundation
import XCTest
@testable import Halo

/// Pins the recorder's ring → writer drain path (P2-recorder) WITHOUT racing the
/// live drain thread: it drives the SPSC ring synchronously through the extracted
/// `drainAvailable` free function, exactly the body the drain thread runs. Proves
/// the full raw-capture path (write → drain → file) and its silent/underrun safety.
final class CaptureTapTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-tap-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testRingDrainsToWriterAndFileMatches() throws {
        let tap = CaptureTap()
        let out = tempDir.appendingPathComponent("tap.wav")
        var writer: WAVFileWriter? = try WAVFileWriter(url: out, sampleRate: 48_000)

        // Producer side: write N interleaved floats (N/2 stereo frames).
        let frames = 24_000                 // 0.5 s @ 48k
        let n = frames * 2
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<frames {
            samples[i * 2] = Float(i % 100) / 100
            samples[i * 2 + 1] = -Float(i % 100) / 100
        }
        _ = samples.withUnsafeBufferPointer { tap.ring.write($0.baseAddress!, count: n) }

        // Consumer side: drain in chunks exactly as the drain thread does.
        let capacity = 8192
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        defer { scratch.deallocate() }
        var drainedFrames = 0
        while true {
            let got = try drainAvailable(ring: tap.ring, scratch: scratch,
                                         capacity: capacity, writer: writer!)
            if got == 0 { break }
            drainedFrames += got
        }
        XCTAssertEqual(drainedFrames, frames)
        XCTAssertEqual(writer!.framesWritten, AVAudioFramePosition(frames))
        writer = nil

        let read = try AVAudioFile(forReading: out)
        XCTAssertEqual(read.fileFormat.channelCount, 2)
        XCTAssertEqual(read.length, AVAudioFramePosition(frames))
    }

    func testUnderrunDrainIsSafeNoOp() throws {
        let tap = CaptureTap()
        let out = tempDir.appendingPathComponent("empty.wav")
        var writer: WAVFileWriter? = try WAVFileWriter(url: out, sampleRate: 48_000)

        let capacity = 8192
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        defer { scratch.deallocate() }

        // Empty ring → nothing drained, nothing written, no crash.
        let got = try drainAvailable(ring: tap.ring, scratch: scratch,
                                     capacity: capacity, writer: writer!)
        XCTAssertEqual(got, 0)
        XCTAssertEqual(writer!.framesWritten, 0)
        writer = nil

        let read = try AVAudioFile(forReading: out)
        XCTAssertEqual(read.length, 0, "an honestly-silent take is a valid empty WAV")
    }

    func testDrainReadTakeRoundTripsMetadata() throws {
        // Write a real WAV, then prove TakesStore.readTake decodes honest metadata.
        let out = tempDir.appendingPathComponent("meta.wav")
        let frames = 48_000                 // 1.0 s @ 48k
        var writer: WAVFileWriter? = try WAVFileWriter(url: out, sampleRate: 48_000)
        var samples = [Float](repeating: 0.1, count: frames * 2)
        try samples.withUnsafeMutableBufferPointer {
            try writer!.write(interleaved: $0.baseAddress!, frames: frames)
        }
        writer = nil

        let take = try XCTUnwrap(TakesStore.readTake(out))
        XCTAssertEqual(take.channels, 2)
        XCTAssertEqual(take.sampleRate, 48_000)
        XCTAssertEqual(take.durationSeconds, 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(take.bytes, 0)
        XCTAssertEqual(take.url, out)
    }

    func testReadTakeRejectsUnreadableFile() throws {
        // A non-audio file must not become an invented take (Brief §1/§4).
        let bogus = tempDir.appendingPathComponent("notaudio.wav")
        try Data("this is not a wav".utf8).write(to: bogus)
        XCTAssertNil(TakesStore.readTake(bogus))
    }
}
