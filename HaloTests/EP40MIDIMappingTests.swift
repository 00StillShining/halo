import XCTest
@testable import Halo

/// Covers the documented MIDI interpretation that drives the replica display:
/// note→group ranges, velocity-zero handling, and the offset↔grid round-trip.
final class EP40MIDIMappingTests: XCTestCase {

    // MARK: Note → group range mapping (36–47 = A … 72–83 = D)

    func testGroupBoundaries() {
        // Group A = 36…47, B = 48…59, C = 60…71, D = 72…83.
        XCTAssertEqual(EP40MIDIMapping.group(forNote: 36), 0)
        XCTAssertEqual(EP40MIDIMapping.group(forNote: 47), 0)
        XCTAssertEqual(EP40MIDIMapping.group(forNote: 48), 1)
        XCTAssertEqual(EP40MIDIMapping.group(forNote: 59), 1)
        XCTAssertEqual(EP40MIDIMapping.group(forNote: 60), 2)
        XCTAssertEqual(EP40MIDIMapping.group(forNote: 71), 2)
        XCTAssertEqual(EP40MIDIMapping.group(forNote: 72), 3)
        XCTAssertEqual(EP40MIDIMapping.group(forNote: 83), 3)
    }

    func testEveryPadNoteMapsToItsGroup() {
        for note in 36...83 {
            let expected = (note - 36) / 12
            XCTAssertEqual(
                EP40MIDIMapping.group(forNote: UInt8(note)), expected,
                "note \(note) should be in group \(expected)"
            )
        }
    }

    func testNotesOutsidePadRangeHaveNoGroup() {
        XCTAssertNil(EP40MIDIMapping.group(forNote: 35))
        XCTAssertNil(EP40MIDIMapping.group(forNote: 84))
        XCTAssertNil(EP40MIDIMapping.group(forNote: 0))
        XCTAssertNil(EP40MIDIMapping.group(forNote: 127))
        XCTAssertNil(EP40MIDIMapping.gridIndex(forNote: 35))
        XCTAssertNil(EP40MIDIMapping.gridIndex(forNote: 84))
    }

    func testGroupCountCoversAllNotes() {
        // Exactly four groups of twelve fill the documented 36…83 span.
        XCTAssertEqual(EP40MIDIMapping.groupCount * EP40MIDIMapping.padsPerGroup, 48)
        XCTAssertEqual(
            Int(EP40MIDIMapping.padNoteRange.upperBound)
                - Int(EP40MIDIMapping.padNoteRange.lowerBound) + 1,
            48
        )
    }

    // MARK: Note-On velocity 0 == Note Off

    func testNoteOnVelocityZeroIsNoteOff() {
        let message = EP40MIDIMapping.normalizedNoteMessage(channel: 0, note: 40, velocity: 0)
        XCTAssertEqual(message, .noteOff(channel: 0, note: 40))
    }

    func testNoteOnPositiveVelocityStaysNoteOn() {
        let message = EP40MIDIMapping.normalizedNoteMessage(channel: 2, note: 40, velocity: 110)
        XCTAssertEqual(message, .noteOn(channel: 2, note: 40, velocity: 110))
    }

    func testNoteOnVelocityOneIsStillNoteOn() {
        // Only velocity 0 is the Note-Off convention; velocity 1 is a real hit.
        let message = EP40MIDIMapping.normalizedNoteMessage(channel: 0, note: 36, velocity: 1)
        XCTAssertEqual(message, .noteOn(channel: 0, note: 36, velocity: 1))
    }

    // MARK: midiOffsetToGrid / padGridOrder round-trip

    func testGridIndexTableIsAPermutationOfZeroToEleven() {
        XCTAssertEqual(EP40MIDIMapping.midiOffsetToGrid.count, 12)
        XCTAssertEqual(Set(EP40MIDIMapping.midiOffsetToGrid), Set(0...11))
    }

    /// The core invariant that keeps pad-travel and the display in agreement:
    /// resolving a note → grid index → physical pad entity must land on the same
    /// pad as the documented MIDI note order.
    func testOffsetToGridRoundTripMatchesNoteOrder() {
        for offset in 0..<12 {
            let note = UInt8(36 + offset)
            guard let gridIndex = EP40MIDIMapping.gridIndex(forNote: note) else {
                return XCTFail("note \(note) unexpectedly had no grid index")
            }
            let padFromGrid = EP40Entity.padGridOrder[gridIndex]
            let padFromNoteOrder = EP40Entity.numericPadsInNoteOrder[offset]
            XCTAssertEqual(
                padFromGrid, padFromNoteOrder,
                "offset \(offset) (note \(note)) grid \(gridIndex) resolved to the wrong pad"
            )
        }
    }

    func testGridIndexRepeatsAcrossGroups() {
        // The same pad position holds across all four groups (group only shifts
        // the note by a multiple of twelve).
        for offset in 0..<12 {
            let base = EP40MIDIMapping.gridIndex(forNote: UInt8(36 + offset))
            for group in 1...3 {
                let note = UInt8(36 + group * 12 + offset)
                XCTAssertEqual(EP40MIDIMapping.gridIndex(forNote: note), base)
            }
        }
    }
}
