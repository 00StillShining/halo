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
    private var pendingRing = HaloRingState.disconnected
    private var sceneGeneration = 0
    private let keyAnimator = KeyTravelAnimator()
    private let ringRig = HaloRingRig()
    private var controls = EP40ControlProjection.rest
    private var palette: HaloPalette = .graphPaper
    private var reduceMotion = false
    /// Polyphonic live pad travel: raw Note On/Off refcounted per physical pad
    /// (two group notes can map to one pad). Preview travel still goes through the
    /// projection; live travel goes through here (Brief §6, DD-012).
    private var padHolds = PadHoldRegistry()

    /// Held by `EP40StageView` so the SceneEvents.Update subscription that drives
    /// the ring tick lives as long as the RealityView content.
    var ringSubscription: EventSubscription?

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
            // Bind ALL pressables now (was pads only) so mode buttons, group pads
            // and transport can travel/light. Reverse map lets a hit or lookup
            // resolve back to its contract entity without searching the tree.
            let pressables = EP40Entity.pressable
            keyAnimator.bind(pressables.compactMap { result.resolved[$0] })
            keyAnimator.setAccent(rim: .rk(palette.rimAccentHex), led: .rk(palette.orangeHotHex))
            keyAnimator.setReduceMotion(reduceMotion)
            controls = .rest
            padHolds = PadHoldRegistry()
            // Halo-ring glow rig (Brief §5). Bound under the same generation guard
            // so a superseded load never rebinds the live rig. State is applied
            // from connection truth via `applyRing`, never from display frames.
            if let ring = result.resolved[.haloRing] {
                ringRig.bind(ring: ring, palette: palette)
                ringRig.setReduceMotion(reduceMotion)
                ringRig.apply(pendingRing)
            }
            renderer?.submit(pendingDisplay)
            updateControls(for: pendingDisplay)
        }
        return world
    }

    /// Recolour the focus rims when the owner flips the palette at the Phase 1
    /// gate. Cheap — at most a handful of lit prims (≤ ~20).
    func applyPalette(_ palette: HaloPalette) {
        self.palette = palette
        keyAnimator.setAccent(rim: .rk(palette.rimAccentHex), led: .rk(palette.orangeHotHex))
        ringRig.setPalette(palette)
    }

    /// Drive the halo-ring glow from connection/monitor/record truth (Brief §5).
    /// Safe before or after the USDZ finishes loading — the latest state wins.
    func applyRing(_ state: HaloRingState) {
        pendingRing = state
        ringRig.apply(state)
    }

    /// Plumbed from `HaloRootView`'s Reduce-Motion environment value: pauses the
    /// discovering sweep and recording breath (information is carried by the
    /// static glow / status-bar timer instead).
    func setReduceMotion(_ on: Bool) {
        reduceMotion = on
        ringRig.setReduceMotion(on)
        keyAnimator.setReduceMotion(on)
    }

    /// Called once per render frame from the RealityView update subscription.
    /// The ring rig and the pad-LED decay both early-out at near-zero cost when
    /// nothing is animating.
    func frameTick(deltaTime: Float) {
        ringRig.tick(deltaTime: deltaTime)
        keyAnimator.tick(deltaTime: deltaTime)
    }

    // MARK: - Live polyphonic pad travel (raw Note On/Off, Brief §6 / DD-012)

    /// Raw observed Note On from `HaloAppModel`. Refcounts the physical pad so
    /// simultaneous holds each depress it, and a duplicate strike re-flashes the
    /// LED without further travel. Travel/display can never disagree: both map
    /// notes through `EP40MIDIMapping.gridIndex` → `EP40Entity.padGridOrder`.
    func padNoteOn(channel: UInt8, note: UInt8, velocity: UInt8) {
        guard let (pad, t) = padHolds.noteOn(channel: channel, note: note,
                                             velocity01: Float(velocity) / 127),
              let e = resolved[EP40Entity.padGridOrder[pad]] else { return }
        switch t {
        case let .press(v):    keyAnimator.press(e, velocity: v)
        case let .restrike(v): keyAnimator.restrike(e, velocity: v)
        default: break
        }
    }

    /// Raw observed Note Off. The pad releases (travel up + LED decay) only when
    /// its LAST hold ends; a `.sustain` (other holds remain) moves nothing.
    func padNoteOff(channel: UInt8, note: UInt8) {
        guard let (pad, t) = padHolds.noteOff(channel: channel, note: note),
              t == .release,
              let e = resolved[EP40Entity.padGridOrder[pad]] else { return }
        keyAnimator.release(e)
    }

    /// Disconnect / MIDI reset: no observation may survive a connection change —
    /// every pad releases and every LED zeroes.
    func releaseAllPads() {
        _ = padHolds.releaseAll()
        keyAnimator.releaseAll()
    }

    func entity(_ e: EP40Entity) -> Entity? { resolved[e] }

    /// Safe before or after the USDZ finishes loading. The latest state wins.
    func applyDisplay(_ state: EP40DisplayState) {
        pendingDisplay = state
        displayRenderer?.submit(state)
        updateControls(for: state)
    }

    /// Drive every model control from the honest projection of the display state:
    /// pad TRAVEL (observed depression), and rims for the inferred mode button,
    /// active group, and observed transport. `.waiting` projects to rest/unlit.
    /// Travel = observed depression; rim = latched/inferred (Brief §4, DD-010).
    private func updateControls(for state: EP40DisplayState) {
        let next = EP40ControlProjection.project(state)
        guard next != controls else { return }
        // Preview-only travel; live travel is owned by raw notes (padNoteOn/Off).
        // Feed the frame's velocity so the demo shows the LED language too.
        diffPress(old: controls.previewPressedPad, new: next.previewPressedPad,
                  velocity: state.velocity)
        diffLit(old: controls.selectedModeButton, new: next.selectedModeButton)
        diffLit(old: controls.activeGroupPad, new: next.activeGroupPad)
        if next.playEngaged != controls.playEngaged, let play = resolved[.buttonPlay] {
            keyAnimator.setLit(play, next.playEngaged)
        }
        controls = next
    }

    /// PREVIEW demo only: one pad travels at the frame's velocity, the previous one
    /// releases. LIVE polyphonic travel is driven by raw Note On/Off through
    /// `padNoteOn`/`padNoteOff`, never here.
    private func diffPress(old: EP40Entity?, new: EP40Entity?, velocity: Float) {
        guard old != new else { return }
        if let old, let e = resolved[old] { keyAnimator.release(e) }
        if let new, let e = resolved[new] { keyAnimator.press(e, velocity: velocity) }
    }

    /// Move the rim from the old control to the new one.
    private func diffLit(old: EP40Entity?, new: EP40Entity?) {
        guard old != new else { return }
        if let old, let e = resolved[old] { keyAnimator.setLit(e, false) }
        if let new, let e = resolved[new] { keyAnimator.setLit(e, true) }
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
