import SwiftUI

/// PLAY rail (Brief §7). Fills the expanded 300 pt utility column with the full
/// monitor / meter / transport anatomy. Honesty position (DD-013/DD-014): the
/// audio engine is Phase 2, so MONITOR/RECORD/GRAB are disabled with real-reason
/// captions, the output list is explicitly MOCK, and the meters rest at true
/// `.silence` (a moving meter in the running app would be a faked hardware state).
/// The gain fader IS enabled — it sets a real local preference and claims nothing
/// about hardware (same honesty class as palette selection).
struct PlayRail: View {
    @Environment(\.halo) private var c
    @State private var monitorGainDB = -12.0            // Brief §7 workflow: safe −12 dB
    @State private var outputIndex = 0                  // MOCK selection, local UI only

    var body: some View {
        VStack(spacing: HaloMetrics.s2) {
            HaloPanel("MONITOR") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    Button("MONITOR") {}
                        .buttonStyle(MechanicalButtonStyle())
                        .disabled(true)
                    RailCaption("AUDIO ENGINE — PHASE 2")

                    Rectangle().fill(c.ink.opacity(0.12)).frame(height: HaloMetrics.hairline)

                    OutputSelectRow(selection: $outputIndex)
                    RailCaption("MOCK LIST — REAL ROUTING PHASE 2")

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

/// MOCK monitor output routing. Real CoreAudio enumeration is Phase 2 work and
/// would make headless screenshots machine-dependent — the `(MOCK)` suffix keeps
/// it honest. Selection is genuine local UI state.
enum MockMonitorRig {
    static let outputs = ["EP-40 USB (MOCK)", "BUILT-IN OUTPUT (MOCK)"]
}

/// An interactive output picker built from tokens — no stock `Picker`/`Menu`
/// (forbidden shortcut) and no popover (Escape semantics stay trivial). Clicking
/// the value expands an inline disclosure list inside the panel; the expanded list
/// registers as a transient so Escape collapses it. The selected row gets the 1 px
/// orange rim inset (the `mechanicalSelected` visual language).
private struct OutputSelectRow: View {
    @Environment(\.halo) private var c
    @Binding var selection: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: HaloMetrics.s1) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    Text("OUTPUT")
                        .font(HaloType.mono(11))
                        .foregroundStyle(c.inkSoft)
                    Spacer(minLength: HaloMetrics.s2)
                    Text(MockMonitorRig.outputs[selection])
                        .font(HaloType.mono(11))
                        .foregroundStyle(c.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(c.inkSoft)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 2) {
                    ForEach(Array(MockMonitorRig.outputs.enumerated()), id: \.offset) { idx, name in
                        Button {
                            selection = idx
                            expanded = false
                        } label: {
                            HStack {
                                Text(name)
                                    .font(HaloType.mono(10))
                                    .foregroundStyle(c.ink)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, HaloMetrics.s1)
                            .background(
                                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                    .fill(selection == idx ? c.paperHigh : c.paper.opacity(0.5)))
                            .overlay {
                                if selection == idx {
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
}

#if DEBUG
#Preview("PlayRail") {
    ScrollView {
        PlayRail()
            .padding(HaloMetrics.s2)
    }
    .frame(width: 300, height: 620)
    .environment(HaloAppModel())
    .environment(\.halo, .graphPaper)
    .background(HaloColorTokens.graphPaper.paperHigh)
}
#endif
