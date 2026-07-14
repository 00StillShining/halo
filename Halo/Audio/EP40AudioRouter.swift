import AudioToolbox
import CoreAudio
import Foundation

/// Everything a route needs to open, resolved to STABLE device UIDs (Brief §8:
/// "persist stable device UIDs, not display names").
struct MonitorRouteConfig: Sendable {
    /// EP-40 audio input UID (the capture source).
    let inputUID: String
    /// Selected Mac output UID (the monitor sink) — never the system default is
    /// changed to match it.
    let outputUID: String
    let profile: MonitorProfile
    let initialGainDB: Double
    /// Ring-glow producer shared with the RealityKit rig.
    let levelBridge: AudioLevelBridge
    /// Optional RAW-input recorder tap (P2-recorder). The input callback writes the
    /// pre-gain/pre-limiter stream here when the recorder has armed it. Nil when no
    /// recorder is attached to this route.
    let captureTap: CaptureTap?
    /// Optional dub FX rack parameter bridge (P5a-rack). Shared with the UI's
    /// `RackModel`; the output callback reads it once per block. Nil = no rack.
    let rackParams: RackParameters?
}

/// Why a route could not be opened. Surfaced honestly to the UI (Brief §1/§4) — no
/// route means the meters stay at silence and the MONITOR control reports the real
/// reason, never a faked "connected" state.
enum MonitorRouteError: Error, Equatable {
    case noInputDevice          // the EP-40 audio input is not present
    case noOutputDevice         // the chosen output UID resolved to nothing
    case micPermission          // microphone (USB-audio input) access not granted
    case componentUnavailable   // the HAL output AudioComponent is missing
    case unitCreation(OSStatus)
    case configuration(OSStatus)
    case couldNotStart(OSStatus)
}

/// Abstract monitor engine so the `@MainActor` `MonitorController` can be unit-
/// tested with a mock and the production `EP40AudioRouter` can own the real
/// AudioUnits. DEVICE-GATED: the live route needs the physical EP-40, so tests use
/// a mock; only the mock path is exercised in CI (Brief loop rules).
protocol MonitorEngine: AnyObject {
    var isRunning: Bool { get }
    func start(config: MonitorRouteConfig) throws
    func stop()
    func setGainDB(_ db: Double)
    func meterSnapshot() -> StereoLevels
}

/// Production monitor route (Brief §8): an input-only AUHAL for the EP-40 and a
/// separate output AUHAL for the chosen Mac output, bridged through the
/// preallocated `AudioRingBuffer`, without ever changing the system default
/// devices. Monitoring begins only when `start` is called (an explicit user
/// action, defaulting to −12 dB) and stops promptly on `stop` or USB removal.
///
/// NEEDS-DEVICE: live audio through real hardware cannot be verified here — that
/// requires the physical EP-40 plus a separate Mac output and a 30-minute
/// stability soak (Brief §8). The AUHAL wiring is the production path; its live
/// behaviour is validated on hardware. All timing/DSP building blocks
/// (`AudioRingBuffer`, `SafetyLimiter`, `MonitorGain`, `AudioMeter`,
/// `DriftController`, `FeedbackGuard`, `MonitorProfile`) are unit-tested without
/// hardware.
final class EP40AudioRouter: MonitorEngine, @unchecked Sendable {
    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var context: MonitorRenderContext?
    private var contextRef: Unmanaged<MonitorRenderContext>?

    private(set) var isRunning = false

