import SwiftUI

/// Live insight feed shown next to the transcript while recording.
///
/// Layout: unhandled blockers stay pinned at the top; everything else flows in a
/// newest-first feed below. New cards never hijack scroll position — when the user
/// has scrolled down, a "new insights" pill appears instead. Old cards auto-collapse
/// to one-line rows to keep long calls scannable.
struct CopilotPanelView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.openSettings) private var openSettings

    /// Set by tapping a card timestamp; LiveRecordingView scrolls the transcript there.
    @Binding var transcriptJumpTarget: TimeInterval?

    @State private var atTop = true
    @State private var unseenCount = 0
    @State private var seenInsightCount = 0
    /// Insights the user has manually tucked into a one-line row. Nothing collapses
    /// by age anymore — A3 cut the volume enough to keep everything readable.
    @State private var manuallyCollapsed: Set<UUID> = []

    private static let topAnchorID = "copilot-top"

    private var engine: CallAnalysisEngine { recordingManager.callAnalysisEngine }

    /// Profile-aware style resolver for a live insight.
    private func style(for insight: Insight) -> KindStyle {
        KindResolver.style(forKey: insight.kindKey, profile: engine.activeProfile, snapshot: [])
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
        }
        .frame(minWidth: 280, idealWidth: 360, maxWidth: 640)
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.Colors.accent)

            Text("Copilot")
                .font(.headline)

            Spacer()

            if let percent = engine.userTalkPercent {
                Text("You \(percent)%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(percent > 70 ? .orange : .secondary)
                    .help("Your share of the conversation so far")
            }

            statusBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch engine.status {
        case .listening:
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("Listening").font(.caption).foregroundStyle(.secondary)
            }
        case .analyzing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
            }
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
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
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Copilot needs a Claude API key to suggest answers in real time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
            // Always-on sentiment strip — shown whenever the active profile has gauges.
            SentimentStripView(
                gauges: engine.activeProfile?.gauges ?? [],
                values: engine.sentiment,
                read: engine.sentimentRead
            )
            .padding(.horizontal, 12).padding(.top, 8)

            if !pinnedBlockers.isEmpty {
                pinnedZone
                Divider()
            }

            if engine.insights.isEmpty && errorMessage == nil {
                emptyState
            } else {
                feed(errorMessage: errorMessage)
            }
        }
    }

    private var pinnedZone: some View {
        VStack(spacing: 6) {
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
        .padding(10)
        .background(.orange.opacity(0.04))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "ear.badge.waveform")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("Listening to the call.\nSuggestions, blockers and action items will appear here as the conversation unfolds.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feed(errorMessage: String?) -> some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Sentinel that tells us whether the user is at the top.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.topAnchorID)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: AtTopPreferenceKey.self,
                                        value: geo.frame(in: .named("copilotScroll")).minY > -24
                                    )
                                }
                            )

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        ForEach(feedInsights) { insight in
                            InsightCard(
                                insight: insight,
                                kindStyle: style(for: insight),
                                isCollapsed: isCollapsed(insight),
                                onToggleCollapse: { toggleCollapse(insight) },
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
                    .padding(10)
                }
                .coordinateSpace(name: "copilotScroll")
                .onPreferenceChange(AtTopPreferenceKey.self) { isAtTop in
                    atTop = isAtTop
                    if isAtTop {
                        unseenCount = 0
                        seenInsightCount = engine.insights.count
                    }
                }
                .onChange(of: engine.insights.count) { _, newCount in
                    if atTop {
                        seenInsightCount = newCount
                    } else {
                        unseenCount = max(0, newCount - seenInsightCount)
                    }
                }
                .animation(.spring(duration: 0.3), value: engine.insights)

                if unseenCount > 0 && !atTop {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(Self.topAnchorID, anchor: .top)
                        }
                        unseenCount = 0
                        seenInsightCount = engine.insights.count
                    } label: {
                        Label("\(unseenCount) new", systemImage: "arrow.up")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.Colors.accent, in: Capsule())
                            .foregroundStyle(.white)
                            .shadow(radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - Collapse logic

    private func isCollapsed(_ insight: Insight) -> Bool {
        if manuallyCollapsed.contains(insight.id) { return true }
        // Handled pinned insights tuck themselves away; everything else stays open.
        return style(for: insight).isPinned && insight.isHandled
    }

    private func toggleCollapse(_ insight: Insight) {
        if manuallyCollapsed.contains(insight.id) {
            manuallyCollapsed.remove(insight.id)
        } else {
            manuallyCollapsed.insert(insight.id)
        }
    }
}

private struct AtTopPreferenceKey: PreferenceKey {
    static var defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

// MARK: - Pinned Blocker Row

struct PinnedBlockerRow: View {
    let insight: Insight
    let onHandled: () -> Void
    let onJump: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title)
                    .font(.callout.weight(.semibold))

                HStack(spacing: 6) {
                    TimestampButton(insight: insight, action: onJump)

                    Text(insight.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button(action: onHandled) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("Mark as handled")
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.orange.opacity(0.35))
        )
    }
}

// MARK: - Insight Card

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
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.Colors.ink3)

                Image(systemName: kindStyle.iconSystemName)
                    .font(.caption)
                    .foregroundStyle(kindStyle.color)

                Text(insight.title)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(1)

                if kindStyle.isPinned && insight.isHandled {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(Theme.Colors.action)
                }

                Spacer()

                Text(insight.formattedCallTime)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.ink3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: 8))
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: kindStyle.iconSystemName)
                Text(kindStyle.label)
                    .font(.caption.weight(.semibold))

                if kindStyle.isPinned && insight.isHandled {
                    Label("Handled", systemImage: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(Theme.Colors.action)
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
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Copy suggested answer")
                }
            }
            .foregroundStyle(kindStyle.color)

            Text(insight.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.Colors.ink)

            Text(insight.detail)
                .font(.callout)
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)

            if let source = insight.source {
                Label(source, systemImage: source == "general knowledge" ? "globe" : "doc.text")
                    .font(.caption2)
                    .foregroundStyle(Theme.Colors.ink3)
            }
        }
        .padding(.vertical, 11)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            kindStyle.isPinned ? Theme.Colors.blocker.opacity(0.10) : Theme.Colors.canvas,
            in: RoundedRectangle(cornerRadius: Theme.Metrics.radius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .strokeBorder(Theme.Colors.line)
        )
        // Colored accent stripe on the leading edge, in place of a tinted fill.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(kindStyle.color)
                .frame(width: 3)
                .padding(.vertical, 9)
        }
        .onTapGesture(count: 2) {
            onToggleCollapse()
        }
    }
}

/// Tappable mm:ss stamp that jumps the transcript to the insight's moment.
struct TimestampButton: View {
    let insight: Insight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(insight.formattedCallTime)
                .font(.caption2)
                .monospacedDigit()
                .underline()
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Jump to this moment in the transcript")
    }
}

