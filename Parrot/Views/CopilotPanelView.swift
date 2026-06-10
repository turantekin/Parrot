import SwiftUI

/// Live insight feed shown next to the transcript while recording.
struct CopilotPanelView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.openSettings) private var openSettings

    private var engine: CallAnalysisEngine { recordingManager.callAnalysisEngine }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)

            Text("Copilot")
                .font(.headline)

            Spacer()

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
            insightList(footer: message)

        default:
            insightList(footer: nil)
        }
    }

    @ViewBuilder
    private func insightList(footer errorMessage: String?) -> some View {
        if engine.insights.isEmpty && errorMessage == nil {
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
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(engine.insights) { insight in
                        InsightCard(insight: insight)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(10)
            }
            .animation(.spring(duration: 0.3), value: engine.insights)
        }
    }
}

// MARK: - Insight Card

struct InsightCard: View {
    let insight: Insight
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: insight.kind.icon)
                Text(insight.kind.label)
                    .font(.caption.weight(.semibold))

                Spacer()

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
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(insight.kind.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(insight.kind.color.opacity(0.25))
        )
    }
}

extension Insight.Kind {
    var label: String {
        switch self {
        case .suggestion: "Suggested answer"
        case .blocker: "Blocker"
        case .actionItem: "Action item"
        case .feedback: "Feedback"
        }
    }

    var icon: String {
        switch self {
        case .suggestion: "lightbulb.fill"
        case .blocker: "exclamationmark.triangle.fill"
        case .actionItem: "checkmark.circle.fill"
        case .feedback: "chart.line.uptrend.xyaxis"
        }
    }

    var color: Color {
        switch self {
        case .suggestion: .blue
        case .blocker: .orange
        case .actionItem: .green
        case .feedback: .purple
        }
    }
}
