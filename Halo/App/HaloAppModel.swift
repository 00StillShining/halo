import CoreAudio
import CoreMIDI
import Foundation
import SwiftUI

/// UI-facing app state plus the narrow EP-40 observation boundary used by the
/// hero model. Halo visualises documented USB MIDI facts; it does not claim to
/// mirror undocumented device menus or internal screen state.
@MainActor
@Observable
final class HaloAppModel {
    var palette: HaloPalette = .graphPaper
    let scene = EP40SceneController()

    private(set) var displayState = EP40DisplayState.previewStill
    private(set) var deviceStatus = "NO DEVICE"
    private(set) var firmwareStatus = "—"
    private(set) var usbStatus = "IDLE"
    private(set) var displayStatus = "PREVIEW"
    private(set) var midiEndpointName: String?

    var displayFeedMode: EP40DisplayFeedMode { displayState.feedMode }
    var isDisplayLive: Bool { displayState.feedMode == .live }

    private var midiObserver: EP40MIDIObserver?
    private var midiDeliveryTask: Task<Void, Never>?
    private var heldMIDIKeys: [HeldMIDIKey] = []
    private var clockCount = 0
    private var lastClockSeconds: Double?
    private var smoothedClockInterval: Double?
    private var lastNoteUptime = -Double.infinity

    /// Starts once for the application lifetime. Closing/reopening a window must
    /// not dispose the process's sole CoreMIDI client.
    func startEP40Monitoring() {
        guard midiObserver == nil else { return }
        do {
            let (stream, continuation) = AsyncStream<EP40MIDIObservation>.makeStream(
                bufferingPolicy: .bufferingNewest(512)
            )
            midiObserver = try EP40MIDIObserver { observation in
                continuation.yield(observation)
            }
            midiDeliveryTask = Task { @MainActor [weak self] in
                for await observation in stream {
                    guard let self else { return }
                    switch observation {
                    case let .connection(connection): receive(connection)
                    case let .event(event): receive(event)
                    }
                }
            }
        } catch {
            usbStatus = "MIDI ERROR"
            displayStatus = "PREVIEW"
            present(.previewStill)
        }
    }

    /// Automatic, deterministic disconnected demo. SwiftUI cancels this as
    /// soon as feed mode changes, the scene backgrounds, or Reduce Motion flips.
    func runDisplayPreview(isSceneActive: Bool, reduceMotion: Bool) async {
        guard displayFeedMode == .preview, isSceneActive else { return }
        if reduceMotion {
            present(.previewStill)
            return
        }

        var tick = 0
        while !Task.isCancelled, displayFeedMode == .preview {
            present(EP40DisplayPreviewSource.frame(at: tick))
            tick += 1
            do {
                try await Task.sleep(for: .milliseconds(166))
            } catch {
                return
            }
        }
    }

    private func receive(_ connection: EP40MIDIConnection) {
        midiEndpointName = connection.displayName
        if connection.isConnected {
            deviceStatus = "CONNECTED"
            usbStatus = "MIDI"
            displayStatus = "WAIT"
            resetClockTracking()
            present(.waiting)
        } else {
            deviceStatus = "NO DEVICE"
            usbStatus = "IDLE"
            displayStatus = "PREVIEW"
            heldMIDIKeys.removeAll(keepingCapacity: true)
            resetClockTracking()
            present(.previewStill)
        }
    }

