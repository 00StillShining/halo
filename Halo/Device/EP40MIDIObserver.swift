import CoreMIDI
import Foundation
import os

struct EP40MIDIConnection: Sendable, Equatable {
    let isConnected: Bool
    let displayName: String?
}

enum EP40MIDIMessage: Sendable, Equatable {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case timingClock
    case start
    case continuePlaying
    case stop
    case songPosition(UInt16)
}

struct EP40MIDIEvent: Sendable, Equatable {
    let timeStamp: MIDITimeStamp
    let message: EP40MIDIMessage
}

enum EP40MIDIObservation: Sendable, Equatable {
    case connection(EP40MIDIConnection)
    case event(EP40MIDIEvent)
}

enum EP40MIDIObserverError: Error {
    case client(OSStatus)
    case inputPort(OSStatus)
}

private struct EP40MIDIEndpointInfo: Sendable {
    let reference: MIDIEndpointRef
    let rawDisplayName: String?
    let rawName: String?
    let manufacturer: String?
    let model: String?
    let isOffline: Bool

    var displayName: String { rawDisplayName ?? rawName ?? "Unnamed MIDI Source" }
}

private final class EP40MIDICallbackBox: @unchecked Sendable {
    weak var owner: EP40MIDIObserver?
}

private struct EP40MIDIVisitContext {
    let owner: Unmanaged<EP40MIDIObserver>
}

private func ep40MIDIEventVisitor(
    _ rawContext: UnsafeMutableRawPointer?,
    _ timeStamp: MIDITimeStamp,
    _ message: MIDIUniversalMessage
) {
    guard let rawContext else { return }
    let context = rawContext.assumingMemoryBound(to: EP40MIDIVisitContext.self).pointee
    context.owner.takeUnretainedValue().receive(message, at: timeStamp)
}

/// A fixed-capacity, allocation-free-on-send mailbox between CoreMIDI's
/// high-priority callback and Halo's ordinary serial delivery queue.
private final class EP40MIDIObservationMailbox: @unchecked Sendable {
    typealias Handler = @Sendable (EP40MIDIObservation) -> Void

    private struct Buffer: Sendable {
        var values = Array<EP40MIDIObservation?>(repeating: nil, count: 512)
        var readIndex = 0
        var writeIndex = 0
    }

    private let buffer = OSAllocatedUnfairLock(initialState: Buffer())
    private let handler: Handler
    private var signal: DispatchSourceUserDataAdd!

    init(handler: @escaping Handler) {
        self.handler = handler
        let signal = DispatchSource.makeUserDataAddSource(
            queue: DispatchQueue(label: "studios.meremortal.halo.midi.delivery")
        )
        self.signal = signal
        signal.setEventHandler { [weak self] in self?.drain() }
        signal.resume()
    }

    deinit {
        signal.setEventHandler {}
        signal.cancel()
    }

    func send(_ observation: EP40MIDIObservation) {
        buffer.withLock { buffer in
            let next = (buffer.writeIndex + 1) % buffer.values.count
            if next == buffer.readIndex {
                // Latest information is more useful than an unbounded backlog.
                buffer.values[buffer.readIndex] = nil
                buffer.readIndex = (buffer.readIndex + 1) % buffer.values.count
            }
            buffer.values[buffer.writeIndex] = observation
            buffer.writeIndex = next
        }
        signal.add(data: 1)
    }

    private func drain() {
        while let observation = pop() { handler(observation) }
    }

    private func pop() -> EP40MIDIObservation? {
        buffer.withLock { buffer in
            guard buffer.readIndex != buffer.writeIndex else { return nil }
            let value = buffer.values[buffer.readIndex]
            buffer.values[buffer.readIndex] = nil
            buffer.readIndex = (buffer.readIndex + 1) % buffer.values.count
            return value
        }
    }
}

/// App-lifetime CoreMIDI observer. It connects only to an endpoint whose
/// published name/model identifies an EP-40 or Riddim, so unrelated controllers
/// cannot accidentally animate the replica.
final class EP40MIDIObserver: @unchecked Sendable {
    typealias ObservationHandler = @Sendable (EP40MIDIObservation) -> Void

    private let mailbox: EP40MIDIObservationMailbox
    private let callbacks = EP40MIDICallbackBox()
    private let managementQueue = DispatchQueue(label: "studios.meremortal.halo.midi.endpoints")

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connected = Set<MIDIEndpointRef>() // managementQueue only
    private var lastConnection: EP40MIDIConnection? // managementQueue only
    private var retryAttempt = 0 // managementQueue only

    init(onObservation: @escaping ObservationHandler) throws {
        mailbox = EP40MIDIObservationMailbox(handler: onObservation)

        let clientStatus = MIDIClientCreateWithBlock(
            "Halo EP-40" as CFString,
            &client
        ) { [callbacks] notification in
            callbacks.owner?.handleNotification(notification.pointee.messageID)
        }
        guard clientStatus == noErr else {
            throw EP40MIDIObserverError.client(clientStatus)
        }

        let portStatus = MIDIInputPortCreateWithProtocol(
            client,
            "Halo EP-40 Input" as CFString,
            ._1_0,
            &inputPort
        ) { [callbacks] eventList, _ in
            guard let owner = callbacks.owner else { return }
            var context = EP40MIDIVisitContext(owner: .passUnretained(owner))
            withUnsafeMutablePointer(to: &context) { pointer in
                MIDIEventListForEachEvent(eventList, ep40MIDIEventVisitor, pointer)
            }
        }
        guard portStatus == noErr else {
            MIDIClientDispose(client)
            client = 0
            throw EP40MIDIObserverError.inputPort(portStatus)
        }

        // Do not expose self to notification/receive callbacks until both CoreMIDI
        // objects are completely initialized.
        callbacks.owner = self
        scheduleRefresh()
    }

