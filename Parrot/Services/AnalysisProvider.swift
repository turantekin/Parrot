import Foundation
import Security

/// Raw insight returned by a provider; the engine attaches call timing.
struct InsightDraft {
    let kind: Insight.Kind
    let title: String
    let detail: String
}

/// Backend that turns a transcript window into structured insights.
/// Pluggable so a local-model provider can be added later without touching the engine.
protocol AnalysisProvider {
    var isConfigured: Bool { get }
    func analyze(transcript: String, knownInsightTitles: [String]) async throws -> [InsightDraft]
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
    missing punctuation, and chopped sentences.

    Produce only NEW, high-value insights about the most recent part of the conversation:
    - suggestion: the other party asked something or raised a topic — draft a short, \
    concrete answer the user can say right now.
    - blocker: an objection or obstacle was raised (price, timing, missing decision \
    maker, competitor) that has not been resolved yet.
    - action_item: the user committed to do something after the call.
    - feedback: brief coaching on how the call is going (only when notable).

    Rules: never repeat an insight whose title you were told already exists. If nothing \
    new and useful happened, return an empty list. Keep titles under 8 words and details \
    under 2 sentences. Write in the same language as the conversation.
    """

    func analyze(transcript: String, knownInsightTitles: [String]) async throws -> [InsightDraft] {
        guard let apiKey = APIKeyStore.load(), !apiKey.isEmpty else {
            throw AnalysisError.missingAPIKey
        }

        let knownList = knownInsightTitles.isEmpty
            ? "(none)"
            : knownInsightTitles.map { "- \($0)" }.joined(separator: "\n")

        let userContent = """
        Already shown insights (do not repeat):
        \(knownList)

        Rolling transcript (oldest to newest):
        \(transcript)
        """

        let itemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ["suggestion", "blocker", "action_item", "feedback"]],
                "title": ["type": "string"],
                "detail": ["type": "string"],
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

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
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

        return try Self.parseInsights(from: data)
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
            return InsightDraft(kind: kind, title: item.title, detail: item.detail)
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
