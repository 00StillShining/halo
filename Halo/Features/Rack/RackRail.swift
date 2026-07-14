import SwiftUI

/// RACK rail (Brief §5a). The dub FX rack: four performable modules on the monitor
/// path in fixed order TAPE ECHO → SPRING → SWEEP → LOW END, each with a mechanical
/// bypass. Controls are real mechanical knobs (`HaloKnob`) and latched keycaps; orange
/// appears only on engaged/committed states. The DSP is inserted post-gain / pre-limiter
/// and is bit-transparent while the master is disengaged.
///
/// HONESTY (Brief §1/§4): the rack is Mac-side DSP, not an EP-40 state. It is only
/// AUDIBLE while a monitor route runs — the panel says so plainly rather than implying
/// the device is affected. Tempo-sync uses the observed MIDI clock when present, else
/// tap-tempo; no tempo is invented.
struct RackRail: View {
    @Environment(\.halo) private var c
    @Environment(HaloAppModel.self) private var model

    var body: some View {
        @Bindable var rack = model.rack
        return VStack(spacing: HaloMetrics.s2) {
            masterPanel(rack)
            echoPanel(rack)
            springPanel(rack)
            sweepPanel(rack)
            lowPanel(rack)
        }
    }

    private var monitorRunning: Bool { model.monitor.isRunning }

    // MARK: - MASTER

