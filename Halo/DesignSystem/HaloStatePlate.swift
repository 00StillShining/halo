import SwiftUI

/// The coarse non-happy-path kinds (Brief §7 P4). Each traces to an already-observed
/// truth (see docs DD-025) — no kind invents a device state. `permission` and
/// `error` are the only attention-toned kinds (warning accent); everything else is
/// neutral (metal accent).
enum HaloStateKind: Equatable {
    case empty          // a real collection is empty (no takes / no snapshots / …)
    case loading        // a real load window (USDZ import, pre-first-snapshot audio)
    case offline        // no usable Mac output device
    case disconnected   // observer up, no EP-40 endpoint / audio input
    case suspended      // real NSWorkspace system sleep
    case busy           // a determinate in-flight operation (future device write)
    case permission     // needs authorization — attention tone
    case error          // recoverable failure — warning tone, stable (never flashing)

    /// Attention-toned kinds get the `warning` accent + title; the rest stay neutral.
    var isAttention: Bool { self == .permission || self == .error }

    /// Whether this kind drives a CONTINUOUS (sweeping) animation for the given
    /// determinate progress + Reduce-Motion state. Pure so `HaloStatePlateTests`
    /// can assert — by construction — that ERROR/EMPTY/etc. never animate and that
    /// BUSY with a determinate % is a static track, honouring the Brief §5/§10 rule
    /// "one short pulse, then a stable labelled state; never continuous flashing".
    func usesContinuousAnimation(progress: Double?, reduceMotion: Bool) -> Bool {
        guard self == .loading || self == .busy else { return false }
        if progress != nil { return false }     // determinate track — no sweep
        return !reduceMotion                     // sweep only when motion is allowed
    }
}

/// The canonical non-happy-path plate. ONE manufactured vocabulary for empty /
/// loading / permission / offline / disconnected / busy / error, raised to the same
/// standard as the happy path (Brief §7 P4). Tokens only; no SF-Symbol icon, no card
/// blur, square 2 px radius. Motion rule (Brief §5/§10): LOADING is a single slow
/// sweep (static under Reduce Motion), BUSY is a determinate numeric track, and
/// ERROR is a fully static hold — no `.repeatForever` opacity anywhere.
struct HaloStatePlate: View {
    @Environment(\.halo) private var c
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let kind: HaloStateKind
    let title: String
    var reason: String? = nil
    var progress: Double? = nil          // BUSY determinate (0…1) → numeric %
    var actionLabel: String? = nil
    var actionHelp: String? = nil        // tooltip naming the action + shortcut
    var action: (() -> Void)? = nil

    private var accent: Color { kind.isAttention ? c.warning : c.metal }
    private var titleColor: Color { kind.isAttention ? c.warning : c.ink }

    /// Live for the current environment — mirrors the pure kind rule.
    var usesContinuousAnimation: Bool {
        kind.usesContinuousAnimation(progress: progress, reduceMotion: reduceMotion)
    }

    var body: some View {
        HStack(alignment: .top, spacing: HaloMetrics.s2) {
            // Leading 2 px accent bar — echoes the rail's extrusion strip and the
            // mechanical "engaged" bar. Metal for neutral, warning for attention.
            Rectangle().fill(accent).frame(width: 2)
            VStack(alignment: .leading, spacing: HaloMetrics.s1) {
                Text(title)
                    .font(HaloType.label(11))
                    .haloLabelCase()
                    .foregroundStyle(titleColor)
                if let reason {
                    Text(reason)
                        .font(HaloType.mono(10))
                        .foregroundStyle(c.inkSoft.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if kind == .loading || kind == .busy { track }
                if let actionLabel, let action {
                    Button(actionLabel, action: action)
                        .buttonStyle(MechanicalButtonStyle())
                        .focusable()
                        .help(actionHelp ?? actionLabel)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(HaloMetrics.s2)
        .background(
            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                .fill(c.paper.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .stroke(c.ink.opacity(0.18), lineWidth: HaloMetrics.hairline))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(reason.map { "\(title). \($0)" } ?? title)
    }

    /// Determinate % (BUSY / transfer) or a single non-blinking sweep (LOADING).
    @ViewBuilder private var track: some View {
        if let progress {
            HaloThinTrack(fill: min(max(progress, 0), 1))
        } else if reduceMotion {
            // Calm static bar — the sweep would be motion; the timer/word carry info.
            HaloThinTrack(fill: 0.4).opacity(0.5)
        } else {
            HaloSweepTrack()
        }
    }
}

/// A 3 px determinate track — a metal channel with an ink-soft fill. Mirrors
/// `RailMeterTrack`'s resting-at-zero language; costs ~zero (no timeline).
struct HaloThinTrack: View {
    @Environment(\.halo) private var c
    /// 0…1 fill fraction.
    var fill: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(c.metal.opacity(0.35))
                RoundedRectangle(cornerRadius: 1)
                    .fill(c.inkSoft)
                    .frame(width: geo.size.width * CGFloat(min(max(fill, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}

/// A single ink-soft segment translating left→right on the render clock — a SWEEP,
/// never a blink (matches the ring's `discovering` single-travelling-segment
/// language, Brief §5). `TimelineView(.animation)` early-outs when off-screen.
struct HaloSweepTrack: View {
    @Environment(\.halo) private var c
    /// Seconds per full traverse.
    var period: Double = 1.2

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geo in
                let t = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                let segW = geo.size.width * 0.34
                // Ease the head across the full width and off the trailing edge.
                let x = (geo.size.width + segW) * CGFloat(t) - segW
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(c.metal.opacity(0.30))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(c.inkSoft.opacity(0.85))
                        .frame(width: segW)
                        .offset(x: x)
                }
                .clipShape(RoundedRectangle(cornerRadius: 1))
            }
        }
        .frame(height: 3)
    }
}

#if DEBUG
#Preview("HaloStatePlate — gallery") {
    ScrollView {
        VStack(spacing: HaloMetrics.s2) {
            HaloStatePlate(kind: .empty, title: "NO TAKES",
                           reason: "RECORD A SESSION TO CAPTURE ONE.")
            HaloStatePlate(kind: .loading, title: "LOADING MODEL",
                           reason: "PREPARING THE EP-40 STAGE.")
            HaloStatePlate(kind: .disconnected, title: "NO EP-40",
                           reason: "CONNECT BY USB-C AND POWER ON. SHOWING PREVIEW.")
            HaloStatePlate(kind: .permission, title: "MIC ACCESS DENIED",
                           reason: "ENABLE IN SYSTEM SETTINGS.",
                           actionLabel: "OPEN SETTINGS", actionHelp: "Open Privacy settings") {}
            HaloStatePlate(kind: .busy, title: "WRITING", reason: "TRANSFER IN PROGRESS.",
                           progress: 0.62)
            HaloStatePlate(kind: .error, title: "MONITOR FAILED",
                           reason: "AUDIO COMPONENT UNAVAILABLE.",
                           actionLabel: "TRY AGAIN", actionHelp: "Restart the monitor route") {}
        }
        .padding(HaloMetrics.s3)
    }
    .frame(width: 360, height: 640)
    .environment(\.halo, .graphPaper)
    .background(HaloColorTokens.graphPaper.canvas)
}
#endif
