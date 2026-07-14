import SwiftUI

/// BACKUPS rail (Brief §7). Lists the dated device snapshots that genuinely exist
/// under `Backups/`, offers Reveal in Finder, and gates restore behind a
/// plain-language confirmation. Old snapshots are never silently deleted — there
/// is no delete control here at all.
///
/// HONESTY (Brief §1/§4): creating a snapshot's PAYLOAD and restoring it both read
/// / write the EP-40 over the proprietary protocol (Phase 0B) and are
/// DEVICE-GATED. So NEW SNAPSHOT is disabled with the real reason, and a confirmed
/// restore reports honestly that it needs a connected device and changed nothing.
/// The list rests at NO SNAPSHOTS until a verified device layer exists — nothing
/// here claims a device write happened.
struct BackupsRail: View {
    @Environment(\.halo) private var c
    @Environment(HaloAppModel.self) private var model

    /// The snapshot the user has asked to restore (drives the confirmation dialog).
    @State private var pendingRestore: BackupManifest?
    /// Plain-language result line after a confirmed restore attempt.
    @State private var restoreNotice: String?

    private var backups: BackupStore { model.backups }
    private var journal: OperationJournal { model.journal }

    var body: some View {
        VStack(spacing: HaloMetrics.s2) {
            snapshotsPanel
            recoveryPanel
            locationPanel
        }
        .confirmationDialog(
            "Restore this snapshot to the EP-40?",
            isPresented: restoreDialogBinding,
            titleVisibility: .visible,
            presenting: pendingRestore
        ) { manifest in
            Button("Restore \(manifest.entries.count) sample\(manifest.entries.count == 1 ? "" : "s")", role: .destructive) {
                confirmRestore(manifest)
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: { manifest in
            Text("Restore overwrites the device's current samples with this snapshot from \(Self.longDate(manifest.createdAt)). Your local recovery copies are kept.")
        }
    }

    // MARK: - Panel 1 · SNAPSHOTS

    private var snapshotsPanel: some View {
        HaloPanel("SNAPSHOTS") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                if backups.snapshots.isEmpty {
                    RailCaption("NO SNAPSHOTS")
                } else {
                    VStack(spacing: HaloMetrics.s1) {
                        ForEach(backups.snapshots) { manifest in
                            SnapshotRow(
                                manifest: manifest,
                                reveal: { backups.reveal(manifest) },
                                restore: { pendingRestore = manifest })
                        }
                    }
                }

                Rectangle().fill(c.ink.opacity(0.12)).frame(height: HaloMetrics.hairline)

                // NEW SNAPSHOT reads the device — DEVICE-GATED (Phase 0B). Disabled
                // with the real reason so it never fakes a snapshot.
                Button("NEW SNAPSHOT") { }
                    .buttonStyle(MechanicalButtonStyle())
                    .disabled(true)
                RailCaption("NEW SNAPSHOT NEEDS A CONNECTED EP-40")

                // The three snapshot reasons (Brief §7), as inert legends.
                HStack(spacing: HaloMetrics.s1) {
                    RailTag("BEFORE WRITE")
                    RailTag("MANUAL")
                    RailTag("DAILY")
                }

                if let restoreNotice {
                    RailCaption(restoreNotice)
                }
            }
        }
    }

    // MARK: - Panel 2 · PENDING RECOVERY (Brief §8 recoverable writes)