    private func receive(_ event: EP40MIDIEvent) {
        var state = displayFeedMode == .live ? displayState : .liveIdle
        state.feedMode = .live
        state.activityStep += 1
        let firstLiveEvent = displayFeedMode != .live

        switch event.message {
        case let .noteOn(channel, note, velocity):
            let key = HeldMIDIKey(channel: channel, note: note)
            heldMIDIKeys.removeAll { $0 == key }
            heldMIDIKeys.append(key)
            lastNoteUptime = ProcessInfo.processInfo.systemUptime
            state.mode = .sound
            state.value = Int(note)
            state.velocity = Float(velocity) / 127
            state.leftMeter = state.velocity
            state.rightMeter = min(state.velocity * 0.82 + 0.08, 1)
            state.clockPulse = true

            applyPadMapping(for: note, to: &state)

        case let .noteOff(channel, note):
            let key = HeldMIDIKey(channel: channel, note: note)
            let wasFrontmost = heldMIDIKeys.last == key
            heldMIDIKeys.removeAll { $0 == key }
            if wasFrontmost, let fallback = heldMIDIKeys.last {
                state.value = Int(fallback.note)
                applyPadMapping(for: fallback.note, to: &state)
                state.velocity *= 0.64
            } else if heldMIDIKeys.isEmpty {
                state.activeGroup = nil
                state.activePadIndex = nil
                state.velocity = 0
            }
            state.leftMeter *= 0.52
            state.rightMeter *= 0.52
            state.clockPulse = false

        case let .controlChange(_, controller, value):
            state.mode = .sound
            state.value = Int(value)
            let normalised = Float(value) / 127
            if controller == 13 {
                state.rightMeter = normalised
            } else {
                state.leftMeter = normalised
            }
            state.clockPulse = controller == 12 || controller == 13

        case .start:
            resetClockTracking()
            state.mode = .main
            state.isPlaying = true
            state.clockPulse = true

        case .continuePlaying:
            state.mode = .main
            state.isPlaying = true
            state.clockPulse = true

        case .stop:
            state.mode = .main
            state.isPlaying = false
            state.clockPulse = false

        case let .songPosition(position):
            state.mode = .main
            state.value = Int(position % 1_000)
            state.activityStep = Int(position)

        case .timingClock:
            clockCount += 1
            updateTempo(from: event.timeStamp)

            // MIDI clock arrives at 24 PPQN. Redrawing every message would be
            // wasteful; eight visual updates per quarter note preserve the feel.
            if !firstLiveEvent, !clockCount.isMultiple(of: 3) { return }
            state.clockPulse = clockCount.isMultiple(of: 6)
            state.leftMeter *= 0.92
            state.rightMeter *= 0.90
            if ProcessInfo.processInfo.systemUptime - lastNoteUptime > 0.45,
               let interval = smoothedClockInterval {
                let bpm = Int((60 / (interval * 24)).rounded())
                if (30...300).contains(bpm) {
                    state.mode = .tempo
                    state.value = bpm
                }
            }
        }

        displayStatus = "LIVE"
        usbStatus = "MIDI RX"
        present(state)
    }

    private func updateTempo(from timeStamp: MIDITimeStamp) {
        let seconds: Double
        if timeStamp == 0 {
            seconds = ProcessInfo.processInfo.systemUptime
        } else {
            seconds = Double(AudioConvertHostTimeToNanos(timeStamp)) / 1_000_000_000
        }

        if let lastClockSeconds {
            let interval = seconds - lastClockSeconds
            if interval > 0.001, interval < 0.20 {
                if let previous = smoothedClockInterval {
                    smoothedClockInterval = previous * 0.84 + interval * 0.16
                } else {
                    smoothedClockInterval = interval
                }
            } else {
                smoothedClockInterval = nil
            }
        }
        lastClockSeconds = seconds
    }

    private func resetClockTracking() {
        clockCount = 0
        lastClockSeconds = nil
        smoothedClockInterval = nil
    }

    private func applyPadMapping(for note: UInt8, to state: inout EP40DisplayState) {
        // Group from note range and physical grid position are conservative,
        // documented inferences shared with the unit tests (EP40MIDIMapping).
        guard let group = EP40MIDIMapping.group(forNote: note),
              let gridIndex = EP40MIDIMapping.gridIndex(forNote: note)
        else {
            state.activeGroup = nil
            state.activePadIndex = nil
            return
        }
        state.activeGroup = group
        state.activePadIndex = gridIndex
    }

    private func present(_ state: EP40DisplayState) {
        displayState = state
        scene.applyDisplay(state)
    }
}

private struct HeldMIDIKey: Hashable {
    let channel: UInt8
    let note: UInt8
}
