import RealityKit
import AppKit

/// Placeholder EP-40 built from RealityKit primitives, honouring the entity-name
/// contract so all interactive logic works identically once the Blender USDZ lands
/// (Brief §6). **This is NOT the final model** — proportions are provisional (see
/// DD-006). It is labelled `PLACEHOLDER MODEL` in diagnostics.
///
/// Units are meters. The chassis is 240 × 176 × 16 mm laid flat: X = width,
/// Z = depth (−Z far / +Z near), Y = thickness (up). Controls sit on the top plate.
enum EP40ProceduralFallback {

    // Chassis dimensions (meters).
    static let width: Float  = 0.240
    static let depth: Float  = 0.176
    static let thickness: Float = 0.016
    static let topY: Float   = thickness / 2      // top plate surface

    /// Build the placeholder device. Root entity is named `ep40_root`.
    @MainActor
    static func build() -> Entity {
        let root = Entity()
        root.name = EP40Entity.root.rawValue

        buildChassis(into: root)
        buildDisplayAndMic(into: root)
        buildKnobsAndFader(into: root)
        buildButtons(into: root)
        buildPads(into: root)
        buildGroupPads(into: root)
        buildPorts(into: root)
        buildSpeaker(into: root)
        buildHaloRing(into: root)

        return root
    }

    // MARK: - Face coordinate helper
    // Normalised face coords: u 0→1 left→right, v 0→1 far→near. Returns world (x,z).
    private static func face(_ u: Float, _ v: Float) -> (x: Float, z: Float) {
        (x: (u - 0.5) * width, z: (v - 0.5) * depth)
    }

