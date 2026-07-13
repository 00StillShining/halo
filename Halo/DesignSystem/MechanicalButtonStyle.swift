import SwiftUI

// MARK: - Latched-state environment (selected / engaged)

private struct MechanicalSelectedKey: EnvironmentKey { static let defaultValue = false }
private struct MechanicalEngagedKey:  EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// A selected control (e.g. the active palette): thin orange focus rim.
    var mechanicalSelected: Bool {
        get { self[MechanicalSelectedKey.self] }
        set { self[MechanicalSelectedKey.self] = newValue }
    }
    /// An engaged/latched control (e.g. a future MONITOR ON): rim + committed bar.
    var mechanicalEngaged: Bool {
        get { self[MechanicalEngagedKey.self] }
        set { self[MechanicalEngagedKey.self] = newValue }
    }
}

extension View {
    func mechanicalSelected(_ on: Bool) -> some View { environment(\.mechanicalSelected, on) }
    func mechanicalEngaged(_ on: Bool)  -> some View { environment(\.mechanicalEngaged, on) }
}

// MARK: - Mechanical button style (Brief §6)

/// A keycap, not a card. Square-ish (radiusSmall), a visible extruded side
/// ("plinth"), a hard offset shadow that collapses on press, and a top highlight
/// that narrows on press. Timing/depth come from `HaloMechanics` so it matches the
/// 3D `KeyTravelAnimator` by construction. Every colour reads from the active
/// palette (`@Environment(\.halo)`), all type from `HaloType`, spacing from
/// `HaloMetrics`. No stock `Button` look survives. Orange is reserved for
/// selected/engaged/keyboard-focus — never decorative.
struct MechanicalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MechanicalCap(configuration: configuration)
    }
}

/// Inner view so we can read environment (enabled/focus/selected/engaged) and
/// hold hover state, which a bare `ButtonStyle.makeBody` cannot.
private struct MechanicalCap: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.halo) private var c
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused          // keyboard focus (consumers .focusable())
    @Environment(\.mechanicalSelected) private var isSelected
    @Environment(\.mechanicalEngaged) private var isEngaged
    @State private var hovering = false

    private var pressed: Bool { configuration.isPressed && isEnabled }

    private var faceOffset: CGFloat {
        pressed ? HaloMechanics.travelPoints
                : (hovering && isEnabled ? -HaloMechanics.hoverLiftPoints : 0)
    }

    private var labelColor: Color {
        isEnabled ? c.ink : c.inkSoft.opacity(0.45)
    }

    private var shadowY: CGFloat { pressed ? 0.5 : 2 }
    private var shadowOpacity: Double { !isEnabled ? 0 : (pressed ? 0.12 : 0.30) }

    var body: some View {
        ZStack {
            // Plinth — the extruded side wall. Fixed; the face travels over it.
            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                .fill(c.metal)
                .offset(y: HaloMechanics.travelPoints)

            // Travelling face.
            configuration.label
                .font(HaloType.label(10))
                .haloLabelCase()
                .foregroundStyle(labelColor)
                .padding(.horizontal, HaloMetrics.s2)
                .frame(minHeight: 28)
                .background(face)
                .offset(y: faceOffset)
                .animation(pressed ? .easeIn(duration: HaloMechanics.pressDuration)
                                   : .easeOut(duration: HaloMechanics.releaseDuration),
                           value: pressed)
                .animation(.easeOut(duration: HaloMechanics.hoverDuration), value: hovering)
        }
        .compositingGroup()
        // Hard offset shadow (blur 0) that collapses on press → contact shadow.
        .shadow(color: c.ink.opacity(shadowOpacity), radius: 0, x: 0, y: shadowY)
        .overlay { if isFocused && isEnabled { focusRing } }
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }

    // The keycap face: paper fill, top highlight that narrows on press, ink
    // outline, and the latched-state rim / engaged bar.
    private var face: some View {
        let outlineOpacity = isEnabled ? 0.25 : 0.12
        return RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
            .fill(isEnabled ? c.paperHigh : c.paper)
            .overlay(alignment: .top) {
                // Top-edge rim light: a 1px highlight that narrows + dims on press.
                Rectangle()
                    .fill(c.paperHigh.opacity(pressed ? 0.5 : (hovering && isEnabled ? 1 : 0.85)))
                    .frame(height: pressed ? 0.5 : 1)
                    .padding(.horizontal, HaloMetrics.radiusSmall)
            }
            .overlay {
                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                    .stroke(c.ink.opacity(outlineOpacity), lineWidth: HaloMetrics.hairline)
            }
            .overlay {
                // Selected / engaged: 1px orange rim stroked just inside the face.
                if isSelected || isEngaged {
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall - 0.5)
                        .stroke(c.orange, lineWidth: HaloMechanics.rimWidth)
                        .padding(1)
                }
            }
            .overlay(alignment: .bottom) {
                // Engaged (committed): a 2px orange bar inset along the bottom edge.
                if isEngaged {
                    Rectangle()
                        .fill(c.orange)
                        .frame(height: 2)
                        .padding(.horizontal, 3)
                        .padding(.bottom, 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall))
    }

    // Keyboard focus: 1px orange rim floated 2pt OUTSIDE the plinth, distinct
    // from the selected rim (which sits inside the face).
    private var focusRing: some View {
        RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall + 2)
            .stroke(c.orange, lineWidth: HaloMechanics.rimWidth)
            .padding(-2)
    }
}
