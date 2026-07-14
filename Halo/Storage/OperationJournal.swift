import Foundation

/// The recoverable-writes journal (Brief §7/§8: the app *records a reversible
/// operation entry* for every device-affecting write). It is an append-only log
/// persisted as one human-readable versioned JSON document at
/// `Manifests/operation-journal.json`. Its job is crash safety: an operation is
/// journalled as `.pending` BEFORE the write begins and flipped to `.committed`
/// only after the write verifies. If halo dies mid-write, the pending entry —
/// and the local recovery copy it points at — survive relaunch, so the user can
/// recover instead of losing a sample.
///
/// HONESTY (Brief §1/§4): entries describe REAL operations. Device writes are the
/// proprietary protocol (Phase 0B) and are DEVICE-GATED, so the running app does
/// not yet originate device-write entries — the journal rests empty and is
/// exercised by unit tests. It is wired into the model now so the eventual device
/// layer records through one audited path. The journal never fabricates entries.
@MainActor
@Observable
final class OperationJournal {
    private(set) var entries: [OperationJournalEntry] = []

    /// Where the journal document lives. Injectable for tests.
    private let fileURL: URL

    init(fileURL: URL = HaloFileStore.url(.manifests)
            .appendingPathComponent(OperationJournal.fileName),
         loadOnInit: Bool = true) {
        self.fileURL = fileURL
        if loadOnInit { load() }
    }

    static let fileName = "operation-journal.json"

    /// Operations that began but never committed — the recoverable set surfaced to
    /// the user after a crash (Brief §8 resilience).
    var recoverable: [OperationJournalEntry] { entries.filter { $0.status == .pending } }

    /// Begin an operation: append a `.pending` entry and persist immediately, so
    /// the record exists on disk BEFORE the risky write starts. Returns the id
    /// used to `commit`/`rollback` it.
    @discardableResult
    func begin(kind: OperationJournalEntry.Kind,
               summary: String,
               recoveryPath: String? = nil,
               at date: Date = Date()) -> UUID {
        let entry = OperationJournalEntry(
            id: UUID(), startedAt: date, committedAt: nil,
            kind: kind, summary: summary, status: .pending, recoveryPath: recoveryPath)
        entries.append(entry)
        persist()
        return entry.id
    }

    /// Mark an operation committed (the write verified by read-back).
    func commit(_ id: UUID, at date: Date = Date()) {
        mutate(id) { $0.status = .committed; $0.committedAt = date }
    }

    /// Mark an operation rolled back (the write was undone / the recovery copy
    /// restored). Distinct from committed so recovery never re-offers it.
    func rollback(_ id: UUID, at date: Date = Date()) {
        mutate(id) { $0.status = .rolledBack; $0.committedAt = date }
    }

    /// Resolve every still-pending entry (e.g. after the user recovers them),
    /// marking them rolled back so they leave the recoverable set.
    func resolveAllPending(at date: Date = Date()) {
        for i in entries.indices where entries[i].status == .pending {
            entries[i].status = .rolledBack
            entries[i].committedAt = date
        }
        persist()
    }

    // MARK: - Persistence

    private func mutate(_ id: UUID, _ change: (inout OperationJournalEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = HaloJSON.decode(OperationJournalDocument.self, from: data) else {
            entries = []
            return
        }
        entries = doc.entries
    }

    private func persist() {
        let doc = OperationJournalDocument(entries: entries)
        guard let data = try? HaloJSON.encode(doc) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    #if DEBUG
    /// Preview/test-only seed (no disk write). The running app only gains entries
    /// through `begin`.
    func seedPreview(_ seed: [OperationJournalEntry]) { entries = seed }
    #endif
}

/// One recoverable write in the journal.
struct OperationJournalEntry: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    var committedAt: Date?
    let kind: Kind
    let summary: String
    var status: Status
    /// Path (relative to `Backups/`) of the local recovery copy that makes this
    /// operation reversible, or nil when the operation needs none. Brief §8: an
    /// overwrite/delete requires a local recovery copy.
    let recoveryPath: String?

    /// What the operation does to the device.
    enum Kind: String, Codable, Sendable {
        case deviceWrite    // upload a sample to a slot
        case deviceDelete   // delete a sample from the device
        case assign         // assign an existing sample to a pad
        case unassign       // remove a pad assignment (never deletes audio)
        case projectWrite   // write a project (gated until its format is verified)

        var label: String {
            switch self {
            case .deviceWrite:  return "WRITE"
            case .deviceDelete: return "DELETE"
            case .assign:       return "ASSIGN"
            case .unassign:     return "UNASSIGN"
            case .projectWrite: return "PROJECT WRITE"
            }
        }
    }

    enum Status: String, Codable, Sendable {
        case pending      // started, not yet verified — recoverable
        case committed    // verified by read-back
        case rolledBack   // undone / recovered
    }
}

/// The persisted journal document — one versioned wrapper so a migration can
/// branch on `schemaVersion` (Brief §8 versioned manifests).
struct OperationJournalDocument: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var entries: [OperationJournalEntry]

    init(entries: [OperationJournalEntry],
         schemaVersion: Int = OperationJournalDocument.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}
