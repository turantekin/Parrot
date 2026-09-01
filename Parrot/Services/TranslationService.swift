import Foundation
import SwiftUI
#if canImport(Translation)
import Translation
#endif

enum TranslationLanguage: String, CaseIterable, Identifiable {
    case en, de, es, fr, it, pt, nl, tr, ru, ar, ur, zh, ja, ko, hi, hinglish

    var id: String { rawValue }

    var label: String {
        switch self {
        case .en: "English"
        case .de: "German"
        case .es: "Spanish"
        case .fr: "French"
        case .it: "Italian"
        case .pt: "Portuguese"
        case .nl: "Dutch"
        case .tr: "Turkish"
        case .ru: "Russian"
        case .ar: "Arabic"
        case .ur: "Urdu"
        case .zh: "Chinese"
        case .ja: "Japanese"
        case .ko: "Korean"
        case .hi: "Hindi"
        case .hinglish: "Hinglish"
        }
    }

    /// Sent to models. Hinglish is not a BCP-47 tag, so spell the mix out.
    var promptName: String {
        switch self {
        case .hinglish: "Hinglish (Hindi-English mix, Latin script)"
        default: label
        }
    }

    /// Live Translate target. Hinglish has no pack — Latin Hindi is the hint.
    var bcp47: String {
        switch self {
        case .en: "en"
        case .de: "de"
        case .es: "es"
        case .fr: "fr"
        case .it: "it"
        case .pt: "pt"
        case .nl: "nl"
        case .tr: "tr"
        case .ru: "ru"
        case .ar: "ar"
        case .ur: "ur"
        case .zh: "zh"
        case .ja: "ja"
        case .ko: "ko"
        case .hi: "hi"
        case .hinglish: "hi-Latn"
        }
    }
}

/// Apple Translation is opt-in. Packs are downloaded once when a language is
/// picked — never during a recording. If the pack is missing, the selected model
/// translates instead.
enum AppleTranslationGate {
    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    static var isEnabled: Bool {
        isSupported && UserDefaults.standard.bool(forKey: FeatureProcessing.appleTranslationKey)
    }

    static func sourceCode() -> String {
        let setting = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        if let setting, setting != "auto", !setting.isEmpty { return setting }
        return "en"
    }

    static func pairID(target: String) -> String {
        "\(sourceCode())>\(target)"
    }

    static func isReady(target: String) -> Bool {
        codes(FeatureProcessing.appleReadyKey).contains(pairID(target: target))
    }

    static func isDeclined(target: String) -> Bool {
        codes(FeatureProcessing.appleDeclinedKey).contains(pairID(target: target))
    }

    /// Live calls may use a pack that is already on disk. Local / Hybrid
    /// translation may use it without the Settings toggle — it is the small
    /// on-device model. The toggle still opts Cloud sessions in.
    static func mayUseDuringCall(target: String) -> Bool {
        guard isSupported, isReady(target: target) else { return false }
        if isEnabled { return true }
        return FeatureProcessing.translation.runsLocalModel
    }

    /// Ask for a pack before a call when the toggle is on, or when Translation
    /// is Local / Hybrid (Apple is the fallback if Ollama is down).
    static var shouldPrepPack: Bool {
        isEnabled || FeatureProcessing.translation.runsLocalModel
    }

    static func markReady(target: String) {
        insert(pairID(target: target), key: FeatureProcessing.appleReadyKey)
        remove(pairID(target: target), key: FeatureProcessing.appleDeclinedKey)
    }

    static func markDeclined(target: String) {
        insert(pairID(target: target), key: FeatureProcessing.appleDeclinedKey)
    }

