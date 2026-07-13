import SwiftUI

/// PLAY rail (Brief §7). Fills the expanded 300 pt utility column with the full
/// monitor / meter / transport anatomy. Honesty position (DD-013/DD-014/DD-016):
/// the audio ENGINE is Phase 2, so MONITOR/RECORD/GRAB stay disabled with real
/// reason captions and the meters rest at true `.silence` (a moving meter would be
/// a faked hardware state). The output picker is now REAL — it lists live Core
/// Audio devices by stable UID (`AudioDeviceDiscovery`) and persists the user's
/// choice — but it changes nothing about the system: routing itself is Phase 2 and
/// the system default output is never touched. The gain fader sets a real local
/// preference and claims nothing about hardware.
struct PlayRail: View {
    @Environment(\.halo) private var c
    @Environment(HaloAppModel.self) private var model
    @State private var monitorGainDB = -12.0            // Brief §7 workflow: safe −12 dB

    var body: some View {
        VStack(spacing: HaloMetrics.s2) {
            HaloPanel("MONITOR") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    Button("MONITOR") {}
                        .buttonStyle(MechanicalButtonStyle())
                        .disabled(true)
                    RailCaption("AUDIO ENGINE — PHASE 2")

                    Rectangle().fill(c.ink.opacity(0.12)).frame(height: HaloMetrics.hairline)

                    OutputDevicePicker(
                        snapshot: model.audioDevices.snapshot,
                        selection: model.audioOutput
                    )
                    RailCaption("LIVE CORE AUDIO DEVICES — ROUTING SHIPS PHASE 2; SYSTEM DEFAULT UNCHANGED")

                    Rectangle().fill(c.ink.opacity(0.12)).frame(height: HaloMetrics.hairline)

                    HaloFader("GAIN", value: $monitorGainDB, in: -40...0, defaultValue: -12) {
                        String(format: "%.1f DB", $0)
                    }
                    RailCaption("LOCAL SETTING — APPLIES WHEN MONITORING SHIPS (PHASE 2)")
                }
            }

            HaloPanel("METERS") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    StereoMeter(levels: .silence)
                    RailCaption("NO AUDIO TRUTH YET — PHASE 2")
                }
            }

            HaloPanel("TRANSPORT") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    Button("RECORD") {}
                        .buttonStyle(MechanicalButtonStyle())
                        .disabled(true)
                    RailCaption("SESSION RECORDER — PHASE 2")
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
