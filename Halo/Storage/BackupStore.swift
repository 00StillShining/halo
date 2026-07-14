import Foundation

/// The local index of device-backup snapshots (Brief §7 Backups). Each snapshot
/// is a dated folder under `Backups/` containing a `manifest.json` beside its
/// recovery copies. This store scans that directory, decodes the manifests, and
/// presents them newest-first — persistence IS the folder tree, so snapshots
/// survive relaunch by rescanning (identical discipline to `TakesStore`).
///
/// HONESTY (Brief §1/§4): the running app only gains snapshots through `write`,
/// which persists a manifest the caller supplies. Creating the PAYLOAD of a real
/// snapshot (reading samples off the EP-40) is the proprietary protocol (Phase
/// 0B) and is DEVICE-GATED, so in normal use this list is empty until a verified
/// device layer exists. The store never invents a snapshot.
@MainActor
@Observable
final class BackupStore {
    private(set) var snapshots: [BackupManifest] = []

    /// Base `Backups/` directory. Injectable so unit tests round-trip in a temp
    /// dir without touching the real Application Support tree.
    private let backupsDir: URL

    /// Manifest filename inside each snapshot folder.
    static let manifestFileName = "manifest.json"

    init(backupsDir: URL = HaloFileStore.url(.backups), scanOnInit: Bool = true) {
        self.backupsDir = backupsDir
        if scanOnInit { load() }
    }

    /// Folder for a snapshot: `Backups/<createdAt-reason-id>/`. The name is
    /// human-sortable (timestamp first) and self-describing in Finder.
    func folder(for manifest: BackupManifest) -> URL {
        backupsDir.appendingPathComponent(Self.folderName(for: manifest), isDirectory: true)
    }

    static func folderName(for manifest: BackupManifest) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = f.string(from: manifest.createdAt)
        return "\(stamp)-\(manifest.reason.rawValue)-\(manifest.id.uuidString.prefix(8))"
    }

    /// Rescan `Backups/` and decode every `manifest.json`. Unreadable or foreign
    /// folders are dropped, never turned into a fabricated row (Brief §1/§4).
    func load() {
        let subdirs = (try? FileManager.default.contentsOfDirectory(
            at: backupsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let loaded: [BackupManifest] = subdirs.compactMap { dir in
            let manifestURL = dir.appendingPathComponent(Self.manifestFileName)
            guard let data = try? Data(contentsOf: manifestURL) else { return nil }
            return HaloJSON.decode(BackupManifest.self, from: data)
        }
        snapshots = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    /// Persist a snapshot manifest into its folder and insert it into the live
    /// list. The caller owns writing the recovery copies the manifest references
    /// (device reads, DEVICE-GATED); this method only writes the manifest JSON.
    /// Returns the snapshot folder URL.
    @discardableResult
    func write(_ manifest: BackupManifest) throws -> URL {
        let dir = folder(for: manifest)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try HaloJSON.encode(manifest)
        try data.write(to: dir.appendingPathComponent(Self.manifestFileName), options: .atomic)
        snapshots.removeAll { $0.id == manifest.id }
        snapshots.insert(manifest, at: 0)
        snapshots.sort { $0.createdAt > $1.createdAt }
        return dir
    }

    // MARK: - Reveal (Brief §7)

    func reveal(_ manifest: BackupManifest) {
        HaloFileStore.reveal(folder(for: manifest))
    }

    func revealFolder() {
        HaloFileStore.reveal(backupsDir)
    }

    #if DEBUG
    /// Preview/test-only seed. The running app only gains snapshots through
    /// `write`; this exists so a `#Preview` renders the list without a device.
    func seedPreview(_ manifests: [BackupManifest]) {
        snapshots = manifests.sorted { $0.createdAt > $1.createdAt }
    }
    #endif
}

/// The device-restore seam (Brief §7: *restore only after plain-language
/// confirmation*). Writing recovered samples back onto the EP-40 is the
/// proprietary protocol (Phase 0B) and is DEVICE-GATED — halo must not invent
/// protocol bytes or claim a write happened. This protocol lets the confirmed
/// restore flow call into a device layer once one exists, and lets the UI stay
/// honest today via `DeviceUnavailableRestorer`.
protocol BackupRestoring: Sendable {
    /// Attempt to restore a snapshot onto the connected device. Implementations
    /// must verify by read-back before reporting `.restored` (Brief §7 workflow).
    func restore(_ manifest: BackupManifest) async -> BackupRestoreResult
}

enum BackupRestoreResult: Equatable, Sendable {
    case restored(entryCount: Int)
    /// No verified device layer / no connected device — nothing was changed.
    case deviceRequired
    case failed(reason: String)

    /// Plain-language line for the rail (Brief §7). Never claims a device change
    /// that did not happen.
    var message: String {
        switch self {
        case let .restored(n):  return "RESTORED \(n) SAMPLE\(n == 1 ? "" : "S") — VERIFIED BY READ-BACK"
        case .deviceRequired:   return "RESTORE NEEDS A CONNECTED EP-40 — NOTHING WAS CHANGED"
        case let .failed(r):    return "RESTORE FAILED — \(r) — NOTHING WAS CHANGED"
        }
    }
}

/// Honest default until the Phase 0B device layer lands: every restore reports
/// `.deviceRequired` and changes nothing. NEEDS-DEVICE.
struct DeviceUnavailableRestorer: BackupRestoring {
    func restore(_ manifest: BackupManifest) async -> BackupRestoreResult {
        .deviceRequired
    }
}
