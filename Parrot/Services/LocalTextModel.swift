import Foundation
import MLXLLM
import MLXLMCommon

/// In-process translation / rewrite models. Same idea as WhisperKit: download
/// weights into Application Support, then run them inside Parrot. No Ollama.
enum LocalTextCatalog {
    struct Entry: Identifiable {
        let id: String
        let label: String
        let sizeLabel: String
        let configuration: ModelConfiguration
    }

    static let models: [Entry] = [
        Entry(id: "gemma3:1b",
              label: "gemma3:1b — fastest, Translation default",
              sizeLabel: "815 MB",
              configuration: LLMRegistry.gemma3_1B_qat_4bit),
        Entry(id: "qwen2.5:1.5b",
              label: "qwen2.5:1.5b — smaller multilingual",
              sizeLabel: "986 MB",
              configuration: LLMRegistry.qwen2_5_1_5b),
        Entry(id: "qwen2.5:3b",
              label: "qwen2.5:3b — strongest small multilingual",
              sizeLabel: "1.9 GB",
              configuration: ModelConfiguration(id: "mlx-community/Qwen2.5-3B-Instruct-4bit")),
        Entry(id: "llama3.2:3b",
              label: "llama3.2:3b — general",
              sizeLabel: "2.0 GB",
              configuration: LLMRegistry.llama3_2_3B_4bit),
    ]

    static var ids: [String] { models.map(\.id) }

    static func entry(id: String) -> Entry? {
        models.first { $0.id == id }
    }

    static var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}

/// Downloads and runs one MLX instruct model. Observed by Settings.
@MainActor
@Observable
final class LocalTextModel {
    static let shared = LocalTextModel()

    enum State: Equatable {
        case idle
        case missing
        case downloading(Double)
        case loading
        case ready
        case failed(String)
        case unsupported
    }

    enum ModelError: LocalizedError {
        case unsupported
        case unknownID(String)
        case notInstalled(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "On-device translation needs Apple Silicon."
            case .unknownID(let id):
                return "Unknown translation model \(id)."
            case .notInstalled(let id):
                return "Download \(id) in Settings → Translation — same as the Whisper model."
            case .empty:
                return "Empty rewrite"
            }
        }
    }

    var state: State = .idle
    private var container: ModelContainer?
    private var loadedID: String?
    private var loadGeneration = 0
    private var inFlight: (id: String, task: Task<ModelContainer, Error>)?

    static func isInstalled(_ id: String) -> Bool {
        guard let entry = LocalTextCatalog.entry(id: id) else { return false }
        let dir = entry.configuration.modelDirectory(hub: defaultHubApi)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) {
            return true
        }
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return false
        }
        return files.contains { ($0 as? URL)?.lastPathComponent == "config.json" }
    }

    func refresh(_ id: String) {
        if !LocalTextCatalog.isSupported {
            state = .unsupported
        } else if loadedID == id, container != nil {
            state = .ready
        } else if Self.isInstalled(id) {
            state = .idle
        } else {
            state = .missing
        }
    }

    func download(_ id: String) async {
        do {
            _ = try await load(id)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func ensureLoaded(_ id: String) async throws {
        _ = try await load(id)
    }

    /// Drop the resident weights. Local translation loads on start and
    /// calls this when that pass finishes so the GPU memory goes back.
    func unload() {
        loadGeneration += 1
        inFlight?.task.cancel()
        inFlight = nil
        container = nil
        loadedID = nil
        refresh(FeatureProcessing.translationOllamaModel)
    }

    /// Local mode only — Hybrid/Cloud keep the model out of this lifecycle.
    static func preloadForLocalTranslation() {
        guard FeatureProcessing.translation == .local else { return }
        Task { @MainActor in
            do {
                try await shared.ensureLoaded(FeatureProcessing.translationOllamaModel)
            } catch {
                NSLog("Parrot: local translation model — \(error.localizedDescription)")
            }
        }
    }

    static func unloadAfterLocalTranslation() {
        guard FeatureProcessing.translation == .local else { return }
        shared.unload()
    }

    func rewrite(_ text: String, instruction: String, model id: String) async throws -> String {
        let box = try await load(id)
        let chat: [Chat.Message] = [
            .system(instruction + " Reply with only the rewritten text."),
            .user(text),
        ]
        let userInput = UserInput(chat: chat)
        let params = GenerateParameters(maxTokens: 512, temperature: 0.2)
        let output = try await box.perform { context in
            let input = try await context.processor.prepare(input: userInput)
            let stream = try generate(input: input, parameters: params, context: context)
            var text = ""
            for await event in stream {
                if case .chunk(let chunk) = event { text += chunk }
            }
            return text
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelError.empty }
        return trimmed
    }

    private func load(_ id: String) async throws -> ModelContainer {
        guard LocalTextCatalog.isSupported else { throw ModelError.unsupported }
        guard let entry = LocalTextCatalog.entry(id: id) else { throw ModelError.unknownID(id) }
        if let container, loadedID == id { return container }
        if let inFlight, inFlight.id == id {
            return try await inFlight.task.value
        }

        loadGeneration += 1
        let generation = loadGeneration
        let installed = Self.isInstalled(id)
        state = installed ? .loading : .downloading(0)
        let task = Task<ModelContainer, Error> { @MainActor in
            do {
                let box = try await LLMModelFactory.shared.loadContainer(
                    configuration: entry.configuration
                ) { [weak self] progress in
                    let fraction = min(max(progress.fractionCompleted, 0), 1)
                    Task { @MainActor in
                        guard let self, self.loadGeneration == generation else { return }
                        if case .downloading = self.state {
                            self.state = .downloading(fraction)
                        }
                    }
                }
                guard self.loadGeneration == generation else { throw CancellationError() }
                self.container = box
                self.loadedID = id
                self.state = .ready
                return box
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if self.loadGeneration == generation {
                    self.state = .failed(error.localizedDescription)
                }
                throw error
            }
        }
        inFlight = (id, task)
        defer {
            if inFlight?.id == id { inFlight = nil }
        }
        return try await task.value
    }
}