    private var recoveryPanel: some View {
        HaloPanel("PENDING RECOVERY") {
            VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                if journal.recoverable.isEmpty {
                    RailCaption("NO PENDING OPERATIONS — ALL WRITES COMPLETED CLEANLY")
                } else {
                    VStack(spacing: HaloMetrics.s1) {
                        ForEach(journal.recoverable) { entry in
                            RailDataRow(entry.kind.label, Self.shortTime(entry.startedAt))
                        }
                    }
                    RailCaption("A WRITE DID NOT FINISH — YOUR LOCAL RECOVERY COPY IS SAFE")
                }
            }
        }
    }

    // MARK: - Panel 3 · LOCATION (Brief §2: never recoverable only through halo)

    private var locationPanel: some View {
        HaloPanel("LOCATION") {
            VStack(alignment: .leading, spacing: HaloMetrics.s1) {
                RailDataRow("FOLDER", HaloFileStore.Folder.backups.displayPath)
                Button("REVEAL FOLDER") { backups.revealFolder() }
                    .buttonStyle(MechanicalButtonStyle())
                RailCaption("SNAPSHOTS ARE PLAIN FILES — OPENABLE WITHOUT HALO")
            }
        }
    }

    // MARK: - Restore flow

    private var restoreDialogBinding: Binding<Bool> {
        Binding(get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } })
    }

    private func confirmRestore(_ manifest: BackupManifest) {
        pendingRestore = nil
        restoreNotice = nil
        let restorer = model.restorer
        Task { @MainActor in
            let result = await restorer.restore(manifest)
            restoreNotice = result.message
        }
    }

    static func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: date)
    }

    static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm"
        return f.string(from: date).uppercased()
    }
}

/// One snapshot card: date + reason tag + entry count, with Reveal and a Restore
/// control that opens the confirmation dialog. No delete control — Brief §7:
/// *never silently delete old backups* (and no destructive default anywhere).
private struct SnapshotRow: View {
    @Environment(\.halo) private var c
    let manifest: BackupManifest
    let reveal: () -> Void
    let restore: () -> Void

    private var entryLine: String {
        let n = manifest.entries.count
        let bytes = HaloRecordFormat.bytes(Int64(manifest.byteCount))
        return n == 0 ? "0 SAMPLES" : "\(n) SAMPLE\(n == 1 ? "" : "S") · \(bytes)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HaloMetrics.s1) {
            HStack(spacing: HaloMetrics.s1) {
                Text(BackupsRail.longDate(manifest.createdAt))
                    .font(HaloType.mono(11))
                    .foregroundStyle(c.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                RailTag(manifest.reason.label)
            }
            Text(entryLine)
                .font(HaloType.mono(9))
                .foregroundStyle(c.inkSoft.opacity(0.85))
            HStack(spacing: HaloMetrics.s1) {
                Button("REVEAL", action: reveal)
                    .buttonStyle(MechanicalButtonStyle())
                Button("RESTORE", action: restore)
                    .buttonStyle(MechanicalButtonStyle())
            }
        }
        .padding(HaloMetrics.s1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                .fill(c.paper.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .stroke(c.ink.opacity(0.18), lineWidth: HaloMetrics.hairline)))
        .contextMenu {
            Button("Reveal in Finder", action: reveal)
        }
    }
}

#if DEBUG
#Preview("BackupsRail — empty") {
    let model = HaloAppModel()
    return ScrollView {
        BackupsRail().padding(HaloMetrics.s2)
    }
    .frame(width: 340, height: 640)
    .environment(model)
    .environment(\.halo, .graphPaper)
    .background(HaloColorTokens.graphPaper.paperHigh)
}

#Preview("BackupsRail — seeded") {
    let model = HaloAppModel()
    model.backups.seedPreview([
        BackupManifest(
            createdAt: Date(timeIntervalSince1970: 1_752_400_000),
            reason: .beforeWrite,
            entries: [
                .init(deviceSlot: "A/03", padReference: "GROUP A · PAD 3",
                      fileName: "a03.wav", byteCount: 512_000, sha256: "deadbeef"),
            ]),
        BackupManifest(
            createdAt: Date(timeIntervalSince1970: 1_752_300_000),
            reason: .manual, entries: []),
    ])
    return ScrollView {
        BackupsRail().padding(HaloMetrics.s2)
    }
    .frame(width: 340, height: 640)
    .environment(model)
    .environment(\.halo, .bonePaper)
    .background(HaloColorTokens.bonePaper.paperHigh)
}
#endif