    // MARK: - Materials (fixed hardware tones — independent of the UI palette)
    private static func matte(_ hex: UInt32, rough: Float = 0.7, metal: Float = 0.0) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .rk(hex))
        m.roughness = .init(floatLiteral: rough)
        m.metallic  = .init(floatLiteral: metal)
        return m
    }
    private static func emissive(_ hex: UInt32, intensity: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .rk(hex))
        m.roughness = .init(floatLiteral: 0.4)
        m.emissiveColor = .init(color: .rk(hex))
        m.emissiveIntensity = intensity
        return m
    }

    // Hardware tones — EP-40 Riddim colourway from TE reference imagery:
    // warm cream body, off-white caps, riddim-green accents, orange highlights.
    private static let bodyHex: UInt32     = 0xE6E1D2   // warm cream body
    private static let plateHex: UInt32    = 0xECE8DA   // slightly lighter plate
    private static let edgeHex: UInt32     = 0xB9B7AF   // metal edge band / rim
    private static let capHex: UInt32      = 0xDAD5C6   // warm off-white keycaps
    private static let capDarkHex: UInt32  = 0x9AA0A0
    private static let displayHex: UInt32  = 0x11201A   // dark green-black readout
    private static let orangeHex: UInt32   = 0xF4551F   // international-orange accent
    private static let greenHex: UInt32    = 0x2F4E3E   // riddim green

    // MARK: - Primitive helpers
    @MainActor
    private static func box(_ name: String, w: Float, h: Float, d: Float,
                            radius: Float, at pos: SIMD3<Float>,
                            _ mat: PhysicallyBasedMaterial) -> ModelEntity {
        let mesh = MeshResource.generateBox(width: w, height: h, depth: d, cornerRadius: radius)
        let e = ModelEntity(mesh: mesh, materials: [mat])
        e.name = name
        e.position = pos
        return e
    }
    @MainActor
    private static func cyl(_ name: String, h: Float, r: Float,
                            at pos: SIMD3<Float>, _ mat: PhysicallyBasedMaterial) -> ModelEntity {
        let e = ModelEntity(mesh: .generateCylinder(height: h, radius: r), materials: [mat])
        e.name = name
        e.position = pos
        return e
    }

    // MARK: - Chassis
    @MainActor
    private static func buildChassis(into root: Entity) {
        // Base body.
        let base = box(EP40Entity.chassisBase.rawValue, w: width, h: thickness, d: depth,
                       radius: 0.004, at: [0, 0, 0], matte(bodyHex, rough: 0.75))
        root.addChild(base)

        // Top plate — a thin inset sheet slightly proud, giving the layered look.
        let plate = box(EP40Entity.chassisTopPlate.rawValue,
                        w: width - 0.010, h: 0.0016, d: depth - 0.010, radius: 0.003,
                        at: [0, topY + 0.0008, 0], matte(plateHex, rough: 0.6))
        root.addChild(plate)

        // Edge band — a thin metal rim around the base sides (visual only).
        let band = box(EP40Entity.chassisEdgeBand.rawValue,
                       w: width + 0.0006, h: 0.003, d: depth + 0.0006, radius: 0.004,
                       at: [0, -thickness/2 + 0.004, 0], matte(edgeHex, rough: 0.35, metal: 0.6))
        root.addChild(band)
    }

    // MARK: - Display + mic (upper-left)
    @MainActor
    private static func buildDisplayAndMic(into root: Entity) {
        let (dx, dz) = face(0.24, 0.18)
        // Dark recessed readout. halo renders its own state here later (live texture / attachment).
        let display = box(EP40Entity.displaySurface.rawValue,
                          w: 0.085, h: 0.0018, d: 0.038, radius: 0.002,
                          at: [dx, topY + 0.0012, dz], emissive(displayHex, intensity: 40))
        root.addChild(display)

        let (mx, mz) = face(0.055, 0.075)
        let mic = cyl(EP40Entity.micPort.rawValue, h: 0.0012, r: 0.0022,
                      at: [mx, topY + 0.0010, mz], matte(0x2A2C2E, rough: 0.5))
        root.addChild(mic)
    }

    // MARK: - Knobs + fader (upper-center)
    @MainActor
    private static func buildKnobsAndFader(into root: Entity) {
        let knobLayout: [(EP40Entity, Float)] = [(.knobVolume, 0.42), (.knobX, 0.52), (.knobY, 0.62)]
        for (ent, u) in knobLayout {
            let (x, z) = face(u, 0.36)
            let knob = cyl(ent.rawValue, h: 0.009, r: 0.0085,
                           at: [x, topY + 0.0045, z], matte(capHex, rough: 0.4))
            // A small cap dot to read rotation.
            let dot = cyl("\(ent.rawValue)_indicator", h: 0.0006, r: 0.0016,
                          at: [0, 0.0048, 0.004], matte(0x1A1B1C, rough: 0.5))
            knob.addChild(dot)
            root.addChild(knob)
        }

        // Fader — a recessed track with a proud cap (left edge).
        let (fx, fz) = face(0.05, 0.40)
        let track = box(EP40Entity.faderTrack.rawValue, w: 0.010, h: 0.0016, d: 0.052, radius: 0.002,
                        at: [fx, topY + 0.0010, fz], matte(0x2A2C2E, rough: 0.5))
        root.addChild(track)
        let cap = box(EP40Entity.faderCap.rawValue, w: 0.016, h: 0.006, d: 0.012, radius: 0.002,
                      at: [fx, topY + 0.0040, fz + 0.010], matte(capHex, rough: 0.45))
        root.addChild(cap)
    }

    // MARK: - Buttons (lower-left rows)
    @MainActor
    private static func buildButtons(into root: Entity) {
        // (entity, u, v, accent)
        let rows: [(EP40Entity, Float, Float, UInt32?)] = [
            // mode row
            (.buttonSound, 0.09, 0.47, nil), (.buttonMain, 0.19, 0.47, nil), (.buttonTempo, 0.29, 0.47, nil),
            // function row
            (.buttonSample, 0.09, 0.59, nil), (.buttonKeys, 0.19, 0.59, nil),
            (.buttonTiming, 0.29, 0.59, nil), (.buttonFx, 0.39, 0.59, nil),
            // transport / edit row
            (.buttonRecord, 0.09, 0.71, orangeHex), (.buttonPlay, 0.19, 0.71, greenHex), (.buttonErase, 0.29, 0.71, nil),
            // modifier row
            (.buttonShift, 0.09, 0.83, nil), (.buttonMinus, 0.19, 0.83, nil), (.buttonPlus, 0.29, 0.83, nil),
        ]
        for (ent, u, v, accent) in rows {
            let (x, z) = face(u, v)
            let mat = accent.map { matte($0, rough: 0.5) } ?? matte(capHex, rough: 0.5)
            let b = box(ent.rawValue, w: 0.0135, h: 0.0042, d: 0.0095, radius: 0.0015,
                        at: [x, topY + 0.0018 + 0.0021, z], mat)   // proud ~1.8mm + half height
            root.addChild(b)
        }
    }

    // MARK: - 12-pad numeric keypad (right) — 3 cols × 4 rows, calculator layout (PROVISIONAL)
    @MainActor
    private static func buildPads(into root: Entity) {
        let uL: Float = 0.61, uR: Float = 0.93
        let vT: Float = 0.44, vB: Float = 0.93
        let cols = 3, rows = 4
        // Physical cell → pad (calculator style; exact mapping needs a photo, DD-006).
        let grid: [[EP40Entity]] = [
            [.pad7, .pad8, .pad9],
            [.pad4, .pad5, .pad6],
            [.pad1, .pad2, .pad3],
            [.padDot, .pad0, .padEnter],
        ]
        let padSize: Float = 0.026
        for r in 0..<rows {
            for c in 0..<cols {
                let u = uL + (uR - uL) * (Float(c) / Float(cols - 1))
                let v = vT + (vB - vT) * (Float(r) / Float(rows - 1))
                let (x, z) = face(u, v)
                let pad = box(grid[r][c].rawValue, w: padSize, h: 0.005, d: padSize, radius: 0.003,
                              at: [x, topY + 0.0018 + 0.0025, z], matte(capHex, rough: 0.45))
                root.addChild(pad)
            }
        }
    }

    // MARK: - 4 group pads (vertical strip left of the keypad)
    @MainActor
    private static func buildGroupPads(into root: Entity) {
        let groups: [EP40Entity] = [.groupA, .groupB, .groupC, .groupD]
        let u: Float = 0.49   // clearly left of the numeric grid (uL 0.61) with a real gap
        // Match the numeric grid's four row positions so this reads as the pad
        // block's tidy left column (riddim-green on the real unit).
        let vT: Float = 0.44, vB: Float = 0.93
        for (i, ent) in groups.enumerated() {
            let v = vT + (vB - vT) * (Float(i) / Float(groups.count - 1))
            let (x, z) = face(u, v)
            let pad = box(ent.rawValue, w: 0.018, h: 0.0050, d: 0.022, radius: 0.003,
                          at: [x, topY + 0.0018 + 0.0025, z], matte(greenHex, rough: 0.5))
            root.addChild(pad)
        }
    }

    // MARK: - Ports (top/far edge)
    @MainActor
    private static func buildPorts(into root: Entity) {
        let (sx, sz) = face(0.5, 0.025)
        let strip = box(EP40Entity.portsStrip.rawValue, w: 0.20, h: 0.008, d: 0.008, radius: 0.002,
                        at: [sx, 0.0, sz - 0.002], matte(0x3A3C3E, rough: 0.5))
        root.addChild(strip)
        let (ux, uz) = face(0.72, 0.02)
        let usb = box(EP40Entity.portsUsb.rawValue, w: 0.010, h: 0.004, d: 0.004, radius: 0.001,
                      at: [ux, 0.0, uz - 0.004], matte(0x161718, rough: 0.5))
        root.addChild(usb)
    }

    // MARK: - Speaker grille — round, front-firing, upper-right (owner-confirmed; DD-006a resolved)
    // The distinctive EP-40 round striped grille. Metal rim + dark recessed disc;
    // real instanced perforations/stripes come with the final model.
    @MainActor
    private static func buildSpeaker(into root: Entity) {
        let (sx, sz) = face(0.79, 0.22)
        let rim = cyl("speaker_rim", h: 0.0016, r: 0.034,
                      at: [sx, topY + 0.0008, sz], matte(edgeHex, rough: 0.4, metal: 0.5))
        root.addChild(rim)
        let grille = cyl(EP40Entity.speakerGrille.rawValue, h: 0.0020, r: 0.030,
                         at: [sx, topY + 0.0010, sz], matte(0x20262A, rough: 0.6))
        root.addChild(grille)
    }

    // MARK: - Halo ring (thin emissive disc just beneath the device; low luminance at rest)
    @MainActor
    private static func buildHaloRing(into root: Entity) {
        // Low resting luminance (no device connected → nearly dormant). Real state
        // machine (discover/connect/monitor/record) drives intensity in Phase 2.
        let ring = cyl(EP40Entity.haloRing.rawValue, h: 0.0010, r: 0.138,
                       at: [0, -thickness/2 - 0.0016, 0], emissive(orangeHex, intensity: 1.6))
        root.addChild(ring)
    }
}

// MARK: - NSColor from hex for RealityKit materials
extension NSColor {
    static func rk(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green:   CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue:    CGFloat(hex & 0xFF) / 255.0,
                alpha:   1.0)
    }
}
