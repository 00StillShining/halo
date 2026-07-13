import Foundation

/// Pure, allocation-light MIDI interpretation shared by the CoreMIDI observer
/// and the app model, and exercised directly by unit tests.
///
/// Everything here is a documented USB-MIDI fact or a conservative, clearly
/// labelled inference (group from note range, physical grid position). Nothing
/// here claims an unobserved device state — see Brief §1/§4 honesty rules.
enum EP40MIDIMapping {

    /// The EP-40 exposes four sample groups (A–D) over MIDI notes 36…83:
    /// twelve contiguous notes per group. Group A = 36…47, B = 48…59,
    /// C = 60…71, D = 72…83.
    static let padNoteRange: ClosedRange<UInt8> = 36...83

    /// Documented MIDI note order within a group is: dot, 0, ENTER, 1…9.
    /// This table converts that per-group offset (0…11) into the physical 3×4
    /// grid index used by `EP40DisplayState.activePadIndex` and, in turn, by
    /// `EP40Entity.padGridOrder`. Row-major, top-left → bottom-right:
    /// `7 8 9 / 4 5 6 / 1 2 3 / . 0 ENTER`.
    static let midiOffsetToGrid: [Int] = [9, 10, 11, 6, 7, 8, 3, 4, 5, 0, 1, 2]

    /// Number of groups (A–D) and pads-per-group.
    static let groupCount = 4
    static let padsPerGroup = 12

    /// The sample group (0 = A … 3 = D) a pad note belongs to, or `nil` when the
    /// note falls outside the documented pad range.
    static func group(forNote note: UInt8) -> Int? {
        guard padNoteRange.contains(note) else { return nil }
        return (Int(note) - Int(padNoteRange.lowerBound)) / padsPerGroup
    }

    /// The physical 3×4 grid index (0…11) for a pad note, or `nil` when the note
    /// falls outside the documented pad range.
    static func gridIndex(forNote note: UInt8) -> Int? {
        guard padNoteRange.contains(note) else { return nil }
        let offset = (Int(note) - Int(padNoteRange.lowerBound)) % padsPerGroup
        return midiOffsetToGrid[offset]
    }

    /// MIDI convention: a Note-On with velocity 0 is a Note-Off. This is the one
    /// place that rule lives, so the observer and the tests agree by construction.
    static func normalizedNoteMessage(
        channel: UInt8,
        note: UInt8,
        velocity: UInt8
    ) -> EP40MIDIMessage {
        velocity == 0
            ? .noteOff(channel: channel, note: note)
            : .noteOn(channel: channel, note: note, velocity: velocity)
    }
}
