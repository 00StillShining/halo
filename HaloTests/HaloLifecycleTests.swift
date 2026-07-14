import AVFoundation
import XCTest
@testable import Halo

/// P2-lifecycle (Brief §8 safety & resilience). Covers the pure lifecycle-phase
/// derivation, the running-route device reconciler, the microphone-permission
/// gating, and the model-level held-key release + status transitions on
/// disconnect / sleep / wake — no CoreMIDI or audio hardware required.
final class HaloLifecycleTests: XCTestCase {

    // MARK: - HaloLifecyclePhase derivation

    func testStartingWhenNothingRunning() {
        XCTAssertEqual(HaloLifecyclePhase.derive(.init()), .starting)
    }

    func testObserverOnlyIsWaiting() {
        XCTAssertEqual(HaloLifecyclePhase.derive(.init(observerRunning: true)), .waiting)
    }

    func testEndpointConnectedIsReady() {
        let p = HaloLifecyclePhase.derive(.init(observerRunning: true, endpointConnected: true))
        XCTAssertEqual(p, .ready)
    }

    func testLiveFeedIsLive() {
        let p = HaloLifecyclePhase.derive(.init(observerRunning: true,
                                                endpointConnected: true,
                                                displayLive: true))
        XCTAssertEqual(p, .live)
    }

    func testEngagedMonitorIsLive() {
        let p = HaloLifecyclePhase.derive(.init(observerRunning: true,
                                                endpointConnected: true,
                                                monitorEngaged: true))
        XCTAssertEqual(p, .live)
    }

    func testSleepBeatsLive() {
        // A stale live feed cannot survive sleep — no activity is observable asleep.
        let p = HaloLifecyclePhase.derive(.init(observerRunning: true,
                                                endpointConnected: true,
                                                displayLive: true,
                                                monitorEngaged: true,
                                                systemAsleep: true))
        XCTAssertEqual(p, .suspended)
    }

    func testErrorBeatsEverythingIncludingSleep() {
        let p = HaloLifecyclePhase.derive(.init(observerRunning: true,
                                                endpointConnected: true,
                                                displayLive: true,
                                                monitorEngaged: true,
                                                systemAsleep: true,
                                                errorLabel: "MIDI"))
        XCTAssertEqual(p, .error(label: "MIDI"))
    }

    func testStatusWords() {
        XCTAssertEqual(HaloLifecyclePhase.starting.word, "STARTING")
        XCTAssertEqual(HaloLifecyclePhase.waiting.word, "WAIT")
        XCTAssertEqual(HaloLifecyclePhase.ready.word, "READY")
        XCTAssertEqual(HaloLifecyclePhase.live.word, "LIVE")
        XCTAssertEqual(HaloLifecyclePhase.suspended.word, "SLEEP")
        XCTAssertEqual(HaloLifecyclePhase.error(label: "MIDI").word, "ERR MIDI")
    }

    // MARK: - MonitorRouteReconciler

    private func snapshot(inputUID: String?, outputUID: String?) -> AudioDeviceSnapshot {
        var devices: [AudioDevice] = []
        if let inputUID {
            devices.append(AudioDevice(uid: inputUID, name: "IN", inputChannels: 2,
                                       outputChannels: 0, currentSampleRate: 48_000,
                                       supportedSampleRates: [48_000], bufferFrameRange: nil))
        }
        if let outputUID {
            devices.append(AudioDevice(uid: outputUID, name: "OUT", inputChannels: 0,
                                       outputChannels: 2, currentSampleRate: 48_000,
                                       supportedSampleRates: [48_000], bufferFrameRange: nil))
        }
        return AudioDeviceSnapshot(devices: devices, defaultInputUID: nil, defaultOutputUID: outputUID)
    }

