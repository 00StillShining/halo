import SwiftUI

/// Top status strip (Brief §7): the `halo` wordmark, device/FW/USB status, and
/// output / monitor / rec affordances. Display status distinguishes the local
/// demo from a connected endpoint and from genuinely observed MIDI activity.
struct HaloStatusBar: View {
    @Environment(\.halo) private var c
    var isPlaceholder: Bool
    var deviceStatus: String
    var firmwareStatus: String
    var usbStatus: String
    var displayStatus: String
    var isDisplayLive: Bool
    var midiEndpointName: String?
    var ringState: HaloRingState
    var lifecyclePhase: HaloLifecyclePhase
    var palette: HaloPalette
    var onSelectPalette: (HaloPalette) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: HaloMetrics.s3) {
            Text("halo")
                .font(HaloType.wordmark(26))
                .tracking(HaloType.Track.wordmark)
                .foregroundStyle(c.ink)

            statusChip(label: "EP-40", value: deviceStatus, accent: false)
                .help(midiEndpointName ?? "No matching EP-40 MIDI source")
            statusChip(label: "FW", value: firmwareStatus, accent: false)
            statusChip(label: "USB", value: usbStatus, accent: false)
            statusChip(label: "STATE", value: lifecyclePhase.word, tint: lifecycleChipTint)
            statusChip(label: "DISPLAY", value: displayStatus, accent: isDisplayLive)
            statusChip(label: "HALO", value: ringState.statusWord, tint: haloChipTint)

            Spacer()

            if isPlaceholder {
                Text("PLACEHOLDER MODEL")
                    .font(HaloType.label(10))
                    .haloLabelCase()
                    .foregroundStyle(c.warning)
                    .padding(.horizontal, HaloMetrics.s1)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                            .stroke(c.warning.opacity(0.6), lineWidth: HaloMetrics.hairline)
                    )
            }

            statusChip(label: "OUTPUT", value: "MACBOOK AIR", accent: false)
            statusChip(label: "MONITOR", value: monitorWord, accent: ringState == .monitoring)
            recChip

            paletteSwitcher
        }
        .padding(.horizontal, HaloMetrics.s3)
        .frame(height: 52)
        .background(c.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(c.ink.opacity(0.18)).frame(height: HaloMetrics.hairline)
        }
    }

    // Palette gate switcher (Brief §5): A / B mechanical keycaps. The owner picks
    // one at the Phase 1 visual gate; both palettes must keep working until then.
    // Exercises rest/hover/pressed/selected/keyboard-focus in one live place.
    private var paletteSwitcher: some View {
        HStack(spacing: 6) {
            Text("PALETTE")
                .font(HaloType.label(9))
                .haloLabelCase()
                .foregroundStyle(c.inkSoft.opacity(0.7))
            ForEach(HaloPalette.allCases) { option in
                Button(option.rawValue) { onSelectPalette(option) }
                    .buttonStyle(MechanicalButtonStyle())
                    .mechanicalSelected(palette == option)
                    .focusable()
                    .help(option.displayName)
            }
        }
    }

    // Green when the ring reports an active link/monitor/record/transfer, warning
    // when a real failure is observed, plain ink for dark/scan. Tokens only.
    private var haloChipTint: Color? {
        if ringState.isError { return c.warning }
        switch ringState {
        case .connected, .monitoring, .recording, .transfer: return c.riddimGreen
        default: return nil
        }
    }

    // Lifecycle chip tint (Brief §8): green on a live feed / engaged monitor, warning
    // on an observed failure, muted while suspended (system asleep), plain otherwise.
    private var lifecycleChipTint: Color? {
        if lifecyclePhase.isError { return c.warning }
        if lifecyclePhase.isLive { return c.riddimGreen }
        if lifecyclePhase.isSuspended { return c.inkSoft }
        return nil
    }

    // Honest MONITOR word — there is no audio engine yet, so this only reads MON
    // when a real monitor producer drives the ring (unreachable today).
    private var monitorWord: String { ringState == .monitoring ? "ON" : "OFF" }

    // REC chip: an unambiguous mm:ss timer while recording, otherwise idle.
    // Only the recording branch pulls in a TimelineView so the static bar stays
    // render-free. // Brief §7 utility rail: the timer moves there once it lands.
    @ViewBuilder
    private var recChip: some View {
        if case let .recording(startedAt) = ringState {
            HStack(spacing: 6) {
                Text("REC")
                    .font(HaloType.label(9))
                    .haloLabelCase()
                    .foregroundStyle(c.inkSoft.opacity(0.7))
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Self.elapsed(from: startedAt, to: context.date))
                        .font(HaloType.mono(11, weight: .medium))
                        .foregroundStyle(c.orangeHot)
                }
            }
        } else {
            statusChip(label: "REC", value: "—", accent: false)
        }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    @ViewBuilder
    private func statusChip(label: String, value: String,
                            accent: Bool = false, tint: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(HaloType.label(9))
                .haloLabelCase()
                .foregroundStyle(c.inkSoft.opacity(0.7))
            Text(value)
                .font(HaloType.mono(11, weight: .medium))
                .foregroundStyle(tint ?? (accent ? c.riddimGreen : c.ink))
        }
    }
}
