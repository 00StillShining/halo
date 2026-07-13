import SwiftUI

/// The bottom mode bar (Brief §7): a left-aligned cluster of latched mode keys,
/// a workbench row rather than a distributed tab bar. `c.paper` fill with a
/// hairline ink rule on the TOP edge (mirror of the status strip's bottom rule).
/// The active mode is `mechanicalEngaged` — a mode is a latched machine state and
/// gets the committed orange bar, not the lighter `mechanicalSelected` rim.
struct HaloModeBar: View {
    @Environment(\.halo) private var c
    var mode: HaloMode
    var visibleModes: [HaloMode]
    var onSelect: (HaloMode) -> Void

    var body: some View {
        HStack(spacing: HaloMetrics.s2) {
            ForEach(Array(visibleModes.enumerated()), id: \.element) { index, m in
                Button {
                    onSelect(m)
                } label: {
                    HStack(spacing: HaloMetrics.s1) {
                        Text(m.title)
                        Text("⌘\(index + 1)")
                            .font(HaloType.mono(9))
                            .foregroundStyle(c.inkSoft.opacity(0.55))
                    }
                    .frame(minWidth: 96)
                }
                .buttonStyle(MechanicalButtonStyle())
                .mechanicalEngaged(mode == m)
                .focusable()
                .help("\(m.title) mode — Command-\(index + 1)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HaloMetrics.s3)
        .frame(height: HaloMetrics.modeBarHeight)
        .frame(maxWidth: .infinity)
        .background(
            c.paper.overlay(alignment: .top) {
                Rectangle()
                    .fill(c.ink.opacity(0.22))
                    .frame(height: HaloMetrics.hairline)
            }
        )
    }
}
