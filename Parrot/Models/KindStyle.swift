import SwiftUI

/// Resolved visual style for an insight kind key. The card never reads a profile
/// directly — it asks the resolver, which walks active-profile → meeting-snapshot
/// → this neutral fallback table.
struct KindStyle: Equatable {
    let label: String
    let color: Color
    let iconSystemName: String
    let isPinned: Bool
}

enum KindResolver {
    /// Neutral fallback covering today's five keys (so pre-Phase-C meetings render
    /// identically) plus a generic style for any unknown key.
    static func fallbackStyle(forKey key: String) -> KindStyle {
        switch key {
        case "suggestion":
            return KindStyle(label: "Suggested answer", color: Theme.Colors.subtle, iconSystemName: "lightbulb.fill", isPinned: false)
        case "question":
            return KindStyle(label: "Open question", color: Theme.Colors.accent, iconSystemName: "questionmark.circle.fill", isPinned: false)
        case "blocker":
            return KindStyle(label: "Blocker", color: Theme.Colors.blocker, iconSystemName: "exclamationmark.triangle.fill", isPinned: true)
        case "action_item":
            return KindStyle(label: "Action item", color: Theme.Colors.action, iconSystemName: "checkmark.circle.fill", isPinned: false)
        case "feedback":
            return KindStyle(label: "Feedback", color: Theme.Colors.ink2, iconSystemName: "chart.line.uptrend.xyaxis", isPinned: false)
        default:
            // Title-case the key as a last resort: "buying_signal" → "Buying Signal".
            let label = key.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
            return KindStyle(label: label.isEmpty ? "Insight" : label,
                             color: Theme.Colors.ink2, iconSystemName: "sparkle", isPinned: false)
        }
    }
}

extension KindResolver {
    /// Profile-aware resolver: walks active profile → snapshot kinds → fallback table.
    /// Live cards pass `snapshot: []`; report cards pass `meeting.snapshotKinds`.
    static func style(forKey key: String, profile: CallProfile?, snapshot: [ProfileKind]) -> KindStyle {
        if let s = profile?.style(forKey: key) { return s }
        if let k = snapshot.first(where: { $0.key == key }) {
            return KindStyle(label: k.label, color: adaptiveColor(forHex: k.colorHex),
                             iconSystemName: k.iconSystemName, isPinned: k.isPinned)
        }
        return fallbackStyle(forKey: key)
    }

    /// Maps known Theme-palette light hexes to their adaptive dark counterparts so that
    /// profile-stored colors (which are persisted as single light hex values) remain
    /// appearance-correct in dark mode. Unknown custom hexes fall back to a fixed color.
    static func adaptiveColor(forHex hex: String) -> Color {
        // Normalise: uppercase, strip leading '#'.
        let s = hex.hasPrefix("#") ? String(hex.dropFirst().uppercased()) : hex.uppercased()
        switch s {
        case "4F6FB0": return Color(lightHex: 0x4F6FB0, darkHex: 0x8AA0D0) // subtle
        case "2F7E96": return Color(lightHex: 0x2F7E96, darkHex: 0x57AEC6) // accent
        case "E8943A": return Color(lightHex: 0xE8943A, darkHex: 0xE8A85C) // blocker
        case "3F9168": return Color(lightHex: 0x3F9168, darkHex: 0x5BBE8C) // action
        case "5F6470": return Color(lightHex: 0x5F6470, darkHex: 0xA0A4AD) // ink2
        default:       return Color(hex: hex)
        }
    }
}

extension Color {
    /// Parses "RRGGBB" or "#RRGGBB". Falls back to gray on malformed input so a
    /// bad profile color can never crash the UI.
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .gray; return }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
