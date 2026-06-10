import Foundation
import Security

/// Raw insight returned by a provider; the engine attaches call timing.
struct InsightDraft {
    let kind: Insight.Kind
    let title: String
    let detail: String
    /// Document name the answer is grounded in, or "general knowledge".
    let source: String?
}

/// Everything a provider needs for one analysis pass.
struct AnalysisRequest {
    let transcript: String
    let knownInsightTitles: [String]
    /// Best-matching knowledge base chunks for the recent conversation.
    let references: [KBReference]
    /// The user's standing coaching instructions (tone, style, behavior).
    let instructions: String
    /// Optional one-line context for this specific call.
    let callBrief: String
    /// Whether the model may answer beyond the knowledge base.
    let allowGeneralKnowledge: Bool
}

/// Backend that turns a transcript window into structured insights.
/// Pluggable so a local-model provider can be added later without touching the engine.
protocol AnalysisProvider {
    var isConfigured: Bool { get }
    func analyze(_ request: AnalysisRequest) async throws -> [InsightDraft]
    func summarize(transcript: String, insightTitles: [String], instructions: String) async throws -> String
}

enum AnalysisError: LocalizedError {
    case missingAPIKey
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No Claude API key set. Add one in Settings → Copilot."
        case .badResponse(let message): message
        }
    }
}

/// Calls the Claude API (Haiku — fastest model) for low-latency structured insights.
final class ClaudeAnalysisProvider: AnalysisProvider {
    static let model = "claude-haiku-4-5"
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    var isConfigured: Bool {
        APIKeyStore.load()?.isEmpty == false
    }

    private static let systemPrompt = """
    You are a live call copilot. You receive a rolling transcript of an ongoing call \
    recorded on the user's Mac. Transcription is automatic, so expect minor errors, \
    missing punctuation, and chopped sentences. Each transcript line is prefixed with \
    the speaker: "Me" is the user you are assisting; "Them" is everyone else on the \
    call. Draft suggestions for Me to say.

    Produce only NEW, high-value insights about the most recent part of the conversation:
    - suggestion: Them asked something or raised a topic — draft a short, concrete \
    answer Me can say right now.
    - blocker: Them raised an objection or obstacle (price, timing, missing decision \
    maker, competitor) that Me has not resolved yet.
    - action_item: Me committed to do something after the call.
    - feedback: brief coaching on how the call is going (only when notable — e.g. Me \
    has been talking far more than Them for a while, or Them raised something Me \
    hasn't addressed).

    Grounding rules: when reference material from the user's knowledge base is provided \
    and covers a question, base the suggestion on it and set "source" to that document's \
    name. Never invent specifics (prices, terms, availability) that the references don't \
    state.

    Rules: never repeat an insight whose title you were told already exists. If nothing \
    new and useful happened, return an empty list. Keep titles under 8 words and details \
    under 2 sentences. Write in the same language as the conversation.
    """

