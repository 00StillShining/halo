import SwiftUI

/// The contextual right rail (Brief §7). A fitted manufactured panel, not a
/// floating drawer: it sits one paper layer above the canvas with a hairline +
/// 2 px metal extrusion strip on its leading edge. Width is driven by
/// `HaloRootView`; this view only routes per-mode content and owns Play's
/// collapse spine. The rail is furniture, not a transient — Escape never
/// collapses it.
struct HaloRailView: View {
    @Environment(\.halo) private var c
    var mode: HaloMode
    @Binding var isPlayCollapsed: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            c.paperHigh

            // Leading edge: hairline + 2 px metal extrusion strip.
            HStack(spacing: 0) {
                Rectangle().fill(c.ink.opacity(0.22)).frame(width: HaloMetrics.hairline)
                Rectangle().fill(c.metal).frame(width: 2)
                Spacer(minLength: 0)
            }

            if mode == .play && isPlayCollapsed {
                spine
            } else {
                railContent
            }
        }
        .clipped()   // width animates; content must not spill
    }

    // MARK: - Collapsed Play spine

    /// A tab, not a keycap — a plain button drawing a vertically-rotated label
    /// plus a small metal grip mark. Clicking expands the rail.
    private var spine: some View {
        Button {
            isPlayCollapsed = false
        } label: {
            ZStack {
                Text("RAIL")
                    .font(HaloType.label(9))
                    .haloLabelCase()
                    .foregroundStyle(c.inkSoft)
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                Rectangle()
                    .fill(c.metal)
                    .frame(width: 6, height: 6)
                    .offset(y: 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .help("Expand rail")
        .padding(.leading, 3)   // clear the extrusion strip
    }

    // MARK: - Expanded rail

    private var railContent: some View {
        VStack(spacing: 0) {
            if mode == .play {
                // Expanded Play keeps a trailing tab to collapse back.
                HStack(spacing: 0) {
                    railScroll
                    collapseTab
                }
            } else {
                railScroll
            }
        }
    }

    private var railScroll: some View {
        ScrollView(.vertical) {
            VStack(spacing: HaloMetrics.s2) {
                switch mode {
                case .play:    PlayRail()
                case .load:    LoadRail()
                case .edit:    EditRail()
                case .capture: CaptureRail()
                case .backups: BackupsRail()
                case .rack:    RackRail()
                }
            }
            .padding(HaloMetrics.s2)
            .padding(.leading, HaloMetrics.s1)   // extra clearance past the extrusion strip
        }
        .frame(maxWidth: .infinity)
    }

    /// The 28 pt trailing collapse tab shown in the expanded Play rail — the same
    /// control as the spine, mirrored to the trailing edge.
    private var collapseTab: some View {
        Button {
            isPlayCollapsed = true
        } label: {
            Text("RAIL")
                .font(HaloType.label(9))
                .haloLabelCase()
                .foregroundStyle(c.inkSoft)
                .fixedSize()
                .rotationEffect(.degrees(90))
                .frame(width: HaloMetrics.railSpineWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .help("Collapse rail")
    }
}
