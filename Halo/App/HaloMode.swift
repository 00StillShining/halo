import Foundation

/// The persistent workbench modes (Brief §7). PLAY is the daily default; the
/// stage (hero model) is always the visual centre and modes only re-frame it and
/// swap the contextual rail — they never replace the screen.
enum HaloMode: String, CaseIterable, Identifiable, Sendable {
    case play, load, edit, capture, rack, backups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .play:    "PLAY"
        case .load:    "LOAD"
        case .edit:    "EDIT"
        case .capture: "CAPTURE"
        case .rack:    "RACK"
        case .backups: "BACKUPS"
        }
    }

    /// Mode-bar order (Brief §7 diagram: RACK sits between CAPTURE and BACKUPS,
    /// hidden until Phase 5a). Command-1…N indexes THIS array, so today
    /// ⌘5 = BACKUPS and ⌘6 is unassigned; when RACK ships ⌘5 = RACK, ⌘6 = BACKUPS.
    static func visible(rackAvailable: Bool) -> [HaloMode] {
        rackAvailable ? [.play, .load, .edit, .capture, .rack, .backups]
                      : [.play, .load, .edit, .capture, .backups]
    }
}
