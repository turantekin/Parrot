import Foundation
#if canImport(Translation)
import Translation
#endif

struct TranslationRequest: Sendable, Equatable {
    var clientIdentifier: String
    var text: String
    var sourceLanguage: String
    var targetLanguage: String
}

struct TranslationResponse: Sendable, Equatable {
    var clientIdentifier: String
    var text: String
}

protocol TranslationProviding: AnyObject {
    func translate(_ requests: [TranslationRequest]) async -> [TranslationResponse]
}

enum TranslationPolicy {
    static let minChars = 2
    static let enabledKey = "liveTranslationEnabled"
    static let targetKey = "translationTargetLanguage"

    static func shouldTranslate(source: String?, target: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minChars else { return false }
        guard !target.isEmpty else { return false }
        if let source, !source.isEmpty {
            let src = source.split(separator: "-").first.map(String.init) ?? source
            let dst = target.split(separator: "-").first.map(String.init) ?? target
            if src.caseInsensitiveCompare(dst) == .orderedSame { return false }
        }
        return true
    }

    static func mapBatch(
        _ requests: [TranslationRequest],
        responses: [TranslationResponse]
    ) -> [String: String] {
        var byID: [String: String] = [:]
        for response in responses {
            byID[response.clientIdentifier] = response.text
        }
        return byID
    }
}

/// Identity / map provider for `--profile-test` and `--translate-test`.
final class StubTranslationProvider: TranslationProviding {
    var map: [String: String] = [:]

    func translate(_ requests: [TranslationRequest]) async -> [TranslationResponse] {
        requests.compactMap { request in
            guard TranslationPolicy.shouldTranslate(
                source: request.sourceLanguage,
                target: request.targetLanguage,
                text: request.text
            ) else { return nil }
            let out = map[request.text] ?? request.text
            return TranslationResponse(clientIdentifier: request.clientIdentifier, text: out)
        }
    }
}

@MainActor
final class TranslationEngine {
    var provider: TranslationProviding

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: TranslationPolicy.enabledKey)
    }

    static var targetLanguage: String {
        let stored = UserDefaults.standard.string(forKey: TranslationPolicy.targetKey) ?? ""
        if !stored.isEmpty { return stored }
        return Locale.current.language.languageCode?.identifier ?? "en"
    }

    init(provider: TranslationProviding = StubTranslationProvider()) {
        self.provider = provider
    }

    func translateCommitted(
        text: String,
        id: String,
        sourceLanguage: String?
    ) async -> String? {
        let target = Self.targetLanguage
        let source = sourceLanguage ?? ""
        guard TranslationPolicy.shouldTranslate(source: sourceLanguage, target: target, text: text) else {
            return nil
        }
        let request = TranslationRequest(
            clientIdentifier: id,
            text: text,
            sourceLanguage: source,
            targetLanguage: target
        )
        let responses = await provider.translate([request])
        return responses.first?.text
    }

#if canImport(Translation)
    @available(macOS 15.0, *)
    func attachLiveSession(_ session: TranslationSession) {
        if let existing = provider as? AppleTranslationProvider {
            existing.attach(session)
        } else {
            let apple = AppleTranslationProvider()
            apple.attach(session)
            provider = apple
        }
    }
#endif
}

#if canImport(Translation)
/// Wraps a SwiftUI-owned `TranslationSession`. OS language packs live outside
/// the app; attaching the session must not sit on the decode task.
@available(macOS 15.0, *)
final class AppleTranslationProvider: TranslationProviding {
    private var session: TranslationSession?

    func attach(_ session: TranslationSession) {
        self.session = session
    }

    func translate(_ requests: [TranslationRequest]) async -> [TranslationResponse] {
        guard let session else { return [] }
        let batch = requests.compactMap { request -> TranslationSession.Request? in
            guard TranslationPolicy.shouldTranslate(
                source: request.sourceLanguage,
                target: request.targetLanguage,
                text: request.text
            ) else { return nil }
            return TranslationSession.Request(
                sourceText: request.text,
                clientIdentifier: request.clientIdentifier
            )
        }
        guard !batch.isEmpty else { return [] }
        do {
            let results = try await session.translations(from: batch)
            return results.map { result in
                TranslationResponse(
                    clientIdentifier: result.clientIdentifier ?? "",
                    text: result.targetText
                )
            }
        } catch {
            return []
        }
    }
}

@available(macOS 15.0, *)
enum LiveTranslationAvailability {
    static func status(from: String, to: String) async -> String {
        let availability = LanguageAvailability()
        let src = Locale.Language(components: Locale.Language.Components(identifier: from))
        let dst = Locale.Language(components: Locale.Language.Components(identifier: to))
        switch await availability.status(from: src, to: dst) {
        case .installed: return "installed"
        case .supported: return "supported"
        case .unsupported: return "unsupported"
        @unknown default: return "unknown"
        }
    }
}
#endif
