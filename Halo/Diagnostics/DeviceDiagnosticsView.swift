import SwiftUI

/// The global read-only Diagnostics drawer (P4-diagnostics, DD-024). Surfaces three
/// honest things: the app's live status right now, the seeded capability matrix
/// (what halo has actually observed on the physical EP-40 vs. what is only
/// documented), and the empty-by-construction protocol-trace scaffold. Plus an
/// EXPORT LOG action writing a plaintext snapshot to the canonical `Diagnostics/`
/// folder.
///
/// **Design rule that shapes every colour here:** green (`riddimGreen`) is reserved
/// for hardware truth halo has ACTUALLY observed. Nothing in the capability matrix
/// is `.observed`, so nothing in the matrix is green. A fully-built, unit-tested
/// Mac-side mechanism reads `BUILT` in a *muted* readiness chip — never green — a
/// working mechanism is not a device confirmation (Brief §1/§3/§4). The HOST audio
/// block is kept verbally distinct from the DEVICE block so "this Mac has an output
/// device" is never misread as "the EP-40 is connected".
///
/// Honesty invariant (DD-013): the drawer is a transient that holds NO audio handle
/// — Escape closes it and can never stop audio.
struct DiagnosticsDrawer: View {
    @Environment(\.halo) private var c
    @Environment(HaloAppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Transparent gutter — taps fall through to the scrim below.
                Spacer(minLength: 0).allowsHitTesting(false)
                panel(width: min(460, geo.size.width * 0.42))
            }
        }
        .haloTransient { model.toggleDiagnostics() }
    }

    private func panel(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(c.ink.opacity(0.18)).frame(height: HaloMetrics.hairline)
            ScrollView {
                VStack(spacing: HaloMetrics.s2) {
                    deviceStatusPanel
                    hostAudioPanel
                    midiStatusPanel
                    CapabilityMatrixPanel()
                    ProtocolTracePanel()
                }
                .padding(HaloMetrics.s2)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(c.paper)
        .overlay(alignment: .leading) {
            Rectangle().fill(c.ink.opacity(0.25)).frame(width: HaloMetrics.hairline)
        }
        // Hard offset shadow (blur 0), key from the right — a machined panel sliding
        // over the stage, not a floating card.
        .shadow(color: c.ink.opacity(0.22), radius: 0, x: -HaloMetrics.shadowOffset, y: 0)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: HaloMetrics.s2) {
            VStack(alignment: .leading, spacing: 1) {
                Text("DIAGNOSTICS")
                    .font(HaloType.label(11))
                    .haloLabelCase()
                    .foregroundStyle(c.ink)
                Text("read-only · local")
                    .font(HaloType.mono(9))
                    .foregroundStyle(c.inkSoft.opacity(0.7))
            }
            Spacer(minLength: 0)
            Button("EXPORT LOG") { model.exportDiagnostics() }
                .buttonStyle(MechanicalButtonStyle())
                .focusable()
                .help("Write a plaintext snapshot to the Diagnostics folder and reveal it")
            Button("✕") { model.toggleDiagnostics() }
                .buttonStyle(MechanicalButtonStyle())
                .focusable()
                .help("Close — Escape")
        }
        .padding(.horizontal, HaloMetrics.s2)
        .frame(height: 52)
    }

    // MARK: - Panel 1 · STATUS · DEVICE

    private var deviceStatusPanel: some View {
        HaloPanel("STATUS · DEVICE") {
            VStack(alignment: .leading, spacing: HaloMetrics.s1) {
                DiagRow(label: "ENDPOINT", value: model.deviceStatus,
                        tint: model.deviceStatus == "CONNECTED" ? c.riddimGreen : nil)
                DiagRow(label: "MIDI SRC", value: model.midiEndpointName ?? "—")
                DiagRow(label: "USB", value: model.usbStatus)
                DiagRow(label: "STATE", value: model.lifecyclePhase.word, tint: lifecycleTint)
                DiagRow(label: "HALO RING", value: model.ringState.statusWord, tint: ringTint)
                DiagRow(label: "MODEL", value: model.diagModelValue,
                        tint: model.scene.isPlaceholder ? c.warning : nil)
            }
        }
    }

    // MARK: - Panel 2 · STATUS · HOST AUDIO

    private var hostAudioPanel: some View {
        HaloPanel("STATUS · HOST AUDIO") {
            VStack(alignment: .leading, spacing: HaloMetrics.s1) {
                // The standing warning: this block is about THIS Mac, never the EP-40.
                Text("this Mac, not the EP-40")
                    .font(HaloType.mono(9))
                    .foregroundStyle(c.inkSoft.opacity(0.7))
                    .padding(.bottom, 2)
                DiagRow(label: "MIC AUTH", value: model.permission.status.word, tint: micTint)
                DiagRow(label: "OUTPUT", value: model.diagOutputValue)
                DiagRow(label: "RATE", value: model.diagRateValue)
                DiagRow(label: "MONITOR", value: model.diagMonitorValue,
                        tint: model.monitor.isRunning ? c.riddimGreen : nil)
                DiagRow(label: "PROFILE", value: model.diagProfileValue)
                DiagRow(label: "FEEDBACK", value: model.diagFeedbackValue,
                        tint: model.monitor.hasFeedbackRisk ? c.warning : nil)
                DiagRow(label: "DEVICES", value: model.diagDevicesValue)
            }
        }
    }

    // MARK: - Panel 3 · STATUS · MIDI

    private var midiStatusPanel: some View {
        HaloPanel("STATUS · MIDI") {
            VStack(alignment: .leading, spacing: HaloMetrics.s1) {
                DiagRow(label: "CLIENT", value: model.isMIDIClientRunning ? "RUNNING" : "DOWN",
                        tint: model.isMIDIClientRunning ? c.riddimGreen : c.warning)
                DiagRow(label: "ERROR", value: model.midiErrorLabel ?? "—",
                        tint: model.midiErrorLabel != nil ? c.warning : nil)
            }
        }
    }

    // MARK: - Tints (tokens only; green strictly reserved for observed live truth)

    private var lifecycleTint: Color? {
        let p = model.lifecyclePhase
        if p.isError { return c.warning }
        if p.isLive { return c.riddimGreen }
        if p.isSuspended { return c.inkSoft }
        return nil
    }

    private var ringTint: Color? {
        let r = model.ringState
        if r.isError { return c.warning }
        switch r {
        case .connected, .monitoring, .recording, .transfer: return c.riddimGreen
        default: return nil
        }
    }

    private var micTint: Color? {
        switch model.permission.status.word {
        case "OK": return c.riddimGreen
        case "DENIED", "BLOCKED": return c.warning
        default: return nil
        }
    }
}

