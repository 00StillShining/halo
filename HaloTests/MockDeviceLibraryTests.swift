import XCTest
@testable import Halo

/// Pins the mock-data honesty invariants (Brief §3, DD-014): determinism (so the
/// loop's headless screenshots are byte-stable), slot/assignment separation, and
/// the derived-usage guarantee that SOUNDS "USE" can never disagree with PADS.
final class MockDeviceLibraryTests: XCTestCase {

    func testGenerationIsDeterministic() {
        let a = MockDeviceLibrary.generate(seed: 0x0E40)
        let b = MockDeviceLibrary.generate(seed: 0x0E40)
        XCTAssertEqual(a, b)
    }

    func testEverySound_hasValidUniqueAscendingSlot() {
        let lib = MockDeviceLibrary.standard
        let raws = lib.sounds.map { $0.slot.raw }
        XCTAssertFalse(raws.isEmpty)
        for r in raws { XCTAssertTrue((1...999).contains(r)) }
        XCTAssertEqual(raws, raws.sorted(), "sounds must be ascending by slot")
        XCTAssertEqual(Set(raws).count, raws.count, "slot ids must be unique")
    }

    func testProjectHasExactly48AssignmentsInGridOrder() {
        let p = MockDeviceLibrary.standard.project
        XCTAssertEqual(p.assignments.count,
                       EP40MIDIMapping.groupCount * EP40MIDIMapping.padsPerGroup)
        var i = 0
        for g in 0..<EP40MIDIMapping.groupCount {
            for grid in 0..<EP40MIDIMapping.padsPerGroup {
                XCTAssertEqual(p.assignments[i].group, g)
                XCTAssertEqual(p.assignments[i].gridIndex, grid)
                i += 1
            }
        }
    }

    func testEveryAssignedSlotExistsInLibrary() {
        let lib = MockDeviceLibrary.standard
        let slots = Set(lib.sounds.map { $0.slot })
        for a in lib.project.assignments {
            if let slot = a.slot {
                XCTAssertTrue(slots.contains(slot),
                              "assignment references a non-existent slot \(slot.label)")
            }
        }
    }

    func testCapacityAccountingBalances() {
        let lib = MockDeviceLibrary.standard
        XCTAssertEqual(lib.usedBytes + lib.freeBytes,
                       MockDeviceLibrary.reportedCapacityBytes)
        XCTAssertGreaterThanOrEqual(lib.freeBytes, 0, "used must not exceed capacity")
    }

    func testUsageDerivationRoundTrips() {
        // Every USE reference points back to an assignment carrying that slot, and
        // every assigned pad appears in exactly one slot's usage set.
        let lib = MockDeviceLibrary.standard
        for sound in lib.sounds {
            for ref in lib.assignments(referencing: sound.slot) {
                XCTAssertEqual(ref.slot, sound.slot)
            }
        }
        let assignedPads = lib.project.assignments.filter { $0.slot != nil }
        let derived = lib.sounds.flatMap { lib.assignments(referencing: $0.slot) }
        XCTAssertEqual(derived.count, assignedPads.count,
                       "each assigned pad is counted exactly once via its slot")
    }
}
