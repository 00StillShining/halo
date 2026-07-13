import SwiftUI

/// LOAD rail (Brief §7). A persistent MOCK-provenance strip anchors the honesty
/// (device data is mock; a real read needs the verified protocol — Phase 0B), then
/// the genuine PADS / SOUNDS tab row over the tab content. Tab and selection state
/// live in `LoadSession` (UI-only, DD-013) so a mode round-trip preserves them.
struct LoadRail: View {
    @Environment(\.halo) private var c
    @Environment(HaloAppModel.self) private var model

    var body: some View {
        @Bindable var session = model.load
        return VStack(alignment: .leading, spacing: HaloMetrics.s2) {
            provenanceStrip

            HStack(spacing: HaloMetrics.s1) {
                ForEach(LoadSession.Tab.allCases, id: \.self) { t in
                    Button(t.rawValue) { session.tab = t }
                        .buttonStyle(MechanicalButtonStyle())
                        .mechanicalSelected(session.tab == t)
                        .focusable()
                }
                Spacer(minLength: 0)
            }

            switch session.tab {
            case .pads:   PadsBoard(session: session)
            case .sounds: SoundsTable(session: session)
            }
        }
    }

    /// The anchor honesty element — shared by both tabs, always laid out first,
    /// above the tab row. (It lives inside the rail's outer scroll, so it can
    /// scroll off on short windows — the headline data rows below repeat their
    /// own (MOCK) suffixes for that case.)
    private var provenanceStrip: some View {
        HStack(spacing: HaloMetrics.s1) {
            RailTag("MOCK")
            Text("MOCK DEVICE DATA — REAL READ NEEDS VERIFIED PROTOCOL (PHASE 0B)")
                .font(HaloType.mono(10))
                .foregroundStyle(c.inkSoft.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
