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

        transcriptionTask = Task { [weak self] in
            guard let self else { return }

            // Process audio in chunks (~2 seconds at 16kHz) per stream
            let chunkSize = 32000
            // Total samples consumed (and freed) per stream. The audio buffers only
            // ever hold not-yet-transcribed samples, so memory stays flat over a long
            // call; these running totals keep segment timestamps absolute regardless.
            var consumedSamples: [AudioSource: Int] = [.me: 0, .them: 0]

            while !Task.isCancelled && self.isTranscribing {
                try? await Task.sleep(for: .milliseconds(500))

                for source in AudioSource.allCases {
                    // Pull everything buffered for this stream and clear it in one
                    // locked step — freeing the consumed audio (so it doesn't pile up
                    // for the whole call) and avoiding any index race with a reset.
                    let chunk: [Float] = self.bufferLock.withLock {
                        guard let buffered = self.audioBuffers[source],
                              buffered.count >= chunkSize else { return [] }
                        self.audioBuffers[source] = []
                        return buffered
                    }
                    guard !chunk.isEmpty else { continue }

                    let startSample = consumedSamples[source] ?? 0
                    let endSample = startSample + chunk.count
                    consumedSamples[source] = endSample
                    let startTime = Double(startSample) / 16000.0
                    let endTime = Double(endSample) / 16000.0

                    // Skip near-silent chunks — saves Whisper passes (the mic is
                    // mostly silent while the user listens, and vice versa) and
                    // avoids hallucinated text on silence.
                    let energy = chunk.reduce(into: Float(0)) { $0 += abs($1) } / Float(chunk.count)
                    guard energy > 0.001 else { continue }

                    do {
                        guard let whisperKit = self.whisperKit else { continue }
                        let result = try await whisperKit.transcribe(audioArray: chunk, decodeOptions: decodeOptions)

                        for transcription in result {
                            let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            }
        }
    }

    /// Stop transcription
    func stopTranscribing() {
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil

        bufferLock.withLock {
            audioBuffers = [.me: [], .them: []]
        }

        currentText = ""
    }
}
