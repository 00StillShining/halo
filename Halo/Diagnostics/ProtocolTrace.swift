import Foundation

/// The empty-by-construction scaffold for the EP-40 proprietary protocol trace
/// (Brief §7 diagnostics). No protocol exists yet (Phase 0B is device-gated), so
/// this holds no frames and has exactly ONE producer seam — `record(_:)`. A future
/// `EP40SysExTransport` will call it with frames it actually sent/received.
///
/// **Honesty guarantee (Brief §1/§4):** nothing else may append. The trace never
/// fabricates a frame, so an empty trace is the truthful rendering today.
@MainActor
@Observable
final class ProtocolTrace {
    struct Frame: Identifiable, Sendable, Equatable {
        enum Direction: String, Sendable { case tx = "TX", rx = "RX" }
        let id: UUID
        let timestamp: Date
        let direction: Direction
        let summary: String        // human label — never invented device semantics
        let bytes: [UInt8]         // raw, hex-rendered

        init(id: UUID = UUID(), timestamp: Date, direction: Direction,
             summary: String, bytes: [UInt8]) {
            self.id = id
            self.timestamp = timestamp
            self.direction = direction
            self.summary = summary
            self.bytes = bytes
        }
    }

    private(set) var frames: [Frame] = []
    private let capacity = 200

    /// The ONLY producer seam. Unused this phase (no protocol exists). A future
    /// verified SysEx transport calls this with really sent/received frames; nothing
    /// else may append — the trace never fabricates a frame (Brief §1/§4).
    func record(_ frame: Frame) {
        frames.append(frame)
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
    }

    func clear() { frames.removeAll() }

    var isEmpty: Bool { frames.isEmpty }
}
