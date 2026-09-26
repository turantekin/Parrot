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

    /// What the last check found for each model a screen asked about; the
    /// model being pulled holds the pull's progress instead.
    private(set) var statuses: [String: Status] = [:]
    /// The one model downloading. A check of it never overwrites the pull's
    /// progress, and a check of any other model never touches the pull.
    private(set) var pullingModel: String?
    /// False until a check reaches the server.
    private(set) var isServerUp = false
    private let defaults: UserDefaults
    nonisolated private static let base = URL(string: "http://localhost:11434")!

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func status(for model: String) -> Status { statuses[model] ?? .checking }

    var isPulling: Bool { pullingModel != nil }

    var pullProgress: Double? {
        guard let pullingModel, case .pulling(let progress)? = statuses[pullingModel] else { return nil }
        return progress
    }

    /// Re-reads the server and the model.
    func refresh(model: String) async {
        record(installed: await Self.installedModels(), for: model)
    }

    /// One check's result (`nil`: server down). Leaves a running pull alone.
    /// A ready model honours a pending "turn Copilot on" every time; that's
    /// a no-op unless setup is waiting on exactly this model.
    func record(installed: [String]?, for model: String) {
        isServerUp = installed != nil
        guard model != pullingModel else { return }
        guard let installed else {
            statuses[model] = .serverDown
            return
        }
        statuses[model] = installed.contains(model) ? .ready : .missing
        if statuses[model] == .ready { CopilotPathSettings.ollamaModelReady(model, in: defaults) }
    }

    /// Starts a pull unless one is already running.
    func pull(_ model: String) {
        guard beginPull(model) else { return }
        Task { [weak self] in await self?.runPull(model) }
    }

    /// Marks `model` as downloading; false when another pull holds the slot.
    func beginPull(_ model: String) -> Bool {
        guard pullingModel == nil else { return false }
        pullingModel = model
        statuses[model] = .pulling(progress: nil)
        return true
    }

    /// Launch: a private-path user whose model never finished gets the pull
    /// started again. Ollama keeps finished layers, so it picks up.
    func resumeIfNeeded(defaults: UserDefaults = .standard) async {
        guard defaults.string(forKey: CopilotPath.defaultsKey) == CopilotPath.private.rawValue,
              defaults.bool(forKey: CopilotPathSettings.enableWhenReadyKey) else { return }
        let model = OpenAICompatibleProvider.ollamaModel
        await refresh(model: model)
        if status(for: model) == .missing { pull(model) }
    }

    private func runPull(_ model: String) async {
        defer { pullingModel = nil }
        do {
            var request = URLRequest(url: Self.base.appendingPathComponent("api/pull"))
            request.httpMethod = "POST"
            request.timeoutInterval = 3600  // multi-GB download
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            for try await line in bytes.lines {
                switch Self.parsePullLine(line) {
                case .progress(let progress)?:
                    statuses[model] = .pulling(progress: progress)
                case .done?:
                    statuses[model] = .ready
                    CopilotPathSettings.ollamaModelReady(model, in: defaults)
                    return
                case .failed(let message)?:
                    statuses[model] = .failed(message)
                    return
                case nil:
                    continue
                }
            }
            pullingModel = nil  // stream ended without a success line: check again
            statuses[model] = .checking
            await refresh(model: model)
        } catch {
            statuses[model] = .failed(error is URLError ? "Ollama stopped. Open it and try again." : error.localizedDescription)
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
