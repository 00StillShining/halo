import SwiftUI

/// Stereo peak/RMS levels in dBFS. `-.infinity` means true silence. This is the
/// value the meter renders; in the running app it is always `.silence` (no audio
/// truth yet — Phase 2, DD-013). Deterministic non-silent levels appear ONLY in
/// `#Preview` blocks so the meter anatomy is reviewable — a meter that moved in the
/// running app would be a faked hardware state (automatic review failure).
struct StereoLevels: Equatable, Sendable {
    var rmsL, rmsR, peakL, peakR: Float      // dBFS; -.infinity = silence
    var clippedL, clippedR: Bool

    static let silence = StereoLevels(
        rmsL: -.infinity, rmsR: -.infinity,
        peakL: -.infinity, peakR: -.infinity,
        clippedL: false, clippedR: false)
}

/// A resting-or-live stereo peak/RMS meter. Full anatomy now, data later: Phase 2
/// wires `AudioLevelBridge`-fed values into this exact view and nothing else
/// changes. Colours/spacing/type all from the design tokens.
struct StereoMeter: View {
    @Environment(\.halo) private var c
    var levels: StereoLevels

    /// The tick dB values shown beneath the tracks; also the piecewise breakpoints.
    static let tickDBs: [Float] = [-40, -20, -12, -6, -3, 0]

    /// Map a dBFS value to a 0…1 track fraction. 0 at ≤ −40 dBFS, 1 at 0 dBFS,
    /// piecewise-linear per tick span so each tick sits where its label is. Pure —
    /// pinned by `StereoMeterTests`.
    static func fraction(dB: Float) -> CGFloat {
        guard let lowest = tickDBs.first else { return 0 }
        if dB <= lowest { return 0 }
        if dB >= 0 { return 1 }
        let count = tickDBs.count
        for i in 0..<(count - 1) {
            let lo = tickDBs[i], hi = tickDBs[i + 1]
            if dB >= lo, dB <= hi {
                let t = (dB - lo) / (hi - lo)
                let fLo = CGFloat(i) / CGFloat(count - 1)
                let fHi = CGFloat(i + 1) / CGFloat(count - 1)
                return fLo + CGFloat(t) * (fHi - fLo)
            }
        }
        return 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HaloMetrics.s1) {
            channel("L", rms: levels.rmsL, peak: levels.peakL, clipped: levels.clippedL)
            channel("R", rms: levels.rmsR, peak: levels.peakR, clipped: levels.clippedR)
            scale
        }
    }

    private func channel(_ name: String, rms: Float, peak: Float, clipped: Bool) -> some View {
        HStack(spacing: HaloMetrics.s1) {
            Text(name)
                .font(HaloType.mono(10))
                .foregroundStyle(c.inkSoft)
                .frame(width: 10, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                let rmsFrac = Self.fraction(dB: rms)
                let peakFrac = Self.fraction(dB: peak)
                ZStack(alignment: .leading) {
                    // Metal track with a hairline outline.
                    RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                        .fill(c.metal.opacity(0.38))
                        .overlay(
                            RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                                .stroke(c.ink.opacity(0.22), lineWidth: HaloMetrics.hairline))

                    // RMS fill.
                    if rmsFrac > 0 {
                        RoundedRectangle(cornerRadius: HaloMetrics.radiusSmall)
                            .fill(c.riddimGreen)
                            .frame(width: max(0, w * rmsFrac))
                    }

                    // Peak-hold tick (1.5 pt ink).
                    if peakFrac > 0 {
                        Rectangle()
                            .fill(c.ink.opacity(0.8))
                            .frame(width: 1.5)
                            .offset(x: min(w - 1.5, w * peakFrac - 0.75))
                    }

                    // Clip dot at the right end — unlit at rest.
                    HStack {
                        Spacer(minLength: 0)
                        Circle()
                            .fill(clipped ? c.warning : c.metal.opacity(0.5))
                            .frame(width: 5, height: 5)
                            .padding(.trailing, 2)
                    }
                }
            }
            .frame(height: 10)
        }
    }

    /// Tick marks + mono labels beneath the tracks at the breakpoint dB values.
    private var scale: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Array(Self.tickDBs.enumerated()), id: \.offset) { _, dB in
                    let x = 20 + (w - 20) * Self.fraction(dB: dB)
                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(c.ink.opacity(0.28))
                            .frame(width: HaloMetrics.hairline, height: 3)
                        Text(dB == 0 ? "0" : "\(Int(dB))")
                            .font(HaloType.mono(8))
                            .foregroundStyle(c.inkSoft.opacity(0.8))
                            .fixedSize()
                    }
                    .offset(x: x - 6)
                }
            }
        }
        .frame(height: 16)
    }
}

#if DEBUG
#Preview("StereoMeter — silence + demo") {
    VStack(spacing: 24) {
        StereoMeter(levels: .silence)
        StereoMeter(levels: StereoLevels(
            rmsL: -14, rmsR: -9, peakL: -6, peakR: -2,
            clippedL: false, clippedR: true))
    }
    .padding(32)
    .frame(width: 260)
    .haloPalette(.graphPaper)
    .environment(\.halo, .graphPaper)
    .background(HaloColorTokens.graphPaper.paper)
}
#endif
