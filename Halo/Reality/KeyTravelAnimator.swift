import RealityKit
import AppKit

/// Mechanical key-travel + velocity LED + latched-state lighting for RealityKit
/// pads/buttons (Brief §6). Captures each entity's rest transform once at bind
/// time, then composes honest channels so they never fight:
///   • `pressed` — an OBSERVED physical depression (raw pad Note On/Off) → travel,
///                 depth scaled by velocity (`HaloMechanics.travelDepth`).
///   • `led`     — a velocity-scaled emissive glow on the struck pad. Intensity
///                 follows the observed velocity MUCH more than travel does
///                 (Brief §6); instant rise, exponential decay after Note Off.
///   • `hovered` — halo's own pointer hover → a tiny lift (always honest).
///   • `lit`     — a latched/inferred state (selected mode button, active group,
///                 engaged transport) → an orange focus rim, NO travel.
///
/// Travel + LED mean "a strike was observed right now"; the rim means "a latched
/// or inferred state" (Brief §4 honesty — see DD-010/DD-012). LED colour is the
/// palette's `orangeHot` (a momentary observed event); the rim stays plain
/// `orange` (latched/inferred) — a legible two-tier vocabulary. Timing and depth
/// come from `HaloMechanics` so this matches the 2D `MechanicalButtonStyle`.
///
/// The model is authored face-up (+Y): a press is a small −Y translation, a hover
/// a small +Y lift, in the entity's local frame.
@MainActor
final class KeyTravelAnimator {

    private struct Key {
        let entity: Entity
        let rest: Transform
        var pressed = false                                    // observed depression
        var pressDepth: Float = HaloMechanics.travelMinMeters  // captured at press time
        var hovered = false                                    // halo pointer hover — always honest
        var lit = false                                        // selected/engaged rim visible
        var rim: Entity?                                       // lazily-built focus-rim child
        var led: ModelEntity?                                  // lazily-built deck-skirt glow
        var ledLevel: Float = 0                                // current LED opacity
        var controller: AnimationPlaybackController?
    }
    private var keys: [ObjectIdentifier: Key] = [:]
    /// Keys whose LED is decaying toward 0 — `tick` early-outs when this is empty,
    /// mirroring the ring rig's near-zero-idle philosophy.
    private var decayingLEDs: Set<ObjectIdentifier> = []
    private var rimAccent: NSColor = .rk(0xFF5A1F)
    private var ledAccent: NSColor = .rk(0xFF6A2A)
    private var reduceMotion = false

    /// Capture rest transforms once — call at scene bind time, never mid-animation.
    /// Resets every channel; any existing rims / LEDs are dropped (children go with
    /// the old scene graph).
    func bind(_ entities: [Entity]) {
        keys.removeAll(keepingCapacity: true)
        decayingLEDs.removeAll(keepingCapacity: true)
        for e in entities {
            keys[ObjectIdentifier(e)] = Key(entity: e, rest: e.transform)
        }
    }

    /// Set the rim accent (palette `orange`) and LED accent (palette `orangeHot`).
    /// Rebuilds rim materials on any lit key and LED materials on any glowing key so
    /// a live palette flip recolours them.
    func setAccent(rim: NSColor, led: NSColor) {
        guard rim != rimAccent || led != ledAccent else { return }
        rimAccent = rim
        ledAccent = led
        for (id, var k) in keys {
            if k.rim != nil {
                let wasLit = k.lit
                k.rim?.removeFromParent()
                k.rim = Self.makeRim(for: k.entity, accent: rimAccent)
                k.rim?.isEnabled = wasLit
            }
            if let ledEntity = k.led {
                ledEntity.model?.materials = [UnlitMaterial(color: ledAccent)]
            }
            keys[id] = k
        }
    }

    /// When on, LEDs snap on/off instead of decaying and pad travel still moves
    /// (the depression is real information; only the decorative tail is dropped).
    func setReduceMotion(_ on: Bool) { reduceMotion = on }

    // MARK: - Observed depression (travel) + velocity LED

    /// A struck pad: travel down to a velocity-scaled depth and snap the LED on at
    /// a velocity-scaled intensity (instant rise — a real LED has no attack).
    func press(_ e: Entity, velocity: Float = 1) {
        let id = ObjectIdentifier(e)
        guard var k = keys[id] else { return }
        let wasPressed = k.pressed
        k.pressed = true
        k.pressDepth = HaloMechanics.travelDepth(velocity: velocity)
        setLED(&k, level: HaloMechanics.padLEDOpacity(velocity: velocity))
        decayingLEDs.remove(id)
        settle(&k, pressChanged: !wasPressed)
        keys[id] = k
    }

    /// The pad is already down and was struck again (a different held note on the
    /// same physical pad, or a hardware retrigger): re-flash the LED at the newly
    /// observed velocity. No travel change — the cap cannot go further down.
    func restrike(_ e: Entity, velocity: Float) {
        let id = ObjectIdentifier(e)
        guard var k = keys[id] else { return }
        setLED(&k, level: HaloMechanics.padLEDOpacity(velocity: velocity))
        decayingLEDs.remove(id)
        keys[id] = k
    }

