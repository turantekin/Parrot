import SwiftUI

/// Parrot's design system — a calm, editorial "Granola-style" language: near-white
/// canvas, serif headings, generous whitespace, hairline dividers, and a single calm
/// blue-teal accent. See docs/IMPROVEMENT-ROADMAP.md (Phase B) and the mockup at
/// .context/mockups/parrot-redesign.html.
///
/// Colors adapt to light/dark so dark mode isn't regressed; the light values match
/// the approved mockup.
enum Theme {

    // MARK: - Colors

    enum Colors {
        /// App canvas.
        static let canvas = Color(lightHex: 0xFFFFFF, darkHex: 0x1C1C1E)
        /// Sidebar / side panels — faint warm off-white in light mode.
        static let panel = Color(lightHex: 0xFAFAF9, darkHex: 0x242427)
        /// Chip / segmented-control background.
        static let chip = Color(lightHex: 0xF4F4F2, darkHex: 0x303034)
        /// Hairline divider.
        static let line = Color(lightHex: 0xECECEA, darkHex: 0x39393D)
        /// Selected row tint.
        static let selection = Color(lightHex: 0xEEF3EF, darkHex: 0x2C3A3E)

        /// Primary text.
        static let ink = Color(lightHex: 0x1C1C1E, darkHex: 0xF2F2F4)
        /// Secondary text.
        static let ink2 = Color(lightHex: 0x5F6470, darkHex: 0xA0A4AD)
        /// Tertiary text / timestamps.
        static let ink3 = Color(lightHex: 0x9AA0AA, darkHex: 0x70747C)
        /// Slate section labels ("Key points").
        static let label = Color(lightHex: 0x6B7686, darkHex: 0x9098A6)

        /// Brand / primary accent — calm blue-teal.
        static let accent = Color(lightHex: 0x2F7E96, darkHex: 0x57AEC6)
        /// Action-item semantic (muted green).
        static let action = Color(lightHex: 0x3F9168, darkHex: 0x5BBE8C)
        /// Blocker / objection semantic (amber).
        static let blocker = Color(lightHex: 0xE8943A, darkHex: 0xE8A85C)
        /// Sub-points / secondary links (muted indigo).
        static let subtle = Color(lightHex: 0x4F6FB0, darkHex: 0x8AA0D0)
    }

    // MARK: - Typography

    enum Typography {
        /// Big editorial title (meeting name, report heading) — system serif.
        static func title(_ size: CGFloat = 27) -> Font {
            .system(size: size, weight: .semibold, design: .serif)
        }
        // Scale matched to the card-guide legend (user-approved look, 2026-07-02):
        // bold ~15pt titles over relaxed ~14pt gray body.
        /// Slate section label ("Key points", "Next steps").
        static let sectionLabel = Font.system(size: 14, weight: .semibold)
        /// Lede / overview paragraph.
        static let lede = Font.system(size: 16.5)
        static let body = Font.system(size: 15)
        static let secondary = Font.system(size: 14)
        static let caption = Font.system(size: 12.5)
        /// Tiny uppercase panel label ("ASK PARROT").
        static let cap = Font.system(size: 11, weight: .semibold)

        // Live copilot "glance" scale — the panel is read in 1-second glances
        // mid-call, so its focal card runs well above document sizes.
        /// Hero card payload (the line the user can say).
        static let heroDetail = Font.system(size: 17.5)
        /// Hero card title.
        static let heroTitle = Font.system(size: 16, weight: .semibold)
        /// Card title (history rows, expanded cards, pinned cards).
        static let cardTitle = Font.system(size: 15, weight: .semibold)
        /// Compact history row title.
        static let rowTitle = Font.system(size: 15)
    }

    // MARK: - Metrics

    enum Metrics {
        static let radius: CGFloat = 10
        static let chipRadius: CGFloat = 8
        /// Report/insights column cap. Was 640 — read as "tiny" on wide
        /// windows (user feedback); wide enough now to use the screen while
        /// keeping prose lines readable.
        static let contentMaxWidth: CGFloat = 1100
        static let pad: CGFloat = 16
        static let sectionGap: CGFloat = 24
    }
}

extension Color {
    /// A hex color that adapts between light and dark appearance, so a single token
    /// works in both. Matches the mockup's light values.
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
