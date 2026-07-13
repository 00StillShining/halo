import SwiftUI

/// The graph-paper stage background (Brief §5). Cool blue-grey canvas with thin
/// technical rules — minor lines on an 8/16 px cadence and a heavier major line
/// every few cells. Drawn with `Canvas` so it stays crisp and cheap at any size.
struct GridCanvas: View {
    @Environment(\.halo) private var c

    var minorSpacing: CGFloat = HaloMetrics.gridMinorSpacing
    var majorEvery: Int = HaloMetrics.gridMajorEvery

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(c.canvas))

            var minor = Path()
            var major = Path()
            var i = 0
            var x: CGFloat = 0
            while x <= size.width {
                let p = Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }
                if i % majorEvery == 0 { major.addPath(p) } else { minor.addPath(p) }
                x += minorSpacing; i += 1
            }
            i = 0
            var y: CGFloat = 0
            while y <= size.height {
                let p = Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }
                if i % majorEvery == 0 { major.addPath(p) } else { minor.addPath(p) }
                y += minorSpacing; i += 1
            }
            ctx.stroke(minor, with: .color(c.gridMinor), lineWidth: HaloMetrics.hairline)
            ctx.stroke(major, with: .color(c.gridMajor), lineWidth: HaloMetrics.hairline)
        }
        .drawingGroup()
    }
}

#Preview {
    GridCanvas()
        .haloPalette(.graphPaper)
        .frame(width: 600, height: 400)
}