    /// The last hold on a pad ended: travel back up and let the LED decay (or snap
    /// it off under Reduce Motion).
    func release(_ e: Entity) {
        let id = ObjectIdentifier(e)
        guard var k = keys[id] else { return }
        let wasPressed = k.pressed
        k.pressed = false
        if reduceMotion {
            setLED(&k, level: 0)
            decayingLEDs.remove(id)
        } else if k.ledLevel > 0 {
            decayingLEDs.insert(id)
        }
        settle(&k, pressChanged: wasPressed)
        keys[id] = k
    }

    // MARK: - Pointer hover (halo's own observation)

    func setHovered(_ e: Entity, _ on: Bool) { mutate(e) { $0.hovered = on } } // 0.08 easeOut

    // MARK: - Latched / inferred state (rim, no travel)

    func setLit(_ e: Entity, _ on: Bool) {
        let id = ObjectIdentifier(e)
        guard var k = keys[id], k.lit != on else { return }
        if on, k.rim == nil { k.rim = Self.makeRim(for: e, accent: rimAccent) }
        k.rim?.isEnabled = on
        k.lit = on
        keys[id] = k
    }

    // MARK: - Per-frame LED decay

    /// LED decay only — early-out when nothing is decaying (one empty-set check per
    /// frame at idle, like the ring rig's `needsTick`). Travel is animated by
    /// RealityKit controllers, not here.
    func tick(deltaTime: Float) {
        guard !decayingLEDs.isEmpty else { return }
        let k = exp(-deltaTime / HaloMechanics.padLEDDecayTau)
        for id in decayingLEDs {
            guard var key = keys[id] else { decayingLEDs.remove(id); continue }
            key.ledLevel *= k
            if key.ledLevel < 0.012 {
                key.ledLevel = 0
                decayingLEDs.remove(id)
            }
            key.led?.components.set(OpacityComponent(opacity: key.ledLevel))
            keys[id] = key
        }
    }

    // MARK: - Bulk resets

    /// Release every observed depression, clear hover, and zero every LED —
    /// disconnect / MIDI reset must never leave a key stuck down or a pad glowing.
    /// Rims (latched state) are left untouched.
    func releaseAll() {
        for (id, var k) in keys {
            let pressChanged = k.pressed
            if k.pressed || k.hovered {
                k.pressed = false
                k.hovered = false
                settle(&k, pressChanged: pressChanged)
            }
            if k.ledLevel != 0 || k.led != nil { setLED(&k, level: 0) }
            keys[id] = k
        }
        decayingLEDs.removeAll(keepingCapacity: true)
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

    /// Set a key's LED level, building the deck skirt lazily on first light, and
    /// push the opacity to the entity.
    private func setLED(_ k: inout Key, level: Float) {
        if k.led == nil {
            guard level > 0 else { k.ledLevel = 0; return }
            k.led = Self.makeLED(for: k.entity, rest: k.rest, accent: ledAccent)
        }
        k.ledLevel = level
        k.led?.components.set(OpacityComponent(opacity: level))
    }

    /// Single source of motion — target Y from the composed state. Press wins over
    /// hover; both compose over rest. Depth is the per-key captured `pressDepth`
    /// (velocity-scaled). Curve/duration match the animator↔2D contract.
    private func settle(_ k: inout Key, pressChanged: Bool) {
        var t = k.rest
        if k.pressed      { t.translation.y -= k.pressDepth }
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

    // MARK: - Velocity-LED primitive

    /// A static deck-skirt glow — a thin rounded plate fixed to the DECK around the
    /// pad's rest footprint, reading as velocity-scaled light spilling from under
    /// the struck keycap. It is deliberately NOT parented to the cap: the cap
    /// travels down up to 1.3 mm, so a cap-parented base plate would sink into the
    /// top plate exactly at peak brightness — here the cap visibly sinks toward its
    /// own glow (a very mechanical read).
    ///
    /// Same doctrine as `makeRim`: Halo-owned annotation derived from `visualBounds`,
    /// never a USDZ material edit, works for USDZ and procedural fallback alike.
    /// Parented to the pad's PARENT at the pad's REST transform so it does not travel.
    private static func makeLED(for e: Entity, rest: Transform, accent: NSColor) -> ModelEntity {
        let b = e.visualBounds(relativeTo: e)             // local frame: travel-invariant
        let holder = Entity()
        holder.name = "\(e.name)_ledHolder"
        holder.transform = rest
        let m = HaloMechanics.padLEDSkirtMargin
        let led = ModelEntity(
            mesh: .generateBox(width: b.extents.x + 2 * m, height: 0.0004,
                               depth: b.extents.z + 2 * m, cornerRadius: 0.0012),
            materials: [UnlitMaterial(color: accent)])
        led.name = "\(e.name)_led"
        led.position = [b.center.x, b.min.y + HaloMechanics.padLEDSkirtLift, b.center.z]
        led.components.set(OpacityComponent(opacity: 0))
        holder.addChild(led)
        e.parent?.addChild(holder)
        return led
    }
}
