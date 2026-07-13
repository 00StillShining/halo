import SwiftUI

/// LOAD rail scaffold (Brief §7). A PADS / SOUNDS tab row (genuine local UI
/// state — the tabs really switch), over honest panels. The actual device read
/// needs the verified SysEx protocol (Phase 0B), stated in the caption; no
/// device values are invented.
struct LoadRail: View {
    @Environment(\.halo) private var c

    enum Tab: String, CaseIterable { case pads = "PADS", sounds = "SOUNDS" }
    @State private var tab: Tab = .pads

    var body: some View {
        VStack(spacing: HaloMetrics.s2) {
            HStack(spacing: HaloMetrics.s1) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button(t.rawValue) { tab = t }
                        .buttonStyle(MechanicalButtonStyle())
                        .mechanicalSelected(tab == t)
                        .focusable()
                }
                Spacer(minLength: 0)
            }

            switch tab {
            case .pads:
                HaloPanel("PADS") {
                    VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                        RailDataRow("PROJECT")
                        RailDataRow("GROUP")
                        RailDataRow("SLOTS", "12")
                        RailCaption("DEVICE READ — NEEDS VERIFIED PROTOCOL (PHASE 0B)")
                    }
                }
            case .sounds:
                HaloPanel("SOUNDS 001–999") {
                    VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                        RailDataRow("SELECTED")
                        RailCaption("DEVICE READ — NEEDS VERIFIED PROTOCOL (PHASE 0B)")
                    }
                }
            }
        }
    }
}
