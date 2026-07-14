import XCTest
@testable import Halo

/// Pins the honesty-critical CHOP core (Brief §5c): spectral-flux onset detection lands
/// within musical tolerance of planted transients, silence yields NO slices, the editable
/// `SliceSet` tiles the whole signal, the keyboard mirrors pad order, and the send plan
/// names/slots/bytes/overflow are exact. All deterministic and hardware-free — the
/// slicing math is provable without the device.
final class OnsetDetectorTests: XCTestCase {

    private let sampleRate = 44_100.0

    // MARK: - Fixture: a synthesized "classic break"

    /// A mono break at `sampleRate`: sharp broadband transients planted at known frames,
    /// each a ~80 ms exponential-decay burst of deterministic pseudo-noise (SplitMix64),
    /// over a low-level (−40 dB) deterministic filler so it is never pure silence.
    private func breakFixture(transientSeconds: [Double], lengthSeconds: Double)
        -> (mono: [Float], transientFrames: [Int]) {
        let n = Int(lengthSeconds * sampleRate)
        var mono = [Float](repeating: 0, count: n)
        var rng = SplitMix64(state: 0xB2EA_9051)

        // −40 dB steady deterministic filler.
        for i in 0..<n {
            let r = Float(rng.next() % 20_001) / 10_000 - 1   // −1…1
            mono[i] += r * 0.01
        }

        // Planted transients: exponential-decay noise bursts.
        var transientFrames: [Int] = []
        let decay = 0.080 * sampleRate
        for t in transientSeconds {
            let start = Int(t * sampleRate)
            guard start < n else { continue }
            transientFrames.append(start)
            let end = min(n, start + Int(decay * 4))
            var burstRng = SplitMix64(state: UInt64(start) &* 0x9E37_79B9)
            for i in start..<end {
                let env = expf(-Float(i - start) / Float(decay))
                let r = Float(burstRng.next() % 20_001) / 10_000 - 1
                mono[i] += r * env * 0.9
            }
        }
        return (mono, transientFrames)
    }

    // MARK: - Onset detection tolerance

    func testDetectsPlantedTransientsWithinTolerance() {
        // Kick / snare / hat style pattern, all interior (frame 0 is the implicit start).
        let seconds = [0.20, 0.45, 0.70, 0.95, 1.20, 1.45]
        let (mono, planted) = breakFixture(transientSeconds: seconds, lengthSeconds: 1.8)
        let onsets = OnsetDetector.detectOnsets(mono: mono, sampleRate: sampleRate,
                                                parameters: .init())
        XCTAssertFalse(onsets.isEmpty, "should detect the planted transients")

        let tolerance = Int(0.030 * sampleRate)   // ±30 ms musical tolerance
        for frame in planted {
            let nearest = onsets.map { abs($0 - frame) }.min() ?? Int.max
            XCTAssertLessThanOrEqual(nearest, tolerance,
                "no onset within tolerance of planted transient at frame \(frame)")
        }
        // No more than ~1 spurious onset per planted transient.
        XCTAssertLessThanOrEqual(onsets.count, planted.count * 2)
    }

    func testSensitivityMonotonicity() {
        let (mono, _) = breakFixture(transientSeconds: [0.2, 0.5, 0.8, 1.1, 1.4],
                                     lengthSeconds: 1.8)
        var lastCount = -1
        for s in stride(from: 0.0, through: 1.0, by: 0.25) {
            let count = OnsetDetector.detectOnsets(mono: mono, sampleRate: sampleRate,
                                                   parameters: .init(sensitivity: s)).count
            XCTAssertGreaterThanOrEqual(count, lastCount,
                "onset count must be non-decreasing as sensitivity rises (s=\(s))")
            lastCount = count
        }
        // Endpoints: max sensitivity finds at least as many as min.
        let low = OnsetDetector.detectOnsets(mono: mono, sampleRate: sampleRate,
                                             parameters: .init(sensitivity: 0)).count
        let high = OnsetDetector.detectOnsets(mono: mono, sampleRate: sampleRate,
                                              parameters: .init(sensitivity: 1)).count
        XCTAssertGreaterThanOrEqual(high, low)
    }

