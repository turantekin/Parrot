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
    /// The transcript, for checking `[mm:ss]` receipts. Empty → stamps are
    /// stripped and no chips or flags show (e.g. a meeting with no lines).
    var receipts: ReceiptIndex = .empty
    /// What a receipt chip can do; nil → chips still show the quote, no buttons.
    var receiptActions: ReceiptActions?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary, !summary.isEmpty {
                ReportProse(text: summary, receipts: receipts, actions: receiptActions)
            }

            if let coaching, !coaching.isEmpty {
                if let pct = talkPercentMe {
                    TalkRatioBar(percentMe: pct)
                }
                ReportProse(text: coaching, receipts: receipts, actions: receiptActions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compared without the actions: they're the same two operations on the
/// same meeting every render, and comparing the rest lets `.equatable()`
/// skip re-parsing the report on every playback tick.
extension ReportContentView: Equatable {
    nonisolated static func == (lhs: ReportContentView, rhs: ReportContentView) -> Bool {
        lhs.summary == rhs.summary && lhs.coaching == rhs.coaching
            && lhs.talkPercentMe == rhs.talkPercentMe && lhs.receipts == rhs.receipts
            && (lhs.receiptActions?.play == nil) == (rhs.receiptActions?.play == nil)
    }
}

/// What the report can do with a receipt: play the moment, or show the line.
struct ReceiptActions {
    /// Nil when the meeting has no audio to play.
    var play: ((TimeInterval) -> Void)?
    /// The line's start, and its words to tell apart two lines that share it.
    var showInTranscript: (TimeInterval, String?) -> Void
}

// MARK: - Receipts

/// "12:34" beside a report bullet — the transcript line that backs it.
/// Click for the quote, with Play and Show in Transcript.
struct ReceiptChip: View {
    let line: ReceiptIndex.Line
    let actions: ReceiptActions?
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Text(Receipts.stamp(line.start))
                .font(Theme.Typography.receipt)
                .foregroundStyle(Theme.Colors.accent)
                .padding(.horizontal, Theme.Metrics.chipInsetH)
                .padding(.vertical, Theme.Metrics.chipInsetV)
                .background(Theme.Colors.accent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("\(line.speaker): \(line.text)")
        .accessibilityLabel("Source at \(Receipts.stamp(line.start))")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ReceiptPopover(line: line, actions: actions) { showing = false }
        }
    }
}

/// The receipt itself: who said it, their words, and a way to hear it.
struct ReceiptPopover: View {
    let line: ReceiptIndex.Line
    let actions: ReceiptActions?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(line.speaker)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.ink)
                Text(Receipts.stamp(line.start))
                    .font(Theme.Typography.receipt)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            Text("\u{201C}\(line.text)\u{201D}")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let actions {
                HStack(spacing: 8) {
                    if let play = actions.play {
                        Button {
                            play(line.start)
                        } label: {
                            Label("Play from Here", systemImage: "play.fill")
                        }
                    }
                    Button {
                        dismiss()
                        actions.showInTranscript(line.start, line.text)
                    } label: {
                        Label("Show in Transcript", systemImage: "text.bubble")
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(Theme.Metrics.popoverPad)
        .frame(width: 320, alignment: .leading)
    }
}

/// Shown instead of a chip when a commitment has no receipt: the model
/// claimed a promise the transcript doesn't back up.
struct UnverifiedTag: View {
    var body: some View {
        Label("unverified", systemImage: "questionmark.circle")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.warn)
            .labelStyle(.titleAndIcon)
            .help("Parrot couldn't find this in the transcript. Check it before acting on it.")
            .accessibilityLabel("Unverified: no matching line in the transcript")
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
    var receipts: ReceiptIndex = .empty
    var actions: ReceiptActions?

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
        // Only a report written under the receipts rule gets "unverified"
        // flags — older reports never claimed a source.
        let flagging = receipts.reportHasReceipts(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if let title = section.title {
                    ReportSectionCard(title: title,
                                      icon: Self.icon(for: title),
                                      tint: Self.tint(for: title)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                                row(block, check: Self.checked(block, section: title,
                                                               receipts: receipts, flagging: flagging))
                            }
                        }
                    }
                } else {
                    // Overview/preamble — breathes outside any card.
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                            row(block, check: Self.checked(block, section: nil,
                                                           receipts: receipts, flagging: flagging))
                        }
                    }
                }
            }
        }
    }

    /// A block's text with its stamps lifted out, the lines they verify,
    /// and whether it's a commitment with no receipt.
    struct Checked: Equatable {
        let text: String
        let lines: [ReceiptIndex.Line]
        let unverified: Bool
    }

    static func checked(_ block: Block, section: String?, receipts: ReceiptIndex,
                        flagging: Bool) -> Checked {
        switch block {
        case .bullet(let raw, _):
            let cited = Receipts.extract(raw)
            let lines = receipts.verified(cited.times)
            let unverified = flagging && lines.isEmpty
                && Receipts.isCommitmentSection(section) && !Receipts.isPlaceholder(cited.text)
            return Checked(text: cited.text, lines: lines, unverified: unverified)
        case .paragraph(let raw, _):
            let cited = Receipts.extract(raw)
            return Checked(text: cited.text, lines: receipts.verified(cited.times), unverified: false)
        }
    }

    @ViewBuilder private func row(_ block: Block, check: Checked) -> some View {
        switch block {
        case .bullet(_, let level):
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(level > 0 ? Theme.Colors.subtle.opacity(0.6) : Theme.Colors.ink3)
                    .frame(width: 5, height: 5)
                    .padding(.top, 7) // optical: centers the dot on the first 13pt line
                    .padding(.leading, level > 0 ? 16 : 2)
                Self.styled(check.text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(level > 0 ? Theme.Colors.subtle : Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                receiptColumn(check)
            }

        case .paragraph(_, let lede):
            HStack(alignment: .top, spacing: 8) {
                Self.styled(check.text)
                    .font(lede ? Theme.Typography.lede : Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineSpacing(lede ? 3 : 1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                receiptColumn(check)
            }
        }
    }

    /// Chips (or the unverified tag) in a right-hand margin, top-aligned
    /// with the text they back.
    @ViewBuilder private func receiptColumn(_ check: Checked) -> some View {
        if check.unverified {
            UnverifiedTag()
                .padding(.top, 1)
        } else if !check.lines.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(check.lines.enumerated()), id: \.offset) { _, line in
                    ReceiptChip(line: line, actions: actions)
                }
            }
            .padding(.top, 1)
        }
    }

    // MARK: parsing

    /// The section labels the report prompts ask for ("Call snapshot" is a
    /// prose line, so it isn't here).
    static let sectionLabels = ["Pain points", "Key points", "Next steps", "What went well",
                                "What to improve", "Objections & questions", "Commitments & follow-ups"]

    private static let inlineSection: NSRegularExpression = {
        let labels = sectionLabels.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "(?i)(^|\\s)(\(labels)):[ \\t]*(?=[-–•][ \\t])")
    }()

    private static let inlineBullet = try! NSRegularExpression(pattern: "[ \\t]+[-–•][ \\t]+")  // swiftlint:disable:this force_try

    /// Small local models (gemma3:4b, 2026-09-25) write the whole report on
    /// one line: "…intro. Pain points: - a. – None. Key points: - b.".
    /// Put each known label on its own line and its " - " items under it.
    /// Only a known label directly followed by a bullet triggers this, so a
    /// well-formed report never changes.
    // ponytail: splits every " - " after such a label, so an item that
    // itself contains " - " is cut in two; fine until a model does both.
    static func unflattened(_ text: String) -> String {
        let ns = text as NSString
        let matches = inlineSection.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        func items(_ body: String) -> String {
            let b = body as NSString
            let first = b.hasPrefix("-") || b.hasPrefix("–") || b.hasPrefix("•")
            let listed = inlineBullet.stringByReplacingMatches(
                in: body, range: NSRange(location: 0, length: b.length), withTemplate: "\n- ")
            return first ? "- " + listed.dropFirst(1).trimmingCharacters(in: .whitespaces) : listed
        }
        for (i, m) in matches.enumerated() {
            let labelRange = m.range(at: 2)
            if i == 0 {
                out += ns.substring(to: labelRange.location).trimmingCharacters(in: .whitespaces)
            }
            let bodyStart = m.range.location + m.range.length
            let bodyEnd = i + 1 < matches.count ? matches[i + 1].range(at: 2).location : ns.length
            let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\n\n" + ns.substring(with: labelRange) + ":\n" + items(body)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sections(from text: String) -> [Section] {
        var sections: [Section] = [Section(title: nil, blocks: [])]
        var sawParagraph = false

        func append(_ block: Block) {
            sections[sections.count - 1].blocks.append(block)
        }

        for rawLine in unflattened(text).components(separatedBy: "\n") {
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
