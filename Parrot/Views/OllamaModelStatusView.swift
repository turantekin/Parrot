import SwiftUI

/// Lives under the Ollama model picker in Settings → Copilot, and at the top
/// of an Ask Parrot chat that uses Ollama (`hideWhenReady`): whether the
/// selected model is ready on this Mac, with a one-click download when it
/// isn't. A thin view over `OllamaService`, so a pull started in onboarding
/// shows here too and never starts twice.
struct OllamaModelStatusView: View {
    let model: String
    /// Ask Parrot shows this only when something needs fixing.
    var hideWhenReady = false
    @Environment(RecordingManager.self) private var recordingManager

    var body: some View {
        let ollama = recordingManager.ollama
        let status = ollama.status(for: model)
        HStack(spacing: 8) {
            switch status {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking Ollama…").foregroundStyle(Theme.Colors.ink2)

            case .serverDown:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
                Text("Ollama isn't open. Get it free at ollama.com, open it, then check again.")
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
                .disabled(ollama.isPulling)  // one pull at a time
                waitingNote(ollama)

            case .pulling(let progress):
                ProgressView(value: progress)
                    .frame(width: 140)
                Text(progress.map { "\(Int($0 * 100))%" } ?? "Starting…")
                    .foregroundStyle(Theme.Colors.ink2)
                    .font(Theme.Typography.mono(11))

            case .ready:
                if !hideWhenReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Colors.good)
                    Text("Ready. Runs on this Mac.")
                        .foregroundStyle(Theme.Colors.ink2)
                }

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
                Text("Download failed: \(message)")
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(2)
                Button("Retry") { ollama.pull(model) }
                    .buttonStyle(.link)
                    .disabled(ollama.isPulling)
                waitingNote(ollama)
            }
        }
        .font(Theme.Typography.caption)
        // Re-check whenever the selected model changes (also fires on appear).
        .task(id: model) { await ollama.refresh(model: model) }
    }

    /// Ollama pulls one model at a time; say why the button is off.
    @ViewBuilder
    private func waitingNote(_ ollama: OllamaService) -> some View {
        if let other = ollama.pullingModel, other != model {
            Text("Waiting for \(other) to finish downloading.")
                .foregroundStyle(Theme.Colors.ink3)
        }
    }
}
