import Foundation

/// Describes where the pixels on Halo's replica display came from. A USB
/// connection alone is deliberately not called `live`: live begins only after
/// Halo receives an observable EP-40 MIDI event.
enum EP40DisplayFeedMode: String, Sendable {
    case preview
    case waiting
    case live
}

/// The five labelled areas along the lower edge of the EP-40 display.
enum EP40DisplayMode: Int, CaseIterable, Sendable {
    case sound
    case main
    case tempo
    case erase
    case system
}

/// A small, device-agnostic snapshot consumed by the display renderer.
///
/// The documented USB MIDI surface cannot mirror the EP-40's actual menu or
/// screen. This state therefore contains only observed MIDI data, conservative
/// inferences (group from note range), and Halo-owned preview values.
struct EP40DisplayState: Equatable, Sendable {
    var feedMode: EP40DisplayFeedMode
    var mode: EP40DisplayMode
    var value: Int
    var activeGroup: Int?
    var activePadIndex: Int?
    var velocity: Float
    var leftMeter: Float
    var rightMeter: Float
    var isPlaying: Bool
    var clockPulse: Bool
    var activityStep: Int

    static let previewStill = EP40DisplayState(
        feedMode: .preview,
        mode: .sound,
        value: 40,
        activeGroup: 0,
        activePadIndex: 3,
        velocity: 0.72,
        leftMeter: 0.68,
        rightMeter: 0.52,
        isPlaying: true,
        clockPulse: true,
        activityStep: 0
    )

    static let waiting = EP40DisplayState(
        feedMode: .waiting,
        mode: .system,
        value: 0,
        activeGroup: nil,
        activePadIndex: nil,
        velocity: 0,
        leftMeter: 0,
        rightMeter: 0,
        isPlaying: false,
        clockPulse: false,
        activityStep: 0
    )

    static let liveIdle = EP40DisplayState(
        feedMode: .live,
        mode: .main,
        value: 0,
        activeGroup: nil,
        activePadIndex: nil,
        velocity: 0,
        leftMeter: 0,
        rightMeter: 0,
        isPlaying: false,
        clockPulse: false,
        activityStep: 0
    )

    mutating func clamp() {
        value = min(max(value, 0), 999)
        velocity = min(max(velocity, 0), 1)
        leftMeter = min(max(leftMeter, 0), 1)
        rightMeter = min(max(rightMeter, 0), 1)
        if let activeGroup { self.activeGroup = min(max(activeGroup, 0), 3) }
        if let activePadIndex { self.activePadIndex = min(max(activePadIndex, 0), 11) }
    }
}