    private static func codes(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func insert(_ value: String, key: String) {
        var set = codes(key)
        set.insert(value)
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    private static func remove(_ value: String, key: String) {
        var set = codes(key)
        set.remove(value)
        UserDefaults.standard.set(Array(set), forKey: key)
    }
}

/// What the downloaded Whisper model can do for translation. Its `language`
/// setting is the language being spoken — not the language to translate into.
/// `task: .translate` only emits English.
enum LocalTranslation {
    static func whisperTranslatesToEnglish(_ code: String) -> Bool {
        code == "en" || code.hasPrefix("en-")
    }

    static func isSameLanguage(target: String) -> Bool {
        let spoken = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
        guard spoken != "auto", !spoken.isEmpty else { return false }
        return spoken == target
    }

    static func unavailableMessage(target: String) -> String {
        if whisperTranslatesToEnglish(target) {
            return "Download the translation model in Settings → Translation — same as Whisper."
        }
        return "Whisper only translates speech into English. For other languages, download the translation model in Settings (same as Whisper) or an Apple pack, or use Hybrid / Cloud with a Gemini key."
    }
}

/// Display-only translations keyed by transcript segment id.
@MainActor
@Observable
final class TranslationStore {
    var lines: [UUID: String] = [:]
    /// Segment id → source text waiting for a session.
    var pending: [(id: UUID, text: String)] = []
    private var inFlight: Set<UUID> = []
    private var failed: Set<UUID> = []
    /// Hybrid skips Ollama after the first "not installed" so it does not
    /// retry a missing local model on every line.
    private var skipLocal = false
    /// When true, translation stays on even if the live toggle is off.
    var forced = false
    var notice: String?
    var targetCode: String = UserDefaults.standard.string(forKey: FeatureProcessing.translationTargetKey) ?? "en" {
        didSet { UserDefaults.standard.set(targetCode, forKey: FeatureProcessing.translationTargetKey) }
    }

    var isEnabled: Bool {
        forced || UserDefaults.standard.bool(forKey: FeatureProcessing.translationEnabledKey)
    }

    var target: String { targetCode }

    func reset() {
        lines = [:]
        pending = []
        inFlight = []
        failed = []
        skipLocal = false
    }

    /// Switch the output language. Existing lines are dropped and re-queued so
    /// everything from this moment is in `code`, spoken language aside.
    func setTarget(_ code: String, segments: [TranscriptSegment]) {
        if code != targetCode { targetCode = code }
        reset()
        enqueue(segments, force: true)
    }

    func enqueue(_ segments: [TranscriptSegment], force: Bool = false) {
        guard isEnabled else { return }
        LocalTextModel.preloadForLocalTranslation()
        let known = force ? Set<UUID>() : Set(lines.keys).union(pending.map(\.id)).union(failed)
        for segment in segments where !known.contains(segment.id) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if LocalTranslation.isSameLanguage(target: targetCode) {
                lines[segment.id] = text
                continue
            }
            pending.append((segment.id, text))
            // Second task next to live transcription — same mode rule.
            Task { await self.translate(id: segment.id, source: text) }
        }
    }

    func fillPending() async {
        let batch = pending
        await withTaskGroup(of: Void.self) { group in
            for item in batch where !failed.contains(item.id) {
                group.addTask { await self.translate(id: item.id, source: item.text) }
            }
        }
    }

    func applySpeech(_ id: UUID, _ text: String) {
        lines[id] = text
        pending.removeAll { $0.id == id }
        notice = nil
    }

    func applyApple(_ id: UUID, _ text: String) {
        applySpeech(id, text)
    }

    /// Local = downloaded model only. Hybrid = that model, then Gemini.
    /// Cloud = Gemini only. Apple is used only when the pack was already
    /// downloaded before the call.
    func translate(id: UUID, source: String, forceModel: Bool = false) async {
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        if !forceModel, AppleTranslationGate.mayUseDuringCall(target: target) {
            return
        }
        let mode = FeatureProcessing.translation
        let steps = TranslationRouting.destinations(for: mode)
        for destination in steps {
            if destination == .local, skipLocal { continue }
            if destination == .cloud, !TranslationRouting.usesGemini(mode) { continue }
            await modelFill(
                id: id,
                source: source,
                destination: destination,
                onlyIfBetter: destination == .cloud && mode == .hybrid,
                optional: destination == .local && mode == .hybrid)
        }
    }

    private func modelFill(id: UUID, source: String,
                           destination: TextRewriter.Destination,
                           onlyIfBetter: Bool,
                           optional: Bool) async {
        if destination == .cloud, !TranslationRouting.usesGemini(FeatureProcessing.translation) {
            return
        }
        let instruction = "Translate the following into \(targetLanguageName()) (\(target)). Reply with only the translation. Do not use any other language."
        do {
            let out = try await TextRewriter.rewrite(
                source, instruction: instruction, destination: destination,
                model: destination == .local ? FeatureProcessing.translationOllamaModel : nil)
            if onlyIfBetter, lines[id] != nil, out.isEmpty { return }
            lines[id] = out
            pending.removeAll { $0.id == id }
            notice = nil
        } catch {
            if optional {
                if TextRewriter.isLocalUnavailable(error) { skipLocal = true }
                return
            }
            failed.insert(id)
            pending.removeAll { $0.id == id }
            let message = destination == .local && TextRewriter.isLocalUnavailable(error)
                ? LocalTranslation.unavailableMessage(target: target)
                : error.localizedDescription
            guard notice != message else { return }
            notice = message
            NSLog("Parrot: translation failed — \(message)")
        }
    }

    func targetLanguageName() -> String {
        TranslationLanguage(rawValue: target)?.promptName ?? target
    }

}

/// Runs the selected local or cloud model over committed lines. Apple's
/// session is attached only when that pack is already installed.
struct LiveTranslationHost: ViewModifier {
    var store: TranslationStore
    var segments: [TranscriptSegment]
    var active: Bool

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *), AppleTranslationGate.mayUseDuringCall(target: store.target) {
            content
                .modifier(LiveAppleTranslationHost(store: store, segments: segments, active: active))
                .task(id: drainID) { await drainModels() }
        } else {
            content.task(id: drainID) { await drainModels() }
        }
        #else
        content.task(id: drainID) { await drainModels() }
        #endif
    }

    private var drainID: String {
        "\(active)-\(segments.count)-\(store.targetCode)"
    }

    private func drainModels() async {
        guard active else { return }
        store.enqueue(segments)
        await store.fillPending()
    }
}

