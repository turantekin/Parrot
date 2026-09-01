import Foundation
import SwiftData

// MARK: - Language + glossary

enum GeminiLanguage {
    /// Settings language tags → BCP-47. `auto` / empty → detect.
    static func bcp47(from setting: String?) -> [String] {
        switch setting {
        case nil, "", "auto": []
        case "en": ["en-US"]
        case "de": ["de-DE"]
        case "es": ["es-US"]
        case "fr": ["fr-FR"]
        case "it": ["it-IT"]
        case "pt": ["pt-BR"]
        case "nl": ["nl-NL"]
        case "tr": ["tr-TR"]
        case "ru": ["ru-RU"]
        case "ar": ["ar-EG"]
        case "zh": ["cmn-Hans-CN"]
        case "ja": ["ja-JP"]
        case "ko": ["ko-KR"]
        case "hi": ["hi-IN"]
        case "ur", "hinglish": []
        default: [setting!]
        }
    }
}

enum GeminiGlossary {
    static func terms(from raw: String, cap: Int = 100) -> [String] {
        raw
            .split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(cap)
            .map { String($0) }
    }
}

// MARK: - Window math

enum RefineWindow {
    /// Completed windows whose end is ≤ `elapsed`. Overlap is subtracted from
    /// the start of window 1… so a clipped word at the boundary is retried.
    static func completed(elapsed: Double, window: Double, overlap: Double) -> [(start: Double, end: Double)] {
        guard window > 0, elapsed >= window else { return [] }
        let count = Int(elapsed / window)
        return (0..<count).map { i in
            let end = Double(i + 1) * window
            let start = i == 0 ? 0 : max(0, Double(i) * window - overlap)
            return (start, end)
        }
    }
}

// MARK: - In-window patch plan

enum SegmentPatcher {
    struct Existing {
        let index: Int
        let start: Double
        let end: Double
        let speaker: String
    }

    /// Rows whose start is before `windowEnd` are in-window (replaceable).
    /// Rows at or after `windowEnd` are the hot tail and must be kept.
    static func partition(starts: [Double], windowEnd: Double) -> (inWindow: [Int], tail: [Int]) {
        var inWindow: [Int] = []
        var tail: [Int] = []
        for (i, start) in starts.enumerated() {
            if start < windowEnd { inWindow.append(i) } else { tail.append(i) }
        }
        return (inWindow, tail)
    }
}

// MARK: - Interactions client

enum GeminiTranscriber {
    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    static let model = "gemini-3.5-transcribe"
    static let keychainAccount = "gemini-api-key"

    struct Word {
        let text: String
        let start: Double
        let end: Double
    }

