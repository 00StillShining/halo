import AVFoundation
import XCTest
@testable import Halo

/// Pins EDIT-mode state (Brief §7, DD-022): local import + cache-of-1 selection,
/// per-asset non-destructive prep, the wired memory estimate, the Space-audition gate,
/// and the pure `WaveformStrip` geometry. All LOCAL — generated on-disk fixtures, no
/// device. `AuditionPlayer` engine playback is untested (needs a real output → needsDevice),
/// but its pure `makeBuffer` is covered here.
@MainActor
final class EditSessionTests: XCTestCase {

    // MARK: - Fixture generation (mirrors SampleProcessorTests)

    private var fixtureURLs: [URL] = []

    private func writeWAVFixture(frames: Int, sampleRate: Double, channels: Int,
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
            .appendingPathComponent("halo-fixture-edit-\(UUID().uuidString).wav")
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
        fixtureURLs.append(url)
        return url
    }

    override func tearDown() {
        for url in fixtureURLs { try? FileManager.default.removeItem(at: url) }
        fixtureURLs = []
        super.tearDown()
    }

    // MARK: - Import

    func testImportBuildsLibraryEntryWithDefaults() async throws {
        let url = try writeWAVFixture(frames: 4_096, sampleRate: 44_100, channels: 2) { _ in 0.5 }
        let session = EditSession()
        await session.import(urls: [url])

        XCTAssertEqual(session.library.count, 1)
        let asset = try XCTUnwrap(session.library.first)
        XCTAssertNotNil(session.buffers[asset.id], "buffer cached on import")
        XCTAssertEqual(session.preps[asset.id], .identity)
        XCTAssertEqual(session.treatments[asset.id], .original)
    }

    func testImportSkipsUnsupported() async {
        let session = EditSession()
        await session.import(urls: [URL(fileURLWithPath: "/nope/file.flac")])
        XCTAssertTrue(session.library.isEmpty)
    }

    func testImportNewestFirst() async throws {
        let a = try writeWAVFixture(frames: 1_000, sampleRate: 44_100, channels: 1) { _ in 0.1 }
        let b = try writeWAVFixture(frames: 1_000, sampleRate: 44_100, channels: 1) { _ in 0.2 }
        let session = EditSession()
        await session.import(urls: [a])
        await session.import(urls: [b])
        XCTAssertEqual(session.library.first?.sourceURL, b, "newest import is first")
    }

    // MARK: - Selection cache-of-1

    func testSelectEvictsOtherBuffersAndReDecodes() async throws {
        let a = try writeWAVFixture(frames: 2_000, sampleRate: 48_000, channels: 2) { _ in 0.3 }
        let b = try writeWAVFixture(frames: 2_000, sampleRate: 48_000, channels: 2) { _ in 0.4 }
        let session = EditSession()
        await session.import(urls: [a, b])
        let assetA = try XCTUnwrap(session.library.first { $0.sourceURL == a })
        let assetB = try XCTUnwrap(session.library.first { $0.sourceURL == b })

        // Both buffers are resident after import; selecting A evicts B (cache-of-1).
        session.select(assetA.id)
        XCTAssertNotNil(session.buffers[assetA.id])
        XCTAssertNil(session.buffers[assetB.id], "cache-of-1: B evicted")

        // Selecting B evicts A and re-decodes B from disk (documented policy: the
        // re-decode is async, so await the seam).
        session.select(assetB.id)
        XCTAssertNil(session.buffers[assetA.id], "cache-of-1: A evicted")
        await session.ensureBuffer(assetB.id)
        XCTAssertNotNil(session.buffers[assetB.id], "B re-decoded on re-selection")

        // Re-selecting A re-decodes A.
        session.select(assetA.id)
        await session.ensureBuffer(assetA.id)
        XCTAssertNotNil(session.buffers[assetA.id], "A re-decoded on re-selection")
    }

    // MARK: - Non-destructive per-asset prep

    func testPrepMutatorsArePerAsset() async throws {
        let a = try writeWAVFixture(frames: 5_000, sampleRate: 44_100, channels: 2) { _ in 0.5 }
        let b = try writeWAVFixture(frames: 5_000, sampleRate: 44_100, channels: 2) { _ in 0.5 }
        let session = EditSession()
        await session.import(urls: [a, b])
        let assetA = try XCTUnwrap(session.library.first { $0.sourceURL == a })
        let assetB = try XCTUnwrap(session.library.first { $0.sourceURL == b })

        session.select(assetA.id)
        session.setGainDB(-6)
        session.setTrim(start: 100, end: 4_000)
        XCTAssertEqual(session.selectedPrep.gainDecibels, -6)
        XCTAssertEqual(session.selectedPrep.trimStartFrame, 100)

        session.select(assetB.id)
        XCTAssertEqual(session.selectedPrep, .identity, "editing A never touched B")
        XCTAssertEqual(session.selectedPrep.gainDecibels, 0)
    }

    func testImportBufferIsNeverMutatedByPrep() async throws {
        let url = try writeWAVFixture(frames: 3_000, sampleRate: 44_100, channels: 1) { _ in 0.9 }
        let session = EditSession()
        await session.import(urls: [url])
        let asset = try XCTUnwrap(session.library.first)
        let before = try XCTUnwrap(session.buffers[asset.id])
        session.select(asset.id)
        session.setGainDB(-24)
        session.setNormalize(true)
        let after = try XCTUnwrap(session.buffers[asset.id])
        XCTAssertEqual(before, after, "prep is non-destructive; the source buffer is untouched")
    }

