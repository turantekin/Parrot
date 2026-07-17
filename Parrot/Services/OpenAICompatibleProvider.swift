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

    /// The LIVE-cards provider ("copilotProvider" — pre-split installs carry
    /// their choice into the live role, which is the main experience).
    static var selected: CopilotProviderKind {
        CopilotProviderKind(rawValue: UserDefaults.standard.string(forKey: "copilotProvider") ?? "") ?? .claude
    }

    /// The post-call reports provider ("reportsProvider"); nil = same as live.
    static var reportsSelected: CopilotProviderKind? {
        let raw = UserDefaults.standard.string(forKey: "reportsProvider") ?? ""
        return raw.isEmpty ? nil : CopilotProviderKind(rawValue: raw)
    }

    static func modelName(for kind: CopilotProviderKind) -> String {
        switch kind {
        case .claude: ClaudeAnalysisProvider.model
        case .ollama: OpenAICompatibleProvider.ollamaModel
        case .custom: OpenAICompatibleProvider.customModel
        }
    }

    /// Model identifier the live backend will use — recorded per meeting for
    /// the cost row.
    static var activeModelName: String { modelName(for: selected) }
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

    /// Which kind this instance serves — a closure so the live/reports split can
    /// hand one instance per role and Settings changes apply on the next call.
    private let kindSource: () -> CopilotProviderKind

    init(kindSource: @escaping () -> CopilotProviderKind = { CopilotProviderKind.selected }) {
        self.kindSource = kindSource
    }

    private struct Config {
        let baseURL: URL
        let model: String
        let apiKey: String?
    }

    /// Resolved fresh on every call so Settings changes apply immediately.
    private func currentConfig() -> Config? {
        switch kindSource() {
        case .claude:
            return nil
        case .ollama:
            return Config(baseURL: URL(string: "http://localhost:11434/v1")!,
                          model: Self.ollamaModel, apiKey: nil)
        case .custom:
            let base = Self.customBaseURL.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: base), !base.isEmpty, !Self.customModel.isEmpty else { return nil }
            return Config(baseURL: url, model: Self.customModel,
                          apiKey: APIKeyStore.load(account: "custom-llm-api-key"))
        }
    }

    var isConfigured: Bool { currentConfig() != nil }

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
        recordNativeUsage(prompt: usage?.promptTokens, completion: usage?.completionTokens)
    }

    private func recordNativeUsage(prompt: Int?, completion: Int?) {
        usageLock.lock(); defer { usageLock.unlock() }
        meteredUsage.inputTokens += prompt ?? 0
        meteredUsage.outputTokens += completion ?? 0
        meteredUsage.calls += 1
    }

    // MARK: - AnalysisProvider

    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult {
        guard let config = currentConfig() else {
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
        guard let config = currentConfig() else {
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
        guard let config = currentConfig() else {
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

    /// Structured-output call — stays on the OpenAI-compat endpoint for EVERY
    /// kind, including Ollama: analysis prompts are small (rolling window,
    /// ~1-2k tokens — no truncation risk), and Ollama's native "format" param
    /// enforces the schema with grammar-constrained decoding that crawled at
    /// ~0.35 tok/s on gemma3:4b (measured 2026-07-17: 599s vs 28s for the same
    /// request). Loose schema + the validation layer is the right trade here.
    /// Tries strict `json_schema` first; falls back once to `json_object` with
    /// the schema inlined in the prompt.
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
        if kindSource() == .ollama {
            return try await sendOllamaNative(system: system, user: user, schema: nil,
                                              maxTokens: maxTokens, config: config)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
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

    // MARK: - Ollama native endpoint

    /// Ollama's OpenAI-compat endpoint silently TRUNCATES prompts to the model's
    /// default context (4096 tokens) and ignores num_ctx overrides — measured
    /// 2026-07-17: a 9k-token transcript came back as prompt_tokens: 2050. An
    /// hour-long call's report would quietly read only a slice of the call.
    /// The native /api/chat endpoint honors options.num_ctx, so REPORT calls
    /// (long transcript, plain text) go through it with the context sized to
    /// the prompt. Live analysis stays on the compat endpoint — see
    /// structuredChat for why (schema-grammar decoding is unusably slow).
    private func sendOllamaNative(system: String, user: String, schema: [String: Any]?,
                                  maxTokens: Int, config: Config) async throws -> String {
        // ~3 chars/token is conservative for mixed-language text; headroom for
        // the reply + template. Clamped: 32k ctx on a 3-4B model is ~2 GB of
        // KV cache — fine on Apple Silicon, and calls longer than that get the
        // most-recent-first truncation Ollama applies at the cap.
        // ROUNDED TO POWER-OF-TWO BUCKETS: Ollama reloads the whole model when
        // num_ctx changes between requests, and the summary + coaching calls
        // are seconds apart with slightly different prompt sizes — exact
        // sizing forced a ~30s reload in the middle of every report.
        let estimated = (system.count + user.count) / 3 + maxTokens + 512
        var numCtx = 4096
        while numCtx < estimated && numCtx < 32768 { numCtx *= 2 }

        var body: [String: Any] = [
            "model": config.model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["num_ctx": numCtx, "num_predict": maxTokens],
        ]
        if let schema { body["format"] = schema }

        // Native root = base URL without the /v1 suffix.
        var root = config.baseURL
        if root.lastPathComponent == "v1" { root.deleteLastPathComponent() }
        var request = URLRequest(url: root.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        // Prompt evaluation on a long transcript is minutes, not seconds, on
        // some machines — reports aren't latency-critical.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        struct NativeResponse: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let promptEvalCount: Int?
            let evalCount: Int?
            let doneReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case promptEvalCount = "prompt_eval_count"
                case evalCount = "eval_count"
                case doneReason = "done_reason"
            }
        }

        for attempt in 0..<2 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AnalysisError.badResponse("No HTTP response")
            }
            if attempt == 0, http.statusCode >= 500 {
                try await Task.sleep(for: .seconds(2))
                continue
            }
            guard http.statusCode == 200 else {
                throw AnalysisError.badResponse(Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(NativeResponse.self, from: data)
            recordNativeUsage(prompt: decoded.promptEvalCount, completion: decoded.evalCount)
            guard decoded.doneReason != "length" else {
                throw AnalysisError.badResponse("Response truncated (hit max_tokens)")
            }
            guard let content = decoded.message.content?.nilIfEmpty else {
                throw AnalysisError.badResponse("Empty model response")
            }
            return Self.stripCodeFence(content)
        }
        throw AnalysisError.badResponse("Unreachable")
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

/// Routes each call by JOB: live analysis passes go to the "Live cards"
/// provider, post-call summaries/coaching go to the "Post-call reports"
/// provider (Settings → Copilot). One compat instance per role keeps the token
/// meters separable so the cost row can price each bucket correctly. All
/// instances stay alive across settings changes; a mid-call switch mislabels
/// at most one meeting's rows (same accepted edge as the transcription-backend
/// note in RecordingManager.writeAIUsage).
final class SwitchingAnalysisProvider: AnalysisProvider {
    private let claude = ClaudeAnalysisProvider()
    private let liveCompat = OpenAICompatibleProvider { CopilotProviderKind.selected }
    private let reportsCompat = OpenAICompatibleProvider { SwitchingAnalysisProvider.reportsKind }

    static var liveKind: CopilotProviderKind { CopilotProviderKind.selected }

    /// Reports kind; "same as live" resolves to the live kind.
    static var reportsKind: CopilotProviderKind {
        CopilotProviderKind.reportsSelected ?? liveKind
    }

    private var liveProvider: AnalysisProvider {
        Self.liveKind == .claude ? claude : liveCompat
    }

    /// The reports provider, falling back to the live provider when the chosen
    /// one isn't configured — a report must never be lost to a half-set-up
    /// secondary backend.
    private var reportsProvider: AnalysisProvider {
        let kind = Self.reportsKind
        let candidate: AnalysisProvider = kind == .claude ? claude : reportsCompat
        return candidate.isConfigured ? candidate : liveProvider
    }

    /// Whether live and reports currently share one provider instance (single
    /// cost bucket in that case).
    private var rolesShareInstance: Bool {
        (liveProvider as AnyObject) === (reportsProvider as AnyObject)
    }

    var isConfigured: Bool { liveProvider.isConfigured }

    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult {
        try await liveProvider.analyze(request)
    }

    func summarize(transcript: String, insightTitles: [String], instructions: String,
                   counterpart: String) async throws -> String {
        try await reportsProvider.summarize(transcript: transcript, insightTitles: insightTitles,
                                            instructions: instructions, counterpart: counterpart)
    }

    func coachingReport(transcript: String, talkPercentMe: Int, instructions: String,
                        counterpart: String) async throws -> String {
        try await reportsProvider.coachingReport(transcript: transcript, talkPercentMe: talkPercentMe,
                                                 instructions: instructions, counterpart: counterpart)
    }

    // MARK: Role-split metering for the cost row

    /// Live bucket: model/provider label + tokens. When both roles share one
    /// instance this is the COMBINED bucket and `reportsUsage` is nil.
    var liveUsage: (model: String, provider: String, totals: AITokenTotals) {
        (CopilotProviderKind.modelName(for: Self.liveKind),
         Self.liveKind.rawValue,
         liveProvider.usageTotals)
    }

    /// Reports bucket, nil when reports ran on the live instance.
    var reportsUsage: (model: String, provider: String, totals: AITokenTotals)? {
        guard !rolesShareInstance else { return nil }
        let kind = Self.reportsKind
        return (CopilotProviderKind.modelName(for: kind),
                kind.rawValue,
                reportsProvider.usageTotals)
    }

    var usageTotals: AITokenTotals {
        [claude.usageTotals, liveCompat.usageTotals, reportsCompat.usageTotals]
            .reduce(AITokenTotals()) { acc, u in
                AITokenTotals(inputTokens: acc.inputTokens + u.inputTokens,
                              outputTokens: acc.outputTokens + u.outputTokens,
                              calls: acc.calls + u.calls)
            }
    }

    func resetUsage() {
        claude.resetUsage()
        liveCompat.resetUsage()
        reportsCompat.resetUsage()
    }
}
