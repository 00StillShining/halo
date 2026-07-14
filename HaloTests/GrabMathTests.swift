import AVFoundation
import XCTest
@testable import Halo

/// Pins the pure GRAB core (Brief §5b): bar-window arithmetic, zero-cross trim, the
/// reference BPM estimate, the filename/title round-trip, the `TakeKind` parse, and
/// the rolling-buffer write→snapshot + floor gating. All deterministic and hardware-
/// free — the honesty-critical math is provable without the device.
final class GrabMathTests: XCTestCase {

    // MARK: - barWindow

    func testBarWindowIsExactWholeBarsEndingAtDownbeat() {
        let sr = 48_000.0, bpm = 120.0
        let perBar = Int((sr * 60.0 / bpm).rounded()) * 4   // 96_000 frames / bar
        let down = 1_000_000
        let w = GrabMath.barWindow(sampleRate: sr, bpm: bpm, beatsPerBar: 4, bars: 8,
                                   lastDownbeatFrame: down, oldestResident: 0)
        XCTAssertEqual(w.endFrame, down)
        XCTAssertEqual(w.bars, 8)
        XCTAssertEqual(w.endFrame - w.startFrame, 8 * perBar)
    }

    func testBarWindowReducesBarCountWhenHistoryIsShort() {
        let sr = 48_000.0, bpm = 120.0
        let perBar = 96_000
        let down = 1_000_000
        // Only ~10 bars of history are resident.
        let oldest = down - 10 * perBar - 5_000
        let w = GrabMath.barWindow(sampleRate: sr, bpm: bpm, beatsPerBar: 4, bars: 16,
                                   lastDownbeatFrame: down, oldestResident: oldest)
        XCTAssertEqual(w.bars, 10)
        XCTAssertEqual(w.endFrame - w.startFrame, 10 * perBar)
        XCTAssertGreaterThanOrEqual(w.startFrame, oldest)
    }

    func testBarWindowClampsToFloorWhenEvenOneBarIsTight() {
        let sr = 48_000.0, bpm = 90.0
        let down = 500_000
        // Not even a single bar of history: reduction drives bars to 0 (empty window).
        let oldest = down - 1_000
        let w = GrabMath.barWindow(sampleRate: sr, bpm: bpm, beatsPerBar: 4, bars: 8,
                                   lastDownbeatFrame: down, oldestResident: oldest)
        XCTAssertEqual(w.bars, 0)
        XCTAssertEqual(w.startFrame, w.endFrame)   // nothing to grab
    }

    // MARK: - secondsWindow

    func testSecondsWindowIsExactFrameCount() {
        let sr = 48_000.0
        let now = 1_000_000
        let w = GrabMath.secondsWindow(sampleRate: sr, seconds: 10, now: now, oldestResident: 0)
        XCTAssertEqual(w.endFrame, now)
        XCTAssertEqual(w.bars, 0)
        XCTAssertEqual(w.endFrame - w.startFrame, 480_000)
    }

    func testSecondsWindowClampsToResidentHistory() {
        let sr = 48_000.0
        let now = 1_000_000
        let oldest = 600_000
        let w = GrabMath.secondsWindow(sampleRate: sr, seconds: 10, now: now, oldestResident: oldest)
        XCTAssertEqual(w.startFrame, oldest)   // 520_000 would reach before the floor
        XCTAssertEqual(w.endFrame - w.startFrame, 400_000)
    }

    // MARK: - snapToZeroCrossing

    /// Sawtooth ramping −1→+1 over `period`, resetting sharply. Rising (neg→pos)
    /// crossings fall exactly at `i % period == period/2` — deterministic in Float
    /// (unlike a sine's fragile value right at the zero crossing), and the sharp
    /// reset is a falling edge the snapper must ignore.
    private func sawtooth(period: Int, count: Int) -> [Float] {
        (0..<count).map { Float($0 % period) / Float(period) * 2 - 1 }
    }