    func testResetPrepRestoresIdentity() async throws {
        let url = try writeWAVFixture(frames: 3_000, sampleRate: 44_100, channels: 1) { _ in 0.5 }
        let session = EditSession()
        await session.import(urls: [url])
        let asset = try XCTUnwrap(session.library.first)
        session.select(asset.id)
        session.setGainDB(9)
        session.setFadeIn(500)
        session.resetPrep()
        XCTAssertEqual(session.selectedPrep, .identity)
    }

    // MARK: - Memory estimate wiring

    func testSelectedEstimateMatchesEstimatorForTrimMonoLoFi() async throws {
        let url = try writeWAVFixture(frames: 44_100, sampleRate: 44_100, channels: 2) { i in
            sin(2 * .pi * 2 * Float(i) / 44_100)
        }
        let session = EditSession()
        await session.import(urls: [url])
        let asset = try XCTUnwrap(session.library.first)
        session.select(asset.id)
        session.setTrim(start: 4_410, end: 40_000)
        session.setChannelMode(.mono)
        session.setTreatment(.loFi(.r11025))

        let expected = SampleMemoryEstimator.estimate(for: asset,
                                                      prep: session.selectedPrep,
                                                      treatment: session.selectedTreatment)
        XCTAssertEqual(session.selectedEstimate, expected)
        XCTAssertEqual(session.selectedEstimate?.channels, 1)
        XCTAssertEqual(session.selectedEstimate?.sampleRate, 11_025)
    }

    // MARK: - Space-audition gate (pure predicate)

    func testShouldAuditionGate() {
        XCTAssertTrue(EditSession.shouldAudition(mode: .edit, isRenaming: false, hasSelection: true))
        XCTAssertFalse(EditSession.shouldAudition(mode: .edit, isRenaming: true, hasSelection: true),
                       "rename field owns Space")
        XCTAssertFalse(EditSession.shouldAudition(mode: .edit, isRenaming: false, hasSelection: false))
        XCTAssertFalse(EditSession.shouldAudition(mode: .play, isRenaming: false, hasSelection: true),
                       "only in Edit")
    }

    // MARK: - Rename

    func testRenameUpdatesLabelAndIgnoresBlank() async throws {
        let url = try writeWAVFixture(frames: 1_000, sampleRate: 44_100, channels: 1) { _ in 0 }
        let session = EditSession()
        await session.import(urls: [url])
        let asset = try XCTUnwrap(session.library.first)
        session.rename(id: asset.id, to: "  AMEN CHOP  ")
        XCTAssertEqual(session.library.first?.displayName, "AMEN CHOP", "trimmed")
        session.rename(id: asset.id, to: "   ")
        XCTAssertEqual(session.library.first?.displayName, "AMEN CHOP", "blank rename ignored")
    }

    // MARK: - Pad target (MOCK)

    func testPadTargetReadsMockAssignment() {
        let session = EditSession()
        session.selectedGroup = 0
        session.setPadTarget(gridIndex: 3)
        XCTAssertEqual(session.selectedGridIndex, 3)
        // The assignment is whatever the deterministic mock holds; it must be consistent
        // with the shared library (no divergence from LoadSession's source).
        let direct = MockDeviceLibrary.standard.project.assignment(group: 0, gridIndex: 3)
        XCTAssertEqual(session.selectedAssignment, direct)
    }

    // MARK: - WaveformStrip geometry (pure)

    func testFrameToXRoundTripAndClamp() {
        let n = 10_000
        let w: CGFloat = 500
        for frame in [0, 2_500, 5_000, 9_999, 10_000] {
            let x = WaveformGeometry.frameToX(frame, sourceFrameCount: n, width: w)
            let back = WaveformGeometry.xToFrame(x, sourceFrameCount: n, width: w)
            XCTAssertEqual(back, frame, accuracy: 2, "round-trip within one pixel of frames")
        }
        XCTAssertEqual(WaveformGeometry.frameToX(-100, sourceFrameCount: n, width: w), 0)
        XCTAssertEqual(WaveformGeometry.frameToX(99_999, sourceFrameCount: n, width: w), w)
        XCTAssertEqual(WaveformGeometry.xToFrame(-10, sourceFrameCount: n, width: w), 0)
        XCTAssertEqual(WaveformGeometry.xToFrame(9_999, sourceFrameCount: n, width: w), n)
    }

    func testClampTrimKeepsStartBeforeEnd() {
        let (s, e) = WaveformGeometry.clampTrim(start: 900, end: 800, sourceFrameCount: 1_000, minGap: 10)
        XCTAssertLessThan(s, e)
        XCTAssertGreaterThanOrEqual(e - s, 10)

        // Start past the end nudges the end out within bounds.
        let (s2, e2) = WaveformGeometry.clampTrim(start: 995, end: 990, sourceFrameCount: 1_000, minGap: 10)
        XCTAssertLessThan(s2, e2)
        XCTAssertLessThanOrEqual(e2, 1_000)
    }

    // MARK: - AuditionPlayer.makeBuffer (pure)

    func testMakeBufferMatchesInput() {
        let channels: [[Float]] = [[0, 0.5, -0.5, 1], [0, -0.5, 0.5, -1]]
        let buffer = AuditionPlayer.makeBuffer(channels: channels, sampleRate: 22_050)
        let buf = try? XCTUnwrap(buffer)
        XCTAssertEqual(buf?.frameLength, 4)
        XCTAssertEqual(buf?.format.channelCount, 2)
        XCTAssertEqual(buf?.format.sampleRate, 22_050)
        XCTAssertEqual(buf?.floatChannelData?[0][3], 1)
        XCTAssertEqual(buf?.floatChannelData?[1][3], -1)
    }

    func testMakeBufferEmptyReturnsNil() {
        XCTAssertNil(AuditionPlayer.makeBuffer(channels: [], sampleRate: 44_100))
        XCTAssertNil(AuditionPlayer.makeBuffer(channels: [[]], sampleRate: 44_100))
    }
}
