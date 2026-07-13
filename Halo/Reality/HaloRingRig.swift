import RealityKit
import AppKit
import Foundation
import simd

/// The Halo-owned 48-segment glow rig for the `halo_ring` (Brief §5 ring states).
/// Same philosophy as `KeyTravelAnimator.makeRim`: child geometry derived from
/// `visualBounds`, working identically for the Blender USDZ (a thin elliptical
/// ink annulus) and the procedural fallback (a solid disc). It NEVER mutates
/// USDZ materials — luminance runs entirely through `OpacityComponent`, which
/// composes multiplicatively down the hierarchy:
///   • the parent `halo_ring_glow`'s opacity is the master luminance (one write
///     for uniform states);
///   • each segment child's opacity is the pattern (only written by the
///     discovering sweep and the transfer progress ring).
///
/// State is driven by connection/monitor/record TRUTH via `apply(_:)` — never by
/// `EP40DisplayState` preview/demo frames (Brief §1/§4). Static states cost one
/// bool check per frame (`needsTick == false`), satisfying the near-zero idle
/// rendering budget.
@MainActor
final class HaloRingRig {

    /// Future audio-monitor producer writes peaks here; the tick reads it on the
    /// main actor at ≤ 60 Hz. Audio-callback data NEVER reaches RealityKit directly.
    let audioLevel = AudioLevelBridge()

    private enum RingColor { case orange, orangeHot, warning }

    private var palette: HaloPalette = .graphPaper
    private var reduceMotion = false

    private var glowParent: Entity?
    private var segments: [ModelEntity] = []
    private var childrenPatterned = false        // children hold a non-uniform pattern

    private var matOrange = UnlitMaterial(color: .white)
    private var matOrangeHot = UnlitMaterial(color: .white)
    private var matWarning = UnlitMaterial(color: .white)
    private var assignedColor: RingColor?

    private(set) var currentState: HaloRingState = .disconnected

    // Animation clocks
    private var phaseClock: Float = 0            // discovering sweep / recording breath
    private var errorClock: Float = 0            // error pulse
    private var errorSettled = false
    private var smoother = RingLuminanceSmoother()
    private var luminanceAccumulator: Float = 0  // 60 Hz coalescing

    // MARK: - Build

    /// Build (or rebuild) the rig as a child of `ring`. Call once at scene bind.
    func bind(ring: Entity, palette: HaloPalette) {
        self.palette = palette
        rebuildMaterials()
        assignedColor = nil

        glowParent?.removeFromParent()
        segments.removeAll(keepingCapacity: true)
        childrenPatterned = false

        let bounds = ring.visualBounds(relativeTo: ring)
        let a = bounds.extents.x / 2
        let b = bounds.extents.z / 2
        let topY = bounds.max.y

        let parent = Entity()
        parent.name = "halo_ring_glow"
        // Sit on top of the ink band, lifted so the glow never z-fights it.
        parent.position = [bounds.center.x, topY + 0.0004, bounds.center.z]

        let seg = HaloRingMechanics.segmentCount
        let am = a - 0.00115                     // midline of the ~2.3 mm band
        let bm = b - 0.00115
        let meanR = (am + bm) / 2
        let chord = (2 * Float.pi * meanR) / Float(seg)

        for k in 0..<seg {
            let theta = 2 * Float.pi * Float(k) / Float(seg)   // θ=0 at screen-top, CW
            let p = SIMD3<Float>(am * sin(theta), 0, -bm * cos(theta))
            let yaw = atan2(-bm * sin(theta), am * cos(theta)) // box +X along tangent
            let box = ModelEntity(
                mesh: .generateBox(width: chord * 0.82, height: 0.0005, depth: 0.0020),
                materials: [matOrange]
            )
            box.name = "halo_ring_seg_\(k)"
            box.position = p
            box.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            box.components.set(OpacityComponent(opacity: 1))
            parent.addChild(box)
            segments.append(box)
        }

        ring.addChild(parent)
        glowParent = parent

        // Establish the baseline for whatever state we are already in.
        install(currentState, force: true)
    }