    func testReconcilerIdleRouteNeverStops() {
        // No running route (nil UIDs) → never disturbed, even against an empty snapshot.
        XCTAssertFalse(MonitorRouteReconciler.shouldStop(
            activeInputUID: nil, activeOutputUID: nil, snapshot: .empty))
    }

    func testReconcilerBothPresentKeepsRunning() {
        let snap = snapshot(inputUID: "ep40", outputUID: "spk")
        XCTAssertFalse(MonitorRouteReconciler.shouldStop(
            activeInputUID: "ep40", activeOutputUID: "spk", snapshot: snap))
    }

    func testReconcilerStopsWhenOutputVanishes() {
        // Headphones unplugged / default output device removed.
        let snap = snapshot(inputUID: "ep40", outputUID: nil)
        XCTAssertTrue(MonitorRouteReconciler.shouldStop(
            activeInputUID: "ep40", activeOutputUID: "spk", snapshot: snap))
    }

    func testReconcilerStopsWhenInputVanishes() {
        // EP-40 yanked (audio side).
        let snap = snapshot(inputUID: nil, outputUID: "spk")
        XCTAssertTrue(MonitorRouteReconciler.shouldStop(
            activeInputUID: "ep40", activeOutputUID: "spk", snapshot: snap))
    }

    // MARK: - AudioPermission

