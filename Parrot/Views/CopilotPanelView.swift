import SwiftUI

/// Live insight feed shown next to the transcript while recording.
///
/// Layout ("glanceable copilot"): sentiment chips and unhandled blockers up top,
/// then a fixed HERO slot that always shows the newest insight at glance scale,
/// then older insights as compact one-line rows. Cards are monochrome (canvas
/// fill, hairline border); color appears only in small signals — the kind icon
/// chip, the score, the open-blocker flag, the live dot, and the meters. The
/// panel is read in 1-second glances mid-call, so there is exactly one place to
/// look: the hero.
struct CopilotPanelView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.openSettings) private var openSettings

    /// Set by tapping a card timestamp; LiveRecordingView scrolls the transcript there.
    @Binding var transcriptJumpTarget: TimeInterval?

    /// History rows the user has expanded inline — compact is the default.
    @State private var expanded: Set<UUID> = []
    /// Hero insight currently announcing itself; its glow fades after ~1.5s.
    @State private var glowingID: UUID?

    private var engine: CallAnalysisEngine { recordingManager.callAnalysisEngine }

    /// Profile-aware style resolver for a live insight.
    private func style(for insight: Insight) -> KindStyle {
        KindResolver.style(forKey: insight.kindKey, profile: engine.activeProfile, snapshot: [])
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            // Center stage now — panel fills the window, but cards keep
            // readable line lengths (leading-aligned, never floating).
            content
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity)
        .background(Theme.Colors.panel)
    }

    // MARK: - Derived lists

    private var pinnedBlockers: [Insight] {
        engine.insights.filter { style(for: $0).isPinned && !$0.isHandled }
    }

    private var feedInsights: [Insight] {
        // Everything except unhandled pinned insights (those live in the pinned zone).
        engine.insights.filter { !(style(for: $0).isPinned && !$0.isHandled) }
    }

    /// The focal slot: newest feed insight (engine inserts newest at index 0).
    private var heroInsight: Insight? { feedInsights.first }

    private var historyInsights: [Insight] { Array(feedInsights.dropFirst()) }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.Colors.accent)

            Text("Copilot")
                .font(.appHeadline)

            Spacer()

            if let percent = engine.userTalkPercent {
                Text("You \(percent)%")
                    .font(.appCaption)
                    .monospacedDigit()
                    .foregroundStyle(percent > 70 ? Theme.Colors.warn : Theme.Colors.ink2)
                    .help("Your share of the conversation so far")
            }

            statusBadge
        }
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch engine.status {
        case .listening:
            HStack(spacing: 5) {
                Circle().fill(Theme.Colors.good).frame(width: 7, height: 7)
                Text("Listening").font(.appCaption).foregroundStyle(Theme.Colors.ink2)
            }
        case .analyzing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Thinking…").font(.appCaption).foregroundStyle(Theme.Colors.ink2)
            }
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.warn)
                .font(.appCaption)
        default:
            EmptyView()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch engine.status {
        case .needsAPIKey:
            VStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.appTitle2)
                    .foregroundStyle(Theme.Colors.ink2)
                Text("Copilot needs a Claude API key to suggest answers in real time.")
                    .font(.appCallout)
                    .foregroundStyle(Theme.Colors.ink2)
                    .multilineTextAlignment(.center)
                Button("Open Settings…") {
                    openSettings()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error(let message):
            feedArea(errorMessage: message)

        default:
            feedArea(errorMessage: nil)
        }
    }

    @ViewBuilder
    private func feedArea(errorMessage: String?) -> some View {
        VStack(spacing: 0) {
            // Always-on live summary: call score + one-line coach verdict +
            // sentiment chips + open-blocker count. THE glanceable answer to
            // "how is it going and what should I do".
            coachCard
                .padding(.horizontal, Theme.Metrics.pad)
                .padding(.top, 12)

            if engine.insights.isEmpty && errorMessage == nil {
                emptyState
            } else {
                feed(errorMessage: errorMessage)
            }
        }
    }

    // MARK: - Coach card

    private func scoreColor(_ score: Int) -> Color {
        score >= 70 ? Theme.Colors.good
            : score >= 40 ? Theme.Colors.warn
            : Theme.Colors.stop
    }

    private var coachCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let score = engine.callScore {
                    Text("\(score)")
                        .font(Theme.Typography.sans(20, .bold))
                        .monospacedDigit()
                        .foregroundStyle(scoreColor(score))
                        .contentTransition(.numericText())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CALL SCORE")
                            .font(Theme.Typography.cap)
                            .foregroundStyle(Theme.Colors.ink3)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.Colors.chip)
                            Capsule().fill(scoreColor(score))
                                .frame(width: 72 * CGFloat(score) / 100)
                        }
                        .frame(width: 72, height: 4)
                    }
                }

                Spacer()

                if !pinnedBlockers.isEmpty {
                    Label("\(pinnedBlockers.count) open", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.sans(12, .medium))
                        .foregroundStyle(Theme.Colors.warn)
                        .help("Unresolved blockers — they're at the top of the feed below")
                }
            }

            Text(engine.coachLine ?? "Warming up — the coach reads the room after the first exchanges.")
                .font(Theme.Typography.body)
                .foregroundStyle(engine.coachLine == nil ? Theme.Colors.ink3 : Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)

            SentimentStripView(
                gauges: engine.activeProfile?.gauges ?? [],
                values: engine.sentiment,
                read: engine.sentimentRead
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
        .animation(.easeOut(duration: 0.3), value: engine.coachLine)
        .animation(.easeOut(duration: 0.3), value: engine.callScore)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "ear.badge.waveform")
                .font(.appTitle2)
                .foregroundStyle(Theme.Colors.ink3)
            Text("Listening to the call.\nSuggestions, blockers and action items will appear here as the conversation unfolds.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink3)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hero + history feed

    private func feed(errorMessage: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.appCaption)
                    .foregroundStyle(Theme.Colors.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Metrics.pad)
                    .padding(.top, 8)
            }

            if let hero = heroInsight {
                HeroInsightCard(
                    insight: hero,
                    kindStyle: style(for: hero),
                    isGlowing: glowingID == hero.id,
                    onJump: { transcriptJumpTarget = hero.callTime },
                    onDismiss: {
                        withAnimation(.spring(duration: 0.25)) {
                            engine.dismiss(hero)
                        }
                    }
                )
                .id(hero.id)  // fresh identity per insight so the arrival transition fires
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.horizontal, Theme.Metrics.pad)
                .padding(.top, 12)
            }

            // Everything below the hero scrolls together: open blockers first
            // (they used to live in an UNBOUNDED fixed zone that could swallow
            // the whole panel — 16 unhandled cards left no room and no scroll),
            // then the compact history.
            ScrollView {
                // Plain VStack: insight volume is modest, and lazy stacks don't
                // lay out under ImageRenderer, which would blind the
                // --copilot-snapshot harness.
                VStack(alignment: .leading, spacing: 6) {
                    if !pinnedBlockers.isEmpty {
                        ForEach(pinnedBlockers) { insight in
                            PinnedBlockerRow(insight: insight) {
                                withAnimation(.spring(duration: 0.3)) {
                                    engine.markHandled(insight)
                                }
                            } onJump: {
                                transcriptJumpTarget = insight.callTime
                            }
                        }
                    }

                    if !historyInsights.isEmpty {
                        Text("EARLIER")
                            .font(Theme.Typography.cap)
                            .foregroundStyle(Theme.Colors.ink3)
                            .padding(.horizontal, 2)
                            .padding(.top, pinnedBlockers.isEmpty ? 2 : 8)

                        ForEach(historyInsights) { insight in
                            InsightCard(
                                insight: insight,
                                kindStyle: style(for: insight),
                                isCollapsed: !expanded.contains(insight.id),
                                onToggleCollapse: { toggleExpanded(insight) },
                                onJump: { transcriptJumpTarget = insight.callTime },
                                onDismiss: {
                                    withAnimation(.spring(duration: 0.25)) {
                                        engine.dismiss(insight)
                                    }
                                }
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .padding(.horizontal, Theme.Metrics.pad)
                .padding(.vertical, 12)
            }
        }
        .animation(.spring(duration: 0.3), value: engine.insights)
        .onChange(of: heroInsight?.id) { _, newID in
            guard let newID else { return }
            glowingID = newID
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                if glowingID == newID { glowingID = nil }
            }
        }
    }

    private func toggleExpanded(_ insight: Insight) {
        if expanded.contains(insight.id) {
            expanded.remove(insight.id)
        } else {
            expanded.insert(insight.id)
        }
    }
}

