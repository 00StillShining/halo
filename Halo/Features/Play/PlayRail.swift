import SwiftUI

/// PLAY rail scaffold (Brief §7). Play's light utility column — a disabled
/// MONITOR keycap and two resting meter tracks. No audio truth exists yet
/// (Phase 2), so nothing moves and nothing is claimed.
struct PlayRail: View {
    var body: some View {
        VStack(spacing: HaloMetrics.s2) {
            HaloPanel("MONITOR") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    Button("MONITOR") {}
                        .buttonStyle(MechanicalButtonStyle())
                        .disabled(true)
                    RailCaption("AUDIO ENGINE — PHASE 2")
                }
            }
            HaloPanel("METERS") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    RailMeterTrack(channel: "L")
                    RailMeterTrack(channel: "R")
                    RailCaption("NO AUDIO TRUTH YET — PHASE 2")
                }
            }
        }
    }
}
