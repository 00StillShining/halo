import SwiftUI

/// The interactive CHOP waveform (Brief §5c): the real min/max envelope with alternating
/// slice tint bands, numbered labels in pad order, draggable/addable/deletable cut
/// markers in the mechanical `TrimHandle` language, and an audition playhead that appears
/// ONLY while a slice is actually playing (no fake motion — Brief §1/§4). Reuses
/// `WaveformGeometry`. Tokens only; orange is reserved for the selected slice and the
/// playhead. Reads as a technical instrument, not a media scrubber.
struct SliceWaveform: View {
    @Environment(\.halo) private var c

    let summary: WaveformSummary
    let slices: [SliceRange]
    let cuts: [Int]
    let sourceFrameCount: Int
    let selectedSlice: Int?
    /// The slice currently auditioning (draws the playhead), or nil when idle.
    let playingSlice: Int?
    /// 0…1 through the playing slice; nil when idle.
    let playheadProgress: Double?

    var onAddCut: (Int) -> Void          // frame
    var onMoveCut: (Int, Int) -> Void    // cutIndex, frame
    var onRemoveCut: (Int) -> Void       // cutIndex
    var onSelectSlice: (Int) -> Void     // sliceIndex (also auditions)

    var height: CGFloat = 140

    @State private var draggingCut: Int?

    private var n: Int { sourceFrameCount }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    drawBands(ctx, size: size, width: w)
                    drawEnvelope(ctx, size: size)
                    drawCentreLine(ctx, size: size)
                    drawLabels(ctx, size: size, width: w)
                    drawPlayhead(ctx, size: size, width: w)
                }

                // Interactive cut markers (mechanical caps on the top rail).
                ForEach(Array(cuts.enumerated()), id: \.offset) { idx, frame in
                    let x = WaveformGeometry.frameToX(frame, sourceFrameCount: n, width: w)
                    CutMarker(color: c, height: h)
                        .position(x: x, y: h / 2)
                        .gesture(markerDrag(index: idx, width: w))
                        .simultaneousGesture(
                            TapGesture().modifiers(.option).onEnded { onRemoveCut(idx) }
                        )
                        .help("Drag to move · ⌥-click to delete")
                }
            }
            .contentShape(Rectangle())
            .gesture(addCutGesture(width: w))       // double-click empty space → add cut
            .gesture(selectGesture(width: w))       // single click → select + audition
            .background(
                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                    .fill(c.paper.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                            .stroke(c.ink.opacity(0.2), lineWidth: HaloMetrics.hairline)))
        }
        .frame(height: height)
    }

    // MARK: - Gestures

    private func markerDrag(index: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                guard n > 0, width > 0 else { return }
                draggingCut = index
                let frame = WaveformGeometry.xToFrame(g.location.x, sourceFrameCount: n, width: width)
                onMoveCut(index, frame)
            }
            .onEnded { _ in draggingCut = nil }
    }

    private func addCutGesture(width: CGFloat) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { event in
                guard n > 0, width > 0 else { return }
                onAddCut(WaveformGeometry.xToFrame(event.location.x, sourceFrameCount: n, width: width))
            }
    }

    private func selectGesture(width: CGFloat) -> some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { event in
                guard n > 0, width > 0 else { return }
                let frame = WaveformGeometry.xToFrame(event.location.x, sourceFrameCount: n, width: width)
                if let i = slices.firstIndex(where: { frame >= $0.startFrame && frame < $0.endFrame }) {
                    onSelectSlice(i)
                } else if !slices.isEmpty {
                    onSelectSlice(slices.count - 1)   // clicked the trailing edge
                }
            }
    }

    // MARK: - Drawing

    private func drawBands(_ ctx: GraphicsContext, size: CGSize, width: CGFloat) {
        for slice in slices {
            let x0 = WaveformGeometry.frameToX(slice.startFrame, sourceFrameCount: n, width: width)
            let x1 = WaveformGeometry.frameToX(slice.endFrame, sourceFrameCount: n, width: width)
            let isSelected = slice.id == selectedSlice
            let fill: Color = isSelected
                ? c.orange.opacity(0.10)
                : c.inkSoft.opacity(slice.id.isMultiple(of: 2) ? 0.05 : 0.10)
            var rect = Path()
            rect.addRect(CGRect(x: x0, y: 0, width: max(0, x1 - x0), height: size.height))
            ctx.fill(rect, with: .color(fill))
        }
    }

    private func drawEnvelope(_ ctx: GraphicsContext, size: CGSize) {
        let count = summary.bucketCount
        guard count > 0 else { return }
        let mid = size.height / 2
        let colWidth = size.width / CGFloat(count)
        let barWidth = max(0.6, colWidth * 0.8)
        for i in 0..<count {
            let x = (CGFloat(i) + 0.5) * colWidth
            let top = mid - CGFloat(summary.maxima[i]) * mid
            let bottom = mid - CGFloat(summary.minima[i]) * mid
            var rect = Path()
            rect.addRect(CGRect(x: x - barWidth / 2, y: min(top, bottom),
                                width: barWidth, height: max(0.6, abs(bottom - top))))
            ctx.fill(rect, with: .color(c.inkSoft.opacity(0.7)))
        }
    }

    private func drawCentreLine(_ ctx: GraphicsContext, size: CGSize) {
        var line = Path()
        line.move(to: CGPoint(x: 0, y: size.height / 2))
        line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        ctx.stroke(line, with: .color(c.ink.opacity(0.2)), lineWidth: HaloMetrics.hairline)
    }

    /// Slice numbers top-left of each band, 1…n mirroring pad order.
    private func drawLabels(_ ctx: GraphicsContext, size: CGSize, width: CGFloat) {
        for slice in slices {
            let x0 = WaveformGeometry.frameToX(slice.startFrame, sourceFrameCount: n, width: width)
            let selected = slice.id == selectedSlice
            let text = Text("\(slice.id + 1)")
                .font(HaloType.mono(9))
                .foregroundColor(selected ? c.orange : c.inkSoft.opacity(0.8))
            ctx.draw(ctx.resolve(text), at: CGPoint(x: x0 + 3, y: 3), anchor: .topLeading)
        }
    }

    private func drawPlayhead(_ ctx: GraphicsContext, size: CGSize, width: CGFloat) {
        guard let playing = playingSlice, let p = playheadProgress,
              let slice = slices.first(where: { $0.id == playing }) else { return }
        let frame = slice.startFrame + Int(Double(slice.frameCount) * min(max(p, 0), 1))
        let x = WaveformGeometry.frameToX(frame, sourceFrameCount: n, width: width)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(line, with: .color(c.orange), lineWidth: 1)
    }
}

/// A thin cut marker with a machined cap at the top rail — the `TrimHandle` language.
private struct CutMarker: View {
    let color: HaloColorTokens
    let height: CGFloat

    var body: some View {
        ZStack {
            // Full-height thin cut line.
            Rectangle()
                .fill(color.ink.opacity(0.55))
                .frame(width: HaloMetrics.hairline, height: height)
            // Metal cap at the top for the grip.
            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                .fill(color.paperHigh)
                .frame(width: 10, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .stroke(color.ink.opacity(0.3), lineWidth: HaloMetrics.hairline))
                .compositingGroup()
                .shadow(color: color.ink.opacity(0.28), radius: 0, x: 0, y: 2)
                .offset(y: -(height / 2) + 9)
        }
        // Wide invisible hit area so the cap is easy to grab.
        .frame(width: 16, height: height)
        .contentShape(Rectangle())
    }
}
