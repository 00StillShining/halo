import CoreGraphics

/// Spatial tokens (Brief §5 "Geometry" + §7 "Window"). 8 px layout unit with
/// 16 / 24 / 32 as dominant spacings; square-ish surfaces (2–4 px radii);
/// hairline rules; visible panel extrusion echoing stacked paper and metal.
enum HaloMetrics {

    /// Base layout unit. Prefer `space(_:)` and the s-scale over raw numbers.
    static let unit: CGFloat = 8
    static func space(_ multiple: CGFloat) -> CGFloat { unit * multiple }

    static let s1: CGFloat = 8
    static let s2: CGFloat = 16
    static let s3: CGFloat = 24
    static let s4: CGFloat = 32

    // Surfaces are square or barely rounded — avoid the contemporary card look.
    static let radiusSmall: CGFloat = 2
    static let radiusPanel: CGFloat = 4

    // Thin technical rules.
    static let hairline: CGFloat = 1

    // Utility panels carry 6–10 px of visible edge extrusion / hard offset shadow.
    static let panelExtrusion: CGFloat = 8
    static let shadowOffset: CGFloat = 6

    // Grid canvas.
    static let gridMinorSpacing: CGFloat = 16
    static let gridMajorEvery: Int = 4        // a major line every 4 minor cells

    // Window (Brief §7).
    static let windowDefault = CGSize(width: 1440, height: 900)
    static let windowMinimum = CGSize(width: 1180, height: 720)

    // Contextual right rail width band (~34–40% in data-heavy modes).
    static let railMinFraction: CGFloat = 0.34
    static let railMaxFraction: CGFloat = 0.40
}
