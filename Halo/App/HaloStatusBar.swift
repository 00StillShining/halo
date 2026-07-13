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
            statusChip(label: "DISPLAY", value: displayStatus, accent: isDisplayLive)

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
            statusChip(label: "MONITOR", value: "OFF", accent: false)
            statusChip(label: "REC", value: "—", accent: false)
        }
        .padding(.horizontal, HaloMetrics.s3)
        .frame(height: 52)
        .background(c.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(c.ink.opacity(0.18)).frame(height: HaloMetrics.hairline)
        }
    }

    @ViewBuilder
    private func statusChip(label: String, value: String, accent: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(HaloType.label(9))
                .haloLabelCase()
                .foregroundStyle(c.inkSoft.opacity(0.7))
            Text(value)
                .font(HaloType.mono(11, weight: .medium))
                .foregroundStyle(accent ? c.riddimGreen : c.ink)
        }
    }
}
