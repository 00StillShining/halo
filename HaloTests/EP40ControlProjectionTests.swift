import XCTest
@testable import Halo

/// Pins the Brief §4 honesty rules for the mechanical button language (DD-010):
/// TRAVEL only for an observed depression, rims only for latched/inferred state,
/// and `button_record` deliberately unrepresented (no observed record source).
final class EP40ControlProjectionTests: XCTestCase {

    // MARK: `.waiting` is fully at rest, even with garbage latched in the struct.

    func testWaitingProjectsToRestEvenWithGarbage() {
        var s = EP40DisplayState.liveIdle
        s.feedMode = .waiting
        s.mode = .sound
        s.isPlaying = true
        s.activeGroup = 2
        s.activePadIndex = 5
        let p = EP40ControlProjection.project(s)
        XCTAssertEqual(p, .rest)
        XCTAssertNil(p.pressedPad)
        XCTAssertNil(p.selectedModeButton)
        XCTAssertNil(p.activeGroupPad)
        XCTAssertFalse(p.playEngaged)
    }

    // MARK: Transport — observed Start/Stop only.

    func testLivePlayingEngagesTransport() {
        var s = EP40DisplayState.liveIdle
        s.isPlaying = true
        XCTAssertTrue(EP40ControlProjection.project(s).playEngaged)
    }

    func testLiveStoppedDisengagesTransport() {
        var s = EP40DisplayState.liveIdle
        s.isPlaying = false
        XCTAssertFalse(EP40ControlProjection.project(s).playEngaged)
    }

    // MARK: Mode button — only verified mappings light; erase/system stay dark.

    func testModeButtonsMapToTheirButton() {
        let cases: [(EP40DisplayMode, EP40Entity?)] = [
            (.sound, .buttonSound),
            (.main,  .buttonMain),
            (.tempo, .buttonTempo),
            (.erase, nil),
            (.system, nil),
        ]
        for (mode, expected) in cases {
            var s = EP40DisplayState.liveIdle
            s.mode = mode
            XCTAssertEqual(
                EP40ControlProjection.project(s).selectedModeButton, expected,
                "mode \(mode) should map to \(String(describing: expected))")
        }
    }

    // MARK: Group pad — 0…3 → A…D; nil / out-of-range → none.

    func testActiveGroupMapsToGroupPad() {
        let expected: [Int: EP40Entity] = [0: .groupA, 1: .groupB, 2: .groupC, 3: .groupD]
        for (idx, ent) in expected {
            var s = EP40DisplayState.liveIdle
            s.activeGroup = idx
            XCTAssertEqual(EP40ControlProjection.project(s).activeGroupPad, ent)
        }
    }

    func testNilOrOutOfRangeGroupHasNoPad() {
        var s = EP40DisplayState.liveIdle
        s.activeGroup = nil
        XCTAssertNil(EP40ControlProjection.project(s).activeGroupPad)
        s.activeGroup = 4
        XCTAssertNil(EP40ControlProjection.project(s).activeGroupPad)
        s.activeGroup = -1
        XCTAssertNil(EP40ControlProjection.project(s).activeGroupPad)
    }

    // MARK: Pad travel round-trips against padGridOrder (mirrors the mapping tests).

    func testActivePadIndexResolvesToGridPad() {
        for idx in 0..<EP40Entity.padGridOrder.count {
            var s = EP40DisplayState.liveIdle
            s.activePadIndex = idx
            XCTAssertEqual(
                EP40ControlProjection.project(s).pressedPad,
                EP40Entity.padGridOrder[idx],
                "grid index \(idx) resolved to the wrong pad")
        }
    }

    func testNilOrOutOfRangePadHasNoTravel() {
        var s = EP40DisplayState.liveIdle
        s.activePadIndex = nil
        XCTAssertNil(EP40ControlProjection.project(s).pressedPad)
        s.activePadIndex = 12
        XCTAssertNil(EP40ControlProjection.project(s).pressedPad)
    }

    // MARK: `.preview` still projects — the demo deliberately drives the controls.

    func testPreviewProjectsControls() {
        // `.previewStill` is playing, sound mode, group 0, pad index 3.
        let p = EP40ControlProjection.project(.previewStill)
        XCTAssertTrue(p.playEngaged)
        XCTAssertEqual(p.selectedModeButton, .buttonSound)
        XCTAssertEqual(p.activeGroupPad, .groupA)
        XCTAssertEqual(p.pressedPad, EP40Entity.padGridOrder[3])
    }

    // MARK: Honesty guarantee — there is no record channel to project at all.

    func testProjectionExposesNoRecordChannel() {
        // The type has exactly four honest channels; `button_record` is absent
        // because no observed record source exists (DD-010). If a record field is
        // ever added speculatively, this reflection guard fails on review.
        let mirror = Mirror(reflecting: EP40ControlProjection.rest)
        let labels = Set(mirror.children.compactMap(\.label))
        XCTAssertEqual(
            labels,
            ["pressedPad", "selectedModeButton", "activeGroupPad", "playEngaged"])
        XCTAssertFalse(labels.contains { $0.lowercased().contains("record") })
    }
}