    // MARK: - Public surface

    func setPalette(_ palette: HaloPalette) {
        guard palette != self.palette else { return }
        self.palette = palette
        rebuildMaterials()
        let key = assignedColor ?? color(for: currentState)
        assignedColor = nil
        assignMaterial(key)
    }

    func setReduceMotion(_ on: Bool) {
        guard on != reduceMotion else { return }
        reduceMotion = on
        luminanceAccumulator = HaloRingMechanics.luminanceInterval
        renderFrame(cappedDt: 0)
    }

    /// Apply a state transition. Resets phase/pulse clocks only on a real change,
    /// so the recording breath and the error pulse aren't restarted by a repeat.
    func apply(_ state: HaloRingState) { install(state, force: false) }

    /// False for static states (disconnected, connected, transfer, settled error)
    /// and for Reduce-Motion discovering/recording — the tick early-outs on this.
    var needsTick: Bool {
        switch currentState {
        case .discovering: return !reduceMotion
        case .monitoring:  return true
        case .recording:   return !reduceMotion
        case .error:       return !errorSettled
        case .disconnected, .connected, .transfer: return false
        }
    }

    /// Advance animation. Luminance writes are coalesced to ≤ 60 Hz even on
    /// ProMotion displays. Only ever writes `OpacityComponent` structs — no mesh
    /// or material allocation, no audio-thread data path.
    func tick(deltaTime dt: Float) {
        guard needsTick else { return }
        phaseClock += dt
        // Keep the periodic clock bounded: discovering can run indefinitely
        // without a device, and an ever-growing Float would eventually lose
        // dt-sized increments. Wrapping by the active period is exact.
        switch currentState {
        case .discovering:
            phaseClock = phaseClock.truncatingRemainder(dividingBy: HaloRingMechanics.discoverPeriod)
        case .recording:
            phaseClock = phaseClock.truncatingRemainder(dividingBy: HaloRingMechanics.recordPeriod)
        default:
            break
        }
        errorClock += dt
        luminanceAccumulator += dt
        guard luminanceAccumulator >= HaloRingMechanics.luminanceInterval else { return }
        let cappedDt = luminanceAccumulator
        luminanceAccumulator = 0
        renderFrame(cappedDt: cappedDt)
    }

    // MARK: - State install

    private func install(_ state: HaloRingState, force: Bool) {
        guard force || state != currentState else { return }
        currentState = state
        assignMaterial(color(for: state))
        phaseClock = 0
        luminanceAccumulator = HaloRingMechanics.luminanceInterval  // force first write
        switch state {
        case .error:      errorClock = 0; errorSettled = false
        case .monitoring: smoother.reset()
        default:          break
        }
        renderFrame(cappedDt: 0)
    }

    // MARK: - Rendering (OpacityComponent only)

    private func renderFrame(cappedDt: Float) {
        switch currentState {
        case .disconnected:
            setUniformChildren()
            setParentOpacity(0)

        case .connected:
            setUniformChildren()
            setParentOpacity(HaloRingMechanics.connectedOpacity)

        case .discovering:
            if reduceMotion {
                setUniformChildren()
                setParentOpacity(HaloRingMechanics.discoverReduceMotionOpacity)
            } else {
                renderDiscoverSweep()
                setParentOpacity(HaloRingMechanics.discoverParentOpacity)
            }

        case .monitoring:
            setUniformChildren()
            let target = audioLevel.read()
            let s = smoother.step(target: target, dt: cappedDt)
            let lum = min(HaloRingMechanics.monitorBase + HaloRingMechanics.monitorScale * s,
                          HaloRingMechanics.monitorCap)
            setParentOpacity(lum)

        case .recording:
            setUniformChildren()
            if reduceMotion {
                setParentOpacity(HaloRingMechanics.recordReduceMotionOpacity)
            } else {
                let phase = sin(2 * Float.pi * phaseClock / HaloRingMechanics.recordPeriod)
                setParentOpacity(HaloRingMechanics.recordBase
                                 + HaloRingMechanics.recordAmplitude * (1 + phase))
            }

        case let .transfer(progress):
            renderTransfer(Float(progress))
            setParentOpacity(HaloRingMechanics.transferParentOpacity)

        case .error:
            setUniformChildren()
            setParentOpacity(errorOpacityNow())
        }
    }

