import AppKit
import Foundation

/// The single authority for halo's on-disk layout under
/// `~/Library/Application Support/Halo/` (Brief §2/§8). Every subsystem that
/// touches the filesystem resolves its directory here, so the five canonical
/// folders — `Library`, `Backups`, `Recordings`, `Manifests`, `Diagnostics` —
/// are named in exactly one place and created on demand.
///
/// The app is unsandboxed and single-machine (DD-003), so these paths are
/// directly writable and directly openable in Finder. That is deliberate and
/// load-bearing for the Brief §2 rule: *never make the user's samples
/// recoverable only through halo*. Everything halo writes lives in plain,
/// user-navigable folders, and the manifests beside them are human-readable
/// versioned JSON (see `HaloJSON`), not an opaque database.
enum HaloFileStore {

    /// The five canonical subfolders (Brief §8). Raw values are the on-disk
    /// folder names — treat as a frozen contract.
    enum Folder: String, CaseIterable, Sendable {
        case library = "Library"          // imported/prepared LOCAL samples
        case backups = "Backups"          // device snapshots (payload + manifest)
        case recordings = "Recordings"    // session takes and loop grabs
        case manifests = "Manifests"      // versioned Codable JSON (journal, indices)
        case diagnostics = "Diagnostics"  // protocol traces, capability evidence, logs

        /// Human-facing short path shown in the UI (never a hard-coded string at
        /// a call site — the LOCATION rows read this).
        var displayPath: String { "~/…/HALO/\(rawValue.uppercased())" }
    }

    /// `~/Library/Application Support/Halo`. Falls back to the temporary
    /// directory only if Application Support cannot be resolved (parity with the
    /// existing recordings path, `Take.swift`) so a missing directory never
    /// crashes — it degrades to a writable location.
    nonisolated static func root() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Halo", isDirectory: true)
    }

    /// Resolve a canonical folder, creating it (and `Halo/`) if absent.
    nonisolated static func url(_ folder: Folder) -> URL {
        let dir = root().appendingPathComponent(folder.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Create every canonical folder up front (called once at launch so the
    /// layout exists before any subsystem writes into it).
    nonisolated static func ensureAll() {
        for folder in Folder.allCases { _ = url(folder) }
    }

    // MARK: - Finder reveal (Brief §7: "Reveal in Finder")

    /// Reveal a specific file/folder, selecting it in its parent.
    @MainActor static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open one of the canonical folders in Finder.
    @MainActor static func revealFolder(_ folder: Folder) {
        NSWorkspace.shared.activateFileViewerSelecting([url(folder)])
    }
}

/// Shared JSON coders for every halo manifest (Brief §8: *readable versioned
/// `Codable` JSON manifests rather than a database*). Pretty-printed with sorted
/// keys so a manifest is diff-friendly and legible in any text editor, and
/// ISO-8601 dates so timestamps are unambiguous across locales. Using one coder
/// pair everywhere guarantees every manifest on disk shares the same shape.
enum HaloJSON {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Encode any manifest to human-readable data.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    /// Decode a manifest, returning nil for anything unreadable or foreign so a
    /// corrupt/partial file is dropped rather than turned into invented state
    /// (Brief §1/§4 honesty — same discipline as `TakesStore.readTake`).
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder().decode(type, from: data)
    }
}
