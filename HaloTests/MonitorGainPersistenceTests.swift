import XCTest
@testable import Halo

/// Pins the P4-states monitor-gain persistence contract (DD-027): the fader position
/// round-trips through the preference store, restores clamped to −40…0, and defaults
/// to the safe −12 dB when unset. HONESTY: persisting the fader POSITION never
/// auto-starts monitoring — this suite asserts the stored value only, not any route.
/// Uses a mock engine + in-memory store so it runs headless (no Core Audio).
final class MonitorGainPersistenceTests: XCTestCase {

    /// In-memory preference double, mirroring the AudioPreferenceStore pattern.
    private final class MemoryGainStore: MonitorPreferenceStore {
        var stored: Double?
        func monitorGainDB() -> Double? { stored }
        func setMonitorGainDB(_ db: Double) { stored = db }
    }

    /// A monitor engine that records nothing and never touches hardware.
    private final class NoopEngine: MonitorEngine, @unchecked Sendable {
        var isRunning = false
        func start(config: MonitorRouteConfig) throws { isRunning = true }
        func stop() { isRunning = false }
        func setGainDB(_ db: Double) {}
        func meterSnapshot() -> StereoLevels { .silence }
    }

    @MainActor
    private func makeController(store: MonitorPreferenceStore) -> MonitorController {
        MonitorController(engine: NoopEngine(), gainStore: store)
    }

    @MainActor
    func testDefaultsToMinusTwelveWhenUnset() {
        let store = MemoryGainStore()
        let controller = makeController(store: store)
        XCTAssertEqual(controller.gainDB, MonitorGain.defaultDB, accuracy: 0.0001)
        XCTAssertEqual(MonitorGain.defaultDB, -12, accuracy: 0.0001)
    }

    @MainActor
    func testWritingGainPersists() {
        let store = MemoryGainStore()
        let controller = makeController(store: store)
        controller.gainDB = -6
        XCTAssertEqual(store.stored ?? .nan, -6, accuracy: 0.0001)
    }

    @MainActor
    func testRestoresPersistedGain() {
        let store = MemoryGainStore()
        store.stored = -3
        let controller = makeController(store: store)
        XCTAssertEqual(controller.gainDB, -3, accuracy: 0.0001)
    }

    @MainActor
    func testRestoreClampsOutOfRange() {
        let low = MemoryGainStore(); low.stored = -999
        XCTAssertEqual(makeController(store: low).gainDB, -40, accuracy: 0.0001)

        let high = MemoryGainStore(); high.stored = 42
        XCTAssertEqual(makeController(store: high).gainDB, 0, accuracy: 0.0001)
    }

    @MainActor
    func testSettingOutOfRangeClampsAndPersistsClamped() {
        let store = MemoryGainStore()
        let controller = makeController(store: store)
        controller.gainDB = 10           // above 0 → clamps to 0
        XCTAssertEqual(controller.gainDB, 0, accuracy: 0.0001)
        XCTAssertEqual(store.stored ?? .nan, 0, accuracy: 0.0001)
    }

    @MainActor
    func testStoredZeroIsRestoredNotTreatedAsUnset() {
        // 0 dB is a valid fader position; it must round-trip, not fall back to −12.
        let store = MemoryGainStore(); store.stored = 0
        XCTAssertEqual(makeController(store: store).gainDB, 0, accuracy: 0.0001)
    }
}
