import Foundation
import RealityKit
import os

/// Loads the EP-40 model. Primary path: a Blender-authored USDZ bundled as
/// `EP40.usdz` (Brief §6). Fallback: the procedural placeholder. Either way the
/// entity-name contract is validated and misses are logged to Diagnostics.
enum EP40ModelLoader {

    struct Result {
        let root: Entity
        let isPlaceholder: Bool
        let resolved: [EP40Entity: Entity]
        let missing: [EP40Entity]
    }

    private static let log = Logger(subsystem: "studios.meremortal.halo", category: "model")

    /// USDZ resource name (without extension). Not present until the owner delivers it.
    static let usdzName = "EP40"

    @MainActor
    static func load() async -> Result {
        if let usdz = await tryLoadUSDZ() {
            let (map, missing) = EP40Entity.resolve(in: usdz)
            if missing.isEmpty {
                log.info("Loaded USDZ '\(usdzName).usdz'; entity contract fully resolved.")
            } else {
                log.fault("USDZ '\(usdzName).usdz' missing \(missing.count) required prims: \(missing.map(\.rawValue).joined(separator: ", "))")
            }
            return Result(root: usdz, isPlaceholder: false, resolved: map, missing: missing)
        }

        // Fallback — procedural placeholder.
        let placeholder = EP40ProceduralFallback.build()
        let (map, missing) = EP40Entity.resolve(in: placeholder)
        if missing.isEmpty {
            log.info("PLACEHOLDER MODEL in use (no USDZ found); contract fully resolved.")
        } else {
            // A bug in the procedural builder — every contract name should be present.
            log.error("PLACEHOLDER MODEL missing \(missing.count) prims: \(missing.map(\.rawValue).joined(separator: ", "))")
            assertionFailure("Procedural fallback violated the entity contract: \(missing.map(\.rawValue))")
        }
        return Result(root: placeholder, isPlaceholder: true, resolved: map, missing: missing)
    }

    @MainActor
    private static func tryLoadUSDZ() async -> Entity? {
        guard Bundle.main.url(forResource: usdzName, withExtension: "usdz") != nil else {
            return nil   // not delivered yet — expected during Phase 1
        }
        do {
            let entity = try await Entity(named: usdzName, in: .main)
            entity.name = EP40Entity.root.rawValue   // normalise root name to the contract
            return entity
        } catch {
            log.error("Failed to load '\(usdzName).usdz': \(error.localizedDescription). Falling back to placeholder.")
            return nil
        }
    }
}