    private func renderDiscoverSweep() {
        let n = HaloRingMechanics.segmentCount
        var arr = [Float](repeating: 0, count: n)
        let headFloat = (phaseClock / HaloRingMechanics.discoverPeriod) * Float(n)
        let headSeg = ((Int(floor(headFloat)) % n) + n) % n
        for (k, op) in HaloRingMechanics.discoverFalloff.enumerated() {
            let idx = ((headSeg - k) % n + n) % n
            arr[idx] = op
        }
        setChildOpacities(arr)
    }

    private func renderTransfer(_ progress: Float) {
        let n = HaloRingMechanics.segmentCount
        let filled = min(max(progress, 0), 1) * Float(n)
        let full = Int(floor(filled))
        let frac = filled - Float(full)
        var arr = [Float](repeating: HaloRingMechanics.transferTrackOpacity, count: n)
        for i in 0..<n {
            if i < full {
                arr[i] = 1.0
            } else if i == full, full < n {
                arr[i] = max(frac, HaloRingMechanics.transferTrackOpacity)
            }
        }
        setChildOpacities(arr)
    }

    /// Single amber-red pulse on entry, then a stable labelled hold forever.
    private func errorOpacityNow() -> Float {
        if reduceMotion {
            errorSettled = true
            return HaloRingMechanics.errorHoldOpacity
        }
        let rise = HaloRingMechanics.errorRise
        let decay = HaloRingMechanics.errorDecay
        let hold = HaloRingMechanics.errorHoldOpacity
        let peak = HaloRingMechanics.errorPeakOpacity
        if errorClock < rise {
            let t = errorClock / rise
            let eased = 1 - (1 - t) * (1 - t)            // easeOut
            return hold + (peak - hold) * eased
        }
        let d = errorClock - rise
        if d < decay {
            return peak + (hold - peak) * (d / decay)     // linear decay to hold
        }
        errorSettled = true
        return hold
    }

    // MARK: - OpacityComponent helpers

    private func setParentOpacity(_ v: Float) {
        glowParent?.components.set(OpacityComponent(opacity: v))
    }

    /// Reset every segment to full opacity (the master parent carries luminance).
    /// Only writes when the children currently hold a pattern.
    private func setUniformChildren() {
        guard childrenPatterned else { return }
        for s in segments { s.components.set(OpacityComponent(opacity: 1)) }
        childrenPatterned = false
    }

    private func setChildOpacities(_ arr: [Float]) {
        guard arr.count == segments.count else { return }
        for (i, s) in segments.enumerated() {
            s.components.set(OpacityComponent(opacity: arr[i]))
        }
        childrenPatterned = true
    }

    // MARK: - Materials

    private func rebuildMaterials() {
        matOrange = UnlitMaterial(color: .rk(palette.orangeHex))
        matOrangeHot = UnlitMaterial(color: .rk(palette.orangeHotHex))
        matWarning = UnlitMaterial(color: .rk(palette.warningHex))
    }

    private func material(for key: RingColor) -> UnlitMaterial {
        switch key {
        case .orange:    return matOrange
        case .orangeHot: return matOrangeHot
        case .warning:   return matWarning
        }
    }

    private func assignMaterial(_ key: RingColor) {
        guard key != assignedColor else { return }
        assignedColor = key
        let mat = material(for: key)
        for s in segments { s.model?.materials = [mat] }
    }

    private func color(for state: HaloRingState) -> RingColor {
        switch state {
        case .recording: return .orangeHot
        case .error:     return .warning
        default:         return .orange
        }
    }
}
