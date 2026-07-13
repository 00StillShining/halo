import RealityKit

/// Mechanical key-travel for RealityKit pads/buttons (Brief §6). Captures each
/// entity's rest transform once at bind time, then presses it into the top plate
/// on a fast ease-in and returns it on a slower damped ease-out. Timing and depth
/// mirror the 2D `MechanicalButtonStyle` so the hardware model and UI controls
/// feel identical.
///
/// The model is authored face-up (+Y), so a press is a small −Y translation in the
/// entity's local frame.
@MainActor
final class KeyTravelAnimator {

    /// Full depression. Brief §6: 1.1–1.3 mm of travel.
    var travel: Float = 0.0012

    private struct Key {
        let entity: Entity
        let rest: Transform
        var pressed: Bool = false
        var controller: AnimationPlaybackController?
    }
    private var keys: [ObjectIdentifier: Key] = [:]

    /// Capture rest transforms once — call at scene bind time, never mid-animation.
    func bind(_ entities: [Entity]) {
        keys.removeAll(keepingCapacity: true)
        for e in entities {
            keys[ObjectIdentifier(e)] = Key(entity: e, rest: e.transform)
        }
    }

    func press(_ entity: Entity) {
        let id = ObjectIdentifier(entity)
        guard var k = keys[id], !k.pressed else { return }
        var down = k.rest
        down.translation.y -= travel
        k.controller?.stop()
        // Note On / pointer down: 55–75 ms ease-in, contact shadow collapsing.
        k.controller = entity.move(to: down, relativeTo: entity.parent,
                                   duration: 0.065, timingFunction: .easeIn)
        k.pressed = true
        keys[id] = k
    }

    func release(_ entity: Entity) {
        let id = ObjectIdentifier(entity)
        guard var k = keys[id], k.pressed else { return }
        k.controller?.stop()
        // Note Off: 95–120 ms critically damped return.
        k.controller = entity.move(to: k.rest, relativeTo: entity.parent,
                                   duration: 0.11, timingFunction: .easeOut)
        k.pressed = false
        keys[id] = k
    }

    /// Release everything — disconnect / MIDI reset must never leave a key stuck down.
    func releaseAll() {
        let stuck = keys.values.filter(\.pressed).map(\.entity)
        for e in stuck { release(e) }
    }
}