    enum TranscribeError: LocalizedError {
        case missingKey
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: "No Gemini API key."
            case .badResponse(let message): message
            }
        }
    }

    static func timeout(forWindowSeconds window: Double) -> TimeInterval {
        max(90, 30 + window / 2)
    }

    static func parseOffset(_ raw: String?) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasSuffix("s") { s.removeLast() }
        return Double(s)
    }

    /// Group word timestamps into utterances at pauses ≥ 0.8 s.
    static func utterances(from words: [Word], shift: Double) -> [(text: String, start: Double, end: Double)] {
        guard !words.isEmpty else { return [] }
        var out: [(String, Double, Double)] = []
        var chunk: [Word] = [words[0]]
        for word in words.dropFirst() {
            if word.start - (chunk.last?.end ?? word.start) >= 0.8 {
                out.append(flush(chunk, shift: shift))
                chunk = [word]
            } else {
                chunk.append(word)
            }
        }
        out.append(flush(chunk, shift: shift))
        return out
    }

    private static func flush(_ words: [Word], shift: Double) -> (String, Double, Double) {
        let text = TranscriptionEngine.cleaned(words.map(\.text).joined(separator: " "))
        return (text, words.first!.start + shift, words.last!.end + shift)
    }

    static func transcribe(
        wav: Data,
        language: String?,
        vocabulary: [String],
        apiKey: String,
        smart: Bool,
        windowSeconds: Double
    ) async throws -> [(text: String, start: Double, end: Double)] {
        guard !apiKey.isEmpty else { throw TranscribeError.missingKey }

        let b64 = wav.base64EncodedString()
        var mode: [String: Any] = ["type": smart ? "smart" : "verbatim"]
        if !smart {
            mode["timestamp_granularities"] = ["word"]
        }
        let body: [String: Any] = [
            "model": model,
            "input": [
                [
                    "type": "audio",
                    "data": b64,
                    "mime_type": "audio/wav",
                ] as [String: Any],
            ],
            "generation_config": [
                "transcription_config": [
                    "language_codes": GeminiLanguage.bcp47(from: language),
                    "custom_vocabulary": vocabulary,
                    "mode": mode,
                ] as [String: Any],
            ],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout(forWindowSeconds: windowSeconds)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscribeError.badResponse("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw TranscribeError.badResponse("Gemini HTTP \(http.statusCode): \(detail)")
        }
        return try parseSegments(data)
    }

    static func parseSegments(_ data: Data) throws -> [(text: String, start: Double, end: Double)] {
        let object = try JSONSerialization.jsonObject(with: data)
        let words = collectWords(object)
        if !words.isEmpty {
            return utterances(from: words, shift: 0).filter { !$0.text.isEmpty }
        }
        if let text = firstOutputText(object) {
            let cleaned = TranscriptionEngine.cleaned(text)
            return cleaned.isEmpty ? [] : [(cleaned, 0, 0)]
        }
        return []
    }

    private static func collectWords(_ object: Any) -> [Word] {
        var words: [Word] = []
        walk(object) { dict in
            let type = (dict["type"] as? String) ?? (dict["type"] as? String)
            guard type == "word_info" else { return }
            let text = (dict["text"] as? String) ?? ""
            guard !text.isEmpty else { return }
            let start = parseOffset(dict["start_offset"] as? String)
                ?? parseOffset(dict["startOffset"] as? String)
                ?? 0
            let end = parseOffset(dict["end_offset"] as? String)
                ?? parseOffset(dict["endOffset"] as? String)
                ?? start
            words.append(Word(text: text, start: start, end: end))
        }
        return words
    }

    private static func firstOutputText(_ object: Any) -> String? {
        if let dict = object as? [String: Any] {
            if let text = dict["output_text"] as? String ?? dict["outputText"] as? String, !text.isEmpty {
                return text
            }
        }
        var found: String?
        walk(object) { dict in
            guard found == nil else { return }
            if dict["type"] as? String == "text", let text = dict["text"] as? String, !text.isEmpty {
                found = text
            }
        }
        return found
    }

    private static func walk(_ object: Any, visit: ([String: Any]) -> Void) {
        if let dict = object as? [String: Any] {
            visit(dict)
            for value in dict.values { walk(value, visit: visit) }
        } else if let array = object as? [Any] {
            for value in array { walk(value, visit: visit) }
        }
    }
}

// MARK: - Mid-call + stop refine

/// Fires completed CAF windows at the chosen vendor. The live decoder is
/// untouched — this only patches already-saved segments.
@MainActor
final class HybridRefiner {
    private(set) var notice: String?
    private(set) var billedSeconds: Double = 0
    private var completedEnds: Set<Int> = []
    private var inFlight = false

    func reset() {
        notice = nil
        billedSeconds = 0
        completedEnds = []
        inFlight = false
    }

    func tick(elapsed: TimeInterval, meeting: Meeting, context: ModelContext?) {
        guard FeatureProcessing.call != .local else { return }
        guard !inFlight, let context else { return }
        let window = FeatureProcessing.refineInterval
        let due = RefineWindow.completed(
            elapsed: elapsed, window: window, overlap: FeatureProcessing.refineOverlap)
        for slot in due {
            let key = Int(slot.end)
            guard !completedEnds.contains(key) else { continue }
            completedEnds.insert(key)
            inFlight = true
            Task { @MainActor in
                defer { self.inFlight = false }
                await self.refine(meeting: meeting, start: slot.start, end: slot.end, context: context, smart: false)
            }
            return
        }
    }

    /// Last incomplete window plus any leftover after the last completed end.
    func flush(meeting: Meeting, elapsed: TimeInterval, context: ModelContext?) async {
        guard FeatureProcessing.call != .local, let context else { return }
        let window = FeatureProcessing.refineInterval
        let lastEnd = completedEnds.max().map(Double.init) ?? 0
        let start = max(0, lastEnd - (lastEnd > 0 ? FeatureProcessing.refineOverlap : 0))
        if elapsed > start + 0.5 {
            await refine(meeting: meeting, start: start, end: elapsed, context: context, smart: false)
        }
        // Cloud polish of the remainder is handled by RecordingManager.
        _ = window
    }

