import Foundation

enum JevError: LocalizedError {
    case missingKey
    case badStatus(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: "No TypeSafe API key set."
        case .badStatus(let code): "TypeSafe HTTP \(code)"
        case .badResponse: "TypeSafe returned an unreadable answer"
        }
    }
}

/// TypeSafe AI "Jev" client behind the copilot's fast document-answer path.
/// Jev never writes text: given the other side's question and up to eight
/// knowledge-base chunks, it returns one probability per chunk that the chunk
/// states what was asked. The engine shows the best chunk as a "From your
/// docs" excerpt while Haiku is still writing. Claude mode only; the path
/// exists only when a key is in the Keychain.
///
/// Verified 2026-09-19 against docs.typesafe.ai: POST /v1/systemone, Bearer
/// auth, `noul` answers carry no confidence field (the probability is the
/// gate), $0.042 per million input tokens, output free.
final class JevDocMatcher {
    static let model = "jev-latest"
    static let keychainAccount = "typesafe-api-key"
    static let maxCandidates = 8
    /// Whole round trip. Measured from this Mac 2026-09-19: 0.27–0.34 s on a
    /// warm connection, 0.61–0.74 s cold (TLS handshake), hence warmUp().
    static let budget: TimeInterval = 0.7
    private let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private let apiKeyOverride: String?
    /// Own session so keep-alive connections stay ours and warm.
    private let session: URLSession

    /// `apiKey` overrides the Keychain (dev harnesses read the key through the
    /// `security` CLI so the unsigned binary never hits a consent dialog).
    init(apiKey: String? = nil) {
        apiKeyOverride = apiKey
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.budget
        config.timeoutIntervalForResource = Self.budget + 0.3
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config)
    }

    private var apiKey: String? {
        if let apiKeyOverride { return apiKeyOverride.isEmpty ? nil : apiKeyOverride }
        return APIKeyStore.load(account: Self.keychainAccount)?.nilIfEmpty
    }

    var isConfigured: Bool { apiKey != nil }

    // MARK: - Usage metering (same lock pattern as ClaudeAnalysisProvider)

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

    private func recordUsage(inputTokens: Int) {
        usageLock.lock(); defer { usageLock.unlock() }
        meteredUsage.inputTokens += inputTokens
        meteredUsage.calls += 1
    }

    // MARK: - Pure helpers (network-free, harness-tested)

    /// One request: JSON state with the question, a little context, and the
    /// chunks under c0…cN; one noul per chunk. Jev reads literally, so the
    /// instructions name the chunk key and tell it to ignore its siblings.
    static func buildBody(asked: String, before: String, candidates: [String]) -> [String: Any] {
        var state: [String: String] = ["asked": asked, "before": before]
        var questions: [String: [String: Any]] = [:]
        for (i, text) in candidates.prefix(maxCandidates).enumerated() {
            let key = "c\(i)"
            state[key] = text
            questions[key] = [
                "type": "noul",
                "instructions": "Does the text in `\(key)` state the information needed to directly answer the question in `asked`? Use `before` only to understand what `asked` refers to. Judge `\(key)` on its own; ignore the other c* texts.",
                "criteria": [
                    "true": "`\(key)` explicitly states the fact, number, price, policy, date, or procedure that `asked` is asking for.",
                    "false": "`\(key)` is only on a related topic, answers a different question, or gives no usable specifics.",
                ],
            ]
        }
        return ["model": model, "state": state, "questions": questions]
    }

    /// Probabilities by chunk index; a missing answer counts as 0.
    static func parse(_ data: Data, count: Int) throws -> [Double] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answers = obj["answers"] as? [String: Any] else { throw JevError.badResponse }
        return (0..<count).map { i in
            ((answers["c\(i)"] as? [String: Any])?["noul"] as? Double) ?? 0
        }
    }

    private static func inputTokens(from data: Data) -> Int {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((obj?["usage"] as? [String: Any])?["input_tokens"] as? Int) ?? 0
    }

    // MARK: - Network

    func score(asked: String, before: String, candidates: [String]) async throws -> [Double] {
        guard let apiKey else { throw JevError.missingKey }
        let body = Self.buildBody(asked: asked, before: before, candidates: candidates)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.budget
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JevError.badResponse }
        guard http.statusCode == 200 else { throw JevError.badStatus(http.statusCode) }
        recordUsage(inputTokens: Self.inputTokens(from: data))
        return try Self.parse(data, count: min(candidates.count, Self.maxCandidates))
    }

    /// Opens the TLS connection ahead of the first real question so the first
    /// excerpt is not the one that pays the handshake. Fire-and-forget; the
    /// tiny request is metered like any other (about 60 tokens).
    func warmUp() {
        guard isConfigured else { return }
        Task { _ = try? await score(asked: "ready", before: "", candidates: ["ready"]) }
    }
}
