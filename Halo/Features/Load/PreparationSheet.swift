import RealityKit
import SwiftUI
import UniformTypeIdentifiers

/// The compact preparation sheet (Brief §7 "Load a sample onto a pad"). A custom
/// transient panel, NOT a stock `.sheet` (stock chrome is a forbidden shortcut).
/// Presented from `HaloRootView` in a ZStack over everything; Escape cancels via
/// the transient stack (`haloTransient`). Honesty (DD-014): the FILE block is REAL
/// (decoded from the dropped file), the DESTINATION block is MOCK, and
/// `SEND + ASSIGN` is disabled (a device write — Phase 0B) and never bound to
/// Return (`haloSafeDefault` is forbidden here — the grep-able device-write rule).
struct PreparationSheet: View {
    @Environment(\.halo) private var c
    @Bindable var session: LoadSession

    private var library: MockDeviceLibrary { session.library }

    var body: some View {
        if let prep = session.prep {
            content(prep)
                .frame(width: 460)
                .background(
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusPanel)
                        .fill(c.paper)
                        .overlay(
                            RoundedRectangle(cornerRadius: HaloMetrics.radiusPanel)
                                .stroke(c.ink.opacity(0.28), lineWidth: HaloMetrics.hairline)))
                .compositingGroup()
                .shadow(color: c.ink.opacity(0.35), radius: 0, x: 4, y: 10)
                .haloTransient { session.cancelPreparation() }
        }
    }

    private func content(_ prep: PrepRequest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerStrip
            rule
            fileSection(prep.metadata)
            rule
            destinationSection(prep)
            rule
            treatmentSection(prep)
            rule
            footer
        }
    }

    // MARK: - Sections

    private var headerStrip: some View {
        HStack {
            Text("PREPARE SAMPLE")
                .font(HaloType.label(10))
                .haloLabelCase()
                .foregroundStyle(c.inkSoft)
            Spacer(minLength: 0)
            RailTag("MOCK")
        }
        .padding(.horizontal, HaloMetrics.s2)
        .frame(height: 32)
    }

    private func fileSection(_ meta: PrepMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RailDataRow("FILE", meta.displayName)
            Text(fileSummary(meta))
                .font(HaloType.mono(10))
                .foregroundStyle(c.inkSoft.opacity(0.85))
        }
        .padding(HaloMetrics.s2)
    }

    private func fileSummary(_ meta: PrepMetadata) -> String {
        "\(MockFormat.duration(meta.durationSeconds)) · "
        + "\(MockFormat.rate(meta.sampleRate))HZ · "
        + "\(MockFormat.channelsLong(meta.channels)) · "
        + MockFormat.bytes(meta.bytes)
    }

    private func destinationSection(_ prep: PrepRequest) -> some View {
        VStack(alignment: .leading, spacing: HaloMetrics.s2) {
            HStack {
                Text("DESTINATION")
                    .font(HaloType.label(9)).haloLabelCase()
                    .foregroundStyle(c.inkSoft)
                Spacer(minLength: 0)
                RailTag("MOCK")
            }

            // GROUP keycaps
            HStack(spacing: HaloMetrics.s1) {
                Text("GROUP").font(HaloType.mono(11)).foregroundStyle(c.inkSoft)
                    .frame(width: 48, alignment: .leading)
                ForEach(0..<4, id: \.self) { g in
                    Button(PadGrid.groupLetter(g)) { session.setPrepGroup(g) }
                        .buttonStyle(MechanicalButtonStyle())
                        .mechanicalSelected(prep.destinationGroup == g)
                }
                Spacer(minLength: 0)
            }

            // Mini pad grid
            HStack(alignment: .top, spacing: HaloMetrics.s1) {
                Text("PAD").font(HaloType.mono(11)).foregroundStyle(c.inkSoft)
                    .frame(width: 48, alignment: .leading)
                miniGrid(prep)
            }

            RailDataRow("SLOT", nextFreeSlotLine())
            RailDataRow("PREVIOUS", previousLine(prep))
        }
        .padding(HaloMetrics.s2)
    }

    private func miniGrid(_ prep: PrepRequest) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(52), spacing: HaloMetrics.s1), count: 3),
            spacing: HaloMetrics.s1
        ) {
            ForEach(0..<12, id: \.self) { gridIndex in
                let selected = prep.destinationGridIndex == gridIndex
                Button {
                    session.setPrepGridIndex(gridIndex)
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

    private func treatmentSection(_ prep: PrepRequest) -> some View {
        VStack(alignment: .leading, spacing: HaloMetrics.s2) {
            HStack(spacing: HaloMetrics.s1) {
                Text("TREATMENT").font(HaloType.mono(11)).foregroundStyle(c.inkSoft)
                Spacer(minLength: 0)
            }
            HStack(spacing: HaloMetrics.s1) {
                ForEach(Treatment.allCases, id: \.self) { t in
                    Button(t.rawValue) { session.setPrepTreatment(t) }
                        .buttonStyle(MechanicalButtonStyle())
                        .mechanicalSelected(prep.treatment == t)
                }
            }
            RailDataRow("REQUIRES", requiresLine(prep))
        }
        .padding(HaloMetrics.s2)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: HaloMetrics.s1) {
            HStack {
                Button("CANCEL") { session.cancelPreparation() }
                    .buttonStyle(MechanicalButtonStyle())
                Spacer(minLength: 0)
                Button("SEND + ASSIGN") {}
                    .buttonStyle(MechanicalButtonStyle())
                    .disabled(true)
            }
            RailCaption("DEVICE TRANSFER — NEEDS VERIFIED PROTOCOL (PHASE 0B)")
        }
        .padding(HaloMetrics.s2)
    }

    private var rule: some View {
        Rectangle().fill(c.ink.opacity(0.14)).frame(height: HaloMetrics.hairline)
    }

    // MARK: - Derived MOCK context

    /// Lowest addressable slot not currently occupied (mock). "next free".
    private func nextFreeSlotLine() -> String {
        let used = Set(library.sounds.map { $0.slot.raw })
        let free = (1...999).first { !used.contains($0) }
        guard let free, let slot = SampleSlotID(free) else { return "—  (FULL) (MOCK)" }
        return "\(slot.label) · NEXT FREE (MOCK)"
    }

    private func previousLine(_ prep: PrepRequest) -> String {
        guard let gridIndex = prep.destinationGridIndex else { return "— (NO PAD SELECTED)" }
        let assignment = library.project.assignment(
            group: prep.destinationGroup, gridIndex: gridIndex)
        guard let slot = assignment.slot, let sound = library.sound(for: slot) else {
            return "NO PREVIOUS ASSIGNMENT"
        }
        return "PAD \(PadGrid.legends[gridIndex]) → SLOT \(slot.label) \"\(sound.name)\""
    }

    private func requiresLine(_ prep: PrepRequest) -> String {
        let est = prep.treatment.estimatedBytes(source: prep.metadata)
        let after = library.freeBytes - est
        return "~\(MockFormat.bytes(est)) (EST) · AFTER: \(MockFormat.megabytes(max(0, after))) FREE (MOCK)"
    }
}

/// Stage-area file-drop delegate (Brief §7): a drop onto a numeric pad preselects
/// its destination and opens the preparation sheet. The drop reticle tracks the
/// hovered pad; it is halo presentation (a drop *target*), never a hardware claim.
struct StageDropDelegate: DropDelegate {
    let scene: EP40SceneController
    let session: LoadSession
    let viewSize: CGSize

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        scene.updateDropReticle(at: info.location, viewSize: viewSize)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { scene.hideDropReticle() }

    func performDrop(info: DropInfo) -> Bool {
        let pad = scene.numericPad(at: info.location, viewSize: viewSize)
        scene.hideDropReticle()
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        let session = self.session   // capture the Sendable value, not self
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                session.beginPreparation(fileURL: url, padHint: pad)
            }
        }
        return true
    }
}

#if DEBUG
#Preview("PreparationSheet") {
    let model = HaloAppModel()
    // Preview without a real file: inject a synthetic request (DEBUG-only path —
    // `beginPreparation` would rightly reject a nonexistent file and show nothing).
    model.load.injectPreviewPrep(PrepRequest(
        fileURL: URL(fileURLWithPath: "/tmp/amen-chop.wav"),
        metadata: PrepMetadata(displayName: "amen-chop.wav", durationSeconds: 1.8,
                               sampleRate: 44100, channels: 2, bytes: 317_520),
        destinationGroup: 0,
        destinationGridIndex: 0,
        treatment: .original))
    return PreparationSheetPreviewHost(session: model.load)
        .environment(model)
        .environment(\.halo, .graphPaper)
        .padding(40)
        .background(HaloColorTokens.graphPaper.canvas)
}

private struct PreparationSheetPreviewHost: View {
    @Bindable var session: LoadSession
    var body: some View { PreparationSheet(session: session) }
}
#endif
