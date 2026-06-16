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

    @State private var filter: InsightFilter = .all
    @State private var atTop = true
    @State private var unseenCount = 0
    @State private var seenInsightCount = 0
    @State private var expandedOverrides: Set<UUID> = []

    /// Suggestions/feedback older than this collapse to a one-line row.
    private static let collapseAge: TimeInterval = 120
    private static let topAnchorID = "copilot-top"

    private var engine: CallAnalysisEngine { recordingManager.callAnalysisEngine }

    enum InsightFilter: String, CaseIterable {
        case all, suggestions, blockers, actions

        var icon: String {
            switch self {
            case .all: "square.grid.2x2"
            case .suggestions: "lightbulb"
            case .blockers: "exclamationmark.triangle"
            case .actions: "checkmark.circle"
            }
        }

        func matches(_ insight: Insight) -> Bool {
            switch self {
            case .all: true
            case .suggestions: insight.kind == .suggestion || insight.kind == .feedback || insight.kind == .question
            case .blockers: insight.kind == .blocker
            case .actions: insight.kind == .actionItem
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Derived lists

    private var pinnedBlockers: [Insight] {
        engine.insights.filter { $0.kind == .blocker && !$0.isHandled }
    }

    private var feedInsights: [Insight] {
        engine.insights.filter { insight in
            // Unhandled blockers live in the pinned zone, not the feed.
            if insight.kind == .blocker && !insight.isHandled { return false }
            return filter.matches(insight)
        }
    }

    private var actionItemCount: Int {
        engine.insights.filter { $0.kind == .actionItem }.count
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)

                Text("Copilot")
                    .font(.headline)

                if actionItemCount > 0 {
                    Button {
                        filter = filter == .actions ? .all : .actions
                    } label: {
                        Label("\(actionItemCount)", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Action items captured so far")
                }

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

            Picker("Filter", selection: $filter) {
                ForEach(InsightFilter.allCases, id: \.self) { option in
                    Image(systemName: option.icon).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
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
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
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
                                    isCollapsed: isCollapsed(insight, now: timeline.date),
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
                }
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
                            .background(.purple, in: Capsule())
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

    private func isCollapsed(_ insight: Insight, now: Date) -> Bool {
        if expandedOverrides.contains(insight.id) { return false }
        // Handled blockers collapse immediately; others age out.
        if insight.kind == .blocker && insight.isHandled { return true }
        return now.timeIntervalSince(insight.createdAt) > Self.collapseAge
    }

    private func toggleCollapse(_ insight: Insight) {
        if expandedOverrides.contains(insight.id) {
            expandedOverrides.remove(insight.id)
        } else {
            expandedOverrides.insert(insight.id)
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
                    .foregroundStyle(.tertiary)

                Image(systemName: insight.kind.icon)
                    .font(.caption)
                    .foregroundStyle(insight.kind.color)

                Text(insight.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if insight.kind == .blocker && insight.isHandled {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }

                Spacer()

                Text(insight.formattedCallTime)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: insight.kind.icon)
                Text(insight.kind.label)
                    .font(.caption.weight(.semibold))

                if insight.kind == .blocker && insight.isHandled {
                    Label("Handled", systemImage: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }

                Spacer()

                TimestampButton(insight: insight, action: onJump)

                if insight.kind == .suggestion {
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
            .foregroundStyle(insight.kind.color)

            Text(insight.title)
                .font(.callout.weight(.semibold))

            Text(insight.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let source = insight.source {
                Label(source, systemImage: source == "general knowledge" ? "globe" : "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(insight.kind.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(insight.kind.color.opacity(0.25))
        )
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

extension Insight.Kind {
    var label: String {
        switch self {
        case .suggestion: "Suggested answer"
        case .question: "Open question"
        case .blocker: "Blocker"
        case .actionItem: "Action item"
        case .feedback: "Feedback"
        }
    }

    var icon: String {
        switch self {
        case .suggestion: "lightbulb.fill"
        case .question: "questionmark.circle.fill"
        case .blocker: "exclamationmark.triangle.fill"
        case .actionItem: "checkmark.circle.fill"
        case .feedback: "chart.line.uptrend.xyaxis"
        }
    }

    var color: Color {
        switch self {
        case .suggestion: .blue
        case .question: .teal
        case .blocker: .orange
        case .actionItem: .green
        case .feedback: .purple
        }
    }
}
