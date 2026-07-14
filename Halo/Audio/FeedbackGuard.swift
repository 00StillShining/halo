import Foundation

/// Pure feedback-loop guard (Brief §8 safety: "Never select the EP-40 as halo's
/// monitor output while routing computer audio to its USB input without an
/// explicit feedback warning").
///
/// halo pulls the EP-40's USB audio INPUT and plays it to the chosen Mac OUTPUT.
/// If the user also picks the EP-40 as that output, the instrument's own monitor
/// feeds straight back into itself — a howl-round risk. This is a pure decision so
/// the UI can surface the warning before anything is routed, and so it is testable
/// without hardware (`FeedbackGuardTests`).
enum FeedbackGuard {
    /// Whether routing the EP-40 input to `outputUID` would create a feedback loop:
    /// true exactly when the selected monitor output is the same physical device
    /// halo is capturing from.
    ///
    /// - Parameters:
    ///   - inputUID: stable UID of the EP-40 audio input being captured.
    ///   - outputUID: stable UID of the selected monitor output (nil = none chosen).
    static func wouldFeedBack(inputUID: String?, outputUID: String?) -> Bool {
        guard let inputUID, let outputUID else { return false }
        return inputUID == outputUID
    }
}
