import XCTest
@testable import Halo

/// Pins the storage layer (Brief §7/§8): versioned human-readable manifests,
/// backup-snapshot round-trip through disk, and operation-journal recovery. All
/// LOCAL — no device. Device restore itself is NEEDS-DEVICE and only its honest
/// `.deviceRequired` seam is asserted here.
final class StorageManifestTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-storage-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    // MARK: - BackupManifest round-trip

    func testBackupManifestRoundTripsUnchanged() throws {
        let original = BackupManifest(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_752_400_000),
            reason: .beforeWrite,
            appVersion: "1.2",
            note: "before overwrite A/03",
            entries: [
                .init(deviceSlot: "A/03", padReference: "GROUP A · PAD 3",
                      fileName: "a03.wav", byteCount: 512_000, sha256: "abc123"),
                .init(deviceSlot: "B/07", padReference: nil,
                      fileName: "b07.wav", byteCount: 64_000, sha256: "def456"),
            ])

        let data = try HaloJSON.encode(original)
        let decoded = try XCTUnwrap(HaloJSON.decode(BackupManifest.self, from: data))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.schemaVersion, BackupManifest.currentSchemaVersion)
        XCTAssertEqual(decoded.byteCount, 576_000)
        // A nil padReference must survive as nil (Brief §7: unknown, not "absent").
        XCTAssertNil(decoded.entries[1].padReference)
    }

    func testManifestJSONIsHumanReadableAndVersioned() throws {
        let m = BackupManifest(reason: .daily)
        let text = try XCTUnwrap(String(data: HaloJSON.encode(m), encoding: .utf8))
        // Pretty-printed (newlines), stores the schema version and the reason as a
        // legible string — a person can read/diff it without halo.
        XCTAssertTrue(text.contains("\n"))
        XCTAssertTrue(text.contains("\"schemaVersion\""))
        XCTAssertTrue(text.contains("\"daily\""))
    }

    func testReasonLabelsMatchBrief() {
        XCTAssertEqual(BackupManifest.Reason.beforeWrite.label, "BEFORE WRITE")
        XCTAssertEqual(BackupManifest.Reason.manual.label, "MANUAL")
        XCTAssertEqual(BackupManifest.Reason.daily.label, "DAILY")
        XCTAssertEqual(Set(BackupManifest.Reason.allCases.map(\.label)),
                       ["BEFORE WRITE", "MANUAL", "DAILY"])
    }

    func testSHA256HexIsStableAndLowercase() {
        let hex = BackupManifest.sha256Hex(of: Data("halo".utf8))
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(hex, hex.lowercased())
        XCTAssertEqual(hex, BackupManifest.sha256Hex(of: Data("halo".utf8)))
    }

    // MARK: - BackupStore persistence

    @MainActor
    func testBackupStoreWritesAndReloadsFromDisk() throws {
        let dir = tempDir(); defer { remove(dir) }
        let store = BackupStore(backupsDir: dir, scanOnInit: false)
        let m = BackupManifest(reason: .manual, note: "manual snapshot")
        let folder = try store.write(m)

        // Manifest JSON lands beside its (future) payload in the snapshot folder.
        let manifestURL = folder.appendingPathComponent(BackupStore.manifestFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertEqual(store.snapshots.map(\.id), [m.id])

        // A fresh store scanning the same dir recovers the snapshot.
        let reloaded = BackupStore(backupsDir: dir, scanOnInit: true)
        XCTAssertEqual(reloaded.snapshots.map(\.id), [m.id])
        XCTAssertEqual(reloaded.snapshots.first?.reason, .manual)
    }

    @MainActor
    func testBackupStoreListsNewestFirstAndDropsUnreadable() throws {
        let dir = tempDir(); defer { remove(dir) }
        let store = BackupStore(backupsDir: dir, scanOnInit: false)
        let older = BackupManifest(createdAt: Date(timeIntervalSince1970: 1_000),
                                   reason: .daily)
        let newer = BackupManifest(createdAt: Date(timeIntervalSince1970: 2_000),
                                   reason: .beforeWrite)
        try store.write(older)
        try store.write(newer)

        // A foreign folder with a garbage manifest must be dropped, not faked.
        let junk = dir.appendingPathComponent("not-a-snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("{ nonsense".utf8).write(
            to: junk.appendingPathComponent(BackupStore.manifestFileName))

        let reloaded = BackupStore(backupsDir: dir, scanOnInit: true)
        XCTAssertEqual(reloaded.snapshots.map(\.id), [newer.id, older.id])
    }

    // MARK: - Restore seam (NEEDS-DEVICE)

    func testDeviceUnavailableRestorerNeverClaimsAWrite() async {
        let result = await DeviceUnavailableRestorer().restore(BackupManifest(reason: .manual))
        XCTAssertEqual(result, .deviceRequired)
        XCTAssertTrue(result.message.contains("NOTHING WAS CHANGED"))
    }

    // MARK: - OperationJournal recovery

    @MainActor
    func testJournalBeginMarksRecoverableAndPersists() throws {
        let dir = tempDir(); defer { remove(dir) }
        let file = dir.appendingPathComponent(OperationJournal.fileName)
        let journal = OperationJournal(fileURL: file, loadOnInit: false)
        let id = journal.begin(kind: .deviceWrite, summary: "upload amen -> A/03",
                               recoveryPath: "snap/a03.wav")

        XCTAssertEqual(journal.recoverable.map(\.id), [id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // A crash is simulated by loading a fresh journal from the same file: the
        // pending write is still recoverable, with its recovery copy path intact.
        let recovered = OperationJournal(fileURL: file, loadOnInit: true)
        XCTAssertEqual(recovered.recoverable.map(\.id), [id])
        XCTAssertEqual(recovered.recoverable.first?.recoveryPath, "snap/a03.wav")
    }

    @MainActor
    func testJournalCommitLeavesRecoverableSet() throws {
        let dir = tempDir(); defer { remove(dir) }
        let file = dir.appendingPathComponent(OperationJournal.fileName)
        let journal = OperationJournal(fileURL: file, loadOnInit: false)
        let id = journal.begin(kind: .assign, summary: "assign A/03 -> pad 3")
        journal.commit(id)

        XCTAssertTrue(journal.recoverable.isEmpty)
        let reloaded = OperationJournal(fileURL: file, loadOnInit: true)
        XCTAssertTrue(reloaded.recoverable.isEmpty)
        XCTAssertEqual(reloaded.entries.first?.status, .committed)
        XCTAssertNotNil(reloaded.entries.first?.committedAt)
    }

    @MainActor
    func testJournalRollbackAndResolveAllClearRecoverable() throws {
        let dir = tempDir(); defer { remove(dir) }
        let file = dir.appendingPathComponent(OperationJournal.fileName)
        let journal = OperationJournal(fileURL: file, loadOnInit: false)
        let a = journal.begin(kind: .deviceDelete, summary: "delete B/07")
        _ = journal.begin(kind: .deviceWrite, summary: "write C/01")
        journal.rollback(a)
        XCTAssertEqual(journal.recoverable.count, 1)   // only the write remains pending

        journal.resolveAllPending()
        XCTAssertTrue(journal.recoverable.isEmpty)
        XCTAssertTrue(journal.entries.allSatisfy { $0.status == .rolledBack })
    }

    // MARK: - Journal document versioning

    func testJournalDocumentRoundTripsWithSchemaVersion() throws {
        let doc = OperationJournalDocument(entries: [
            .init(id: UUID(), startedAt: Date(timeIntervalSince1970: 10),
                  committedAt: nil, kind: .unassign, summary: "unassign pad 5",
                  status: .pending, recoveryPath: nil),
        ])
        let data = try HaloJSON.encode(doc)
        let decoded = try XCTUnwrap(HaloJSON.decode(OperationJournalDocument.self, from: data))
        XCTAssertEqual(decoded, doc)
        XCTAssertEqual(decoded.schemaVersion, OperationJournalDocument.currentSchemaVersion)
    }

    // MARK: - HaloFileStore layout

    func testFileStoreResolvesFiveCanonicalFoldersUnderHalo() {
        XCTAssertEqual(Set(HaloFileStore.Folder.allCases.map(\.rawValue)),
                       ["Library", "Backups", "Recordings", "Manifests", "Diagnostics"])
        let backups = HaloFileStore.url(.backups)
        XCTAssertEqual(backups.lastPathComponent, "Backups")
        XCTAssertEqual(backups.deletingLastPathComponent().lastPathComponent, "Halo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups.path))
    }
}
