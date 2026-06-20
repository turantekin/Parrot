import Foundation
import Security

/// Raw insight returned by a provider; the engine attaches call timing.
struct InsightDraft {
    let kindKey: String
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
    /// All knowledge-base document names. Used to validate the model's "source"
    /// tag so it can't invent provenance like "call transcript".
    let knownDocumentNames: [String]
}

/// Backend that turns a transcript window into structured insights.
/// Pluggable so a local-model provider can be added later without touching the engine.
protocol AnalysisProvider {
    var isConfigured: Bool { get }
    func analyze(_ request: AnalysisRequest) async throws -> [InsightDraft]
    func summarize(transcript: String, insightTitles: [String], instructions: String) async throws -> String
    /// Post-call coaching + follow-ups: talk balance, what went well / to improve,
    /// objections handled vs missed, and commitments with any timing.
    func coachingReport(transcript: String, talkPercentMe: Int, instructions: String) async throws -> String
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
    - question: Them asked a direct question that Me has NOT answered yet — surface \
    it briefly so Me doesn't lose track of it. (Use this for open/unanswered \
    questions; use suggestion when you can actually draft the answer.)
    - blocker: Them raised an objection or obstacle (price, timing, missing decision \
    maker, competitor) that Me has not resolved yet.
    - action_item: Me committed to do something after the call. If a time or date \
    was mentioned ("by Friday", "next week"), include it in the detail.
    - feedback: a brief read on a SIGNIFICANT shift only — Them clearly turning \
    hesitant, frustrated, or enthusiastic, or Me dominating for a long stretch. Use \
    this sparingly (at most once every few minutes); skip routine commentary.

    Grounding rules: when reference material from the user's knowledge base is provided \
    and covers a question, base the suggestion on it and set "source" to that document's \
    EXACT name. Never invent specifics (prices, terms, availability) that the references \
    don't state.

    The "source" field is only a provenance tag. Set it to exactly one of: the exact \
    name of a provided knowledge-base document, or the literal "general knowledge" (only \
    when answering from general knowledge and that is allowed). Otherwise OMIT "source" \
    entirely. Never describe the conversation in it (e.g. "call transcript", "the \
    conversation", "rolling transcript") — that is always wrong.

    Rules: never repeat an insight whose title you were told already exists. Return at \
    most the 2 most valuable NEW insights per response — prefer fewer, and an empty list \
    when nothing important is new (that is common and expected, not a failure). Keep \
    titles under 8 words and details under 2 sentences. Write in the same language as \
    the conversation.
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
                "kind": ["type": "string", "enum": ["suggestion", "question", "blocker", "action_item", "feedback"]],
                "title": ["type": "string"],
                "detail": ["type": "string"],
                "source": ["type": "string", "description": "Exact knowledge-base document name, or 'general knowledge'. Omit otherwise — never a description of the conversation."],
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
        let drafts = try Self.parseInsights(from: data)
        return Self.validatingSources(drafts, knownDocuments: request.knownDocumentNames)
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

    // MARK: - Post-Call Coaching & Follow-ups

    private static let coachingSystemPrompt = """
    You are a sales/meeting coach reviewing a call transcript. "Me" is the person \
    you coach; "Them" is everyone else. Transcription is automatic, so expect minor \
    errors. Be specific, direct, and useful — not generic praise. Write plain text \
    with simple "-" bullets, no markdown headers. Use the same language as the call.

    Output exactly these sections, in order:
    Call snapshot: one line — overall how it went, plus the talk balance you're told.
    What went well: 1-3 concrete bullets quoting or referencing real moments.
    What to improve: 1-3 concrete, actionable bullets (e.g. "Them asked about pricing \
    twice and Me deflected both times — answer it directly next time").
    Objections & questions: list any objection or direct question Them raised and \
    whether Me actually addressed it (Handled / Missed).
    Commitments & follow-ups: every concrete next step either side committed to, with \
    any date/time mentioned. If none, write "- None".

    Keep the whole thing tight — a busy person should read it in 30 seconds.
    """

    func coachingReport(transcript: String, talkPercentMe: Int, instructions: String) async throws -> String {
        guard let apiKey = APIKeyStore.load(), !apiKey.isEmpty else {
            throw AnalysisError.missingAPIKey
        }

        var sections: [String] = []
        if !instructions.isEmpty {
            sections.append("The user's standing goals/instructions:\n\(instructions)")
        }
        sections.append("Talk balance: Me spoke roughly \(talkPercentMe)% of the words, "
            + "Them \(100 - talkPercentMe)%.")
        sections.append("Full call transcript:\n\(transcript)")

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 1200,
            "system": Self.coachingSystemPrompt,
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

    /// The model occasionally invents a "source" that describes the conversation
    /// ("call transcript", "rolling transcript", "conversation with coach"). Keep
    /// "source" only when it's a real KB document name or the literal "general
    /// knowledge"; otherwise drop it so the UI never shows a bogus provenance.
    private static func validatingSources(
        _ drafts: [InsightDraft],
        knownDocuments: [String]
    ) -> [InsightDraft] {
        let valid = Set(knownDocuments.map { $0.lowercased() })
        return drafts.map { draft in
            guard let source = draft.source else { return draft }
            let normalized = source.lowercased()
            if normalized == "general knowledge" || valid.contains(normalized) {
                return draft
            }
            return InsightDraft(kindKey: draft.kindKey, title: draft.title, detail: draft.detail, source: nil)
        }
    }

    private static func parseInsights(from data: Data) throws -> [InsightDraft] {
        let response = try JSONDecoder().decode(MessagesResponse.self, from: data)
        guard let text = response.content.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8) else {
            throw AnalysisError.badResponse("Empty model response")
        }
        let payload = try JSONDecoder().decode(InsightsPayload.self, from: jsonData)
        return payload.insights.map { item in
            InsightDraft(kindKey: item.kind, title: item.title, detail: item.detail, source: item.source?.nilIfEmpty)
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
