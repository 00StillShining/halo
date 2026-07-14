import SwiftUI
import UniformTypeIdentifiers

/// Shared honest formatting for the recorder readouts (Capture + Play transport).
/// Pure — no invented data; silence renders as an em-dash, not "-inf".
enum HaloRecordFormat {
    /// `mm:ss.d` from a wall-clock elapsed interval.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let m = Int(total) / 60
        let s = Int(total) % 60
        let tenths = Int((total - Double(Int(total))) * 10)
        return String(format: "%02d:%02d.%d", m, s, tenths)
    }

    /// A dBFS reading. True silence (`-inf`/NaN) is an em-dash, never "-inf".
    static func dbfs(_ value: Float) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.1f", value)
    }

    /// Peak reading paired with its take-long max-hold: `-6.2 (-1.1 PK)`.
    static func peakLine(current: Float, hold: Float) -> String {
        let now = dbfs(current)
        guard hold.isFinite else { return now }
        return "\(now) (\(dbfs(hold)) PK)"
    }

    /// Human byte size, e.g. `214.0 GB`.
    static func bytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, n))
        var i = 0
        while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", value, units[i])
    }

    /// Remaining record time for `freeBytes` at `sampleRate`, 24-bit stereo on disk.
    static func remaining(freeBytes: Int64, sampleRate: Double) -> String {
        let bytesPerSecond = max(1, sampleRate) * 2 * 3   // 2 ch × 3 bytes (24-bit)
        let seconds = Double(max(0, freeBytes)) / bytesPerSecond
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 { return "~\(h)H \(String(format: "%02d", m))M" }
        return "~\(m)M"
    }

    /// Compact `duration · rate · ch · size` line for a take row.
    static func takeSummary(_ take: Take) -> String {
        "\(clock(take.durationSeconds)) · \(take.sampleRate) HZ · "
        + "\(take.channels) CH · \(bytes(Int64(take.bytes)))"
    }

    static func diskLine(freeBytes: Int64, sampleRate: Double) -> String {
        "\(bytes(freeBytes)) · \(remaining(freeBytes: freeBytes, sampleRate: sampleRate))"
    }
}

/// CAPTURE rail (Brief §7). The session recorder is REAL as of P2-recorder: RECORD
/// taps the raw pre-monitor EP-40 input (before gain/limiter/FX, DD-018) and writes
/// a timestamped WAV to `~/Library/Application Support/Halo/Recordings`. It records
/// only while a monitor route runs (the raw stream exists only then); otherwise the
/// control is disabled with a real reason. Takes are files on disk and can be
/// dragged onto a model pad, reusing the honest prep flow (no device write). All
/// readouts rest at an em-dash until a take runs — nothing is invented (§1/§4).
struct CaptureRail: View {
    @Environment(\.halo) private var c
    @Environment(HaloAppModel.self) private var model

    private var recorder: SessionRecorder { model.recorder }
    private var canRecord: Bool { model.monitor.isRunning }

    private var captureCaption: String {
        switch recorder.state {
        case .recording:
            return recorder.printFX
                ? "CAPTURING POST-RACK FX — TAGGED “FX” ON DISK"
                : "CAPTURING RAW EP-40 INPUT — PRE-GAIN / PRE-LIMITER"
        case let .failed(reason):
            switch reason {
            case .monitorOff: return "MONITOR OFF — START MONITORING TO RECORD"
            case let .fileOpen(msg): return "COULD NOT OPEN FILE — \(msg)"
            }
        case .idle:
            return canRecord
                ? "READY — RECORDS THE RAW INPUT (⌘R)"
                : "MONITOR OFF — START MONITORING TO RECORD"
        }
    }

    var body: some View {
        VStack(spacing: HaloMetrics.s2) {
            capturePanel
            takesPanel
            locationPanel
        }
    }

    // MARK: - Panel 1 · SESSION CAPTURE

