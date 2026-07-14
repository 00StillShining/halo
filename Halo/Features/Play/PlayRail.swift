import SwiftUI

/// PLAY rail (Brief §7). Fills the expanded 300 pt utility column with the full
/// monitor / meter / transport anatomy. Honesty position (DD-013/DD-014/DD-016/
/// DD-017): the monitor route is now REAL (P2-route) — MONITOR opens an input-only
/// AUHAL for the EP-40 and an output AUHAL for the chosen Mac output, bridged and
/// limited, without touching the system default. It starts only on this explicit
/// press, defaults to −12 dB, and the meters show the ACTUAL rendered levels; when
/// no route runs they rest at true `.silence` (a moving meter without a live route
/// would be a faked hardware state). MONITOR stays disabled with a real reason
/// until an EP-40 audio input and an output device are both present. Live audio
/// through hardware is verified on-device (needs-device). RECORD/GRAB remain later
/// phases.
struct PlayRail: View {
    @Environment(\.halo) private var c
    @Environment(HaloAppModel.self) private var model

    private var ep40InputUID: String? { model.audioDevices.snapshot.ep40AudioInput?.uid }
    private var outputUID: String? {
        model.audioOutput.resolution(in: model.audioDevices.snapshot).device?.uid
    }
    private var canMonitor: Bool { ep40InputUID != nil && outputUID != nil }
    private var isRunning: Bool { model.monitor.isRunning }

    private var gainBinding: Binding<Double> {
        Binding(get: { model.monitor.gainDB }, set: { model.monitor.gainDB = $0 })
    }

    /// Honest one-line status for the MONITOR control.
    private var monitorCaption: String {
        switch model.monitor.state {
        case .running:
            return "LIVE — GAIN → LIMITER (−1 DBFS); SYSTEM DEFAULT UNCHANGED"
        case let .failed(error):
            return Self.reason(for: error)
        case .idle:
            if ep40InputUID == nil { return "EP-40 AUDIO INPUT NOT DETECTED" }
            if outputUID == nil { return "NO OUTPUT DEVICE" }
            return "READY — STARTS AT −12 DB ON PRESS"
        }
    }

    private static func reason(for error: MonitorRouteError) -> String {
        switch error {
        case .noInputDevice: return "EP-40 AUDIO INPUT NOT DETECTED"
        case .noOutputDevice: return "NO OUTPUT DEVICE"
        case .componentUnavailable: return "AUDIO COMPONENT UNAVAILABLE"
        case let .unitCreation(s): return "AUDIO UNIT ERROR (\(s))"
        case let .configuration(s): return "ROUTE CONFIG ERROR (\(s))"
        case let .couldNotStart(s): return "COULD NOT START (\(s))"
        }
    }

    /// Honest one-line status for the RECORD control. The recorder taps the RAW
    /// pre-monitor input (DD-018), so it needs a running route to record.
    private var recordCaption: String {
        switch model.recorder.state {
        case .recording:
            // Read the observed `elapsed` (updated at 50 Hz) so the caption ticks.
            return "CAPTURING RAW INPUT — \(HaloRecordFormat.clock(model.recorder.elapsed))"
        case let .failed(reason):
            switch reason {
            case .monitorOff: return "MONITOR OFF — START MONITORING TO RECORD"
            case let .fileOpen(msg): return "COULD NOT OPEN FILE — \(msg)"
            }
        case .idle:
            return isRunning
                ? "RECORDS THE RAW INPUT — PRE-GAIN / PRE-LIMITER (⌘R)"
                : "MONITOR OFF — START MONITORING TO RECORD"
        }
    }

    private func toggleMonitor() {
        // Through the app-model wrappers so the halo ring's MON truth updates in
        // the same breath as the route (never a stale ring state).
        if isRunning {
            model.stopMonitor()
        } else {
            model.startMonitor(inputUID: ep40InputUID, outputUID: outputUID)
        }
    }

