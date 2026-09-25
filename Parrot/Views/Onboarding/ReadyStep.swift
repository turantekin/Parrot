import SwiftUI

/// What's set up, Copilot first. Reads real state, so a download still in
/// flight says so.
struct ReadyStep: View {
    @Environment(OnboardingModel.self) private var model
    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage(CopilotPathSettings.enableWhenReadyKey) private var enableWhenReady = false
    @AppStorage(TranscriptionBackend.defaultsKey) private var backend = TranscriptionBackend.local.rawValue
    @AppStorage("copilotOllamaModel") private var ollamaModel = "llama3.2:3b"
    @State private var hasClaudeKey = false
    @State private var celebrate = false

    var body: some View {
        let ollama = recordingManager.ollama
        let status = CopilotStatus.current(
            copilotEnabled: copilotEnabled, path: model.path, enableWhenReady: enableWhenReady,
            ollamaPulling: ollama.isPulling, ollamaProgress: ollama.pullProgress, hasClaudeKey: hasClaudeKey)
        let copy = Self.copy(status, path: model.path, ollamaModel: ollamaModel)
        VStack(spacing: 16) {
            Text("🎉")
                .font(.system(size: 56))
                .scaleEffect(celebrate ? 1.0 : 0.4)
                .opacity(celebrate ? 1 : 0)
            StepHeader(title: model.mode == .copilot ? "Copilot is set up" : "Ready to go",
                       subtitle: "Downloads keep going after you close this.")
            CopilotHeroCard(title: copy.title, subtitle: copy.detail, emphasized: status == .on) {
                if status == .on {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.appTitle2)
                        .foregroundStyle(Theme.Colors.good)
                }
            }
            if model.mode == .full {
                if backend == TranscriptionBackend.deepgram.rawValue {
                    PermissionRow(icon: "waveform", askTitle: "", grantedTitle: "Live text: Deepgram",
                                  subtitle: "The speech model on this Mac is the backup", isGranted: true, action: {})
                }
                SpeechDownloadRow()
            }
        }
        .frame(maxWidth: 480)
        .padding(Theme.Metrics.pad)
        .onAppear {
            hasClaudeKey = APIKeyStore.load() != nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(0.05)) { celebrate = true }
        }
    }

    static func copy(_ status: CopilotStatus, path: CopilotPath?, ollamaModel: String) -> (title: String, detail: String) {
        switch status {
        case .on where path == .private:
            ("Copilot is on, running on this Mac", "\(ollamaModel). Nothing leaves your Mac.")
        case .on:
            ("Copilot is on, using Claude", "Only text is sent.")
        case .waitingForModel(let progress):
            ("Copilot turns on when \(ollamaModel) finishes",
             progress.map { "\(Int($0 * 100))% downloaded. Keep going." } ?? "Starting the download.")
        case .finishOllama:
            ("Copilot is almost there", "Finish the Ollama setup from the card on Home.")
        case .needsClaudeKey:
            ("Copilot needs a working Claude key", "Add it from the card on Home.")
        case .off:
            ("Copilot is off for now", "Set it up any time from the card on Home.")
        }
    }
}
