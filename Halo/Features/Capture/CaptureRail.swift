import SwiftUI

/// CAPTURE rail scaffold (Brief §7). Session-capture readouts at their honest
/// em-dash rest values; the capture engine is Phase 3 (stated in the caption),
/// so no elapsed / peak / disk figure is invented.
struct CaptureRail: View {
    var body: some View {
        VStack(spacing: HaloMetrics.s2) {
            HaloPanel("SESSION CAPTURE") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    RailDataRow("ELAPSED")
                    RailDataRow("PEAK L")
                    RailDataRow("PEAK R")
                    RailDataRow("DISK FREE")
                    RailCaption("CAPTURE ENGINE — PHASE 3")
                }
            }
        }
    }
}
