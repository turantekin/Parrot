import Foundation

// MARK: - Provider selection

/// Which backend powers the copilot. Persisted in UserDefaults ("copilotProvider");
/// Settings → Copilot writes it, SwitchingAnalysisProvider reads it per call.
enum CopilotProviderKind: String, CaseIterable, Identifiable {
    case claude
    case ollama
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: "Claude (cloud)"
        case .ollama: "Ollama (local)"
        case .custom: "Custom server"
        }
    }

    static var selected: CopilotProviderKind {
        CopilotProviderKind(rawValue: UserDefaults.standard.string(forKey: "copilotProvider") ?? "") ?? .claude
    }

    /// Model identifier the active backend will use — recorded per meeting for
    /// the cost row.
    static var activeModelName: String {
        switch selected {
        case .claude: ClaudeAnalysisProvider.model
        case .ollama: OpenAICompatibleProvider.ollamaModel
        case .custom: OpenAICompatibleProvider.customModel
        }
    }
}

// MARK: - Ollama model catalog

/// Curated local models for the Settings dropdown — small, non-"thinking"
/// instruct models only (reasoning models like qwen3/deepseek-r1 spend minutes
/// on hidden chain-of-thought and time out the live loop; measured 2026-07-17).
enum OllamaCatalog {
    struct Model {
        let id: String
        let label: String
        let sizeLabel: String
    }

    static let models: [Model] = [
        Model(id: "llama3.2:3b", label: "llama3.2:3b — fastest, good default", sizeLabel: "2.0 GB"),
        Model(id: "gemma3:4b", label: "gemma3:4b — better writing & languages", sizeLabel: "3.3 GB"),
    ]

    static var ids: [String] { models.map(\.id) }

    static func sizeLabel(for id: String) -> String? {
        models.first { $0.id == id }?.sizeLabel
    }
}

// MARK: - OpenAI-compatible provider

/// Talks to any OpenAI-compatible chat-completions server: Ollama on this Mac
/// (free, fully private) or a custom endpoint (OpenAI, Gemini, Groq, OpenRouter,
/// LM Studio…). Prompts, schema, and validation are shared with
/// ClaudeAnalysisProvider so every backend gets identical instructions — only
/// the transport and response envelope differ.
final class OpenAICompatibleProvider: AnalysisProvider {

    static var ollamaModel: String {
        UserDefaults.standard.string(forKey: "copilotOllamaModel")?.nilIfEmpty ?? "llama3.2:3b"
    }
    static var customModel: String {
        UserDefaults.standard.string(forKey: "copilotCustomModel") ?? ""
    }
    static var customBaseURL: String {
        UserDefaults.standard.string(forKey: "copilotCustomBaseURL") ?? ""
    }

    private struct Config {
        let baseURL: URL
        let model: String
        let apiKey: String?
    }

