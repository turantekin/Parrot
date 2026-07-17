import SwiftUI

/// Renders the AI's plain-text summary / coaching reports as structured, styled
/// content: an opening overview paragraph, then one CARD per section — icon in
/// the section's semantic color, a readable 15pt title, and the section's
/// bullets — instead of a flat run of tiny gray labels.
struct ReportContentView: View {
    let summary: String?
    let coaching: String?
    /// Me's share of the words, for the talk-balance bar (nil → no bar).
    var talkPercentMe: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary, !summary.isEmpty {
                ReportProse(text: summary)
            }

            if let coaching, !coaching.isEmpty {
                if let pct = talkPercentMe {
                    TalkRatioBar(percentMe: pct)
                }
                ReportProse(text: coaching)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Section chrome shared by cards + talk bar

/// One report section as a card: tinted icon chip + title header, content below.
struct ReportSectionCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(tint.opacity(0.14))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint)
                    )
                Text(title)
                    .font(Theme.Typography.sans(15, .semibold))
                    .foregroundStyle(Theme.Colors.ink)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
    }
}

// MARK: - Talk-ratio bar

struct TalkRatioBar: View {
    let percentMe: Int

    var body: some View {
        ReportSectionCard(title: "Talk balance", icon: "chart.bar", tint: Theme.Colors.accent) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(Theme.Colors.accent)
                        .frame(width: max(0, geo.size.width * CGFloat(percentMe) / 100 - 1))
                    Capsule().fill(Theme.Colors.chip)
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

/// Parses the AI's plain text into an overview + sections and renders each
/// section as a card.
struct ReportProse: View {
    let text: String

    enum Block {
        case bullet(String, level: Int)
        case paragraph(String, lede: Bool)
    }

    struct Section {
        let title: String?   // nil = preamble before the first heading
        var blocks: [Block]
    }

    var body: some View {
        let sections = Self.sections(from: text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if let title = section.title {
                    ReportSectionCard(title: title,
                                      icon: Self.icon(for: title),
                                      tint: Self.tint(for: title)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                                row(block)
                            }
                        }
                    }
                } else {
                    // Overview/preamble — breathes outside any card.
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                            row(block)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ block: Block) -> some View {
        switch block {
        case .bullet(let text, let level):
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(level > 0 ? Theme.Colors.subtle.opacity(0.6) : Theme.Colors.ink3)
                    .frame(width: 5, height: 5)
                    .padding(.top, 7) // optical: centers the dot on the first 13pt line
                    .padding(.leading, level > 0 ? 16 : 2)
                Self.styled(text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(level > 0 ? Theme.Colors.subtle : Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
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

    static func sections(from text: String) -> [Section] {
        var sections: [Section] = [Section(title: nil, blocks: [])]
        var sawParagraph = false

        func append(_ block: Block) {
            sections[sections.count - 1].blocks.append(block)
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Markdown header ("# Heading", "## Heading")
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { sections.append(Section(title: title, blocks: [])) }
                continue
            }

            if let bullet = bulletMatch(rawLine) {
                append(.bullet(bullet.text, level: bullet.level))
                continue
            }

            let words = line.split(separator: " ")

            // Short label line ending in ":" → section heading
            if line.hasSuffix(":") && words.count <= 7 {
                sections.append(Section(title: String(line.dropLast()), blocks: []))
                continue
            }

            // Bold-only short line "**Heading**" → heading
            if line.hasPrefix("**"), line.hasSuffix("**"), words.count <= 8 {
                sections.append(Section(title: String(line.dropFirst(2).dropLast(2)), blocks: []))
                continue
            }

            append(.paragraph(line, lede: !sawParagraph))
            sawParagraph = true
        }
        // An empty preamble (text that starts straight at a heading) renders as
        // a stray gap — drop it.
        return sections.filter { $0.title != nil || !$0.blocks.isEmpty }
    }

    static func bulletMatch(_ raw: String) -> (text: String, level: Int)? {
        let leading = raw.prefix { $0 == " " || $0 == "\t" }.count
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• ", "– ", "·  "] where trimmed.hasPrefix(marker) {
            return (String(trimmed.dropFirst(marker.count)), leading >= 2 ? 1 : 0)
        }
        // Models sometimes emit "-Prospect asked…" with no space — still a
        // bullet, previously rendered as a paragraph with a stray dash.
        if let first = trimmed.first, "-–•*".contains(first), trimmed.count > 2 {
            let rest = trimmed.dropFirst()
            if let next = rest.first, next != " ", !next.isNumber, !"-–•*".contains(next) {
                return (rest.trimmingCharacters(in: .whitespaces), leading >= 2 ? 1 : 0)
            }
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

    static func icon(for title: String) -> String {
        let t = title.lowercased()
        switch true {
        case t.contains("pain"), t.contains("struggl"): return "exclamationmark.bubble"
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

    /// Semantic tint per section — color as a signal, consistent with the
    /// copilot cards: warn = needs attention, good = positive/committed,
    /// accent = informational.
    static func tint(for title: String) -> Color {
        let t = title.lowercased()
        switch true {
        case t.contains("pain"), t.contains("struggl"), t.contains("improve"),
             t.contains("work on"), t.contains("objection"):
            return Theme.Colors.warn
        case t.contains("went well"), t.contains("strength"),
             t.contains("commit"), t.contains("follow"):
            return Theme.Colors.good
        default:
            return Theme.Colors.accent
        }
    }
}