    var body: some View {
        VStack(spacing: HaloMetrics.s2) {
            HaloPanel("MONITOR") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    Button(isRunning ? "STOP" : "MONITOR") { toggleMonitor() }
                        .buttonStyle(MechanicalButtonStyle())
                        .disabled(!canMonitor && !isRunning)
                    RailCaption(monitorCaption)

                    // Feedback-loop warning (Brief §8 safety): the EP-40 chosen as
                    // BOTH capture source and monitor output would howl. Surfaced
                    // explicitly; the user still decides.
                    if MonitorController.feedbackRisk(inputUID: ep40InputUID, outputUID: outputUID) {
                        HStack(spacing: HaloMetrics.s1) {
                            RailTag("FEEDBACK RISK")
                            Text("OUTPUT IS THE EP-40 INPUT")
                                .font(HaloType.mono(9))
                                .foregroundStyle(c.warning)
                        }
                    }

                    Rectangle().fill(c.ink.opacity(0.12)).frame(height: HaloMetrics.hairline)

                    OutputDevicePicker(
                        snapshot: model.audioDevices.snapshot,
                        selection: model.audioOutput
                    )
                    RailCaption("LIVE CORE AUDIO DEVICES — SYSTEM DEFAULT UNCHANGED")

                    Rectangle().fill(c.ink.opacity(0.12)).frame(height: HaloMetrics.hairline)

                    HaloFader("GAIN", value: gainBinding, in: -40...0, defaultValue: -12) {
                        String(format: "%.1f DB", $0)
                    }
                    RailCaption("SAFE MONITORING LEVEL — DEFAULT −12 DB")

                    MonitorProfileSelector(profile: model.monitor.profile,
                                           locked: isRunning) { model.monitor.profile = $0 }
                    RailCaption(isRunning
                        ? "BUFFER PROFILE LOCKED WHILE MONITORING"
                        : "IO BUFFER — LOW 128 / BALANCED 256 / SAFE 512")
                }
            }

            HaloPanel("METERS") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    StereoMeter(levels: model.monitor.levels)
                    RailCaption(isRunning ? "LIVE POST-LIMITER LEVELS" : "RESTING — NO ROUTE RUNNING")
                }
            }

            HaloPanel("TRANSPORT") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    let isRecording = model.recorder.isRecording
                    Button(isRecording ? "STOP" : "RECORD") { model.toggleRecording() }
                        .buttonStyle(MechanicalButtonStyle())
                        .mechanicalEngaged(isRecording)
                        .disabled(!isRunning && !isRecording)
                    RailCaption(recordCaption)
                    Button("GRAB") {}
                        .buttonStyle(MechanicalButtonStyle())
                        .disabled(true)
                    RailCaption("LOOP GRAB — PHASE 5B")
                }
            }
        }
    }
}

/// Real monitor-output picker built from tokens — no stock `Picker`/`Menu`
/// (forbidden shortcut) and no popover (Escape stays trivial). It lists the live
/// output-capable Core Audio devices from the discovery snapshot and binds the
/// selection to STABLE UIDs via `AudioOutputSelection`. The resolved row states
/// honestly whether the highlighted device is the user's own pick or a system
/// default fallback (when their remembered device is currently absent). Selecting
/// persists a UID for the Phase 2 route; it never changes the system default.
private struct OutputDevicePicker: View {
    @Environment(\.halo) private var c
    let snapshot: AudioDeviceSnapshot
    let selection: AudioOutputSelection
    @State private var expanded = false