    func testSilenceYieldsNoOnsets() {
        let mono = [Float](repeating: 0, count: Int(sampleRate))   // 1 s of true silence
        XCTAssertTrue(OnsetDetector.detectOnsets(mono: mono, sampleRate: sampleRate,
                                                 parameters: .init()).isEmpty)
    }

    func testTooShortYieldsNoOnsets() {
        let mono = [Float](repeating: 0.5, count: 256)             // shorter than the FFT window
        XCTAssertTrue(OnsetDetector.detectOnsets(mono: mono, sampleRate: sampleRate,
                                                 parameters: .init()).isEmpty)
    }

    // MARK: - SliceSet

    func testSlicesTileWholeSignal() {
        let set = SliceSet(sourceFrameCount: 1000, onsets: [200, 500, 800])
        let slices = set.slices()
        XCTAssertEqual(slices.count, 4)
        XCTAssertEqual(slices.first?.startFrame, 0)
        XCTAssertEqual(slices.last?.endFrame, 1000)
        // Contiguous: each slice's end is the next slice's start.
        for i in 1..<slices.count {
            XCTAssertEqual(slices[i - 1].endFrame, slices[i].startFrame)
        }
        XCTAssertEqual(slices.map(\.id), [0, 1, 2, 3])
    }

    func testEmptyOnsetsGivesOneWholeSlice() {
        let set = SliceSet(sourceFrameCount: 1000, onsets: [])
        XCTAssertEqual(set.sliceCount, 1)
        XCTAssertEqual(set.slices().first?.startFrame, 0)
        XCTAssertEqual(set.slices().first?.endFrame, 1000)
    }

    func testAddRespectsMinGap() {
        var set = SliceSet(sourceFrameCount: 1000, onsets: [500])
        set.addCut(at: 505, minGap: 50)        // too close to 500 → rejected
        XCTAssertEqual(set.cuts, [500])
        set.addCut(at: 200, minGap: 50)        // valid
        XCTAssertEqual(set.cuts, [200, 500])
        set.addCut(at: 5, minGap: 50)          // too close to the start (frame 0)
        XCTAssertEqual(set.cuts, [200, 500])
    }

    func testMoveClampsBetweenNeighbours() {
        var set = SliceSet(sourceFrameCount: 1000, onsets: [200, 500, 800])
        set.moveCut(index: 1, to: 250, minGap: 50)   // would collide with cut 0 (200)
        XCTAssertEqual(set.cuts[1], 250)             // clamped to 200 + minGap
        set.moveCut(index: 1, to: 900, minGap: 50)   // would collide with cut 2 (800)
        XCTAssertEqual(set.cuts[1], 750)             // clamped to 800 − minGap
    }

    func testRemoveMergesSlices() {
        var set = SliceSet(sourceFrameCount: 1000, onsets: [200, 500, 800])
        set.removeCut(index: 1)
        XCTAssertEqual(set.cuts, [200, 800])
        XCTAssertEqual(set.sliceCount, 3)
    }

    // MARK: - ChopKeyboard (mirrors pad order)

