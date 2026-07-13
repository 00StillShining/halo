import XCTest
@testable import Halo

/// Locks the board legends to the physical pad order so the PADS board, the
/// SOUNDS "USE" column, pad travel and the display can never disagree (DD-014).
final class PadsBoardTests: XCTestCase {

    /// Expected legend for a numeric pad entity.
    private func legend(for entity: EP40Entity) -> String? {
        switch entity {
        case .pad0: "0"
        case .pad1: "1"
        case .pad2: "2"
        case .pad3: "3"
        case .pad4: "4"
        case .pad5: "5"
        case .pad6: "6"
        case .pad7: "7"
        case .pad8: "8"
        case .pad9: "9"
        case .padDot: "."
        case .padEnter: "ENTER"
        default: nil
        }
    }

    func testLegendsMatchPadGridOrder() {
        XCTAssertEqual(PadGrid.legends.count, EP40Entity.padGridOrder.count)
        for (legendText, entity) in zip(PadGrid.legends, EP40Entity.padGridOrder) {
            XCTAssertEqual(legendText, legend(for: entity),
                           "legend \(legendText) must map to \(entity.rawValue)")
        }
    }

    func testGroupLetters() {
        XCTAssertEqual(PadGrid.groupLetter(0), "A")
        XCTAssertEqual(PadGrid.groupLetter(1), "B")
        XCTAssertEqual(PadGrid.groupLetter(2), "C")
        XCTAssertEqual(PadGrid.groupLetter(3), "D")
    }

    func testUseTokenComposesGroupAndLegend() {
        // group A (0), grid index 0 == legend "7" → "A7".
        let a = MockPadAssignment(group: 0, gridIndex: 0, slot: nil)
        XCTAssertEqual(PadGrid.useToken(a), "A7")
        // group D (3), grid index 9 == legend "." → "D.".
        let d = MockPadAssignment(group: 3, gridIndex: 9, slot: nil)
        XCTAssertEqual(PadGrid.useToken(d), "D.")
    }
}
