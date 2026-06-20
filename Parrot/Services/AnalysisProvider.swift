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
    /// Tone/style for this call (carries the profile's `tone`).
    let instructions: String
    /// Optional one-line context for this specific call.
    let callBrief: String
    /// Whether the model may answer beyond the knowledge base.
    let allowGeneralKnowledge: Bool
    /// All knowledge-base document names. Used to validate the model's "source"
    /// tag so it can't invent provenance like "call transcript".
    let knownDocumentNames: [String]
    /// Profile persona/framing paragraph.
    let persona: String
    /// Reshapable insight kinds — drive the prompt's kind list and the schema enum.
    let kinds: [ProfileKind]
    /// Sentiment gauges to read each pass.
    let gauges: [SentimentGauge]
}

/// Combined result from one analysis pass: structured insights plus a sentiment reading.
struct AnalysisResult {
    let insights: [InsightDraft]
    let sentiment: [String: Int]
    let read: String?
}

/// Backend that turns a transcript window into structured insights.
/// Pluggable so a local-model provider can be added later without touching the engine.
protocol AnalysisProvider {
    var isConfigured: Bool { get }
    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult
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

    // MARK: - Pure static helpers (network-free, testable)

    static func buildKindList(_ kinds: [ProfileKind]) -> String {
        kinds.sorted { $0.priority > $1.priority }
            .map { "- \($0.key): \($0.triggerDescription)" }
            .joined(separator: "\n")
    }

    static func systemPrompt(persona: String, kinds: [ProfileKind], gauges: [SentimentGauge]) -> String {
        var p = """
        You are a live call copilot. You receive a rolling transcript of an ongoing call. \
        Transcription is automatic, so expect minor errors and chopped sentences. Each line \
        is prefixed with the speaker: "Me" is the user you assist; "Them" is everyone else.

        \(persona)

        Produce only NEW, high-value insights about the most recent part of the conversation. \
        Each insight has a "kind" — use exactly one of these and follow its rule:
        \(buildKindList(kinds))

        Grounding: when knowledge-base reference material is provided and covers a question, \
        base the answer on it and set "source" to that document's EXACT name. Never invent \
        specifics the references don't state. The "source" field is only a provenance tag: set \
        it to exactly the name of a provided document, or the literal "general knowledge" (only \
        when allowed), otherwise OMIT it. Never describe the conversation in it.

        Rules: never repeat an insight whose title already exists. Return at most the 2 most \
        valuable NEW insights per response — prefer fewer; an empty list is common and fine. \
        Keep titles under 8 words and details under 2 sentences. Same language as the call.
        """
        if !gauges.isEmpty {
            let list = gauges.map { "- \($0.key): 0 = \($0.lowLabel), 100 = \($0.highLabel) (\($0.label))" }.joined(separator: "\n")
            p += """


            Also return a "sentiment" object reading the room right now, as an integer 0–100 for \
            each gauge, plus a one-word "read":
            \(list)
            """
        }
        return p
    }

    static func schema(kinds: [ProfileKind], gauges: [SentimentGauge]) -> [String: Any] {
        let itemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": kinds.map(\.key)],
                "title": ["type": "string"],
                "detail": ["type": "string"],
                "source": ["type": "string", "description": "Exact KB document name, or 'general knowledge'. Omit otherwise."],
            ],
            "required": ["kind", "title", "detail"],
            "additionalProperties": false,
        ]
        var properties: [String: Any] = ["insights": ["type": "array", "items": itemSchema]]
        var required = ["insights"]
        if !gauges.isEmpty {
            var sentProps: [String: Any] = [:]
            for g in gauges { sentProps[g.key] = ["type": "integer", "minimum": 0, "maximum": 100] }
            sentProps["read"] = ["type": "string"]
            properties["sentiment"] = ["type": "object", "properties": sentProps, "additionalProperties": false]
            required.append("sentiment")
        }
        return ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    static func validatingKinds(_ drafts: [InsightDraft], allowed: Set<String>) -> [InsightDraft] {
        drafts.filter { allowed.contains($0.kindKey) }
    }

    // MARK: - Live Analysis

    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult {
        guard let apiKey = APIKeyStore.load(), !apiKey.isEmpty else {
            throw AnalysisError.missingAPIKey
        }

        let knownList = request.knownInsightTitles.isEmpty
            ? "(none)"
            : request.knownInsightTitles.map { "- \($0)" }.joined(separator: "\n")

        var sections: [String] = []

        if !request.instructions.isEmpty {
            sections.append("Tone/style from the user:\n\(request.instructions)")
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

        let sys = Self.systemPrompt(persona: request.persona, kinds: request.kinds, gauges: request.gauges)
        let schemaObj = Self.schema(kinds: request.kinds, gauges: request.gauges)

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 1024,
            "system": sys,
            "messages": [["role": "user", "content": userContent]],
            "output_config": ["format": ["type": "json_schema", "schema": schemaObj]],
        ]

        let data = try await performRequest(body: body, apiKey: apiKey)
        let parsed = try Self.parseResult(from: data)
        let sourceValidated = Self.validatingSources(parsed.insights, knownDocuments: request.knownDocumentNames)
        let kindValidated = Self.validatingKinds(sourceValidated, allowed: Set(request.kinds.map(\.key)))
        return AnalysisResult(insights: kindValidated, sentiment: parsed.sentiment, read: parsed.read)
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

    private static func parseResult(from data: Data) throws -> (insights: [InsightDraft], sentiment: [String: Int], read: String?) {
        let response = try JSONDecoder().decode(MessagesResponse.self, from: data)
        guard let text = response.content.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8) else {
            throw AnalysisError.badResponse("Empty model response")
        }
        let obj = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] ?? [:]
        let items = (obj["insights"] as? [[String: Any]]) ?? []
        let drafts = items.compactMap { item -> InsightDraft? in
            guard let kind = item["kind"] as? String, let title = item["title"] as? String,
                  let detail = item["detail"] as? String else { return nil }
            return InsightDraft(kindKey: kind, title: title, detail: detail, source: (item["source"] as? String)?.nilIfEmpty)
        }
        var sentiment: [String: Int] = [:]
        var read: String? = nil
        if let s = obj["sentiment"] as? [String: Any] {
            for (k, v) in s {
                if k == "read" { read = v as? String }
                else if let i = v as? Int { sentiment[k] = i }
                else if let d = v as? Double { sentiment[k] = Int(d) }
            }
        }
        return (drafts, sentiment, read)
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