    private var capturePanel: some View {
        HaloPanel("SESSION CAPTURE") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                let isRecording = recorder.isRecording
                Button(isRecording ? "STOP" : "RECORD") { model.toggleRecording() }
                    .buttonStyle(MechanicalButtonStyle())
                    .mechanicalEngaged(isRecording)
                    .disabled(!canRecord && !isRecording)
                    .focusable(canRecord || isRecording)
                    .help(isRecording ? "Stop recording — ⌘R" : "Record raw input — ⌘R")
                RailCaption(captureCaption)

                Rectangle().fill(c.ink.opacity(0.12)).frame(height: HaloMetrics.hairline)

                RailDataRow("ELAPSED", isRecording ? HaloRecordFormat.clock(recorder.elapsed) : "—")
                RailDataRow("PEAK L", isRecording
                    ? HaloRecordFormat.peakLine(current: recorder.peaks.peakL, hold: recorder.peakHoldL)
                    : "—")
                RailDataRow("PEAK R", isRecording
                    ? HaloRecordFormat.peakLine(current: recorder.peaks.peakR, hold: recorder.peakHoldR)
                    : "—")
                RailDataRow("DISK FREE",
                    HaloRecordFormat.diskLine(freeBytes: recorder.diskFreeBytes,
                                              sampleRate: recorder.sampleRate))
            }
        }
    }

    // MARK: - Panel 2 · TAKES

    private var takesPanel: some View {
        HaloPanel("TAKES") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                if model.takes.takes.isEmpty {
                    HaloStatePlate(kind: .empty, title: "NO TAKES",
                                   reason: "RECORD A SESSION TO CAPTURE ONE.")
                } else {
                    VStack(spacing: HaloMetrics.s1) {
                        ForEach(model.takes.takes) { take in
                            TakeRow(take: take, reveal: { model.takes.reveal(take) })
                        }
                    }
                    RailCaption("DRAG A TAKE ONTO A MODEL PAD TO PREPARE IT")
                }
            }
        }
    }

    // MARK: - Panel 3 · LOCATION

    private var locationPanel: some View {
        HaloPanel("LOCATION") {
            VStack(alignment: .leading, spacing: HaloMetrics.s1) {
                RailDataRow("FOLDER", "~/…/HALO/RECORDINGS")
                Button("REVEAL FOLDER") { model.takes.revealFolder() }
                    .buttonStyle(MechanicalButtonStyle())
                    .focusable()
                    .help("Reveal the recordings folder in Finder")
            }
        }
    }
}

/// One draggable take card. Dragging registers the file URL (`.fileURL`), which the
/// existing `StageDropDelegate` already accepts: dropping onto a model pad opens the
/// prep sheet preselected to that pad — the exact same honest flow as a Finder drop.
/// No waveform is drawn (the summary cache is a later phase); the RAW tag states that
/// honestly rather than faking a wave.
private struct TakeRow: View {
    @Environment(\.halo) private var c
    let take: Take
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: HaloMetrics.s2) {
            // Hairline-outlined thumbnail block — a placeholder, not a fake wave.
            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                .fill(c.metal.opacity(0.30))
                .overlay(
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .stroke(c.ink.opacity(0.22), lineWidth: HaloMetrics.hairline))
                .overlay(
                    Text("RAW").font(HaloType.label(8)).haloLabelCase()
                        .foregroundStyle(c.inkSoft.opacity(0.8)))
                .frame(width: 44, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(take.title)
                    .font(HaloType.mono(11))
                    .foregroundStyle(c.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(HaloRecordFormat.takeSummary(take))
                    .font(HaloType.mono(9))
                    .foregroundStyle(c.inkSoft.opacity(0.85))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(HaloMetrics.s1)
        .background(
            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                .fill(c.paper.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .stroke(c.ink.opacity(0.18), lineWidth: HaloMetrics.hairline)))
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(contentsOf: take.url) ?? NSItemProvider()
        } preview: {
            TakeDragPreview(take: take)
        }
        .contextMenu {
            Button("Reveal in Finder", action: reveal)
        }
    }
}

/// The drag preview — a compact token card, not the whole row.
private struct TakeDragPreview: View {
    @Environment(\.halo) private var c
    let take: Take
    var body: some View {
        HStack(spacing: HaloMetrics.s1) {
            Text("RAW").font(HaloType.label(8)).haloLabelCase()
                .foregroundStyle(c.inkSoft)
            Text(take.title)
                .font(HaloType.mono(10))
                .foregroundStyle(c.ink)
        }
        .padding(.horizontal, HaloMetrics.s2)
        .padding(.vertical, HaloMetrics.s1)
        .background(
            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                .fill(c.paperHigh)
                .overlay(
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .stroke(c.ink.opacity(0.28), lineWidth: HaloMetrics.hairline)))
    }
}

#if DEBUG
#Preview("CaptureRail") {
    let model = HaloAppModel()
    // Seed the takes store with fixtures so the rail renders without real files.
    model.takes.seedPreview([
        .previewFixture("take-2026-07-13-2142-07.wav", duration: 92.4, bytes: 26_600_000),
        .previewFixture("take-2026-07-13-2109-55.wav", duration: 18.1, bytes: 5_200_000),
    ])
    return ScrollView {
        CaptureRail()
            .padding(HaloMetrics.s2)
    }
    .frame(width: 340, height: 640)
    .environment(model)
    .environment(\.halo, .graphPaper)
    .background(HaloColorTokens.graphPaper.paperHigh)
}
#endif
