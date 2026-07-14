import SwiftUI

/// The CHOP transient panel (Brief §5c). A custom panel exactly like `PreparationSheet`
/// (NOT a stock `.sheet`) presented over everything from `HaloRootView`, dismissed by
/// the transient stack (`haloTransient`). Slice a break/vocal/grab into consecutive pads:
/// the LOCAL audio (onsets, slices, fades, audition, byte estimates) is REAL; the
/// pads/slots DESTINATION is MOCK and SEND TO PADS is disabled (Phase 0B, needsDevice).
/// Tokens + mechanical language only; orange reserved for selected/engaged/focus.
struct ChopSurface: View {
    @Environment(\.halo) private var c
    @Environment(HaloAppModel.self) private var model

    @FocusState private var surfaceFocused: Bool
    @FocusState private var nameFieldFocused: Bool
    @State private var sensitivity = 0.5
    @State private var detectDebounce: Task<Void, Never>?
    @State private var baseNameText = "CHOP"

    private var session: ChopSession { model.chop }
    private var audition: AuditionPlayer { model.audition }

    var body: some View {
        if session.isOpen {
            VStack(spacing: 0) {
                header
                rule
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                        waveformPanel
                        detectPanel
                        slicesPanel
                        if session.selectedSlice != nil { fadePanel }
                        formatPanel
                        sendPanel
                    }
                    .padding(HaloMetrics.s2)
                }
                .frame(maxHeight: 560)
                rule
                footer
            }
            .frame(width: 820)
            .background(
                RoundedRectangle(cornerRadius: HaloMetrics.radiusPanel)
                    .fill(c.paper)
                    .overlay(
                        RoundedRectangle(cornerRadius: HaloMetrics.radiusPanel)
                            .stroke(c.ink.opacity(0.28), lineWidth: HaloMetrics.hairline)))
            .compositingGroup()
            .shadow(color: c.ink.opacity(0.35), radius: 0, x: 4, y: 10)
            .haloTransient { model.closeChop() }
            .focusable()
            .focused($surfaceFocused)
            .focusEffectDisabled()
            .onKeyPress(.delete) {
                guard !nameFieldFocused else { return .ignored }
                session.removeCutAtSelectedSliceStart()
                return .handled
            }
            .onKeyPress { press in handleKeyAudition(press) }
            .onAppear {
                sensitivity = session.params.sensitivity
                baseNameText = session.baseName
                surfaceFocused = true
            }
            .onChange(of: session.baseName) { _, new in baseNameText = new }
        }
    }

    // MARK: - Keyboard audition (1-9, 0, ., Return in pad order)

    private func handleKeyAudition(_ press: KeyPress) -> KeyPress.Result {
        guard !nameFieldFocused, let ch = press.characters.first,
              let i = ChopKeyboard.sliceIndex(forCharacter: ch,
                                              startGridIndex: session.startGridIndex,
                                              sliceCount: session.sliceSet.sliceCount)
        else { return .ignored }
        model.auditionChopSlice(index: i)
        return .handled
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: HaloMetrics.s1) {
            HStack(spacing: HaloMetrics.s1) {
                Text("CHOP")
                    .font(HaloType.label(11)).haloLabelCase()
                    .foregroundStyle(c.ink)
                Text(session.source?.name ?? "—")
                    .font(HaloType.mono(11))
                    .foregroundStyle(c.inkSoft)
                    .lineLimit(1).truncationMode(.middle)
                RailTag("LOCAL")
                Spacer(minLength: 0)
                RailTag("MOCK")
            }
            RailCaption("SLICE A BREAK, VOCAL OR GRAB → CONSECUTIVE PADS. LOCAL AUDIO IS REAL; PADS/SLOTS ARE MOCK.")
        }
        .padding(.horizontal, HaloMetrics.s2)
        .padding(.vertical, HaloMetrics.s1)
    }

    // MARK: - WAVEFORM

    private var waveformPanel: some View {
        HaloPanel("WAVEFORM") {
            VStack(alignment: .leading, spacing: HaloMetrics.s1) {
                SliceWaveform(
                    summary: session.summary,
                    slices: session.sliceSet.slices(),
                    cuts: session.sliceSet.cuts,
                    sourceFrameCount: session.sliceSet.sourceFrameCount,
                    selectedSlice: session.selectedSlice,
                    playingSlice: playingSlice,
                    playheadProgress: playheadProgress,
                    onAddCut: { session.addCut(atFrame: $0) },
                    onMoveCut: { session.moveCut(index: $0, toFrame: $1) },
                    onRemoveCut: { session.removeCut(index: $0) },
                    onSelectSlice: { model.auditionChopSlice(index: $0) })
                RailCaption("CLICK A SLICE TO AUDITION · DOUBLE-CLICK TO ADD A CUT · DRAG A MARKER TO MOVE · ⌥-CLICK OR ⌫ TO DELETE")
            }
        }
    }

    private var playingSlice: Int? {
        guard audition.isPlaying, audition.playingAssetID == session.auditionID else { return nil }
        return session.auditioningSlice
    }

    private var playheadProgress: Double? {
        guard audition.isPlaying, audition.playingAssetID == session.auditionID else { return nil }
        return audition.progress
    }

    // MARK: - DETECT

    private var detectPanel: some View {
        HaloPanel("DETECT") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                HStack(alignment: .top, spacing: HaloMetrics.s3) {
                    HaloKnob("SENSITIVITY", value: $sensitivity, in: 0...1, defaultValue: 0.5,
                             step: 0.02, coarseStep: 0.1) { String(format: "%.0f%%", $0 * 100) }
                        .onChange(of: sensitivity) { _, v in scheduleDetect(v) }
                    VStack(alignment: .leading, spacing: HaloMetrics.s1) {
                        RailDataRow("SLICES", "\(session.sliceSet.sliceCount)")
                        HStack(spacing: HaloMetrics.s1) {
                            Button("RE-DETECT") { session.detect() }
                                .buttonStyle(MechanicalButtonStyle())
                            Button("CLEAR CUTS") { session.clearCuts() }
                                .buttonStyle(MechanicalButtonStyle())
                            Spacer(minLength: 0)
                        }
                    }
                    Spacer(minLength: 0)
                }
                RailCaption("RE-DETECT REPLACES MANUAL CUTS · SILENCE YIELDS NO SLICES")
            }
        }
    }

    private func scheduleDetect(_ v: Double) {
        detectDebounce?.cancel()
        detectDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            session.setSensitivity(v)
        }
    }

    // MARK: - SLICES (chips in pad order)

    private var slicesPanel: some View {
        HaloPanel("SLICES") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                if session.sliceSet.sliceCount == 0 {
                    RailCaption("NO SLICES — RAISE SENSITIVITY OR DOUBLE-CLICK THE WAVEFORM TO ADD A CUT.")
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 92), spacing: HaloMetrics.s1)],
                        alignment: .leading, spacing: HaloMetrics.s1
                    ) {
                        ForEach(session.sliceSet.slices()) { slice in
                            sliceChip(slice)
                        }
                    }
                    RailCaption("KEYS 1–9 0 · ENTER AUDITION IN PAD ORDER")
                }
            }
        }
    }

    private func sliceChip(_ slice: SliceRange) -> some View {
        let selected = slice.id == session.selectedSlice
        let padGrid = session.startGridIndex + slice.id
        let legend = padGrid < PadGrid.legends.count ? PadGrid.legends[padGrid] : "—"
        let rate = session.source?.sampleRate ?? 0
        return Button {
            model.auditionChopSlice(index: slice.id)
        } label: {
            HStack(spacing: HaloMetrics.s1) {
                Text("\(slice.id + 1)")
                    .font(HaloType.mono(10)).foregroundStyle(c.inkSoft)
                Text(legend)
                    .font(HaloType.label(9)).haloLabelCase()
                    .foregroundStyle(selected ? c.orange : c.inkSoft.opacity(0.85))
                Spacer(minLength: 0)
                Text(MockFormat.duration(rate > 0 ? Double(slice.frameCount) / rate : 0))
                    .font(HaloType.mono(9)).foregroundStyle(c.ink)
            }
            .padding(.horizontal, HaloMetrics.s1)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                    .fill(selected ? c.paperHigh : c.paper.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                            .stroke(c.ink.opacity(0.2), lineWidth: HaloMetrics.hairline)))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .stroke(c.orange, lineWidth: HaloMechanics.rimWidth).padding(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - PER-SLICE FADE

    private var fadePanel: some View {
        HaloPanel("PER-SLICE FADE") {
            if let i = session.selectedSlice {
                let rate = session.source?.sampleRate ?? 0
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    Text("SLICE \(i + 1)").font(HaloType.mono(11)).foregroundStyle(c.inkSoft)
                    HaloFader("FADE IN", value: fadeInBinding(i, rate: rate), in: 0...50,
                              defaultValue: 4, step: 1, coarseStep: 5) { String(format: "%.0f MS", $0) }
                    HaloFader("FADE OUT", value: fadeOutBinding(i, rate: rate), in: 0...50,
                              defaultValue: 4, step: 1, coarseStep: 5) { String(format: "%.0f MS", $0) }
                    HaloFader("GAIN", value: gainBinding(i), in: -24...12,
                              defaultValue: 0, step: 0.5, coarseStep: 3) { String(format: "%+.1f DB", $0) }
                    RailCaption("EQUAL-POWER MICRO-FADES BY DEFAULT (ANTI-CLICK)")
                }
            }
        }
    }

    // MARK: - FORMAT

    private var formatPanel: some View {
        HaloPanel("FORMAT") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                Text("RATE").font(HaloType.label(9)).haloLabelCase().foregroundStyle(c.inkSoft)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: HaloMetrics.s1), count: 3),
                    spacing: HaloMetrics.s1
                ) {
                    ForEach(SampleTreatment.allSelectable, id: \.self) { t in
                        Button(t.label) { session.treatment = t }
                            .buttonStyle(MechanicalButtonStyle())
                            .mechanicalSelected(session.treatment == t)
                    }
                }
                RailCaption("GOVERNS THE PER-SLICE BYTE ESTIMATE + EXPORT")
            }
        }
    }

    // MARK: - SEND TO PADS (MOCK + disabled)

    private var sendPanel: some View {
        HaloPanel("SEND TO PADS") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                HStack {
                    Text("DESTINATION").font(HaloType.label(9)).haloLabelCase().foregroundStyle(c.inkSoft)
                    Spacer(minLength: 0)
                    RailTag("MOCK")
                }
                groupRow
                HStack(alignment: .top, spacing: HaloMetrics.s1) {
                    Text("START PAD").font(HaloType.mono(11)).foregroundStyle(c.inkSoft)
                        .frame(width: 72, alignment: .leading)
                    startPadGrid
                }
                nameRow
                Rectangle().fill(c.ink.opacity(0.12)).frame(height: HaloMetrics.hairline)
                planReadout
                if session.plan.overflowCount > 0 { overflowPlate }
                Button("SEND TO PADS") {}
                    .buttonStyle(MechanicalButtonStyle())
                    .disabled(true)
                    .help("Upload + assign the slices — needs a verified protocol (Phase 0B)")
                RailCaption("DEVICE TRANSFER — NEEDS VERIFIED PROTOCOL (PHASE 0B)")
                RailCaption("WOULD TAKE ONE PRE-WRITE BACKUP, THEN A SERIALISED VERIFIED WRITE+ASSIGN PER SLICE; ABORT LEAVES A TRUTHFUL PARTIAL REPORT")
            }
        }
    }

    private var groupRow: some View {
        HStack(spacing: HaloMetrics.s1) {
            Text("GROUP").font(HaloType.mono(11)).foregroundStyle(c.inkSoft)
                .frame(width: 72, alignment: .leading)
            ForEach(0..<4, id: \.self) { g in
                Button(PadGrid.groupLetter(g)) { session.group = g }
                    .buttonStyle(MechanicalButtonStyle())
                    .mechanicalSelected(session.group == g)
            }
            Spacer(minLength: 0)
        }
    }

    private var startPadGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(48), spacing: HaloMetrics.s1), count: 3),
            spacing: HaloMetrics.s1
        ) {
            ForEach(0..<12, id: \.self) { gridIndex in
                let selected = session.startGridIndex == gridIndex
                Button {
                    session.startGridIndex = gridIndex
                } label: {
                    Text(PadGrid.legends[gridIndex])
                        .font(HaloType.mono(10))
                        .foregroundStyle(c.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                .fill(c.paper)
                                .overlay(
                                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                        .stroke(c.ink.opacity(0.22), lineWidth: HaloMetrics.hairline)))
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                    .stroke(c.orange, lineWidth: HaloMechanics.rimWidth).padding(1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var nameRow: some View {
        HStack(spacing: HaloMetrics.s1) {
            Text("BASE NAME").font(HaloType.mono(11)).foregroundStyle(c.inkSoft)
                .frame(width: 72, alignment: .leading)
            TextField("", text: $baseNameText)
                .textFieldStyle(.plain)
                .font(HaloType.mono(11))
                .foregroundStyle(c.ink)
                .focused($nameFieldFocused)
                .onChange(of: baseNameText) { _, v in session.baseName = v }
                .onSubmit { nameFieldFocused = false; surfaceFocused = true }
                .padding(.horizontal, HaloMetrics.s1)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .fill(c.paper)
                        .overlay(
                            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                .stroke(nameFieldFocused ? c.orange : c.ink.opacity(0.22),
                                        lineWidth: nameFieldFocused ? HaloMechanics.rimWidth : HaloMetrics.hairline)))
        }
    }

    private var planReadout: some View {
        let plan = session.plan
        return VStack(alignment: .leading, spacing: HaloMetrics.s1) {
            RailDataRow("PADS", padsLine(plan))
            RailDataRow("SLOTS", slotsLine(plan))
            RailDataRow("TOTAL", "~\(MockFormat.bytes(plan.totalBytes)) (EST · PAYLOAD)")
            RailDataRow("AFTER", "\(MockFormat.megabytes(max(0, plan.freeAfterBytes))) FREE (MOCK)")
        }
    }

    private func padsLine(_ plan: SendToPadsPlan) -> String {
        guard let last = plan.lastGridIndex, plan.placedCount > 0 else { return "— (NO SLICES) (MOCK)" }
        let g = PadGrid.groupLetter(plan.group)
        let startLegend = PadGrid.legends[plan.startGridIndex]
        let lastLegend = PadGrid.legends[last]
        return "\(g)\(startLegend) → \(g)\(lastLegend) · \(plan.placedCount) SLICES (MOCK)"
    }

    private func slotsLine(_ plan: SendToPadsPlan) -> String {
        guard let span = plan.slotSpan else { return "— (MOCK)" }
        if span.first == span.last { return "\(span.first.label) (NEXT FREE · MOCK)" }
        return "\(span.first.label)–\(span.last.label) (NEXT FREE · MOCK)"
    }

    private var overflowPlate: some View {
        let plan = session.plan
        let firstOverflowPad = PadGrid.legends[min(plan.startGridIndex + plan.placedCount, 11)]
        return HaloStatePlate(
            kind: .error,
            title: "\(plan.overflowCount) SLICES DON'T FIT",
            reason: "PAST PAD \(firstOverflowPad) IN GROUP \(PadGrid.groupLetter(plan.group)) — PICK AN EARLIER START OR FEWER SLICES.")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("CANCEL") { model.closeChop() }
                .buttonStyle(MechanicalButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(HaloMetrics.s2)
    }

    private var rule: some View {
        Rectangle().fill(c.ink.opacity(0.14)).frame(height: HaloMetrics.hairline)
    }

    // MARK: - Bindings

    private func fadeInBinding(_ i: Int, rate: Double) -> Binding<Double> {
        Binding(get: { msFromFrames(session.prep(forSlice: i).fadeInFrames, rate: rate) },
                set: { session.setFadeIn(framesFromMs($0, rate: rate), forSlice: i) })
    }

    private func fadeOutBinding(_ i: Int, rate: Double) -> Binding<Double> {
        Binding(get: { msFromFrames(session.prep(forSlice: i).fadeOutFrames, rate: rate) },
                set: { session.setFadeOut(framesFromMs($0, rate: rate), forSlice: i) })
    }

    private func gainBinding(_ i: Int) -> Binding<Double> {
        Binding(get: { Double(session.prep(forSlice: i).gainDecibels) },
                set: { session.setGainDB(Float($0), forSlice: i) })
    }

    private func msFromFrames(_ frames: Int, rate: Double) -> Double {
        rate > 0 ? Double(frames) / rate * 1000 : 0
    }

    private func framesFromMs(_ ms: Double, rate: Double) -> Int {
        max(0, Int((ms / 1000 * rate).rounded()))
    }
}
