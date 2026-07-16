import SwiftUI

/// Parrot's design system — native macOS.
///
/// Every color is a stock AppKit semantic color, so light/dark and accessibility
/// settings (increased contrast, reduced transparency) are correct automatically
/// and always match the system. The accent is the user's own accent color from
/// System Settings. Typography is the system font (SF Pro) on a 5-size scale
/// (20/15/13/12/11) — hierarchy comes from weight, not size. One radius: 6pt.
/// One content inset: 20pt.
///
/// Rules (see docs/IMPROVEMENT-ROADMAP.md):
/// - Color is a signal, not decoration: `warn` always means "unresolved",
///   `good` always "done/positive", `stop` always "recording/destructive",
///   `accent` selection/links/"say this". Nothing else is colored.
/// - Timestamps, durations, and costs render in monospaced digits (`mono`).
enum Theme {

    // MARK: - Colors

    enum Colors {
        /// Main window / content background.
        static let canvas = Color(nsColor: .textBackgroundColor)
        /// Sidebar / side panels.
        static let panel = Color(nsColor: .windowBackgroundColor)
        /// Chips, meters, quiet fills.
        static let chip = Color(nsColor: .quaternaryLabelColor)
        /// Hairline dividers and card borders.
        static let line = Color(nsColor: .separatorColor)
        /// Selected row tint (accent at low opacity, like a source list).
        static let selection = Color.accentColor.opacity(0.16)

        /// Primary text.
        static let ink = Color(nsColor: .labelColor)
        /// Secondary text.
        static let ink2 = Color(nsColor: .secondaryLabelColor)
        /// Tertiary text / timestamps / hints.
        static let ink3 = Color(nsColor: .tertiaryLabelColor)
        /// Section labels ("KEY POINTS") — same as ink2; callers add tracking/caps.
        static let label = Color(nsColor: .secondaryLabelColor)

        /// The user's system accent — selection, links, suggested answers.
        static let accent = Color.accentColor
        /// Success / action items / "listening".
        static let good = Color(nsColor: .systemGreen)
        /// Unresolved: blockers, open questions, warnings.
        static let warn = Color(nsColor: .systemOrange)
        /// Recording / destructive / failures.
        static let stop = Color(nsColor: .systemRed)

        // Legacy semantic names — same tokens, kept so call sites read naturally.
        static let action = good
        static let blocker = warn
        static let subtle = accent
    }

    // MARK: - Typography

    enum Typography {
        /// System font factory. All view fonts route through this or a token below.
        static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }

        /// Monospaced digits/labels — timestamps, durations, costs.
        static func mono(_ size: CGFloat = 11, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        /// Big title (meeting name, report heading).
        static func title(_ size: CGFloat = 20) -> Font {
            sans(size, .bold)
        }

        // The 5-size scale: 20 / 15 / 13 / 12 / 11.
        /// Section label ("Key points") — pair with ink2/ink3 + uppercase at call site.
        static let sectionLabel = sans(11, .semibold)
        /// Lede / overview paragraph — same as body; emphasis comes from position.
        static let lede = sans(13)
        static let body = sans(13)
        static let secondary = sans(12)
        static let caption = sans(11)
        /// Tiny uppercase panel label ("ASK PARROT").
        static let cap = sans(11, .semibold)

        // Live copilot "glance" scale — the panel is read in 1-second glances
        // mid-call, so its focal card runs one step above document sizes.
        /// Hero card payload (the line the user can say).
        static let heroDetail = sans(15)
        /// Hero card title.
        static let heroTitle = sans(15, .semibold)
        /// Card title (history rows, expanded cards, pinned cards).
        static let cardTitle = sans(13, .semibold)
        /// Compact history row title.
        static let rowTitle = sans(13)
    }

    // MARK: - Metrics

    enum Metrics {
        /// The one corner radius. Capsule is allowed only for true pills.
        static let radius: CGFloat = 6
        static let chipRadius: CGFloat = 6
        /// Report/insights column cap — wide enough to use the screen while
        /// keeping prose lines readable.
        static let contentMaxWidth: CGFloat = 1100
        /// The one content inset: every pane starts at the same edge.
        static let pad: CGFloat = 20
        static let sectionGap: CGFloat = 24
    }
}

/// System text styles under the app's historical alias names. These now map
/// straight to the native macOS styles (SF Pro at the system's sizes), so views
/// saying `.font(.appBody)` render exactly like a native Mac app.
extension Font {
    static let appLargeTitle = Font.largeTitle
    static let appTitle = Font.title
    static let appTitle2 = Font.title2
    static let appTitle3 = Font.title3
    static let appHeadline = Font.headline
    static let appBody = Font.body
    static let appCallout = Font.callout
    static let appSubheadline = Font.subheadline
    static let appFootnote = Font.footnote
    static let appCaption = Font.caption
    static let appCaption2 = Font.caption2
}

extension Color {
    /// A hex color that adapts between light and dark appearance, so a single token
    /// works in both. Used for user-configurable profile colors (KindStyle) and
    /// the sidebar's meeting-dot palette — app chrome uses system colors above.
    init(lightHex: UInt32, darkHex: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(rgbHex: isDark ? darkHex : lightHex)
        })
    }
}

private extension NSColor {
    convenience init(rgbHex hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