    deinit {
        callbacks.owner = nil
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    private func handleNotification(_ id: MIDINotificationMessageID) {
        switch id {
        case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
            scheduleRefresh()
        case .msgIOError:
            scheduleIOReset()
        default:
            break
        }
    }

    private func scheduleRefresh() {
        managementQueue.async { [weak self] in
            self?.refreshEndpoints()
        }
    }

    private func scheduleIOReset() {
        managementQueue.async { [weak self] in
            guard let self else { return }
            for endpoint in connected {
                MIDIPortDisconnectSource(inputPort, endpoint)
            }
            connected.removeAll(keepingCapacity: true)
            publishConnection(from: [:])
            managementQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refreshEndpoints()
            }
        }
    }

    private func refreshEndpoints() {
        var current: [MIDIEndpointRef: EP40MIDIEndpointInfo] = [:]
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }
            let info = Self.endpointInfo(endpoint)
            if !info.isOffline, Self.isEP40(info) { current[endpoint] = info }
        }

        let removed = connected.filter { current[$0] == nil }
        for endpoint in removed {
            MIDIPortDisconnectSource(inputPort, endpoint)
            connected.remove(endpoint)
        }

        var connectFailed = false
        for endpoint in current.keys where !connected.contains(endpoint) {
            if MIDIPortConnectSource(inputPort, endpoint, nil) == noErr {
                connected.insert(endpoint)
            } else {
                connectFailed = true
            }
        }

        publishConnection(from: current)

        if connectFailed, retryAttempt < 5 {
            retryAttempt += 1
            let delay = min(pow(2.0, Double(retryAttempt - 1)) * 0.25, 4)
            managementQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshEndpoints()
            }
        } else if !connectFailed {
            retryAttempt = 0
        }
    }

    private func publishConnection(from current: [MIDIEndpointRef: EP40MIDIEndpointInfo]) {
        let firstConnected = current.values
            .filter { connected.contains($0.reference) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .first
        let connection = EP40MIDIConnection(
            isConnected: firstConnected != nil,
            displayName: firstConnected?.displayName
        )
        if connection != lastConnection {
            lastConnection = connection
            mailbox.send(.connection(connection))
        }
    }

    private static func isEP40(_ endpoint: EP40MIDIEndpointInfo) -> Bool {
        let identity = [endpoint.rawDisplayName, endpoint.rawName, endpoint.model, endpoint.manufacturer]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return identity.contains("ep-40")
            || identity.contains("ep 40")
            || identity.contains("ep40")
            || identity.contains("riddim")
    }

    private static func endpointInfo(_ endpoint: MIDIEndpointRef) -> EP40MIDIEndpointInfo {
        let display = stringProperty(endpoint, kMIDIPropertyDisplayName)
        let name = stringProperty(endpoint, kMIDIPropertyName)
        var offline: Int32 = 0
        let isOffline = MIDIObjectGetIntegerProperty(
            endpoint,
            kMIDIPropertyOffline,
            &offline
        ) == noErr && offline != 0
        return EP40MIDIEndpointInfo(
            reference: endpoint,
            rawDisplayName: display,
            rawName: name,
            manufacturer: stringProperty(endpoint, kMIDIPropertyManufacturer),
            model: stringProperty(endpoint, kMIDIPropertyModel),
            isOffline: isOffline
        )
    }

    private static func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String? {
        var unmanaged: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &unmanaged) == noErr,
              let unmanaged
        else { return nil }
        return unmanaged.takeRetainedValue() as String
    }

    fileprivate func receive(_ message: MIDIUniversalMessage, at timeStamp: MIDITimeStamp) {
        let decoded: EP40MIDIMessage?

        switch message.type {
        case .channelVoice1:
            let channel = message.channelVoice1.channel
            switch message.channelVoice1.status {
            case .noteOn:
                let note = message.channelVoice1.note.number
                let velocity = message.channelVoice1.note.velocity
                decoded = velocity == 0
                    ? .noteOff(channel: channel, note: note)
                    : .noteOn(channel: channel, note: note, velocity: velocity)
            case .noteOff:
                decoded = .noteOff(
                    channel: channel,
                    note: message.channelVoice1.note.number
                )
            case .controlChange:
                decoded = .controlChange(
                    channel: channel,
                    controller: message.channelVoice1.controlChange.index,
                    value: message.channelVoice1.controlChange.data
                )
            default:
                decoded = nil
            }

        case .system:
            switch message.system.status {
            case .statusTimingClock: decoded = .timingClock
            case .statusStart: decoded = .start
            case .statusContinue: decoded = .continuePlaying
            case .statusStop: decoded = .stop
            case .statusSongPosPointer: decoded = .songPosition(message.system.songPositionPointer)
            default: decoded = nil
            }

        default:
            decoded = nil
        }

        if let decoded {
            // The high-priority CoreMIDI callback performs compact decoding and
            // one bounded mailbox write. SwiftUI delivery happens elsewhere.
            mailbox.send(.event(.init(timeStamp: timeStamp, message: decoded)))
        }
    }
}
