import AVFoundation
import Foundation
import AppKit

/// One captured session recording. Every field is REAL — read from the file on
/// disk via `AVAudioFile`/`FileManager` (Brief §1/§4 honesty); nothing is invented.
/// Persistence IS the file: there is no separate database, so takes survive relaunch
/// simply by scanning the Recordings directory.
/// How a take was captured. Derived from the on-disk filename (persistence IS the
/// file, DD-029) — a `grab-` prefix marks an instant loop grab, everything else a
/// session recording. No sidecar DB, so the kind survives relaunch by directory scan.
enum TakeKind: Sendable, Equatable, Hashable {
    case session
    case grab
}

struct Take: Identifiable, Sendable, Equatable, Hashable {
    let id: UUID
    let url: URL
    let createdAt: Date
    let durationSeconds: Double   // frames / sampleRate — REAL, from the file
    let sampleRate: Int
    let channels: Int
    let bytes: Int
    var title: String
    var kind: TakeKind = .session

    #if DEBUG
    /// Memberwise fixture for previews only (no real file required).
    static func previewFixture(_ name: String, duration: Double, bytes: Int,
                               kind: TakeKind = .session) -> Take {
        Take(id: UUID(), url: URL(fileURLWithPath: "/tmp/\(name)"),
             createdAt: Date(timeIntervalSince1970: 1_752_400_000),
             durationSeconds: duration, sampleRate: 48_000, channels: 2,
             bytes: bytes, title: name.uppercased(), kind: kind)
    }
    #endif
}

/// The local library of captured takes (newest first). @MainActor @Observable so
/// the Capture rail updates as takes are ingested. Reads real file metadata on
/// ingest and on init (directory scan) — a half-written or foreign file that cannot
/// be reopened is dropped (parity with `PrepMetadata.init?`), never turned into an
/// invented row.
@MainActor
@Observable
final class TakesStore {
    private(set) var takes: [Take] = []

    init(scanOnInit: Bool = true) {
        if scanOnInit { loadFromDisk() }
    }

    /// Directory the recorder writes into and this store scans. Resolved through
    /// the single filesystem authority (`HaloFileStore`) so the canonical layout
    /// is named in exactly one place. Unsandboxed app, so this path is directly
    /// writable.
    nonisolated static func recordingsDir() -> URL {
        HaloFileStore.url(.recordings)
    }

    /// Ingest a just-finished take (called after the drain has fully flushed and
    /// closed the file). Reads real metadata; a nil read is silently skipped.
    func ingest(url: URL) {
        guard let take = Self.readTake(url) else { return }
        takes.removeAll { $0.url == take.url }
        takes.insert(take, at: 0)
    }

    /// Reveal a take in Finder.
    func reveal(_ take: Take) {
        NSWorkspace.shared.activateFileViewerSelecting([take.url])
    }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.recordingsDir()])
    }

    private func loadFromDisk() {
        let dir = Self.recordingsDir()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let loaded = urls
            .filter { $0.pathExtension.lowercased() == "wav" }
            .compactMap { Self.readTake($0) }
            .sorted { $0.createdAt > $1.createdAt }
        takes = loaded
    }

    /// Decode REAL metadata for a WAV on disk. Returns nil for anything unreadable,
    /// so a foreign or partial file never becomes a fabricated take (Brief §1/§4).
    nonisolated static func readTake(_ url: URL) -> Take? {
        guard let audio = try? AVAudioFile(forReading: url) else { return nil }
        let format = audio.fileFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return nil }
        let frames = audio.length
        let duration = Double(frames) / sampleRate

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        let created = (attrs?[.creationDate] as? Date) ?? Date()

        // A `grab-` filename is a GRAB take; its bars/bpm come straight from the
        // filename (real computed values, DD-029), never invented. Anything else is a
        // session recording titled by its creation time.
        let name = url.lastPathComponent
        let grabTitle = GrabMath.title(fromFilename: name)
        let kind: TakeKind = grabTitle != nil ? .grab : .session

        return Take(
            id: UUID(),
            url: url,
            createdAt: created,
            durationSeconds: duration,
            sampleRate: Int(sampleRate.rounded()),
            channels: Int(format.channelCount),
            bytes: bytes,
            title: grabTitle ?? Self.title(for: created),
            kind: kind)
    }

    nonisolated static func title(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "TAKE · " + f.string(from: date)
    }

    #if DEBUG
    /// Preview/test-only seed. The running app only ever gains takes through
    /// `ingest`, which reads a real file — this exists so a `#Preview` renders the
    /// takes list without recording anything.
    func seedPreview(_ fixtures: [Take]) { takes = fixtures }
    #endif
}
