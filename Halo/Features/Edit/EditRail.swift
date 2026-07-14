import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// EDIT rail (Brief §7). Fuses two provenance classes and keeps them visibly distinct
/// (DD-022): the LOCAL sample library + waveform editor are REAL; the pad DESTINATION
/// is MOCK device context and `SEND CHANGES` is disabled (device transfer = Phase 0B).
/// Tokens only, mechanical controls, no stock sliders. A single top strip names both
/// classes so a reviewer sees the honesty at a glance.
struct EditRail: View {
    @Environment(\.halo) private var c
    @Environment(HaloAppModel.self) private var model
    @FocusState private var renameFocused: Bool
    @FocusState private var libraryFocused: Bool
    @State private var renameText = ""

    private var session: EditSession { model.edit }
    private var audition: AuditionPlayer { model.audition }

    var body: some View {
        VStack(alignment: .leading, spacing: HaloMetrics.s2) {
            provenanceStrip
            libraryPanel
            destinationPanel
            waveformPanel
            trimFadePanel
            gainPanel
            formatPanel
            memoryPanel
            sendPanel
        }
        .onChange(of: session.selectedAssetID) { _, _ in
            renameText = session.selectedAsset?.displayName ?? ""
        }
        .onChange(of: renameFocused) { _, focused in
            model.edit.isRenaming = focused
            if !focused { commitRename() }
        }
    }

    // MARK: - Provenance strip

