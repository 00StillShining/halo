import RealityKit
import SwiftUI
import simd

/// Owns the RealityKit scene: the EP-40 model, lighting rig, and hero camera.
/// Holds resolved entity references so views never search the entity tree per
/// event (Brief §8). Interactive logic (press travel, etc.) will hang off this.
@MainActor
@Observable
final class EP40SceneController {

    /// Honest scene-load phase (P4-states, DD-025/DD-026). Distinct from
    /// `isPlaceholder`, which conflates "still loading" with "fell back to
    /// procedural" (both `true`). The stage LOADING plate keys off `.loading` ONLY,
    /// so it disappears the instant the USDZ resolves OR the procedural fallback
    /// lands — never a lingering spinner. The `PLACEHOLDER MODEL` status chip keeps
    /// keying off `isPlaceholder`, unchanged.
    enum LoadPhase: Equatable {
        case loading, loaded, fallback

        /// Pure terminal-phase derivation from the loader's placeholder result, so it
        /// is unit-tested (`SceneLoadPhaseTests`) without loading a RealityKit scene.
        static func terminal(isPlaceholder: Bool) -> LoadPhase {
            isPlaceholder ? .fallback : .loaded
        }
    }
    private(set) var loadPhase: LoadPhase = .loading

    private(set) var isPlaceholder = true
    private(set) var missing: [EP40Entity] = []
    private(set) var resolved: [EP40Entity: Entity] = [:]
    private(set) var modelRoot: Entity?
    private var displayRenderer: EP40DisplayRenderer?
    private var pendingDisplay = EP40DisplayState.previewStill
    private var pendingRing = HaloRingState.disconnected
    private var sceneGeneration = 0
    private let keyAnimator = KeyTravelAnimator()
    private let ringRig = HaloRingRig()

    /// The ring rig's audio-level bridge, exposed so the monitor route's output
    /// callback publishes its post-limiter peak into the SAME instance the
    /// `.monitoring` glow tick reads (P2-route). Audio-callback data never touches
    /// RealityKit directly — only this atomic seam.
    var audioLevelBridge: AudioLevelBridge { ringRig.audioLevel }
    private var controls = EP40ControlProjection.rest
    private(set) var palette: HaloPalette = .graphPaper
    private var reduceMotion = false

    // MARK: - File-drop targeting (P1-play-load, PadDropTargeting.swift)
    /// Reverse map Entity.ID → contract pad name for a raycast hit; and the
    /// dedicated hover reticle (halo presentation — a drop *target*, never a
    /// hardware `setLit` claim, DD-010/DD-014).
    var dropTargets: [Entity.ID: EP40Entity] = [:]
    var dropReticle: Entity?
    var reticlePad: EP40Entity?
    /// The hero camera, resolved once the scene is built. `pendingMode` lets a
    /// mode selected before the USDZ finishes loading apply its framing on load
    /// (same late-load pattern as `pendingDisplay` / `pendingRing`).
    private var cameraEntity: Entity?
    private(set) var pendingMode: HaloMode = .play
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
        loadPhase = .loading
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

        let cam = Self.makeHeroCamera()
        world.addChild(result.root)
        world.addChild(Self.makeLightingRig())
        world.addChild(cam)