    func start(config: MonitorRouteConfig) throws {
        stop()   // idempotent restart

        guard let inputDevice = Self.deviceID(forUID: config.inputUID),
              Self.channelCount(inputDevice, scope: kAudioObjectPropertyScopeInput) > 0 else {
            throw MonitorRouteError.noInputDevice
        }
        guard let outputDevice = Self.deviceID(forUID: config.outputUID),
              Self.channelCount(outputDevice, scope: kAudioObjectPropertyScopeOutput) > 0 else {
            throw MonitorRouteError.noOutputDevice
        }

        // Match the route format to the output device's nominal rate; each AUHAL's
        // built-in SRC reconciles its hardware to that rate. HONEST LIMIT: slow
        // cross-clock drift (ppm clock differences filling/emptying the ring over
        // long sessions) is NOT yet corrected on the live stream — DriftController /
        // DriftCompensatingConverter are built and unit-tested, but wiring a
        // varispeed stage into this render path and tuning it needs two real
        // clocks to observe (needs-device, Phase 0A soak). Until then an extreme
        // fill excursion degrades to a bounded drop/silence-fill, never a crash.
        let sampleRate = Self.nominalSampleRate(outputDevice) ?? 48_000
        let frames = Int(config.profile.frames)

        let ctx = MonitorRenderContext(
            sampleRate: sampleRate,
            maxFrames: max(frames, 512),
            initialGainDB: config.initialGainDB,
            levelBridge: config.levelBridge,
            captureTap: config.captureTap,
            rackParams: config.rackParams)
        let ref = Unmanaged.passUnretained(ctx)
        let refcon = ref.toOpaque()

        // Best-effort IO buffer size on both devices (clamped to their ranges by
        // the caller's profile; the HAL clamps again).
        Self.setBufferFrameSize(inputDevice, frames: config.profile.frames)
        Self.setBufferFrameSize(outputDevice, frames: config.profile.frames)

        do {
            // Keep the context and each unit registered the moment they exist so
            // the `catch { stop() }` below disposes everything on ANY failure —
            // a late `makeOutputUnit`/start error must not leak the input unit.
            context = ctx
            contextRef = ref

            let input = try Self.makeInputUnit(device: inputDevice, format: ctx.format,
                                               maxFrames: ctx.maxFrames, refcon: refcon)
            inputUnit = input
            ctx.inputUnit = input
            let output = try Self.makeOutputUnit(device: outputDevice, format: ctx.format,
                                                 maxFrames: ctx.maxFrames, refcon: refcon)
            outputUnit = output

            ctx.ringBuffer.drain()

            let s1 = AudioOutputUnitStart(input)
            guard s1 == noErr else { throw MonitorRouteError.couldNotStart(s1) }
            let s2 = AudioOutputUnitStart(output)
            guard s2 == noErr else { throw MonitorRouteError.couldNotStart(s2) }
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let inputUnit {
            AudioOutputUnitStop(inputUnit)
            AudioUnitUninitialize(inputUnit)
            AudioComponentInstanceDispose(inputUnit)
        }
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
        }
        inputUnit = nil
        outputUnit = nil
        context?.meter.reset()
        context = nil
        contextRef = nil
        isRunning = false
    }

    func setGainDB(_ db: Double) {
        context?.setGainTargetDB(db)
    }

    func meterSnapshot() -> StereoLevels {
        context?.meter.snapshot() ?? .silence
    }

    // MARK: - AudioUnit construction

    private static func halComponent() throws -> AudioComponent {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw MonitorRouteError.componentUnavailable
        }
        return comp
    }

    private static func makeInputUnit(device: AudioDeviceID,
                                      format: AudioStreamBasicDescription,
                                      maxFrames: Int,
                                      refcon: UnsafeMutableRawPointer) throws -> AudioUnit {
        let comp = try halComponent()
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &unit))
        guard let unit else { throw MonitorRouteError.unitCreation(-1) }

        do {
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            // Enable input (bus 1), disable output (bus 0).
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)))
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)))
            var dev = device
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)))
            var fmt = format
            // Client format on the OUTPUT scope of the input bus (what the callback receives).
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Output, 1, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            var maxF = UInt32(maxFrames)
            AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                 kAudioUnitScope_Global, 0, &maxF, UInt32(MemoryLayout<UInt32>.size))

            var cb = AURenderCallbackStruct(inputProc: monitorInputRender, inputProcRefCon: refcon)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                           kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try check(AudioUnitInitialize(unit))
        } catch {
            // Configuration failed mid-way: dispose the instance so a failed
            // start never leaks a live AudioComponent instance.
            AudioComponentInstanceDispose(unit)
            throw error
        }
        return unit
    }

    private static func makeOutputUnit(device: AudioDeviceID,
                                       format: AudioStreamBasicDescription,
                                       maxFrames: Int,
                                       refcon: UnsafeMutableRawPointer) throws -> AudioUnit {
        let comp = try halComponent()
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &unit))
        guard let unit else { throw MonitorRouteError.unitCreation(-1) }

        do {
            var dev = device
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)))
            var fmt = format
            // Client format on the INPUT scope of the output bus (what we hand the unit).
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            var maxF = UInt32(maxFrames)
            AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                 kAudioUnitScope_Global, 0, &maxF, UInt32(MemoryLayout<UInt32>.size))

            var cb = AURenderCallbackStruct(inputProc: monitorOutputRender, inputProcRefCon: refcon)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try check(AudioUnitInitialize(unit))
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        return unit
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw MonitorRouteError.configuration(status) }
    }

    // MARK: - Core Audio device queries

    /// Translate a stable device UID to its (non-persistable) live AudioDeviceID.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var outSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let inSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &address, inSize, uidPtr, &outSize, &device)
        }
        guard status == noErr, device != 0 else { return nil }
        return device
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    private static func setBufferFrameSize(_ id: AudioDeviceID, frames: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = frames
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
