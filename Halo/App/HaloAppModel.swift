import AppKit
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
    let scene: EP40SceneController

    /// LOAD-mode UI state (Brief §7). UI-only, same honesty class as `mode` — it
    /// never touches displayState / ringState / MIDI (DD-013/DD-014).
    let load = LoadSession()

    /// EDIT-mode UI state (Brief §7, DD-022). LOCAL sample library + non-destructive
    /// prep; pad target is MOCK device context. UI-only, same honesty class as `load`.
    let edit = EditSession()

    /// LOCAL sample audition (Brief §7). Plays a prepared buffer to the SYSTEM DEFAULT
    /// output — deliberately separate from the EP-40 monitor route (DD-022), claims
    /// nothing about the device.
    let audition = AuditionPlayer()

    /// Core Audio device discovery + the user's persisted monitor-output choice
    /// (Brief §8). Read-only: discovery reflects real devices and never changes
    /// the system default; selection persists a stable UID for the Phase 2 route.
    let audioDevices = AudioDeviceDiscovery()
    let audioOutput = AudioOutputSelection()

    /// Monitor route lifecycle (Brief §8). Owns the AUHAL engine, −12 dB-default
    /// gain, LOW/BALANCED/SAFE profile and the honest meter feed. Monitoring starts
    /// only on explicit user action; the meter rests at silence otherwise.
    /// Constructed in `init` so its ring-glow feed is the SAME `AudioLevelBridge`
    /// instance the scene's `HaloRingRig` reads (a private bridge would publish
    /// real peaks into a dead end).
    let monitor: MonitorController

    /// RAW pre-monitor recorder tap (P2-recorder, DD-018). The SAME instance is
    /// shared with the `MonitorController` (so the input callback fills it) and the
    /// `SessionRecorder` (so the drain thread consumes it) — identical ownership to
    /// the scene's `audioLevelBridge`.
    let captureTap = CaptureTap()
    /// Local library of captured takes (files on disk).
    let takes = TakesStore()
    /// Session recorder lifecycle. Records the raw input while a monitor route runs.
    let recorder: SessionRecorder

    /// Local backup-snapshot index (Brief §7 Backups). Scans `Backups/` for dated
    /// snapshot folders. Empty until a verified device layer (Phase 0B) can read
    /// samples off the EP-40 — halo never fabricates a snapshot.
    let backups = BackupStore()

    /// Recoverable-writes journal (Brief §7/§8). Wired now so the eventual device
    /// layer records every reversible operation through one audited path; rests
    /// empty until a real device write occurs.
    let journal = OperationJournal()

    /// Device-restore seam (Brief §7). NEEDS-DEVICE: writing samples back onto the
    /// EP-40 is the proprietary protocol (Phase 0B), so the default honestly reports
    /// that restore needs a connected device and changes nothing.
    let restorer: any BackupRestoring = DeviceUnavailableRestorer()

    /// Microphone (USB-audio input) authorisation (Brief §8). Gates an explicit
    /// monitor start and is surfaced honestly — a denied device can never be shown
    /// as monitoring. Injectable so the gating is unit-tested with a mock probe.
    let permission: AudioPermission

    init(permission: AudioPermission = AudioPermission()) {
        // Create the canonical on-disk layout up front (Brief §8) so every
        // subsystem has its folder before it writes.
        HaloFileStore.ensureAll()
        let sceneController = EP40SceneController()
        scene = sceneController
        monitor = MonitorController(levelBridge: sceneController.audioLevelBridge,
                                    captureTap: captureTap)
        recorder = SessionRecorder(tap: captureTap, takes: takes)
        self.permission = permission
    }

    /// The running route's sample rate = the resolved output device's nominal rate.
    /// The recorder writes its WAV at this rate so the file matches the route (never
    /// a guessed rate). Nil when no output device resolves.
    var activeRouteSampleRate: Double? {
        audioOutput.resolution(in: audioDevices.snapshot).device?.currentSampleRate
    }

    /// ⌘R / RECORD (Brief §7). Toggles the recorder, gated on an active monitor
    /// route: the raw pre-monitor stream only exists while the input AUHAL runs
    /// (DD-018). Refuses honestly (no-op) when the route is off — the UI shows the
    /// real reason. Refreshes the halo ring so `.recording` truth is never stale.
    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            guard monitor.isRunning else { return }
            recorder.start(sampleRate: activeRouteSampleRate ?? 48_000)
        }
        refreshRingState()
    }

    /// Start the monitor route (explicit user action, Brief §8) and reflect the
    /// engaged-truth on the halo ring. Gated on microphone authorisation: capturing
    /// the EP-40 USB-audio input trips the same TCC gate as a mic, so a denied
    /// device is refused honestly (the route would only capture silence) rather than
    /// shown as monitoring. Undetermined prompts once; the route opens only on grant.
    /// All monitor start/stop goes through these wrappers so `ringState` never lags.
    func startMonitor(inputUID: String?, outputUID: String?) {
        permission.ensureAuthorized { [weak self] granted in
            guard let self else { return }
            if granted {
                self.monitor.start(inputUID: inputUID, outputUID: outputUID)
            } else {
                // Honest refusal: no route opens; the UI shows the real reason.
                self.monitor.fail(.micPermission)
            }
            self.refreshRingState()
            self.refreshLifecycle()
        }
    }

    func stopMonitor() {
        // Stopping the monitor ends the raw input stream, so finalize any take
        // first (valid WAV) rather than leaving a dangling recorder (DD-018).
        recorder.finishIfRecording()
        monitor.stop()
        refreshRingState()
        refreshLifecycle()
    }

    /// SPACE / AUDITION (Brief §7). Toggles LOCAL playback of the prepared+treated
    /// selected sample to the system default output. Honest: an empty selection or a
    /// failed engine start is a no-op. Not the EP-40 route (DD-022) — no device claim.
    func toggleAudition() {
        if audition.isPlaying {
            audition.stop()
        } else {
            Task { @MainActor in
                if let buffer = await edit.auditionBuffer(), let id = edit.selectedAssetID {
                    audition.play(buffer, assetID: id)
                }
            }
        }
    }

    /// EDIT pad target (Brief §7). Sets the mock destination pad and eases the camera
    /// toward it (or back to the mode framing when cleared). Presentation only (DD-013);
    /// never releases pads or touches display / ring state.
    func selectEditPad(gridIndex: Int?) {
        edit.setPadTarget(gridIndex: gridIndex)
        if let gridIndex {
            scene.focusCamera(onPadGridIndex: gridIndex)
        } else {
            scene.focusCamera(for: .edit)
        }
    }

    // MARK: - Shell (Brief §7). UI-only state — a mode switch never touches
    // displayState / ringState / MIDI paths, so it cannot disturb PREVIEW / WAIT
    // / LIVE provenance (DD-013).

    private(set) var mode: HaloMode = .play      // Play is the daily default
    var isPlayRailCollapsed = true               // Play: the model is the hero by default
    let rackAvailable = false                    // flips at Phase 5a
    let transients = TransientCoordinator()

    /// Switch modes. Ignores no-ops and any mode not currently in the mode bar.
    /// Re-frames the hero model (camera move) — it never releases pads or touches
    /// display / ring state.
    func select(_ mode: HaloMode) {
        guard mode != self.mode,
              HaloMode.visible(rackAvailable: rackAvailable).contains(mode) else { return }
        self.mode = mode
        scene.focusCamera(for: mode)
    }

    /// Owner picks a palette at the Phase 1 visual gate. Recolours the 3D focus
    /// rims to match; the SwiftUI subtree recolours through `\.halo` automatically.
    func selectPalette(_ palette: HaloPalette) {
        guard palette != self.palette else { return }
        self.palette = palette
        scene.applyPalette(palette)
    }

    private(set) var displayState = EP40DisplayState.previewStill
    /// Halo-ring state, derived only from connection/monitor/record truth
    /// (Brief §5). Never derived from `displayState` preview/demo frames.
    private(set) var ringState: HaloRingState = .disconnected
    /// Coarse connection lifecycle for the status strip (Brief §8): STARTING / WAIT
    /// / READY / LIVE / SLEEP / ERROR. Same honest inputs as the ring, phrased as a
    /// connection state. Starts at `.starting` (no observer running yet).
    private(set) var lifecyclePhase: HaloLifecyclePhase = .starting
    private(set) var deviceStatus = "NO DEVICE"
    private(set) var firmwareStatus = "—"
    private(set) var usbStatus = "IDLE"
    private(set) var displayStatus = "PREVIEW"
    private(set) var midiEndpointName: String?

    var displayFeedMode: EP40DisplayFeedMode { displayState.feedMode }
    var isDisplayLive: Bool { displayState.feedMode == .live }

    private var midiObserver: EP40MIDIObserver?
    /// The only real ring failure reachable today (CoreMIDI client setup). Real
    /// failures only — never a decorative error (Brief §4).
    private var ringErrorLabel: String?
    /// Last observed endpoint-connected truth; the ring reads this, not strings.
    private var endpointConnected = false
    private var midiDeliveryTask: Task<Void, Never>?
    private var heldMIDIKeys: [HeldMIDIKey] = []
    private var clockCount = 0
    private var lastClockSeconds: Double?
    private var smoothedClockInterval: Double?
    private var lastNoteUptime = -Double.infinity
    /// True inside a system sleep window (between `willSleep` and `didWake`). While
    /// asleep no MIDI/audio can be observed, so held keys are released and the route
    /// is stopped; the lifecycle reports `.suspended`.
    private var systemAsleep = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    /// Begin Core Audio device discovery for the output picker (Brief §8). Read
    /// only — installs property listeners and reflects real devices; it never
    /// changes the system default input/output. Idempotent for the app lifetime.
    func startAudioDeviceDiscovery() {
        // Reconcile a running route against every fresh snapshot (default-output
        // change, device removal) — Brief §8.
        audioDevices.onChange = { [weak self] in self?.reconcileAudioDevices() }
        audioDevices.start()
    }

    /// Observe system sleep/wake (Brief §8). Sleep tears down inputs and releases
    /// held keys promptly; wake restores the lifecycle read but never auto-restarts
    /// monitoring (that stays an explicit user action). Idempotent; app-lifetime.
    func startLifecycleObservers() {
        guard sleepObserver == nil else { return }
        permission.refresh()
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification,
                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
        refreshLifecycle()
    }

    /// System is going to sleep. Stop audio units promptly, finalize any take into a
    /// valid WAV first, and release every visually pressed key — a pad still lit or a
    /// route still "running" across sleep would be a faked hardware state (Brief §1/
    /// §4/§8). A live display drops to WAIT since no activity can be observed asleep.
    func systemWillSleep() {
        systemAsleep = true
        recorder.finishIfRecording()
        monitor.stop()
        // Audition is local, but a stuck engine across sleep is sloppy — stop it too.
        audition.stop()
        releaseAllHeldKeys()
        resetClockTracking()
        if displayFeedMode == .live {
            displayStatus = "WAIT"
            present(.waiting)
        }
        if endpointConnected { usbStatus = "SLEEP" }
        refreshRingState()
        refreshLifecycle()
    }

    /// System woke. Clear the suspend flag and re-read the lifecycle; audio-device
    /// discovery re-publishes on its own listeners. Monitoring is NOT auto-restarted
    /// (Brief §8: it begins only after an explicit user action).
    func systemDidWake() {
        systemAsleep = false
        permission.refresh()
        if endpointConnected {
            usbStatus = "MIDI"
            displayStatus = "WAIT"
            if displayFeedMode != .live { present(.waiting) }
        }
        refreshRingState()
        refreshLifecycle()
    }

    /// App was hidden / suspended (scene phase → background). App Nap can throttle
    /// MIDI delivery, so a pad lit from a Note On whose Note Off we may miss would
    /// stick. Drop every visually pressed key to a known state; MIDI still drives
    /// them again on return. Merely losing key-window focus (`.inactive`) does NOT
    /// release — events keep flowing there, so the held state stays honest.
    func handleSceneBackgrounded() {
        audition.stop()
        releaseAllHeldKeys()
        if displayFeedMode == .live, !systemAsleep {
            displayStatus = "WAIT"
            present(.waiting)
        }
        refreshLifecycle()
    }

    /// Reconcile a RUNNING route against the current device snapshot. Stops the
    /// route when the input or output it opened has vanished (Brief §8). No-op when
    /// idle. Pure decision lives in `MonitorRouteReconciler` (unit-tested).
    private func reconcileAudioDevices() {
        guard monitor.isRunning else { return }
        if MonitorRouteReconciler.shouldStop(activeInputUID: monitor.activeInputUID,
                                             activeOutputUID: monitor.activeOutputUID,
                                             snapshot: audioDevices.snapshot) {
            stopMonitor()   // finalizes any take, drops the ring, re-reads lifecycle
        }
    }

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
            // Client is alive and watching but no EP-40 endpoint yet → discovering.
            ringErrorLabel = nil
            refreshRingState()
            refreshLifecycle()
        } catch {
            usbStatus = "MIDI ERROR"
            displayStatus = "PREVIEW"
            ringErrorLabel = "MIDI"
            refreshRingState()
            refreshLifecycle()
            present(.previewStill)
        }
    }

    /// Rebuild the ring state from real inputs and push it to the scene. Called on
    /// connection lifecycle changes only — connection state does not change per
    /// MIDI note, so this is never called from the hot event path (Brief §8).
    private func refreshRingState() {
        let inputs = HaloRingState.Inputs(
            observerRunning: midiObserver != nil,
            endpointConnected: endpointConnected,
            errorLabel: ringErrorLabel,
            monitorEngaged: monitor.isRunning,
            // recordingStartedAt is REAL as of P2-recorder: non-nil only while the
            // drain thread is actually running (SessionRecorder.startedAt). It sits
            // above monitoring in `derive`, so an active take shows `.recording`.
            recordingStartedAt: recorder.startedAt
            // transferProgress still has no producer (device transfer is Phase 0B).
        )
        ringState = HaloRingState.derive(inputs)
        scene.applyRing(ringState)
    }

    /// Recompute the coarse lifecycle phase (Brief §8) from the same honest inputs
    /// as the ring. Called on connection/monitor/sleep transitions and once when a
    /// live feed begins — never per-note (a cheap enum, but the observable write is
    /// kept off the hot path so SwiftUI is not invalidated every MIDI message).
    private func refreshLifecycle() {
        lifecyclePhase = HaloLifecyclePhase.derive(.init(
            observerRunning: midiObserver != nil,
            endpointConnected: endpointConnected,
            displayLive: displayFeedMode == .live,
            monitorEngaged: monitor.isRunning,
            systemAsleep: systemAsleep,
            errorLabel: ringErrorLabel))
    }

    /// Release every visually pressed key to a known state (Brief §8): the frontmost-
    /// held display collapse and the polyphonic scene travel/LEDs. Used on disconnect,
    /// sleep and background — anywhere Halo can no longer guarantee it will observe the
    /// matching Note Off, so a lingering lit pad would be dishonest.
    private func releaseAllHeldKeys() {
        heldMIDIKeys.removeAll(keepingCapacity: true)
        scene.releaseAllPads()
    }

    /// Count of keys Halo is currently showing as held (frontmost-held display
    /// stack). Test seam for the held-key-release resilience contract.
    var pressedVisualKeyCount: Int { heldMIDIKeys.count }

    /// Delivery seam mirroring the live CoreMIDI Task, so the connection + note
    /// lifecycle (and the held-key release on disconnect) is unit-tested without
    /// CoreMIDI hardware. Same routing the observer stream uses.
    func ingest(_ observation: EP40MIDIObservation) {
        switch observation {
        case let .connection(connection): receive(connection)
        case let .event(event): receive(event)
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
        endpointConnected = connection.isConnected
        // No live pad hold or LED may survive a connection change (DD-012). Done
        // before present() so the PREVIEW demo's own pad press (on disconnect) is
        // not immediately cleared.
        scene.releaseAllPads()
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
            // USB removal must stop the monitor route promptly (Brief §8 safety).
            // Finalize any in-flight take first so a yank yields a valid WAV of
            // whatever was captured, never a dangling recorder (DD-018).
            recorder.finishIfRecording()
            monitor.stop()
            // A USB yank is a hardware-context change; stop local audition too (DD-022).
            audition.stop()
            heldMIDIKeys.removeAll(keepingCapacity: true)
            resetClockTracking()
            present(.previewStill)
        }
        refreshRingState()
        refreshLifecycle()
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
            // Raw, per-note travel (polyphonic) — separate from the display's
            // frontmost-held collapse above (DD-012). Two group notes can map to
            // one physical pad; the scene refcounts them.
            scene.padNoteOn(channel: channel, note: note, velocity: velocity)

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
            scene.padNoteOff(channel: channel, note: note)

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
        // Lifecycle flips to LIVE only on the transition into a live feed — kept off
        // the per-note hot path (the observable write would otherwise fire per event).
        if firstLiveEvent { refreshLifecycle() }
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
