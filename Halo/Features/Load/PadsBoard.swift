import SwiftUI

/// PADS tab content (Brief §7 Load): the selected mock project, its four groups
/// A–D, a flat 3×4 map of the twelve numeric pads in physical grid order, and a
/// detail plate for the selected pad. The board cells are flat plates — a *map* of
/// the hardware, not keycaps (the 3D model is the pressable thing). Group
/// selection is UI state; it never lights the 3D group pads (`setLit` is reserved
/// for observed hardware state, DD-010). All data MOCK.
struct PadsBoard: View {
    @Environment(\.halo) private var c
    @Bindable var session: LoadSession

    @FocusState private var boardFocused: Bool

    private var library: MockDeviceLibrary { session.library }
    private var groupLabel: String { PadGrid.groupLetter(session.selectedGroup) }

    /// True when NO pad in the current group has an assigned slot (P4-states empty).
    private var groupIsEmpty: Bool {
        (0..<12).allSatisfy {
            library.project.assignment(group: session.selectedGroup, gridIndex: $0).slot == nil
        }
    }

    var body: some View {
        VStack(spacing: HaloMetrics.s2) {
            HaloPanel("PROJECT") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    RailDataRow("PROJECT", "\(library.project.name) (MOCK)")
                    RailDataRow("PROJECTS ON DEVICE", "9")
                }
            }

            groupRow

            HaloPanel("PADS — GROUP \(groupLabel)") {
                if groupIsEmpty {
                    HaloStatePlate(kind: .empty, title: "GROUP \(groupLabel) EMPTY",
                                   reason: "DRAG A SAMPLE ONTO A PAD.")
                } else {
                    board
                }
            }

            HaloPanel("PAD DETAIL") {
                padDetail
            }
        }
    }

    // MARK: - Group keycaps A B C D

    private var groupRow: some View {
        HStack(spacing: HaloMetrics.s1) {
            ForEach(0..<4, id: \.self) { g in
                Button(PadGrid.groupLetter(g)) {
                    session.selectedGroup = g
                    session.selectedGridIndex = nil
                }
                .buttonStyle(MechanicalButtonStyle())
                .mechanicalSelected(session.selectedGroup == g)
                .focusable()
                .help("Select group \(PadGrid.groupLetter(g))")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 3×4 flat board

    private var board: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: HaloMetrics.s1),
                           count: 3),
            spacing: HaloMetrics.s1
        ) {
            ForEach(0..<12, id: \.self) { gridIndex in
                cell(gridIndex)
            }
        }
        // Arrow-key selection over the 3×4 grid (Brief §7). Left/right step by one,
        // up/down by a row, clamped to the grid — no wraparound past the edges.
        .focusable()
        .focused($boardFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            moveSelection(press.key)
        }
    }

    /// Move the 3×4 selection by one cell in `key`'s direction, clamped. Selecting
    /// the first cell when nothing is selected yet.
    private func moveSelection(_ key: KeyEquivalent) -> KeyPress.Result {
        let cols = 3, rows = 4
        let current = session.selectedGridIndex ?? 0
        var row = current / cols, col = current % cols
        switch key {
        case .leftArrow:  col = max(0, col - 1)
        case .rightArrow: col = min(cols - 1, col + 1)
        case .upArrow:    row = max(0, row - 1)
        case .downArrow:  row = min(rows - 1, row + 1)
        default: return .ignored
        }
        session.selectedGridIndex = row * cols + col
        return .handled
    }

    private func cell(_ gridIndex: Int) -> some View {
        let assignment = library.project.assignment(
            group: session.selectedGroup, gridIndex: gridIndex)
        let sound = assignment.slot.flatMap { library.sound(for: $0) }
        let selected = session.selectedGridIndex == gridIndex
        return Button {
            session.selectedGridIndex = gridIndex
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(PadGrid.legends[gridIndex])
                    .font(HaloType.mono(10))
                    .foregroundStyle(c.inkSoft)
                Spacer(minLength: 0)
                if let sound {
                    Text(sound.name)
                        .font(HaloType.mono(10))
                        .foregroundStyle(c.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("SLOT \(assignment.slot?.label ?? "—")")
                        .font(HaloType.mono(9))
                        .foregroundStyle(c.inkSoft.opacity(0.75))
                } else {
                    Text("—")
                        .font(HaloType.mono(12))
                        .foregroundStyle(c.inkSoft.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 56)
            .padding(HaloMetrics.s1)
            .background(
                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                    .fill(c.paper)
                    .overlay(
                        RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                            .stroke(c.ink.opacity(0.22), lineWidth: HaloMetrics.hairline))
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .stroke(c.orange, lineWidth: HaloMechanics.rimWidth)
                        .padding(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pad detail

    @ViewBuilder
    private var padDetail: some View {
        if let gridIndex = session.selectedGridIndex {
            let assignment = library.project.assignment(
                group: session.selectedGroup, gridIndex: gridIndex)
            let sound = assignment.slot.flatMap { library.sound(for: $0) }
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                RailDataRow("PAD", "\(PadGrid.legends[gridIndex]) · GROUP \(groupLabel)")
                if let sound {
                    RailDataRow("ASSIGNED SLOT", sound.slot.label)
                    RailDataRow("NAME", sound.name)
                    RailDataRow("SIZE", MockFormat.bytes(sound.bytes))
                } else {
                    RailDataRow("ASSIGNED SLOT", "—  (NO ASSIGNMENT)")
                    RailDataRow("NAME", "—")
                    RailDataRow("SIZE", "—")
                }
            }
        } else {
            RailCaption("SELECT A PAD ABOVE")
        }
    }
}
