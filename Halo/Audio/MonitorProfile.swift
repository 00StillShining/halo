import Foundation

/// The three exposed IO buffer profiles (Brief §8: "Start with a 256-frame safety
/// profile; test 128/256/512 and expose only `LOW`, `BALANCED`, `SAFE`").
///
/// Lower frame counts mean lower latency but a tighter real-time deadline (more
/// risk of dropouts); higher counts are safer but laggier. `balanced` (256) is the
/// documented default safety profile.
enum MonitorProfile: String, CaseIterable, Sendable, Identifiable {
    case low        // 128 frames — lowest latency, tightest deadline
    case balanced   // 256 frames — default safety profile
    case safe       // 512 frames — most headroom against dropouts

    var id: String { rawValue }

    /// Preferred IO buffer size in frames.
    var frames: UInt32 {
        switch self {
        case .low: return 128
        case .balanced: return 256
        case .safe: return 512
        }
    }

    /// Short uppercase label for the UI (tokens/type applied by the view).
    var label: String {
        switch self {
        case .low: return "LOW"
        case .balanced: return "BALANCED"
        case .safe: return "SAFE"
        }
    }

    /// The default profile halo starts a route with.
    static let `default`: MonitorProfile = .balanced

    /// Clamp the requested frame size into a device's supported IO buffer range so
    /// we never ask for something the hardware rejects (Brief §8 buffer-range
    /// discovery). Pure — pinned by `MonitorProfileTests`.
    func frames(clampedTo range: AudioDevice.BufferFrameRange?) -> UInt32 {
        guard let range else { return frames }
        return min(max(frames, range.minFrames), range.maxFrames)
    }
}
