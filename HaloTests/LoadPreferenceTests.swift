import XCTest
@testable import Halo

/// Pins the P4-states LOAD UI-selection persistence contract (DD-027): the last tab
/// (PADS/SOUNDS) and group (A–D / 0…3) round-trip through the preference store,
/// default to PADS / group 0 when unset, and restoring never re-persists a no-op.
/// Scope note: this is the UI selection only — "project" is a device concept
/// (Phase 0B); no device claim is made. Headless, in-memory store.
@MainActor
final class LoadPreferenceTests: XCTestCase {

    private final class MemoryLoadStore: LoadPreferenceStore {
        var tab: String?
        var group: Int?
        var tabWrites = 0
        var groupWrites = 0
        func loadTab() -> String? { tab }
        func setLoadTab(_ raw: String) { tab = raw; tabWrites += 1 }
        func loadGroup() -> Int? { group }
        func setLoadGroup(_ g: Int) { group = g; groupWrites += 1 }
    }

    func testDefaultsWhenUnset() {
        let session = LoadSession(store: MemoryLoadStore())
        XCTAssertEqual(session.tab, .pads)
        XCTAssertEqual(session.selectedGroup, 0)
    }

    func testTabRoundTrips() {
        let store = MemoryLoadStore()
        let session = LoadSession(store: store)
        session.tab = .sounds
        XCTAssertEqual(store.tab, "SOUNDS")

        let reloaded = LoadSession(store: store)
        XCTAssertEqual(reloaded.tab, .sounds)
    }

    func testGroupRoundTrips() {
        let store = MemoryLoadStore()
        let session = LoadSession(store: store)
        session.selectedGroup = 2
        XCTAssertEqual(store.group, 2)

        let reloaded = LoadSession(store: store)
        XCTAssertEqual(reloaded.selectedGroup, 2)
    }

    func testRestoringDoesNotRepersist() {
        let store = MemoryLoadStore()
        store.tab = "SOUNDS"
        store.group = 3
        _ = LoadSession(store: store)      // init assigns; didSet must not fire
        XCTAssertEqual(store.tabWrites, 0)
        XCTAssertEqual(store.groupWrites, 0)
    }

    func testInvalidStoredGroupFallsBackToDefault() {
        let store = MemoryLoadStore()
        store.group = 99                   // out of 0…3 → ignored
        XCTAssertEqual(LoadSession(store: store).selectedGroup, 0)
    }

    func testNoOpAssignmentDoesNotWrite() {
        let store = MemoryLoadStore()
        let session = LoadSession(store: store)
        session.selectedGroup = 0          // same as default → no write
        XCTAssertEqual(store.groupWrites, 0)
    }
}
