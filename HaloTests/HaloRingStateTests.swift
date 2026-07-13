import XCTest
@testable import Halo

/// Covers the pure ring-state derivation (Brief §5). The ring is driven only by
/// connection/monitor/record truth; these tests lock the priority order and the
/// honest defaults (no observer → disconnected; observer only → discovering).
final class HaloRingStateTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 0)

    // MARK: Base ladder

    func testNoObserverNoEndpointIsDisconnected() {
        XCTAssertEqual(HaloRingState.derive(.init()), .disconnected)
    }

    func testObserverOnlyIsDiscovering() {
        let s = HaloRingState.derive(.init(observerRunning: true))
        XCTAssertEqual(s, .discovering)
    }

    func testEndpointIsConnected() {
        let s = HaloRingState.derive(.init(observerRunning: true, endpointConnected: true))
        XCTAssertEqual(s, .connected)
    }

    func testMonitorEngagedIsMonitoring() {
        let s = HaloRingState.derive(.init(observerRunning: true,
                                           endpointConnected: true,
                                           monitorEngaged: true))
        XCTAssertEqual(s, .monitoring)
    }

    // MARK: Priority — error > transfer > recording > monitoring > connected > discovering

    func testErrorBeatsEverything() {
        let s = HaloRingState.derive(.init(observerRunning: true,
                                           endpointConnected: true,
                                           errorLabel: "MIDI",
                                           monitorEngaged: true,
                                           recordingStartedAt: epoch,
                                           transferProgress: 0.5))
        XCTAssertEqual(s, .error(label: "MIDI"))
    }

    func testTransferBeatsRecording() {
        let s = HaloRingState.derive(.init(observerRunning: true,
                                           endpointConnected: true,
                                           monitorEngaged: true,
                                           recordingStartedAt: epoch,
                                           transferProgress: 0.5))
        XCTAssertEqual(s, .transfer(progress: 0.5))
    }

    func testRecordingBeatsMonitoring() {
        let s = HaloRingState.derive(.init(observerRunning: true,
                                           endpointConnected: true,
                                           monitorEngaged: true,
                                           recordingStartedAt: epoch))
        XCTAssertEqual(s, .recording(startedAt: epoch))
    }

    func testMonitoringBeatsConnected() {
        let s = HaloRingState.derive(.init(observerRunning: true,
                                           endpointConnected: true,
                                           monitorEngaged: true))
        XCTAssertEqual(s, .monitoring)
    }

    func testConnectedBeatsDiscovering() {
        let s = HaloRingState.derive(.init(observerRunning: true, endpointConnected: true))
        XCTAssertEqual(s, .connected)
    }

    // MARK: Transfer progress clamped to 0…1

    func testTransferProgressClampedLow() {
        let s = HaloRingState.derive(.init(transferProgress: -0.5))
        XCTAssertEqual(s, .transfer(progress: 0))
    }

    func testTransferProgressClampedHigh() {
        let s = HaloRingState.derive(.init(transferProgress: 1.8))
        XCTAssertEqual(s, .transfer(progress: 1))
    }

    // MARK: Status words

    func testStatusWords() {
        XCTAssertEqual(HaloRingState.disconnected.statusWord, "DARK")
        XCTAssertEqual(HaloRingState.discovering.statusWord, "SCAN")
        XCTAssertEqual(HaloRingState.connected.statusWord, "LINK")
        XCTAssertEqual(HaloRingState.monitoring.statusWord, "MON")
        XCTAssertEqual(HaloRingState.recording(startedAt: epoch).statusWord, "REC")
        XCTAssertEqual(HaloRingState.transfer(progress: 0.42).statusWord, "TX 42%")
        XCTAssertEqual(HaloRingState.error(label: "MIDI").statusWord, "ERR MIDI")
    }

    func testIsError() {
        XCTAssertTrue(HaloRingState.error(label: "MIDI").isError)
        XCTAssertFalse(HaloRingState.connected.isError)
    }
}