    func analyze(_ request: AnalysisRequest) async throws -> [InsightDraft] {
        guard let apiKey = APIKeyStore.load(), !apiKey.isEmpty else {
            throw AnalysisError.missingAPIKey
        }

        let knownList = request.knownInsightTitles.isEmpty
            ? "(none)"
            : request.knownInsightTitles.map { "- \($0)" }.joined(separator: "\n")

        var sections: [String] = []

        if !request.instructions.isEmpty {
            sections.append("Coaching instructions from the user:\n\(request.instructions)")
        }

        if !request.callBrief.isEmpty {
            sections.append("Brief for this specific call:\n\(request.callBrief)")
        }

        if !request.references.isEmpty {
            let formatted = request.references.map { reference in
                var header = "[source: \(reference.documentName)]"
                if let note = reference.note {
                    header += " (user note: \(note))"
                }
                return header + "\n" + reference.text
            }.joined(separator: "\n\n")
            sections.append("Reference material from the user's knowledge base:\n\(formatted)")
        }

        sections.append(request.allowGeneralKnowledge
            ? "If the reference material doesn't cover a question, you may answer from "
              + "general knowledge — set \"source\" to \"general knowledge\" so the user "
              + "knows the answer is not from their documents."
            : "Only ground suggested answers in the reference material above. If it "
              + "doesn't cover a question, say so briefly in the suggestion instead of "
              + "answering from general knowledge, and leave \"source\" unset.")

        sections.append("Already shown insights (do not repeat):\n\(knownList)")
        sections.append("Rolling transcript (oldest to newest):\n\(request.transcript)")

        let userContent = sections.joined(separator: "\n\n---\n\n")

        let itemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ["suggestion", "blocker", "action_item", "feedback"]],
                "title": ["type": "string"],
                "detail": ["type": "string"],
                "source": ["type": "string"],
            ],
            "required": ["kind", "title", "detail"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "insights": ["type": "array", "items": itemSchema],
            ],
            "required": ["insights"],
            "additionalProperties": false,
        ]

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 1024,
            "system": Self.systemPrompt,
            "messages": [["role": "user", "content": userContent]],
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
        ]

        let data = try await performRequest(body: body, apiKey: apiKey)
        return try Self.parseInsights(from: data)
    }

    // MARK: - Post-Call Summary

    private static let summarySystemPrompt = """
    You write concise post-call reports from meeting transcripts. Transcription is \
    automatic, so expect minor errors and missing punctuation.

    Structure: a 2-3 sentence overview of what the call was about and how it ended, \
    then "Key points:" as short bullets, then "Next steps:" as bullets if any \
    commitments were made. Use plain text with simple "-" bullets, no markdown \
    headers. Write in the same language as the conversation.
    """

    func summarize(transcript: String, insightTitles: [String], instructions: String) async throws -> String {
        guard let apiKey = APIKeyStore.load(), !apiKey.isEmpty else {
            throw AnalysisError.missingAPIKey
        }

        var sections: [String] = []
        if !instructions.isEmpty {
            sections.append("User's standing instructions:\n\(instructions)")
        }
        if !insightTitles.isEmpty {
            sections.append("Insights captured live during the call:\n"
                + insightTitles.map { "- \($0)" }.joined(separator: "\n"))
        }
        sections.append("Full call transcript:\n\(transcript)")

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 1500,
            "system": Self.summarySystemPrompt,
            "messages": [["role": "user", "content": sections.joined(separator: "\n\n---\n\n")]],
        ]

        let data = try await performRequest(body: body, apiKey: apiKey)
        let response = try JSONDecoder().decode(MessagesResponse.self, from: data)
        guard let text = response.content.first(where: { $0.type == "text" })?.text else {
            throw AnalysisError.badResponse("Empty model response")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTTP

    private func performRequest(body: [String: Any], apiKey: String) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AnalysisError.badResponse("No HTTP response")
        }
        guard http.statusCode == 200 else {
            throw AnalysisError.badResponse(Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }
        return data
    }

    // MARK: - Response Parsing

    private struct MessagesResponse: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
        let content: [ContentBlock]
    }

    private struct InsightsPayload: Decodable {
        struct Item: Decodable {
            let kind: String
            let title: String
            let detail: String
            let source: String?
        }
        let insights: [Item]
    }

    private static func parseInsights(from data: Data) throws -> [InsightDraft] {
        let response = try JSONDecoder().decode(MessagesResponse.self, from: data)
        guard let text = response.content.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8) else {
            throw AnalysisError.badResponse("Empty model response")
        }
        let payload = try JSONDecoder().decode(InsightsPayload.self, from: jsonData)
        return payload.insights.compactMap { item in
            guard let kind = Insight.Kind(rawValue: item.kind) else { return nil }
            return InsightDraft(
                kind: kind,
                title: item.title,
                detail: item.detail,
                source: item.source?.nilIfEmpty
            )
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }
}

/// Stores the Claude API key in the user's keychain.
enum APIKeyStore {
    private static let service = "com.uygar.parrot"
    private static let account = "claude-api-key"

    static func save(_ key: String) {
        delete()
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