    func testSnapLandsOnRisingCrossingWithinRadius() {
        let mono = sawtooth(period: 480, count: 2_400)   // rising crossings at 240, 720…
        let target = 250
        let idx = GrabMath.snapToZeroCrossing(mono, target: target, radius: 60)
        XCTAssertEqual(idx, 240)
        XCTAssertLessThan(mono[idx - 1], 0)
        XCTAssertGreaterThanOrEqual(mono[idx], 0)   // rising slope, not the reset edge
        XCTAssertLessThanOrEqual(abs(idx - target), 60)
    }

    func testSnapReturnsTargetWhenNoCrossingInWindow() {
        // A strictly positive ramp has no neg→pos crossing anywhere.
        let mono = (0..<1_000).map { 0.1 + Float($0) / 1_000 }
        let target = 500
        XCTAssertEqual(GrabMath.snapToZeroCrossing(mono, target: target, radius: 40), target)
    }

    func testSnapBothEndsUseSameSlopeForSeamlessLoop() {
        let n = 4_800
        let mono = sawtooth(period: 480, count: n)
        let start = GrabMath.snapToZeroCrossing(mono, target: 250, radius: 60)
        let end = GrabMath.snapToZeroCrossing(mono, target: n, radius: 300)
        // Both ends rising ⇒ the loop seam matches sign+slope (click-free).
        XCTAssertTrue(mono[start - 1] < 0 && mono[start] >= 0)
        XCTAssertTrue(mono[end - 1] < 0 && mono[end] >= 0)
    }

    // MARK: - estimateBPM

    func testEstimateBPMOnImpulseTrainMatchesTempo() {
        let sr = 48_000.0
        let seconds = 6
        let n = Int(sr) * seconds
        var mono = [Float](repeating: 0, count: n)
        let period = Int(sr / 2)   // 0.5 s → 120 BPM
        var t = 0
        while t < n {
            for k in 0..<64 where t + k < n { mono[t + k] = 1.0 }   // short click
            t += period
        }
        let bpm = GrabMath.estimateBPM(mono: mono, sampleRate: sr)
        XCTAssertNotNil(bpm)
        XCTAssertEqual(bpm ?? 0, 120, accuracy: 3)
    }

    func testEstimateBPMReturnsNilForFlatSignal() {
        let sr = 48_000.0
        let mono = [Float](repeating: 0, count: Int(sr) * 2)   // silence → no onsets
        XCTAssertNil(GrabMath.estimateBPM(mono: mono, sampleRate: sr))
    }

    // MARK: - filename / title round-trip

    func testFilenameAndTitleRoundTripClocked() {
        let date = Date(timeIntervalSince1970: 1_752_400_000)
        let name = GrabMath.filename(kind: .barsClocked(bars: 8, bpm: 92), date: date)
        XCTAssertTrue(name.hasPrefix("grab-"))
        XCTAssertTrue(name.hasSuffix("-08bars-92bpm.wav"))
        let title = GrabMath.title(fromFilename: name)
        XCTAssertNotNil(title)
        XCTAssertTrue(title!.hasPrefix("GRAB · "))
        XCTAssertTrue(title!.contains("8 BARS"))
        XCTAssertTrue(title!.contains("92 BPM"))
    }

    func testFilenameAndTitleRoundTripUnclockedWithEstimate() {
        let date = Date(timeIntervalSince1970: 1_752_400_000)
        let name = GrabMath.filename(kind: .secondsUnclocked(seconds: 10, estBPM: 92), date: date)
        XCTAssertTrue(name.hasSuffix("-10s-est92bpm.wav"))
        let title = GrabMath.title(fromFilename: name)
        XCTAssertNotNil(title)
        XCTAssertTrue(title!.contains("10 S"))
        XCTAssertTrue(title!.contains("~92 BPM (EST)"))
    }

    func testFilenameAndTitleRoundTripUnclockedNoEstimate() {
        let date = Date(timeIntervalSince1970: 1_752_400_000)
        let name = GrabMath.filename(kind: .secondsUnclocked(seconds: 30, estBPM: nil), date: date)
        XCTAssertTrue(name.hasSuffix("-30s.wav"))
        let title = GrabMath.title(fromFilename: name)
        XCTAssertNotNil(title)
        XCTAssertTrue(title!.contains("30 S"))
        XCTAssertFalse(title!.contains("BPM"))
    }