    /// Deterministic permission double. `unchecked Sendable` for the escaping probe
    /// closure; only touched on the main actor in these tests.
    private final class MockPermissionProbe: AudioPermissionProbe, @unchecked Sendable {
        var status: AudioPermissionStatus
        let grant: Bool
        private(set) var requestCount = 0
        init(status: AudioPermissionStatus, grant: Bool = true) {
            self.status = status
            self.grant = grant
        }
        func currentStatus() -> AudioPermissionStatus { status }
        func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
            requestCount += 1
            // Reflect the grant into the reported status, like the real system.
            status = grant ? .authorized : .denied
            completion(grant)
        }
    }

    func testPermissionStatusMapping() {
        XCTAssertEqual(AudioPermissionStatus.from(.authorized), .authorized)
        XCTAssertEqual(AudioPermissionStatus.from(.denied), .denied)
        XCTAssertEqual(AudioPermissionStatus.from(.restricted), .restricted)
        XCTAssertEqual(AudioPermissionStatus.from(.notDetermined), .notDetermined)
        XCTAssertTrue(AudioPermissionStatus.authorized.allowsCapture)
        XCTAssertFalse(AudioPermissionStatus.denied.allowsCapture)
    }

    @MainActor
    func testEnsureAuthorizedGrantsImmediatelyWhenAuthorized() {
        let probe = MockPermissionProbe(status: .authorized)
        let perm = AudioPermission(probe: probe)
        var result: Bool?
        perm.ensureAuthorized { result = $0 }
        XCTAssertEqual(result, true)
        XCTAssertEqual(probe.requestCount, 0, "authorized never prompts")
    }

    @MainActor
    func testEnsureAuthorizedRefusesWhenDeniedWithoutPrompting() {
        let probe = MockPermissionProbe(status: .denied)
        let perm = AudioPermission(probe: probe)
        var result: Bool?
        perm.ensureAuthorized { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertEqual(probe.requestCount, 0, "denied is only changed in System Settings")
    }

    @MainActor
    func testEnsureAuthorizedRequestsOnceWhenUndetermined() {
        let probe = MockPermissionProbe(status: .notDetermined, grant: true)
        let perm = AudioPermission(probe: probe)
        let done = expectation(description: "grant")
        perm.ensureAuthorized { granted in
            XCTAssertTrue(granted)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(probe.requestCount, 1)
        XCTAssertEqual(perm.status, .authorized)
    }

    // MARK: - Model gating: a denied device is refused honestly (no route opens)

    @MainActor
    func testStartMonitorRefusedWhenPermissionDenied() {
        let model = HaloAppModel(permission: AudioPermission(probe: MockPermissionProbe(status: .denied)))
        model.startMonitor(inputUID: "in", outputUID: "out")
        XCTAssertEqual(model.monitor.state, .failed(.micPermission))
        XCTAssertFalse(model.monitor.isRunning)
    }

    @MainActor
    func testStartMonitorPassesPermissionGateWhenAuthorized() {
        // Authorized → the gate is cleared and the real router is asked to open. With
        // fabricated UIDs it fails at device resolution, NOT at permission — proving
        // the gate let it through.
        let model = HaloAppModel(permission: AudioPermission(probe: MockPermissionProbe(status: .authorized)))
        model.startMonitor(inputUID: "does-not-exist", outputUID: "nope")
        XCTAssertEqual(model.monitor.state, .failed(.noInputDevice))
    }

    // MARK: - Held-key release + status transitions on the model

    @MainActor
    func testConnectThenLiveNoteThenDisconnectReleasesHeldKeys() {
        let model = HaloAppModel()

        // Device connects → READY.
        model.ingest(.connection(.init(isConnected: true, displayName: "EP-40")))
        XCTAssertEqual(model.lifecyclePhase, .ready)

        // A live Note On → one visually held key, lifecycle LIVE.
        model.ingest(.event(.init(timeStamp: 0, message: .noteOn(channel: 0, note: 48, velocity: 100))))
        XCTAssertEqual(model.pressedVisualKeyCount, 1)
        XCTAssertEqual(model.lifecyclePhase, .live)

        // USB removal / disconnect → every visually pressed key released, no stuck note.
        model.ingest(.connection(.init(isConnected: false, displayName: nil)))
        XCTAssertEqual(model.pressedVisualKeyCount, 0)
        XCTAssertFalse(model.lifecyclePhase.isLive)
    }

    @MainActor
    func testSleepReleasesHeldKeysAndReportsSuspendedThenWakeRestores() {
        let model = HaloAppModel()
        model.ingest(.connection(.init(isConnected: true, displayName: "EP-40")))
        model.ingest(.event(.init(timeStamp: 0, message: .noteOn(channel: 0, note: 40, velocity: 90))))
        XCTAssertEqual(model.pressedVisualKeyCount, 1)

        model.systemWillSleep()
        XCTAssertEqual(model.pressedVisualKeyCount, 0, "no key survives sleep")
        XCTAssertEqual(model.lifecyclePhase, .suspended)
        XCTAssertFalse(model.monitor.isRunning)

        model.systemDidWake()
        // Endpoint was still connected across sleep → back to READY, not stuck asleep.
        XCTAssertEqual(model.lifecyclePhase, .ready)
    }

    @MainActor
    func testBackgroundReleasesHeldKeys() {
        let model = HaloAppModel()
        model.ingest(.connection(.init(isConnected: true, displayName: "EP-40")))
        model.ingest(.event(.init(timeStamp: 0, message: .noteOn(channel: 0, note: 55, velocity: 80))))
        XCTAssertEqual(model.pressedVisualKeyCount, 1)

        model.handleSceneBackgrounded()
        XCTAssertEqual(model.pressedVisualKeyCount, 0, "App-Nap suspension must not leave a lit pad")
    }

    // MARK: - MonitorController.fail

    @MainActor
    func testMonitorFailReflectsReasonAndStaysStopped() {
        let controller = MonitorController(engine: NoopEngine())
        controller.fail(.micPermission)
        XCTAssertEqual(controller.state, .failed(.micPermission))
        XCTAssertFalse(controller.isRunning)
    }
}

/// Minimal engine double: never runs, used to exercise controller state directly.
private final class NoopEngine: MonitorEngine, @unchecked Sendable {
    private(set) var isRunning = false
    func start(config: MonitorRouteConfig) throws { isRunning = true }
    func stop() { isRunning = false }
    func setGainDB(_ db: Double) {}
    func meterSnapshot() -> StereoLevels { .silence }
}
