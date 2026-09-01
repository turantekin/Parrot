import CoreML
import FluidAudio
import Foundation
import WhisperKit

enum PreviewMode: String, Sendable {
    case on, off, tail
}

enum ComputePlacement: String, Sendable {
    case ane, gpu, all

    var computeOptions: ModelComputeOptions {
        switch self {
        case .ane:
            return ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        case .gpu:
            return ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        case .all:
            return ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        }
    }
}

enum OnDeviceASRBackend: String, Sendable, CaseIterable {
    case whisper
    case parakeet
    case sensevoice
}

/// Session knobs for the live loop. Harnesses set `sessionOverride`;
/// production reads UserDefaults plus optional `LIVELOOP_*` env.
struct LoopSessionConfig: Sendable, Equatable {
    var language: String?
    var preview: PreviewMode
    var fallbackCount: Int
    var compute: ComputePlacement
    var streams: Int
    var backend: OnDeviceASRBackend
    /// When true, the first detected language is locked for the rest of the
    /// session. Auto (`language == nil`) defaults to false so mixed-language
    /// calls can re-detect on every commit. Opt in with `freeze=true` / `LIVELOOP_FREEZE`.
    var freezeLanguage: Bool
    var englishOnlyWeights: Bool

    static let defaultsKeyCompute = "asrComputePlacement"
    static let defaultsKeyBackend = "onDeviceASRBackend"

    static func fromEnvironmentAndDefaults() -> LoopSessionConfig {
        let env = ProcessInfo.processInfo.environment
        let langRaw = env["LIVELOOP_LANGUAGE"]
            ?? UserDefaults.standard.string(forKey: "transcriptionLanguage")
            ?? "auto"
        let language = (langRaw == "auto" || langRaw.isEmpty) ? nil : langRaw

        let preview: PreviewMode
        if let raw = env["LIVELOOP_PREVIEW"], let parsed = PreviewMode(rawValue: raw) {
            preview = parsed
        } else {
            let on = UserDefaults.standard.object(forKey: "livePreview") as? Bool ?? true
            preview = on ? .tail : .off
        }

        let fallback: Int
        if let raw = env["LIVELOOP_FALLBACK"], let n = Int(raw) {
            fallback = n
        } else {
            fallback = 1
        }

        let compute = ComputePlacement(
            rawValue: env["LIVELOOP_COMPUTE"]
                ?? UserDefaults.standard.string(forKey: defaultsKeyCompute)
                ?? ComputePlacement.ane.rawValue
        ) ?? .ane

        let streams = Int(env["LIVELOOP_STREAMS"] ?? "") ?? 1

        let backend = OnDeviceASRBackend(
            rawValue: env["LIVELOOP_BACKEND"]
                ?? UserDefaults.standard.string(forKey: defaultsKeyBackend)
                ?? OnDeviceASRBackend.whisper.rawValue
        ) ?? .whisper

        let freezeRaw = env["LIVELOOP_FREEZE"]
        let freezeLanguage = freezeRaw == "1" || freezeRaw == "true"

        return LoopSessionConfig(
            language: language,
            preview: preview,
            fallbackCount: fallback,
            compute: compute,
            streams: max(1, min(streams, 2)),
            backend: backend,
            freezeLanguage: freezeLanguage,
            englishOnlyWeights: language == "en"
        )
    }

    /// Parses `--asr-bench` specs: `preview=on,language=auto,fallback=3,compute=ane,backend=whisper`
    static func parseBenchSpec(_ spec: String) -> LoopSessionConfig {
        var cfg = fromEnvironmentAndDefaults()
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "preview":
                if let mode = PreviewMode(rawValue: value) { cfg.preview = mode }
            case "language":
                cfg.language = (value == "auto" || value.isEmpty) ? nil : value
                cfg.englishOnlyWeights = cfg.language == "en"
            case "fallback":
                if let n = Int(value) { cfg.fallbackCount = n }
            case "compute":
                if let c = ComputePlacement(rawValue: value) { cfg.compute = c }
            case "backend":
                if let b = OnDeviceASRBackend(rawValue: value) { cfg.backend = b }
            case "streams":
                if let n = Int(value) { cfg.streams = max(1, min(n, 2)) }
            case "freeze":
                cfg.freezeLanguage = value == "1" || value == "true"
            default:
                break
            }
        }
        return cfg
    }

    /// tiny/base/small → `.en` when the session is locked to English.
    static func resolvedWhisperModel(_ model: String, language: String?) -> String {
        guard language == "en" else { return model }
        switch model {
        case "tiny", "base", "small": return model + ".en"
        default: return model
        }
    }
}