    func testTitleReturnsNilForNonGrabFilename() {
        XCTAssertNil(GrabMath.title(fromFilename: "take-2026-07-13-2142-07.wav"))
    }

    // MARK: - TakesStore.readTake sets grab kind + parsed title

    func testReadTakeParsesGrabKindAndTitleFromFilename() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-grab-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("grab-2026-07-13-2142-07-08bars-92bpm.wav")
        var writer: WAVFileWriter? = try WAVFileWriter(url: url, sampleRate: 48_000)
        let frames = 24_000
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { samples[i * 2] = 0.1; samples[i * 2 + 1] = -0.1 }
        try samples.withUnsafeBufferPointer { try writer!.write(interleaved: $0.baseAddress!, frames: frames) }
        writer = nil

        let take = try XCTUnwrap(TakesStore.readTake(url))
        XCTAssertEqual(take.kind, .grab)
        XCTAssertTrue(take.title.contains("8 BARS"))
        XCTAssertTrue(take.title.contains("92 BPM"))
    }

    func testReadTakeMarksNonGrabFileAsSession() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-grab-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("take-2026-07-13-2142-07.wav")
        var writer: WAVFileWriter? = try WAVFileWriter(url: url, sampleRate: 48_000)
        let frames = 4_800
        let samples = [Float](repeating: 0.05, count: frames * 2)
        try samples.withUnsafeBufferPointer { try writer!.write(interleaved: $0.baseAddress!, frames: frames) }
        writer = nil

        let take = try XCTUnwrap(TakesStore.readTake(url))
        XCTAssertEqual(take.kind, .session)
        XCTAssertTrue(take.title.hasPrefix("TAKE · "))
    }

    // MARK: - RollingCaptureBuffer write → snapshot over a wrap + floor gating

    func testRollingBufferSnapshotRoundTripsAcrossWrap() {
        // seconds:0.1 @ 48k → wantFrames 4800 → capacity 8192 frames.
        let buffer = RollingCaptureBuffer(seconds: 0.1, referenceRate: 48_000)
        XCTAssertEqual(buffer.capacityFrames, 8_192)

        // Write 10_000 frames (> capacity ⇒ one wrap). Frame f: L = f, R = f + 0.5.
        let total = 10_000
        var src = [Float](repeating: 0, count: total * 2)
        for f in 0..<total { src[f * 2] = Float(f); src[f * 2 + 1] = Float(f) + 0.5 }
        src.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: total) }
        XCTAssertEqual(buffer.nowFrame, total)

        // Snapshot a window straddling the wrap boundary at frame 8192.
        let startF = 6_000, endF = 9_000
        var dst = [Float](repeating: -1, count: (endF - startF) * 2)
        XCTAssertTrue(buffer.snapshot(startFrame: startF, endFrame: endF, into: &dst))
        for probe in [0, 2_192, 2_999] {   // 6000, 8192 (wrap), 8999
            let f = startF + probe
            XCTAssertEqual(dst[probe * 2], Float(f), accuracy: 0.001)
            XCTAssertEqual(dst[probe * 2 + 1], Float(f) + 0.5, accuracy: 0.001)
        }
    }

    func testRollingBufferFloorGatesPreviousSession() {
        let buffer = RollingCaptureBuffer(seconds: 0.1, referenceRate: 48_000)
        let total = 10_000
        var src = [Float](repeating: 0.25, count: total * 2)
        src.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: total) }

        // A new session floor at the current head must refuse a window from before it.
        buffer.resetSession()
        XCTAssertEqual(buffer.floor, total)
        var dst = [Float](repeating: 0, count: 3_000 * 2)
        XCTAssertFalse(buffer.snapshot(startFrame: 6_000, endFrame: 9_000, into: &dst))
    }
}
