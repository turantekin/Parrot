import Foundation

/// The local Ollama server, app-wide: is it up, is the chosen model there,
/// and the one model pull every screen reads (onboarding, Settings, the
/// Home card). It lives as long as the app, so a pull started in the setup
/// sheet keeps going and stays visible after the sheet closes. Talks only
/// to localhost:11434.
@MainActor
@Observable
final class OllamaService {
    enum Status: Equatable {
        case checking, serverDown, missing, pulling(progress: Double?), ready, failed(String)
    }

    enum PullEvent: Equatable { case progress(Double?), done, failed(String) }

    private(set) var status: Status = .checking
    /// The model `status` describes.
    private(set) var model = OpenAICompatibleProvider.ollamaModel
    private var pullTask: Task<Void, Never>?
    nonisolated private static let base = URL(string: "http://localhost:11434")!

    var isServerUp: Bool {
        switch status {
        case .checking, .serverDown: false
        default: true
        }
    }

    var isPulling: Bool {
        if case .pulling = status { true } else { false }
    }

    var pullProgress: Double? {
        if case .pulling(let progress) = status { progress } else { nil }
    }

    /// Re-reads the server and the model. Leaves a running pull of the same
    /// model alone, so polling never hides its progress.
    func refresh(model: String) async {
        if isPulling, model == self.model { return }
        if model != self.model {
            self.model = model
            status = .checking
        }
        guard let installed = await Self.installedModels() else {
            status = .serverDown
            return
        }
        let wasReady = status == .ready
        status = installed.contains(model) ? .ready : .missing
        if status == .ready, !wasReady { CopilotPathSettings.ollamaModelReady() }
    }

    /// Starts a pull unless one is already running.
    func pull(_ model: String) {
        guard pullTask == nil else { return }
        self.model = model
        status = .pulling(progress: nil)
        pullTask = Task { [weak self] in
            await self?.runPull(model)
            self?.pullTask = nil
        }
    }

    /// Launch: a private-path user whose model never finished gets the pull
    /// started again. Ollama keeps finished layers, so it picks up.
    func resumeIfNeeded(defaults: UserDefaults = .standard) async {
        guard defaults.string(forKey: CopilotPath.defaultsKey) == CopilotPath.private.rawValue,
              defaults.bool(forKey: CopilotPathSettings.enableWhenReadyKey) else { return }
        let model = OpenAICompatibleProvider.ollamaModel
        await refresh(model: model)
        if status == .missing { pull(model) }
    }

    private func runPull(_ model: String) async {
        do {
            var request = URLRequest(url: Self.base.appendingPathComponent("api/pull"))
            request.httpMethod = "POST"
            request.timeoutInterval = 3600  // multi-GB download
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                switch Self.parsePullLine(line) {
                case .progress(let progress)?:
                    status = .pulling(progress: progress)
                case .done?:
                    status = .ready
                    CopilotPathSettings.ollamaModelReady()
                    return
                case .failed(let message)?:
                    status = .failed(message)
                    return
                case nil:
                    continue
                }
            }
            status = .checking  // stream ended without a success line
            await refresh(model: model)
        } catch {
            status = .failed(error is URLError ? "Ollama stopped. Open it and try again." : error.localizedDescription)
        }
    }

    nonisolated static func parsePullLine(_ line: String) -> PullEvent? {
        struct Line: Decodable {
            let status: String?
            let total: Int64?
            let completed: Int64?
            let error: String?
        }
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Line.self, from: data) else { return nil }
        if let error = parsed.error { return .failed(error) }
        if parsed.status == "success" { return .done }
        if let total = parsed.total, let completed = parsed.completed, total > 0 {
            return .progress(Double(completed) / Double(total))
        }
        return nil
    }

    nonisolated private static func installedModels() async -> [String]? {
        struct Tags: Decodable {
            struct Entry: Decodable { let name: String }
            let models: [Entry]
        }
        var request = URLRequest(url: base.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return nil }
        return tags.models.map(\.name)
    }
}
