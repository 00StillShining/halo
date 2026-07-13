/// Projects an `EP40DisplayState` onto the model's latched control states.
///
/// Pure and non-`@MainActor` so `HaloTests` can pin the honesty rules (Brief §4)
/// exactly where a regression would be a review failure. The split is deliberate:
///   • `pressedPad`        — TRAVEL: an observed physical depression.
///   • `selectedModeButton`— rim: the inferred display mode.
///   • `activeGroupPad`    — rim: a note-range inference (brief-labelled).
///   • `playEngaged`       — rim: observed MIDI Start / Continue / Stop.
///
/// `button_record` is DELIBERATELY absent — there is no observed record source on
/// the documented USB MIDI surface (`EP40DisplayState` has no record field), so
/// there is nothing to project. That absence IS the honesty guarantee, and the
/// tests assert it stays absent. See DD-010.
struct EP40ControlProjection: Equatable {
    var pressedPad: EP40Entity?         // travel — observed depression
    var selectedModeButton: EP40Entity? // rim — inferred display mode
    var activeGroupPad: EP40Entity?     // rim — note-range inference
    var playEngaged: Bool               // rim — observed Start/Stop/Continue

    static let rest = EP40ControlProjection(
        pressedPad: nil, selectedModeButton: nil, activeGroupPad: nil, playEngaged: false)

    static func project(_ s: EP40DisplayState) -> EP40ControlProjection {
        // `.waiting` is at rest/unlit even if stale values linger in the struct.
        guard s.feedMode != .waiting else { return .rest }

        let pad = s.activePadIndex.flatMap {
            EP40Entity.padGridOrder.indices.contains($0) ? EP40Entity.padGridOrder[$0] : nil
        }
        // Only verified button mappings light up. `.erase` (preview-only) and
        // `.system` have no confirmed button — they stay dark.
        let mode: EP40Entity? = switch s.mode {
        case .sound: .buttonSound
        case .main:  .buttonMain
        case .tempo: .buttonTempo
        case .erase, .system: nil
        }
        let group = s.activeGroup.flatMap {
            EP40Entity.groupPads.indices.contains($0) ? EP40Entity.groupPads[$0] : nil
        }
        return EP40ControlProjection(
            pressedPad: pad,
            selectedModeButton: mode,
            activeGroupPad: group,
            playEngaged: s.isPlaying
        )
    }
}
