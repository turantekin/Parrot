import AppKit
import Foundation

struct TransformItem: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var instruction: String
    var isBuiltIn: Bool
}

enum TransformCatalog {
    static let customsKey = "customTransforms"
    static let activeIDKey = "activeTransformID"

    static func builtins() -> [TransformItem] {
        TransformKind.allCases.map {
            TransformItem(id: $0.rawValue, name: $0.label, instruction: $0.instruction, isBuiltIn: true)
        }
    }

    static func customs() -> [TransformItem] {
        guard let data = UserDefaults.standard.data(forKey: customsKey),
              let items = try? JSONDecoder().decode([TransformItem].self, from: data) else { return [] }
        return items
    }

    static func all() -> [TransformItem] { builtins() + customs() }

    static func item(id: String) -> TransformItem? {
        all().first { $0.id == id }
    }

    static func saveCustoms(_ items: [TransformItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: customsKey)
        }
    }

    static func addCustom(name: String, instruction: String) -> TransformItem {
        var items = customs()
        let item = TransformItem(id: UUID().uuidString, name: name, instruction: instruction, isBuiltIn: false)
        items.append(item)
        saveCustoms(items)
        return item
    }

    static func updateCustom(_ item: TransformItem) {
        var items = customs()
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
            saveCustoms(items)
        }
    }

    static func deleteCustom(id: String) {
        saveCustoms(customs().filter { $0.id != id })
    }
}

enum TransformKind: String, CaseIterable, Identifiable {
    case polish, concise, bullets, formal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .polish: "Polish"
        case .concise: "Concise"
        case .bullets: "Bullets"
        case .formal: "Formal"
        }
    }

    var instruction: String {
        switch self {
        case .polish:
            "Rewrite the text so it is clear, grammatical, and natural. Keep the meaning. Do not add facts."
        case .concise:
            "Rewrite the text shorter. Keep every concrete fact. No preamble."
        case .bullets:
            "Rewrite the text as a short bullet list. One idea per bullet. No preamble."
        case .formal:
            "Rewrite the text in a formal professional tone. Keep the meaning. No preamble."
        }
    }
}

enum TextRewriter {
    enum Destination: CaseIterable, Equatable {
        case local
        case cloud
    }

    enum RewriteError: LocalizedError {
        case notConfigured(String)
        case badResponse(String)
        case overCap

        var errorDescription: String? {
            switch self {
            case .notConfigured(let message): message
            case .badResponse(let message): message
            case .overCap: "That's over the 1000-word cap."
            }
        }
    }

    static let wordCap = 1000
    /// Local transforms always hit Ollama on this Mac — never the cloud vendor.
    static let localChatURL = URL(string: "http://localhost:11434/v1/chat/completions")!
    /// Shown when localhost:11434 is down. Whisper downloads do not count.
    static let ollamaUnavailableMessage =
        "Local transforms need Ollama running on this Mac (localhost:11434)."

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    static func guardLength(_ text: String) throws {
        if wordCount(text) > wordCap { throw RewriteError.overCap }
    }

    static func rewrite(_ text: String, instruction: String, destination: Destination,
                        model: String? = nil) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        try guardLength(trimmed)
        let localModel = (model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? model! : OpenAICompatibleProvider.ollamaModel
        switch destination {
        case .local:
            if model != nil {
                let id = LocalTextCatalog.entry(id: localModel)?.id
                    ?? FeatureProcessing.translationOllamaDefault
                do {
                    return try await LocalTextModel.shared.rewrite(
                        trimmed, instruction: instruction, model: id)
                } catch let error as LocalTextModel.ModelError {
                    throw RewriteError.notConfigured(error.localizedDescription)
                }
            }
            do {
                return try await chatCompletions(
                    baseURL: localChatURL,
                    model: localModel,
                    apiKey: nil,
                    instruction: instruction,
                    text: trimmed)
            } catch is URLError {
                throw RewriteError.notConfigured(ollamaUnavailableMessage)
            } catch let RewriteError.badResponse(message)
                where message.contains("HTTP 404") || message.localizedCaseInsensitiveContains("not found") {
                throw RewriteError.notConfigured(
                    "Download \(localModel) in Settings → Translation — same as Whisper.")
            }
        case .cloud:
            return try await cloudRewrite(trimmed, instruction: instruction)
        }
    }

    private static func cloudRewrite(_ text: String, instruction: String) async throws -> String {
        switch CloudVendor.selected {
        case .gemini:
            guard let key = CloudVendor.gemini.speechKey() else {
                throw RewriteError.notConfigured("Add a Gemini key in Settings → API Keys.")
            }
            return try await geminiGenerate(text: text, instruction: instruction, apiKey: key)
        case .groq:
            guard let key = CloudVendor.groq.speechKey() else {
                throw RewriteError.notConfigured("Add a Groq key in Settings → API Keys.")
            }
            return try await chatCompletions(
                baseURL: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
                model: "llama-3.3-70b-versatile",
                apiKey: key,
                instruction: instruction,
                text: text)
        case .custom:
            let base = OpenAICompatibleProvider.customBaseURL.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: base), !base.isEmpty,
                  !OpenAICompatibleProvider.customModel.isEmpty else {
                throw RewriteError.notConfigured("Set a custom server in Settings → Copilot.")
            }
            let chatURL = url.path.contains("chat/completions") ? url
                : url.appendingPathComponent("chat/completions")
            return try await chatCompletions(
                baseURL: chatURL,
                model: OpenAICompatibleProvider.customModel,
                apiKey: CloudVendor.custom.speechKey(),
                instruction: instruction,
                text: text)
        }
    }

    private static func chatCompletions(baseURL: URL, model: String, apiKey: String?,
                                        instruction: String, text: String) async throws -> String {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": instruction + " Reply with only the rewritten text."],
                ["role": "user", "content": text],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RewriteError.badResponse("HTTP \(code)")
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = object?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard let content = message?["content"] as? String else {
            throw RewriteError.badResponse("Empty rewrite")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Connection refused, missing Ollama tag, or the old Settings copy.
    static func isLocalUnavailable(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return text.localizedCaseInsensitiveContains("Ollama")
            || text.localizedCaseInsensitiveContains("localhost")
            || text.localizedCaseInsensitiveContains("Install a local model")
            || text.localizedCaseInsensitiveContains("same as Whisper")
            || text.localizedCaseInsensitiveContains("same as the Whisper")
            || text.localizedCaseInsensitiveContains("Download") && text.localizedCaseInsensitiveContains("Translation")
    }

    private static func geminiGenerate(text: String, instruction: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": instruction + "\n\n" + text]]],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RewriteError.badResponse(Self.geminiError(data, fallbackCode: (response as? HTTPURLResponse)?.statusCode ?? 0))
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let candidates = object?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        guard let out = parts?.first?["text"] as? String else {
            throw RewriteError.badResponse("Empty Gemini rewrite")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull Google's error message. API_KEY_INVALID is the usual paste/save miss.
    static func geminiError(_ data: Data, fallbackCode: Int) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? ""
        if message.localizedCaseInsensitiveContains("API key not valid")
            || message.localizedCaseInsensitiveContains("API_KEY_INVALID") {
            return "Gemini rejected the API key. Paste an AI Studio key (AIza…) in Settings → API Keys and click Save Key."
        }
        if !message.isEmpty {
            let short = message.count > 140 ? String(message.prefix(140)) + "…" : message
            return "Gemini HTTP \(fallbackCode): \(short)"
        }
        return "Gemini HTTP \(fallbackCode)"
    }
}

enum ClipboardOut {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static var changeCount: Int { NSPasteboard.general.changeCount }
}
