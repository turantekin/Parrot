import SwiftUI

/// Lives under the Ollama model picker in Settings → Copilot: whether the
/// selected model is ready on this Mac, with a one-click download when it
/// isn't. A thin view over `OllamaService`, so a pull started in onboarding
/// shows here too and never starts twice.
struct OllamaModelStatusView: View {
    let model: String
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        let ollama = recordingManager.ollama
        let status: OllamaService.Status = ollama.model == model ? ollama.status : .checking
        HStack(spacing: 8) {
            switch status {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking Ollama…").foregroundStyle(Theme.Colors.ink2)

            case .serverDown:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
                Text("Ollama isn't running — install it from ollama.com, then open it.")
                    .foregroundStyle(Theme.Colors.ink2)
                Button("Check Again") { Task { await ollama.refresh(model: model) } }
                    .buttonStyle(.link)

            case .missing:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.Colors.ink2)
                Text("Model not downloaded yet.")
                    .foregroundStyle(Theme.Colors.ink2)
                Button("Download (\(OllamaCatalog.sizeLabel(for: model) ?? "size varies"))") {
                    ollama.pull(model)
                }
                .controlSize(.small)

            case .pulling(let progress):
                ProgressView(value: progress)
                    .frame(width: 140)
                Text(progress.map { "\(Int($0 * 100))%" } ?? "Starting…")
                    .foregroundStyle(Theme.Colors.ink2)
                    .font(Theme.Typography.mono(11))

            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.good)
                Text("Ready — runs on this Mac.")
                    .foregroundStyle(Theme.Colors.ink2)

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
                Text("Download failed: \(message)")
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(2)
                Button("Retry") { ollama.pull(model) }
                    .buttonStyle(.link)
            }
        }
        .font(Theme.Typography.caption)
        // Re-check whenever the selected model changes (also fires on appear).
        .task(id: model) { await ollama.refresh(model: model) }
    }
}
