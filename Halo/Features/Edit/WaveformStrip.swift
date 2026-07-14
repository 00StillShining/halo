import SwiftUI

/// Pure waveform-strip geometry (frame ↔ x, trim clamping). Extracted so the mapping
/// is unit-testable without a live view. All maths is on real measured frame counts.
enum WaveformGeometry {

    /// Map a source frame to an x position within `width`. Clamped to [0, width].
    static func frameToX(_ frame: Int, sourceFrameCount n: Int, width: CGFloat) -> CGFloat {
        guard n > 0, width > 0 else { return 0 }
        let f = min(max(frame, 0), n)
        return CGFloat(Double(f) / Double(n)) * width
    }

    /// Map an x position within `width` back to a source frame. Clamped to [0, n].
    static func xToFrame(_ x: CGFloat, sourceFrameCount n: Int, width: CGFloat) -> Int {
        guard n > 0, width > 0 else { return 0 }
        let frac = min(max(x / width, 0), 1)
        return Int((Double(frac) * Double(n)).rounded())
    }

    /// Constrain a proposed trim window so `start < end` with at least `minGap` frames
    /// between them, both inside [0, n]. Returns the adjusted (start, end).
    static func clampTrim(start: Int, end: Int, sourceFrameCount n: Int, minGap: Int) -> (start: Int, end: Int) {
        let gap = max(1, minGap)
        var s = min(max(start, 0), n)
        var e = min(max(end, 0), n)
        if e - s < gap {
            // Prefer keeping the handle the caller moved; nudge the other one.
            if s + gap <= n { e = s + gap } else { s = max(0, n - gap); e = n }
        }
        return (s, e)
    }
}

/// The custom waveform editor (Brief §7 "waveform, trim, fade"). A `Canvas`-drawn
/// min/max envelope with mechanical trim handles (the `HaloFader` cap language), fade
/// ramps, and an audition playhead. Reads as a technical instrument panel, not a media
/// scrubber — no stock controls. HONEST (DD-022): it draws only a LOCAL sample's real
/// summary; the playhead appears only while that sample is actually auditioning.
struct WaveformStrip: View {
    @Environment(\.halo) private var c

    let summary: WaveformSummary
    let prep: SamplePrep
    /// 0…1 through the trimmed window while auditioning; nil when idle (no fake motion).
    let playheadProgress: Double?
    /// Called with a clamped (startFrame, endFrame) window as a handle is dragged.
    let onSetTrim: (Int, Int) -> Void

    var height: CGFloat = 120

    private var n: Int { summary.sourceFrameCount }
    private var trimStart: Int { min(max(prep.trimStartFrame, 0), n) }
    private var trimEnd: Int { min(max(prep.trimEndFrame ?? n, trimStart), n) }
    private var minGap: Int { max(1, summary.framesPerBucket) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let startX = WaveformGeometry.frameToX(trimStart, sourceFrameCount: n, width: w)
            let endX = WaveformGeometry.frameToX(trimEnd, sourceFrameCount: n, width: w)

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    drawEnvelope(ctx, size: size, startX: startX, endX: endX)
                    drawCentreLine(ctx, size: size)
                    drawFades(ctx, size: size, startX: startX, endX: endX)
                    drawPlayhead(ctx, size: size, startX: startX, endX: endX)
                }

