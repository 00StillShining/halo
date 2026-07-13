import RealityKit

/// FROZEN entity-name contract (Brief §6, corrected by 2026-07-13 hardware research —
/// see DD-006). USD/Blender sanitizes '.' and '-' to '_', so the machine contract
/// uses underscores. **Blender objects must be named with these exact strings** so
/// the USDZ path and the procedural fallback resolve identically.
enum EP40Entity: String, CaseIterable, Sendable {

    // Chassis & surfaces
    case root            = "ep40_root"
    case chassisBase     = "chassis_base"
    case chassisTopPlate = "chassis_topPlate"
    case chassisEdgeBand = "chassis_edgeBand"
    case displaySurface  = "display_surface"   // segmented icon readout — halo draws its own state
    case speakerGrille   = "speaker_grille"    // PROVISIONAL location — see DD-006a
    case haloRing        = "halo_ring"
    case micPort         = "mic_port"          // built-in mic (non-interactive)

    // Four group pads (REAL pressure-sensitive pads, not indicators)
    case groupA = "group_a"
    case groupB = "group_b"
    case groupC = "group_c"
    case groupD = "group_d"

    // The one physical set of twelve numeric/sample pads.
    // Documented MIDI note order for a group is: dot, 0…9, ENTER.
    case padDot   = "pad_dot"
    case pad0     = "pad_0"
    case pad1     = "pad_1"
    case pad2     = "pad_2"
    case pad3     = "pad_3"
    case pad4     = "pad_4"
    case pad5     = "pad_5"
    case pad6     = "pad_6"
    case pad7     = "pad_7"
    case pad8     = "pad_8"
    case pad9     = "pad_9"
    case padEnter = "pad_enter"

    // Rotaries & fader
    case knobVolume = "knob_volume"   // present on shared chassis; verify on EP-40
    case knobX      = "knob_x"
    case knobY      = "knob_y"
    case faderTrack = "fader_track"
    case faderCap   = "fader_cap"

    // Buttons (incl. KEYS, added from research)
    case buttonSound  = "button_sound"
    case buttonMain   = "button_main"
    case buttonTempo  = "button_tempo"
    case buttonSample = "button_sample"
    case buttonKeys   = "button_keys"
    case buttonTiming = "button_timing"
    case buttonFx     = "button_fx"
    case buttonErase  = "button_erase"
    case buttonShift  = "button_shift"
    case buttonMinus  = "button_minus"
    case buttonPlus   = "button_plus"
    case buttonRecord = "button_record"
    case buttonPlay   = "button_play"

    // Ports (all on the top edge)
    case portsStrip = "ports_strip"
    case portsUsb   = "ports_usb"

    // MARK: - Groupings

    /// The twelve numeric pads in documented MIDI-note order (dot, 0, ENTER, 1…9).
    static let numericPadsInNoteOrder: [EP40Entity] =
        [.padDot, .pad0, .padEnter, .pad1, .pad2, .pad3, .pad4, .pad5, .pad6, .pad7, .pad8, .pad9]

    static let groupPads: [EP40Entity] = [.groupA, .groupB, .groupC, .groupD]

    static let knobs: [EP40Entity] = [.knobVolume, .knobX, .knobY]

    static let buttons: [EP40Entity] = [
        .buttonSound, .buttonMain, .buttonTempo,
        .buttonSample, .buttonKeys, .buttonTiming, .buttonFx,
        .buttonErase, .buttonShift, .buttonMinus, .buttonPlus,
        .buttonRecord, .buttonPlay,
    ]

    /// Pressable things (get press-travel + hit testing): numeric pads, group pads, buttons.
    static var pressable: [EP40Entity] { numericPadsInNoteOrder + groupPads + buttons }

    /// Everything that must resolve for a model to pass validation.
    static var required: [EP40Entity] { allCases }
}

extension EP40Entity {
    /// Recursively resolve the contract against a loaded root. `.root` maps to
    /// `root` itself. Returns the resolved map and any missing names.
    @MainActor
    static func resolve(in root: Entity) -> (map: [EP40Entity: Entity], missing: [EP40Entity]) {
        var map: [EP40Entity: Entity] = [.root: root]
        var missing: [EP40Entity] = []
        for e in EP40Entity.allCases where e != .root {
            if let found = root.findEntity(named: e.rawValue) {
                map[e] = found
            } else {
                missing.append(e)
            }
        }
        return (map, missing)
    }
}