// MARK: - Icon Chip

/// 20×20 kind-colored icon chip — the one place a card shows its kind color.
private struct IconChip: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Pinned Blocker Row

struct PinnedBlockerRow: View {
    let insight: Insight
    let onHandled: () -> Void
    let onJump: () -> Void

    /// Details start clamped to two lines; a click on the card shows the rest.
    @State private var expanded: Bool

    init(insight: Insight, startExpanded: Bool = false,
         onHandled: @escaping () -> Void, onJump: @escaping () -> Void) {
        self.insight = insight
        self.onHandled = onHandled
        self.onJump = onJump
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            IconChip(systemName: "exclamationmark.triangle.fill", color: Theme.Colors.warn)

            VStack(alignment: .leading, spacing: 3) {
                Text(insight.title)
                    .font(Theme.Typography.cardTitle)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 6) {
                    TimestampButton(insight: insight, action: onJump)

                    Text(insight.detail)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                        .lineLimit(expanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The answer is the valuable part — always visible, no click.
                if let reply = insight.reply {
                    SuggestedReplyBox(reply: reply)
                        .padding(.top, 2)
                }

                // ponytail: length heuristic for "is it truncated" — measuring
                // real truncation in SwiftUI needs a two-pass text layout.
                if !expanded && insight.detail.count > 120 {
                    Text("show more")
                        .font(Theme.Typography.sans(11, .medium))
                        .foregroundStyle(Theme.Colors.warn)
                }
            }

            Spacer()

            Button(action: onHandled) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.warn)
            }
            .buttonStyle(.plain)
            .help("Mark as handled")
        }
        .padding(12)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .strokeBorder(Theme.Colors.line)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        }
    }
}