        // A cancelled/replaced RealityView may finish loading after its successor.
        // Only the latest generation is allowed to become the update target.
        if generation == sceneGeneration, !Task.isCancelled {
            isPlaceholder = result.isPlaceholder
            // Honest, distinct terminal phase: the USDZ resolved, or we fell back to
            // the procedural model. Either way the LOADING window has closed.
            loadPhase = .terminal(isPlaceholder: result.isPlaceholder)
            resolved = result.resolved
            missing = result.missing
            modelRoot = result.root
            displayRenderer = renderer
            // Apply any mode framing chosen before the USDZ finished loading.
            cameraEntity = cam
            cam.transform = Self.heroTransform(Self.framing(for: pendingMode))
            // Bind ALL pressables now (was pads only) so mode buttons, group pads
            // and transport can travel/light. Reverse map lets a hit or lookup
            // resolve back to its contract entity without searching the tree.
            let pressables = EP40Entity.pressable
            keyAnimator.bind(pressables.compactMap { result.resolved[$0] })
            keyAnimator.setAccent(rim: .rk(palette.rimAccentHex), led: .rk(palette.orangeHotHex))
            keyAnimator.setReduceMotion(reduceMotion)
            controls = .rest
            padHolds = PadHoldRegistry()
            // Trigger colliders on the numeric pads so Finder file drops can
            // hit-test against the model (works for USDZ + procedural fallback).
            installDropTargets(resolved: result.resolved)
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
        recolorDropReticle()
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
        hideDropReticle()
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

    nonisolated static func heroPosition(radius r: Float, yawDeg: Float, pitchDeg: Float) -> SIMD3<Float> {
        let yaw = yawDeg * .pi / 180
        let pitch = pitchDeg * .pi / 180
        return [
            r * cos(pitch) * sin(yaw),
            r * sin(pitch),
            r * cos(pitch) * cos(yaw),
        ]
    }

    // MARK: - Mode framing (Brief §7). A mode change re-frames the hero model with
    // a subtle camera move — never a scene replacement. All framings sit within a
    // few degrees of the hero view; `.play` equals the original hero values so the
    // default view is pixel-identical.

    struct ModeFraming: Equatable, Sendable {
        var radius: Float
        var yawDeg: Float
        var pitchDeg: Float
    }

    nonisolated static func framing(for mode: HaloMode) -> ModeFraming {
        switch mode {
        case .play:    ModeFraming(radius: 0.70, yawDeg: 28, pitchDeg: 42)  // current hero — unchanged
        case .load:    ModeFraming(radius: 0.72, yawDeg: 22, pitchDeg: 48)  // slightly top-down: pads read as drop targets
        case .edit:    ModeFraming(radius: 0.66, yawDeg: 34, pitchDeg: 38)  // a touch closer / sider
        case .capture: ModeFraming(radius: 0.74, yawDeg: 28, pitchDeg: 40)  // pulled back, calm
        case .rack:    ModeFraming(radius: 0.72, yawDeg: 30, pitchDeg: 41)  // placeholder until 5a
        case .backups: ModeFraming(radius: 0.76, yawDeg: 24, pitchDeg: 44)  // furthest, archival distance
        }
    }

    /// The look-at transform for a framing. A full `Transform` is needed because
    /// `move(to:)` won't re-`look(at:)` mid-animation; camera forward is −Z, so
    /// the +Z column points from the origin toward the camera.
    nonisolated static func heroTransform(_ f: ModeFraming) -> Transform {
        let p = heroPosition(radius: f.radius, yawDeg: f.yawDeg, pitchDeg: f.pitchDeg)
        let back  = simd_normalize(p)                                   // local +Z in world
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up    = simd_cross(back, right)
        return Transform(scale: .one,
                         rotation: simd_quatf(simd_float3x3(right, up, back)),
                         translation: p)
    }

    /// Look-at transform from an arbitrary eye to an arbitrary target (the
    /// `heroTransform` above is the `target == .zero` special case). Camera forward
    /// is −Z, so the +Z basis column points from the target back toward the eye.
    nonisolated static func lookAtTransform(from eye: SIMD3<Float>, to target: SIMD3<Float>) -> Transform {
        let back  = simd_normalize(eye - target)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up    = simd_cross(back, right)
        return Transform(scale: .one,
                         rotation: simd_quatf(simd_float3x3(right, up, back)),
                         translation: eye)
    }

    /// Ease the hero camera toward a numeric pad while keeping the whole device framed
    /// (Brief §7 "without losing whole-device context", DD-013 presentation — never a
    /// hardware claim, never releases pads / touches display / ring). Gentle by design:
    /// bias the look-at ~40% toward the pad, pull the radius in ~6%, and slide the eye a
    /// little to the pad's side. Safe before the USDZ loads (records `pendingMode`).
    func focusCamera(onPadGridIndex gridIndex: Int) {
        pendingMode = .edit
        guard EP40Entity.padGridOrder.indices.contains(gridIndex),
              let e = resolved[EP40Entity.padGridOrder[gridIndex]],
              let cam = cameraEntity else { return }
        let pad = e.position(relativeTo: nil)                       // world space
        let target = simd_mix(SIMD3<Float>.zero, pad, SIMD3<Float>(repeating: 0.40))
        let base = Self.framing(for: .edit)
        let eye = Self.heroPosition(radius: base.radius * 0.94, yawDeg: base.yawDeg, pitchDeg: base.pitchDeg)
                + SIMD3<Float>(pad.x, 0, pad.z) * 0.25
        let t = Self.lookAtTransform(from: eye, to: target)
        if reduceMotion {
            cam.transform = t
        } else {
            cam.move(to: t, relativeTo: nil,
                     duration: HaloMechanics.modeChangeDuration, timingFunction: .easeInOut)
        }
    }

    /// Re-frame the hero model for a mode. Safe before or after the USDZ loads —
    /// `pendingMode` is applied on load. This is halo presentation, not a hardware
    /// claim: it never releases pads or touches display / ring state (DD-013).
    func focusCamera(for mode: HaloMode) {
        pendingMode = mode
        guard let cam = cameraEntity else { return }
        let target = Self.heroTransform(Self.framing(for: mode))
        if reduceMotion {
            cam.transform = target                                     // jump-cut under Reduce Motion
        } else {
            cam.move(to: target, relativeTo: nil,
                     duration: HaloMechanics.modeChangeDuration, timingFunction: .easeInOut)
        }
    }
}
