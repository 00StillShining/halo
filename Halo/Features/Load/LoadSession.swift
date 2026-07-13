import AVFoundation
import Foundation

/// LOAD-mode UI state (Brief §7). UI-only, the same honesty class as `mode` /
/// `isPlayRailCollapsed` (DD-013): nothing here touches `displayState`,
/// `ringState`, or any MIDI path, so a mode round-trip through LOAD can never
/// disturb PREVIEW / WAIT / LIVE provenance. The library it reads is the ONE
/// deterministic MOCK instance — real device reads need the verified protocol
/// (Phase 0B) and are out of scope.
@MainActor
@Observable
final class LoadSession {

    enum Tab: String, CaseIterable { case pads = "PADS", sounds = "SOUNDS" }

    var tab: Tab = .pads
    var selectedGroup = 0                          // 0…3 = A…D
    var selectedGridIndex: Int? = nil              // PADS board selection
    var selectedSlot: SampleSlotID? = nil          // SOUNDS table selection
    private(set) var prep: PrepRequest? = nil

    /// The single mock source of truth for this session.
    let library = MockDeviceLibrary.standard

    // MARK: - Preparation sheet

    /// Begin sample preparation from a drop. Reads real metadata from the file; a
    /// non-decodable file is rejected before the sheet opens (no invented data). A
    /// pad drop passes the resolved pad; a global Finder drop passes `nil`.
    func beginPreparation(fileURL: URL, padHint: EP40Entity?) {
        guard let meta = PrepMetadata(fileURL: fileURL) else { return }  // reject unreadable
        let gridIndex = padHint.flatMap { EP40Entity.padGridOrder.firstIndex(of: $0) }
        // A pad drop resolves to a physical pad (grid index); the *group* is a UI
        // concept here (pads are one physical set), so it follows the rail's
        // current group — no claim about the device's actual current group.
        prep = PrepRequest(
            fileURL: fileURL,
            metadata: meta,
            destinationGroup: selectedGroup,
            destinationGridIndex: gridIndex,
            treatment: .original)
    }

    func cancelPreparation() { prep = nil }

    /// Mutating helpers used by the prep sheet (the request is `private(set)`).
    func setPrepGroup(_ group: Int) { prep?.destinationGroup = group }
    func setPrepGridIndex(_ index: Int?) { prep?.destinationGridIndex = index }
    func setPrepTreatment(_ treatment: Treatment) { prep?.treatment = treatment }

    #if DEBUG
    /// Preview/test-only injection. The running app creates a request ONLY through
    /// `beginPreparation`, which decodes real file metadata — this exists so a
    /// `#Preview` can show the sheet without a real audio file on disk.
    func injectPreviewPrep(_ request: PrepRequest) { prep = request }
    #endif
}

// MARK: - Preparation request

/// Storage-treatment choice (Brief §7 workflow step 3). Size impact is a pure,
/// clearly-`EST` function — nothing is claimed about the actual on-device encode.
enum Treatment: String, CaseIterable, Sendable {
    case original = "ORIGINAL"
    case high     = "HIGH"
    case balanced = "BALANCED"
    case lofi     = "LO-FI"

    /// Estimated stored bytes for a source. HIGH/BALANCED/LO-FI model resample to
    /// the EP-40's documented on-device rates; LO-FI also folds to mono.
    func estimatedBytes(source: PrepMetadata) -> Int {
        switch self {
        case .original: return source.bytes
        case .high:     return source.resampledBytes(rate: 46875, channels: source.channels)
        case .balanced: return source.resampledBytes(rate: 32000, channels: source.channels)
        case .lofi:     return source.resampledBytes(rate: 26250, channels: 1)
        }
    }
}

/// Real, honest metadata decoded from the dropped file. Not mock.
struct PrepMetadata: Sendable, Equatable {
    let displayName: String
    let durationSeconds: Double
    let sampleRate: Int
    let channels: Int
    let bytes: Int

    /// Decode via `AVAudioFile`. Returns nil for anything not a supported audio
    /// file — the caller then declines to open the sheet (no invented metadata).
    init?(fileURL: URL) {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let format = file.fileFormat
        let frames = file.length
        let rate = format.sampleRate > 0 ? format.sampleRate : 44100
        self.displayName = fileURL.lastPathComponent
        self.durationSeconds = Double(frames) / rate
        self.sampleRate = Int(rate.rounded())
        self.channels = Int(format.channelCount)
        let size = (try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        self.bytes = size ?? Int(Double(frames) * Double(format.channelCount) * 2)
    }

    /// Memberwise init for previews/tests (no file required).
    init(displayName: String, durationSeconds: Double,
         sampleRate: Int, channels: Int, bytes: Int) {
        self.displayName = displayName
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channels = channels
        self.bytes = bytes
    }

    func resampledBytes(rate: Int, channels: Int) -> Int {
        Int((durationSeconds * Double(rate) * Double(channels) * 2).rounded())
    }
}

/// A pending preparation. Destination context is MOCK (project/slot are mock);
/// the file metadata is real. `SEND + ASSIGN` is a future device write (Phase 0B)
/// and is disabled — this struct never triggers a transfer.
struct PrepRequest: Sendable, Equatable {
    let fileURL: URL
    let metadata: PrepMetadata
    var destinationGroup: Int
    var destinationGridIndex: Int?
    var treatment: Treatment
}