    /// Resolved fresh on every call so Settings changes apply immediately.
    private static func currentConfig() -> Config? {
        switch CopilotProviderKind.selected {
        case .claude:
            return nil
        case .ollama:
            return Config(baseURL: URL(string: "http://localhost:11434/v1")!,
                          model: ollamaModel, apiKey: nil)
        case .custom:
            let base = customBaseURL.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: base), !base.isEmpty, !customModel.isEmpty else { return nil }
            return Config(baseURL: url, model: customModel,
                          apiKey: APIKeyStore.load(account: "custom-llm-api-key"))
        }
    }

    var isConfigured: Bool { Self.currentConfig() != nil }

    // MARK: - Usage metering (same pattern as ClaudeAnalysisProvider)

    private let usageLock = NSLock()
    private var meteredUsage = AITokenTotals()

    var usageTotals: AITokenTotals {
        usageLock.lock(); defer { usageLock.unlock() }
        return meteredUsage
    }

    func resetUsage() {
        usageLock.lock(); defer { usageLock.unlock() }
        meteredUsage = AITokenTotals()
    }

    private func recordUsage(_ usage: ChatResponse.Usage?) {
        usageLock.lock(); defer { usageLock.unlock() }
        meteredUsage.inputTokens += usage?.promptTokens ?? 0
        meteredUsage.outputTokens += usage?.completionTokens ?? 0
        meteredUsage.calls += 1
    }

    // MARK: - AnalysisProvider

    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult {
        guard let config = Self.currentConfig() else {
            throw AnalysisError.badResponse("Copilot model not configured — check Settings → Copilot.")
        }

        let sys = ClaudeAnalysisProvider.systemPrompt(
            persona: request.persona, kinds: request.kinds,
            gauges: request.gauges, counterpart: request.counterpart)
        let userContent = ClaudeAnalysisProvider.analysisUserContent(request)
        let schemaObj = ClaudeAnalysisProvider.schema(kinds: request.kinds, gauges: request.gauges)

        let text = try await structuredChat(system: sys, user: userContent,
                                            schema: schemaObj, maxTokens: 1024, config: config)
        let parsed = try ClaudeAnalysisProvider.parseAnalysisPayload(text)
        let sourceValidated = ClaudeAnalysisProvider.validatingSources(
            parsed.insights, knownDocuments: request.knownDocumentNames)
        let kindValidated = ClaudeAnalysisProvider.validatingKinds(
            sourceValidated, allowed: Set(request.kinds.map(\.key)))
        return AnalysisResult(insights: kindValidated, sentiment: parsed.sentiment,
                              read: parsed.read, coach: parsed.coach, resolved: parsed.resolved)
    }

    func summarize(transcript: String, insightTitles: [String], instructions: String,
                   counterpart: String = "the other person") async throws -> String {
        guard let config = Self.currentConfig() else {
            throw AnalysisError.badResponse("Copilot model not configured — check Settings → Copilot.")
        }
        var sections: [String] = []
        if !instructions.isEmpty {
            sections.append("User's standing instructions:\n\(instructions)")
        }
        if !insightTitles.isEmpty {
            sections.append("Insights captured live during the call:\n"
                + insightTitles.map { "- \($0)" }.joined(separator: "\n"))
        }
        sections.append("Full call transcript:\n<transcript>\n\(transcript)\n</transcript>")

        return try await plainChat(
            system: ClaudeAnalysisProvider.summarySystemPrompt(counterpart: counterpart),
            user: sections.joined(separator: "\n\n---\n\n"),
            maxTokens: 1500, config: config)
    }

    func coachingReport(transcript: String, talkPercentMe: Int, instructions: String,
                        counterpart: String = "the other person") async throws -> String {
        guard let config = Self.currentConfig() else {
            throw AnalysisError.badResponse("Copilot model not configured — check Settings → Copilot.")
        }
        var sections: [String] = []
        if !instructions.isEmpty {
            sections.append("The user's standing goals/instructions:\n\(instructions)")
        }
        sections.append("Talk balance: you spoke roughly \(talkPercentMe)% of the words, "
            + "\(counterpart) \(100 - talkPercentMe)%.")
        sections.append("Full call transcript:\n<transcript>\n\(transcript)\n</transcript>")

        return try await plainChat(
            system: ClaudeAnalysisProvider.coachingSystemPrompt(counterpart: counterpart),
            user: sections.joined(separator: "\n\n---\n\n"),
            maxTokens: 1200, config: config)
    }

    // MARK: - Chat plumbing

    /// Structured-output call. Tries strict `json_schema` first (OpenAI, Ollama,
    /// OpenRouter, LM Studio all support it); if the server rejects the request,
    /// falls back once to loose `json_object` mode with the schema inlined in the
    /// prompt — the parse + validation layer catches drift either way.
    private func structuredChat(system: String, user: String, schema: [String: Any],
                                maxTokens: Int, config: Config) async throws -> String {
        let strictBody: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "analysis", "strict": true, "schema": schema],
            ],
        ]
        do {
            return try await send(body: strictBody, config: config)
        } catch let AnalysisError.badResponse(message) where message.contains("HTTP 4") || message.lowercased().contains("response_format") {
            // Server doesn't do strict schemas — inline it and ask for JSON mode.
            let schemaText = (try? JSONSerialization.data(withJSONObject: schema))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let fallbackBody: [String: Any] = [
                "model": config.model,
                "max_tokens": maxTokens,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user + "\n\n---\n\nRespond with ONLY a JSON object matching exactly this JSON Schema (no prose, no code fences):\n" + schemaText],
                ],
                "response_format": ["type": "json_object"],
            ]
            return try await send(body: fallbackBody, config: config)
        }
    }

    private func plainChat(system: String, user: String, maxTokens: Int,
                           config: Config) async throws -> String {
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        return try await send(body: body, config: config)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
        let choices: [Choice]
        let usage: Usage?
    }

    private func send(body: [String: Any], config: Config) async throws -> String {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        // Local models can take a while on first token (model load); generous cap.
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey?.nilIfEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // ponytail: single retry with fixed backoff on transient failures,
        // mirroring ClaudeAnalysisProvider.
        for attempt in 0..<2 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AnalysisError.badResponse("No HTTP response")
            }
            if attempt == 0, http.statusCode == 429 || http.statusCode >= 500 {
                try await Task.sleep(for: .seconds(2))
                continue
            }
            guard http.statusCode == 200 else {
                throw AnalysisError.badResponse(Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            recordUsage(decoded.usage)
            guard decoded.choices.first?.finishReason != "length" else {
                throw AnalysisError.badResponse("Response truncated (hit max_tokens)")
            }
            guard let content = decoded.choices.first?.message.content?.nilIfEmpty else {
                throw AnalysisError.badResponse("Empty model response")
            }
            return Self.stripCodeFence(content)
        }
        throw AnalysisError.badResponse("Unreachable")
    }

    /// Small local models sometimes wrap JSON in ``` fences despite instructions.
    static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        s = s.replacingOccurrences(of: "```json", with: "```")
        let parts = s.components(separatedBy: "```").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? s
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return object["error"] as? String
    }
}

// MARK: - Switching provider

/// Routes every call to the provider selected in Settings → Copilot. Both
/// concrete providers stay alive so token meters survive a mid-call settings
/// change; usage totals are the sum of both (same accepted edge case as the
/// transcription-backend note in RecordingManager.writeAIUsage).
final class SwitchingAnalysisProvider: AnalysisProvider {
    private let claude = ClaudeAnalysisProvider()
    private let compat = OpenAICompatibleProvider()

    private var active: AnalysisProvider {
        CopilotProviderKind.selected == .claude ? claude : compat
    }

    var isConfigured: Bool { active.isConfigured }

    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult {
        try await active.analyze(request)
    }

    func summarize(transcript: String, insightTitles: [String], instructions: String,
                   counterpart: String) async throws -> String {
        try await active.summarize(transcript: transcript, insightTitles: insightTitles,
                                   instructions: instructions, counterpart: counterpart)
    }

    func coachingReport(transcript: String, talkPercentMe: Int, instructions: String,
                        counterpart: String) async throws -> String {
        try await active.coachingReport(transcript: transcript, talkPercentMe: talkPercentMe,
                                        instructions: instructions, counterpart: counterpart)
    }

    var usageTotals: AITokenTotals {
        let a = claude.usageTotals
        let b = compat.usageTotals
        return AITokenTotals(inputTokens: a.inputTokens + b.inputTokens,
                             outputTokens: a.outputTokens + b.outputTokens,
                             calls: a.calls + b.calls)
    }

    func resetUsage() {
        claude.resetUsage()
        compat.resetUsage()
    }
}
