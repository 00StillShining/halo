import RealityKit
import SwiftUI
import simd

/// Owns the RealityKit scene: the EP-40 model, lighting rig, and hero camera.
/// Holds resolved entity references so views never search the entity tree per
/// event (Brief §8). Interactive logic (press travel, etc.) will hang off this.
@MainActor
@Observable
final class EP40SceneController {

    private(set) var isPlaceholder = true
    private(set) var missing: [EP40Entity] = []
    private var resolved: [EP40Entity: Entity] = [:]
    private(set) var modelRoot: Entity?
    private var displayRenderer: EP40DisplayRenderer?
    private var pendingDisplay = EP40DisplayState.previewStill
    private var sceneGeneration = 0
    private let keyAnimator = KeyTravelAnimator()
    private var pressedPad: EP40Entity?

    /// Build the full scene (model + lights + camera) into a world root and return it.
    func makeScene() async -> Entity {
        sceneGeneration += 1
        let generation = sceneGeneration
        let world = Entity()
        world.name = "halo_world"

        let result = await EP40ModelLoader.load()
        let renderer: EP40DisplayRenderer?
        if let displaySurface = result.resolved[.displaySurface],
           let candidate = EP40DisplayRenderer(displaySurface: displaySurface) {
            renderer = candidate
            await candidate.install(initial: pendingDisplay)
        } else {
            renderer = nil
        }

        world.addChild(result.root)
        world.addChild(Self.makeLightingRig())
        world.addChild(Self.makeHeroCamera())

        // A cancelled/replaced RealityView may finish loading after its successor.
        // Only the latest generation is allowed to become the update target.
        if generation == sceneGeneration, !Task.isCancelled {
            isPlaceholder = result.isPlaceholder
            resolved = result.resolved
            missing = result.missing
            modelRoot = result.root
            displayRenderer = renderer
            keyAnimator.bind(EP40Entity.padGridOrder.compactMap { result.resolved[$0] })
            pressedPad = nil
            renderer?.submit(pendingDisplay)
        }
        return world
    }

    func entity(_ e: EP40Entity) -> Entity? { resolved[e] }

    /// Safe before or after the USDZ finishes loading. The latest state wins.
    func applyDisplay(_ state: EP40DisplayState) {
        pendingDisplay = state
        displayRenderer?.submit(state)
        updatePadTravel(for: state)
    }

    /// Depress the single active pad and release the previous one. Works in both
    /// PREVIEW and LIVE because both set `activePadIndex`. Polyphonic travel can
    /// arrive later by feeding raw Note On/Off instead of the collapsed state.
    private func updatePadTravel(for state: EP40DisplayState) {
        let target: EP40Entity? = state.activePadIndex.flatMap { idx in
            EP40Entity.padGridOrder.indices.contains(idx) ? EP40Entity.padGridOrder[idx] : nil
        }
        guard target != pressedPad else { return }
        if let old = pressedPad, let e = resolved[old] { keyAnimator.release(e) }
        if let new = target, let e = resolved[new] { keyAnimator.press(e) }
        pressedPad = target
    }

    func activateDisplayStreaming() {
        displayRenderer?.activateStreaming()
        displayRenderer?.submit(pendingDisplay)
    }

    // MARK: - Lighting (soft key upper-left, weaker fill front-right, subtle rim). Brief §6.
    private static func makeLightingRig() -> Entity {
        let rig = Entity()
        rig.name = "halo_lights"

        func dir(_ intensity: Float, from d: SIMD3<Float>, shadow: Bool) -> Entity {
            let e = Entity()
            var comps: [any Component] = [DirectionalLightComponent(color: .white, intensity: intensity)]
            if shadow { comps.append(DirectionalLightComponent.Shadow()) }
            e.components.set(comps)
            e.look(at: .zero, from: d, relativeTo: nil)
            return e
        }
        rig.addChild(dir(2_300, from: [-0.35, 0.9, 0.35], shadow: true))   // key, above-left
        rig.addChild(dir(750,  from: [0.6, 0.3, 0.55], shadow: false))     // fill, front-right
        rig.addChild(dir(650,  from: [0.0, 0.25, -0.7], shadow: false))    // rim, from behind
        return rig
    }

    // MARK: - Hero camera — near-orthographic 3/4 view (~28° yaw, ~42° pitch). Brief §6.
    private static func makeHeroCamera() -> Entity {
        let cam = Entity()
        cam.name = "halo_camera"
        var persp = PerspectiveCameraComponent()
        persp.fieldOfViewInDegrees = 24          // small FOV → near-orthographic
        persp.near = 0.01
        persp.far = 10
        cam.components.set(persp)
        cam.position = Self.heroPosition(radius: 0.70, yawDeg: 28, pitchDeg: 42)
        cam.look(at: .zero, from: cam.position, relativeTo: nil)
        return cam
    }

    static func heroPosition(radius r: Float, yawDeg: Float, pitchDeg: Float) -> SIMD3<Float> {
        let yaw = yawDeg * .pi / 180
        let pitch = pitchDeg * .pi / 180
        return [
            r * cos(pitch) * sin(yaw),
            r * sin(pitch),
            r * cos(pitch) * cos(yaw),
        ]
    }
}
