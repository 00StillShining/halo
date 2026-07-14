import CryptoKit
import Foundation

/// A dated device-backup snapshot descriptor (Brief §7 Backups). One snapshot is
/// a self-contained folder under `Backups/` holding this manifest (`manifest.json`)
/// beside the recovered sample files it references. Co-locating the manifest with
/// its payload keeps a snapshot legible and restorable straight from Finder — the
/// Brief §2 rule that the user's samples are *never recoverable only through halo*.
///
/// HONESTY (Brief §1/§4): a manifest `Entry` describes a real file that was read
/// off the EP-40 and written into the snapshot folder. Reading device samples is
/// the proprietary protocol (Phase 0B) and is DEVICE-GATED — halo cannot fabricate
/// entries, so a snapshot produced without a device has an empty `entries` array.
/// `BackupStore` only ever lists manifests that genuinely exist on disk.
struct BackupManifest: Codable, Sendable, Equatable, Identifiable {
    /// Current on-disk schema. Bump when the shape changes; older manifests keep
    /// their recorded version so a migration can branch on it.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let reason: Reason
    /// halo version that wrote the snapshot (provenance for a future migration).
    let appVersion: String
    /// Optional free-text note (e.g. why a manual snapshot was taken).
    var note: String?
    /// One entry per backed-up device sample. Empty until a real device read
    /// populates it — never fabricated.
    var entries: [Entry]

    init(id: UUID = UUID(),
         createdAt: Date = Date(),
         reason: Reason,
         appVersion: String = BackupManifest.hostAppVersion,
         note: String? = nil,
         entries: [Entry] = [],
         schemaVersion: Int = BackupManifest.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.reason = reason
        self.appVersion = appVersion
        self.note = note
        self.entries = entries
    }

    /// Total recovery bytes across all entries.
    var byteCount: Int { entries.reduce(0) { $0 + $1.byteCount } }

    /// The reason a snapshot was taken (Brief §7: exactly these three).
    enum Reason: String, Codable, Sendable, CaseIterable {
        case beforeWrite   // automatic, before the first device write of an operation
        case manual        // user pressed NEW SNAPSHOT
        case daily         // once-a-day safety snapshot

        var label: String {
            switch self {
            case .beforeWrite: return "BEFORE WRITE"
            case .manual:      return "MANUAL"
            case .daily:       return "DAILY"
            }
        }
    }

    /// Where the bytes in an entry came from. Only `.device` is a real backup
    /// source; the enum exists so an entry can never be silently assumed to be a
    /// device sample when it is not (Brief §1/§4).
    enum Provenance: String, Codable, Sendable {
        case device   // read off the EP-40 over the proprietary protocol (Phase 0B)
    }

    /// One backed-up sample. `fileName` is a path RELATIVE to the snapshot folder
    /// so the folder stays portable (movable, revealable) and the recovery copy is
    /// always beside the manifest.
    struct Entry: Codable, Sendable, Equatable, Identifiable {
        let id: UUID
        /// Device-side slot/library reference this sample occupied at snapshot time.
        let deviceSlot: String
        /// Known pad assignment at snapshot time, or nil when unknown. Brief §7
        /// safety: unknown references are labelled unknown, never assumed absent —
        /// a nil here MUST surface as "REFERENCES UNKNOWN", not "unassigned".
        let padReference: String?
        /// Recovery-copy filename inside the snapshot folder.
        let fileName: String
        let byteCount: Int
        /// SHA-256 of the recovery copy, for read-back verification on restore.
        let sha256: String
        let provenance: Provenance

        init(id: UUID = UUID(),
             deviceSlot: String,
             padReference: String?,
             fileName: String,
             byteCount: Int,
             sha256: String,
             provenance: Provenance = .device) {
            self.id = id
            self.deviceSlot = deviceSlot
            self.padReference = padReference
            self.fileName = fileName
            self.byteCount = byteCount
            self.sha256 = sha256
            self.provenance = provenance
        }
    }

    /// Short host-app version string for manifest provenance.
    static var hostAppVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v ?? "0.0"
    }

    /// Lowercased hex SHA-256 of arbitrary data (recovery-copy integrity).
    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
