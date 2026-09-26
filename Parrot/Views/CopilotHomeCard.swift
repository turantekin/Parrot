import SwiftUI

/// On Home when Copilot is off or half set up: why it's worth it and a way
/// back into setup. Also says "Copilot is on" once, right after it switched
/// itself on when the Ollama model finished. The close button hides the
/// nudge for good; Settings → Copilot keeps the same button.
struct CopilotHomeCard: View {
    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage(CopilotPath.defaultsKey) private var pathRaw = ""
    @AppStorage(CopilotPathSettings.enableWhenReadyKey) private var enableWhenReady = false
    @AppStorage(CopilotPathSettings.cardDismissedKey) private var dismissed = false
    @AppStorage(CopilotPathSettings.justTurnedOnKey) private var justTurnedOn = false
    @AppStorage("copilotOllamaModel") private var ollamaModel = "llama3.2:3b"
    @State private var hasClaudeKey = false

    var body: some View {
        let ollama = recordingManager.ollama
        let status = CopilotStatus.current(
            copilotEnabled: copilotEnabled, path: CopilotPath(rawValue: pathRaw), enableWhenReady: enableWhenReady,
            ollamaPulling: ollama.isPulling, ollamaProgress: ollama.pullProgress, hasClaudeKey: hasClaudeKey)
        Group {
            if CopilotStatus.showsHomeCard(status, dismissed: dismissed, justTurnedOn: justTurnedOn) {
                card(status)
            }
        }
        .task { hasClaudeKey = await APIKeyStore.loadInBackground() != nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { hasClaudeKey = await APIKeyStore.loadInBackground() != nil }
        }
    }

    @ViewBuilder
    private func card(_ status: CopilotStatus) -> some View {
        switch status {
        case .on:
            CopilotHeroCard(title: "Copilot is on",
                            subtitle: "It opens beside your next call and shows answers as they ask.") {
                closeButton { justTurnedOn = false }
            }
        case .waitingForModel(let progress):
            CopilotHeroCard(title: "Copilot turns on when \(ollamaModel) finishes",
                            subtitle: progress.map { "\(Int($0 * 100))% downloaded" } ?? "Starting the download",
                            emphasized: false) {
                ProgressView(value: progress)
                    .frame(width: 90)
            }
        case .finishOllama, .needsClaudeKey, .off:
            nudge(status)
        }
    }

    private func nudge(_ status: CopilotStatus) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius)
        return VStack(alignment: .leading, spacing: 12) {
            CopilotHeroCard(title: status == .off ? "Turn on Copilot" : "Finish setting up Copilot",
                            subtitle: reason(status), bordered: false) {
                closeButton { dismissed = true }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(Theme.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("They ask about security. Copilot suggests:")
                        .foregroundStyle(Theme.Colors.ink2)
                    Text("“All audio stays on your Mac. Only the text goes to the AI.”")
                }
                .font(Theme.Typography.secondary)
            }
            .padding(Theme.Metrics.popoverPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            HStack(spacing: 10) {
                Button("Set up Copilot") { MeetingActions.showCopilotSetup() }
                    .buttonStyle(.borderedProminent)
                Text("Takes about 2 minutes")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .padding(Theme.Metrics.pad)
        .overlay(shape.stroke(Theme.Colors.spotlightLine, lineWidth: 1.5))
    }

    private func reason(_ status: CopilotStatus) -> String {
        switch status {
        case .finishOllama: "Finish the Ollama setup to turn it on."
        case .needsClaudeKey: "It needs a working Claude key."
        default: "Suggested answers, pinned deal-breakers and a live call score, while you talk."
        }
    }

    private func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .foregroundStyle(Theme.Colors.ink3)
        }
        .buttonStyle(.plain)
        .help("Hide")
        .accessibilityLabel("Hide")
    }
}
