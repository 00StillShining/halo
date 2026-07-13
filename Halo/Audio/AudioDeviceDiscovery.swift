import CoreAudio
import Foundation
import os

/// Live Core Audio device discovery (Brief §8, Phase 0A capability row).
///
/// Enumerates every audio device the Mac exposes, capturing STABLE UIDs (never
/// display names), input/output channel counts, current + supported nominal
/// sample rates and IO buffer-frame ranges. It installs Core Audio property
/// listeners so the published `snapshot` tracks device-list, default-device and
/// per-device sample-rate changes in real time.
///
/// Honesty (Brief §1/§4): this is read-only. It NEVER sets the system default
/// input or output — it only reflects the truth Core Audio reports. Real EP-40
/// USB-audio input verification remains needs-device; this layer works today with
/// whatever devices the machine has, and the EP-40 shows up like any other class
/// compliant device once connected.
@MainActor
@Observable
final class AudioDeviceDiscovery {
    /// The most recent picture of the machine's audio devices. Republished
    /// whole-value on every observed change so SwiftUI diffs cleanly.
    private(set) var snapshot: AudioDeviceSnapshot

    private var isRunning = false
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private let listenerQueue = DispatchQueue(label: "studios.meremortal.halo.audio.listeners")

    /// Weak bridge so the `@Sendable` Core Audio listener blocks can reach the
    /// `@MainActor` instance without retaining it (mirrors the MIDI observer).
    private final class WeakRef: @unchecked Sendable { weak var target: AudioDeviceDiscovery? }
    private let weakRef = WeakRef()

    /// Retained listener blocks, kept so we can remove exactly what we added.
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var rateBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    /// System-level property addresses we watch: the device list and the two
    /// default-device selectors. A change to any of these coalesces into a refresh.
    private static let systemAddresses: [AudioObjectPropertyAddress] = [
        address(kAudioHardwarePropertyDevices),
        address(kAudioHardwarePropertyDefaultOutputDevice),
        address(kAudioHardwarePropertyDefaultInputDevice),
    ]

    private static let rateAddress = address(kAudioDevicePropertyNominalSampleRate)

    /// Seed with a snapshot (used by previews / injected fixtures). The default is
    /// empty; `start()` performs the first real scan.
    init(snapshot: AudioDeviceSnapshot = .empty) {
        self.snapshot = snapshot
    }

    deinit {
        // Listener blocks hold only a weak ref; still, drop the bridge eagerly.
        weakRef.target = nil
    }

    /// Begin observing. Installs system listeners, does the first enumeration and
    /// wires per-device sample-rate listeners. Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        weakRef.target = self

