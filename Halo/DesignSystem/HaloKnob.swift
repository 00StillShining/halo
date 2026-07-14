import SwiftUI

/// A reusable 2D mechanical rotary knob (Brief §6 mechanical language, §5a rack:
/// "knobs with real travel, orange only for engaged/committed"). A metal collar with
/// a paper cap that actually rotates through ~270° of throw, a hard offset contact
/// shadow, a keycap top-highlight, and a machined pointer. Orange appears ONLY as the
/// keyboard-focus rim — never as decoration. Sets a real local value and claims
/// nothing about hardware, so it is honest to be enabled. All colours/type/spacing
/// come from the design tokens.
///
/// Drag vertically (up = increase) or use ←/→ when focused (⌥ for the coarse step);
/// double-click resets to `defaultValue`.
struct HaloKnob: View {
    @Environment(\.halo) private var c
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var step: Double
    var coarseStep: Double
    var readout: (Double) -> String

    init(_ label: String,
         value: Binding<Double>,
         in range: ClosedRange<Double>,
         defaultValue: Double,
         step: Double = 0.02,
         coarseStep: Double = 0.1,
         readout: @escaping (Double) -> String) {
        self.label = label
        self._value = value
        self.range = range
        self.defaultValue = defaultValue
        self.step = step
        self.coarseStep = coarseStep
        self.readout = readout
    }

    private let diameter: CGFloat = 46
    private let sweep: Double = 270   // degrees of total throw
    @State private var dragAnchor: Double?

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((value - range.lowerBound) / span)
    }

    /// Pointer angle: −135° (min) … +135° (max).
    private var angle: Angle { .degrees(-sweep / 2 + Double(fraction) * sweep) }

    var body: some View {
        VStack(spacing: 6) {
            knob
            Text(label)
                .font(HaloType.label(8))
                .haloLabelCase()
                .foregroundStyle(c.inkSoft)
                .lineLimit(1)
            Text(readout(value))
                .font(HaloType.mono(9))
                .foregroundStyle(isEnabled ? c.ink : c.inkSoft.opacity(0.5))
                .lineLimit(1)
        }
        .frame(width: diameter + 12)
    }

    private var knob: some View {
        ZStack {
            // Metal collar (fixed) — the plinth the cap turns inside.
            Circle()
                .fill(c.metal)
                .frame(width: diameter + 4, height: diameter + 4)
                .overlay(Circle().stroke(c.ink.opacity(0.22), lineWidth: HaloMetrics.hairline))
                .offset(y: 1.5)

            // Tick marks at min / centre / max — a machined bezel, not decoration.
            ForEach([-sweep / 2, 0, sweep / 2], id: \.self) { deg in
                Rectangle()
                    .fill(c.ink.opacity(0.28))
                    .frame(width: HaloMetrics.hairline, height: 4)
                    .offset(y: -(diameter / 2 + 4))
                    .rotationEffect(.degrees(deg))
            }

            // Turning cap.
            Circle()
                .fill(isEnabled ? c.paperHigh : c.paper)
                .frame(width: diameter, height: diameter)
                .overlay(alignment: .top) {
                    // Keycap top-highlight.
                    Circle()
                        .trim(from: 0.5, to: 1)
                        .stroke(c.paperHigh, lineWidth: 1)
                        .frame(width: diameter - 4, height: diameter - 4)
                        .blur(radius: 0.5)
                }
                .overlay(Circle().stroke(c.ink.opacity(isEnabled ? 0.3 : 0.14),
                                         lineWidth: HaloMetrics.hairline))
                .overlay {
                    // Machined pointer line.
                    Rectangle()
                        .fill(isEnabled ? c.ink : c.inkSoft.opacity(0.4))
                        .frame(width: 2, height: diameter / 2 - 6)
                        .offset(y: -(diameter / 4 - 1))
                }
                .rotationEffect(angle)
                .overlay {
                    if focused && isEnabled {
                        Circle()
                            .stroke(c.orange, lineWidth: HaloMechanics.rimWidth)
                            .padding(-3)
                    }
                }
                .compositingGroup()
                .shadow(color: c.ink.opacity(isEnabled ? 0.28 : 0), radius: 0, x: 0, y: 2)
        }
        .frame(width: diameter + 8, height: diameter + 8)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard isEnabled else { return }
                    if dragAnchor == nil { dragAnchor = value }
                    let span = range.upperBound - range.lowerBound
                    // ~180 px of vertical travel spans the whole range; up = increase.
                    let delta = Double(-g.translation.height) / 180 * span
                    value = clampToStep((dragAnchor ?? value) + delta)
                }
                .onEnded { _ in dragAnchor = nil }
        )
        .onTapGesture(count: 2) { if isEnabled { value = defaultValue } }
        .focusable(isEnabled)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard isEnabled else { return .ignored }
            let dir: Double = press.key == .leftArrow ? -1 : 1
            value = clampToStep(value + dir * (press.modifiers.contains(.option) ? coarseStep : step))
            return .handled
        }
        .help(label)
    }

    private func clampToStep(_ raw: Double) -> Double {
        let stepped = (raw / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}

#if DEBUG
private struct HaloKnobPreviewHost: View {
    @State private var fb = 0.45
    var body: some View {
        HaloKnob("FEEDBACK", value: $fb, in: 0...1, defaultValue: 0.45) {
            String(format: "%.0f%%", $0 * 100)
        }
        .padding(32)
        .environment(\.halo, .graphPaper)
        .background(HaloColorTokens.graphPaper.paper)
    }
}
#Preview("HaloKnob") { HaloKnobPreviewHost() }
#endif
