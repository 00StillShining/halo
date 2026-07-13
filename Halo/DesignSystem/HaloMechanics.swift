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
    static let hoverLiftMeters: Float = 0.00015  // 0.15 mm hover lift

    // 2D equivalents (points) — the same feel at UI scale.
    static let travelPoints: CGFloat    = 2
    static let hoverLiftPoints: CGFloat = 0.5
    static let rimWidth: CGFloat        = 1      // thin orange focus rim

    // Velocity response (Brief §6: velocity affects LED intensity MORE than
    // travel). Travel varies only ~1.18x across the whole velocity range while
    // the LED varies ~5.6x — the asymmetry is the brief's mandate and is pinned
    // by `HaloMechanicsVelocityTests`. LED rise is instantaneous (a real LED has
    // no attack); travel keeps the 65 ms ease-in / 110 ms ease-out — the contrast
    // is itself part of the mechanical language.
    static let travelMinMeters: Float = 0.0011      // brief: 1.1 mm (soft depression)
    static let travelMaxMeters: Float = 0.0013      // brief: 1.3 mm (full depression)
    static func travelDepth(velocity v: Float) -> Float {   // ~1.18x span
        travelMinMeters + (travelMaxMeters - travelMinMeters) * min(max(v, 0), 1)
    }

    static let padLEDFloor: Float = 0.16
    static let padLEDScale: Float = 0.74
    static func padLEDOpacity(velocity v: Float) -> Float { // 0.16 … 0.90, ~5.6x span
        let c = min(max(v, 0), 1)
        return padLEDFloor + padLEDScale * c * c            // quadratic: soft hits read soft
    }

    static let padLEDDecayTau: Float = 0.09       // s; exponential — ~0.25 s visible tail
    static let padLEDSkirtMargin: Float = 0.0008  // 0.8 mm light spill beyond the cap
    static let padLEDSkirtLift: Float = 0.0004    // sits above the deck; no z-fighting

    // Mode change (Brief §7). One duration shared by the rail-width animation and
    // the camera move so the whole gesture reads as a single mechanical motion —
    // the model slides over, the screen is never replaced.
    static let modeChangeDuration: Double = 0.45
}

/// Brief §5 halo-ring behaviour constants. Single source of truth for the
/// ring's per-state luminance and timing so `HaloRingRig` reads no magic
/// numbers inline (same philosophy as `HaloMechanics`). Luminance values are
/// `OpacityComponent` opacities (0…1), never material colours.
enum HaloRingMechanics {
    // Segment rig
    static let segmentCount = 48

    // disconnected — the USDZ ink annulus alone (glow parent opacity 0); the
    // optional ink-softening was skipped, see DD-011.

    // discovering — one travelling head sweeping a full revolution.
    static let discoverPeriod: Float = 4.0                    // seconds per revolution
    static let discoverParentOpacity: Float = 0.9
    static let discoverFalloff: [Float] = [1.0, 0.72, 0.48, 0.28, 0.14, 0.06]
    static let discoverReduceMotionOpacity: Float = 0.14      // static, no sweep

    // connected — steady low glow, all segments lit.
    static let connectedOpacity: Float = 0.20

    // monitoring — audio-responsive, hard-capped so it never reads as a nightclub.
    static let monitorBase: Float = 0.20
    static let monitorScale: Float = 0.35
    static let monitorCap: Float = 0.55

    // recording — slow breathing.
    static let recordPeriod: Float = 3.2                      // seconds per breath
    static let recordBase: Float = 0.22
    static let recordAmplitude: Float = 0.165                 // → 0.22 … 0.55
    static let recordReduceMotionOpacity: Float = 0.45        // steady; timer carries info

    // transfer — clockwise progress ring.
    static let transferParentOpacity: Float = 0.85
    static let transferTrackOpacity: Float = 0.08             // faint un-filled track

    // error — one pulse on entry, then a stable labelled hold.
    static let errorPeakOpacity: Float = 0.85
    static let errorHoldOpacity: Float = 0.30
    static let errorRise: Float = 0.12                        // seconds, easeOut to peak
    static let errorDecay: Float = 0.5                        // seconds, peak → hold

    // Luminance write cadence — coalesce to ≤ 60 Hz even on ProMotion displays.
    static let luminanceInterval: Float = 1.0 / 60.0
}
