import SwiftUI

/// Lives under the Ollama model picker in Settings → Copilot and Translation:
/// shows whether the selected model is ready on this Mac and offers a one-click
/// download when it isn't. Talks only to the local Ollama server
/// (localhost:11434) — checking installed models via /api/tags and pulling
/// with streamed progress via /api/pull. Never touches the network beyond
/// loopback.
struct OllamaModelStatusView: View {
    let model: String

    private enum Status: Equatable {
        case checking
        case serverDown
        case missing
        case pulling
        case ready
        case failed(String)
    }

    @State private var status: Status = .checking
    /// nil while pulling = size not known yet (manifest phase).
    @State private var progress: Double?

    var body: some View {
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
                Button("Check Again") { Task { await refresh() } }
                    .buttonStyle(.link)

            case .missing:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.Colors.ink2)
                Text("Model not downloaded yet.")
                    .foregroundStyle(Theme.Colors.ink2)
                Button("Download (\(OllamaCatalog.sizeLabel(for: model) ?? "size varies"))") {
                    Task { await pull() }
                }
                .controlSize(.small)

            case .pulling:
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
                Button("Retry") { Task { await pull() } }
                    .buttonStyle(.link)
            }
        }
        .font(Theme.Typography.caption)
        // Re-check whenever the selected model changes (also fires on appear).
        .task(id: model) { await refresh() }
    }

    // MARK: - Local Ollama API

    private func refresh() async {
        status = .checking
        guard let installed = await Self.installedModels() else {
            status = .serverDown
            return
        }
        status = installed.contains(model) ? .ready : .missing
    }

    private static func installedModels() async -> [String]? {
        struct Tags: Decodable {
            struct Entry: Decodable { let name: String }
            let models: [Entry]
        }
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return nil }
        return tags.models.map(\.name)
    }

    private func pull() async {
        status = .pulling
        progress = nil
        struct Line: Decodable {
            let status: String?
            let total: Int64?
            let completed: Int64?
            let error: String?
        }
        do {
            var request = URLRequest(url: URL(string: "http://localhost:11434/api/pull")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 3600  // multi-GB download
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let update = try? JSONDecoder().decode(Line.self, from: data) else { continue }
                if let message = update.error {
                    status = .failed(message)
                    return
                }
                if let total = update.total, let completed = update.completed, total > 0 {
                    progress = Double(completed) / Double(total)
                }
                if update.status == "success" {
                    status = .ready
                    return
                }
            }
            await refresh()  // stream ended without an explicit success line
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

/// Catalog picker + download row. Used by Copilot and Translation.
struct OllamaModelPicker: View {
    @Binding var model: String
    var title: String = "Model"
    var hint: String?
    @State private var customEditing = false

    var body: some View {
        Picker(title, selection: selection) {
            ForEach(OllamaCatalog.models, id: \.id) { entry in
                Text(entry.label).tag(entry.id)
            }
            Divider()
            Text("Custom…").tag("custom")
        }
        .pickerStyle(.menu)

        if showsCustomField {
            LabeledContent("Model name") {
                TextField("", text: $model, prompt: Text("model:tag"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
            if let hint {
                Hint(hint)
            }
        }

        OllamaModelStatusView(model: model)
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                if customEditing { return "custom" }
                return OllamaCatalog.ids.contains(model) ? model : "custom"
            },
            set: { picked in
                if picked == "custom" {
                    customEditing = true
                } else {
                    customEditing = false
                    model = picked
                }
            }
        )
    }

    private var showsCustomField: Bool {
        customEditing || !OllamaCatalog.ids.contains(model)
    }
}

/// Download / load status for the in-process translation model (Whisper-style).
struct LocalTextModelStatusView: View {
    var modelID: String
    private var engine: LocalTextModel { LocalTextModel.shared }

    var body: some View {
        HStack(spacing: 8) {
            switch engine.state {
            case .idle:
                if LocalTextModel.isInstalled(modelID) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Colors.good)
                    Text("Downloaded — Local translation loads it when a session starts.")
                        .foregroundStyle(Theme.Colors.ink2)
                    Button("Load") { Task { await engine.download(modelID) } }
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Theme.Colors.ink2)
                    Text("Not downloaded yet.")
                        .foregroundStyle(Theme.Colors.ink2)
                    Button("Download (\(LocalTextCatalog.entry(id: modelID)?.sizeLabel ?? "size varies"))") {
                        Task { await engine.download(modelID) }
                    }
                    .controlSize(.small)
                }
            case .missing:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.Colors.ink2)
                Text("Not downloaded yet.")
                    .foregroundStyle(Theme.Colors.ink2)
                Button("Download (\(LocalTextCatalog.entry(id: modelID)?.sizeLabel ?? "size varies"))") {
                    Task { await engine.download(modelID) }
                }
                .controlSize(.small)
            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(width: 140)
                Text("\(Int(progress * 100))%")
                    .foregroundStyle(Theme.Colors.ink2)
                    .font(Theme.Typography.mono(11))
            case .loading:
                ProgressView().controlSize(.small)
                Text("Preparing \(modelID)…")
                    .foregroundStyle(Theme.Colors.ink2)
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.good)
                Text("Ready — unloads when the Local translation pass finishes.")
                    .foregroundStyle(Theme.Colors.ink2)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
                Text(message)
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(2)
                Button("Retry") { Task { await engine.download(modelID) } }
                    .buttonStyle(.link)
            case .unsupported:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warn)
                Text("On-device translation needs Apple Silicon.")
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .font(Theme.Typography.caption)
        .task(id: modelID) { engine.refresh(modelID) }
    }
}