                // Trim handles on the top rail at the window edges.
                TrimHandle(color: c, isEnabled: !summary.isEmpty)
                    .position(x: startX, y: h / 2)
                    .gesture(dragGesture(width: w, movingStart: true))
                TrimHandle(color: c, isEnabled: !summary.isEmpty)
                    .position(x: endX, y: h / 2)
                    .gesture(dragGesture(width: w, movingStart: false))
            }
            .background(
                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                    .fill(c.paper.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                            .stroke(c.ink.opacity(0.2), lineWidth: HaloMetrics.hairline)))
        }
        .frame(height: height)
    }

    // MARK: - Drag

    private func dragGesture(width: CGFloat, movingStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard n > 0, width > 0 else { return }
                let frame = WaveformGeometry.xToFrame(g.location.x, sourceFrameCount: n, width: width)
                let proposed = movingStart ? (frame, trimEnd) : (trimStart, frame)
                let clamped = WaveformGeometry.clampTrim(start: proposed.0, end: proposed.1,
                                                         sourceFrameCount: n, minGap: minGap)
                onSetTrim(clamped.start, clamped.end)
            }
    }

    // MARK: - Drawing

    private func drawEnvelope(_ ctx: GraphicsContext, size: CGSize, startX: CGFloat, endX: CGFloat) {
        let count = summary.bucketCount
        guard count > 0 else { return }
        let mid = size.height / 2
        let colWidth = size.width / CGFloat(count)
        let barWidth = max(0.6, colWidth * 0.8)
        for i in 0..<count {
            let x = (CGFloat(i) + 0.5) * colWidth
            let top = mid - CGFloat(summary.maxima[i]) * mid
            let bottom = mid - CGFloat(summary.minima[i]) * mid
            let inside = x >= startX && x <= endX
            let colour = c.inkSoft.opacity(inside ? 0.7 : 0.22)
            var rect = Path()
            rect.addRect(CGRect(x: x - barWidth / 2, y: min(top, bottom),
                                width: barWidth, height: max(0.6, abs(bottom - top))))
            ctx.fill(rect, with: .color(colour))
        }
    }

    private func drawCentreLine(_ ctx: GraphicsContext, size: CGSize) {
        var line = Path()
        line.move(to: CGPoint(x: 0, y: size.height / 2))
        line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        ctx.stroke(line, with: .color(c.ink.opacity(0.2)), lineWidth: HaloMetrics.hairline)
    }

    /// Shade the fade-in/out regions with a triangular wedge so the taper is visible.
    /// Indicative of the equal-power ramp actually applied at audition/export.
    private func drawFades(_ ctx: GraphicsContext, size: CGSize, startX: CGFloat, endX: CGFloat) {
        guard n > 0 else { return }
        let window = max(1, trimEnd - trimStart)
        let span = max(0, endX - startX)
        if prep.fadeInFrames > 0 {
            let frac = min(1, Double(prep.fadeInFrames) / Double(window))
            let fx = startX + span * CGFloat(frac)
            var wedge = Path()
            wedge.move(to: CGPoint(x: startX, y: 0))
            wedge.addLine(to: CGPoint(x: fx, y: size.height))
            wedge.addLine(to: CGPoint(x: startX, y: size.height))
            wedge.closeSubpath()
            ctx.fill(wedge, with: .color(c.paper.opacity(0.5)))
        }
        if prep.fadeOutFrames > 0 {
            let frac = min(1, Double(prep.fadeOutFrames) / Double(window))
            let fx = endX - span * CGFloat(frac)
            var wedge = Path()
            wedge.move(to: CGPoint(x: endX, y: 0))
            wedge.addLine(to: CGPoint(x: fx, y: size.height))
            wedge.addLine(to: CGPoint(x: endX, y: size.height))
            wedge.closeSubpath()
            ctx.fill(wedge, with: .color(c.paper.opacity(0.5)))
        }
    }

    private func drawPlayhead(_ ctx: GraphicsContext, size: CGSize, startX: CGFloat, endX: CGFloat) {
        guard let p = playheadProgress else { return }
        let x = startX + CGFloat(min(max(p, 0), 1)) * (endX - startX)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(line, with: .color(c.orange), lineWidth: 1)
    }
}

/// A metal trim cap in the `HaloFader` visual language: paper-high fill, top highlight,
/// ink hairline outline, hard offset shadow. No stock control.
private struct TrimHandle: View {
    let color: HaloColorTokens
    let isEnabled: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
            .fill(isEnabled ? color.paperHigh : color.paper)
            .frame(width: 12, height: 26)
            .overlay(alignment: .top) {
                Rectangle().fill(color.paperHigh)
                    .frame(height: 1)
                    .padding(.horizontal, HaloMetrics.radiusSmall)
            }
            .overlay(
                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                    .stroke(color.ink.opacity(isEnabled ? 0.3 : 0.14), lineWidth: HaloMetrics.hairline))
            .compositingGroup()
            .shadow(color: color.ink.opacity(isEnabled ? 0.28 : 0), radius: 0, x: 0, y: 2)
            .contentShape(Rectangle())
    }
}
