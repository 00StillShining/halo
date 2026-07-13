import Foundation

/// A deterministic twelve-second demo. It is intentionally stepped like an
/// instrument readout rather than a decorative random animation.
enum EP40DisplayPreviewSource {
    static let framesPerSecond = 6

    static func frame(at tick: Int) -> EP40DisplayState {
        let safeTick = max(tick, 0)
        let beat = safeTick / 3
        let phraseBeat = beat % 24
        let mode = EP40DisplayMode.allCases[(phraseBeat / 5) % EP40DisplayMode.allCases.count]
        let values = [40, 72, 96, 120, 83, 64, 108, 77]
        let meterPattern: [Float] = [0.12, 0.46, 0.82, 0.30, 0.66, 0.96, 0.42, 0.74]
        let index = phraseBeat % values.count
        let pulse = safeTick.isMultiple(of: 3)
        let decay = Float(2 - safeTick % 3) * 0.08

        return EP40DisplayState(
            feedMode: .preview,
            mode: mode,
            value: values[index],
            activeGroup: (phraseBeat / 6) % 4,
            activePadIndex: phraseBeat % 12,
            velocity: min(meterPattern[index] + decay, 1),
            leftMeter: min(meterPattern[index] + decay, 1),
            rightMeter: min(meterPattern[(index + 3) % meterPattern.count] * 0.84 + decay, 1),
            isPlaying: true,
            clockPulse: pulse,
            activityStep: phraseBeat
        )
    }
}
