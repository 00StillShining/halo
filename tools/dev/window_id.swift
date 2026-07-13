// Prints the CGWindowID of the frontmost on-screen window owned by "Halo".
// Reads only kCGWindowOwnerName (no screen-recording permission needed, unlike
// kCGWindowName). Used by capture_gate.sh to scope `screencapture -l` to the
// app window rather than the whole screen. Exit 0 + id on success, 1 on miss.
import CoreGraphics
import Foundation

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list where (window[kCGWindowOwnerName as String] as? String) == "Halo" {
    if let number = window[kCGWindowNumber as String] as? Int {
        print(number)
        exit(0)
    }
}
exit(1)
