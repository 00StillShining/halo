import SwiftUI

/// Small drawn vector marks so halo never falls back to SF Symbols (Brief §5 — the
/// interface is 100% drawn geometry / Core Graphics, no stock system iconography).
/// Each mark is stroked with a token colour supplied by the caller and sized by its
/// frame, so it inherits the same palette + metrics as every other drawn element.

/// A single chevron, pointing up or down — used for disclosure state on the drawn
/// (non-`Menu`) pickers. Replaces `Image(systemName: "chevron.up/down")`.
struct HaloChevron: Shape {
    var pointingUp: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let inset = rect.height * 0.12
        if pointingUp {
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY - inset))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.minY + inset))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - inset))
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + inset))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - inset))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + inset))
        }
        return p
    }
}

/// A circular loop arrow — the "looping" indicator on a playing GRAB take. Drawn as
/// a near-full arc with a tangential arrowhead so it reads as repeat without an SF
/// Symbol. The arc is sampled point-by-point (not `addArc`) so the arrowhead tangent
/// is derived from the exact curve drawn and can never point the wrong way.
struct HaloLoopGlyph: View {
    var color: Color
    var lineWidth: CGFloat = 1.3

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - lineWidth
            guard r > 0 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func pt(_ deg: Double) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            }

            // ~260° of arc with a gap, travelling from `start` to `end`.
            let start = 40.0, end = 300.0, step = 8.0
            var arc = Path()
            arc.move(to: pt(start))
            var d = start + step
            while d < end { arc.addLine(to: pt(d)); d += step }
            arc.addLine(to: pt(end))
            let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            ctx.stroke(arc, with: .color(color), style: stroke)

            // Arrowhead at the end, aligned to the actual travel tangent.
            let tip = pt(end)
            let prev = pt(end - step)
            let dx = tip.x - prev.x, dy = tip.y - prev.y
            let len = max(0.0001, (dx * dx + dy * dy).squareRoot())
            let bx = -dx / len, by = -dy / len   // backward unit vector
            let h = max(2.2, r * 0.8)
            let phi = 0.55                        // arrowhead half-angle (~31°)
            let cphi = cos(phi), sphi = sin(phi)
            let a1 = CGPoint(x: tip.x + h * (bx * cphi - by * sphi),
                             y: tip.y + h * (bx * sphi + by * cphi))
            let a2 = CGPoint(x: tip.x + h * (bx * cphi + by * sphi),
                             y: tip.y + h * (-bx * sphi + by * cphi))
            var head = Path()
            head.move(to: a1)
            head.addLine(to: tip)
            head.addLine(to: a2)
            ctx.stroke(head, with: .color(color), style: stroke)
        }
    }
}