/// Pure decode-loop policy. `--profile-test` drives these without a model.
enum ASRLoopPolicy {
    static let sampleRate = 16_000
    static let tailPreviewSamples = sampleRate * 3
    static let maxDecodeSamples = sampleRate * 15
    static let minDrainSamples = sampleRate / 5
    /// Force a cut near this length (Wispr live p50 is 1.3–3.6 s). Hard cap stays 12 s.
    static let softCapSamples = sampleRate * 4
    /// Never discard the last N samples of "silence" — a false VAD still gets decoded.
    static let silenceLookbackSamples = sampleRate * 3
    /// Decode even when energy is under the floor once this much is buffered.
    static let speculativePendingSamples = sampleRate * 2
    /// Search the last 1 s of a soft-cap window for the quietest 100 ms frame.
    static let valleySearchFrames = 10
    /// Previous-transcript prompt (Whisper condition-on-previous-text), last N words.
    static let previousTextWords = 40

    static func previewSamples(_ pending: [Float], mode: PreviewMode) -> [Float] {
        switch mode {
        case .off: return []
        case .on: return applyDecodeWindowCap(pending)
        case .tail:
            if pending.count <= tailPreviewSamples { return applyDecodeWindowCap(pending) }
            return applyDecodeWindowCap(Array(pending.suffix(tailPreviewSamples)))
        }
    }

    static func shouldPreview(
        mode: PreviewMode,
        commitInFlight: Bool,
        pendingCount: Int,
        now: Date,
        nextAt: Date,
        otherCommitReady: Bool = false
    ) -> Bool {
        guard mode != .off else { return false }
        guard !commitInFlight else { return false }
        guard !otherCommitReady else { return false }
        guard pendingCount >= TranscriptionEngine.Segmenter.minSpeechSamples else { return false }
        return now >= nextAt
    }

    static func applyDecodeWindowCap(_ samples: [Float]) -> [Float] {
        if samples.count <= maxDecodeSamples { return samples }
        return Array(samples.suffix(maxDecodeSamples))
    }

    static func shouldDropDrainTail(_ sampleCount: Int, draining: Bool) -> Bool {
        draining && sampleCount > 0 && sampleCount < minDrainSamples
    }

    /// After the first confident detect, later options must not re-run language detection.
    static func applyingLanguageFreeze(
        _ options: DecodingOptions,
        frozen: String?
    ) -> DecodingOptions {
        var next = options
        if let frozen, !frozen.isEmpty {
            next.language = frozen
            next.detectLanguage = false
        }
        return next
    }

    static func previewOptions(_ options: DecodingOptions, hintLanguage: String? = nil) -> DecodingOptions {
        var next = options
        next.detectLanguage = false
        if let hintLanguage, !hintLanguage.isEmpty {
            next.language = hintLanguage
        }
        return next
    }

    /// Energy passed the segmenter but the decode returned empty — wasted ANE time.
    static func isWastedDecode(energyPassed: Bool, text: String) -> Bool {
        energyPassed && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func shouldSpeculativePreview(pendingCount: Int) -> Bool {
        pendingCount >= speculativePendingSamples
    }

    /// First 2–3 s of a "silence" buffer — decode, don't delete.
    static func silenceWindowTake(sampleCount: Int) -> Int? {
        guard sampleCount >= speculativePendingSamples else { return nil }
        return min(silenceLookbackSamples, sampleCount)
    }

    /// Lowest-energy frame near the 4 s soft cap so a forced cut prefers a pause.
    static func energyValleyTake(in buffer: [Float], drop: Int, speechLen: Int) -> Int? {
        guard speechLen >= softCapSamples else { return nil }
        let frame = TranscriptionEngine.Segmenter.frame
        let pad = TranscriptionEngine.Segmenter.padFrames
        let minSpeech = TranscriptionEngine.Segmenter.minSpeechSamples
        let searchStart = max(drop, drop + softCapSamples - valleySearchFrames * frame)
        let searchEnd = min(buffer.count, drop + softCapSamples)
        guard searchEnd > searchStart else { return softCapSamples }
        var bestFrame = max(searchStart / frame, 0)
        var bestE = Float.greatestFiniteMagnitude
        var i = searchStart / frame
        let endI = searchEnd / frame
        while i < endI {
            let e = TranscriptionEngine.Segmenter.frameEnergy(buffer, i)
            if e <= bestE {
                bestE = e
                bestFrame = i
            }
            i += 1
        }
        let take = (bestFrame + 1 + pad) * frame - drop
        return min(max(take, minSpeech), softCapSamples)
    }

    static func previousTextPrompt(_ text: String, maxWords: Int = previousTextWords) -> String {
        text.split(whereSeparator: \.isWhitespace).suffix(maxWords).joined(separator: " ")
    }

    static func applyingPreviousText(_ options: DecodingOptions, tokens: [Int]) -> DecodingOptions {
        var next = options
        guard !tokens.isEmpty else { return next }
        next.promptTokens = tokens
        next.usePrefillPrompt = true
        return next
    }
}

/// LocalAgreement-2 (Macháček et al., IJCNLP 2023; UFAL whisper_streaming).
/// Two consecutive hypotheses that share a prefix → that prefix is stable enough to emit.
enum LocalAgreement {
    static let minConfirmedWords = 2

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func displayPrefix(from text: String, wordCount: Int) -> String {
        guard wordCount > 0 else { return "" }
        var count = 0
        var idx = text.startIndex
        var end = text.startIndex
        while idx < text.endIndex, count < wordCount {
            while idx < text.endIndex, text[idx].isWhitespace {
                idx = text.index(after: idx)
            }
            while idx < text.endIndex, !text[idx].isWhitespace {
                idx = text.index(after: idx)
            }
            end = idx
            count += 1
        }
        return String(text[..<end]).trimmingCharacters(in: .whitespaces)
    }

