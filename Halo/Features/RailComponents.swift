import SwiftUI

/// Shared honest rest-state parts for the per-mode rail scaffolds (Brief §7).
/// No invented data, no fake-working controls: placeholders are disabled with a
/// mono caption stating the real reason; rest values are an em-dash. These read
/// as spec plates, not empty states. No orange anywhere — orange stays reserved
/// for selected / engaged / focus.

/// A mono caption stating the real reason a control is inert.
struct RailCaption: View {
    @Environment(\.halo) private var c
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(HaloType.mono(10))
            .foregroundStyle(c.inkSoft.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A monospaced `LABEL — VALUE` readout row; the value defaults to an em-dash
/// (no data exists yet — the honest rest value).
struct RailDataRow: View {
    @Environment(\.halo) private var c
    var label: String
    var value: String
    init(_ label: String, _ value: String = "—") {
        self.label = label
        self.value = value
    }
    var body: some View {
        HStack {
            Text(label)
                .font(HaloType.mono(11))
                .foregroundStyle(c.inkSoft)
            Spacer(minLength: HaloMetrics.s2)
            Text(value)
                .font(HaloType.mono(11))
                .foregroundStyle(c.ink)
        }
    }
}

/// An inert hairline-outlined tag — a legend, never a control.
struct RailTag: View {
    @Environment(\.halo) private var c
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(HaloType.label(9))
            .haloLabelCase()
            .foregroundStyle(c.inkSoft.opacity(0.8))
            .padding(.horizontal, HaloMetrics.s1)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                    .stroke(c.ink.opacity(0.28), lineWidth: HaloMetrics.hairline)
            )
    }
}

/// A hairline meter track resting at zero — no motion, because no audio truth
/// exists yet (Brief §1/§4 honesty).
struct RailMeterTrack: View {
    @Environment(\.halo) private var c
    var channel: String
    var body: some View {
        HStack(spacing: HaloMetrics.s1) {
            Text(channel)
                .font(HaloType.mono(10))
                .foregroundStyle(c.inkSoft)
            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                .fill(c.metal.opacity(0.35))
                .frame(height: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .stroke(c.ink.opacity(0.2), lineWidth: HaloMetrics.hairline)
                )
            Text("—")
                .font(HaloType.mono(10))
                .foregroundStyle(c.inkSoft)
        }
    }
}
