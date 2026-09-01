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
    /// Live Deepgram sockets, one per source, when the deepgram backend is
    /// active. Audio routes straight to them instead of the chunk buffers.
    /// Same benign cross-thread pattern as `isCapturing`.
    private var deepgramStreamers: [AudioSource: DeepgramStreamer] = [:]
    /// Sources whose Deepgram socket has failed: their audio falls back to the
    /// local buffer/loop path for the rest of the session. Per-source, so one
    /// dead socket (a mic that stopped feeding it) doesn't take the other,
    /// healthy stream off Deepgram with it. Guarded by `bufferLock`.
    private var deepgramFailedSources: Set<AudioSource> = []
    /// Offset added to locally-derived timestamps, per source. Sample counts
    /// don't measure dead time: when a stream falls off Deepgram mid-call (or
    /// the mic restarts after a device change) the counter is way behind the
    /// meeting clock, and without re-anchoring the fallback segments restart
    /// at 0:00 — the bug that filed the back half of a call under minute 3.
    /// Guarded by `bufferLock`.
    private var localClockOffset: [AudioSource: TimeInterval] = [:]
    /// Total samples consumed (and freed) per stream by the local loop. The
    /// buffers only ever hold not-yet-transcribed samples, so memory stays flat
    /// over a long call; these running totals keep segment timestamps absolute.
    /// Guarded by `bufferLock` (the loop and `reanchorLocalClock` both touch it).
    private var consumedSamples: [AudioSource: Int] = [:]
    private var meetingStartTime = Date()

    /// PARROT_LOOP_TRACE=1: print every raw decode piece before filtering —
    /// the tell for "the loop decoded it but a filter ate it" class of drops.
    static let loopTrace = ProcessInfo.processInfo.environment["PARROT_LOOP_TRACE"] != nil

    private(set) var isReady = false
    private(set) var isTranscribing = false
    private(set) var currentText = ""
    /// Which stream `currentText` came from, so the live view can hang the
    /// preview bubble under the right speaker (Me right, Them left). nil
    /// whenever `currentText` is empty.
    private(set) var currentSpeaker: AudioSource?
    /// True while live audio carries speech-level energy. Drives the typing
    /// bubble on chunked backends (Groq, local Whisper) that have no interim
    /// stream — the bubble shows dots while someone talks, text when interims
    /// exist. Same benign cross-thread pattern as the streamers dict.
    private(set) var isHearingSpeech = false
    private var lastSpeechAt = Date.distantPast
    private(set) var modelState: ModelState = .notLoaded
    /// Display name of the model currently downloading/preparing, set at the
    /// start of every load — the status views use it to answer "which model
    /// is this?" when the picker selection and the in-flight load disagree.
    private(set) var loadingModelName: String?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    /// One-line notice when a cloud backend can't be used (missing key, API
    /// errors) and the session is running on-device instead. Shown in the
    /// live device bar.
    private(set) var cloudNotice: String?

    /// Called when a finalized transcript segment is ready
    var onSegment: ((TranscriptionResult) -> Void)?
    /// Harness override for loop knobs. Production leaves this nil.
    var sessionOverride: LoopSessionConfig?
    private let statsLock = OSAllocatedUnfairLock()
    private var decodeStats = DecodeStats()

    func snapshotDecodeStats(segmentCount: Int) -> DecodeStats.Snapshot {
        statsLock.withLock { decodeStats.snapshot(segmentCount: segmentCount) }
    }

    @MainActor
    func unloadModel() {
        whisperKit = nil
        isReady = false
        modelState = .notLoaded
        loadingModelName = nil
    }

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
        let detectedLanguage: String?
    }

    // MARK: - Model Management

    /// Load WhisperKit with the specified model.
    ///
    /// Two guards against the eternal "Loading WhisperKit model…" state this
    /// used to produce (idle CPU, dead record button, no error):
    /// - If the model is already on disk, pass its folder directly — WhisperKit's
    ///   name resolution goes through the HuggingFace hub even for local models
    ///   and has been observed suspending forever on a live network. A direct
    ///   folder load is also offline-proof.
    /// - The whole init races a deadline; a first-time download can legitimately
    ///   take minutes, but past the deadline the user gets a real error state
    ///   (the dashboard renders it) instead of a spinner that never ends.
    /// @MainActor: `modelState`/`isReady` are UI-observed, and a nonisolated
    /// async func runs on the global executor, not the caller's actor — mutating
    /// them there fires SwiftUI observation off-main and trips SwiftData's
    /// main-queue assert when a @Query view is invalidating concurrently (the
    /// #18 launch crash-loop). The heavy WhisperKit init is awaited, so main is
    /// never blocked. Same rule for start/stopTranscribing below.
    @MainActor
    func loadModel(_ modelName: String = "base") async {
        let session = sessionOverride ?? LoopSessionConfig.fromEnvironmentAndDefaults()
        let resolved = LoopSessionConfig.resolvedWhisperModel(modelName, language: session.language)
        await loadResolvedModel(resolved)
    }

    @MainActor
    private func loadResolvedModel(_ modelName: String) async {
        // Switching models mid-download must not race two loads (the old
        // last-finisher-wins behavior could load a model the user had already
        // navigated away from). The newest call cancels the previous one; the
        // generation check drops the loser's late callbacks and results.
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task { @MainActor in await self.performLoad(modelName, generation: generation) }
        loadTask = task
        await task.value
    }

    @MainActor
    private func performLoad(_ modelName: String, generation: Int) async {
        isReady = false
        loadingModelName = Self.displayName(for: modelName)
        do {
            let resolvedModelName = Self.hubVariant(for: modelName)
            let modelFolder: URL
            if let localFolder = Self.localModelFolder(for: modelName) {
                modelFolder = localFolder
            } else {
                modelState = .downloading(progress: 0)
                modelFolder = try await Self.withTimeout(seconds: 300) {
                    try await WhisperKit.download(variant: resolvedModelName) { progress in
                        let fraction = min(max(progress.fractionCompleted, 0), 1)
                        Task { @MainActor [weak self] in
                            guard let self, self.loadGeneration == generation,
                                  case .downloading(let current) = self.modelState else { return }
                            self.modelState = .downloading(progress: max(current, fraction))
                        }
                    }
                }
            }

            guard loadGeneration == generation else { return }
            modelState = .loading
            let session = sessionOverride ?? LoopSessionConfig.fromEnvironmentAndDefaults()
            let config = WhisperKitConfig(
                model: resolvedModelName,
                modelFolder: modelFolder.path,
                computeOptions: session.compute.computeOptions,
                verbose: false,
                logLevel: .none,
                prewarm: true,
                load: true,
                download: false
            )
            let kit = try await Self.withTimeout(seconds: 300) { try await WhisperKit(config) }
            guard loadGeneration == generation else { return }
            whisperKit = kit
            modelState = .ready
            isReady = true
        } catch {
            guard loadGeneration == generation, !(error is CancellationError) else { return }
            modelState = .error(error.localizedDescription)
            isReady = false
        }
    }

    /// UI model tags → the hub's spelling. WhisperKit downloads by globbing
    /// "*<variant>/*" against the repo, and no folder there ends in
    /// "large-v3-turbo" — OpenAI's turbo checkpoint is published as
    /// "openai_whisper-large-v3-v20240930", so a fresh download of our
    /// "large-v3-turbo" tag failed with modelsUnavailable (issue #30).
    /// Stored tags stay as-is; only this boundary maps.
    nonisolated static func hubVariant(for modelName: String) -> String {
        modelName == "large-v3-turbo" ? "large-v3-v20240930" : modelName
    }

    /// Human-readable model names for the status line, so "which model is
    /// downloading?" is answerable mid-flight. Falls back to the raw tag.
    nonisolated static func displayName(for modelName: String) -> String {
        switch modelName {
        case "large-v3-turbo": "Large V3 Turbo"
        case "large-v3-v20240930_626MB": "Large V3 Turbo Compressed"
        case "tiny", "base", "small", "medium": modelName.capitalized
        case "tiny.en": "Tiny (English)"
        case "base.en": "Base (English)"
        case "small.en": "Small (English)"
        default: modelName
        }
    }

    /// The on-disk folder for a model, if already downloaded. WhisperKit's repo
    /// spells variants inconsistently ('_' vs '-' between segments), hence the
    /// normalized matcher below. A matching folder is not enough: Hub creates
    /// the destination before every file arrives, so an interrupted download
    /// must be rejected and resumed instead of loaded.
    nonisolated static func localModelFolder(for modelName: String) -> URL? {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        guard let name = matchModelFolder(modelName, in: names) else { return nil }
        let folder = base.appendingPathComponent(name, isDirectory: true)
        return isCompleteModelFolder(folder) ? folder : nil
    }

    /// WhisperKit requires these three compiled pipelines. Checking files inside
    /// each bundle (rather than only the bundle directory) catches interrupted
    /// Hugging Face snapshots such as issue #30's partial Turbo download.
    nonisolated static var requiredModelFiles: [String] {
        [
            "MelSpectrogram.mlmodelc/model.mil",
            "MelSpectrogram.mlmodelc/coremldata.bin",
            "MelSpectrogram.mlmodelc/weights/weight.bin",
            "AudioEncoder.mlmodelc/model.mil",
            "AudioEncoder.mlmodelc/coremldata.bin",
            "AudioEncoder.mlmodelc/weights/weight.bin",
            "TextDecoder.mlmodelc/model.mil",
            "TextDecoder.mlmodelc/coremldata.bin",
            "TextDecoder.mlmodelc/weights/weight.bin",
            "config.json",
            "generation_config.json",
        ]
    }

    nonisolated static func isCompleteModelFolder(_ folder: URL) -> Bool {
        requiredModelFiles.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Pure matcher (so --profile-test can drive it): compares case-insensitively
    /// with '_' and '-' unified. The current artifact wins over a legacy copy;
    /// ambiguity within either name falls back to WhisperKit's hub resolution.
    nonisolated static func matchModelFolder(_ modelName: String, in folderNames: [String]) -> String? {
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "_", with: "-") }
        let resolvedName = hubVariant(for: modelName)
        let names = resolvedName == modelName ? [modelName] : [resolvedName, modelName]
        for name in names {
            let wanted = "openai-whisper-" + norm(name)
            let hits = folderNames.filter { norm($0) == wanted }
            if hits.count > 1 { return nil }
            if let hit = hits.first { return hit }
        }
        return nil
    }

    private struct ModelLoadTimeout: LocalizedError {
        var errorDescription: String? {
            "Model load timed out — check your connection, or pick the model again in Settings"
        }
    }

    nonisolated private static func withTimeout<T: Sendable>(
        seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ModelLoadTimeout()
            }
            guard let first = try await group.next() else { throw ModelLoadTimeout() }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Audio Input

    /// Feed audio buffer from AudioCaptureManager, tagged with its stream
    func appendAudio(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        // Speech-presence for the typing bubble: mark speech on energetic
        // buffers (same adaptive floor as the chunk loop, so the dots fire at
        // any input gain), release after 1 s of silence — capture keeps
        // feeding silent buffers, so the flip-off is driven from here too.
        // The floor comes from the accumulated backlog, not this tiny buffer:
        // the backlog carries enough context to tell quiet speech (floor
        // drops) from steady room tone (stays flat-silence, dots stay off).
        if isTranscribing, frameCount > 0 {
            let energy = samples.reduce(into: Float(0)) { $0 += abs($1) } / Float(frameCount)
            let floor = bufferLock.withLock { Segmenter.adaptiveFloor(for: audioBuffers[source] ?? []) }
            if energy > floor { lastSpeechAt = Date() }
            let hearing = Date().timeIntervalSince(lastSpeechAt) < 1.0
            if hearing != isHearingSpeech {
                Task { @MainActor in self.isHearingSpeech = hearing }
            }
        }

        // Streaming backend: straight to the socket, no chunk buffering.
        let streamer: DeepgramStreamer? = bufferLock.withLock {
            deepgramFailedSources.contains(source) ? nil : deepgramStreamers[source]
        }
        if let streamer {
            streamer.send(samples)
            return
        }

        bufferLock.withLock {
            audioBuffers[source, default: []].append(contentsOf: samples)
        }
        if isTranscribing {
            statsLock.withLock {
                decodeStats.audioSecondsFed += Double(frameCount) / 16_000
            }
        }
    }

    // MARK: - Utterance Segmentation

    /// Pure utterance segmenter for the live loop (--profile-test drives it).
    ///
    /// Replaces the old fixed 2 s chunk emission, which cut ~75% of lines
    /// mid-sentence and decoded silence-bounded fragments that Whisper turned
    /// into hallucinations ("you", YouTube-outro residue). The segmenter only
    /// ever emits speech bounded by a real pause: leading silence is discarded
    /// outright (never decoded — the structural fix for silence hallucinations),
    /// and an utterance is cut when a sustained pause follows it, when it hits
    /// the length cap, or when the loop is draining at stop.
    enum Segmenter {
        /// Energy-frame size: 100 ms at 16 kHz. Pause detection resolution.
        static let frame = 1600
        /// The legacy fixed mean-abs floor for "this is speech" — now the
        /// adaptive floor's CEILING and the fallback where no audio exists to
        /// estimate from. It is only correct near default input gain: a real
        /// session at 49% input volume measured speech at ~0.0014 mean-abs
        /// (2026-08-04 live trace), below this value, so the segmenter ate
        /// continuous speech as "leading silence" and the preview gate never
        /// passed. `adaptiveFloor(for:)` below fixes that.
        static let silenceFloor: Float = 0.002
        /// Digital dither / AEC-residue ceiling: content below this can never
        /// be speech; content above it always might be.
        static let ditherFloor: Float = 0.0004

        static func frameEnergy(_ buffer: [Float], _ i: Int) -> Float {
            var sum: Float = 0
            for j in (i * frame)..<((i + 1) * frame) { sum += abs(buffer[j]) }
            return sum / Float(frame)
        }

        /// Adaptive speech/silence threshold for a buffered window, derived
        /// from the window's own quietest 100 ms frame — the rolling noise
        /// estimate is the backlog itself, so it needs no cross-poll state and
        /// cannot start wrong. noise × 4 headroom, clamped to
        /// [ditherFloor, silenceFloor] so no environment behaves worse than
        /// the shipped fixed floor.
        ///
        /// A window with no frame above the derived floor is all one thing:
        /// true silence when even its loudest frame sits at dither level,
        /// otherwise quiet speech that hasn't reached its bounding pause yet
        /// (the un-paused head of an utterance — exactly what the fixed floor
        /// used to discard). For speech the floor drops to `ditherFloor` so
        /// every frame reads as speech and nothing is lost; the eventual pause
        /// makes the window bimodal and the real threshold takes over.
        static func adaptiveFloor(for buffer: [Float]) -> Float {
            let frames = buffer.count / frame
            guard frames > 0 else {
                // Sub-frame tail: its mean decides silence vs maybe-speech.
                let mean = buffer.isEmpty ? 0
                    : buffer.reduce(into: Float(0)) { $0 += abs($1) } / Float(buffer.count)
                return mean >= ditherFloor ? ditherFloor : silenceFloor
            }
            var minE = Float.greatestFiniteMagnitude
            var maxE: Float = 0
            for i in 0..<frames {
                let e = frameEnergy(buffer, i)
                minE = min(minE, e)
                maxE = max(maxE, e)
            }
            let floor = min(max(minE * 4, ditherFloor), silenceFloor)
            if maxE >= floor { return floor }
            return maxE >= ditherFloor ? ditherFloor : silenceFloor
        }
        /// 600 ms of continuous silence ends an utterance. Intra-word and
        /// clause gaps run shorter; sentence gaps run longer.
        // ponytail: fixed threshold — adaptive (speaker-rate) pausing if
        // fast-talker reports come in.
        static let pauseFrames = 6
        /// Speech islands under 300 ms surrounded by silence are clicks/noise:
        /// dropped without a decode.
        static let minSpeechSamples = 4800
        /// Forced cut for uninterrupted speech: bounds live latency and keeps a
        /// backlogged pass from decoding a minute as one wall of text (the old
        /// 2 s cap's job, at utterance scale). 12 s at 16 kHz.
        // ponytail: cap cuts mid-word; upgrade is cutting back at the
        // lowest-energy frame near the cap.
        static let maxSegmentSamples = 192_000
        /// Keep 100 ms of the pause on the cut so Whisper hears the word release.
        static let padFrames = 1

        /// One polling decision: discard `dropLeading` samples (silence — the
        /// consumed counter still advances so timestamps stay absolute), then
        /// cut `take` samples for decoding; `take == nil` means keep buffering.
        struct Cut: Equatable {
            var dropLeading: Int
            var take: Int?
        }

        static func nextCut(in buffer: [Float], draining: Bool, floor: Float = silenceFloor) -> Cut {
            let n = buffer.count
            let frames = n / frame

            // Leading silence: whole silent frames before the first speech frame.
            var speechFrame: Int?
            for i in 0..<frames where frameEnergy(buffer, i) >= floor { speechFrame = i; break }
            guard let s = speechFrame else {
                // Energy VAD called this silence. Walk it in 2–3 s decode
                // windows instead of deleting it — quiet meeting mixes were
                // sitting until 110 s for that reason. True silence comes
                // back empty and is dropped after the decode.
                if draining {
                    if let take = ASRLoopPolicy.silenceWindowTake(sampleCount: frames * frame) {
                        return Cut(dropLeading: 0, take: take)
                    }
                    if n >= minSpeechSamples { return Cut(dropLeading: 0, take: n) }
                    return Cut(dropLeading: n, take: nil)
                }
                if let take = ASRLoopPolicy.silenceWindowTake(sampleCount: frames * frame) {
                    return Cut(dropLeading: 0, take: take)
                }
                return Cut(dropLeading: 0, take: nil)
            }
            let drop = s * frame

            // Scan for the first sustained pause after speech starts.
            var silentRun = 0
            for i in s..<frames {
                if frameEnergy(buffer, i) < floor {
                    silentRun += 1
                    if silentRun == pauseFrames {
                        let speechEndFrame = i - pauseFrames + 1  // first frame of the pause
                        let speechLen = speechEndFrame * frame - drop
                        if speechLen < minSpeechSamples {
                            // Noise blip between silences: discard it with its pause.
                            return Cut(dropLeading: (i + 1) * frame, take: nil)
                        }
                        return Cut(dropLeading: drop, take: (speechEndFrame + padFrames) * frame - drop)
                    }
                } else {
                    silentRun = 0
                }
            }

            // Speech with no boundary yet.
            let speechLen = n - drop
            if let take = ASRLoopPolicy.energyValleyTake(in: buffer, drop: drop, speechLen: speechLen) {
                return Cut(dropLeading: drop, take: take)
            }
            if speechLen >= maxSegmentSamples { return Cut(dropLeading: drop, take: maxSegmentSamples) }
            if draining { return Cut(dropLeading: drop, take: speechLen) }
            return Cut(dropLeading: drop, take: nil)
        }
    }

    /// Whisper wants speech, not whispers: scale a chunk to a healthy loudness
    /// before every decode. A quiet-but-real voice (49% input volume ≈ 0.0014
    /// mean-abs, 2026-08-04 live trace) decodes as fragments and wrong-language
    /// hallucinations at raw level. Gain is capped so a noise-floor chunk can't
    /// be amplified into fake speech, never attenuates (loud audio already
    /// decodes fine), and output is clamped to ±1 so a stray click can't clip.
    static func normalizedForDecode(_ samples: [Float]) -> [Float] {
        let targetRMS: Float = 0.06
        let maxGain: Float = 32
        guard !samples.isEmpty else { return samples }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        guard rms > 0, rms < targetRMS else { return samples }
        let gain = min(targetRMS / rms, maxGain)
        return samples.map { min(max($0 * gain, -1), 1) }
    }

    // MARK: - Transcription Loop

    /// Start the continuous transcription loop
    @MainActor
    func startTranscribing(meetingStartTime: Date) {
        guard isReady else { return }
        // Never run two loops: cancel any prior task before starting a new one.
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = true

        // Resolve the transcription backend for this session. Cloud backends
        // need their key; anything missing falls back to on-device with a
        // visible notice. (Deepgram streaming lands separately; until then it
        // behaves as local.)
        var backend = TranscriptionBackend.selected
        var groqKey: String?
        cloudNotice = nil
        self.meetingStartTime = meetingStartTime
        statsLock.withLock { decodeStats = DecodeStats() }
        bufferLock.withLock {
            deepgramFailedSources = []
            localClockOffset = [:]
            consumedSamples = [.me: 0, .them: 0]
        }
        deepgramStreamers = [:]
        if backend == .groq {
            groqKey = APIKeyStore.load(account: TranscriptionBackend.groq.keychainAccount!)
            if groqKey?.isEmpty != false {
                backend = .local
                cloudNotice = "Groq key missing — using on-device Whisper"
            }
        }

        let session = sessionOverride ?? LoopSessionConfig.fromEnvironmentAndDefaults()
        if let notice = FluidStreamingASR.fallbackNotice(for: session.backend) {
            cloudNotice = notice
        }
        let language = session.language

        if backend == .deepgram {
            if let key = APIKeyStore.load(account: TranscriptionBackend.deepgram.keychainAccount!), !key.isEmpty {
                startDeepgram(apiKey: key, language: language)
            } else {
                backend = .local
                cloudNotice = "Deepgram key missing — using on-device Whisper"
            }
        }
        var decodeOptions = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil
        )

        // Custom vocabulary: prime Whisper with the user's names/terms so it stops
        // mangling proper nouns (e.g. "LaunchEase" → "Lawn Cheese").
        primeGlossary(into: &decodeOptions)

        // Quality + anti-garbage decoding. We derive each segment's timestamps from
        // sample offsets, so suppress Whisper's special + timestamp tokens — they were
        // leaking into the live line as "<|0.00|> ... <|1.00|>" gibberish. The
        // thresholds trip a temperature fallback that breaks Whisper's repetition loops
        // (the "What's your name?" ×N hallucination on near-silent / noisy chunks).
        // noSpeechThreshold is set for the day it works: WhisperKit hardcodes
        // noSpeechProb to 0 (TextDecoder.swift TODO), so it currently gates nothing —
        // see "Why there is no confidence-based noise filter" below.
        decodeOptions.skipSpecialTokens = true
        decodeOptions.withoutTimestamps = true
        decodeOptions.compressionRatioThreshold = 2.4
        decodeOptions.logProbThreshold = -1.0
        decodeOptions.noSpeechThreshold = 0.6
        decodeOptions.temperatureFallbackCount = session.fallbackCount

        // Detached on purpose: startTranscribing is @MainActor, and a plain
        // Task {} would inherit that, putting every energy scan and buffer copy
        // on the main thread for the whole call. The loop belongs on the global
        // executor; its UI-state writes already hop via MainActor explicitly.
        transcriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Rolling-preview pacing, per source. 1s base reads as "words as
            // you speak"; each preview re-decodes the open utterance, so the
            // next one isn't scheduled until 2× the last decode's duration has
            // passed — a fast Mac previews every second, a busy one (copilot +
            // diarization sharing the die) backs off automatically instead of
            // starving the commit decodes. Toggleable in Settings; read once
            // per session like the language setting.
            let previewBase: TimeInterval = 1.0
            var nextPreviewAt: [AudioSource: Date] = [:]
            var lastPreviewText: [AudioSource: String] = [:]
            var emittedPrefix: [AudioSource: String] = [:]
            var loopOptions = decodeOptions
            var lastDetectedLanguage = language
            var frozenLanguage = language
            var commitInFlight = false
            let previewMode = session.preview
            let freezeLanguage = session.freezeLanguage
            let meetingStart = self.meetingStartTime

            while !Task.isCancelled {
                // isTranscribing == false flips the loop into drain mode: keep
                // consuming the backlog (whole utterances, down to the final
                // sub-frame tail) and exit once the buffers are empty. Capture
                // must already be stopped by then or the buffers keep growing —
                // that ordering is RecordingManager.stopRecording's contract.
                let draining = !self.isTranscribing
                var didWork = false
                // Dual-stream stall: a preview of A used to delay a pending
                // cut of B by one full decode. Peek first; commits win.
                let anyCommitReady: Bool = self.bufferLock.withLock {
                    AudioSource.allCases.contains { src in
                        guard let buffered = self.audioBuffers[src], !buffered.isEmpty else {
                            return false
                        }
                        let floor = Segmenter.adaptiveFloor(for: buffered)
                        return Segmenter.nextCut(in: buffered, draining: draining, floor: floor).take != nil
                    }
                }

                for source in AudioSource.allCases {
                    // Pull at most one utterance for this stream under the lock.
                    // The segmenter decides the cut: leading silence is discarded
                    // (the consumed counter still advances, keeping timestamps
                    // absolute) and speech is only taken once a pause bounds it —
                    // or the cap / drain forces the cut. Freeing consumed audio
                    // keeps memory flat; the counter and clock offset ride along
                    // in the same lock.
                    let (chunk, startSample, clockOffset, floor): ([Float], Int, TimeInterval, Float) = self.bufferLock.withLock {
                        guard let buffered = self.audioBuffers[source], !buffered.isEmpty else {
                            return ([], 0, 0, Segmenter.silenceFloor)
                        }
                        let floor = Segmenter.adaptiveFloor(for: buffered)
                        let cut = Segmenter.nextCut(in: buffered, draining: draining, floor: floor)
                        let taken = cut.take.map { Array(buffered[cut.dropLeading ..< cut.dropLeading + $0]) } ?? []
                        let consumed = cut.dropLeading + taken.count
                        guard consumed > 0 else { return ([], 0, 0, floor) }
                        if cut.take == nil, cut.dropLeading > 0 {
                            self.statsLock.withLock {
                                self.decodeStats.samplesDroppedAsSilence += cut.dropLeading
                            }
                        }
                        self.audioBuffers[source] = Array(buffered[consumed...])
                        let start = self.consumedSamples[source] ?? 0
                        self.consumedSamples[source] = start + consumed
                        return (taken, start + cut.dropLeading, self.localClockOffset[source] ?? 0, floor)
                    }
                    guard !chunk.isEmpty else {
                        // Rolling preview — the "text feels slower since
                        // segmentation" fix (2026-08-01 dogfood): while an
                        // utterance is still accumulating, decode what's
                        // buffered into the typing bubble so words appear WHILE
                        // the user talks. Committed segments still land only at
                        // the cut; the buffer is never consumed here. Local
                        // backend only (cloud chunk users keep the dots).
                        // ponytail: a preview of source A delays a pending cut
                        // of source B by one decode; parallelize if dual-speech
                        // latency reports come in.
                        let pendingCount = self.bufferLock.withLock { self.audioBuffers[source]?.count ?? 0 }
                        if backend == .local, !draining,
                           ASRLoopPolicy.shouldPreview(
                            mode: previewMode,
                            commitInFlight: commitInFlight,
                            pendingCount: pendingCount,
                            now: Date(),
                            nextAt: nextPreviewAt[source] ?? .distantPast,
                            otherCommitReady: anyCommitReady
                           ) {
                            let (pending, floor): ([Float], Float) = self.bufferLock.withLock {
                                let buffered = self.audioBuffers[source] ?? []
                                guard buffered.count >= Segmenter.minSpeechSamples else {
                                    return ([], Segmenter.silenceFloor)
                                }
                                return (buffered, Segmenter.adaptiveFloor(for: buffered))
                            }
                            let previewAudio = ASRLoopPolicy.previewSamples(pending, mode: previewMode)
                            let energy = previewAudio.isEmpty ? 0
                                : previewAudio.reduce(into: Float(0)) { $0 += abs($1) } / Float(previewAudio.count)
                            let speculative = ASRLoopPolicy.shouldSpeculativePreview(pendingCount: pending.count)
                            if (energy > floor || speculative), let whisperKit = self.whisperKit {
                                let decodeStarted = Date()
                                let result = (try? await whisperKit.transcribe(
                                    audioArray: Self.normalizedForDecode(previewAudio),
                                    decodeOptions: ASRLoopPolicy.previewOptions(
                                        loopOptions, hintLanguage: lastDetectedLanguage))) ?? []
                                let ms = Date().timeIntervalSince(decodeStarted) * 1000
                                self.statsLock.withLock {
                                    self.decodeStats.record(.preview, ms: ms, meetingStart: meetingStart)
                                }
                                nextPreviewAt[source] = Date().addingTimeInterval(
                                    max(previewBase, Date().timeIntervalSince(decodeStarted) * 2))
                                let raw = Self.cleaned(result.map(\.text).joined(separator: " "))
                                let display = self.glossaryActive ? (Self.strippingGlossaryEcho(raw) ?? "") : raw
                                if Self.loopTrace {
                                    print("TRACE \(source.label) preview: \(display.isEmpty ? "<empty>" : display)")
                                }
                                if !display.isEmpty {
                                    if Self.loopTrace {
                                        print(String(format: "TRACE %@ preview +%.1fs (decode %.2fs): %@",
                                                     source.label,
                                                     Date().timeIntervalSince(self.meetingStartTime),
                                                     Date().timeIntervalSince(decodeStarted), display))
                                    }
                                    await MainActor.run {
                                        self.currentText = display
                                        self.currentSpeaker = source
                                    }
                                    let previous = lastPreviewText[source] ?? ""
                                    if let confirmed = LocalAgreement.confirmedPrefix(previous, display),
                                       let delta = LocalAgreement.delta(
                                        emitted: emittedPrefix[source] ?? "", confirmed: confirmed
                                       ),
                                       !Self.isLikelyHallucination(delta, energy: energy) {
                                        emittedPrefix[source] = confirmed
                                        let (consumed, offset, pendingN): (Int, TimeInterval, Int) =
                                            self.bufferLock.withLock {
                                                (self.consumedSamples[source] ?? 0,
                                                 self.localClockOffset[source] ?? 0,
                                                 self.audioBuffers[source]?.count ?? 0)
                                            }
                                        let agreeStart = Double(consumed) / 16_000 + offset
                                        let agreeEnd = LocalAgreement.estimatedEnd(
                                            startTime: agreeStart,
                                            pendingSamples: pendingN,
                                            confirmed: confirmed,
                                            hypothesis: display
                                        )
                                        self.statsLock.withLock {
                                            self.decodeStats.recordAgreementEmit(meetingStart: meetingStart)
                                        }
                                        let consume = LocalAgreement.samplesForPrefix(
                                            pendingSamples: pendingN,
                                            confirmed: confirmed,
                                            hypothesis: display
                                        )
                                        if consume > 0 {
                                            self.bufferLock.withLock {
                                                let buffered = self.audioBuffers[source] ?? []
                                                let n = min(consume, buffered.count)
                                                self.audioBuffers[source] = Array(buffered[n...])
                                                self.consumedSamples[source] = (self.consumedSamples[source] ?? 0) + n
                                            }
                                        }
                                        let detected = lastDetectedLanguage
                                        await MainActor.run {
                                            self.onSegment?(TranscriptionResult(
                                                text: delta,
                                                source: source,
                                                startTime: agreeStart,
                                                endTime: agreeEnd,
                                                confidence: nil,
                                                detectedLanguage: detected
                                            ))
                                        }
                                    }
                                    lastPreviewText[source] = display
                                }
                            }
                        }
                        continue
                    }
                    didWork = true

                    let startTime = Double(startSample) / 16000.0 + clockOffset
                    let endTime = Double(startSample + chunk.count) / 16000.0 + clockOffset

                    // Backstop energy gate at the stream's adaptive floor. The
                    // segmenter already refuses to cut silence, so this mostly
                    // guards drain-mode tails and keeps feeding the
                    // hallucination filter its energy signal.
                    if ASRLoopPolicy.shouldDropDrainTail(chunk.count, draining: draining) {
                        self.statsLock.withLock {
                            self.decodeStats.samplesDroppedAsSilence += chunk.count
                        }
                        continue
                    }

                    let energy = chunk.reduce(into: Float(0)) { $0 += abs($1) } / Float(chunk.count)
                    // Live soft-cap takes already passed the segmenter. Skipping
                    // them here ate quiet meeting mixes (clip 01: 180 s in, 3 lines
                    // out). Only drain tails still use the energy backstop.
                    if draining, energy <= floor { continue }

                    // Boost quiet-but-real chunks to a healthy level before
                    // every decode. `energy` above stays raw on purpose: the
                    // hallucination filter reads the room, not the boosted copy.
                    let decodeSamples = Self.normalizedForDecode(ASRLoopPolicy.applyDecodeWindowCap(chunk))

                    // On-device decode — the default path, and the per-chunk
                    // fallback when a cloud backend hiccups (never lose a chunk).
                    func decodeLocally() async throws -> [(text: String, confidence: Float?, language: String?)] {
                        guard let whisperKit = self.whisperKit else { return [] }
                        // No interim streaming here anymore: the rolling preview is
                        // the live text, and re-streaming the same sentence from
                        // word one during the commit decode made its tail appear
                        // three times over (preview, re-stream, committed bubble —
                        // the "repeated 3 times" dry-run report, 2026-08-01).
                        func decode(_ options: DecodingOptions, kind: DecodeStats.Kind) async throws -> [(text: String, confidence: Float?, language: String?)] {
                            let decodeStarted = Date()
                            let result = try await whisperKit.transcribe(
                                audioArray: decodeSamples,
                                decodeOptions: options
                            )
                            let ms = Date().timeIntervalSince(decodeStarted) * 1000
                            self.statsLock.withLock {
                                self.decodeStats.record(kind, ms: ms, meetingStart: meetingStart)
                                if options.detectLanguage { self.decodeStats.languageDetects += 1 }
                            }
                            if let lang = result.first?.language, !lang.isEmpty {
                                lastDetectedLanguage = lang
                                if freezeLanguage, frozenLanguage == nil {
                                    frozenLanguage = lang
                                    loopOptions = ASRLoopPolicy.applyingLanguageFreeze(loopOptions, frozen: lang)
                                }
                            }
                            return result.map { transcription in
                                (transcription.text,
                                 transcription.segments.map(\.avgLogprob).reduce(0, +)
                                    / Float(max(transcription.segments.count, 1)),
                                 transcription.language)
                            }
                        }

                        commitInFlight = true
                        defer { commitInFlight = false }
                        let pieces = try await decode(loopOptions, kind: .commit)
                        guard self.glossaryActive else { return pieces }
                        // The glossary prompt can make Whisper swallow a clear
                        // utterance whole — empty text (or only the echoed
                        // prompt) for real speech. Deterministic repro:
                        // --liveloop-test with LIVELOOP_VOCAB on
                        // large-v3-turbo. The segmenter only cuts real speech,
                        // so an unusable decode of it is always wrong: decode
                        // once more without the prompt. Costs one extra pass
                        // only when the prompt misfired; that utterance just
                        // loses its spelling bias.
                        let usable = pieces.contains { piece in
                            let t = Self.cleaned(piece.text)
                            return !t.isEmpty && Self.strippingGlossaryEcho(t) != nil
                        }
                        if usable { return pieces }
                        if Self.loopTrace { print("TRACE \(source.label) glossary decode unusable — retrying bare") }
                        var bare = loopOptions
                        bare.promptTokens = nil
                        bare.usePrefillPrompt = false
                        return try await decode(bare, kind: .glossaryRetry)
                    }

                    do {
                        let pieces: [(text: String, confidence: Float?, language: String?)]
                        if backend == .groq, let groqKey {
                            do {
                                pieces = [(try await GroqTranscriber.transcribe(
                                    samples: decodeSamples, language: language, apiKey: groqKey), nil, language)]
                            } catch {
                                NSLog("Parrot: Groq transcription failed — \(error.localizedDescription)")
                                await MainActor.run {
                                    self.cloudNotice = "Groq error — on-device fallback for failed chunks"
                                }
                                pieces = try await decodeLocally()
                            }
                        } else {
                            pieces = try await decodeLocally()
                        }

                        for piece in pieces {
                            let cleaned = Self.cleaned(piece.text)
                            if ASRLoopPolicy.isWastedDecode(energyPassed: true, text: cleaned) {
                                self.statsLock.withLock { self.decodeStats.emptyTextCommits += 1 }
                            }
                            if Self.loopTrace {
                                // logprob is printed so a real call can be used
                                // to study the noise/quality question with
                                // numbers instead of guesses.
                                print(String(format: "TRACE %@ [%.2f-%.2f] logprob=%@ raw=%@",
                                             source.label, startTime, endTime,
                                             piece.confidence.map { String(format: "%.2f", $0) } ?? "-",
                                             piece.text.isEmpty ? "<empty>" : piece.text))
                            }
                            guard !cleaned.isEmpty else { continue }
                            // Silence hallucinations ("you", "Thank you.",
                            // "Okay.") flooded real transcripts — drop them
                            // when the chunk was near-silent.
                            guard !Self.isLikelyHallucination(cleaned, energy: energy) else { continue }
                            // Prompt leak: the glossary prompt comes back as
                            // "transcription", alone or prefixed onto real
                            // speech — keep the speech, drop only the echo.
                            guard let committed = self.glossaryActive
                                ? Self.strippingGlossaryEcho(cleaned) : cleaned else { continue }
                            let already = emittedPrefix[source] ?? ""
                            let text = LocalAgreement.remainder(emitted: already, full: committed)
                            emittedPrefix[source] = nil
                            lastPreviewText[source] = nil
                            guard !text.isEmpty else { continue }
                            let detected = piece.language ?? lastDetectedLanguage
                            if !self.glossaryActive, let tokenizer = self.whisperKit?.tokenizer {
                                let prompt = ASRLoopPolicy.previousTextPrompt(
                                    [already, text].filter { !$0.isEmpty }.joined(separator: " ")
                                )
                                let tokens = tokenizer.encode(text: " " + prompt)
                                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                                loopOptions = ASRLoopPolicy.applyingPreviousText(loopOptions, tokens: tokens)
                            }

                            await MainActor.run {
                                // Clear the interim line — the text lives in the
                                // committed segment now; leaving it here kept a
                                // duplicate "typing" bubble on screen.
                                self.currentText = ""
                                self.currentSpeaker = nil
                                self.onSegment?(TranscriptionResult(
                                    text: text,
                                    source: source,
                                    startTime: startTime,
                                    endTime: endTime,
                                    confidence: piece.confidence,
                                    detectedLanguage: detected
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
                    let backlog = self.bufferLock.withLock {
                        AudioSource.allCases.contains { (self.audioBuffers[$0]?.count ?? 0) > 0 }
                    }
                    if draining {
                        if !backlog { break }
                        continue
                    }
                    try? await Task.sleep(for: .milliseconds(backlog ? 20 : 250))
                }
            }
        }
    }

    /// Wire up one Deepgram socket per audio source. Interims drive the live
    /// line; finals become segments with Deepgram's stream-relative timestamps
    /// (= meeting-relative, streaming starts with the recording). Any failure
    /// flips the session to the local buffer/loop path.
    private func startDeepgram(apiKey: String, language: String?) {
        for source in AudioSource.allCases {
            let streamer = DeepgramStreamer()
            streamer.onInterim = { [weak self] text in
                let partial = Self.cleaned(text)
                guard !partial.isEmpty else { return }
                Task { @MainActor in
                    self?.currentText = partial
                    self?.currentSpeaker = source
                }
            }
            streamer.onFinal = { [weak self] text, start, end in
                guard let self else { return }
                let cleanedText = Self.cleaned(text)
                // energy 1.0: Deepgram runs its own voice-activity detection,
                // so only punctuation-only junk is filtered here.
                guard !cleanedText.isEmpty,
                      !Self.isLikelyHallucination(cleanedText, energy: 1.0) else { return }
                Task { @MainActor in
                    // Same as the Whisper path: the final belongs to the committed
                    // segment; the interim line must clear or it duplicates.
                    self.currentText = ""
                    self.currentSpeaker = nil
                    self.onSegment?(TranscriptionResult(
                        text: cleanedText, source: source,
                        startTime: start, endTime: end, confidence: nil,
                        detectedLanguage: language))
                }
            }
            streamer.onError = { [weak self] message in
                guard let self else { return }
                NSLog("Parrot: Deepgram stream failed (\(source.label)) — \(message)")
                // Only this stream falls back to local; the other socket keeps
                // streaming. Re-anchor before the first fallback sample lands.
                self.bufferLock.withLock { _ = self.deepgramFailedSources.insert(source) }
                self.reanchorLocalClock(source: source)
                Task { @MainActor in
                    self.cloudNotice = "Deepgram error — \(source.label) stream now on on-device Whisper"
                }
            }
            streamer.connect(apiKey: apiKey, language: language)
            deepgramStreamers[source] = streamer
        }
    }

    /// Re-anchor a stream's locally-derived timestamps to "now" in meeting time.
    /// Called when a stream falls off Deepgram mid-call and when the mic capture
    /// restarts after an input-device change — in both cases the sample counter
    /// wasn't ticking through the gap, so the next locally-transcribed segments
    /// would otherwise land minutes early.
    func reanchorLocalClock(source: AudioSource) {
        let elapsed = Date().timeIntervalSince(meetingStartTime)
        bufferLock.withLock {
            localClockOffset[source] = elapsed - Double(consumedSamples[source] ?? 0) / 16000.0
        }
    }

    /// True while a glossary prompt is active — gates the echo filter below.
    private var glossaryActive = false

    /// Prime Whisper with the user's custom glossary so proper nouns aren't
    /// mangled — shared by the live loop and file import. Fed as an initial
    /// prompt, the standard Whisper mechanism for biasing spelling.
    private func primeGlossary(into options: inout DecodingOptions) {
        glossaryActive = false
        let vocab = (UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vocab.isEmpty, let tokenizer = whisperKit?.tokenizer else { return }
        let terms = vocab
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return }
        let promptText = "Glossary: " + terms.joined(separator: ", ") + "."
        let tokens = tokenizer.encode(text: " " + promptText)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        options.promptTokens = tokens
        options.usePrefillPrompt = true
        glossaryActive = true
    }

    /// Whisper leaks the initial prompt back as fake transcription on silent or
    /// noisy chunks — the live view showed "Glossary, Launchese, Uygar." bubbles
    /// during quiet stretches. Drop any segment that STARTS with "glossary":
    /// spoken vocab terms mid-sentence stay (only the structural echo matches).
    static func isGlossaryEcho(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
            .hasPrefix("glossary")
    }

    /// A prompt leak can PREFIX real speech, not only stand alone — turbo
    /// decoded a live utterance as "Glossary: Launchese, Uygar. However I'm
    /// worried…" and the drop-the-segment filter ate the real sentence
    /// (2026-08-01; `--liveloop-test <audio> large-v3-turbo` with
    /// LIVELOOP_VOCAB reproduces it deterministically). Utterance-sized
    /// segments made that loss a whole sentence, so: strip the leaked echo
    /// sentence, keep what follows. nil = pure echo, drop the segment.
    static func strippingGlossaryEcho(_ text: String) -> String? {
        guard isGlossaryEcho(text) else { return text }
        // The leak is one short "Glossary: …" sentence; cut through its
        // terminator and keep any real speech behind it.
        if let echo = text.range(of: #"^[^.!?]{0,120}[.!?]+"#, options: .regularExpression) {
            let rest = String(text[echo.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    // MARK: - File Import (whole-file, on-device)

    /// Transcribe a complete audio file on-device — the import path. Runs fully
    /// independent of the live streaming loop (never touches `isTranscribing` or
    /// the chunk buffers), so importing can't disturb an in-flight recording.
    /// Unlike the live loop it keeps Whisper's own segment timestamps: the loop
    /// derives them from sample offsets and suppresses them, but for a whole file
    /// Whisper's per-utterance boundaries are exactly what we want.
    /// WhisperKit loads + resamples any format (m4a/mp3/wav/aac/caf) to 16 kHz mono.
    func transcribeFile(url: URL) async throws -> [TranscriptionResult] {
        guard let whisperKit else { throw RecordingError.modelNotReady }

        let setting = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        let language = (setting == nil || setting == "auto") ? nil : setting

        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil
        )
        // Same anti-garbage decoding as the live loop, but WITHOUT
        // `withoutTimestamps` — we want the segment timestamps here.
        options.skipSpecialTokens = true
        options.compressionRatioThreshold = 2.4
        options.logProbThreshold = -1.0
        options.noSpeechThreshold = 0.6
        options.temperatureFallbackCount = (sessionOverride ?? LoopSessionConfig.fromEnvironmentAndDefaults()).fallbackCount
        primeGlossary(into: &options)

        let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)

        // One mixed track, so every segment is "Them"; diarization splits it later.
        return results.flatMap(\.segments).compactMap { segment in
            let cleaned = Self.cleaned(segment.text)
            guard !cleaned.isEmpty else { return nil }
            // Same glossary-prompt echo handling as the live loop.
            guard let text = glossaryActive
                ? Self.strippingGlossaryEcho(cleaned) : cleaned else { return nil }
            return TranscriptionResult(
                text: text,
                source: .them,
                startTime: Double(segment.start),
                endTime: Double(segment.end),
                confidence: segment.avgLogprob,
                detectedLanguage: language
            )
        }
    }

    /// Stop transcription, draining the buffered backlog first so the final words
    /// of the call (previously always dropped — the loop needed ≥2 s buffered)
    /// make it into the transcript. Await this before assembling the transcript.
    // ponytail: drain is uncapped — a hung whisper pass hangs stop; upgrade path
    // is a wall-clock cap + surfaced timeout.
    @MainActor
    func stopTranscribing() async {
        // Streaming backend: flush finals, then tear down. When the stream is
        // healthy, the chunk buffers only hold pre-connection audio — clear
        // them so the drain can't re-emit the call's first words at the end.
        if !deepgramStreamers.isEmpty {
            for streamer in deepgramStreamers.values { streamer.finish() }
            try? await Task.sleep(for: .seconds(1.2))  // grace for final results
            for streamer in deepgramStreamers.values { streamer.close() }
            // Clear the pre-connection buffers of streams that stayed on
            // Deepgram; a fallen-back stream's buffered tail still needs draining.
            bufferLock.withLock {
                for source in AudioSource.allCases where !deepgramFailedSources.contains(source) {
                    audioBuffers[source] = []
                }
            }
            deepgramStreamers = [:]
        }

        isTranscribing = false          // flips the loop into drain mode
        await transcriptionTask?.value  // deliberately not cancel(): let it finish
        transcriptionTask = nil

        bufferLock.withLock {
            audioBuffers = [.me: [], .them: []]
        }

        currentText = ""
        currentSpeaker = nil
        isHearingSpeech = false
    }

    /// The classic Whisper silence hallucinations — phrases the model invents
    /// verbatim on near-silent chunks (YouTube-outro residue in its training
    /// data). Matched against normalized text, only for low-energy chunks.
    static let hallucinationPhrases: Set<String> = [
        "you", "okay", "ok", "thank you", "thanks", "bye", "bye-bye",
        "thank you for watching", "thanks for watching", "hmm", "mm-hmm",
        "uh", "um", "the end", "subtitles by", "1", "2",
    ]

    // MARK: Why there is no confidence-based noise filter
    //
    // Typing next to the mic makes Whisper narrate confident nonsense, and the
    // obvious fix — drop segments below some avgLogprob floor — is a trap. Two
    // findings from the real store (9,301 stored segments, 2026-08-04):
    //
    // 1. avgLogprob tracks LANGUAGE, not junk. Segments containing Turkish
    //    characters average -1.43; plain-latin segments average -0.29, and
    //    every one of the 115 segments scoring -Inf is real Turkish speech.
    //    Any floor that catches junk (junk sat at -0.50..-0.94 on the
    //    2026-08-01 call, real English at -0.03..-0.47) would silently delete
    //    most of a bilingual user's transcript. Never ship a global floor.
    // 2. noSpeechProb — the signal that would actually separate speech from
    //    keyboard clatter — is hardcoded to 0 in WhisperKit
    //    (TextDecoder.swift: "let noSpeechProb: Float = 0 // TODO"). It is
    //    always 0.0 in traces, so `decodeOptions.noSpeechThreshold` below is
    //    inert too, and no filter can lean on it until upstream implements it.
    //
    // What could work later: compare a segment against the median confidence
    // for its own language within the same call (junk is an outlier per
    // language, whereas a whole language is not), or gate on acoustics before
    // decoding. Both need per-segment language, which isn't stored yet.
    // PARROT_LOOP_TRACE=1 prints per-chunk logprob for exactly this work.

    /// True when a decoded chunk is almost certainly invented: punctuation-only
    /// text, or a known silence-hallucination phrase produced from a chunk that
    /// carried no confident speech energy. A real "Okay." at speaking volume
    /// (energy well above the floor) is never dropped.
    static func isLikelyHallucination(_ text: String, energy: Float) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?…-—"))
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return true }  // "." and friends, at any volume
        // ponytail: 0.006 mean-abs ≈ room noise ceiling; speech runs 0.01+.
        // Tune here if quiet-talker reports come in.
        guard energy < 0.006 else { return false }
        return hallucinationPhrases.contains(normalized)
    }

    /// Strips any Whisper special/timestamp tokens (e.g. "<|startoftranscript|>",
    /// "<|0.00|>") that can leak into raw decoder text, and trims whitespace.
    static func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
