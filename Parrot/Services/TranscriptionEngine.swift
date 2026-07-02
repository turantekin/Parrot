import AVFoundation
import WhisperKit
import Combine
import os

/// Which capture stream a piece of audio came from.
enum AudioSource: CaseIterable {
    /// Microphone — the user.
    case me
    /// System audio — everyone else on the call.
    case them

    var label: String {
        switch self {
        case .me: "Me"
        case .them: "Them"
        }
    }
}

/// Wraps WhisperKit for real-time streaming transcription. The microphone ("Me")
/// and system audio ("Them") streams are buffered and transcribed separately, so
/// every segment knows who was talking — no diarization model needed.
@Observable
final class TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var audioBuffers: [AudioSource: [Float]] = [.me: [], .them: []]
    private let bufferLock = OSAllocatedUnfairLock()
    private var transcriptionTask: Task<Void, Never>?

    private(set) var isReady = false
    private(set) var isTranscribing = false
    private(set) var currentText = ""
    private(set) var modelState: ModelState = .notLoaded

    /// Called when a finalized transcript segment is ready
    var onSegment: ((TranscriptionResult) -> Void)?

    enum ModelState {
        case notLoaded
        case downloading(progress: Double)
        case loading
        case ready
        case error(String)
    }

    struct TranscriptionResult {
        let text: String
        let source: AudioSource
        let startTime: TimeInterval
        let endTime: TimeInterval
        let confidence: Float?
    }

    // MARK: - Model Management

    /// Load WhisperKit with the specified model
    func loadModel(_ modelName: String = "base") async {
        modelState = .loading
        do {
            let config = WhisperKitConfig(
                model: modelName,
                verbose: false,
                logLevel: .none,
                prewarm: true,
                load: true
            )
            whisperKit = try await WhisperKit(config)
            modelState = .ready
            isReady = true
        } catch {
            modelState = .error(error.localizedDescription)
            isReady = false
        }
    }

    // MARK: - Audio Input

    /// Feed audio buffer from AudioCaptureManager, tagged with its stream
    func appendAudio(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        bufferLock.withLock {
            audioBuffers[source, default: []].append(contentsOf: samples)
        }
    }

    // MARK: - Transcription Loop

    /// Start the continuous transcription loop
    func startTranscribing(meetingStartTime: Date) {
        guard isReady else { return }
        // Never run two loops: cancel any prior task before starting a new one.
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = true

        // Resolve the user's transcription language ("auto"/nil = auto-detect).
        let setting = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        let language = (setting == nil || setting == "auto") ? nil : setting
        var decodeOptions = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil
        )

        // Custom vocabulary: prime Whisper with the user's names/terms so it stops
        // mangling proper nouns (e.g. "LaunchEase" → "Lawn Cheese"). Fed as an
        // initial prompt, the standard Whisper mechanism for biasing spelling.
        let vocab = (UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty, let tokenizer = whisperKit?.tokenizer {
            let terms = vocab
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !terms.isEmpty {
                let promptText = "Glossary: " + terms.joined(separator: ", ") + "."
                let tokens = tokenizer.encode(text: " " + promptText)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                decodeOptions.promptTokens = tokens
                decodeOptions.usePrefillPrompt = true
            }
        }

        // Quality + anti-garbage decoding. We derive each segment's timestamps from
        // sample offsets, so suppress Whisper's special + timestamp tokens — they were
        // leaking into the live line as "<|0.00|> ... <|1.00|>" gibberish. The
        // thresholds trip a temperature fallback that breaks Whisper's repetition loops
        // (the "What's your name?" ×N hallucination on near-silent / noisy chunks), and
        // noSpeechThreshold drops silence instead of hallucinating over it.
        decodeOptions.skipSpecialTokens = true
        decodeOptions.withoutTimestamps = true
        decodeOptions.compressionRatioThreshold = 2.4
        decodeOptions.logProbThreshold = -1.0
        decodeOptions.noSpeechThreshold = 0.6
        decodeOptions.temperatureFallbackCount = 3

        transcriptionTask = Task { [weak self] in
            guard let self else { return }

            // Trigger a transcription pass once a stream has buffered at least
            // ~2 s of audio (32k samples at 16 kHz).
            let chunkSize = 32000
            // Hard cap on how much audio a single pass consumes. Without this, a
            // slow Whisper pass (CPU spike, larger model) lets the buffer grow
            // unbounded and the next pass transcribes 30–70 s of speech as ONE
            // giant segment — the "silent for minutes, then a wall of text" bug.
            // Capping keeps every emitted segment ~2 s; under sustained load
            // latency grows gracefully instead of dumping a paragraph.
            let maxChunkSamples = 32000
            // Total samples consumed (and freed) per stream. The audio buffers only
            // ever hold not-yet-transcribed samples, so memory stays flat over a long
            // call; these running totals keep segment timestamps absolute regardless.
            var consumedSamples: [AudioSource: Int] = [.me: 0, .them: 0]

            while !Task.isCancelled {
                // isTranscribing == false flips the loop into drain mode: keep
                // consuming the backlog (any chunk size, down to the final <2 s
                // tail) and exit once the buffers are empty. Capture must already
                // be stopped by then or the buffers keep growing — that ordering
                // is RecordingManager.stopRecording's contract.
                let draining = !self.isTranscribing
                var didWork = false

                for source in AudioSource.allCases {
                    // Pull one bounded window for this stream under the lock —
                    // freeing the consumed audio so it doesn't pile up for the whole
                    // call, and avoiding any index race with a reset.
                    let chunk: [Float] = self.bufferLock.withLock {
                        guard let buffered = self.audioBuffers[source],
                              buffered.count >= (draining ? 1 : chunkSize) else { return [] }
                        let take = min(buffered.count, maxChunkSamples)
                        self.audioBuffers[source] = Array(buffered[take...])
                        return Array(buffered[..<take])
                    }
                    guard !chunk.isEmpty else { continue }
                    didWork = true

                    let startSample = consumedSamples[source] ?? 0
                    let endSample = startSample + chunk.count
                    consumedSamples[source] = endSample
                    let startTime = Double(startSample) / 16000.0
                    let endTime = Double(endSample) / 16000.0

                    // Skip near-silent chunks — saves Whisper passes and avoids
                    // hallucinated text on silence.
                    let energy = chunk.reduce(into: Float(0)) { $0 += abs($1) } / Float(chunk.count)
                    guard energy > 0.001 else { continue }

                    do {
                        guard let whisperKit = self.whisperKit else { continue }
                        // Stream interim words to the live view as they decode; strip
                        // any stray special/timestamp tokens defensively.
                        let interimCallback: TranscriptionCallback = { [weak self] progress in
                            let partial = Self.cleaned(progress.text)
                            if !partial.isEmpty {
                                Task { @MainActor in self?.currentText = partial }
                            }
                            return nil
                        }
                        let result = try await whisperKit.transcribe(
                            audioArray: chunk,
                            decodeOptions: decodeOptions,
                            callback: interimCallback
                        )

                        for transcription in result {
                            let text = Self.cleaned(transcription.text)
                            guard !text.isEmpty else { continue }

                            let avgLogProb = transcription.segments.map(\.avgLogprob).reduce(0, +)
                                / Float(max(transcription.segments.count, 1))

                            await MainActor.run {
                                self.currentText = text
                                self.onSegment?(TranscriptionResult(
                                    text: text,
                                    source: source,
                                    startTime: startTime,
                                    endTime: endTime,
                                    confidence: avgLogProb
                                ))
                            }
                        }
                    } catch {
                        print("Transcription error (\(source.label)): \(error)")
                    }
                }

                // Pause only when caught up. When a backlog exists (CPU spike or a
                // slow pass), keep draining bounded windows back-to-back so
                // transcription keeps pace with real time instead of falling
                // progressively behind — the regression that left the back half of a
                // call untranscribed.
                if !didWork {
                    if draining { break }  // buffers empty → fully drained, exit
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    /// Stop transcription, draining the buffered backlog first so the final words
    /// of the call (previously always dropped — the loop needed ≥2 s buffered)
    /// make it into the transcript. Await this before assembling the transcript.
    // ponytail: drain is uncapped — a hung whisper pass hangs stop; upgrade path
    // is a wall-clock cap + surfaced timeout.
    func stopTranscribing() async {
        isTranscribing = false          // flips the loop into drain mode
        await transcriptionTask?.value  // deliberately not cancel(): let it finish
        transcriptionTask = nil

        bufferLock.withLock {
            audioBuffers = [.me: [], .them: []]
        }

        currentText = ""
    }

    /// Strips any Whisper special/timestamp tokens (e.g. "<|startoftranscript|>",
    /// "<|0.00|>") that can leak into raw decoder text, and trims whitespace.
    static func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
