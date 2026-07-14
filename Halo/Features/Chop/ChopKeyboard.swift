import Foundation

/// Pure key → pad-legend → slice-index map for CHOP keyboard audition (Brief §5c:
/// "audition slices from the keyboard (1-9, 0, ., Return mirroring pad order)").
///
/// Slices fill CONSECUTIVE pads in grid order starting at `startGridIndex` (slice 0 →
/// the start pad, slice 1 → the next grid index, …). The key whose legend sits on pad P
/// auditions the slice assigned to P — so the numeric keypad mirrors the physical pad
/// layout exactly (`PadGrid.legends`). Deterministic and unit-tested.
enum ChopKeyboard {

    /// Grid index (0…11) of a pad legend, or nil if the legend is not on the board.
    static func gridIndex(forLegend legend: String) -> Int? {
        PadGrid.legends.firstIndex(of: legend)
    }

    /// Map a pressed key's character to its pad legend: "1"…"9", "0", "." verbatim, and
    /// Return/Enter → "ENTER" (the twelfth pad legend). nil for anything else.
    static func legend(forCharacter ch: Character) -> String? {
        if ch == "\r" || ch == "\n" || ch == "\u{3}" { return "ENTER" }
        let s = String(ch)
        return PadGrid.legends.contains(s) ? s : nil
    }

    /// Slice index for a legend, given the fill start pad and the slice count. Returns
    /// nil when that pad holds no slice (before the start pad, or past the last slice).
    static func sliceIndex(forLegend legend: String, startGridIndex: Int, sliceCount: Int) -> Int? {
        guard let gi = gridIndex(forLegend: legend), gi >= startGridIndex else { return nil }
        let idx = gi - startGridIndex
        return idx < sliceCount ? idx : nil
    }

    /// Convenience: resolve a pressed character straight to a slice index (or nil).
    static func sliceIndex(forCharacter ch: Character, startGridIndex: Int, sliceCount: Int) -> Int? {
        guard let legend = legend(forCharacter: ch) else { return nil }
        return sliceIndex(forLegend: legend, startGridIndex: startGridIndex, sliceCount: sliceCount)
    }
}
