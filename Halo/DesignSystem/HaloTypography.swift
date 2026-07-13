import SwiftUI

/// Typographic tokens (Brief §5). SF Pro / SF Mono are the system faces —
/// halo never downloads or imitates Teenage Engineering's proprietary type.
///   • Wordmark & large status → SF Pro Display  (system, .default, optical-sized)
///   • Device labels / numbers / IDs / shortcuts → SF Mono  (.monospaced)
///   • Descriptions / inspectors → SF Pro Text   (system, .default)
/// Labels are mostly uppercase with careful tracking, never microscopic.
enum HaloType {

    // Wordmark & hero status — SF Pro Display.
    static func wordmark(_ size: CGFloat = 34) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
    static func status(_ size: CGFloat = 15, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    // Monospaced device data — SF Mono.
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Uppercase tracked panel/section labels (use with `.haloLabelCase()`).
    static func label(_ size: CGFloat = 11, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // Body copy & inspector text — SF Pro Text.
    static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Tracking presets (points). Labels get more air; numbers stay tight.
    enum Track {
        static let label: CGFloat = 1.2
        static let wordmark: CGFloat = 2.0
        static let number: CGFloat = 0.0
    }
}

extension View {
    /// Uppercase + label tracking, the halo section-label treatment.
    func haloLabelCase(_ tracking: CGFloat = HaloType.Track.label) -> some View {
        self.textCase(.uppercase).tracking(tracking)
    }
}
