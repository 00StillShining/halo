import XCTest
@testable import Halo

/// Pins the remaining pure pieces of the monitor path: the monitor gain, the drift
/// controller, the buffer profiles, the feedback guard and the controller's honest
/// state machine (via a mock engine — live audio is needs-device).
final class MonitorPathTests: XCTestCase {

    // MARK: MonitorGain

    func testGainDBToLinearLandmarks() {
        XCTAssertEqual(MonitorGain.linear(fromDB: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(MonitorGain.linear(fromDB: -6), 0.5012, accuracy: 1e-3)
        XCTAssertEqual(MonitorGain.linear(fromDB: -12), 0.2512, accuracy: 1e-3)
        XCTAssertEqual(MonitorGain.linear(fromDB: -60), 0, "floor is true silence")
        XCTAssertEqual(MonitorGain.linear(fromDB: -80), 0)
    }

    func testGainConvergesToTarget() {
        var gain = MonitorGain(db: -12, sampleRate: 48_000)
        gain.setTargetDB(0)
        // Process well past the 20 ms ramp (1 s) so it settles onto the target.
        var buf = [Float](repeating: 1, count: 48_000 * 2)
        buf.withUnsafeMutableBufferPointer { gain.processStereo($0.baseAddress!, frames: 48_000) }
        XCTAssertEqual(gain.currentLinear, 1, accuracy: 1e-3, "ramps up to unity")
        XCTAssertEqual(buf.last!, 1, accuracy: 1e-3)
    }

    func testGainAtUnityIsTransparent() {
        var gain = MonitorGain(db: 0, sampleRate: 48_000)
        var buf: [Float] = [0.3, -0.4, 0.5, -0.6]
        let original = buf
        buf.withUnsafeMutableBufferPointer { gain.processStereo($0.baseAddress!, frames: 2) }
        for (a, b) in zip(original, buf) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    // MARK: DriftController

    func testDriftRatioDirectionAndClamp() {
        let ctrl = DriftController(maxDeviation: 0.002, strength: 0.05, targetFraction: 0.5)
        // Half-full → no correction.
        XCTAssertEqual(ctrl.ratio(fill: 50, capacity: 100), 1, accuracy: 1e-9)
        // Too full → consume faster (>1).
        XCTAssertGreaterThan(ctrl.ratio(fill: 100, capacity: 100), 1)
        // Too empty → consume slower (<1).
        XCTAssertLessThan(ctrl.ratio(fill: 0, capacity: 100), 1)
        // Never beyond the deviation clamp.
        XCTAssertLessThanOrEqual(ctrl.ratio(fill: 100, capacity: 100), 1.002 + 1e-9)
        XCTAssertGreaterThanOrEqual(ctrl.ratio(fill: 0, capacity: 100), 0.998 - 1e-9)
    }

    func testDriftRatioIsGentle() {
        let ctrl = DriftController()
        // A mild imbalance produces a parts-per-thousand nudge, not a pitch shift.
        let r = ctrl.ratio(fill: 60, capacity: 100)
        XCTAssertLessThan(abs(r - 1), 0.01)
    }

    // MARK: MonitorProfile

    func testProfileFrames() {
        XCTAssertEqual(MonitorProfile.low.frames, 128)
        XCTAssertEqual(MonitorProfile.balanced.frames, 256)
        XCTAssertEqual(MonitorProfile.safe.frames, 512)
        XCTAssertEqual(MonitorProfile.default, .balanced)
    }

    func testProfileClampsToDeviceRange() {
        let tight = AudioDevice.BufferFrameRange(minFrames: 256, maxFrames: 256)
        XCTAssertEqual(MonitorProfile.low.frames(clampedTo: tight), 256)
        XCTAssertEqual(MonitorProfile.safe.frames(clampedTo: tight), 256)
        let wide = AudioDevice.BufferFrameRange(minFrames: 16, maxFrames: 4096)
        XCTAssertEqual(MonitorProfile.low.frames(clampedTo: wide), 128)
        XCTAssertEqual(MonitorProfile.low.frames(clampedTo: nil), 128)
    }

    // MARK: FeedbackGuard

    func testFeedbackGuard() {
        XCTAssertTrue(FeedbackGuard.wouldFeedBack(inputUID: "EP40", outputUID: "EP40"))
        XCTAssertFalse(FeedbackGuard.wouldFeedBack(inputUID: "EP40", outputUID: "Speakers"))
        XCTAssertFalse(FeedbackGuard.wouldFeedBack(inputUID: nil, outputUID: "EP40"))
        XCTAssertFalse(FeedbackGuard.wouldFeedBack(inputUID: "EP40", outputUID: nil))
    }

    // MARK: MonitorController state machine (mock engine)

    @MainActor
    func testControllerStartsRunningWithMockEngine() {
        let engine = MockMonitorEngine()
        let controller = MonitorController(engine: engine)
        XCTAssertFalse(controller.isRunning)

        controller.start(inputUID: "EP40-IN", outputUID: "SPK")
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(controller.state, .running)
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertEqual(engine.lastConfig?.initialGainDB, MonitorGain.defaultDB, "defaults to −12 dB")

        controller.stop()
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.levels, .silence, "meter drops to silence when stopped")
    }

    @MainActor
    func testControllerMissingInputFailsHonestly() {
        let engine = MockMonitorEngine()
        let controller = MonitorController(engine: engine)
        controller.start(inputUID: nil, outputUID: "SPK")
        XCTAssertEqual(controller.state, .failed(.noInputDevice))
        XCTAssertEqual(engine.startCount, 0, "no engine start attempted without an input")
        XCTAssertFalse(controller.isRunning)
    }

    @MainActor
    func testControllerSurfacesEngineFailure() {
        let engine = MockMonitorEngine()
        engine.startError = .couldNotStart(-10875)
        let controller = MonitorController(engine: engine)
        controller.start(inputUID: "EP40-IN", outputUID: "SPK")
        XCTAssertEqual(controller.state, .failed(.couldNotStart(-10875)))
        XCTAssertFalse(controller.isRunning)
    }

    @MainActor
    func testControllerGainForwardsToEngine() {
        let engine = MockMonitorEngine()
        let controller = MonitorController(engine: engine)
        controller.gainDB = -3
        XCTAssertEqual(engine.lastGainDB, -3)
    }
}

/// In-memory `MonitorEngine` double so the controller's honesty/state machine is
/// tested without any Core Audio hardware (device-gated live route excluded).
private final class MockMonitorEngine: MonitorEngine, @unchecked Sendable {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var lastConfig: MonitorRouteConfig?
    private(set) var lastGainDB: Double?
    var startError: MonitorRouteError?

    func start(config: MonitorRouteConfig) throws {
        if let startError { throw startError }
        lastConfig = config
        startCount += 1
        isRunning = true
    }

    func stop() { isRunning = false }
    func setGainDB(_ db: Double) { lastGainDB = db }
    func meterSnapshot() -> StereoLevels { .silence }
}