    private var provenanceStrip: some View {
        HStack(spacing: HaloMetrics.s1) {
            RailTag("MOCK")
            Text("MOCK DEVICE CONTEXT · LOCAL EDIT IS REAL")
                .font(HaloType.mono(10))
                .foregroundStyle(c.inkSoft.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Panel A · LIBRARY (local, REAL)

    private var libraryPanel: some View {
        HaloPanel("LIBRARY") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                HStack {
                    Text("\(session.library.count) LOCAL")
                        .font(HaloType.mono(10))
                        .foregroundStyle(c.inkSoft)
                    Spacer(minLength: 0)
                    Button("ADD SAMPLE") { presentImportPanel() }
                        .buttonStyle(MechanicalButtonStyle())
                        .focusable()
                        .help("Add a local audio file to the library")
                }
                if session.library.isEmpty {
                    HaloStatePlate(kind: .empty, title: "NO SAMPLES",
                                   reason: "ADD A FILE, OR DRAG ONE HERE.",
                                   actionLabel: "ADD SAMPLE",
                                   actionHelp: "Add a local audio file to the library") {
                        presentImportPanel()
                    }
                } else {
                    libraryRows
                }
            }
        }
    }

    private var libraryRows: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: HaloMetrics.s1) {
                    ForEach(session.library) { asset in
                        libraryRow(asset).id(asset.id)
                    }
                }
            }
            .frame(height: min(CGFloat(session.library.count) * 52, 184))
            .focusable()
            .focused($libraryFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                moveSelection(press.key == .upArrow ? -1 : 1, proxy: proxy)
            }
        }
    }

    private func libraryRow(_ asset: SampleAsset) -> some View {
        let selected = session.selectedAssetID == asset.id
        return Button {
            session.select(asset.id)
            libraryFocused = true
        } label: {
            HStack(spacing: HaloMetrics.s2) {
                WaveformThumbnail(summary: asset.summary)
                    .frame(width: 52, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.displayName)
                        .font(HaloType.mono(11))
                        .foregroundStyle(c.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(rowSummary(asset))
                        .font(HaloType.mono(9))
                        .foregroundStyle(c.inkSoft.opacity(0.85))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(HaloMetrics.s1)
            .background(
                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                    .fill(selected ? c.paperHigh : c.paper.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                            .stroke(c.ink.opacity(0.18), lineWidth: HaloMetrics.hairline)))
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
        .help("Local sample — right-click to reveal in Finder")
        .contextMenu {
            // Imports are referenced in place (DD-022): the honest reveal target is the
            // sample's real source URL, not the (empty) canonical Library folder.
            Button("Reveal in Finder") { HaloFileStore.reveal(asset.sourceURL) }
        }
    }

    private func rowSummary(_ asset: SampleAsset) -> String {
        "\(MockFormat.duration(asset.durationSeconds)) · "
        + "\(MockFormat.rate(Int(asset.sampleRate.rounded())))HZ · "
        + MockFormat.channelsLong(asset.channelCount)
    }

    // MARK: - Panel B · DESTINATION (mock device context)

    private var destinationPanel: some View {
        HaloPanel("DESTINATION") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                HStack {
                    Text("PAD TARGET").font(HaloType.mono(11)).foregroundStyle(c.inkSoft)
                    Spacer(minLength: 0)
                    RailTag("MOCK")
                }
                groupRow
                miniGrid
                RailDataRow("CURRENT", currentAssignmentLine)
                RailDataRow("TARGET", targetLine)
            }
        }
    }

    private var groupRow: some View {
        HStack(spacing: HaloMetrics.s1) {
            ForEach(0..<4, id: \.self) { g in
                Button(PadGrid.groupLetter(g)) {
                    session.selectedGroup = g
                    model.selectEditPad(gridIndex: session.selectedGridIndex)
                }
                .buttonStyle(MechanicalButtonStyle())
                .mechanicalSelected(session.selectedGroup == g)
                .focusable()
                .help("Select group \(PadGrid.groupLetter(g))")
            }
            Spacer(minLength: 0)
        }
    }

    private var miniGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: HaloMetrics.s1), count: 3),
            spacing: HaloMetrics.s1
        ) {
            ForEach(0..<12, id: \.self) { gridIndex in
                let selected = session.selectedGridIndex == gridIndex
                Button {
                    model.selectEditPad(gridIndex: selected ? nil : gridIndex)
                } label: {
                    Text(PadGrid.legends[gridIndex])
                        .font(HaloType.mono(10))
                        .foregroundStyle(c.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                .fill(c.paper)
                                .overlay(
                                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                        .stroke(c.ink.opacity(0.22), lineWidth: HaloMetrics.hairline)))
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
            }
        }
    }

    private var currentAssignmentLine: String {
        guard let gridIndex = session.selectedGridIndex else { return "— (SELECT A PAD) (MOCK)" }
        let padLabel = "PAD \(PadGrid.legends[gridIndex]) · GROUP \(PadGrid.groupLetter(session.selectedGroup))"
        if let slot = session.selectedAssignment?.slot, let sound = session.selectedPadSound {
            return "\(padLabel) · SLOT \(slot.label) \"\(sound.name)\" (MOCK)"
        }
        return "\(padLabel) · NO ASSIGNMENT (MOCK)"
    }

    private var targetLine: String {
        guard session.selectedGridIndex != nil else { return "— (MOCK)" }
        if let slot = session.selectedAssignment?.slot {
            return "REPLACES SLOT \(slot.label) (MOCK)"
        }
        if let free = session.nextFreeSlot {
            return "NEW SLOT \(free.label) · NEXT FREE (MOCK)"
        }
        return "— (LIBRARY FULL) (MOCK)"
    }

    // MARK: - Panel C · WAVEFORM (the editor — REAL)

    private var waveformPanel: some View {
        HaloPanel("WAVEFORM") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                if let asset = session.selectedAsset {
                    nameRow(asset)
                    WaveformStrip(summary: asset.summary,
                                  prep: session.selectedPrep,
                                  playheadProgress: playheadProgress(for: asset),
                                  onSetTrim: { start, end in
                                      session.setTrim(start: start, end: end == asset.frameCount ? nil : end)
                                  })
                    transportRow(asset)
                } else if let gridIndex = session.selectedGridIndex, session.selectedAssignment?.slot != nil {
                    RailCaption("PAD \(PadGrid.legends[gridIndex]) HOLDS A DEVICE SAMPLE — WAVEFORM UNAVAILABLE (DEVICE SAMPLE, NEEDS DEVICE)")
                } else {
                    RailCaption("SELECT A LOCAL SAMPLE TO EDIT")
                }
            }
        }
    }

    private func nameRow(_ asset: SampleAsset) -> some View {
        HStack(spacing: HaloMetrics.s1) {
            Text("NAME").font(HaloType.mono(11)).foregroundStyle(c.inkSoft)
            TextField("", text: $renameText)
                .textFieldStyle(.plain)
                .font(HaloType.mono(11))
                .foregroundStyle(c.ink)
                .focused($renameFocused)
                .onSubmit { commitRename(); renameFocused = false }
                .padding(.horizontal, HaloMetrics.s1)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .fill(c.paper)
                        .overlay(
                            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                .stroke(renameFocused ? c.orange : c.ink.opacity(0.22),
                                        lineWidth: renameFocused ? HaloMechanics.rimWidth : HaloMetrics.hairline)))
        }
    }

    private func transportRow(_ asset: SampleAsset) -> some View {
        VStack(alignment: .leading, spacing: HaloMetrics.s1) {
            HStack(spacing: HaloMetrics.s1) {
                Button(audition.isPlaying ? "STOP" : "AUDITION") { model.toggleAudition() }
                    .buttonStyle(MechanicalButtonStyle())
                    .mechanicalEngaged(audition.isPlaying)
                    .focusable()
                    .help(audition.isPlaying ? "Stop audition — Space" : "Audition locally — Space")
                Button("CHOP INTO PADS") { model.beginChopFromEdit() }
                    .buttonStyle(MechanicalButtonStyle())
                    .focusable()
                    .help("Onset-slice this sample onto consecutive pads (device send disabled, Phase 0B)")
                Spacer(minLength: 0)
            }
            RailCaption("SPACE TO AUDITION — LOCAL PLAYBACK OF THE PREPARED SAMPLE")
        }
    }

    private func playheadProgress(for asset: SampleAsset) -> Double? {
        guard audition.isPlaying, audition.playingAssetID == asset.id else { return nil }
        return audition.progress
    }

    // MARK: - Panel D · TRIM / FADE

    private var trimFadePanel: some View {
        HaloPanel("TRIM / FADE") {
            if let asset = session.selectedAsset {
                let prep = session.selectedPrep
                let rate = asset.sampleRate
                let (start, end) = prep.resolvedTrim(sourceFrameCount: asset.frameCount)
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    RailDataRow("START", clock(start, rate))
                    RailDataRow("END", clock(end, rate))
                    RailDataRow("LENGTH", clock(end - start, rate))
                    HStack(spacing: HaloMetrics.s1) {
                        Button("RESET TRIM") { session.setTrim(start: 0, end: nil) }
                            .buttonStyle(MechanicalButtonStyle())
                        Button("RESET ALL") { session.resetPrep() }
                            .buttonStyle(MechanicalButtonStyle())
                        Spacer(minLength: 0)
                    }
                    Rectangle().fill(c.ink.opacity(0.12)).frame(height: HaloMetrics.hairline)
                    HaloFader("FADE IN", value: fadeInBinding(rate: rate), in: 0...500,
                              defaultValue: 0, step: 5, coarseStep: 50) { String(format: "%.0f MS", $0) }
                    HaloFader("FADE OUT", value: fadeOutBinding(rate: rate), in: 0...500,
                              defaultValue: 0, step: 5, coarseStep: 50) { String(format: "%.0f MS", $0) }
                }
            } else {
                RailCaption("SELECT A LOCAL SAMPLE TO EDIT")
            }
        }
    }

    // MARK: - Panel E · GAIN / LEVEL

    private var gainPanel: some View {
        HaloPanel("GAIN / LEVEL") {
            if session.selectedAsset != nil {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    HaloFader("GAIN", value: gainBinding(), in: -24...12,
                              defaultValue: 0, step: 0.5, coarseStep: 3) { String(format: "%+.1f DB", $0) }
                    Button("NORMALISE") { session.setNormalize(!session.selectedPrep.normalize) }
                        .buttonStyle(MechanicalButtonStyle())
                        .mechanicalEngaged(session.selectedPrep.normalize)
                    RailCaption("PEAK → −1 dBFS (OPT-IN)")
                }
            } else {
                RailCaption("SELECT A LOCAL SAMPLE TO EDIT")
            }
        }
    }

    // MARK: - Panel F · FORMAT

    private var formatPanel: some View {
        HaloPanel("FORMAT") {
            if session.selectedAsset != nil {
                let prep = session.selectedPrep
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    Text("CHANNELS").font(HaloType.label(9)).haloLabelCase().foregroundStyle(c.inkSoft)
                    HStack(spacing: HaloMetrics.s1) {
                        channelButton("PRESERVE", .preserve, current: prep.channelMode)
                        channelButton("MONO", .mono, current: prep.channelMode)
                        channelButton("STEREO", .stereo, current: prep.channelMode)
                        Spacer(minLength: 0)
                    }
                    Text("RATE").font(HaloType.label(9)).haloLabelCase().foregroundStyle(c.inkSoft)
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: HaloMetrics.s1), count: 2),
                        spacing: HaloMetrics.s1
                    ) {
                        ForEach(SampleTreatment.allSelectable, id: \.self) { t in
                            Button(t.label) { session.setTreatment(t) }
                                .buttonStyle(MechanicalButtonStyle())
                                .mechanicalSelected(session.selectedTreatment == t)
                        }
                    }
                }
            } else {
                RailCaption("SELECT A LOCAL SAMPLE TO EDIT")
            }
        }
    }

    private func channelButton(_ label: String, _ mode: SamplePrep.ChannelMode,
                               current: SamplePrep.ChannelMode) -> some View {
        Button(label) { session.setChannelMode(mode) }
            .buttonStyle(MechanicalButtonStyle())
            .mechanicalSelected(current == mode)
    }

    // MARK: - Panel G · MEMORY IMPACT (real local estimate)

    private var memoryPanel: some View {
        HaloPanel("MEMORY IMPACT") {
            if let est = session.selectedEstimate, let asset = session.selectedAsset {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    RailDataRow("RATE", "\(MockFormat.rate(Int(est.sampleRate.rounded())))HZ")
                    RailDataRow("CHANNELS", MockFormat.channelsLong(est.channels))
                    RailDataRow("LENGTH", clock(est.frames, est.sampleRate))
                    RailDataRow("ON DEVICE", "\(MockFormat.bytes(est.totalBytes)) (EST · PAYLOAD)")
                    RailDataRow("HALO RAM", HaloRecordFormat.bytes(Int64(asset.canonicalBytes)))
                }
            } else {
                RailCaption("SELECT A LOCAL SAMPLE TO EDIT")
            }
        }
    }

    // MARK: - Panel H · SEND CHANGES (disabled — needsDevice)

    private var sendPanel: some View {
        HaloPanel("SEND CHANGES") {
            VStack(alignment: .leading, spacing: HaloMetrics.s1) {
                Button("SEND CHANGES") {}
                    .buttonStyle(MechanicalButtonStyle())
                    .disabled(true)
                    .help("Send edits to the device — needs a verified protocol (Phase 0B)")
                RailCaption("DEVICE TRANSFER — NEEDS VERIFIED PROTOCOL (PHASE 0B)")
                if let intent = sendIntentLine { RailCaption(intent) }
            }
        }
    }

    private var sendIntentLine: String? {
        guard session.selectedAsset != nil, let gridIndex = session.selectedGridIndex else { return nil }
        let padLabel = "PAD \(PadGrid.legends[gridIndex]) · GROUP \(PadGrid.groupLetter(session.selectedGroup))"
        if let slot = session.selectedAssignment?.slot {
            return "WOULD REPLACE SLOT \(slot.label) ON \(padLabel) (MOCK)"
        }
        if let free = session.nextFreeSlot {
            return "WOULD CREATE SLOT \(free.label) AND ASSIGN \(padLabel) (MOCK)"
        }
        return nil
    }

    // MARK: - Bindings & helpers

    private func gainBinding() -> Binding<Double> {
        Binding(get: { Double(session.selectedPrep.gainDecibels) },
                set: { session.setGainDB(Float($0)) })
    }

    private func fadeInBinding(rate: Double) -> Binding<Double> {
        Binding(get: { msFromFrames(session.selectedPrep.fadeInFrames, rate: rate) },
                set: { session.setFadeIn(framesFromMs($0, rate: rate)) })
    }

    private func fadeOutBinding(rate: Double) -> Binding<Double> {
        Binding(get: { msFromFrames(session.selectedPrep.fadeOutFrames, rate: rate) },
                set: { session.setFadeOut(framesFromMs($0, rate: rate)) })
    }

    private func msFromFrames(_ frames: Int, rate: Double) -> Double {
        rate > 0 ? Double(frames) / rate * 1000 : 0
    }

    private func framesFromMs(_ ms: Double, rate: Double) -> Int {
        max(0, Int((ms / 1000 * rate).rounded()))
    }

    /// `mm:ss.d` from a frame count at a sample rate.
    private func clock(_ frames: Int, _ rate: Double) -> String {
        MockFormat.duration(rate > 0 ? Double(max(0, frames)) / rate : 0)
    }

    private func commitRename() {
        guard let id = session.selectedAssetID else { return }
        session.rename(id: id, to: renameText)
        renameText = session.selectedAsset?.displayName ?? renameText
    }

    private func moveSelection(_ delta: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let items = session.library
        guard !items.isEmpty else { return .ignored }
        let current = session.selectedAssetID.flatMap { id in items.firstIndex { $0.id == id } }
        let next = min(max((current ?? -1) + delta, 0), items.count - 1)
        session.select(items[next].id)
        proxy.scrollTo(items[next].id, anchor: .center)
        return .handled
    }

    // MARK: - Import

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.wav, .aiff, .mp3, .mpeg4Audio,
                                     UTType(filenameExtension: "caf")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await model.edit.import(urls: urls) }
        }
    }
}

/// A compact, non-interactive real waveform thumbnail for a library row (Brief §8 —
/// we have the summary, so we draw it honestly rather than a placeholder block).
struct WaveformThumbnail: View {
    @Environment(\.halo) private var c
    let summary: WaveformSummary

    var body: some View {
        Canvas { ctx, size in
            let count = summary.bucketCount
            guard count > 0 else { return }
            let mid = size.height / 2
            let colWidth = size.width / CGFloat(count)
            for i in 0..<count {
                let x = (CGFloat(i) + 0.5) * colWidth
                let top = mid - CGFloat(summary.maxima[i]) * mid
                let bottom = mid - CGFloat(summary.minima[i]) * mid
                var bar = Path()
                bar.addRect(CGRect(x: x - max(0.4, colWidth * 0.7) / 2, y: min(top, bottom),
                                   width: max(0.4, colWidth * 0.7), height: max(0.5, abs(bottom - top))))
                ctx.fill(bar, with: .color(c.inkSoft.opacity(0.7)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                .fill(c.metal.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .stroke(c.ink.opacity(0.2), lineWidth: HaloMetrics.hairline)))
    }
}
