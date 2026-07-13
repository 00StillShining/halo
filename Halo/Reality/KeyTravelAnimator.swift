import RealityKit
import AppKit

/// Mechanical key-travel + latched-state lighting for RealityKit pads/buttons
/// (Brief §6). Captures each entity's rest transform once at bind time, then
/// composes three honest channels through a single `settle` function so they
/// never fight:
///   • `pressed` — an OBSERVED physical depression (pad Note On/Off) → travel.
///   • `hovered` — halo's own pointer hover → a tiny lift (always honest).
///   • `lit`     — a latched/inferred state (selected mode button, active group,
///                 engaged transport) → an orange focus rim, NO travel.
///
/// Travel means "a depression was observed right now"; the rim means "a latched
/// or inferred state" (Brief §4 honesty — see DD-010). Timing and depth come from
/// `HaloMechanics` so this matches the 2D `MechanicalButtonStyle` by construction.
///
/// The model is authored face-up (+Y), so a press is a small −Y translation and a
/// hover a small +Y lift in the entity's local frame.
@MainActor
final class KeyTravelAnimator {

    private struct Key {
        let entity: Entity
        let rest: Transform
        var pressed = false          // observed depression (or halo's own pointer, P2)
        var hovered = false          // halo pointer hover — always honest
        var lit = false              // selected/engaged rim visible
        var rim: Entity?             // lazily-built focus-rim child
        var controller: AnimationPlaybackController?
    }
    private var keys: [ObjectIdentifier: Key] = [:]
    private var accent: NSColor = .rk(0xFF5A1F)

    /// Capture rest transforms once — call at scene bind time, never mid-animation.
    /// Resets every channel; any existing rims are dropped (children go with the
    /// old scene graph).
    func bind(_ entities: [Entity]) {
        keys.removeAll(keepingCapacity: true)
        for e in entities {
            keys[ObjectIdentifier(e)] = Key(entity: e, rest: e.transform)
        }
    }

    /// Set the focus-rim accent (the active palette's `orange`). Rebuilds the rim
    /// materials on any currently-lit key so a live palette flip recolours them.
    func setAccent(_ color: NSColor) {
        guard color != accent else { return }
        accent = color
        for (id, var k) in keys where k.rim != nil {
            let wasLit = k.lit
            k.rim?.removeFromParent()
            k.rim = Self.makeRim(for: k.entity, accent: accent)
            k.rim?.isEnabled = wasLit
            keys[id] = k
        }
    }

    // MARK: - Observed depression (travel)

    func press(_ e: Entity)   { mutate(e) { $0.pressed = true  } }   // 0.065 easeIn
    func release(_ e: Entity) { mutate(e) { $0.pressed = false } }   // 0.11 easeOut

    // MARK: - Pointer hover (halo's own observation)

    func setHovered(_ e: Entity, _ on: Bool) { mutate(e) { $0.hovered = on } } // 0.08 easeOut

    // MARK: - Latched / inferred state (rim, no travel)

    func setLit(_ e: Entity, _ on: Bool) {
        let id = ObjectIdentifier(e)
        guard var k = keys[id], k.lit != on else { return }
        if on, k.rim == nil { k.rim = Self.makeRim(for: e, accent: accent) }
        k.rim?.isEnabled = on
        k.lit = on
        keys[id] = k
    }

    // MARK: - Bulk resets

    /// Release every observed depression and clear hover — disconnect / MIDI reset
    /// must never leave a key stuck down. Rims (latched state) are left untouched.
    func releaseAll() {
        for (id, var k) in keys where k.pressed || k.hovered {
            let pressChanged = k.pressed
            k.pressed = false
            k.hovered = false
            settle(&k, pressChanged: pressChanged)
            keys[id] = k
        }
    }

    /// Turn every rim off — used on disconnect / `.waiting` where nothing is
    /// selected, engaged, or grouped.
    func unlitAll() {
        for (id, var k) in keys where k.lit {
            k.rim?.isEnabled = false
            k.lit = false
            keys[id] = k
        }
    }

    // MARK: - Motion core

    /// Apply a mutation to a key's channels, then settle it to the composed target.
    private func mutate(_ e: Entity, _ change: (inout Key) -> Void) {
        let id = ObjectIdentifier(e)
        guard var k = keys[id] else { return }
        let wasPressed = k.pressed
        change(&k)
        settle(&k, pressChanged: k.pressed != wasPressed)
        keys[id] = k
    }

    /// Single source of motion — target Y from the composed state. Press wins over
    /// hover; both compose over rest. Curve/duration match the animator↔2D contract.
    private func settle(_ k: inout Key, pressChanged: Bool) {
        var t = k.rest
        if k.pressed      { t.translation.y -= HaloMechanics.travelMeters }
        else if k.hovered { t.translation.y += HaloMechanics.hoverLiftMeters }

        k.controller?.stop()
        let (d, tf): (TimeInterval, AnimationTimingFunction) =
            k.pressed ? (HaloMechanics.pressDuration, .easeIn)
                      : (pressChanged ? (HaloMechanics.releaseDuration, .easeOut)
                                      : (HaloMechanics.hoverDuration, .easeOut))
        k.controller = k.entity.move(to: t, relativeTo: k.entity.parent,
                                     duration: d, timingFunction: tf)
    }

    // MARK: - Focus-rim primitive

    /// A thin orange square outline built from four bars, added as a CHILD of the
    /// button entity so it follows travel automatically and works identically for
    /// the Blender USDZ and the procedural fallback. Halo-owned geometry — it never
    /// mutates USDZ materials (whose structure we don't know and must not touch).
    /// Reads as an annotation, not a fake LED (UnlitMaterial, not emissive).
    private static func makeRim(for e: Entity, accent: NSColor) -> Entity {
        let b = e.visualBounds(relativeTo: e)                 // local-space cap bounds
        let w = b.extents.x + 0.002, d = b.extents.z + 0.002  // 1 mm margin per side
        let t: Float = 0.0006, h: Float = 0.0006              // thin bar, 0.6 mm
        let mat = UnlitMaterial(color: accent)
        let rim = Entity()
        rim.name = "\(e.name)_focusRim"
        let bars: [(Float, Float, Float, Float)] = [          // (x, z, width, depth)
            (0, -(d - t) / 2, w, t), (0, (d - t) / 2, w, t),
            (-(w - t) / 2, 0, t, d), ((w - t) / 2, 0, t, d),
        ]
        for (x, z, bw, bd) in bars {
            let bar = ModelEntity(mesh: .generateBox(width: bw, height: h, depth: bd),
                                  materials: [mat])
            bar.position = [x + b.center.x, b.min.y + h / 2, z + b.center.z]
            rim.addChild(bar)
        }
        rim.isEnabled = false
        e.addChild(rim)
        return rim
    }
}