    private func masterPanel(_ rack: RackModel) -> some View {
        HaloPanel("DUB RACK") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                HStack(spacing: HaloMetrics.s1) {
                    Button(rack.engaged ? "ENGAGED" : "ENGAGE") { rack.engaged.toggle() }
                        .buttonStyle(MechanicalButtonStyle())
                        .mechanicalEngaged(rack.engaged)
                        .focusable()
                        .help("Insert / bypass the whole rack (bit-transparent when bypassed)")
                    Button(rack.printFX ? "PRINT FX ON" : "PRINT FX") { rack.printFX.toggle() }
                        .buttonStyle(MechanicalButtonStyle())
                        .mechanicalEngaged(rack.printFX)
                        .focusable()
                        .help("Record the post-rack signal on the next take (labelled)")
                }
                RailCaption(monitorRunning
                    ? "INSERTED POST-GAIN / PRE-LIMITER — BYPASS IS BIT-TRANSPARENT"
                    : "MONITOR OFF — START MONITORING (⌘M) TO HEAR THE RACK")
                if rack.printFX {
                    RailCaption("NEXT TAKE CAPTURES POST-RACK FX — TAGGED “FX” ON DISK")
                }
            }
        }
    }

    // MARK: - TAPE ECHO

    private func echoPanel(_ rack: RackModel) -> some View {
        modulePanel(title: "TAPE ECHO",
                    active: !rack.echoBypassed,
                    toggle: { rack.echoBypassed.toggle() }) {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                // Tempo-sync row.
                HStack(spacing: HaloMetrics.s1) {
                    Button(rack.echoSync ? "SYNC" : "FREE") { rack.echoSync.toggle() }
                        .buttonStyle(MechanicalButtonStyle())
                        .mechanicalEngaged(rack.echoSync)
                        .focusable()
                        .help("Tempo-sync the delay time to the clock / tap tempo")
                    Button("TAP") { rack.tapTempo() }
                        .buttonStyle(MechanicalButtonStyle())
                        .focusable()
                        .help("Tap tempo (used when the device sends no MIDI clock)")
                    Spacer(minLength: 0)
                    Text("\(rack.tempoSource.rawValue) \(tempoText(rack))")
                        .font(HaloType.mono(9))
                        .foregroundStyle(c.inkSoft)
                }
                if rack.echoSync {
                    divisionRow(rack)
                }
                RailDataRow("DELAY", String(format: "%.0f MS", rack.effectiveEchoMs))

                knobGrid([
                    AnyView(HaloKnob("TIME", value: bindEchoTime(rack), in: 40...1200,
                                     defaultValue: 360, step: 5, coarseStep: 50) {
                        String(format: "%.0f", $0)
                    }.disabled(rack.echoSync)),
                    AnyView(HaloKnob("FEEDBACK", value: bind(rack, \.echoFeedback), in: 0...1,
                                     defaultValue: 0.45, readout: pct)),
                    AnyView(HaloKnob("TONE", value: bind(rack, \.echoTone), in: 0...1,
                                     defaultValue: 0.5, readout: pct)),
                    AnyView(HaloKnob("WOW", value: bind(rack, \.echoWow), in: 0...1,
                                     defaultValue: 0.25, readout: pct)),
                    AnyView(HaloKnob("MIX", value: bind(rack, \.echoMix), in: 0...1,
                                     defaultValue: 0.35, readout: pct)),
                ])
            }
        }
    }

    private func divisionRow(_ rack: RackModel) -> some View {
        HStack(spacing: HaloMetrics.s1) {
            ForEach(EchoDivision.allCases) { div in
                Button(div.label) { rack.echoDivision = div }
                    .buttonStyle(MechanicalButtonStyle())
                    .mechanicalEngaged(rack.echoDivision == div)
                    .focusable()
                    .help("Delay division \(div.label)")
            }
        }
    }

    // MARK: - SPRING

    private func springPanel(_ rack: RackModel) -> some View {
        modulePanel(title: "SPRING",
                    active: !rack.springBypassed,
                    toggle: { rack.springBypassed.toggle() }) {
            knobGrid([
                AnyView(HaloKnob("MIX", value: bind(rack, \.springMix), in: 0...1,
                                 defaultValue: 0.30, readout: pct)),
                AnyView(HaloKnob("DECAY", value: bind(rack, \.springDecay), in: 0...1,
                                 defaultValue: 0.55, readout: pct)),
                AnyView(HaloKnob("TONE", value: bind(rack, \.springTone), in: 0...1,
                                 defaultValue: 0.5, readout: pct)),
            ])
        }
    }

    // MARK: - SWEEP

    private func sweepPanel(_ rack: RackModel) -> some View {
        modulePanel(title: "SWEEP",
                    active: !rack.sweepBypassed,
                    toggle: { rack.sweepBypassed.toggle() }) {
            knobGrid([
                AnyView(HaloKnob("SWEEP", value: bind(rack, \.sweepMacro), in: 0...1,
                                 defaultValue: 0.5) { v in
                    v < 0.34 ? "LP" : (v < 0.66 ? "BP" : "HP")
                }),
                AnyView(HaloKnob("RESO", value: bind(rack, \.sweepReso), in: 0...1,
                                 defaultValue: 0.3, readout: pct)),
            ])
        }
    }

    // MARK: - LOW END

    private func lowPanel(_ rack: RackModel) -> some View {
        modulePanel(title: "LOW END",
                    active: !rack.lowBypassed,
                    toggle: { rack.lowBypassed.toggle() }) {
            VStack(alignment: .leading, spacing: HaloMetrics.s1) {
                knobGrid([
                    AnyView(HaloKnob("AMOUNT", value: bind(rack, \.lowAmount), in: 0...1,
                                     defaultValue: 0.4, readout: pct)),
                ])
                RailCaption("GENTLE SUB/LOUDNESS FOR LAPTOP SPEAKERS — OFF BY DEFAULT")
            }
        }
    }

    // MARK: - Building blocks

    /// A module panel whose header carries a mechanical bypass keycap; engaged (active)
    /// gets the committed orange bar.
    private func modulePanel<Content: View>(title: String, active: Bool,
                                            toggle: @escaping () -> Void,
                                            @ViewBuilder content: () -> Content) -> some View {
        HaloPanel(title) {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                Button(active ? "ON" : "BYPASSED") { toggle() }
                    .buttonStyle(MechanicalButtonStyle())
                    .mechanicalEngaged(active)
                    .focusable()
                    .help("Bypass \(title)")
                content()
            }
        }
    }

    /// Lay knobs out three-per-row so they never clip the rail at the minimum window.
    private func knobGrid(_ knobs: [AnyView]) -> some View {
        let rows = stride(from: 0, to: knobs.count, by: 3).map { start in
            Array(knobs[start..<min(start + 3, knobs.count)])
        }
        return VStack(alignment: .leading, spacing: HaloMetrics.s2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: HaloMetrics.s2) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, knob in knob }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func tempoText(_ rack: RackModel) -> String {
        guard let bpm = rack.tempoBPM else { return "" }
        return "\(Int(bpm)) BPM"
    }

    // Percent readout for 0…1 knobs.
    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    // MARK: - Bindings

    private func bind(_ rack: RackModel, _ key: ReferenceWritableKeyPath<RackModel, Double>) -> Binding<Double> {
        Binding(get: { rack[keyPath: key] }, set: { rack[keyPath: key] = $0 })
    }

    private func bindEchoTime(_ rack: RackModel) -> Binding<Double> {
        Binding(get: { rack.echoFreeMs }, set: { rack.echoFreeMs = $0 })
    }
}

#if DEBUG
#Preview("RackRail") {
    let model = HaloAppModel()
    model.rack.engaged = true
    return ScrollView {
        RackRail()
            .padding(HaloMetrics.s2)
    }
    .frame(width: 420, height: 760)
    .environment(model)
    .environment(\.halo, .graphPaper)
    .background(HaloColorTokens.graphPaper.paperHigh)
}
#endif
