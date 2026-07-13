import Foundation

/// Pure, non-`@MainActor`. Tracks which `(channel, note)` holds are keeping each
/// physical pad depressed so live pad travel can be POLYPHONIC and honest.
///
/// The real quirk this survives: two notes from different groups (e.g. 36 and 48)
/// map to the SAME physical pad via `EP40MIDIMapping.gridIndex(forNote:)`. A raw
/// integer count would break on duplicate Note Ons (retrigger) and orphan Note
/// Offs; a per-pad set of `(channel, note)` keys is robust to both — a pad
/// releases only when its LAST hold ends.
///
/// Policy (opinionated, so the scene never invents state):
///   • A duplicate Note On for an already-held key is a `.restrike` — the
///     hardware sent a strike, so the LED re-flashes at the newly observed
///     velocity, but travel cannot go further down.
///   • Latest observed velocity wins. There is no max-hold blending — that would
///     be inferring a level the device never reported.
///   • Notes outside the Keys-mode pad range (36…83) return `nil` and do nothing.
///
/// Exercised directly by `PadHoldRegistryTests`.
struct PadHoldRegistry {
    struct Hold: Hashable { let channel: UInt8; let note: UInt8 }

    enum Transition: Equatable {
        case press(velocity: Float)     // 0 → 1 holds: travel down + LED on
        case restrike(velocity: Float)  // already down, struck again: LED re-flash only
        case release                    // last hold gone: travel up + LED decay
        case sustain                    // a hold ended but others remain: nothing moves
    }

    private var holds: [Set<Hold>] =
        Array(repeating: [], count: EP40MIDIMapping.padsPerGroup)

    mutating func noteOn(channel: UInt8, note: UInt8, velocity01: Float)
        -> (pad: Int, transition: Transition)? {
        guard let pad = EP40MIDIMapping.gridIndex(forNote: note) else { return nil }
        let wasHeld = !holds[pad].isEmpty
        holds[pad].insert(Hold(channel: channel, note: note))
        return (pad, wasHeld ? .restrike(velocity: velocity01)
                             : .press(velocity: velocity01))
    }

    mutating func noteOff(channel: UInt8, note: UInt8)
        -> (pad: Int, transition: Transition)? {
        guard let pad = EP40MIDIMapping.gridIndex(forNote: note),
              holds[pad].remove(Hold(channel: channel, note: note)) != nil
        else { return nil }                       // orphan Note Off: ignore
        return (pad, holds[pad].isEmpty ? .release : .sustain)
    }

    /// Disconnect / reset: returns the pads that were held so the caller can
    /// release them, then clears all state. No observation may survive a
    /// connection change.
    mutating func releaseAll() -> [Int] {
        let held = holds.indices.filter { !holds[$0].isEmpty }
        for i in holds.indices { holds[i].removeAll(keepingCapacity: true) }
        return held
    }
}
