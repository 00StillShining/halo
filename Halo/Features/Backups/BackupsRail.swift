import SwiftUI

/// BACKUPS rail scaffold (Brief §7). `NO SNAPSHOTS` rest state plus the three
/// snapshot-reason legends rendered as inert hairline-outlined tags. Snapshots
/// are written by later phases; nothing here claims a device write happened.
struct BackupsRail: View {
    var body: some View {
        VStack(spacing: HaloMetrics.s2) {
            HaloPanel("SNAPSHOTS") {
                VStack(alignment: .leading, spacing: HaloMetrics.s2) {
                    RailCaption("NO SNAPSHOTS")
                    HStack(spacing: HaloMetrics.s1) {
                        RailTag("BEFORE WRITE")
                        RailTag("MANUAL")
                        RailTag("DAILY")
                    }
                }
            }
        }
    }
}