/// Asks once, before a call, to download a single language pair. Never used
/// on the live recording screen.
struct AppleTranslationPrep: ViewModifier {
    var targetCode: String
    var enabled: Bool

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            content.modifier(AppleTranslationPrep15(targetCode: targetCode, enabled: enabled))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct AppleTranslationPrep15: ViewModifier {
    var targetCode: String
    var enabled: Bool
    @State private var ask = false
    @State private var languageName = ""
    @State private var prepareConfig: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .task(id: "\(enabled)-\(targetCode)") { await consider() }
            .alert("Download Apple language pack?", isPresented: $ask) {
                Button("Download") { startPrepare() }
                Button("Use selected model", role: .cancel) {
                    AppleTranslationGate.markDeclined(target: targetCode)
                }
            } message: {
                Text("Download the pack for \(languageName) now. This is asked once. Meetings will not show this dialog.")
            }
            .translationTask(prepareConfig) { session in
                do {
                    try await session.prepareTranslation()
                    AppleTranslationGate.markReady(target: targetCode)
                } catch {
                    AppleTranslationGate.markDeclined(target: targetCode)
                }
                await MainActor.run { prepareConfig = nil }
            }
    }

    private func consider() async {
        guard enabled else { return }
        guard !AppleTranslationGate.isReady(target: targetCode) else { return }
        guard !AppleTranslationGate.isDeclined(target: targetCode) else { return }
        let source = Locale.Language(identifier: AppleTranslationGate.sourceCode())
        let target = Locale.Language(identifier: targetCode)
        let status = await LanguageAvailability().status(from: source, to: target)
        languageName = TranslationLanguage(rawValue: targetCode)?.label ?? targetCode
        switch status {
        case .installed:
            AppleTranslationGate.markReady(target: targetCode)
        case .supported:
            ask = true
        default:
            AppleTranslationGate.markDeclined(target: targetCode)
        }
    }

    private func startPrepare() {
        prepareConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: AppleTranslationGate.sourceCode()),
            target: Locale.Language(identifier: targetCode)
        )
    }
}
#endif

#if canImport(Translation)
@available(macOS 15.0, *)
private struct LiveAppleTranslationHost: ViewModifier {
    var store: TranslationStore
    var segments: [TranscriptSegment]
    var active: Bool
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                store.enqueue(segments)
                let batch = store.pending
                for item in batch {
                    do {
                        let response = try await session.translate(item.text)
                        await MainActor.run { store.applyApple(item.id, response.targetText) }
                    } catch {
                        await store.translate(id: item.id, source: item.text, forceModel: true)
                    }
                }
            }
            .onAppear { sync() }
            .onChange(of: store.targetCode) { sync() }
            .onChange(of: active) { sync() }
            .onChange(of: segments.count) { poke() }
    }

    private func sync() {
        guard active, AppleTranslationGate.mayUseDuringCall(target: store.target) else {
            configuration = nil
            return
        }
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: AppleTranslationGate.sourceCode()),
            target: Locale.Language(identifier: store.target)
        )
    }

    private func poke() {
        guard AppleTranslationGate.mayUseDuringCall(target: store.target) else { return }
        if var current = configuration {
            current.invalidate()
            configuration = current
        } else {
            sync()
        }
    }
}
#endif
