import SwiftUI

/// The two switchable palettes required by Brief §5. Both ship behind one token
/// set; the owner picks one at the Phase 1 visual gate and the loser is deleted.
enum HaloPalette: String, CaseIterable, Sendable, Identifiable {
    case graphPaper = "A"   // cool  — "graph paper"
    case bonePaper  = "B"   // warm  — "bone paper"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .graphPaper: "A · graph paper"
        case .bonePaper:  "B · bone paper"
        }
    }
}

/// Central design tokens. Every colour in halo resolves through one of these —
/// no ad-hoc `Color(...)` at call sites (Brief §10 visual gate).
struct HaloColorTokens: Sendable, Equatable {
    var canvas: Color
    var gridMinor: Color      // opacity from the brief is baked in
    var gridMajor: Color      // opacity from the brief is baked in
    var paper: Color
    var paperHigh: Color
    var metal: Color
    var ink: Color
    var inkSoft: Color
    var orange: Color
    var orangeHot: Color
    var riddimGreen: Color
    var lcdGreen: Color
    var warning: Color

    /// Palette A — "graph paper" (cool). Brief §5 colour tokens.
    static let graphPaper = HaloColorTokens(
        canvas:      Color(hex: 0xAEB9BE),
        gridMinor:   Color(hex: 0xCAD3D6, opacity: 0.52),
        gridMajor:   Color(hex: 0x869399, opacity: 0.34),
        paper:       Color(hex: 0xE6E8E5),
        paperHigh:   Color(hex: 0xF4F4EF),
        metal:       Color(hex: 0xA6B0B4),
        ink:         Color(hex: 0x111315),
        inkSoft:     Color(hex: 0x343A3D),
        orange:      Color(hex: 0xFF5A1F),
        orangeHot:   Color(hex: 0xFF6A2A),
        riddimGreen: Color(hex: 0x405C4C),
        lcdGreen:    Color(hex: 0xA6D39F),
        warning:     Color(hex: 0xD94A24)
    )

    /// Palette B — "bone paper" (warm). Brief §5 colour tokens.
    static let bonePaper = HaloColorTokens(
        canvas:      Color(hex: 0xDAD8D2),
        gridMinor:   Color(hex: 0xE7E5E0, opacity: 0.60),
        gridMajor:   Color(hex: 0xB9B7AF, opacity: 0.40),
        paper:       Color(hex: 0xE7E5E0),
        paperHigh:   Color(hex: 0xF0EFEB),
        metal:       Color(hex: 0xB0AEA6),
        ink:         Color(hex: 0x1C1C1A),
        inkSoft:     Color(hex: 0x3A3936),
        orange:      Color(hex: 0xFF4A00),
        orangeHot:   Color(hex: 0xFF6A2A),
        riddimGreen: Color(hex: 0x405C4C),
        lcdGreen:    Color(hex: 0xC8FF00),
        warning:     Color(hex: 0xD94A24)
    )

    static func tokens(for palette: HaloPalette) -> HaloColorTokens {
        switch palette {
        case .graphPaper: .graphPaper
        case .bonePaper:  .bonePaper
        }
    }
}

extension HaloPalette {
    /// The `orange` token as a raw hex, for RealityKit materials (the 3D focus
    /// rim) which cannot read a SwiftUI `Color`. Kept in lockstep with the
    /// `orange:` values in `HaloColorTokens.graphPaper` / `.bonePaper` above —
    /// change both together.
    var rimAccentHex: UInt32 {
        switch self {
        case .graphPaper: 0xFF5A1F
        case .bonePaper:  0xFF4A00
        }
    }
}

// MARK: - Environment plumbing

private struct HaloColorsKey: EnvironmentKey {
    static let defaultValue: HaloColorTokens = .graphPaper
}

extension EnvironmentValues {
    /// The active palette's tokens. Views read `@Environment(\.halo) private var c`.
    var halo: HaloColorTokens {
        get { self[HaloColorsKey.self] }
        set { self[HaloColorsKey.self] = newValue }
    }
}

extension View {
    /// Inject a palette's tokens into the environment subtree.
    func haloPalette(_ palette: HaloPalette) -> some View {
        environment(\.halo, HaloColorTokens.tokens(for: palette))
    }
}

// MARK: - Hex convenience

extension Color {
    /// sRGB from a 0xRRGGBB literal, optional alpha.
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
