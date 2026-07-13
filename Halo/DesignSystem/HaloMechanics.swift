import CoreGraphics

/// Brief §6 mechanical button language. One source of truth shared by
/// `MechanicalButtonStyle` (2D SwiftUI) and `KeyTravelAnimator` (3D RealityKit)
/// so timing and depth match by construction — the brief requires the hardware
/// model and the UI controls to feel identical.
enum HaloMechanics {
    // Timing (seconds)
    static let pressDuration: Double   = 0.065  // 55–75 ms ease-in
    static let releaseDuration: Double = 0.11   // 95–120 ms damped ease-out
    static let hoverDuration: Double   = 0.08

    // 3D depth (meters)
    static let travelMeters: Float    = 0.0012   // 1.1–1.3 mm full depression
    static let hoverLiftMeters: Float = 0.00015  // 0.15 mm hover lift

    // 2D equivalents (points) — the same feel at UI scale.
    static let travelPoints: CGFloat    = 2
    static let hoverLiftPoints: CGFloat = 0.5
    static let rimWidth: CGFloat        = 1      // thin orange focus rim
}