    func testLegendToSliceMirrorsPadOrder() {
        // PadGrid.legends = ["7","8","9","4","5","6","1","2","3",".","0","ENTER"].
        // Fill from grid index 6 (legend "1"): key "1" → slice 0, "2" → 1, "3" → 2.
        let start = 6
        XCTAssertEqual(ChopKeyboard.sliceIndex(forLegend: "1", startGridIndex: start, sliceCount: 3), 0)
        XCTAssertEqual(ChopKeyboard.sliceIndex(forLegend: "2", startGridIndex: start, sliceCount: 3), 1)
        XCTAssertEqual(ChopKeyboard.sliceIndex(forLegend: "3", startGridIndex: start, sliceCount: 3), 2)
        // "." is grid index 9 → slice 3, past the 3-slice count → nil.
        XCTAssertNil(ChopKeyboard.sliceIndex(forLegend: ".", startGridIndex: start, sliceCount: 3))
        // Keys before the start pad map to nil.
        XCTAssertNil(ChopKeyboard.sliceIndex(forLegend: "7", startGridIndex: start, sliceCount: 3))
        // Return maps to the ENTER legend (grid index 11).
        XCTAssertEqual(ChopKeyboard.legend(forCharacter: "\r"), "ENTER")
        XCTAssertEqual(ChopKeyboard.legend(forCharacter: "\n"), "ENTER")
        XCTAssertNil(ChopKeyboard.legend(forCharacter: "x"))
    }

    // MARK: - ChopPlanner

    private func planFixture(sliceCount: Int, startGridIndex: Int) -> SendToPadsPlan {
        // Deterministic slices of 10_000 frames each over a 44_100 Hz source.
        let slices = (0..<sliceCount).map {
            SliceRange(id: $0, startFrame: $0 * 10_000, endFrame: ($0 + 1) * 10_000)
        }
        return ChopPlanner.plan(slices: slices, channelCount: 2, treatment: .original,
                                sourceRate: sampleRate, group: 1, startGridIndex: startGridIndex,
                                baseName: "AMEN", library: MockDeviceLibrary.standard)
    }

    func testPlanNamesAndSlotsAscending() {
        let plan = planFixture(sliceCount: 4, startGridIndex: 0)
        XCTAssertEqual(plan.writes.count, 4)
        XCTAssertEqual(plan.overflowCount, 0)
        // Names are base.NN, 1-based.
        XCTAssertEqual(plan.writes.map(\.name), ["AMEN.01", "AMEN.02", "AMEN.03", "AMEN.04"])
        // Slots ascend and are all free in the mock library.
        let usedRaw = Set(MockDeviceLibrary.standard.sounds.map(\.slot.raw))
        var previous = 0
        for write in plan.writes {
            XCTAssertGreaterThan(write.proposedSlot.raw, previous)
            XCTAssertFalse(usedRaw.contains(write.proposedSlot.raw))
            previous = write.proposedSlot.raw
        }
        // Total bytes = Σ payloads; grid indices are consecutive from the start.
        XCTAssertEqual(plan.totalBytes, plan.writes.reduce(0) { $0 + $1.payloadBytes })
        XCTAssertEqual(plan.writes.map(\.gridIndex), [0, 1, 2, 3])
    }

    func testOverflowReportedNotWrapped() {
        // 13 slices from pad grid index 11 (the last pad) → 1 placeable, 12 overflow.
        let plan = planFixture(sliceCount: 13, startGridIndex: 11)
        XCTAssertEqual(plan.placedCount, 1)
        XCTAssertEqual(plan.overflowCount, 12)
        XCTAssertEqual(plan.writes.first?.gridIndex, 11)   // never wraps to group C
    }

    func testAfterBytesArithmetic() {
        let plan = planFixture(sliceCount: 4, startGridIndex: 0)
        XCTAssertEqual(plan.freeBeforeBytes, MockDeviceLibrary.standard.freeBytes)
        XCTAssertEqual(plan.freeAfterBytes, plan.freeBeforeBytes - plan.totalBytes)
        // Each 10_000-frame stereo slice at ORIGINAL (source ≤ device max) = 10_000×2×2.
        XCTAssertEqual(plan.writes.first?.payloadBytes, 10_000 * 2 * 2)
    }

    func testDisabledSenderNeedsDevice() async {
        let plan = planFixture(sliceCount: 2, startGridIndex: 0)
        let result = await DeviceUnavailableChopSender().send(plan)
        guard case .needsDevice = result else {
            return XCTFail("device send must report needsDevice (Phase 0B)")
        }
    }
}