// MARK: - Status row

/// A monospaced `LABEL   VALUE` diagnostics row. The value tint is nil by default
/// (plain ink); callers pass `c.riddimGreen` only for observed live truth,
/// `c.warning` for an observed problem.
private struct DiagRow: View {
    @Environment(\.halo) private var c
    let label: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: HaloMetrics.s2) {
            Text(label)
                .font(HaloType.label(10))
                .haloLabelCase()
                .foregroundStyle(c.inkSoft.opacity(0.7))
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(HaloType.mono(11, weight: .medium))
                .foregroundStyle(tint ?? c.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
    }
}

// MARK: - Capability matrix

private struct CapabilityMatrixPanel: View {
    @Environment(\.halo) private var c

    var body: some View {
        HaloPanel("CAPABILITY MATRIX") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                Text("green = observed on the physical EP-40. nothing here is green yet.")
                    .font(HaloType.mono(9))
                    .foregroundStyle(c.inkSoft.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(CapabilityDomain.allCases) { domain in
                    let rows = DeviceCapabilities.rows(in: domain)
                    if !rows.isEmpty {
                        Text(domain.rawValue)
                            .font(HaloType.label(9))
                            .haloLabelCase()
                            .foregroundStyle(c.inkSoft)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 {
                                    Rectangle().fill(c.ink.opacity(0.08))
                                        .frame(height: HaloMetrics.hairline)
                                }
                                CapabilityRow(capability: row)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct CapabilityRow: View {
    @Environment(\.halo) private var c
    let capability: Capability

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: HaloMetrics.s1) {
                Text(capability.title)
                    .font(HaloType.body(12))
                    .foregroundStyle(c.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: HaloMetrics.s1)
                CapabilityPill(status: capability.status)
                ReadinessChip(readiness: capability.readiness)
            }
            HStack(spacing: HaloMetrics.s1) {
                Text(capability.evidence)
                    .font(HaloType.mono(9))
                    .foregroundStyle(c.inkSoft.opacity(0.6))
                if let note = capability.note {
                    Text("· \(note)")
                        .font(HaloType.body(11))
                        .foregroundStyle(c.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, HaloMetrics.s1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The device-truth axis. Green ONLY for `.observed` (earned). Documented reads as an
/// ink hairline outline; not-observed as a warning outline; unknown is the quietest.
private struct CapabilityPill: View {
    @Environment(\.halo) private var c
    let status: CapabilityStatus

    var body: some View {
        Text(status.rawValue)
            .font(HaloType.label(9))
            .haloLabelCase()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(fg)
            .background(bg)
            .overlay(
                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                    .stroke(stroke, lineWidth: HaloMetrics.hairline))
            .clipShape(RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall))
            .fixedSize()
    }

    private var fg: Color {
        switch status {
        case .observed:    return c.paperHigh
        case .documented:  return c.inkSoft
        case .notObserved: return c.warning
        case .unknown:     return c.inkSoft.opacity(0.55)
        }
    }
    private var bg: Color { status == .observed ? c.riddimGreen : .clear }
    private var stroke: Color {
        switch status {
        case .observed:    return .clear
        case .documented:  return c.ink.opacity(0.35)
        case .notObserved: return c.warning.opacity(0.6)
        case .unknown:     return c.inkSoft.opacity(0.28)
        }
    }
}

/// The build-readiness axis — always muted, NEVER green (built ≠ device confirmed).
/// Reads as metadata, not status.
private struct ReadinessChip: View {
    @Environment(\.halo) private var c
    let readiness: CapabilityReadiness

    var body: some View {
        Text(readiness.rawValue)
            .font(HaloType.mono(9))
            .foregroundStyle(c.inkSoft.opacity(0.6))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                    .stroke(c.inkSoft.opacity(0.25), lineWidth: HaloMetrics.hairline))
            .fixedSize()
    }
}

// MARK: - Protocol trace

private struct ProtocolTracePanel: View {
    @Environment(\.halo) private var c
    @Environment(HaloAppModel.self) private var model

    var body: some View {
        HaloPanel("PROTOCOL TRACE") {
            if model.protocolTrace.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: HaloMetrics.s1) {
                    Button("CLEAR") { model.protocolTrace.clear() }
                        .buttonStyle(MechanicalButtonStyle())
                    ForEach(model.protocolTrace.frames) { frame in
                        FrameRow(frame: frame)
                    }
                }
            }
        }
    }

    // The scaffold's honest voice: empty by construction, and it says why.
    private var emptyState: some View {
        VStack(spacing: HaloMetrics.s1) {
            Text("NO PROTOCOL FRAMES")
                .font(HaloType.label(10))
                .haloLabelCase()
                .foregroundStyle(c.inkSoft)
            Text("The EP-40 proprietary protocol is Phase 0B (needs device). This "
                 + "trace stays empty until a verified SysEx transport is wired — "
                 + "halo never fabricates a frame.")
                .font(HaloType.body(11))
                .foregroundStyle(c.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(HaloMetrics.s2)
        .background(
            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                .fill(c.ink.opacity(0.03)))
    }
}

private struct FrameRow: View {
    @Environment(\.halo) private var c
    let frame: ProtocolTrace.Frame

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: HaloMetrics.s1) {
                Text(frame.direction.rawValue)
                    .font(HaloType.label(9)).haloLabelCase()
                    .foregroundStyle(c.inkSoft)
                Text(frame.summary)
                    .font(HaloType.mono(10))
                    .foregroundStyle(c.ink)
            }
            Text(frame.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                .font(HaloType.mono(9))
                .foregroundStyle(c.inkSoft.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("DiagnosticsDrawer") {
    let model = HaloAppModel()
    return DiagnosticsDrawer()
        .frame(width: 900, height: 700)
        .environment(model)
        .environment(\.halo, .graphPaper)
        .background(HaloColorTokens.graphPaper.canvas)
}
#endif
