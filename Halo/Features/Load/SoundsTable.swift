import SwiftUI

/// SOUNDS tab content (Brief §7 Load): the mock 001–999 device library with name,
/// duration, rate, channels, size and derived usage. The `USE` column is *computed*
/// from PADS assignments through `library.assignments(referencing:)` — the visible
/// proof that slots (`SLOT 042`) and pads (`PAD 7 · GROUP A`) are never the same
/// thing (Brief §3). All data MOCK; on-device audition needs the verified Bank/PC
/// scheme (Phase 0A) and is disabled.
struct SoundsTable: View {
    @Environment(\.halo) private var c
    @Bindable var session: LoadSession
    @FocusState private var listFocused: Bool

    private var library: MockDeviceLibrary { session.library }

    var body: some View {
        VStack(spacing: HaloMetrics.s2) {
            HaloPanel("STORAGE") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    RailDataRow("SLOTS USED", "\(library.sounds.count) / 999 (MOCK)")
                    RailDataRow("CAPACITY", capacityLine)
                }
            }

            HaloPanel("SOUNDS 001–999") {
                VStack(spacing: 0) {
                    header
                    Rectangle().fill(c.ink.opacity(0.2)).frame(height: HaloMetrics.hairline)
                    rows
                }
            }

            HaloPanel("SOUND DETAIL") {
                detail
            }
        }
    }

    private var capacityLine: String {
        "\(MockFormat.megabytes(library.usedBytes)) USED · "
        + "\(MockFormat.megabytes(library.freeBytes)) FREE OF "
        + "\(MockFormat.megabytes(MockDeviceLibrary.reportedCapacityBytes)) (MOCK)"
    }

    // MARK: - Table

    private var header: some View {
        row(slot: "SLOT", name: "NAME", dur: "DUR", rate: "RATE",
            ch: "CH", size: "SIZE", use: "USE",
            font: HaloType.mono(9), color: c.inkSoft)
        .padding(.vertical, 4)
    }

    /// The library rows scroll INSIDE the panel (bounded height): the rail hosts
    /// ~150 mock rows, and an unbounded list would push the SOUND DETAIL plate —
    /// and its honesty caption — hundreds of points below the fold. The internal
    /// `ScrollView` is also what makes `proxy.scrollTo` real: a `ScrollViewReader`
    /// only reaches descendant scroll views, so keyboard selection tracks into view.
    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(library.sounds) { sound in
                        soundRow(sound)
                            .id(sound.slot)
                    }
                }
            }
            .frame(height: 264)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                move(press.key == .upArrow ? -1 : 1, proxy: proxy)
            }
        }
    }

    private func soundRow(_ sound: MockDeviceSound) -> some View {
        let selected = session.selectedSlot == sound.slot
        return Button {
            session.selectedSlot = sound.slot
            listFocused = true
        } label: {
            row(slot: sound.slot.label,
                name: sound.name,
                dur: MockFormat.duration(sound.durationSeconds),
                rate: MockFormat.rate(sound.sampleRate),
                ch: MockFormat.channels(sound.channels),
                size: MockFormat.bytesCompact(sound.bytes),
                use: useToken(sound.slot),
                font: HaloType.mono(10), color: c.ink)
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                    .fill(selected ? c.paperHigh : Color.clear)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .stroke(c.orange, lineWidth: HaloMechanics.rimWidth)
                        .padding(1)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(c.ink.opacity(0.08)).frame(height: HaloMetrics.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One aligned table row. Fixed column widths keep the monospaced grid honest.
    private func row(slot: String, name: String, dur: String, rate: String,
                     ch: String, size: String, use: String,
                     font: Font, color: Color) -> some View {
        HStack(spacing: HaloMetrics.s1) {
            Text(slot).font(font).foregroundStyle(color)
                .frame(width: 30, alignment: .leading)
            Text(name).font(font).foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1).truncationMode(.tail)
            Text(dur).font(font).foregroundStyle(color)
                .frame(width: 48, alignment: .trailing)
            Text(rate).font(font).foregroundStyle(color)
                .frame(width: 42, alignment: .trailing)
            Text(ch).font(font).foregroundStyle(color)
                .frame(width: 22, alignment: .trailing)
            Text(size).font(font).foregroundStyle(color)
                .frame(width: 40, alignment: .trailing)
            Text(use).font(font).foregroundStyle(color == c.ink ? c.inkSoft : color)
                .frame(width: 48, alignment: .trailing)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private func useToken(_ slot: SampleSlotID) -> String {
        let refs = library.assignments(referencing: slot)
        guard !refs.isEmpty else { return "—" }
        return refs.map { PadGrid.useToken($0) }.joined(separator: " ")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let slot = session.selectedSlot, let sound = library.sound(for: slot) {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                RailDataRow("SLOT", sound.slot.label)
                RailDataRow("NAME", sound.name)
                RailDataRow("DURATION", MockFormat.duration(sound.durationSeconds))
                RailDataRow("RATE", "\(MockFormat.rate(sound.sampleRate))HZ")
                RailDataRow("CHANNELS", MockFormat.channelsLong(sound.channels))
                RailDataRow("SIZE", MockFormat.bytes(sound.bytes))
                RailDataRow("USED BY", usedByLine(slot))

                Button("AUDITION") {}
                    .buttonStyle(MechanicalButtonStyle())
                    .disabled(true)
                RailCaption("ON-DEVICE AUDITION — BANK/PC SCHEME UNVERIFIED (PHASE 0A)")
            }
        } else {
            RailCaption("SELECT A SOUND ABOVE")
        }
    }

    private func usedByLine(_ slot: SampleSlotID) -> String {
        let refs = library.assignments(referencing: slot)
        guard !refs.isEmpty else { return "—  (NO PAD REFERENCES)" }
        return refs.map { "PAD \(PadGrid.legends[$0.gridIndex]) · GROUP \(PadGrid.groupLetter($0.group))" }
            .joined(separator: ", ")
    }

    // MARK: - Keyboard selection (Brief §7 arrow keys)

    private func move(_ delta: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let sounds = library.sounds
        guard !sounds.isEmpty else { return .ignored }
        let current = session.selectedSlot.flatMap { s in sounds.firstIndex { $0.slot == s } }
        let next = min(max((current ?? -1) + delta, 0), sounds.count - 1)
        session.selectedSlot = sounds[next].slot
        proxy.scrollTo(sounds[next].slot, anchor: .center)
        return .handled
    }
}
