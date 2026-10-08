import AVFoundation
import FluidAudio
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
    /// Set per recording: the call is on-device only (see CloudGate).
    var forceLocal = false
    private var whisperKit: WhisperKit?
    /// The model the user picked (a Whisper tag or `ParakeetTranscriber.modelID`).
    @ObservationIgnored private(set) var currentModel = ""
    /// Loaded when Parakeet is the model; `whisperKit` then stays nil until a
    /// side of a call needs Whisper (see `ensureWhisper`).
    @ObservationIgnored private var parakeet: ParakeetTranscriber?
    /// Whisper Tiny, only for "which language is this?" while on Parakeet.
    @ObservationIgnored private var tinyDetector: WhisperKit?
    @ObservationIgnored private var whisperLoad: Task<WhisperKit?, Never>?
    /// Silero voice-activity model (FluidAudio, on-device), the last gate
    /// before every decode. Whisper narrates noise ("so", "What can I do?"
    /// from an idle room), and no loudness rule tells quiet speech from room
    /// tone. nil until loaded, or if its one-time download failed; then
    /// nothing is gated. Guarded by `bufferLock` (read from the loop).
    private var speechDetector: VadManager?
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
    /// don't measure dead time: when a stream falls off Deepgram mid-call the
    /// counter is way behind the meeting clock, and without re-anchoring the fallback segments restart
    /// at 0:00 — the bug that filed the back half of a call under minute 3.
    /// Guarded by `bufferLock`.
    private var localClockOffset: [AudioSource: TimeInterval] = [:]
    /// Total samples consumed (and freed) per stream by the local loop. The
    /// buffers only ever hold not-yet-transcribed samples, so memory stays flat
    /// over a long call; these running totals keep segment timestamps absolute.
    /// Guarded by `bufferLock` (the loop and `reanchorLocalClock` both touch it).
    private var consumedSamples: [AudioSource: Int] = [:]
    /// Each stream's loudness per 20 ms, counted like `consumedSamples`, for
    /// the echo gate. Guarded by `bufferLock`.
    private var levels: [AudioSource: EchoGate.Levels] = [:]
    private var meetingStartTime = Date()

    /// The language this call sounds like, when it isn't what the session is
    /// transcribing in (nil = no mismatch, or not checked yet). The live bar
    /// offers a one-click switch. A pinned English setting on a Turkish call
    /// turned 46 minutes into English-shaped nonsense on 2026-09-30.
    private(set) var languageMismatch: String?
    /// The session's language (nil = auto). Read per decode by the local loop
    /// and swapped by `switchLanguage`. Guarded by `bufferLock`.
    private var sessionLanguage: String?
    private var sessionBackend: TranscriptionBackend = .local
    private var deepgramKey: String?
    /// Voiced audio gathered per side for the language check (one side each:
    /// interleaving both would feed Whisper stitched-up audio). nil = off.
    /// Guarded by `bufferLock`.
    private var probe: LanguageProbe?
    /// Which engine each side uses (Parakeet on Auto-detect holds each side
    /// until its check). Guarded by `bufferLock`.
    private var router = LanguageRouter(parakeet: false, pinned: nil)
    /// The mismatch banner, kept up all call (see `MismatchWatch`). Main actor.
    @ObservationIgnored private var watch = MismatchWatch(setting: nil)
    /// Enough speech for Whisper to be sure: 10 s scored p ≥ 0.93 on 8 real
    /// tracks (Turkish and English, both sides), and warns twice as soon as 20.
    static let languageProbeSamples = 10 * 16000

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
    /// Per stream: samples appended so far, and the count at the last buffer
    /// with speech-level energy (both guarded by bufferLock). Live nudges read
    /// them through `speechClock()`, on the same clock as segment timestamps.
    private var appendedSamples: [AudioSource: Int] = [:]
    private var heardSamples: [AudioSource: Int] = [:]
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
        currentModel = modelName
        // Download progress lands on the main actor, for this load only.
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation,
                      case .downloading(let current) = self.modelState else { return }
                self.modelState = .downloading(progress: max(current, fraction))
            }
        }
        do {
            if Self.isParakeet(modelName) {
                modelState = ParakeetTranscriber.isDownloaded ? .loading : .downloading(progress: 0)
                let parakeet = try await ParakeetTranscriber.load(progress: progress)
                // No detector just means every side goes to Whisper: safe.
                let detector = try? await Self.makeWhisperKit(Self.detectorModel)
                guard loadGeneration == generation else { return }
                self.parakeet = parakeet
                tinyDetector = detector
                whisperKit = nil   // loaded again only when a call needs it
                modelState = .ready
                isReady = true
                Task { await self.loadSpeechDetector() }
                Task.detached(priority: .utility) { await Self.prepareFallback() }
                return
            }
            if Self.localModelFolder(for: modelName) == nil { modelState = .downloading(progress: 0) }
            let kit = try await Self.makeWhisperKit(modelName, loading: { @MainActor [weak self] in
                if let self, self.loadGeneration == generation { self.modelState = .loading }
            }, progress: progress)
            guard loadGeneration == generation else { return }
            parakeet = nil
            tinyDetector = nil
            whisperKit = kit
            modelState = .ready
            isReady = true
            // Background: a first-run download must never hold up recording.
            Task { await self.loadSpeechDetector() }
        } catch {
            guard loadGeneration == generation, !(error is CancellationError) else { return }
            modelState = .error(error.localizedDescription)
            isReady = false
        }
    }

    /// Download (if missing) and load one WhisperKit model. `loading` runs
    /// once the files are there, before the (possibly long) Core ML load.
    nonisolated static func makeWhisperKit(_ modelName: String,
                                           loading: (@Sendable () async -> Void)? = nil,
                                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> WhisperKit {
        let resolvedModelName = hubVariant(for: modelName)
        let modelFolder: URL
        if let localFolder = localModelFolder(for: modelName) {
            modelFolder = localFolder
        } else {
            modelFolder = try await withStallTimeout(seconds: 60) { tick in
                try await WhisperKit.download(variant: resolvedModelName) { download in
                    let fraction = min(max(download.fractionCompleted, 0), 1)
                    tick(fraction)
                    progress?(fraction)
                }
            }
        }
        await loading?()
        let config = WhisperKitConfig(
            model: resolvedModelName,
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )
        return try await withTimeout(seconds: 300) { try await WhisperKit(config) }
    }

    /// What answers "which language is this?": Tiny while Parakeet is the
    /// model, else the loaded Whisper (English-only models can't tell).
    private var languageDetector: WhisperKit? { parakeet != nil ? tinyDetector : whisperKit }

    /// The Whisper to decode with. On Parakeet it's the fallback, loaded the
    /// first time a side of a call needs it (seconds, thanks to
    /// `prepareFallback`); that side's audio waits in its buffer meanwhile.
    // ponytail: only the transcription loop and imports call this, never both at once.
    func ensureWhisper() async -> WhisperKit? {
        if let whisperKit { return whisperKit }
        // One load however many callers (the loop, an import, the preload).
        let load: Task<WhisperKit?, Never> = bufferLock.withLock {
            if let whisperLoad { return whisperLoad }
            let fresh = Task { try? await Self.makeWhisperKit(Self.fallbackWhisper) }
            whisperLoad = fresh
            return fresh
        }
        let kit = await load.value
        whisperKit = kit
        bufferLock.withLock { whisperLoad = nil }
        return kit
    }

    /// Download the fallback and load it once, so macOS prepares it for the
    /// Neural Engine now (the first load can take minutes) instead of mid-call.
    nonisolated static func prepareFallback() async {
        let key = "parakeetFallbackPrepared"
        guard UserDefaults.standard.string(forKey: key) != fallbackWhisper else { return }
        guard (try? await makeWhisperKit(fallbackWhisper)) != nil else { return }
        UserDefaults.standard.set(fallbackWhisper, forKey: key)
    }

    /// Loads the voice-activity model (~1 MB from Hugging Face the first
    /// time, like the Whisper models). Until it's there, clips go to Whisper
    /// ungated, as before. Capped so a stalled download can't hold up the
    /// polish or import passes that wait on it.
    func loadSpeechDetector() async {
        guard bufferLock.withLock({ speechDetector }) == nil else { return }
        do {
            let detector = try await Self.withTimeout(seconds: 60) { try await VadManager() }
            bufferLock.withLock { speechDetector = detector }
        } catch {
            AudioCaptureManager.oslog.error("Speech detector unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Minimum speech probability, in at least one 256 ms window, for a clip
    /// to reach Whisper. Calibrated 2026-09-24 on real room tone from this
    /// Mac plus typing/hum/pink noise: words with content scored 1.00 even at
    /// 0.02× gain over room tone (English, Turkish, one-word answers; lowest
    /// real-speech clip 0.74), while clips Whisper turned into junk scored
    /// 0.06–0.64 but for a few faint maybe-voices. PARROT_VAD_THRESHOLD
    /// overrides it; 0 disables gating but keeps the trace.
    static let speechThreshold: Float = ProcessInfo.processInfo.environment["PARROT_VAD_THRESHOLD"]
        .flatMap(Float.init) ?? 0.6

    /// Peak Silero speech probability over the clip; nil when there's no
    /// detector (not downloaded) or it failed, which means "don't gate".
    private func speechPeak(_ samples: [Float]) async -> Float? {
        guard let detector = bufferLock.withLock({ speechDetector }),
              let results = try? await detector.process(samples) else { return nil }
        return results.map(\.probability).max()
    }

    /// Speech probability per 256 ms window for a whole track, for the
    /// whole-file passes (polish, import) that have no live gate in front of
    /// Whisper. nil = no detector, keep everything.
    func speechTimeline(samples: [Float]? = nil, url: URL? = nil) async -> [Float]? {
        await loadSpeechDetector()
        guard let detector = bufferLock.withLock({ speechDetector }) else { return nil }
        let results: [VadResult]?
        if let samples { results = try? await detector.process(samples) }
        else if let url { results = try? await detector.process(url) }
        else { results = nil }
        return results?.map(\.probability)
    }

    /// Whether [start, end] ± `pad` seconds holds speech: two consecutive
    /// voiced windows (~0.5 s). Whole-file Whisper writes its inventions over
    /// 30 s blocks, and room tone throws lone one-window spikes into those;
    /// a real word spans 2+ windows, even a quiet "Yes." (2026-09-24
    /// timelines). The pad forgives drifting timestamps; a span outside the
    /// timeline is kept, so a mismatch can never delete real text.
    nonisolated static func hasVoice(_ timeline: [Float], from start: Double, to end: Double,
                                     pad: Double = 1.0) -> Bool {
        let window = Double(VadManager.chunkSize) / 16000
        let lo = max(0, Int(((start - pad) / window).rounded(.down)))
        let hi = min(timeline.count - 1, Int(((end + pad) / window).rounded(.up)))
        guard lo <= hi else { return true }
        return timeline[lo...hi].indices.dropFirst().contains {
            timeline[$0 - 1] >= speechThreshold && timeline[$0] >= speechThreshold
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
        case ParakeetTranscriber.modelID: ParakeetTranscriber.displayName
        default: modelName
        }
    }

    nonisolated static func isParakeet(_ modelName: String) -> Bool { modelName == ParakeetTranscriber.modelID }
    /// The Whisper a Parakeet call switches to for other languages.
    nonisolated static let fallbackWhisper = "large-v3-v20240930_626MB"
    /// Whisper's language check while Parakeet is the model.
    nonisolated static let detectorModel = "tiny"

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

    /// Tracks whether a download is still moving. Only a rise in progress
    /// counts, so a stuck value can't keep it alive.
    struct ProgressStall {
        let limit: TimeInterval
        private var best: Double = -1
        private var lastMove: Date

        init(limit: TimeInterval, start: Date = .now) {
            self.limit = limit
            lastMove = start
        }

        mutating func note(_ progress: Double, at time: Date = .now) {
            guard progress > best else { return }
            best = progress
            lastMove = time
        }

        func isStalled(at time: Date = .now) -> Bool {
            time.timeIntervalSince(lastMove) >= limit
        }
    }

    /// Like `withTimeout`, but for downloads: fails only when progress stops
    /// moving for `seconds`. A fixed limit failed the 1.6 GB turbo model on
    /// anything slower than ~5 MB/s.
    nonisolated private static func withStallTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ op: @escaping @Sendable (_ tick: @escaping @Sendable (Double) -> Void) async throws -> T
    ) async throws -> T {
        let watch = OSAllocatedUnfairLock(initialState: ProgressStall(limit: seconds))
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op { progress in watch.withLock { $0.note(progress) } } }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if watch.withLock({ $0.isStalled() }) { throw ModelLoadTimeout() }
                }
            }
            guard let first = try await group.next() else { throw ModelLoadTimeout() }
            group.cancelAll()
            return first
        }
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
            bufferLock.withLock {
                let total = (appendedSamples[source] ?? 0) + frameCount
                appendedSamples[source] = total
                if energy > floor { heardSamples[source] = total }
            }
            let hearing = Date().timeIntervalSince(lastSpeechAt) < 1.0
            if hearing != isHearingSpeech {
                Task { @MainActor in self.isHearingSpeech = hearing }
            }
        }

        // Language check: gather each side's first voiced audio, then ask
        // Whisper what it hears. Runs for every backend, since the setting is
        // shared and a wrong pin ruins all of them; on Parakeet it also
        // decides which engine transcribes that side.
        if isTranscribing, frameCount > 0 {
            let energy = samples.reduce(into: Float(0)) { $0 += abs($1) } / Float(frameCount)
            let full: [Float]? = bufferLock.withLock {
                probe?.add(samples, voiced: energy > Segmenter.silenceFloor, from: source, at: Date(),
                           holding: router.route(source) == .undecided)
            }
            if let full { Task { await self.checkLanguage(full, source: source) } }
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
            levels[source, default: EchoGate.Levels()].add(samples[...])
        }
    }

    /// "Now" and when each stream last carried speech, in seconds into the
    /// call on the segments' own clock (samples / 16 kHz + the stream's
    /// offset). A wall clock would drift from segment times whenever a tap
    /// starts late.
    func speechClock() -> (now: TimeInterval, lastHeard: [AudioSource: TimeInterval]) {
        bufferLock.withLock {
            var now: TimeInterval = 0
            var heard: [AudioSource: TimeInterval] = [:]
            for source in AudioSource.allCases {
                let offset = localClockOffset[source] ?? 0
                if let n = appendedSamples[source] { now = max(now, Double(n) / 16000 + offset) }
                if let h = heardSamples[source] { heard[source] = Double(h) / 16000 + offset }
            }
            return (now, heard)
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
            // Flat for longer than any real utterance runs without a dip is
            // steady noise (fan, hum, hiss), not un-paused quiet speech: left
            // as "speech" it was cut every 12 s and Whisper narrated it
            // ("so", "What can I do?" from an idle room, 2026-09-24).
            if frames > maxFlatSpeechFrames { return silenceFloor }
            return maxE >= ditherFloor ? ditherFloor : silenceFloor
        }
        /// How long a flat window may still be quiet speech waiting for its
        /// pause. Speech dips between words well within 3 s; noise doesn't.
        static let maxFlatSpeechFrames = 30
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
                // All silence so far. Keep the partial tail frame while live (it
                // may be the onset of a word); draining consumes everything so
                // the loop can reach empty and exit.
                return Cut(dropLeading: draining ? n : frames * frame, take: nil)
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
        // Retries a detector download that failed at launch (offline first run).
        Task { await self.loadSpeechDetector() }

        // Resolve the transcription backend for this session. Cloud backends
        // need their key; anything missing falls back to on-device with a
        // visible notice. (Deepgram streaming lands separately; until then it
        // behaves as local.)
        // An on-device-only call never uses a cloud engine.
        var backend = forceLocal ? .local : TranscriptionBackend.selected
        var groqKey: String?
        cloudNotice = nil
        self.meetingStartTime = meetingStartTime
        bufferLock.withLock {
            deepgramFailedSources = []
            localClockOffset = [:]
            consumedSamples = [.me: 0, .them: 0]
            levels = [:]
            appendedSamples = [:]
            heardSamples = [:]
        }
        deepgramStreamers = [:]
        if backend == .groq {
            groqKey = APIKeyStore.load(account: TranscriptionBackend.groq.keychainAccount!)
            if groqKey?.isEmpty != false {
                backend = .local
                cloudNotice = "Groq key missing — using on-device \(onDeviceName)"
            }
        }

        // Resolve the user's transcription language ("auto"/nil = auto-detect).
        let language = TranscriptionLanguage.selected
        languageMismatch = nil
        watch = MismatchWatch(setting: language)
        deepgramKey = nil
        bufferLock.withLock {
            sessionLanguage = language
            probe = LanguageProbe()
        }
        kept = [:]
        pendingRecheck = [:]

        if backend == .deepgram {
            if let key = APIKeyStore.load(account: TranscriptionBackend.deepgram.keychainAccount!), !key.isEmpty {
                deepgramKey = key
                startDeepgram(apiKey: key, language: language)
            } else {
                backend = .local
                cloudNotice = "Deepgram key missing — using on-device \(onDeviceName)"
            }
        }
        let resolved = backend
        let routesParakeet = parakeet != nil && resolved == .local
        let holding: Bool = bufferLock.withLock {
            sessionBackend = resolved
            router = LanguageRouter(parakeet: routesParakeet, pinned: language)
            return router.isHolding
        }
        if holding {
            cloudNotice = Self.checkingNotice
        } else if routesParakeet, let language, !LanguageRouter.parakeetLanguages.contains(language) {
            cloudNotice = "\(TranscriptionLanguage.name(language)) isn't a Parakeet language: using Whisper"
            // Picked before the call: load it now, so the first line isn't late.
            Task.detached(priority: .userInitiated) { [weak self] in _ = await self?.ensureWhisper() }
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
        decodeOptions.temperatureFallbackCount = 3

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
            let previewEnabled = UserDefaults.standard.object(forKey: "livePreview") as? Bool ?? true
            var nextPreviewAt: [AudioSource: Date] = [:]

            while !Task.isCancelled {
                // Re-read per pass: `switchLanguage` can change it mid-call.
                let language = self.bufferLock.withLock { self.sessionLanguage }
                var decodeOptions = decodeOptions
                decodeOptions.language = language
                decodeOptions.detectLanguage = language == nil

                // isTranscribing == false flips the loop into drain mode: keep
                // consuming the backlog (whole utterances, down to the final
                // sub-frame tail) and exit once the buffers are empty. Capture
                // must already be stopped by then or the buffers keep growing —
                // that ordering is RecordingManager.stopRecording's contract.
                let draining = !self.isTranscribing
                var didWork = false

                for source in AudioSource.allCases {
                    // Parakeet on Auto-detect: this side's language isn't known
                    // yet, so its audio waits in the buffer (Whisper needs ~10 s
                    // of speech to be sure). Past 30 s of waiting it's checked
                    // with what there is; while stopping, right away. Once
                    // decided, the backlog below catches up in bounded cuts.
                    if self.bufferLock.withLock({ self.router.route(source) }) == .undecided {
                        let due = self.bufferLock.withLock {
                            self.probe?.take(source, at: Date(), force: draining, holding: true)
                        }
                        if let due {
                            await self.checkLanguage(due, source: source)
                        }
                        if self.bufferLock.withLock({ self.router.route(source) }) == .undecided {
                            // Nothing to take while stopping means this side's
                            // check is already running (the probe filled): wait
                            // for its answer rather than guess. Draining never
                            // sleeps on its own, so pace the wait here.
                            if draining { try? await Task.sleep(for: .milliseconds(50)) }
                            continue
                        }
                    }
                    if let seconds = self.pendingRecheck.removeValue(forKey: source) {
                        await self.recheck(source, seconds: seconds, options: decodeOptions)
                    }

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
                        if previewEnabled, backend == .local, !draining,
                           Date() >= nextPreviewAt[source] ?? .distantPast {
                            let (pending, floor): ([Float], Float) = self.bufferLock.withLock {
                                let buffered = self.audioBuffers[source] ?? []
                                guard buffered.count >= Segmenter.minSpeechSamples else {
                                    return ([], Segmenter.silenceFloor)
                                }
                                return (buffered, Segmenter.adaptiveFloor(for: buffered))
                            }
                            let energy = pending.isEmpty ? 0
                                : pending.reduce(into: Float(0)) { $0 += abs($1) } / Float(pending.count)
                            var voiced = energy > floor
                            if voiced, let peak = await self.speechPeak(pending),
                               peak < Self.speechThreshold {
                                // Room noise: no bubble, and no re-check for a beat.
                                voiced = false
                                nextPreviewAt[source] = Date().addingTimeInterval(previewBase)
                            }
                            // No interim callback here on purpose: each preview
                            // re-decodes from the utterance's start, so streaming
                            // its words made the bubble restart the same sentence
                            // every cycle (dry-run feedback, 2026-08-01). The
                            // bubble now updates once per preview with the fuller
                            // text; word-by-word streaming stays on the commit
                            // decode where it reads forward, not in circles.
                            // The side's own engine; a preview never triggers the
                            // lazy Whisper load, only a commit decode does.
                            let decodeStarted = Date()
                            var previewText: String?
                            if voiced {
                                switch self.bufferLock.withLock({ self.router.route(source) }) {
                                case .parakeet(let language):
                                    if let parakeet = self.parakeet {
                                        previewText = (try? await parakeet.transcribe(
                                            Self.normalizedForDecode(pending), language: language)) ?? ""
                                    }
                                case .whisper:
                                    if let whisperKit = self.whisperKit {
                                        let result = (try? await whisperKit.transcribe(
                                            audioArray: Self.normalizedForDecode(pending),
                                            decodeOptions: decodeOptions)) ?? []
                                        previewText = result.map(\.text).joined(separator: " ")
                                    }
                                case .undecided:
                                    break
                                }
                            }
                            if let previewText {
                                nextPreviewAt[source] = Date().addingTimeInterval(
                                    max(previewBase, Date().timeIntervalSince(decodeStarted) * 2))
                                let raw = Self.cleaned(previewText)
                                let display = self.glossaryActive ? (Self.strippingGlossaryEcho(raw) ?? "") : raw
                                if Self.loopTrace {
                                    // Printed even when empty: "gate never passed"
                                    // and "decoded to nothing" need different fixes.
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
                    let energy = chunk.reduce(into: Float(0)) { $0 += abs($1) } / Float(chunk.count)
                    guard energy > floor else { continue }

                    // Boost quiet-but-real chunks to a healthy level before
                    // every decode. `energy` above stays raw on purpose: the
                    // hallucination filter reads the room, not the boosted copy.
                    let decodeSamples = Self.normalizedForDecode(chunk)

                    // No voice in the clip: Whisper would only invent text.
                    // Ahead of every backend, so noise isn't uploaded either.
                    // Scored on the RAW clip: boosted room tone reads as
                    // speech to the detector too (0.8–1.0 vs 0.2–0.4 raw,
                    // 2026-09-24), while real speech scores 1.0 at any gain.
                    let vadStarted = Date()
                    if let peak = await self.speechPeak(chunk) {
                        if Self.loopTrace {
                            print(String(format: "TRACE %@ [%.2f-%.2f] vad=%.2f (%.0f ms) energy=%.5f%@",
                                         source.label, startTime, endTime, peak,
                                         Date().timeIntervalSince(vadStarted) * 1000, energy,
                                         peak < Self.speechThreshold ? " SKIP" : ""))
                        }
                        guard peak >= Self.speechThreshold else { continue }
                    }

                    // Speakers: the mic re-hears the other side, and what the
                    // echo canceller leaves decodes as Me lines, often filler in
                    // another language that shares no words with theirs (#98).
                    // Once the call shows the mic hears the speakers, skip a Me
                    // clip whose loudness just follows theirs. Ahead of every
                    // backend, like the voice gate.
                    if source == .me {
                        let tracks: (mic: [Float], them: [Float])? = self.bufferLock.withLock {
                            // ponytail: both clocks must agree; a cloud fallback re-anchors one, and then the gate sits out.
                            guard self.localClockOffset[.me] == self.localClockOffset[.them],
                                  let mic = self.levels[.me], let them = self.levels[.them] else { return nil }
                            return (mic.frames, them.frames)
                        }
                        if let tracks {
                            let verdict = EchoGate.check(clip: chunk, mic: tracks.mic, them: tracks.them,
                                                         at: startSample / EchoGate.hop)
                            if verdict.isEcho {
                                AudioCaptureManager.oslog.log("echo gate skipped a Me clip at \(startTime, format: .fixed(precision: 1), privacy: .public) s (follows \(verdict.clip.follows, format: .fixed(precision: 2), privacy: .public), bleed \(verdict.bleed.follows, format: .fixed(precision: 2), privacy: .public))")
                                if Self.loopTrace {
                                    print(String(format: "TRACE Me [%.2f-%.2f] echo gate SKIP follows=%.2f bleed=%.2f lag=%d",
                                                 startTime, endTime, verdict.clip.follows, verdict.bleed.follows, verdict.clip.lag))
                                }
                                continue
                            }
                        }
                    }

                    // On-device decode — the default path, and the per-chunk
                    // fallback when a cloud backend hiccups (never lose a chunk).
                    func decodeLocally() async throws -> [(text: String, confidence: Float?)] {
                        if case .parakeet(let language) = self.bufferLock.withLock({ self.router.route(source) }),
                           let parakeet = self.parakeet {
                            let (text, score) = try await parakeet.transcribeScored(decodeSamples, language: language)
                            if Self.loopTrace { print(String(format: "TRACE %@ parakeet[%@] conf=%.3f: %@", source.label, language ?? "-", score, text)) }
                            self.keepForRecheck(chunk, source: source, start: startTime, end: endTime,
                                                doubtful: Self.parakeetDoubts(score, seconds: endTime - startTime))
                            // Parakeet's 0-1 score isn't Whisper's log-prob: don't mix them.
                            return [(text, nil)]
                        }
                        // Whisper: on Parakeet, loaded the first time a side needs it.
                        if Self.loopTrace, self.whisperKit == nil { print("TRACE \(source.label) loading Whisper \(Self.fallbackWhisper)") }
                        guard let whisperKit = await self.ensureWhisper() else { return [] }
                        if Self.loopTrace, self.parakeet != nil { print("TRACE \(source.label) whisper decode") }
                        // No interim streaming here anymore: the rolling preview is
                        // the live text, and re-streaming the same sentence from
                        // word one during the commit decode made its tail appear
                        // three times over (preview, re-stream, committed bubble —
                        // the "repeated 3 times" dry-run report, 2026-08-01).
                        func decode(_ options: DecodingOptions) async throws -> [(text: String, confidence: Float?)] {
                            let result = try await whisperKit.transcribe(
                                audioArray: decodeSamples,
                                decodeOptions: options
                            )
                            return result.map { transcription in
                                (transcription.text,
                                 transcription.segments.map(\.avgLogprob).reduce(0, +)
                                    / Float(max(transcription.segments.count, 1)))
                            }
                        }

                        let pieces = try await decode(decodeOptions)
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
                        return try await decode(Self.withoutGlossary(decodeOptions))
                    }

                    do {
                        let pieces: [(text: String, confidence: Float?)]
                        if backend == .groq, let groqKey {
                            do {
                                // No glossary prompt for Groq: it echoes the prompt into
                                // quiet chunks ("Glossary, Uygar", mangled name tags) and
                                // there is no echo guard or bare retry on this path, unlike
                                // the on-device decode above. A real 20-minute call on
                                // 2026-09-23 was ruined that way. Re-add only with both.
                                pieces = [(try await GroqTranscriber.transcribe(
                                    samples: decodeSamples, language: language, apiKey: groqKey), nil)]
                            } catch {
                                AudioCaptureManager.oslog.error("Groq transcription failed: \(error.localizedDescription, privacy: .public)")
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
                            guard let text = self.glossaryActive
                                ? Self.strippingGlossaryEcho(cleaned) : cleaned else { continue }

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
                                    confidence: piece.confidence
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
                if draining {
                    // Exit only on truly empty buffers. `didWork` counts decodes,
                    // not discards: a dropped noise blip used to end the drain
                    // and lose every word buffered after it. Each drain cut
                    // consumes something, so this always terminates.
                    if self.bufferLock.withLock({ self.audioBuffers.values.allSatisfy(\.isEmpty) }) { break }
                } else if !didWork {
                    try? await Task.sleep(for: .milliseconds(250))
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
            deepgramStreamers[source] = makeDeepgramStreamer(
                source: source, apiKey: apiKey, language: language, offset: 0)
        }
    }

    /// One connected socket for `source`. `offset` is the meeting time the
    /// socket opens at: Deepgram's timestamps restart at 0 on every stream.
    private func makeDeepgramStreamer(source: AudioSource, apiKey: String,
                                      language: String?, offset: TimeInterval) -> DeepgramStreamer {
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
                    startTime: start + offset, endTime: end + offset, confidence: nil))
            }
        }
        streamer.onError = { [weak self] message in
            guard let self else { return }
            // Public on purpose: NSLog is redacted in `log show`, and this
            // is the only place the real Deepgram failure reason exists.
            AudioCaptureManager.oslog.error("Deepgram stream failed (\(source.label, privacy: .public)): \(message, privacy: .public)")
            // Only this stream falls back to local; the other socket keeps
            // streaming. Re-anchor before the first fallback sample lands.
            self.bufferLock.withLock { _ = self.deepgramFailedSources.insert(source) }
            self.reanchorLocalClock(source: source)
            Task { @MainActor in
                self.cloudNotice = "Deepgram error — \(source.label) stream now on on-device Whisper"
            }
        }
        streamer.connect(apiKey: apiKey, language: language)
        return streamer
    }

    /// "Keep English": the banner goes, and the watch has already marked
    /// that language as offered, so it won't come back this call.
    @MainActor
    func dismissLanguageMismatch() {
        languageMismatch = nil
    }

    /// Switch the running call to `code` and remember it for the next one.
    /// Deepgram sockets are pinned to a language at connect, so each healthy
    /// one is replaced; the old socket flushes its finals, then closes. The
    /// local and Groq paths pick the new language up on their next pass.
    @MainActor
    func switchLanguage(to code: String) {
        UserDefaults.standard.set(code, forKey: TranscriptionLanguage.defaultsKey)
        languageMismatch = nil
        watch.switched(to: code)
        bufferLock.withLock {
            sessionLanguage = code
            router.switchLanguage(to: code)
        }
        guard isTranscribing, let deepgramKey else { return }
        let offset = Date().timeIntervalSince(meetingStartTime)
        for source in AudioSource.allCases {
            let fresh = makeDeepgramStreamer(source: source, apiKey: deepgramKey, language: code, offset: offset)
            let old: DeepgramStreamer? = bufferLock.withLock {
                guard !deepgramFailedSources.contains(source) else { return nil }
                defer { deepgramStreamers[source] = fresh }
                return deepgramStreamers[source]
            }
            guard let old else { fresh.close(); continue }
            old.finish()
            Task {
                try? await Task.sleep(for: .seconds(1.2))  // same grace as stop
                old.close()
            }
        }
    }

    /// Ask Whisper what language one side's probe is in. It routes that side
    /// on Parakeet, and the first conclusive answer drives the mismatch
    /// banner (an unsure one re-arms that side, a few times at most).
    func checkLanguage(_ samples: [Float], source: AudioSource) async {
        var detected: (language: String, confidence: Float)?
        if let detector = languageDetector, !samples.isEmpty,
           let result = try? await detector.detectLangauge(audioArray: Self.normalizedForDecode(samples)) {
            // WhisperKit reports the winner's log-probability.
            detected = (result.language, exp(result.langProbs[result.language] ?? -.infinity))
        }
        let heard = detected?.language
        let confidence = detected?.confidence ?? 0
        let (setting, backend, holding, change, themHeld) = bufferLock.withLock {
            let holding = router.route(source) == .undecided
            let change = router.heard(source, language: heard, confidence: confidence)
            // Unsure while holding: this side gets one more stretch.
            if case .retry = change { probe?.rearm(source) }
            return (sessionLanguage, sessionBackend, holding, change, router.route(.them) == .undecided)
        }
        if Self.loopTrace {
            print(String(format: "TRACE %@ language check: heard %@ p=%.2f from %.1f s → %@", source.label,
                         heard ?? "-", confidence, Double(samples.count) / 16000, String(describing: change)))
        }
        AudioCaptureManager.oslog.info("Language check \(source.label, privacy: .public): heard \(heard ?? "-", privacy: .public) p=\(confidence, privacy: .public), set \(setting ?? "auto", privacy: .public)")
        if let change, let notice = Self.noticeFor(change, heard: heard) {
            await MainActor.run { if self.isTranscribing { self.cloudNotice = notice } }
        } else if holding, !themHeld {
            // The notice is about the other side's lines. Yours rarely wait
            // (you're mostly listening), so they don't keep it up.
            await MainActor.run { if self.cloudNotice == Self.checkingNotice { self.cloudNotice = nil } }
        }
        // A routing check on Auto isn't a warning check: Auto on this Mac
        // transcribes any language, so there's nothing to offer. The banner
        // can only fire on a pinned language, or Deepgram on auto; only
        // those keep checking every side all call.
        guard !holding, let heard, setting != nil || backend == .deepgram else { return }
        let mismatch = Self.languageMismatch(setting: setting, backend: backend, heard: heard, confidence: confidence)
        await MainActor.run {
            guard self.isTranscribing else { return }
            let (offer, recheckAfter) = self.watch.heard(source, mismatch: mismatch, confidence: confidence)
            if let offer { self.languageMismatch = offer }
            self.bufferLock.withLock { self.probe?.rearm(source, skipping: recheckAfter) }
        }
    }

    static let checkingNotice = "Checking the language\u{2026}"

    /// A Parakeet side's lines since its last clean language check, with
    /// their audio, so a late switch to Whisper can re-do them. Loop-only.
    @ObservationIgnored private var kept: [AudioSource: [(start: TimeInterval, end: TimeInterval, audio: [Float])]] = [:]
    /// Sides due a language recheck, and how many seconds of their latest
    /// audio to check; the loop runs it before that side's next cut, so a
    /// recheck never races the decode it might redo.
    @ObservationIgnored private var pendingRecheck: [AudioSource: Int] = [:]

    /// Parakeet was unsure of a line it wrote: on English its lines scored
    /// 0.98-1.00, on Turkish (which it can't do) 0.10-0.71. That only asks
    /// for a language check on the spot. It never drops or hides a line.
    nonisolated static let parakeetDoubt: Float = 0.9
    nonisolated static func parakeetDoubts(_ score: Float, seconds: TimeInterval) -> Bool {
        score < parakeetDoubt && seconds >= 1.5
    }
    /// Replace one side's lines in a time range (a rewind), same hop as onSegment.
    var onReplace: ((AudioSource, ClosedRange<TimeInterval>, [TranscriptionResult]) -> Void)?

    /// The latest `seconds` of a side's kept audio, for its recheck.
    nonisolated static func recheckAudio(_ clips: [[Float]], seconds: Int) -> [Float] {
        Array(clips.joined().suffix(seconds * 16000))
    }

    /// Keeps a Parakeet side's decoded audio for its language recheck: every
    /// 30 s of speech on its latest 10 s, or at once on the latest 5 s when
    /// Parakeet doubted the line (a side switching to Turkish, most likely).
    private func keepForRecheck(_ samples: [Float], source: AudioSource, start: TimeInterval, end: TimeInterval,
                                doubtful: Bool = false) {
        kept[source, default: []].append((start, end, samples))
        // ponytail: 90 s cap per side, so failed checks can't grow memory.
        while (kept[source]?.reduce(0) { $0 + $1.audio.count } ?? 0) > 90 * 16000 { kept[source]?.removeFirst() }
        let due = bufferLock.withLock { router.decoded(source, seconds: end - start) }
        if doubtful {
            pendingRecheck[source] = 5
        } else if due, pendingRecheck[source] == nil {
            pendingRecheck[source] = 10
        }
    }

    /// Ask again what language a Parakeet side speaks. Still one of
    /// Parakeet's: those lines are verified. Something else (Turkish mid-call):
    /// the side is on Whisper from now on, and its lines since the last clean
    /// check are re-done with Whisper and replaced.
    private func recheck(_ source: AudioSource, seconds: Int, options: DecodingOptions) async {
        let clips = kept[source] ?? []
        await checkLanguage(Self.recheckAudio(clips.map(\.audio), seconds: seconds), source: source)
        guard bufferLock.withLock({ router.route(source) }) == .whisper else {
            kept[source] = []
            return
        }
        kept[source] = nil
        let started = Date()
        guard let first = clips.first, let last = clips.last, let whisper = await ensureWhisper() else { return }
        if Self.loopTrace { print(String(format: "TRACE %@ rewind: Whisper ready after %.1f s", source.label, Date().timeIntervalSince(started))) }
        let bare = Self.withoutGlossary(options)
        var redone: [TranscriptionResult] = []
        for clip in clips {
            let clipStarted = Date()
            let pieces = (try? await whisper.transcribe(audioArray: Self.normalizedForDecode(clip.audio),
                                                        decodeOptions: bare)) ?? []
            if Self.loopTrace { print(String(format: "TRACE %@ rewind: %.1f s clip in %.1f s", source.label, clip.end - clip.start, Date().timeIntervalSince(clipStarted))) }
            let text = Self.cleaned(pieces.map(\.text).joined(separator: " "))
            if !text.isEmpty {
                redone.append(TranscriptionResult(text: text, source: source, startTime: clip.start,
                                                  endTime: clip.end, confidence: nil))
            }
        }
        if Self.loopTrace { print("TRACE \(source.label) rewind \(clips.count) line(s), \(first.start)-\(last.end) s") }
        let replacement = redone
        await MainActor.run { self.onReplace?(source, first.start...last.end, replacement) }
    }

    /// The live bar's line when a side's engine is decided or switched.
    static func noticeFor(_ change: LanguageRouter.Change, heard: String?) -> String? {
        let name = heard.map(TranscriptionLanguage.name)
        switch change {
        case .decided(let source, .whisper):
            let side = source == .me ? "you" : "them"
            return name.map { "\($0) heard: using Whisper for \(side)" } ?? "Language unclear: using Whisper for \(side)"
        case .switchedToWhisper(let source):
            return "\(name ?? "Another language") heard: using Whisper for \(source == .me ? "you" : "them") from here"
        default:
            return nil
        }
    }

    /// The on-device engine a cloud fallback lands on, for the live bar.
    private var onDeviceName: String { parakeet != nil ? "Parakeet" : "Whisper" }

    /// Which language to offer switching to, or nil to stay quiet.
    /// - setting: the session's language (nil = auto-detect)
    /// - heard: Whisper's language code for the call's first ~10 s of speech
    /// - confidence: Whisper's probability for `heard`, 0...1
    static func languageMismatch(setting: String?, backend: TranscriptionBackend,
                                 heard: String, confidence: Float) -> String? {
        // 0.8: real calls score 1.00; an unsure guess must not nag.
        guard confidence >= 0.8, heard != setting,
              TranscriptionLanguage.options.contains(where: { $0.code == heard }) else { return nil }
        if setting != nil { return heard }
        // Auto: Whisper and Groq detect anything; Deepgram only its ten.
        return backend == .deepgram && !TranscriptionLanguage.deepgramMulti.contains(heard) ? heard : nil
    }

    /// Re-anchor a stream's locally-derived timestamps to "now" in meeting time.
    /// Called when a stream falls off Deepgram mid-call: the local sample
    /// counter wasn't ticking while Deepgram had the audio, so the next
    /// locally-transcribed segments would otherwise land minutes early. (Gaps
    /// in capture itself are padded with silence upstream, in AudioCaptureManager.)
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
        guard let promptText = Self.glossaryPrompt(from: UserDefaults.standard.string(forKey: "customVocabulary") ?? ""),
              let tokenizer = whisperKit?.tokenizer else { return }
        let tokens = tokenizer.encode(text: " " + promptText)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        options.promptTokens = tokens
        options.usePrefillPrompt = true
        glossaryActive = true
    }

    /// The same decode without the glossary prompt, for when the prompt
    /// misfired or a Parakeet stretch is redone with Whisper. WhisperKit forces
    /// the language only through the prefill, so a pinned language keeps it.
    static func withoutGlossary(_ options: DecodingOptions) -> DecodingOptions {
        var bare = options
        bare.promptTokens = nil
        bare.usePrefillPrompt = options.language != nil
        return bare
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
        if let parakeet, let lines = try await parakeetImport(url: url, parakeet: parakeet) { return lines }
        // Whisper: on Parakeet, loaded for this file only when it needs it.
        guard let whisperKit = await ensureWhisper() else { throw RecordingError.modelNotReady }

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
        options.temperatureFallbackCount = 3
        // ponytail: no glossary prompt here. Prompt tokens + timestamped
        // decoding makes Whisper return empty text for every 30 s window, so
        // any user with a custom vocabulary got "No speech found" on every
        // import (2026-09-25). Imports lose the vocabulary hint; bring it back
        // only with a prompt/timestamp combo that a real file proves works.
        glossaryActive = false

        let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
        let timeline = await speechTimeline(url: url)

        // One mixed track, so every segment is "Them"; diarization splits it later.
        return results.flatMap(\.segments).compactMap { segment in
            let cleaned = Self.cleaned(segment.text)
            guard !cleaned.isEmpty else { return nil }
            // Lines Whisper wrote over a stretch with no voice are invented.
            if let timeline, !Self.hasVoice(timeline, from: Double(segment.start), to: Double(segment.end)) {
                return nil
            }
            // Same glossary-prompt echo handling as the live loop.
            guard let text = glossaryActive
                ? Self.strippingGlossaryEcho(cleaned) : cleaned else { return nil }
            return TranscriptionResult(
                text: text,
                source: .them,
                startTime: Double(segment.start),
                endTime: Double(segment.end),
                confidence: segment.avgLogprob
            )
        }
    }

    /// Parakeet's share of imports. nil = this file goes to Whisper: a pinned
    /// language Parakeet lacks, or on Auto any of three 30 s windows that
    /// isn't confidently one of its 25 (one mixed track, so the whole file
    /// goes one way).
    private func parakeetImport(url: URL, parakeet: ParakeetTranscriber) async throws -> [TranscriptionResult]? {
        let pinned = TranscriptionLanguage.selected
        if let pinned, !LanguageRouter.parakeetLanguages.contains(pinned) { return nil }
        let samples = AudioProcessor.convertBufferToArray(buffer: try AudioProcessor.loadAudio(fromPath: url.path))
        var hint = pinned
        if pinned == nil {
            var verdicts: [(language: String?, confidence: Float)] = []
            for window in Self.importWindows(sampleCount: samples.count) {
                if let detector = languageDetector,
                   let result = try? await detector.detectLangauge(audioArray: Self.normalizedForDecode(Array(samples[window]))) {
                    verdicts.append((result.language, exp(result.langProbs[result.language] ?? -.infinity)))
                } else {
                    verdicts.append((nil, 0))
                }
            }
            if Self.loopTrace { print("TRACE import language: \(verdicts.map { "\($0.language ?? "-") \(String(format: "%.2f", $0.confidence))" })") }
            guard Self.importUsesParakeet(verdicts) else { return nil }
            let heard = Set(verdicts.compactMap(\.language))
            hint = heard.count == 1 ? heard.first : nil
        }
        let timeline = await speechTimeline(samples: samples)
        var lines: [TranscriptionResult] = []
        for piece in Self.utterances(in: samples) {
            let start = Double(piece.start) / 16000, end = Double(piece.start + piece.audio.count) / 16000
            // Lines over a stretch with no voice would be invented.
            if let timeline, !Self.hasVoice(timeline, from: start, to: end) { continue }
            let text = Self.cleaned(try await parakeet.transcribe(Self.normalizedForDecode(piece.audio), language: hint))
            guard !text.isEmpty else { continue }
            // One mixed track, so every line is "Them"; diarization splits it later.
            lines.append(TranscriptionResult(text: text, source: .them, startTime: start, endTime: end, confidence: nil))
        }
        return lines
    }

    /// Start, middle and end: 30 s each (one window for short files).
    nonisolated static func importWindows(sampleCount: Int) -> [Range<Int>] {
        let window = 30 * 16000
        guard sampleCount > window * 3 else { return [0 ..< sampleCount] }
        let mid = sampleCount / 2 - window / 2
        return [0 ..< window, mid ..< mid + window, sampleCount - window ..< sampleCount]
    }

    nonisolated static func importUsesParakeet(_ verdicts: [(language: String?, confidence: Float)]) -> Bool {
        !verdicts.isEmpty && verdicts.allSatisfy { verdict in
            verdict.language.map(LanguageRouter.parakeetLanguages.contains) == true && verdict.confidence >= LanguageRouter.sure
        }
    }

    /// The live loop's cutter over a whole file, so imported lines get the
    /// same sample-offset timestamps as live ones. A window of twice the
    /// segment cap always holds a cut, and slicing it keeps a long file linear.
    nonisolated static func utterances(in samples: [Float]) -> [(start: Int, audio: [Float])] {
        var pieces: [(start: Int, audio: [Float])] = []
        var offset = 0
        let window = Segmenter.maxSegmentSamples * 2
        while offset < samples.count {
            let end = min(offset + window, samples.count)
            let buffer = Array(samples[offset ..< end])
            let floor = Segmenter.adaptiveFloor(for: buffer)
            var cut = Segmenter.nextCut(in: buffer, draining: end == samples.count, floor: floor)
            if cut.dropLeading == 0, cut.take == nil {
                cut = Segmenter.nextCut(in: buffer, draining: true, floor: floor)
            }
            let take = cut.take ?? 0
            if take > 0 {
                pieces.append((offset + cut.dropLeading, Array(buffer[cut.dropLeading ..< cut.dropLeading + take])))
            }
            let consumed = cut.dropLeading + take
            guard consumed > 0 else { break }
            offset += consumed
        }
        return pieces
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

        languageMismatch = nil
        isTranscribing = false          // flips the loop into drain mode
        await transcriptionTask?.value  // deliberately not cancel(): let it finish
        transcriptionTask = nil
        // On Parakeet, a Whisper loaded for this call goes again: memory back.
        if parakeet != nil { whisperKit = nil }
        bufferLock.withLock { probe = nil }
        kept = [:]
        pendingRecheck = [:]

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
    /// "Glossary: a, b." from the Settings vocabulary, or nil when empty. The
    /// on-device engine primes Whisper with it, behind its echo guard. Groq
    /// does NOT get it: sent as `prompt`, Whisper echoed it into every quiet
    /// chunk of a real call ("Glossary, Uygar"), and that path has no guard.
    nonisolated static func glossaryPrompt(from vocabulary: String) -> String? {
        let terms = vocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return terms.isEmpty ? nil : "Glossary: " + terms.joined(separator: ", ") + "."
    }

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
