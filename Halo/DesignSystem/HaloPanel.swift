import SwiftUI

/// The manufactured panel primitive — the single reusable rail surface so the
/// rail never drifts into SaaS cards (Brief §5/§7 forbidden shortcuts). Anatomy:
/// an uppercase tracked mono header on its own strip, a hairline rule, a
/// square-ish 4 px radius, a hairline ink outline, and a HARD offset shadow
/// (blur 0 — the extrusion read of stacked paper lit from the upper-left). No
/// material blur, no `.regularMaterial`, no grouped `Form`.
struct HaloPanel<Content: View>: View {
    @Environment(\.halo) private var c
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(HaloType.label(10))
                .haloLabelCase()
                .foregroundStyle(c.inkSoft)
                .padding(.horizontal, HaloMetrics.s2)
                .frame(height: 28, alignment: .leading)
            Rectangle()
                .fill(c.ink.opacity(0.18))
                .frame(height: HaloMetrics.hairline)
            content
                .padding(HaloMetrics.s2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HaloMetrics.radiusPanel)
                .fill(c.paper)
                .overlay(
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusPanel)
                        .stroke(c.ink.opacity(0.25), lineWidth: HaloMetrics.hairline)
                )
        )
        .compositingGroup()
        // Hard offset shadow, blur 0 — stacked paper, key light from upper-left.
        .shadow(color: c.ink.opacity(0.22), radius: 0,
                x: HaloMetrics.panelShadow.width, y: HaloMetrics.panelShadow.height)
    }
}