// MARK: - Hero Insight Card

/// The focal slot at the top of the copilot panel: the newest insight rendered
/// at glance scale on a monochrome card — the kind color lives in the icon chip.
struct HeroInsightCard: View {
    let insight: Insight
    let kindStyle: KindStyle
    /// Kept for API compatibility; the arrival glow was dropped with the native restyle.
    let isGlowing: Bool
    let onJump: () -> Void
    let onDismiss: () -> Void

    @State private var copied = false

    /// Kinds whose detail is a line the user can literally say — they get the
    /// prominent Copy pill.
    private var isSayable: Bool {
        ["suggestion", "answer", "reflection", "open_question", "follow_up_question"]
            .contains(insight.kindKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconChip(systemName: kindStyle.iconSystemName, color: kindStyle.color)
                Text(kindStyle.label)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.ink2)

                if kindStyle.isPinned && insight.isHandled {
                    Label("Handled", systemImage: "checkmark")
                        .font(.appCaption2)
                        .foregroundStyle(Theme.Colors.good)
                }

                Spacer()

                TimestampButton(insight: insight, action: onJump)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.ink3)
                }
                .buttonStyle(.plain)
                .help("Dismiss — the previous insight moves up")
            }

            Text(insight.title)
                .font(Theme.Typography.heroTitle)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(insight.detail)
                .font(Theme.Typography.heroDetail)
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let reply = insight.reply {
                SuggestedReplyBox(reply: reply)
            }

            HStack(spacing: 8) {
                if isSayable {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(insight.detail, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(Theme.Typography.sans(12, .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.Colors.accent.opacity(0.14), in: Capsule())
                            .foregroundStyle(Theme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Copy this line")
                }

                if let source = insight.source {
                    Label(source, systemImage: source == "general knowledge" ? "globe" : "doc.text")
                        .font(Theme.Typography.sans(12))
                        .foregroundStyle(Theme.Colors.ink3)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .strokeBorder(Theme.Colors.line)
        )
        .contextMenu {
            Button("Jump to transcript") { onJump() }
            Button("Dismiss", role: .destructive) { onDismiss() }
        }
    }
}

// MARK: - Insight Card (history rows)

struct InsightCard: View {
    let insight: Insight
    /// Resolved visual style — callers supply this via KindResolver so the card
    /// never hard-codes the fallback table and is profile-aware.
    let kindStyle: KindStyle
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onJump: () -> Void
    let onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        Group {
            if isCollapsed {
                collapsedRow
            } else {
                expandedCard
            }
        }
        .contextMenu {
            Button("Jump to transcript") { onJump() }
            Button("Dismiss", role: .destructive) { onDismiss() }
        }
    }

    private var collapsedRow: some View {
        Button(action: onToggleCollapse) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.appCaption2)
                    .foregroundStyle(Theme.Colors.ink3)

                IconChip(systemName: kindStyle.iconSystemName, color: kindStyle.color)

                Text(insight.title)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(1)

                if kindStyle.isPinned && insight.isHandled {
                    Image(systemName: "checkmark")
                        .font(.appCaption2)
                        .foregroundStyle(Theme.Colors.good)
                }

                Spacer()

                Text(insight.formattedCallTime)
                    .font(Theme.Typography.mono(11))
                    .foregroundStyle(Theme.Colors.ink3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .strokeBorder(Theme.Colors.line)
        )
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IconChip(systemName: kindStyle.iconSystemName, color: kindStyle.color)
                Text(kindStyle.label)
                    .font(Theme.Typography.sans(11, .semibold))
                    .foregroundStyle(Theme.Colors.ink2)

                if kindStyle.isPinned && insight.isHandled {
                    Label("Handled", systemImage: "checkmark")
                        .font(.appCaption2)
                        .foregroundStyle(Theme.Colors.good)
                }

                Spacer()

                TimestampButton(insight: insight, action: onJump)

                if insight.kindKey == "suggestion" {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(insight.detail, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.appCaption)
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                    .buttonStyle(.plain)
                    .help("Copy suggested answer")
                }
            }

            Text(insight.title)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Colors.ink)

            Text(insight.detail)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)

            if let reply = insight.reply {
                SuggestedReplyBox(reply: reply)
            }

            if let source = insight.source {
                Label(source, systemImage: source == "general knowledge" ? "globe" : "doc.text")
                    .font(.appCaption2)
                    .foregroundStyle(Theme.Colors.ink3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .strokeBorder(Theme.Colors.line)
        )
        .onTapGesture(count: 2) {
            onToggleCollapse()
        }
    }
}

/// The copilot's suggested line to address an unresolved item — a bordered
/// "here's what to say" block with a copy button; the quote mark and copy
/// button carry the accent ("say this"). KB-grounded when documents cover it.
struct SuggestedReplyBox: View {
    let reply: String

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "quote.opening")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Colors.accent)
                .padding(.top, 4)

            Text(reply)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reply, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)
            .help("Copy this line")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .strokeBorder(Theme.Colors.line)
        )
    }
}

/// Tappable mm:ss stamp that jumps the transcript to the insight's moment.
struct TimestampButton: View {
    let insight: Insight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(insight.formattedCallTime)
                .font(Theme.Typography.mono(11))
                .underline()
                .foregroundStyle(Theme.Colors.ink2)
        }
        .buttonStyle(.plain)
        .help("Jump to this moment in the transcript")
    }
}