    private var resolution: AudioOutputResolution {
        selection.resolution(in: snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HaloMetrics.s1) {
            Button {
                guard !snapshot.outputs.isEmpty else { return }
                expanded.toggle()
            } label: {
                HStack(spacing: HaloMetrics.s2) {
                    Text("OUTPUT")
                        .font(HaloType.mono(11))
                        .foregroundStyle(c.inkSoft)
                    Spacer(minLength: HaloMetrics.s2)
                    Text(resolution.device?.name ?? "NO OUTPUT DEVICE")
                        .font(HaloType.mono(11))
                        .foregroundStyle(resolution.device == nil ? c.inkSoft : c.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(c.inkSoft)
                        .opacity(snapshot.outputs.isEmpty ? 0.3 : 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(snapshot.outputs.isEmpty)

            // Honest provenance + real device facts for the resolved output. The
            // fallback tag names the ACTUAL fallback rule that fired: `.fallbackFirst`
            // is not the system default, so it must not claim to be (Brief §1/§4).
            if let device = resolution.device {
                HStack(spacing: HaloMetrics.s1) {
                    switch resolution {
                    case .fallbackDefault: RailTag("SYSTEM DEFAULT")
                    case .fallbackFirst: RailTag("AUTO FALLBACK")
                    case .preferred, .none: EmptyView()
                    }
                    Spacer(minLength: 0)
                    Text(Self.detail(for: device))
                        .font(HaloType.mono(10))
                        .foregroundStyle(c.inkSoft)
                }
            }

            if expanded {
                VStack(spacing: 2) {
                    ForEach(snapshot.outputs) { device in
                        let isSelected = resolution.device?.uid == device.uid
                        Button {
                            selection.select(device.uid)
                            expanded = false
                        } label: {
                            HStack {
                                Text(device.name)
                                    .font(HaloType.mono(10))
                                    .foregroundStyle(c.ink)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: HaloMetrics.s1)
                                Text(Self.detail(for: device))
                                    .font(HaloType.mono(9))
                                    .foregroundStyle(c.inkSoft)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, HaloMetrics.s1)
                            .background(
                                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                    .fill(isSelected ? c.paperHigh : c.paper.opacity(0.5)))
                            .overlay {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                        .stroke(c.orange, lineWidth: HaloMechanics.rimWidth)
                                        .padding(1)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .haloTransient { expanded = false }
            }
        }
    }

    /// Real, device-reported facts: current nominal rate + output channel count.
    private static func detail(for device: AudioDevice) -> String {
        let khz = device.currentSampleRate / 1_000
        let rate = khz.rounded() == khz
            ? String(format: "%.0f KHZ", khz)
            : String(format: "%.1f KHZ", khz)
        return "\(rate) · \(device.outputChannels) CH"
    }
}

/// Token-built LOW/BALANCED/SAFE profile selector (no stock segmented control —
/// forbidden shortcut). Locked while a route runs, since the IO buffer size can
/// only change on a fresh `start` (Brief §8).
private struct MonitorProfileSelector: View {
    @Environment(\.halo) private var c
    let profile: MonitorProfile
    let locked: Bool
    let onSelect: (MonitorProfile) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MonitorProfile.allCases) { p in
                let selected = p == profile
                Button { onSelect(p) } label: {
                    Text(p.label)
                        .font(HaloType.mono(9))
                        .foregroundStyle(selected ? c.ink : c.inkSoft)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                .fill(selected ? c.paperHigh : c.paper.opacity(0.5)))
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                    .stroke(c.orange, lineWidth: HaloMechanics.rimWidth)
                                    .padding(1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(locked)
                .opacity(locked && !selected ? 0.4 : 1)
            }
        }
    }
}

#if DEBUG
extension AudioDeviceSnapshot {
    /// Deterministic fixture so previews render without depending on the build
    /// machine's real devices (and so nothing in a preview implies live hardware).
    static let previewFixture = AudioDeviceSnapshot(
        devices: [
            AudioDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                        inputChannels: 0, outputChannels: 2,
                        currentSampleRate: 48_000, supportedSampleRates: [44_100, 48_000],
                        bufferFrameRange: .init(minFrames: 15, maxFrames: 4096)),
            AudioDevice(uid: "EP40-USB-UID", name: "EP-40 (MOCK)",
                        inputChannels: 2, outputChannels: 2,
                        currentSampleRate: 48_000, supportedSampleRates: [48_000],
                        bufferFrameRange: .init(minFrames: 32, maxFrames: 2048)),
        ],
        defaultInputUID: nil,
        defaultOutputUID: "BuiltInSpeakerDevice"
    )
}

#Preview("PlayRail") {
    let model = HaloAppModel()
    model.audioDevices.previewSeed(.previewFixture)
    return ScrollView {
        PlayRail()
            .padding(HaloMetrics.s2)
    }
    .frame(width: 300, height: 620)
    .environment(model)
    .environment(\.halo, .graphPaper)
    .background(HaloColorTokens.graphPaper.paperHigh)
}
#endif