        let box = weakRef
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // Core Audio calls this on `listenerQueue`; hop to the main actor to
            // mutate observable state.
            Task { @MainActor in box.target?.handleChange() }
        }
        systemBlock = block
        for var addr in Self.systemAddresses {
            AudioObjectAddPropertyListenerBlock(systemObject, &addr, listenerQueue, block)
        }

        refresh()
    }

    /// Stop observing and release all listener blocks.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let systemBlock {
            for var addr in Self.systemAddresses {
                AudioObjectRemovePropertyListenerBlock(systemObject, &addr, listenerQueue, systemBlock)
            }
        }
        systemBlock = nil

        for (id, block) in rateBlocks {
            var addr = Self.rateAddress
            AudioObjectRemovePropertyListenerBlock(id, &addr, listenerQueue, block)
        }
        rateBlocks.removeAll(keepingCapacity: false)
        weakRef.target = nil
    }

    /// A watched property changed → re-enumerate and reconcile rate listeners.
    private func handleChange() {
        guard isRunning else { return }
        refresh()
    }

    /// Re-read every device and republish. Also reconciles the per-device sample
    /// rate listeners against the current device set so newly-attached devices are
    /// watched and removed ones are unwatched.
    private func refresh() {
        let ids = CoreAudioEnumerator.deviceIDs()
        let devices = ids.compactMap(CoreAudioEnumerator.device(for:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        snapshot = AudioDeviceSnapshot(
            devices: devices,
            defaultInputUID: CoreAudioEnumerator.defaultDeviceUID(kAudioHardwarePropertyDefaultInputDevice),
            defaultOutputUID: CoreAudioEnumerator.defaultDeviceUID(kAudioHardwarePropertyDefaultOutputDevice)
        )

        reconcileRateListeners(currentIDs: Set(ids))
    }

    private func reconcileRateListeners(currentIDs: Set<AudioObjectID>) {
        guard isRunning else { return }

        // Remove listeners for departed devices.
        for id in Array(rateBlocks.keys) where !currentIDs.contains(id) {
            if let block = rateBlocks.removeValue(forKey: id) {
                var addr = Self.rateAddress
                AudioObjectRemovePropertyListenerBlock(id, &addr, listenerQueue, block)
            }
        }

        // Add listeners for newly-present devices.
        let box = weakRef
        for id in currentIDs where rateBlocks[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor in box.target?.handleChange() }
            }
            var addr = Self.rateAddress
            AudioObjectAddPropertyListenerBlock(id, &addr, listenerQueue, block)
            rateBlocks[id] = block
        }
    }

    #if DEBUG
    /// Seed a fixed snapshot for SwiftUI previews without touching Core Audio.
    /// Never call `start()` after this in a preview — it would overwrite the seed
    /// with the build machine's real devices.
    func previewSeed(_ snapshot: AudioDeviceSnapshot) {
        self.snapshot = snapshot
    }
    #endif

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

/// Stateless Core Audio read helpers. Every function is a pure query against the
/// HAL — no listeners, no mutation, no default-device writes. Kept `enum` +
/// `static` so it holds no state and is safe to call from `refresh()`.
enum CoreAudioEnumerator {

    static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.filter { $0 != 0 }
    }

    /// Build the pure `AudioDevice` for one HAL device id. Returns `nil` if the
    /// device has no stable UID (in which case halo cannot safely persist it).
    static func device(for id: AudioObjectID) -> AudioDevice? {
        guard let uid = cfStringProperty(id, kAudioDevicePropertyDeviceUID,
                                         scope: kAudioObjectPropertyScopeGlobal) else {
            return nil
        }
        let name = cfStringProperty(id, kAudioObjectPropertyName,
                                    scope: kAudioObjectPropertyScopeGlobal) ?? uid
        return AudioDevice(
            uid: uid,
            name: name,
            inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            currentSampleRate: nominalSampleRate(id),
            supportedSampleRates: supportedSampleRates(id),
            bufferFrameRange: bufferFrameRange(id)
        )
    }

    static func defaultDeviceUID(_ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else {
            return nil
        }
        return cfStringProperty(deviceID, kAudioDevicePropertyDeviceUID,
                                scope: kAudioObjectPropertyScopeGlobal)
    }

    // MARK: - Property reads

    private static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let listPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalSampleRate(_ id: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private static func supportedSampleRates(_ id: AudioObjectID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioValueRange>.stride
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        let status = ranges.withUnsafeMutableBytes { raw -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { return [] }

        var rates = Set<Double>()
        for range in ranges {
            if range.mMinimum == range.mMaximum {
                rates.insert(range.mMinimum)
            } else {
                // Continuous range: expose the standard rates that fall inside it.
                for candidate in standardRates where candidate >= range.mMinimum && candidate <= range.mMaximum {
                    rates.insert(candidate)
                }
            }
        }
        return rates.sorted()
    }

    private static func bufferFrameRange(_ id: AudioObjectID) -> AudioDevice.BufferFrameRange? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &range) == noErr else { return nil }
        return AudioDevice.BufferFrameRange(
            minFrames: UInt32(range.mMinimum),
            maxFrames: UInt32(range.mMaximum)
        )
    }

    private static func cfStringProperty(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static let standardRates: [Double] = [
        8_000, 11_025, 16_000, 22_050, 32_000,
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000,
    ]
}
