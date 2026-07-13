import XCTest
@testable import Halo

/// Pins the polyphonic, refcounted live pad-travel contract (Brief §6, DD-012):
/// two group notes can map to one physical pad, and the pad releases only when the
/// LAST hold ends. Duplicate strikes restrike; orphan Note Offs and out-of-range
/// notes do nothing.
final class PadHoldRegistryTests: XCTestCase {

    // Note 36 (group A) and note 48 (group B) both map to physical grid pad 9
    // (offset 0 in each group → midiOffsetToGrid[0] == 9).
    private let sharedPad = 9

    func testTwoGroupsSharePhysicalPadRefcounts() {
        var r = PadHoldRegistry()
        // First note on the shared pad → press.
        let a = r.noteOn(channel: 0, note: 36, velocity01: 0.5)
        XCTAssertEqual(a?.pad, sharedPad)
        XCTAssertEqual(a?.transition, .press(velocity: 0.5))
        // Second note on the SAME physical pad → restrike (already down).
        let b = r.noteOn(channel: 0, note: 48, velocity01: 0.9)
        XCTAssertEqual(b?.pad, sharedPad)
        XCTAssertEqual(b?.transition, .restrike(velocity: 0.9))
        // Off the first note → sustain (the other hold keeps it down).
        XCTAssertEqual(r.noteOff(channel: 0, note: 36)?.transition, .sustain)
        // Off the second note → release (last hold gone).
        XCTAssertEqual(r.noteOff(channel: 0, note: 48)?.transition, .release)
    }

    func testDuplicateNoteOnRestrikesAndSingleOffReleases() {
        var r = PadHoldRegistry()
        XCTAssertEqual(r.noteOn(channel: 0, note: 40, velocity01: 0.3)?.transition,
                       .press(velocity: 0.3))
        // Same (channel, note) struck again → restrike at the new velocity.
        XCTAssertEqual(r.noteOn(channel: 0, note: 40, velocity01: 0.7)?.transition,
                       .restrike(velocity: 0.7))
        // A set collapses the duplicate, so a single Off fully releases.
        XCTAssertEqual(r.noteOff(channel: 0, note: 40)?.transition, .release)
    }

    func testOrphanNoteOffIsIgnored() {
        var r = PadHoldRegistry()
        XCTAssertNil(r.noteOff(channel: 0, note: 40), "Note Off with no matching hold must be nil")
    }

    func testOutOfRangeNotesDoNothing() {
        var r = PadHoldRegistry()
        for n: UInt8 in [35, 84, 0] {
            XCTAssertNil(r.noteOn(channel: 0, note: n, velocity01: 1))
            XCTAssertNil(r.noteOff(channel: 0, note: n))
        }
    }

    func testDistinctPadsEachPress() {
        var r = PadHoldRegistry()
        // Notes 36, 37, 38 → distinct grid pads, each a fresh press (real polyphony).
        for n: UInt8 in [36, 37, 38] {
            XCTAssertEqual(r.noteOn(channel: 0, note: n, velocity01: 1)?.transition,
                           .press(velocity: 1))
        }
    }

    func testReleaseAllReturnsHeldPadsAndEmpties() {
        var r = PadHoldRegistry()
        _ = r.noteOn(channel: 0, note: 36, velocity01: 1)   // pad 9
        _ = r.noteOn(channel: 0, note: 37, velocity01: 1)   // pad 10
        let held = Set(r.releaseAll())
        XCTAssertEqual(held, [9, 10])
        // State is empty afterwards: a subsequent Off is an orphan.
        XCTAssertNil(r.noteOff(channel: 0, note: 36))
        // And a fresh Note On is a press again, not a restrike.
        XCTAssertEqual(r.noteOn(channel: 0, note: 36, velocity01: 1)?.transition,
                       .press(velocity: 1))
    }

    func testChannelIsolationOnSharedPad() {
        var r = PadHoldRegistry()
        // Same note on two channels are two distinct holds on the one pad.
        XCTAssertEqual(r.noteOn(channel: 0, note: 36, velocity01: 1)?.transition,
                       .press(velocity: 1))
        XCTAssertEqual(r.noteOn(channel: 1, note: 36, velocity01: 1)?.transition,
                       .restrike(velocity: 1))
        XCTAssertEqual(r.noteOff(channel: 0, note: 36)?.transition, .sustain)
        XCTAssertEqual(r.noteOff(channel: 1, note: 36)?.transition, .release)
    }
}