    static func confirmedPrefix(_ previous: String, _ current: String, minWords: Int = minConfirmedWords) -> String? {
        let a = words(previous)
        let b = words(current)
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] { n += 1 }
        guard n >= minWords else { return nil }
        return displayPrefix(from: current, wordCount: n)
    }

    static func delta(emitted: String, confirmed: String) -> String? {
        let e = words(emitted)
        let c = words(confirmed)
        guard c.count > e.count else { return nil }
        guard zip(e, c).allSatisfy({ $0.0 == $0.1 }) else { return nil }
        let skip = displayPrefix(from: confirmed, wordCount: e.count)
        let rest = String(confirmed.dropFirst(skip.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    static func remainder(emitted: String, full: String) -> String {
        let e = words(emitted)
        let f = words(full)
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, f.count >= e.count,
              zip(e, f).allSatisfy({ $0.0 == $0.1 }) else { return trimmed }
        let skip = displayPrefix(from: full, wordCount: e.count)
        return String(full.dropFirst(skip.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func estimatedEnd(
        startTime: TimeInterval,
        pendingSamples: Int,
        confirmed: String,
        hypothesis: String
    ) -> TimeInterval {
        let total = max(words(hypothesis).count, 1)
        let done = min(words(confirmed).count, total)
        return startTime + Double(pendingSamples) / Double(ASRLoopPolicy.sampleRate)
            * Double(done) / Double(total)
    }

    static func samplesForPrefix(pendingSamples: Int, confirmed: String, hypothesis: String) -> Int {
        let total = max(words(hypothesis).count, 1)
        let done = min(words(confirmed).count, total)
        let n = pendingSamples * done / total
        let keep = ASRLoopPolicy.sampleRate / 5
        return min(n, max(0, pendingSamples - keep))
    }
}

/// Picks a streaming backend by language. FluidAudio ASR is not on the
/// current diarization pin — the engine falls back to Whisper when
/// `FluidStreamingASR.isAvailable` is false.
enum ASRLanguageRouter {
    static func backend(for language: String?) -> OnDeviceASRBackend {
        switch language {
        case "en", "es", "fr", "de", "it", "pt": return .parakeet
        case "zh", "tr", "ar", "hi", "ja", "ko": return .sensevoice
        default: return .whisper
        }
    }

    static func resolved(requested: OnDeviceASRBackend, language: String?) -> OnDeviceASRBackend {
        if requested != .whisper { return requested }
        return backend(for: language)
    }
}

/// FluidAudio on this pin already ships `AsrManager` / streaming types, but we
/// do not load those weights until `--asr-bench` beats Whisper on a real file.
/// `isAvailable` stays false so the live loop never downloads a second stack.
enum FluidStreamingASR {
    static var isAvailable: Bool { false }

    static func fallbackNotice(for backend: OnDeviceASRBackend) -> String? {
        guard backend != .whisper, !isAvailable else { return nil }
        return "ANE streaming (\(backend.rawValue)) is gated until a bench win — using Whisper"
    }

    /// Type-check against the pinned FluidAudio ASR API. Not invoked at runtime
    /// while `isAvailable` is false.
    static func makeManager() -> AsrManager {
        AsrManager()
    }
}

/// FluidAudio CTC keyword boost — same gate as streaming ASR. Today's glossary
/// prompt already has a `--liveloop-test` + `LIVELOOP_VOCAB` retry path; flip
/// this only if `glossary_retries` stays high after a bench against the prompt.
enum FluidVocabBoost {
    static var isAvailable: Bool { false }
}
