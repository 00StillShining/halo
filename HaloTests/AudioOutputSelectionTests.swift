import XCTest
@testable import Halo

/// Pins the Brief §8 output-routing SELECTION + PERSISTENCE contract (DD-016):
/// resolution is a pure function of the persisted UID and the live snapshot, it
/// keys on STABLE UIDs (not names), it falls back honestly when the remembered
/// device is absent, and choices round-trip through the preference store. None of
/// this needs Core Audio — the discovery layer's real device reads are exercised
/// on-device (needs-device); this suite locks the logic that has no hardware seam.
final class AudioOutputSelectionTests: XCTestCase {

    // MARK: - Fixtures

    private func device(
        _ uid: String,
        name: String? = nil,
        input: Int = 0,
        output: Int = 2,
        rate: Double = 48_000
    ) -> AudioDevice {
        AudioDevice(
            uid: uid,
            name: name ?? uid,
            inputChannels: input,
            outputChannels: output,
            currentSampleRate: rate,
            supportedSampleRates: [44_100, 48_000],
            bufferFrameRange: .init(minFrames: 32, maxFrames: 4096)
        )
    }

    private func snapshot(
        _ devices: [AudioDevice],
        defaultOutput: String? = nil,
        defaultInput: String? = nil
    ) -> AudioDeviceSnapshot {
        AudioDeviceSnapshot(
            devices: devices,
            defaultInputUID: defaultInput,
            defaultOutputUID: defaultOutput
        )
    }

    /// In-memory preference store double.
    private final class MemoryStore: AudioPreferenceStore {
        var stored: String?
        func preferredOutputUID() -> String? { stored }
        func setPreferredOutputUID(_ uid: String?) { stored = uid }
    }

    // MARK: - Resolver purity

    func testResolveEmptyIsNone() {
        XCTAssertEqual(
            AudioOutputResolver.resolve(preferredUID: "anything", snapshot: snapshot([])),
            .none
        )
    }

    func testResolvePrefersPersistedUID() {
        let snap = snapshot(
            [device("A"), device("B"), device("C")],
            defaultOutput: "A"
        )
        let result = AudioOutputResolver.resolve(preferredUID: "C", snapshot: snap)
        XCTAssertEqual(result, .preferred(device("C")))
        XCTAssertTrue(result.isExactPreference)
        XCTAssertEqual(result.device?.uid, "C")
    }

    func testResolveFallsBackToSystemDefaultWhenPreferenceAbsent() {
        // Remembered "GONE" is not present → fall back to the system default "B".
        let snap = snapshot([device("A"), device("B")], defaultOutput: "B")
        let result = AudioOutputResolver.resolve(preferredUID: "GONE", snapshot: snap)
        XCTAssertEqual(result, .fallbackDefault(device("B")))
        XCTAssertFalse(result.isExactPreference)
    }

    func testResolveFallsBackToSystemDefaultWhenNoPreferenceSet() {
        let snap = snapshot([device("A"), device("B")], defaultOutput: "A")
        let result = AudioOutputResolver.resolve(preferredUID: nil, snapshot: snap)
        XCTAssertEqual(result, .fallbackDefault(device("A")))
    }

    func testResolveFallsBackToFirstOutputWhenNoUsableDefault() {
        // Default output UID points at a device that isn't in the list → first output.
        let snap = snapshot([device("A"), device("B")], defaultOutput: "MISSING")
        let result = AudioOutputResolver.resolve(preferredUID: nil, snapshot: snap)
        XCTAssertEqual(result, .fallbackFirst(device("A")))
    }

    func testResolveIgnoresInputOnlyDevices() {
        // An input-only device (e.g. a raw EP-40 source) must never be a monitor
        // OUTPUT target, even if it is the persisted UID or system default output.
        let inputOnly = device("MIC", input: 2, output: 0)
        let out = device("SPK", output: 2)
        let snap = snapshot([inputOnly, out], defaultOutput: "MIC")
        XCTAssertEqual(
            AudioOutputResolver.resolve(preferredUID: "MIC", snapshot: snap),
            .fallbackFirst(out)
        )
    }

    func testResolveKeysOnUIDNotName() {
        // Two devices share a display name; only the UID disambiguates.
        let a = device("uid-1", name: "USB Audio")
        let b = device("uid-2", name: "USB Audio")
        let snap = snapshot([a, b], defaultOutput: "uid-1")
        XCTAssertEqual(
            AudioOutputResolver.resolve(preferredUID: "uid-2", snapshot: snap),
            .preferred(b)
        )
    }

    // MARK: - Selection persistence

    @MainActor
    func testSelectionPersistsUIDAndReloads() {
        let store = MemoryStore()
        let selection = AudioOutputSelection(store: store)
        XCTAssertNil(selection.preferredUID)

        selection.select("uid-2")
        XCTAssertEqual(selection.preferredUID, "uid-2")
        XCTAssertEqual(store.stored, "uid-2")

        // A fresh instance backed by the same store reloads the remembered UID.
        let reloaded = AudioOutputSelection(store: store)
        XCTAssertEqual(reloaded.preferredUID, "uid-2")
    }

    @MainActor
    func testSelectNilClearsPreference() {
        let store = MemoryStore()
        store.stored = "old"
        let selection = AudioOutputSelection(store: store)
        XCTAssertEqual(selection.preferredUID, "old")

        selection.select(nil)
        XCTAssertNil(selection.preferredUID)
        XCTAssertNil(store.stored)
    }

    @MainActor
    func testSelectionResolutionUsesPersistedPreference() {
        let store = MemoryStore()
        let selection = AudioOutputSelection(store: store)
        selection.select("B")
        let snap = snapshot([device("A"), device("B")], defaultOutput: "A")
        XCTAssertEqual(selection.resolution(in: snap), .preferred(device("B")))
    }
}
