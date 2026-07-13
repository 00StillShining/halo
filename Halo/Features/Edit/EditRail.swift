import SwiftUI

/// EDIT rail scaffold (Brief §7). `NO PAD SELECTED` is true today and true
/// forever as the empty state, so it doubles as the honest rest content.
struct EditRail: View {
    var body: some View {
        VStack(spacing: HaloMetrics.s2) {
            HaloPanel("WAVEFORM") {
                RailCaption("NO PAD SELECTED")
            }
            HaloPanel("TRIM / GAIN") {
                RailCaption("NO PAD SELECTED")
            }
        }
    }
}
