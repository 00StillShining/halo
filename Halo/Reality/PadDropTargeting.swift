import RealityKit
import SwiftUI
import simd

/// File-drop targeting on the numeric pads (Brief §4/§7: "Dragging a file to a pad
/// should feel like physically loading the instrument"). Trigger colliders let a
/// Finder drop hit-test the model; a hairline reticle highlights the hovered pad.
///
/// Honesty (DD-014): the reticle is a dedicated Halo-owned entity, NOT
/// `keyAnimator.setLit` — that channel means observed/inferred hardware state
/// (DD-010). This is presentation of a drop *target*, no hardware claim.
extension CollisionGroup {
    static var haloDropTargets: CollisionGroup { CollisionGroup(rawValue: 1 << 3) }
}

/// A world-space pick ray. Pure value so the unprojection is unit-testable without
/// a live RealityKit scene.
struct DropRay: Equatable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
}

extension EP40SceneController {

    // MARK: - Collider installation

    /// Install trigger colliders on the numeric pads, in a dedicated collision
    /// group, from each pad's visual bounds. Called inside `makeScene()`'s
    /// generation-guarded block (USDZ + procedural fallback both resolve shapes
    /// from bounds). Trigger mode only — never physics.
    func installDropTargets(resolved: [EP40Entity: Entity]) {
        dropTargets.removeAll(keepingCapacity: true)
        hideDropReticle()
        for pad in EP40Entity.numericPadsInNoteOrder {
            guard let e = resolved[pad] else { continue }
            let b = e.visualBounds(relativeTo: e)
            let extents = simd_max(b.extents, SIMD3<Float>(repeating: 0.002))
            let shape = ShapeResource
                .generateBox(size: extents)
                .offsetBy(translation: b.center)
            e.components.set(CollisionComponent(
                shapes: [shape],
                mode: .trigger,
                filter: CollisionFilter(group: .haloDropTargets, mask: [])))
            dropTargets[e.id] = pad
        }
    }

    // MARK: - Ray unprojection (pure)

    /// Build a world-space pick ray from a view-space point. Uses the settled
    /// target framing (`framing(for: pendingMode)`), not the animating camera:
    /// a drop mid-camera-glide (0.45 s) resolves against where the camera is
    /// *going*, matching where the reticle will land — an accepted edge (DD-014).
    /// The camera's vertical FOV is 24° (`makeHeroCamera`).
    nonisolated static func dropRay(at p: CGPoint, viewSize s: CGSize,
                                    framing f: ModeFraming) -> DropRay {
        let cam = heroTransform(f)
        let tanHalf = tan(24 * Float.pi / 360)              // half of the 24° vertical FOV
        let aspect = s.height > 0 ? Float(s.width / s.height) : 1
        let u = Float(p.x / max(s.width, 1)) * 2 - 1
        let v = 1 - Float(p.y / max(s.height, 1)) * 2
        let dirCam = SIMD3<Float>(u * tanHalf * aspect, v * tanHalf, -1)
        return DropRay(origin: cam.translation,
                       direction: simd_normalize(cam.rotation.act(dirCam)))
    }

    /// Resolve the numeric pad under a view-space point, or nil.
    func numericPad(at point: CGPoint, viewSize: CGSize) -> EP40Entity? {
        guard viewSize.width > 0, viewSize.height > 0,
              let scene = modelRoot?.scene else { return nil }
        let ray = Self.dropRay(at: point, viewSize: viewSize,
                               framing: Self.framing(for: pendingMode))
        return scene.raycast(origin: ray.origin, direction: ray.direction,
                             length: 5, query: .nearest,
                             mask: .haloDropTargets, relativeTo: nil)
            .first.flatMap { dropTargets[$0.entity.id] }
    }

    // MARK: - Drop reticle (drag-hover highlight)

    /// Move/build the hover reticle over the pad under the point. Early-outs when
    /// the resolved pad hasn't changed; clears it when the point is off any pad.
    func updateDropReticle(at point: CGPoint, viewSize: CGSize) {
        let pad = numericPad(at: point, viewSize: viewSize)
        guard pad != reticlePad else { return }
        reticlePad = pad
        dropReticle?.removeFromParent()
        dropReticle = nil
        guard let pad, let e = resolved[pad], let root = modelRoot else { return }

        let b = e.visualBounds(relativeTo: root)
        let margin = HaloMechanics.padLEDSkirtMargin
        let width = b.extents.x + margin * 2
        let depth = b.extents.z + margin * 2
        let reticle = Self.makeReticleFrame(width: width, depth: depth,
                                            colorHex: palette.orangeHex)
        reticle.position = SIMD3<Float>(
            b.center.x,
            b.center.y + b.extents.y / 2 + HaloMechanics.padLEDSkirtLift,
            b.center.z)
        root.addChild(reticle)
        dropReticle = reticle
    }

    /// Clear the reticle on drop / exit / disconnect.
    func hideDropReticle() {
        dropReticle?.removeFromParent()
        dropReticle = nil
        reticlePad = nil
    }

    /// Recolour a live reticle when the owner flips the palette (parity with the
    /// focus rims). Cheap — the reticle is at most four thin boxes.
    func recolorDropReticle() {
        guard let reticle = dropReticle else { return }
        let material = UnlitMaterial(color: .rk(palette.orangeHex))
        for bar in reticle.children {
            bar.components[ModelComponent.self]?.materials = [material]
        }
    }

    /// A square hairline frame in the XZ plane (four thin unlit bars). Parent
    /// opacity 0.85 so it reads as a restrained target, not a lit LED.
    private static func makeReticleFrame(
        width: Float, depth: Float, colorHex: UInt32
    ) -> Entity {
        let frame = Entity()
        frame.name = "halo_drop_reticle"
        let thickness: Float = 0.0003                       // ~0.3 mm
        let material = UnlitMaterial(color: .rk(colorHex))

        func bar(size: SIMD3<Float>, at pos: SIMD3<Float>) -> Entity {
            let mesh = MeshResource.generateBox(size: simd_max(size, SIMD3<Float>(repeating: thickness)))
            let e = ModelEntity(mesh: mesh, materials: [material])
            e.position = pos
            return e
        }
        frame.addChild(bar(size: [width, thickness, thickness], at: [0, 0, -depth / 2]))
        frame.addChild(bar(size: [width, thickness, thickness], at: [0, 0, depth / 2]))
        frame.addChild(bar(size: [thickness, thickness, depth], at: [-width / 2, 0, 0]))
        frame.addChild(bar(size: [thickness, thickness, depth], at: [width / 2, 0, 0]))
        frame.components.set(OpacityComponent(opacity: 0.85))
        return frame
    }
}