    func refine(meeting: Meeting, start: Double, end: Double, context: ModelContext, smart: Bool) async {
        guard let vendorWork = Self.chunkWork() else {
            if FeatureProcessing.call == .cloud {
                notice = "Cloud vendor key missing — keeping the live transcript"
            }
            return
        }
        let language = Self.languageSetting()
        let vocabulary = GeminiGlossary.terms(
            from: UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
        var polished: [TranscriptPolisher.PolishedSegment] = []
        do {
            for (path, speaker) in [
                (meeting.systemAudioPath, "Them"),
                (meeting.micAudioPath ?? "", "Me"),
            ] where !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                let duration = max(0.2, end - start)
                guard let samples = try? AudioFileLoader.read16kMono(
                    url: url, from: start, duration: duration), !samples.isEmpty else { continue }
                let wav = WAVEncoder.encode(samples: samples, sampleRate: 16000)
                let parts = try await vendorWork(wav, language, vocabulary, duration, smart)
                for part in parts where !part.text.isEmpty {
                    polished.append(.init(
                        text: part.text,
                        start: part.start + start,
                        end: (part.end > part.start ? part.end : part.start + 0.4) + start,
                        speaker: speaker))
                }
            }
        } catch {
            notice = "Gemini error — local transcript kept"
            NSLog("Parrot: hybrid refine failed — \(error.localizedDescription)")
            return
        }
        guard !polished.isEmpty else { return }
        billedSeconds += (end - start) * Double(polished.map(\.speaker).uniqued().count)
        TranscriptPolisher.applyWindow(
            polished, to: meeting, windowStart: start, windowEnd: end, context: context)
    }

    /// Full-track polish after Stop (Cloud polish mode, or Hybrid remainder).
    static func polishTracks(systemPath: String?, micPath: String?, smart: Bool) async throws -> [TranscriptPolisher.PolishedSegment] {
        guard let work = chunkWork() else {
            throw GeminiTranscriber.TranscribeError.missingKey
        }
        let language = languageSetting()
        let vocabulary = GeminiGlossary.terms(
            from: UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
        var out: [TranscriptPolisher.PolishedSegment] = []
        for (path, speaker) in [(systemPath, "Them"), (micPath, "Me")] {
            guard let path, FileManager.default.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            guard let total = try? AudioFileLoader.durationSeconds(url: url), total > 0 else { continue }
            var offset: Double = 0
            let part = Double(TranscriptPolisher.partSeconds)
            while offset < total {
                let length = min(part, total - offset)
                let samples = try AudioFileLoader.read16kMono(url: url, from: offset, duration: length)
                guard !samples.isEmpty else { break }
                let wav = WAVEncoder.encode(samples: samples, sampleRate: 16000)
                let parts = try await work(wav, language, vocabulary, length, smart)
                for s in parts where !s.text.isEmpty {
                    out.append(.init(text: s.text, start: s.start + offset,
                                     end: (s.end > s.start ? s.end : s.start + 0.4) + offset,
                                     speaker: speaker))
                }
                offset += length
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    private static func languageSetting() -> String? {
        let setting = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        return (setting == nil || setting == "auto") ? nil : setting
    }

    /// False when the preferred vendor has no key (or is Custom, which is
    /// text-only). Hybrid then stays on the live transcript; Cloud refuses.
    nonisolated static func canStartCloudWork() -> Bool {
        let vendor = CloudVendor.selected
        return vendor != .custom && vendor.speechKey() != nil
    }

    private static func chunkWork() -> ((Data, String?, [String], Double, Bool) async throws -> [(text: String, start: Double, end: Double)])? {
        let vendor = CloudVendor.selected
        guard let key = vendor.speechKey() else { return nil }
        switch vendor {
        case .gemini:
            return { wav, language, vocab, window, smart in
                try await GeminiTranscriber.transcribe(
                    wav: wav, language: language, vocabulary: vocab,
                    apiKey: key, smart: smart, windowSeconds: window)
            }
        case .groq:
            return { wav, language, _, _, _ in
                try await GroqTranscriber.transcribeFile(wav, fileName: "part.wav",
                                                         language: language, apiKey: key)
            }
        case .custom:
            return nil
        }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
