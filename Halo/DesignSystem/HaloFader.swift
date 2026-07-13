import SwiftUI

/// A reusable 2D mechanical fader (Brief §6 mechanical language) — a metal groove
/// with a square paper cap that carries the keycap top-highlight. Orange appears
/// only as the keyboard-focus rim (reserved accent). Sets a real local value and
/// claims nothing about hardware, so it is honest to be *enabled* (same class as
/// palette selection). Reused later for the Rack. All colours/type/spacing from
/// the design tokens.
///
/// Keyboard (when focused): ←/→ nudge by `step`, ⌥←/→ by `coarseStep`; double-click
/// resets to `defaultValue`.
struct HaloFader: View {
    @Environment(\.halo) private var c
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var step: Double = 0.5
    var coarseStep: Double = 3
    /// Formats the numeric readout (right-aligned, mono).
    var readout: (Double) -> String

    init(_ label: String,
         value: Binding<Double>,
         in range: ClosedRange<Double>,
         defaultValue: Double,
         step: Double = 0.5,
         coarseStep: Double = 3,
         readout: @escaping (Double) -> String) {
        self.label = label
        self._value = value
        self.range = range
        self.defaultValue = defaultValue
        self.step = step
        self.coarseStep = coarseStep
        self.readout = readout
    }

    private let trackHeight: CGFloat = 4
    private let capWidth: CGFloat = 16
    private let capHeight: CGFloat = 22

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((value - range.lowerBound) / span)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(HaloType.label(9))
                    .haloLabelCase()
                    .foregroundStyle(c.inkSoft)
                Spacer(minLength: HaloMetrics.s2)
                Text(readout(value))
                    .font(HaloType.mono(11))
                    .foregroundStyle(isEnabled ? c.ink : c.inkSoft.opacity(0.5))
            }

            GeometryReader { geo in
                let usable = max(0, geo.size.width - capWidth)
                ZStack(alignment: .leading) {
                    // Metal groove (hairline outline).
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .fill(c.metal.opacity(0.5))
                        .frame(height: trackHeight)
                        .overlay(
                            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                .stroke(c.ink.opacity(0.22), lineWidth: HaloMetrics.hairline))
                        .frame(maxHeight: .infinity, alignment: .center)

                    cap
                        .offset(x: usable * fraction)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard isEnabled, usable > 0 else { return }
                            let frac = min(max((g.location.x - capWidth / 2) / usable, 0), 1)
                            setFromFraction(frac)
                        }
                )
                .onTapGesture(count: 2) { if isEnabled { value = defaultValue } }
            }
            .frame(height: capHeight + 6)
            .focusable(isEnabled)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                let dir: Double = press.key == .leftArrow ? -1 : 1
                return nudge(dir, coarse: press.modifiers.contains(.option))
            }
        }
    }

    private var cap: some View {
        RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
            .fill(isEnabled ? c.paperHigh : c.paper)
            .frame(width: capWidth, height: capHeight)
            .overlay(alignment: .top) {
                // Keycap top-highlight.
                Rectangle()
                    .fill(c.paperHigh)
                    .frame(height: 1)
                    .padding(.horizontal, HaloMetrics.radiusSmall)
            }
            .overlay(
                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                    .stroke(c.ink.opacity(isEnabled ? 0.3 : 0.14), lineWidth: HaloMetrics.hairline))
            .overlay {
                if focused && isEnabled {
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall + 2)
                        .stroke(c.orange, lineWidth: HaloMechanics.rimWidth)
                        .padding(-2)
                }
            }
            .compositingGroup()
            .shadow(color: c.ink.opacity(isEnabled ? 0.28 : 0), radius: 0, x: 0, y: 2)
    }

    private func setFromFraction(_ frac: CGFloat) {
        let span = range.upperBound - range.lowerBound
        let raw = range.lowerBound + Double(frac) * span
        value = clampToStep(raw)
    }

    private func nudge(_ direction: Double, coarse: Bool) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        value = clampToStep(value + direction * (coarse ? coarseStep : step))
        return .handled
    }

    private func clampToStep(_ raw: Double) -> Double {
        let stepped = (raw / step).rounded() * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}

#if DEBUG
private struct HaloFaderPreviewHost: View {
    @State private var gain = -12.0
    var body: some View {
        HaloFader("GAIN", value: $gain, in: -40...0, defaultValue: -12) {
            String(format: "%.1f DB", $0)
        }
        .padding(32)
        .frame(width: 260)
        .environment(\.halo, .graphPaper)
        .background(HaloColorTokens.graphPaper.paper)
    }
}
#Preview("HaloFader") { HaloFaderPreviewHost() }
#endif
