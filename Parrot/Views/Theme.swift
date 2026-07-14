import SwiftUI

/// Parrot's design system — the tweakcn "Claude +" shadcn theme rendered natively:
/// Outfit typography, warm cream neutrals, terracotta accent, round 16pt radii.
/// Source: https://tweakcn.com/themes/cmdght103000n04lh3e2ae93r
/// Fonts are bundled in Parrot/Fonts and auto-registered via
/// ATSApplicationFontsPath in project.yml.
///
/// Colors adapt to light/dark; values track the theme's light/dark CSS variables.
enum Theme {

    // MARK: - Colors

    enum Colors {
        /// App canvas — theme background.
        static let canvas = Color(lightHex: 0xFAF9F5, darkHex: 0x262624)
        /// Sidebar / side panels — theme sidebar.
        static let panel = Color(lightHex: 0xF5F4EE, darkHex: 0x1F1E1D)
        /// Chip / segmented-control background — theme secondary/popover.
        static let chip = Color(lightHex: 0xE9E6DC, darkHex: 0x30302E)
        /// Hairline divider — theme border.
        static let line = Color(lightHex: 0xDAD9D4, darkHex: 0x3E3E38)
        /// Selected row tint — theme muted.
        static let selection = Color(lightHex: 0xEDE9DE, darkHex: 0x30302E)

        /// Primary text — theme foreground (warm near-black).
        static let ink = Color(lightHex: 0x3D3929, darkHex: 0xF1F1EF)
        /// Secondary text — theme muted-foreground.
        static let ink2 = Color(lightHex: 0x6E6D68, darkHex: 0xB7B5A9)
        /// Tertiary text / timestamps (derived — theme has no tertiary step).
        static let ink3 = Color(lightHex: 0x9A988F, darkHex: 0x8A887D)
        /// Section labels ("Key points") — theme muted-foreground.
        static let label = Color(lightHex: 0x6E6D68, darkHex: 0xB7B5A9)

        /// Brand / primary accent — theme primary (Claude terracotta).
        static let accent = Color(lightHex: 0xC96442, darkHex: 0xD97757)
        /// Action-item semantic (emerald).
        static let action = Color(lightHex: 0x059669, darkHex: 0x34D399)
        /// Blocker / objection semantic — red, so it can't be confused with the
        /// terracotta accent (the old amber sat too close to it).
        static let blocker = Color(lightHex: 0xDC2626, darkHex: 0xEF4444)
        /// Sub-points / secondary links (indigo).
        static let subtle = Color(lightHex: 0x6366F1, darkHex: 0x818CF8)
    }

    // MARK: - Typography

    enum Typography {
        /// App typeface family — swap here to retheme (fonts live in Parrot/Fonts).
        /// Hardcoded view fonts should route through sans() (or a token below),
        /// never .system, or they silently fall back to SF Pro.
        static let family = "Outfit"

        static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .custom(family, size: size).weight(weight)
        }

        /// Big title (meeting name, report heading) — semibold,
        /// tracking-tight applied at call sites.
        static func title(_ size: CGFloat = 26) -> Font {
            sans(size, .semibold)
        }
        // Scale matched to the card-guide legend (user-approved look, 2026-07-02):
        // bold ~15pt titles over relaxed ~14pt gray body.
        /// Slate section label ("Key points", "Next steps").
        static let sectionLabel = sans(14, .semibold)
        /// Lede / overview paragraph.
        static let lede = sans(16.5)
        static let body = sans(15)
        static let secondary = sans(14)
        static let caption = sans(12.5)
        /// Tiny uppercase panel label ("ASK PARROT").
        static let cap = sans(11, .semibold)

        // Live copilot "glance" scale — the panel is read in 1-second glances
        // mid-call, so its focal card runs well above document sizes.
        /// Hero card payload (the line the user can say).
        static let heroDetail = sans(17.5)
        /// Hero card title.
        static let heroTitle = sans(16, .semibold)
        /// Card title (history rows, expanded cards, pinned cards).
        static let cardTitle = sans(15, .semibold)
        /// Compact history row title.
        static let rowTitle = sans(15)
    }

    // MARK: - Metrics

    enum Metrics {
        // Theme --radius: 1rem — the round, soft Claude look.
        static let radius: CGFloat = 16
        static let chipRadius: CGFloat = 10
        /// Report/insights column cap. Was 640 — read as "tiny" on wide
        /// windows (user feedback); wide enough now to use the screen while
        /// keeping prose lines readable.
        static let contentMaxWidth: CGFloat = 1100
        static let pad: CGFloat = 16
        static let sectionGap: CGFloat = 24
    }
}

/// App-typeface stand-ins for the built-in macOS text styles, at the system's fixed
/// point sizes. Views say `.font(.appCaption)` instead of `.font(.caption)` —
/// the built-ins always render SF Pro and would bypass the app typeface.
extension Font {
    static let appLargeTitle = Theme.Typography.sans(26)
    static let appTitle = Theme.Typography.sans(22)
    static let appTitle2 = Theme.Typography.sans(17)
    static let appTitle3 = Theme.Typography.sans(15)
    static let appHeadline = Theme.Typography.sans(13, .semibold)
    static let appBody = Theme.Typography.sans(13)
    static let appCallout = Theme.Typography.sans(12)
    static let appSubheadline = Theme.Typography.sans(11)
    static let appFootnote = Theme.Typography.sans(10)
    static let appCaption = Theme.Typography.sans(10)
    static let appCaption2 = Theme.Typography.sans(10)
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
