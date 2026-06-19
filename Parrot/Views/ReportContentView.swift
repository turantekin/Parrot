import SwiftUI

/// Renders the AI's plain-text summary / coaching reports as structured, styled
/// content — section labels with icons, bulleted lists, and a talk-ratio bar —
/// instead of dumping the raw string into one `Text`. This is what makes the
/// report match the design mockup (.context/mockups/parrot-redesign.html).
struct ReportContentView: View {
    let summary: String?
    let coaching: String?
    /// Me's share of the words, for the talk-balance bar (nil → no bar).
    var talkPercentMe: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let summary, !summary.isEmpty {
                ReportProse(text: summary)
            }

            if let coaching, !coaching.isEmpty {
                if summary?.isEmpty == false {
                    Divider().overlay(Theme.Colors.line)
                }
                if let pct = talkPercentMe {
                    TalkRatioBar(percentMe: pct)
                }
                ReportProse(text: coaching)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Talk-ratio bar

struct TalkRatioBar: View {
    let percentMe: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Talk balance", systemImage: "chart.bar")
                .font(Theme.Typography.sectionLabel)
                .foregroundStyle(Theme.Colors.label)

            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(Theme.Colors.accent)
                        .frame(width: max(0, geo.size.width * CGFloat(percentMe) / 100 - 1))
                    Capsule().fill(Theme.Colors.line)
                }
            }
            .frame(height: 8)

            HStack {
                Text("You \(percentMe)%")
                Spacer()
                Text("Them \(100 - percentMe)%")
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.ink2)
        }
    }
}

// MARK: - Prose parser + renderer

/// Parses the AI's plain text into headings / bullets / paragraphs and renders
/// each with the design-system styles.
struct ReportProse: View {
    let text: String

    private enum Block: Identifiable {
        case heading(String)
        case bullet(String, level: Int)
        case paragraph(String, lede: Bool)
        var id: String {
            switch self {
            case .heading(let s): "h:\(s)"
            case .bullet(let s, let l): "b\(l):\(s)"
            case .paragraph(let s, _): "p:\(s)"
            }
        }
    }

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                row(block)
            }
        }
    }

    @ViewBuilder private func row(_ block: Block) -> some View {
        switch block {
        case .heading(let title):
            Label {
                Text(title)
            } icon: {
                Image(systemName: Self.icon(for: title))
            }
            .font(Theme.Typography.sectionLabel)
            .foregroundStyle(Theme.Colors.label)
            .padding(.top, 8)
            .padding(.bottom, 1)

        case .bullet(let text, let level):
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(level > 0 ? Theme.Colors.subtle.opacity(0.6) : Theme.Colors.ink3)
                    .frame(width: 5, height: 5)
                    .padding(.top, 7)
                    .padding(.leading, level > 0 ? 16 : 2)
                Self.styled(text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(level > 0 ? Theme.Colors.subtle : Theme.Colors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .paragraph(let text, let lede):
            Self.styled(text)
                .font(lede ? Theme.Typography.lede : Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
                .lineSpacing(lede ? 3 : 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: parsing

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var sawParagraph = false

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Markdown header ("# Heading", "## Heading")
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { blocks.append(.heading(title)) }
                continue
            }

            // Bullet ("- ", "* ", "• ", "– "); leading whitespace → sub-level
            if let bullet = bulletMatch(rawLine) {
                blocks.append(.bullet(bullet.text, level: bullet.level))
                continue
            }

            let words = line.split(separator: " ")

            // Short label line ending in ":" → section heading
            if line.hasSuffix(":") && words.count <= 7 {
                blocks.append(.heading(String(line.dropLast())))
                continue
            }

            // Bold-only short line "**Heading**" → heading
            if line.hasPrefix("**"), line.hasSuffix("**"), words.count <= 8 {
                blocks.append(.heading(String(line.dropFirst(2).dropLast(2))))
                continue
            }

            blocks.append(.paragraph(line, lede: !sawParagraph))
            sawParagraph = true
        }
        return blocks
    }

    private static func bulletMatch(_ raw: String) -> (text: String, level: Int)? {
        let leading = raw.prefix { $0 == " " || $0 == "\t" }.count
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• ", "– ", "·  "] where trimmed.hasPrefix(marker) {
            return (String(trimmed.dropFirst(marker.count)), leading >= 2 ? 1 : 0)
        }
        return nil
    }

    /// Inline-markdown styled text (handles **bold**, *italic*), falling back to plain.
    private static func styled(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(s)
    }

    private static func icon(for title: String) -> String {
        let t = title.lowercased()
        switch true {
        case t.contains("key point"), t.contains("highlight"): return "list.bullet"
        case t.contains("next step"), t.contains("action"): return "checklist"
        case t.contains("commit"), t.contains("follow"): return "checkmark.seal"
        case t.contains("went well"), t.contains("strength"): return "hand.thumbsup"
        case t.contains("improve"), t.contains("work on"): return "arrow.up.forward"
        case t.contains("objection"), t.contains("question"): return "questionmark.circle"
        case t.contains("snapshot"), t.contains("balance"), t.contains("overview"): return "chart.bar"
        case t.contains("summary"), t.contains("report"): return "text.alignleft"
        default: return "circle.grid.2x1"
        }
    }
}
